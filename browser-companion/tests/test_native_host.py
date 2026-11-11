import io
import json
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / "native-host"))
import omakhinsider_native_host as host


class NativeHostTests(unittest.TestCase):
    def test_documented_setup_installs_a_host_that_accepts_the_connection_check(self):
        source = pathlib.Path(__file__).parents[1]
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            companion = root / "plugin's folder/browser-companion"
            shutil.copytree(source, companion, ignore=shutil.ignore_patterns(
                "build", "__pycache__", "tests", "assets",
            ))
            tools = root / "bin"
            tools.mkdir()
            ipc = tools / "omarchy-shell"
            ipc.write_text(
                "#!/usr/bin/env python3\nimport sys\n"
                "assert sys.argv[1:] == ['kelmankenberg.omakhinsider', 'checkBrowserConnection']\n"
                "print('connected')\n"
            )
            ipc.chmod(0o755)
            env = dict(host.os.environ, HOME=str(root / "home"),
                       XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
                       XDG_CACHE_HOME=str(root / "cache"),
                       PATH=str(tools) + host.os.pathsep + host.os.environ["PATH"])
            for browser in ("chromium", "firefox"):
                with self.subTest(browser=browser):
                    subprocess.run(
                        [str(companion / "build-extension.sh"), browser],
                        env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    )
                    self.assertIn("test-button", (
                        companion / "build" / browser / "popup.html"
                    ).read_text())
                    args = [str(companion / "install-native-host.sh"), browser]
                    if browser == "chromium":
                        args.append("a" * 32)
                    subprocess.run(args, env=env, check=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    registration = root / (
                        "config/chromium/NativeMessagingHosts/org.omarchy.omakhinsider.json"
                        if browser == "chromium" else
                        "home/.mozilla/native-messaging-hosts/org.omarchy.omakhinsider.json"
                    )
                    manifest = json.loads(registration.read_text())
                    request = io.BytesIO()
                    host.write_message(request, {"type": "ping"})
                    result = subprocess.run(
                        [manifest["path"]], env=env, input=request.getvalue(),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=10,
                    )
                    self.assertEqual(host.read_message(io.BytesIO(result.stdout)), {
                        "ok": True, "status": "connected",
                    })
                    self.assertFalse((root / "cache").exists())

    @patch.object(host, "call_plugin")
    def test_connection_check_does_not_stage_inspect_or_spool_an_album(self, call):
        for status in ("connected", "plugin_unavailable", "state_unavailable", "plugin_error"):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory, \
                    patch.dict(host.os.environ, {"XDG_CACHE_HOME": directory}):
                call.return_value = status
                self.assertEqual(host.handle_message({"type": "ping"}), {
                    "ok": status == "connected", "status": status,
                })
                call.assert_called_with("checkBrowserConnection")
                self.assertEqual(list(pathlib.Path(directory).iterdir()), [])

    @patch.object(host.subprocess, "run")
    def test_connection_check_uses_read_only_shell_ipc_and_reports_transport_failure(self, run):
        run.return_value.returncode = 0
        run.return_value.stdout = "connected\n"
        self.assertEqual(host.handle_message({"type": "ping"}), {
            "ok": True, "status": "connected",
        })
        self.assertEqual(run.call_args.args[0], [
            "omarchy-shell", "kelmankenberg.omakhinsider", "checkBrowserConnection",
        ])
        run.return_value.returncode = 1
        run.return_value.stderr = "No running plugin"
        self.assertEqual(host.handle_message({"type": "ping"}), {
            "ok": False, "status": "plugin_unavailable",
        })

    def test_album_url_validation_and_normalization(self):
        self.assertEqual(
            host.normalize_album_url(
                "https://downloads.khinsider.com/game-soundtracks/album/example/"
            ),
            "https://downloads.khinsider.com/game-soundtracks/album/example",
        )
        for value in (
            "http://downloads.khinsider.com/game-soundtracks/album/example",
            "https://example.com/game-soundtracks/album/example",
            "https://downloads.khinsider.com/game-soundtracks/album/example?x=1",
            "https://user@downloads.khinsider.com/game-soundtracks/album/example",
            "https://downloads.khinsider.com/game-soundtracks/album/../private",
        ):
            with self.subTest(value=value):
                self.assertIsNone(host.normalize_album_url(value))

    @patch.object(host.subprocess, "run")
    def test_valid_album_is_staged_through_shell_ipc(self, run):
        run.return_value.returncode = 0
        run.return_value.stdout = "staged\n"
        result = host.handle_message({
            "type": "stage_album",
            "url": "https://downloads.khinsider.com/game-soundtracks/album/example/",
        })
        self.assertEqual(result, {"ok": True, "status": "staged"})
        self.assertEqual(
            run.call_args.args[0],
            [
                "omarchy-shell",
                "kelmankenberg.omakhinsider",
                "stageAlbumFromBrowser",
                "https://downloads.khinsider.com/game-soundtracks/album/example",
            ],
        )

    @patch.object(host.subprocess, "run")
    def test_invalid_album_is_rejected_without_ipc(self, run):
        result = host.handle_message({
            "type": "stage_album",
            "url": "https://example.com/",
        })
        self.assertEqual(result, {"ok": False, "status": "album_url_invalid"})
        run.assert_not_called()

    def test_native_messaging_frame_round_trips(self):
        message = {"type": "stage_album", "url": "https://example.com"}
        payload = json.dumps(message).encode("utf-8")
        framed = io.BytesIO(struct.pack("<I", len(payload)) + payload)
        self.assertEqual(host.read_message(framed), message)

        output = io.BytesIO()
        host.write_message(output, {"ok": True, "status": "staged"})
        output.seek(0)
        self.assertEqual(host.read_message(output), {"ok": True, "status": "staged"})

    @patch.object(host, "call_plugin")
    def test_browser_inspection_is_spooled_privately_and_removed_on_rejection(self, call):
        source = {
            "url": "https://downloads.khinsider.com/game-soundtracks/album/test",
            "title": "Test",
            "tracks": [],
        }
        with tempfile.TemporaryDirectory() as directory, patch.dict(host.os.environ, {"XDG_CACHE_HOME": directory}):
            call.return_value = "importing"
            response = host.handle_message({"type": "import_album", "album": source})
            self.assertEqual(response, {"ok": True, "status": "importing"})
            method, url, path = call.call_args.args
            self.assertEqual(method, "importAlbumFromBrowser")
            self.assertEqual(url, source["url"])
            path = pathlib.Path(path)
            self.assertEqual(json.loads(path.read_text()), source)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            call.return_value = "busy"
            self.assertFalse(host.handle_message({"type": "import_album", "album": source})["ok"])
            self.assertEqual(len(list(path.parent.glob("*.json"))), 1)

    @patch.object(host, "call_plugin", return_value="inspection_failed")
    def test_inspection_failure_is_reported_without_evaluating_error_text(self, call):
        error = "<img src='https://invalid.test/image'>"
        url = "https://downloads.khinsider.com/game-soundtracks/album/test"
        response = host.handle_message({"type": "inspection_failed", "url": url, "error": error})
        self.assertTrue(response["ok"])
        call.assert_called_once_with("failAlbumInspection", url, error)

    @patch.object(host, "call_plugin", return_value="inspecting")
    def test_connection_accepts_multiple_messages(self, call):
        input_stream = io.BytesIO()
        host.write_message(input_stream, {"type": "invalid"})
        host.write_message(input_stream, {
            "type": "inspection_started",
            "url": "https://downloads.khinsider.com/game-soundtracks/album/test",
        })
        input_stream.seek(0)
        output_stream = io.BytesIO()
        with patch.object(host.sys, "stdin", SimpleNamespace(buffer=input_stream)), \
                patch.object(host.sys, "stdout", SimpleNamespace(buffer=output_stream)):
            self.assertEqual(host.main(), 0)
        output_stream.seek(0)
        self.assertEqual(host.read_message(output_stream)["status"], "invalid_request")
        self.assertEqual(host.read_message(output_stream)["status"], "inspecting")


if __name__ == "__main__":
    unittest.main()
