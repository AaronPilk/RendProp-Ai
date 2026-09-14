#!/usr/bin/env python3
"""Inactive D3: expand cached training-only pairs, then use frozen D2 geometry.

Separate official pycolmap==4.2.0 environment. Plans unless --execute is given.
No feature extraction, new images, intrinsics changes, GPU, network, or training.
All original cached rows must survive unchanged. Registration quality remains
unknown and requires manual review before any separately authorized GPU job.
"""
import argparse
from contextlib import closing
import hashlib
from itertools import combinations
import json
import math
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import struct
import sys
import time

import refine_sfm as d1
import refine_sfm_incremental as d2
from prepare_capture import CaptureError, require, read_json
from run_training import bounded_process, validate_dataset

PROFILE = {
    "name": "D3-cached-all-training-pairs-v1", "pycolmap_version": "4.2.0",
    "num_threads": 4, "random_seed": 0, "max_seconds": 1800,
    "candidate_pairs": 8778, "training_frames": 133, "evaluation_frames": 20,
    "matching": "D1 FeatureMatchingOptions(num_threads=4,use_gpu=False); original SIFT descriptors; all sorted unordered training pairs.",
    "verification": "D1 TwoViewGeometryOptions defaults; ransac.random_seed=0,num_threads=1.",
    "existing_rows": "All original match and two-view rows must remain byte-identical; fixed database tables cannot change.",
    "geometry_profile": d2.PROFILE, "feature_extraction_performed": False,
    "gpu_used": False, "network_used": False, "quality_status": "unknown", "scene_quality_accepted": False,
}
PAIR_TABLES = {"matches", "two_view_geometries"}
SOURCE_FILES = ("refine_sfm_expanded_pairs.py", "refine_sfm_incremental.py", "refine_sfm.py",
                "run_training.py", "prepare_capture.py")


def matching_options(p):
    matching = p.FeatureMatchingOptions(num_threads=4, use_gpu=False)
    verification = p.TwoViewGeometryOptions()
    verification.ransac.random_seed = 0
    verification.ransac.num_threads = 1
    return matching, verification


def all_pairs(expected):
    require(all(type(i) is int and expected[i] == f"{i:06d}.jpg" for i in expected), "invalid training IDs")
    return list(combinations(sorted(expected), 2))


def hash_row(digest, row):
    """Unambiguous typed hashing includes full descriptor and correspondence blobs."""
    for value in row:
        if value is None:
            tag, data = b"n", b""
        elif isinstance(value, bytes):
            tag, data = b"b", value
        elif isinstance(value, str):
            tag, data = b"s", value.encode("utf-8")
        elif isinstance(value, int):
            tag, data = b"i", str(value).encode("ascii")
        else:
            require(isinstance(value, float) and math.isfinite(value), "non-finite cache value")
            tag, data = b"f", struct.pack("<d", value)
        digest.update(tag + struct.pack("<Q", len(data)) + data)
    digest.update(b"r")


def database_tables(path):
    """Read a quiescent bounded file; do not create WAL/SHM sidecars."""
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= d2.PROFILE["cache_limit_bytes"],
            "database exceeds the regular-file bound")
    wal = path.with_name(path.name + "-wal")
    require(not wal.exists() or wal.stat().st_size == 0, "database has uncheckpointed WAL")
    tables = {}
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True)) as db:
        schema = list(db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"))
        for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
            require(name.replace("_", "").isalnum(), "unexpected SQLite table name")
            digest, count = hashlib.sha256(), 0
            for row in db.execute(f'SELECT * FROM "{name}" ORDER BY rowid'):
                hash_row(digest, row)
                count += 1
            tables[name] = {"rows": count, "sha256": digest.hexdigest()}
    return {"schema_sha256": hashlib.sha256(json.dumps(schema, separators=(",", ":")).encode()).hexdigest(),
            "tables": tables}


def validate_expansion(source, expanded, expected, before, after):
    require(before["schema_sha256"] == after["schema_sha256"] and set(before["tables"]) == set(after["tables"]),
            "expanded cache schema changed")
    require(all(before["tables"][name] == after["tables"][name] for name in before["tables"] if name not in PAIR_TABLES),
            "fixed cached features, calibration or camera records changed")
    pair_ids = {a * 2147483647 + b for a, b in all_pairs(expected)}
    with closing(sqlite3.connect(source.as_uri() + "?mode=ro&immutable=1", uri=True)) as original, \
            closing(sqlite3.connect(expanded.as_uri() + "?mode=ro&immutable=1", uri=True)) as result:
        for table in sorted(PAIR_TABLES):
            require({row[0] for row in result.execute(f'SELECT pair_id FROM "{table}"')} == pair_ids,
                    "expanded matches must contain every training-only candidate pair")
            for pair_id, count, size in result.execute(f'SELECT pair_id,rows,LENGTH(data) FROM "{table}"'):
                require(count >= 0 and (size or 0) == count * 8, "malformed expanded correspondence")
            for row in original.execute(f'SELECT * FROM "{table}" ORDER BY pair_id'):
                require(result.execute(f'SELECT * FROM "{table}" WHERE pair_id=?', (row[0],)).fetchone() == row,
                        "matching replaced an original cached row")
    return {"original_match_rows_unchanged": True, "original_verification_rows_unchanged": True,
            "fixed_tables_unchanged": True, "heldout_images_absent": True}


def expand_pairs(source, database, pairfile, expected, p):
    inventory = d2.cache_inventory(source, expected)
    before = database_tables(source)
    with closing(sqlite3.connect(source.as_uri() + "?mode=ro&immutable=1", uri=True)) as db:
        matches = {row[0] for row in db.execute("SELECT pair_id FROM matches")}
        verified = {row[0] for row in db.execute("SELECT pair_id FROM two_view_geometries")}
        require(matches == verified, "cached pair tables are incomplete; existing pairs must be skipped intact")
    shutil.copyfile(source, database)
    require(d2.file_sha(database) == inventory["database_sha256"], "cache changed during copy")
    pairs = all_pairs(expected)
    pairfile.write_text("".join(f"{expected[a]} {expected[b]}\n" for a, b in pairs))
    matching, verification = matching_options(p)
    started = time.monotonic()
    p.match_image_pairs(database, matching_options=matching,
        pairing_options=p.ImportedPairingOptions(match_list_path=pairfile),
        verification_options=verification, device=p.Device.cpu)
    after = database_tables(database)
    preserved = validate_expansion(source, database, expected, before, after)
    expanded = d2.cache_inventory(database, expected)
    require(database_tables(source) == before and d2.file_sha(source) == inventory["database_sha256"],
            "original D1 cache changed")
    return {"candidate_pairs": len(pairs), "pair_list_sha256": d2.file_sha(pairfile),
        "added_candidate_pairs": len(pairs) - inventory["verification_row_count"],
        "added_pairs_with_inliers": expanded["pairs_with_inliers"] - inventory["pairs_with_inliers"],
        "matching_options": d2.json_options(matching.todict()),
        "verification_options": d2.json_options(verification.todict()),
        "matching_seconds": time.monotonic() - started, "before": inventory, "after": expanded,
        "before_tables": before, "after_tables": after, **preserved}


def refine(dataset, cached, output, allow_fallback):
    p, source, original, train, heldout, inventory = d2.validate_inputs(dataset, cached)
    ids = {int(name[:6]) for name in train}
    work, target = output / "work", output / "dataset"
    work.mkdir()
    images = work / "training-images"
    images.mkdir()
    record = {"status": "running", "profile": PROFILE, "fallback_authorized": allow_fallback,
        "python_version": platform.python_version(), "numpy_version": __import__("numpy").__version__,
        "cache": inventory, "source_model_sha256": source["model_sha256"], "source_image_sha256": source["image_sha256"],
        "source_adapter_report_sha256": d2.file_sha(dataset / "adapter-report.json"),
        "source_sha256": {name: d2.file_sha(Path(__file__).with_name(name)) for name in SOURCE_FILES},
        "training_images": train, "evaluation_images": heldout, "evaluation_pose_records_unchanged": True,
        "heldout_pixels_used_by_sfm": False, "original_arkit_seeds_used": False,
        "feature_extraction_performed": False, "gpu_used": False, "network_used": False,
        "scene_quality_accepted": False, "quality_status": "unknown"}
    path = output / "sfm-report.json"
    try:
        d1.write_json(path, record)
        database = work / "features.db"
        record["matching"] = expand_pairs(cached / "work/features.db", database, work / "matched-pairs.txt",
                                          {i: f"{i:06d}.jpg" for i in ids}, p)
        require(record["matching"]["candidate_pairs"] == PROFILE["candidate_pairs"], "wrong fixed candidate count")
        d1.write_json(path, record)
        with p.Database.open(database) as db:
            require(db.num_pose_priors() == 0, "unexpected cached pose priors")
            for camera in db.read_all_cameras():
                d2.require_original_calibration(camera, original, p)
            require({im.image_id: im.camera_id for im in db.read_all_images()} ==
                    {i: original.images[i].camera_id for i in ids}, "cached calibration IDs changed")
        for name in train:
            shutil.copyfile(dataset / "images" / name, images / name)
            require(d2.file_sha(images / name) == source["image_sha256"][name], "training JPEG changed")
        started = time.monotonic()
        model, record["registration"] = d2.register_cached(database, images, work, train, p)
        record["registration_seconds"] = time.monotonic() - started
        record["registered_model_sha256"] = {name: d2.file_sha(work / "registered-model" / name) for name in d1.MODEL_FILES}
        record["copied_database_sha256"] = d2.file_sha(database)
        require(database_tables(database) == record["matching"]["after_tables"], "registration changed expanded cache records")
        registered = set(model.reg_image_ids())
        all_registered = {i for component in record["registration"]["models"] for i in component["registered_ids"]}
        record.update(registered_training_ids=sorted(registered), unregistered_training_ids=sorted(ids - all_registered),
            missing_from_selected_model_ids=sorted(ids - registered), registered_in_other_models_ids=sorted(all_registered - registered),
            original_pose_fallback_ids=[])
        d1.write_json(path, record)
        require(not (ids - registered) or allow_fallback, "unregistered training cameras; fallback was not authorized")
        require(100 <= model.num_points3D() <= 500000, "registered seed count outside bounds")
        for image in model.images.values():
            d2.require_original_calibration(image.camera, original, p)
        record["alignment"] = d2.align_registered(model, original, p)
        record["bundle_adjustment"] = d1.pose_prior_ba(model, original, p)
        record["filtered_observations"] = p.ObservationManager(model).filter_all_points3D(4., 1.5)
        require(100 <= model.num_points3D() <= 500000, "filtered seed count outside bounds")
        model.extract_colors_for_all_images(images, num_threads=4)
        record["final_reprojection_rmse_px"] = d1.reprojection_rmse(model)
        record["original_pose_fallback_ids"] = d2.complete_cohort(model, original, ids, p, allow_fallback)
        record.update(final_points=model.num_points3D(), final_observations=model.compute_num_observations(),
            observations_by_training_image={str(i): im.num_points3D for i, im in sorted(model.images.items())})
        d2.export_preserving_fallback(model, original, dataset, target, set(heldout), record["original_pose_fallback_ids"], work, p)
        (target / "images").mkdir()
        for name, checksum in source["image_sha256"].items():
            shutil.copyfile(dataset / "images" / name, target / "images" / name)
            require(d2.file_sha(target / "images" / name) == checksum, "output JPEG changed")
        derived = {key: source[key] for key in ("format", "schema_version", "gsplat_commit", "session_id", "frames",
                    "world_space", "camera_conversion") if key in source}
        derived.update(initial_points=record["final_points"], point_observations=record["final_observations"],
            image_sha256=source["image_sha256"], model_sha256={name: d2.file_sha(target / "sparse/0" / name) for name in d1.MODEL_FILES},
            gpu_training_performed=False, reprojection_error_measured=True, sfm_profile=PROFILE, sfm_provenance="../sfm-report.json",
            evaluation_images=heldout, registered_training_ids=record["registered_training_ids"],
            original_pose_fallback_ids=record["original_pose_fallback_ids"], fallback_authorized=allow_fallback,
            initialization="Original D1 cached features; expanded training-only pairs; frozen D2 geometry pipeline.",
            scene_quality_accepted=False, quality_status="unknown")
        require(d2.validate_inputs(dataset, cached)[-1] == inventory, "frozen D1 cache or source changed")
        d1.write_json(target / "adapter-report.pending.json", derived)
        record["status"] = "prepared_pending_supervisor"
    except BaseException as exc:
        record.update(status="failed", error=str(exc))
        raise
    finally:
        d1.write_json(path, record)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("dataset", "cached-sfm", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--max-seconds", type=int, default=1800)
    parser.add_argument("--allow-original-pose-fallback", action="store_true")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        require(1 <= args.max_seconds <= 1800, "D3 wall-clock ceiling must be 1–1800 seconds")
        dataset, cached, output = args.dataset.resolve(), args.cached_sfm.resolve(), args.output.resolve()
        d2.validate_paths(dataset, cached, output)
        if args.worker:
            require(args.execute and output.is_dir(), "worker requires supervisor-created directory")
            refine(dataset, cached, output, args.allow_original_pose_fallback)
            return 0
        require(not output.exists(), "output exists; choose a new private directory")
        p, _, _, train, heldout, inventory = d2.validate_inputs(dataset, cached)
        matching, verification = matching_options(p)
        plan = {"profile": PROFILE, "max_seconds": args.max_seconds, "cache": inventory,
            "matching_options": d2.json_options(matching.todict()), "verification_options": d2.json_options(verification.todict()),
            "mapping_options": d2.json_options(d2.mapping_options(train, p).todict()),
            "alignment_options": d2.json_options(d2.alignment_options(p).todict()),
            "training_frames": len(train), "evaluation_frames": len(heldout), "evaluation_images": heldout,
            "fallback_authorized": args.allow_original_pose_fallback, "execute": args.execute}
        print(json.dumps(plan, indent=2), flush=True)
        if not args.execute:
            return 0
        output.mkdir(parents=True, mode=0o700)
        run, started = {**plan, "status": "running"}, time.monotonic()
        try:
            env = dict(os.environ)
            env.update({key: "4" for key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
                        "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS")})
            env.update(CUDA_VISIBLE_DEVICES="", PYTHONUNBUFFERED="1", PYTHONDONTWRITEBYTECODE="1")
            command = [sys.executable, str(Path(__file__).resolve()), "--dataset", str(dataset), "--cached-sfm", str(cached),
                       "--output", str(output), "--execute", "--worker"]
            if args.allow_original_pose_fallback:
                command.append("--allow-original-pose-fallback")
            with (output / "sfm.log").open("x") as log:
                code, _ = bounded_process(command, args.max_seconds, env=env, stdout=log)
            require(code == 0, f"D3 worker exited {code}; see private sfm.log")
            require(d2.validate_inputs(dataset, cached)[-1] == inventory, "frozen source changed during worker")
            (output / "dataset/adapter-report.pending.json").rename(output / "dataset/adapter-report.json")
            validate_dataset(output / "dataset", 500000)
            prepared = read_json(output / "sfm-report.json")
            require(prepared.get("status") == "prepared_pending_supervisor", "worker has no complete receipt")
            prepared["status"] = run["status"] = "prepared"
            d1.write_json(output / "sfm-report.json", prepared)
        except BaseException as exc:
            (output / "dataset/adapter-report.json").unlink(missing_ok=True)
            run.update(status="failed", error=str(exc))
            raise
        finally:
            run["elapsed_seconds"] = time.monotonic() - started
            d1.write_json(output / "sfm-run.json", run)
        return 0
    except (CaptureError, OSError, ImportError, RuntimeError, ValueError, sqlite3.Error) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
