import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from io import BytesIO
from download_file import download_file


class Response(BytesIO):
    def __init__(self, body, status=200, **headers):
        super().__init__(body)
        self.status = status
        self.headers = headers


class DownloadTests(unittest.TestCase):
    def test_interrupted_transfer_resumes_without_duplicate_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'model'
            responses = [Response(b'abc', **{'Content-Length':'6'}),
                         Response(b'def', 206, **{'Content-Range':'bytes 3-5/6'})]
            with patch('download_file.urlopen', side_effect=responses) as opened:
                download_file('https://example.com/model', target, backoff=0)
            self.assertEqual(target.read_bytes(), b'abcdef')
            self.assertEqual(opened.call_args_list[1].args[0].get_header('Range'), 'bytes=3-')

    def test_server_ignoring_range_restarts_safely(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'model'
            target.with_name('model.part').write_bytes(b'old')
            with patch('download_file.urlopen', return_value=Response(b'newdata', **{'Content-Length':'7'})):
                download_file('https://example.com/model', target)
            self.assertEqual(target.read_bytes(), b'newdata')

    def test_incomplete_download_never_becomes_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'model'
            with patch('download_file.urlopen', return_value=Response(b'abc', **{'Content-Length':'6'})):
                with self.assertRaises(RuntimeError):
                    download_file('https://example.com/model', target, attempts=1)
            self.assertFalse(target.exists())
            self.assertEqual(target.with_name('model.part').read_bytes(), b'abc')
