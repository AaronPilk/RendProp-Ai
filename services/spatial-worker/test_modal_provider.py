"""Strict offline provider-boundary execution, not a successful GPU run."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from worker import JobFailure, TRAINING_ROOT
from modal_provider import ModalProvider
from test_worker import job

sys.path.insert(0, str(TRAINING_ROOT))
import modal_room


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.modal = Mock(); self.modal.__version__ = "1.5.3"
        self.app = SimpleNamespace(name="rendprop-spatial-worker")
        self.sb = self.modal.Sandbox.create.return_value
        self.sb.object_id = "sb-fixture1234"; self.sb.poll.return_value = 137
        self.sb.filesystem.stat.return_value = SimpleNamespace(size=3)
        def copy(remote, local):
            local.parent.mkdir(parents=True, exist_ok=True)
            local.write_bytes(json.dumps({"status": "trained", "gaussian_count": 100}).encode()
                              if remote.endswith("run.json") else b"sog")
        self.sb.filesystem.copy_to_local.side_effect = copy
        self.journal_rows = []
        def journal_call(j, route, **fields):
            self.assertEqual(route, "provider-attempt")
            self.journal_rows.append(fields)
            return {"ok": True, "job_id": j["id"], "lease_token": j["lease_token"],
                    "attempt_key": j["attempt_key"], "dispatch": True, **fields["data"]}
        self.api = SimpleNamespace(job_call=Mock(side_effect=journal_call))
        self.lease = SimpleNamespace(check=Mock(), stage=Mock(), abort=lambda: None, provider_stopped=True, api=self.api)
        self.capture = {"frames": [{"pose": [[1,0,0,0],[0,1,0,1.6],[0,0,1,0],[0,0,0,1]]}],
                        "seeds": [{"position": [-1,0,-1]}, {"position": [1,2,1]}]}
        self.provider = ModalProvider(self.modal, self.app)

    def test_runtime_ttl_no_secrets_network_denial_and_termination(self):
        order = []
        self.sb._experimental_set_outbound_network_policy.side_effect = lambda **k: order.append(("network", k))
        self.sb.filesystem.copy_from_local.side_effect = lambda p, r: order.append(("copy", r))
        with patch.object(modal_room, "inventory", return_value=[{"path": "images/000000.jpg"}]), \
                patch.object(modal_room, "exec_to_log") as execute:
            output, manifest = self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.assertEqual(output.read_bytes(), b"sog")
        self.assertEqual(manifest["gaussian_count"], 100)
        create = self.modal.Sandbox.create.call_args.kwargs
        self.assertLessEqual(create["timeout"], 7200)
        self.assertEqual(create["secrets"], [])
        self.assertEqual(create["volumes"], {})
        self.assertEqual(create["gpu"], "L4")
        deny = max(i for i, entry in enumerate(order) if entry == ("network", {"outbound_cidr_allowlist": [], "outbound_domain_allowlist": []}))
        media = next(i for i, entry in enumerate(order) if entry[0] == "copy" and "/dataset/" in entry[1])
        self.assertLess(deny, media)
        self.assertEqual(execute.call_count, 3)
        training = execute.call_args_list[1].args[1]
        self.assertEqual(training[training.index("--max-seconds") + 1], "900")
        self.assertEqual(training[training.index("--max-steps") + 1], "3000")
        self.sb.terminate.assert_called_once_with(wait=True)
        self.sb.filesystem.remove.assert_called_once_with(modal_room.REMOTE, recursive=True)
        self.assertIs(self.lease.provider_stopped, True)

    def test_ambiguous_allocation_cannot_authorize_an_immediate_retry(self):
        def lost_create(**options):
            self.assertIs(self.lease.provider_stopped, False)
            raise TimeoutError()
        self.modal.Sandbox.create.side_effect = lost_create
        self.modal.Sandbox.from_name.side_effect = TimeoutError()
        with patch.object(modal_room, "inventory", return_value=[]):
            with self.assertRaises(JobFailure):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.assertIs(self.lease.provider_stopped, False)
        self.modal.Sandbox.create.assert_called_once()

    def test_unconfirmed_termination_does_not_authorize_an_immediate_retry(self):
        self.sb.poll.return_value = None
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"):
            with self.assertRaisesRegex(JobFailure, "provider_termination_unconfirmed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.assertIs(self.lease.provider_stopped, False)

    def test_setup_failure_no_dataset_transfer_one_allocation(self):
        self.sb.filesystem.stat.side_effect = FileNotFoundError()
        with patch.object(modal_room, "inventory", return_value=[]), \
                patch.object(modal_room, "exec_to_log", side_effect=RuntimeError("private SDK body")):
            with self.assertRaisesRegex(JobFailure, "generation_failed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.modal.Sandbox.create.assert_called_once()
        self.assertFalse(any("/dataset/" in c.args[1] for c in self.sb.filesystem.copy_from_local.call_args_list))
        self.sb.terminate.assert_called_once_with(wait=True)

    def test_ambiguous_create_only_reconciles_named_attempt_never_creates_twice(self):
        self.modal.Sandbox.create.side_effect = TimeoutError()
        recovered = self.modal.Sandbox.from_name.return_value
        recovered.object_id = "sb-recovered1234"
        recovered.poll.return_value = 137
        recovered.filesystem.stat.side_effect = FileNotFoundError()
        with patch.object(modal_room, "inventory", return_value=[]):
            with self.assertRaises(JobFailure):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.modal.Sandbox.create.assert_called_once()
        self.modal.Sandbox.from_name.assert_called_once()
        self.assertEqual(self.modal.Sandbox.from_name.call_args.args[0], "rendprop-spatial-worker")
        recovered.terminate.assert_called_once_with(wait=True)

    def test_lease_loss_stops_before_allocation(self):
        self.lease.check.side_effect = JobFailure("lease_lost")
        with patch.object(modal_room, "inventory", return_value=[]):
            with self.assertRaisesRegex(JobFailure, "lease_lost"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.modal.Sandbox.create.assert_not_called()
        self.assertIs(self.lease.provider_stopped, True)

    def test_cleanup_failure_cannot_return_successful_artifact(self):
        self.sb.filesystem.remove.side_effect = RuntimeError("fixture")
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"):
            with self.assertRaisesRegex(JobFailure, "provider_cleanup_unconfirmed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.sb.terminate.assert_called_once_with(wait=True)

    def test_real_billing_classification_survives_generic_exit(self):
        self.sb.filesystem.stat.side_effect = FileNotFoundError()
        with patch.object(modal_room, "inventory", return_value=[]), \
                patch.object(modal_room, "exec_to_log", side_effect=modal_room.StageFailure(137)), \
                patch.object(modal_room, "provider_terminal", return_value={"reason": "billing_cycle_spend_limit"}):
            with self.assertRaisesRegex(JobFailure, "provider_billing_limit"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)

    def test_no_allocation_without_durable_intent_acknowledgement(self):
        self.api.job_call.side_effect = JobFailure("control_plane_unavailable")
        with patch.object(modal_room, "inventory", return_value=[]):
            with self.assertRaises(JobFailure):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.modal.Sandbox.create.assert_not_called()
        self.sb.filesystem.copy_from_local.assert_not_called()

    def test_identity_ack_failure_transfers_nothing_and_still_journals_cleanup(self):
        original = self.api.job_call.side_effect
        def deny_created(j, route, **fields):
            if fields["action"] == "created":
                raise JobFailure("control_plane_unavailable")
            return original(j, route, **fields)
        self.api.job_call.side_effect = deny_created
        with patch.object(modal_room, "inventory", return_value=[]):
            with self.assertRaises(JobFailure):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.sb.filesystem.copy_from_local.assert_not_called()
        self.assertEqual(self.journal_rows[-1]["action"], "cleanup")
        self.assertIs(self.journal_rows[-1]["data"]["terminated"], True)
        self.assertEqual(self.journal_rows[-1]["data"]["sandbox_id"], self.sb.object_id)

    def test_receipts_survive_temporary_directory_removal_and_precede_transfers(self):
        def create(**options):
            self.assertEqual([r["action"] for r in self.journal_rows], ["plan"])
            return self.sb
        self.modal.Sandbox.create.side_effect = create
        def copy(*args):
            self.assertIn("created", [r["action"] for r in self.journal_rows])
        self.sb.filesystem.copy_from_local.side_effect = copy
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"):
            self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.temp.cleanup()
        self.assertFalse(self.root.exists())
        self.assertEqual([r["action"] for r in self.journal_rows], ["plan", "created", "cleanup"])
        self.assertIs(self.journal_rows[-1]["data"]["files_removed"], True)
        self.assertIs(self.journal_rows[-1]["data"]["terminated"], True)

    def test_terminal_failure_cannot_skip_durable_pending_cleanup(self):
        self.sb.terminate.side_effect = TimeoutError("private SDK message")
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"):
            with self.assertRaisesRegex(JobFailure, "provider_termination_unconfirmed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.assertEqual(self.journal_rows[-1]["action"], "cleanup")
        self.assertIs(self.journal_rows[-1]["data"]["terminated"], False)
        self.assertEqual(self.journal_rows[-1]["data"]["last_error_code"], "termination_failed")

    def test_completed_local_cleanup_without_durable_ack_is_not_success(self):
        original = self.api.job_call.side_effect
        def deny_cleanup(j, route, **fields):
            if fields["action"] == "cleanup":
                raise JobFailure("control_plane_unavailable")
            return original(j, route, **fields)
        self.api.job_call.side_effect = deny_cleanup
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"):
            with self.assertRaisesRegex(JobFailure, "provider_journal_unconfirmed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)


if __name__ == "__main__":
    unittest.main(verbosity=2)
