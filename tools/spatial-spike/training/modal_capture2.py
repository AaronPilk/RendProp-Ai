#!/usr/bin/env python3
"""One preregistered recapture experiment under the existing $25 approval.

Only the capture changes from s01. The new 315/46 split is frozen separately;
its PSNR/SSIM/LPIPS are NOT a paired comparison with s01's older 50 views.
No production service, automatic retry, or independent budget is introduced.
"""
import argparse
from datetime import datetime, timezone, timedelta
from decimal import Decimal
import fcntl
import hashlib
import math
import os
from pathlib import Path
import signal
import subprocess
import sys

import modal_capture_benchmark as benchmark
import modal_ablation as ablation
import modal_room as room
from modal_retry import bounded_json, private_path

PRIVATE_ROOT = Path.home() / "LocalSpatialExperiments"
CAPTURE_ROOT = PRIVATE_ROOT / "capture2-20260930/source-capture"
DATASET = PRIVATE_ROOT / "capture2-20260930/dataset"
ADMISSION = PRIVATE_ROOT / "capture2-20260930/admission-receipt.json"
CAPTURE_MANIFEST_SHA256 = "1d10a27ee6ed5dd1e25e704867f3a28b52724390367d500a10fee6a871af123b"
ADMISSION_SHA256 = "dd269981ae55259161ab7cd809ec204b0dc7c91d646280fa61e810d1f24f001f"
ADAPTER_REPORT_SHA256 = "a88872f8ac9392cd47938f424adb1c50bf117e32b54c1b0bbc1146a48db42d56"
ADAPTER_COMMIT = "aedf861a6e4a35d2b552390b7e9ffc029fc39454"
ADAPTER_HELPERS = {"prepare_capture.py": "7a788c3a92ae43f0218e6a350ba2f55c86a8b250e5979a99de04bba4e9cb89b4",
                   "capture_blur.py": "09d46f75c7e5c6a48f5b06e760dbe763779fb198b699a2d3c28deb1fbfd73603"}
PROFILE = "capture2-20260930-s01-recipe-v1"
MARKER_NAME = "spatial-ablation-20260914-capture2-20260930-r01.allocation.json"
S01_MARKER_NAME = "spatial-ablation-20260914-capture20260923-s01.allocation.json"
S01_PLAN_SHA256 = "1ab44c5d0c045aa60dfac8552f76a34fa806f914651561bd0149bd46d0531d2e"
S01_RECEIPT_SHA256 = "6aae6e17cd7ae375bdb46fca0f1aa73bc81a849df0f161a9a0eeda98a6943a62"
RECIPE = {"pose_optimization": True, "steps": 30000, "max_training_seconds": 4200,
          "world_normalization": False, "max_gaussians": 500000,
          "fixed_eval_every": 8, "random_seed": 42, "automatic_retries": 0}
BILLING_WINDOW_END = datetime(2026, 10, 1, tzinfo=timezone.utc)
CREATION_MARGIN_SECONDS = 300
EXTRA_SOURCE_NAMES = ("modal_capture2.py", "refine_sfm.py", "refine_sfm_incremental.py")


def require_september_window():
    # The unchanged reserve includes September free egress. Do not carry that
    # assumption into October; leave five minutes for local/provider creation
    # after the final check, in addition to the entire provider-enforced TTL.
    latest_end = datetime.now(timezone.utc) + timedelta(
        seconds=room.policy()["timeout_seconds"] + CREATION_MARGIN_SECONDS)
    room.require(latest_end < BILLING_WINDOW_END,
                 "September billing window cannot cover the full sandbox lifetime; no allocation")


def source_binding():
    # This includes all original room helpers AND the imported benchmark/ledger.
    # The benchmark verifies committed-and-clean source before any provider call.
    binding = benchmark.source_binding()
    source = Path(__file__).resolve().parent
    for name in EXTRA_SOURCE_NAMES:
        path = source / name
        room.require(path.is_file() and not path.is_symlink(), "capture2 helper missing or linked")
        committed = subprocess.check_output(["git", "-C", str(source.parents[2]), "show",
            f"{binding['commit']}:tools/spatial-spike/training/{name}"])
        digest = hashlib.sha256(committed).hexdigest()
        room.require(room.sha(path) == digest, "capture2 helper differs from committed source")
        binding["files"][name] = digest
    return binding


def frozen_files(root, hashes):
    room.require(isinstance(hashes, dict) and hashes, "missing frozen input hashes")
    entries = list(root.rglob("*"))
    room.require(all(not path.is_symlink() for path in entries), "linked frozen input")
    room.require({str(path.relative_to(root)) for path in entries if path.is_file()} == set(hashes),
                 "frozen input inventory changed")
    for name, digest in hashes.items():
        path = root / name
        room.require(isinstance(name, str) and not Path(name).is_absolute() and
                     ".." not in Path(name).parts and path.resolve().is_relative_to(root.resolve()) and
                     path.is_file() and room.sha(path) == digest, "frozen input checksum changed")


def cohort(dataset, files):
    room.require(dataset == private_path(DATASET), "only the preregistered capture2 dataset is configured")
    capture = private_path(CAPTURE_ROOT)
    admission_path = private_path(ADMISSION)
    admission = bounded_json(admission_path)
    room.require(room.sha(admission_path) == ADMISSION_SHA256, "frozen admission receipt changed")
    report_path = dataset / "adapter-report.json"
    report = bounded_json(report_path)
    room.require(room.sha(report_path) == ADAPTER_REPORT_SHA256 and
                 admission.get("adapter_report") == {"path": str(report_path), "sha256": ADAPTER_REPORT_SHA256},
                 "preregistered adapter report changed")
    room.require(admission.get("format") == "rendprop-capture-admission-receipt" and
                 admission.get("schema_version") == 1 and admission.get("status") == "passed" and
                 admission.get("source_commit") == ADAPTER_COMMIT and
                 admission.get("source_capture") == str(capture) and admission.get("dataset") == str(dataset) and
                 admission.get("source_unchanged_before_and_after") is True and
                 admission.get("production_accepted") is False,
                 "capture admission lacks validated source provenance")
    room.require(room.sha(capture / "manifest.json") == CAPTURE_MANIFEST_SHA256 ==
                 admission.get("capture_manifest_sha256") == report.get("capture_manifest_sha256"),
                 "capture2 manifest changed")
    names = [f"{i:06d}.jpg" for i in range(1, 362)]
    evaluation = names[::8]
    training = [name for name in names if name not in set(evaluation)]
    room.require(admission.get("fixed_split") == {"evaluation_every": 8, "original_order_preserved": True,
                 "frames_filtered": 0, "training_count": 315, "evaluation_count": 46},
                 "original-index cohort may not be filtered or reindexed")
    for evidence in (report, admission):
        room.require(evidence.get("frames") == 361 and evidence.get("training_images") == training and
                     evidence.get("evaluation_images") == evaluation and evidence.get("seed_image_names") == training and
                     evidence.get("seed_colors_from_training_only") is True and
                     evidence.get("seed_geometry_from_training_observations_only") is True,
                     "frozen 315/46 split or training-only seeds changed")
    room.require(report.get("adapter_profile") == "capture-training-holdout-v1" and
                 report.get("adapter_helper_sha256") == ADAPTER_HELPERS["prepare_capture.py"],
                 "dataset was not made by the reviewed integrated adapter")
    hashes = admission.get("source_files_sha256")
    frozen_files(capture, hashes)
    room.require(len(hashes) == 723 and hashes.get("manifest.json") == CAPTURE_MANIFEST_SHA256,
                 "all 361 source JPEG/sidecar pairs are required")
    room.require(admission.get("dataset_files_sha256") == {row["path"]: row["sha256"] for row in files},
                 "dataset differs from admitted bytes")
    room.require(set(report.get("image_sha256", {})) == set(names), "exact 361-image inventory required")
    room.require(isinstance(report.get("capture_metadata_sha256"), dict) and
                 len(report["capture_metadata_sha256"]) == 361 and
                 all(hashes.get(name) == digest for name, digest in report["capture_metadata_sha256"].items()),
                 "source sidecar provenance changed")
    source_receipt = admission["source_receipt"]
    room.require(room.sha(private_path(Path(source_receipt["path"]))) == source_receipt["sha256"],
                 "source copy receipt changed")
    # The hash-frozen admission was produced by a separate full decoder + motion
    # revalidation, not a caller's asserted 'passed' flag. Bind those helper bytes
    # to their committed revision as well as to every admitted source input.
    helpers = admission.get("adapter_helpers", {})
    room.require(set(helpers) == set(ADAPTER_HELPERS), "admission helper inventory changed")
    for name, digest in ADAPTER_HELPERS.items():
        helper = Path(helpers[name]["path"])
        room.require(not helper.is_symlink() and helper.is_file() and
                     helpers[name]["sha256"] == digest == room.sha(helper), "admission helper changed")
        committed = subprocess.check_output(["git", "-C", admission["source_repository"], "show",
                                            f"{ADAPTER_COMMIT}:tools/spatial-spike/training/{name}"])
        room.require(hashlib.sha256(committed).hexdigest() == digest, "admission helper is not committed")
    quality = admission.get("capture_quality", {})
    summary = quality.get("summary", {})
    room.require(report.get("capture_quality") == quality and quality.get("status") == "passed" and
                 quality.get("policy") == {"max_median_px": 4.0, "max_fraction_over_px": [5.0, 0.35]} and
                 summary.get("frames") == 361 and summary.get("unknown_motion_frames") == 0 and
                 0 <= summary.get("predicted_smear_px", {}).get("median", float("inf")) <= 4 and
                 0 <= summary.get("frames_over_px", {}).get("5", float("inf")) <= 361 * 0.35,
                 "source capture motion admission failed")
    equivalence = admission["binary_equivalence"]
    proof_path = private_path(Path(equivalence["path"]))
    proof = bounded_json(proof_path)
    room.require(room.sha(proof_path) == equivalence["sha256"] and equivalence["status"] == "passed" and
                 proof.get("status") == "passed" and proof.get("all_images_byte_identical") is True and
                 proof.get("no_frame_filtering") is True and proof.get("models") == equivalence["models"] and
                 set(equivalence["models"]) == set(report["model_sha256"]) and
                 all(row.get("byte_identical") is True and row.get("current_sha256") ==
                     row.get("old_benchmark_sha256") == report["model_sha256"][name]
                     for name, row in equivalence["models"].items()), "s01 adapter-equivalence proof changed")
    return {"profile": PROFILE, "capture_manifest_sha256": CAPTURE_MANIFEST_SHA256,
            "admission_sha256": ADMISSION_SHA256, "adapter_report_sha256": ADAPTER_REPORT_SHA256,
            "source_files_sha256": hashes, "dataset_inventory_sha256": benchmark.fingerprint(files),
            "training_images": training, "evaluation_images": evaluation,
            "image_sha256": report["image_sha256"],
            "evaluation_image_sha256": {name: report["image_sha256"][name] for name in evaluation},
            "seed_image_names": training, "seed_colors_from_training_only": True,
            "seed_geometry_from_training_observations_only": True,
            "model_sha256": report["model_sha256"], "capture_quality": quality,
            "adapter_helpers": helpers, "binary_equivalence_sha256": equivalence["sha256"]}


def comparison_predecessor(source, predecessors):
    marker_path = PRIVATE_ROOT / S01_MARKER_NAME
    entry = next((row for row in predecessors if row["marker"] == str(marker_path)), None)
    room.require(entry is not None, "completed s01 must remain in the shared ledger")
    marker = bounded_json(marker_path)
    room.require(room.sha(marker_path) == entry["marker_sha256"], "s01 marker changed")
    state = private_path(Path(marker["state"]))
    receipt_path = state / "provider-receipt.json"
    receipt = bounded_json(receipt_path)
    room.require(room.sha(receipt_path) == entry["receipt_sha256"] == S01_RECEIPT_SHA256,
                 "s01 provider receipt changed")
    ablation.require_cleanup_reconciled(receipt_path, receipt)
    plan_path = private_path(Path(marker["plan_path"]))
    prior = bounded_json(plan_path)
    room.require(room.sha(plan_path) == marker.get("plan_sha256") == S01_PLAN_SHA256,
                 "s01 frozen plan changed")
    room.require(prior.get("label") == "s01" and prior.get("stage") == "s" and
                 prior.get("profile") == benchmark.PROFILE and receipt.get("outcome") == "trained",
                 "comparison predecessor is not completed s01")
    # New controller files may be added; the trainer/setup/room lifecycle and
    # original benchmark must remain byte-identical to the s01 experiment.
    old_files = prior.get("source", {}).get("files", {})
    room.require(old_files and all(source["files"].get(name) == digest for name, digest in old_files.items()) and
                 all(old_files.get(name) == digest for name, digest in receipt.get("source", {}).get("files", {}).items()),
                 "s01 training or lifecycle source changed")
    prior_dataset = private_path(benchmark.DATASET)
    old_inventory = room.inventory(prior_dataset)
    room.require(prior.get("dataset") == str(prior_dataset) and receipt.get("dataset_files") == old_inventory and
                 prior.get("cohort") == benchmark.cohort(prior_dataset, old_inventory, source),
                 "s01 dataset or fixed 350/50 cohort changed")
    baseline_hash = room.sha(ablation.BASELINE_RUN)
    room.require(prior.get("dependency_baseline_sha256") == baseline_hash ==
                 receipt.get("dependency_baseline_sha256"), "s01 dependency baseline changed")
    room.require(all(prior.get(key) == value for key, value in RECIPE.items() if key != "world_normalization") and
                 receipt.get("pose_optimization") is True and receipt.get("policy") == room.policy(),
                 "s01 recipe or provider limits changed")
    run_path = benchmark.collected_artifact(state, receipt, "result/run.json")
    run = bounded_json(run_path)
    room.require(run.get("status") == "trained" and run.get("frames") == 400 and
                 run.get("max_steps") == 30000 and run.get("max_seconds") == 4200 and
                 run.get("max_gaussians") == 500000 and run.get("pose_optimization") is True and
                 run.get("world_normalization") is False and
                 run.get("resolved_dependencies") == bounded_json(ablation.BASELINE_RUN).get("resolved_dependencies"),
                 "s01 run or resolved dependency receipt is incomplete")
    metrics_path = benchmark.collected_artifact(state, receipt, "result/stats/val_step29999.json")
    metrics = bounded_json(metrics_path)
    room.require(all(type(metrics.get(key)) in (int, float) and math.isfinite(metrics[key])
                     for key in ("psnr", "ssim", "lpips")), "s01 metrics must be finite")
    renders = [f"result/renders/val_step29999_{i:04d}.png" for i in range(50)]
    recorded = [row.get("path") for row in receipt.get("artifacts", [])
                if str(row.get("path", "")).startswith("result/renders/val_step29999_")]
    room.require(sorted(recorded) == renders, "s01 requires all 50 collected evaluation renders")
    for relative in renders:
        benchmark.collected_artifact(state, receipt, relative)
    return {"marker": str(marker_path), "marker_sha256": room.sha(marker_path),
            "plan_sha256": room.sha(plan_path), "receipt_sha256": room.sha(receipt_path),
            "run_sha256": room.sha(run_path), "metrics_sha256": room.sha(metrics_path),
            "dependency_baseline_sha256": baseline_hash,
            "cohort_sha256": benchmark.fingerprint(prior["cohort"]),
            "evaluation_images": prior["cohort"]["evaluation_images"],
            "metrics": {key: metrics[key] for key in ("psnr", "ssim", "lpips")},
            "same_evaluation_cohort": False, "direct_metric_comparison_valid": False}


def prepare(dataset=DATASET, label="r01"):
    room.require(label == "r01", "only the single reviewed r01 capture attempt is configured")
    require_september_window()
    dataset = private_path(dataset)
    source = source_binding()
    files = room.inventory(dataset)
    binding = cohort(dataset, files)
    # Do not replace, filter, or reset the original shared ledger.
    held, reserve, predecessors, _ = benchmark.ledger()
    room.require(reserve >= Decimal(room.policy()["compute_upper_bound_usd"]), "full-lifetime reserve required")
    room.require(held + reserve <= Decimal("25.00"), "attempt exceeds the shared $25 authorization")
    return {"schema_version": 1, "profile": PROFILE, "label": label,
            "app_name": "rendprop-capture2-r01-20260930", "dataset": str(dataset),
            "cohort": binding, "source": source, "policy": room.policy(),
            "dependency_baseline_sha256": room.sha(ablation.BASELINE_RUN),
            "cost_baseline_sha256": room.sha(ablation.COST_BASELINE),
            "prior_costs_and_holds_usd": str(held), "reserved_usd": str(reserve), "ceiling_usd": "25.00",
            "predecessors": predecessors, "comparison_predecessor": comparison_predecessor(source, predecessors),
            **RECIPE, "experimental_variable": "new capture, including its poses and training-only initialization",
            "evaluation": "46 original-index every-eighth loss-heldout views; all 361 originals retained; "
                          "315 training views alone supply seed colors and geometry; ARKit VIO poses are not "
                          "independent ground truth; scores are not directly comparable to s01's 50 old-room views"}


def fresh_output_path(path):
    path = private_path(path, must_exist=False)
    room.require(not path.exists() and path.parent.is_dir(), "fresh private output path required")
    room.require(not path.is_relative_to(DATASET.resolve()) and
                 not path.is_relative_to(CAPTURE_ROOT.resolve()), "outputs cannot modify frozen capture or dataset")
    return path


def execute(modal, plan_path, state):
    require_september_window()
    room.require(modal.__version__ == "1.5.3", "use pinned Modal SDK 1.5.3")
    plan_path = private_path(plan_path)
    plan = bounded_json(plan_path)
    marker = PRIVATE_ROOT / MARKER_NAME
    room.require(not marker.exists(), "r01 was already reserved; no automatic retry")
    room.require(plan == prepare(Path(plan["dataset"]), plan["label"]),
                 "plan data, admission, source, predecessor or costs changed")
    state = fresh_output_path(state)
    _, _, _, inventory = benchmark.ledger()
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
    room.require(isinstance(app.app_id, str) and app.app_id.startswith("ap-"), "invalid capture2 app identity")
    room.require(not list(modal.Sandbox.list(app_id=app.app_id)), "capture2 namespace has active resources")
    require_september_window()  # Recheck after all provider lookups, before the durable rental hold.
    room.save(marker, {"state": str(state), "reserved_usd": plan["reserved_usd"], "app_id": app.app_id,
                       "plan_path": str(plan_path), "plan_sha256": room.sha(plan_path),
                       "utc": datetime.now(timezone.utc).isoformat(), "automatic_retries": 0})
    room.run(modal, Path(plan["dataset"]), state, app_name=plan["app_name"],
             pose_opt=True, dependency_baseline=ablation.BASELINE_RUN, max_steps=30000, max_seconds=4200)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run"))
    parser.add_argument("--dataset", type=Path, default=DATASET)
    parser.add_argument("--label", default="r01")
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--confirm-one-allocation", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "plan":
        path = fresh_output_path(args.plan)
        room.save(path, prepare(args.dataset, args.label))
        print("PASS: capture2 preregistered plan saved; no provider calls")
        return
    room.require(args.state is not None and args.confirm_one_allocation,
                 "explicit one-allocation confirmation and state required")
    with (PRIVATE_ROOT / "room-approval-20260910.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ["MODAL_PROFILE"] = room.PROFILE
        import modal
        execute(modal, args.plan, args.state)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise InterruptedError(f"capture2 interrupted by signal {signum}")
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {type(exc).__name__}; inspect private receipts; no automatic retry", file=sys.stderr)
        sys.exit(1)
