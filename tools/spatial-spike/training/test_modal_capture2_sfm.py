"""Budget, lifecycle and post-training boundaries using local synthetic fixtures only."""
from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal
import json
import hashlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import modal_capture2_sfm as r02
import modal_room as room
import modal_retry


class BudgetLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.clock = self.mock(r02, "datetime")
        self.clock.now.return_value = datetime(2026, 9, 30, 21, tzinfo=timezone.utc)
        self.mock(r02, "PRIVATE_ROOT", self.root)
        self.mock(modal_retry, "PRIVATE_ROOT", self.root)
        self.mock(r02, "R01_MARKER", self.root / "prior-marker.json")
        r02.R01_MARKER.write_text(json.dumps({"reserved_usd": "4.9110336000"}))
        self.mock(r02, "private_path", side_effect=lambda p, **kw: Path(p))
        self.mock(r02, "DATASET", self.root / "dataset")
        self.r01 = {"billing_sha256": "bill", "cohort": {}}
        self.predecessors = [{"marker": str(r02.R01_MARKER), "billing_sha256": "bill",
                              "app_id": "ap-prior", "sandbox_id": "sb-prior"}]
        self.inventory = {"active_by_app": {}, "exact_sandbox_terminal_polls": {}}
        self.provider = SimpleNamespace(__version__="1.5.3",
            App=SimpleNamespace(lookup=Mock(return_value=SimpleNamespace(app_id="ap-new"))),
            Sandbox=SimpleNamespace(list=Mock(return_value=[]), from_id=Mock(return_value=SimpleNamespace(
                poll=Mock(return_value=137), detach=Mock()))))

    def mock(self, module, name, *args, **kwargs):
        p = patch.object(module, name, *args, **kwargs)
        result = p.start()
        self.addCleanup(p.stop)
        return result

    def prepare_fixture(self, spent="22.10"):
        self.mock(r02, "source_binding", return_value={"files": {}})
        self.mock(r02, "r01_binding", return_value=self.r01)
        self.mock(room, "inventory", return_value=[])
        self.mock(r02, "candidate_binding", return_value={})
        self.mock(r02, "diagnostic_binding", return_value={})
        self.mock(room, "sha", return_value="hash")
        def ledger():
            # Verify the shared reader sees the lowered legitimate hold, while r01 validation does not.
            self.assertEqual(room.policy()["timeout_seconds"], 3900)
            return Decimal(spent), Decimal(room.policy()["compute_upper_bound_usd"]), self.predecessors, self.inventory
        self.mock(r02.benchmark, "ledger", side_effect=ledger)

    def plan_fixture(self):
        plan = {"app_name": "r02-test", "dataset": str(self.root / "dataset"),
                "reserved_usd": "2.660143200", "predecessors": self.predecessors, "diagnostics": {}}
        path = self.root / "plan.json"
        path.write_text(json.dumps(plan))
        self.mock(r02, "prepare", return_value=deepcopy(plan))
        self.mock(r02.benchmark, "ledger", return_value=(None, None, self.predecessors, self.inventory))
        return path, plan

    def test_full_hold_exact_rate_without_provider_call(self):
        p = r02.policy()
        self.assertEqual(p["timeout_seconds"], 3900)
        self.assertEqual(Decimal(p["compute_upper_bound_usd"]), Decimal("2.6601432"))
        self.assertEqual(room.policy()["timeout_seconds"], 7200)
        self.provider.App.lookup.assert_not_called()

    def test_provider_creation_request_really_has_3900_second_ttl(self):
        modal = SimpleNamespace(Image=SimpleNamespace(from_registry=lambda x: x))
        receipt = {"sandbox_name": "fixture", "run_id": "fixture"}
        result = r02.create_options(modal, "app", receipt)
        self.assertEqual(result["timeout"], 3900)
        self.assertEqual(result["cpu"], (4.0, 4.0))
        self.assertEqual(result["memory"], (32768, 32768))
        self.assertEqual(r02.ORIGINAL_CREATE_OPTIONS(modal, "app", receipt)["timeout"], 7200)

    def test_policy_scope_restores_after_exception(self):
        with self.assertRaises(RuntimeError), r02.policy_scope():
            self.assertIs(room.policy, r02.policy)
            raise RuntimeError("synthetic failure")
        self.assertIs(room.policy, r02.ORIGINAL_POLICY)

    def test_nested_policy_scope_rejected(self):
        with r02.policy_scope():
            with self.assertRaisesRegex(ValueError, "overlapping"), r02.policy_scope():
                pass
        self.assertIs(room.policy, r02.ORIGINAL_POLICY)

    def test_dispatch_restores_all_overrides_after_failure(self):
        with self.assertRaises(RuntimeError), r02.dispatch_scope({"diagnostics": {}}):
            self.assertIs(room.create_options, r02.create_options)
            self.assertIsNot(room.collect, r02.ORIGINAL_COLLECT)
            raise RuntimeError("synthetic training failure")
        self.assertIs(room.policy, r02.ORIGINAL_POLICY)
        self.assertIs(room.create_options, r02.ORIGINAL_CREATE_OPTIONS)
        self.assertIs(room.collect, r02.ORIGINAL_COLLECT)

    def test_actual_plus_full_hold_at_ceiling_accepted(self):
        self.prepare_fixture("22.3398568")
        plan = r02.prepare()
        self.assertEqual(Decimal(plan["prior_costs_and_holds_usd"]) + Decimal(plan["reserved_usd"]), Decimal(25))
        self.assertIs(room.policy, r02.ORIGINAL_POLICY)

    def test_one_ten_millionth_over_budget_refused(self):
        self.prepare_fixture("22.3398569")
        with self.assertRaisesRegex(ValueError, "shared \\$25"):
            r02.prepare()
        self.assertIs(room.policy, r02.ORIGINAL_POLICY)

    def test_prior_r01_binding_runs_under_original_7200_policy(self):
        self.prepare_fixture()
        def check(source):
            self.assertEqual(room.policy()["timeout_seconds"], 7200)
            return self.r01
        r02.r01_binding.side_effect = check
        r02.prepare()

    def test_closed_r01_bill_must_appear_in_shared_ledger(self):
        self.prepare_fixture()
        self.predecessors[0]["billing_sha256"] = None
        with self.assertRaisesRegex(ValueError, "closed bill is absent"):
            r02.prepare()

    def test_new_shorter_profile_cannot_reduce_older_full_holds(self):
        self.prepare_fixture()
        r02.R01_MARKER.write_text(json.dumps({"reserved_usd": "3.00"}))
        with self.assertRaisesRegex(ValueError, "older allocation lost"):
            r02.prepare()

    def test_missing_finalized_hashes_refuse_candidate_before_read(self):
        for value in (None, "", "estimated", "a" * 63):
            with self.assertRaisesRegex(ValueError, "has not bound"):
                r02.require_digest(value, "candidate")

    def test_exact_calendar_cutoff_includes_five_minute_margin(self):
        self.clock.now.return_value = datetime(2026, 9, 30, 22, 49, 59, tzinfo=timezone.utc)
        r02.require_billing_window()
        self.clock.now.return_value = datetime(2026, 9, 30, 22, 50, tzinfo=timezone.utc)
        with self.assertRaisesRegex(ValueError, "billing window"):
            r02.require_billing_window()

    def test_prior_active_or_nonterminal_blocks_before_reservation(self):
        path, _ = self.plan_fixture()
        self.provider.Sandbox.list.return_value = [object()]
        with self.assertRaisesRegex(ValueError, "still active"):
            r02.execute(self.provider, path, self.root / "run")
        self.provider.Sandbox.list.return_value = []
        self.provider.Sandbox.from_id.return_value.poll.return_value = None
        with self.assertRaisesRegex(ValueError, "not terminal"):
            r02.execute(self.provider, path, self.root / "run")
        self.provider.App.lookup.assert_not_called()
        self.assertFalse((self.root / r02.MARKER_NAME).exists())

    def test_changed_plan_blocks_before_provider_calls(self):
        path, _ = self.plan_fixture()
        r02.prepare.return_value["reserved_usd"] = "1"
        with self.assertRaisesRegex(ValueError, "budget changed"):
            r02.execute(self.provider, path, self.root / "run")
        self.provider.Sandbox.list.assert_not_called()

    def test_cutoff_rechecked_after_slow_provider_lookup(self):
        path, _ = self.plan_fixture()
        def lookup(*a, **kw):
            self.clock.now.return_value = datetime(2026, 9, 30, 22, 50, tzinfo=timezone.utc)
            return SimpleNamespace(app_id="ap-new")
        self.provider.App.lookup.side_effect = lookup
        with self.assertRaisesRegex(ValueError, "billing window"):
            r02.execute(self.provider, path, self.root / "run")
        self.assertFalse((self.root / r02.MARKER_NAME).exists())

    def test_single_dispatch_has_persisted_hold_actual_ttl_and_fixed_recipe(self):
        path, plan = self.plan_fixture()
        def run(*args, **kw):
            marker = self.root / r02.MARKER_NAME
            self.assertIn(marker, list(self.root.glob(r02.ablation.MARKER_GLOB)))
            saved = json.loads(marker.read_text())
            self.assertEqual(saved["reserved_usd"], "2.660143200")
            self.assertEqual(saved["automatic_retries"], 0)
            self.assertEqual(room.policy()["timeout_seconds"], 3900)
            self.assertIs(room.create_options, r02.create_options)
            self.assertEqual(kw["max_seconds"], 3000)
            self.assertEqual(kw["max_steps"], 30000)
            self.assertTrue(kw["pose_opt"])
        with patch.object(room, "run", side_effect=run) as dispatch:
            r02.execute(self.provider, path, self.root / "run")
        dispatch.assert_called_once()
        self.assertIs(room.policy, r02.ORIGINAL_POLICY)

    def test_ambiguous_failure_keeps_marker_and_cannot_retry(self):
        path, _ = self.plan_fixture()
        with patch.object(room, "run", side_effect=RuntimeError("ambiguous")) as dispatch:
            with self.assertRaises(RuntimeError):
                r02.execute(self.provider, path, self.root / "run")
            marker = self.root / r02.MARKER_NAME
            original = marker.read_bytes()
            with self.assertRaisesRegex(ValueError, "already reserved"):
                r02.execute(self.provider, path, self.root / "retry")
            self.assertEqual(marker.read_bytes(), original)
        dispatch.assert_called_once()
        self.assertIs(room.create_options, r02.ORIGINAL_CREATE_OPTIONS)
        self.assertIs(room.collect, r02.ORIGINAL_COLLECT)

    def diagnostic_fixture(self, present=("summary.json", "panel.png")):
        inputs = {}
        for name in ("helper", "baseline_ply", "baseline_renders", "evaluation_poses"):
            path = self.root / name
            path.write_bytes(b"synthetic " + name.encode())
            inputs[name] = {"path": str(path), "sha256": room.sha(path)}
        spec = {**inputs, "output_files": ["summary.json", "panel.png"]}
        fs = SimpleNamespace(make_directory=Mock(), copy_from_local=Mock(),
            list_files=Mock(return_value=[SimpleNamespace(name=n) for n in present]),
            stat=Mock(return_value=SimpleNamespace(size=3)),
            copy_to_local=Mock(side_effect=lambda remote, local: local.write_bytes(b"PNG")))
        sb = SimpleNamespace(filesystem=fs, _experimental_set_outbound_network_policy=Mock())
        original = [{"path": f"original{i}", "bytes": 1, "sha256": "hash"} for i in range(52)]
        collect = self.mock(r02, "ORIGINAL_COLLECT", return_value=original)
        def execute(*args, **kw):
            kw["stage"]["exit_code"] = 0
            kw["persist"]()
        run = self.mock(room, "exec_to_log", side_effect=execute)
        return sb, {"diagnostics": spec}, collect, run

    def test_diagnostics_exact_whitelist_and_bound_is109_files(self):
        self.assertEqual(len(r02.DIAGNOSTIC_OUTPUTS), 109)
        self.assertEqual(len(set(r02.DIAGNOSTIC_OUTPUTS)), 109)
        self.assertEqual(r02.DIAGNOSTIC_SECONDS, 300)
        self.assertEqual(r02.MAX_COMBINED_DOWNLOAD, 768 * 1024**2)

    def test_diagnostics_hashbound_uploads_under_denied_network_and_preserves_originals(self):
        sb, plan, collect, run = self.diagnostic_fixture()
        target = self.root / "download"
        output = r02.collect_with_diagnostics(sb, target, 30000, plan)
        collect.assert_called_once()
        self.assertEqual(sb.filesystem.copy_from_local.call_count, 4)
        self.assertEqual(len(output), 54)
        self.assertEqual(run.call_args.args[2], 300)
        self.assertEqual(run.call_args.args[1][0], "/opt/conda/bin/python")
        self.assertIn("--baseline-renders", run.call_args.args[1])
        sb._experimental_set_outbound_network_policy.assert_not_called()
        status = json.loads((self.root / "diagnostics-status.json").read_text())
        self.assertEqual(status["status"], "collected")
        self.assertEqual(status["acceptance"], "not_accepted")

    def test_failed_diagnostic_stage_retains_original_and_valid_partial_outputs(self):
        sb, plan, collect, run = self.diagnostic_fixture(present=("summary.json",))
        run.side_effect = room.StageFailure(124)
        output = r02.collect_with_diagnostics(sb, self.root / "download", 30000, plan)
        self.assertEqual(len(output), 53)
        status = json.loads((self.root / "diagnostics-status.json").read_text())
        self.assertEqual(status["status"], "failed")
        self.assertEqual(status["original_artifacts_preserved"], 52)
        self.assertEqual(status["missing_files"], ["panel.png"])
        self.assertFalse(status["automatic_retry"])
        run.assert_called_once()

    def test_changed_diagnostic_input_preserves_originals_without_upload(self):
        sb, plan, collect, run = self.diagnostic_fixture()
        Path(plan["diagnostics"]["helper"]["path"]).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "input changed"):
            r02.collect_with_diagnostics(sb, self.root / "download", 30000, plan)
        collect.assert_called_once()
        sb.filesystem.copy_from_local.assert_not_called()
        run.assert_not_called()
        receipt = json.loads((self.root / "primary-artifact-receipt.json").read_text())
        self.assertEqual(receipt["artifacts"], collect.return_value)
        self.assertEqual(receipt["max_steps"], 30000)
        self.assertFalse(receipt["provider_receipt_modified"])

    def test_upload_failure_has_durable_primary_receipt_before_transfer(self):
        sb, plan, collect, run = self.diagnostic_fixture()
        def fail_upload(*args):
            receipt = json.loads((self.root / "primary-artifact-receipt.json").read_text())
            self.assertEqual(len(receipt["artifacts"]), 52)
            self.assertEqual(receipt["artifacts"], collect.return_value)
            self.assertEqual(receipt["plan_fingerprint"], r02.benchmark.fingerprint(plan))
            raise OSError("synthetic upload failure")
        sb.filesystem.copy_from_local.side_effect = fail_upload
        with self.assertRaisesRegex(OSError, "synthetic upload failure"):
            r02.collect_with_diagnostics(sb, self.root / "download", 30000, plan)
        run.assert_not_called()

    def test_unexpected_diagnostic_output_never_downloaded_and_is_no_go(self):
        sb, plan, _, _ = self.diagnostic_fixture(present=("summary.json", "panel.png", "private.key"))
        r02.collect_with_diagnostics(sb, self.root / "download", 30000, plan)
        self.assertEqual(sb.filesystem.copy_to_local.call_count, 2)
        status = json.loads((self.root / "diagnostics-status.json").read_text())
        self.assertEqual(status["status"], "failed")
        self.assertEqual(status["unexpected_files"], ["private.key"])

    def test_combined_download_limit_fails_before_diagnostic_download(self):
        sb, plan, collect, _ = self.diagnostic_fixture()
        sb.filesystem.stat.return_value.size = r02.MAX_COMBINED_DOWNLOAD
        with self.assertRaisesRegex(ValueError, "combined artifact"):
            r02.collect_with_diagnostics(sb, self.root / "download", 30000, plan)
        collect.assert_called_once()
        sb.filesystem.copy_to_local.assert_not_called()


if __name__ == "__main__":
    unittest.main()
