#!/usr/bin/env python3
"""Explicit September 14 ablations, sharing the original $25 approval lock.

One invocation can allocate only once. Old reservations are never reset. Each
attempt has its own billing app; unresolved costs retain their full-lifetime
hold. This is a manual experiment harness, not an automatic retry policy.
"""
import argparse
from contextlib import closing
from datetime import datetime, timezone
from decimal import Decimal
import fcntl
import hashlib
from itertools import zip_longest
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
import refine_sfm_incremental as sfm_incremental

PRIVATE_ROOT = Path.home() / "LocalSpatialExperiments"
COST_BASELINE = PRIVATE_ROOT / "spatial-ablation-20260914-cost-baseline.json"
BASELINE_RUN = PRIVATE_ROOT / "modal-room-20260911-01/download/result/run.json"
ORIGINAL_DATASET = PRIVATE_ROOT / "capture-20260911.liWf0i/dataset"
D1_DATASET = PRIVATE_ROOT / "spatial-sfm-20260914-d01/dataset"
MARKER_GLOB = "spatial-ablation-20260914-*.allocation.json"
# Canonical JSON fingerprints of the official 4.2.0 options, excluding only
# mapping image_names (checked separately against the original 133-frame split).
D2_MAPPING_OPTIONS_SHA256 = "370f512026e3d4f5a0aafe2a7089803b10debed64e4c36f0351fa10fbfc3157f"
D2_ALIGNMENT_OPTIONS_SHA256 = "8c6a840f3a0a6d999da9ebb982223b0b25602fb52b74d2d807a45d9b9f7c023e"


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


def committed_incremental_helpers(source):
    root = Path(__file__).resolve().parent
    result = {}
    for name in ("refine_sfm_incremental.py", "refine_sfm.py", "run_training.py", "prepare_capture.py"):
        committed = subprocess.check_output(["git", "-C", str(root.parents[2]), "show",
            f"{source['commit']}:tools/spatial-spike/training/{name}"])
        digest = hashlib.sha256(committed).hexdigest()
        room.require(room.sha(root / name) == digest, "D2 helper differs from committed source")
        result[name] = digest
    return result


def canonical_sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def exact_ids(value, allowed, label):
    room.require(isinstance(value, list) and all(type(i) is int and i in allowed for i in value)
                 and value == sorted(set(value)), f"invalid D2 {label} IDs")
    return set(value)


def require_same_cached_records(original, copied):
    """COLMAP may update SQLite headers; all schema and cached rows stay exact."""
    with closing(sqlite3.connect(original.as_uri() + "?mode=ro&immutable=1", uri=True)) as before, \
            closing(sqlite3.connect(copied.as_uri() + "?mode=ro&immutable=1", uri=True)) as after:
        schema = "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"
        room.require(list(before.execute(schema)) == list(after.execute(schema)),
                     "D2 requires the exact copied D01 cache schema")
        for (table,) in before.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
            room.require(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", table) is not None,
                         "unexpected D01 cache table name")
            query = f'SELECT * FROM "{table}" ORDER BY rowid'
            sentinel = object()
            room.require(all(left == right for left, right in zip_longest(
                before.execute(query), after.execute(query), fillvalue=sentinel)),
                "D2 requires the exact copied D01 cache records")


def validate_incremental_sfm_dataset(dataset, files, original, source):
    """D2 has separate provenance; the frozen D1 validator above is unchanged."""
    d1_dataset = private_path(D1_DATASET)
    d1_files = room.inventory(d1_dataset)
    d1_binding = validate_sfm_dataset(d1_dataset, d1_files, original, source)
    original_dataset = private_path(ORIGINAL_DATASET)
    before = {item["path"]: item for item in original["dataset_files"]}
    after = {item["path"]: item for item in files}
    jpegs = {name: item for name, item in before.items() if name.startswith("images/")}
    room.require({name: item for name, item in after.items() if name.startswith("images/")} == jpegs,
                 "D2 requires exact original JPEG inventory")
    room.require(after.get("sparse/0/cameras.bin") == before.get("sparse/0/cameras.bin"),
                 "D2 requires original cameras.bin")
    train, heldout = sfm.fixed_split([Path(name).name for name in jpegs])
    training_ids = {int(name[:6]) for name in train}
    originals = sfm.image_records(original_dataset / "sparse/0/images.bin")
    records = sfm.image_records(dataset / "sparse/0/images.bin")
    room.require(set(records) == set(originals) == set(range(1, 154)) and
                 all(row[0] == f"{i:06d}.jpg" for i, row in records.items()), "D2 dropped or renamed a camera")
    room.require(all(records[int(name[:6])] == originals[int(name[:6])] and records[int(name[:6])][2] == 0
                     for name in heldout), "D2 changed original heldout camera records")
    run_path, report_path = dataset.parent / "sfm-run.json", dataset.parent / "sfm-report.json"
    run, report = bounded_json(run_path), bounded_json(report_path)
    adapter = bounded_json(dataset / "adapter-report.json")
    room.require(run.get("status") == report.get("status") == "prepared" and
                 run.get("profile") == report.get("profile") == adapter.get("sfm_profile") == sfm_incremental.PROFILE,
                 "D2 requires completed exact incremental profile")
    room.require(run.get("execute") is True and type(run.get("max_seconds")) is int and
                 1 <= run["max_seconds"] <= 1800 and type(run.get("elapsed_seconds")) in (int, float) and
                 math.isfinite(run["elapsed_seconds"]) and run["elapsed_seconds"] >= 0 and
                 run.get("training_frames") == 133 and run.get("evaluation_frames") == 20,
                 "D2 requires the bounded 133/20 CPU run")
    room.require(report.get("training_images") == train and
                 report.get("evaluation_images") == run.get("evaluation_images") == adapter.get("evaluation_images") == heldout and
                 report.get("evaluation_pose_records_unchanged") is True and report.get("heldout_pixels_used_by_sfm") is False and
                 report.get("original_arkit_seeds_used") is False and report.get("gpu_used") is False and report.get("network_used") is False and
                 report.get("quality_status") == adapter.get("quality_status") == "unknown" and
                 report.get("scene_quality_accepted") is False and adapter.get("scene_quality_accepted") is False and
                 adapter.get("gpu_training_performed") is False and adapter.get("reprojection_error_measured") is True and
                 adapter.get("sfm_provenance") == "../sfm-report.json", "D2 split, seed or quality provenance changed")
    helper_hashes = committed_incremental_helpers(source)
    original_models = {Path(name).name: item["sha256"] for name, item in before.items() if name.startswith("sparse/0/")}
    room.require(report.get("source_sha256") == helper_hashes and report.get("source_model_sha256") == original_models and
                 report.get("source_adapter_report_sha256") == before["adapter-report.json"]["sha256"] and
                 report.get("source_image_sha256") == {Path(name).name: item["sha256"] for name, item in jpegs.items()},
                 "D2 original source or committed helper binding changed")
    registration, alignment = report.get("registration"), report.get("alignment")
    room.require(isinstance(registration, dict) and isinstance(alignment, dict), "D2 registration/alignment receipts missing")
    options = registration.get("options")
    room.require(isinstance(options, dict) and options == run.get("mapping_options") and options.get("image_names") == train and
                 canonical_sha({k: v for k, v in options.items() if k != "image_names"}) == D2_MAPPING_OPTIONS_SHA256 and
                 alignment.get("options") == run.get("alignment_options") and
                 canonical_sha(alignment.get("options")) == D2_ALIGNMENT_OPTIONS_SHA256,
                 "D2 frozen registration or alignment options changed")
    source_database = private_path(d1_dataset.parent / "work/features.db")
    source_cache = sfm_incremental.cache_inventory(source_database, {i: f"{i:06d}.jpg" for i in training_ids})
    copied_database = private_path(dataset.parent / "work/features.db")
    copied_cache = sfm_incremental.cache_inventory(copied_database, {i: f"{i:06d}.jpg" for i in training_ids})
    expected_cache = {**source_cache, "sfm_report_sha256": d1_binding["sfm_report_sha256"]}
    room.require({k: v for k, v in copied_cache.items() if k != "database_sha256"} ==
                 {k: v for k, v in source_cache.items() if k != "database_sha256"} and
                 report.get("cache") == run.get("cache") == expected_cache and
                 report.get("copied_database_sha256") == copied_cache["database_sha256"],
                 "D2 must use the exact copied D01 feature database and report")
    require_same_cached_records(source_database, copied_database)
    registered = exact_ids(report.get("registered_training_ids"), training_ids, "registered")
    fallback = exact_ids(report.get("original_pose_fallback_ids"), training_ids, "fallback")
    missing = exact_ids(report.get("missing_from_selected_model_ids"), training_ids, "missing")
    other = exact_ids(report.get("registered_in_other_models_ids"), training_ids, "other-model")
    unregistered = exact_ids(report.get("unregistered_training_ids"), training_ids, "unregistered")
    authorized = run.get("fallback_authorized")
    room.require(type(authorized) is bool and report.get("fallback_authorized") is authorized and
                 adapter.get("fallback_authorized") is authorized and (authorized or not fallback) and
                 registered.isdisjoint(fallback) and registered | fallback == training_ids and missing == fallback and
                 other <= fallback and unregistered == training_ids - registered - other and
                 adapter.get("registered_training_ids") == sorted(registered) and
                 adapter.get("original_pose_fallback_ids") == sorted(fallback),
                 "D2 fallback authorization or complete cohort accounting changed")
    models = registration.get("models")
    room.require(isinstance(models, list) and 1 <= len(models) <= 50 and all(isinstance(m, dict) for m in models),
                 "D2 component inventory missing")
    model_ids = [m.get("model_id") for m in models]
    room.require(all(type(i) is int and i >= 0 for i in model_ids) and model_ids == sorted(set(model_ids)),
                 "D2 component IDs invalid")
    all_registered = set()
    for model in models:
        all_registered |= exact_ids(model.get("registered_ids"), training_ids, "component")
        room.require(type(model.get("points")) is int and model["points"] > 0, "D2 component point count invalid")
    selected = min(models, key=lambda m: (-len(m["registered_ids"]), -m["points"], m["model_id"]))
    room.require(type(registration.get("selected_model_id")) is int and
                 registration["selected_model_id"] == selected["model_id"] and
                 set(selected["registered_ids"]) == registered and all_registered - registered == other,
                 "D2 selected component or dropped-camera accounting changed")
    registered_directory = private_path(dataset.parent / "work/registered-model")
    registered_hashes = {name: room.sha(private_path(registered_directory / name)) for name in sfm.MODEL_FILES}
    registered_records = sfm.image_records(registered_directory / "images.bin")
    room.require(report.get("registered_model_sha256") == registered_hashes and set(registered_records) == registered and
                 all(row[0] == f"{i:06d}.jpg" for i, row in registered_records.items()),
                 "D2 registered model differs from its receipt")
    registered_points, _ = validate_point_tracks(registered_directory / "points3D.bin", registered_records, registered)
    room.require(registered_points == selected["points"], "D2 registered point count differs from selected component")
    point_count, observations = validate_point_tracks(dataset / "sparse/0/points3D.bin", records, training_ids)
    room.require(all(records[i] == originals[i] and records[i][2] == observations[i] == 0 for i in fallback),
                 "D2 fallback must preserve original zero-track camera records")
    room.require(after["sparse/0/points3D.bin"]["sha256"] != before["sparse/0/points3D.bin"]["sha256"] and
                 point_count == report.get("final_points") == adapter.get("initial_points") and
                 sum(observations.values()) == report.get("final_observations") == adapter.get("point_observations") and
                 report.get("observations_by_training_image") == {str(i): count for i, count in observations.items()},
                 "D2 real training tracks or observation receipts changed")
    return {"variant": "D2", "d1_dataset": str(d1_dataset), "d1_sfm": d1_binding,
            "d1_dataset_inventory_sha256": canonical_sha(d1_files), "cache": expected_cache,
            "copied_database_sha256": copied_cache["database_sha256"],
            "helper_sha256": helper_hashes, "registered_model_sha256": registered_hashes,
            "sfm_report_sha256": room.sha(report_path), "sfm_run_sha256": room.sha(run_path),
            "derived_model_sha256": adapter["model_sha256"], "training_images": train, "evaluation_images": heldout,
            "registered_training_ids": sorted(registered), "original_pose_fallback_ids": sorted(fallback),
            "fallback_authorized": authorized}


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
    is_d2 = is_d and bounded_json(dataset / "adapter-report.json").get("sfm_profile") == sfm_incremental.PROFILE
    if is_d:
        if is_d2:
            room.require(int(label[1:]) >= 2, "D2 must follow the original D01 attempt")
            sfm_binding = validate_incremental_sfm_dataset(dataset, files, original, source)
        else:
            sfm_binding = validate_sfm_dataset(dataset, files, original, source)
    else:
        room.require(files == original["dataset_files"], "A and B require the exact original 153-frame dataset")
    held = Decimal(costs["total_historical_spatial_usage_usd"])
    predecessors = []
    completed_a = []
    completed_b = []
    completed_d01 = []
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
        if is_d2 and path.name == "spatial-ablation-20260914-d01.allocation.json" and receipt.get("outcome") == "trained":
            room.require(canonical_sha(receipt.get("dataset_files")) == sfm_binding["d1_dataset_inventory_sha256"],
                         "D2 requires D01 metrics from the exact cached D1 dataset")
            completed_d01.append(completed_pose_metrics(receipt_path, receipt, expected_step=29999))
    room.require(not is_b or completed_a, "B requires completed A with collected held-out metrics")
    room.require(not is_d or completed_b, "D requires completed B with collected final held-out metrics")
    room.require(not is_d2 or completed_d01, "D2 requires completed D01 with collected final held-out metrics")
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
    if is_d2:
        plan.update(completed_d01_metrics=completed_d01,
                    selection="manual review of D01 quality; unknown-pose registration from the frozen D1 cache; no automatic quality threshold or retry")
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
