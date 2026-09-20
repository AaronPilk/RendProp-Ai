"""D4 synthetic-only tests. Never read a customer capture or contact a provider."""
from contextlib import closing, redirect_stdout
import io
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import refine_sfm as d1
import refine_sfm_incremental as d2
import refine_sfm_expanded_pairs as d3
import refine_sfm_calibrated as d4
from prepare_capture import CaptureError
import test_refine_sfm_incremental as fixture


def zero_focal_flags(database):
    with closing(sqlite3.connect(database)) as db:
        db.execute("UPDATE cameras SET prior_focal_length=0")
        db.commit()
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")


def full_d3_fixture(root):
    """153 artificial images,133 per-image cameras, exactly584883 raw matches."""
    import numpy as np
    p = fixture.p
    source, old_cached = fixture.synthetic_fixed_cohort(root)
    old = p.Reconstruction(source / "sparse/0")
    original = p.Reconstruction()
    for i, image in old.images.items():
        camera = p.Camera(camera_id=i, model=p.CameraModelId.PINHOLE, width=image.camera.width,
                          height=image.camera.height, params=image.camera.params)
        original.add_camera_with_trivial_rig(camera)
        original.add_image_with_trivial_frame(p.Image(image_id=i, camera_id=i, name=image.name), image.cam_from_world())
    for point in old.points3D.values():
        original.add_point3D(point.xyz, p.Track(), point.color)
    original.write_binary(source / "sparse/0")
    for name in ("rigs.bin", "frames.bin"):
        (source / "sparse/0" / name).unlink()
    adapter = d1.read_json(source / "adapter-report.json")
    adapter["model_sha256"] = {n: d2.file_sha(source / "sparse/0" / n) for n in d1.MODEL_FILES}
    d1.write_json(source / "adapter-report.json", adapter)
    train, heldout = d1.fixed_split(adapter["image_sha256"])
    cached = root / "d3"
    work = cached / "work"
    work.mkdir(parents=True)
    database = work / "features.db"
    d1.seed_database(d1.subset_model(original, set(train), p), database, p)
    pair_count = 8778
    extra = d4.PROFILE["raw_correspondences"] - pair_count * 66
    with closing(sqlite3.connect(old_cached / "work/features.db")) as before, closing(sqlite3.connect(database)) as after:
        for table in ("keypoints", "descriptors", "matches", "two_view_geometries"):
            rows = list(before.execute(f'SELECT * FROM "{table}" ORDER BY 1'))
            if table in ("matches", "two_view_geometries"):
                transformed = []
                for index, row in enumerate(rows):
                    row = list(row)
                    size = 67 if index < extra else 66
                    matches = np.frombuffer(row[3], dtype="<u4").reshape(-1, 2)
                    selected = np.roll(matches, index % len(matches), axis=0)[:size].copy()
                    row[1], row[3] = size, selected.tobytes()
                    transformed.append(row)
                rows = transformed
            after.executemany(f'INSERT INTO "{table}" VALUES ({",".join("?" for _ in rows[0])})', rows)
        after.commit()
        after.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    zero_focal_flags(database)
    names = {int(n[:6]): n for n in train}
    pairfile = work / "matched-pairs.txt"
    pairfile.write_text("".join(f"{names[a]} {names[b]}\n" for a, b in d3.all_pairs(names)))
    report = {"status": "prepared", "profile": d3.PROFILE,
        "source_sha256": {n: d2.file_sha(Path(d3.__file__).with_name(n)) for n in d3.SOURCE_FILES},
        "source_model_sha256": adapter["model_sha256"], "source_image_sha256": adapter["image_sha256"],
        "source_adapter_report_sha256": d2.file_sha(source / "adapter-report.json"),
        "training_images": train, "evaluation_images": heldout, "heldout_pixels_used_by_sfm": False,
        "original_arkit_seeds_used": False, "copied_database_sha256": d2.file_sha(database),
        "matching": {"after_tables": d3.database_tables(database), "pair_list_sha256": d2.file_sha(pairfile)}}
    d1.write_json(cached / "sfm-report.json", report)
    d1.write_json(cached / "sfm-run.json", {"status": "prepared", "profile": d3.PROFILE, "execute": True})
    return source, cached


@unittest.skipUnless(fixture.OFFICIAL, "requires separate official pycolmap==4.2.0 environment")
class CalibratedSfmTests(unittest.TestCase):
    def test_actual_reverification_refreshes_geometry_preserves_raw_and_changes_only_flag(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d4-cache-synthetic-") as directory:
            root = Path(directory)
            model, source = fixture.synthetic(root)
            zero_focal_flags(source)
            with closing(sqlite3.connect(source)) as db:
                db.execute("UPDATE two_view_geometries SET config=77")
                db.commit()
                db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            original_sha = d2.file_sha(source)
            expected = {i: im.name for i, im in model.images.items()}
            output = root / "new.db"
            with patch.object(fixture.p, "extract_features", side_effect=AssertionError("no extraction")):
                receipt = d4.reverify_cached(source, output, root / "pairs.txt", expected, fixture.p)
            self.assertEqual(d2.file_sha(source), original_sha)
            self.assertEqual(receipt["changed_camera_flags"], 1 if len(model.cameras) == 1 else len(expected))
            self.assertEqual(receipt["before"]["raw_correspondences"], receipt["after"]["raw_correspondences"])
            self.assertEqual(receipt["before_tables"]["tables"]["matches"], receipt["after_tables"]["tables"]["matches"])
            self.assertNotIn("77", receipt["after"]["positive_geometry_configs"])
            self.assertIn("2", receipt["after"]["positive_geometry_configs"])

    def test_protected_feature_match_and_numeric_camera_mutations_fail(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d4-tamper-synthetic-") as directory:
            root = Path(directory)
            model, source = fixture.synthetic(root)
            zero_focal_flags(source)
            expected = {i: im.name for i, im in model.images.items()}
            before = d3.database_tables(source)
            target = root / "copied.db"
            for statement in ("UPDATE keypoints SET data=zeroblob(LENGTH(data))", "UPDATE matches SET data=zeroblob(LENGTH(data))",
                              "UPDATE cameras SET width=width+1", "UPDATE cameras SET prior_focal_length=2"):
                shutil.copyfile(source, target)
                with closing(sqlite3.connect(target)) as db:
                    db.execute("UPDATE cameras SET prior_focal_length=1")
                    db.execute(statement)
                    db.commit()
                    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                with self.subTest(statement=statement), self.assertRaises(CaptureError):
                    d4.verify_protected_tables(source, target, before, d3.database_tables(target), expected)

    def test_pose_boundaries_and_earlier_stage_rejections_cannot_be_hidden(self):
        import numpy as np
        p = fixture.p
        with tempfile.TemporaryDirectory(prefix="sfm-d4-pose-synthetic-") as directory:
            original, _ = fixture.synthetic(Path(directory))
            original.images[2].frame.rig_from_world = p.Rigid3d()
            ids = set(original.images)
            clean = d4.pose_stage(original, original, ids, "aligned")
            self.assertFalse(clean["rotation_rejection_ids"])
            for distance, rejected in ((1., False), (1.000001, True)):
                model = p.Reconstruction(original)
                image = model.images[2]
                center = image.projection_center() + np.array([distance, 0., 0.])
                image.frame.rig_from_world = p.Rigid3d(image.cam_from_world().rotation, -image.cam_from_world().rotation.matrix() @ center)
                result = d4.pose_stage(model, original, ids, "aligned")
                self.assertEqual(2 in result["position_rejection_ids"], rejected)
            for angle, rejected in ((89.999999, False), (90., True), (90.000001, True), (180., True)):
                model = p.Reconstruction(original)
                image = model.images[2]
                rotation = p.Rotation3d(np.array([0., 0., math.radians(angle)])) * image.cam_from_world().rotation
                image.frame.rig_from_world = p.Rigid3d(rotation, -rotation.matrix() @ image.projection_center())
                result = d4.pose_stage(model, original, ids, "aligned")
                self.assertEqual(2 in result["rotation_rejection_ids"], rejected)
            stages = [d4.pose_stage(original, original, ids, name, name != "registered_unaligned") for name in
                      ("registered_unaligned", "aligned", "after_ba", "after_filtering", "exported")]
            self.assertTrue(d4.admission(stages)["passed"])
            stages[1] = result
            self.assertFalse(d4.admission(stages)["passed"])
            self.assertFalse(d4.admission(stages)["gpu_authorized"])
            with self.assertRaises(CaptureError):
                d4.admission(stages[1:])
            invalid = p.Reconstruction(original)
            invalid.points3D[next(iter(invalid.points3D))].xyz = np.array([float("nan"), 0., 0.])
            with self.assertRaisesRegex(CaptureError, "nonfinite"):
                d4.pose_stage(invalid, original, ids, "aligned")

    def test_missing_and_zero_observation_fallback_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d4-coverage-synthetic-") as directory:
            original, _ = fixture.synthetic(Path(directory))
            ids = set(original.images)
            stripped = d1.subset_model(original, {im.name for i, im in original.images.items() if i != 2}, fixture.p)
            missing = d4.pose_stage(stripped, original, ids, "aligned")
            self.assertEqual(missing["missing_ids"], [2])
            d2.complete_cohort(stripped, original, ids, fixture.p, True)
            restored = d4.pose_stage(stripped, original, ids, "exported")
            self.assertIn(2, restored["zero_observation_ids"])

    def test_full_fixed_cohort_worker_preserves_all_source_bytes(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d4-full-synthetic-") as directory:
            root = Path(directory)
            source, cached = full_d3_fixture(root)
            binding = d4.validate_inputs(source, cached)[-1]
            output = root / "output"
            with redirect_stdout(io.StringIO()):
                code = d4.main(["--dataset", str(source), "--cached-sfm", str(cached), "--output", str(output),
                                "--max-seconds", "90", "--execute"])
            if code:
                self.fail((output / "sfm.log").read_text()[-3000:])
            self.assertEqual(d4.validate_inputs(source, cached)[-1], binding)
            report = d1.read_json(output / "sfm-report.json")
            self.assertEqual(report["status"], "cpu_preflight_passed")
            self.assertEqual(report["reverification"]["changed_camera_flags"], 133)
            self.assertEqual(report["reverification"]["after"]["raw_correspondences"], 584883)
            self.assertEqual(len(report["registered_training_ids"]), 133)
            self.assertTrue(report["cpu_admission"]["passed"])
            self.assertFalse(report["cpu_admission"]["quality_accepted"])
            before = d1.image_records(source / "sparse/0/images.bin")
            after = d1.image_records(output / "dataset/sparse/0/images.bin")
            for i in range(1, 154, 8):
                self.assertEqual(before[i], after[i])
            self.assertEqual(d4.validate_dataset(output / "dataset", 500000)["image_sha256"],
                             d4.validate_dataset(source, 500000)["image_sha256"])

    def test_changed_source_receipt_or_evaluation_cohort_fails_before_worker(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d4-input-synthetic-") as directory:
            source, cached = full_d3_fixture(Path(directory))
            original = d1.read_json(cached / "sfm-report.json")
            for key, value in (("source_adapter_report_sha256", "0" * 64), ("evaluation_images", []),
                               ("source_sha256", {}), ("copied_database_sha256", "0" * 64)):
                d1.write_json(cached / "sfm-report.json", {**original, key: value})
                with self.subTest(key=key), self.assertRaises(CaptureError):
                    d4.validate_inputs(source, cached)
            d1.write_json(cached / "sfm-report.json", original)
            d4.validate_inputs(source, cached)

    def test_completed_rotation_rejection_never_promotes_adapter(self):
        import numpy as np
        p = fixture.p
        with tempfile.TemporaryDirectory(prefix="sfm-d4-rejected-synthetic-") as directory:
            root = Path(directory)
            source, cached = full_d3_fixture(root)
            # Only this artificial source's ARKit orientation disagrees with its
            # exact synthetic correspondences. Registration still runs in full.
            original = p.Reconstruction(source / "sparse/0")
            image = original.images[2]
            rotation = p.Rotation3d(np.array([0., 0., math.pi])) * image.cam_from_world().rotation
            image.frame.rig_from_world = p.Rigid3d(rotation, -rotation.matrix() @ image.projection_center())
            original.write_binary(source / "sparse/0")
            for name in ("rigs.bin", "frames.bin"):
                (source / "sparse/0" / name).unlink()
            adapter = d1.read_json(source / "adapter-report.json")
            adapter["model_sha256"] = {n: d2.file_sha(source / "sparse/0" / n) for n in d1.MODEL_FILES}
            d1.write_json(source / "adapter-report.json", adapter)
            report = d1.read_json(cached / "sfm-report.json")
            report.update(source_model_sha256=adapter["model_sha256"],
                          source_adapter_report_sha256=d2.file_sha(source / "adapter-report.json"))
            d1.write_json(cached / "sfm-report.json", report)
            output = root / "output"
            with redirect_stdout(io.StringIO()):
                code = d4.main(["--dataset", str(source), "--cached-sfm", str(cached), "--output", str(output),
                                "--max-seconds", "90", "--execute"])
            self.assertEqual(code, 2, (output / "sfm.log").read_text()[-2000:])
            result = d1.read_json(output / "sfm-report.json")
            self.assertEqual(result["status"], "cpu_rejected")
            self.assertIn(2, result["pose_stages"][1]["rotation_rejection_ids"])
            self.assertFalse(result["cpu_admission"]["passed"])
            self.assertTrue((output / "dataset/adapter-report.pending.json").is_file())
            self.assertFalse((output / "dataset/adapter-report.json").exists())

    def test_clean_environment_network_denial_and_timeout(self):
        with patch.dict(os.environ, {"MODAL_TOKEN_SECRET": "synthetic-secret", "AWS_ACCESS_KEY_ID": "synthetic",
                                     "PYTHONPATH": "/synthetic/injection"}):
            env = d4.clean_environment()
        self.assertNotIn("MODAL_TOKEN_SECRET", env)
        self.assertNotIn("AWS_ACCESS_KEY_ID", env)
        self.assertNotIn("PYTHONPATH", env)
        self.assertNotIn("HOME", env)
        probe = "import socket\ns=socket.socket()\ntry:s.connect(('127.0.0.1',9))\nexcept PermissionError:print('denied')\n"
        result = subprocess.run(["/usr/bin/sandbox-exec", "-p", d4.SANDBOX_PROFILE, sys.executable, "-c", probe],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "denied")
        with tempfile.TemporaryDirectory(prefix="sfm-d4-timeout-synthetic-") as directory:
            root = Path(directory)
            source, cached = full_d3_fixture(root)
            output = root / "output"
            with redirect_stdout(io.StringIO()):
                code = d4.main(["--dataset", str(source), "--cached-sfm", str(cached), "--output", str(output),
                                "--max-seconds", "1", "--execute"])
            self.assertEqual(code, 1)
            self.assertEqual(d1.read_json(output / "sfm-run.json")["status"], "failed")
            self.assertFalse((output / "dataset/adapter-report.json").exists())


if __name__ == "__main__":
    unittest.main()
