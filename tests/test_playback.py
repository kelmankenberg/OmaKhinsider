import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import wave


class PlaybackTests(unittest.TestCase):
    def test_real_qt_multimedia_controls_and_playlist_lifecycle(self):
        project = Path(__file__).parents[1]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "tests").mkdir()
            shutil.copyfile(project / "AudioPlayer.qml", folder / "AudioPlayer.qml")
            shutil.copyfile(project / "Model.js", folder / "Model.js")
            shutil.copyfile(project / "tests/tst_player.qml", folder / "tests/tst_player.qml")
            for name, duration in [("tone #%.wav", 2), ("short.wav", 0.18)]:
                with wave.open(str(folder / name), "wb") as audio:
                    audio.setnchannels(1)
                    audio.setsampwidth(2)
                    audio.setframerate(16000)
                    audio.writeframes(b"\0\0" * int(16000 * duration))
            result = subprocess.run(
                ["/usr/lib/qt6/bin/qmltestrunner", "-input", str(folder / "tests/tst_player.qml")],
                env={**os.environ, "QT_QPA_PLATFORM": "offscreen", "QT_FORCE_STDERR_LOGGING": "1"},
                text=True, capture_output=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
