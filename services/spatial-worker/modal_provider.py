"""Ephemeral Modal implementation of the cloud worker's provider boundary."""
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import sys

from worker import JobFailure, MAX_OUTPUT_BYTES, TRAINING_ROOT, require


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
        manifest = navigation_manifest(capture, job["room_label"])
        dataset_files = experiment.inventory(root / "dataset")
        receipt = {"job_id": job["id"], "sandbox_name": "spatial-" + job["id"] + "-" + job["lease_token"],
                   "run_id": job["lease_token"], "stages": {}, "artifacts": [], "cleanup_complete": False}
        receipt_path = root / "provider-receipt.json"
        save = lambda: experiment.save(receipt_path, receipt)
        save()
        sb, attempted = None, False
        try:
            lease.check()
            remaining = (datetime.fromisoformat(job["deadline_at"].replace("Z", "+00:00"))
                         - datetime.now(timezone.utc)).total_seconds()
            # The TTL is sent with CREATE, before compilation or room transfer.
            # Heartbeat loss is an additional stop, never the only cost boundary.
            require(remaining >= 2400, "insufficient_job_lifetime")
            options = experiment.create_options(self.modal, self.app, receipt)
            options["timeout"] = min(7200, int(remaining) - 120)
            options["tags"] = {"product": "rendprop-spatial", "job": job["id"]}
            attempted = True
            sb = self.modal.Sandbox.create(**options)
            receipt["sandbox_id"] = sb.object_id
            save()
            lease.abort = lambda: sb.terminate(wait=True)
            lease.check()
            sb.filesystem.make_directory(experiment.REMOTE)
            # As in the field-tested runner, prove the dynamic network-policy API
            # before setup costs or media. Dependency download happens without data.
            sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=[], outbound_domain_allowlist=[])
            sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=["0.0.0.0/0"], outbound_domain_allowlist=["*"])
            sources = [(TRAINING_ROOT / name, name) for name in experiment.SOURCE_FILES]
            sources.append((Path(__file__).parent / "setup_service.sh", "setup_service.sh"))
            viewer = TRAINING_ROOT.parent / "viewer"
            sources.extend((viewer / name, "converter/" + name) for name in ("package.json", "package-lock.json"))
            for source, name in sources:
                sb.filesystem.copy_from_local(source, f"{experiment.REMOTE}/{name}")
            receipt["stages"]["setup"] = {}
            experiment.exec_to_log(sb, ["bash", f"{experiment.REMOTE}/setup_service.sh"], 2100,
                                   root / "setup.log", stage=receipt["stages"]["setup"], persist=save)
            sb._experimental_set_outbound_network_policy(outbound_cidr_allowlist=[], outbound_domain_allowlist=[])
            receipt["network_denied_before_media"] = True
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
                       "--max-gaussians", str(job["max_gaussians"])]
            experiment.exec_to_log(sb, command, job["max_training_seconds"] + 100, root / "training.log",
                                   stage=receipt["stages"]["training"], persist=save)
            lease.stage(.75)
            ply = f"{experiment.REMOTE}/result/ply/point_cloud_{job['max_iterations'] - 1}.ply"
            sog = f"{experiment.REMOTE}/result/model.sog"
            receipt["stages"]["conversion"] = {}
            # Direct executable from npm ci; no npx implicit install, no network,
            # no alternate converter if the pinned SOG path fails.
            experiment.exec_to_log(sb, [f"{experiment.REMOTE}/converter/node_modules/.bin/splat-transform",
                                   "-g", "cpu", ply, sog], 600, root / "conversion.log",
                                   stage=receipt["stages"]["conversion"], persist=save)
            lease.check()
            size = sb.filesystem.stat(sog).size
            require(type(size) is int and 0 < size <= MAX_OUTPUT_BYTES, "sog_output_too_large")
            metadata_path = f"{experiment.REMOTE}/result/run.json"
            require(sb.filesystem.stat(metadata_path).size <= 1024**2, "training_metadata_too_large")
            sb.filesystem.copy_to_local(metadata_path, root / "run.json")
            metadata = json.loads((root / "run.json").read_text())
            require(metadata.get("status") == "trained" and type(metadata.get("gaussian_count")) is int
                    and 0 < metadata["gaussian_count"] <= job["max_gaussians"], "training_output_unconfirmed")
            output = root / "model.sog"
            sb.filesystem.copy_to_local(sog, output)
            os.chmod(output, 0o600)
            require(output.stat().st_size == size, "sog_size_changed")
            manifest["gaussian_count"] = metadata["gaussian_count"]
            return output, manifest
        except Exception as error:
            if sb is None and attempted:
                # Unknown CREATE outcome cannot allocate a second sandbox. Lookup
                # is only for terminating the uniquely named attempt if it exists.
                try:
                    sb = self.modal.Sandbox.from_name(self.app.name, receipt["sandbox_name"])
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
                        receipt["terminated"] = sb.poll() is not None
                        require(receipt["terminated"], "provider_termination_unconfirmed")
                    finally:
                        sb.detach()
                        lease.abort = lambda: None
                        save()
                if not active_failure:
                    require(receipt.get("private_files_removed") and receipt.get("terminated"),
                            "provider_cleanup_unconfirmed")
