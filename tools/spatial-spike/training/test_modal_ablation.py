"""Offline ordered-ablation authorization and dependency regressions."""
import json
import importlib.metadata
from pathlib import Path
import shutil
import sqlite3
import struct
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

import modal_ablation as ablation
import modal_retry
import modal_room as room

REAL_INVENTORY = room.inventory
try:
    OFFICIAL_SFM = importlib.metadata.version("pycolmap") == "4.2.0"
except importlib.metadata.PackageNotFoundError:
    OFFICIAL_SFM = False

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

    def completed(self, label="a00", step=2999):
        state = self.predecessor(label)
        relative = f"result/stats/val_step{step}.json"
        metrics_path = state / "download" / relative
        metrics_path.parent.mkdir(parents=True)
        self.write(metrics_path, {"psnr": 19.2, "ssim": 0.80, "lpips": 0.55})
        receipt_path = state / "provider-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt.update(outcome="trained", pose_optimization=True, artifacts=[{
            "path": relative, "sha256": room.sha(metrics_path),
            "bytes": metrics_path.stat().st_size}])
        self.write(receipt_path, receipt)
        return state

    def completed_a(self):
        return self.completed()

    def lost_setup(self):
        state = self.predecessor()
        receipt_path = state / "provider-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt.update(outcome="failed", transferred_files=[],
                       events=[{"phase": phase} for phase in ("allocated", "setup_started", "failed", "terminated")],
                       stages={"setup": {"exit_code": 1}},
                       remote_copy_delete={"response": "failed", "error_type": "ConnectionError"},
                       terminate={"poll_exit_code": 0})
        self.write(receipt_path, receipt)
        observed = {"schema_version": 1, "sdk": "modal==1.5.3", "profile": "rendprop-room-experiment",
                    "app_id": receipt["app_id"], "sandbox_id": receipt["sandbox_id"],
                    "provider_receipt_sha256": room.sha(receipt_path),
                    "provider_receipt_path": str(receipt_path),
                    "provider_state": {"terminal": True, "numeric_exit_code": 0,
                                       "generic_result_status": 2,
                                       "generic_result_status_name": "GENERIC_STATUS_FAILURE",
                                       "exception_classification": "worker_disappeared",
                                       "provider_exception": "Worker disappeared."},
                    "active_app_sandbox_count": 0, "active_app_sandboxes": [],
                    "private_transfer_proof": {"transferred_files": [],
                                               "outbound_denied_event_present": False,
                                               "training_started_event_present": False,
                                               "failed_during_dependency_setup": True},
                    "remote_directory_deletion": {"confirmed": False}}
        self.write(state / "provider-readback.json", observed)
        return state, receipt, observed

    def test_independently_terminal_disappeared_setup_allows_explicit_continuation_only(self):
        state, receipt, observed = self.lost_setup()
        receipt_path = state / "provider-receipt.json"
        before = receipt_path.read_bytes()
        plan = ablation.prepare(self.dataset, "a01")
        self.assertEqual(plan["prior_costs_and_holds_usd"], "6.5910543900")
        self.assertEqual(receipt_path.read_bytes(), before)
        self.assertEqual(receipt["remote_copy_delete"]["response"], "failed")
        self.assertFalse(observed["remote_directory_deletion"]["confirmed"])
        with self.assertRaisesRegex(ValueError, "completed A"):
            ablation.prepare(self.dataset, "b01")

    def test_disappeared_setup_exception_never_excuses_possible_private_transfer(self):
        state, original, observed = self.lost_setup()
        receipt_path = state / "provider-receipt.json"
        for change in ({"transferred_files": ["images/000001.jpg"]},
                       {"events": original["events"] + [{"phase": "outbound_denied"}]},
                       {"events": original["events"] + [{"phase": "training_started"}]},
                       {"stages": {"setup": {"exit_code": 0}}}):
            with self.subTest(change=change):
                self.write(receipt_path, {**original, **change})
                self.write(state / "provider-readback.json", {**observed,
                           "provider_receipt_sha256": room.sha(receipt_path)})
                with self.assertRaisesRegex(ValueError, "pre-media cleanup reconciliation"):
                    ablation.prepare(self.dataset, "a01")

    def test_disappeared_setup_requires_exact_identity_receipt_and_terminal_readback(self):
        state, receipt, original = self.lost_setup()
        for change in ({"provider_receipt_sha256": "0" * 64}, {"app_id": "ap-other"},
                       {"sandbox_id": "sb-other"}, {"active_app_sandbox_count": 1},
                       {"active_app_sandboxes": ["sb-active"]},
                       {"provider_state": {**original["provider_state"], "terminal": False}},
                       {"provider_state": {**original["provider_state"], "exception_classification": "unknown"}},
                       {"private_transfer_proof": {"failed_during_dependency_setup": False}}):
            with self.subTest(change=change):
                self.write(state / "provider-readback.json", {**original, **change})
                with self.assertRaisesRegex(ValueError, "pre-media cleanup reconciliation"):
                    ablation.prepare(self.dataset, "a01")
        self.write(state / "provider-readback.json", original)
        receipt["terminate"]["poll_exit_code"] = None
        self.write(state / "provider-receipt.json", receipt)
        with self.assertRaisesRegex(ValueError, "explicit cleanup reconciliation"):
            ablation.prepare(self.dataset, "a01")

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
        with self.assertRaisesRegex(ValueError, "reviewed"):
            ablation.prepare(self.dataset, "c01")

    def test_b_requires_a_completion_and_bound_metrics(self):
        with self.assertRaisesRegex(ValueError, "completed A"):
            ablation.prepare(self.dataset, "b01")
        state = self.completed_a()
        plan = ablation.prepare(self.dataset, "b01")
        self.assertEqual((plan["steps"], plan["max_training_seconds"], plan["max_gaussians"]),
                         (30000, 4200, 500000))
        self.assertEqual((plan["fixed_eval_every"], plan["random_seed"]), (8, 42))
        self.assertTrue(plan["pose_optimization"])
        self.assertEqual(plan["completed_a_metrics"][0]["psnr"], 19.2)
        # Poor-but-finite A measurements are accepted; success must not be cherry-picked.
        metrics = state / "download/result/stats/val_step2999.json"
        metrics.write_text('{"psnr": 40, "ssim": 0.99, "lpips": 0.01}')
        with self.assertRaisesRegex(ValueError, "collected artifact"):
            ablation.prepare(self.dataset, "b01")

    def test_b_rejects_failed_a_or_missing_metrics(self):
        state = self.predecessor()
        with self.assertRaisesRegex(ValueError, "completed A"):
            ablation.prepare(self.dataset, "b01")
        receipt_path = state / "provider-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt.update(outcome="trained", pose_optimization=True)
        self.write(receipt_path, receipt)
        with self.assertRaisesRegex(ValueError, "missing"):
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
                                     "pose_opt": True, "dependency_baseline": self.run_path,
                                     "max_steps": 3000, "max_seconds": 900})
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


class SfmAblationTests(unittest.TestCase):
    """Real synthetic binary models and private receipts; no provider calls."""
    write = staticmethod(AblationGuardTests.write)
    predecessor = AblationGuardTests.predecessor
    completed = AblationGuardTests.completed
    modal = AblationGuardTests.modal

    def setUp(self):
        AblationGuardTests.setUp(self)
        self.original = self.dataset
        self.dataset = self.root / "sfm-result/dataset"
        self.dataset.mkdir(parents=True)
        self.train, self.heldout = ablation.sfm.fixed_split([f"{i:06d}.jpg" for i in range(1, 154)])
        self.training_ids = {int(name[:6]) for name in self.train}
        for dataset, derived in ((self.original, False), (self.dataset, True)):
            (dataset / "images").mkdir()
            sparse = dataset / "sparse/0"
            sparse.mkdir(parents=True)
            for i in range(1, 154):
                (dataset / "images" / f"{i:06d}.jpg").write_bytes(f"synthetic-jpeg-{i}".encode())
            (sparse / "cameras.bin").write_bytes(struct.pack("<QIiQQ4d", 1, 1, 1, 80, 60, 60., 60., 40., 30.))
            image_bytes = bytearray(struct.pack("<Q", 153))
            for i in range(1, 154):
                image_bytes.extend(struct.pack("<I4d3dI", i, 1., 0., 0., 0., i * .01, 0., 0., 1))
                image_bytes.extend(f"{i:06d}.jpg".encode() + b"\0")
                length = 100 if derived and i in self.training_ids else 0
                image_bytes.extend(struct.pack("<Q", length))
                for point_id in range(1, length + 1):
                    image_bytes.extend(struct.pack("<ddq", float(point_id), 1., point_id))
            (sparse / "images.bin").write_bytes(image_bytes)
            points = bytearray(struct.pack("<Q", 100))
            for point_id in range(1, 101):
                points.extend(struct.pack("<Q3d3BdQ", point_id, point_id * .01, 0., 2., 128, 128, 128,
                                          0.1 if derived else 0., len(self.training_ids) if derived else 0))
                if derived:
                    for image_id in sorted(self.training_ids):
                        points.extend(struct.pack("<II", image_id, point_id - 1))
            (sparse / "points3D.bin").write_bytes(points)
            adapter = {"format": "rendprop-posed-gsplat-dataset", "schema_version": 1,
                       "gsplat_commit": "937e29912570c372bed6747a5c9bf85fed877bae", "frames": 153,
                       "initial_points": 100, "image_sha256": {p.name: room.sha(p) for p in (dataset / "images").iterdir()},
                       "model_sha256": {p.name: room.sha(p) for p in sparse.iterdir()}}
            if derived:
                adapter.update(sfm_profile=ablation.sfm.PROFILE, evaluation_images=self.heldout,
                    sfm_provenance="../sfm-report.json", gpu_training_performed=False,
                    reprojection_error_measured=True, point_observations=13300)
            self.write(dataset / "adapter-report.json", adapter)
        self.write(self.baseline / "provider-receipt.json", {"dataset_files": REAL_INVENTORY(self.original)})
        work = self.dataset.parent / "work"
        work.mkdir()
        with sqlite3.connect(work / "features.db") as database:
            database.execute("CREATE TABLE images (image_id INTEGER PRIMARY KEY, name TEXT)")
            database.executemany("INSERT INTO images VALUES (?,?)", [(i, f"{i:06d}.jpg") for i in sorted(self.training_ids)])
        (work / "matched-pairs.txt").write_text("000002.jpg 000003.jpg\n")
        original_adapter = json.loads((self.original / "adapter-report.json").read_text())
        self.report_path = self.dataset.parent / "sfm-report.json"
        self.run_report_path = self.dataset.parent / "sfm-run.json"
        self.write(self.report_path, {"status": "prepared", "profile": ablation.sfm.PROFILE,
            "training_images": self.train, "evaluation_images": self.heldout,
            "evaluation_pose_records_unchanged": True, "heldout_pixels_used_by_sfm": False,
            "original_arkit_seeds_used": False, "gpu_used": False,
            "source_adapter_report_sha256": room.sha(self.original / "adapter-report.json"),
            "source_model_sha256": original_adapter["model_sha256"],
            "helper_sha256": room.sha(Path(ablation.sfm.__file__)), "final_points": 100,
            "final_observations": 13300, "observations_by_training_image": {str(i): 100 for i in self.training_ids},
            "pair_count": 1, "pair_list_sha256": room.sha(work / "matched-pairs.txt")})
        self.write(self.run_report_path, {"status": "prepared", "profile": ablation.sfm.PROFILE,
            "execute": True, "max_seconds": 1800, "elapsed_seconds": 10., "training_frames": 133,
            "evaluation_frames": 20, "evaluation_images": self.heldout})
        for target, name, kwargs in ((room, "inventory", {"side_effect": REAL_INVENTORY}),
                                    (room, "source_binding", {"return_value": {"commit": "HEAD"}}),
                                    (ablation, "ORIGINAL_DATASET", {"new": self.original})):
            context = patch.object(target, name, **kwargs)
            context.start()
            self.addCleanup(context.stop)

    def rehash_model(self, name):
        path = self.dataset / "adapter-report.json"
        adapter = json.loads(path.read_text())
        adapter["model_sha256"][name] = room.sha(self.dataset / "sparse/0" / name)
        self.write(path, adapter)

    def test_d_requires_completed_b_and_preserves_b_profile(self):
        with self.assertRaisesRegex(ValueError, "completed B"):
            ablation.prepare(self.dataset, "d01")
        self.completed()
        with self.assertRaisesRegex(ValueError, "completed B"):
            ablation.prepare(self.dataset, "d01")
        self.completed("b00", 29999)
        plan = ablation.prepare(self.dataset, "d01")
        self.assertEqual((plan["steps"], plan["max_training_seconds"], plan["max_gaussians"]), (30000, 4200, 500000))
        self.assertTrue(plan["pose_optimization"])
        self.assertEqual(plan["automatic_retries"], 0)
        self.assertEqual((plan["fixed_eval_every"], plan["random_seed"]), (8, 42))
        self.assertIn("153 frames", plan["c_unavailable_reason"])
        self.assertEqual(plan["completed_b_metrics"][0]["psnr"], 19.2)
        self.assertEqual(plan["sfm_dataset"]["sfm_report_sha256"], room.sha(self.report_path))
        self.assertEqual(plan["sfm_dataset"]["derived_model_sha256"], json.loads((self.dataset / "adapter-report.json").read_text())["model_sha256"])

    def test_a_and_b_still_reject_a_valid_derived_dataset(self):
        self.completed()
        for label in ("a01", "b01"):
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, "exact original"):
                ablation.prepare(self.dataset, label)

    def test_d_requires_b_final_step_and_hash_bound_finite_metrics(self):
        state = self.completed("b00", 2999)
        with self.assertRaisesRegex(ValueError, "missing"):
            ablation.prepare(self.dataset, "d01")
        metrics = state / "download/result/stats/val_step29999.json"
        self.write(metrics, {"psnr": 19.2, "ssim": .8, "lpips": .55})
        with self.assertRaisesRegex(ValueError, "collected artifact"):
            ablation.prepare(self.dataset, "d01")
        receipt_path = state / "provider-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        for value in (float("nan"), float("inf"), "19.2", True):
            self.write(metrics, {"psnr": value, "ssim": .8, "lpips": .55})
            receipt["artifacts"] = [{"path": "result/stats/val_step29999.json", "sha256": room.sha(metrics), "bytes": metrics.stat().st_size}]
            self.write(receipt_path, receipt)
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "finite"):
                ablation.prepare(self.dataset, "d01")

    def test_d_rejects_incomplete_or_changed_sfm_provenance(self):
        self.completed("b00", 29999)
        original = json.loads(self.report_path.read_text())
        for change in ({"status": "running"}, {"profile": {**ablation.sfm.PROFILE, "pycolmap_version": "0.0.1"}},
                       {"source_adapter_report_sha256": "0" * 64}, {"source_model_sha256": {}},
                       {"helper_sha256": "0" * 64}, {"original_arkit_seeds_used": True},
                       {"heldout_pixels_used_by_sfm": True}, {"training_images": self.train[:-1]},
                       {"evaluation_pose_records_unchanged": False}, {"final_points": 101},
                       {"observations_by_training_image": {}}, {"pair_list_sha256": "0" * 64}):
            self.write(self.report_path, {**original, **change})
            with self.subTest(change=change), self.assertRaises(ValueError):
                ablation.prepare(self.dataset, "d01")
        self.write(self.report_path, original)
        run = json.loads(self.run_report_path.read_text())
        for change in ({"status": "prepared_pending_supervisor"}, {"execute": False}, {"max_seconds": 1801},
                       {"elapsed_seconds": float("inf")}, {"training_frames": 153}):
            self.write(self.run_report_path, {**run, **change})
            with self.subTest(change=change), self.assertRaises(ValueError):
                ablation.prepare(self.dataset, "d01")

    def test_d_rejects_changed_original_or_derived_jpegs(self):
        self.completed("b00", 29999)
        path = self.dataset / "images/000002.jpg"
        path.write_bytes(b"another source image")
        adapter_path = self.dataset / "adapter-report.json"
        adapter = json.loads(adapter_path.read_text())
        adapter["image_sha256"][path.name] = room.sha(path)
        self.write(adapter_path, adapter)
        with self.assertRaisesRegex(ValueError, "original JPEG inventory"):
            ablation.prepare(self.dataset, "d01")
        (self.original / "images/000001.jpg").write_bytes(b"changed baseline")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            ablation.prepare(self.dataset, "d01")

    def test_d_rejects_changed_calibration_or_heldout_pose_even_when_rehashed(self):
        self.completed("b00", 29999)
        path = self.dataset / "sparse/0/cameras.bin"
        before = path.read_bytes()
        changed = bytearray(before)
        struct.pack_into("<d", changed, 32, 61.)
        path.write_bytes(changed)
        self.rehash_model(path.name)
        with self.assertRaisesRegex(ValueError, "original cameras.bin"):
            ablation.prepare(self.dataset, "d01")
        path.write_bytes(before)
        self.rehash_model(path.name)
        path = self.dataset / "sparse/0/images.bin"
        changed = bytearray(path.read_bytes())
        struct.pack_into("<d", changed, 8 + 36, .25)
        path.write_bytes(changed)
        self.rehash_model(path.name)
        with self.assertRaisesRegex(ValueError, "heldout image records"):
            ablation.prepare(self.dataset, "d01")

    def test_d_rejects_heldout_or_untriangulated_point_tracks(self):
        self.completed("b00", 29999)
        path = self.dataset / "sparse/0/points3D.bin"
        original = path.read_bytes()
        for offset, fmt, value, pattern in ((8 + 51, "<I", 1, "excluded"),
                                           (8 + 43, "<Q", 0, "real training-view tracks"),
                                           (8 + 51 + 8, "<I", 2, "duplicate observation")):
            changed = bytearray(original)
            struct.pack_into(fmt, changed, offset, value)
            path.write_bytes(changed)
            self.rehash_model(path.name)
            with self.subTest(offset=offset), self.assertRaisesRegex(ValueError, pattern):
                ablation.prepare(self.dataset, "d01")

    def test_real_colmap_multiple_observations_in_one_image_remain_valid(self):
        self.completed("b00", 29999)
        images_path = self.dataset / "sparse/0/images.bin"
        records = ablation.sfm.image_records(images_path)
        name, raw, observations = records[2]
        count_offset = len(raw) - observations * 24 - 8
        raw = (raw[:count_offset] + struct.pack("<Q", observations + 1) + raw[count_offset + 8:] +
               struct.pack("<ddq", 1.5, 2., 1))
        records[2] = (name, raw, observations + 1)
        images_path.write_bytes(struct.pack("<Q", 153) + b"".join(records[i][1] for i in sorted(records)))
        points_path = self.dataset / "sparse/0/points3D.bin"
        points = bytearray(points_path.read_bytes())
        struct.pack_into("<Q", points, 8 + 43, 134)
        end_first_track = 8 + 51 + 133 * 8
        points[end_first_track:end_first_track] = struct.pack("<II", 2, 100)
        points_path.write_bytes(points)
        self.rehash_model(images_path.name)
        self.rehash_model(points_path.name)
        report = json.loads(self.report_path.read_text())
        report["final_observations"] += 1
        report["observations_by_training_image"]["2"] += 1
        self.write(self.report_path, report)
        adapter_path = self.dataset / "adapter-report.json"
        adapter = json.loads(adapter_path.read_text())
        adapter["point_observations"] += 1
        self.write(adapter_path, adapter)
        self.assertEqual(ablation.prepare(self.dataset, "d01")["steps"], 30000)

    def test_d_rejects_extra_feature_image_or_unbound_pair_list(self):
        self.completed("b00", 29999)
        database = self.dataset.parent / "work/features.db"
        with sqlite3.connect(database) as connection:
            connection.execute("INSERT INTO images VALUES (1, '000001.jpg')")
        with self.assertRaisesRegex(ValueError, "exactly the 133"):
            ablation.prepare(self.dataset, "d01")
        with sqlite3.connect(database) as connection:
            connection.execute("DELETE FROM images WHERE image_id=1")
        pairs = self.dataset.parent / "work/matched-pairs.txt"
        pairs.write_text("000001.jpg 000002.jpg\n")
        report = json.loads(self.report_path.read_text())
        report["pair_list_sha256"] = room.sha(pairs)
        self.write(self.report_path, report)
        with self.assertRaisesRegex(ValueError, "training-only"):
            ablation.prepare(self.dataset, "d01")

    def test_d_provenance_cannot_escape_private_root(self):
        self.completed("b00", 29999)
        with tempfile.TemporaryDirectory() as outside:
            destination = Path(outside) / "sfm-report.json"
            destination.write_bytes(self.report_path.read_bytes())
            self.report_path.unlink()
            self.report_path.symlink_to(destination)
            with self.assertRaisesRegex(ValueError, "remain under"):
                ablation.prepare(self.dataset, "d01")

    def test_d_plan_binds_new_model_and_blocks_changed_inputs_before_provider_access(self):
        self.completed("b00", 29999)
        plan_path = self.root / "d-plan.json"
        self.write(plan_path, ablation.prepare(self.dataset, "d01"))
        path = self.dataset / "sparse/0/points3D.bin"
        changed = bytearray(path.read_bytes())
        struct.pack_into("<d", changed, 16, .25)
        path.write_bytes(changed)
        self.rehash_model(path.name)
        modal = self.modal()
        with patch.object(room, "run") as dispatch:
            with self.assertRaisesRegex(ValueError, "plan inputs"):
                ablation.execute(modal, plan_path, self.root / "d01")
            dispatch.assert_not_called()
            modal.App.lookup.assert_not_called()

    def test_d_single_allocation_keeps_baseline_dependencies_and_no_retry(self):
        self.completed("b00", 29999)
        plan_path = self.root / "d-plan.json"
        self.write(plan_path, ablation.prepare(self.dataset, "d01"))
        marker = self.root / "spatial-ablation-20260914-d01.allocation.json"
        def fail(*args, **kwargs):
            self.assertTrue(marker.exists())
            self.assertEqual(kwargs, {"app_name": "rendprop-spatial-ablation-d01-20260914", "pose_opt": True,
                "dependency_baseline": self.run_path, "max_steps": 30000, "max_seconds": 4200})
            raise TimeoutError("ambiguous allocation")
        with patch.object(room, "run", side_effect=fail) as dispatch:
            with self.assertRaises(TimeoutError):
                ablation.execute(self.modal(), plan_path, self.root / "d01")
            original = marker.read_bytes()
            with self.assertRaises(ValueError):
                ablation.execute(self.modal(), plan_path, self.root / "d02")
            self.assertEqual(marker.read_bytes(), original)
            dispatch.assert_called_once()


@unittest.skipUnless(OFFICIAL_SFM, "D2 option fingerprints require the separate official 4.2.0 environment")
class IncrementalSfmAblationTests(unittest.TestCase):
    """Exact binary cohort/track guards; no real-room data or provider access."""
    write = staticmethod(AblationGuardTests.write)
    predecessor = AblationGuardTests.predecessor
    completed = AblationGuardTests.completed
    modal = AblationGuardTests.modal
    rehash_model = SfmAblationTests.rehash_model

    def setUp(self):
        import pycolmap as p
        SfmAblationTests.setUp(self)
        self.d1_dataset = self.dataset
        d1_work = self.d1_dataset.parent / "work"
        with sqlite3.connect(d1_work / "features.db") as db:
            db.execute("CREATE TABLE keypoints (image_id INTEGER PRIMARY KEY, rows INTEGER)")
            db.executemany("INSERT INTO keypoints VALUES (?,100)", [(i,) for i in self.training_ids])
            db.execute("CREATE TABLE two_view_geometries (pair_id INTEGER PRIMARY KEY, rows INTEGER, data BLOB)")
            db.execute("INSERT INTO two_view_geometries VALUES (?,1,?)", (2 * 2147483647 + 3, struct.pack("<II", 0, 0)))
        db.close()
        self.dataset = self.root / "incremental-result/dataset"
        shutil.copytree(self.d1_dataset, self.dataset)
        (self.dataset.parent / "work").mkdir()
        shutil.copyfile(d1_work / "features.db", self.dataset.parent / "work/features.db")
        self.report_path = self.dataset.parent / "sfm-report.json"
        self.run_report_path = self.dataset.parent / "sfm-run.json"
        incremental = ablation.sfm_incremental
        helpers = {name: room.sha(Path(incremental.__file__).with_name(name)) for name in
                   ("refine_sfm_incremental.py", "refine_sfm.py", "run_training.py", "prepare_capture.py")}
        for name, value in (("D1_DATASET", self.d1_dataset),):
            context = patch.object(ablation, name, value)
            context.start()
            self.addCleanup(context.stop)
        context = patch.object(ablation, "committed_incremental_helpers", return_value=helpers)
        context.start()
        self.addCleanup(context.stop)
        cache = incremental.cache_inventory(d1_work / "features.db", {i: f"{i:06d}.jpg" for i in self.training_ids})
        cache["sfm_report_sha256"] = room.sha(self.d1_dataset.parent / "sfm-report.json")
        mapping = incremental.json_options(incremental.mapping_options(self.train, p).todict())
        alignment = incremental.json_options(incremental.alignment_options(p).todict())
        original_adapter = json.loads((self.original / "adapter-report.json").read_text())
        adapter_path = self.dataset / "adapter-report.json"
        adapter = json.loads(adapter_path.read_text())
        adapter.update(sfm_profile=incremental.PROFILE, registered_training_ids=sorted(self.training_ids),
            original_pose_fallback_ids=[], fallback_authorized=False, scene_quality_accepted=False, quality_status="unknown")
        self.write(adapter_path, adapter)
        self.write(self.report_path, {"status": "prepared", "profile": incremental.PROFILE,
            "training_images": self.train, "evaluation_images": self.heldout,
            "evaluation_pose_records_unchanged": True, "heldout_pixels_used_by_sfm": False,
            "original_arkit_seeds_used": False, "gpu_used": False, "network_used": False,
            "quality_status": "unknown", "scene_quality_accepted": False, "source_sha256": helpers,
            "source_model_sha256": original_adapter["model_sha256"], "source_image_sha256": original_adapter["image_sha256"],
            "source_adapter_report_sha256": room.sha(self.original / "adapter-report.json"),
            "cache": cache, "copied_database_sha256": cache["database_sha256"], "fallback_authorized": False,
            "registered_training_ids": sorted(self.training_ids), "original_pose_fallback_ids": [],
            "missing_from_selected_model_ids": [], "registered_in_other_models_ids": [], "unregistered_training_ids": [],
            "registration": {"options": mapping, "models": [{"model_id": 0, "registered_ids": sorted(self.training_ids), "points": 100}],
                             "selected_model_id": 0},
            "alignment": {"options": alignment}, "final_points": 100, "final_observations": 13300,
            "observations_by_training_image": {str(i): 100 for i in self.training_ids}})
        self.write(self.run_report_path, {"status": "prepared", "profile": incremental.PROFILE,
            "execute": True, "max_seconds": 1800, "elapsed_seconds": 10., "training_frames": 133, "evaluation_frames": 20,
            "evaluation_images": self.heldout, "mapping_options": mapping, "alignment_options": alignment,
            "cache": cache, "fallback_authorized": False})
        self.registered_model(self.training_ids)
        self.completed("b00", 29999)

    def registered_model(self, registered):
        directory = self.dataset.parent / "work/registered-model"
        directory.mkdir(exist_ok=True)
        for name in ("cameras.bin", "points3D.bin"):
            shutil.copyfile(self.dataset / "sparse/0" / name, directory / name)
        records = ablation.sfm.image_records(self.dataset / "sparse/0/images.bin")
        (directory / "images.bin").write_bytes(struct.pack("<Q", len(registered)) + b"".join(records[i][1] for i in sorted(registered)))
        report = json.loads(self.report_path.read_text())
        report["registered_model_sha256"] = {name: room.sha(directory / name) for name in ablation.sfm.MODEL_FILES}
        self.write(self.report_path, report)

    def completed_d1(self, step=29999):
        state = self.completed("d01", step)
        path = state / "provider-receipt.json"
        receipt = json.loads(path.read_text())
        receipt["dataset_files"] = REAL_INVENTORY(self.d1_dataset)
        self.write(path, receipt)
        return state

    def add_fallback(self, authorized):
        registered = self.training_ids - {2}
        images = self.dataset / "sparse/0/images.bin"
        records = ablation.sfm.image_records(images)
        records[2] = ablation.sfm.image_records(self.original / "sparse/0/images.bin")[2]
        images.write_bytes(struct.pack("<Q", len(records)) + b"".join(records[i][1] for i in sorted(records)))
        points = bytearray(struct.pack("<Q", 100))
        for point_id in range(1, 101):
            points.extend(struct.pack("<Q3d3BdQ", point_id, point_id * .01, 0., 2., 128, 128, 128, .1, len(registered)))
            for image_id in sorted(registered):
                points.extend(struct.pack("<II", image_id, point_id - 1))
        (self.dataset / "sparse/0/points3D.bin").write_bytes(points)
        for name in ("images.bin", "points3D.bin"):
            self.rehash_model(name)
        for path in (self.run_report_path, self.report_path, self.dataset / "adapter-report.json"):
            data = json.loads(path.read_text())
            data["fallback_authorized"] = authorized
            if path != self.run_report_path:
                data.update(registered_training_ids=sorted(registered), original_pose_fallback_ids=[2])
            if path == self.report_path:
                data.update(missing_from_selected_model_ids=[2], unregistered_training_ids=[2], final_observations=13200,
                            observations_by_training_image={str(i): 100 if i in registered else 0 for i in self.training_ids})
                data["registration"]["models"][0]["registered_ids"] = sorted(registered)
            if path.name == "adapter-report.json":
                data["point_observations"] = 13200
            self.write(path, data)
        self.registered_model(registered)

    def test_d2_requires_collected_d01_final_metrics_and_exact_predecessor_dataset(self):
        with self.assertRaisesRegex(ValueError, "completed D01"):
            ablation.prepare(self.dataset, "d02")
        state = self.completed_d1(step=2999)
        with self.assertRaisesRegex(ValueError, "missing"):
            ablation.prepare(self.dataset, "d02")
        path = state / "download/result/stats/val_step29999.json"
        self.write(path, {"psnr": 19.9, "ssim": .78, "lpips": .40})
        with self.assertRaisesRegex(ValueError, "collected artifact"):
            ablation.prepare(self.dataset, "d02")
        receipt_path = state / "provider-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["artifacts"] = [{"path": "result/stats/val_step29999.json", "sha256": room.sha(path), "bytes": path.stat().st_size}]
        self.write(receipt_path, receipt)
        plan = ablation.prepare(self.dataset, "d02")
        self.assertEqual(plan["completed_d01_metrics"][0]["psnr"], 19.9)
        self.assertEqual((plan["steps"], plan["max_training_seconds"], plan["fixed_eval_every"], plan["random_seed"]), (30000, 4200, 8, 42))
        receipt["dataset_files"] = REAL_INVENTORY(self.original)
        self.write(receipt_path, receipt)
        with self.assertRaisesRegex(ValueError, "exact cached D1 dataset"):
            ablation.prepare(self.dataset, "d02")

    def test_d2_rejects_wrong_label_nonfinite_metrics_and_active_predecessor(self):
        self.completed_d1()
        with self.assertRaisesRegex(ValueError, "follow the original D01"):
            ablation.prepare(self.dataset, "d01")
        path = self.root / "d01/provider-receipt.json"
        receipt = json.loads(path.read_text())
        receipt["phase"] = "training_started"
        self.write(path, receipt)
        with self.assertRaisesRegex(ValueError, "cleanup reconciliation"):
            ablation.prepare(self.dataset, "d02")
        receipt["phase"] = "terminated"
        metrics = self.root / "d01/download/result/stats/val_step29999.json"
        self.write(metrics, {"psnr": float("nan"), "ssim": .8, "lpips": .4})
        receipt["artifacts"][0].update(sha256=room.sha(metrics), bytes=metrics.stat().st_size)
        self.write(path, receipt)
        with self.assertRaisesRegex(ValueError, "finite"):
            ablation.prepare(self.dataset, "d02")

    def test_d2_default_rejects_fallback_and_explicit_fallback_preserves_full_cohort(self):
        self.completed_d1()
        self.add_fallback(False)
        with self.assertRaisesRegex(ValueError, "fallback authorization"):
            ablation.prepare(self.dataset, "d02")
        self.add_fallback(True)
        plan = ablation.prepare(self.dataset, "d02")
        self.assertEqual(plan["sfm_dataset"]["original_pose_fallback_ids"], [2])
        self.assertEqual(len(plan["sfm_dataset"]["registered_training_ids"]), 132)
        self.assertTrue(plan["sfm_dataset"]["fallback_authorized"])
        self.assertEqual(len(plan["sfm_dataset"]["evaluation_images"]), 20)

    def test_d2_rejects_profile_options_helpers_cache_and_partition_mutations(self):
        self.completed_d1()
        original = json.loads(self.report_path.read_text())
        changes = [{"profile": {**ablation.sfm_incremental.PROFILE, "random_seed": 5}}, {"source_sha256": {}},
                   {"copied_database_sha256": "0" * 64}, {"cache": {}}, {"registered_model_sha256": {}},
                   {"registered_training_ids": sorted(self.training_ids - {2})}, {"original_pose_fallback_ids": [1]},
                   {"registered_in_other_models_ids": [2]}, {"unregistered_training_ids": [2]},
                   {"scene_quality_accepted": True}, {"heldout_pixels_used_by_sfm": True}]
        for change in changes:
            self.write(self.report_path, {**original, **change})
            with self.subTest(change=change), self.assertRaises(ValueError):
                ablation.prepare(self.dataset, "d02")
        self.write(self.report_path, original)
        run = json.loads(self.run_report_path.read_text())
        changed = json.loads(json.dumps(original))
        changed["registration"]["options"]["mapper"]["abs_pose_refine_focal_length"] = True
        run["mapping_options"] = changed["registration"]["options"]
        self.write(self.report_path, changed)
        self.write(self.run_report_path, run)
        with self.assertRaisesRegex(ValueError, "frozen registration"):
            ablation.prepare(self.dataset, "d02")

    def test_d2_rejects_changed_copied_database_even_if_receipts_are_rehashed(self):
        self.completed_d1()
        database = self.dataset.parent / "work/features.db"
        for statement in ("UPDATE keypoints SET rows=101 WHERE image_id=2",
                          "UPDATE two_view_geometries SET data=x'0100000000000000'",
                          "CREATE TABLE extra_cache (image_id INTEGER)"):
            shutil.copyfile(self.d1_dataset.parent / "work/features.db", database)
            with sqlite3.connect(database) as db:
                db.execute(statement)
            db.close()
            report = json.loads(self.report_path.read_text())
            report["copied_database_sha256"] = room.sha(database)
            self.write(self.report_path, report)
            with self.subTest(statement=statement), self.assertRaisesRegex(ValueError, "exact copied D01"):
                ablation.prepare(self.dataset, "d02")

    def test_d2_allows_sqlite_header_changes_only_with_post_mapping_hash(self):
        self.completed_d1()
        database = self.dataset.parent / "work/features.db"
        before = room.sha(database)
        with sqlite3.connect(database) as db:
            db.execute("PRAGMA user_version=4")
        db.close()
        self.assertNotEqual(room.sha(database), before)
        with self.assertRaisesRegex(ValueError, "exact copied D01"):
            ablation.prepare(self.dataset, "d02")
        report = json.loads(self.report_path.read_text())
        report["copied_database_sha256"] = room.sha(database)
        self.write(self.report_path, report)
        plan = ablation.prepare(self.dataset, "d02")
        self.assertEqual(plan["sfm_dataset"]["cache"]["database_sha256"], before)
        self.assertEqual(plan["sfm_dataset"]["copied_database_sha256"], room.sha(database))

    def test_d2_rejects_heldout_tracks_dropped_cohort_and_changed_original_fallback(self):
        self.completed_d1()
        self.add_fallback(True)
        path = self.dataset / "sparse/0/images.bin"
        original = path.read_bytes()
        records = ablation.sfm.image_records(path)
        for image_id, pattern in ((1, "heldout"), (2, "fallback")):
            changed = dict(records)
            name, raw, count = changed[image_id]
            raw = bytearray(raw)
            struct.pack_into("<d", raw, 36, .25)
            changed[image_id] = (name, bytes(raw), count)
            path.write_bytes(struct.pack("<Q", 153) + b"".join(changed[i][1] for i in sorted(changed)))
            self.rehash_model(path.name)
            with self.subTest(image_id=image_id), self.assertRaisesRegex(ValueError, pattern):
                ablation.prepare(self.dataset, "d02")
        path.write_bytes(struct.pack("<Q", 152) + b"".join(records[i][1] for i in sorted(records) if i != 2))
        self.rehash_model(path.name)
        with self.assertRaisesRegex(ValueError, "dropped"):
            ablation.prepare(self.dataset, "d02")
        path.write_bytes(original)
        self.rehash_model(path.name)
        points = self.dataset / "sparse/0/points3D.bin"
        changed = bytearray(points.read_bytes())
        struct.pack_into("<I", changed, 8 + 51, 1)
        points.write_bytes(changed)
        self.rehash_model(points.name)
        with self.assertRaisesRegex(ValueError, "excluded"):
            ablation.prepare(self.dataset, "d02")

    def test_d2_plan_mutation_stops_before_provider_and_preserves_budget_hold(self):
        self.completed_d1()
        plan_path = self.root / "d2-plan.json"
        plan = ablation.prepare(self.dataset, "d02")
        self.assertEqual(plan["reserved_usd"], "4.9110336000")
        self.assertEqual(plan["prior_costs_and_holds_usd"], "11.5020879900")
        self.write(plan_path, plan)
        report = json.loads(self.report_path.read_text())
        report["registration_seconds"] = 100.
        self.write(self.report_path, report)
        modal = self.modal()
        with patch.object(room, "run") as dispatch:
            with self.assertRaisesRegex(ValueError, "plan inputs"):
                ablation.execute(modal, plan_path, self.root / "d02")
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
