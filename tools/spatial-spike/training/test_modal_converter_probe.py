"""Offline guards and mocked lifecycle only: no provider, GPU or conversion."""
import contextlib
import io
import json
import os
from pathlib import Path
import struct
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile

import converter_probe_remote as remote
import modal_ablation as ablation
import modal_converter_probe as probe
import modal_retry
import modal_room as room


class ProbeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        original = self.root / "modal-room-20260911-01"
        (original / "download/result").mkdir(parents=True)
        self.files = [{"path": "images/000001.jpg", "bytes": 1, "sha256": "a" * 64}]
        self.write(original / "provider-receipt.json", {"dataset_files": self.files})
        self.baseline_run = original / "download/result/run.json"
        self.write(self.baseline_run, {})
        self.cost = self.root / "cost.json"
        self.write(self.cost, {"budget_ceiling_usd": "25.00", "total_historical_spatial_usage_usd": "1.68002079",
                              "inventory": {"active_by_app": {"ap-old": 0},
                                            "exact_sandbox_terminal_polls": {"sb-old": 137}}})
        self.dataset = self.root / "dataset"
        self.dataset.mkdir()
        self.binding = {"commit": "fixture", "files": {}, "converter_files": {
            path.relative_to(probe.REPO).as_posix(): room.sha(path) for path in probe.PUBLIC_FILES.values()}}
        for target, name, value in ((ablation, "PRIVATE_ROOT", self.root), (modal_retry, "PRIVATE_ROOT", self.root),
                                    (ablation, "COST_BASELINE", self.cost),
                                    (ablation, "BASELINE_RUN", self.baseline_run),
                                    (ablation, "ORIGINAL_DATASET", self.dataset)):
            context = patch.object(target, name, value)
            context.start()
            self.addCleanup(context.stop)
        for target, name, value in ((room, "inventory", self.files),
                                    (room, "source_binding", self.binding),
                                    (probe, "source_binding", self.binding)):
            context = patch.object(target, name, return_value=value)
            context.start()
            self.addCleanup(context.stop)
        self.source = self.predecessor("b01", trained=True)
        self.d = self.predecessor("d01")
        self.plan_path = self.root / "plan.json"
        self.state = self.root / "probe"

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))

    def predecessor(self, label, trained=False):
        state = self.root / label
        state.mkdir()
        receipt = {"phase": "terminated", "app_id": f"ap-{label}", "sandbox_id": f"sb-{label}",
                   "remote_copy_delete": {"response": "success"}, "terminate": {"poll_exit_code": 137},
                   "outcome": "trained" if trained else "failed"}
        if trained:
            ply = state / "download/result/ply/point_cloud_29999.ply"
            ply.parent.mkdir(parents=True)
            names = ["x", "y", "z", "opacity", *(f"f_dc_{i}" for i in range(3)),
                     *(f"f_rest_{i}" for i in range(45)), *(f"scale_{i}" for i in range(3)),
                     *(f"rot_{i}" for i in range(4))]
            header = "ply\nformat binary_little_endian 1.0\nelement vertex 1\n"
            header += "".join(f"property float {name}\n" for name in names) + "end_header\n"
            ply.write_bytes(header.encode() + struct.pack("<" + "f" * len(names), *([0.0] * len(names))))
            receipt["artifacts"] = [{"path": "result/ply/point_cloud_29999.ply",
                                     "bytes": ply.stat().st_size, "sha256": room.sha(ply)}]
        self.write(state / "provider-receipt.json", receipt)
        self.write(self.root / f"spatial-ablation-20260914-{label}.allocation.json",
                   {"state": str(state), "reserved_usd": room.policy()["compute_upper_bound_usd"]})
        return state

    def save_plan(self):
        plan = probe.prepare(self.source, "converter01")
        self.write(self.plan_path, plan)
        return plan

    def modal(self):
        sb = Mock(object_id="sb-probe")
        sb.poll.return_value = None
        prior = Mock()
        prior.poll.return_value = 137
        provider = SimpleNamespace(__version__="1.5.3", App=Mock(), Sandbox=Mock(), Image=Mock())
        provider.App.lookup.return_value = SimpleNamespace(app_id="ap-probe")
        provider.Sandbox.list.return_value = []
        provider.Sandbox.from_id.return_value = prior
        provider.Sandbox.create.return_value = sb
        return provider, sb

    def test_plan_is_local_and_preserves_full_ledger_hold(self):
        plan = self.save_plan()
        self.assertEqual(plan["reserved_usd"], "4.9110336000")
        self.assertEqual(plan["policy"]["compute_upper_bound_usd"], "1.2277584000")
        self.assertEqual(plan["policy"]["timeout_seconds"], 1800)
        self.assertEqual(plan["combined_costs_and_holds_usd"], "16.4131215900")
        self.assertEqual((plan["sh_bands"], plan["sh_iterations"], plan["gpu_index"]), (3, 10, 0))
        self.assertFalse(plan["cpu_fallback_allowed"])
        self.assertFalse(plan["quality_acceptance_implied"])

    def test_default_cli_only_saves_plan_without_importing_modal(self):
        before = sys.modules.get("modal")
        with patch.object(sys, "argv", ["probe", "--source-state", str(self.source),
                                       "--label", "converter01", "--plan", str(self.plan_path)]):
            probe.main()
        self.assertIs(sys.modules.get("modal"), before)
        self.assertTrue(self.plan_path.exists())

    def test_active_or_missing_d_rejects_before_provider(self):
        path = self.d / "provider-receipt.json"
        receipt = json.loads(path.read_text())
        receipt["phase"] = "setup_started"
        self.write(path, receipt)
        with self.assertRaisesRegex(ValueError, "cleanup reconciliation"):
            self.save_plan()
        (self.root / "spatial-ablation-20260914-d01.allocation.json").unlink()
        with self.assertRaisesRegex(ValueError, "D must exist"):
            self.save_plan()

    def test_uncertain_cleanup_cannot_be_excused_for_media_probe(self):
        path = self.d / "provider-receipt.json"
        receipt = json.loads(path.read_text())
        receipt["remote_copy_delete"] = {"response": "failed"}
        self.write(path, receipt)
        with self.assertRaises(ValueError):
            self.save_plan()

    def test_budget_rejects_every_outstanding_attempt(self):
        self.predecessor("a01")
        self.predecessor("a02")
        with self.assertRaisesRegex(ValueError, "25"):
            self.save_plan()

    def test_only_closed_exact_billing_releases_hold(self):
        billing = {"app_id": "ap-d01", "sandbox_id": "sb-d01", "closed_hourly_intervals": True,
                   "actual_metered_usd": "0.50"}
        self.write(self.d / "billing-readback.json", billing)
        self.assertEqual(self.save_plan()["prior_costs_and_holds_usd"], "7.0910543900")
        billing["closed_hourly_intervals"] = False
        self.write(self.d / "billing-readback.json", billing)
        with self.assertRaisesRegex(ValueError, "billing attribution"):
            probe.prepare(self.source, "converter01")

    def test_ply_mutation_symlink_and_harmonic_loss_rejected(self):
        plan = self.save_plan()
        path = Path(plan["input_ply"])
        original = path.read_bytes()
        path.write_bytes(original[:-1])
        with self.assertRaisesRegex(ValueError, "payload size"):
            probe.prepare(self.source, "converter01")
        path.write_bytes(original.replace(b"f_rest_44", b"f_rest_45"))
        with self.assertRaisesRegex(ValueError, "three-SH"):
            probe.prepare(self.source, "converter01")
        path.write_bytes(original)
        moved = path.with_suffix(".backup")
        path.rename(moved)
        path.symlink_to(moved)
        with self.assertRaises(ValueError):
            probe.prepare(self.source, "converter01")

    def test_provider_active_predecessor_or_changed_plan_never_creates(self):
        self.save_plan()
        provider, _ = self.modal()
        provider.Sandbox.list.return_value = [Mock()]
        with self.assertRaisesRegex(ValueError, "active"):
            probe.execute(provider, self.plan_path, self.state)
        provider.App.lookup.assert_not_called()
        provider.Sandbox.create.assert_not_called()
        provider.Sandbox.list.return_value = []
        provider.Sandbox.from_id.return_value.poll.return_value = None
        with self.assertRaisesRegex(ValueError, "not terminal"):
            probe.execute(provider, self.plan_path, self.state)
        provider.Sandbox.create.assert_not_called()
        provider.Sandbox.from_id.return_value.poll.return_value = 137
        plan = json.loads(self.plan_path.read_text())
        plan["sh_iterations"] = 1
        self.write(self.plan_path, plan)
        with self.assertRaisesRegex(ValueError, "reviewed plan"):
            probe.execute(provider, self.plan_path, self.state)
        provider.Sandbox.create.assert_not_called()

    def test_marker_precedes_sole_create_and_ambiguous_create_never_retries(self):
        plan = self.save_plan()
        provider, _ = self.modal()
        marker = self.root / "spatial-ablation-20260914-converter01.allocation.json"
        def ambiguous(**options):
            self.assertTrue(marker.exists())
            self.assertEqual(options["timeout"], 1800)
            self.assertEqual((options["gpu"], options["cpu"], options["memory"]),
                             ("L4", (4.0, 4.0), (32768, 32768)))
            for key in ("secrets", "encrypted_ports", "unencrypted_ports", "h2_ports"):
                self.assertEqual(options[key], [])
            self.assertEqual(options["volumes"], {})
            raise TimeoutError()
        provider.Sandbox.create.side_effect = ambiguous
        provider.Sandbox.from_name.side_effect = TimeoutError()
        with self.assertRaises(TimeoutError):
            probe.execute(provider, self.plan_path, self.state)
        self.assertEqual(provider.Sandbox.create.call_count, 1)
        self.assertEqual(provider.Sandbox.from_name.call_count, 1)
        receipt = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual(receipt["phase"], "allocation_unresolved_no_retry")
        self.assertEqual(receipt["transferred_files"], [])
        self.assertEqual(json.loads(marker.read_text())["reserved_usd"], plan["reserved_usd"])
        with self.assertRaises(ValueError):
            probe.execute(provider, self.plan_path, self.state)
        self.assertEqual(provider.Sandbox.create.call_count, 1)

    def test_setup_failure_retains_numeric_exit_and_deletes_then_terminates(self):
        self.save_plan()
        provider, sb = self.modal()
        operations = []
        sb.filesystem.remove.side_effect = lambda *a, **k: operations.append("delete")
        sb.terminate.side_effect = lambda **k: operations.append("terminate")
        sb.poll.return_value = 137
        def failed(_sb, argv, seconds, logfile, *, stage, persist):
            stage["exit_code"] = 143
            persist()
            raise room.StageFailure(143)
        with patch.object(room, "exec_to_log", side_effect=failed), \
                patch.object(probe, "diagnostics", return_value=[]), \
                patch.object(room, "provider_terminal", return_value={"poll_exit_code": 137}):
            with self.assertRaises(room.StageFailure):
                probe.execute(provider, self.plan_path, self.state)
        receipt = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual(operations, ["delete", "terminate"])
        self.assertEqual(receipt["stages"]["setup"]["exit_code"], 143)
        self.assertEqual(receipt["transferred_files"], [])
        self.assertEqual(receipt["phase"], "terminated")
        self.assertEqual(receipt["outcome"], "failed")
        ablation.require_cleanup_reconciled(self.state / "provider-receipt.json", receipt)

    def test_conversion_failure_only_after_device_and_network_denial(self):
        self.save_plan()
        provider, sb = self.modal()
        order = []
        sb.poll.return_value = 137
        sb.terminate.return_value = None
        sb._experimental_set_outbound_network_policy.side_effect = lambda **kw: order.append(
            "deny" if not kw["outbound_cidr_allowlist"] else "allow")
        def transfer(local, remote_path):
            if remote_path.endswith("input.ply"):
                self.assertEqual(order[-1], "deny")
                order.append("private")
        sb.filesystem.copy_from_local.side_effect = transfer
        def stage(_sb, argv, seconds, logfile, *, stage, persist):
            name = logfile.stem
            order.append(name)
            stage["exit_code"] = 7 if name == "conversion" else 0
            persist()
            if name == "conversion":
                self.assertLess(order.index("device"), order.index("private"))
                self.assertEqual(argv[-2:], ["--gaussian-count", "1"])
                raise room.StageFailure(7)
        def collect(_sb, state, name, maximum):
            target = state / "download" / name
            target.parent.mkdir()
            self.write(target, {"success": True, "device": {"nvidia_l4": True, "adapter_count": 1},
                                "vulkan": {"vulkan_available": True}})
            return {"path": name, "bytes": target.stat().st_size, "sha256": room.sha(target)}
        with patch.object(room, "exec_to_log", side_effect=stage), patch.object(probe, "collect_file", side_effect=collect), \
                patch.object(probe, "diagnostics", return_value=[]), \
                patch.object(room, "provider_terminal", return_value={"poll_exit_code": 137}):
            with self.assertRaises(room.StageFailure):
                probe.execute(provider, self.plan_path, self.state)
        receipt = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual(receipt["stages"]["conversion"]["exit_code"], 7)
        self.assertEqual(receipt["transferred_files"], ["input.ply"])
        self.assertEqual(provider.Sandbox.create.call_count, 1)
        sb.filesystem.remove.assert_called_once_with(room.REMOTE, recursive=True)
        sb.terminate.assert_called_once_with(wait=True)
        self.assertFalse(receipt["training_performed"])

    def test_failed_directory_delete_is_never_reported_as_success(self):
        self.save_plan()
        provider, sb = self.modal()
        sb.poll.return_value = 137
        sb.terminate.return_value = None
        sb.filesystem.remove.side_effect = ConnectionError()
        with patch.object(room, "exec_to_log", side_effect=room.StageFailure(143)), \
                patch.object(probe, "diagnostics", return_value=[]), \
                patch.object(room, "provider_terminal", return_value={"poll_exit_code": 137}):
            with self.assertRaisesRegex(ValueError, "cleanup requires follow-up"):
                probe.execute(provider, self.plan_path, self.state)
        receipt = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual(receipt["remote_copy_delete"]["response"], "failed")
        self.assertEqual(receipt["terminate"]["poll_exit_code"], 137)
        sb.terminate.assert_called_once_with(wait=True)
        with self.assertRaises(ValueError):
            ablation.require_cleanup_reconciled(self.state / "provider-receipt.json", receipt)

    def test_explicit_run_requires_confirmation_before_provider_import(self):
        with patch.object(sys, "argv", ["probe", "run", "--plan", str(self.plan_path),
                                       "--state", str(self.state)]):
            with self.assertRaisesRegex(ValueError, "explicit single allocation"):
                probe.main()

    def test_output_size_is_checked_before_copy(self):
        provider, sb = self.modal()
        sb.filesystem.stat.return_value = SimpleNamespace(size=32 * 1024**2 + 1)
        with self.assertRaisesRegex(ValueError, "bounded converter output"):
            probe.collect_file(sb, self.state, "model.sog", probe.MAX_OUTPUT_BYTES)
        sb.filesystem.copy_to_local.assert_not_called()

    def test_success_keeps_artifact_hashes_and_existing_ledger_compatibility(self):
        plan = self.save_plan()
        provider, sb = self.modal()
        sb.poll.return_value = 137
        sb.terminate.return_value = None
        fixtures = self.root / "remote-fixtures"
        fixtures.mkdir()
        sog = fixtures / "model.sog"
        with zipfile.ZipFile(sog, "w") as archive:
            archive.writestr("meta.json", json.dumps({"version": 2, "count": 1,
                "asset": {"generator": "splat-transform v3.4.2"}, "shN": {"bands": 3}}))
            for name in ("means_l", "means_u", "quats", "scales", "sh0", "shN_centroids", "shN_labels"):
                archive.writestr(name + ".webp", b"synthetic-validation-fixture")
        self.write(fixtures / "device-receipt.json", {
            "success": True, "device": {"nvidia_l4": True, "adapter_count": 1},
            "vulkan": {"vulkan_available": True}})
        self.write(fixtures / "conversion-receipt.json", {
            "success": True, "input": {key: plan["input"][key] for key in ("sha256", "bytes", "gaussian_count")},
            "gpu_usage": {"gpu_memory_used": True}, "sh_bands": 3, "sh_iterations": 10,
            "output": remote.validate_sog(sog, 1)})
        sb.filesystem.stat.side_effect = lambda path: SimpleNamespace(size=(fixtures / Path(path).name).stat().st_size)
        sb.filesystem.copy_to_local.side_effect = lambda path, target: shutil.copyfile(fixtures / Path(path).name, target)
        def success(_sb, argv, seconds, logfile, *, stage, persist):
            stage["exit_code"] = 0
            persist()
        with patch.object(room, "exec_to_log", side_effect=success):
            probe.execute(provider, self.plan_path, self.state)
        receipt = json.loads((self.state / "provider-receipt.json").read_text())
        self.assertEqual((receipt["phase"], receipt["outcome"]), ("terminated", "converted"))
        output = next(item for item in receipt["artifacts"] if item["path"] == "model.sog")
        self.assertEqual(output["sha256"], room.sha(self.state / "download/model.sog"))
        self.assertEqual(os.stat(self.state / "provider-receipt.json").st_mode & 0o777, 0o600)
        ablation.require_cleanup_reconciled(self.state / "provider-receipt.json", receipt)
        ledger = ablation.prepare(self.dataset, "a00")
        self.assertEqual(ledger["prior_costs_and_holds_usd"], "16.4131215900")
        self.assertEqual(len(ledger["predecessors"]), 3)
        self.assertEqual(provider.Sandbox.create.call_count, 1)


class RemoteValidationTests(unittest.TestCase):
    def test_exact_adapter_and_no_fallback(self):
        self.assertTrue(remote.validate_adapters("[0] NVIDIA L4\n")["nvidia_l4"])
        for text in ("No GPU adapters found.", "[0] llvmpipe\n", "[1] NVIDIA L4\n",
                     "[0] NVIDIA L4\n[1] SwiftShader\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                remote.validate_adapters(text)
        log = "500,000 gaussians · 3 SH bands\ndone in 10s  [peak cpu=1.5 GiB gpu=512.00 MiB]"
        self.assertTrue(remote.validate_conversion_log(log)["gpu_memory_used"])
        for invalid in (log + "\nGPU adapter index 0 not found, using default", log.replace(" gpu=512.00 MiB", ""),
                        log.replace("3 SH bands", "0 SH bands"), log.replace("512.00", "0.00")):
            with self.assertRaises(ValueError):
                remote.validate_conversion_log(invalid)

    def test_vulkan_device_requires_hardware_l4(self):
        text = "deviceName = NVIDIA L4\nvendorID = 0x10de\ndeviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n"
        text += "driverID = DRIVER_ID_NVIDIA_PROPRIETARY\ndriverVersion = 580.95.5\n"
        self.assertEqual(remote.validate_vulkan(text)["vendor_id"], 0x10DE)
        with self.assertRaises(ValueError):
            remote.validate_vulkan(text.replace("NVIDIA L4", "llvmpipe"))
        with self.assertRaises(ValueError):
            remote.validate_vulkan(text + "deviceName = NVIDIA L4\n")

    def test_vulkan_observed_packed_driver_version_requires_matching_hex(self):
        text = "deviceName = NVIDIA L4\nvendorID = 0x10de\ndeviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n"
        text += "driverID = DRIVER_ID_NVIDIA_PROPRIETARY\n"
        text += "driverVersion = 2434253120 (0x9117c140)\ndriverInfo = 580.95.05\n"
        result = remote.validate_vulkan(text)
        self.assertEqual(result["driver_version_uint32"], 2434253120)
        self.assertEqual(result["driver_info_version"], "580.95.05")
        self.assertEqual(result["driver_version"], "2434253120 (0x9117c140)")
        with self.assertRaises(ValueError):
            remote.validate_vulkan(text.replace("0x9117c140", "0x9117c141"))
        with self.assertRaises(ValueError):
            remote.validate_vulkan(text.replace("2434253120 (0x9117c140)", "4294967296 (0x100000000)"))

    def test_bounded_cpu_child_timeout_and_output_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.log"
            with patch.object(remote, "MAX_LOG", 100):
                result = remote.run_bounded([sys.executable, "-c", "print('x'*1000)"], 5, path)
            self.assertEqual(result["exit_code"], 0)
            self.assertTrue(result["log_truncated"])
            self.assertEqual(path.stat().st_size, 100)
            result = remote.run_bounded([sys.executable, "-c", "import time; time.sleep(5)"], 0.05,
                                        Path(directory) / "timeout.log")
            self.assertTrue(result["timed_out"])
            self.assertLess(result["exit_code"], 0)

    def test_sog_must_keep_count_three_sh_and_pinned_generator(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.sog"
            def archive(bands=3):
                with zipfile.ZipFile(path, "w") as result:
                    result.writestr("meta.json", json.dumps({"version": 2, "count": 1,
                        "asset": {"generator": "splat-transform v3.4.2"}, "shN": {"bands": bands}}))
                    for name in ("means_l", "means_u", "quats", "scales", "sh0", "shN_centroids", "shN_labels"):
                        result.writestr(name + ".webp", b"synthetic-validation-fixture")
            archive()
            self.assertEqual(remote.validate_sog(path, 1)["sh_bands"], 3)
            with self.assertRaises(ValueError):
                remote.validate_sog(path, 2)
            archive(0)
            with self.assertRaises(ValueError):
                remote.validate_sog(path, 1)
            with patch.object(remote, "MAX_OUTPUT", 10), self.assertRaisesRegex(ValueError, "32MiB"):
                remote.validate_sog(path, 1)


if __name__ == "__main__":
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
