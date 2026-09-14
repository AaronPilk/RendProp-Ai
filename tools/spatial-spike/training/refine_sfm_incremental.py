#!/usr/bin/env python3
"""Inactive manual D2: register unknown cameras from D1's copied cached matches.

Separate official pycolmap==4.2.0 environment only. Plans by default; --execute
must only be used after the frozen D1 quality result is reviewed. No feature
extraction, matching, GPU, network client, provisioning, or trainer invocation.
Default: fail closed on unregistered training images. The explicit fallback
option preserves missing cameras as ORIGINAL ARKit records with zero tracks;
it does not claim those cameras were reconstructed or their quality accepted.
"""

import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import struct
import sys
import time

import refine_sfm as d1
from prepare_capture import CaptureError, read_json, require
from run_training import bounded_process, validate_dataset


PROFILE = {
    "name": "D2-cached-incremental-registration-v1",
    "pycolmap_version": "4.2.0", "num_threads": 4, "random_seed": 0,
    "max_seconds": 1800, "cache_limit_bytes": 1024 ** 3,
    "registration": "Unknown-pose incremental_mapping, no input reconstruction or position priors; fixed intrinsics.",
    "model_selection": "Most registered images, then most points, then lowest model ID; other components are not silently merged.",
    "alignment_max_error_m": 1.0, "alignment_min_inlier_fraction": 0.5,
    "alignment": "Robust Sim3 camera-center alignment to ARKit; 1m geometric consensus bound, not a rendering-quality threshold.",
    "bundle_adjustment": "Unchanged D1 fixed-intrinsics 1m isotropic camera-position-prior BA.",
    "fallback_default": "fail_closed",
    "optional_fallback": "Explicitly restore original ARKit camera records for unregistered training IDs, with zero 3D observations.",
    "determinism": "Seeds and options frozen; four-thread solvers are not guaranteed bitwise deterministic.",
    "gpu_used": False, "network_used": False, "scene_quality_accepted": False, "quality_status": "unknown",
}


def file_sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def json_options(value):
    if isinstance(value, dict):
        return {str(k): json_options(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        values = sorted(value) if isinstance(value, set) else value
        return [json_options(v) for v in values]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return str(value)


def mapping_options(names, p):
    options = p.IncrementalPipelineOptions(
        num_threads=4, random_seed=0, max_runtime_seconds=1800,
        extract_colors=False, ba_use_gpu=False, use_prior_position=False,
        structure_less_registration_fallback=False,
        ba_refine_focal_length=False, ba_refine_principal_point=False,
        ba_refine_extra_params=False, ba_refine_sensor_from_rig=False)
    options.image_names = sorted(names)
    options.mapper.num_threads = 4
    options.mapper.random_seed = 0
    options.mapper.abs_pose_refine_focal_length = False
    options.mapper.abs_pose_refine_extra_params = False
    options.triangulation.random_seed = 0
    return options


def alignment_options(p):
    return p.RANSACOptions(max_error=PROFILE["alignment_max_error_m"],
        min_inlier_ratio=PROFILE["alignment_min_inlier_fraction"], confidence=0.9999,
        min_num_trials=1000, max_num_trials=10000, random_seed=0, num_threads=1)


def require_original_calibration(camera, original, p):
    import numpy as np
    require(camera.camera_id in original.cameras, "unknown camera calibration")
    expected = original.cameras[camera.camera_id]
    require(camera.model == expected.model == p.CameraModelId.PINHOLE
            and camera.width == expected.width and camera.height == expected.height
            and np.array_equal(camera.params, expected.params), "changed fixed camera calibration")


def cache_inventory(database, expected):
    """Read only a quiescent SQLite file; immutable avoids touching its WAL/SHM."""
    database = Path(database)
    require(database.is_file() and not database.is_symlink(), "cached database must be a regular file")
    require(0 < database.stat().st_size <= PROFILE["cache_limit_bytes"], "cached database exceeds bound")
    wal = database.with_name(database.name + "-wal")
    require(not wal.exists() or wal.stat().st_size == 0, "cached database has an uncheckpointed WAL")
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro&immutable=1", uri=True)) as db:
        require(dict(db.execute("SELECT image_id,name FROM images")) == expected,
                "cached images must be exactly the training cohort; no heldout images")
        keypoints = dict(db.execute("SELECT image_id,rows FROM keypoints"))
        require(set(keypoints) == set(expected) and all(n > 0 for n in keypoints.values()),
                "cached features are incomplete")
        rows = list(db.execute("SELECT pair_id,rows,LENGTH(data) FROM two_view_geometries"))
        for pair_id, count, size in rows:
            a, b = divmod(pair_id, 2147483647)
            require(a in expected and b in expected and a < b,
                    "cached correspondence references an excluded image")
            require(count >= 0 and (size or 0) == count * 8, "malformed cached correspondence")
        positives = sum(n > 0 for _, n, _ in rows)
        require(positives > 0, "cached database has no inlier correspondences")
    return {"database_sha256": file_sha(database), "verification_row_count": len(rows),
            "pairs_with_inliers": positives, "inlier_match_count": sum(n for _, n, _ in rows)}


def register_cached(database, images, work, names, p):
    """No existing model passed: camera poses are estimated from correspondences."""
    options = mapping_options(names, p)
    models = p.incremental_mapping(database, images, work / "incremental-models", options=options)
    require(models, "incremental registration produced no model")
    inventory = [{"model_id": int(i), "registered_ids": sorted(m.reg_image_ids()),
                  "points": m.num_points3D()} for i, m in sorted(models.items())]
    model_id = min(models, key=lambda i: (-len(models[i].reg_image_ids()), -models[i].num_points3D(), i))
    # COLMAP's writer serializes registered images only, stripping unloaded
    # database camera records before any explicit missing-camera fallback.
    selected = work / "registered-model"
    selected.mkdir()
    models[model_id].write_binary(selected)
    model = p.Reconstruction(selected)
    require(set(model.images) == set(model.reg_image_ids()), "selected model contains unregistered records")
    require({im.name for im in model.images.values()} <= set(names), "registration included an excluded image")
    return model, {"models": inventory, "selected_model_id": int(model_id),
                   "options": json_options(options.todict())}


def align_registered(model, original, p):
    import numpy as np
    ids = sorted(model.reg_image_ids())
    require(len(ids) >= 3, "alignment requires three registered cameras")
    centers = np.array([original.images[i].projection_center() for i in ids])
    require(np.isfinite(centers).all() and np.linalg.matrix_rank(centers - centers.mean(axis=0)) >= 2,
            "ARKit camera centers do not anchor a similarity transform")
    options = alignment_options(p)
    transform = p.align_reconstruction_to_locations(model,
        [original.images[i].name for i in ids], centers, 3, options)
    require(transform is not None and np.isfinite(transform.scale) and transform.scale > 0,
            "robust alignment to ARKit failed")
    model.transform(transform)
    errors = np.array([np.linalg.norm(model.images[i].projection_center() - centers[j])
                       for j, i in enumerate(ids)])
    inliers = errors <= PROFILE["alignment_max_error_m"]
    require(np.isfinite(errors).all() and int(inliers.sum()) >= max(3, int(np.ceil(len(ids) * 0.5)))
            and np.linalg.matrix_rank(centers[inliers] - centers[inliers].mean(axis=0)) >= 2,
            "alignment lacks non-collinear majority support")
    return {"options": json_options(options.todict()), "scale": float(transform.scale),
            "inlier_ids": [i for i, valid in zip(ids, inliers) if valid],
            "position_error_median_m": float(np.median(errors)), "position_error_max_m": float(errors.max())}


def complete_cohort(model, original, training_ids, p, allow_fallback=False):
    registered = set(model.reg_image_ids())
    require(registered <= set(training_ids), "registered camera outside training cohort")
    missing = sorted(set(training_ids) - registered)
    require(not missing or allow_fallback, f"unregistered training cameras: {missing}; fallback was not authorized")
    for image_id in missing:
        image = original.images[image_id]
        require(image_id not in model.images, "fallback would replace an existing image")
        if image.camera_id not in model.cameras:
            model.add_camera_with_trivial_rig(p.Camera(image.camera.todict()))
        model.add_image_with_trivial_frame(p.Image(image_id=image_id, camera_id=image.camera_id, name=image.name),
            p.Rigid3d(p.Rotation3d(image.cam_from_world().rotation.quat.copy()),
                      image.cam_from_world().translation.copy()))
    require(set(model.images) == set(training_ids), "training cohort was not preserved")
    return missing


def export_preserving_fallback(model, original, source, target, heldout, fallback_ids, work, p):
    d1.export_legacy(model, original, source, target, heldout, work, p)
    path = target / "sparse/0/images.bin"
    records = d1.image_records(path)
    originals = d1.image_records(source / "sparse/0/images.bin")
    for image_id in fallback_ids:
        require(model.images[image_id].num_points3D == 0 and originals[image_id][2] == 0,
                "fallback camera must have zero point observations")
        records[image_id] = originals[image_id]
    path.write_bytes(struct.pack("<Q", len(records)) + b"".join(records[i][1] for i in sorted(records)))
    final = d1.image_records(path)
    require(all(final[i] == originals[i] for i in fallback_ids), "fallback record changed")
    reloaded = p.Reconstruction(target / "sparse/0")
    require(reloaded.num_images() == original.num_images() and reloaded.num_points3D() == model.num_points3D(),
            "fallback export changed model cohort")


def validate_inputs(dataset, cached_sfm):
    p = d1.colmap_module()
    report = validate_dataset(dataset, 500000)
    train, heldout = d1.fixed_split(report["image_sha256"])
    prior = read_json(cached_sfm / "sfm-report.json")
    require(prior.get("status") == "prepared" and prior.get("profile") == d1.PROFILE,
            "cache must come from the completed frozen D1 profile")
    require(prior.get("source_model_sha256") == report["model_sha256"]
            and prior.get("source_adapter_report_sha256") == file_sha(dataset / "adapter-report.json")
            and prior.get("training_images") == train and prior.get("evaluation_images") == heldout
            and prior.get("heldout_pixels_used_by_sfm") is False,
            "cached reconstruction does not bind this original cohort")
    original = p.Reconstruction(dataset / "sparse/0")
    require({i: im.name for i, im in original.images.items()} == {i: f"{i:06d}.jpg" for i in range(1, 154)},
            "original camera IDs differ from the fixed cohort")
    inventory = cache_inventory(cached_sfm / "work/features.db", {int(n[:6]): n for n in train})
    inventory["sfm_report_sha256"] = file_sha(cached_sfm / "sfm-report.json")
    return p, report, original, train, heldout, inventory


def refine(dataset, cached_sfm, output, allow_fallback):
    import numpy as np
    p, source, original, train, heldout, inventory = validate_inputs(dataset, cached_sfm)
    training_ids = {int(n[:6]) for n in train}
    work, target = output / "work", output / "dataset"
    work.mkdir()
    images = work / "training-images"
    images.mkdir()
    record = {"status": "running", "profile": PROFILE, "fallback_authorized": allow_fallback,
        "source_model_sha256": source["model_sha256"], "source_image_sha256": source["image_sha256"],
        "source_adapter_report_sha256": file_sha(dataset / "adapter-report.json"),
        "original_arkit_seeds_used": False,
        "cache": inventory, "training_images": train, "evaluation_images": heldout,
        "source_sha256": {name: file_sha(Path(__file__).with_name(name)) for name in
                          (Path(__file__).name, "refine_sfm.py", "run_training.py", "prepare_capture.py")},
        "python_version": platform.python_version(), "numpy_version": np.__version__,
        "gpu_used": False, "network_used": False, "heldout_pixels_used_by_sfm": False,
        "evaluation_pose_records_unchanged": True, "scene_quality_accepted": False, "quality_status": "unknown",
        "qualification": "Original loss-heldout ARKit camera records; ARKit VIO is not independent ground-truth evaluation. Fallback IDs, if any, are not reconstructed."}
    path = output / "sfm-report.json"
    try:
        d1.write_json(path, record)
        database = work / "features.db"
        shutil.copyfile(cached_sfm / "work/features.db", database)
        require(file_sha(database) == inventory["database_sha256"], "cache changed during copy")
        with p.Database.open(database) as db:
            require(db.num_pose_priors() == 0, "cached database unexpectedly contains pose priors")
            for camera in db.read_all_cameras():
                require_original_calibration(camera, original, p)
            require({im.image_id: im.camera_id for im in db.read_all_images()} ==
                    {i: original.images[i].camera_id for i in training_ids}, "cached image calibration IDs changed")
        for name in train:
            shutil.copyfile(dataset / "images" / name, images / name)
            require(file_sha(images / name) == source["image_sha256"][name], "training JPEG changed")
        started = time.monotonic()
        model, record["registration"] = register_cached(database, images, work, train, p)
        record["registered_model_sha256"] = {name: file_sha(work / "registered-model" / name) for name in d1.MODEL_FILES}
        record["copied_database_sha256"] = file_sha(database)
        record["registration_seconds"] = time.monotonic() - started
        record["registered_training_ids"] = sorted(model.reg_image_ids())
        all_registered = {i for item in record["registration"]["models"] for i in item["registered_ids"]}
        record["unregistered_training_ids"] = sorted(training_ids - all_registered)
        record["missing_from_selected_model_ids"] = sorted(training_ids - set(model.reg_image_ids()))
        record["registered_in_other_models_ids"] = sorted(all_registered - set(model.reg_image_ids()))
        record["original_pose_fallback_ids"] = []
        d1.write_json(path, record)
        require(not record["missing_from_selected_model_ids"] or allow_fallback,
                f"training cameras missing from selected model: {record['missing_from_selected_model_ids']}; fallback was not authorized")
        require(100 <= model.num_points3D() <= 500000, "registered seed count outside trainer bounds")
        for image in model.images.values():
            require_original_calibration(image.camera, original, p)
        record["alignment"] = align_registered(model, original, p)
        record["bundle_adjustment"] = d1.pose_prior_ba(model, original, p)
        record["filtered_observations"] = p.ObservationManager(model).filter_all_points3D(4., 1.5)
        require(100 <= model.num_points3D() <= 500000, "filtered seed count outside trainer bounds")
        model.extract_colors_for_all_images(images, num_threads=4)
        record["final_reprojection_rmse_px"] = d1.reprojection_rmse(model)
        record["original_pose_fallback_ids"] = complete_cohort(model, original, training_ids, p, allow_fallback)
        record["final_points"] = model.num_points3D()
        record["final_observations"] = model.compute_num_observations()
        record["observations_by_training_image"] = {str(i): im.num_points3D for i, im in sorted(model.images.items())}
        export_preserving_fallback(model, original, dataset, target, set(heldout),
                                   record["original_pose_fallback_ids"], work, p)
        (target / "images").mkdir()
        for name, checksum in source["image_sha256"].items():
            shutil.copyfile(dataset / "images" / name, target / "images" / name)
            require(file_sha(target / "images" / name) == checksum, "output JPEG changed")
        derived = {key: source[key] for key in ("format", "schema_version", "gsplat_commit", "session_id",
                   "frames", "world_space", "camera_conversion") if key in source}
        derived.update(initial_points=model.num_points3D(), point_observations=model.compute_num_observations(),
            image_sha256=source["image_sha256"], model_sha256={name: file_sha(target / "sparse/0" / name) for name in d1.MODEL_FILES},
            gpu_training_performed=False, reprojection_error_measured=True, sfm_profile=PROFILE,
            sfm_provenance="../sfm-report.json", evaluation_images=heldout,
            initialization="Cached training-only COLMAP correspondences; unknown-pose incremental registration, robust ARKit alignment, and unchanged D1 position-prior BA.",
            registered_training_ids=record["registered_training_ids"],
            fallback_authorized=allow_fallback,
            original_pose_fallback_ids=record["original_pose_fallback_ids"], scene_quality_accepted=False, quality_status="unknown",
            evaluation_camera_records="Byte-identical originals, excluded from registration and point colors.")
        require(validate_inputs(dataset, cached_sfm)[-1] == inventory, "original cache or source changed")
        d1.write_json(target / "adapter-report.pending.json", derived)
        record["status"] = "prepared_pending_supervisor"
    except BaseException as exc:
        record.update(status="failed", error=str(exc))
        raise
    finally:
        d1.write_json(path, record)


def validate_paths(dataset, cached_sfm, output):
    for source in (dataset, cached_sfm):
        require(not output.is_relative_to(source) and not source.is_relative_to(output),
                "output must be disjoint from original data and cached reconstruction")
    require(not any((parent / ".git").exists() for parent in (output, *output.parents)),
            "private reconstruction output must be outside Git")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--cached-sfm", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--max-seconds", type=int, default=1800)
    parser.add_argument("--allow-original-pose-fallback", action="store_true")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        require(1 <= args.max_seconds <= 1800, "D2 wall-clock ceiling must be 1–1800 seconds")
        dataset, cached, output = args.dataset.resolve(), args.cached_sfm.resolve(), args.output.resolve()
        validate_paths(dataset, cached, output)
        if args.worker:
            require(args.execute and output.is_dir(), "worker requires a supervisor-created directory")
            refine(dataset, cached, output, args.allow_original_pose_fallback)
            return 0
        require(not output.exists(), "output exists; choose a new private directory")
        p, _, _, train, heldout, inventory = validate_inputs(dataset, cached)
        plan = {"profile": PROFILE, "max_seconds": args.max_seconds, "cache": inventory,
                "mapping_options": json_options(mapping_options(train, p).todict()),
                "alignment_options": json_options(alignment_options(p).todict()),
                "training_frames": len(train), "evaluation_frames": len(heldout),
                "evaluation_images": heldout,
                "fallback_authorized": args.allow_original_pose_fallback, "execute": args.execute}
        print(json.dumps(plan, indent=2), flush=True)
        if not args.execute:
            return 0
        output.mkdir(parents=True, mode=0o700)
        run = {**plan, "status": "running"}
        started = time.monotonic()
        try:
            env = dict(os.environ)
            env.update({key: "4" for key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
                        "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS")})
            env.update(CUDA_VISIBLE_DEVICES="", PYTHONUNBUFFERED="1", PYTHONDONTWRITEBYTECODE="1")
            command = [sys.executable, str(Path(__file__).resolve()), "--dataset", str(dataset),
                       "--cached-sfm", str(cached), "--output", str(output), "--execute", "--worker"]
            if args.allow_original_pose_fallback:
                command.append("--allow-original-pose-fallback")
            with (output / "sfm.log").open("x") as log:
                code, _ = bounded_process(command, args.max_seconds, env=env, stdout=log)
            require(code == 0, f"D2 worker exited {code}; see private sfm.log")
            require(validate_inputs(dataset, cached)[-1] == inventory, "frozen source changed during worker")
            pending = output / "dataset/adapter-report.pending.json"
            pending.rename(output / "dataset/adapter-report.json")
            validate_dataset(output / "dataset", 500000)
            prepared = read_json(output / "sfm-report.json")
            require(prepared.get("status") == "prepared_pending_supervisor", "worker has no complete receipt")
            prepared["status"] = "prepared"
            d1.write_json(output / "sfm-report.json", prepared)
            run["status"] = "prepared"
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
