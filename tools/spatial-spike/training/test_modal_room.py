"""Offline provider-boundary tests; no Modal import, token or network is used."""
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

import modal_room as room


class RoomPolicyTests(unittest.TestCase):
    def test_two_hour_provider_lifetime_and_hard_resource_limits(self):
        modal = SimpleNamespace(Image=SimpleNamespace(from_registry=lambda value: value))
        opts = room.create_options(modal, "app", {"sandbox_name": "room-test", "run_id": "test"})
        self.assertEqual(opts["timeout"], 7200)
        self.assertEqual(opts["gpu"], "L4")
        self.assertEqual(opts["cpu"], (4.0, 4.0))
        self.assertEqual(opts["memory"], (32768, 32768))
        self.assertEqual(opts["region"], "us")
        self.assertEqual(opts["volumes"], {})
        self.assertEqual(opts["secrets"], [])
        self.assertEqual(opts["encrypted_ports"] + opts["unencrypted_ports"] + opts["h2_ports"], [])
        self.assertIn("@sha256:", opts["image"])

    def test_dynamic_network_controls_are_initialized_at_creation(self):
        modal = SimpleNamespace(Image=SimpleNamespace(from_registry=lambda value: value))
        opts = room.create_options(modal, "app", {"sandbox_name": "room-test", "run_id": "test"})
        self.assertEqual(opts.get("outbound_cidr_allowlist"), ["0.0.0.0/0"])
        self.assertEqual(opts.get("outbound_domain_allowlist"), ["*"])

    def test_budget_uses_sandbox_rates_and_not_actual_charge(self):
        p = room.policy()
        self.assertEqual(p["compute_upper_bound_usd"], "4.9110336000")
        self.assertEqual(p["approval_total_usd"], "25.00")
        self.assertIsNone(p["actual_charge_usd"])
        self.assertEqual(p["automatic_rent_retries"], 0)


class DatasetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "images").mkdir()
        (self.root / "sparse/0").mkdir(parents=True)
        images, models = {}, {}
        for i in range(20):
            name = f"{i:06d}.jpg"
            data = f"synthetic-{i}".encode()
            (self.root / "images" / name).write_bytes(data)
            images[name] = hashlib.sha256(data).hexdigest()
        for name in ("cameras.bin", "images.bin", "points3D.bin"):
            (self.root / "sparse/0" / name).write_bytes(b"synthetic-model")
            models[name] = hashlib.sha256(b"synthetic-model").hexdigest()
        self.report = {"format": "rendprop-posed-gsplat-dataset", "schema_version": 1,
                       "gsplat_commit": "937e29912570c372bed6747a5c9bf85fed877bae",
                       "frames": 20, "initial_points": 100, "image_sha256": images,
                       "model_sha256": models}
        self.write_report()

    def write_report(self):
        (self.root / "adapter-report.json").write_text(json.dumps(self.report))

    def test_only_adapter_dataset_not_private_provenance_or_sidecars(self):
        (self.root / "capture-provenance.json").write_text("private source metadata")
        files = room.inventory(self.root)
        self.assertEqual(len(files), 24)
        self.assertNotIn("capture-provenance.json", [x["path"] for x in files])
        self.assertEqual(sum(x["path"].startswith("images/") for x in files), 20)

    def test_changed_image_refused(self):
        (self.root / "images/000000.jpg").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            room.inventory(self.root)

    def test_extra_image_refused(self):
        (self.root / "images/extra.jpg").write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "extra"):
            room.inventory(self.root)

    def test_symlink_image_refused_even_with_matching_hash(self):
        image = self.root / "images/000000.jpg"
        data = image.read_bytes()
        image.unlink()
        target = self.root / "outside.jpg"
        target.write_bytes(data)
        image.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "nonregular"):
            room.inventory(self.root)

    def test_wrong_trainer_and_seed_cap_refused(self):
        self.report["gsplat_commit"] = "not the trainer"
        self.write_report()
        with self.assertRaisesRegex(ValueError, "trainer"):
            room.inventory(self.root)
        self.report["gsplat_commit"] = "937e29912570c372bed6747a5c9bf85fed877bae"
        self.report["initial_points"] = 500001
        self.write_report()
        with self.assertRaisesRegex(ValueError, "seed"):
            room.inventory(self.root)

    def test_transfer_cap_refused(self):
        with patch.object(room, "MAX_DATASET", 1):
            with self.assertRaisesRegex(ValueError, "ceiling"):
                room.inventory(self.root)

    def test_existing_state_refuses_before_any_provider_call(self):
        modal = Mock()
        with self.assertRaisesRegex(ValueError, "exists"):
            room.run(modal, self.root, self.root)
        modal.Sandbox.create.assert_not_called()
        modal.App.lookup.assert_not_called()


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "provider-receipt.json"
        self.receipt = {"outcome": "failed", "actual_charge_usd": None}
        self.sb = Mock()
        self.sb.object_id = "sb-owned-fixture"
        self.sb.terminate.return_value = 137
        self.sb.poll.return_value = 137

    def test_exact_target_delete_then_provider_terminate_and_readback(self):
        room.cleanup(self.sb, self.path, self.receipt)
        self.sb.filesystem.remove.assert_called_once_with(room.REMOTE, recursive=True)
        self.sb.terminate.assert_called_once_with(wait=True)
        self.sb.poll.assert_called_once()
        self.sb.detach.assert_called_once()
        saved = json.loads(self.path.read_text())
        self.assertEqual(saved["phase"], "terminated")
        self.assertEqual(saved["outcome"], "failed")
        self.assertEqual(saved["terminate"]["poll_exit_code"], 137)
        self.assertIsNone(saved["actual_charge_usd"])

    def test_delete_failure_still_terminates_but_does_not_report_clean(self):
        self.sb.filesystem.remove.side_effect = RuntimeError("fixture")
        with self.assertRaisesRegex(ValueError, "remote_copy_delete"):
            room.cleanup(self.sb, self.path, self.receipt)
        self.sb.terminate.assert_called_once_with(wait=True)
        self.assertEqual(json.loads(self.path.read_text())["remote_copy_delete"]["response"], "failed")

    def test_interrupted_delete_still_terminates_and_restores_handlers(self):
        import signal
        original = signal.getsignal(signal.SIGTERM)
        self.sb.filesystem.remove.side_effect = KeyboardInterrupt()
        try:
            with self.assertRaisesRegex(ValueError, "remote_copy_delete"):
                room.cleanup(self.sb, self.path, self.receipt)
        except KeyboardInterrupt:
            self.fail("interrupted remote deletion skipped provider termination")
        self.sb.terminate.assert_called_once_with(wait=True)
        self.assertIs(signal.getsignal(signal.SIGTERM), original)

    def test_repeated_signal_during_cleanup_does_not_skip_termination(self):
        import signal
        self.sb.filesystem.remove.side_effect = lambda *a, **kw: signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
        with self.assertRaisesRegex(ValueError, "signal_"):
            room.cleanup(self.sb, self.path, self.receipt)
        self.sb.terminate.assert_called_once_with(wait=True)

    def test_live_provider_readback_stays_failed(self):
        self.sb.poll.return_value = None
        with self.assertRaisesRegex(ValueError, "terminate"):
            room.cleanup(self.sb, self.path, self.receipt)
        self.assertEqual(json.loads(self.path.read_text())["phase"], "cleanup_incomplete")
        self.sb.detach.assert_called_once()

    def test_terminate_exception_records_failure_and_detaches(self):
        self.sb.terminate.side_effect = RuntimeError("do not emit this SDK payload")
        with self.assertRaisesRegex(ValueError, "terminate"):
            room.cleanup(self.sb, self.path, self.receipt)
        self.assertNotIn("SDK payload", self.path.read_text())
        self.sb.detach.assert_called_once()

    def test_atomic_receipt_is_owner_only(self):
        room.save(self.path, {"phase": "fixture"})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(self.path.read_text()), {"phase": "fixture"})


class OrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dataset = self.root / "dataset"
        self.dataset.mkdir()
        self.state = self.root / "attempt"
        self.modal = Mock()
        # App is not a Modal _Object: the real SDK exposes app_id, not object_id.
        # A permissive Mock would invent either attribute and hide this boundary.
        self.modal.App.lookup.return_value = SimpleNamespace(app_id="ap-fixture")
        self.sb = self.modal.Sandbox.create.return_value
        self.sb.object_id = "sb-fixture"
        self.sb.terminate.return_value = 137
        self.sb.poll.return_value = 137
        binding = patch.object(room, "source_binding", return_value={"commit": "synthetic-test"})
        binding.start()
        self.addCleanup(binding.stop)

    def test_real_run_orders_network_denial_before_data_and_always_terminates(self):
        order = []
        self.sb._experimental_set_outbound_network_policy.side_effect = lambda **kw: order.append("deny")
        self.sb.filesystem.copy_from_local.side_effect = lambda p, r: order.append("data" if "/dataset/" in r else "tool")
        (self.dataset / "adapter-report.json").write_bytes(b"fixture")
        item = {"path": "adapter-report.json", "sha256": room.sha(self.dataset / "adapter-report.json"), "bytes": 7}
        with patch.object(room, "inventory", return_value=[item]), \
                patch.object(room, "exec_to_log"), patch.object(room, "collect", return_value=[]):
            room.run(self.modal, self.dataset, self.state)
        self.assertLess(order.index("deny"), order.index("data"))
        self.modal.Sandbox.create.assert_called_once()
        self.assertEqual(self.modal.Sandbox.create.call_args.kwargs["timeout"], 7200)
        self.sb.terminate.assert_called_once_with(wait=True)
        saved = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual(saved["outcome"], "trained")
        self.assertFalse(saved["phase_a_acceptance_complete"])
        self.assertIsNone(saved["actual_charge_usd"])
        self.assertEqual(saved["transferred_files"], ["adapter-report.json"])
        self.assertEqual([call.kwargs for call in self.sb._experimental_set_outbound_network_policy.call_args_list], [
            {"outbound_cidr_allowlist": [], "outbound_domain_allowlist": []},
            {"outbound_cidr_allowlist": ["0.0.0.0/0"], "outbound_domain_allowlist": ["*"]},
            {"outbound_cidr_allowlist": [], "outbound_domain_allowlist": []},
        ])

    def test_unsupported_policy_stops_before_setup_or_dataset_transfer(self):
        self.sb._experimental_set_outbound_network_policy.side_effect = RuntimeError("fixture")
        self.sb.filesystem.stat.side_effect = FileNotFoundError("fixture")
        with patch.object(room, "inventory", return_value=[]), patch.object(room, "exec_to_log") as execute:
            with self.assertRaises(RuntimeError):
                room.run(self.modal, self.dataset, self.state)
        execute.assert_not_called()
        self.sb.filesystem.copy_from_local.assert_not_called()
        self.sb.terminate.assert_called_once_with(wait=True)

    def test_failed_setup_never_transfers_media_and_still_destroys_instance(self):
        self.sb.filesystem.stat.side_effect = FileNotFoundError("fixture")
        with patch.object(room, "inventory", return_value=[]), \
                patch.object(room, "exec_to_log", side_effect=RuntimeError("fixture")):
            with self.assertRaises(RuntimeError):
                room.run(self.modal, self.dataset, self.state)
        self.assertTrue(all("/dataset/" not in c.args[1] for c in self.sb.filesystem.copy_from_local.call_args_list))
        self.sb.terminate.assert_called_once_with(wait=True)
        saved = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual(saved["outcome"], "failed")
        self.assertEqual(saved["phase"], "terminated")

    def test_lost_creation_reply_looks_up_exact_name_without_second_rental(self):
        self.modal.Sandbox.create.side_effect = TimeoutError("fixture")
        recovered = self.modal.Sandbox.from_name.return_value
        recovered.object_id = "sb-recovered"
        recovered.poll.return_value = 137
        recovered.terminate.return_value = 137
        recovered.filesystem.stat.side_effect = FileNotFoundError("fixture")
        with patch.object(room, "inventory", return_value=[]):
            with self.assertRaises(TimeoutError):
                room.run(self.modal, self.dataset, self.state)
        self.modal.Sandbox.create.assert_called_once()
        self.modal.Sandbox.from_name.assert_called_once()
        saved = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual(self.modal.Sandbox.from_name.call_args.args, (room.APP_NAME, saved["sandbox_name"]))
        recovered.terminate.assert_called_once_with(wait=True)

    def test_namespace_failure_records_receipt_without_attempting_rental(self):
        self.modal.App.lookup.side_effect = RuntimeError("private SDK detail")
        with patch.object(room, "inventory", return_value=[]):
            with self.assertRaises(RuntimeError):
                room.run(self.modal, self.dataset, self.state)
        self.modal.Sandbox.create.assert_not_called()
        self.modal.Sandbox.from_name.assert_not_called()
        saved = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual(saved["phase"], "failed")
        self.assertEqual(saved["failure_type"], "RuntimeError")
        self.assertNotIn("private SDK detail", json.dumps(saved))


class CollectionTests(unittest.TestCase):
    def test_collects_real_contract_without_nonexistent_remote_wrapper_log(self):
        with tempfile.TemporaryDirectory() as temp:
            sb = Mock()
            sb.filesystem.list_files.return_value = []
            sb.filesystem.stat.return_value.size = 7
            def copy(remote, local):
                local.parent.mkdir(parents=True, exist_ok=True)
                local.write_bytes(b"fixture")
            sb.filesystem.copy_to_local.side_effect = copy
            result = room.collect(sb, Path(temp) / "download")
            self.assertEqual(len(result), 4)
            self.assertNotIn("wrapper.log", [r["path"] for r in result])
            self.assertEqual(sum(r["bytes"] for r in result), 28)

    def test_size_cap_is_checked_before_downloading(self):
        with tempfile.TemporaryDirectory() as temp:
            sb = Mock()
            sb.filesystem.list_files.return_value = []
            sb.filesystem.stat.return_value.size = room.MAX_DOWNLOAD
            with self.assertRaisesRegex(ValueError, "512MiB"):
                room.collect(sb, Path(temp))
            sb.filesystem.copy_to_local.assert_not_called()


class DiagnosticTests(unittest.TestCase):
    def test_streamed_log_exists_before_process_wait_returns_and_records_exit(self):
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "stage.log"
            consumed = threading.Event()
            def stream():
                yield "trainer started\n"
                consumed.set()
            def wait():
                self.assertTrue(consumed.wait(2), "stdout was not drained while process ran")
                self.assertEqual(path.read_text(), "trainer started\n")
                return 137
            sb = SimpleNamespace(exec=lambda *a, **k: SimpleNamespace(
                stdout=stream(), stderr=iter(()), wait=wait))
            stage, snapshots = {}, []
            with self.assertRaises(room.StageFailure) as error:
                room.exec_to_log(sb, ["fixture"], 10, path, stage=stage,
                                 persist=lambda: snapshots.append(dict(stage)))
            self.assertEqual(error.exception.exit_code, 137)
            self.assertEqual(stage["exit_code"], 137)
            self.assertTrue(any(x["exit_code"] == 137 for x in snapshots))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_log_ceiling_drains_every_chunk_without_buffering_entire_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            yielded = []
            def stream():
                for n in range(100):
                    yielded.append(n)
                    yield "xxxxxxxx"
            sb = SimpleNamespace(exec=lambda *a, **k: SimpleNamespace(
                stdout=stream(), stderr=iter(()), wait=lambda: 0))
            with patch.object(room, "MAX_STAGE_LOG", 32):
                report = room.exec_to_log(sb, ["fixture"], 10, Path(tmp) / "log")
            self.assertEqual(len(yielded), 100)
            self.assertEqual(report["log_bytes"], 32)
            self.assertTrue(report["log_truncated"])
            self.assertEqual((Path(tmp) / "log").stat().st_size, 32)

    def test_stream_failure_cannot_erase_numeric_stage_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            def stream():
                yield "partial log"
                raise ConnectionError("SDK payload not serialized")
            sb = SimpleNamespace(exec=lambda *a, **k: SimpleNamespace(
                stdout=stream(), stderr=iter(()), wait=lambda: 137))
            stage = {}
            with self.assertRaises(ConnectionError):
                room.exec_to_log(sb, ["fixture"], 10, Path(tmp) / "log", stage=stage)
            self.assertEqual(stage["exit_code"], 137)
            self.assertEqual((Path(tmp) / "log").read_text(), "partial log")

    def test_failed_diagnostic_stat_is_recorded_not_silently_dropped(self):
        with tempfile.TemporaryDirectory() as tmp:
            sb = Mock()
            sb.filesystem.stat.side_effect = FileNotFoundError("private path")
            result = room.collect_failed_diagnostics(sb, Path(tmp))
            self.assertEqual(len(result), 3)
            self.assertTrue(all(not x["collected"] for x in result))
            self.assertTrue(all(x["error_type"] == "FileNotFoundError" for x in result))
            self.assertNotIn("private path", json.dumps(result))
            sb.filesystem.copy_to_local.assert_not_called()

    def test_provider_readback_failure_stays_unavailable(self):
        sb = SimpleNamespace(poll=lambda: None)
        self.assertEqual(room.provider_terminal(sb), {"poll_exit_code": None, "reason": "running"})
        sb = Mock()
        sb.poll.side_effect = RuntimeError("private provider payload")
        result = room.provider_terminal(sb)
        self.assertEqual(result["reason"], "unavailable")
        self.assertEqual(result["readback_error_type"], "RuntimeError")
        self.assertNotIn("payload", json.dumps(result))


if __name__ == "__main__":
    unittest.main(verbosity=2)
