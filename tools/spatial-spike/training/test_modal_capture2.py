"""Synthetic capture2 guards and one-run dispatch; no provider import/calls."""
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import modal_capture2 as capture2
import modal_room as room
import test_modal_capture_benchmark as old_tests


class Capture2Tests(unittest.TestCase):
    def setUp(self):
        clock = self.mock(capture2, "datetime")
        clock.now.return_value = datetime(2026, 9, 30, 19, tzinfo=timezone.utc)
        self.f = old_tests.CaptureBenchmarkTests(methodName="runTest")
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.root, self.write = self.f.root, self.f.write
        self.source = deepcopy(self.f.source)
        self.source["files"]["modal_capture2.py"] = "2" * 64
        self.mock(capture2, "source_binding", side_effect=lambda: deepcopy(self.source))
        for label in ("f01", "p01", "s01"):
            marker, state, receipt = self.f.completed(label)
        self.prior_state = state
        receipt.update(policy=room.policy(), source=deepcopy(self.f.source))
        run_path = state / "download/result/run.json"
        run = json.loads(run_path.read_text())
        run.update(max_seconds=4200, max_gaussians=500000, world_normalization=False,
                   resolved_dependencies=["fixture==1"])
        self.write(run_path, run)
        for artifact in receipt["artifacts"]:
            if artifact["path"] == "result/run.json":
                artifact.update(bytes=run_path.stat().st_size, sha256=room.sha(run_path))
        self.write(state / "provider-receipt.json", receipt)
        self.dataset = self.root / "capture2/dataset"
        self.capture = self.root / "capture2/source-capture"
        self.admission_path = self.root / "capture2/admission-receipt.json"
        for name, value in (("PRIVATE_ROOT", self.root), ("DATASET", self.dataset),
                            ("CAPTURE_ROOT", self.capture), ("ADMISSION", self.admission_path),
                            ("S01_PLAN_SHA256", room.sha(Path(json.loads(marker.read_text())["plan_path"]))),
                            ("S01_RECEIPT_SHA256", room.sha(state / "provider-receipt.json"))):
            self.mock(capture2, name, value)
        names = [f"{i:06d}.jpg" for i in range(1, 362)]
        evaluation = names[::8]
        training = [name for name in names if name not in set(evaluation)]
        self.write(self.capture / "manifest.json", {"frames": [f"frames/{n[:-4]}.json" for n in names]})
        digest = room.sha(self.capture / "manifest.json")
        self.mock(capture2, "CAPTURE_MANIFEST_SHA256", digest)
        for name in names:
            self.write(self.capture / "frames" / (name[:-4] + ".json"), {"synthetic": name})
            for base in (self.capture, self.dataset):
                path = base / "images" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
        models = self.dataset / "sparse/0"
        models.mkdir(parents=True)
        for name in ("cameras.bin", "images.bin", "points3D.bin"):
            (models / name).write_bytes(name.encode())
        self.helper_contents = {"prepare_capture.py": b"synthetic prepare", "capture_blur.py": b"synthetic blur"}
        hashes = {name: hashlib.sha256(value).hexdigest() for name, value in self.helper_contents.items()}
        self.mock(capture2, "ADAPTER_HELPERS", hashes)
        self.helpers = {}
        for name, content in self.helper_contents.items():
            path = self.root / name
            path.write_bytes(content)
            self.helpers[name] = {"path": str(path), "sha256": hashes[name]}
        self.mock(capture2.subprocess, "check_output", side_effect=lambda args, **kw:
                  self.helper_contents[args[-1].split("/")[-1]])
        quality = {"status": "passed", "policy": {"max_median_px": 4.0, "max_fraction_over_px": [5.0, .35]},
                   "summary": {"frames": 361, "unknown_motion_frames": 0,
                               "predicted_smear_px": {"median": 2.55}, "frames_over_px": {"5": 0}}}
        self.report = {"format": "rendprop-posed-gsplat-dataset", "schema_version": 1,
            "gsplat_commit": "937e29912570c372bed6747a5c9bf85fed877bae", "frames": 361, "initial_points": 100,
            "adapter_profile": "capture-training-holdout-v1", "adapter_helper_sha256": hashes["prepare_capture.py"],
            "capture_manifest_sha256": digest, "capture_quality": quality,
            "training_images": training, "evaluation_images": evaluation, "seed_image_names": training,
            "seed_colors_from_training_only": True, "seed_geometry_from_training_observations_only": True,
            "capture_metadata_sha256": {str(p.relative_to(self.capture)): room.sha(p) for p in (self.capture / "frames").iterdir()},
            "image_sha256": {name: room.sha(self.dataset / "images" / name) for name in names},
            "model_sha256": {p.name: room.sha(p) for p in models.iterdir()}}
        copy_path, proof_path = self.root / "source-copy.json", self.root / "equivalence.json"
        self.write(copy_path, {"synthetic": True})
        proof = {"status": "passed", "all_images_byte_identical": True, "no_frame_filtering": True,
                 "models": {name: {"byte_identical": True, "current_sha256": value, "old_benchmark_sha256": value}
                            for name, value in self.report["model_sha256"].items()}}
        self.write(proof_path, proof)
        self.admission = {"format": "rendprop-capture-admission-receipt", "schema_version": 1, "status": "passed",
            "source_commit": capture2.ADAPTER_COMMIT, "source_repository": str(self.root),
            "source_capture": str(self.capture), "dataset": str(self.dataset), "source_unchanged_before_and_after": True,
            "production_accepted": False, "capture_manifest_sha256": digest,
            "frames": 361, "training_images": training, "evaluation_images": evaluation, "seed_image_names": training,
            "seed_colors_from_training_only": True, "seed_geometry_from_training_observations_only": True,
            "fixed_split": {"evaluation_every": 8, "original_order_preserved": True, "frames_filtered": 0,
                            "training_count": 315, "evaluation_count": 46},
            "source_files_sha256": {str(p.relative_to(self.capture)): room.sha(p) for p in self.capture.rglob("*") if p.is_file()},
            "source_receipt": {"path": str(copy_path), "sha256": room.sha(copy_path)},
            "adapter_helpers": self.helpers, "capture_quality": quality,
            "binary_equivalence": {"path": str(proof_path), "sha256": room.sha(proof_path), "status": "passed", "models": proof["models"]}}
        self.freeze_fixture()
        self.provider = SimpleNamespace(__version__="1.5.3",
            App=SimpleNamespace(lookup=Mock(return_value=SimpleNamespace(app_id="ap-capture2"))),
            Sandbox=SimpleNamespace(list=Mock(return_value=[]), from_id=Mock(return_value=SimpleNamespace(
                poll=Mock(return_value=137), detach=Mock()))))

    def mock(self, module, name, *args, **kwargs):
        context = patch.object(module, name, *args, **kwargs)
        result = context.start()
        self.addCleanup(context.stop)
        return result

    def freeze_fixture(self):
        """Refreeze synthetic constants only, to exercise structural guards."""
        path = self.dataset / "adapter-report.json"
        self.write(path, self.report)
        digest = room.sha(path)
        self.mock(capture2, "ADAPTER_REPORT_SHA256", digest)
        self.admission["adapter_report"] = {"path": str(path), "sha256": digest}
        self.admission["dataset_files_sha256"] = {row["path"]: row["sha256"] for row in room.inventory(self.dataset)}
        self.write(self.admission_path, self.admission)
        self.mock(capture2, "ADMISSION_SHA256", room.sha(self.admission_path))

    def plan(self):
        plan = capture2.prepare(self.dataset)
        path = self.root / "r01-plan.json"
        self.write(path, plan)
        return path, plan

    def test_capture_only_recipe_and_new_cohort_are_explicit(self):
        _, plan = self.plan()
        self.assertEqual({k: plan[k] for k in capture2.RECIPE}, capture2.RECIPE)
        self.assertEqual(len(plan["cohort"]["training_images"]), 315)
        self.assertEqual(len(plan["cohort"]["evaluation_images"]), 46)
        self.assertEqual(plan["cohort"]["evaluation_images"][-1], "000361.jpg")
        self.assertFalse(plan["comparison_predecessor"]["same_evaluation_cohort"])
        self.assertFalse(plan["comparison_predecessor"]["direct_metric_comparison_valid"])
        self.assertEqual(plan["reserved_usd"], "4.9110336000")
        self.provider.App.lookup.assert_not_called()

    def test_full_lifetime_must_finish_inside_september_window(self):
        path, _ = self.plan()
        for instant in (datetime(2026, 9, 30, 21, 55, tzinfo=timezone.utc),
                        datetime(2026, 10, 1, tzinfo=timezone.utc)):
            capture2.datetime.now.return_value = instant
            with self.assertRaisesRegex(ValueError, "September billing window"):
                capture2.prepare(self.dataset)
            with self.assertRaisesRegex(ValueError, "September billing window"):
                capture2.execute(self.provider, path, self.root / "run")
        self.provider.Sandbox.list.assert_not_called()
        self.provider.App.lookup.assert_not_called()

    def test_deadline_rechecked_after_provider_lookups_before_reservation(self):
        path, _ = self.plan()
        def lookup(*args, **kwargs):
            capture2.datetime.now.return_value = datetime(2026, 9, 30, 21, 55, tzinfo=timezone.utc)
            return SimpleNamespace(app_id="ap-capture2")
        self.provider.App.lookup.side_effect = lookup
        with patch.object(room, "run") as run, self.assertRaisesRegex(ValueError, "September billing window"):
            capture2.execute(self.provider, path, self.root / "run")
        run.assert_not_called()
        self.assertFalse((self.root / capture2.MARKER_NAME).exists())

    def test_unreviewed_labels_rejected(self):
        for label in (None, "r00", "r02", "f01", "s01", "../r01"):
            with self.subTest(label=label), self.assertRaises(ValueError):
                capture2.prepare(self.dataset, label)

    def test_source_manifest_sidecar_and_jpeg_are_bound(self):
        for relative in ("manifest.json", "frames/000001.json", "images/000361.jpg"):
            path = self.capture / relative
            original = path.read_bytes()
            path.write_bytes(b"changed")
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                self.plan()
            path.write_bytes(original)

    def test_dataset_and_admission_hashes_are_bound(self):
        for path in (self.dataset / "images/000001.jpg", self.dataset / "adapter-report.json", self.admission_path):
            original = path.read_bytes()
            path.write_bytes(original + b" ")
            with self.subTest(path=path.name), self.assertRaises(ValueError):
                self.plan()
            path.write_bytes(original)

    def test_filtered_reordered_or_leaked_split_fails_even_when_rehashed(self):
        original = deepcopy(self.report)
        for key, value in (("evaluation_images", original["evaluation_images"][1:]),
                           ("training_images", original["training_images"][::-1]),
                           ("seed_image_names", original["evaluation_images"]),
                           ("seed_geometry_from_training_observations_only", False)):
            self.report = {**original, key: value}
            self.freeze_fixture()
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "split or training-only"):
                self.plan()

    def test_quality_policy_cannot_be_waived(self):
        for change in ({"unknown_motion_frames": 1}, {"predicted_smear_px": {"median": 4.01}}, {"frames_over_px": {"5": 127}}):
            original = deepcopy(self.report["capture_quality"])
            changed = deepcopy(original)
            changed["summary"].update(change)
            self.report["capture_quality"] = self.admission["capture_quality"] = changed
            self.freeze_fixture()
            with self.assertRaisesRegex(ValueError, "motion admission failed"):
                self.plan()
            self.report["capture_quality"] = self.admission["capture_quality"] = original

    def test_helper_and_equivalence_bytes_are_bound(self):
        for path in (Path(self.helpers["capture_blur.py"]["path"]), Path(self.admission["binary_equivalence"]["path"])):
            original = path.read_bytes()
            path.write_bytes(original + b" ")
            with self.assertRaises(ValueError):
                self.plan()
            path.write_bytes(original)

    def test_uncertain_cleanup_blocks_before_provider(self):
        path, _ = self.plan()
        prior_path = self.prior_state / "provider-receipt.json"
        receipt = json.loads(prior_path.read_text())
        receipt["remote_copy_delete"]["response"] = "failed"
        self.write(prior_path, receipt)
        with patch.object(room, "run") as run, self.assertRaises(ValueError):
            capture2.execute(self.provider, path, self.root / "run")
        run.assert_not_called()
        self.provider.App.lookup.assert_not_called()

    def test_changed_predecessor_metrics_are_rejected(self):
        self.write(self.prior_state / "download/result/stats/val_step29999.json", {"psnr": 999, "ssim": 1, "lpips": 0})
        with self.assertRaisesRegex(ValueError, "artifact does not match"):
            self.plan()

    def test_shared_budget_includes_other_attempts(self):
        self.f.prior("other", actual="19.98118436")
        with self.assertRaisesRegex(ValueError, "shared \\$25"):
            self.plan()

    def test_missing_bills_retain_the_entire_hold(self):
        for label in ("f01", "p01", "s01"):
            (self.root / (label + "-state") / "billing-readback.json").unlink()
        self.f.prior("extra")
        with self.assertRaisesRegex(ValueError, "shared \\$25"):
            self.plan()

    def test_dirty_source_blocks_before_provider(self):
        path, _ = self.plan()
        with patch.object(capture2, "source_binding", side_effect=ValueError("source must be committed and clean")):
            with self.assertRaisesRegex(ValueError, "committed and clean"):
                capture2.execute(self.provider, path, self.root / "run")
        self.provider.Sandbox.list.assert_not_called()

    def test_changed_controller_invalidates_saved_plan(self):
        path, _ = self.plan()
        self.source["files"]["modal_capture2.py"] = "3" * 64
        with self.assertRaisesRegex(ValueError, "plan data, admission, source"):
            capture2.execute(self.provider, path, self.root / "run")
        self.provider.Sandbox.list.assert_not_called()

    def test_active_or_nonterminal_prior_prevents_reservation(self):
        path, _ = self.plan()
        self.provider.Sandbox.list.return_value = [object()]
        with self.assertRaisesRegex(ValueError, "sandbox is active"):
            capture2.execute(self.provider, path, self.root / "run")
        self.provider.Sandbox.list.return_value = []
        prior = self.provider.Sandbox.from_id.return_value
        prior.poll.return_value = None
        with self.assertRaisesRegex(ValueError, "not terminal"):
            capture2.execute(self.provider, path, self.root / "run")
        prior.detach.assert_called_once()
        self.provider.App.lookup.assert_not_called()
        self.assertFalse((self.root / capture2.MARKER_NAME).exists())

    def test_exact_recipe_dispatch_after_durable_shared_marker(self):
        path, plan = self.plan()
        marker = self.root / capture2.MARKER_NAME
        def dispatch(*args, **kwargs):
            self.assertIn(marker, list(self.root.glob(capture2.ablation.MARKER_GLOB)))
            saved = json.loads(marker.read_text())
            self.assertEqual(saved["plan_sha256"], room.sha(path))
            self.assertEqual(saved["reserved_usd"], "4.9110336000")
            self.assertEqual(args, (self.provider, self.dataset, self.root / "run"))
            self.assertEqual(kwargs, {"app_name": plan["app_name"], "pose_opt": True,
                "dependency_baseline": self.f.baseline, "max_steps": 30000, "max_seconds": 4200})
            self.assertEqual(self.provider.Sandbox.from_id.call_count, 3)
        with patch.object(room, "run", side_effect=dispatch) as run:
            capture2.execute(self.provider, path, self.root / "run")
        run.assert_called_once()

    def test_ambiguous_dispatch_keeps_hold_and_never_retries(self):
        path, _ = self.plan()
        with patch.object(room, "run", side_effect=RuntimeError("ambiguous")) as run:
            with self.assertRaises(RuntimeError):
                capture2.execute(self.provider, path, self.root / "run")
            marker = self.root / capture2.MARKER_NAME
            content = marker.read_bytes()
            with self.assertRaisesRegex(ValueError, "already reserved"):
                capture2.execute(self.provider, path, self.root / "another-run")
            self.assertEqual(marker.read_bytes(), content)
        run.assert_called_once()

    def test_explicit_confirmation_and_original_lock_required(self):
        args = ["capture2", "run", "--plan", str(self.root / "plan.json"), "--state", str(self.root / "state")]
        with patch.object(sys, "argv", args), self.assertRaisesRegex(ValueError, "explicit one-allocation"):
            capture2.main()
        with patch.object(sys, "argv", args + ["--confirm-one-allocation"]), \
             patch.object(capture2.fcntl, "flock", side_effect=BlockingIOError) as flock, \
             patch.object(capture2, "execute") as execute:
            with self.assertRaises(BlockingIOError):
                capture2.main()
        self.assertTrue((self.root / "room-approval-20260910.lock").exists())
        self.assertEqual(flock.call_args.args[1], capture2.fcntl.LOCK_EX | capture2.fcntl.LOCK_NB)
        execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
