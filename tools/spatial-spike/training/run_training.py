#!/usr/bin/env python3
"""Bounded manual Linux/CUDA gsplat invocation; no GPU provisioning or uploads."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from prepare_capture import CaptureError, GSPLAT_COMMIT, read_json, require


def training_command(python, gsplat, dataset, output, max_steps, max_gaussians):
    require(1 <= max_steps <= 7000, "max_steps must be 1–7000")
    require(100 <= max_gaussians <= 500000, "max_gaussians must be 100–500000")
    # Fields exist in v1.5.3 Config and MCMCStrategy. DefaultStrategy has no
    # gaussian cap; MCMC is selected deliberately to bound this experiment.
    return [str(python), str(Path(gsplat) / "examples/simple_trainer.py"), "mcmc",
            "--data-dir", str(dataset), "--data-factor", "1", "--result-dir", str(output),
            "--init-type", "sfm", "--no-normalize-world-space", "--no-pose-opt",
            "--disable-viewer", "--disable-video", "--save-ply", "--packed",
            "--max-steps", str(max_steps), "--eval-steps", str(max_steps),
            "--save-steps", str(max_steps), "--ply-steps", str(max_steps),
            "--strategy.cap-max", str(max_gaussians)]


def bounded_process(command, timeout, *, cwd=None, env=None, stdout=None):
    require(0 < timeout <= 1800, "wall-clock ceiling must be positive and at most 1800 seconds")
    started = time.monotonic()
    process = None
    handlers = {}

    def interrupted(signum, _frame):
        raise CaptureError(f"training supervisor interrupted by signal {signum}")

    def stop_group():
        if process is None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # The leader may exit on TERM while a GPU worker ignores it. Escalate
        # against the SAME owned group even when process.wait() already returned.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)

    try:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            handlers[signum] = signal.signal(signum, interrupted)
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stdout,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        return process.wait(timeout=timeout), time.monotonic() - started
    except subprocess.TimeoutExpired:
        # Stop the whole group, including worker children. Keep partial outputs
        # for diagnosis but never write a success record for a timed-out run.
        stop_group()
        raise CaptureError(f"training exceeded {timeout}s wall-clock ceiling")
    except BaseException:
        stop_group()
        raise
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)


def validate_dataset(dataset, max_gaussians):
    dataset = Path(dataset).resolve()
    report = read_json(dataset / "adapter-report.json")
    require(report.get("format") == "rendprop-posed-gsplat-dataset" and report.get("schema_version") == 1,
            "dataset requires a completed adapter report")
    require(report.get("gsplat_commit") == GSPLAT_COMMIT, "dataset trainer pin mismatch")
    require(type(report.get("initial_points")) is int and 100 <= report["initial_points"] <= max_gaussians,
            "seed count must be at least 100 and cannot exceed gaussian ceiling")
    images, models = report.get("image_sha256"), report.get("model_sha256")
    require(isinstance(images, dict) and len(images) >= 20, "dataset requires image checksums")
    require(isinstance(models, dict) and set(models) == {"cameras.bin", "images.bin", "points3D.bin"},
            "dataset requires all binary model checksums")
    for directory, entries in ((dataset / "images", images), (dataset / "sparse/0", models)):
        require(set(p.name for p in directory.iterdir()) == set(entries), "dataset contains missing/extra files")
        for name, checksum in entries.items():
            path = (directory / name).resolve()
            require(Path(name).name == name and path.is_relative_to(dataset), "unsafe dataset checksum path")
            require(hashlib.sha256(path.read_bytes()).hexdigest() == checksum, f"dataset changed: {name}")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gsplat-dir", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="must not exist")
    parser.add_argument("--max-seconds", type=int, default=900)
    parser.add_argument("--max-steps", type=int, default=3000)
    parser.add_argument("--max-gaussians", type=int, default=500000)
    args = parser.parse_args()
    try:
        gsplat, dataset, output = args.gsplat_dir.resolve(), args.dataset.resolve(), args.output.resolve()
        require(sys.platform == "linux", "the pinned GPU runner requires Linux with NVIDIA CUDA")
        require(1 <= args.max_seconds <= 1800, "max_seconds must be 1–1800")
        command = training_command(sys.executable, gsplat, dataset, output, args.max_steps, args.max_gaussians)
        report = validate_dataset(dataset, args.max_gaussians)
        head = subprocess.check_output(["git", "-C", str(gsplat), "rev-parse", "HEAD"], text=True).strip()
        require(head == GSPLAT_COMMIT, "gsplat checkout does not match the pinned commit")
        require(not subprocess.check_output(["git", "-C", str(gsplat), "status", "--porcelain", "--untracked-files=no"],
                                            text=True).strip(), "gsplat checkout has tracked edits")
        require(not output.exists(), "output exists; choose a new directory")
        require(not output.is_relative_to(dataset) and not output.is_relative_to(gsplat),
                "output must be outside dataset and gsplat checkout")
        import torch
        import gsplat as installed_gsplat
        require(Path(installed_gsplat.__file__).resolve().is_relative_to(gsplat),
                "installed gsplat must come from the pinned checkout (pip install -e)")
        require(torch.cuda.is_available() and torch.version.cuda is not None,
                "CUDA unavailable: CPU or Apple Metal does not verify this trainer")
        # Force exactly one selected GPU to keep caps and report semantics simple.
        environment = dict(os.environ)
        require("," not in environment.get("CUDA_VISIBLE_DEVICES", "0"), "select exactly one CUDA GPU")
        environment.setdefault("CUDA_VISIBLE_DEVICES", "0")
        environment["PYTHONUNBUFFERED"] = "1"
        output.mkdir(parents=True)
        metadata = {"status": "running", "gsplat_commit": GSPLAT_COMMIT, "command": command,
                    "frames": report["frames"], "initial_points": report["initial_points"],
                    "gpu": torch.cuda.get_device_name(0), "torch_version": torch.__version__,
                    "gpu_total_vram_bytes": torch.cuda.get_device_properties(0).total_memory,
                    "cuda_version": torch.version.cuda, "max_seconds": args.max_seconds,
                    "max_steps": args.max_steps, "max_gaussians": args.max_gaussians,
                    "world_normalization": False, "pose_optimization": False,
                    "resolved_dependencies": sorted(f"{dist.metadata['Name']}=={dist.version}"
                                                    for dist in importlib.metadata.distributions())}
        (output / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
        try:
            with (output / "training.log").open("x") as log:
                code, seconds = bounded_process(command, args.max_seconds, cwd=gsplat, env=environment, stdout=log)
            require(code == 0, f"trainer exited {code}; see training.log")
            ply = output / "ply" / f"point_cloud_{args.max_steps-1}.ply"
            require(ply.is_file() and ply.stat().st_size > 100, "trainer produced no nonempty PLY")
            stats = read_json(output / "stats" / f"train_step{args.max_steps-1:04d}_rank0.json")
            require(type(stats.get("num_GS")) is int and 0 < stats["num_GS"] <= args.max_gaussians,
                    "final gaussian count missing or exceeds ceiling")
            metadata.update(status="trained", elapsed_seconds=seconds, training_minutes=seconds/60,
                            ply=str(ply), ply_bytes=ply.stat().st_size, gaussian_count=stats["num_GS"],
                            ply_sha256=hashlib.sha256(ply.read_bytes()).hexdigest(),
                            peak_allocated_vram_gib=stats.get("mem"),
                            phone_browser_fps=None, sog_bytes=None,
                            phase_a_acceptance_complete=False)
        except BaseException as exc:
            metadata.update(status="failed", error=str(exc))
            raise
        finally:
            (output / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
        print(json.dumps(metadata, indent=2))
        return 0
    except (CaptureError, OSError, ImportError, subprocess.SubprocessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
