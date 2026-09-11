#!/usr/bin/env python3
"""One owner-authorized room, one ephemeral Modal GPU, durable local receipts.

Not a production reconstruction service. No automatic rental/retry, no volumes,
no snapshots, no public endpoint, and no implicit collection of a capture root.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta
from decimal import Decimal
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
import uuid

IMAGE = "pytorch/pytorch@sha256:3d614dfd422b7e43647491cbf07d6acc516c032fc49c594a94afdebd52552fb9"
APP_NAME = "rendprop-private-room-proof-20260910"
REMOTE = "/opt/room-experiment"
PROFILE = "rendprop-room-experiment"
MAX_DOWNLOAD = 512 * 1024 * 1024
MAX_DATASET = 2 * 1024**3
SOURCE_FILES = ("run_training.py", "prepare_capture.py", "modal_setup.sh")


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def policy():
    # Published September10 rates. CPU/RAM use Sandbox rates, NOT the cheaper
    # Function rates. The 1.15 multiplier is for the broad US region. This is
    # a conservative full-lifetime compute bound, never the actual invoice.
    seconds = 7200
    compute = (Decimal("0.000222") + 4 * Decimal("0.00003942")
               + 32 * Decimal("0.00000667")) * seconds * Decimal("1.15")
    require(compute < Decimal("25"), "published compute bound exceeds approval")
    return {"gpu": "L4", "gpu_count": 1, "gpu_vram_class_gb": 24,
            "timeout_seconds": seconds, "cpu_request_and_limit": 4,
            "memory_request_and_limit_mib": 32768, "region": "us",
            "compute_upper_bound_usd": str(compute), "approval_total_usd": "25.00",
            "automatic_rent_retries": 0, "persistent_volumes": False,
            "image": IMAGE, "egress_charge_september_2026": "0",
            "actual_charge_usd": None}


def inventory(dataset):
    """Only adapter output, never sidecars/provenance/source-capture siblings."""
    require(not dataset.is_symlink(), "dataset root is a symlink")
    dataset = dataset.resolve(strict=True)
    report_path = dataset / "adapter-report.json"
    require(report_path.is_file() and not report_path.is_symlink(), "missing regular adapter report")
    require(report_path.stat().st_size <= 1024 * 1024, "oversized adapter report")
    report = json.loads(report_path.read_text())
    require(report.get("format") == "rendprop-posed-gsplat-dataset", "not an adapter dataset")
    require(report.get("schema_version") == 1, "wrong dataset schema")
    require(report.get("gsplat_commit") == "937e29912570c372bed6747a5c9bf85fed877bae", "wrong trainer pin")
    require(type(report.get("frames")) is int and 20 <= report["frames"] <= 400, "invalid frame count")
    require(type(report.get("initial_points")) is int and 100 <= report["initial_points"] <= 500000,
            "invalid seed count")
    images, models = report.get("image_sha256"), report.get("model_sha256")
    require(isinstance(images, dict) and len(images) == report["frames"], "image inventory mismatch")
    require(isinstance(models, dict) and set(models) == {"cameras.bin", "images.bin", "points3D.bin"},
            "model inventory mismatch")
    result = []
    for prefix, entries in (("images", images), ("sparse/0", models)):
        directory = dataset / prefix
        require(not directory.is_symlink() and not directory.parent.is_symlink(), "linked dataset directory")
        require(set(p.name for p in directory.iterdir()) == set(entries), "extra or missing dataset files")
        for name, digest in sorted(entries.items()):
            require(name == Path(name).name and name not in (".", ".."), "unsafe file name")
            path = directory / name
            require(not path.is_symlink() and stat.S_ISREG(path.stat().st_mode), "nonregular dataset file")
            require(path.resolve().is_relative_to(dataset), "dataset file escaped root")
            require(sha(path) == digest, "dataset checksum mismatch")
            result.append({"path": f"{prefix}/{name}", "bytes": path.stat().st_size, "sha256": digest})
    result.append({"path": "adapter-report.json", "bytes": report_path.stat().st_size,
                   "sha256": sha(report_path)})
    require(sum(item["bytes"] for item in result) <= MAX_DATASET, "dataset exceeds transfer ceiling")
    return result


def save(path, value):
    temp = path.with_name(path.name + ".next")
    with temp.open("w") as out:
        json.dump(value, out, indent=2)
        out.write("\n")
        out.flush()
        os.fsync(out.fileno())
    os.chmod(temp, 0o600)
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def record(path, receipt, phase, **fields):
    receipt.update(fields)
    receipt["phase"] = phase
    receipt.setdefault("events", []).append({"phase": phase, "utc": datetime.now(timezone.utc).isoformat()})
    save(path, receipt)
    print(phase, flush=True)


def create_options(modal, app, receipt):
    return {"app": app, "name": receipt["sandbox_name"], "image": modal.Image.from_registry(IMAGE),
            "gpu": "L4", "cpu": (4.0, 4.0), "memory": (32768, 32768),
            "timeout": 7200, "region": "us", "volumes": {}, "secrets": [],
            "encrypted_ports": [], "unencrypted_ports": [], "h2_ports": [],
            "env": {"MAX_JOBS": "4", "OMP_NUM_THREADS": "4", "CUDA_VISIBLE_DEVICES": "0"},
            "tags": {"experiment": "rendprop-one-room-20260910", "run": receipt["run_id"]}}


def cleanup(sb, receipt_path, receipt):
    # This exact path is created only in this exact ephemeral sandbox. The user
    # authorized removal of the remote experiment, not any production objects.
    failures = []
    handlers = {}
    # Once cleanup starts, repeated user cancellation must not skip termination.
    # SIGKILL/process loss still needs the independently enforced provider TTL.
    def interrupted(signum, _frame):
        failures.append(f"signal_{signum}")
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        handlers[signum] = signal.signal(signum, interrupted)
    try:
        try:
            sb.filesystem.remove(REMOTE, recursive=True)
            receipt["remote_copy_delete"] = {"path": REMOTE, "response": "success"}
        except BaseException as exc:
            receipt["remote_copy_delete"] = {"path": REMOTE, "response": "failed", "error_type": type(exc).__name__}
            failures.append("remote_copy_delete")
        finally:
            try:
                result = sb.terminate(wait=True)
                ended = sb.poll()
                require(ended is not None, "provider still reports running")
                receipt["terminate"] = {"call": "Sandbox.terminate(wait=True)", "response": result,
                                        "poll_exit_code": ended, "sandbox_id": sb.object_id}
                record(receipt_path, receipt, "terminated")
            except BaseException as exc:
                receipt["terminate"] = {"call": "Sandbox.terminate(wait=True)", "error_type": type(exc).__name__}
                failures.append("terminate")
                record(receipt_path, receipt, "cleanup_incomplete")
    finally:
        try:
            sb.detach()
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
    require(not failures, "cleanup requires follow-up: " + ",".join(failures))


def exec_to_log(sb, argv, timeout, logfile):
    process = sb.exec(*argv, timeout=timeout, text=True)
    # Drain both streams concurrently, without printing remote data or error
    # payloads into chat. These logs are local, private, and outside Git.
    pool = ThreadPoolExecutor(max_workers=2)
    completed = False
    try:
        out = pool.submit(process.stdout.read)
        err = pool.submit(process.stderr.read)
        code = process.wait()
        logfile.write_text(out.result() + err.result())
        completed = True
    finally:
        # On interruption, don't wait for a stalled read before reaching the
        # caller's provider termination. Termination closes those remote streams.
        pool.shutdown(wait=completed, cancel_futures=True)
    require(code == 0, f"remote stage failed (exit {code}); inspect private stage log")


def collect(sb, target):
    """Copy only final artifact, diagnostics and held-out renders, not checkpoints."""
    allowed = ("result/run.json", "result/training.log", "result/ply/point_cloud_2999.ply",
               "resolved-setup.txt")
    names = list(allowed)
    for directory in ("result/stats", "result/renders"):
        for info in sb.filesystem.list_files(f"{REMOTE}/{directory}"):
            name = Path(info.name).name
            require(name == info.name or info.name == f"{REMOTE}/{directory}/{name}", "unexpected remote filename")
            if name.endswith((".json", ".png")):
                names.append(f"{directory}/{name}")
    entries = []
    for name in names:
        size = sb.filesystem.stat(f"{REMOTE}/{name}").size
        require(type(size) is int and 0 <= size <= MAX_DOWNLOAD, "invalid output size")
        entries.append((name, size))
    require(sum(size for _, size in entries) <= MAX_DOWNLOAD, "output collection exceeds 512MiB")
    results = []
    for name, size in entries:
        local = target / name
        require(not local.exists(), "refusing to overwrite collected output")
        sb.filesystem.copy_to_local(f"{REMOTE}/{name}", local)
        os.chmod(local, 0o600)
        require(local.stat().st_size == size, "output size changed during collection")
        results.append({"path": name, "bytes": size, "sha256": sha(local)})
    return results


def source_binding():
    source = Path(__file__).resolve().parent
    repo = source.parents[2]
    require(not subprocess.check_output(["git", "-C", str(repo), "status", "--porcelain"], text=True).strip(),
            "source must be committed and clean before rental")
    return {"commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
            "files": {name: sha(source / name) for name in (*SOURCE_FILES, "modal_room.py")}}


def run(modal, dataset, state):
    require(not state.exists(), "experiment state exists; never silently rent again")
    require(state.parent.is_dir() and not state.parent.is_symlink(), "private state parent required")
    files = inventory(dataset)
    binding = source_binding()
    require(not state.resolve().is_relative_to(dataset.resolve()), "state cannot modify dataset")
    state.mkdir(mode=0o700)
    receipt_path = state / "provider-receipt.json"
    receipt = {"schema_version": 1, "run_id": str(uuid.uuid4()), "policy": policy(), "source": binding,
               "dataset_files": files, "transferred_files": [], "phase_a_acceptance_complete": False,
               "actual_charge_usd": None, "billing_status": "not_yet_measured"}
    receipt["sandbox_name"] = "room-proof-" + receipt["run_id"]
    record(receipt_path, receipt, "namespace_lookup_started")
    # The provider lifetime is in the creation request BEFORE setup/training.
    # A lost create response must never trigger a second rental automatically.
    sb = None
    creation_attempted = False
    try:
        app = modal.App.lookup(APP_NAME, create_if_missing=True)
        require(isinstance(app.app_id, str) and app.app_id.startswith("ap-"), "invalid experiment app ID")
        record(receipt_path, receipt, "creation_started", app_id=app.app_id)
        creation_attempted = True
        sb = modal.Sandbox.create(**create_options(modal, app, receipt))
        record(receipt_path, receipt, "allocated", sandbox_id=sb.object_id)
        sb.filesystem.make_directory(REMOTE)
        source = Path(__file__).parent
        for name in SOURCE_FILES:
            sb.filesystem.copy_from_local(source / name, f"{REMOTE}/{name}")
        record(receipt_path, receipt, "setup_started")
        exec_to_log(sb, ["bash", f"{REMOTE}/modal_setup.sh"], 1800, state / "setup.log")
        # Dataset bytes are not present until public dependency setup succeeds.
        sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=[], outbound_domain_allowlist=[])
        record(receipt_path, receipt, "outbound_denied")
        for item in files:
            local = dataset / item["path"]
            require(sha(local) == item["sha256"], "dataset changed before transfer")
            sb.filesystem.copy_from_local(local, f"{REMOTE}/dataset/{item['path']}")
            receipt["transferred_files"].append(item["path"])
            save(receipt_path, receipt)
        record(receipt_path, receipt, "training_started")
        command = ["python", f"{REMOTE}/run_training.py", "--gsplat-dir", "/opt/gsplat-phase-a",
                   "--dataset", f"{REMOTE}/dataset", "--output", f"{REMOTE}/result",
                   "--max-seconds", "900", "--max-steps", "3000", "--max-gaussians", "500000"]
        receipt["training_command"] = command
        save(receipt_path, receipt)
        exec_to_log(sb, command, 1000, state / "wrapper.log")
        # wrapper stdout is already local; do not require a nonexistent remote log.
        artifacts = collect(sb, state / "download")
        record(receipt_path, receipt, "artifacts_collected", artifacts=artifacts, outcome="trained")
    except BaseException as exc:
        record(receipt_path, receipt, "failed", failure_type=type(exc).__name__, outcome="failed")
        if sb is None and creation_attempted:
            # Reconciliation uses the unique provider name; it is lookup only.
            try:
                sb = modal.Sandbox.from_name(APP_NAME, receipt["sandbox_name"])
                receipt["sandbox_id"] = sb.object_id
            except Exception:
                record(receipt_path, receipt, "allocation_unresolved_no_retry")
        if sb is not None:
            # Preserve bounded diagnostics on a failed run without retrying it.
            for name in ("result/run.json", "result/training.log", "resolved-setup.txt"):
                try:
                    if sb.filesystem.stat(f"{REMOTE}/{name}").size <= 8 * 1024**2:
                        sb.filesystem.copy_to_local(f"{REMOTE}/{name}", state / "failed" / name)
                except Exception:
                    pass
        raise
    finally:
        if sb is not None:
            cleanup(sb, receipt_path, receipt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run", "cleanup"))
    parser.add_argument("--dataset", type=Path)
    parser.add_argument("--state", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "plan":
        print(json.dumps(policy(), indent=2))
        return 0
    require(args.state is not None, "--state is required")
    private_root = Path.home() / "LocalSpatialExperiments"
    require(not args.state.is_symlink() and args.state.resolve().is_relative_to(private_root.resolve()),
            "state must remain inside LocalSpatialExperiments")
    # One lock for this one approval, shared even across different state paths.
    lock = private_root / "room-approval-20260910.lock"
    with lock.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ["MODAL_PROFILE"] = PROFILE
        import modal
        require(modal.__version__ == "1.5.3", "use pinned Modal SDK1.5.3")
        if args.command == "cleanup":
            path = args.state / "provider-receipt.json"
            receipt = json.loads(path.read_text())
            require(receipt["policy"] == policy(), "receipt policy mismatch")
            sb = modal.Sandbox.from_id(receipt["sandbox_id"])
            cleanup(sb, path, receipt)
        else:
            require(args.dataset is not None, "--dataset is required")
            marker = lock.with_suffix(".allocation.json")
            require(not marker.exists(), "this approval already attempted rental; reconcile before any further spend")
            save(marker, {"state": str(args.state.resolve()), "status": "rental_attempt_reserved",
                          "reserved_usd": "25.00", "utc": datetime.now(timezone.utc).isoformat()})
            run(modal, args.dataset, args.state)
    return 0


if __name__ == "__main__":
    def request_cleanup(signum, _frame):
        raise InterruptedError(f"experiment interrupted by signal {signum}")
    for experiment_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(experiment_signal, request_cleanup)
    try:
        sys.exit(main())
    except Exception as exc:
        # Do not echo raw SDK error payloads/headers or paths containing tokens.
        print(f"FAIL: {type(exc).__name__}; inspect private receipt/logs", file=sys.stderr)
        sys.exit(1)
