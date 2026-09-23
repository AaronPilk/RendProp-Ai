"""Actual image/model regression: evaluation pixels and points never seed training."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import prepare_capture as adapter
import prepare_capture_benchmark as benchmark
from test_prepare_capture import fixture


class BenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spatial-benchmark-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.capture = self.base / "capture"
        self.capture.mkdir()
        fixture(self.capture)
        mpath = self.capture / "manifest.json"
        manifest = json.loads(mpath.read_text())
        for i in range(20, 400):
            origin = i % 20 + 1
            frame = json.loads((self.capture / f"frames/{origin:06d}.json").read_text())
            frame.update(timestamp=10+i, image=f"images/{i+1:06d}.jpg")
            name = f"frames/{i+1:06d}.json"
            (self.capture / name).write_text(json.dumps(frame))
            shutil.copyfile(self.capture / f"images/{origin:06d}.jpg", self.capture / frame["image"])
            manifest["frames"].append(name)
        manifest["feature_point_observations"] = 40000
        mpath.write_text(json.dumps(manifest))

    def alter_pixels(self, index, color):
        image = Image.new("RGB", (80, 60), color)
        exif = Image.Exif(); exif[274] = 1
        image.save(self.capture / f"images/{index:06d}.jpg", exif=exif)

    def test_eval_pixels_and_points_cannot_change_initialization_but_training_can(self):
        first = self.base / "first"
        report = benchmark.prepare(self.capture, first)
        self.assertEqual(len(report["training_images"]), 350)
        self.assertEqual(len(report["evaluation_images"]), 50)
        self.assertEqual(report["evaluation_images"], [f"{i+1:06d}.jpg" for i in range(0, 400, 8)])
        self.assertEqual(report["seed_image_names"], report["training_images"])
        for index in range(1, 401, 8):
            self.alter_pixels(index, (0, 255, 0))
            path = self.capture / f"frames/{index:06d}.json"
            frame = json.loads(path.read_text())
            for point in frame["raw_feature_points"]:
                point["id"] = str(int(point["id"]) + 1000000)
                point["position"][2] = -3
            path.write_text(json.dumps(frame))
        second = self.base / "second"
        changed = benchmark.prepare(self.capture, second)
        self.assertNotEqual(report["image_sha256"], changed["image_sha256"])
        self.assertEqual(report["model_sha256"], changed["model_sha256"])
        for name in report["image_sha256"]:
            self.assertEqual((second / "images" / name).read_bytes(), (self.capture / "images" / name).read_bytes())
        self.alter_pixels(400, (0, 0, 255))
        third = benchmark.prepare(self.capture, self.base / "third")
        self.assertNotEqual(changed["model_sha256"]["points3D.bin"], third["model_sha256"]["points3D.bin"])

    def test_existing_output_and_changed_cohort_are_rejected(self):
        with self.assertRaisesRegex(adapter.CaptureError, "already exists"):
            benchmark.prepare(self.capture, self.base)
        path = self.capture / "manifest.json"
        m = json.loads(path.read_text()); m["frames"] = m["frames"][:-1]; m["feature_point_observations"] -= 100
        path.write_text(json.dumps(m))
        with self.assertRaisesRegex(adapter.CaptureError, "exactly 400"):
            benchmark.prepare(self.capture, self.base / "short")

    def test_enrichment_failure_never_publishes_generic_completion_marker(self):
        output = self.base / "failed"
        with patch.object(benchmark, "enrich_report", side_effect=RuntimeError("injected after adapter write")):
            with self.assertRaisesRegex(RuntimeError, "injected"):
                benchmark.prepare(self.capture, output)
        self.assertFalse(output.exists())
        self.assertEqual(list(self.base.glob(".failed-preparing-*")), [])


if __name__ == "__main__":
    unittest.main()
