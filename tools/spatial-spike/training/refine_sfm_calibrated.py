#!/usr/bin/env python3
"""D4 CPU-only known-focal metadata experiment; plans unless --execute is supplied.

The sole algorithm input change is prior_focal_length:0->1 on copied cameras.
The flag persists through cached verification and initial-pair registration.
Historical D3 features/raw matches are immutable. Frozen D2/D3 geometry follows.
Rejected diagnostics never receive a completed adapter report or GPU approval.
"""
import argparse
from contextlib import closing
import json
import math
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import sys
import time

import refine_sfm as d1
import refine_sfm_incremental as d2
import refine_sfm_expanded_pairs as d3
from prepare_capture import CaptureError, require, read_json
from run_training import bounded_process, validate_dataset

PREREGISTRATION = Path(__file__).resolve().parents[3] / "docs/audits/2026-09-19/D4-CALIBRATED-SFM-PREREGISTRATION.md"
SOURCE_FILES = ("refine_sfm_calibrated.py", *d3.SOURCE_FILES)
PROFILE = {"name": "D4-known-focal-metadata-v1", "pycolmap_version": "4.2.0",
    "camera_flag": "prior_focal_length", "before": 0, "after": 1,
    "training_frames": 133, "evaluation_frames": 20, "candidate_pairs": 8778,
    "raw_correspondences": 584883, "num_threads": 4, "random_seed": 0, "max_seconds": 1800,
    "geometry_profile": d2.PROFILE, "position_disagreement_reject_above_m": 1.0,
    "rotation_disagreement_reject_at_degrees": 90.0, "every_training_camera_requires_observations": True,
    "rotation_boundary_roundoff_degrees": 1e-10,
    "flag_scope": "Known-focal metadata remains enabled during verification and frozen registration, including initial-pair estimation.",
    "qualification": "ARKit disagreement preflight only; not physical ground truth or rendering-quality acceptance.",
    "calibrated_verification_caveat": "Pinned COLMAP may still select F/H fallback; this is not essential-matrix-only verification."}
SANDBOX_PROFILE = "(version 1) (allow default) (deny network*)"


def immutable(path):
    return closing(sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True))


def source_binding():
    return {"helper_sha256": {name: d2.file_sha(Path(__file__).with_name(name)) for name in SOURCE_FILES},
            "preregistration_sha256": d2.file_sha(PREREGISTRATION)}


def raw_inventory(path, expected):
    inventory = d2.cache_inventory(path, expected)
    pair_ids = {a * 2147483647 + b for a, b in d3.all_pairs(expected)}
    with immutable(path) as db:
        rows = list(db.execute("SELECT pair_id,rows,LENGTH(data) FROM matches"))
        require({r[0] for r in rows} == pair_ids, "raw cache must contain every training-only pair")
        require(all(n == 0 or n >= 15 for _, n, _ in rows), "raw rows below frozen verifier minimum would be altered")
        require(all(n >= 0 and (size or 0) == n * 8 for _, n, size in rows), "malformed raw correspondence data")
        require({r[0] for r in db.execute("SELECT pair_id FROM two_view_geometries")} == pair_ids,
                "derived cache has an incomplete pair inventory")
        cameras = list(db.execute("SELECT camera_id,model,width,height,params,prior_focal_length FROM cameras ORDER BY camera_id"))
        configs = {str(c): n for c, n in db.execute("SELECT config,COUNT(*) FROM two_view_geometries WHERE rows>0 GROUP BY config")}
    return {**inventory, "raw_pair_rows": len(rows), "raw_correspondences": sum(n for _, n, _ in rows),
            "camera_count": len(cameras), "focal_prior_zero_count": sum(r[-1] == 0 for r in cameras),
            "focal_prior_one_count": sum(r[-1] == 1 for r in cameras), "positive_geometry_configs": configs}


def validate_inputs(dataset, cached):
    p = d1.colmap_module()
    source = validate_dataset(dataset, 500000)
    train, heldout = d1.fixed_split(source["image_sha256"])
    expected = {int(n[:6]): n for n in train}
    original = p.Reconstruction(dataset / "sparse/0")
    require({i: im.name for i, im in original.images.items()} == {i: f"{i:06d}.jpg" for i in range(1, 154)},
            "original camera cohort changed")
    report, run = read_json(cached / "sfm-report.json"), read_json(cached / "sfm-run.json")
    require(report.get("status") == run.get("status") == "prepared" and
            report.get("profile") == run.get("profile") == d3.PROFILE and run.get("execute") is True,
            "cache must come from completed frozen D3")
    require(report.get("source_sha256") == {n: d2.file_sha(Path(__file__).with_name(n)) for n in d3.SOURCE_FILES},
            "D3 helper source changed")
    require(report.get("source_model_sha256") == source["model_sha256"] and
            report.get("source_image_sha256") == source["image_sha256"] and
            report.get("source_adapter_report_sha256") == d2.file_sha(dataset / "adapter-report.json") and
            report.get("training_images") == train and report.get("evaluation_images") == heldout and
            report.get("heldout_pixels_used_by_sfm") is False and report.get("original_arkit_seeds_used") is False,
            "D3 source or fixed evaluation cohort changed")
    database = cached / "work/features.db"
    inventory = raw_inventory(database, expected)
    require(inventory["raw_pair_rows"] == PROFILE["candidate_pairs"] and
            inventory["raw_correspondences"] == PROFILE["raw_correspondences"] and
            inventory["camera_count"] == inventory["focal_prior_zero_count"] == 133,
            "D4 requires exact original D3 raw matches and133 unknown-focal camera flags")
    tables = d3.database_tables(database)
    require(report.get("copied_database_sha256") == inventory["database_sha256"] and
            report["matching"]["after_tables"] == tables, "D3 database differs from frozen receipt")
    pairfile = cached / "work/matched-pairs.txt"
    pairs = "".join(f"{expected[a]} {expected[b]}\n" for a, b in d3.all_pairs(expected))
    require(pairfile.read_text() == pairs and report["matching"]["pair_list_sha256"] == d2.file_sha(pairfile),
            "D3 pair list changed")
    # Read using immutable SQLite, never opening the historical cache through a
    # writer-capable COLMAP handle (which can alter SQLite header bytes).
    with immutable(database) as db:
        require(db.execute("SELECT COUNT(*) FROM pose_priors").fetchone()[0] == 0, "unexpected pose priors")
        image_cameras = dict(db.execute("SELECT image_id,camera_id FROM images"))
        require(image_cameras == {i: original.images[i].camera_id for i in expected}, "cached camera IDs changed")
        import numpy as np
        for cid, model_id, width, height, params in db.execute("SELECT camera_id,model,width,height,params FROM cameras"):
            camera = original.cameras[cid]
            require(model_id == int(camera.model) and width == camera.width and height == camera.height and
                    np.array_equal(np.frombuffer(params, dtype="<f8"), camera.params), "cached numeric calibration changed")
    binding = {"database": inventory, "tables": tables, "pair_list_sha256": d2.file_sha(pairfile),
        "d3_report_sha256": d2.file_sha(cached / "sfm-report.json"), "d3_run_sha256": d2.file_sha(cached / "sfm-run.json"),
        "original_adapter_sha256": d2.file_sha(dataset / "adapter-report.json"),
        "original_model_sha256": source["model_sha256"], "original_image_sha256": source["image_sha256"]}
    return p, source, original, train, heldout, binding


def verify_protected_tables(source, copied, before, after, expected):
    require(before["schema_sha256"] == after["schema_sha256"] and set(before["tables"]) == set(after["tables"]),
            "cache schema changed")
    require(all(before["tables"][t] == after["tables"][t] for t in before["tables"]
                if t not in {"cameras", "two_view_geometries"}),
            "protected raw matches, features or fixed table changed")
    with immutable(source) as a, immutable(copied) as b:
        query = "SELECT camera_id,model,width,height,params,prior_focal_length FROM cameras ORDER BY camera_id"
        old, new = list(a.execute(query)), list(b.execute(query))
        require(len(old) == len(new) == before["tables"]["cameras"]["rows"] and all(r[-1] == 0 for r in old) and
                new == [(*r[:-1], 1) for r in old], "camera change was not solely prior_focal_length0->1")
    raw_inventory(copied, expected)


def reverify_cached(source, database, pairfile, expected, p):
    before_inventory, before = raw_inventory(source, expected), d3.database_tables(source)
    require(before_inventory["camera_count"] == before_inventory["focal_prior_zero_count"],
            "source focal flags must all be zero")
    require(not database.exists(), "fresh copied database required")
    shutil.copyfile(source, database)
    require(d2.file_sha(database) == before_inventory["database_sha256"], "source changed during cache copy")
    with closing(sqlite3.connect(database)) as db:
        changed = db.execute("UPDATE cameras SET prior_focal_length=1 WHERE prior_focal_length=0").rowcount
        require(changed == before_inventory["camera_count"], "wrong number of camera flags changed")
        db.execute("DELETE FROM two_view_geometries")
        db.commit()
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    pairfile.write_text("".join(f"{expected[a]} {expected[b]}\n" for a, b in d3.all_pairs(expected)))
    matching, verification = d3.matching_options(p)
    started = time.monotonic()
    # With raw matches present and geometry absent, this exact frozen API sends
    # existing raw rows directly to verification. Final raw-row hashes must match.
    p.match_image_pairs(database, matching_options=matching,
        pairing_options=p.ImportedPairingOptions(match_list_path=pairfile),
        verification_options=verification, device=p.Device.cpu)
    after = d3.database_tables(database)
    verify_protected_tables(source, database, before, after, expected)
    require(d3.database_tables(source) == before and d2.file_sha(source) == before_inventory["database_sha256"],
            "historical source cache changed")
    return {"before": before_inventory, "after": raw_inventory(database, expected),
        "before_tables": before, "after_tables": after, "changed_camera_flags": changed,
        "pair_list_sha256": d2.file_sha(pairfile), "seconds": time.monotonic() - started,
        "matching_options": d2.json_options(matching.todict()), "verification_options": d2.json_options(verification.todict()),
        "raw_matches_unchanged": True, "features_unchanged": True, "numeric_calibration_unchanged": True,
        "feature_extraction_performed": False, "descriptor_matching_performed": False}


def pose_stage(model, original, ids, stage, aligned=True):
    import numpy as np
    registered = set(model.reg_image_ids()) & set(ids)
    # Count genuine reciprocal observations, not merely a camera's presence in
    # the reconstruction. Heldout cameras must never appear in a point track.
    counts = {i: 0 for i in registered}
    for point_id, point in model.points3D.items():
        require(np.isfinite(point.xyz).all() and math.isfinite(point.error), "nonfinite reconstructed point")
        seen = set()
        for element in point.track.elements:
            image_id, index = element.image_id, element.point2D_idx
            require(image_id in registered and (image_id, index) not in seen, "excluded or duplicate track observation")
            seen.add((image_id, index))
            image = model.images[image_id]
            require(index < len(image.points2D) and image.points2D[index].point3D_id == point_id and
                    np.isfinite(image.points2D[index].xy).all(), "nonreciprocal point track")
            counts[image_id] += 1
        require(len({i for i, _ in seen}) >= 2, "point lacks two distinct training views")
    rows, bad_rotation, bad_position, nonfinite, zero = [], [], [], [], []
    for i in sorted(registered):
        image = model.images[i]
        observations = int(image.num_points3D)
        require(observations == counts[i], "camera and point observation counts differ")
        if observations == 0:
            zero.append(i)
        finite = bool(np.isfinite(image.cam_from_world().matrix()).all() and np.isfinite(image.projection_center()).all())
        row = {"image_id": i, "observations": observations, "finite": finite}
        if not finite:
            nonfinite.append(i)
        if aligned and finite:
            for pose in (image.cam_from_world(), original.images[i].cam_from_world()):
                rotation_matrix = pose.rotation.matrix()
                require(np.isfinite(rotation_matrix).all() and
                        np.allclose(rotation_matrix.T @ rotation_matrix, np.eye(3), atol=1e-6) and
                        abs(np.linalg.det(rotation_matrix) - 1.) <= 1e-6, "invalid rotation matrix")
            position = float(np.linalg.norm(image.projection_center() - original.images[i].projection_center()))
            rotation = float(np.degrees((image.cam_from_world().rotation * original.images[i].cam_from_world().rotation.inverse()).angle()))
            require(math.isfinite(position) and math.isfinite(rotation), "nonfinite pose discrepancy")
            row.update(position_difference_m=position, rotation_difference_degrees=rotation)
            if position > PROFILE["position_disagreement_reject_above_m"]:
                bad_position.append(i)
            # Conservatively include numerical roundoff at the exact 90° bound.
            if rotation >= PROFILE["rotation_disagreement_reject_at_degrees"] - PROFILE["rotation_boundary_roundoff_degrees"]:
                bad_rotation.append(i)
        rows.append(row)
    return {"stage": stage, "aligned_to_arkit_world": aligned, "registered_count": len(registered),
        "missing_ids": sorted(set(ids) - registered), "zero_observation_ids": zero, "nonfinite_ids": nonfinite,
        "position_rejection_ids": bad_position, "rotation_rejection_ids": bad_rotation, "per_camera": rows}


def admission(stages):
    require([s["stage"] for s in stages] == ["registered_unaligned", "aligned", "after_ba", "after_filtering", "exported"],
            "missing required pose/coverage stage")
    failures = [{"stage": s["stage"], "check": key, "image_ids": s[key]} for s in stages for key in
        ("missing_ids", "zero_observation_ids", "nonfinite_ids", "position_rejection_ids", "rotation_rejection_ids") if s[key]]
    return {"passed": not failures, "rejections": failures, "quality_accepted": False, "gpu_authorized": False,
            "qualification": PROFILE["qualification"]}


def refine(dataset, cached, output, allow_fallback):
    p, source, original, train, heldout, inputs = validate_inputs(dataset, cached)
    ids = {int(n[:6]) for n in train}
    work, target = output / "work", output / "dataset"
    work.mkdir()
    images = work / "training-images"
    images.mkdir()
    record = {"status": "running", "profile": PROFILE, "inputs": inputs, "source": source_binding(),
        "python_version": platform.python_version(), "numpy_version": __import__("numpy").__version__,
        "training_images": train, "evaluation_images": heldout, "evaluation_pose_records_unchanged": True,
        "fallback_authorized": allow_fallback, "gpu_used": False, "network_used": False,
        "heldout_pixels_used_by_sfm": False, "original_arkit_seeds_used": False,
        "quality_status": "unknown", "scene_quality_accepted": False, "pose_stages": []}
    path = output / "sfm-report.json"
    def checkpoint():
        d1.write_json(path, record)
    def stage(model, name, aligned=True):
        record["pose_stages"].append(pose_stage(model, original, ids, name, aligned))
        checkpoint()
    try:
        checkpoint()
        database = work / "features.db"
        record["reverification"] = reverify_cached(cached / "work/features.db", database, work / "matched-pairs.txt",
                                                   {i: f"{i:06d}.jpg" for i in ids}, p)
        checkpoint()
        for name in train:
            shutil.copyfile(dataset / "images" / name, images / name)
            require(d2.file_sha(images / name) == source["image_sha256"][name], "training JPEG changed")
        started = time.monotonic()
        model, record["registration"] = d2.register_cached(database, images, work, train, p)
        record["registration_seconds"] = time.monotonic() - started
        record["registered_model_sha256"] = {n: d2.file_sha(work / "registered-model" / n) for n in d1.MODEL_FILES}
        record["copied_database_sha256"] = d2.file_sha(database)
        require(d3.database_tables(database) == record["reverification"]["after_tables"], "registration changed copied cache records")
        registered = set(model.reg_image_ids())
        all_registered = {i for c in record["registration"]["models"] for i in c["registered_ids"]}
        record.update(registered_training_ids=sorted(registered), missing_from_selected_model_ids=sorted(ids - registered),
            unregistered_training_ids=sorted(ids - all_registered), registered_in_other_models_ids=sorted(all_registered - registered))
        stage(model, "registered_unaligned", False)
        require(not (ids - registered) or allow_fallback, "missing training cameras; diagnostic fallback was not authorized")
        require(100 <= model.num_points3D() <= 500000, "registered point count outside bounds")
        for image in model.images.values():
            d2.require_original_calibration(image.camera, original, p)
        record["alignment"] = d2.align_registered(model, original, p)
        stage(model, "aligned")
        record["bundle_adjustment"] = d1.pose_prior_ba(model, original, p)
        stage(model, "after_ba")
        record["filtered_observations"] = p.ObservationManager(model).filter_all_points3D(4., 1.5)
        require(100 <= model.num_points3D() <= 500000, "filtered point count outside bounds")
        stage(model, "after_filtering")
        model.extract_colors_for_all_images(images, num_threads=4)
        record["final_reprojection_rmse_px"] = d1.reprojection_rmse(model)
        require(math.isfinite(record["final_reprojection_rmse_px"]), "nonfinite residual")
        record["original_pose_fallback_ids"] = d2.complete_cohort(model, original, ids, p, allow_fallback)
        record.update(final_points=model.num_points3D(), final_observations=model.compute_num_observations(),
            observations_by_training_image={str(i): int(im.num_points3D) for i, im in sorted(model.images.items())})
        d2.export_preserving_fallback(model, original, dataset, target, set(heldout), record["original_pose_fallback_ids"], work, p)
        exported = p.Reconstruction(target / "sparse/0")
        stage(exported, "exported")
        record["cpu_admission"] = admission(record["pose_stages"])
        (target / "images").mkdir()
        for name, digest in source["image_sha256"].items():
            shutil.copyfile(dataset / "images" / name, target / "images" / name)
            require(d2.file_sha(target / "images" / name) == digest, "output JPEG changed")
        derived = {k: source[k] for k in ("format", "schema_version", "gsplat_commit", "session_id", "frames",
                   "world_space", "camera_conversion") if k in source}
        derived.update(initial_points=record["final_points"], point_observations=record["final_observations"],
            image_sha256=source["image_sha256"], model_sha256={n: d2.file_sha(target / "sparse/0" / n) for n in d1.MODEL_FILES},
            gpu_training_performed=False, reprojection_error_measured=True, sfm_profile=PROFILE, sfm_provenance="../sfm-report.json",
            evaluation_images=heldout, registered_training_ids=record["registered_training_ids"],
            original_pose_fallback_ids=record["original_pose_fallback_ids"], fallback_authorized=allow_fallback,
            cpu_admission_passed=record["cpu_admission"]["passed"], quality_status="unknown", scene_quality_accepted=False)
        require(validate_inputs(dataset, cached)[-1] == inputs and source_binding() == record["source"],
                "frozen inputs or helper source changed")
        d1.write_json(target / "adapter-report.pending.json", derived)
        record["status"] = "completed_pending_supervisor"
    except BaseException as exc:
        record.update(status="failed", error=str(exc))
        raise
    finally:
        checkpoint()


def clean_environment():
    # An explicit allowlist: never propagate host tokens, cloud configuration,
    # PYTHONPATH, dynamic-loader settings, or HOME into the room worker.
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
           "CUDA_VISIBLE_DEVICES": "", "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"}
    env.update({k: "4" for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
                "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS")})
    return env


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("dataset", "cached-sfm", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--max-seconds", type=int, default=1800)
    parser.add_argument("--allow-original-pose-fallback", action="store_true")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        require(1 <= args.max_seconds <= 1800, "D4 wall-clock ceiling must be1–1800 seconds")
        dataset, cached, output = args.dataset.resolve(), args.cached_sfm.resolve(), args.output.resolve()
        d2.validate_paths(dataset, cached, output)
        if args.worker:
            require(args.execute and output.is_dir(), "worker requires supervisor-created output")
            refine(dataset, cached, output, args.allow_original_pose_fallback)
            return 0
        require(not output.exists(), "fresh private output required")
        p, _, _, train, heldout, inputs = validate_inputs(dataset, cached)
        matching, verification = d3.matching_options(p)
        plan = {"profile": PROFILE, "source": source_binding(), "inputs": inputs, "max_seconds": args.max_seconds,
            "matching_options": d2.json_options(matching.todict()), "verification_options": d2.json_options(verification.todict()),
            "mapping_options": d2.json_options(d2.mapping_options(train, p).todict()),
            "alignment_options": d2.json_options(d2.alignment_options(p).todict()),
            "training_frames": len(train), "evaluation_frames": len(heldout), "evaluation_images": heldout,
            "execute": args.execute, "fallback_authorized": args.allow_original_pose_fallback,
            "network_policy": SANDBOX_PROFILE, "worker_environment_keys": sorted(clean_environment())}
        print(json.dumps(plan, indent=2), flush=True)
        if not args.execute:
            return 0
        require(platform.system() == "Darwin" and Path("/usr/bin/sandbox-exec").is_file(),
                "this frozen local experiment requires macOS sandbox network denial")
        output.mkdir(parents=True, mode=0o700)
        run, started = {**plan, "status": "running"}, time.monotonic()
        try:
            command = ["/usr/bin/sandbox-exec", "-p", SANDBOX_PROFILE, sys.executable, str(Path(__file__).resolve()),
                       "--dataset", str(dataset), "--cached-sfm", str(cached), "--output", str(output), "--execute", "--worker"]
            if args.allow_original_pose_fallback:
                command.append("--allow-original-pose-fallback")
            with (output / "sfm.log").open("x") as log:
                code, _ = bounded_process(command, args.max_seconds, env=clean_environment(), stdout=log)
            require(code == 0, f"D4 worker exited{code}; see private sfm.log")
            require(validate_inputs(dataset, cached)[-1] == inputs and source_binding() == plan["source"], "frozen inputs/source changed")
            result = read_json(output / "sfm-report.json")
            require(result.get("status") == "completed_pending_supervisor", "missing complete worker receipt")
            decision = admission(result["pose_stages"])
            require(decision == result.get("cpu_admission"), "admission receipt changed")
            if decision["passed"]:
                (output / "dataset/adapter-report.pending.json").rename(output / "dataset/adapter-report.json")
                validate_dataset(output / "dataset", 500000)
            result["status"] = run["status"] = "cpu_preflight_passed" if decision["passed"] else "cpu_rejected"
            run["cpu_admission"] = decision
            d1.write_json(output / "sfm-report.json", result)
        except BaseException as exc:
            (output / "dataset/adapter-report.json").unlink(missing_ok=True)
            run.update(status="failed", error=str(exc))
            raise
        finally:
            run["elapsed_seconds"] = time.monotonic() - started
            d1.write_json(output / "sfm-run.json", run)
        return 0 if decision["passed"] else 2
    except (CaptureError, OSError, ImportError, RuntimeError, ValueError, sqlite3.Error) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
