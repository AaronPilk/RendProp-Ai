"""Ephemeral Modal implementation of the cloud worker's provider boundary."""
from datetime import datetime, timezone
from decimal import Decimal, ROUND_CEILING
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys

from worker import JobFailure, MAX_OUTPUT_BYTES, TRAINING_ROOT, canonical_uuid, require
from provider_journal import ProviderJournal, sandbox_name

# Published Modal Sandbox rates (September 10, 2026), USD per second. These are
# the same figures `policy()` in tools/spatial-spike/training/modal_room.py
# multiplies out for the approved experiment; they are copied rather than
# imported so this module's pricing never depends on the experiment CLI, and
# test_modal_provider cross-checks the two so they cannot drift apart silently.
# CPU/RAM are Sandbox rates, NOT the cheaper Function rates. The region factor
# is the broad "us" multiplier. This is a full-lifetime ceiling, not an invoice.
GPU_USD_PER_SECOND = {"L4": Decimal("0.000222")}
CPU_USD_PER_CORE_SECOND = Decimal("0.00003942")
MEMORY_USD_PER_GIB_SECOND = Decimal("0.00000667")
REGION_MULTIPLIER = {"us": Decimal("1.15")}
TRAINER_COMMIT = "937e29912570c372bed6747a5c9bf85fed877bae"
CONVERTER_HELPER_SHA256 = "f4211a35f600cde54e5fc487e80a6ccbff78d585d929bf72c3b2a3e33479cdb4"


def copy_converter_log(sandbox, remote, local):
    """Bounded temporary diagnostics for validation; never print raw contents."""
    size = sandbox.filesystem.stat(remote).size
    require(type(size) is int and 0 < size <= 2 * 1024**2, "converter_log_too_large")
    require(not local.exists(), "converter_log_already_exists")
    sandbox.filesystem.copy_to_local(remote, local)
    os.chmod(local, 0o600)
    require(local.stat().st_size == size, "converter_log_size_changed")
    return local.read_text(errors="replace")


def valid_converter_process(value, seconds):
    return (isinstance(value, dict) and type(value.get("exit_code")) is int and value["exit_code"] == 0
            and value.get("timed_out") is False and value.get("log_truncated") is False
            and type(value.get("elapsed_seconds")) in (int, float)
            and math.isfinite(value["elapsed_seconds"]) and 0 < value["elapsed_seconds"] <= seconds + 5)


def validate_converter_device(helper, device, adapter_log, vulkan_log):
    require(device.get("schema_version") == 1 and device.get("stage") == "device"
            and device.get("success") is True and device.get("sh_bands") == 3
            and device.get("sh_iterations") == 10 and device.get("automatic_retries") == 0
            and (device.get("node_version"), device.get("converter_version"), device.get("webgpu_version"))
            == ("v22.22.0", "3.4.2", "0.4.0")
            and re.fullmatch(r"[0-9a-f]{64}", device.get("icd_sha256", "")) is not None
            and valid_converter_process(device.get("process"), 40)
            and valid_converter_process(device.get("vulkan_process"), 20), "invalid_converter_device")
    try:
        require(helper.validate_adapters(adapter_log) == device.get("device")
                and helper.validate_vulkan(vulkan_log) == device.get("vulkan"), "invalid_converter_device")
    except ValueError:
        raise JobFailure("invalid_converter_device") from None


def converter_input(job, metadata, remote):
    steps = job.get("max_iterations")
    require(remote == "/opt/room-experiment" and type(steps) is int and 1 <= steps <= 30000,
            "invalid_converter_input")
    source = f"{remote}/result/ply/point_cloud_{steps - 1}.ply"
    require(metadata.get("ply") == source and type(metadata.get("ply_bytes")) is int
            and 100 < metadata["ply_bytes"] <= 512 * 1024**2
            and isinstance(metadata.get("ply_sha256"), str)
            and re.fullmatch(r"[0-9a-f]{64}", metadata["ply_sha256"]) is not None,
            "invalid_converter_input")
    return {"sha256": metadata["ply_sha256"], "bytes": metadata["ply_bytes"],
            "gaussian_count": metadata["gaussian_count"]}


def converter_link_command(job, metadata, remote):
    binding = converter_input(job, metadata, remote)
    # Fixed paths only; never execute or follow the arbitrary metadata['ply'].
    source = f"{remote}/result/ply/point_cloud_{job['max_iterations'] - 1}.ply"
    code = (
        "import os; from pathlib import Path\n"
        f"source=Path({source!r}); target=Path({(remote + '/input.ply')!r})\n"
        "if source.is_symlink() or source.resolve()!=source or not source.is_file():\n"
        " raise RuntimeError('invalid trained PLY path')\n"
        f"if source.stat().st_size!={binding['bytes']} or target.exists() or target.is_symlink():\n"
        " raise RuntimeError('trained PLY size or target changed')\n"
        "os.link(source,target,follow_symlinks=False)\n"
        "print(1)\n"
    )
    return ["python", "-c", code]


def conversion_record(helper, job, sandbox_id, device, converted, binding, log):
    require(converted.get("schema_version") == 1 and converted.get("stage") == "convert"
            and converted.get("success") is True and converted.get("input") == binding
            and converted.get("device") == device["device"] and converted.get("icd_sha256") == device["icd_sha256"]
            and (converted.get("node_version"), converted.get("converter_version"), converted.get("webgpu_version"))
            == ("v22.22.0", "3.4.2", "0.4.0")
            and converted.get("sh_bands") == 3 and converted.get("sh_iterations") == 10
            and converted.get("automatic_retries") == 0
            and valid_converter_process(converted.get("process"), 600), "invalid_converter_receipt")
    try:
        gpu = helper.validate_conversion_log(log)
    except ValueError:
        raise JobFailure("invalid_converter_gpu_proof") from None
    require(gpu == converted.get("gpu_usage"), "invalid_converter_gpu_proof")
    output = converted.get("output", {})
    require(type(output.get("bytes")) is int and 0 < output["bytes"] <= MAX_OUTPUT_BYTES
            and type(output.get("gaussian_count")) is int
            and output["gaussian_count"] == binding["gaussian_count"] and output.get("sh_bands") == 3
            and output.get("sog_version") == 2 and isinstance(output.get("sha256"), str)
            and re.fullmatch(r"[0-9a-f]{64}", output["sha256"]) is not None, "invalid_converter_output")
    return {"event": "spatial_conversion", "job_id": job["id"], "sandbox_id": sandbox_id,
            "converter_version": "3.4.2", "sh_bands": 3, "sh_iterations": 10,
            "gaussians": binding["gaussian_count"], "input_sha256": binding["sha256"],
            "output_sha256": output["sha256"], "output_bytes": output["bytes"],
            "conversion_seconds": converted["process"]["elapsed_seconds"],
            "gpu_peak_value": gpu["engine_tracked_gpu_peak_value"],
            "gpu_peak_unit": gpu["engine_tracked_gpu_peak_unit"], "hardware_peak_measured": False}


def dependency_baseline_digest(path):
    """Only a bounded public package==version list may be sent to setup."""
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= 64 * 1024,
            "invalid_dependency_baseline")
    raw = path.read_bytes()
    require(len(raw) <= 64 * 1024, "invalid_dependency_baseline")
    try:
        entries = raw.decode("ascii").splitlines()
    except UnicodeDecodeError:
        raise JobFailure("invalid_dependency_baseline") from None
    require(entries and entries == sorted(set(entries)) and all(
        re.fullmatch(r"[A-Za-z0-9_.-]+==[A-Za-z0-9_.+!-]+", entry) for entry in entries),
        "invalid_dependency_baseline")
    return hashlib.sha256(raw).hexdigest()


def dependency_verification_command(remote, expected_digest):
    """Check the full GPU environment without logging arbitrary package data."""
    require(re.fullmatch(r"[0-9a-f]{64}", expected_digest) is not None, "invalid_dependency_baseline")
    code = (
        "import hashlib,importlib.metadata as m; from pathlib import Path\n"
        f"raw=Path({(remote + '/requirements-baseline.txt')!r}).read_bytes()\n"
        f"if len(raw)>65536 or hashlib.sha256(raw).hexdigest()!={expected_digest!r}:\n"
        " raise RuntimeError('dependency baseline changed during setup')\n"
        "expected=raw.decode('ascii').splitlines()\n"
        "actual=sorted(f\"{d.metadata['Name']}=={d.version}\" for d in m.distributions())\n"
        "if actual!=expected:\n"
        " raise RuntimeError('resolved environment differs from baseline')\n"
        "print('PASS: exact baseline Python dependencies')\n"
    )
    return ["python", "-c", code]


def copy_bounded_json(sandbox, remote, local, limit):
    """Read one exact, bounded trainer receipt; never emit its arbitrary fields."""
    size = sandbox.filesystem.stat(remote).size
    require(type(size) is int and 0 < size <= limit, "training_receipt_too_large")
    require(not local.exists(), "training_receipt_already_exists")
    sandbox.filesystem.copy_to_local(remote, local)
    os.chmod(local, 0o600)
    require(local.stat().st_size == size, "training_receipt_size_changed")
    value = json.loads(local.read_text())
    require(isinstance(value, dict), "invalid_training_receipt")
    return value


def quality_record(job, sandbox_id, frame_count, metadata, metrics, *, pose_opt=False):
    """Only source-bound numeric quality and approved identities may reach logs."""
    require(canonical_uuid(job.get("id")) and isinstance(sandbox_id, str)
            and re.fullmatch(r"sb-[A-Za-z0-9]{4,64}", sandbox_id) is not None,
            "invalid_quality_identity")
    require(type(frame_count) is int and 20 <= frame_count <= 400
            and frame_count == len(job["manifest"]["frames"]), "training_frame_count_mismatch")
    require(metadata.get("status") == "trained" and metadata.get("gsplat_commit") == TRAINER_COMMIT
            and type(metadata.get("frames")) is int and metadata["frames"] == frame_count
            and type(metadata.get("max_steps")) is int and metadata["max_steps"] == job["max_iterations"]
            and type(metadata.get("max_seconds")) is int and metadata["max_seconds"] == job["max_training_seconds"]
            and type(metadata.get("max_gaussians")) is int and metadata["max_gaussians"] == job["max_gaussians"]
            and metadata.get("world_normalization") is False
            and type(pose_opt) is bool and metadata.get("pose_optimization") is pose_opt,
            "training_output_unconfirmed")
    count = metadata.get("gaussian_count")
    require(type(count) is int and 0 < count <= job["max_gaussians"]
            and type(metrics.get("num_GS")) is int and metrics["num_GS"] == count,
            "training_gaussian_count_mismatch")
    elapsed = metadata.get("elapsed_seconds")
    require(type(elapsed) in (int, float) and math.isfinite(elapsed)
            and 0 < elapsed <= job["max_training_seconds"] + 100, "invalid_training_elapsed")
    require(all(type(metrics.get(key)) in (int, float) and math.isfinite(metrics[key])
                for key in ("psnr", "ssim", "lpips")), "invalid_training_quality")
    require(metrics["psnr"] >= 0 and -1 <= metrics["ssim"] <= 1 and metrics["lpips"] >= 0,
            "invalid_training_quality")
    return {"event": "spatial_training_quality", "job_id": job["id"], "sandbox_id": sandbox_id,
            "trainer_commit": TRAINER_COMMIT, "frames": frame_count,
            "loss_heldout_count": (frame_count + 7) // 8, "test_every": 8, "seed": 42,
            "pose_optimization": pose_opt, "steps": metadata["max_steps"], "gaussians": count,
            "training_elapsed_seconds": elapsed, "psnr": metrics["psnr"], "ssim": metrics["ssim"],
            "lpips": metrics["lpips"], "evaluation": "loss_held_out_seed_initialization_uses_all_frames"}


def compute_bound_cents(options):
    """Whole cents (rounded up) that one CREATE request can bill over its full TTL.

    Reads exactly the arguments about to be sent to `Sandbox.create`, so the
    figure covers what the provider will actually run, not a hoped-for shape.
    Anything this table cannot price is refused rather than assumed free.
    """
    gpu, region, timeout = options.get("gpu"), options.get("region"), options.get("timeout")
    cpu, memory = options.get("cpu"), options.get("memory")
    require(gpu in GPU_USD_PER_SECOND and region in REGION_MULTIPLIER, "unpriced_provider_resources")
    require(type(timeout) is int and 0 < timeout <= 7200, "invalid_provider_ttl")
    # Request and limit must agree: Modal bills the reservation, and a limit
    # above the request would make the ceiling below depend on scheduling luck.
    require(isinstance(cpu, tuple) and len(cpu) == 2 and cpu[0] == cpu[1]
            and type(cpu[1]) in (int, float) and math.isfinite(cpu[1]) and 0 < cpu[1] <= 64,
            "unpriced_provider_resources")
    require(isinstance(memory, tuple) and len(memory) == 2 and memory[0] == memory[1]
            and type(memory[1]) is int and 0 < memory[1] <= 262144, "unpriced_provider_resources")
    per_second = (GPU_USD_PER_SECOND[gpu] + Decimal(str(cpu[1])) * CPU_USD_PER_CORE_SECOND
                  + Decimal(memory[1]) / 1024 * MEMORY_USD_PER_GIB_SECOND)
    usd = per_second * timeout * REGION_MULTIPLIER[region]
    return int((usd * 100).to_integral_value(rounding=ROUND_CEILING))


def navigation_manifest(capture, room_label):
    positions = [[f["pose"][i][3] for i in range(3)] for f in capture["frames"]]
    points = [s["position"] for s in capture["seeds"]] + positions
    low = [min(p[i] for p in points) - 1 for i in range(3)]
    high = [max(p[i] for p in points) + 1 for i in range(3)]
    # This capture format has no RoomPlan floor plane. Be explicit that this is
    # an eye-height navigation estimate, NOT LiDAR measurement or collision data.
    floor = min(p[1] for p in positions) - 1.6
    low[1] = min(low[1], floor)
    high[1] = max(high[1], floor + 2.6)
    require(all(math.isfinite(x) and abs(x) <= 10000 for x in low + high)
            and all(0 < high[i] - low[i] <= 200 for i in range(3)), "invalid_navigation_bounds")
    pose = capture["frames"][0]["pose"]
    start = [pose[0][3], floor + 1.6, pose[2][3]]
    direction = [-pose[0][2], 0, -pose[2][2]]
    length = math.hypot(direction[0], direction[2])
    direction = [v / length for v in direction] if length > .01 else [0, 0, -1]
    target = [start[i] + direction[i] for i in range(3)]
    return {"schema_version": 1, "format": "sog", "bounds": {"min": low, "max": high},
            "floor_y": floor, "eye_height": 1.6, "floor_source": "capture_estimate",
            "navigation_bounds_source": "capture_estimate", "initial_camera": {"position": start, "target": target},
            "rooms": [{"id": "room", "label": room_label, "position": start, "target": target}]}


class ModalProvider:
    def __init__(self, modal, app):
        require(modal.__version__ == "1.5.3", "unsupported_modal_sdk")
        self.modal, self.app = modal, app

    def reconstruct(self, job, root, capture, lease):
        sys.path.insert(0, str(TRAINING_ROOT)) if str(TRAINING_ROOT) not in sys.path else None
        import modal_room as experiment
        converter_helper = TRAINING_ROOT / "converter_probe_remote.py"
        require(experiment.sha(converter_helper) == CONVERTER_HELPER_SHA256, "converter_helper_changed")
        import converter_probe_remote as converter
        baseline_path = Path(__file__).parent / "requirements-baseline.txt"
        baseline_digest = dependency_baseline_digest(baseline_path)
        manifest = navigation_manifest(capture, job["room_label"])
        dataset_files = experiment.inventory(root / "dataset")
        receipt = {"job_id": job["id"], "sandbox_name": sandbox_name(job),
                   "run_id": job["lease_token"], "stages": {}, "artifacts": [], "cleanup_complete": False,
                   "python_dependency_baseline_sha256": baseline_digest}
        receipt_path = root / "provider-receipt.json"
        save = lambda: experiment.save(receipt_path, receipt)
        save()
        sb, attempted, planned = None, False, False
        journal = ProviderJournal(lease, job)
        try:
            lease.check()
            remaining = (datetime.fromisoformat(job["deadline_at"].replace("Z", "+00:00"))
                         - datetime.now(timezone.utc)).total_seconds()
            # The TTL is sent with CREATE, before compilation or room transfer.
            # Heartbeat loss is an additional stop, never the only cost boundary.
            require(remaining >= 2400, "insufficient_job_lifetime")
            options = experiment.create_options(self.modal, self.app, receipt)
            options["env"] = {**options["env"], "NVIDIA_DRIVER_CAPABILITIES": "compute,graphics,utility"}
            options["timeout"] = min(7200, int(remaining) - 120)
            options["tags"] = {"product": "rendprop-spatial", "job": job["id"]}
            # The DB reserved max_cost_cents for this attempt. Prove, from the
            # exact CREATE arguments, that the provider's full TTL fits inside
            # it BEFORE intent is journaled: a request that cannot be afforded
            # is never planned, never created, and leaves no ambiguous receipt.
            receipt["compute_bound_cents"] = compute_bound_cents(options)
            require(receipt["compute_bound_cents"] <= job["max_cost_cents"], "provider_cost_bound_exceeded")
            save()
            journal.plan(self.app.name, receipt["sandbox_name"])
            planned = True
            lease.check()
            attempted = True
            lease.provider_attempted = True
            lease.provider_stopped = False
            sb = self.modal.Sandbox.create(**options)
            receipt["sandbox_id"] = sb.object_id
            save()
            lease.abort = lambda: sb.terminate(wait=True)
            # The ID must outlive this TemporaryDirectory BEFORE any source or
            # room bytes reach the GPU. A failed acknowledgement triggers cleanup.
            journal.created(sb.object_id)
            lease.check()
            sb.filesystem.make_directory(experiment.REMOTE)
            # As in the field-tested runner, prove the dynamic network-policy API
            # before setup costs or media. Dependency download happens without data.
            sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=[], outbound_domain_allowlist=[])
            sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=["0.0.0.0/0"], outbound_domain_allowlist=["*"])
            sources = [(TRAINING_ROOT / name, name) for name in experiment.SOURCE_FILES]
            sources.append((Path(__file__).parent / "setup_service.sh", "setup_service.sh"))
            sources.append((baseline_path, "requirements-baseline.txt"))
            sources.append((converter_helper, "converter_probe_remote.py"))
            viewer = TRAINING_ROOT.parent / "viewer"
            sources.extend((viewer / name, "converter/" + name) for name in ("package.json", "package-lock.json"))
            for source, name in sources:
                sb.filesystem.copy_from_local(source, f"{experiment.REMOTE}/{name}")
            receipt["stages"]["setup"] = {}
            experiment.exec_to_log(sb, ["bash", f"{experiment.REMOTE}/setup_service.sh"], 2100,
                                   root / "setup.log", stage=receipt["stages"]["setup"], persist=save)
            lease.check()
            receipt["stages"]["device"] = {}
            experiment.exec_to_log(sb, ["python", f"{experiment.REMOTE}/converter_probe_remote.py", "device"], 90,
                                   root / "device-wrapper.log", stage=receipt["stages"]["device"], persist=save)
            device = copy_bounded_json(sb, f"{experiment.REMOTE}/device-receipt.json",
                                       root / "device-receipt.json", 64 * 1024)
            adapter_log = copy_converter_log(sb, f"{experiment.REMOTE}/device.log", root / "device.log")
            vulkan_log = copy_converter_log(sb, f"{experiment.REMOTE}/vulkan.log", root / "vulkan.log")
            validate_converter_device(converter, device, adapter_log, vulkan_log)
            receipt["gpu_device_verified_before_media"] = True
            save()
            lease.check()
            sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=[], outbound_domain_allowlist=[])
            receipt["network_denied_before_media"] = True
            save()
            receipt["stages"]["dependencies"] = {}
            experiment.exec_to_log(sb, dependency_verification_command(experiment.REMOTE, baseline_digest), 60,
                                   root / "dependencies.log", stage=receipt["stages"]["dependencies"], persist=save)
            receipt["dependencies_verified_before_media"] = True
            save()
            lease.stage(.25)
            for item in dataset_files:
                lease.check()
                sb.filesystem.copy_from_local(root / "dataset" / item["path"],
                                              f"{experiment.REMOTE}/dataset/{item['path']}")
            lease.stage(.35)
            receipt["stages"]["training"] = {}
            command = ["python", f"{experiment.REMOTE}/run_training.py", "--gsplat-dir", "/opt/gsplat-phase-a",
                       "--dataset", f"{experiment.REMOTE}/dataset", "--output", f"{experiment.REMOTE}/result",
                       "--max-seconds", str(job["max_training_seconds"]), "--max-steps", str(job["max_iterations"]),
                       "--max-gaussians", str(job["max_gaussians"]), "--pose-opt"]
            experiment.exec_to_log(sb, command, job["max_training_seconds"] + 100, root / "training.log",
                                   stage=receipt["stages"]["training"], persist=save)
            metadata = copy_bounded_json(sb, f"{experiment.REMOTE}/result/run.json", root / "run.json", 1024**2)
            metrics_name = f"val_step{job['max_iterations'] - 1:04d}.json"
            metrics = copy_bounded_json(sb, f"{experiment.REMOTE}/result/stats/{metrics_name}",
                                        root / metrics_name, 64 * 1024)
            receipt["quality"] = quality_record(job, sb.object_id, len(capture["frames"]), metadata, metrics,
                                                pose_opt="--pose-opt" in command)
            save()
            # This CPU-controller log survives a later converter failure and the
            # temporary directory cleanup. No room label, path or raw output is logged.
            print(json.dumps(receipt["quality"], sort_keys=True, allow_nan=False), flush=True)
            lease.stage(.75)
            binding = converter_input(job, metadata, experiment.REMOTE)
            receipt["stages"]["conversion_input"] = {}
            lease.check()
            experiment.exec_to_log(sb, converter_link_command(job, metadata, experiment.REMOTE), 30,
                                   root / "conversion-input.log", stage=receipt["stages"]["conversion_input"], persist=save)
            lease.check()
            receipt["stages"]["conversion"] = {}
            # The unchanged, cloud-validated helper verifies the PLY hash, uses
            # explicit GPU0 / 3 SH bands / 10 iterations, and never falls back.
            experiment.exec_to_log(sb, ["python", f"{experiment.REMOTE}/converter_probe_remote.py", "convert",
                                   "--input-sha256", binding["sha256"], "--input-bytes", str(binding["bytes"]),
                                   "--gaussian-count", str(binding["gaussian_count"])], 630, root / "conversion-wrapper.log",
                                   stage=receipt["stages"]["conversion"], persist=save)
            lease.check()
            converted = copy_bounded_json(sb, f"{experiment.REMOTE}/conversion-receipt.json",
                                          root / "conversion-receipt.json", 64 * 1024)
            log = copy_converter_log(sb, f"{experiment.REMOTE}/conversion.log", root / "conversion.log")
            record = conversion_record(converter, job, sb.object_id, device, converted, binding, log)
            sog = f"{experiment.REMOTE}/model.sog"
            size = sb.filesystem.stat(sog).size
            require(type(size) is int and 0 < size <= MAX_OUTPUT_BYTES, "sog_output_too_large")
            require(size == record["output_bytes"], "sog_size_changed")
            output = root / "model.sog"
            sb.filesystem.copy_to_local(sog, output)
            os.chmod(output, 0o600)
            require(output.stat().st_size == size, "sog_size_changed")
            require(experiment.sha(output) == record["output_sha256"], "sog_hash_changed")
            try:
                require(converter.validate_sog(output, binding["gaussian_count"]) == converted["output"],
                        "invalid_converter_output")
            except (ValueError, OSError):
                raise JobFailure("invalid_converter_output") from None
            lease.check()
            receipt["conversion"] = record
            save()
            print(json.dumps(record, sort_keys=True, allow_nan=False), flush=True)
            manifest["gaussian_count"] = metadata["gaussian_count"]
            return output, manifest
        except Exception as error:
            if sb is None and attempted:
                # Unknown CREATE outcome cannot allocate a second sandbox. Lookup
                # is only for terminating the uniquely named attempt if it exists.
                try:
                    sb = self.modal.Sandbox.from_name(self.app.name, receipt["sandbox_name"])
                    receipt["sandbox_id"] = sb.object_id
                except Exception:
                    receipt["allocation_unresolved"] = True
            if sb is not None:
                receipt["provider_terminal"] = experiment.provider_terminal(sb)
                receipt["failed_diagnostics"] = experiment.collect_failed_diagnostics(sb, root)
            save()
            if receipt.get("provider_terminal", {}).get("reason") == "billing_cycle_spend_limit":
                raise JobFailure("provider_billing_limit") from None
            if isinstance(error, JobFailure):
                raise
            raise JobFailure("generation_failed") from None
        finally:
            active_failure = sys.exc_info()[0] is not None
            if sb is not None:
                # GPU release does not depend on an R2 upload, a successful
                # conversion or a functioning control-plane request.
                try:
                    sb.filesystem.remove(experiment.REMOTE, recursive=True)
                    receipt["private_files_removed"] = True
                except Exception as error:
                    receipt["cleanup_error_type"] = type(error).__name__
                finally:
                    try:
                        sb.terminate(wait=True)
                        receipt["exit_code"] = sb.poll()
                        receipt["terminated"] = receipt["exit_code"] is not None
                        if receipt["terminated"]:
                            lease.provider_stopped = True
                    except Exception as error:
                        receipt["termination_error_type"] = type(error).__name__
                    finally:
                        try:
                            journal.cleanup(receipt)
                            receipt["durable_cleanup_acknowledged"] = True
                        except Exception as error:
                            receipt["journal_error_type"] = type(error).__name__
                        try:
                            sb.detach()
                        except Exception:
                            pass
                        lease.abort = lambda: None
                        save()
                if not active_failure:
                    require(receipt.get("terminated"), "provider_termination_unconfirmed")
                    require(receipt.get("private_files_removed") and receipt.get("terminated"),
                            "provider_cleanup_unconfirmed")
                    require(receipt.get("durable_cleanup_acknowledged"), "provider_journal_unconfirmed")
            elif attempted or planned:
                try:
                    if attempted:
                        journal.write("unknown", last_error_code="allocation_unknown")
                    else:
                        journal.write("not_created", proof="create_not_invoked")
                except Exception as error:
                    receipt["journal_error_type"] = type(error).__name__
                save()
