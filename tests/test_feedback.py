import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class FeedbackTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("WAYLAND_DISPLAY"), "Quickshell panels require a Wayland backend")
    def test_issue_chooser_opens_without_sending_library_data_and_reports_browser_failure(self):
        project = Path(__file__).parents[1]
        with tempfile.TemporaryDirectory(prefix="omakhinsider-feedback-") as directory:
            home = Path(directory)
            shutil.copyfile(project / "tests/tst_feedback.qml", home / "shell.qml")
            for name, target in [
                ("Plugin", project),
                ("Commons", Path("/usr/share/omarchy/shell/Commons")),
                ("Ui", Path("/usr/share/omarchy/shell/Ui")),
            ]:
                (home / name).symlink_to(target, target_is_directory=True)
            config = home / ".config"
            config.mkdir()
            state_path = config / "omakhinsider.json"
            state_path.write_text(json.dumps({
                "schemaVersion": 1, "albumQueue": [], "playlists": [],
                "settings": {"downloadDirectory": str(home / "Music"), "format": "mp3"},
            }))
            before = state_path.read_bytes()
            tools = home / "bin"
            tools.mkdir()
            opener = tools / "xdg-open"
            opener.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys, time\n"
                "log = pathlib.Path(os.environ['HOME']) / 'browser-calls.json'\n"
                "calls = json.loads(log.read_text()) if log.exists() else []\n"
                "calls.append(sys.argv[1:])\n"
                "log.write_text(json.dumps(calls))\n"
                "time.sleep(0.2)\n"
                "sys.exit(1 if len(calls) in (2, 4) else 0)\n"
            )
            opener.chmod(0o755)
            result = subprocess.run(
                ["qs", "--no-color", "-p", str(home / "shell.qml")],
                env={**os.environ, "HOME": str(home), "XDG_CONFIG_HOME": str(config),
                     "XDG_CACHE_HOME": str(home / "cache"), "QT_QPA_PLATFORM": "wayland",
                     "QT_FORCE_STDERR_LOGGING": "1",
                     "PATH": str(tools) + os.pathsep + os.environ["PATH"]},
                text=True, capture_output=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("FEEDBACK_UI_PASS", result.stdout + result.stderr)
            calls = json.loads((home / "browser-calls.json").read_text())
            self.assertEqual(calls, [
                ["https://github.com/kelmankenberg/OmaKhinsider/issues/new/choose"],
            ] * 3 + [["https://downloads.khinsider.com/"]])
            self.assertEqual(state_path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
