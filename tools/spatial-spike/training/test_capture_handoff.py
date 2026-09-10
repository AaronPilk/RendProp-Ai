"""Synthetic-only handoff regressions. No user captures or reconstruction."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import capture_handoff as handoff
import prepare_capture as adapter
import run_training
from test_prepare_capture import fixture


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spatial-handoff-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "SYNTHETIC-NOT-A-ROOM"
        self.root.mkdir()
        fixture(self.root)
        self.alter("manifest.json", lambda m: m.update(image_bytes=sum(
            p.stat().st_size for p in (self.root / "images").iterdir())))

    def alter(self, relative, fn):
        path = self.root / relative
        data = json.loads(path.read_text())
        fn(data)
        path.write_text(json.dumps(data))

    def inventory(self):
        return handoff.root_inventory(self.root)

    def assemble(self, destination):
        return handoff.assemble_capture(self.root / "manifest.json", self.root / "frames",
                                        self.root / "images", destination)

    def test_complete_private_copy_and_dataset_bind_original_bytes(self):
        before = self.inventory()
        copied = self.assemble(self.base / "copy")
        self.assertEqual(handoff.root_inventory(copied), before)
        self.assertEqual(copied.stat().st_mode & 0o777, 0o700)
        dataset = self.base / "dataset"
        report = handoff.inspect_capture(copied, dataset)
        self.assertEqual(report["source"], before)
        self.assertEqual(report["source"]["file_count"], 41)
        self.assertEqual(report["adapter"]["initial_points"], 100)
        self.assertEqual(report["adapter"]["frames"], 20)
        self.assertEqual(report["growth_plan"]["final_artifact_gaussians_upper_bound"], 302)
        self.assertTrue(report["dataset_prepared"])
        for field in ("gpu_training_performed", "reconstructed_room_verified", "phone_viewer_verified",
                      "raw_pose_and_calibration_modified"):
            self.assertIs(report[field], False)
        self.assertEqual(json.loads((dataset / "capture-provenance.json").read_text()), report)
        self.assertEqual(run_training.validate_dataset(dataset, 500000)["initial_points"], 100)
        for name, info in before["files"].items():
            self.assertEqual(handoff.bounded_file(self.root / name, handoff.JPEG_LIMIT)[0], info)
        for image in (dataset / "images").iterdir():
            self.assertEqual(image.read_bytes(), (copied / "images" / image.name).read_bytes())

    def test_split_image_directory_rename_is_copy_only(self):
        images = self.base / "images 2"
        (self.root / "images").rename(images)  # Synthetic fixture only.
        output = self.base / "copy"
        handoff.assemble_capture(self.root / "manifest.json", self.root / "frames", images, output)
        self.assertTrue(images.is_dir())
        self.assertEqual(len(list(images.iterdir())), 20)
        self.assertEqual(handoff.inspect_capture(output)["adapter"]["frames"], 20)

    def test_session_mismatch_refused_before_output_creation(self):
        self.alter("frames/000001.json", lambda f: f.update(session_id="other"))
        output = self.base / "copy"
        with self.assertRaisesRegex(adapter.CaptureError, "mixed ARSession"):
            self.assemble(output)
        self.assertFalse(output.exists())

    def test_incomplete_missing_or_extra_files_refused(self):
        for status in ("recording", "interrupted", "failed", "limit_reached"):
            self.alter("manifest.json", lambda m: m.update(status=status))
            with self.assertRaisesRegex(adapter.CaptureError, "status"):
                self.inventory()
        self.alter("manifest.json", lambda m: m.update(status="complete"))
        path = self.root / "images/000020.jpg"
        path.rename(self.base / "preserved.jpg")
        with self.assertRaisesRegex(adapter.CaptureError, "missing"):
            self.inventory()
        (self.base / "preserved.jpg").rename(path)
        (self.root / ".DS_Store").write_bytes(b"synthetic")
        with self.assertRaisesRegex(adapter.CaptureError, "unexpected"):
            self.inventory()

    def test_file_directory_and_root_symlinks_refused(self):
        link = self.base / "root-link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(adapter.CaptureError, "real directory"):
            handoff.root_inventory(link)
        path = self.root / "images/000001.jpg"
        preserved = self.base / "image.jpg"
        path.rename(preserved)
        path.symlink_to(preserved)
        with self.assertRaisesRegex(adapter.CaptureError, "regular file"):
            self.inventory()
        frames = self.root / "frames"
        frames.rename(self.base / "preserved-frames")
        frames.symlink_to(self.base / "preserved-frames", target_is_directory=True)
        with self.assertRaisesRegex(adapter.CaptureError, "real directory"):
            self.inventory()

    def test_noncontiguous_and_mispaired_paths_refused(self):
        self.alter("manifest.json", lambda m: m["frames"].reverse())
        with self.assertRaisesRegex(adapter.CaptureError, "contiguous"):
            self.inventory()
        self.alter("manifest.json", lambda m: m["frames"].reverse())
        self.alter("frames/000001.json", lambda f: f.update(image="images/../images/000001.jpg"))
        with self.assertRaisesRegex(adapter.CaptureError, "pairing"):
            self.inventory()

    def test_byte_and_observation_totals_refused(self):
        self.alter("manifest.json", lambda m: m.update(image_bytes=True))
        with self.assertRaisesRegex(adapter.CaptureError, "image_bytes"):
            self.inventory()
        self.alter("manifest.json", lambda m: m.update(feature_point_observations=1999))
        with self.assertRaisesRegex(adapter.CaptureError, "observations"):
            self.inventory()

    def test_native_raster_and_point_limits_refused(self):
        for resolution in ({"width": 8193, "height": 1}, {"width": 8192, "height": 8192},
                           {"width": True, "height": 60}):
            self.alter("frames/000001.json", lambda f: f.update(image_resolution=resolution))
            with self.assertRaisesRegex(adapter.CaptureError, "raster"):
                self.inventory()
        self.alter("frames/000001.json", lambda f: f.update(image_resolution={"width":80,"height":60},
                                                           raw_feature_points=[None] * 50001))
        with self.assertRaisesRegex(adapter.CaptureError, "50,000"):
            self.inventory()

    def test_bounded_files_and_total_reject_before_unbounded_adapter(self):
        with patch.object(handoff, "MANIFEST_LIMIT", 10), patch.object(adapter, "load_capture") as load:
            with self.assertRaisesRegex(adapter.CaptureError, "byte limit"):
                handoff.inspect_capture(self.root)
            load.assert_not_called()
        for limit in ("SIDECAR_LIMIT", "JPEG_LIMIT", "TOTAL_LIMIT"):
            with patch.object(handoff, limit, 10):
                with self.assertRaises(adapter.CaptureError):
                    self.inventory()

    def test_duplicate_and_nonfinite_json_refused(self):
        path = self.root / "manifest.json"
        for text in ('{"status":"complete","status":"complete"}', '{"x":NaN}'):
            path.write_text(text)
            with self.assertRaises(adapter.CaptureError):
                self.inventory()

    def test_unchanged_adapter_rejects_projective_pose_and_truncated_jpeg(self):
        self.alter("frames/000001.json", lambda f: f["camera_to_world"][3].__setitem__(0, 0.1))
        with self.assertRaisesRegex(adapter.CaptureError, "homogeneous"):
            handoff.inspect_capture(self.root)
        self.alter("frames/000001.json", lambda f: f["camera_to_world"][3].__setitem__(0, 0))
        image = self.root / "images/000001.jpg"
        image.write_bytes(image.read_bytes()[:100])
        self.alter("manifest.json", lambda m: m.update(image_bytes=sum(
            p.stat().st_size for p in (self.root / "images").iterdir())))
        with self.assertRaisesRegex(adapter.CaptureError, "invalid JPEG"):
            handoff.inspect_capture(self.root)

    def test_existing_inside_and_low_disk_outputs_refused(self):
        before = self.inventory()
        with self.assertRaisesRegex(adapter.CaptureError, "exists"):
            self.assemble(self.root)
        with self.assertRaisesRegex(adapter.CaptureError, "outside"):
            self.assemble(self.root / "frames/copy")
        with patch.object(handoff.shutil, "disk_usage", return_value=type("Disk", (), {"free":0})()):
            with self.assertRaisesRegex(adapter.CaptureError, "disk space"):
                self.assemble(self.base / "copy")
        self.assertEqual(before, self.inventory())

    def test_copy_inside_manifest_parent_is_refused_without_touching_source(self):
        before = self.inventory()
        output = self.root / "copy"
        with self.assertRaisesRegex(adapter.CaptureError, "outside"):
            self.assemble(output)
        self.assertFalse(output.exists())
        self.assertEqual(self.inventory(), before)

    def test_copy_inside_manifest_parent_via_alias_is_refused(self):
        before = self.inventory()
        alias = self.base / "source-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        output = alias / "copy"
        with self.assertRaisesRegex(adapter.CaptureError, "outside"):
            self.assemble(output)
        self.assertFalse(output.exists())
        self.assertEqual(self.inventory(), before)

    def test_dataset_is_owner_only_before_first_write_under_permissive_umask(self):
        # tempfile may use /var while the actual writer resolves /private/var.
        # Match the writer's real path so its FIRST JPEG open is observed.
        output = (self.base / "dataset").resolve()
        original_open = Path.open
        writes = []
        def checking_open(path, mode="r", *args, **kwargs):
            stream = original_open(path, mode, *args, **kwargs)
            if any(flag in mode for flag in ("w", "x", "a")) and path.is_relative_to(output):
                try:
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600, str(path))
                    parent = path.parent
                    while parent.is_relative_to(output):
                        self.assertEqual(parent.stat().st_mode & 0o777, 0o700, str(parent))
                        parent = parent.parent
                    writes.append(path)
                except BaseException:
                    stream.close()
                    raise
            return stream
        saved = os.umask(0o022)
        try:
            with patch.object(Path, "open", checking_open):
                handoff.inspect_capture(self.root, output)
            self.assertGreaterEqual(len(writes), 25)
            observed = os.umask(0o022)
            self.assertEqual(observed, 0o022, "caller umask was not restored")
        finally:
            os.umask(saved)

    def test_dataset_failure_restores_umask_and_keeps_partial_files_private(self):
        output = self.base / "dataset"
        def interrupted_writer(capture, destination):
            destination.mkdir()
            (destination / "partial.bin").write_bytes(b"synthetic only")
            raise KeyboardInterrupt("injected after partial write")
        saved = os.umask(0o022)
        try:
            with patch.object(adapter, "write_dataset", side_effect=interrupted_writer):
                with self.assertRaises(KeyboardInterrupt):
                    handoff.inspect_capture(self.root, output)
            observed = os.umask(0o022)
            self.assertEqual(observed, 0o022, "caller umask was not restored on interruption")
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual((output / "partial.bin").stat().st_mode & 0o777, 0o600)
            self.assertFalse((output / "capture-provenance.json").exists())
        finally:
            os.umask(saved)

    def test_changed_source_never_gets_handoff_completion_marker(self):
        original = adapter.write_dataset
        def changing(capture, output):
            result = original(capture, output)
            self.alter("frames/000001.json", lambda f: f.update(timestamp=999))
            return result
        output = self.base / "dataset"
        with patch.object(adapter, "write_dataset", side_effect=changing):
            with self.assertRaisesRegex(adapter.CaptureError, "source changed"):
                handoff.inspect_capture(self.root, output)
        self.assertTrue((output / "adapter-report.json").exists())
        self.assertFalse((output / "capture-provenance.json").exists())

    def test_seed_count_over_runner_cap_never_silently_truncated(self):
        capture = adapter.load_capture(self.root)
        capture["seeds"] = [capture["seeds"][0]] * 500001
        output = self.base / "dataset"
        with patch.object(adapter, "load_capture", return_value=capture):
            report = handoff.inspect_capture(self.root)
            self.assertEqual(report["growth_plan"]["status"], "blocked")
            with self.assertRaisesRegex(adapter.CaptureError, "runner cap"):
                handoff.inspect_capture(self.root, output)
        self.assertFalse(output.exists())

    def test_cli_invalid_and_valid_exit_codes(self):
        executable = [sys.executable, str(Path(handoff.__file__))]
        for args in ([], ["--unknown"], ["inspect", str(self.base / "missing")]):
            result = subprocess.run(executable + args, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("FAIL:", result.stderr)
        result = subprocess.run(executable + ["inspect", str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["reconstructed_room_verified"])


if __name__ == "__main__":
    unittest.main()
