#!/usr/bin/env python3
import fcntl
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_AUDIO_BYTES = 2 * 1024 * 1024 * 1024
MAX_TRACKS = 1000
FORMATS = {"mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "alac"}
SITE = "https://downloads.khinsider.com"
ALBUM_PATH = re.compile(r"/game-soundtracks/album/[A-Za-z0-9._~%!-]+(?:/[A-Za-z0-9._~%!-]+)*")
MEDIA_HOST = re.compile(r"(?:[a-z0-9-]+\.)*(?:vgmsite\.com|vgmtreasurechest\.com)")
PLUGIN_ID = "kelmankenberg.omakhinsider"
BAR_SECTIONS = ("left", "centerBegin", "center", "centerEnd", "right", "tray")


class Canceled(Exception):
    pass


def bounded_string(value, limit, label):
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ValueError(f"Invalid {label}")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError(f"Control characters in {label}")
    return value


def album_url(value):
    bounded_string(value, 2048, "album URL")
    parts = urlsplit(value)
    if (parts.scheme != "https" or parts.netloc != "downloads.khinsider.com"
            or parts.query or parts.fragment or not ALBUM_PATH.fullmatch(parts.path)
            or any(part in {".", ".."} for part in parts.path.split("/"))):
        raise ValueError("Invalid KHInsider album URL")
    return value


def media_url(value, expected_format=None):
    bounded_string(value, 4096, "audio URL")
    parts = urlsplit(value)
    extension = parts.path.rsplit(".", 1)[-1].lower()
    if (parts.scheme != "https" or parts.username or parts.password or parts.port
            or parts.fragment or not MEDIA_HOST.fullmatch(parts.hostname or "")
            or extension not in FORMATS
            or (expected_format and extension != expected_format)):
        raise ValueError("Audio link is not on a supported KHInsider media host")
    return value


def validate_manifest(value):
    if not isinstance(value, dict):
        raise ValueError("Invalid album inspection")
    url = album_url(value.get("url"))
    title = bounded_string(value.get("title"), 500, "album title")
    tracks = value.get("tracks")
    if not isinstance(tracks, list) or not 1 <= len(tracks) <= MAX_TRACKS:
        raise ValueError("An album must contain between 1 and 1000 tracks")
    result = []
    seen = set()
    for track in tracks:
        if not isinstance(track, dict):
            raise ValueError("Invalid track")
        track_url = bounded_string(track.get("trackUrl"), 2048, "track URL")
        suffix = track_url.removeprefix(url + "/")
        if (not track_url.startswith(url + "/") or track_url in seen
                or not re.fullmatch(r"[A-Za-z0-9._~%!-]+(?:/[A-Za-z0-9._~%!-]+)*", suffix)
                or any(part in {".", ".."} for part in suffix.split("/"))):
            raise ValueError("Track URL does not belong to this album")
        seen.add(track_url)
        links = track.get("audioLinks")
        if not isinstance(links, list) or not 1 <= len(links) <= len(FORMATS):
            raise ValueError("Track has no supported audio links")
        formats = set()
        audio = []
        for link in links:
            if not isinstance(link, dict) or link.get("format") not in FORMATS:
                raise ValueError("Invalid audio format")
            fmt = link["format"]
            if fmt in formats:
                raise ValueError("Duplicate audio format")
            formats.add(fmt)
            audio.append({"format": fmt, "url": media_url(link.get("url"), fmt)})
        result.append({
            "title": bounded_string(track.get("title"), 500, "track title"),
            "trackUrl": track_url,
            "audioLinks": audio,
        })
    return {"url": url, "title": title, "tracks": result}


def download_directory(value):
    bounded_string(value, 4096, "download directory")
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise ValueError("Use an absolute download directory or a path starting with ~/")
    path.mkdir(parents=True, exist_ok=True)
    path = path.resolve(strict=True)
    with tempfile.TemporaryFile(dir=path):
        pass
    return path


def choose_directory(request):
    initial = Path(bounded_string(request.get("directory"), 4096, "initial directory")).expanduser()
    if not initial.is_absolute():
        raise ValueError("The initial directory must be an absolute path")
    while not initial.is_dir() and initial != initial.parent:
        initial = initial.parent
    title = bounded_string(request.get("title"), 500, "folder chooser title")
    result = subprocess.run(
        ["zenity", "--file-selection", "--directory", "--title=" + title,
         "--filename=" + str(initial).rstrip("/") + "/"],
        text=True, capture_output=True, check=False,
    )
    if result.returncode == 1:
        raise Canceled()
    if result.returncode != 0:
        raise ValueError("Could not open the folder chooser: " + result.stderr.strip()[:500])
    selected = result.stdout.removesuffix("\n")
    bounded_string(selected, 4096, "selected directory")
    path = Path(selected)
    if not path.is_absolute() or not path.is_dir():
        raise ValueError("The folder chooser did not return an existing local directory")
    return {"directory": selected}


def import_directory():
    return Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "omakhinsider/imports"


def read_import(value):
    path = Path(value)
    if (path.parent != import_directory() or not re.fullmatch(r"[0-9a-f]{32}\.json", path.name)):
        raise ValueError("Invalid browser import location")
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_JSON_BYTES:
            raise ValueError("Browser inspection is too large")
        data = source.read(MAX_JSON_BYTES + 1)
    try:
        if len(data) > MAX_JSON_BYTES:
            raise ValueError("Browser inspection is too large")
        return validate_manifest(json.loads(data))
    finally:
        path.unlink()


def safe_name(value):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f\x7f]', "_", value).strip(" .")
    return (name[:100].rstrip(" .") or "Untitled")


class MediaRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        media_url(new_url)
        return super().redirect_request(request, response, code, message, headers, new_url)


def open_media(url, referer):
    return build_opener(MediaRedirect()).open(
        Request(media_url(url), headers={
            "User-Agent": "OmaKhinsider/0.2",
            "Accept": "audio/*,application/octet-stream",
            "Referer": referer,
        }),
        timeout=30,
    )


def atomic_json(path, value, label="Album manifest"):
    encoded = json.dumps(value, ensure_ascii=True)
    if len(encoded.encode()) > MAX_JSON_BYTES:
        raise ValueError(label + " exceeds the 2 MiB limit")
    descriptor, temporary = tempfile.mkstemp(prefix=".omakhinsider-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def bar_player_layout(config, enabled, side):
    if not isinstance(enabled, bool) or side not in {"left", "right"}:
        raise ValueError("Invalid top-bar player settings")
    if (not isinstance(config, dict) or not isinstance(config.get("bar"), dict)
            or not isinstance(config["bar"].get("layout"), dict)):
        raise ValueError("Omarchy shell configuration has no valid bar layout")
    result = json.loads(json.dumps(config))
    layout = result["bar"]["layout"]
    player = None
    primary_present = False
    for section in BAR_SECTIONS:
        entries = layout.get(section, [])
        if not isinstance(entries, list):
            raise ValueError("Invalid Omarchy bar section: " + section)
        kept = []
        for entry in entries:
            own = isinstance(entry, dict) and entry.get("id") == PLUGIN_ID
            if own and entry.get("view") == "player":
                if player is None:
                    player = entry
            else:
                kept.append(entry)
                primary_present = primary_present or own or entry == PLUGIN_ID
        if section in layout:
            layout[section] = kept
    if not primary_present:
        raise ValueError("Place the KH library icon on the bar before enabling its player")
    player = player if player is not None else {"id": PLUGIN_ID, "view": "player"}
    player["playerEnabled"] = enabled
    section = "centerBegin" if side == "left" else "centerEnd"
    entries = layout.setdefault(section, [])
    entries.insert(len(entries) if side == "left" else 0, player)
    return result


def configure_bar_player(request):
    path = Path.home() / ".config/omarchy/shell.json"
    if path.is_symlink():
        raise ValueError("Cannot replace a symlinked Omarchy shell configuration")
    if not path.is_file():
        raise ValueError("Omarchy shell configuration is missing; place the KH icon on the bar first")
    with (path.parent / ".omakhinsider-bar.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with path.open("rb") as source:
            raw = source.read(MAX_JSON_BYTES + 1)
        if len(raw) > MAX_JSON_BYTES:
            raise ValueError("Shell configuration exceeds the 2 MiB limit")
        config = json.loads(raw)
        try:
            current = subprocess.run(
                ["omarchy-shell", "shell", "listShellConfig"],
                text=True, capture_output=True, timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError("Could not read the running shell configuration; retry: " + str(error)) from error
        if current.returncode != 0:
            raise ValueError("Could not read the running shell configuration: " + current.stderr.strip()[:500])
        if json.loads(current.stdout) != config:
            raise ValueError("Omarchy has pending configuration changes; wait briefly and retry")
        changed = bar_player_layout(config, request.get("enabled"), request.get("side"))
        if path.read_bytes() != raw:
            raise ValueError("Bar configuration changed during this operation; retry")
        if changed != config:
            atomic_json(path, changed, "Shell configuration")
        try:
            result = subprocess.run(
                ["omarchy-shell", "shell", "reloadConfig"],
                text=True, capture_output=True, timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError("Bar settings were saved, but the shell could not reload. Restart the Omarchy shell: " + str(error)) from error
        if result.returncode != 0 or result.stdout.strip() != "ok":
            raise ValueError("Bar settings were saved, but the shell could not reload. Restart the Omarchy shell: " +
                             (result.stderr.strip() or result.stdout.strip())[:500])
    return {"enabled": request["enabled"], "side": request["side"]}


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(256 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def album_identity(url, fmt):
    return "kh-" + hashlib.sha256((url + "\n" + fmt).encode()).hexdigest()


def portable_identity(url, tracks):
    formats = {track["format"] for track in tracks}
    fmt = next(iter(formats)) if len(formats) == 1 else "mixed"
    return (album_identity(url, fmt) if url else
            "local-" + hashlib.sha256("\n".join(track["sha256"] for track in tracks).encode()).hexdigest())


def read_record(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_JSON_BYTES:
            raise ValueError("Invalid or oversized album manifest")
        return json.loads(source.read(MAX_JSON_BYTES + 1))


def relative_path(value):
    bounded_string(value, 4096, "relative audio path")
    parts = value.split("/")
    if ("\\" in value or len(parts) > 7
            or any(part in {"", ".", ".."} or len(part) > 255 for part in parts)):
        raise ValueError("Audio paths must stay within the album folder")
    return parts


def audio_file(folder, name, record=None):
    parts = relative_path(name)
    parent = folder
    for part in parts[:-1]:
        parent = parent / part
        if parent.is_symlink() or not parent.is_dir():
            raise ValueError("Audio paths must not traverse symbolic links or missing folders")
    path = folder / name
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_AUDIO_BYTES:
            raise ValueError(f"Invalid audio file: {name}")
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if record is not None and (not isinstance(record, dict)
                              or record.get("bytes") != info.st_size or record.get("sha256") != digest):
        raise ValueError(f"Audio verification failed: {name}")
    return {"path": name, "bytes": info.st_size, "sha256": digest,
            "format": path.suffix[1:].lower()}


def validate_portable(folder, entry):
    if not isinstance(entry, dict) or entry.get("complete") is not True:
        raise ValueError("Incomplete album; finish or retry its download before importing")
    title = bounded_string(entry.get("title"), 500, "album title")
    tracks = entry.get("tracks")
    if not isinstance(tracks, list) or not 1 <= len(tracks) <= MAX_TRACKS:
        raise ValueError("Invalid portable track list")
    url = album_url(entry["albumUrl"]) if entry.get("albumUrl") else None
    result = []
    seen = set()
    for track in tracks:
        if not isinstance(track, dict):
            raise ValueError("Invalid portable track")
        data = audio_file(folder, track.get("path"), track)
        if data["format"] not in FORMATS or track.get("format") != data["format"] or data["path"] in seen:
            raise ValueError("Invalid or duplicate audio format/path")
        seen.add(data["path"])
        data["title"] = bounded_string(track.get("title"), 500, "track title")
        if track.get("trackUrl") is not None:
            if not url:
                raise ValueError("Track URL has no source album")
            track_url = bounded_string(track.get("trackUrl"), 2048, "track URL")
            suffix = track_url.removeprefix(url + "/")
            if (not track_url.startswith(url + "/")
                    or not re.fullmatch(r"[A-Za-z0-9._~%!-]+(?:/[A-Za-z0-9._~%!-]+)*", suffix)
                    or any(part in {".", ".."} for part in suffix.split("/"))
                    or any(item.get("trackUrl") == track_url for item in result)):
                raise ValueError("Invalid portable track URL")
            data["trackUrl"] = track_url
        result.append(data)
    identity = portable_identity(url, result)
    if entry.get("libraryId") != identity:
        raise ValueError("Album identity does not match the manifest")
    album = {"libraryId": identity, "title": title, "tracks": result,
             **({"albumUrl": url} if url else {})}
    if "discs" in entry:
        discs = entry["discs"]
        if not isinstance(discs, list) or not 2 <= len(discs) <= 100:
            raise ValueError("Invalid multi-disc album")
        paths = set()
        identities = set()
        for disc in discs:
            if (not isinstance(disc, dict) or len(relative_path(disc.get("path"))) != 1
                    or not re.fullmatch(r"(?:kh|local)-[a-f0-9]{64}", disc.get("libraryId", ""))
                    or disc["path"] in paths or disc["libraryId"] in identities
                    or not any(track["path"].startswith(disc["path"] + "/") for track in result)):
                raise ValueError("Invalid or duplicate disc folder")
            paths.add(disc["path"])
            identities.add(disc["libraryId"])
        if any(track["path"].split("/")[0] not in paths for track in result):
            raise ValueError("Track is outside the declared disc folders")
        album["discs"] = [{"path": disc["path"], "libraryId": disc["libraryId"]} for disc in discs]
    return album


def probe_tags(path):
    with tempfile.TemporaryFile() as output:
        try:
            result = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries",
                 "format_tags=title,album,track,disc:stream=codec_type", "-of", "json", str(path)],
                stdout=output, stderr=subprocess.PIPE, timeout=15, check=False,
            )
        except FileNotFoundError as error:
            raise ValueError("ffprobe is required to preview albums without complete manifests") from error
        except subprocess.TimeoutExpired as error:
            raise ValueError(f"Audio metadata inspection timed out: {path.name}") from error
        if result.returncode:
            raise ValueError(f"Cannot inspect audio metadata: {path.name}")
        if output.tell() > MAX_JSON_BYTES:
            raise ValueError(f"Audio metadata is too large: {path.name}")
        output.seek(0)
        data = json.load(output)
    if not any(stream.get("codec_type") == "audio" for stream in data.get("streams", [])):
        raise ValueError(f"No audio stream: {path.name}")
    return {key.lower(): value for key, value in data.get("format", {}).get("tags", {}).items()}


def natural_order(value):
    return [(0, int(part)) if part.isdigit() else (1, part.casefold())
            for part in re.split(r"(\d+)", value)]


def infer_album(folder, names, record, hints):
    if len(names) > MAX_TRACKS:
        raise ValueError("Album exceeds the 1000 track limit")
    files = record.get("files", {}) if record else {}
    if not isinstance(files, dict):
        raise ValueError("Invalid legacy download record")
    url = album_url(record["albumUrl"]) if record and record.get("albumUrl") else None
    tracks = []
    titles = []
    matching = [hint for hint in hints if hint.get("kind") != "online"
                and url and hint.get("sourceAlbumUrl") == url]
    for name in sorted(names, key=natural_order):
        verification = files.get(name) if record else None
        if record and verification is None:
            raise ValueError(f"Unverified file in legacy download folder: {name}")
        data = audio_file(folder, name, verification)
        known = next((track for hint in matching for track in hint.get("tracks", [])
                      if Path(track.get("localPath", "")).name == name
                      and hashlib.sha256(track.get("trackUrl", "").encode()).hexdigest()
                      == verification.get("source")), None) if verification else None
        if known:
            tags = {}
            data["title"] = bounded_string(known.get("title"), 500, "track title")
            data["trackUrl"] = known["trackUrl"]
            titles.append(known.get("albumTitle", ""))
        else:
            tags = probe_tags(folder / name)
            data["title"] = bounded_string(tags.get("title") or
                                          re.sub(r"^\d+[\s._-]+", "", Path(name).stem) or Path(name).stem,
                                          500, "track title")
            if tags.get("album"):
                titles.append(bounded_string(tags["album"], 500, "album title"))
        def number(key):
            match = re.match(r"\d+", str(tags.get(key, "")))
            return int(match[0]) if match else 0
        tracks.append((number("disc"), number("track"), natural_order(name), data))
    tracks = [item[3] for item in sorted(tracks, key=lambda item: item[:3])]
    # Legacy records cannot prove completeness without the original playlist.
    for hint in matching:
        expected = [Path(track.get("localPath", "")).name for track in hint.get("tracks", [])
                    if track.get("localPath") and Path(track["localPath"]).suffix[1:].lower()
                    in {item["format"] for item in tracks}]
        if set(expected) - set(names):
            raise ValueError("Legacy album is missing tracks from its saved playlist")
    if not tracks:
        raise ValueError("No audio files found")
    identity = portable_identity(url, tracks)
    return {"libraryId": identity,
            "title": next((title for title in titles if title), folder.name)[:500],
            "tracks": tracks, **({"albumUrl": url} if url else {})}


def scan_folder(folder, hints, warnings=None, group_discs=True):
    bounded_string(str(folder), 4096, "album directory")
    if folder.is_symlink():
        raise ValueError("Album folders must not be symbolic links")
    if not folder.is_dir():
        raise ValueError("Album folder does not exist or is not a directory")
    record_path = folder / ".omakhinsider.json"
    record = read_record(record_path) if record_path.exists() or record_path.is_symlink() else None
    if record is not None and not isinstance(record, dict):
        raise ValueError("Invalid album manifest")
    if record is not None and "schemaVersion" in record:
        if record["schemaVersion"] not in {1, 2} or not isinstance(record.get("albums"), list) or not 1 <= len(record["albums"]) <= 9:
            raise ValueError("Unsupported portable album manifest")
        entries = []
        for entry in record["albums"]:
            try:
                entries.append(validate_portable(folder, entry))
            except (ValueError, OSError, TypeError, KeyError) as error:
                if warnings is None:
                    raise
                warnings.append(f"{folder}: {error}")
        return entries, False
    names = [entry.name for entry in folder.iterdir() if entry.suffix[1:].lower() in FORMATS]
    if not names:
        if record:
            raise ValueError("Album manifest has no audio files")
        if group_discs:
            return scan_disc_group(folder, hints)
        return [], False
    return [infer_album(folder, names, record, hints)], True


def scan_disc_group(folder, hints):
    discs = []
    for child in folder.iterdir():
        match = re.fullmatch(r"(?:cd|disc|disk)[ _-]*(\d+)", child.name, re.IGNORECASE)
        if match:
            discs.append((int(match[1]), child))
    if len(discs) < 2:
        return [], False
    discs.sort(key=lambda item: item[0])
    if len(discs) > 100 or len({number for number, _ in discs}) != len(discs):
        raise ValueError("Too many or ambiguously numbered disc folders")
    inspected = []
    for _number, child in discs:
        entries, _preview = scan_folder(child, hints, group_discs=False)
        if not entries:
            raise ValueError(f"No complete audio album in disc folder: {child.name}")
        inspected.append((child, entries))
    # Do not silently drop a format present on only some discs.
    by_disc = []
    for child, entries in inspected:
        formats = {}
        for entry in entries:
            key = tuple(sorted({track["format"] for track in entry["tracks"]}))
            if key in formats:
                raise ValueError(f"Ambiguous editions in disc folder: {child.name}")
            formats[key] = entry
        by_disc.append((child, formats))
    if any(set(editions) != set(by_disc[0][1]) for _child, editions in by_disc):
        raise ValueError("Disc folders contain different audio formats; import them separately")
    grouped = []
    for key in by_disc[0][1]:
        entries = [(child, editions[key]) for child, editions in by_disc]
        urls = {entry.get("albumUrl") for _child, entry in entries}
        if len(urls) != 1:
            raise ValueError("Disc folders have different source albums; import them separately")
        tracks = [{**track, "path": child.name + "/" + track["path"]}
                  for child, entry in entries for track in entry["tracks"]]
        if len(tracks) > MAX_TRACKS:
            raise ValueError("Multi-disc album exceeds the 1000 track limit")
        url = next(iter(urls))
        identity = portable_identity(url, tracks)
        title = entries[0][1]["title"]
        title = re.sub(r"\s*[\[(]?(?:cd|disc|disk)\s*\d+[\])]?\s*$", "", title, flags=re.IGNORECASE).strip() or folder.name
        portable = {
            "libraryId": identity, "title": title, "tracks": tracks, "complete": True,
            "discs": [{"path": child.name, "libraryId": entry["libraryId"]} for child, entry in entries],
            **({"albumUrl": url} if url else {}),
        }
        grouped.append(validate_portable(folder, portable))
    return grouped, True


def playlist_locations(hints, warnings):
    locations = []
    for hint in hints:
        directory = hint.get("downloadDirectory")
        if hint.get("kind") == "online" or not directory:
            continue
        bounded_string(directory, 4096, "saved album directory")
        if not Path(directory).is_absolute():
            raise ValueError("Invalid saved album directory")
        try:
            info = Path(directory).stat()
            missing = not stat.S_ISDIR(info.st_mode)
        except (FileNotFoundError, NotADirectoryError):
            missing = True
        except OSError as error:
            warnings.append(f"{directory}: cannot check saved album folder: {error}")
            continue
        locations.append({"id": hint.get("id"), "directory": directory, "missing": missing})
    return locations


def scan_library(request):
    path = Path(bounded_string(request.get("directory"), 4096, "library directory")).expanduser()
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        raise ValueError("Choose an existing, non-symbolic-link library directory")
    root = path.resolve(strict=True)
    hints = request.get("playlists", [])
    if not isinstance(hints, list) or len(hints) > 200 or not all(isinstance(hint, dict) for hint in hints):
        raise ValueError("Invalid saved playlist hints")
    albums, previews, warnings = [], [], []
    visited = 0
    identities = set()
    for directory, subfolders, _files in os.walk(root, followlinks=False):
        folder = Path(directory)
        visited += 1
        if visited > 2000:
            raise ValueError("Library exceeds the 2000 folder scan limit")
        symlinks = [name for name in subfolders if (folder / name).is_symlink()]
        warnings.extend(f"{folder / name}: symbolic-link folder skipped" for name in symlinks)
        subfolders[:] = sorted(name for name in subfolders if name not in symlinks and not name.startswith("."))
        if len(folder.relative_to(root).parts) >= 6 and subfolders:
            warnings.append(f"{folder}: subfolders beyond depth 6 skipped")
            subfolders[:] = []
        try:
            entries, preview = scan_folder(folder, hints, warnings)
            covered = {disc["path"] for entry in entries for disc in entry.get("discs", [])}
            subfolders[:] = [name for name in subfolders if name not in covered]
            for entry in entries:
                if entry["libraryId"] in identities:
                    warnings.append(f"{folder}: duplicate album copy skipped")
                    continue
                identities.add(entry["libraryId"])
                entry["directory"] = str(folder)
                (previews if preview else albums).append(entry)
        except (ValueError, OSError, TypeError, KeyError) as error:
            warnings.append(f"{folder}: {error}")
        if len(albums) + len(previews) > 200:
            raise ValueError("Library exceeds the 200 album scan limit")
        if len(warnings) > 200:
            raise ValueError("Too many unreadable or unsupported library folders")
    locations = playlist_locations(hints, warnings)
    result = {"albums": albums, "previews": previews, "warnings": warnings, "locations": locations}
    if len(json.dumps(result).encode()) > MAX_JSON_BYTES:
        raise ValueError("Library scan is too large; choose a smaller library folder")
    return result


def import_folder(request):
    root = Path(bounded_string(request.get("directory"), 4096, "library directory")).expanduser().resolve(strict=True)
    folder = Path(bounded_string(request.get("folder"), 4096, "album directory"))
    if not folder.is_absolute() or not folder.is_relative_to(root):
        raise ValueError("Album folder is outside the library")
    relative = folder.relative_to(root)
    current = root
    for part in relative.parts:
        current = current / part
        if part in {".", ".."} or current.is_symlink():
            raise ValueError("Invalid or symbolic-link album folder")
    entries, preview = scan_folder(folder, request.get("playlists", []))
    matches = [entry for entry in entries if entry["libraryId"] == request.get("libraryId")]
    if len(matches) != 1:
        raise ValueError("Album changed since its preview; refresh folders before importing")
    entry = matches[0]
    if preview:
        record_path = folder / ".omakhinsider.json"
        record = read_record(record_path) if record_path.exists() else {"files": {}}
        record.update({"schemaVersion": 2 if any(album.get("discs") for album in entries) else 1,
                       "albums": [{**album, "complete": True} for album in entries]})
        atomic_json(record_path, record)
    return {"albums": [{**entry, "directory": str(folder)}]}


def relink_folder(request):
    folder = Path(bounded_string(request.get("folder"), 4096, "replacement album folder")).expanduser()
    if not folder.is_absolute() or folder.is_symlink():
        raise ValueError("Choose an existing, non-symbolic-link replacement album folder")
    folder = folder.resolve(strict=True)
    entries, _preview = scan_folder(folder, request.get("playlists", []))
    previous = next((hint for hint in request.get("playlists", [])
                     if hint.get("id") == request.get("playlistId")), None)
    if not previous or previous.get("kind") == "online":
        raise ValueError("The original downloaded playlist is no longer available")
    fmt = request.get("format")
    if fmt != previous.get("downloadFormat"):
        raise ValueError("The replacement must use the original playlist's audio format")
    matches = [entry for entry in entries
               if ({track["format"] for track in entry["tracks"]} == {fmt}
                   or (fmt == "mixed" and len({track["format"] for track in entry["tracks"]}) > 1))]
    if len(matches) != 1:
        raise ValueError("Choose a folder containing one album in the original playlist's audio format")
    entry = matches[0]
    if entry.get("albumUrl") and previous.get("sourceAlbumUrl") and entry["albumUrl"] != previous["sourceAlbumUrl"]:
        raise ValueError("The replacement folder belongs to a different KHInsider album")
    old_identity = entry["libraryId"]
    def title_key(title):
        title = re.sub(r"\s*\((?:feat(?:uring)?\.?|ft\.?|with)\s+[^)]*\)", "", title, flags=re.IGNORECASE)
        return re.sub(r"[\W_]+", "", title.casefold())
    old_tracks = previous.get("tracks", [])
    mapped = []
    matched = set()
    for track in entry["tracks"]:
        key = title_key(track["title"])
        candidates = [old for old in old_tracks if key and title_key(old["title"]) == key]
        unique = sum(title_key(other["title"]) == key for other in entry["tracks"]) == 1
        old = candidates[0] if len(candidates) == 1 and unique else None
        updated = dict(track)
        if old:
            matched.add(old["id"])
            updated["title"] = old["title"]
            if old.get("trackUrl") and old.get("albumUrl") == previous.get("sourceAlbumUrl"):
                updated["trackUrl"] = old["trackUrl"]
        mapped.append((old, updated))
    if len(matched) == len(old_tracks) == len(mapped):
        mapped.sort(key=lambda pair: next(index for index, old in enumerate(old_tracks) if old["id"] == pair[0]["id"]))
    source = entry.get("albumUrl") or previous.get("sourceAlbumUrl")
    if source:
        source = album_url(source)
    linked = {**entry, "tracks": [track for _old, track in mapped], "complete": True}
    if source:
        linked["albumUrl"] = source
    linked["libraryId"] = portable_identity(source, linked["tracks"])
    linked = validate_portable(folder, linked)
    record_path = folder / ".omakhinsider.json"
    record = read_record(record_path) if record_path.exists() else {"files": {}}
    record.update({"schemaVersion": 2 if any(album.get("discs") for album in entries) else 1,
                   "albums": [{**(linked if album is entry else album), "complete": True} for album in entries]})
    if source:
        record["albumUrl"] = source
    atomic_json(record_path, record)
    return {"albums": [{**linked, "directory": str(folder), "previousLibraryId": old_identity}]}


def import_folders(request, emit):
    folders = request.get("folders")
    if not isinstance(folders, list) or not 1 <= len(folders) <= 200:
        raise ValueError("Choose between 1 and 200 album folders to import")
    seen = set()
    for folder in folders:
        if not isinstance(folder, dict):
            raise ValueError("Invalid album folder request")
        name = bounded_string(folder.get("folder"), 4096, "album directory")
        bounded_string(folder.get("libraryId"), 100, "album identity")
        if name in seen:
            raise ValueError("Duplicate album folder request")
        seen.add(name)
    albums, errors = [], []
    for index, folder in enumerate(folders):
        emit({"type": "progress", "completed": index, "total": len(folders),
              "directory": folder["folder"]})
        try:
            result = import_folder({
                "directory": request.get("directory"), "playlists": request.get("playlists", []),
                "folder": folder["folder"], "libraryId": folder["libraryId"],
            })
            albums.extend(result["albums"])
        except (ValueError, OSError, TypeError, KeyError) as error:
            print(f'OmaKhinsider import failed for {folder["folder"]}: {error}', file=sys.stderr)
            errors.append({"directory": folder["folder"], "message": str(error)[:1000]})
        emit({"type": "progress", "completed": index + 1, "total": len(folders),
              "directory": folder["folder"]})
    return {"albums": albums, "errors": errors}


def download_album(request, emit):
    album = validate_manifest(request.get("album"))
    fmt = request.get("format", "mp3")
    if fmt not in {"mp3", "flac"}:
        raise ValueError("Choose MP3 or FLAC")
    selected = []
    for track in album["tracks"]:
        link = next((link for link in track["audioLinks"] if link["format"] == fmt), None)
        if link is None:
            raise ValueError(f'{fmt.upper()} is unavailable for "{track["title"]}". Inspect again or change format.')
        selected.append((track, link))
    root = download_directory(request.get("directory"))
    folder = root / (safe_name(album["title"]) + "-" + hashlib.sha256(album["url"].encode()).hexdigest()[:8])
    if folder.is_symlink():
        raise ValueError("The album folder must not be a symbolic link")
    folder.mkdir(exist_ok=True)
    metadata_path = folder / ".omakhinsider.json"
    if metadata_path.is_symlink():
        raise ValueError("The download record must not be a symbolic link")
    metadata = {"albumUrl": album["url"], "files": {}}
    if metadata_path.exists():
        if metadata_path.stat().st_size > MAX_JSON_BYTES:
            raise ValueError("Download record is too large")
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        if (not isinstance(metadata, dict) or metadata.get("albumUrl") != album["url"]
                or not isinstance(metadata.get("files"), dict)):
            raise ValueError("This folder contains a different or invalid download record")
    portable = {
        "libraryId": album_identity(album["url"], fmt), "title": album["title"],
        "albumUrl": album["url"], "complete": False, "tracks": [],
    }
    editions = metadata.get("albums", [])
    if (not isinstance(editions, list) or len(editions) > 9
            or not all(isinstance(entry, dict) for entry in editions)):
        raise ValueError("Invalid portable album manifest")
    metadata.update({"schemaVersion": 1, "albums": [
        entry for entry in editions if entry.get("libraryId") != portable["libraryId"]
    ] + [portable]})
    atomic_json(metadata_path, metadata)
    for index, (track, link) in enumerate(selected):
        filename = f'{index + 1:04d} - {safe_name(track["title"])}.{fmt}'
        target = folder / filename
        record = metadata["files"].get(filename)
        source_id = hashlib.sha256(track["trackUrl"].encode()).hexdigest()
        if target.is_symlink():
            raise ValueError(f"Refusing a symbolic link: {filename}")
        if target.exists():
            if (not isinstance(record, dict) or record.get("source") != source_id
                    or not target.is_file() or target.stat().st_size != record.get("bytes")
                    or file_hash(target) != record.get("sha256")):
                raise ValueError(f"Refusing to overwrite an unverified existing file: {filename}")
            emit({"type": "progress", "completed": index + 1, "total": len(selected), "percent": 100})
            continue
        descriptor, temporary = tempfile.mkstemp(prefix=".omakhinsider-", suffix=".part", dir=folder)
        received = 0
        digest = hashlib.sha256()
        try:
            with os.fdopen(descriptor, "wb") as output, open_media(link["url"], track["trackUrl"]) as response:
                content_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
                if not (content_type.startswith("audio/") or content_type in {
                    "application/octet-stream", "application/flac", "binary/octet-stream",
                }):
                    raise ValueError("The media server did not return audio. Reinspect the album in your browser.")
                length = response.headers.get("Content-Length")
                expected = int(length) if length is not None else None
                if expected is not None and not 0 < expected <= MAX_AUDIO_BYTES:
                    raise ValueError("Invalid or oversized audio response")
                last_update = 0.0
                while True:
                    chunk = response.read(256 * 1024)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > MAX_AUDIO_BYTES:
                        raise ValueError("Audio file exceeds the 2 GiB limit")
                    output.write(chunk)
                    digest.update(chunk)
                    if time.monotonic() - last_update >= 0.25:
                        emit({"type": "progress", "completed": index, "total": len(selected),
                              "percent": min(100, int(received * 100 / expected)) if expected else -1})
                        last_update = time.monotonic()
                if received == 0 or (expected is not None and received != expected):
                    raise ValueError("Audio transfer was incomplete; retry the download")
                output.flush()
                os.fsync(output.fileno())
            os.link(temporary, target)
            metadata["files"][filename] = {"source": source_id, "bytes": received, "sha256": digest.hexdigest()}
            atomic_json(metadata_path, metadata)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        emit({"type": "progress", "completed": index + 1, "total": len(selected), "percent": 100})
    portable["tracks"] = [
        {"path": name, "title": track["title"], "trackUrl": track["trackUrl"], "format": fmt,
         "bytes": metadata["files"][name]["bytes"], "sha256": metadata["files"][name]["sha256"]}
        for index, (track, _link) in enumerate(selected)
        for name in [f'{index + 1:04d} - {safe_name(track["title"])}.{fmt}']
    ]
    portable["complete"] = True
    atomic_json(metadata_path, metadata)
    return {
        "directory": str(folder),
        "completed": len(selected),
        "files": [
            {"trackUrl": track["trackUrl"], "format": fmt,
             "path": str(folder / f'{index + 1:04d} - {safe_name(track["title"])}.{fmt}')}
            for index, (track, _link) in enumerate(selected)
        ],
    }


def emit(value):
    print(json.dumps(value, ensure_ascii=True), flush=True)


def cancel(_signal, _frame):
    raise Canceled("Download canceled")


def main():
    signal.signal(signal.SIGTERM, cancel)
    try:
        if len(sys.argv) < 2:
            raise ValueError("Missing worker action")
        action = sys.argv[1]
        if action == "read-import" and len(sys.argv) == 3:
            result = {"album": read_import(sys.argv[2])}
        else:
            raw = sys.stdin.buffer.readline(MAX_JSON_BYTES + 1)
            if len(raw) > MAX_JSON_BYTES:
                raise ValueError("Request is too large")
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise ValueError("Invalid worker request")
            if action == "check-directory":
                result = {"directory": str(download_directory(request.get("directory")))}
            elif action == "bar-player-settings":
                result = configure_bar_player(request)
            elif action == "choose-directory":
                result = choose_directory(request)
            elif action == "download":
                result = download_album(request, emit)
            elif action == "scan-library":
                result = scan_library(request)
            elif action == "import-folder":
                result = import_folder(request)
            elif action == "import-folders":
                result = import_folders(request, emit)
            elif action == "relink-folder":
                result = relink_folder(request)
            else:
                raise ValueError("Unknown worker action")
        emit({"type": "result", **result})
        return 0
    except Canceled:
        emit({"type": "canceled"})
        return 2
    except (ValueError, OSError, HTTPException, KeyError, TypeError) as error:
        print(f"OmaKhinsider worker: {error}", file=sys.stderr)
        emit({"type": "error", "message": str(error)[:1000]})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
