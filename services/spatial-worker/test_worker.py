"""Offline controller boundary tests. No credentials, uploads or GPUs used."""
from datetime import datetime, timedelta, timezone
from io import BytesIO
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

import worker as w
from modal_provider import navigation_manifest

JOB_ID = "11111111-1111-4111-8111-111111111111"
LEASE_ID = "22222222-2222-4222-8222-222222222222"
REVISION = "33333333-3333-4333-8333-333333333333"


def job():
    return {"id": JOB_ID, "lease_token": LEASE_ID, "attempt_key": REVISION, "room_label": "Living room",
            "deadline_at": (datetime.now(timezone.utc) + timedelta(seconds=7200)).isoformat(),
            "max_seconds": 7200, "max_training_seconds": 900, "max_iterations": 3000, "max_gaussians": 500000, "max_cost_cents": 600,
            "manifest": {"frames": [f"frames/{i:06d}.json" for i in range(20)]},
            "inputs": [{"relative_path": f"images/{i:06d}.jpg", "bytes": 3,
                        "download_url": f"https://storage.example/images/{i:06d}.jpg",
                        "frame": {"image": f"images/{i:06d}.jpg"}} for i in range(20)]}


class Response(BytesIO):
    def __init__(self, content, status=200, headers=None):
        super().__init__(content)
        self.status = status
        self.headers = headers if headers is not None else {"Content-Length": str(len(content))}


class FakeClock:
    """Monotonic seconds the test advances by hand; nothing here sleeps for real."""
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ContractTests(unittest.TestCase):
    def test_control_plane_identifies_actual_worker_without_default_urllib_agent(self):
        opener = Mock(); opener.open.return_value = Response(b'{"job":null}')
        api = w.ControlPlane("https://api.example/functions/v1/spatial", "fixture-not-a-credential", opener=opener)
        self.assertIsNone(api.claim())
        self.assertEqual(opener.open.call_args.args[0].get_header("User-agent"), "Rendprop-Spatial-Worker/1.0")

    def test_valid_contract(self):
        self.assertGreater(w.validate_job(job()), 7000)

    def test_hostile_numeric_bounds(self):
        for field, value in [("max_seconds", 0), ("max_seconds", 60), ("max_seconds", 7201), ("max_seconds", True),
                             ("max_training_seconds", 1801), ("max_training_seconds", 0),
                             ("max_iterations", 7001), ("max_gaussians", 500001),
                             ("max_cost_cents", 599), ("max_cost_cents", 2501)]:
            with self.subTest(field=field, value=value):
                value_job = job(); value_job[field] = value
                with self.assertRaises(w.JobFailure):
                    w.validate_job(value_job)

    def test_deadline_must_be_bounded_future_with_timezone(self):
        for date in ["bad", "2026-01-01T00:00:00", "2000-01-01T00:00:00Z", "2999-01-01T00:00:00Z"]:
            value_job = job(); value_job["deadline_at"] = date
            with self.assertRaises(w.JobFailure):
                w.validate_job(value_job)

    def test_bad_input_bytes(self):
        for size in [-1, 0, True, float("nan"), 33554433]:
            value_job = job(); value_job["inputs"][0]["bytes"] = size
            with self.assertRaises(w.JobFailure):
                w.validate_job(value_job)

    def test_paths_and_exact_manifest_coverage(self):
        for name in ["../../outside.jpg", "images//000000.jpg", "images/000001.jpg", "images/a.jpg"]:
            value_job = job(); value_job["inputs"][0]["relative_path"] = name
            with self.assertRaises(w.JobFailure):
                w.validate_job(value_job)
        value_job = job(); value_job["manifest"]["frames"][0] = "frames/000001.json"
        with self.assertRaises(w.JobFailure):
            w.validate_job(value_job)

    def test_too_many_tiny_images_is_not_free_admission(self):
        value_job = job()
        value_job["inputs"] = value_job["inputs"] * 21
        with self.assertRaisesRegex(w.JobFailure, "invalid_input_count"):
            w.validate_job(value_job)

    def test_nan_metadata_rejected_before_allocation(self):
        value_job = job(); value_job["inputs"][0]["frame"]["timestamp"] = float("nan")
        with self.assertRaisesRegex(w.JobFailure, "invalid_json"):
            w.validate_job(value_job)

    def test_urls_cannot_escape_exact_https_origin(self):
        for url in ["http://storage.example/a", "https://storage.example.evil/a", "https://u:p@storage.example/a",
                    "https://storage.example:123/a", "https://storage.example/a#x", "https://127.0.0.1/a"]:
            with self.assertRaises(w.JobFailure):
                w.https_url(url, {"storage.example"})
        self.assertEqual(w.https_url("https://storage.example/a?cap=x", {"storage.example"}),
                         "https://storage.example/a?cap=x")

    def test_redirect_handler_never_forwards_request(self):
        self.assertIsNone(w.NoRedirect().redirect_request(None, None, 307, "", {}, "https://evil.example"))


class DownloadTests(unittest.TestCase):
    def test_exact_downloads_create_only_expected_capture_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            opener = Mock(); opener.open.side_effect = lambda *a, **k: Response(b"jpg")
            path = Path(tmp) / "capture"
            w.download_capture(job(), path, {"storage.example"}, opener=opener)
            self.assertEqual(opener.open.call_count, 20)
            self.assertTrue(all(c.args[0].get_header("User-agent") == w.WORKER_USER_AGENT
                                for c in opener.open.call_args_list))
            self.assertEqual(len(list(path.rglob("*.*"))), 41)
            self.assertEqual((path / "images/000000.jpg").read_bytes(), b"jpg")
            self.assertEqual((path / "manifest.json").stat().st_mode & 0o777, 0o600)

    def test_oversized_stream_rejected_even_with_small_length_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            opener = Mock(); opener.open.return_value = Response(b"too long", headers={"Content-Length": "3"})
            with self.assertRaisesRegex(w.JobFailure, "image_length_mismatch"):
                w.download_capture(job(), Path(tmp) / "capture", {"storage.example"}, opener=opener)
            self.assertEqual(opener.open.call_count, 1)

    def test_truncated_stream_is_not_counted_as_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            opener = Mock(); opener.open.return_value = Response(b"j", headers={"Content-Length": "3"})
            with self.assertRaisesRegex(w.JobFailure, "image_length_mismatch"):
                w.download_capture(job(), Path(tmp) / "capture", {"storage.example"}, opener=opener)

    def test_cross_origin_rejected_before_any_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            opener = Mock(); value_job = job(); value_job["inputs"][0]["download_url"] = "https://evil.example/x"
            with self.assertRaises(w.JobFailure):
                w.download_capture(value_job, Path(tmp) / "capture", {"storage.example"}, opener=opener)
            opener.open.assert_not_called()


class LifecycleTests(unittest.TestCase):
    def test_idle_never_touches_provider(self):
        api, provider = Mock(), Mock(); api.claim.return_value = None
        self.assertEqual(w.run_one(api, provider, {"storage.example"}), {"status": "idle"})
        provider.reconstruct.assert_not_called()

    def test_invalid_capture_fails_before_gpu_and_does_not_retry(self):
        api, provider, adapter = Mock(), Mock(), Mock()
        api.claim.return_value = job(); adapter.load_capture.side_effect = ValueError("bad geometry")
        with patch.object(w, "download_capture"), patch.object(w, "load_adapter", return_value=adapter):
            with self.assertRaises(w.JobFailure):
                w.run_one(api, provider, {"storage.example"})
        api.claim.assert_called_once()
        provider.reconstruct.assert_not_called()
        terminal = [c for c in api.job_call.call_args_list if c.args[1] == "fail"]
        self.assertEqual(len(terminal), 1)
        self.assertEqual(terminal[0].kwargs["cost_cents"], 600)
        self.assertIs(terminal[0].kwargs["provider_stopped"], True)
        proof = [c for c in api.job_call.call_args_list if c.args[1] == "provider-attempt"]
        self.assertEqual(len(proof), 1)
        self.assertEqual(proof[0].kwargs["action"], "not_created")
        self.assertEqual(proof[0].kwargs["data"]["proof"], "create_not_invoked")

    def test_failure_reports_provider_stop_proof_not_failure_alone(self):
        for terminal_proved in (False, True):
            with self.subTest(terminal_proved=terminal_proved):
                api, provider, adapter = Mock(), Mock(), Mock()
                api.claim.return_value = job()
                def uncertain_provider(value, root, capture, lease):
                    lease.provider_attempted = True
                    lease.provider_stopped = terminal_proved
                    raise w.JobFailure("generation_failed")
                provider.reconstruct.side_effect = uncertain_provider
                with patch.object(w, "download_capture"), patch.object(w, "load_adapter", return_value=adapter):
                    with self.assertRaisesRegex(w.JobFailure, "generation_failed"):
                        w.run_one(api, provider, {"storage.example"})
                terminal = [c for c in api.job_call.call_args_list if c.args[1] == "fail"]
                self.assertEqual(len(terminal), 1)
                self.assertIs(terminal[0].kwargs["provider_stopped"], terminal_proved)
                self.assertFalse(any(c.args[1] == "provider-attempt" for c in api.job_call.call_args_list))

    def test_lease_failure_aborts_gpu_and_will_not_heartbeat_forever(self):
        api = Mock(); api.job_call.side_effect = w.JobFailure("lease_lost")
        lease = w.Lease(api, job(), interval=.001)
        aborted = threading.Event(); lease.abort = aborted.set
        lease.thread.start()
        self.assertTrue(aborted.wait(2))
        lease.thread.join(2)
        with self.assertRaisesRegex(w.JobFailure, "lease_lost"):
            lease.check()

    def test_failed_abort_remains_failed_without_a_raw_thread_exception(self):
        api = Mock(); api.job_call.side_effect = w.JobFailure("lease_lost")
        lease = w.Lease(api, job(), interval=.001)
        lease.abort = Mock(side_effect=RuntimeError("raw private SDK error"))
        lease.thread.start(); lease.thread.join(2)
        self.assertFalse(lease.thread.is_alive())
        self.assertEqual(lease.abort_failure_type, "RuntimeError")
        with self.assertRaisesRegex(w.JobFailure, "lease_lost"): lease.check()

    def test_one_transient_heartbeat_failure_does_not_terminate_a_paid_gpu(self):
        clock, api, settled = FakeClock(), Mock(), threading.Event()
        outcomes = [w.JobFailure("control_plane_unavailable"), None, OSError("reset"), None, None]
        def heartbeat(j, action, **fields):
            self.assertEqual(action, "heartbeat")
            clock.now += 5
            outcome = outcomes.pop(0) if outcomes else None
            if not outcomes:
                settled.set()
            if outcome is not None:
                raise outcome
            return {"ok": True}
        api.job_call.side_effect = heartbeat
        lease = w.Lease(api, job(), interval=.001, retry_interval=.001, clock=clock)
        aborted = threading.Event(); lease.abort = aborted.set
        lease.thread.start()
        self.assertTrue(settled.wait(2))
        lease.stop.set(); lease.thread.join(2)
        self.assertFalse(aborted.is_set())
        self.assertIsNone(lease.error)
        self.assertEqual(lease.failed_beats, 0)  # reset by the accepted beat that followed
        self.assertEqual(lease.last_beat_error, "OSError")  # a type name, never a body
        lease.check()

    def test_transient_failures_are_retried_until_the_db_lease_is_within_reach(self):
        clock, api, beats = FakeClock(), Mock(), []
        def heartbeat(j, action, **fields):
            beats.append(clock.now)
            clock.now += 10  # every failed beat burns ten seconds of the two-minute DB lease
            raise w.JobFailure("control_plane_unavailable")
        api.job_call.side_effect = heartbeat
        lease = w.Lease(api, job(), interval=.001, retry_interval=.001, clock=clock)
        aborted = threading.Event(); lease.abort = aborted.set
        lease.thread.start()
        self.assertTrue(aborted.wait(2))
        lease.thread.join(2)
        # Retried at 0,10,...,60s while at most half the lease had elapsed; the
        # failure ending at 70s is the first past that line, so compute stopped
        # with 50s of provably valid lease left, not on the first blip.
        self.assertEqual(beats, [0, 10, 20, 30, 40, 50, 60])
        self.assertEqual(lease.failed_beats, 7)
        with self.assertRaisesRegex(w.JobFailure, "lease_lost"):
            lease.check()

    def test_definitive_rejection_is_not_retried_even_when_the_lease_has_time_left(self):
        clock, api = FakeClock(), Mock()
        api.job_call.side_effect = w.JobFailure("lease_lost")  # 403/409/410 from the control plane
        lease = w.Lease(api, job(), interval=.001, retry_interval=.001, clock=clock)
        aborted = threading.Event(); lease.abort = aborted.set
        lease.thread.start()
        self.assertTrue(aborted.wait(2)); lease.thread.join(2)
        self.assertEqual(api.job_call.call_count, 1)
        self.assertEqual(clock.now, 0)

    def test_a_lease_nobody_renewed_for_its_whole_lifetime_is_lost_even_when_quiet(self):
        clock, api = FakeClock(), Mock()
        lease = w.Lease(api, job(), clock=clock)
        clock.now = 119.9
        lease.check()
        clock.now = 120
        with self.assertRaisesRegex(w.JobFailure, "lease_lost"):
            lease.check()
        api.job_call.assert_not_called()

    def test_progress_report_failure_is_advisory_unless_definitive(self):
        api = Mock(); lease = w.Lease(api, job(), clock=FakeClock())
        api.job_call.side_effect = w.JobFailure("control_plane_unavailable")
        lease.stage(0.5)
        self.assertEqual(lease.progress, 0.5)
        self.assertEqual(lease.failed_beats, 1)
        api.job_call.side_effect = w.JobFailure("lease_lost")
        with self.assertRaisesRegex(w.JobFailure, "lease_lost"):
            lease.stage(0.6)

    def test_transient_complete_failure_does_not_burn_the_stored_artifact(self):
        api, provider, adapter = Mock(), Mock(), Mock()
        api.claim.return_value = job()
        api.service_host = "api.example"; api.base_url = "https://api.example/functions/v1/spatial"
        api.opener.open.return_value = Response(b'{"ok":true}')
        actions, completes = [], [w.JobFailure("control_plane_unavailable"), {"status": "review"}]
        def job_call(j, action, **fields):
            actions.append(action)
            if action == "output-ticket":
                return {"method": "PUT", "bytes": 3, "content_type": "application/octet-stream",
                        "upload_url": f"{api.base_url}/worker/{JOB_ID}/output", "upload_token": "fixture-token",
                        "artifact_revision": REVISION}
            if action == "complete":
                outcome = completes.pop(0)
                if isinstance(outcome, Exception):
                    raise outcome
                return outcome
            return {"ok": True}
        api.job_call.side_effect = job_call
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.sog"; path.write_bytes(b"sog")
            provider.reconstruct.return_value = (path, {})
            with patch.object(w, "download_capture"), patch.object(w, "load_adapter", return_value=adapter), \
                    patch.object(w, "COMPLETE_RETRY_DELAYS", (0,)):
                self.assertEqual(w.run_one(api, provider, {"storage.example"}), {"status": "review", "job_id": JOB_ID})
        self.assertNotIn("fail", actions)
        self.assertEqual(actions[-3:], ["complete", "heartbeat", "complete"])
        self.assertEqual(api.opener.open.call_count, 1)  # the bytes went over exactly once

    def test_success_uses_server_terminal_receipt_not_provider_return_alone(self):
        api, provider, adapter = Mock(), Mock(), Mock()
        api.claim.return_value = job()
        provider.reconstruct.return_value = (Path("synthetic.sog"), {})
        with patch.object(w, "download_capture"), patch.object(w, "load_adapter", return_value=adapter), \
                patch.object(w, "upload_output", return_value={"status": "review"}) as upload:
            result = w.run_one(api, provider, {"storage.example"})
        self.assertEqual(result, {"status": "review", "job_id": JOB_ID})
        provider.reconstruct.assert_called_once(); upload.assert_called_once()

    def test_false_ok_does_not_succeed(self):
        api, provider, adapter = Mock(), Mock(), Mock(); api.claim.return_value = job()
        provider.reconstruct.return_value = (Path("synthetic.sog"), {})
        with patch.object(w, "download_capture"), patch.object(w, "load_adapter", return_value=adapter), \
                patch.object(w, "upload_output", return_value={"ok": True}):
            with self.assertRaisesRegex(w.JobFailure, "generation_completion_unconfirmed"):
                w.run_one(api, provider, {"storage.example"})


class OutputTests(unittest.TestCase):
    def test_missing_revision_rejected_before_physical_output_transfer(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.sog"; path.write_bytes(b"sog")
            api = Mock(); api.service_host = "api.example"; api.base_url = "https://api.example/functions/v1/spatial"
            api.job_call.return_value = {"method": "PUT", "bytes": 3, "content_type": "application/octet-stream",
                "upload_url": f"{api.base_url}/worker/{JOB_ID}/output", "upload_token": "fixture-only"}
            with self.assertRaisesRegex(w.JobFailure, "invalid_output_revision"):
                w.upload_output(api, job(), path, {})
            api.opener.open.assert_not_called()

    def test_output_revision_digest_and_private_state_are_server_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.sog"; path.write_bytes(b"synthetic-output")
            api = Mock(); api.service_host = "api.example"; api.base_url = "https://api.example/functions/v1/spatial"
            api.job_call.side_effect = [{"method": "PUT", "bytes": 16, "content_type": "application/octet-stream",
                "upload_url": f"{api.base_url}/worker/{JOB_ID}/output", "upload_token": "fixture-token",
                "artifact_revision": REVISION}, {"status": "review"}]
            api.opener.open.return_value = Response(b'{"ok":true}')
            self.assertEqual(w.upload_output(api, job(), path, {"privacy_reviewed": True}), {"status": "review"})
            self.assertEqual(api.opener.open.call_args.args[0].get_header("User-agent"), w.WORKER_USER_AGENT)
            completed = api.job_call.call_args.kwargs
            self.assertEqual(completed["manifest"]["artifact_revision"], REVISION)
            self.assertFalse(completed["manifest"]["privacy_reviewed"])
            self.assertEqual(completed["manifest"]["bytes"], 16)
            self.assertEqual(completed["manifest"]["sha256"], w.hashlib.sha256(b"synthetic-output").hexdigest())

    def stored_output(self, complete_outcomes, heartbeat=None):
        """An API whose PUT already succeeded; only `complete` misbehaves as scripted."""
        api = Mock(); api.service_host = "api.example"; api.base_url = "https://api.example/functions/v1/spatial"
        api.opener.open.return_value = Response(b'{"ok":true}')
        actions = []
        def job_call(j, action, **fields):
            actions.append(action)
            if action == "output-ticket":
                return {"method": "PUT", "bytes": 3, "content_type": "application/octet-stream",
                        "upload_url": f"{api.base_url}/worker/{JOB_ID}/output", "upload_token": "fixture-token",
                        "artifact_revision": REVISION}
            if action == "heartbeat":
                if heartbeat is not None:
                    raise heartbeat
                return {"ok": True}
            self.assertEqual(action, "complete")
            outcome = complete_outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome
        api.job_call.side_effect = job_call
        return api, actions

    def test_complete_is_retried_through_transient_failures_with_fresh_heartbeats(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.sog"; path.write_bytes(b"sog")
            api, actions = self.stored_output([w.JobFailure("control_plane_unavailable"),
                                               w.JobFailure("invalid_service_response"), {"status": "review"}])
            clock, sleeps = FakeClock(), []
            def sleep(seconds):
                sleeps.append(seconds); clock.sleep(seconds)
            lease = w.Lease(api, job(), clock=clock)
            self.assertEqual(w.upload_output(api, job(), path, {}, lease, sleep=sleep), {"status": "review"})
        self.assertEqual(sleeps, [5, 10])
        self.assertEqual(actions, ["output-ticket", "complete", "heartbeat", "complete", "heartbeat", "complete"])
        self.assertEqual(api.opener.open.call_count, 1)
        self.assertTrue(lease.stop.is_set())

    def test_complete_retries_are_bounded_and_the_last_failure_is_reported_honestly(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.sog"; path.write_bytes(b"sog")
            api, actions = self.stored_output([w.JobFailure("control_plane_unavailable")] * 6)
            clock = FakeClock()
            with self.assertRaisesRegex(w.JobFailure, "control_plane_unavailable"):
                w.upload_output(api, job(), path, {}, w.Lease(api, job(), clock=clock), sleep=clock.sleep)
        self.assertEqual(actions.count("complete"), len(w.COMPLETE_RETRY_DELAYS) + 1)
        self.assertEqual(actions.count("heartbeat"), len(w.COMPLETE_RETRY_DELAYS))
        self.assertEqual(clock.now, sum(w.COMPLETE_RETRY_DELAYS))

    def test_definitive_complete_rejection_is_not_retried(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.sog"; path.write_bytes(b"sog")
            for code in ("lease_lost", "invalid_json"):
                with self.subTest(code=code):
                    api, actions = self.stored_output([w.JobFailure(code)])
                    sleep = Mock()
                    with self.assertRaisesRegex(w.JobFailure, code):
                        w.upload_output(api, job(), path, {}, w.Lease(api, job(), clock=FakeClock()), sleep=sleep)
                    self.assertEqual(actions, ["output-ticket", "complete"])
                    sleep.assert_not_called()

    def test_complete_is_not_retried_against_a_lease_that_certainly_expired(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.sog"; path.write_bytes(b"sog")
            api, actions = self.stored_output([w.JobFailure("control_plane_unavailable")] * 6,
                                              heartbeat=w.JobFailure("control_plane_unavailable"))
            clock = FakeClock()
            def slow_outage(seconds):
                clock.sleep(seconds + 100)  # each pause plus a hung control plane eats most of a lease
            with self.assertRaisesRegex(w.JobFailure, "lease_lost"):
                w.upload_output(api, job(), path, {}, w.Lease(api, job(), clock=clock), sleep=slow_outage)
        # 105s in: the renewal fails but the lease may still hold, so one more
        # attempt is allowed; 215s in it certainly expired, so no more attempts.
        self.assertEqual(actions, ["output-ticket", "complete", "heartbeat", "complete"])

    def test_navigation_estimate_is_not_reported_as_measured_floor(self):
        pose = [[1, 0, 0, 0], [0, 1, 0, 1.6], [0, 0, 1, 0], [0, 0, 0, 1]]
        capture = {"frames": [{"pose": pose}], "seeds": [{"position": [-1, 0, -1]}, {"position": [1, 2, 1]}]}
        manifest = navigation_manifest(capture, "Living room")
        self.assertEqual(manifest["floor_source"], "capture_estimate")
        self.assertEqual(manifest["initial_camera"]["position"], [0, 1.6, 0])
        self.assertEqual(manifest["initial_camera"]["target"], [0, 1.6, -1])
        self.assertEqual(manifest["rooms"][0]["label"], "Living room")


if __name__ == "__main__":
    unittest.main(verbosity=2)
