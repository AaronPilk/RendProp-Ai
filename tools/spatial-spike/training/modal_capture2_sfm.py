#!/usr/bin/env python3
"""One reviewed capture2 SfM comparison; never an automatic retry of r01.

The original room helper stays unchanged. Scoped overrides lower its actual
sandbox TTL as well as its reservation, and add bounded post-training diagnostics.
Unfilled evidence constants fail before a provider call.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from decimal import Decimal
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import zipfile

import modal_capture2 as capture2
import modal_capture_benchmark as benchmark
import modal_ablation as ablation
import modal_room as room
import refine_sfm as sfm
from modal_retry import bounded_json, private_path

PRIVATE_ROOT = Path.home() / "LocalSpatialExperiments"
BASE = PRIVATE_ROOT / "capture2-20260930"
DATASET = BASE / "sfm-training-candidate/dataset"
ADMISSION = BASE / "sfm-training-candidate/candidate-admission.json"
EVALUATION_POSES = BASE / "sfm-training-candidate/localized-evaluation-poses.json"
ADMISSION_SHA256 = None  # Root binds independently reviewed finalized evidence.
EVALUATION_POSES_SHA256 = None
DIAGNOSTICS_SHA256 = None
DIAGNOSTIC_OUTPUTS = (
    "summary.json", "optimized-training-poses.json", "resolved-config.json",
    "r01-original-stats.json", "r01-localized-stats.json", "r02-localized-stats.json",
    "r01-original-worst-psnr.png", "r01-original-worst-ssim.png", "r01-original-worst-lpips.png",
    *(f"r01-localized-{i:04d}.png" for i in range(46)),
    *(f"r02-localized-{i:04d}.png" for i in range(46)),
    *(f"r02-training-{i:04d}.png" for i in range(8)),
)
PROFILE = "capture2-sfm-r02-20260930-v1"
MARKER_NAME = "spatial-ablation-20260914-capture2-20260930-r02.allocation.json"
R01_MARKER = PRIVATE_ROOT / capture2.MARKER_NAME
R01_PLAN_SHA256 = "d9141d4d065afa42ffe6a927b5cf01990d63a3f6d3f51a3e69f6348e30b6152a"
R01_PROVIDER_SHA256 = "72e711af9f04fc67652e5aca95e5a58fd0d572eb73e3558459bba878599cfcab"
R01_SOURCE_COMMIT = "11ebf0a3f60fa74521ae656c2f5116a6b02e2e2a"
BASELINE_RENDERS = BASE / "r01/reference-renders.zip"
BASELINE_RENDERS_SHA256 = "36d3e36c185cf0495a5448fd2ee38b4798c3208c9668e5d112793666eaa5c6ae"
TTL_SECONDS = 3900
TRAINING_SECONDS = 3000
DIAGNOSTIC_SECONDS = 300
MAX_COMBINED_DOWNLOAD = 768 * 1024**2
BILLING_WINDOW_END = datetime(2026, 10, 1, tzinfo=timezone.utc)
CREATION_MARGIN_SECONDS = 300
ORIGINAL_POLICY = room.policy
ORIGINAL_CREATE_OPTIONS = room.create_options
ORIGINAL_COLLECT = room.collect
EXTRA_SOURCE_NAMES = ("modal_capture2_sfm.py", "modal_capture2_sfm_diagnostics.py")


def policy():
    value = ORIGINAL_POLICY()
    room.require(value["timeout_seconds"] == 7200 and value["gpu"] == "L4" and
                 value["cpu_request_and_limit"] == 4 and
                 value["memory_request_and_limit_mib"] == 32768 and value["region"] == "us",
                 "original reviewed provider limits changed")
    per_second = Decimal("0.000682088")
    room.require(Decimal(value["compute_upper_bound_usd"]) == per_second * 7200,
                 "original reviewed provider rates changed")
    return {**value, "timeout_seconds": TTL_SECONDS,
            "compute_upper_bound_usd": str(per_second * TTL_SECONDS)}


def require_billing_window():
    room.require(datetime.now(timezone.utc) + timedelta(seconds=TTL_SECONDS + CREATION_MARGIN_SECONDS)
                 < BILLING_WINDOW_END, "September billing window cannot cover full r02 lifetime")


def create_options(modal, app, receipt):
    options = ORIGINAL_CREATE_OPTIONS(modal, app, receipt)
    room.require(options["timeout"] == 7200 and options["cpu"] == (4.0, 4.0) and
                 options["memory"] == (32768, 32768), "original creation limits changed")
    return {**options, "timeout": TTL_SECONDS}


@contextmanager
def policy_scope():
    previous = room.policy
    room.require(previous is ORIGINAL_POLICY, "overlapping policy override")
    room.policy = policy
    try:
        yield
    finally:
        room.policy = previous


def source_binding():
    result = capture2.source_binding()
    root = Path(__file__).resolve().parent
    for name in EXTRA_SOURCE_NAMES:
        path = root / name
        room.require(path.is_file() and not path.is_symlink(), "missing reviewed SfM controller helper")
        committed = subprocess.check_output(["git", "-C", str(root.parents[2]), "show",
            f"{result['commit']}:tools/spatial-spike/training/{name}"])
        digest = hashlib.sha256(committed).hexdigest()
        room.require(room.sha(path) == digest, "SfM helper differs from clean committed source")
        result["files"][name] = digest
    return result


def shared_ledger():
    with policy_scope():
        value = benchmark.ledger()
    # Lowering the new profile must never weaken any older allocation's hold.
    old_minimum = Decimal(ORIGINAL_POLICY()["compute_upper_bound_usd"])
    for item in value[2]:
        path = Path(item["marker"])
        marker = bounded_json(private_path(path))
        minimum = Decimal(policy()["compute_upper_bound_usd"]) if path == PRIVATE_ROOT / MARKER_NAME else old_minimum
        room.require(benchmark.money(marker.get("reserved_usd")) >= minimum,
                     "older allocation lost its original full-lifetime reservation")
    return value


def require_digest(value, label):
    room.require(isinstance(value, str) and re.fullmatch("[a-f0-9]{64}", value),
                 f"root has not bound finalized {label}")


def r01_binding(source):
    marker = bounded_json(private_path(R01_MARKER))
    state = private_path(Path(marker["state"]))
    plan_path = private_path(Path(marker["plan_path"]))
    provider_path = state / "provider-receipt.json"
    bill_path = state / "billing-readback.json"
    room.require(room.sha(plan_path) == marker["plan_sha256"] == R01_PLAN_SHA256 and
                 room.sha(provider_path) == R01_PROVIDER_SHA256, "r01 frozen evidence changed")
    plan, provider = bounded_json(plan_path), bounded_json(provider_path)
    # Closed billing is mandatory; neither elapsed cost nor an estimated bill can release r01's hold.
    room.require(bill_path.is_file() and not bill_path.is_symlink(), "r01 final billing is not reconciled")
    bill = bounded_json(bill_path)
    room.require(bill.get("closed_hourly_intervals") is True and bill.get("currency") == "USD" and
                 bill.get("provider_receipt_sha256") == R01_PROVIDER_SHA256 and
                 bill.get("allocation_marker_sha256") == room.sha(R01_MARKER) and
                 bill.get("app_id") == provider.get("app_id") == marker.get("app_id") and
                 bill.get("sandbox_id") == provider.get("sandbox_id"), "r01 final bill attribution changed")
    actual = benchmark.money(bill.get("actual_metered_usd"))
    room.require(actual <= benchmark.money(marker["reserved_usd"]), "r01 bill exceeds its reserved lifetime")
    ablation.require_cleanup_reconciled(provider_path, provider)
    room.require(provider.get("outcome") == "trained" and provider.get("policy") == ORIGINAL_POLICY() and
                 plan.get("source", {}).get("commit") == provider.get("source", {}).get("commit") == R01_SOURCE_COMMIT,
                 "r01 comparison does not use its original 7200-second policy/source")
    room.require(all(source["files"].get(name) == digest for name, digest in plan["source"]["files"].items()),
                 "r01 trainer, dependency setup or controller source changed")
    room.require(plan["dependency_baseline_sha256"] == provider["dependency_baseline_sha256"] ==
                 room.sha(ablation.BASELINE_RUN), "r01 dependency baseline changed")
    original_files = room.inventory(capture2.DATASET)
    room.require(original_files == provider["dataset_files"] and
                 plan["cohort"] == capture2.cohort(private_path(capture2.DATASET), original_files),
                 "r01 original admitted capture changed")
    run_path = benchmark.collected_artifact(state, provider, "result/run.json")
    run = bounded_json(run_path)
    room.require(run.get("status") == "trained" and run.get("max_steps") == 30000 and
                 run.get("max_seconds") == 4200 and run.get("max_gaussians") == 500000 and
                 run.get("pose_optimization") is True and run.get("world_normalization") is False and
                 run.get("frames") == 361, "r01 training recipe changed")
    ply = benchmark.collected_artifact(state, provider, "result/ply/point_cloud_29999.ply")
    metrics = benchmark.collected_artifact(state, provider, "result/stats/val_step29999.json")
    for index in range(46):
        benchmark.collected_artifact(state, provider, f"result/renders/val_step29999_{index:04d}.png")
    reference_archive = private_path(BASELINE_RENDERS)
    room.require(reference_archive.stat().st_size <= 256 * 1024**2 and
                 room.sha(reference_archive) == BASELINE_RENDERS_SHA256, "reviewed r01 reference archive changed")
    references = {Path(row["path"]).name: row for row in provider["artifacts"]
                  if row["path"].startswith("result/renders/val_step29999_")}
    with zipfile.ZipFile(reference_archive) as archive:
        entries = archive.infolist()
        room.require(len(entries) == 46 and {info.filename for info in entries} == set(references),
                     "reference archive does not contain exact46 baseline renders")
        for info in entries:
            recorded = references[info.filename]
            room.require(info.compress_type == zipfile.ZIP_STORED and info.file_size == recorded["bytes"] and
                         hashlib.sha256(archive.read(info)).hexdigest() == recorded["sha256"],
                         "reference archive image differs from r01 collected artifact")
    return {"marker_sha256": room.sha(R01_MARKER), "plan_sha256": room.sha(plan_path),
            "provider_receipt_sha256": room.sha(provider_path), "billing_sha256": room.sha(bill_path),
            "actual_metered_usd": str(actual), "baseline_ply": {"path": str(ply), "sha256": room.sha(ply)},
            "metrics_sha256": room.sha(metrics), "metrics": bounded_json(metrics),
            "baseline_renders": {"path": str(reference_archive), "sha256": BASELINE_RENDERS_SHA256},
            "cohort": plan["cohort"], "source": plan["source"]}


def candidate_binding(dataset, files, prior):
    for value, label in ((ADMISSION_SHA256, "SfM admission"),
                         (EVALUATION_POSES_SHA256, "SfM evaluation poses"),
                         (DIAGNOSTICS_SHA256, "diagnostic helper")):
        require_digest(value, label)
    room.require(dataset == private_path(DATASET), "only reviewed r02 candidate is configured")
    admission_path = private_path(ADMISSION)
    room.require(room.sha(admission_path) == ADMISSION_SHA256, "SfM admission changed")
    admission = bounded_json(admission_path)
    # Root binds ADMISSION_SHA256 only after independent review; a caller cannot self-assert review.
    room.require(admission.get("format") == "rendprop-sfm-training-candidate" and
                 admission.get("schema_version") == 1 and admission.get("status") == "passed" and
                 admission.get("production_accepted") is False and
                 admission.get("source_admission") == {"path": str(capture2.ADMISSION),
                                                        "sha256": capture2.ADMISSION_SHA256} and
                 admission.get("dataset") == str(dataset) and
                 admission.get("dataset_files_sha256") == {row["path"]: row["sha256"] for row in files},
                 "SfM admission lacks reviewed original-r01/candidate binding")
    report = bounded_json(dataset / "adapter-report.json")
    old = prior["cohort"]
    train, evaluation = old["training_images"], old["evaluation_images"]
    train_ids, evaluation_ids = [int(name[:6]) for name in train], [int(name[:6]) for name in evaluation]
    room.require(len(train) == 315 and len(evaluation) == 46 and
                 report.get("frames") == 361 and report.get("training_images") == train and
                 report.get("evaluation_images") == evaluation and
                 report.get("image_sha256") == old["image_sha256"], "SfM dropped, changed or reindexed original views")
    room.require(report.get("seed_image_names") == train and
                 report.get("seed_colors_from_training_only") is True and
                 report.get("seed_geometry_from_training_observations_only") is True and
                 admission.get("training_ids") == train_ids and admission.get("evaluation_ids") == evaluation_ids,
                 "SfM training/evaluation isolation changed")
    proof = admission.get("train_only_proof", {})
    secondary = admission.get("evaluation_secondary", {})
    room.require(proof.get("cache_image_ids") == proof.get("registered_model_ids") == train_ids and
                 proof.get("point_track_image_ids") == train_ids and
                 proof.get("heldout_pixels_used_for_training_geometry_or_colors") is False and
                 proof.get("all_image_model_used") is False and proof.get("fixed_original_K") is True and
                 proof.get("pose_priors") == 0 and proof.get("one_complete_component") is True and
                 admission.get("alignment", {}).get("training_ids") == train_ids and
                 admission.get("frozen_model_sha256_before") == admission.get("frozen_model_sha256_after") and
                 isinstance(admission.get("frozen_model_sha256_before"), dict) and
                 bool(admission["frozen_model_sha256_before"]) and
                 admission.get("evaluation_primary") == "original_arkit" and
                 admission.get("evaluation_primary_records_byte_identical") is True and
                 secondary.get("all_46_pnp_passed") is True and secondary.get("minimum_inliers", 0) >= 20 and
                 secondary.get("paired_baselines_required") == ["r01", "r02"] and
                 secondary.get("baseline_ply_roundtrip_render_validation_required") is True and
                 secondary.get("primary_series_replacement_allowed") is False,
                 "SfM model, alignment or heldout localization proof changed")
    original_files = {row["path"]: row["sha256"] for row in room.inventory(capture2.DATASET)}
    room.require(admission.get("original_dataset_sha256") == original_files and
                 report["model_sha256"]["cameras.bin"] == old["model_sha256"]["cameras.bin"],
                 "SfM original dataset or fixed camera intrinsics changed")
    records = sfm.image_records(dataset / "sparse/0/images.bin")
    original_records = sfm.image_records(capture2.DATASET / "sparse/0/images.bin")
    room.require(set(records) == set(range(1, 362)) and all(row[0] == f"{i:06d}.jpg" for i, row in records.items()),
                 "SfM original image IDs changed")
    room.require(all(records[i] == original_records[i] and records[i][2] == 0 for i in evaluation_ids),
                 "primary heldout camera/observations changed")
    points, _ = ablation.validate_point_tracks(dataset / "sparse/0/points3D.bin", records,
                                              {int(name[:6]) for name in train})
    room.require(points == report["initial_points"], "SfM point count differs from admitted model")
    proof_files = dict(admission.get("scripts_sha256", {}))
    room.require(proof_files, "missing independent SfM source evidence")
    for evidence in (admission.get("plan", {}), admission.get("results", {}), proof.get("cache_inventory", {})):
        path = private_path(Path(evidence["path"]))
        proof_files[str(path)] = evidence["sha256"]
    for name, digest in admission["frozen_model_sha256_before"].items():
        room.require(name in ("cameras.bin", "images.bin", "points3D.bin", "rigs.bin", "frames.bin"),
                     "unexpected frozen SfM model file")
        path = private_path(DATASET.parent / "frozen-training-model" / name)
        proof_files[str(path)] = digest
    for name, digest in proof_files.items():
        path = Path(name)
        require_digest(digest, "SfM proof digest")
        room.require(path.is_absolute() and path.is_file() and not path.is_symlink() and room.sha(path) == digest,
                     "independent SfM evidence changed")
    poses = private_path(EVALUATION_POSES)
    room.require(room.sha(poses) == EVALUATION_POSES_SHA256 and
                 secondary.get("pose_sidecar") == {"path": str(poses), "sha256": EVALUATION_POSES_SHA256},
                 "SfM diagnostic evaluation poses changed")
    pose_data = bounded_json(poses)
    room.require(pose_data.get("evaluation_images") == evaluation and pose_data.get("training_ids") == train_ids and
                 pose_data.get("evaluation_ids") == evaluation_ids and pose_data.get("geometry_frozen") is True and
                 len(pose_data.get("poses", [])) == 46 and
                 [row.get("image_id") for row in pose_data["poses"]] == evaluation_ids and
                 all(row.get("status") == "passed" and row.get("recomputed_final_inliers", 0) >= 20
                     for row in pose_data["poses"]), "SfM evaluation pose sidecar incomplete")
    return {"admission_sha256": ADMISSION_SHA256, "files": files,
            "evaluation_poses": {"path": str(poses), "sha256": EVALUATION_POSES_SHA256},
            "training_images": train, "evaluation_images": evaluation,
            "evidence_files_sha256": proof_files, "model_sha256": report["model_sha256"]}


def diagnostic_binding(source, prior, candidate):
    room.require(source["files"].get("modal_capture2_sfm_diagnostics.py") == DIAGNOSTICS_SHA256,
                 "diagnostic helper is not the reviewed committed bytes")
    room.require(isinstance(DIAGNOSTIC_OUTPUTS, tuple) and DIAGNOSTIC_OUTPUTS and
                 len(DIAGNOSTIC_OUTPUTS) == len(set(DIAGNOSTIC_OUTPUTS)) and
                 all(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_-]+\.(?:json|png)", name)
                     for name in DIAGNOSTIC_OUTPUTS), "root has not bound exact diagnostic output whitelist")
    helper = Path(__file__).resolve().with_name("modal_capture2_sfm_diagnostics.py")
    return {"helper": {"path": str(helper), "sha256": DIAGNOSTICS_SHA256},
            "baseline_ply": prior["baseline_ply"], "evaluation_poses": candidate["evaluation_poses"],
            "baseline_renders": prior["baseline_renders"],
            "baseline_metrics_sha256": prior["metrics_sha256"], "baseline_metrics": prior["metrics"],
            "timeout_seconds": DIAGNOSTIC_SECONDS, "output_files": list(DIAGNOSTIC_OUTPUTS),
            "combined_download_limit_bytes": MAX_COMBINED_DOWNLOAD}


def prepare():
    require_billing_window()
    source = source_binding()
    prior = r01_binding(source)  # Original policy remains in force for the comparison.
    dataset = private_path(DATASET)
    files = room.inventory(dataset)
    candidate = candidate_binding(dataset, files, prior)
    diagnostics = diagnostic_binding(source, prior, candidate)
    spent, reserve, predecessors, _ = shared_ledger()
    room.require(reserve == Decimal("2.660143200") and spent + reserve <= Decimal("25.00"),
                 "r02 full lifetime exceeds shared $25 authority")
    room.require(any(row["marker"] == str(R01_MARKER) and row["billing_sha256"] == prior["billing_sha256"]
                     for row in predecessors), "r01 closed bill is absent from shared ledger")
    return {"schema_version": 1, "profile": PROFILE, "label": "r02",
            "app_name": "rendprop-capture2-sfm-r02-20260930", "dataset": str(dataset), "source": source,
            "comparison_predecessor": prior, "candidate": candidate, "diagnostics": diagnostics,
            "policy": policy(), "prior_costs_and_holds_usd": str(spent), "reserved_usd": str(reserve),
            "ceiling_usd": "25.00", "predecessors": predecessors,
            "dependency_baseline_sha256": room.sha(ablation.BASELINE_RUN),
            "pose_optimization": True, "steps": 30000, "max_training_seconds": TRAINING_SECONDS,
            "max_gaussians": 500000, "world_normalization": False, "fixed_eval_every": 8,
            "random_seed": 42, "automatic_retries": 0,
            "experimental_variable": "training-only SfM poses/seeds; heldout PnP localization against fixed training model",
            "evaluation_caveat": "Primary evaluation retains original ARKit poses; secondary paired rerenders use common finalized PnP poses"}


def collect_with_diagnostics(sb, target, max_steps, plan):
    room.require(max_steps == 30000, "unexpected final training step")
    spec = plan["diagnostics"]
    # Preserve the completed reconstruction before optional diagnostic validation.
    artifacts = ORIGINAL_COLLECT(sb, target, max_steps=max_steps)
    room.require(len(artifacts) == 52, "original heldout collection is not the expected 52 artifacts")
    primary_receipt = target.parent / "primary-artifact-receipt.json"
    room.require(not primary_receipt.exists() and not primary_receipt.is_symlink(),
                 "refusing to replace preserved primary artifact receipt")
    room.save(primary_receipt, {
        "schema_version": 1, "status": "primary_artifacts_preserved", "acceptance": "not_accepted",
        "observed_utc": datetime.now(timezone.utc).isoformat(), "max_steps": max_steps,
        "plan_fingerprint": benchmark.fingerprint(plan), "artifacts": artifacts,
        "dataset": {"path": plan.get("dataset"),
                    "admission_sha256": plan.get("candidate", {}).get("admission_sha256"),
                    "files": plan.get("candidate", {}).get("files")},
        "original_capture_admission_sha256": capture2.ADMISSION_SHA256,
        "comparison_predecessor_provider_sha256": plan.get("comparison_predecessor", {}).get("provider_receipt_sha256"),
        "provider_receipt_modified": False, "automatic_retry": False,
    })
    # No network policy is widened: room.run denied egress before any room media arrived.
    remote = room.REMOTE
    sb.filesystem.make_directory(f"{remote}/diagnostic-inputs")
    transfers = (("helper", f"{remote}/post-training-diagnostics.py"),
                 ("baseline_ply", f"{remote}/diagnostic-inputs/r01.ply"),
                 ("baseline_renders", f"{remote}/diagnostic-inputs/r01-renders.zip"),
                 ("evaluation_poses", f"{remote}/diagnostic-inputs/evaluation-poses.json"))
    for key, destination in transfers:
        item = spec[key]
        path = Path(item["path"])
        room.require(path.is_file() and not path.is_symlink() and room.sha(path) == item["sha256"],
                     "diagnostic input changed before transfer")
        sb.filesystem.copy_from_local(path, destination)
    command = ["/opt/conda/bin/python", f"{remote}/post-training-diagnostics.py",
               "--baseline-ply", f"{remote}/diagnostic-inputs/r01.ply",
               "--baseline-renders", f"{remote}/diagnostic-inputs/r01-renders.zip",
               "--candidate-ply", f"{remote}/result/ply/point_cloud_29999.ply",
               "--dataset", f"{remote}/dataset",
               "--evaluation-poses", f"{remote}/diagnostic-inputs/evaluation-poses.json",
               "--output", f"{remote}/diagnostics"]
    stage = {}
    status_path = target.parent / "diagnostics-status.json"
    stage_failure = None
    try:
        room.exec_to_log(sb, command, DIAGNOSTIC_SECONDS, target.parent / "post-training-diagnostics.log",
                         stage=stage, persist=lambda: room.save(status_path, {
                             "status": "running", "acceptance": "not_accepted", "stage": stage}))
    except (room.StageFailure, TimeoutError) as exc:
        stage_failure = type(exc).__name__
    found = []
    try:
        for item in sb.filesystem.list_files(f"{remote}/diagnostics"):
            name = Path(item.name).name
            room.require(item.name in (name, f"{remote}/diagnostics/{name}"), "unsafe diagnostic output path")
            found.append(name)
    except Exception as exc:
        stage_failure = stage_failure or type(exc).__name__
    expected = set(spec["output_files"])
    missing, extra = sorted(expected - set(found)), sorted(set(found) - expected)
    sizes = {}
    for name in sorted(expected & set(found)):
        size = sb.filesystem.stat(f"{remote}/diagnostics/{name}").size
        room.require(type(size) is int and 0 < size <= MAX_COMBINED_DOWNLOAD, "invalid diagnostic artifact size")
        sizes[name] = size
    room.require(sum(row["bytes"] for row in artifacts) + sum(sizes.values())
                 <= MAX_COMBINED_DOWNLOAD, "combined artifact collection exceeds reviewed count/limit")
    for name, size in sizes.items():
        relative = f"diagnostics/{name}"
        path = target / relative
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        room.require(not path.exists(), "refusing to replace diagnostic artifact")
        sb.filesystem.copy_to_local(f"{remote}/{relative}", path)
        os.chmod(path, 0o600)
        room.require(path.stat().st_size == size, "diagnostic artifact size changed")
        artifacts.append({"path": relative, "bytes": size, "sha256": room.sha(path)})
    complete = not stage_failure and stage.get("exit_code") == 0 and not missing and not extra and len(found) == len(expected)
    room.save(status_path, {"status": "collected" if complete else "failed", "acceptance": "not_accepted",
                           "stage": stage, "failure_type": stage_failure, "missing_files": missing,
                           "unexpected_files": extra, "original_artifacts_preserved": 52,
                           "diagnostic_artifacts_preserved": len(sizes), "automatic_retry": False})
    return artifacts


@contextmanager
def dispatch_scope(plan):
    room.require(room.create_options is ORIGINAL_CREATE_OPTIONS and room.collect is ORIGINAL_COLLECT,
                 "overlapping room dispatch override")
    with policy_scope():
        room.create_options = create_options
        room.collect = lambda sb, target, max_steps=30000: collect_with_diagnostics(sb, target, max_steps, plan)
        try:
            yield
        finally:
            room.create_options = ORIGINAL_CREATE_OPTIONS
            room.collect = ORIGINAL_COLLECT


def fresh_path(path):
    path = private_path(path, must_exist=False)
    room.require(not path.exists() and path.parent.is_dir() and
                 not path.is_relative_to(DATASET.resolve()) and
                 not path.is_relative_to(capture2.CAPTURE_ROOT.resolve()) and
                 not path.is_relative_to(capture2.DATASET.resolve()), "fresh private output path required")
    return path


def execute(modal, plan_path, state):
    require_billing_window()
    room.require(modal.__version__ == "1.5.3", "pinned Modal1.5.3 required")
    marker = PRIVATE_ROOT / MARKER_NAME
    room.require(not marker.exists(), "r02 already reserved; no automatic retry")
    plan_path = private_path(plan_path)
    plan = bounded_json(plan_path)
    room.require(plan == prepare(), "r02 plan source, data, predecessor or budget changed")
    state = fresh_path(state)
    _, _, _, inventory = shared_ledger()
    for app_id in sorted(set(inventory["active_by_app"]) | {p["app_id"] for p in plan["predecessors"]}):
        room.require(not list(modal.Sandbox.list(app_id=app_id)), "prior spatial sandbox still active")
    for sandbox_id in sorted(set(inventory["exact_sandbox_terminal_polls"]) | {p["sandbox_id"] for p in plan["predecessors"]}):
        previous = modal.Sandbox.from_id(sandbox_id)
        try:
            room.require(previous.poll() is not None, "prior spatial allocation not terminal")
        finally:
            previous.detach()
    app = modal.App.lookup(plan["app_name"], environment_name="main", create_if_missing=True)
    room.require(isinstance(app.app_id, str) and app.app_id.startswith("ap-"), "invalid r02 app identity")
    room.require(not list(modal.Sandbox.list(app_id=app.app_id)), "r02 namespace has active resources")
    require_billing_window()
    room.save(marker, {"state": str(state), "reserved_usd": plan["reserved_usd"], "app_id": app.app_id,
                       "plan_path": str(plan_path), "plan_sha256": room.sha(plan_path),
                       "utc": datetime.now(timezone.utc).isoformat(), "automatic_retries": 0})
    with dispatch_scope(plan):
        # Original room.run keeps its single creation attempt and cleanup/terminate finally.
        room.run(modal, Path(plan["dataset"]), state, app_name=plan["app_name"], pose_opt=True,
                 dependency_baseline=ablation.BASELINE_RUN, max_steps=30000, max_seconds=TRAINING_SECONDS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run"))
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--confirm-one-allocation", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "plan":
        path = fresh_path(args.plan)
        room.save(path, prepare())
        print("PASS: reviewed r02 plan saved; no provider call")
        return
    room.require(args.state is not None and args.confirm_one_allocation, "explicit one-allocation confirmation required")
    with (PRIVATE_ROOT / "room-approval-20260910.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ["MODAL_PROFILE"] = room.PROFILE
        import modal
        execute(modal, args.plan, args.state)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise InterruptedError(f"r02 interrupted by signal {signum}")
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {type(exc).__name__}; inspect private receipts; no automatic retry", file=sys.stderr)
        sys.exit(1)
