"""Strict offline provider-boundary execution, not a successful GPU run."""
from decimal import Decimal, ROUND_CEILING
from contextlib import redirect_stdout
from io import BytesIO, StringIO
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import Mock, patch

from worker import JobFailure, MIN_COST_RESERVATION_CENTS, TRAINING_ROOT
from modal_provider import (ModalProvider, TRAINER_COMMIT, compute_bound_cents, copy_bounded_json,
                            dependency_baseline_digest, dependency_verification_command, quality_record,
                            converter_input, converter_link_command, conversion_record)
from provider_journal import sandbox_name
from test_worker import JOB_ID, LEASE_ID, job

sys.path.insert(0, str(TRAINING_ROOT))
import modal_room
import converter_probe_remote

try:
    # The pinned SDK's own local name validator, the one Sandbox.create runs
    # before any RPC. Importing it authenticates nothing and allocates nothing.
    from modal._utils import name_utils as modal_names
    import modal as modal_sdk
except ImportError:  # the suite must still run where the SDK is not installed
    modal_names = modal_sdk = None


class ProviderFixture(unittest.TestCase):
    """Shared offline provider fixture; the test classes below hold the cases."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.modal = Mock(); self.modal.__version__ = "1.5.3"
        self.app = SimpleNamespace(name="rendprop-spatial-worker")
        self.sb = self.modal.Sandbox.create.return_value
        self.sb.object_id = "sb-fixture1234"; self.sb.poll.return_value = 137
        self.metadata = {"status": "trained", "gsplat_commit": TRAINER_COMMIT, "frames": 20,
                         "max_steps": 3000, "max_seconds": 900, "max_gaussians": 500000,
                         "gaussian_count": 100, "world_normalization": False,
                         "pose_optimization": True, "elapsed_seconds": 200.5,
                         "ply": f"{modal_room.REMOTE}/result/ply/point_cloud_2999.ply",
                         "ply_bytes": 23701, "ply_sha256": "a" * 64}
        self.metrics = {"psnr": 19.6, "ssim": 0.81, "lpips": 0.55, "num_GS": 100}
        self.adapter_log = "[0] NVIDIA L4\n"
        self.vulkan_log = ("deviceName = NVIDIA L4\nvendorID = 0x10de\n"
                           "deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n"
                           "driverID = DRIVER_ID_NVIDIA_PROPRIETARY\n"
                           "driverVersion = 2434253120 (0x9117c140)\ndriverInfo = 580.95.05\n")
        self.conversion_log = "100 gaussians · 3 SH bands\ndone in 10s [peak cpu=100MB gpu=112.9MB]\n"
        process = {"exit_code": 0, "timed_out": False, "log_truncated": False, "elapsed_seconds": 1.0}
        self.device = {"schema_version": 1, "stage": "device", "success": True, "sh_bands": 3,
                       "sh_iterations": 10, "automatic_retries": 0, "node_version": "v22.22.0",
                       "converter_version": "3.4.2", "webgpu_version": "0.4.0", "icd_sha256": "b" * 64,
                       "process": dict(process), "vulkan_process": dict(process),
                       "device": converter_probe_remote.validate_adapters(self.adapter_log),
                       "vulkan": converter_probe_remote.validate_vulkan(self.vulkan_log)}
        data = BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr("meta.json", json.dumps({"version": 2, "count": 100,
                "asset": {"generator": "splat-transform v3.4.2"}, "shN": {"bands": 3}}))
            for name in ("means_l", "means_u", "quats", "scales", "sh0", "shN_centroids", "shN_labels"):
                archive.writestr(name + ".webp", b"synthetic-validation-fixture")
        self.sog = data.getvalue()
        self.converted = {key: self.device[key] for key in ("schema_version", "success", "sh_bands", "sh_iterations",
                          "automatic_retries", "node_version", "converter_version", "webgpu_version", "icd_sha256", "device")}
        self.converted.update(stage="convert", process=dict(process), input={"sha256": self.metadata["ply_sha256"],
                              "bytes": self.metadata["ply_bytes"], "gaussian_count": 100},
                              gpu_usage=converter_probe_remote.validate_conversion_log(self.conversion_log),
                              output={"bytes": len(self.sog), "sha256": hashlib.sha256(self.sog).hexdigest(),
                                      "gaussian_count": 100, "sh_bands": 3, "sog_version": 2})
        def content(remote):
            if remote.endswith("device-receipt.json"):
                return json.dumps(self.device).encode()
            if remote.endswith("conversion-receipt.json"):
                return json.dumps(self.converted).encode()
            for name, text in (("device.log", self.adapter_log), ("vulkan.log", self.vulkan_log),
                               ("conversion.log", self.conversion_log)):
                if remote.endswith(name):
                    return text.encode()
            if remote.endswith("run.json"):
                return json.dumps(self.metadata).encode()
            if remote.endswith(f"val_step{self.metadata['max_steps'] - 1:04d}.json"):
                return json.dumps(self.metrics).encode()
            return self.sog
        self.sb.filesystem.stat.side_effect = lambda remote: SimpleNamespace(size=len(content(remote)))
        def copy(remote, local):
            local.parent.mkdir(parents=True, exist_ok=True)
            local.write_bytes(content(remote))
        self.sb.filesystem.copy_to_local.side_effect = copy
        self.journal_rows = []
        def journal_call(j, route, **fields):
            self.assertEqual(route, "provider-attempt")
            self.journal_rows.append(fields)
            return {"ok": True, "job_id": j["id"], "lease_token": j["lease_token"],
                    "attempt_key": j["attempt_key"], "dispatch": True, **fields["data"]}
        self.api = SimpleNamespace(job_call=Mock(side_effect=journal_call))
        self.lease = SimpleNamespace(check=Mock(), stage=Mock(), abort=lambda: None, provider_stopped=True, api=self.api)
        self.capture = {"frames": [{"pose": [[1,0,0,0],[0,1,0,1.6],[0,0,1,0],[0,0,0,1]]} for _ in range(20)],
                        "seeds": [{"position": [-1,0,-1]}, {"position": [1,2,1]}]}
        self.provider = ModalProvider(self.modal, self.app)


class ProviderTests(ProviderFixture):
    def test_runtime_ttl_no_secrets_network_denial_and_termination(self):
        order = []
        self.sb._experimental_set_outbound_network_policy.side_effect = lambda **k: order.append(("network", k))
        self.sb.filesystem.copy_from_local.side_effect = lambda p, r: order.append(("copy", r))
        with patch.object(modal_room, "inventory", return_value=[{"path": "images/000000.jpg"}]), \
                patch.object(modal_room, "exec_to_log") as execute:
            output, manifest = self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.assertEqual(output.read_bytes(), self.sog)
        self.assertEqual(manifest["gaussian_count"], 100)
        create = self.modal.Sandbox.create.call_args.kwargs
        # The TTL travels with CREATE: deadline minus 120s of controller slack,
        # never above the 7200s ceiling and never below the 2400s admission floor.
        self.assertTrue(2280 <= create["timeout"] <= 7080, create["timeout"])
        self.assertEqual(create["secrets"], [])
        self.assertEqual(create["volumes"], {})
        # Every priced dimension is pinned, not just the GPU class: the cost
        # bound below is only meaningful for exactly this shape.
        self.assertEqual(create["gpu"], "L4")
        self.assertEqual(create["cpu"], (4.0, 4.0))
        self.assertEqual(create["memory"], (32768, 32768))
        self.assertEqual(create["region"], "us")
        self.assertEqual(create["name"], "spatial-" + LEASE_ID)
        self.assertLessEqual(compute_bound_cents(create), job()["max_cost_cents"])
        receipt = json.loads((self.root / "provider-receipt.json").read_text())
        self.assertEqual(receipt["compute_bound_cents"], compute_bound_cents(create))
        deny = max(i for i, entry in enumerate(order) if entry == ("network", {"outbound_cidr_allowlist": [], "outbound_domain_allowlist": []}))
        media = next(i for i, entry in enumerate(order) if entry[0] == "copy" and "/dataset/" in entry[1])
        self.assertLess(deny, media)
        self.assertEqual(execute.call_count, 6)
        training = execute.call_args_list[3].args[1]
        self.assertEqual(training.count("--pose-opt"), 1)
        self.assertEqual(training[training.index("--max-seconds") + 1], "900")
        self.assertEqual(training[training.index("--max-steps") + 1], "3000")
        self.assertIs(receipt["quality"]["pose_optimization"], True)
        self.sb.terminate.assert_called_once_with(wait=True)
        self.sb.filesystem.remove.assert_called_once_with(modal_room.REMOTE, recursive=True)
        self.assertIs(self.lease.provider_stopped, True)

    def test_candidate_bounds_drive_deadline_metrics_and_converter_input_without_extending_provider_lifetime(self):
        value_job = job()
        value_job.update(max_iterations=30000, max_training_seconds=4200)
        self.metadata.update(max_steps=30000, max_seconds=4200,
                             ply=f"{modal_room.REMOTE}/result/ply/point_cloud_29999.ply")
        with patch.object(modal_room, "inventory", return_value=[]), \
                patch.object(modal_room, "exec_to_log") as execute, redirect_stdout(StringIO()):
            self.provider.reconstruct(value_job, self.root, self.capture, self.lease)
        training_call = execute.call_args_list[3]
        training = training_call.args[1]
        self.assertEqual(training[training.index("--max-steps") + 1], "30000")
        self.assertEqual(training[training.index("--max-seconds") + 1], "4200")
        self.assertEqual(training[training.index("--max-gaussians") + 1], "500000")
        self.assertEqual(training.count("--pose-opt"), 1)
        self.assertEqual(training_call.args[2], 4300)
        downloads = [call.args[0] for call in self.sb.filesystem.copy_to_local.call_args_list]
        self.assertIn(f"{modal_room.REMOTE}/result/stats/val_step29999.json", downloads)
        link_call = execute.call_args_list[4]
        self.assertIn(f"{modal_room.REMOTE}/result/ply/point_cloud_29999.ply", link_call.args[1][2])
        self.assertEqual(link_call.args[2], 30)
        converter_call = execute.call_args_list[5]
        self.assertEqual(converter_call.args[1][:3], ["python", f"{modal_room.REMOTE}/converter_probe_remote.py", "convert"])
        self.assertEqual(converter_call.args[2], 630)
        receipt = json.loads((self.root / "provider-receipt.json").read_text())
        self.assertEqual(receipt["quality"]["steps"], 30000)
        self.assertIs(receipt["quality"]["pose_optimization"], True)
        create = self.modal.Sandbox.create.call_args.kwargs
        self.assertLessEqual(create["timeout"], 7080)
        self.assertLessEqual(compute_bound_cents(create), value_job["max_cost_cents"])
        self.assertEqual(create["secrets"], [])
        self.modal.Sandbox.create.assert_called_once()
        self.sb.terminate.assert_called_once_with(wait=True)

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
        # Reconciliation looks up exactly the name that was sent with CREATE.
        self.assertEqual(self.modal.Sandbox.from_name.call_args.args,
                         ("rendprop-spatial-worker", self.modal.Sandbox.create.call_args.kwargs["name"]))
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


class QualityReceiptTests(ProviderFixture):
    def test_receipt_allowlist_excludes_arbitrary_trainer_fields(self):
        self.metadata.update(command=["/private/path", "secret-canary"], token="secret-canary",
                             resolved_dependencies=["private-source"], room_label="private-room")
        self.metrics.update(raw_image="private-pixels", source_path="/private/path")
        record = quality_record(job(), self.sb.object_id, 20, self.metadata, self.metrics, pose_opt=True)
        self.assertEqual(set(record), {"event", "job_id", "sandbox_id", "trainer_commit", "frames",
                         "loss_heldout_count", "test_every", "seed", "pose_optimization", "steps",
                         "gaussians", "training_elapsed_seconds", "psnr", "ssim", "lpips", "evaluation"})
        self.assertEqual(record["evaluation"], "loss_held_out_seed_initialization_uses_all_frames")
        self.assertEqual((record["loss_heldout_count"], record["test_every"], record["seed"]), (3, 8, 42))
        self.assertFalse(any(value in json.dumps(record) for value in
                             ("private", "secret-canary", "command", "token")))
        dense_job = job(); dense_job["manifest"]["frames"] = ["frame"] * 153
        self.assertEqual(quality_record(dense_job, self.sb.object_id, 153,
                         {**self.metadata, "frames": 153}, self.metrics, pose_opt=True)["loss_heldout_count"], 20)

    def test_nonfinite_or_invalid_metric_ranges_fail_without_quality_log(self):
        for field, value in (("psnr", float("nan")), ("psnr", float("inf")), ("psnr", -0.01),
                             ("ssim", 1.01), ("ssim", -1.01), ("lpips", -0.01),
                             ("lpips", float("inf")), ("psnr", True), ("ssim", "0.81")):
            with self.subTest(field=field, value=value), self.assertRaisesRegex(JobFailure, "invalid_training_quality"):
                quality_record(job(), self.sb.object_id, 20, self.metadata, {**self.metrics, field: value}, pose_opt=True)

    def test_metadata_must_match_claimed_job_and_pinned_trainer(self):
        for change in ({"status": "running"}, {"gsplat_commit": "wrong-commit"}, {"frames": 21},
                       {"max_steps": 3001}, {"max_seconds": 901}, {"max_gaussians": 500001},
                       {"gaussian_count": 0}, {"gaussian_count": 101}, {"gaussian_count": True},
                       {"world_normalization": True}, {"pose_optimization": False},
                       {"elapsed_seconds": float("nan")}, {"elapsed_seconds": -1},
                       {"elapsed_seconds": 1001}):
            with self.subTest(change=change), self.assertRaises(JobFailure):
                quality_record(job(), self.sb.object_id, 20, {**self.metadata, **change}, self.metrics, pose_opt=True)
        with self.assertRaisesRegex(JobFailure, "frame_count"):
            quality_record(job(), self.sb.object_id, 21, self.metadata, self.metrics, pose_opt=True)
        with self.assertRaisesRegex(JobFailure, "gaussian_count"):
            quality_record(job(), self.sb.object_id, 20, self.metadata, {**self.metrics, "num_GS": True}, pose_opt=True)

    def test_quality_pose_flag_must_match_actual_trainer_receipt_in_both_directions(self):
        for pose_opt in (False, True):
            metadata = {**self.metadata, "pose_optimization": pose_opt}
            with self.subTest(pose_opt=pose_opt):
                record = quality_record(job(), self.sb.object_id, 20, metadata, self.metrics, pose_opt=pose_opt)
                self.assertIs(record["pose_optimization"], pose_opt)
                with self.assertRaisesRegex(JobFailure, "training_output_unconfirmed"):
                    quality_record(job(), self.sb.object_id, 20, metadata, self.metrics, pose_opt=not pose_opt)

    def test_copy_checks_positive_bounded_size_before_transfer_and_exact_size_after(self):
        for index, size in enumerate((0, -1, True, 1024**2 + 1, 1.5)):
            sb = Mock(); sb.filesystem.stat.return_value.size = size
            with self.subTest(size=size), self.assertRaisesRegex(JobFailure, "too_large"):
                copy_bounded_json(sb, "/result/run.json", self.root / f"run-{index}.json", 1024**2)
            sb.filesystem.copy_to_local.assert_not_called()
        sb = Mock(); sb.filesystem.stat.return_value.size = 65537
        with self.assertRaisesRegex(JobFailure, "too_large"):
            copy_bounded_json(sb, "/result/stats/val_step2999.json", self.root / "stats.json", 64 * 1024)
        sb.filesystem.copy_to_local.assert_not_called()
        sb.filesystem.stat.return_value.size = 1
        sb.filesystem.copy_to_local.side_effect = lambda remote, local: local.write_text("{}")
        with self.assertRaisesRegex(JobFailure, "size_changed"):
            copy_bounded_json(sb, "/result/run.json", self.root / "changed.json", 1024**2)

    def test_conversion_failure_keeps_numeric_log_and_local_receipt_before_cleanup(self):
        output = StringIO()
        self.metadata["token"] = "must-never-be-logged"
        stages = []
        def execute(sb, command, *args, **kwargs):
            stages.append(command)
            if command[2:3] == ["convert"]:
                self.assertIn('"event": "spatial_training_quality"', output.getvalue())
                raise modal_room.StageFailure(1)
        with patch.object(modal_room, "inventory", return_value=[]), \
                patch.object(modal_room, "exec_to_log", side_effect=execute), redirect_stdout(output):
            with self.assertRaisesRegex(JobFailure, "generation_failed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        quality = json.loads(lines[0])
        self.assertEqual(quality["psnr"], 19.6)
        self.assertNotIn("must-never-be-logged", output.getvalue())
        receipt = json.loads((self.root / "provider-receipt.json").read_text())
        self.assertEqual(receipt["quality"], quality)
        self.assertEqual(len(stages), 6)
        self.assertTrue(receipt["private_files_removed"])
        self.assertTrue(receipt["terminated"])
        self.assertEqual(self.journal_rows[-1]["action"], "cleanup")
        self.sb.terminate.assert_called_once_with(wait=True)

    def test_invalid_metrics_prevent_conversion_and_log_but_still_clean_up(self):
        self.metrics["ssim"] = float("nan")
        output = StringIO()
        with patch.object(modal_room, "inventory", return_value=[]), \
                patch.object(modal_room, "exec_to_log") as execute, redirect_stdout(output):
            with self.assertRaisesRegex(JobFailure, "invalid_training_quality"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.assertEqual(execute.call_count, 4)
        self.assertEqual(output.getvalue(), "")
        self.sb.terminate.assert_called_once_with(wait=True)


class GpuExportTests(ProviderFixture):
    def test_invalid_device_stops_before_any_room_transfer_and_cleans_up(self):
        self.adapter_log = "[0] llvmpipe\n"
        with patch.object(modal_room, "inventory", return_value=[{"path": "images/000001.jpg"}]), \
                patch.object(modal_room, "exec_to_log"), redirect_stdout(StringIO()):
            with self.assertRaisesRegex(JobFailure, "invalid_converter_device"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        copies = [call.args[1] for call in self.sb.filesystem.copy_from_local.call_args_list]
        self.assertFalse(any("/dataset/" in path for path in copies))
        self.assertIn(f"{modal_room.REMOTE}/converter_probe_remote.py", copies)
        self.assertEqual(self.modal.Sandbox.create.call_args.kwargs["env"]["NVIDIA_DRIVER_CAPABILITIES"],
                         "compute,graphics,utility")
        receipt = json.loads((self.root / "provider-receipt.json").read_text())
        self.assertNotIn("gpu_device_verified_before_media", receipt)
        self.assertTrue(receipt["private_files_removed"])
        self.assertTrue(receipt["terminated"])
        self.sb.terminate.assert_called_once_with(wait=True)
        self.assertEqual(self.journal_rows[-1]["action"], "cleanup")

    def test_device_execution_failure_transfers_no_private_bytes(self):
        def execute(sandbox, command, *args, **kwargs):
            if command[2:3] == ["device"]:
                kwargs["stage"]["exit_code"] = 1
                kwargs["persist"]()
                raise modal_room.StageFailure(1)
        with patch.object(modal_room, "inventory", return_value=[{"path": "images/000001.jpg"}]), \
                patch.object(modal_room, "exec_to_log", side_effect=execute):
            with self.assertRaisesRegex(JobFailure, "generation_failed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.assertFalse(any("/dataset/" in call.args[1] for call in self.sb.filesystem.copy_from_local.call_args_list))
        receipt = json.loads((self.root / "provider-receipt.json").read_text())
        self.assertEqual(receipt["stages"]["device"]["exit_code"], 1)
        self.assertTrue(receipt["terminated"])

    def test_helper_must_remain_exact_validated_source_before_allocation(self):
        with patch.object(modal_room, "sha", return_value="0" * 64):
            with self.assertRaisesRegex(JobFailure, "converter_helper_changed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.modal.Sandbox.create.assert_not_called()
        self.assertEqual(self.journal_rows, [])

    def test_trainer_ply_binding_rejects_wrong_paths_hashes_and_sizes(self):
        expected = converter_input(job(), self.metadata, modal_room.REMOTE)
        self.assertEqual(expected, self.converted["input"])
        for change in ({"ply": "/private/other.ply"}, {"ply": f"{modal_room.REMOTE}/result/ply/../other.ply"},
                       {"ply_sha256": "wrong"}, {"ply_sha256": None}, {"ply_bytes": True},
                       {"ply_bytes": 0}, {"ply_bytes": 512 * 1024**2 + 1}):
            with self.subTest(change=change), self.assertRaisesRegex(JobFailure, "invalid_converter_input"):
                converter_input(job(), {**self.metadata, **change}, modal_room.REMOTE)

    def test_fixed_hardlink_preserves_source_and_refuses_existing_or_linked_input(self):
        command = converter_link_command(job(), self.metadata, modal_room.REMOTE)
        # Run only the path/link guard on a synthetic local file, never a converter.
        local_root = (self.root / "link-fixture").resolve()
        source = local_root / "result/ply/point_cloud_2999.ply"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"x" * self.metadata["ply_bytes"])
        code = command[2].replace(modal_room.REMOTE, str(local_root))
        with redirect_stdout(StringIO()):
            exec(compile(code, "<synthetic-link-guard>", "exec"), {})
        target = local_root / "input.ply"
        self.assertEqual(source.stat().st_ino, target.stat().st_ino)
        self.assertEqual(source.read_bytes(), target.read_bytes())
        with self.assertRaises(RuntimeError):
            exec(compile(code, "<existing-link-guard>", "exec"), {})
        target.unlink()
        actual = source.with_name("actual.ply")
        source.rename(actual)
        source.symlink_to(actual)
        with self.assertRaisesRegex(RuntimeError, "invalid trained PLY path"):
            exec(compile(code, "<symlink-guard>", "exec"), {})

    def test_receipt_input_profile_and_gpu_proof_must_match(self):
        binding = converter_input(job(), self.metadata, modal_room.REMOTE)
        for change in ({"input": {**binding, "sha256": "c" * 64}}, {"sh_bands": 0},
                       {"sh_iterations": 1}, {"converter_version": "3.4.3"}, {"success": False},
                       {"device": {"adapter_count": 1, "cpu_fallback_allowed": True}},
                       {"process": {**self.converted["process"], "timed_out": True}}):
            with self.subTest(change=change), self.assertRaisesRegex(JobFailure, "invalid_converter_receipt"):
                conversion_record(converter_probe_remote, job(), self.sb.object_id, self.device,
                                  {**self.converted, **change}, binding, self.conversion_log)
        for log in (self.conversion_log + "GPU adapter index 0 not found, using default\n",
                    self.conversion_log.replace(" gpu=112.9MB", "")):
            with self.assertRaisesRegex(JobFailure, "invalid_converter_gpu_proof"):
                conversion_record(converter_probe_remote, job(), self.sb.object_id, self.device,
                                  self.converted, binding, log)

    def test_tampered_download_fails_hash_and_still_terminates(self):
        self.converted["output"]["sha256"] = "c" * 64
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"), \
                redirect_stdout(StringIO()):
            with self.assertRaisesRegex(JobFailure, "sog_hash_changed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.sb.filesystem.remove.assert_called_once_with(modal_room.REMOTE, recursive=True)
        self.sb.terminate.assert_called_once_with(wait=True)
        self.assertEqual(self.journal_rows[-1]["action"], "cleanup")

    def test_wrong_sog_metadata_fails_even_with_matching_byte_hash(self):
        data = BytesIO()
        with zipfile.ZipFile(BytesIO(self.sog)) as source, zipfile.ZipFile(data, "w") as target:
            for name in source.namelist():
                body = source.read(name)
                if name == "meta.json":
                    value = json.loads(body); value["shN"]["bands"] = 0
                    body = json.dumps(value).encode()
                target.writestr(name, body)
        self.sog = data.getvalue()
        self.converted["output"].update(bytes=len(self.sog), sha256=hashlib.sha256(self.sog).hexdigest())
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"), \
                redirect_stdout(StringIO()):
            with self.assertRaisesRegex(JobFailure, "invalid_converter_output"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.sb.terminate.assert_called_once_with(wait=True)

    def test_only_allowlisted_conversion_values_reach_controller_logs(self):
        self.converted["token"] = "sensitive-canary"
        self.device["raw_input"] = "sensitive-canary"
        self.conversion_log += "/private/room sensitive-canary\n"
        output = StringIO()
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"), \
                redirect_stdout(output):
            self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        lines = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([line["event"] for line in lines], ["spatial_training_quality", "spatial_conversion"])
        self.assertNotIn("sensitive-canary", output.getvalue())
        self.assertNotIn("/private/room", output.getvalue())
        self.assertFalse(lines[1]["hardware_peak_measured"])


class DependencyBaselineTests(ProviderFixture):
    def test_committed_baseline_contains_only_reviewed_public_version_pins(self):
        baseline = Path(__file__).with_name("requirements-baseline.txt")
        self.assertEqual(dependency_baseline_digest(baseline),
                         "9c5c6356ccb384bb430c2690126df0ba2bb2e989bb3b181fb22802d024bb91f7")
        self.assertEqual(len(baseline.read_text().splitlines()), 164)
        for index, text in enumerate(("package @ file:///private/source\n", "--extra-index-url https://example.test\n",
                                      "pkg==1\npkg==1\n", "pkg==1\n", "")):
            candidate = self.root / f"candidate-{index}.txt"
            candidate.write_text(text)
            if text == "pkg==1\n":
                self.assertEqual(len(dependency_baseline_digest(candidate)), 64)
            else:
                with self.subTest(text=text), self.assertRaisesRegex(JobFailure, "invalid_dependency_baseline"):
                    dependency_baseline_digest(candidate)

    def test_remote_check_rejects_missing_extra_changed_and_tampered_dependencies_even_optimized(self):
        baseline = self.root / "requirements-baseline.txt"
        baseline.write_text("alpha==1\nbeta==2\n")
        command = dependency_verification_command(str(self.root), dependency_baseline_digest(baseline))
        compiled = compile(command[2], "<offline-dependency-check>", "exec", optimize=2)
        def distribution(name, version):
            return SimpleNamespace(metadata={"Name": name}, version=version)
        expected = [distribution("beta", "2"), distribution("alpha", "1")]
        output = StringIO()
        with patch.object(importlib.metadata, "distributions", return_value=expected), redirect_stdout(output):
            exec(compiled, {})
        self.assertEqual(output.getvalue(), "PASS: exact baseline Python dependencies\n")
        for actual in (expected[:1], expected + [distribution("unexpected", "3")],
                       [distribution("alpha", "1"), distribution("beta", "3")]):
            output = StringIO()
            with self.subTest(actual=actual), \
                    patch.object(importlib.metadata, "distributions", return_value=actual), redirect_stdout(output):
                with self.assertRaisesRegex(RuntimeError, "resolved environment differs"):
                    exec(compiled, {})
            self.assertEqual(output.getvalue(), "")
        baseline.write_text("alpha==1\nbeta==3\n")
        with self.assertRaisesRegex(RuntimeError, "baseline changed"):
            exec(compiled, {})

    def test_dependency_mismatch_after_network_denial_transfers_no_room_and_terminates(self):
        phases = []
        self.sb._experimental_set_outbound_network_policy.side_effect = lambda **kwargs: phases.append(kwargs)
        def execute(sandbox, command, *args, **kwargs):
            if command[:2] == ["python", "-c"]:
                self.assertEqual(phases[-1], {"outbound_cidr_allowlist": [], "outbound_domain_allowlist": []})
                self.assertFalse(any("/dataset/" in call.args[1]
                                     for call in sandbox.filesystem.copy_from_local.call_args_list))
                raise modal_room.StageFailure(1)
        with patch.object(modal_room, "inventory", return_value=[{"path": "images/000001.jpg"}]), \
                patch.object(modal_room, "exec_to_log", side_effect=execute):
            with self.assertRaisesRegex(JobFailure, "generation_failed"):
                self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        sources = [call.args[1] for call in self.sb.filesystem.copy_from_local.call_args_list]
        self.assertIn(f"{modal_room.REMOTE}/requirements-baseline.txt", sources)
        self.assertFalse(any("/dataset/" in path for path in sources))
        receipt = json.loads((self.root / "provider-receipt.json").read_text())
        self.assertNotIn("dependencies_verified_before_media", receipt)
        self.assertTrue(receipt["network_denied_before_media"])
        self.assertTrue(receipt["private_files_removed"])
        self.assertTrue(receipt["terminated"])
        self.modal.Sandbox.create.assert_called_once()
        self.sb.terminate.assert_called_once_with(wait=True)
        self.assertEqual(self.journal_rows[-1]["action"], "cleanup")

    def test_successful_dependency_gate_precedes_media_without_changing_training_options(self):
        verified = False
        def execute(sandbox, command, *args, **kwargs):
            nonlocal verified
            if command[:2] == ["python", "-c"]:
                verified = True
            elif "--max-steps" in command:
                self.assertEqual(command.count("--pose-opt"), 1)
                self.assertEqual(command[command.index("--max-steps") + 1], "3000")
                self.assertEqual(command[command.index("--max-seconds") + 1], "900")
        def copy(source, remote):
            if "/dataset/" in remote:
                self.assertTrue(verified)
        self.sb.filesystem.copy_from_local.side_effect = copy
        with patch.object(modal_room, "inventory", return_value=[{"path": "images/000001.jpg"}]), \
                patch.object(modal_room, "exec_to_log", side_effect=execute), redirect_stdout(StringIO()):
            self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        receipt = json.loads((self.root / "provider-receipt.json").read_text())
        self.assertTrue(receipt["dependencies_verified_before_media"])
        self.assertEqual(receipt["python_dependency_baseline_sha256"],
                         dependency_baseline_digest(Path(__file__).with_name("requirements-baseline.txt")))
        self.assertEqual(self.modal.Sandbox.create.call_args.kwargs["secrets"], [])


class SandboxNameTests(ProviderFixture):
    """The name is validated by the SDK before any RPC; a Mock cannot notice."""

    def test_sandbox_name_passes_the_pinned_sdk_validator_and_is_shared_with_the_journal(self):
        with patch.object(modal_room, "inventory", return_value=[]), patch.object(modal_room, "exec_to_log"):
            self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        name = self.modal.Sandbox.create.call_args.kwargs["name"]
        # First the rule that actually bit: whatever shape the name takes, the
        # SDK must accept it, or CREATE raises before any RPC.
        if modal_names is not None:
            self.assertTrue(modal_names.is_valid_object_name(name), name)
            modal_names.check_object_name(name, "Sandbox")  # InvalidError is a test failure, not a skip
            # This is the exact 81-character form the SDK refused before this fix.
            retired = "spatial-" + JOB_ID + "-" + LEASE_ID
            self.assertFalse(modal_names.is_valid_object_name(retired))
            with self.assertRaises(modal_sdk.exception.InvalidError):
                modal_names.check_object_name(retired, "Sandbox")
        else:
            # Local mirror of the SDK rule; the real validator runs whenever the
            # pinned SDK is installed, which the release environment guarantees.
            self.assertRegex(name, r"^[A-Za-z0-9._-]{1,64}$")
        self.assertEqual(name, "spatial-" + LEASE_ID)
        self.assertEqual(name, sandbox_name(job()))
        # Durable intent, the CREATE request and reconciliation all use one name.
        self.assertEqual([row["data"]["sandbox_name"] for row in self.journal_rows if row["action"] == "plan"], [name])

    def test_a_name_the_provider_would_refuse_fails_before_intent_or_allocation(self):
        odd = job(); odd["lease_token"] = "not a token/" + "x" * 60
        with patch.object(modal_room, "inventory", return_value=[]):
            with self.assertRaisesRegex(JobFailure, "invalid_sandbox_name"):
                self.provider.reconstruct(odd, self.root, self.capture, self.lease)
        self.modal.Sandbox.create.assert_not_called()
        self.assertEqual(self.journal_rows, [])
        self.assertIs(self.lease.provider_stopped, True)


class CostBoundTests(ProviderFixture):
    def test_full_ttl_bound_is_proven_from_the_create_request_before_intent(self):
        poor = job(); poor["max_cost_cents"] = 400  # below this CREATE's own full-TTL ceiling
        with patch.object(modal_room, "inventory", return_value=[]):
            with self.assertRaisesRegex(JobFailure, "provider_cost_bound_exceeded"):
                self.provider.reconstruct(poor, self.root, self.capture, self.lease)
        self.modal.Sandbox.create.assert_not_called()
        self.assertEqual(self.journal_rows, [])  # never planned, so nothing ambiguous to reconcile
        self.assertIs(self.lease.provider_stopped, True)
        receipt = json.loads((self.root / "provider-receipt.json").read_text())
        # L4 + 4 cores + 32GiB at Sandbox rates, x1.15 for "us", over the ~7080s TTL.
        self.assertEqual(receipt["compute_bound_cents"], 483)
        self.assertNotIn("sandbox_id", receipt)

    def test_unpriced_or_unequal_resources_never_allocate(self):
        options = modal_room.create_options(self.modal, self.app, {"sandbox_name": "n", "run_id": "r"})
        for change in ({"gpu": "H100"}, {"gpu": None}, {"region": "eu"}, {"cpu": (4.0, 8.0)},
                       {"memory": (32768, 65536)}, {"cpu": (65.0, 65.0)}, {"memory": (32768.0, 32768.0)}):
            with self.subTest(change=change):
                with patch.object(modal_room, "create_options", return_value={**options, **change}), \
                        patch.object(modal_room, "inventory", return_value=[]):
                    with self.assertRaisesRegex(JobFailure, "unpriced_provider_resources"):
                        self.provider.reconstruct(job(), self.root, self.capture, self.lease)
        self.modal.Sandbox.create.assert_not_called()
        self.assertEqual(self.journal_rows, [])

    def test_rate_table_matches_the_experiment_policy_it_was_copied_from(self):
        policy = modal_room.policy()
        options = {"gpu": policy["gpu"], "region": policy["region"], "timeout": policy["timeout_seconds"],
                   "cpu": (float(policy["cpu_request_and_limit"]),) * 2,
                   "memory": (policy["memory_request_and_limit_mib"],) * 2}
        expected = int((Decimal(policy["compute_upper_bound_usd"]) * 100).to_integral_value(rounding=ROUND_CEILING))
        self.assertEqual(compute_bound_cents(options), expected)
        self.assertEqual(expected, 492)  # USD 4.9110336 for the full 7200s, as in the real-room receipt
        # The 600c admission floor covers the longest TTL the provider can be sent.
        self.assertLessEqual(expected, MIN_COST_RESERVATION_CENTS)
        with self.assertRaisesRegex(JobFailure, "invalid_provider_ttl"):
            compute_bound_cents({**options, "timeout": 7201})


if __name__ == "__main__":
    unittest.main(verbosity=2)
