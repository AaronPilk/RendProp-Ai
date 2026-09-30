"""CPU contract tests; these do not claim to exercise CUDA or camera hardware."""
from copy import deepcopy
import json
from pathlib import Path
import struct
import tempfile
import unittest

import numpy as np

import modal_capture2_sfm_diagnostics as diagnostic


class DiagnosticContractTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def ply(self, *, count=2, mutate_header=None, mutate_body=None):
        # Encode with an independent scalar loop, not the decoder's reshaping.
        names = ["x", "y", "z"] + ["f_dc_0", "f_dc_1", "f_dc_2"]
        names += [f"f_rest_{i}" for i in range(45)]
        names += ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        header = ["ply", "format binary_little_endian 1.0", f"element vertex {count}"]
        header += [f"property float {name}" for name in names] + ["end_header"]
        if mutate_header:
            mutate_header(header)
        values = []
        for vertex in range(2):
            values += [10 + vertex, 20 + vertex, 30 + vertex, .1, .2, .3]
            # Exporter orders all red SH coefficients, then green, then blue.
            for channel in range(3):
                for coefficient in range(15):
                    values.append(100 * vertex + 10 * channel + coefficient)
            values += [-2.5, -1.2, -.8, -1.6, 1.3, .1, .2, .3]
        body = struct.pack("<" + "f" * len(values), *values)
        if mutate_body:
            body = mutate_body(body)
        path = self.root / "test.ply"
        path.write_bytes(("\n".join(header) + "\n").encode() + body)
        return path

    def test_channel_major_sh_and_raw_log_parameters_decode_correctly(self):
        result = diagnostic.load_ply(self.ply())
        for vertex in range(2):
            for coefficient in range(15):
                for channel in range(3):
                    self.assertEqual(result["shN"][vertex, coefficient, channel],
                                     100 * vertex + 10 * channel + coefficient)
        self.assertEqual(result["shN"].shape, (2, 15, 3))
        self.assertEqual(result["sh0"].shape, (2, 1, 3))
        self.assertEqual(result["opacities"].tolist(), [-2.5, -2.5])
        self.assertAlmostEqual(result["scales"][0, 0], -1.2)
        self.assertAlmostEqual(result["quats"][0, 0], 1.3)

    def test_reordered_properties_reject(self):
        def swap(header):
            header[9], header[10] = header[10], header[9]
        with self.assertRaisesRegex(ValueError, "property order"):
            diagnostic.load_ply(self.ply(mutate_header=swap))

    def test_double_property_rejects(self):
        with self.assertRaisesRegex(ValueError, "property order"):
            diagnostic.load_ply(self.ply(mutate_header=lambda h: h.__setitem__(3, "property double x")))

    def test_wrong_endian_rejects(self):
        with self.assertRaisesRegex(ValueError, "encoding"):
            diagnostic.load_ply(self.ply(mutate_header=lambda h: h.__setitem__(1, "format binary_big_endian 1.0")))

    def test_truncated_or_appended_body_rejects(self):
        for mutation in (lambda b: b[:-4], lambda b: b + b"junk"):
            with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError, "body length"):
                diagnostic.load_ply(self.ply(mutate_body=mutation))

    def test_no_nonfinite_filtering(self):
        for value in (float("nan"), float("inf"), -float("inf")):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "nonfinite"):
                diagnostic.load_ply(self.ply(mutate_body=lambda b: struct.pack("<f", value) + b[4:]))

    def test_vertex_cap_rejects(self):
        for count in (0, -1, 500001):
            with self.subTest(count=count), self.assertRaisesRegex(ValueError, "cap"):
                diagnostic.load_ply(self.ply(count=count))

    def fixture(self):
        originals = np.repeat(np.eye(4)[None], 46, axis=0)
        Ks = np.repeat(np.array([[1300., 0, 960], [0, 1301., 720], [0, 0, 1]])[None], 46, axis=0)
        poses = []
        for index, name in enumerate(diagnostic.EVAL_NAMES):
            localized = np.eye(4)
            localized[0, 3] = index * .01
            poses.append({"image_name": name, "status": "passed", "recomputed_final_inliers": 20, "camtoworld": localized.tolist(),
                          "original_camtoworld": originals[index].tolist(), "K": Ks[index].tolist()})
        return {"schema_version": 1, "coordinate_system": "ARKit-world/OpenCV-camera",
                "evaluation_images": diagnostic.EVAL_NAMES.copy(), "poses": poses}, originals, Ks

    def test_all_46_fixed_views_validate_without_changing_original(self):
        value, original, Ks = self.fixture()
        localized = diagnostic.validate_pose_sidecar(value, original, Ks)
        self.assertEqual(localized.shape, (46, 4, 4))
        self.assertEqual(localized[-1, 0, 3], .45)
        np.testing.assert_equal(original[:, 0, 3], 0)

    def test_duplicate_dropped_or_reordered_view_rejects(self):
        for mode in ("duplicate", "dropped", "reordered"):
            value, originals, Ks = self.fixture()
            if mode == "duplicate":
                value["poses"][5] = deepcopy(value["poses"][4])
            elif mode == "dropped":
                value["poses"].pop()
            else:
                value["poses"].reverse()
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "view"):
                diagnostic.validate_pose_sidecar(value, originals, Ks)

    def test_reflection_scale_and_nonfinite_pose_reject(self):
        for replacement in (-1, 1.1, float("nan")):
            value, originals, Ks = self.fixture()
            value["poses"][0]["camtoworld"][0][0] = replacement
            with self.subTest(value=replacement), self.assertRaises(ValueError):
                diagnostic.validate_pose_sidecar(value, originals, Ks)

    def test_modified_original_pose_or_K_reject(self):
        for key, r, c in (("original_camtoworld", 0, 3), ("K", 0, 0)):
            value, originals, Ks = self.fixture()
            value["poses"][0][key][r][c] += .01
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.validate_pose_sidecar(value, originals, Ks)

    def comparison(self):
        return [{"image_name": name, "delta_vs_saved_png": {key: 0. for key in diagnostic.BASELINE_METRICS}}
                for name in diagnostic.EVAL_NAMES]

    def test_aggregate_cannot_hide_one_bad_view(self):
        views = self.comparison()
        self.assertTrue(diagnostic.compare_import(diagnostic.BASELINE_METRICS, views)["passed"])
        views[17]["delta_vs_saved_png"]["ssim"] = .02
        result = diagnostic.compare_import(diagnostic.BASELINE_METRICS, views)
        self.assertFalse(result["passed"])
        self.assertEqual(result["worst_view_for_each_metric"]["ssim"]["image_name"], "000137.jpg")

    def test_signed_aggregate_drift_and_nonfinite_fail(self):
        for key, tolerance in diagnostic.AGGREGATE_TOLERANCES.items():
            for sign in (-1, 1):
                metrics = {**diagnostic.BASELINE_METRICS, key: diagnostic.BASELINE_METRICS[key] + sign * tolerance * 2}
                self.assertFalse(diagnostic.compare_import(metrics, self.comparison())["passed"])
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            diagnostic.compare_import({**diagnostic.BASELINE_METRICS, "psnr": float("nan")}, self.comparison())

    def test_no_evaluation_leak_into_training_diagnostics(self):
        self.assertEqual(len(diagnostic.TRAIN_NAMES), 315)
        self.assertEqual(len(diagnostic.EVAL_NAMES), 46)
        self.assertFalse(set(diagnostic.TRAIN_NAMES) & set(diagnostic.EVAL_NAMES))
        self.assertTrue(set(diagnostic.TRAIN_DIAGNOSTIC_NAMES) <= set(diagnostic.TRAIN_NAMES))
        self.assertEqual(len(set(diagnostic.OUTPUT_NAMES)), 109)

    def test_frozen_output_cannot_be_rewritten_or_nan_serialized(self):
        path = self.root / "output.json"
        diagnostic.save_json(path, {"status": "failed"})
        with self.assertRaises(FileExistsError):
            diagnostic.save_json(path, {"status": "passed"})
        self.assertEqual(json.loads(path.read_text())["status"], "failed")


if __name__ == "__main__":
    unittest.main()
