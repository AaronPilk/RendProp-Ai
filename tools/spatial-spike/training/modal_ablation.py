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
import sys

import modal_room as room
from modal_retry import private_path, bounded_json

PRIVATE_ROOT = Path.home() / "LocalSpatialExperiments"
COST_BASELINE = PRIVATE_ROOT / "spatial-ablation-20260914-cost-baseline.json"
BASELINE_RUN = PRIVATE_ROOT / "modal-room-20260911-01/download/result/run.json"
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


def completed_pose_metrics(receipt_path, receipt):
    """Bind B's prerequisite to A's collected finite held-out measurements."""
    room.require(receipt.get("outcome") == "trained" and receipt.get("pose_optimization") is True,
                 "B requires a trained pose-only A result")
    relative = "result/stats/val_step2999.json"
    metrics_path = receipt_path.parent / "download" / relative
    metrics = bounded_json(metrics_path)
    artifact = next((item for item in receipt.get("artifacts", []) if item.get("path") == relative), None)
    room.require(artifact is not None and artifact.get("sha256") == room.sha(metrics_path)
                 and artifact.get("bytes") == metrics_path.stat().st_size,
                 "A held-out metrics do not match collected artifact")
    room.require(all(type(metrics.get(key)) in (int, float) and math.isfinite(metrics[key])
                     for key in ("psnr", "ssim", "lpips")), "A held-out metrics must be finite")
    return {"path": str(metrics_path), "sha256": room.sha(metrics_path),
            "psnr": metrics["psnr"], "ssim": metrics["ssim"], "lpips": metrics["lpips"]}


def prepare(dataset, label):
    room.require(re.fullmatch(r"[ab][0-9]{2}", label) is not None, "only reviewed A and B attempts are configured")
    is_b = label.startswith("b")
    dataset = private_path(dataset)
    costs = bounded_json(COST_BASELINE)
    room.require(costs["budget_ceiling_usd"] == "25.00" and
                 costs["total_historical_spatial_usage_usd"] == "1.68002079", "historical cost baseline changed")
    files = room.inventory(dataset)
    original = bounded_json(PRIVATE_ROOT / "modal-room-20260911-01/provider-receipt.json")
    room.require(files == original["dataset_files"], "A and B require the exact original 153-frame dataset")
    held = Decimal(costs["total_historical_spatial_usage_usd"])
    predecessors = []
    completed_a = []
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
    room.require(not is_b or completed_a, "B requires completed A with collected held-out metrics")
    reserve = Decimal(room.policy()["compute_upper_bound_usd"])
    room.require(held + reserve <= Decimal("25.00"), "attempt exceeds remaining $25 authorization")
    plan = {"schema_version": 1, "label": label, "app_name": f"rendprop-spatial-ablation-{label}-20260914",
            "dataset": str(dataset), "dataset_inventory_sha256": hashlib.sha256(
                json.dumps(files, sort_keys=True).encode()).hexdigest(),
            "baseline_run_sha256": room.sha(BASELINE_RUN), "cost_baseline_sha256": room.sha(COST_BASELINE),
            "source": room.source_binding(), "prior_costs_and_holds_usd": str(held),
            "reserved_usd": str(reserve), "ceiling_usd": "25.00", "predecessors": predecessors,
            "automatic_retries": 0, "pose_optimization": True, "steps": 30000 if is_b else 3000,
            "max_training_seconds": 4200 if is_b else 900, "max_gaussians": 500000,
            "fixed_eval_every": 8, "random_seed": 42, "evaluation": "loss-held-out; baseline seed initialization preserved"}
    if is_b:
        plan["completed_a_metrics"] = completed_a
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
