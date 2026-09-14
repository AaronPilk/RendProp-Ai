#!/usr/bin/env python3
"""Explicit September 14 ablations, sharing the original $25 approval lock.

One invocation can allocate only once. Old reservations are never reset. Each
attempt has its own billing app; unresolved costs retain their full-lifetime
hold. This is a manual experiment harness, not an automatic retry policy.
"""
import argparse
from datetime import datetime, timezone
from decimal import Decimal
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import sqlite3
import struct
import subprocess
import sys

import modal_room as room
from modal_retry import private_path, bounded_json
import refine_sfm as sfm

PRIVATE_ROOT = Path.home() / "LocalSpatialExperiments"
COST_BASELINE = PRIVATE_ROOT / "spatial-ablation-20260914-cost-baseline.json"
BASELINE_RUN = PRIVATE_ROOT / "modal-room-20260911-01/download/result/run.json"
ORIGINAL_DATASET = PRIVATE_ROOT / "capture-20260911.liWf0i/dataset"
MARKER_GLOB = "spatial-ablation-20260914-*.allocation.json"


def require_cleanup_reconciled(receipt_path, receipt):
    room.require(receipt.get("phase") == "terminated" and
                 receipt.get("terminate", {}).get("poll_exit_code") is not None,
                 "previous attempt requires explicit cleanup reconciliation")
    if receipt.get("remote_copy_delete", {}).get("response") == "success":
        return
    # A disappeared provider worker cannot acknowledge a directory removal.
    # A separately observed, terminal PRE-MEDIA setup failure can be continued;
    # this never rewrites the failed deletion receipt or excuses private input
    # cleanup once the first transfer could have started.
    observed = bounded_json(receipt_path.parent / "provider-readback.json")
    phases = {event.get("phase") for event in receipt.get("events", [])}
    setup_exit = receipt.get("stages", {}).get("setup", {}).get("exit_code")
    room.require(receipt.get("outcome") == "failed" and receipt.get("transferred_files") == [] and
                 "setup_started" in phases and "outbound_denied" not in phases and
                 "training_started" not in phases and type(setup_exit) is int and setup_exit != 0 and
                 observed.get("provider_receipt_sha256") == room.sha(receipt_path) and
                 observed.get("sandbox_id") == receipt.get("sandbox_id") and
                 observed.get("app_id") == receipt.get("app_id") and
                 observed.get("provider_state", {}).get("terminal") is True and
                 observed.get("provider_state", {}).get("exception_classification") == "worker_disappeared" and
                 observed.get("active_app_sandbox_count") == 0 and observed.get("active_app_sandboxes") == [] and
                 observed.get("private_transfer_proof", {}).get("failed_during_dependency_setup") is True,
                 "previous attempt requires explicit pre-media cleanup reconciliation")


def completed_pose_metrics(receipt_path, receipt, expected_step=2999):
    """Bind an ordered prerequisite to its collected final held-out metrics."""
    room.require(expected_step in (2999, 29999), "unreviewed predecessor evaluation step")
    previous, following = ("A", "B") if expected_step == 2999 else ("B", "D")
    room.require(receipt.get("outcome") == "trained" and receipt.get("pose_optimization") is True,
                 f"{following} requires a trained pose-enabled {previous} result")
    relative = f"result/stats/val_step{expected_step}.json"
    metrics_path = receipt_path.parent / "download" / relative
    metrics = bounded_json(metrics_path)
    artifact = next((item for item in receipt.get("artifacts", []) if item.get("path") == relative), None)
    room.require(artifact is not None and artifact.get("sha256") == room.sha(metrics_path)
                 and artifact.get("bytes") == metrics_path.stat().st_size,
                 f"{previous} held-out metrics do not match collected artifact")
    room.require(all(type(metrics.get(key)) in (int, float) and math.isfinite(metrics[key])
                     for key in ("psnr", "ssim", "lpips")), f"{previous} held-out metrics must be finite")
    return {"path": str(metrics_path), "sha256": room.sha(metrics_path),
            "psnr": metrics["psnr"], "ssim": metrics["ssim"], "lpips": metrics["lpips"]}


def committed_sfm_helper(source):
    """The helper is local source, not a path supplied by private provenance."""
    helper = Path(__file__).resolve().with_name("refine_sfm.py")
    relative = "tools/spatial-spike/training/refine_sfm.py"
    committed = subprocess.check_output(["git", "-C", str(helper.parents[3]),
                                         "show", f"{source['commit']}:{relative}"])
    digest = hashlib.sha256(committed).hexdigest()
    room.require(room.sha(helper) == digest, "SfM helper differs from committed source")
    return digest


def validate_point_tracks(path, records, training_ids):
    """Check classic COLMAP tracks without installing a second pycolmap."""
    point_ids, counts = set(), {i: 0 for i in training_ids}
    max_track_length = sum(records[i][2] for i in training_ids)
    with path.open("rb") as stream:
        def read(size):
            value = stream.read(size)
            room.require(len(value) == size, "truncated SfM point model")
            return value
        count, = struct.unpack("<Q", read(8))
        room.require(100 <= count <= 500000, "SfM point count outside trainer limits")
        for _ in range(count):
            row = struct.unpack("<Q3d3BdQ", read(51))
            point_id, length = row[0], row[-1]
            room.require(point_id not in point_ids and all(math.isfinite(x) for x in (*row[1:4], row[-2])),
                         "duplicate or non-finite SfM point")
            point_ids.add(point_id)
            room.require(2 <= length <= max_track_length, "SfM points require real training-view tracks")
            seen = set()
            for _ in range(length):
                image_id, index = struct.unpack("<II", read(8))
                # COLMAP can retain multiple SIFT observations of the same point
                # in one image. The (image, point2D-index) pair must be unique.
                room.require(image_id in training_ids and (image_id, index) not in seen,
                             "SfM track contains an excluded image or duplicate observation")
                seen.add((image_id, index))
                name, raw, observations = records[image_id]
                room.require(index < observations, "SfM track observation index is invalid")
                offset = len(raw) - observations * 24 + index * 24
                x, y, observed_id = struct.unpack_from("<ddq", raw, offset)
                room.require(observed_id == point_id and math.isfinite(x) and math.isfinite(y),
                             "SfM track does not match its image observation")
                counts[image_id] += 1
            room.require(len({image_id for image_id, _ in seen}) >= 2,
                         "SfM point must be observed in at least two training views")
        room.require(stream.read(1) == b"", "extra bytes in SfM point model")
    for image_id in training_ids:
        _, raw, observations = records[image_id]
        assigned = 0
        for index in range(observations):
            _, _, point_id = struct.unpack_from("<ddq", raw, len(raw) - observations * 24 + index * 24)
            room.require(point_id == -1 or point_id in point_ids, "image observation references a missing SfM point")
            assigned += point_id != -1
        room.require(assigned == counts[image_id], "SfM point/image track counts disagree")
    return count, counts


def validate_sfm_dataset(dataset, files, original, source):
    """Only the fixed original cohort may produce the private D dataset."""
    original_dataset = private_path(ORIGINAL_DATASET)
    room.require(room.inventory(original_dataset) == original["dataset_files"],
                 "D requires the exact original source dataset")
    before = {item["path"]: item for item in original["dataset_files"]}
    after = {item["path"]: item for item in files}
    original_jpegs = {name: item for name, item in before.items() if name.startswith("images/")}
    room.require({name: item for name, item in after.items() if name.startswith("images/")} == original_jpegs,
                 "D requires the exact original JPEG inventory")
    room.require(after.get("sparse/0/cameras.bin") == before.get("sparse/0/cameras.bin"),
                 "D requires byte-identical original cameras.bin")
    train, heldout = sfm.fixed_split([Path(name).name for name in original_jpegs])
    training_ids = {int(name[:6]) for name in train}
    original_records = sfm.image_records(original_dataset / "sparse/0/images.bin")
    records = sfm.image_records(dataset / "sparse/0/images.bin")
    room.require(set(records) == set(original_records) == set(range(1, 154)) and
                 all(row[0] == f"{image_id:06d}.jpg" for image_id, row in records.items()),
                 "D requires all original image IDs and names")
    room.require(all(records[int(name[:6])] == original_records[int(name[:6])] and
                     records[int(name[:6])][2] == 0 for name in heldout),
                 "D heldout image records must remain byte-identical without observations")
    # These are fixed helper-owned siblings. Never resolve a path supplied by
    # the adapter report or grant a general '../' exception to private_path.
    run_path, report_path = dataset.parent / "sfm-run.json", dataset.parent / "sfm-report.json"
    run, report = bounded_json(run_path), bounded_json(report_path)
    adapter = bounded_json(dataset / "adapter-report.json")
    room.require(run.get("status") == report.get("status") == "prepared" and
                 run.get("profile") == report.get("profile") == adapter.get("sfm_profile") == sfm.PROFILE and
                 sfm.PROFILE["pycolmap_version"] == "4.2.0", "D requires completed official 4.2.0 SfM provenance")
    room.require(run.get("execute") is True and type(run.get("max_seconds")) is int and
                 1 <= run["max_seconds"] <= 1800 and
                 type(run.get("elapsed_seconds")) in (int, float) and
                 math.isfinite(run["elapsed_seconds"]) and run["elapsed_seconds"] >= 0 and
                 run.get("training_frames") == 133 and run.get("evaluation_frames") == 20,
                 "D requires the bounded 133/20 SfM run")
    room.require(report.get("training_images") == train and
                 report.get("evaluation_images") == run.get("evaluation_images") == adapter.get("evaluation_images") == heldout and
                 report.get("evaluation_pose_records_unchanged") is True and
                 report.get("heldout_pixels_used_by_sfm") is False and
                 report.get("original_arkit_seeds_used") is False and report.get("gpu_used") is False and
                 adapter.get("gpu_training_performed") is False and adapter.get("reprojection_error_measured") is True and
                 adapter.get("sfm_provenance") == "../sfm-report.json",
                 "D SfM split, pose, or seed provenance changed")
    original_models = {Path(name).name: item["sha256"] for name, item in before.items() if name.startswith("sparse/0/")}
    helper_hash = committed_sfm_helper(source)
    room.require(report.get("source_adapter_report_sha256") == before["adapter-report.json"]["sha256"] and
                 report.get("source_model_sha256") == original_models and report.get("helper_sha256") == helper_hash,
                 "D SfM source/helper hashes do not match the committed original experiment")
    room.require(after["sparse/0/points3D.bin"]["sha256"] != before["sparse/0/points3D.bin"]["sha256"],
                 "D cannot reuse original ARKit seed model")
    point_count, observations = validate_point_tracks(dataset / "sparse/0/points3D.bin", records, training_ids)
    room.require(point_count == report.get("final_points") == adapter.get("initial_points") and
                 sum(observations.values()) == report.get("final_observations") == adapter.get("point_observations") and
                 report.get("observations_by_training_image") == {str(i): count for i, count in observations.items()},
                 "D SfM point/observation receipts do not match the derived model")
    database = private_path(dataset.parent / "work/features.db")
    room.require(database.is_file() and database.stat().st_size <= room.MAX_DATASET, "invalid SfM feature database")
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    try:
        database_images = connection.execute("SELECT image_id, name FROM images ORDER BY image_id").fetchall()
    finally:
        connection.close()
    room.require(database_images == [(i, f"{i:06d}.jpg") for i in sorted(training_ids)],
                 "D feature database must contain exactly the 133 training IDs")
    pairs_path = private_path(dataset.parent / "work/matched-pairs.txt")
    room.require(pairs_path.is_file() and pairs_path.stat().st_size <= 2 * 1024**2, "invalid SfM pair list")
    pairs = [tuple(line.split()) for line in pairs_path.read_text().splitlines()]
    room.require(pairs and pairs == sorted(set(pairs)) and
                 all(len(pair) == 2 and pair[0] < pair[1] and set(pair) <= set(train) for pair in pairs) and
                 report.get("pair_count") == len(pairs) and report.get("pair_list_sha256") == room.sha(pairs_path),
                 "D pair list is not bound to the training-only SfM report")
    return {"original_dataset": str(original_dataset), "original_adapter_sha256": before["adapter-report.json"]["sha256"],
            "source_model_sha256": original_models, "derived_model_sha256": adapter["model_sha256"],
            "sfm_helper_sha256": helper_hash, "sfm_report_sha256": room.sha(report_path),
            "sfm_run_sha256": room.sha(run_path), "feature_database_sha256": room.sha(database),
            "matched_pairs_sha256": room.sha(pairs_path), "training_images": train, "evaluation_images": heldout}


def prepare(dataset, label):
    room.require(re.fullmatch(r"[abd][0-9]{2}", label) is not None, "only reviewed A, B and D attempts are configured; C has no additional original frames")
    is_b = label.startswith("b")
    is_d = label.startswith("d")
    dataset = private_path(dataset)
    costs = bounded_json(COST_BASELINE)
    room.require(costs["budget_ceiling_usd"] == "25.00" and
                 costs["total_historical_spatial_usage_usd"] == "1.68002079", "historical cost baseline changed")
    files = room.inventory(dataset)
    original = bounded_json(PRIVATE_ROOT / "modal-room-20260911-01/provider-receipt.json")
    source = room.source_binding()
    if is_d:
        sfm_binding = validate_sfm_dataset(dataset, files, original, source)
    else:
        room.require(files == original["dataset_files"], "A and B require the exact original 153-frame dataset")
    held = Decimal(costs["total_historical_spatial_usage_usd"])
    predecessors = []
    completed_a = []
    completed_b = []
    for path in sorted(PRIVATE_ROOT.glob(MARKER_GLOB)):
        marker = bounded_json(path)
        receipt_path = private_path(Path(marker["state"])) / "provider-receipt.json"
        receipt = bounded_json(receipt_path)
        require_cleanup_reconciled(receipt_path, receipt)
        # A completed provider billing receipt may release the unused hold.
        # Until then use the whole reserve, never a guessed elapsed-time charge.
        reserve = Decimal(marker["reserved_usd"])
        room.require(reserve.is_finite() and reserve >= Decimal(room.policy()["compute_upper_bound_usd"]),
                     "invalid prior full-lifetime reserve")
        billing_path = receipt_path.parent / "billing-readback.json"
        if billing_path.exists():
            billing = bounded_json(billing_path)
            room.require(billing["app_id"] == receipt["app_id"] and billing["sandbox_id"] == receipt["sandbox_id"]
                         and billing["closed_hourly_intervals"] is True, "billing attribution incomplete")
            actual = Decimal(billing["actual_metered_usd"])
            room.require(actual.is_finite() and actual >= 0, "invalid actual cost")
            reserve = actual
        held += reserve
        predecessors.append({"marker": str(path), "marker_sha256": room.sha(path),
                             "receipt_sha256": room.sha(receipt_path), "app_id": receipt["app_id"],
                             "sandbox_id": receipt["sandbox_id"], "cost_or_hold_usd": str(reserve)})
        if is_b and re.fullmatch(r"spatial-ablation-20260914-a[0-9]{2}\.allocation\.json", path.name) \
                and receipt.get("outcome") == "trained":
            completed_a.append(completed_pose_metrics(receipt_path, receipt))
        if is_d and re.fullmatch(r"spatial-ablation-20260914-b[0-9]{2}\.allocation\.json", path.name) \
                and receipt.get("outcome") == "trained":
            completed_b.append(completed_pose_metrics(receipt_path, receipt, expected_step=29999))
    room.require(not is_b or completed_a, "B requires completed A with collected held-out metrics")
    room.require(not is_d or completed_b, "D requires completed B with collected final held-out metrics")
    reserve = Decimal(room.policy()["compute_upper_bound_usd"])
    room.require(held + reserve <= Decimal("25.00"), "attempt exceeds remaining $25 authorization")
    plan = {"schema_version": 1, "label": label, "app_name": f"rendprop-spatial-ablation-{label}-20260914",
            "dataset": str(dataset), "dataset_inventory_sha256": hashlib.sha256(
                json.dumps(files, sort_keys=True).encode()).hexdigest(),
            "baseline_run_sha256": room.sha(BASELINE_RUN), "cost_baseline_sha256": room.sha(COST_BASELINE),
            "source": source, "prior_costs_and_holds_usd": str(held),
            "reserved_usd": str(reserve), "ceiling_usd": "25.00", "predecessors": predecessors,
            "automatic_retries": 0, "pose_optimization": True, "steps": 30000 if is_b or is_d else 3000,
            "max_training_seconds": 4200 if is_b or is_d else 900, "max_gaussians": 500000,
            "fixed_eval_every": 8, "random_seed": 42, "evaluation": "loss-held-out; baseline seed initialization preserved"}
    if is_b:
        plan["completed_a_metrics"] = completed_a
    if is_d:
        plan.update(completed_b_metrics=completed_b, sfm_dataset=sfm_binding,
                    evaluation="same original 20 loss-heldout camera records; SfM uses only 133 training images; original ARKit VIO poses are not independent ground truth",
                    selection="manual review of B quality; no automatic quality threshold or retry",
                    c_unavailable_reason="The original capture has only 153 frames. A new dense capture changes the fixed heldout cohort.")
    return plan


def execute(modal, plan_path, state):
    room.require(modal.__version__ == "1.5.3", "use pinned Modal SDK 1.5.3")
    plan = bounded_json(plan_path)
    room.require(plan == prepare(Path(plan["dataset"]), plan["label"]), "plan inputs, source or costs changed")
    private_path(state, must_exist=False)
    room.require(not state.exists() and state.parent.is_dir(), "fresh private output directory required")
    marker = PRIVATE_ROOT / f"spatial-ablation-20260914-{plan['label']}.allocation.json"
    room.require(not marker.exists(), "this explicit attempt was already reserved; no automatic retry")
    historical = bounded_json(COST_BASELINE)["inventory"]
    app_ids = set(historical["active_by_app"]) | {p["app_id"] for p in plan["predecessors"]}
    for app_id in app_ids:
        room.require(not list(modal.Sandbox.list(app_id=app_id)), "a prior spatial sandbox is active")
    sandbox_ids = set(historical["exact_sandbox_terminal_polls"]) | {p["sandbox_id"] for p in plan["predecessors"]}
    for sandbox_id in sandbox_ids:
        previous = modal.Sandbox.from_id(sandbox_id)
        try:
            room.require(previous.poll() is not None, "prior allocation is not terminal")
        finally:
            previous.detach()
    # Empty app namespace has no running compute. The immutable reservation is
    # persisted BEFORE the sole GPU create, including ambiguous create responses.
    app = modal.App.lookup(plan["app_name"], environment_name="main", create_if_missing=True)
    room.require(not list(modal.Sandbox.list(app_id=app.app_id)), "ablation namespace has active resources")
    room.save(marker, {"state": str(state.resolve()), "reserved_usd": plan["reserved_usd"],
                       "app_id": app.app_id, "plan_sha256": room.sha(plan_path),
                       "utc": datetime.now(timezone.utc).isoformat(), "automatic_retries": 0})
    room.run(modal, Path(plan["dataset"]), state, app_name=plan["app_name"],
             pose_opt=True, dependency_baseline=BASELINE_RUN,
             max_steps=plan["steps"], max_seconds=plan["max_training_seconds"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run"))
    parser.add_argument("--dataset", type=Path)
    parser.add_argument("--label")
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--confirm-one-allocation", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "plan":
        room.require(args.dataset is not None and args.label is not None, "dataset and label required")
        private_path(args.plan, must_exist=False)
        room.require(not args.plan.exists(), "plan already exists")
        room.save(args.plan, prepare(args.dataset, args.label))
        print("PASS: exact ablation plan saved; no provider allocation")
        return
    room.require(args.state is not None and args.confirm_one_allocation, "explicit single allocation required")
    with (PRIVATE_ROOT / "room-approval-20260910.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ["MODAL_PROFILE"] = room.PROFILE
        import modal
        execute(modal, args.plan, args.state)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise InterruptedError(f"experiment interrupted by signal {signum}")
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {type(exc).__name__}; inspect private receipts; no automatic retry", file=sys.stderr)
        sys.exit(1)
