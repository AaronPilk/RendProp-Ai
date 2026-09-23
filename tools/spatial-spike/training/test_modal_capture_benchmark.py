"""Synthetic-only admission/ordering tests; no provider, image decoder or GPU."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import modal_ablation as ablation
import modal_capture_benchmark as benchmark
import modal_retry
import modal_room as room


class CaptureBenchmarkTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.dataset = self.root / "capture-test-20260923/dataset"
        self.capture_manifest = self.root / "capture-test-20260923/capture/manifest.json"
        self.write(self.capture_manifest, {"fixture": "synthetic400"})
        self.cost = self.root / "spatial-ablation-20260914-cost-baseline.json"
        self.baseline = self.root / "baseline-run.json"
        self.write(self.baseline, {"resolved_dependencies": ["fixture==1"]})
        self.write(self.cost, {"budget_ceiling_usd": "25.00", "total_historical_spatial_usage_usd": "1.68002079",
                               "inventory": {"active_by_app": {}, "exact_sandbox_terminal_polls": {}}})
        self.source = {"commit": "f" * 40, "files": {"run_training.py": "a" * 64,
                       "modal_capture_benchmark.py": "b" * 64, "prepare_capture_benchmark.py": "c" * 64}}
        for module, name, value in [
            (benchmark, "PRIVATE_ROOT", self.root), (modal_retry, "PRIVATE_ROOT", self.root),
            (benchmark, "DATASET", self.dataset), (benchmark, "CAPTURE_MANIFEST", self.capture_manifest),
            (benchmark, "CAPTURE_MANIFEST_SHA256", room.sha(self.capture_manifest)),
            (ablation, "COST_BASELINE", self.cost), (ablation, "BASELINE_RUN", self.baseline),
        ]:
            context = patch.object(module, name, value)
            context.start()
            self.addCleanup(context.stop)
        self.source_mock = patch.object(benchmark, "source_binding", side_effect=lambda: deepcopy(self.source))
        self.source_mock.start()
        self.addCleanup(self.source_mock.stop)
        images = self.dataset / "images"
        models = self.dataset / "sparse/0"
        images.mkdir(parents=True)
        models.mkdir(parents=True)
        names = [f"{i:06d}.jpg" for i in range(1, 401)]
        for name in names:
            (images / name).write_bytes(name.encode())
        for name in ("cameras.bin", "images.bin", "points3D.bin"):
            (models / name).write_bytes(b"synthetic-" + name.encode())
        evaluation = names[::8]
        training = [name for name in names if name not in set(evaluation)]
        self.report = {"format": "rendprop-posed-gsplat-dataset", "schema_version": 1,
                       "gsplat_commit": "937e29912570c372bed6747a5c9bf85fed877bae", "frames": 400, "initial_points": 100,
                       "benchmark_profile": benchmark.PROFILE,
                       "capture_manifest_sha256": benchmark.CAPTURE_MANIFEST_SHA256,
                       "benchmark_helper_sha256": self.source["files"]["prepare_capture_benchmark.py"],
                       "training_images": training, "evaluation_images": evaluation,
                       "seed_image_names": training, "seed_colors_from_training_only": True,
                       "seed_geometry_from_training_observations_only": True,
                       "image_sha256": {name: room.sha(images / name) for name in names},
                       "model_sha256": {p.name: room.sha(p) for p in models.iterdir()}}
        self.save_report()
        self.provider = SimpleNamespace(__version__="1.5.3",
            App=SimpleNamespace(lookup=Mock(return_value=SimpleNamespace(app_id="ap-fixture"))),
            Sandbox=SimpleNamespace(list=Mock(return_value=[]), from_id=Mock()))

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def save_report(self):
        self.write(self.dataset / "adapter-report.json", self.report)

    def plan(self, label="f01"):
        value = benchmark.prepare(self.dataset, label)
        path = self.root / (label + "-plan.json")
        self.write(path, value)
        return path, value

    def prior(self, suffix="older", actual=None, reserve=None, cleanup=True):
        state = self.root / (suffix + "-state")
        receipt = {"phase": "terminated", "outcome": "failed", "app_id": "ap-" + suffix,
                   "sandbox_id": "sb-" + suffix, "terminate": {"poll_exit_code": 137},
                   "remote_copy_delete": {"response": "success" if cleanup else "failed"}}
        self.write(state / "provider-receipt.json", receipt)
        marker = self.root / f"spatial-ablation-20260914-{suffix}.allocation.json"
        self.write(marker, {"state": str(state), "reserved_usd": reserve or room.policy()["compute_upper_bound_usd"]})
        if actual is not None:
            self.write(state / "billing-readback.json", {"app_id": receipt["app_id"], "sandbox_id": receipt["sandbox_id"],
                       "closed_hourly_intervals": True, "actual_metered_usd": actual})
        return marker, state, receipt

    def completed(self, label):
        plan_path, plan = self.plan(label)
        state = self.root / (label + "-state")
        artifacts = []
        step = plan["steps"] - 1
        payloads = {
            "result/run.json": json.dumps({"status": "trained", "frames": 400, "max_steps": plan["steps"],
                                           "pose_optimization": plan["pose_optimization"]}).encode(),
            f"result/stats/val_step{step}.json": json.dumps({"psnr": 20., "ssim": .8, "lpips": .4}).encode(),
            **{f"result/renders/val_step{step}_{i:04d}.png": b"synthetic fixture" for i in range(50)},
        }
        for relative, payload in payloads.items():
            path = state / "download" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            artifacts.append({"path": relative, "bytes": len(payload), "sha256": room.sha(path)})
        receipt = {"phase": "terminated", "outcome": "trained", "app_id": "ap-" + label, "sandbox_id": "sb-" + label,
                   "terminate": {"poll_exit_code": 137}, "remote_copy_delete": {"response": "success"},
                   "pose_optimization": plan["pose_optimization"], "dataset_files": room.inventory(self.dataset),
                   "artifacts": artifacts}
        self.write(state / "provider-receipt.json", receipt)
        marker = self.root / f"{benchmark.MARKER_PREFIX}{label}.allocation.json"
        self.write(marker, {"state": str(state), "reserved_usd": plan["reserved_usd"], "plan_path": str(plan_path),
                            "plan_sha256": room.sha(plan_path), "app_id": receipt["app_id"]})
        self.write(state / "billing-readback.json", {"app_id": receipt["app_id"], "sandbox_id": receipt["sandbox_id"],
                            "closed_hourly_intervals": True, "actual_metered_usd": "0.10"})
        return marker, state, receipt

    def test_fixed_plan_freezes_all_400_images_350_training_and_50_evaluation(self):
        _, plan = self.plan()
        self.assertFalse(plan["pose_optimization"])
        self.assertEqual((plan["steps"], plan["max_training_seconds"]), (3000, 900))
        self.assertEqual(len(plan["cohort"]["training_images"]), 350)
        self.assertEqual(len(plan["cohort"]["evaluation_images"]), 50)
        self.assertEqual(len(plan["cohort"]["image_sha256"]), 400)
        self.assertIs(plan["cohort"]["seed_geometry_from_training_observations_only"], True)
        self.assertEqual(plan["cohort"]["evaluation_images"][0], "000001.jpg")
        self.assertEqual(plan["cohort"]["evaluation_images"][-1], "000393.jpg")
        self.assertEqual(plan["prior_costs_and_holds_usd"], "1.68002079")
        self.assertEqual(plan["reserved_usd"], "4.9110336000")
        self.assertEqual(plan["automatic_retries"], 0)
        self.provider.App.lookup.assert_not_called()

    def test_stage_order_requires_same_capture_fixed_then_pose_then_steps(self):
        for label in ("p01", "s01"):
            with self.assertRaisesRegex(ValueError, "requires a completed"):
                self.plan(label)
        self.completed("f01")
        _, pose = self.plan("p01")
        self.assertTrue(pose["pose_optimization"])
        self.assertEqual(pose["steps"], 3000)
        with self.assertRaisesRegex(ValueError, "requires a completed p"):
            self.plan("s01")
        self.completed("p01")
        _, longer = self.plan("s01")
        self.assertEqual((longer["pose_optimization"], longer["steps"], longer["max_training_seconds"]), (True, 30000, 4200))

    def test_old_capture_completion_cannot_satisfy_new_capture_order(self):
        _, state, receipt = self.prior("a02", actual="0.65")
        receipt["outcome"] = "trained"
        self.write(state / "provider-receipt.json", receipt)
        with self.assertRaisesRegex(ValueError, "requires a completed f"):
            self.plan("p01")

    def test_arbitrary_labels_and_zero_attempts_are_not_accepted(self):
        for label in (None, "a01", "f00", "f1", "f100", "../f01", "s01/other"):
            with self.subTest(label=label), self.assertRaises(ValueError):
                benchmark.prepare(self.dataset, label)

    def test_own_markers_are_visible_to_the_old_shared_ledger_glob(self):
        marker, _, _ = self.completed("f01")
        self.assertIn(marker, list(self.root.glob(ablation.MARKER_GLOB)))
        _, value = self.plan("p01")
        self.assertEqual(value["prior_costs_and_holds_usd"], "1.78002079")

    def test_existing_ambiguous_spend_uses_entire_hold_and_never_elapsed_estimate(self):
        _, state, receipt = self.prior()
        receipt["elapsed_seconds"] = 1
        self.write(state / "provider-receipt.json", receipt)
        _, value = self.plan()
        self.assertEqual(value["prior_costs_and_holds_usd"], "6.5910543900")
        self.assertIsNone(value["predecessors"][0]["billing_sha256"])

    def test_four_outstanding_holds_prevent_an_additional_allocation(self):
        for n in range(4):
            self.prior("hold" + str(n))
        with self.assertRaisesRegex(ValueError, "shared \\$25"):
            self.plan()

    def test_nonfinite_negative_or_reduced_reservations_never_create_headroom(self):
        marker, _, _ = self.prior()
        original = json.loads(marker.read_text())
        for amount in ("NaN", "Infinity", "-1", "0", "1", 1):
            self.write(marker, {**original, "reserved_usd": amount})
            with self.subTest(amount=amount), self.assertRaises(ValueError):
                self.plan()

    def test_billing_requires_closed_attributed_finite_receipt(self):
        _, state, _ = self.prior(actual="0.25")
        path = state / "billing-readback.json"
        original = json.loads(path.read_text())
        for change in ({"closed_hourly_intervals": False}, {"app_id": "ap-foreign"}, {"sandbox_id": "sb-foreign"},
                       {"actual_metered_usd": "NaN"}, {"actual_metered_usd": "-0.1"}):
            self.write(path, {**original, **change})
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.plan()

    def test_cleanup_failure_blocks_the_next_plan_even_if_bill_is_closed(self):
        self.prior(actual="0.25", cleanup=False)
        with self.assertRaises(ValueError):
            self.plan()

    def test_original_budget_ceiling_or_historical_baseline_cannot_be_reset(self):
        original = json.loads(self.cost.read_text())
        for change in ({"budget_ceiling_usd": "26.00"}, {"total_historical_spatial_usage_usd": "0"}):
            self.write(self.cost, {**original, **change})
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.plan()

    def test_original_capture_manifest_and_helper_source_are_bound(self):
        self.report["benchmark_helper_sha256"] = "d" * 64
        self.save_report()
        with self.assertRaisesRegex(ValueError, "committed benchmark preparer"):
            self.plan()
        self.report["benchmark_helper_sha256"] = self.source["files"]["prepare_capture_benchmark.py"]
        self.save_report()
        self.write(self.capture_manifest, {"changed": True})
        with self.assertRaisesRegex(ValueError, "capture manifest changed"):
            self.plan()

    def test_split_and_train_only_seed_claim_cannot_be_relaxed(self):
        original = deepcopy(self.report)
        for change in ({"evaluation_images": original["evaluation_images"][1:]},
                       {"seed_image_names": original["evaluation_images"]},
                       {"seed_colors_from_training_only": False},
                       {"seed_geometry_from_training_observations_only": False},
                       {"seed_geometry_from_training_observations_only": None},
                       {"training_images": original["training_images"][::-1]}):
            self.report = {**original, **change}
            self.save_report()
            with self.subTest(change=list(change)), self.assertRaises(ValueError):
                self.plan()

    def test_dataset_alias_or_mutated_bytes_are_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.dataset, target_is_directory=True)
        with self.assertRaises(ValueError):
            benchmark.prepare(alias, "f01")
        (self.dataset / "images/000001.jpg").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.plan()

    def test_predecessor_modified_plan_or_source_cannot_authorize_next_stage(self):
        marker, _, _ = self.completed("f01")
        m = json.loads(marker.read_text())
        path = Path(m["plan_path"])
        prior = json.loads(path.read_text())
        prior["source"]["files"]["run_training.py"] = "e" * 64
        self.write(path, prior)
        with self.assertRaisesRegex(ValueError, "frozen plan changed"):
            self.plan("p01")
        m["plan_sha256"] = room.sha(path)
        self.write(marker, m)
        with self.assertRaisesRegex(ValueError, "different data, split or source"):
            self.plan("p01")

    def test_predecessor_must_have_exact_training_and_50_collected_renders(self):
        _, state, receipt = self.completed("f01")
        receipt["artifacts"] = [row for row in receipt["artifacts"] if not row["path"].endswith("0049.png")]
        self.write(state / "provider-receipt.json", receipt)
        with self.assertRaisesRegex(ValueError, "complete fixed 50-view"):
            self.plan("p01")

    def test_predecessor_changed_metrics_bytes_are_detected(self):
        _, state, _ = self.completed("f01")
        self.write(state / "download/result/stats/val_step2999.json", {"psnr": 999, "ssim": 1, "lpips": 0})
        with self.assertRaisesRegex(ValueError, "artifact does not match"):
            self.plan("p01")

    def test_a_saved_plan_rejects_changed_source_before_any_provider_call(self):
        path, _ = self.plan()
        self.source["files"]["modal_capture_benchmark.py"] = "e" * 64
        with patch.object(room, "run") as run, self.assertRaisesRegex(ValueError, "plan data, source"):
            benchmark.execute(self.provider, path, self.root / "output")
        run.assert_not_called()
        self.provider.Sandbox.list.assert_not_called()

    def test_rehashed_dataset_mutation_still_invalidates_saved_plan(self):
        path, _ = self.plan()
        target = self.dataset / "images/000400.jpg"
        target.write_bytes(b"changed but internally rehashed")
        self.report["image_sha256"][target.name] = room.sha(target)
        self.save_report()
        with patch.object(room, "run") as run, self.assertRaisesRegex(ValueError, "plan data, source"):
            benchmark.execute(self.provider, path, self.root / "output")
        run.assert_not_called()
        self.provider.Sandbox.list.assert_not_called()

    def test_reconciled_cost_changes_invalidate_plan_before_provider_call(self):
        _, state, _ = self.prior(actual="0.25")
        path, _ = self.plan()
        billing = state / "billing-readback.json"
        value = json.loads(billing.read_text())
        value["actual_metered_usd"] = "0.26"
        self.write(billing, value)
        with self.assertRaisesRegex(ValueError, "plan data, source"):
            benchmark.execute(self.provider, path, self.root / "output")
        self.provider.Sandbox.list.assert_not_called()

    def test_active_prior_sandbox_prevents_reservation_and_training(self):
        self.prior(actual="0.25")
        path, _ = self.plan()
        self.provider.Sandbox.list.return_value = [object()]
        with patch.object(room, "run") as run, self.assertRaisesRegex(ValueError, "sandbox is active"):
            benchmark.execute(self.provider, path, self.root / "output")
        run.assert_not_called()
        self.assertFalse((self.root / (benchmark.MARKER_PREFIX + "f01.allocation.json")).exists())

    def test_output_cannot_be_written_inside_frozen_capture_or_dataset(self):
        path, _ = self.plan()
        for state in (self.dataset / "output", self.capture_manifest.parent / "output"):
            with self.subTest(state=state), patch.object(room, "run") as run:
                with self.assertRaisesRegex(ValueError, "cannot modify the frozen"):
                    benchmark.execute(self.provider, path, state)
                run.assert_not_called()
        self.provider.Sandbox.list.assert_not_called()
        self.provider.App.lookup.assert_not_called()

    def test_run_requires_explicit_confirmation_before_provider_import(self):
        with patch.object(sys, "argv", ["benchmark", "run", "--plan", str(self.root / "plan.json"),
                                       "--state", str(self.root / "output")]), patch.object(benchmark, "execute") as execute:
            with self.assertRaisesRegex(ValueError, "explicit one-allocation"):
                benchmark.main()
        execute.assert_not_called()

    def test_shared_lock_contention_prevents_allocation(self):
        with patch.object(sys, "argv", ["benchmark", "run", "--plan", str(self.root / "plan.json"),
                                       "--state", str(self.root / "output"), "--confirm-one-allocation"]), \
             patch.object(benchmark.fcntl, "flock", side_effect=BlockingIOError) as flock, \
             patch.object(benchmark, "execute") as execute:
            with self.assertRaises(BlockingIOError):
                benchmark.main()
        self.assertTrue((self.root / "room-approval-20260910.lock").exists())
        self.assertEqual(flock.call_args.args[1], benchmark.fcntl.LOCK_EX | benchmark.fcntl.LOCK_NB)
        execute.assert_not_called()

    def test_a_nonterminal_previous_allocation_is_detached_without_new_rental(self):
        self.prior(actual="0.25")
        path, _ = self.plan()
        prior = SimpleNamespace(poll=Mock(return_value=None), detach=Mock())
        self.provider.Sandbox.from_id.return_value = prior
        with patch.object(room, "run") as run, self.assertRaisesRegex(ValueError, "not terminal"):
            benchmark.execute(self.provider, path, self.root / "output")
        prior.detach.assert_called_once()
        run.assert_not_called()

    def test_exact_one_existing_room_run_after_durable_reservation(self):
        path, plan = self.plan()
        state = self.root / "output"
        marker = self.root / (benchmark.MARKER_PREFIX + "f01.allocation.json")
        def run(*args, **kwargs):
            self.assertTrue(marker.is_file())
            saved = json.loads(marker.read_text())
            self.assertEqual(saved["plan_sha256"], room.sha(path))
            self.assertEqual(saved["reserved_usd"], plan["reserved_usd"])
            self.assertEqual(saved["state"], str(state))
            self.assertEqual(kwargs, {"app_name": plan["app_name"], "pose_opt": False,
                "dependency_baseline": self.baseline, "max_steps": 3000, "max_seconds": 900})
        with patch.object(room, "run", side_effect=run) as invoked:
            benchmark.execute(self.provider, path, state)
        invoked.assert_called_once()

    def test_ambiguous_failure_preserves_reservation_and_cannot_retry(self):
        path, _ = self.plan()
        state = self.root / "output"
        with patch.object(room, "run", side_effect=RuntimeError("ambiguous fixture create")) as invoked:
            with self.assertRaises(RuntimeError):
                benchmark.execute(self.provider, path, state)
            marker = self.root / (benchmark.MARKER_PREFIX + "f01.allocation.json")
            content = marker.read_bytes()
            with self.assertRaises(ValueError):
                benchmark.execute(self.provider, path, state)
            self.assertEqual(marker.read_bytes(), content)
        invoked.assert_called_once()


if __name__ == "__main__":
    unittest.main()
