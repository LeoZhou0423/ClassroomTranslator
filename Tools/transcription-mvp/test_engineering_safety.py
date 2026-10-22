"""Fault injection for persistence and the public error contract."""

import errno
import http.client
import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import asr_lab
import classroom_revision
import classroom_summary
from app_errors import AppError, error_response
from desktop_store import DesktopStore
from json_storage import atomic_write_json, read_json


class EngineeringSafetyTests(unittest.TestCase):
    def test_failed_summary_start_releases_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            state = {"rows": [{"id": "a", "text": "A meaningful classroom statement."}]}
            with patch("classroom_summary.atomic_write_json", side_effect=PermissionError()):
                with self.assertRaises(PermissionError):
                    classroom_summary.start_summary(path, state, "key", "url", False)
            self.assertNotIn(str(path.resolve()), classroom_summary.ACTIVE)

    def test_failed_revision_start_releases_both_registries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with (
                patch("classroom_revision.revision_credentials", return_value=("key", "url")),
                patch("classroom_revision.atomic_write_json", side_effect=PermissionError()),
            ):
                with self.assertRaises(PermissionError):
                    classroom_revision.start_revision(path)
            self.assertNotIn(str(path.resolve()), classroom_revision.ACTIVE)
            self.assertNotIn(str(path.resolve()), classroom_revision.CANCEL_EVENTS)

    def test_cancel_marks_event_and_retains_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            identity = str(path.resolve())
            event = threading.Event()
            atomic_write_json(
                path / classroom_revision.STATE_NAME, {"status": "revising", "processed_rows": 3}
            )
            classroom_revision.ACTIVE[identity] = threading.current_thread()
            classroom_revision.CANCEL_EVENTS[identity] = event
            try:
                self.assertTrue(classroom_revision.cancel_revision(path))
                self.assertTrue(event.is_set())
                self.assertEqual(
                    read_json(path / classroom_revision.STATE_NAME)["processed_rows"], 3
                )
            finally:
                classroom_revision.ACTIVE.pop(identity, None)
                classroom_revision.CANCEL_EVENTS.pop(identity, None)

    def test_failed_replace_keeps_previous_content_and_removes_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "record.json"
            atomic_write_json(path, {"rows": ["original"]})
            with patch.object(Path, "replace", side_effect=OSError(errno.ENOSPC, "full")):
                with self.assertRaises(OSError):
                    atomic_write_json(path, {"rows": ["replacement"]})
            self.assertEqual(read_json(path), {"rows": ["original"]})
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_unserializable_value_does_not_touch_original(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "record.json"
            atomic_write_json(path, {"safe": True})
            with self.assertRaises(TypeError):
                atomic_write_json(path, {"bad": object()})
            self.assertEqual(read_json(path), {"safe": True})

    def test_corrupt_library_is_preserved_instead_of_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            store = DesktopStore(directory)
            store.path.write_text("{broken", encoding="utf-8")
            with self.assertRaises(AppError) as raised:
                store.update_settings({"font_size": 18})
            self.assertEqual(raised.exception.code, "DATA_CORRUPT")
            self.assertEqual(store.path.read_text(encoding="utf-8"), "{broken")

    def test_library_keeps_previous_valid_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            store = DesktopStore(directory)
            store.update_settings({"font_size": 18})
            store.update_settings({"font_size": 20})
            self.assertEqual(
                read_json(store.path.with_suffix(".json.bak"))["settings"]["font_size"], 18
            )
            self.assertEqual(store.settings()["font_size"], 20)

    def test_internal_exception_does_not_expose_secret(self):
        status, body = error_response(
            RuntimeError("secret-token-and-private-transcript"), "test-id"
        )
        self.assertEqual(status, 500)
        self.assertEqual(body["code"], "INTERNAL")
        self.assertEqual(body["request_id"], "test-id")
        self.assertNotIn("secret-token", str(body))

    def test_storage_full_and_timeout_are_distinct(self):
        self.assertEqual(error_response(OSError(errno.ENOSPC, "full"))[0], 507)
        status, body = error_response(TimeoutError())
        self.assertEqual(status, 504)
        self.assertTrue(body["retryable"])


class HttpBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), asr_lab.DesktopRequestHandler)
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=2)

    def request(self, method, path, body=None, token=True):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        try:
            headers = {"X-Lingo-Token": asr_lab.TOKEN} if token else {}
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            payload = json.loads(response.read())
            self.assertEqual(response.getheader("X-Request-ID"), payload["request_id"])
            return response.status, payload
        finally:
            connection.close()

    def test_invalid_json_and_array_are_rejected(self):
        for body in ("{broken", "[]"):
            status, payload = self.request("POST", "/api/courses", body)
            self.assertEqual(status, 400)
            self.assertEqual(payload["code"], "INVALID_ARGUMENT")

    def test_expired_session_and_unknown_route(self):
        self.assertEqual(self.request("POST", "/api/start", "{}", token=False)[0], 403)
        self.assertEqual(self.request("GET", "/api/unknown-resource")[0], 404)

    def test_internal_fault_is_500_without_private_details(self):
        with patch.object(asr_lab.STORE, "library", side_effect=RuntimeError("private-key")):
            status, payload = self.request("GET", "/api/library")
        self.assertEqual(status, 500)
        self.assertNotIn("private-key", str(payload))


if __name__ == "__main__":
    unittest.main()
