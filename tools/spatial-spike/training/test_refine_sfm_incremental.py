"""Synthetic-only D2 tests; never read the room capture or its cached database."""
import importlib.metadata
from contextlib import closing, redirect_stdout
import io
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest

try:
    OFFICIAL = importlib.metadata.version("pycolmap") == "4.2.0"
except importlib.metadata.PackageNotFoundError:
    OFFICIAL = False
if OFFICIAL:
    import numpy as np
    import pycolmap as p
else:
    np = p = None

from prepare_capture import CaptureError, GSPLAT_COMMIT
import refine_sfm as d1
import refine_sfm_incremental as d2


def synthetic(root, frames=12, points=300):
    p.set_random_seed(11)
    database = root / "source.db"
    with p.Database.open(database) as db:
        truth = p.synthesize_dataset(p.SyntheticDatasetOptions(
            num_rigs=1, num_cameras_per_rig=1, num_frames_per_rig=frames,
            num_points3D=points, camera_model_id=p.CameraModelId.PINHOLE,
            camera_params=[600., 600., 320., 240.], camera_width=640, camera_height=480,
            num_points2D_without_point3D=0), db)
    with sqlite3.connect(database) as db:
        for image_id, image in truth.images.items():
            image.name = f"{image_id:06d}.jpg"
            db.execute("UPDATE images SET name=? WHERE image_id=?", (image.name, image_id))
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()
    return truth, database


def synthetic_fixed_cohort(root):
    """Construct a complete artificial capture plus a training-only cached DB."""
    truth, full_db = synthetic(root, frames=153, points=160)
    source, cached = root / "source", root / "cached-d1"
    (source / "images").mkdir(parents=True)
    (source / "sparse/0").mkdir(parents=True)
    (cached / "work").mkdir(parents=True)
    p.synthesize_images(p.SyntheticImageOptions(), truth, source / "images")
    original = d1.subset_model(truth, {im.name for im in truth.images.values()}, p)
    for point in truth.points3D.values():
        original.add_point3D(point.xyz, p.Track(), point.color)
    original.write_binary(source / "sparse/0")
    for name in ("frames.bin", "rigs.bin"):
        (source / "sparse/0" / name).unlink()
    image_hashes = {im.name: d2.file_sha(source / "images" / im.name) for im in truth.images.values()}
    source_report = {"format": "rendprop-posed-gsplat-dataset", "schema_version": 1,
        "gsplat_commit": GSPLAT_COMMIT, "initial_points": 160, "frames": 153,
        "image_sha256": image_hashes,
        "model_sha256": {name: d2.file_sha(source / "sparse/0" / name) for name in d1.MODEL_FILES}}
    d1.write_json(source / "adapter-report.json", source_report)
    train, heldout = d1.fixed_split(image_hashes)
    train_ids = {int(n[:6]) for n in train}
    cache_db = cached / "work/features.db"
    d1.seed_database(d1.subset_model(truth, set(train), p), cache_db, p)
    with closing(sqlite3.connect(full_db)) as src, closing(sqlite3.connect(cache_db)) as dest:
        for table in ("keypoints", "descriptors", "matches", "two_view_geometries"):
            rows = list(src.execute("SELECT * FROM " + table))
            if table in {"keypoints", "descriptors"}:
                selected = [r for r in rows if r[0] in train_ids]
            else:
                selected = [r for r in rows if set(divmod(r[0], 2147483647)) <= train_ids]
            dest.executemany("INSERT INTO " + table + " VALUES (" + ",".join("?" for _ in selected[0]) + ")", selected)
        dest.commit()
        dest.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    d1.write_json(cached / "sfm-report.json", {
        "status": "prepared", "profile": d1.PROFILE,
        "source_model_sha256": source_report["model_sha256"],
        "source_adapter_report_sha256": d2.file_sha(source / "adapter-report.json"),
        "training_images": train, "evaluation_images": heldout, "heldout_pixels_used_by_sfm": False})
    return source, cached


@unittest.skipUnless(OFFICIAL, "requires separate official pycolmap==4.2.0 environment")
class IncrementalSfmTests(unittest.TestCase):
    def test_complete_synthetic_cohort_supervisor_export_and_input_integrity(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d2-full-synthetic-") as directory:
            root = Path(directory)
            source, cached = synthetic_fixed_cohort(root)
            expected = d2.validate_inputs(source, cached)[-1]
            output = root / "output"
            with redirect_stdout(io.StringIO()):
                code = d2.main(["--dataset", str(source), "--cached-sfm", str(cached),
                               "--output", str(output), "--max-seconds", "60", "--execute"])
            if code:
                self.fail((output / "sfm.log").read_text()[-5000:])
            report = d1.read_json(output / "sfm-report.json")
            run = d1.read_json(output / "sfm-run.json")
            self.assertEqual((report["status"], run["status"]), ("prepared", "prepared"))
            self.assertEqual(len(report["registered_training_ids"]), 133)
            self.assertEqual(report["original_pose_fallback_ids"], [])
            self.assertEqual(report["unregistered_training_ids"], [])
            self.assertEqual(report["missing_from_selected_model_ids"], [])
            self.assertEqual(report["registered_in_other_models_ids"], [])
            self.assertFalse(report["scene_quality_accepted"])
            self.assertEqual(report["quality_status"], "unknown")
            self.assertLess(run["elapsed_seconds"], 60.)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual(d2.validate_inputs(source, cached)[-1], expected)
            original = d2.validate_dataset(source, 500000)
            derived = d2.validate_dataset(output / "dataset", 500000)
            self.assertEqual(original["image_sha256"], derived["image_sha256"])
            before = d1.image_records(source / "sparse/0/images.bin")
            after = d1.image_records(output / "dataset/sparse/0/images.bin")
            self.assertEqual(set(before), set(after))
            for image_id in range(1, 154, 8):
                self.assertEqual(before[image_id], after[image_id])

    def test_actual_registration_recovers_noisy_pose_case_from_cached_correspondences(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d2-synthetic-") as directory:
            root = Path(directory)
            truth, source_db = synthetic(root)
            noisy = p.Reconstruction(truth)
            p.synthesize_noise(p.SyntheticNoiseOptions(
                rig_from_world_rotation_stddev=8., rig_from_world_translation_stddev=.1,
                point3D_stddev=0.), noisy)
            images, work = root / "images", root / "work"
            images.mkdir()
            work.mkdir()
            p.synthesize_images(p.SyntheticImageOptions(), truth, images)
            expected = {i: im.name for i, im in truth.images.items()}
            inventory = d2.cache_inventory(source_db, expected)
            database = work / "features.db"
            shutil.copyfile(source_db, database)
            self.assertEqual(d2.file_sha(database), inventory["database_sha256"])
            model, receipt = d2.register_cached(database, images, work, expected.values(), p)
            self.assertEqual(set(model.reg_image_ids()), set(truth.images))
            self.assertEqual(model.num_points3D(), 300)
            self.assertEqual(model.compute_num_observations(), 3600)
            self.assertLess(d1.reprojection_rmse(model), 0.001)
            self.assertFalse(receipt["options"]["ba_use_gpu"])
            self.assertFalse(receipt["options"]["use_prior_position"])
            self.assertFalse(receipt["options"]["mapper"]["abs_pose_refine_focal_length"])
            self.assertEqual(receipt["options"]["random_seed"], 0)
            for camera_id, camera in model.cameras.items():
                np.testing.assert_array_equal(camera.params, truth.cameras[camera_id].params)

            # Same cached observations, but D1's known-pose triangulation stage
            # starts from noisy ARKit-like poses and cannot register them anew.
            known_db = root / "known.db"
            shutil.copyfile(source_db, known_db)
            known = d1.subset_model(noisy, set(expected.values()), p)
            initial = {i: im.cam_from_world().matrix().copy() for i, im in known.images.items()}
            fixed = p.triangulate_points(known, known_db, images, root / "known-triangulated",
                clear_points=True, options=d2.mapping_options(expected.values(), p), refine_intrinsics=False)
            self.assertLess(fixed.compute_num_observations(), model.compute_num_observations() * 0.5)
            for image_id in fixed.images:
                np.testing.assert_allclose(fixed.images[image_id].cam_from_world().matrix(), initial[image_id], atol=1e-12)

            alignment = d2.align_registered(model, noisy, p)
            self.assertGreaterEqual(len(alignment["inlier_ids"]), 6)
            ba = d1.pose_prior_ba(model, noisy, p)
            self.assertLess(ba["reprojection_rmse_after_px"], 0.1)
            self.assertEqual(d2.cache_inventory(source_db, expected), inventory)

    def test_cache_rejects_excluded_images_dirty_wal_and_malformed_matches(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d2-cache-synthetic-") as directory:
            root = Path(directory)
            truth, database = synthetic(root)
            expected = {i: im.name for i, im in truth.images.items()}
            self.assertGreater(d2.cache_inventory(database, expected)["pairs_with_inliers"], 0)
            with self.assertRaisesRegex(CaptureError, "exactly the training cohort"):
                d2.cache_inventory(database, {i: n for i, n in expected.items() if i != 1})
            wal = database.with_name(database.name + "-wal")
            wal.write_bytes(b"not checkpointed")
            with self.assertRaisesRegex(CaptureError, "uncheckpointed WAL"):
                d2.cache_inventory(database, expected)
            wal.unlink()
            with sqlite3.connect(database) as db:
                db.execute("UPDATE two_view_geometries SET rows=rows+1 WHERE pair_id=(SELECT MIN(pair_id) FROM two_view_geometries)")
            db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            db.close()
            with self.assertRaisesRegex(CaptureError, "malformed cached correspondence"):
                d2.cache_inventory(database, expected)

    def test_robust_alignment_rejects_one_bad_position_prior_and_collinear_gauge(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d2-alignment-synthetic-") as directory:
            truth, _ = synthetic(Path(directory))
            reference = p.Reconstruction(truth)
            image = reference.images[1]
            image.frame.rig_from_world = p.Rigid3d(image.cam_from_world().rotation,
                                                 image.cam_from_world().translation + np.array([20., 0., 0.]))
            model = p.Reconstruction(truth)
            model.transform(p.Sim3d(1.7, p.Rotation3d([.1, .2, -.3]), [2., -.4, 3.]))
            receipt = d2.align_registered(model, reference, p)
            self.assertEqual(set(receipt["inlier_ids"]), set(truth.images) - {1})
            self.assertLess(receipt["position_error_median_m"], 1e-8)
            self.assertGreater(receipt["position_error_max_m"], 10.)
            for i, image in reference.images.items():
                image.frame.rig_from_world = p.Rigid3d(p.Rotation3d(), [-float(i), 0., 0.])
            with self.assertRaisesRegex(CaptureError, "do not anchor"):
                d2.align_registered(model, reference, p)

    def test_missing_camera_fails_closed_or_exports_explicit_bit_exact_fallback(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d2-fallback-synthetic-") as directory:
            root = Path(directory)
            truth, _ = synthetic(root)
            original = p.Reconstruction(truth)
            for image_id in (20, 25):
                original.add_image_with_trivial_frame(
                    p.Image(image_id=image_id, camera_id=1, name=f"{image_id:06d}.jpg"),
                    p.Rigid3d(p.Rotation3d([.1, .2, -.05]), [.17, -.4, 1.3]))
            training_ids = set(truth.images) | {20}
            with self.assertRaisesRegex(CaptureError, "fallback was not authorized"):
                d2.complete_cohort(truth, original, training_ids, p)
            self.assertNotIn(20, truth.images)
            fallback = d2.complete_cohort(truth, original, training_ids, p, allow_fallback=True)
            self.assertEqual(fallback, [20])
            self.assertEqual(truth.images[20].num_points3D, 0)
            source, target, work = root / "source", root / "target", root / "export"
            (source / "sparse/0").mkdir(parents=True)
            work.mkdir()
            original.write_binary(source / "sparse/0")
            d2.export_preserving_fallback(truth, original, source, target, {"000025.jpg"}, fallback, work, p)
            before = d1.image_records(source / "sparse/0/images.bin")
            after = d1.image_records(target / "sparse/0/images.bin")
            self.assertEqual(set(before), set(after))
            for image_id in (20, 25):
                self.assertEqual(before[image_id], after[image_id])
            reloaded = p.Reconstruction(target / "sparse/0")
            self.assertTrue(all(element.image_id not in {20, 25} for point in reloaded.points3D.values()
                                for element in point.track.elements))

    def test_private_disjoint_paths_and_timeout_ceiling(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d2-paths-synthetic-") as directory:
            root = Path(directory)
            data, cache = root / "data", root / "cache"
            for output in (data / "output", cache / "output", root):
                with self.assertRaisesRegex(CaptureError, "disjoint"):
                    d2.validate_paths(data, cache, output)
            repository = root / "repo"
            repository.mkdir()
            (repository / ".git").write_text("gitdir: synthetic\n")
            with self.assertRaisesRegex(CaptureError, "outside Git"):
                d2.validate_paths(data, cache, repository / "output")
            d2.validate_paths(data, cache, root / "private-output")
        for seconds in (0, 1801):
            self.assertEqual(d2.main(["--dataset", "/missing-data", "--cached-sfm", "/missing-cache",
                "--output", "/missing-output", "--max-seconds", str(seconds)]), 1)

    def test_calibration_guard_rejects_dimensions_and_focal_changes(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d2-calibration-synthetic-") as directory:
            original, _ = synthetic(Path(directory))
            camera = p.Camera(original.cameras[1].todict())
            d2.require_original_calibration(camera, original, p)
            camera.width += 1
            with self.assertRaisesRegex(CaptureError, "changed fixed camera calibration"):
                d2.require_original_calibration(camera, original, p)
            camera = p.Camera(original.cameras[1].todict())
            camera.params = [601., 600., 320., 240.]
            with self.assertRaisesRegex(CaptureError, "changed fixed camera calibration"):
                d2.require_original_calibration(camera, original, p)


if __name__ == "__main__":
    unittest.main()
