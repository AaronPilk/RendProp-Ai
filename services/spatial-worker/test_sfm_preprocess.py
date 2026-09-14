"""Inactive SfM stage: lifecycle tests everywhere, geometry only in official venv.

All images here are synthesized. Nothing reads a room capture, provisions a
provider, uploads files, or claims image quality from the synthetic fixture.
"""
import importlib.metadata
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import sfm_preprocess as stage
from run_training import GSPLAT_COMMIT

try:
    OFFICIAL = importlib.metadata.version("pycolmap") == "4.2.0"
except importlib.metadata.PackageNotFoundError:
    OFFICIAL = False
if OFFICIAL:
    import numpy as np
    import pycolmap as p
    OFFICIAL = getattr(p, "__version__", None) == "4.2.0"
else:
    np = p = None


def names(count):
    return [f"{i:06d}.jpg" for i in range(1, count + 1)]


def write_report(source, count, points=250):
    report = {"format": "rendprop-posed-gsplat-dataset", "schema_version": 1,
        "gsplat_commit": GSPLAT_COMMIT,
        "session_id": "synthetic-only", "frames": count, "initial_points": points,
        "world_space": "synthetic Cartesian metres", "camera_conversion": "synthetic world-to-camera",
        "image_sha256": {name: stage.frozen.sha256(source / "images" / name) for name in names(count)},
        "model_sha256": {name: stage.frozen.sha256(source / "sparse/0" / name) for name in stage.frozen.MODEL_FILES}}
    stage.frozen.write_json(source / "adapter-report.json", report)
    return report


def fingerprinted_stub(source, count=20):
    """Hash-valid inputs for prelaunch/lifecycle guards; never geometry input."""
    (source / "images").mkdir(parents=True)
    (source / "sparse/0").mkdir(parents=True)
    for name in names(count):
        (source / "images" / name).write_bytes(b"not a real image: guard fixture only")
    for name in stage.frozen.MODEL_FILES:
        (source / "sparse/0" / name).write_bytes(b"not a model: guard fixture only")
    return write_report(source, count)


class ProtocolTests(unittest.TestCase):
    def test_verification_rows_distinguish_positive_inliers_without_mutating_frozen_record(self):
        with tempfile.TemporaryDirectory(prefix="sfm-count-test-") as directory:
            database = Path(directory) / "features.db"
            with sqlite3.connect(database) as connection:
                connection.execute('CREATE TABLE two_view_geometries (pair_id INTEGER PRIMARY KEY, "rows" INTEGER, config INTEGER)')
                connection.executemany('INSERT INTO two_view_geometries VALUES (?, ?, ?)',
                    [(1, 0, 0), (2, 12, 3), (3, 0, 0), (4, 7, 6)])
            before = stage.frozen.sha256(database)
            self.assertEqual(stage.verification_counts(database),
                             {"verification_row_count": 4, "pairs_with_inliers": 2})
            record = {"status": "running", "verified_pairs": 4}
            snapshot = stage.report_snapshot(record, database)
            self.assertEqual(snapshot, {"status": "running", "verification_row_count": 4, "pairs_with_inliers": 2})
            self.assertEqual(record, {"status": "running", "verified_pairs": 4})
            self.assertEqual(stage.frozen.sha256(database), before)

    def test_all_capture_counts_keep_exact_every_eighth_holdout(self):
        for count in range(20, 401):
            with self.subTest(count=count):
                train, heldout = stage.split_images(reversed(names(count)))
                self.assertEqual(heldout, names(count)[::8])
                self.assertEqual(sorted(train + heldout), names(count))
                self.assertFalse(set(train) & set(heldout))
        self.assertEqual(stage.split_images(names(153)), stage.frozen.fixed_split(names(153)))
        self.assertEqual(tuple(map(len, stage.split_images(names(20)))), (17, 3))
        self.assertEqual(tuple(map(len, stage.split_images(names(400)))), (350, 50))

    def test_cohort_rejects_missing_duplicate_invalid_identity_and_out_of_bounds(self):
        for bad in (names(19), names(401), names(20) + names(20)[:1],
                    [*names(20)[:-1], "000021.jpg"], [*names(20)[:-1], "../000020.jpg"]):
            with self.subTest(bad=bad[-1]), self.assertRaisesRegex(stage.SfmFailure, "capture_cohort"):
                stage.split_images(bad)

    def test_profile_binds_unmodified_geometry_and_separate_cohort(self):
        profile = stage.profile()
        self.assertEqual(profile["algorithm"], stage.frozen.PROFILE)
        self.assertEqual(profile["frozen_helper_sha256"], stage.frozen.sha256(stage.frozen.__file__))
        self.assertTrue(profile["provisional"])
        self.assertNotEqual(profile["name"], stage.frozen.PROFILE["name"])
        self.assertEqual(profile["cohort"], {"min_frames": 20, "max_frames": 400, "test_every": 8})

    def test_child_environment_has_no_inherited_credentials_or_configuration(self):
        with tempfile.TemporaryDirectory(prefix="sfm-env-test-") as directory:
            ambient = {"SUPABASE_SERVICE_ROLE_KEY": "fixture", "MODAL_TOKEN_SECRET": "fixture",
                "AWS_SECRET_ACCESS_KEY": "fixture", "R2_SECRET_ACCESS_KEY": "fixture",
                "PYTHONPATH": "fixture", "HOME": "fixture", "LD_PRELOAD": "fixture"}
            with patch.dict(os.environ, ambient):
                env = stage.child_environment(sys.executable, Path(directory))
            self.assertFalse(set(ambient) & set(env))
            self.assertEqual(env["PATH"].split(os.pathsep)[0], str(Path(sys.executable).absolute().parent))
            self.assertEqual(env["CUDA_VISIBLE_DEVICES"], "")
            self.assertEqual(env["OMP_NUM_THREADS"], "4")
            self.assertEqual(env["TMPDIR"], str(Path(directory).resolve()))

    def test_invalid_timeout_or_overlapping_output_cannot_start_a_child(self):
        with tempfile.TemporaryDirectory(prefix="sfm-admission-test-") as directory:
            root = Path(directory)
            source = root / "source"
            fingerprinted_stub(source)
            with patch.object(stage, "owned_process") as process:
                for timeout in (0, 1801, True, 1.0):
                    with self.assertRaisesRegex(stage.SfmFailure, "invalid_timeout"):
                        stage.preprocess(source, root / "result", python=sys.executable, max_seconds=timeout)
                for output in (source, source / "result", root):
                    with self.assertRaises(stage.SfmFailure):
                        stage.preprocess(source, output, python=sys.executable)
                process.assert_not_called()
            self.assertFalse((root / "result").exists())

    def test_frame_count_mismatch_and_modified_source_fail_before_output(self):
        with tempfile.TemporaryDirectory(prefix="sfm-source-test-") as directory:
            root = Path(directory)
            source = root / "source"
            report = fingerprinted_stub(source)
            report["frames"] = 21
            stage.frozen.write_json(source / "adapter-report.json", report)
            with self.assertRaisesRegex(stage.SfmFailure, "frame_count_mismatch"):
                stage.preprocess(source, root / "result", python=sys.executable)
            self.assertFalse((root / "result").exists())
            report["frames"] = 20
            stage.frozen.write_json(source / "adapter-report.json", report)
            (source / "images/000001.jpg").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "dataset changed"):
                stage.preprocess(source, root / "result", python=sys.executable)
            self.assertFalse((root / "result").exists())

    def test_failed_child_never_leaves_a_completed_dataset_or_retries(self):
        with tempfile.TemporaryDirectory(prefix="sfm-failure-test-") as directory:
            root = Path(directory)
            source, output = root / "source", root / "result"
            fingerprinted_stub(source)
            def failed_child(*args, **kwargs):
                (output / "dataset").mkdir()
                (output / "dataset/adapter-report.json").write_text("{}")
                raise stage.SfmFailure("sfm_timeout")
            with patch.object(stage, "owned_process", side_effect=failed_child) as process:
                with self.assertRaisesRegex(stage.SfmFailure, "sfm_timeout"):
                    stage.preprocess(source, output, python=sys.executable)
                self.assertEqual(process.call_count, 1)
            self.assertFalse((output / "dataset/adapter-report.json").exists())
            receipt = json.loads((output / "sfm-run.json").read_text())
            self.assertEqual(receipt["status"], "failed")
            self.assertEqual(receipt["automatic_retries"], 0)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sfm-process-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = stage.child_environment(sys.executable, self.root)

    def run_child(self, code, timeout=5, **kwargs):
        return stage.owned_process([sys.executable, "-c", code], timeout,
            environment=self.env, logfile=self.root / "child.log", **kwargs)

    def assert_not_running(self, pid):
        # On Linux an orphan killed child can remain a zombie until PID 1 reaps
        # it. That process cannot execute; do not make its reaping our test.
        for _ in range(60):
            result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
            state = result.stdout.strip()
            if not state or state.startswith("Z"):
                return
            time.sleep(.05)
        self.fail(f"owned process {pid} still running")

    def descendant_script(self):
        pidfile = self.root / "pids.json"
        child = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
        code = ("import json,os,subprocess,sys,time; from pathlib import Path; "
                f"child=subprocess.Popen([sys.executable,'-c',{child!r}]); "
                f"Path({str(pidfile)!r}).write_text(json.dumps([os.getpid(),child.pid])); "
                "time.sleep(60)")
        return code, pidfile

    def test_success_clears_cancellation_callback_and_failure_is_reported(self):
        callbacks = []
        seconds = self.run_child("print('synthetic worker complete')", on_abort=callbacks.append)
        self.assertGreater(seconds, 0)
        self.assertEqual(len(callbacks), 2)
        callbacks[-1]()
        self.assertIn("complete", (self.root / "child.log").read_text())
        (self.root / "child.log").unlink()
        with self.assertRaisesRegex(stage.SfmFailure, "child_failed"):
            self.run_child("raise SystemExit(7)")

    def test_timeout_kills_the_leader_and_sigterm_ignoring_descendant(self):
        code, pidfile = self.descendant_script()
        with self.assertRaisesRegex(stage.SfmFailure, "sfm_timeout"):
            self.run_child(code, timeout=1)
        for pid in json.loads(pidfile.read_text()):
            self.assert_not_running(pid)

    def test_heartbeat_thread_abort_kills_owned_group_and_clears_hook(self):
        code, pidfile = self.descendant_script()
        callbacks, threads = [], []
        def register(callback):
            callbacks.append(callback)
            if len(callbacks) == 1:
                def heartbeat():
                    limit = time.monotonic() + 3
                    while not pidfile.exists() and time.monotonic() < limit:
                        time.sleep(.02)
                    callback()
                thread = threading.Thread(target=heartbeat)
                threads.append(thread)
                thread.start()
        try:
            with self.assertRaisesRegex(stage.SfmFailure, "sfm_cancelled"):
                self.run_child(code, on_abort=register)
        finally:
            for thread in threads:
                thread.join(timeout=5)
        self.assertEqual(len(callbacks), 2)
        for pid in json.loads(pidfile.read_text()):
            self.assert_not_running(pid)

    def test_cancellation_before_popen_prevents_creation(self):
        with patch.object(stage.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(stage.SfmFailure, "sfm_cancelled"):
                self.run_child("raise AssertionError('must not start')", on_abort=lambda callback: callback())
            popen.assert_not_called()

    def test_lease_check_exception_cancels_group(self):
        code, pidfile = self.descendant_script()
        def check():
            if pidfile.exists():
                raise RuntimeError("synthetic lease lost")
        with self.assertRaisesRegex(RuntimeError, "lease lost"):
            self.run_child(code, check=check)
        for pid in json.loads(pidfile.read_text()):
            self.assert_not_running(pid)


@unittest.skipUnless(OFFICIAL, "Geometry tests require the separate official pycolmap==4.2.0 venv")
class SyntheticGeometryTests(unittest.TestCase):
    def test_generic_20_frame_stage_uses_real_features_and_preserves_eval_bytes(self):
        p.set_random_seed(7)
        truth = p.synthesize_dataset(p.SyntheticDatasetOptions(num_rigs=1,
            num_cameras_per_rig=1, num_frames_per_rig=20, num_points3D=250,
            camera_width=640, camera_height=480, camera_model_id=p.CameraModelId.PINHOLE,
            camera_params=[600., 600., 320., 240.], num_points2D_without_point3D=0))
        anchor = p.Rigid3d(truth.images[1].cam_from_world().matrix())
        for image_id, image in truth.images.items():
            image.name = f"{image_id:06d}.jpg"
            image.frame.rig_from_world = p.Rigid3d(anchor.rotation,
                anchor.translation + np.array([((image_id % 6) - 2.5) * .15, np.sin(image_id % 6) * .04, 0.]))
            for observation in image.points2D:
                observation.xy = image.project_point(truth.points3D[observation.point3D_id].xyz)
        with tempfile.TemporaryDirectory(prefix="sfm-generic-synthetic-") as directory:
            root = Path(directory)
            source = root / "source"
            images, sparse = source / "images", source / "sparse/0"
            images.mkdir(parents=True)
            sparse.mkdir(parents=True)
            p.synthesize_images(p.SyntheticImageOptions(feature_peak_radius=2, feature_patch_radius=7), truth, images)
            original = stage.frozen.subset_model(truth, set(names(20)), p)
            for point in truth.points3D.values():
                original.add_point3D(point.xyz, p.Track(), point.color)
            original.write_binary(sparse)
            (sparse / "rigs.bin").unlink()
            (sparse / "frames.bin").unlink()
            before = write_report(source, 20)
            before_report_hash = stage.frozen.sha256(source / "adapter-report.json")
            target = stage.preprocess(source, root / "result", python=sys.executable, max_seconds=120)
            after = stage.frozen.validate_dataset(target, 500000)
            receipt = json.loads((root / "result/sfm-report.json").read_text())
            run = json.loads((root / "result/sfm-run.json").read_text())
            self.assertEqual(receipt["status"], "prepared")
            self.assertEqual(run["status"], "prepared")
            self.assertEqual((run["training_frames"], run["evaluation_frames"]), (17, 3))
            self.assertGreater(receipt["pairs_with_inliers"], 0)
            self.assertGreaterEqual(receipt["verification_row_count"], receipt["pairs_with_inliers"])
            self.assertNotIn("verified_pairs", receipt)
            self.assertGreaterEqual(receipt["final_points"], 100)
            self.assertGreater(receipt["final_observations"], receipt["final_points"] * 2)
            self.assertFalse(receipt["heldout_pixels_used_by_sfm"])
            self.assertFalse(receipt["original_arkit_seeds_used"])
            self.assertFalse(receipt["scene_quality_accepted"])
            self.assertEqual(after["image_sha256"], before["image_sha256"])
            self.assertEqual(stage.frozen.validate_dataset(source, 500000), before)
            self.assertEqual(stage.frozen.sha256(source / "adapter-report.json"), before_report_hash)
            self.assertEqual((sparse / "cameras.bin").read_bytes(), (target / "sparse/0/cameras.bin").read_bytes())
            old_records = stage.frozen.image_records(sparse / "images.bin")
            new_records = stage.frozen.image_records(target / "sparse/0/images.bin")
            train, heldout = stage.split_images(names(20))
            for name in heldout:
                self.assertEqual(new_records[int(name[:6])], old_records[int(name[:6])])
            trained = p.Reconstruction(target / "sparse/0")
            train_ids = {int(name[:6]) for name in train}
            self.assertTrue(all(element.image_id in train_ids for point in trained.points3D.values()
                                for element in point.track.elements))
            with p.Database.open(root / "result/work/features.db") as db:
                self.assertEqual({image.image_id for image in db.read_all_images()}, train_ids)

    def test_153_protocol_matches_manual_and_400_pair_selection_excludes_eval(self):
        for count in (20, 153, 400):
            train, heldout = stage.split_images(names(count))
            centers = {int(name[:6]): np.array([int(name[:6]) % 11, int(name[:6]) // 11, 0.]) for name in train}
            pairs = stage.frozen.deterministic_pairs(centers)
            ids = {i for pair in pairs for i in pair}
            self.assertEqual(ids, set(centers))
            self.assertFalse(ids & {int(name[:6]) for name in heldout})
            self.assertLessEqual(len(pairs), len(train) * 20)
            if count == 153:
                manual_train, manual_eval = stage.frozen.fixed_split(names(count))
                self.assertEqual((train, heldout), (manual_train, manual_eval))
                manual_centers = {int(name[:6]): centers[int(name[:6])] for name in manual_train}
                self.assertEqual(pairs, stage.frozen.deterministic_pairs(manual_centers))


if __name__ == "__main__":
    unittest.main()
