"""Adversarial checks for inactive diagnostics; not publication acceptance."""
import copy
import math
import subprocess
import sys
import time
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "container"))
import motion_qc
import smooth_finish
from process_deadline import BoundedProcess, ProcessDeadlineError
from unittest.mock import patch
from tests.test_motion_finish import shot
import tempfile


def measured_path(*, x=None, y=None, angle=None, log_scale=None, still=False):
    t = np.linspace(0, 1, 121)
    zero = np.zeros_like(t)
    x, y = zero if x is None else x, zero if y is None else y
    angle, log_scale = zero if angle is None else angle, zero if log_scale is None else log_scale
    steps = [{"valid": True, "dx": float(x[i + 1] - x[i]), "dy": float(y[i + 1] - y[i]),
              "rot": float(angle[i + 1] - angle[i]), "scale": float(math.expm1(log_scale[i + 1] - log_scale[i])),
              "inliers": 20, "mad": 0.0 if still else 5.0} for i in range(120)]
    return motion_qc.summarize(steps, 24)[0]


class ClosedMotionDiagnostics(unittest.TestCase):
    def test_steady_glide_passes_and_static_original_remains_explicit(self):
        glide = measured_path(x=np.linspace(0, 100, 121))
        self.assertTrue(motion_qc.verdict(glide)["pass"])
        static = measured_path(still=True)
        self.assertTrue(static["static_shot"])
        self.assertTrue(motion_qc.verdict(static)["pass"])
        # Static is a measured fact. Only a trusted caller knows whether this
        # is a permitted original-photo fallback or an AI shot lacking motion.
        self.assertEqual(static["duplicate_ratio"], 0)

    def test_pull_back_and_push_in_use_the_same_scale_ratio_limit(self):
        t = np.linspace(0, 1, 121)
        for scale in (1.8, .3):
            with self.subTest(scale=scale):
                metrics = measured_path(log_scale=math.log(scale) * t)
                self.assertGreater(metrics["zoom_excursion_pct"], 40)
                self.assertIn("walk_through_travel", motion_qc.verdict(metrics)["reasons"])

    def test_return_to_start_zoom_and_pan_cannot_cancel_excursion(self):
        t = np.linspace(0, 1, 121)
        for path in ({"log_scale": math.log(1.8) * np.sin(math.pi * t)}, {"x": 600 * np.sin(math.pi * t)}):
            with self.subTest(path=next(iter(path))):
                metrics = measured_path(**path)
                self.assertAlmostEqual(metrics["zoom_pct"], 0)
                self.assertAlmostEqual(metrics["pan_x_pct"], 0)
                self.assertIn("walk_through_travel", motion_qc.verdict(metrics)["reasons"])

    def test_slow_roll_returning_to_level_does_not_pass(self):
        t = np.linspace(0, 1, 121)
        metrics = measured_path(angle=math.radians(1.6) * np.sin(math.pi * t))
        self.assertAlmostEqual(metrics["roll_drift_deg"], 0)
        self.assertLess(metrics["roll_wobble_pp_deg"], .08)
        self.assertGreater(metrics["roll_span_deg"], 1)
        self.assertIn("horizon_roll", motion_qc.verdict(metrics)["reasons"])

    def test_centered_zoom_pumping_cannot_pass_as_low_total_travel(self):
        for amplitude in (.05, .08):
            logs = amplitude * np.sin(2 * math.pi * 3 * np.arange(121) / 24)
            metrics = measured_path(log_scale=logs)
            self.assertLess(metrics["zoom_excursion_pct"], 40)
            self.assertGreater(metrics["zoom_pump_pp_pct"], 9)
            self.assertIn("zoom_pumping", motion_qc.verdict(metrics)["reasons"])

    def test_majority_frozen_clip_is_not_a_static_original(self):
        metrics_steps = [{"valid": True, "dx": 0.0 if i < 70 else .5, "dy": 0., "rot": 0., "scale": 0.,
                          "mad": 0.0 if i < 70 else 5.0, "inliers": 20} for i in range(120)]
        metrics = motion_qc.summarize(metrics_steps, 24)[0]
        self.assertFalse(metrics["static_shot"])
        self.assertAlmostEqual(metrics["duplicate_ratio"], 70 / 120, places=3)
        self.assertIn("duplicate_frames", motion_qc.verdict(metrics)["reasons"])

    def test_textureless_original_is_explicitly_static_without_fabricating_a_fit(self):
        metrics = motion_qc.summarize([{"valid": False, "mad": 0.0} for _ in range(120)], 24)[0]
        self.assertEqual(metrics["invalid_ratio"], 1)
        self.assertTrue(metrics["static_shot"])
        self.assertTrue(motion_qc.verdict(metrics)["pass"])

    def test_nonfinite_types_shapes_and_profile_refuse(self):
        good = measured_path()
        numeric = [key for key, value in good.items() if type(value) in (float, int)]
        for key in numeric:
            for value in (float("nan"), float("inf"), float("-inf"), True, "0", None):
                with self.subTest(key=key, value=value):
                    invalid = {**good, key: value}
                    self.assertEqual(motion_qc.verdict(invalid)["reasons"], ["invalid_metrics"])
        for invalid in (None, [], {}, {**good, "extra": 0}, {**good, "profile": "temporal-motion-v1"},
                        {**good, "frame": [1, 1]}, {**good, "static_shot": 0},
                        {**good, "frame": [1920.0, 1080.0]},
                        {key: value for key, value in good.items() if key != "zoom_excursion_pct"},
                        {**good, "cadence_hz": float("nan")}, {**good, "cadence_hz": True},
                        {**good, "invalid_ratio": -1}, {**good, "invalid_ratio": 2}):
            with self.subTest(invalid=invalid):
                self.assertFalse(motion_qc.verdict(invalid)["pass"])
        for limits in ({**motion_qc.FINISHED_LIMITS, "bob_pp_px": float("nan")}, {}, {"extra": 0}):
            self.assertEqual(motion_qc.verdict(good, limits)["reasons"], ["invalid_limits"])

    def test_nonfinite_camera_path_refuses_before_warp(self):
        path = {key: np.zeros(121) for key in ("x", "y", "angle", "log_scale")}
        for key in path:
            bad = copy.deepcopy(path)
            bad[key][20] = float("nan")
            with self.assertRaises(smooth_finish.FinishError):
                smooth_finish.corrections(bad)
        for bad in ({"avg_frame_rate": "0/0", "r_frame_rate": "0/0"}, {"avg_frame_rate": "1000000/1"}):
            with self.assertRaises(motion_qc.MotionError):
                motion_qc.native_fps(bad)


class VersionedLimitsAndWorkerReport(unittest.TestCase):
    # property-video-worker/temporal.ts pins this exact text and SHA; the worker
    # holds every steady shot whose report names any other limit set.
    WORKER_PIN = "244436b765886f537bd6d3b835dc42ca06cc758dc1a3b796028aae448b21d555"

    def test_limits_canonical_text_and_sha_match_the_worker_pin(self):
        text = motion_qc.limits_canonical()
        self.assertEqual(text.split("\n")[0], "bob_pp_px=1.2")
        self.assertEqual(text.split("\n"), sorted(text.split("\n")))
        self.assertEqual(len(text.split("\n")), len(motion_qc.FINISHED_LIMITS))
        self.assertEqual(motion_qc.limits_canonical({"a": 1.0, "b": .4}), "a=1\nb=0.4")  # %g parity with JS String(n)
        self.assertEqual(motion_qc.LIMITS_SHA256, self.WORKER_PIN)
        self.assertNotEqual(motion_qc.limits_sha256({**motion_qc.FINISHED_LIMITS, "bob_pp_px": 1.3}), self.WORKER_PIN)

    def test_measure_reports_verdict_metrics_and_the_limit_version(self):
        with tempfile.TemporaryDirectory(prefix="motion-report-") as directory:
            root = Path(directory)
            glide = shot(root / "glide.mp4", (640, 360), pan=.4, seed=91)
            report = motion_qc.measure(glide)
            self.assertEqual(set(report), {"metrics", "verdict", "limits"})
            self.assertEqual(report["limits"], {"profile": motion_qc.PROFILE, "sha256": self.WORKER_PIN})
            self.assertEqual(report["verdict"]["profile"], motion_qc.PROFILE)
            self.assertEqual(report["metrics"]["profile"], motion_qc.PROFILE)
            self.assertTrue(report["verdict"]["pass"], report["verdict"])
            bob = shot(root / "bob.mp4", (640, 360), pan=.4, bob=6, seed=92)
            failed = motion_qc.measure(bob)
            self.assertFalse(failed["verdict"]["pass"])
            self.assertTrue({"vertical_bob", "walking_cadence"} & set(failed["verdict"]["reasons"]), failed["verdict"])
            self.assertEqual(failed["limits"]["sha256"], self.WORKER_PIN)
            self.assertNotIn("series", failed)

    def test_extract_task_with_temporal_qc_returns_frames_and_the_report_the_worker_records(self):
        # The actual renderer extract step with a closed local download double:
        # a steady-profile task (temporal_qc) adds `temporal`; a v1 task does not.
        import datetime
        import hashlib
        import renderer
        with tempfile.TemporaryDirectory(prefix="motion-extract-") as directory:
            root = Path(directory)
            clip = shot(root / "glide-1080.mp4", (1920, 1080), pan=.5, seed=93)
            sha = hashlib.sha256(clip.read_bytes()).hexdigest()
            expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).isoformat()
            job, attempt, lease = ("30000000-0000-4000-8000-00000000000%d" % i for i in (1, 2, 3))
            task = {"state": "quality_review", "action": "extract_frames", "job_id": job, "attempt_id": attempt, "lease_token": lease,
                    "source": {"url": "https://media.invalid/photo", "bytes": 1, "sha256": "a" * 64},
                    "clip": {"url": "https://media.invalid/clip", "bytes": clip.stat().st_size, "sha256": sha}, "expires_at": expires}

            def local_download(item, target, hosts, **_):
                self.assertEqual(item["url"], "https://media.invalid/clip")
                target.write_bytes(clip.read_bytes())
                return sha
            for steady in (True, False):
                with self.subTest(steady=steady):
                    full = {**task, **({"temporal_qc": {"profile": "temporal-motion-v2", "aspect": "16:9"}} if steady else {})}
                    renderer.validate_task(full)
                    work = root / ("work-steady" if steady else "work-v1")
                    work.mkdir()
                    with patch("renderer.download", side_effect=local_download):
                        result = renderer.extract(full, work, {"media.invalid"})
                    self.assertEqual([result["job_id"], result["attempt_id"], result["lease_token"], result["clip_sha256"]], [job, attempt, lease, sha])
                    self.assertEqual(len(result["frames"]), 3)
                    self.assertEqual((result["width"], result["height"]), (1920, 1080))
                    if steady:
                        self.assertEqual(set(result["temporal"]), {"metrics", "verdict", "limits"})
                        self.assertEqual(result["temporal"]["limits"]["sha256"], self.WORKER_PIN)
                        self.assertTrue(result["temporal"]["verdict"]["pass"], result["temporal"]["verdict"])
                        self.assertEqual(result["temporal"]["metrics"]["frame"], [1920, 1080])
                    else:
                        self.assertNotIn("temporal", result)


class EncodedDiagnosticDefects(unittest.TestCase):
    def test_encoded_zoom_pumping_and_majority_freeze_are_refused(self):
        # Small encoded textures test the detector in final-frame pixels. They
        # are synthetic diagnostics, not admitted production1080 source clips.
        with tempfile.TemporaryDirectory(prefix="motion-defects-") as directory:
            root = Path(directory)
            pumping = shot(root / "pump.mp4", (640, 360), zoom_wobble=.05, seed=81)
            metrics = motion_qc.measure(pumping)["metrics"]
            self.assertGreater(metrics["zoom_pump_pp_pct"], 5)
            self.assertIn("zoom_pumping", motion_qc.verdict(metrics)["reasons"])
            frozen = shot(root / "majority-frozen.mp4", (640, 360), pan=.3, freeze_frames=70, seed=82)
            metrics = motion_qc.measure(frozen)["metrics"]
            self.assertFalse(metrics["static_shot"])
            self.assertGreater(metrics["duplicate_ratio"], .5)
            self.assertIn("duplicate_frames", motion_qc.verdict(metrics)["reasons"])

    def test_undersized_encoded_source_refuses_before_measurement_and_no_output(self):
        with tempfile.TemporaryDirectory(prefix="motion-pixel-floor-") as directory:
            source, output = Path(directory) / "small.mp4", Path(directory) / "must-not-exist.mp4"
            subprocess.run([motion_qc.shutil.which("ffmpeg"), "-v", "error", "-f", "lavfi", "-i", "color=gray:s=1280x720:r=24",
                            "-frames:v", "120", "-c:v", "libx264", "-threads", "2", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(source)],
                           check=True, capture_output=True, timeout=30)
            with patch.object(motion_qc, "measure_steps", side_effect=AssertionError("pixel floor must precede motion analysis")):
                with self.assertRaisesRegex(smooth_finish.FinishError, "source_lacks_native_framing_pixels"):
                    smooth_finish.finish_shot(source, output)
            with self.assertRaisesRegex(smooth_finish.FinishError, "source_lacks_native_framing_pixels"):
                smooth_finish.render(source, output, "16:9", {"strength": 0, "zoom": 1}, 1280, 720)
            self.assertFalse(output.exists())


class MediaProcessDeadline(unittest.TestCase):
    def assert_reaped(self, process, start):
        self.assertIsNotNone(process.process.poll())
        self.assertLess(time.monotonic() - start, 2)
        self.assertTrue(process.process.stderr.closed)

    def test_stalled_decoder_read_is_killed_and_reaped(self):
        start = time.monotonic()
        with self.assertRaises(ProcessDeadlineError):
            with BoundedProcess([sys.executable, "-c", "import time; time.sleep(30)"], timeout=.25, read_stdout=True) as process:
                process.read_exact(1)
        self.assert_reaped(process, start)

    def test_stalled_encoder_write_is_killed_and_reaped(self):
        start = time.monotonic()
        with self.assertRaises(ProcessDeadlineError):
            with BoundedProcess([sys.executable, "-c", "import time; time.sleep(30)"], timeout=.25, write_stdin=True) as process:
                process.write(b"x" * (2 * 1024 * 1024))
        self.assert_reaped(process, start)

    def test_stderr_cannot_deadlock_stdout_and_is_bounded(self):
        code = "import os; os.write(2,b'x'*1048576); os.write(1,b'ok')"
        with BoundedProcess([sys.executable, "-c", code], timeout=2, read_stdout=True) as process:
            self.assertEqual(process.read_exact(2), b"ok")
            self.assertEqual(process.read_exact(2), b"")
            self.assertEqual(process.finish(), 0)
            self.assertEqual(len(process.stderr), process.STDERR_LIMIT)

    def test_caller_exception_also_kills_child(self):
        start = time.monotonic()
        with self.assertRaisesRegex(ValueError, "caller_error"):
            with BoundedProcess([sys.executable, "-c", "import os,time; os.write(1,b'x'); time.sleep(30)"], timeout=2, read_stdout=True) as process:
                self.assertEqual(process.read_exact(1), b"x")
                raise ValueError("caller_error")
        self.assert_reaped(process, start)

    def test_child_exiting_with_inherited_pipe_open_does_not_escape_deadline(self):
        code = "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']); print(p.pid,flush=True)"
        start = time.monotonic()
        with self.assertRaises(ProcessDeadlineError):
            with BoundedProcess([sys.executable, "-c", code], timeout=.3, read_stdout=True) as process:
                pid = b""
                while not pid.endswith(b"\n"):
                    pid += process.read_exact(1)
                process.finish()
        # A reparented zombie is already dead and awaits its OS reaper; it
        # cannot retain descriptors or consume CPU. No running child survives.
        # Group SIGKILL and reaping the already-exited direct child do not
        # synchronize the descendant's final /proc transition. Observe death
        # within the SAME two-second budget; a live survivor still fails.
        deadline = start + 2
        state = "unknown"
        while True:
            if Path("/proc").exists():
                # The production slim image deliberately has no procps package.
                status = Path(f"/proc/{int(pid)}/stat")
                try:
                    state = status.read_text().rsplit(") ", 1)[1].split()[0]
                except (FileNotFoundError, ProcessLookupError):
                    state = None  # the OS reaped it between opening and reading
            else:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                result = subprocess.run(["ps", "-o", "stat=", "-p", str(int(pid))], capture_output=True, timeout=remaining)
                state = result.stdout.strip().decode()[:1] or None
            remaining = deadline - time.monotonic()
            if state in (None, "Z") or remaining <= 0:
                break
            time.sleep(min(.01, remaining))
        self.assertIn(state, (None, "Z"))
        self.assert_reaped(process, start)

    def test_child_with_closed_pipes_still_has_a_bounded_wait(self):
        start = time.monotonic()
        with self.assertRaises(ProcessDeadlineError):
            with BoundedProcess([sys.executable, "-c", "import os,time; os.close(1);os.close(2);time.sleep(30)"], timeout=.25, read_stdout=True) as process:
                process.finish()
        self.assert_reaped(process, start)


if __name__ == "__main__":
    unittest.main()
