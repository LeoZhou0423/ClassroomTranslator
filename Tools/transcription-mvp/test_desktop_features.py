import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import requests
from asr_lab import TOKEN, Handler


class DesktopFeaturesTests(unittest.TestCase):
    def test_native_export_writes_selected_file_and_cancel_writes_nothing(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / "lecture.txt"
                choices = [(str(target),), None, ("",), []]
                window = SimpleNamespace(create_file_dialog=lambda *args, **kwargs: choices.pop(0))
                fake = SimpleNamespace(windows=[window], FileDialog=SimpleNamespace(SAVE=30))
                with patch.dict("sys.modules", {"webview": fake}):
                    url = f"http://127.0.0.1:{server.server_port}/api/export-text"
                    headers = {"X-Lingo-Token": TOKEN}
                    body = {"filename": "lecture.txt", "text": "Teacher: Hello.\n你好。"}
                    ok = requests.post(url, headers=headers, json=body, timeout=3).json()
                    self.assertTrue(ok["saved"])
                    self.assertEqual(target.read_text(encoding="utf-8-sig"), body["text"])
                    self.assertTrue(ok.get("path", "").endswith("lecture.txt"))
                    cancelled = requests.post(url, headers=headers, json=body, timeout=3).json()
                    self.assertFalse(cancelled["saved"])
                    self.assertNotIn("error", cancelled)
                    empty = requests.post(url, headers=headers, json=body, timeout=3).json()
                    self.assertFalse(empty["saved"])
                    self.assertIn("error", empty)
                    self.assertEqual(requests.post(url, json=body, timeout=3).status_code, 403)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
