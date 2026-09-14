"""Synthetic-only D1 tests. Run with the separate official pycolmap 4.2.0 venv."""
import importlib.metadata
from pathlib import Path
import struct
import tempfile
import unittest

try:
    OFFICIAL_PYCOLMAP = importlib.metadata.version("pycolmap") == "4.2.0"
except importlib.metadata.PackageNotFoundError:
    OFFICIAL_PYCOLMAP = False

# Do not import gsplat's unrelated pycolmap 0.0.1 model-reader package.
# Its optional dependencies must not prevent ordinary trainer test discovery.
if OFFICIAL_PYCOLMAP:
    import numpy as np
    import pycolmap as p
    OFFICIAL_PYCOLMAP = getattr(p, "__version__", None) == "4.2.0"
else:
    np = p = None

from prepare_capture import CaptureError
import refine_sfm as sfm


def synthetic_model(frames=6, points=160):
    p.set_random_seed(7)
    options = p.SyntheticDatasetOptions(num_rigs=1, num_cameras_per_rig=1,
        num_frames_per_rig=frames, num_points3D=points, camera_width=640, camera_height=480,
        camera_model_id=p.CameraModelId.PINHOLE, camera_params=[600., 600., 320., 240.],
        num_points2D_without_point3D=0)
    model = p.synthesize_dataset(options)
    for image_id, image in model.images.items():
        image.name = f"{image_id:06d}.jpg"
    return model


@unittest.skipUnless(OFFICIAL_PYCOLMAP,
                     "SfM suite requires the separate official pycolmap==4.2.0 environment")
class SfmTests(unittest.TestCase):
    def test_exact_original_cohort_and_holdout(self):
        names = [f"{i:06d}.jpg" for i in range(1, 154)]
        train, heldout = sfm.fixed_split(reversed(names))
        self.assertEqual((len(train), len(heldout)), (133, 20))
        self.assertEqual(heldout, [f"{i:06d}.jpg" for i in range(1, 154, 8)])
        self.assertFalse(set(train) & set(heldout))
        for bad in (names[:-1], names + names[:1], [*names[:-1], "other.jpg"]):
            with self.assertRaises(CaptureError):
                sfm.fixed_split(bad)

    def test_pair_list_is_deterministic_bounded_and_excludes_holdout(self):
        train, heldout = sfm.fixed_split([f"{i:06d}.jpg" for i in range(1, 154)])
        centers = {int(name[:6]): np.array([int(name[:6]) % 11, int(name[:6]) // 11, 0.]) for name in train}
        pairs = sfm.deterministic_pairs(centers)
        self.assertEqual(pairs, sfm.deterministic_pairs(dict(reversed(list(centers.items())))))
        self.assertEqual(pairs, sorted(set(pairs)))
        self.assertLessEqual(len(pairs), 20 * 133)
        self.assertTrue(all(a < b and a in centers and b in centers for a, b in pairs))
        self.assertEqual({i for pair in pairs for i in pair}, set(centers))
        self.assertFalse({int(name[:6]) for name in heldout} & {i for pair in pairs for i in pair})

    def test_subsetting_removes_all_original_seed_tracks_and_points(self):
        original = synthetic_model()
        subset = sfm.subset_model(original, {"000002.jpg", "000004.jpg", "000006.jpg"}, p)
        self.assertEqual(set(subset.images), {2, 4, 6})
        self.assertEqual(subset.num_points3D(), 0)
        for image in subset.images.values():
            self.assertEqual(image.num_points2D(), 0)
            np.testing.assert_array_equal(image.cam_from_world().matrix(), original.images[image.image_id].cam_from_world().matrix())
        self.assertEqual(original.num_points3D(), 160)

    def test_actual_pose_prior_ba_improves_perturbed_synthetic_geometry(self):
        truth = synthetic_model()
        refined = p.Reconstruction(truth)
        p.synthesize_noise(p.SyntheticNoiseOptions(rig_from_world_translation_stddev=0.015,
            rig_from_world_rotation_stddev=0.35, point3D_stddev=0.01,
            prior_position_stddev=0., prior_gravity_stddev=0.), refined)
        original_k = refined.cameras[1].params.copy()
        before = sfm.reprojection_rmse(refined)
        noisy_poses = {i: image.cam_from_world().matrix().copy() for i, image in refined.images.items()}
        result = sfm.pose_prior_ba(refined, truth, p)
        self.assertGreater(before, 0.1)
        self.assertLess(result["reprojection_rmse_after_px"], before * 0.01)
        self.assertTrue(any(np.max(np.abs(image.cam_from_world().matrix() - noisy_poses[i])) > 0.001
                            for i, image in refined.images.items()))
        self.assertLess(result["rotation_change_max_deg"], 0.01)
        self.assertLess(result["position_change_max_m"], 0.01)
        np.testing.assert_array_equal(refined.cameras[1].params, original_k)
        self.assertEqual(result["num_residuals"], 160 * 6 * 2 + 6 * 3)

    def test_export_preserves_heldout_record_bits_and_training_point_tracks(self):
        trained = synthetic_model()
        original = p.Reconstruction(trained)
        for image_id in (7, 9):
            original.add_image_with_trivial_frame(p.Image(image_id=image_id, camera_id=1,
                name=f"{image_id:06d}.jpg"), p.Rigid3d(p.Rotation3d([0.1, 0.2, -0.05]), [0.17, -0.4, 1.3]))
        with tempfile.TemporaryDirectory(prefix="sfm-synthetic-export-") as directory:
            root = Path(directory)
            source, target, work = root / "source", root / "target", root / "work"
            (source / "sparse/0").mkdir(parents=True)
            work.mkdir()
            original.write_binary(source / "sparse/0")
            heldout = {"000007.jpg", "000009.jpg"}
            sfm.export_legacy(trained, original, source, target, heldout, work, p)
            sparse = target / "sparse/0"
            self.assertEqual({file.name for file in sparse.iterdir()}, set(sfm.MODEL_FILES))
            before = sfm.image_records(source / "sparse/0/images.bin")
            after = sfm.image_records(sparse / "images.bin")
            for image_id in (7, 9):
                self.assertEqual(after[image_id], before[image_id])
            self.assertEqual((sparse / "cameras.bin").read_bytes(), (source / "sparse/0/cameras.bin").read_bytes())
            # Parse classic points format independently, including real tracks.
            data = (sparse / "points3D.bin").read_bytes()
            count, = struct.unpack_from("<Q", data)
            self.assertEqual(count, 160)
            offset = 8
            for _ in range(count):
                row = struct.unpack_from("<Q3d3BdQ", data, offset)
                track_length = row[-1]
                self.assertEqual(track_length, 6)
                offset += 51
                for _ in range(track_length):
                    image_id, _ = struct.unpack_from("<II", data, offset)
                    self.assertIn(image_id, range(1, 7))
                    offset += 8
            self.assertEqual(offset, len(data))
            (root / "bad-work").mkdir()
            with self.assertRaisesRegex(CaptureError, "heldout camera entered"):
                sfm.export_legacy(trained, original, source, root / "bad", {"000001.jpg"}, root / "bad-work", p)

    def test_actual_cpu_sift_matching_and_known_pose_triangulation(self):
        truth = synthetic_model(points=250)
        # A short translated arc gives actual patch overlap. The library's
        # default synthetic cameras orbit the entire object, which is unsuitable
        # for matching its screen-aligned synthetic feature patches.
        anchor = p.Rigid3d(truth.images[1].cam_from_world().matrix())
        for image_id, image in truth.images.items():
            image.frame.rig_from_world = p.Rigid3d(anchor.rotation,
                anchor.translation + np.array([(image_id - 3.5) * 0.15, np.sin(image_id) * 0.04, 0.]))
            for observation in image.points2D:
                observation.xy = image.project_point(truth.points3D[observation.point3D_id].xyz)
        with tempfile.TemporaryDirectory(prefix="sfm-synthetic-features-") as directory:
            root = Path(directory)
            images, work = root / "images", root / "work"
            images.mkdir()
            work.mkdir()
            p.synthesize_images(p.SyntheticImageOptions(feature_peak_radius=2, feature_patch_radius=7), truth, images)
            posed = sfm.subset_model(truth, {image.name for image in truth.images.values()}, p)
            record = {}
            result = sfm.feature_triangulation(posed, images, work, p, record)
            self.assertGreater(record["verified_pairs"], 0)
            self.assertTrue(all(count > 0 for count in record["keypoints_by_image"].values()))
            self.assertGreater(result.num_points3D(), 5)
            self.assertGreater(result.compute_num_observations(), result.num_points3D() * 2)
            self.assertEqual(record["pair_count"], 15)
            self.assertEqual(set(result.images), set(truth.images))

    def test_cli_rejects_unbounded_timeout_before_processing(self):
        for seconds in (0, 1801):
            self.assertEqual(sfm.main(["--dataset", "/nonexistent", "--output", "/also-nonexistent", "--max-seconds", str(seconds)]), 1)


if __name__ == "__main__":
    unittest.main()
