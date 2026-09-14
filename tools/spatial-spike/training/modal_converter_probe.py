#!/usr/bin/env python3
"""Inactive, explicit one-allocation L4 converter validation after ablation D.

Default `plan` is local only. `run --confirm-one-allocation` requires the saved
plan, a committed clean checkout, the existing approval lock, reconciled prior
cleanup, and fresh provider terminal checks. It never trains, deploys, enables
a feature or retries an allocation. The original $25 ceiling includes every
ablation marker. The conservative $4.9110336 hold remains compatible with the
existing ablation ledger until a closed-hour provider billing receipt replaces
it, even though this probe's 1800-second priced compute bound is smaller.
"""
import argparse
from datetime import datetime, timezone
from decimal import Decimal
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import uuid

import modal_ablation as ablation
import modal_room as room
from modal_retry import bounded_json, private_path
from converter_probe_remote import validate_sog

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
TTL_SECONDS = 1800
MAX_OUTPUT_BYTES = 32 * 1024**2
PUBLIC_FILES = {
    "setup_converter_probe.sh": SOURCE / "setup_converter_probe.sh",
    "converter_probe_remote.py": SOURCE / "converter_probe_remote.py",
    "converter/package.json": SOURCE.parent / "viewer/package.json",
    "converter/package-lock.json": SOURCE.parent / "viewer/package-lock.json",
}
EXTRA_SOURCE = (*PUBLIC_FILES.values(), Path(__file__).resolve(),
                SOURCE / "test_modal_converter_probe.py")


def policy():
    result = dict(room.policy())
    result["timeout_seconds"] = TTL_SECONDS
    result["compute_upper_bound_usd"] = str(Decimal(room.policy()["compute_upper_bound_usd"])
                                          * Decimal(TTL_SECONDS) / Decimal(room.policy()["timeout_seconds"]))
    result.update(ledger_reserved_usd=room.policy()["compute_upper_bound_usd"],
                  purpose="converter_validation_only", training_performed=False)
    return result


def source_binding():
    binding = room.source_binding()
    extra = {}
    for path in EXTRA_SOURCE:
        relative = path.relative_to(REPO).as_posix()
        committed = subprocess.check_output(["git", "-C", str(REPO), "show",
                                             f"{binding['commit']}:{relative}"])
        digest = room.sha(path)
        room.require(hashlib.sha256(committed).hexdigest() == digest,
                     "converter source must exactly match its commit")
        extra[relative] = digest
    return {**binding, "converter_files": extra}


def regular_private_file(path):
    resolved = private_path(path)
    root = ablation.PRIVATE_ROOT.resolve()
    current = path.absolute()
    while current != root:
        room.require(not current.is_symlink(), "linked private evidence is not accepted")
        current = current.parent
        room.require(current != current.parent or current == root, "private evidence escaped root")
    room.require(stat.S_ISREG(resolved.stat().st_mode), "regular private evidence required")
    return resolved


def ply_metadata(path):
    room.require(0 < path.stat().st_size <= room.MAX_DOWNLOAD, "invalid private PLY size")
    with path.open("rb") as handle:
        header = bytearray()
        while len(header) < 65536:
            line = handle.readline(4096)
            room.require(line and len(line) < 4096, "invalid PLY header")
            header.extend(line)
            if line == b"end_header\n":
                break
        else:
            raise ValueError("oversized PLY header")
    lines = header.decode("ascii").splitlines()
    room.require(lines[:2] == ["ply", "format binary_little_endian 1.0"], "binary trained PLY required")
    elements = [line for line in lines if line.startswith("element ")]
    room.require(len(elements) == 1 and re.fullmatch(r"element vertex [0-9]+", elements[0]),
                 "one vertex element required")
    count = int(elements[0].split()[-1])
    room.require(1 <= count <= 500000, "invalid Gaussian count")
    properties = [line.split() for line in lines if line.startswith("property ")]
    room.require(all(len(item) == 3 and item[1] == "float" for item in properties),
                 "trained PLY must use float properties")
    names = [item[2] for item in properties]
    required = {"x", "y", "z", "opacity", *(f"f_dc_{i}" for i in range(3)),
                *(f"f_rest_{i}" for i in range(45)), *(f"scale_{i}" for i in range(3)),
                *(f"rot_{i}" for i in range(4))}
    room.require(len(names) == len(set(names)) and required <= set(names)
                 and set(names) <= required | {"nx", "ny", "nz"}, "exact three-SH trained PLY required")
    room.require(path.stat().st_size == len(header) + count * len(properties) * 4,
                 "PLY payload size does not match its header")
    return {"bytes": path.stat().st_size, "sha256": room.sha(path),
            "gaussian_count": count, "sh_bands": 3}


def prepare(source_state, label):
    room.require(re.fullmatch(r"converter[0-9]{2}", label or ""), "explicit converterNN label required")
    # Reuse the existing budget and cleanup admission unchanged, including its
    # narrow independently reconciled pre-media A01 infrastructure exception.
    ledger = ablation.prepare(ablation.ORIGINAL_DATASET, "a00")
    predecessors = ledger["predecessors"]
    room.require(any(re.fullmatch(r"spatial-ablation-20260914-d[0-9]{2}\.allocation\.json",
                                 Path(item["marker"]).name) for item in predecessors),
                 "D must exist and have terminal reconciled cleanup before converter validation")
    marker = ablation.PRIVATE_ROOT / f"spatial-ablation-20260914-{label}.allocation.json"
    room.require(not marker.exists(), "converter attempt already reserved; never automatically retry")
    source_state = private_path(source_state)
    receipt_path = regular_private_file(source_state / "provider-receipt.json")
    receipt = bounded_json(receipt_path)
    room.require(any(item["receipt_sha256"] == room.sha(receipt_path)
                     and item["app_id"] == receipt.get("app_id")
                     and item["sandbox_id"] == receipt.get("sandbox_id") for item in predecessors),
                 "source PLY must belong to a reconciled ablation in this ledger")
    room.require(receipt.get("outcome") == "trained", "source must be a completed training output")
    candidates = [item for item in receipt.get("artifacts", [])
                  if re.fullmatch(r"result/ply/point_cloud_[0-9]+\.ply", item.get("path", ""))]
    room.require(len(candidates) == 1, "one receipt-bound final PLY required")
    artifact = candidates[0]
    ply = regular_private_file(source_state / "download" / artifact["path"])
    metadata = ply_metadata(ply)
    room.require(metadata["sha256"] == artifact.get("sha256") and metadata["bytes"] == artifact.get("bytes"),
                 "source PLY differs from original provider receipt")
    reserve = Decimal(room.policy()["compute_upper_bound_usd"])
    held = Decimal(ledger["prior_costs_and_holds_usd"])
    room.require(held.is_finite() and held >= 0 and held + reserve <= Decimal("25.00"),
                 "prior spend plus outstanding holds plus new reserve exceeds $25")
    source = source_binding()
    package = json.loads(PUBLIC_FILES["converter/package.json"].read_text())
    lock = json.loads(PUBLIC_FILES["converter/package-lock.json"].read_text())
    room.require(package.get("dependencies", {}).get("@playcanvas/splat-transform") == "3.4.2"
                 and package["dependencies"].get("playcanvas") == "2.22.1"
                 and lock["packages"]["node_modules/@playcanvas/splat-transform"]["version"] == "3.4.2"
                 and lock["packages"]["node_modules/webgpu"]["version"] == "0.4.0",
                 "reviewed converter dependency pins changed")
    return {"schema_version": 1, "purpose": "converter_validation_only", "label": label,
            "app_name": f"rendprop-spatial-{label}-20260914", "source_state": str(source_state),
            "source_receipt_sha256": room.sha(receipt_path), "input_ply": str(ply), "input": metadata,
            "source": source, "policy": policy(), "allocation_count": 1, "automatic_retries": 0,
            "budget_ceiling_usd": "25.00", "cost_baseline_sha256": room.sha(ablation.COST_BASELINE),
            "prior_costs_and_holds_usd": str(held), "reserved_usd": str(reserve),
            "combined_costs_and_holds_usd": str(held + reserve), "predecessors": predecessors,
            "sh_iterations": 10, "sh_bands": 3, "gpu_index": 0, "cpu_fallback_allowed": False,
            "max_output_bytes": MAX_OUTPUT_BYTES, "quality_acceptance_implied": False}


def collect_file(sb, state, name, maximum):
    remote = f"{room.REMOTE}/{name}"
    size = sb.filesystem.stat(remote).size
    room.require(type(size) is int and 0 < size <= maximum, "invalid bounded converter output size")
    local = state / "download" / name
    room.require(not local.exists(), "refusing to overwrite collected evidence")
    local.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    sb.filesystem.copy_to_local(remote, local)
    local.chmod(0o600)
    room.require(local.stat().st_size == size, "output changed during download")
    return {"path": name, "bytes": size, "sha256": room.sha(local)}


def diagnostics(sb, state):
    evidence = []
    for name in ("device-receipt.json", "conversion-receipt.json", "device.log", "vulkan.log", "conversion.log"):
        existing = state / "download" / name
        if existing.exists():
            continue
        try:
            evidence.append(collect_file(sb, state, name, 2 * 1024**2))
        except Exception as error:
            evidence.append({"path": name, "error_type": type(error).__name__})
    return evidence


def run_one(modal, app, plan, state):
    state.mkdir(mode=0o700)
    path = state / "provider-receipt.json"
    receipt = {"schema_version": 1, "run_id": str(uuid.uuid4()), "purpose": "converter_validation_only",
               "sdk": "modal==1.5.3", "profile": room.PROFILE,
               "policy": plan["policy"], "source": plan["source"], "input": plan["input"],
               "source_receipt_sha256": plan["source_receipt_sha256"], "app_id": app.app_id,
               "transferred_files": [], "stages": {}, "actual_charge_usd": None,
               "billing_status": "not_yet_measured", "automatic_retries": 0,
               "training_performed": False, "quality_acceptance_implied": False}
    receipt["sandbox_name"] = "converter-probe-" + receipt["run_id"]
    sb = None
    attempted = False

    def stage(name, command, seconds):
        receipt["stages"][name] = {"started_utc": datetime.now(timezone.utc).isoformat()}
        started = time.monotonic()
        room.record(path, receipt, f"{name}_started")
        try:
            room.exec_to_log(sb, command, seconds, state / f"{name}.log",
                             stage=receipt["stages"][name], persist=lambda: room.save(path, receipt))
        finally:
            receipt["stages"][name]["elapsed_seconds"] = round(time.monotonic() - started, 6)
            room.save(path, receipt)

    try:
        room.record(path, receipt, "creation_started")
        attempted = True
        options = room.create_options(modal, app, receipt)
        options["timeout"] = TTL_SECONDS
        options["env"] = {**options["env"], "NVIDIA_DRIVER_CAPABILITIES": "compute,graphics,utility"}
        options["tags"] = {"experiment": "rendprop-converter-validation-20260914", "run": receipt["run_id"]}
        sb = modal.Sandbox.create(**options)
        room.record(path, receipt, "allocated", sandbox_id=sb.object_id)
        sb.filesystem.make_directory(room.REMOTE)
        sb.filesystem.make_directory(f"{room.REMOTE}/converter")
        sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=[], outbound_domain_allowlist=[])
        sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=["0.0.0.0/0"],
                                                    outbound_domain_allowlist=["*"])
        room.record(path, receipt, "network_policy_api_ready")
        for remote, local in PUBLIC_FILES.items():
            room.require(room.sha(local) == plan["source"]["converter_files"][local.relative_to(REPO).as_posix()],
                         "public source changed before transfer")
            sb.filesystem.copy_from_local(local, f"{room.REMOTE}/{remote}")
        stage("setup", ["bash", f"{room.REMOTE}/setup_converter_probe.sh"], 600)
        stage("device", ["python", f"{room.REMOTE}/converter_probe_remote.py", "device"], 90)
        preflight = collect_file(sb, state, "device-receipt.json", 65536)
        device = bounded_json(state / "download/device-receipt.json")
        room.require(device.get("success") is True and device.get("device", {}).get("nvidia_l4") is True
                     and device["device"].get("adapter_count") == 1
                     and device.get("vulkan", {}).get("vulkan_available") is True,
                     "L4 device preflight failed")
        receipt["artifacts"] = [preflight]
        # Policy narrowing completes before any private PLY can be transferred.
        sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=[], outbound_domain_allowlist=[])
        room.record(path, receipt, "outbound_denied")
        local = regular_private_file(Path(plan["input_ply"]))
        room.require(ply_metadata(local) == plan["input"], "PLY changed before private transfer")
        room.record(path, receipt, "private_transfer_started")
        sb.filesystem.copy_from_local(local, f"{room.REMOTE}/input.ply")
        receipt["transferred_files"].append("input.ply")
        room.record(path, receipt, "private_transfer_complete")
        stage("conversion", ["python", f"{room.REMOTE}/converter_probe_remote.py", "convert",
                             "--input-sha256", plan["input"]["sha256"],
                             "--input-bytes", str(plan["input"]["bytes"]),
                             "--gaussian-count", str(plan["input"]["gaussian_count"])], 630)
        receipt["artifacts"].append(collect_file(sb, state, "conversion-receipt.json", 65536))
        converted = bounded_json(state / "download/conversion-receipt.json")
        room.require(converted.get("success") is True and converted.get("input") == {
            key: plan["input"][key] for key in ("sha256", "bytes", "gaussian_count")}
            and converted.get("gpu_usage", {}).get("gpu_memory_used") is True
            and converted.get("sh_bands") == 3 and converted.get("sh_iterations") == 10,
            "conversion receipt does not bind input and GPU profile")
        output = collect_file(sb, state, "model.sog", MAX_OUTPUT_BYTES)
        actual = validate_sog(state / "download/model.sog", plan["input"]["gaussian_count"])
        room.require(actual == converted.get("output"), "SOG differs from its remote receipt")
        receipt["artifacts"].append(output)
        receipt["diagnostics"] = diagnostics(sb, state)
        room.record(path, receipt, "artifacts_collected", outcome="converted", conversion=converted)
    except BaseException as error:
        room.record(path, receipt, "failed", outcome="failed", failure_type=type(error).__name__)
        if sb is None and attempted:
            try:
                sb = modal.Sandbox.from_name(plan["app_name"], receipt["sandbox_name"], environment_name="main")
                receipt["sandbox_id"] = sb.object_id
            except Exception:
                room.record(path, receipt, "allocation_unresolved_no_retry")
        if sb is not None:
            receipt["provider_terminal"] = room.provider_terminal(sb)
            receipt["failed_diagnostics"] = diagnostics(sb, state)
            room.save(path, receipt)
        raise
    finally:
        if sb is not None:
            room.cleanup(sb, path, receipt)


def execute(modal, plan_path, state):
    room.require(modal.__version__ == "1.5.3", "use pinned Modal SDK 1.5.3")
    plan = bounded_json(plan_path)
    room.require(plan == prepare(Path(plan["source_state"]), plan["label"]),
                 "reviewed plan source, PLY, cleanup or cost evidence changed")
    state = private_path(state, must_exist=False)
    room.require(not state.exists() and state.parent.is_dir(), "fresh private output directory required")
    historical = bounded_json(ablation.COST_BASELINE)["inventory"]
    apps = set(historical["active_by_app"]) | {item["app_id"] for item in plan["predecessors"]}
    for app_id in sorted(apps):
        room.require(not list(modal.Sandbox.list(app_id=app_id)), "a prior spatial sandbox is active")
    ids = set(historical["exact_sandbox_terminal_polls"]) | {item["sandbox_id"] for item in plan["predecessors"]}
    for sandbox_id in sorted(ids):
        prior = modal.Sandbox.from_id(sandbox_id)
        try:
            room.require(prior.poll() is not None, "prior sandbox is not terminal")
        finally:
            prior.detach()
    app = modal.App.lookup(plan["app_name"], environment_name="main", create_if_missing=True)
    room.require(isinstance(app.app_id, str) and app.app_id.startswith("ap-"), "invalid empty app namespace")
    room.require(not list(modal.Sandbox.list(app_id=app.app_id)), "converter namespace already has an active sandbox")
    marker = ablation.PRIVATE_ROOT / f"spatial-ablation-20260914-{plan['label']}.allocation.json"
    room.require(not marker.exists(), "allocation marker already exists; never retry automatically")
    room.save(marker, {"state": str(state), "reserved_usd": plan["reserved_usd"], "app_id": app.app_id,
                       "plan_sha256": room.sha(plan_path), "utc": datetime.now(timezone.utc).isoformat(),
                       "automatic_retries": 0, "purpose": "converter_validation_only",
                       "provider_timeout_seconds": TTL_SECONDS,
                       "priced_compute_bound_usd": plan["policy"]["compute_upper_bound_usd"]})
    run_one(modal, app, plan, state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=("plan", "run"), default="plan")
    parser.add_argument("--source-state", type=Path)
    parser.add_argument("--label")
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--confirm-one-allocation", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "plan":
        room.require(args.source_state is not None and args.label is not None, "source state and label required")
        path = private_path(args.plan, must_exist=False)
        room.require(not path.exists() and path.parent.is_dir(), "fresh private plan path required")
        room.save(path, prepare(args.source_state, args.label))
        print("plan_saved_no_provider_calls")
        return
    room.require(args.confirm_one_allocation and args.state is not None, "explicit single allocation required")
    with (ablation.PRIVATE_ROOT / "room-approval-20260910.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ["MODAL_PROFILE"] = room.PROFILE
        import modal
        execute(modal, args.plan, args.state)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise InterruptedError(f"converter interrupted by signal {signum}")
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        main()
    except Exception as error:
        print(f"failed_{type(error).__name__}_no_automatic_retry", file=sys.stderr)
        sys.exit(1)
