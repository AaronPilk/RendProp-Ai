"""Actual worker + DB helper, synthetic RPC responses; no provider/storage sends.

SQL atomicity/roles/leases are tested separately by worker_publish_transaction.sql
against disposable PostgreSQL. These tests do not pretend Python mocks prove SQL.
"""
import copy
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import requests
import db
import worker

JOB = {"id": "10000000-0000-0000-0000-000000000001",
       "listing_id": "20000000-0000-0000-0000-000000000001",
       "capture_asset_id": "30000000-0000-0000-0000-000000000001",
       "source": "worker", "worker_id": db.WORKER_ID, "attempts": 2}
RID = "40000000-0000-0000-0000-000000000001"
PREFIX = f"renders/{JOB['listing_id']}/{RID}"
RENDER = {"id": RID, "slug": "fixture-slug", "duration_s": 30, "speed_factor": 2,
          "video_key": PREFIX + ".mp4", "poster_key": PREFIX + "-poster.jpg",
          "stream_uid": None, "hero_key": None}
OUTCOME = {"ran": False, "staged": False, "reason": "fixture"}


def committed(payload):
    row = {**payload["p_render"], "job_id": payload["p_job"],
           "listing_id": JOB["listing_id"], "staged": payload["p_enhancement_result"]["staged"],
           "published_at": "2026-09-10T12:00:00Z"}
    receipt = {"version": 1, "job_id": payload["p_job"], "worker_id": payload["p_worker"],
               "attempt": payload["p_attempt"], "request": {"render": payload["p_render"],
                   "enhancement_result": payload["p_enhancement_result"], "photos": payload["p_photos"]},
               "render": row}
    return {"job_id": payload["p_job"], "status": "ready", "render": row, "receipt": receipt}


def response(body):
    result = requests.Response()
    result.status_code = 200
    result._content = json.dumps(body).encode()
    return result


class WorkerPublishTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.object(requests.sessions.Session, "send",
            side_effect=AssertionError("No HTTP sends are allowed")))
        self.calls = []
        self.rpc = self.enterContext(patch.object(db, "_request", side_effect=self.good_rpc))

    def good_rpc(self, method, endpoint, **kw):
        self.assertEqual((method, endpoint), ("POST", "rpc/publish_worker_render"))
        self.calls.append(copy.deepcopy(kw["json"]))
        return response(committed(kw["json"]))

    def publish(self):
        return db.publish_worker_render(JOB, RENDER, OUTCOME, [])

    def test_exact_receipt_is_required_and_accepted(self):
        row = self.publish()
        self.assertEqual(row["video_key"], RENDER["video_key"])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0]["p_attempt"], 2)
        self.assertEqual(self.calls[0]["p_worker"], db.WORKER_ID)

    def test_same_attempt_same_payload_replay_is_unchanged(self):
        self.assertEqual(self.publish(), self.publish())
        self.assertEqual(self.calls[0], self.calls[1])

    def test_timeout_retries_exact_payload_and_accepts_commit_receipt(self):
        def flaky(method, endpoint, **kw):
            if not self.calls:
                self.calls.append(copy.deepcopy(kw["json"]))
                raise db.DBError("synthetic response timeout")
            return self.good_rpc(method, endpoint, **kw)
        self.rpc.side_effect = flaky
        self.publish()
        self.assertEqual(self.calls[0], self.calls[1])

    def test_ambiguous_timeout_twice_is_not_success(self):
        self.rpc.side_effect = db.DBError("synthetic timeout")
        with self.assertRaises(db.PublishUncertain):
            self.publish()
        self.assertEqual(self.rpc.call_count, 2)

    def test_2xx_without_exact_identity_and_receipt_is_never_success(self):
        corruptions = [
            lambda r: r.update(status="processing"),
            lambda r: r.update(job_id="other-job"),
            lambda r: r.update(receipt={}),
            lambda r: r["receipt"].update(attempt=1),
            lambda r: r["receipt"]["request"]["render"].update(video_key="wrong.mp4"),
            lambda r: r["render"].update(job_id="other-job"),
            lambda r: r["render"].update(listing_id="other-listing"),
            lambda r: r["render"].update(video_key="wrong.mp4"),
            lambda r: r["render"].update(staged=True),
            lambda r: r["render"].update(published_at=None),
            lambda r: r["render"].update(published_at="not-a-time"),
            lambda r: r["render"].update(id="not-a-render-uuid"),
            lambda r: r["receipt"].update(version=True),
        ]
        for corrupt in corruptions:
            with self.subTest(corruption=corruptions.index(corrupt)):
                def bad(_method, _endpoint, **kw):
                    result = committed(copy.deepcopy(kw["json"]))
                    corrupt(result)
                    return response(result)
                self.rpc.side_effect = bad
                self.rpc.reset_mock()
                with self.assertRaises(db.PublishUncertain):
                    self.publish()
                self.assertEqual(self.rpc.call_count, 2)

    def test_stale_attempt_and_changed_ready_payload_do_not_retry(self):
        for code in ("WP001", "WP002"):
            self.rpc.reset_mock()
            self.rpc.side_effect = db.DBError("synthetic rejection", code=code)
            with self.assertRaises(db.JobNotOwned):
                self.publish()
            self.assertEqual(self.rpc.call_count, 1)

    def test_known_missing_rpc_role_or_validation_rejection_has_no_fallback(self):
        for code in ("PGRST202", "42501", "WP003"):
            self.rpc.reset_mock()
            self.rpc.side_effect = db.DBError("synthetic rejection", code=code)
            with self.assertRaises(db.PublishRejected):
                self.publish()
            self.assertEqual(self.rpc.call_count, 1)

    def test_legacy_or_foreign_claim_fails_before_http(self):
        for changed in ({"worker_id": "other-worker"}, {"attempts": None},
                        {"attempts": True}, {"attempts": 0}, {"source": "app"}):
            with self.assertRaises(db.JobNotOwned):
                db.publish_worker_render({**JOB, **changed}, RENDER, OUTCOME, [])
        self.rpc.assert_not_called()

    def test_unsafe_alternate_helpers_are_removed(self):
        for name in ("insert_render", "_replace_render_for_job", "set_enhancement_result",
                     "set_listing_status", "finish_job", "insert_photo"):
            self.assertFalse(hasattr(db, name), name)

    def run_inner(self, *, rpc_error=None, job=None):
        self.enterContext(patch.object(worker, "db", db))
        self.enterContext(patch.object(worker, "SETTINGS", SimpleNamespace(
            r2_bucket_uploads="uploads", r2_bucket_renders="renders", encode_preset="veryfast",
            encode_bitrate="12M")))
        for name in ("set_progress", "record_cost", "rollup_job_best_effort", "flush_cost_spool"):
            self.enterContext(patch.object(db, name))
        self.enterContext(patch.object(db, "fetch_listing", return_value={"org_id": "fixture-org"}))
        self.enterContext(patch.object(db, "fetch_asset", return_value={
            "id": JOB["capture_asset_id"], "bucket": "uploads", "uploaded": True,
            "storage_key": "fixture.mov", "bytes": 1, "kind": "video"}))
        self.enterContext(patch.object(worker, "_check_free_space"))
        self.enterContext(patch.object(worker.ffmpeg_render, "render", return_value=("out.mp4", "poster.jpg", 30, 2)))
        self.enterContext(patch.object(worker, "_register_stream", return_value=None))
        self.enterContext(patch.object(worker.r2, "download_file"))
        self.upload = self.enterContext(patch.object(worker.r2, "upload_file"))
        self.delete = self.enterContext(patch.object(worker.r2, "delete_object"))
        self.enterContext(patch.object(worker.shutil, "rmtree"))
        self.fail = self.enterContext(patch.object(db, "fail_job"))
        if rpc_error:
            self.rpc.side_effect = rpc_error
        worker._process_job_inner(job or JOB, JOB["id"], JOB["listing_id"],
                                  JOB["capture_asset_id"], {}, "fixture-workdir", Mock())

    def test_real_process_publishes_only_one_receipted_rpc(self):
        self.run_inner()
        self.assertEqual(self.rpc.call_count, 1)
        self.assertEqual(self.upload.call_count, 2)
        self.assertEqual(self.calls[0]["p_enhancement_result"]["staged"], False)
        self.fail.assert_not_called()
        self.delete.assert_not_called()

    def test_real_process_keeps_artifacts_after_ambiguous_commit(self):
        with self.assertRaises(db.PublishUncertain):
            self.run_inner(rpc_error=db.DBError("synthetic response lost after commit"))
        self.assertEqual(self.rpc.call_count, 2)
        self.assertEqual(self.upload.call_count, 2)
        self.delete.assert_not_called()
        self.fail.assert_not_called()

    def test_real_process_stale_worker_cannot_fail_winner_or_delete_artifacts(self):
        self.run_inner(rpc_error=db.DBError("synthetic stale claim", code="WP001"))
        self.assertEqual(self.rpc.call_count, 1)
        self.delete.assert_not_called()
        self.fail.assert_not_called()

    def test_real_process_known_rejection_surfaces_without_side_writes(self):
        with self.assertRaises(db.PublishRejected):
            self.run_inner(rpc_error=db.DBError("synthetic invalid request", code="WP003"))
        self.assertEqual(self.rpc.call_count, 1)
        self.delete.assert_not_called()
        self.fail.assert_not_called()

    def test_real_process_legacy_claim_cannot_download_or_upload(self):
        self.run_inner(job={**JOB, "attempts": None})
        self.rpc.assert_not_called()
        self.upload.assert_not_called()
        self.fail.assert_not_called()


if __name__ == "__main__":
    unittest.main()
