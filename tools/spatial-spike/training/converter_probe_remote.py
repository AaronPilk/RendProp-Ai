#!/usr/bin/env python3
"""Inert on import; bounded, credential-free converter probe inside one sandbox.

No training, filters, harmonic reduction, alternate converter or CPU retry.
The pinned CLI's invalid-index fallback is explicitly rejected. Restricting the
Vulkan ICD and requiring a single L4 adapter removes ambiguous device selection.
Only numeric status is printed. Full bounded diagnostic logs stay private.
"""
import argparse
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time
import zipfile

ROOT = Path("/opt/room-experiment")
MAX_OUTPUT = 32 * 1024**2
MAX_LOG = 2 * 1024**2
ICD = Path("/etc/vulkan/icd.d/nvidia_icd.json")
CLI = ROOT / "converter/node_modules/.bin/splat-transform"


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024**2), b""):
            result.update(block)
    return result.hexdigest()


def save(path, value):
    temporary = path.with_suffix(".next")
    with temporary.open("w") as handle:
        json.dump(value, handle, sort_keys=True)
        handle.flush()
        os.fsync(handle.fileno())
    temporary.chmod(0o600)
    temporary.replace(path)


def run_bounded(argv, timeout, log_path):
    """Drain both streams with a disk limit; kill the child group on timeout."""
    started = time.monotonic()
    result = {"exit_code": None, "timed_out": False, "log_truncated": False,
              "log_bytes": 0, "elapsed_seconds": 0}
    with log_path.open("xb", buffering=0) as log:
        child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        streams = selectors.DefaultSelector()
        for stream in (child.stdout, child.stderr):
            os.set_blocking(stream.fileno(), False)
            streams.register(stream, selectors.EVENT_READ)
        try:
            deadline = started + timeout
            while streams.get_map():
                if time.monotonic() >= deadline:
                    result["timed_out"] = True
                    os.killpg(child.pid, signal.SIGKILL)
                    break
                for key, _ in streams.select(min(0.25, max(0, deadline - time.monotonic()))):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        streams.unregister(key.fileobj)
                        continue
                    remaining = max(0, MAX_LOG - result["log_bytes"])
                    log.write(block[:remaining])
                    result["log_bytes"] += min(len(block), remaining)
                    result["log_truncated"] |= len(block) > remaining
            # A child can close its streams but remain alive; the same deadline applies.
            try:
                result["exit_code"] = child.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                result["timed_out"] = True
                os.killpg(child.pid, signal.SIGKILL)
                result["exit_code"] = child.wait(timeout=10)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=10)
            streams.close()
            child.stdout.close()
            child.stderr.close()
    result["elapsed_seconds"] = round(time.monotonic() - started, 6)
    return result


def plain(text):
    return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)


def validate_adapters(text):
    entries = re.findall(r"(?m)^\s*\[(\d+)\]\s+([^\r\n]+?)\s*$", plain(text))
    require(entries == [("0", "NVIDIA L4")], "one exact NVIDIA L4 adapter required")
    return {"adapter_count": 1, "adapter_index": 0, "nvidia_l4": True,
            "cpu_fallback_allowed": False, "icd": "nvidia"}


def validate_conversion_log(text):
    text = plain(text)
    require(not re.search(r"using default|\bfallback\b|\bCPU.only\b|\bCPU mode\b", text, re.I),
            "default or CPU fallback reported")
    require(re.search(r"\b3 SH bands\b", text), "three SH bands must reach the writer")
    match = re.search(r"done in [^\n]*\[peak cpu=[^\]\n]* gpu=([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)\]", text)
    require(match and float(match[1]) > 0, "CLI did not prove GPU memory use")
    return {"engine_tracked_gpu_peak_value": float(match[1]),
            "engine_tracked_gpu_peak_unit": match[2], "gpu_memory_used": True,
            "hardware_peak_measured": False}


def validate_vulkan(text):
    def values(field):
        return re.findall(rf"(?m)^\s*{field}\s*=\s*([^\r\n]+?)\s*$", plain(text))
    require(values("deviceName") == ["NVIDIA L4"] and values("vendorID") == ["0x10de"]
            and values("deviceType") == ["PHYSICAL_DEVICE_TYPE_DISCRETE_GPU"]
            and values("driverID") == ["DRIVER_ID_NVIDIA_PROPRIETARY"],
            "exact NVIDIA L4 Vulkan device required")
    version = values("driverVersion")
    require(len(version) == 1, "one numeric Vulkan driver version required")
    dotted = re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,4}", version[0])
    packed = re.fullmatch(r"([0-9]+) \(0x([0-9a-fA-F]{1,8})\)", version[0])
    require(dotted or (packed and 0 <= int(packed[1]) <= 0xFFFFFFFF
                       and int(packed[1]) == int(packed[2], 16)),
            "numeric Vulkan driver version or matching uint32/hex pair required")
    result = {"physical_device_count": 1, "vendor_id": 0x10DE, "nvidia_l4": True,
              "nvidia_proprietary_driver": True, "driver_version": version[0],
              "vulkan_available": True}
    if packed:
        result["driver_version_uint32"] = int(packed[1])
    info = values("driverInfo")
    if len(info) == 1 and re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,4}", info[0]):
        result["driver_info_version"] = info[0]
    return result


def validate_sog(path, gaussian_count):
    size = path.stat().st_size
    require(0 < size <= MAX_OUTPUT, "SOG exceeds 32MiB")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        expected = {"meta.json", "means_l.webp", "means_u.webp", "quats.webp", "scales.webp",
                    "sh0.webp", "shN_centroids.webp", "shN_labels.webp"}
        require(len(entries) == len(expected) and {item.filename for item in entries} == expected,
                "unexpected SOG entries")
        require(all(0 < item.file_size <= MAX_OUTPUT for item in entries)
                and sum(item.file_size for item in entries) <= 64 * 1024**2,
                "oversized SOG members")
        require(archive.getinfo("meta.json").file_size <= 256 * 1024, "oversized SOG metadata")
        meta = json.loads(archive.read("meta.json"))
        require(meta.get("version") == 2 and meta.get("count") == gaussian_count
                and meta.get("asset", {}).get("generator") == "splat-transform v3.4.2"
                and meta.get("shN", {}).get("bands") == 3, "SOG profile mismatch")
        require(archive.testzip() is None, "SOG archive checksum failure")
    return {"bytes": size, "sha256": digest(path), "gaussian_count": gaussian_count,
            "sh_bands": 3, "sog_version": 2}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("device", "convert"))
    parser.add_argument("--input-sha256")
    parser.add_argument("--input-bytes", type=int)
    parser.add_argument("--gaussian-count", type=int)
    args = parser.parse_args()
    os.umask(0o077)
    receipt_path = ROOT / ("device-receipt.json" if args.stage == "device" else "conversion-receipt.json")
    receipt = {"schema_version": 1, "stage": args.stage, "success": False,
               "sh_bands": 3, "sh_iterations": 10, "automatic_retries": 0}
    started = time.monotonic()
    try:
        require(ICD.is_file() and ctypes.util.find_library("vulkan"), "NVIDIA ICD or Vulkan loader missing")
        # A fresh process applies the exact ICD policy before Dawn initializes.
        os.environ["VK_DRIVER_FILES"] = str(ICD)
        os.environ["VK_ICD_FILENAMES"] = str(ICD)
        receipt["icd_sha256"] = digest(ICD)
        package = json.loads((ROOT / "converter/node_modules/@playcanvas/splat-transform/package.json").read_text())
        webgpu = json.loads((ROOT / "converter/node_modules/webgpu/package.json").read_text())
        require(package["version"] == "3.4.2" and webgpu["version"] == "0.4.0", "package pin mismatch")
        node_version = subprocess.check_output(["node", "--version"], timeout=10, text=True).strip()
        require(node_version == "v22.22.0", "Node pin mismatch")
        receipt.update(node_version=node_version, converter_version="3.4.2", webgpu_version="0.4.0")
        if args.stage == "device":
            vulkan = run_bounded(["vulkaninfo", "--summary"], 20, ROOT / "vulkan.log")
            receipt["vulkan_process"] = vulkan
            save(receipt_path, receipt)
            require(vulkan["exit_code"] == 0 and not vulkan["timed_out"] and not vulkan["log_truncated"],
                    "Vulkan device validation failed")
            receipt["vulkan"] = validate_vulkan((ROOT / "vulkan.log").read_text(errors="replace"))
            result = run_bounded([str(CLI), "--no-tty", "--list-gpus"], 40, ROOT / "device.log")
            receipt["process"] = result
            save(receipt_path, receipt)
            require(result["exit_code"] == 0 and not result["timed_out"] and not result["log_truncated"],
                    "GPU enumeration failed")
            receipt["device"] = validate_adapters((ROOT / "device.log").read_text(errors="replace"))
        else:
            device = json.loads((ROOT / "device-receipt.json").read_text())
            require(device.get("success") is True and device["icd_sha256"] == receipt["icd_sha256"],
                    "public device preflight changed")
            receipt["device"] = device["device"]
            require(re.fullmatch(r"[0-9a-f]{64}", args.input_sha256 or "")
                    and type(args.input_bytes) is int and 0 < args.input_bytes <= 512 * 1024**2
                    and type(args.gaussian_count) is int and 1 <= args.gaussian_count <= 500000,
                    "invalid input binding")
            source = ROOT / "input.ply"
            require(not source.is_symlink() and source.stat().st_size == args.input_bytes
                    and digest(source) == args.input_sha256, "private PLY changed during transfer")
            receipt["input"] = {"sha256": args.input_sha256, "bytes": args.input_bytes,
                                "gaussian_count": args.gaussian_count}
            save(receipt_path, receipt)
            result = run_bounded([str(CLI), "--no-tty", "-g", "0", "-i", "10",
                                  str(source), str(ROOT / "model.sog")], 600, ROOT / "conversion.log")
            receipt["process"] = result
            save(receipt_path, receipt)
            require(result["exit_code"] == 0 and not result["timed_out"] and not result["log_truncated"],
                    "GPU conversion failed")
            receipt["gpu_usage"] = validate_conversion_log((ROOT / "conversion.log").read_text(errors="replace"))
            receipt["output"] = validate_sog(ROOT / "model.sog", args.gaussian_count)
            require(digest(source) == args.input_sha256, "converter changed the source PLY")
        receipt["success"] = True
    except BaseException as error:
        receipt["error_type"] = type(error).__name__
        raise
    finally:
        receipt["elapsed_seconds"] = round(time.monotonic() - started, 6)
        save(receipt_path, receipt)
        print(json.dumps({"success": receipt["success"], "elapsed_seconds": receipt["elapsed_seconds"]}))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        # Arbitrary provider or geometry-bearing exception text stays out of stdout/stderr.
        raise SystemExit(1)
