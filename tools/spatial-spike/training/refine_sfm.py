#!/usr/bin/env python3
"""Manual D1 SfM fallback; official pycolmap 4.2.0 in a SEPARATE environment.

No provisioning, uploads, GPU use, or trainer changes. The public entry point
only plans unless --execute is supplied. Never run this in gsplat's environment:
its unrelated pycolmap 0.0.1 package is a model reader.

D1 changes initialization AND training poses, so it is a pipeline ablation.
The original 20 loss-heldout camera records remain byte-identical. Their pixels
never enter SIFT, matching, triangulation, BA, or point-color extraction here.
The original ARKit trajectory itself used VIO observations across the capture;
this is therefore not a claim of independent ground-truth evaluation poses.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import sys
import time

from prepare_capture import CaptureError, require, read_json
from run_training import bounded_process, validate_dataset


PYCOLMAP_VERSION = "4.2.0"
PROFILE = {
    "name": "D1-sift-arkit-position-prior-v1",
    "pycolmap_version": PYCOLMAP_VERSION,
    "num_threads": 4,
    "max_seconds": 1800,
    "random_seed": 0,
    "max_num_features": 8192,
    "temporal_neighbors": 10,
    "nearest_position_neighbors": 10,
    "position_prior_stddev_m": 1.0,
    "position_prior_covariance_m2": [[1., 0., 0.], [0., 1., 0.], [0., 0., 1.]],
    "position_prior_assumption": "Isotropic 1m standard deviation, COLMAP's fallback default; NOT measured ARKit covariance.",
    "intrinsics": "fixed original per-image PINHOLE calibration",
    "rotation_prior": "ARKit initialization only; no rotation residual/prior is added",
    "pair_rule": "Union of next 10 training frames and 10 nearest camera centers per training frame; distance ties use image ID; sorted unique pairs.",
    "determinism": "Pair list and random seeds fixed; four-thread floating-point solvers are not guaranteed bitwise deterministic.",
}
MODEL_FILES = ("cameras.bin", "images.bin", "points3D.bin")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def colmap_module():
    import pycolmap
    require(pycolmap.__version__ == PYCOLMAP_VERSION,
            "use the separate official pycolmap==4.2.0 environment")
    return pycolmap


def fixed_split(image_names):
    """The same sorted-name test_every=8 split as the pinned gsplat reader."""
    expected = [f"{i:06d}.jpg" for i in range(1, 154)]
    require(sorted(image_names) == expected,
            "D1 requires the original 153-frame cohort, with unchanged 000001–000153.jpg names")
    heldout = expected[::8]
    return [name for name in expected if name not in heldout], heldout


def deterministic_pairs(centers):
    """IDs preserve capture order; no heldout frames may be supplied."""
    import numpy as np
    ids = sorted(centers)
    require(len(ids) >= 3, "at least three training cameras required")
    require(all(np.asarray(centers[i]).shape == (3,) and np.isfinite(centers[i]).all()
                for i in ids), "camera centers must be finite 3-vectors")
    pairs = set()
    for index, image_id in enumerate(ids):
        nearby = ids[index + 1:index + 1 + PROFILE["temporal_neighbors"]]
        by_distance = sorted((float(np.sum((centers[image_id] - centers[j]) ** 2)), j)
                             for j in ids if j != image_id)
        nearby += [j for _, j in by_distance[:PROFILE["nearest_position_neighbors"]]]
        pairs.update(tuple(sorted((image_id, other))) for other in nearby)
    return sorted(pairs)


def image_records(path):
    """Read classic COLMAP image records without changing quaternion bits."""
    data = Path(path).read_bytes()
    require(len(data) >= 8, "truncated images.bin")
    count, = struct.unpack_from("<Q", data)
    offset, records = 8, {}
    for _ in range(count):
        start = offset
        require(offset + 64 <= len(data), "truncated image header")
        image_id, = struct.unpack_from("<I", data, offset)
        end = data.find(b"\0", offset + 64)
        require(end >= 0 and end + 9 <= len(data), "truncated image name")
        name = data[offset + 64:end].decode("utf-8")
        observations, = struct.unpack_from("<Q", data, end + 1)
        offset = end + 9 + observations * 24
        require(offset <= len(data) and image_id not in records, "truncated or duplicate image record")
        records[image_id] = (name, data[start:offset], observations)
    require(offset == len(data), "extra bytes in images.bin")
    return records


def subset_model(original, names, p):
    """Copy poses and calibration only, explicitly discarding all old seeds."""
    result = p.Reconstruction()
    for image_id in sorted(original.images):
        image = original.images[image_id]
        if image.name not in names:
            continue
        require(image.has_pose and image.camera.model == p.CameraModelId.PINHOLE,
                "input requires registered PINHOLE cameras")
        if image.camera_id not in result.cameras:
            result.add_camera_with_trivial_rig(p.Camera(image.camera.todict()))
        result.add_image_with_trivial_frame(
            p.Image(image_id=image_id, camera_id=image.camera_id, name=image.name),
            p.Rigid3d(p.Rotation3d(image.cam_from_world().rotation.quat.copy()),
                      image.cam_from_world().translation.copy()))
    require(result.num_images() == len(names), "model/image cohort mismatch")
    return result


def seed_database(model, database, p):
    with p.Database.open(database) as db:
        for camera_id in sorted(model.cameras):
            db.write_camera(model.cameras[camera_id], use_camera_id=True)
            db.write_rig(model.rigs[camera_id], use_rig_id=True)
        # Modern COLMAP checks that an image's frame already contains its data ID.
        for image_id in sorted(model.images):
            db.write_frame(model.images[image_id].frame, use_frame_id=True)
            db.write_image(model.images[image_id], use_image_id=True)


def feature_triangulation(model, images, work, p, record, checkpoint=lambda: None):
    database = work / "features.db"
    centers = {i: model.images[i].projection_center() for i in model.images}
    pairs = deterministic_pairs(centers)
    pairfile = work / "matched-pairs.txt"
    pairfile.write_text("".join(f"{model.images[a].name} {model.images[b].name}\n" for a, b in pairs))
    record.update(pair_count=len(pairs), pair_list_sha256=sha256(pairfile))
    checkpoint()
    seed_database(model, database, p)
    extraction = p.FeatureExtractionOptions(num_threads=4, use_gpu=False, max_image_size=-1)
    extraction.sift.max_num_features = PROFILE["max_num_features"]
    matching = p.FeatureMatchingOptions(num_threads=4, use_gpu=False)
    verification = p.TwoViewGeometryOptions()
    verification.ransac.random_seed = PROFILE["random_seed"]
    verification.ransac.num_threads = 1
    start = time.monotonic()
    p.extract_features(database, images, image_names=sorted(image.name for image in model.images.values()),
                       extraction_options=extraction, device=p.Device.cpu)
    record["extraction_seconds"] = time.monotonic() - start
    checkpoint()
    start = time.monotonic()
    p.match_image_pairs(database, matching_options=matching,
                        pairing_options=p.ImportedPairingOptions(match_list_path=pairfile),
                        verification_options=verification, device=p.Device.cpu)
    record["matching_seconds"] = time.monotonic() - start
    checkpoint()
    with p.Database.open(database) as db:
        require({i.image_id for i in db.read_all_images()} == set(model.images),
                "feature database contains a missing or excluded image")
        record["verified_pairs"] = db.num_verified_image_pairs()
        record["keypoints_by_image"] = {str(i): len(db.read_keypoints(i)) for i in sorted(model.images)}
    checkpoint()
    require(record["verified_pairs"] > 0, "SIFT produced no verified image pairs")
    options = p.IncrementalPipelineOptions(num_threads=4, random_seed=0, ba_use_gpu=False,
                                          max_runtime_seconds=1800)
    options.image_names = sorted(i.name for i in model.images.values())
    options.ba_refine_focal_length = False
    options.ba_refine_principal_point = False
    options.ba_refine_extra_params = False
    options.ba_refine_sensor_from_rig = False
    options.triangulation.random_seed = 0
    options.mapper.random_seed = 0
    options.mapper.num_threads = 4
    start = time.monotonic()
    # This API holds known poses fixed internally. The separate BA below is
    # essential: triangulation alone would not test the pose-quality hypothesis.
    result = p.triangulate_points(model, database, images, work / "triangulated",
                                  clear_points=True, options=options, refine_intrinsics=False)
    record["triangulation_seconds"] = time.monotonic() - start
    checkpoint()
    require(set(result.images) == set(model.images), "triangulation changed training cohort")
    return result


def pose_prior_ba(model, original, p):
    import numpy as np
    supported = [i for i in sorted(model.images) if model.images[i].num_points3D > 0]
    locations = np.array([original.images[i].projection_center() for i in supported])
    require(len(supported) >= 3 and np.linalg.matrix_rank(locations - locations.mean(axis=0)) >= 2,
            "position priors cannot anchor this reconstruction's coordinate frame")
    config, priors = p.BundleAdjustmentConfig(), []
    for image_id in sorted(model.images):
        config.add_image(image_id)
        config.set_constant_cam_intrinsics(model.images[image_id].camera_id)
        priors.append(p.PosePrior(corr_data_id=model.images[image_id].data_id,
            position=original.images[image_id].projection_center(),
            position_covariance=PROFILE["position_prior_covariance_m2"],
            coordinate_system=p.PosePriorCoordinateSystem.CARTESIAN))
    options = p.BundleAdjustmentOptions(refine_focal_length=False, refine_principal_point=False,
        refine_extra_params=False, refine_sensor_from_rig=False, refine_rig_from_world=True,
        refine_points3D=True, print_summary=True)
    options.ceres.use_gpu = False
    options.ceres.solver_options.num_threads = 4
    options.ceres.solver_options.max_solver_time_in_seconds = 1800
    options.ceres.solver_options.max_num_iterations = 100
    prior_options = p.PosePriorBundleAdjustmentOptions(prior_position_fallback_stddev=1.0)
    prior_options.alignment_ransac.random_seed = 0
    prior_options.alignment_ransac.num_threads = 1
    prior_options.alignment_ransac.max_num_trials = 10000
    before = reprojection_rmse(model)
    start = time.monotonic()
    summary = p.create_pose_prior_bundle_adjuster(options, prior_options, config, priors, model).solve()
    require(summary.is_solution_usable(), "pose-prior bundle adjustment did not produce a usable solution")
    # Otherwise COLMAP can silently fall back to an unanchored two-camera gauge.
    expected_residuals = model.compute_num_observations() * 2 + len(supported) * 3
    require(summary.num_residuals == expected_residuals, "BA did not apply every supported camera-position prior")
    offsets = [float(np.linalg.norm(model.images[i].projection_center() -
                                   original.images[i].projection_center())) for i in sorted(model.images)]
    rotations = [float(np.degrees((model.images[i].cam_from_world().rotation *
                                  original.images[i].cam_from_world().rotation.inverse()).angle()))
                 for i in sorted(model.images)]
    return {"seconds": time.monotonic() - start, "summary": summary.brief_report(),
            "num_residuals": summary.num_residuals, "reprojection_rmse_before_px": before,
            "reprojection_rmse_after_px": reprojection_rmse(model),
            "position_change_median_m": float(np.median(offsets)), "position_change_max_m": max(offsets),
            "rotation_change_median_deg": float(np.median(rotations)), "rotation_change_max_deg": max(rotations),
            "images_without_triangulated_observations": sorted(set(model.images) - set(supported)),
            "coordinate_frame": "ARKit Cartesian camera-center priors; COLMAP restores its temporary fixed-scale numerical normalization after BA; no additional world transform."}


def reprojection_rmse(model):
    import numpy as np
    errors = []
    for image in model.images.values():
        for observation in image.points2D:
            if observation.has_point3D():
                projected = image.project_point(model.points3D[observation.point3D_id].xyz)
                require(projected is not None and np.isfinite(projected).all(), "invalid SfM reprojection")
                errors.append(float(np.sum((projected - observation.xy) ** 2)))
    require(errors, "SfM model contains no reprojection observations")
    return float(np.sqrt(np.mean(errors)))


def export_legacy(model, original, source, target, heldout, work, p):
    """Exactly three model-reader files; preserve original evaluation records."""
    import numpy as np
    for camera_id in model.cameras:
        require(np.array_equal(model.cameras[camera_id].params, original.cameras[camera_id].params),
                "SfM changed fixed intrinsics")
    modern = work / "refined-modern"
    modern.mkdir()
    model.write_binary(modern)
    source_records = image_records(source / "sparse/0/images.bin")
    result_records = image_records(modern / "images.bin")
    heldout_ids = {i for i, row in source_records.items() if row[0] in heldout}
    require(not (heldout_ids & set(result_records)), "heldout camera entered SfM")
    for image_id in heldout_ids:
        require(source_records[image_id][2] == 0, "original evaluation camera has point observations")
        result_records[image_id] = source_records[image_id]
    require(set(result_records) == set(source_records), "output image cohort changed")
    sparse = target / "sparse/0"
    sparse.mkdir(parents=True)
    shutil.copyfile(source / "sparse/0/cameras.bin", sparse / "cameras.bin")
    shutil.copyfile(modern / "points3D.bin", sparse / "points3D.bin")
    (sparse / "images.bin").write_bytes(struct.pack("<Q", len(result_records)) +
                                       b"".join(result_records[i][1] for i in sorted(result_records)))
    reloaded = p.Reconstruction(sparse)
    require(reloaded.num_images() == len(source_records) and reloaded.num_points3D() == model.num_points3D(),
            "classic three-file model failed its round trip")
    require(all(element.image_id not in heldout_ids for point in reloaded.points3D.values()
                for element in point.track.elements), "heldout observation leaked into a point track")
    require(all(image_records(sparse / "images.bin")[i][1] == source_records[i][1] for i in heldout_ids),
            "evaluation camera record changed")


def refine(dataset, output):
    p = colmap_module()
    report = validate_dataset(dataset, 500000)
    train, heldout = fixed_split(report["image_sha256"])
    original = p.Reconstruction(dataset / "sparse/0")
    require({image.name for image in original.images.values()} == set(train + heldout), "original model names mismatch")
    require(all(image.name == f"{i:06d}.jpg" for i, image in original.images.items()), "original image IDs mismatch")
    work, target = output / "work", output / "dataset"
    work.mkdir()
    training_images = work / "training-images"
    training_images.mkdir()
    for name in train:
        shutil.copyfile(dataset / "images" / name, training_images / name)
    record = {"status": "running", "profile": PROFILE, "source_adapter_report_sha256": sha256(dataset / "adapter-report.json"),
              "helper_sha256": sha256(__file__), "python_version": platform.python_version(),
              "platform": platform.platform(), "numpy_version": __import__("numpy").__version__,
              "source_model_sha256": report["model_sha256"], "training_images": train,
              "evaluation_images": heldout, "evaluation_pose_records_unchanged": True,
              "heldout_pixels_used_by_sfm": False, "original_arkit_seeds_used": False,
              "qualification": "Same original loss-heldout views/poses. D removes original ARKit seed-color leakage, but ARKit VIO poses are not independently heldout ground truth.",
              "gpu_used": False, "scene_quality_accepted": False}
    record_path = output / "sfm-report.json"
    try:
        write_json(record_path, record)
        model = feature_triangulation(subset_model(original, set(train), p), training_images, work, p, record,
                                      checkpoint=lambda: write_json(record_path, record))
        require(100 <= model.num_points3D() <= 500000, "triangulated point count outside trainer seed limits")
        record["triangulated_points"] = model.num_points3D()
        write_json(record_path, record)
        record["bundle_adjustment"] = pose_prior_ba(model, original, p)
        manager = p.ObservationManager(model)
        record["filtered_observations"] = manager.filter_all_points3D(max_reproj_error=4., min_tri_angle=1.5)
        require(100 <= model.num_points3D() <= 500000, "filtered point count outside trainer seed limits")
        model.extract_colors_for_all_images(training_images, num_threads=4)
        record["final_reprojection_rmse_px"] = reprojection_rmse(model)
        record["final_points"] = model.num_points3D()
        record["final_observations"] = model.compute_num_observations()
        record["observations_by_training_image"] = {str(i): image.num_points3D for i, image in sorted(model.images.items())}
        export_legacy(model, original, dataset, target, set(heldout), work, p)
        (target / "images").mkdir()
        for name in sorted(report["image_sha256"]):
            shutil.copyfile(dataset / "images" / name, target / "images" / name)
        require({name: sha256(target / "images" / name) for name in report["image_sha256"]} == report["image_sha256"],
                "JPEG bytes changed in derived dataset")
        validate_dataset(dataset, 500000)
        derived = {key: report[key] for key in ("format", "schema_version", "gsplat_commit", "session_id", "frames", "world_space", "camera_conversion") if key in report}
        derived.update(initial_points=model.num_points3D(), point_observations=model.compute_num_observations(),
                       image_sha256=report["image_sha256"], model_sha256={name: sha256(target / "sparse/0" / name) for name in MODEL_FILES},
                       gpu_training_performed=False, reprojection_error_measured=True,
                       initialization="Official COLMAP SIFT correspondences, triangulation and fixed-intrinsics camera-position-prior bundle adjustment on 133 training images only.",
                       sfm_profile=PROFILE, sfm_provenance="../sfm-report.json", evaluation_images=heldout,
                       evaluation_camera_records="Byte-identical originals; zero observations; excluded from SfM and point colors.")
        write_json(target / "adapter-report.pending.json", derived)
        record["status"] = "prepared_pending_supervisor"
    except BaseException as exc:
        record.update(status="failed", error=str(exc))
        raise
    finally:
        write_json(record_path, record)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="new private directory outside the original dataset")
    parser.add_argument("--max-seconds", type=int, default=1800)
    parser.add_argument("--execute", action="store_true", help="run the CPU experiment; otherwise only validate and print its plan")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        require(1 <= args.max_seconds <= 1800, "D1 wall-clock ceiling must be 1–1800 seconds")
        dataset, output = args.dataset.resolve(), args.output.resolve()
        require(not output.is_relative_to(dataset) and not dataset.is_relative_to(output), "output and original dataset must be disjoint")
        if args.worker:
            require(args.execute and output.is_dir(), "worker requires a supervisor-created output directory")
            refine(dataset, output)
            return 0
        require(not output.exists(), "output exists; choose a new directory")
        colmap_module()
        source = validate_dataset(dataset, 500000)
        train, heldout = fixed_split(source["image_sha256"])
        plan = {"profile": PROFILE, "max_seconds": args.max_seconds, "training_frames": len(train),
                "evaluation_frames": len(heldout), "evaluation_images": heldout, "execute": args.execute}
        print(json.dumps(plan, indent=2), flush=True)
        if not args.execute:
            return 0
        output.mkdir(parents=True, mode=0o700)
        run = {**plan, "status": "running"}
        started = time.monotonic()
        try:
            environment = dict(os.environ)
            environment.update({key: "4" for key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS")})
            environment.update(CUDA_VISIBLE_DEVICES="", PYTHONUNBUFFERED="1")
            command = [sys.executable, str(Path(__file__).resolve()), "--dataset", str(dataset),
                       "--output", str(output), "--execute", "--worker"]
            with (output / "sfm.log").open("x") as log:
                code, _ = bounded_process(command, args.max_seconds, env=environment, stdout=log)
            require(code == 0, f"SfM worker exited {code}; see sfm.log")
            pending = output / "dataset/adapter-report.pending.json"
            pending.rename(output / "dataset/adapter-report.json")
            validate_dataset(output / "dataset", 500000)
            validate_dataset(dataset, 500000)
            prepared = read_json(output / "sfm-report.json")
            prepared["status"] = "prepared"
            write_json(output / "sfm-report.json", prepared)
            run["status"] = "prepared"
        except BaseException as exc:
            (output / "dataset/adapter-report.json").unlink(missing_ok=True)
            run.update(status="failed", error=str(exc))
            raise
        finally:
            run["elapsed_seconds"] = time.monotonic() - started
            write_json(output / "sfm-run.json", run)
        return 0
    except (CaptureError, OSError, ImportError, RuntimeError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
