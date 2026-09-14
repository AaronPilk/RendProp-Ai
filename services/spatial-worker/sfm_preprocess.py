"""PROVISIONAL, unreferenced production SfM stage. No scheduler or provider API.

Only orchestration/cohort handling lives here. Geometry, fixed calibration,
position priors and legacy export use the frozen manual D helper unchanged.
Call preprocess() from the existing job TemporaryDirectory and Lease only after
quality acceptance and a measured whole-job resource/deadline budget.
"""
from __future__ import annotations

import argparse
from contextlib import closing
import os
from pathlib import Path
import platform
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time

TRAINING_ROOT = Path(__file__).resolve().parents[2] / "tools/spatial-spike/training"
if str(TRAINING_ROOT) not in sys.path:
    sys.path.insert(0, str(TRAINING_ROOT))
import refine_sfm as frozen

MAX_SECONDS = 1800
POLL_SECONDS = 0.1
STOP_GRACE_SECONDS = 2
COHORT_PROFILE = "production-sfm-provisional-20-400-v1"


class SfmFailure(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(ok, code):
    if not ok:
        raise SfmFailure(code)


def split_images(image_names):
    names = sorted(image_names)
    require(20 <= len(names) <= 400 and names == [f"{i:06d}.jpg" for i in range(1, len(names) + 1)],
            "sfm_invalid_capture_cohort")
    heldout = names[::8]
    return [name for index, name in enumerate(names) if index % 8], heldout


def profile():
    return {"name": COHORT_PROFILE, "provisional": True,
            "cohort": {"min_frames": 20, "max_frames": 400, "test_every": 8},
            "algorithm": frozen.PROFILE,
            "frozen_helper_sha256": frozen.sha256(frozen.__file__),
            "entrypoint_sha256": frozen.sha256(__file__)}


def verification_counts(database):
    """COLMAP stores failed zero-inlier verification results as table rows too."""
    uri = Path(database).resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True)) as connection:
        total, positive = connection.execute(
            'SELECT COUNT(*), COALESCE(SUM("rows" > 0), 0) FROM two_view_geometries').fetchone()
    return {"verification_row_count": total, "pairs_with_inliers": positive}


def report_snapshot(record, database):
    # The frozen helper still needs its historical key internally. Sanitize a
    # copy for interim checkpoints without changing that helper's execution.
    snapshot = dict(record)
    if "verified_pairs" in snapshot:
        snapshot.pop("verified_pairs")
        snapshot.update(verification_counts(database))
    return snapshot


def child_environment(python, scratch):
    """An allowlist built from nothing; no controller credentials or user config."""
    python, scratch = Path(python).absolute(), Path(scratch).resolve()
    require(python.is_file() and scratch.is_dir(), "sfm_invalid_process_environment")
    environment = {"PATH": str(python.parent) + os.pathsep + os.defpath,
                   "TMPDIR": str(scratch), "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                   "PYTHONUNBUFFERED": "1", "PYTHONUTF8": "1", "CUDA_VISIBLE_DEVICES": "",
                   "LANG": "C", "LC_ALL": "C"}
    environment.update({name: "4" for name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS")})
    return environment


def owned_process(command, timeout, *, environment, logfile, check=lambda: None, on_abort=lambda callback: None):
    """Bound one child group; on_abort registers then clears its cancellation hook.

    Intended lease wiring: check=lease.check and
    on_abort=lambda callback: setattr(lease, 'abort', callback). This stage runs
    before provider allocation, so its cleared hook never replaces a GPU hook.
    Cancellation is safe from the heartbeat thread, including before Popen.
    """
    require(type(timeout) in (int, float) and 0 < timeout <= MAX_SECONDS, "sfm_invalid_timeout")
    cancelled, lock = threading.Event(), threading.Lock()
    process = None
    stopped = False

    def stop_group():
        nonlocal stopped
        if process is None or stopped:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=STOP_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            pass
        # The leader can exit while an ignoring grandchild still owns the group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=STOP_GRACE_SECONDS)
        stopped = True

    def abort():
        cancelled.set()
        with lock:
            stop_group()

    started = time.monotonic()
    try:
        on_abort(abort)
        check()
        with logfile.open("xb", buffering=0) as log:
            with lock:
                require(not cancelled.is_set(), "sfm_cancelled")
                process = subprocess.Popen(command, env=environment, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
            while True:
                check()
                require(not cancelled.is_set(), "sfm_cancelled")
                require(time.monotonic() - started < timeout, "sfm_timeout")
                code = process.poll()
                if code is not None:
                    require(code == 0, "sfm_child_failed")
                    return time.monotonic() - started
                cancelled.wait(POLL_SECONDS)
    finally:
        try:
            with lock:
                stop_group()
        finally:
            on_abort(lambda: None)


def refine_dataset(dataset, output):
    """Child-only geometry execution, with no original dataset or pose mutation."""
    p = frozen.colmap_module()
    original_report = frozen.validate_dataset(dataset, 500000)
    train, heldout = split_images(original_report["image_sha256"])
    require(type(original_report.get("frames")) is int and original_report["frames"] == len(train) + len(heldout),
            "sfm_frame_count_mismatch")
    original = p.Reconstruction(dataset / "sparse/0")
    require(set(original.images) == set(range(1, original_report["frames"] + 1)) and
            all(image.name == f"{i:06d}.jpg" for i, image in original.images.items()), "sfm_model_cohort_mismatch")
    work, target = output / "work", output / "dataset"
    work.mkdir()
    images = work / "training-images"
    images.mkdir()
    for name in train:
        shutil.copyfile(dataset / "images" / name, images / name)
    record = {"status": "running", "profile": profile(), "training_images": train,
              "python_version": platform.python_version(), "platform": platform.platform(),
              "numpy_version": __import__("numpy").__version__,
              "evaluation_images": heldout, "source_adapter_report_sha256": frozen.sha256(dataset / "adapter-report.json"),
              "source_model_sha256": original_report["model_sha256"], "original_arkit_seeds_used": False,
              "heldout_pixels_used_by_sfm": False, "evaluation_pose_records_unchanged": True,
              "gpu_used": False, "scene_quality_accepted": False,
              "qualification": "Loss-heldout original cameras; ARKit VIO poses are not independent ground truth."}
    receipt = output / "sfm-report.json"
    save = lambda: frozen.write_json(receipt, report_snapshot(record, work / "features.db"))
    try:
        save()
        model = frozen.feature_triangulation(frozen.subset_model(original, set(train), p), images, work, p, record, save)
        record.pop("verified_pairs", None)
        record.update(verification_counts(work / "features.db"))
        require(100 <= model.num_points3D() <= 500000, "sfm_insufficient_triangulation")
        record["triangulated_points"] = model.num_points3D()
        record["bundle_adjustment"] = frozen.pose_prior_ba(model, original, p)
        record["filtered_observations"] = p.ObservationManager(model).filter_all_points3D(max_reproj_error=4., min_tri_angle=1.5)
        require(100 <= model.num_points3D() <= 500000, "sfm_insufficient_filtered_points")
        model.extract_colors_for_all_images(images, num_threads=4)
        record.update(final_reprojection_rmse_px=frozen.reprojection_rmse(model), final_points=model.num_points3D(),
                      final_observations=model.compute_num_observations(),
                      observations_by_training_image={str(i): image.num_points3D for i, image in sorted(model.images.items())})
        frozen.export_legacy(model, original, dataset, target, set(heldout), work, p)
        (target / "images").mkdir()
        for name in sorted(original_report["image_sha256"]):
            shutil.copyfile(dataset / "images" / name, target / "images" / name)
        require({name: frozen.sha256(target / "images" / name) for name in original_report["image_sha256"]}
                == original_report["image_sha256"], "sfm_image_bytes_changed")
        frozen.validate_dataset(dataset, 500000)
        derived = {key: original_report[key] for key in ("format", "schema_version", "gsplat_commit",
            "session_id", "frames", "world_space", "camera_conversion") if key in original_report}
        derived.update(initial_points=model.num_points3D(), point_observations=model.compute_num_observations(),
            image_sha256=original_report["image_sha256"],
            model_sha256={name: frozen.sha256(target / "sparse/0" / name) for name in frozen.MODEL_FILES},
            gpu_training_performed=False, reprojection_error_measured=True, sfm_profile=record["profile"],
            sfm_provenance="../sfm-report.json", evaluation_images=heldout,
            initialization=f"Frozen D1 COLMAP SIFT/triangulation/position-prior BA using only {len(train)} training images.",
            evaluation_camera_records="Byte-identical originals; excluded from SfM observations and point colors.")
        frozen.write_json(target / "adapter-report.pending.json", derived)
        record["status"] = "prepared_pending_supervisor"
    except BaseException as error:
        record.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        save()


def preprocess(dataset, output, *, python, max_seconds=1800, check=lambda: None, on_abort=lambda callback: None):
    """Return a new validated dataset; never publish, allocate, or retry.

    max_seconds must come from the remaining WHOLE-JOB deadline budget, including
    setup/training/conversion/upload margins. 1800 is a ceiling, not a new lease.
    python must name the separately built official pycolmap 4.2.0 venv executable.
    """
    require(type(max_seconds) is int and 1 <= max_seconds <= MAX_SECONDS, "sfm_invalid_timeout")
    dataset, output = Path(dataset).resolve(), Path(output).resolve()
    require(not output.exists() and output.parent.is_dir(), "sfm_output_must_be_new")
    require(not output.is_relative_to(dataset) and not dataset.is_relative_to(output), "sfm_output_overlaps_input")
    check()
    source = frozen.validate_dataset(dataset, 500000)
    source_hash = frozen.sha256(dataset / "adapter-report.json")
    train, heldout = split_images(source["image_sha256"])
    require(type(source.get("frames")) is int and source["frames"] == len(train) + len(heldout), "sfm_frame_count_mismatch")
    output.mkdir(mode=0o700)
    scratch = output / "tmp"
    scratch.mkdir(mode=0o700)
    record = {"status": "running", "profile": profile(), "max_seconds": max_seconds,
              "source_adapter_report_sha256": source_hash, "source_model_sha256": source["model_sha256"],
              "training_frames": len(train), "evaluation_frames": len(heldout), "evaluation_images": heldout,
              "execute": True, "automatic_retries": 0}
    started = time.monotonic()
    marker = output / "dataset/adapter-report.json"
    try:
        frozen.write_json(output / "sfm-run.json", record)
        command = [str(Path(python).absolute()), str(Path(__file__).resolve()), "--worker",
                   "--dataset", str(dataset), "--output", str(output)]
        owned_process(command, max_seconds, environment=child_environment(python, scratch),
                      logfile=output / "sfm.log", check=check, on_abort=on_abort)
        check()
        (output / "dataset/adapter-report.pending.json").rename(marker)
        derived = frozen.validate_dataset(output / "dataset", 500000)
        require(frozen.validate_dataset(dataset, 500000) == source and
                frozen.sha256(dataset / "adapter-report.json") == source_hash, "sfm_input_changed")
        require(derived["image_sha256"] == source["image_sha256"] and
                derived["frames"] == source["frames"] and derived["evaluation_images"] == heldout and
                derived["sfm_profile"] == record["profile"], "sfm_output_protocol_changed")
        check()
        report = frozen.read_json(output / "sfm-report.json")
        require(report["profile"] == record["profile"], "sfm_source_changed")
        require(report["status"] == "prepared_pending_supervisor" and
                report["source_adapter_report_sha256"] == source_hash and
                report["source_model_sha256"] == source["model_sha256"], "sfm_provenance_changed")
        report["status"] = "prepared"
        frozen.write_json(output / "sfm-report.json", report)
        record["status"] = "prepared"
        return output / "dataset"
    except BaseException as error:
        marker.unlink(missing_ok=True)
        record.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        record["elapsed_seconds"] = time.monotonic() - started
        frozen.write_json(output / "sfm-run.json", record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(args.worker and args.output.is_dir(), "sfm_requires_supervisor")
    os.umask(0o077)
    refine_dataset(args.dataset.resolve(), args.output.resolve())


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
