"""Cloud-side spatial job execution. The iPhone never operates a GPU.

The database grants one fenced attempt and reserves its entire cost ceiling.
This controller downloads only that attempt's inputs, validates them BEFORE GPU
allocation, and hands the sandbox neither storage credentials nor network access
after dependency setup. A lost response never triggers another paid attempt.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
from typing import Callable
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler
import uuid

MAX_INPUT_BYTES = 2 * 1024**3
MAX_IMAGE_BYTES = 32 * 1024**2
MAX_JSON_BYTES = 32 * 1024**2
MAX_OUTPUT_BYTES = 32 * 1024**2
MAX_FRAMES = 400
MIN_COST_RESERVATION_CENTS = 600  # GPU full TTL plus bounded CPU controller.
WORKER_USER_AGENT = "Rendprop-Spatial-Worker/1.0"
TRAINING_ROOT = Path(__file__).resolve().parents[2] / "tools/spatial-spike/training"


class JobFailure(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)  # Never include a signed URL, SDK body or a credential.


def require(ok, code):
    if not ok:
        raise JobFailure(code)


def canonical_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def integer(value, low, high):
    return type(value) is int and low <= value <= high


class NoRedirect(HTTPRedirectHandler):
    # urllib's default redirect handler can forward a bearer header. A service
    # boundary is exact-origin, including on error and expired-capability paths.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def https_url(value, hosts):
    require(isinstance(value, str) and len(value) <= 16384, "invalid_transfer_url")
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname in hosts
            and parsed.port in (None, 443) and not parsed.username and not parsed.password
            and not parsed.fragment, "invalid_transfer_origin")
    return value


def json_bytes(value):
    try:
        encoded = json.dumps(value, allow_nan=False, separators=(",", ":")).encode()
    except (ValueError, TypeError):
        raise JobFailure("invalid_json") from None
    require(len(encoded) <= MAX_JSON_BYTES, "metadata_too_large")
    return encoded


def read_bounded(response, limit):
    declared = response.headers.get("Content-Length")
    if declared is not None:
        require(declared.isascii() and declared.isdecimal() and int(declared) <= limit,
                "response_too_large")
    result = response.read(limit + 1)
    require(len(result) <= limit, "response_too_large")
    return result


class ControlPlane:
    def __init__(self, base_url, service_token, *, opener=None):
        parsed = urlsplit(base_url)
        https_url(base_url, {parsed.hostname})
        require(not parsed.query and parsed.path.endswith("/functions/v1/spatial"), "invalid_service_origin")
        require(isinstance(service_token, str) and service_token and "\n" not in service_token,
                "missing_worker_credential")
        self.base_url = base_url.rstrip("/")
        self.service_host = parsed.hostname
        self.token = service_token
        self.opener = opener or build_opener(NoRedirect())

    def call(self, path, payload):
        require(re.fullmatch(r"/worker/(claim|[0-9a-f-]{36}/(?:heartbeat|complete|fail|output-ticket|provider-attempt))", path)
                is not None, "invalid_worker_path")
        request = Request(self.base_url + path, data=json_bytes(payload), method="POST", headers={
            "Authorization": "Bearer " + self.token, "Content-Type": "application/json",
            "User-Agent": WORKER_USER_AGENT})
        try:
            with self.opener.open(request, timeout=45) as response:
                require(200 <= response.status < 300, "control_plane_rejected")
                data = json.loads(read_bounded(response, MAX_JSON_BYTES))
                require(isinstance(data, dict), "invalid_service_response")
                return data
        except HTTPError as error:
            raise JobFailure("lease_lost" if error.code in (403, 409, 410) else "control_plane_unavailable") from None
        except (OSError, ValueError):
            raise JobFailure("control_plane_unavailable") from None

    def claim(self):
        response = self.call("/worker/claim", {"worker_id": str(uuid.uuid4())})
        require("job" in response, "invalid_claim_response")
        return response["job"]

    def job_call(self, job, action, **fields):
        return self.call(f"/worker/{job['id']}/{action}", {"lease_token": job["lease_token"], **fields})


def validate_job(job, now=None):
    require(isinstance(job, dict) and canonical_uuid(job.get("id"))
            and canonical_uuid(job.get("lease_token"))
            and canonical_uuid(job.get("attempt_key")), "invalid_job_identity")
    require(integer(job.get("max_seconds"), 7200, 7200), "invalid_lifetime_ceiling")
    require(integer(job.get("max_training_seconds"), 1, 1800), "invalid_training_ceiling")
    require(integer(job.get("max_iterations"), 1, 7000), "invalid_iteration_ceiling")
    require(integer(job.get("max_gaussians"), 100, 500000), "invalid_gaussian_ceiling")
    require(integer(job.get("max_cost_cents"), MIN_COST_RESERVATION_CENTS, 2500), "insufficient_cost_reservation")
    try:
        deadline = datetime.fromisoformat(job["deadline_at"].replace("Z", "+00:00"))
        require(deadline.tzinfo is not None, "invalid_deadline")
        remaining = (deadline - (now or datetime.now(timezone.utc))).total_seconds()
        require(60 <= remaining <= 7500, "expired_or_unbounded_deadline")
    except (ValueError, KeyError, AttributeError):
        raise JobFailure("invalid_deadline") from None
    inputs = job.get("inputs")
    require(isinstance(inputs, list) and 20 <= len(inputs) <= MAX_FRAMES, "invalid_input_count")
    manifest = job.get("manifest")
    require(isinstance(manifest, dict) and isinstance(manifest.get("frames"), list)
            and len(manifest["frames"]) == len(inputs), "manifest_count_mismatch")
    names, sidecars, total = set(), set(), 0
    for item in inputs:
        require(isinstance(item, dict), "invalid_input")
        path, frame = item.get("relative_path"), item.get("frame")
        require(isinstance(path, str) and re.fullmatch(r"images/[0-9]{6}\.jpg", path)
                and path not in names, "invalid_input_path")
        require(isinstance(frame, dict) and frame.get("image") == path, "frame_image_mismatch")
        require(integer(item.get("bytes"), 1, MAX_IMAGE_BYTES), "invalid_image_bytes")
        sidecar = path.replace("images/", "frames/").replace(".jpg", ".json")
        require(sidecar in manifest["frames"], "missing_frame_sidecar")
        names.add(path)
        sidecars.add(sidecar)
        total += item["bytes"]
        require(len(json_bytes(frame)) <= 1024**2, "frame_metadata_too_large")
    require(len(set(manifest["frames"])) == len(inputs) and set(manifest["frames"]) == sidecars,
            "invalid_manifest_coverage")
    require(total <= MAX_INPUT_BYTES, "capture_too_large")
    # A byte cap does not catch JSON NaNs or giant metadata in an otherwise small
    # image inventory. This runs before any GPU or file allocation.
    json_bytes(job)
    return remaining


def download_capture(job, destination, allowed_hosts, *, opener=None, check=lambda: None):
    opener = opener or build_opener(NoRedirect())
    destination.mkdir(mode=0o700)
    (destination / "images").mkdir(mode=0o700)
    (destination / "frames").mkdir(mode=0o700)
    for item in job["inputs"]:
        check()
        url = https_url(item.get("download_url"), allowed_hosts)
        path = destination / item["relative_path"]
        expected, written, digest = item["bytes"], 0, hashlib.sha256()
        try:
            # Identify our service honestly. The default Python-urllib UA was
            # rejected by the live Cloudflare gateway before application code.
            with opener.open(Request(url, method="GET", headers={"User-Agent": WORKER_USER_AGENT}), timeout=45) as response, path.open("xb") as out:
                require(response.status == 200, "image_download_rejected")
                declared = response.headers.get("Content-Length")
                require(declared is not None and declared.isdecimal() and int(declared) == expected,
                        "image_length_mismatch")
                while True:
                    chunk = response.read(min(1024**2, expected - written + 1))
                    if not chunk:
                        break
                    written += len(chunk)
                    require(written <= expected, "image_length_mismatch")
                    out.write(chunk)
                    digest.update(chunk)
                require(written == expected, "image_length_mismatch")
        except HTTPError:
            raise JobFailure("image_download_rejected") from None
        checksum = item.get("sha256")
        require(checksum is None or checksum == digest.hexdigest(), "image_checksum_mismatch")
        os.chmod(path, 0o600)
        sidecar = destination / item["relative_path"].replace("images/", "frames/").replace(".jpg", ".json")
        sidecar.write_bytes(json_bytes(item["frame"]))
        os.chmod(sidecar, 0o600)
    (destination / "manifest.json").write_bytes(json_bytes(job["manifest"]))
    os.chmod(destination / "manifest.json", 0o600)


class Lease:
    def __init__(self, api, job, *, interval=30):
        self.api, self.job, self.interval = api, job, interval
        self.stop = threading.Event()
        self.error = None
        self.progress = 0.05
        self.lock = threading.Lock()
        self.abort: Callable[[], None] = lambda: None
        # True initially because no provider allocation has been attempted. The
        # provider flips this BEFORE CREATE, including an ambiguous timeout, and
        # restores it only after a terminal poll. A retry must not overlap a GPU
        # whose lease was lost but whose provider lifetime is still uncertain.
        self.provider_stopped = True
        self.provider_attempted = False
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self.stop.wait(self.interval):
            try:
                self.beat()
            except Exception:
                self.error = JobFailure("lease_lost")
                # Losing authorization must stop compute, not merely prevent the
                # final result from being saved while the GPU keeps billing.
                try:
                    self.abort()
                except Exception as error:
                    # The provider TTL remains the last resort. Do not let a
                    # daemon-thread traceback print arbitrary SDK error bodies.
                    self.abort_failure_type = type(error).__name__
                return

    def check(self):
        if self.error:
            raise self.error
        deadline = datetime.fromisoformat(self.job["deadline_at"].replace("Z", "+00:00"))
        require(datetime.now(timezone.utc) < deadline, "job_deadline_exceeded")

    def beat(self):
        self.check()
        with self.lock:
            self.api.job_call(self.job, "heartbeat", progress=self.progress, cost_cents=0)

    def stage(self, progress):
        self.progress = max(self.progress, min(progress, 0.95))
        self.beat()

    def __enter__(self):
        self.beat()
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stop.set()
        self.thread.join(timeout=50)


def load_adapter():
    # One measured-pose adapter, shared by the experiment and cloud worker. Do
    # not re-derive camera conventions in a second implementation.
    root = str(TRAINING_ROOT)
    if root not in sys.path:
        sys.path.insert(0, root)
    import prepare_capture
    return prepare_capture


def upload_output(api, job, path, manifest, lease=None):
    size = path.stat().st_size
    require(0 < size <= MAX_OUTPUT_BYTES, "sog_output_too_large")
    data = path.read_bytes()  # Hard32MiB bound, unlike the unbounded capture.
    digest = hashlib.sha256(data).hexdigest()
    ticket = api.job_call(job, "output-ticket", bytes=size, sha256=digest)
    require(ticket.get("method") == "PUT" and ticket.get("bytes") == size
            and ticket.get("content_type") == "application/octet-stream", "invalid_output_ticket")
    url = https_url(ticket.get("upload_url"), {api.service_host})
    require(urlsplit(url).path == urlsplit(api.base_url).path + f"/worker/{job['id']}/output",
            "invalid_output_path")
    token = ticket.get("upload_token")
    require(isinstance(token, str) and token and "\n" not in token, "invalid_output_token")
    require(canonical_uuid(ticket.get("artifact_revision")), "invalid_output_revision")
    request = Request(url, data=data, method="PUT", headers={
        "Authorization": "Bearer " + token, "Content-Type": "application/octet-stream",
        "User-Agent": WORKER_USER_AGENT})
    try:
        with api.opener.open(request, timeout=120) as response:
            require(200 <= response.status < 300, "output_upload_rejected")
            receipt = json.loads(read_bounded(response, 65536))
            require(receipt.get("ok") is True, "output_upload_unconfirmed")
    except (HTTPError, OSError, ValueError):
        # Do not blindly repeat an ambiguous physical write. The control plane
        # retains the immutable attempt journal for reconciliation.
        raise JobFailure("output_upload_unconfirmed") from None
    manifest = {**manifest, "scene_id": job["id"], "artifact_revision": ticket["artifact_revision"],
                "bytes": size, "sha256": digest, "privacy_reviewed": False, "provenance": "captured"}
    def complete():
        return api.job_call(job, "complete", sog_bytes=size, sog_sha256=digest,
                            manifest=manifest, cost_cents=job["max_cost_cents"])
    if lease is None:
        return complete()
    # Keep the heartbeat alive through the potentially120s output upload. Only
    # stop it at the actual terminal call, serialized with an in-flight heartbeat.
    lease.stop.set()
    with lease.lock:
        lease.check()
        return complete()


def run_one(api, provider, allowed_input_hosts, *, scratch_parent=None):
    """One claimed attempt per call; no automatic paid retries in this process."""
    job = api.claim()
    if job is None:
        return {"status": "idle"}
    lease = Lease(api, job)
    try:
        validate_job(job)
        with tempfile.TemporaryDirectory(prefix="rendprop-spatial-job-", dir=scratch_parent) as tmp:
            root = Path(tmp)
            with lease:
                download_capture(job, root / "capture", allowed_input_hosts, check=lease.check)
                adapter = load_adapter()
                capture = adapter.load_capture(root / "capture")
                adapter.write_dataset(capture, root / "dataset")
                lease.stage(0.15)
                output, manifest = provider.reconstruct(job, root, capture, lease)
                lease.stage(0.9)
                lease.check()
                result = upload_output(api, job, output, manifest, lease)
            require(isinstance(result, dict) and result.get("status") in ("review", "ready"),
                    "generation_completion_unconfirmed")
            return {"status": result["status"], "job_id": job["id"]}
    except Exception as error:
        code = error.code if isinstance(error, JobFailure) else "generation_failed"
        if not lease.provider_attempted:
            try:
                from provider_journal import ProviderJournal
                ProviderJournal(lease, job).no_allocation()
            except Exception:
                # Missing/ambiguous acknowledgement remains cleanup debt. It is
                # not permission to erase a receipt or pretend a GPU was stopped.
                pass
        try:
            # Full reservation is retained, not guessed down from a timer or an
            # absent invoice. Billing reconciliation can settle actual cost later.
            api.job_call(job, "fail", failure_code=code, cost_cents=job["max_cost_cents"],
                         provider_stopped=lease.provider_stopped is True)
        except Exception:
            pass  # DB deadline fences publication and retains the reservation.
        raise JobFailure(code) from None
