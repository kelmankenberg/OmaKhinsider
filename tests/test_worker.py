import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / "backend"))
import worker


def album():
    return {
        "url": "https://downloads.khinsider.com/game-soundtracks/album/test",
        "title": "../Album",
        "tracks": [{
            "title": "../../Opening",
            "trackUrl": "https://downloads.khinsider.com/game-soundtracks/album/test/01.mp3",
            "audioLinks": [{"format": "mp3", "url": "https://kappa.vgmsite.com/soundtracks/test/01.mp3"}],
        }],
    }


class AudioResponse(io.BytesIO):
    def __init__(self, value=b"fixture audio", content_type="audio/mpeg", length=None):
        super().__init__(value)
        self.headers = {"Content-Type": content_type, "Content-Length": str(len(value) if length is None else length)}


class WorkerTests(unittest.TestCase):
    def test_bar_player_placement_preserves_clock_primary_icon_and_unrelated_settings(self):
        config = {"version": 1, "plugins": [{"id": "other"}], "bar": {
            "position": "top", "layout": {
                "center": [{"id": "custom.clock", "format": "HH:mm"}],
                "centerBegin": [{"id": "indicators"}],
                "centerEnd": [{"id": "weather", "cities": ["Test"]}],
                "right": [{"id": worker.PLUGIN_ID, "customSetting": 42}],
            },
        }}
        original = json.loads(json.dumps(config))
        first = worker.bar_player_layout(config, True, "right")
        self.assertEqual(config, original)
        self.assertEqual(first["bar"]["layout"]["center"], original["bar"]["layout"]["center"])
        self.assertEqual(first["bar"]["layout"]["right"], original["bar"]["layout"]["right"])
        self.assertEqual(first["plugins"], original["plugins"])
        self.assertEqual(first["bar"]["layout"]["centerEnd"][1:], original["bar"]["layout"]["centerEnd"])
        first["bar"]["layout"]["centerEnd"][0]["customWidth"] = 140
        moved = worker.bar_player_layout(first, False, "left")
        self.assertEqual(moved["bar"]["layout"]["centerEnd"], original["bar"]["layout"]["centerEnd"])
        self.assertEqual(moved["bar"]["layout"]["centerBegin"][-1], {
            "id": worker.PLUGIN_ID, "view": "player", "playerEnabled": False, "customWidth": 140,
        })
        self.assertEqual(worker.bar_player_layout(moved, False, "left"), moved)
        for enabled, side in ((1, "left"), (True, "center")):
            with self.assertRaises(ValueError):
                worker.bar_player_layout(config, enabled, side)
        with self.assertRaises(ValueError):
            worker.bar_player_layout({"bar": {"layout": {"centerEnd": [{"id": worker.PLUGIN_ID, "view": "player"}]}}}, True, "right")

    @patch.object(worker.subprocess, "run")
    def test_bar_player_settings_persist_without_touching_music_and_report_reload_failure(self, run):
        with tempfile.TemporaryDirectory() as directory, patch.dict(worker.os.environ, {"HOME": directory}):
            path = Path(directory) / ".config/omarchy/shell.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"bar": {"layout": {"right": [{"id": worker.PLUGIN_ID}]}}}))
            run.return_value.returncode = 0
            run.return_value.stdout = "ok\n"
            run.return_value.stderr = ""
            run.side_effect = lambda args, **kwargs: (
                SimpleNamespace(returncode=0, stdout=path.read_text(), stderr="")
                if args[-1] == "listShellConfig" else run.return_value
            )
            self.assertEqual(worker.configure_bar_player({"enabled": True, "side": "left"}),
                             {"enabled": True, "side": "left"})
            run.assert_called_with(["omarchy-shell", "shell", "reloadConfig"],
                                   text=True, capture_output=True, timeout=5, check=False)
            saved = path.read_bytes()
            worker.configure_bar_player({"enabled": True, "side": "left"})
            self.assertEqual(path.read_bytes(), saved)
            run.return_value.returncode = 1
            run.return_value.stderr = "Shell unavailable"
            with self.assertRaisesRegex(ValueError, "settings were saved.*could not reload"):
                worker.configure_bar_player({"enabled": False, "side": "right"})
            self.assertFalse(json.loads(path.read_text())["bar"]["layout"]["centerEnd"][0]["playerEnabled"])
            self.assertFalse((Path(directory) / "Music").exists())
            before = path.read_bytes()
            run.side_effect = lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout="{}", stderr="")
            with self.assertRaisesRegex(ValueError, "pending configuration changes"):
                worker.configure_bar_player({"enabled": True, "side": "left"})
            self.assertEqual(path.read_bytes(), before)

    @patch.object(worker, "probe_tags", return_value={})
    def test_multi_disc_manifest_orders_numeric_disc_folders_and_survives_relocation(self, _probe):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            group = root / "Album"
            child_records = {}
            for number in [1, 10, 2]:
                child = group / f"CD{number}"
                child.mkdir(parents=True)
                (child / "01 - Opening.mp3").write_bytes(str(number).encode())
                entries, _ = worker.scan_folder(child, [])
                worker.import_folder({"directory": directory, "folder": str(child), "libraryId": entries[0]["libraryId"]})
                child_records[child.name] = (child / ".omakhinsider.json").read_bytes()
            scan = worker.scan_library({"directory": directory})
            self.assertEqual(scan["warnings"], [])
            self.assertEqual(scan["albums"], [])
            self.assertEqual(len(scan["previews"]), 1)
            preview = scan["previews"][0]
            self.assertEqual([track["path"] for track in preview["tracks"]],
                             [f"CD{i}/01 - Opening.mp3" for i in [1, 2, 10]])
            self.assertFalse((group / ".omakhinsider.json").exists())
            worker.import_folder({"directory": directory, "folder": str(group), "libraryId": preview["libraryId"]})
            self.assertEqual(json.loads((group / ".omakhinsider.json").read_text())["schemaVersion"], 2)
            for child, original in child_records.items():
                self.assertEqual((group / child / ".omakhinsider.json").read_bytes(), original)
            moved = root / "Moved"
            group.rename(moved)
            scan = worker.scan_library({"directory": directory})
            self.assertEqual(scan["warnings"], [])
            self.assertEqual(scan["previews"], [])
            self.assertEqual(len(scan["albums"]), 1)
            self.assertEqual(scan["albums"][0]["libraryId"], preview["libraryId"])
            self.assertEqual(scan["albums"][0]["directory"], str(moved))
            self.assertEqual(len(scan["albums"][0]["discs"]), 3)
            target = moved / "CD1"
            outside = root / "outside"
            target.rename(outside)
            target.symlink_to(outside)
            corrupted = worker.scan_library({"directory": directory})
            self.assertTrue(corrupted["warnings"])
            self.assertFalse(any(album["libraryId"] == preview["libraryId"] for album in corrupted["albums"]))

    @patch.object(worker, "probe_tags", return_value={})
    def test_disc_format_mismatch_is_reported_without_hiding_individual_albums(self, _probe):
        with tempfile.TemporaryDirectory() as directory:
            for number, fmt in [(1, "mp3"), (2, "flac")]:
                child = Path(directory) / "Album" / f"Disc {number}"
                child.mkdir(parents=True)
                (child / f"01 Opening.{fmt}").write_bytes(str(number).encode())
            result = worker.scan_library({"directory": directory})
            self.assertTrue(any("different audio formats" in warning for warning in result["warnings"]))
            self.assertEqual(len(result["previews"]), 2)

    def test_scan_detects_missing_saved_folders_without_removing_playlist_records(self):
        with tempfile.TemporaryDirectory() as directory:
            existing = Path(directory) / "Exists"
            existing.mkdir()
            hints = [
                {"id": "exists", "downloadDirectory": str(existing)},
                {"id": "missing", "downloadDirectory": str(Path(directory) / "Missing")},
                {"id": "online", "kind": "online"},
            ]
            result = worker.scan_library({"directory": directory, "playlists": hints})
            self.assertEqual(result["locations"], [
                {"id": "exists", "directory": str(existing), "missing": False},
                {"id": "missing", "directory": str(Path(directory) / "Missing"), "missing": True},
            ])
            self.assertEqual(len(hints), 3)

    @patch.object(worker, "probe_tags")
    def test_relink_enriches_manifest_with_original_source_order_and_keeps_audio_untouched(self, probe):
        probe.side_effect = lambda path: {"title": "Opening" if path.name.startswith("01") else "Ending",
                                         "track": "2" if path.name.startswith("01") else "1"}
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "Replacement"
            folder.mkdir()
            (folder / "01 Opening.mp3").write_bytes(b"opening")
            (folder / "02 Ending.mp3").write_bytes(b"ending")
            preview = worker.scan_library({"directory": directory})["previews"][0]
            worker.import_folder({"directory": directory, "folder": str(folder), "libraryId": preview["libraryId"]})
            source = album()["url"]
            previous = {"id": "original", "downloadFormat": "mp3", "sourceAlbumUrl": source, "tracks": [
                {"id": "one", "title": "Opening (feat. Guest)", "trackUrl": source + "/01.mp3", "albumUrl": source},
                {"id": "two", "title": "Ending", "trackUrl": source + "/02.mp3", "albumUrl": source},
            ]}
            linked = worker.relink_folder({"folder": str(folder), "playlistId": "original", "format": "mp3",
                                          "albumUrl": source, "playlists": [previous]})["albums"][0]
            self.assertEqual(linked["previousLibraryId"], preview["libraryId"])
            self.assertEqual(linked["libraryId"], worker.album_identity(source, "mp3"))
            self.assertEqual([track["path"] for track in linked["tracks"]], ["01 Opening.mp3", "02 Ending.mp3"])
            self.assertEqual(linked["tracks"][0]["trackUrl"], source + "/01.mp3")
            self.assertEqual((folder / "01 Opening.mp3").read_bytes(), b"opening")
            refreshed = worker.scan_library({"directory": directory})["albums"][0]
            self.assertEqual(refreshed["albumUrl"], source)
            self.assertEqual([track["trackUrl"] for track in refreshed["tracks"]],
                             [source + "/01.mp3", source + "/02.mp3"])
            original = (folder / ".omakhinsider.json").read_bytes()
            previous["sourceAlbumUrl"] = source + "-other"
            with self.assertRaisesRegex(ValueError, "different KHInsider"):
                worker.relink_folder({"folder": str(folder), "playlistId": "original", "format": "mp3",
                                      "playlists": [previous]})
            self.assertEqual((folder / ".omakhinsider.json").read_bytes(), original)

    @patch.object(worker, "probe_tags", return_value={})
    def test_import_all_keeps_successes_and_reports_each_failure_without_stopping(self, _probe):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["A", "B", "C"]:
                folder = root / name
                folder.mkdir()
                (folder / "01 - Opening.mp3").write_bytes(name.encode())
            previews = worker.scan_library({"directory": directory})["previews"]
            (root / "B/01 - Opening.mp3").write_bytes(b"changed after preview")
            request = {"directory": directory, "folders": [
                {"folder": entry["directory"], "libraryId": entry["libraryId"]} for entry in previews
            ]}
            events = []
            result = worker.import_folders(request, events.append)
            self.assertEqual([Path(album["directory"]).name for album in result["albums"]], ["A", "C"])
            self.assertEqual(len(result["errors"]), 1)
            self.assertEqual(result["errors"][0]["directory"], str(root / "B"))
            self.assertIn("changed", result["errors"][0]["message"])
            self.assertFalse((root / "B/.omakhinsider.json").exists())
            self.assertEqual((root / "A/01 - Opening.mp3").read_bytes(), b"A")
            self.assertEqual(events[-1]["completed"], 3)
            self.assertEqual(events[-1]["total"], 3)
            self.assertTrue((root / "C/.omakhinsider.json").exists())
            repeated = worker.import_folders(request, lambda _: None)
            self.assertEqual([album["libraryId"] for album in repeated["albums"]],
                             [album["libraryId"] for album in result["albums"]])
            self.assertEqual(len(repeated["errors"]), 1)

    @patch.object(worker, "probe_tags", return_value={})
    def test_import_all_validates_requests_before_writing_and_reports_all_failures(self, _probe):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "Album"
            folder.mkdir()
            (folder / "01.mp3").write_bytes(b"audio")
            preview = worker.scan_library({"directory": directory})["previews"][0]
            item = {"folder": str(folder), "libraryId": preview["libraryId"]}
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                worker.import_folders({"directory": directory, "folders": [item, item]}, lambda _: None)
            self.assertFalse((folder / ".omakhinsider.json").exists())
            result = worker.import_folders({"directory": directory, "folders": [
                {"folder": str(root / "missing"), "libraryId": preview["libraryId"]},
                {"folder": str(root / "../outside"), "libraryId": preview["libraryId"]},
            ]}, lambda _: None)
            self.assertEqual(result["albums"], [])
            self.assertEqual(len(result["errors"]), 2)

    @patch.object(worker.subprocess, "run")
    def test_folder_chooser_returns_selected_path_without_creating_or_saving_folders(self, run):
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory) / " Music #100% "
            selected.mkdir()
            run.return_value = subprocess.CompletedProcess([], 0, stdout=str(selected) + "\n", stderr="")
            result = worker.choose_directory({
                "directory": str(Path(directory) / "not-created/album"),
                "title": "Choose download folder",
            })
            self.assertEqual(result["directory"], str(selected))
            self.assertFalse((Path(directory) / "not-created").exists())
            command = run.call_args.args[0]
            self.assertIn("--directory", command)
            self.assertIn("--filename=" + directory + "/", command)
            self.assertEqual(list(selected.iterdir()), [])

    @patch.object(worker.subprocess, "run")
    def test_folder_chooser_cancel_errors_and_invalid_results_are_explicit(self, run):
        with tempfile.TemporaryDirectory() as directory:
            request = {"directory": directory, "title": "Choose folder"}
            run.return_value = subprocess.CompletedProcess([], 1, stdout="", stderr="")
            with self.assertRaises(worker.Canceled):
                worker.choose_directory(request)
            run.return_value = subprocess.CompletedProcess([], 255, stdout="", stderr="No display")
            with self.assertRaisesRegex(ValueError, "No display"):
                worker.choose_directory(request)
            for value in ["relative", directory + "\nsecond\n", "file:///tmp", ""]:
                run.return_value = subprocess.CompletedProcess([], 0, stdout=value, stderr="")
                with self.subTest(value=value), self.assertRaises(ValueError):
                    worker.choose_directory(request)

    def test_manifest_rejects_untrusted_links_and_cross_album_tracks(self):
        self.assertEqual(worker.validate_manifest(album())["title"], "../Album")
        for url in [
            "https://vgmsite.com.evil.test/01.mp3",
            "https://127.0.0.1/01.mp3",
            "http://kappa.vgmsite.com/01.mp3",
            "https://user@kappa.vgmsite.com/01.mp3",
            "https://kappa.vgmsite.com:8443/01.mp3",
        ]:
            data = album()
            data["tracks"][0]["audioLinks"][0]["url"] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                worker.validate_manifest(data)
        data = album()
        data["tracks"][0]["trackUrl"] = data["url"] + "/../other.mp3"
        with self.assertRaises(ValueError):
            worker.validate_manifest(data)

    @patch.object(worker, "open_media")
    def test_atomic_download_sanitizes_names_and_retry_skips_verified_files(self, open_media):
        open_media.side_effect = lambda *_: AudioResponse()
        with tempfile.TemporaryDirectory() as directory:
            request = {"album": album(), "directory": directory, "format": "mp3"}
            events = []
            result = worker.download_album(request, events.append)
            folder = Path(result["directory"])
            self.assertEqual(folder.parent, Path(directory))
            files = list(folder.glob("*.mp3"))
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].read_bytes(), b"fixture audio")
            self.assertEqual(result["files"], [{
                "trackUrl": request["album"]["tracks"][0]["trackUrl"],
                "format": "mp3",
                "path": str(files[0]),
            }])
            self.assertFalse(list(folder.glob("*.part")))
            worker.download_album(request, events.append)
            self.assertEqual(open_media.call_count, 1)
            manifest = json.loads((folder / ".omakhinsider.json").read_text())
            portable = manifest["albums"][0]
            self.assertTrue(portable["complete"])
            self.assertEqual(portable["title"], album()["title"])
            self.assertEqual(portable["tracks"][0]["path"], files[0].name)
            self.assertEqual(portable["tracks"][0]["trackUrl"], album()["tracks"][0]["trackUrl"])
            request["album"]["tracks"][0]["audioLinks"][0]["url"] += "?refreshed=token"
            worker.download_album(request, events.append)
            self.assertEqual(open_media.call_count, 1)
            files[0].write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError, "overwrite"):
                worker.download_album(request, events.append)

    @patch.object(worker, "open_media")
    def test_html_truncation_and_cancellation_never_create_final_audio(self, open_media):
        for response in [
            AudioResponse(b"<html>blocked</html>", "text/html"),
            AudioResponse(length=1000),
            worker.Canceled("stop"),
        ]:
            with self.subTest(response=response), tempfile.TemporaryDirectory() as directory:
                open_media.side_effect = response if isinstance(response, Exception) else lambda *_: response
                with self.assertRaises((ValueError, worker.Canceled)):
                    worker.download_album({"album": album(), "directory": directory}, lambda _: None)
                self.assertFalse(list(Path(directory).rglob("*.mp3")))
                self.assertFalse(list(Path(directory).rglob("*.part")))

    @patch.object(worker, "open_media")
    def test_missing_format_does_not_start_download(self, open_media):
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(ValueError, "FLAC"):
            worker.download_album({"album": album(), "directory": directory, "format": "flac"}, lambda _: None)
        open_media.assert_not_called()

    @patch.object(worker, "open_media")
    def test_cancel_keeps_completed_tracks_for_retry(self, open_media):
        source = album()
        source["tracks"].append({
            "title": "Ending",
            "trackUrl": source["url"] + "/02.mp3",
            "audioLinks": [{"format": "mp3", "url": "https://kappa.vgmsite.com/test/02.mp3"}],
        })
        open_media.side_effect = [AudioResponse(), worker.Canceled("stop")]
        with tempfile.TemporaryDirectory() as directory:
            request = {"album": source, "directory": directory}
            with self.assertRaises(worker.Canceled):
                worker.download_album(request, lambda _: None)
            self.assertEqual(len(list(Path(directory).rglob("*.mp3"))), 1)
            scan = worker.scan_library({"directory": directory})
            self.assertEqual(scan["albums"], [])
            self.assertEqual(scan["previews"], [])
            self.assertIn("Incomplete", scan["warnings"][0])
            open_media.reset_mock()
            open_media.side_effect = lambda *_: AudioResponse()
            worker.download_album(request, lambda _: None)
            self.assertEqual(open_media.call_count, 1)
            self.assertEqual(len(list(Path(directory).rglob("*.mp3"))), 2)

    def test_redirect_to_untrusted_host_is_rejected(self):
        with self.assertRaises(ValueError):
            worker.MediaRedirect().redirect_request(
                None, None, 302, "", {}, "https://evil.test/audio.mp3",
            )

    def test_browser_import_is_bounded_and_consumed_only_from_its_cache_directory(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(worker, "import_directory", return_value=Path(directory)):
            path = Path(directory) / ("a" * 32 + ".json")
            path.write_text(json.dumps(album()))
            self.assertEqual(worker.read_import(str(path)), worker.validate_manifest(album()))
            self.assertFalse(path.exists())
            with self.assertRaises(ValueError):
                worker.read_import("/tmp/not-an-import.json")
            path.symlink_to("/dev/null")
            with self.assertRaises(OSError):
                worker.read_import(str(path))

    @patch.object(worker, "open_media", side_effect=lambda *_: AudioResponse())
    def test_complete_album_remains_portable_after_move_and_checksum_is_checked(self, _open_media):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = worker.download_album({"album": album(), "directory": directory}, lambda _: None)
            moved = root / "Relocated"
            Path(result["directory"]).rename(moved)
            scan = worker.scan_library({"directory": directory})
            self.assertEqual(scan["warnings"], [])
            self.assertEqual(scan["previews"], [])
            self.assertEqual(scan["albums"][0]["directory"], str(moved))
            self.assertEqual(scan["albums"][0]["tracks"][0]["title"], "../../Opening")
            audio = next(moved.glob("*.mp3"))
            audio.write_bytes(b"fixture AUDIO")
            scan = worker.scan_library({"directory": directory})
            self.assertEqual(scan["albums"], [])
            self.assertIn("verification failed", scan["warnings"][0])

    @patch.object(worker, "probe_tags")
    def test_external_album_preview_import_and_relocation_never_change_audio(self, probe):
        probe.side_effect = lambda path: {"title": path.stem + " tag", "album": "Tagged album",
                                         "track": "2" if path.name.startswith("1 ") else "1"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "External"
            folder.mkdir()
            (folder / "1 Start.mp3").write_bytes(b"first")
            (folder / "10 End.flac").write_bytes(b"second")
            scan = worker.scan_library({"directory": directory})
            self.assertEqual(scan["albums"], [])
            self.assertEqual(scan["warnings"], [])
            preview = scan["previews"][0]
            self.assertEqual(preview["title"], "Tagged album")
            self.assertEqual([t["title"] for t in preview["tracks"]], ["10 End tag", "1 Start tag"])
            self.assertFalse((folder / ".omakhinsider.json").exists())
            result = worker.import_folder({"directory": directory, "folder": str(folder),
                                           "libraryId": preview["libraryId"]})
            self.assertEqual(result["albums"][0]["libraryId"], preview["libraryId"])
            self.assertEqual((folder / "1 Start.mp3").read_bytes(), b"first")
            moved = root / "Moved"
            folder.rename(moved)
            probe.reset_mock()
            scan = worker.scan_library({"directory": directory})
            probe.assert_not_called()
            self.assertEqual(scan["previews"], [])
            self.assertEqual(scan["albums"][0]["libraryId"], preview["libraryId"])
            self.assertEqual(scan["albums"][0]["directory"], str(moved))

    @patch.object(worker, "probe_tags", return_value={})
    def test_filename_fallback_natural_order_and_changed_preview_rejected(self, _probe):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "Album"
            folder.mkdir()
            (folder / "10 - End.mp3").write_bytes(b"end")
            (folder / "2 - Start.mp3").write_bytes(b"start")
            preview = worker.scan_library({"directory": directory})["previews"][0]
            self.assertEqual([t["title"] for t in preview["tracks"]], ["Start", "End"])
            (folder / "2 - Start.mp3").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "changed"):
                worker.import_folder({"directory": directory, "folder": str(folder),
                                      "libraryId": preview["libraryId"]})
            self.assertFalse((folder / ".omakhinsider.json").exists())

    @patch.object(worker, "open_media", side_effect=lambda *_: AudioResponse())
    @patch.object(worker, "probe_tags")
    def test_legacy_record_can_use_saved_playlist_without_metadata_probe_or_redownload(self, probe, _open_media):
        with tempfile.TemporaryDirectory() as directory:
            result = worker.download_album({"album": album(), "directory": directory}, lambda _: None)
            folder = Path(result["directory"])
            manifest_path = folder / ".omakhinsider.json"
            record = json.loads(manifest_path.read_text())
            manifest_path.write_text(json.dumps({"albumUrl": record["albumUrl"], "files": record["files"]}))
            hints = [{"sourceAlbumUrl": album()["url"], "tracks": [{
                "localPath": result["files"][0]["path"], "trackUrl": album()["tracks"][0]["trackUrl"],
                "title": "Original title", "albumTitle": "Original album",
            }]}]
            scan = worker.scan_library({"directory": directory, "playlists": hints})
            self.assertEqual(scan["warnings"], [])
            preview = scan["previews"][0]
            self.assertEqual(preview["tracks"][0]["title"], "Original title")
            self.assertEqual(preview["albumUrl"], album()["url"])
            worker.import_folder({"directory": directory, "folder": str(folder),
                                  "libraryId": preview["libraryId"], "playlists": hints})
            probe.assert_not_called()
            self.assertEqual(worker.scan_library({"directory": directory})["previews"], [])

    @patch.object(worker, "open_media", side_effect=lambda *_: AudioResponse())
    def test_manifest_paths_symlinks_and_unknown_versions_are_not_imported(self, _open_media):
        with tempfile.TemporaryDirectory() as directory:
            result = worker.download_album({"album": album(), "directory": directory}, lambda _: None)
            folder = Path(result["directory"])
            path = folder / ".omakhinsider.json"
            original = json.loads(path.read_text())
            for name in ["../outside.mp3", "/tmp/outside.mp3", "nested/track.mp3"]:
                record = json.loads(json.dumps(original))
                record["albums"][0]["tracks"][0]["path"] = name
                path.write_text(json.dumps(record))
                scan = worker.scan_library({"directory": directory})
                self.assertEqual(scan["albums"], [])
                self.assertTrue(scan["warnings"])
            path.write_text(json.dumps(original))
            audio = Path(result["files"][0]["path"])
            outside = Path(directory) / "outside"
            outside.write_bytes(audio.read_bytes())
            audio.unlink()
            audio.symlink_to(outside)
            self.assertTrue(worker.scan_library({"directory": directory})["warnings"])
            audio.unlink()
            shutil.copyfile(outside, audio)
            original["schemaVersion"] = 99
            path.write_text(json.dumps(original))
            self.assertIn("Unsupported", worker.scan_library({"directory": directory})["warnings"][0])
            path.unlink()
            path.symlink_to(outside)
            self.assertTrue(worker.scan_library({"directory": directory})["warnings"])

    def test_scanner_reports_bad_audio_and_never_follows_folder_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "Bad"
            folder.mkdir()
            (folder / "bad.mp3").write_bytes(b"not audio")
            (Path(directory) / "linked").symlink_to(folder)
            scan = worker.scan_library({"directory": directory})
            self.assertEqual(scan["previews"], [])
            self.assertTrue(any("symbolic-link" in warning for warning in scan["warnings"]))
            self.assertTrue(any("Cannot inspect" in warning for warning in scan["warnings"]))

    @patch.object(worker, "open_media", side_effect=lambda *_: AudioResponse())
    def test_completed_format_is_still_discovered_when_other_format_is_incomplete(self, open_media):
        source = album()
        source["tracks"][0]["audioLinks"].append({
            "format": "flac", "url": "https://kappa.vgmsite.com/test/01.flac",
        })
        with tempfile.TemporaryDirectory() as directory:
            worker.download_album({"album": source, "directory": directory}, lambda _: None)
            open_media.side_effect = worker.Canceled("stop")
            with self.assertRaises(worker.Canceled):
                worker.download_album({"album": source, "directory": directory, "format": "flac"}, lambda _: None)
            scan = worker.scan_library({"directory": directory})
            self.assertEqual(len(scan["albums"]), 1)
            self.assertEqual(scan["albums"][0]["tracks"][0]["format"], "mp3")
            self.assertTrue(any("Incomplete" in warning for warning in scan["warnings"]))
            open_media.side_effect = lambda *_: AudioResponse()
            worker.download_album({"album": source, "directory": directory, "format": "flac"}, lambda _: None)
            self.assertEqual(len(worker.scan_library({"directory": directory})["albums"]), 2)


if __name__ == "__main__":
    unittest.main()
