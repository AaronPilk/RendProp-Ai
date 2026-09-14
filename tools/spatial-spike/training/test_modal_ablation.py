"""Offline A-ablation authorization and dependency-order regressions."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

import modal_ablation as ablation
import modal_retry
import modal_room as room


class AblationGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.dataset = self.root / "dataset"
        self.dataset.mkdir()
        self.files = [{"path": f"images/{i:06d}.jpg", "bytes": 1, "sha256": "a" * 64}
                      for i in range(1, 154)]
        self.baseline = self.root / "modal-room-20260911-01"
        (self.baseline / "download/result").mkdir(parents=True)
        self.write(self.baseline / "provider-receipt.json", {"dataset_files": self.files})
        self.run_path = self.baseline / "download/result/run.json"
        self.write(self.run_path, {"resolved_dependencies": ["numpy==1.26.4"]})
        self.cost_path = self.root / "cost.json"
        self.write(self.cost_path, {"budget_ceiling_usd": "25.00",
                   "total_historical_spatial_usage_usd": "1.68002079",
                   "inventory": {"active_by_app": {"ap-old": 0},
                                 "exact_sandbox_terminal_polls": {"sb-old": 137}}})
        for target, name, value in ((ablation, "PRIVATE_ROOT", self.root),
                                    (modal_retry, "PRIVATE_ROOT", self.root),
                                    (ablation, "BASELINE_RUN", self.run_path),
                                    (ablation, "COST_BASELINE", self.cost_path)):
            context = patch.object(target, name, value)
            context.start()
            self.addCleanup(context.stop)
        for name, value in (("inventory", self.files), ("source_binding", {"commit": "fixture"})):
            context = patch.object(room, name, return_value=value)
            context.start()
            self.addCleanup(context.stop)

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))

    def predecessor(self, label="a00", reserve="4.9110336000", terminal=True):
        state = self.root / label
        state.mkdir()
        self.write(self.root / f"spatial-ablation-20260914-{label}.allocation.json",
                   {"state": str(state), "reserved_usd": reserve})
        self.write(state / "provider-receipt.json", {
            "phase": "terminated" if terminal else "allocation_unresolved_no_retry",
            "remote_copy_delete": {"response": "success"},
            "terminate": {"poll_exit_code": 137 if terminal else None},
            "app_id": f"ap-{label}", "sandbox_id": f"sb-{label}"})
        return state

    def test_plan_keeps_baseline_training_and_fixed_evaluation(self):
        plan = ablation.prepare(self.dataset, "a01")
        self.assertTrue(plan["pose_optimization"])
        self.assertEqual((plan["steps"], plan["max_training_seconds"], plan["max_gaussians"]),
                         (3000, 900, 500000))
        self.assertEqual((plan["fixed_eval_every"], plan["random_seed"]), (8, 42))
        self.assertEqual(plan["automatic_retries"], 0)
        self.assertEqual(plan["prior_costs_and_holds_usd"], "1.68002079")

    def test_changed_dataset_and_unreviewed_profile_are_rejected(self):
        with patch.object(room, "inventory", return_value=self.files[:-1]):
            with self.assertRaisesRegex(ValueError, "exact original"):
                ablation.prepare(self.dataset, "a01")
        with self.assertRaisesRegex(ValueError, "pose-only"):
            ablation.prepare(self.dataset, "b01")

    def test_unreconciled_previous_attempt_blocks_another_allocation(self):
        self.predecessor(terminal=False)
        with self.assertRaisesRegex(ValueError, "cleanup reconciliation"):
            ablation.prepare(self.dataset, "a01")

    def test_unbilled_attempts_keep_full_holds_and_cannot_exceed_25(self):
        for index in range(4):
            self.predecessor(label=f"a{index:02d}")
        with self.assertRaisesRegex(ValueError, "remaining.*25"):
            ablation.prepare(self.dataset, "a05")

    def test_invalid_prior_reservation_is_not_budget_headroom(self):
        self.predecessor(reserve="-5")
        with self.assertRaises(ValueError):
            ablation.prepare(self.dataset, "a01")

    def test_only_attributed_closed_billing_releases_hold(self):
        state = self.predecessor()
        billing = {"app_id": "ap-a00", "sandbox_id": "sb-a00",
                   "closed_hourly_intervals": True, "actual_metered_usd": "0.50"}
        self.write(state / "billing-readback.json", billing)
        self.assertEqual(ablation.prepare(self.dataset, "a01")["prior_costs_and_holds_usd"], "2.18002079")
        for change in ({"app_id": "ap-other"}, {"closed_hourly_intervals": False},
                       {"actual_metered_usd": "-0.01"}):
            with self.subTest(change=change):
                self.write(state / "billing-readback.json", {**billing, **change})
                with self.assertRaises(ValueError):
                    ablation.prepare(self.dataset, "a01")

    def modal(self):
        modal = Mock()
        modal.__version__ = "1.5.3"
        modal.Sandbox.list.return_value = []
        modal.Sandbox.from_id.return_value.poll.return_value = 137
        modal.App.lookup.return_value = SimpleNamespace(app_id="ap-new")
        return modal

    def test_reservation_precedes_single_dispatch_and_ambiguous_failure_cannot_retry(self):
        plan_path = self.root / "plan.json"
        self.write(plan_path, ablation.prepare(self.dataset, "a01"))
        modal = self.modal()
        marker = self.root / "spatial-ablation-20260914-a01.allocation.json"
        def fail(*args, **kwargs):
            self.assertTrue(marker.exists())
            self.assertEqual(kwargs, {"app_name": "rendprop-spatial-ablation-a01-20260914",
                                     "pose_opt": True, "dependency_baseline": self.run_path})
            raise TimeoutError("ambiguous allocation")
        with patch.object(room, "run", side_effect=fail) as dispatch:
            with self.assertRaises(TimeoutError):
                ablation.execute(modal, plan_path, self.root / "a01")
            original = marker.read_bytes()
            with self.assertRaises(ValueError):
                ablation.execute(modal, plan_path, self.root / "another-state")
            self.assertEqual(marker.read_bytes(), original)
            dispatch.assert_called_once()

    def test_live_previous_sandbox_blocks_before_new_namespace_or_dispatch(self):
        plan_path = self.root / "plan.json"
        self.write(plan_path, ablation.prepare(self.dataset, "a01"))
        modal = self.modal()
        modal.Sandbox.list.return_value = [SimpleNamespace(object_id="sb-still-active")]
        with patch.object(room, "run") as dispatch:
            with self.assertRaisesRegex(ValueError, "active"):
                ablation.execute(modal, plan_path, self.root / "a01")
            dispatch.assert_not_called()
            modal.App.lookup.assert_not_called()


class DependencyGateTests(unittest.TestCase):
    def test_dependency_mismatch_stops_before_media_and_terminates_one_allocation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset = root / "dataset"
            dataset.mkdir()
            image = dataset / "image.jpg"
            image.write_bytes(b"synthetic")
            baseline = root / "baseline.json"
            baseline.write_text(json.dumps({"resolved_dependencies": ["numpy==1.26.4"]}))
            modal = Mock()
            modal.App.lookup.return_value = SimpleNamespace(app_id="ap-fixture")
            sandbox = modal.Sandbox.create.return_value
            sandbox.object_id = "sb-fixture"
            sandbox.poll.return_value = 137
            sandbox.terminate.return_value = 137
            sandbox.filesystem.stat.side_effect = FileNotFoundError()
            stages = []
            def stage(sb, command, *args, **kwargs):
                stages.append(command)
                if command[:2] == ["python", "-c"]:
                    raise room.StageFailure(1)
            with patch.object(room, "inventory", return_value=[{
                    "path": "image.jpg", "sha256": room.sha(image), "bytes": 9}]), \
                    patch.object(room, "source_binding", return_value={"commit": "fixture"}), \
                    patch.object(room, "exec_to_log", side_effect=stage):
                with self.assertRaises(room.StageFailure):
                    room.run(modal, dataset, root / "attempt", pose_opt=True,
                             app_name="reviewed-app", dependency_baseline=baseline)
            self.assertEqual(stages[0][0], "env")
            self.assertTrue(stages[0][1].startswith("PIP_CONSTRAINT="))
            self.assertTrue(all("/dataset/" not in call.args[1]
                                for call in sandbox.filesystem.copy_from_local.call_args_list))
            modal.Sandbox.create.assert_called_once()
            sandbox.terminate.assert_called_once_with(wait=True)


if __name__ == "__main__":
    unittest.main()
