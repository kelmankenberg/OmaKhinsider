#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import secrets
import struct
import subprocess
import sys
from urllib.parse import urlsplit


HOST_NAME = "downloads.khinsider.com"
PLUGIN_ID = "kelmankenberg.omakhinsider"
MAX_MESSAGE_SIZE = 2 * 1024 * 1024
ALBUM_PATH = re.compile(
    r"^/game-soundtracks/album/[A-Za-z0-9._~%!-]+(?:/[A-Za-z0-9._~%!-]+)*/?$"
)
RESULTS = {
    "connected",
    "staged",
    "album_url_invalid",
    "state_unavailable",
    "plugin_unavailable",
    "inspecting",
    "importing",
    "inspection_failed",
    "busy",
    "album_queue_full",
}


def read_exact(stream, size, allow_eof=False):
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            if allow_eof and not data:
                return None
            raise ValueError("Unexpected end of native messaging input")
        data.extend(chunk)
    return bytes(data)


def read_message(stream):
    header = read_exact(stream, 4, allow_eof=True)
    if header is None:
        return None
    (size,) = struct.unpack("<I", header)
    if size > MAX_MESSAGE_SIZE:
        raise ValueError("Native messaging request is too large")
    payload = read_exact(stream, size)
    return json.loads(payload.decode("utf-8"))


def write_message(stream, message):
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
    stream.write(struct.pack("<I", len(payload)))
    stream.write(payload)
    stream.flush()


def normalize_album_url(value):
    if not isinstance(value, str) or len(value) > 2048:
        return None
    try:
        parts = urlsplit(value)
    except ValueError:
        return None
    if (parts.scheme.lower() != "https" or parts.netloc.lower() != HOST_NAME or
            parts.query or parts.fragment or not ALBUM_PATH.fullmatch(parts.path)):
        return None
    if any(segment in {".", ".."} for segment in parts.path.split("/")):
        return None
    return "https://" + HOST_NAME + parts.path.rstrip("/")


def call_plugin(method, *args):
    try:
        result = subprocess.run(
            ["omarchy-shell", PLUGIN_ID, method, *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as error:
        print(f"OmaKhinsider IPC failed: {error}", file=sys.stderr)
        return "plugin_unavailable"
    if result.returncode != 0:
        print(f"OmaKhinsider IPC failed: {result.stderr.strip()}", file=sys.stderr)
        return "plugin_unavailable"
    status = result.stdout.strip()
    return status if status in RESULTS else "plugin_error"


def handle_message(message):
    if not isinstance(message, dict) or message.get("type") not in {
        "ping", "stage_album", "inspection_started", "inspection_failed", "import_album",
    }:
        return {"ok": False, "status": "invalid_request"}
    kind = message["type"]
    if kind == "ping":
        status = call_plugin("checkBrowserConnection")
        return {"ok": status == "connected", "status": status}
    source = message.get("album") if kind == "import_album" else message
    url = normalize_album_url(source.get("url") if isinstance(source, dict) else None)
    if not url:
        return {"ok": False, "status": "album_url_invalid"}
    if kind == "stage_album":
        status = call_plugin("stageAlbumFromBrowser", url)
    elif kind == "inspection_started":
        status = call_plugin("beginAlbumInspection", url)
    elif kind == "inspection_failed":
        error = message.get("error")
        if not isinstance(error, str) or not error or len(error) > 1000:
            return {"ok": False, "status": "invalid_request"}
        status = call_plugin("failAlbumInspection", url, error)
    else:
        payload = json.dumps(source, ensure_ascii=True).encode()
        if len(payload) > MAX_MESSAGE_SIZE:
            return {"ok": False, "status": "invalid_request"}
        directory = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "omakhinsider/imports"
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = directory / (secrets.token_hex(16) + ".json")
        try:
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as output:
                output.write(payload)
            status = call_plugin("importAlbumFromBrowser", url, str(path))
        except OSError as error:
            print(f"OmaKhinsider import failed: {error}", file=sys.stderr)
            status = "plugin_error"
        if status != "importing":
            path.unlink(missing_ok=True)
    return {"ok": status in {"staged", "inspecting", "importing", "inspection_failed"}, "status": status}


def main():
    while True:
        try:
            message = read_message(sys.stdin.buffer)
            if message is None:
                return 0
            write_message(sys.stdout.buffer, handle_message(message))
        except (ValueError, UnicodeDecodeError, OSError) as error:
            print(f"OmaKhinsider native message failed: {error}", file=sys.stderr)
            write_message(sys.stdout.buffer, {"ok": False, "status": "invalid_request"})
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
