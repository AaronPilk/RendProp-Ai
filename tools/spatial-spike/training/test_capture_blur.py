"""Synthetic-only motion-blur gate tests; no customer capture, GPU or network."""
import contextlib
import io
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from PIL import Image, ImageFilter

import capture_blur as blur
import capture_handoff as handoff
import prepare_capture as adapter
from test_prepare_capture import synthetic_capture

SESSION = "cccccccc-1111-2222-3333-dddddddddddd"
FX = 1332.0
ONE_SIXTIETH = 1 / 60


def checkerboard(size=(64, 48), cell=4):
    width, height = size
    image = Image.new("L", size)
    image.putdata([255 if ((x // cell) + (y // cell)) % 2 else 0 for y in range(height) for x in range(width)])
    return image.convert("RGB")


def jpeg_bytes(image, blur_radius=0):
    if blur_radius:
        image = image.filter(ImageFilter.BoxBlur(blur_radius))
    exif = Image.Exif()
    exif[274] = 1
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=95, exif=exif)
    return buffer.getvalue()


def rotation_y(angle_deg, x=0.0):
    c, s = math.cos(math.radians(angle_deg)), math.sin(math.radians(angle_deg))
    return [[c, 0, s, x], [0, 1, 0, 0], [-s, 0, c, 0], [0, 0, 0, 1]]


def blur_capture(root, frames=24, omega_deg_s=18.8, exposures=None, fx=FX, cadence=0.5, points=120):
    """Camera rotating about +Y at a constant rate while translating along X.

    Each frame carries its own feature points, placed in front of that camera
    so seeds exist whatever the rotation. Returns the sidecar names in order.
    """
    (root / "images").mkdir()
    (root / "frames").mkdir()
    manifest = {**adapter.CONVENTIONS, "session_id": SESSION, "frames": [],
                "feature_point_observations": 0, "image_bytes": 0}
    width, height = 80, 60
    half_x, half_y = 0.8 * 2 * (width / 2) / fx, 0.8 * 2 * (height / 2) / fx
    for i in range(frames):
        name = f"{i + 1:06d}"
        image_path = root / "images" / f"{name}.jpg"
        board = checkerboard((width, height), cell=3 + i % 3)
        image_path.write_bytes(jpeg_bytes(board))
        t = 10 + cadence * i
        pose = rotation_y(omega_deg_s * cadence * i, x=0.02 * i)
        rotation = [row[:3] for row in pose[:3]]
        local = [((j % 12 - 5.5) / 6 * half_x, (j // 12 - 4.5) / 5 * half_y, -2.0) for j in range(points)]
        world = [[sum(rotation[r][c] * p[c] for c in range(3)) + pose[r][3] for r in range(3)] for p in local]
        exposure = ONE_SIXTIETH if exposures is None else exposures[i]
        metadata = {"schema_version": 1, "session_id": SESSION, "image": f"images/{name}.jpg",
                    "camera_to_world": pose, "intrinsics": [[fx, 0, width / 2], [0, fx, height / 2], [0, 0, 1]],
                    "image_resolution": {"width": width, "height": height}, "timestamp": t,
                    "exposure_duration_seconds": exposure,
                    "motion_previous_timestamp": t - 1/60,
                    "motion_previous_camera_to_world": rotation_y(omega_deg_s * (cadence * i - 1/60), x=0.02*i),
                    "angular_speed_deg_s": omega_deg_s,
                    "predicted_smear_px": fx * math.radians(omega_deg_s * exposure),
                    "tracking_state": {"state": "normal", "reason": None},
                    "raw_feature_points": [{"id": str(i * 1000 + j), "position": p} for j, p in enumerate(world)]}
        sidecar = f"frames/{name}.json"
        (root / sidecar).write_text(json.dumps(metadata))
        manifest["frames"].append(sidecar)
        manifest["feature_point_observations"] += points
        manifest["image_bytes"] += image_path.stat().st_size
    (root / "manifest.json").write_text(json.dumps(manifest))
    return manifest["frames"]


class FormulaTests(unittest.TestCase):
    def test_smear_matches_hand_computed_values(self):
        # fx * radians(omega * t): 1332 * radians(18.8 / 60) = 7.284 px.
        self.assertAlmostEqual(blur.predicted_smear_px(18.8, ONE_SIXTIETH, 1332), 1332 * math.radians(18.8 / 60))
        self.assertAlmostEqual(blur.predicted_smear_px(18.8, ONE_SIXTIETH, 1332), 7.284, places=3)
        self.assertAlmostEqual(blur.predicted_smear_px(42.5, ONE_SIXTIETH, 1332), 16.467, places=3)
        self.assertAlmostEqual(blur.predicted_smear_px(18.8, 1 / 120, 1332), 3.642, places=3)
        self.assertEqual(blur.predicted_smear_px(0, ONE_SIXTIETH, 1332), 0.0)
        for omega, exposure, fx in ((-1, ONE_SIXTIETH, 1332), (1, -0.01, 1332), (1, 0, 1332), (1, 1, 1332), (1, 0.01, 0),
                                    (math.nan, 0.01, 1332), (1, math.inf, 1332), (True, 0.01, 1332)):
            with self.subTest(omega=omega, exposure=exposure, fx=fx):
                with self.assertRaises(adapter.CaptureError):
                    blur.predicted_smear_px(omega, exposure, fx)

    def test_angular_speed_uses_max_adjacent_motion_without_cancellation(self):
        angles, times = [0, 10, 30, 35], [0, 1, 2, 3]
        frames = [{"camera_to_world": rotation_y(a), "timestamp": t} for a, t in zip(angles, times)]
        self.assertEqual([round(v, 9) for v in blur.angular_speed_deg_s(frames)], [10, 20, 20, 5])
        uneven = [{"pose": rotation_y(a), "timestamp": t} for a, t in zip([0, 20, 20, 50], [0, 0.5, 2, 2.5])]
        self.assertEqual([round(v, 9) for v in blur.angular_speed_deg_s(uneven)], [40, 40, 60, 60])
        with self.assertRaisesRegex(adapter.CaptureError, "at least 2 frames"):
            blur.angular_speed_deg_s(frames[:1])
        with self.assertRaisesRegex(adapter.CaptureError, "strictly increase"):
            blur.angular_speed_deg_s(list(reversed(frames)))
        with self.assertRaisesRegex(adapter.CaptureError, "non-rigid"):
            blur.angular_speed_deg_s([{"camera_to_world": [[2, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
                                       "timestamp": 0}, frames[1]])
        self.assertAlmostEqual(blur.rotation_angle_deg(rotation_y(0), rotation_y(90)), 90)
        self.assertAlmostEqual(blur.rotation_angle_deg(rotation_y(0), rotation_y(180)), 180)

    def test_laplacian_orders_sharp_checkerboard_over_box_blurred(self):
        board = checkerboard()
        sharp, soft, softer = (jpeg_bytes(board, r) for r in (0, 1, 3))
        values = [blur.laplacian_variance(b) for b in (sharp, soft, softer)]
        self.assertGreater(values[0], values[1])
        self.assertGreater(values[1], values[2])
        self.assertGreater(values[2], 0)
        self.assertEqual(blur.laplacian_variance(jpeg_bytes(Image.new("RGB", (64, 48), (90, 90, 90)))), 0.0)
        with tempfile.TemporaryDirectory(prefix="spatial-blur-") as temp:
            path = Path(temp) / "sharp.jpg"
            path.write_bytes(sharp)
            with Image.open(io.BytesIO(sharp)) as image:
                decoded = image.convert("RGB")
            self.assertEqual(blur.laplacian_variance(path), values[0])
            self.assertEqual(blur.laplacian_variance(decoded), values[0])
        self.assertNotEqual(blur.laplacian_variance(sharp, centre_crop=1.0), values[0])
        for crop in (0, 1.5, math.nan):
            with self.assertRaises(adapter.CaptureError):
                blur.laplacian_variance(sharp, centre_crop=crop)
        with self.assertRaisesRegex(adapter.CaptureError, "too small"):
            blur.laplacian_variance(jpeg_bytes(Image.new("RGB", (2, 2))))
        with self.assertRaisesRegex(adapter.CaptureError, "cannot decode"):
            blur.laplacian_variance(b"not a jpeg")

    def test_percentile_and_pearson_helpers(self):
        self.assertEqual(blur.percentile([4, 1, 3, 2], 0.5), 2.5)
        self.assertEqual(blur.percentile(list(range(11)), 0.9), 9.0)
        self.assertEqual(blur.percentile([7], 0.9), 7)
        self.assertAlmostEqual(blur.pearson([1, 2, 3], [2, 4, 6]), 1.0)
        self.assertAlmostEqual(blur.pearson([1, 2, 3], [3, 2, 1]), -1.0)
        self.assertIsNone(blur.pearson([1, 1, 1], [1, 2, 3]))
        self.assertIsNone(blur.pearson([1, 2], [1, 2]))


class ReportAndPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spatial-blur-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def capture(self, name="capture", **kwargs):
        root = self.base / name
        root.mkdir()
        sidecars = blur_capture(root, **kwargs)
        return root, sidecars

    def test_blur_report_summarises_synthetic_capture(self):
        root, sidecars = self.capture(frames=24, omega_deg_s=18.8)
        report = blur.blur_report(root)
        self.assertEqual(report["format"], "rendprop-capture-blur-report")
        self.assertEqual([row["source"] for row in report["rows"]], sidecars)
        expected = 1332 * math.radians(18.8 / 60)
        for row in report["rows"]:
            self.assertAlmostEqual(row["angular_speed_deg_s"], 18.8)
            self.assertAlmostEqual(row["predicted_smear_px"], expected)
            self.assertGreater(row["laplacian_variance"], 0)
        summary = report["summary"]
        self.assertEqual(summary["frames"], 24)
        self.assertAlmostEqual(summary["angular_speed_deg_s"]["median"], 18.8)
        self.assertAlmostEqual(summary["predicted_smear_px"]["median"], expected)
        self.assertEqual(summary["frames_over_px"], {"5": 24, "10": 0, "20": 0})
        self.assertEqual(summary["exposure_histogram_ms"], {"16.667": 24})
        self.assertEqual(summary["frames_exposure_ge_1_60"], 24)
        self.assertAlmostEqual(summary["exposure_median_ms"], 1000 / 60)
        self.assertIn("sharpness_laplacian_variance", summary)
        self.assertIsNone(summary["corr_log_smear_log_sharpness"])  # Constant smear: undefined.
        json.dumps(report, allow_nan=False)
        without = blur.blur_report(root, with_sharpness=False)
        self.assertNotIn("laplacian_variance", without["rows"][0])
        self.assertNotIn("sharpness_laplacian_variance", without["summary"])

    def test_report_requires_exposure_and_at_least_two_frames(self):
        root = self.base / "no-exposure"
        root.mkdir()
        synthetic_capture(root)
        with self.assertRaisesRegex(adapter.CaptureError, "exposure_duration_seconds"):
            blur.blur_report(root)
        root, _ = self.capture("one", frames=1)
        with self.assertRaisesRegex(adapter.CaptureError, "at least 2"):
            blur.blur_report(root)

    @staticmethod
    def rows(smears):
        return [{"index": i, "source": f"frames/{i + 1:06d}.json", "timestamp": float(i),
                 "exposure_duration_seconds": ONE_SIXTIETH, "angular_speed_deg_s": 0.0, "fx": FX,
                 "predicted_smear_px": float(s), "motion_known": True} for i, s in enumerate(smears)]

    def test_policy_boundaries_and_messages(self):
        rows = self.rows([3.0] * 13 + [6.0] * 7)  # median 3.0, 7/20 = 35% over 5 px
        blur.evaluate_policy(rows, {"max_median_px": 3.0, "max_fraction_over_px": (5.0, 0.35)})
        with self.assertRaisesRegex(adapter.CaptureError, r"capture too blurred: median predicted smear 3\.00 px > 2\.9 px"):
            blur.evaluate_policy(rows, {"max_median_px": 2.9})
        with self.assertRaisesRegex(adapter.CaptureError, r"7/20 frames \(35\.0%\) over 5 px > 34\.0%"):
            blur.evaluate_policy(rows, {"max_fraction_over_px": [5.0, 0.34]})
        with self.assertRaisesRegex(adapter.CaptureError, r"median.*; 7/20"):
            blur.evaluate_policy(rows, {"max_median_px": 1, "max_fraction_over_px": [5.0, 0.0]})
        blur.evaluate_policy(rows, {"max_fraction_over_px": [6.0, 0.0]})  # > threshold, not >=
        blur.evaluate_policy(self.rows([5.7] * 5), {"max_median_px": 5.7})
        for bad in ({}, {"other": 1}, {"max_median_px": 0}, {"max_median_px": True}, {"max_median_px": math.nan},
                    {"max_fraction_over_px": [5.0]}, {"max_fraction_over_px": [0, 0.5]},
                    {"max_fraction_over_px": [5.0, 1.5]}, "4"):
            with self.subTest(policy=bad):
                with self.assertRaisesRegex(adapter.CaptureError, "blur_policy"):
                    blur.validate_policy(bad)
        self.assertEqual(blur.validate_policy(blur.DEFAULT_BLUR_POLICY),
                         {"max_median_px": 4.0, "max_fraction_over_px": [5.0, 0.35]})

    def test_select_sharp_frames_preserves_order_and_guards_minimum(self):
        rows = self.rows([1, 9, 2, 5.0, 5.01, 3])
        kept, dropped = blur.select_sharp_frames(rows, 5.0, 4)
        self.assertEqual([r["index"] for r in kept], [0, 2, 3, 5])
        self.assertEqual([r["source"] for r in dropped], ["frames/000002.json", "frames/000005.json"])
        with self.assertRaisesRegex(adapter.CaptureError, "keeps 4 of 6 frames under 5 px; need 5"):
            blur.select_sharp_frames(rows, 5.0, 5)
        for limit in (0, -1, math.inf, "5"):
            with self.assertRaises(adapter.CaptureError):
                blur.select_sharp_frames(rows, limit, 1)
        with self.assertRaises(adapter.CaptureError):
            blur.select_sharp_frames(rows, 5.0, 0)


class AdapterGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spatial-blur-gate-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def capture(self, name, **kwargs):
        root = self.base / name
        root.mkdir()
        return root, blur_capture(root, **kwargs)

    @staticmethod
    def dataset_bytes(output):
        names = sorted(p.name for p in (output / "images").iterdir())
        return ({name: (output / "images" / name).read_bytes() for name in names},
                {name: (output / "sparse/0" / name).read_bytes() for name in ("cameras.bin", "images.bin", "points3D.bin")})

    def test_gate_rejects_blur_and_missing_or_forged_motion_before_export(self):
        root, names = self.capture("fast", omega_deg_s=18.8)
        with self.assertRaisesRegex(adapter.CaptureError, "capture too blurred"):
            adapter.load_capture(root, blur_policy=blur.DEFAULT_BLUR_POLICY)
        root, names = self.capture("slow", omega_deg_s=5)
        first = root / names[0]
        original = json.loads(first.read_text())
        for key, value in (("exposure_duration_seconds", 0), ("exposure_duration_seconds", -1),
                           ("predicted_smear_px", 0), ("motion_previous_timestamp", 0),
                           ("angular_speed_deg_s", None)):
            with self.subTest(key=key, value=value):
                first.write_text(json.dumps({**original, key: value}))
                with self.assertRaises(adapter.CaptureError):
                    adapter.load_capture(root, blur_policy=blur.DEFAULT_BLUR_POLICY)
        first.write_text(json.dumps(original))
        for name in names:
            path = root / name
            data = json.loads(path.read_text())
            for key in ("angular_speed_deg_s", "predicted_smear_px", "motion_previous_timestamp", "motion_previous_camera_to_world"):
                data.pop(key)
            path.write_text(json.dumps(data))
        with self.assertRaisesRegex(adapter.CaptureError, "quality unavailable"):
            adapter.load_capture(root, blur_policy=blur.DEFAULT_BLUR_POLICY)
        self.assertEqual(len(adapter.load_capture(root)["frames"]), 24)

    def test_gate_pass_preserves_original_images_models_and_holdout(self):
        root, _ = self.capture("slow", omega_deg_s=5)
        plain = adapter.write_dataset(adapter.load_capture(root), self.base / "plain")
        gated = adapter.write_dataset(adapter.load_capture(root, blur_policy=blur.DEFAULT_BLUR_POLICY), self.base / "gated")
        self.assertEqual(self.dataset_bytes(self.base / "plain"), self.dataset_bytes(self.base / "gated"))
        self.assertEqual(gated["evaluation_images"], ["000001.jpg", "000009.jpg", "000017.jpg"])
        self.assertEqual(gated["training_images"], plain["training_images"])
        self.assertEqual(gated["seed_image_names"], plain["seed_image_names"])
        self.assertEqual(gated["capture_quality"]["status"], "passed")
        self.assertEqual(gated["capture_quality"]["summary"]["unknown_motion_frames"], 0)

    def test_sparse_reversal_never_looks_stationary_or_passes_policy(self):
        entries = [{"pose": rotation_y(10 if i % 2 else 0), "timestamp": i * .2,
                    "fx": FX, "exposure_duration_seconds": ONE_SIXTIETH} for i in range(24)]
        rows = blur.blur_rows(entries)
        self.assertTrue(all(abs(row["predicted_smear_px"] - 19.373154697) < 1e-7 for row in rows))
        self.assertTrue(all(row["motion_known"] is False for row in rows))
        with self.assertRaisesRegex(adapter.CaptureError, "unavailable"):
            blur.evaluate_policy(rows, blur.DEFAULT_BLUR_POLICY)
        kept, dropped = blur.select_sharp_frames(rows, 4, 1)
        self.assertEqual([row["index"] for row in kept], [0, 8, 16])
        self.assertEqual(len(dropped), 21)

    def test_stationary_sparse_gap_is_unknown_not_a_sharpness_certificate(self):
        entries = [{"pose": rotation_y(0), "timestamp": i * .5,
                    "fx": FX, "exposure_duration_seconds": ONE_SIXTIETH} for i in range(24)]
        rows = blur.blur_rows(entries)
        self.assertTrue(all(row["predicted_smear_px"] == 0 for row in rows))
        with self.assertRaisesRegex(adapter.CaptureError, "unavailable"):
            blur.evaluate_policy(rows, blur.DEFAULT_BLUR_POLICY)

    def test_diagnostic_selection_preserves_all_50_original_eval_ids_and_export_is_blocked(self):
        rows = ReportAndPolicyTests.rows([8 if i % 3 == 0 or i % 8 == 0 else 1 for i in range(400)])
        kept, dropped = blur.select_sharp_frames(rows, 4, 20)
        original_eval = set(range(0, 400, 8))
        self.assertEqual({row["index"] for row in kept if row["index"] % 8 == 0}, original_eval)
        self.assertFalse(original_eval & {row["index"] for row in dropped})
        root, _ = self.capture("fixed")
        for threshold in (4, 1, 100, 0, True):
            with self.assertRaisesRegex(adapter.CaptureError, "original evaluation IDs"):
                adapter.load_capture(root, sharp_only_max_px=threshold)
        self.assertFalse((self.base / "filtered").exists())

    def test_existing_fixture_without_exposure_is_readable_but_not_rental_eligible(self):
        root = self.base / "legacy"
        root.mkdir()
        synthetic_capture(root)
        self.assertEqual(len(adapter.load_capture(root)["frames"]), 20)
        with self.assertRaisesRegex(adapter.CaptureError, "exposure_duration_seconds"):
            adapter.load_capture(root, blur_policy=blur.DEFAULT_BLUR_POLICY)



if __name__ == "__main__":
    unittest.main()
