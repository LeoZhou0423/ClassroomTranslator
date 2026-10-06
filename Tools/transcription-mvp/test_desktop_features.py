import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import requests
from http.server import ThreadingHTTPServer
from asr_lab import Handler,TOKEN

class DesktopFeaturesTests(unittest.TestCase):
    def test_native_export_writes_selected_file_and_cancel_writes_nothing(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                target=Path(directory)/'lecture.txt'
                choices=[(str(target),),None]
                window=SimpleNamespace(create_file_dialog=lambda *args,**kwargs:choices.pop(0))
                fake=SimpleNamespace(windows=[window],FileDialog=SimpleNamespace(SAVE=30))
                with patch.dict('sys.modules',{'webview':fake}):
                    url=f'http://127.0.0.1:{server.server_port}/api/export-text'
                    headers={'X-Lingo-Token':TOKEN}
                    body={'filename':'lecture.txt','text':'Teacher: Hello.\n你好。'}
                    self.assertTrue(requests.post(url,headers=headers,json=body,timeout=3).json()['saved'])
                    self.assertEqual(target.read_text(encoding='utf-8-sig'),body['text'])
                    self.assertFalse(requests.post(url,headers=headers,json=body,timeout=3).json()['saved'])
                    self.assertEqual(requests.post(url,json=body,timeout=3).status_code,403)
        finally:server.shutdown();server.server_close()

if __name__=='__main__':unittest.main()
