"""Real Stream/client fallback code with synthetic files and no HTTP sends.

Requests' multipart encoder eagerly copies file data. The primary R2 URL-copy
path may fail, but that must never turn a finished tour into a multi-GB read.
"""
from __future__ import annotations

import io
import os
import stat
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import requests
import stream
import worker

BUDGET = 16 * 1024 * 1024


class RecordingFile(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.read_sizes = []

    def fileno(self):
        return 12345  # os.fstat is intercepted; no descriptor is used.

    def read(self, size=-1):
        self.read_sizes.append(size)
        return super().read(size)


class StreamFallbackTests(unittest.TestCase):
    def setUp(self):
        self.file = RecordingFile(b"tiny-video")
        self.info = SimpleNamespace(st_size=10, st_mode=stat.S_IFREG)
        self.stat = Mock(return_value=self.info)
        self.fstat = Mock(return_value=self.info)
        # Scope the fake to stream.py: patching process-global os.stat also
        # breaks unittest's traceback loader and hides the assertion we need.
        self.enterContext(patch.object(stream, "os", create=True,
            new=SimpleNamespace(stat=self.stat, fstat=self.fstat)))
        self.open = self.enterContext(patch.object(stream, "open", create=True,
                                                   return_value=self.file))
        self.send = self.enterContext(patch.object(requests.sessions.Session, "send",
            side_effect=AssertionError("No test may send an HTTP request")))
        self.response = Mock(ok=True, status_code=200)
        self.response.json.return_value = {"success": True, "result": {"uid": "fixture-uid"}}
        self.request = self.enterContext(patch.object(stream, "_request",
                                                     side_effect=self.prepare_only))
        self.enterContext(patch.object(stream, "SETTINGS", SimpleNamespace(
            cloudflare_account_id="fixture", cloudflare_stream_token="fixture-not-real",
            stream_timeout_s=31)))
        self.enterContext(patch.object(worker, "SETTINGS", SimpleNamespace(
            has_stream=True, stream_require_ready=False, r2_bucket_renders="fixture-renders")))
        self.prepared = None

    def prepare_only(self, method, url, **kw):
        self.assertEqual(kw.pop("timeout"), 31)
        self.prepared = requests.Request(method, url, **kw).prepare()
        self.assertIsInstance(self.prepared.body, bytes)
        return self.response

    def assert_rejected_without_read_or_network(self, size, mode=stat.S_IFREG):
        self.info.st_size, self.info.st_mode = size, mode
        with self.assertRaises(stream.StreamError):
            stream.direct_upload("fixture.mp4")
        self.open.assert_not_called()
        self.assertEqual(self.file.read_sizes, [])
        self.request.assert_not_called()
        self.send.assert_not_called()

    def test_over_budget_never_opens_reads_or_requests(self):
        self.assert_rejected_without_read_or_network(BUDGET + 1)

    def test_empty_never_opens_reads_or_requests(self):
        self.assert_rejected_without_read_or_network(0)

    def test_non_regular_file_never_opens_reads_or_requests(self):
        self.assert_rejected_without_read_or_network(10, stat.S_IFIFO)

    def test_stat_failure_is_typed_and_no_open_or_request(self):
        self.stat.side_effect = FileNotFoundError("synthetic missing file")
        with self.assertRaises(stream.StreamError):
            stream.direct_upload("fixture.mp4")
        self.open.assert_not_called()
        self.request.assert_not_called()

    def test_small_file_prepares_real_multipart_and_returns_uid(self):
        self.assertEqual(stream.direct_upload("fixture.mp4", name="named.mp4"), "fixture-uid")
        self.assertIn(b'filename="named.mp4"', self.prepared.body)
        self.assertIn(b"tiny-video", self.prepared.body)
        self.assertEqual(self.request.call_count, 1)
        self.send.assert_not_called()

    def test_exact_budget_is_accepted_with_bounded_read(self):
        self.info.st_size = BUDGET
        self.file = RecordingFile(b"x" * BUDGET)
        self.open.return_value = self.file
        self.assertEqual(stream.direct_upload("fixture.mp4"), "fixture-uid")
        self.assertTrue(self.file.read_sizes)
        self.assertTrue(all(0 < n <= BUDGET + 1 for n in self.file.read_sizes))
        self.assertGreaterEqual(len(self.prepared.body), BUDGET)
        self.send.assert_not_called()

    def test_growth_before_open_is_rejected_before_read(self):
        self.fstat.return_value = SimpleNamespace(st_size=BUDGET + 1, st_mode=stat.S_IFREG)
        with self.assertRaises(stream.StreamError):
            stream.direct_upload("fixture.mp4")
        self.assertEqual(self.file.read_sizes, [])
        self.request.assert_not_called()

    def test_growth_during_read_cannot_exceed_budget_or_send(self):
        self.file = RecordingFile(b"x" * (BUDGET + 2))
        self.open.return_value = self.file
        with self.assertRaises(stream.StreamError):
            stream.direct_upload("fixture.mp4")
        self.assertTrue(self.file.read_sizes)
        self.assertTrue(all(0 < n <= BUDGET + 1 for n in self.file.read_sizes))
        self.request.assert_not_called()

    def test_empty_after_open_is_rejected_without_request(self):
        self.file = RecordingFile(b"")
        self.open.return_value = self.file
        with self.assertRaises(stream.StreamError):
            stream.direct_upload("fixture.mp4")
        self.request.assert_not_called()

    def test_missing_uid_remains_a_failure(self):
        self.response.json.return_value = {"success": True, "result": {}}
        with self.assertRaises(stream.StreamError):
            stream.direct_upload("fixture.mp4")

    def test_worker_keeps_r2_playback_when_large_fallback_is_refused(self):
        self.info.st_size = BUDGET + 1
        with patch.object(worker.r2, "presigned_get_url", return_value="https://fixture.invalid/video"), \
             patch.object(stream, "copy_from_url", side_effect=stream.StreamError("fixture copy unavailable")), \
             patch.object(os.path, "exists", return_value=True):
            result = worker._register_stream("fixture-key", "L", "R", "fixture.mp4")
        self.assertIsNone(result)
        self.open.assert_not_called()
        self.request.assert_not_called()

    def test_worker_uses_normal_small_fallback_after_copy_failure(self):
        with patch.object(worker.r2, "presigned_get_url", return_value="https://fixture.invalid/video"), \
             patch.object(stream, "copy_from_url", side_effect=stream.StreamError("fixture copy unavailable")), \
             patch.object(os.path, "exists", return_value=True):
            result = worker._register_stream("fixture-key", "L", "R", "fixture.mp4")
        self.assertEqual(result, "fixture-uid")
        self.assertEqual(self.request.call_count, 1)
        self.send.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
