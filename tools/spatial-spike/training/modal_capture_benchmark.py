#!/usr/bin/env python3
"""One explicit allocation for the owner's frozen September 23 capture.

fNN: fixed poses / 3000 steps; pNN: pose optimization / 3000; sNN: pose
optimization / 30000. Every invocation is separate. All attempts share the
existing September approval lock, historical costs, markers and cleanup gate.
"""
import argparse
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

import modal_ablation as ablation
import modal_room as room
from modal_retry import bounded_json, private_path

PRIVATE_ROOT = Path.home() / "LocalSpatialExperiments"
DATASET = PRIVATE_ROOT / "capture-test-20260923/dataset"
CAPTURE_MANIFEST = PRIVATE_ROOT / "capture-test-20260923/capture/manifest.json"
CAPTURE_MANIFEST_SHA256 = "c3b8818adb5c4fe54399b52ae51cf743a24cdda8c76cd663ecee9a081f33c124"
PROFILE = "capture-benchmark-20260923-v1"
MARKER_PREFIX = "spatial-ablation-20260914-capture20260923-"
SOURCE_NAMES = ("modal_capture_benchmark.py", "prepare_capture_benchmark.py")
STAGES = {
    "f": {"pose_optimization": False, "steps": 3000, "max_training_seconds": 900, "predecessor": None},
    "p": {"pose_optimization": True, "steps": 3000, "max_training_seconds": 900, "predecessor": "f"},
    "s": {"pose_optimization": True, "steps": 30000, "max_training_seconds": 4200, "predecessor": "p"},
}


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def money(value):
    room.require(isinstance(value, str), "cost evidence must use exact decimal strings")
    try:
        result = Decimal(value)
    except InvalidOperation as exc:
        raise ValueError("invalid cost evidence") from exc
    room.require(result.is_finite() and result >= 0, "invalid cost evidence")
    return result


def source_binding():
    binding = room.source_binding()  # Requires the entire worktree committed and clean.
    source = Path(__file__).resolve().parent
    for name in SOURCE_NAMES:
        path = source / name
        room.require(path.is_file() and not path.is_symlink(), "benchmark source is missing or linked")
        committed = subprocess.check_output([
            "git", "-C", str(source.parents[2]), "show",
            f"{binding['commit']}:tools/spatial-spike/training/{name}",
        ])
        digest = hashlib.sha256(committed).hexdigest()
        room.require(room.sha(path) == digest, "benchmark helper differs from committed source")
        binding["files"][name] = digest
    return binding


def ledger():
    """Read the original approval; never reset, narrow or create a new budget."""
    costs = bounded_json(ablation.COST_BASELINE)
    room.require(costs.get("budget_ceiling_usd") == "25.00" and
                 costs.get("total_historical_spatial_usage_usd") == "1.68002079",
                 "the original historical approval baseline changed")
    held = money(costs["total_historical_spatial_usage_usd"])
    full_hold = money(room.policy()["compute_upper_bound_usd"])
    predecessors = []
    for marker_path in sorted(PRIVATE_ROOT.glob(ablation.MARKER_GLOB)):
        marker = bounded_json(marker_path)
        receipt_path = private_path(Path(marker["state"])) / "provider-receipt.json"
        receipt = bounded_json(receipt_path)
        ablation.require_cleanup_reconciled(receipt_path, receipt)
        charge = money(marker["reserved_usd"])
        room.require(charge >= full_hold, "a previous attempt lost its full-lifetime hold")
        billing_path = receipt_path.parent / "billing-readback.json"
        billing_sha = None
        if billing_path.exists():
            billing = bounded_json(billing_path)
            room.require(billing.get("app_id") == receipt.get("app_id") and
                         billing.get("sandbox_id") == receipt.get("sandbox_id") and
                         billing.get("closed_hourly_intervals") is True,
                         "previous billing is incomplete or attributed to another attempt")
            charge = money(billing["actual_metered_usd"])
            billing_sha = room.sha(billing_path)
        for key, prefix in (("app_id", "ap-"), ("sandbox_id", "sb-")):
            room.require(isinstance(receipt.get(key), str) and
                         re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9_-]{1,160}", receipt[key]),
                         "previous provider identity is missing")
        held += charge
        predecessors.append({
            "marker": str(marker_path), "marker_sha256": room.sha(marker_path),
            "receipt_sha256": room.sha(receipt_path), "billing_sha256": billing_sha,
            "app_id": receipt["app_id"], "sandbox_id": receipt["sandbox_id"],
            "cost_or_hold_usd": str(charge),
        })
    inventory = costs.get("inventory")
    room.require(isinstance(inventory, dict) and
                 isinstance(inventory.get("active_by_app"), dict) and
                 isinstance(inventory.get("exact_sandbox_terminal_polls"), dict),
                 "historical allocation inventory is missing")
    return held, full_hold, predecessors, inventory


def cohort(dataset, files, source):
    room.require(dataset == private_path(DATASET), "only the frozen September 23 dataset is configured")
    manifest = private_path(CAPTURE_MANIFEST)
    room.require(manifest.is_file() and manifest.stat().st_size <= 2 * 1024**2 and
                 room.sha(manifest) == CAPTURE_MANIFEST_SHA256, "original capture manifest changed")
    report = bounded_json(dataset / "adapter-report.json")
    names = [f"{i:06d}.jpg" for i in range(1, 401)]
    evaluation = names[::8]
    training = [name for name in names if name not in set(evaluation)]
    room.require(report.get("frames") == 400 and report.get("benchmark_profile") == PROFILE and
                 report.get("capture_manifest_sha256") == CAPTURE_MANIFEST_SHA256 and
                 report.get("benchmark_helper_sha256") == source["files"]["prepare_capture_benchmark.py"],
                 "dataset does not match this capture and committed benchmark preparer")
    room.require(report.get("training_images") == training and report.get("evaluation_images") == evaluation and
                 report.get("seed_image_names") == training and report.get("seed_colors_from_training_only") is True and
                 report.get("seed_geometry_from_training_observations_only") is True,
                 "the frozen 350/50 split or training-only seed colors/geometry changed")
    image_hashes = report.get("image_sha256")
    room.require(isinstance(image_hashes, dict) and set(image_hashes) == set(names) and
                 all(isinstance(v, str) and re.fullmatch(r"[a-f0-9]{64}", v) for v in image_hashes.values()),
                 "the exact 400-image inventory is missing")
    return {
        "profile": PROFILE, "capture_manifest_sha256": CAPTURE_MANIFEST_SHA256,
        "dataset_inventory_sha256": fingerprint(files),
        "training_images": training,
        "evaluation_images": evaluation,
        "image_sha256": image_hashes,
        "evaluation_image_sha256": {name: image_hashes[name] for name in evaluation},
        "seed_image_names": training, "seed_colors_from_training_only": True,
        "seed_geometry_from_training_observations_only": True,
        "model_sha256": report["model_sha256"],
    }


def collected_artifact(state, receipt, relative):
    path = private_path(state / "download" / relative)
    artifact = next((row for row in receipt.get("artifacts", []) if row.get("path") == relative), None)
    room.require(path.is_file() and not path.is_symlink() and artifact is not None and
                 artifact.get("bytes") == path.stat().st_size and artifact.get("sha256") == room.sha(path),
                 "predecessor artifact does not match its collected receipt")
    return path


def prerequisite(stage, binding, source, files, predecessors):
    required = STAGES[stage]["predecessor"]
    if required is None:
        return None
    for entry in reversed(predecessors):
        marker_path = Path(entry["marker"])
        if not re.fullmatch(re.escape(MARKER_PREFIX) + required + r"[0-9]{2}\.allocation\.json", marker_path.name):
            continue
        marker = bounded_json(marker_path)
        state = private_path(Path(marker["state"]))
        receipt = bounded_json(state / "provider-receipt.json")
        if receipt.get("outcome") != "trained":
            continue
        plan_path = private_path(Path(marker["plan_path"]))
        prior_plan = bounded_json(plan_path)
        room.require(room.sha(plan_path) == marker.get("plan_sha256"), "predecessor frozen plan changed")
        room.require(prior_plan.get("dependency_baseline_sha256") == room.sha(ablation.BASELINE_RUN) and
                     receipt.get("dependency_baseline_sha256") == prior_plan["dependency_baseline_sha256"],
                     "predecessor used a different dependency baseline")
        room.require(prior_plan.get("cohort") == binding and prior_plan.get("dataset") == str(DATASET.resolve()) and
                     prior_plan.get("source", {}).get("files") == source["files"] and
                     receipt.get("dataset_files") == files, "predecessor used different data, split or source")
        expected = STAGES[required]
        room.require(prior_plan.get("stage") == required and prior_plan.get("steps") == expected["steps"] and
                     prior_plan.get("pose_optimization") is expected["pose_optimization"] and
                     receipt.get("pose_optimization") is expected["pose_optimization"],
                     "predecessor is not the required one-variable baseline")
        run = bounded_json(collected_artifact(state, receipt, "result/run.json"))
        room.require(run.get("status") == "trained" and run.get("frames") == 400 and
                     run.get("max_steps") == expected["steps"] and
                     run.get("pose_optimization") is expected["pose_optimization"],
                     "predecessor did not complete the required training stage")
        step = expected["steps"] - 1
        relative = f"result/stats/val_step{step}.json"
        metrics_path = collected_artifact(state, receipt, relative)
        metrics = bounded_json(metrics_path)
        room.require(all(type(metrics.get(key)) in (int, float) and math.isfinite(metrics[key])
                         for key in ("psnr", "ssim", "lpips")), "predecessor metrics must be finite")
        renders = [f"result/renders/val_step{step}_{i:04d}.png" for i in range(50)]
        recorded = [row.get("path") for row in receipt.get("artifacts", [])
                    if str(row.get("path", "")).startswith(f"result/renders/val_step{step}_")]
        room.require(sorted(recorded) == renders, "predecessor lacks the complete fixed 50-view evaluation")
        for relative in renders:
            collected_artifact(state, receipt, relative)
        return {"marker": str(marker_path), "plan_sha256": room.sha(plan_path),
                "receipt_sha256": entry["receipt_sha256"], "metrics_sha256": room.sha(metrics_path),
                "psnr": metrics["psnr"], "ssim": metrics["ssim"], "lpips": metrics["lpips"]}
    raise ValueError(f"stage {stage} requires a completed {required} stage on this exact frozen capture")


def prepare(dataset, label):
    room.require(isinstance(label, str) and re.fullmatch(r"[fps](?:0[1-9]|[1-9][0-9])", label),
                 "use a reviewed fNN, pNN or sNN attempt numbered 01–99")
    dataset = private_path(dataset)
    source = source_binding()
    files = room.inventory(dataset)
    binding = cohort(dataset, files, source)
    held, reserve, predecessors, _ = ledger()
    room.require(held + reserve <= Decimal("25.00"), "attempt exceeds the shared $25 authorization")
    stage = label[0]
    return {
        "schema_version": 1, "profile": PROFILE, "label": label, "stage": stage,
        "app_name": f"rendprop-capture-benchmark-{label}-20260923", "dataset": str(dataset),
        "cohort": binding, "source": source,
        "dependency_baseline_sha256": room.sha(ablation.BASELINE_RUN),
        "cost_baseline_sha256": room.sha(ablation.COST_BASELINE),
        "prior_costs_and_holds_usd": str(held), "reserved_usd": str(reserve), "ceiling_usd": "25.00",
        "predecessors": predecessors, "prerequisite": prerequisite(stage, binding, source, files, predecessors),
        **{key: STAGES[stage][key] for key in ("pose_optimization", "steps", "max_training_seconds")},
        "max_gaussians": 500000, "fixed_eval_every": 8, "random_seed": 42, "automatic_retries": 0,
        "evaluation": "same 50 loss-heldout images; seed colors and feature geometry use only 350 training observations; validation uses original ARKit VIO poses, not independent ground truth",
    }


def fresh_output_path(path):
    path = private_path(path, must_exist=False)
    room.require(not path.exists() and path.parent.is_dir(), "fresh private output path required")
    room.require(not path.is_relative_to(DATASET.resolve()) and
                 not path.is_relative_to(CAPTURE_MANIFEST.parent.resolve()),
                 "outputs cannot modify the frozen dataset or original capture")
    return path


def execute(modal, plan_path, state):
    room.require(modal.__version__ == "1.5.3", "use pinned Modal SDK 1.5.3")
    plan = bounded_json(plan_path)
    room.require(plan == prepare(Path(plan["dataset"]), plan["label"]), "plan data, source, predecessor or costs changed")
    state = fresh_output_path(state)
    marker = PRIVATE_ROOT / f"{MARKER_PREFIX}{plan['label']}.allocation.json"
    room.require(not marker.exists(), "this attempt was already reserved; no automatic retry")
    _, _, _, inventory = ledger()
    app_ids = set(inventory["active_by_app"]) | {row["app_id"] for row in plan["predecessors"]}
    for app_id in sorted(app_ids):
        room.require(not list(modal.Sandbox.list(app_id=app_id)), "a prior spatial sandbox is active")
    sandbox_ids = set(inventory["exact_sandbox_terminal_polls"]) | {row["sandbox_id"] for row in plan["predecessors"]}
    for sandbox_id in sorted(sandbox_ids):
        prior = modal.Sandbox.from_id(sandbox_id)
        try:
            room.require(prior.poll() is not None, "a prior spatial allocation is not terminal")
        finally:
            prior.detach()
    app = modal.App.lookup(plan["app_name"], environment_name="main", create_if_missing=True)
    room.require(isinstance(app.app_id, str) and app.app_id.startswith("ap-"), "invalid benchmark app identity")
    room.require(not list(modal.Sandbox.list(app_id=app.app_id)), "benchmark namespace has active resources")
    # All labels deliberately remain inside the old ledger's wildcard. No new
    # approval pool or reservation reset; ambiguous create retains this marker.
    room.save(marker, {"state": str(state), "reserved_usd": plan["reserved_usd"], "app_id": app.app_id,
                       "plan_path": str(private_path(plan_path)), "plan_sha256": room.sha(plan_path),
                       "utc": datetime.now(timezone.utc).isoformat(), "automatic_retries": 0})
    room.run(modal, Path(plan["dataset"]), state, app_name=plan["app_name"],
             pose_opt=plan["pose_optimization"], dependency_baseline=ablation.BASELINE_RUN,
             max_steps=plan["steps"], max_seconds=plan["max_training_seconds"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run"))
    parser.add_argument("--dataset", type=Path, default=DATASET)
    parser.add_argument("--label")
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--confirm-one-allocation", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "plan":
        args.plan = fresh_output_path(args.plan)
        room.save(args.plan, prepare(args.dataset, args.label))
        print("PASS: frozen capture plan saved; no provider calls")
        return
    room.require(args.state is not None and args.confirm_one_allocation, "explicit one-allocation confirmation and state required")
    with (PRIVATE_ROOT / "room-approval-20260910.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ["MODAL_PROFILE"] = room.PROFILE
        import modal
        execute(modal, args.plan, args.state)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise InterruptedError(f"capture benchmark interrupted by signal {signum}")
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {type(exc).__name__}; inspect private receipts; no automatic retry", file=sys.stderr)
        sys.exit(1)
