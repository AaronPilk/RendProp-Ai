"""Small durable control-plane receipts; never upload logs or room data here."""
import hashlib
from pathlib import Path

from worker import require

SOURCE_FILES = (
    "services/spatial-worker/app.py",
    "services/spatial-worker/worker.py", "services/spatial-worker/modal_provider.py",
    "services/spatial-worker/provider_journal.py", "services/spatial-worker/setup_service.sh",
    "tools/spatial-spike/training/modal_room.py", "tools/spatial-spike/training/run_training.py",
    "tools/spatial-spike/training/prepare_capture.py", "tools/spatial-spike/training/modal_setup.sh",
    "tools/spatial-spike/viewer/package.json", "tools/spatial-spike/viewer/package-lock.json",
)


def source_fingerprint():
    root = Path(__file__).resolve().parents[2]
    digest = hashlib.sha256()
    for name in SOURCE_FILES:
        digest.update(name.encode() + b"\0")
        digest.update(hashlib.sha256((root / name).read_bytes()).digest())
    return digest.hexdigest()


class ProviderJournal:
    def __init__(self, lease, job):
        self.lease, self.job = lease, job

    def write(self, action, **data):
        # This endpoint remains usable for existing receipts after job/account
        # deletion. Cleanup is a debt to discharge, not an authenticated-user UI.
        result = self.lease.api.job_call(self.job, "provider-attempt",
                                       attempt_key=self.job["attempt_key"], action=action, data=data)
        require(result.get("ok") is True and result.get("job_id") == self.job["id"]
                and result.get("lease_token") == self.job["lease_token"]
                and result.get("attempt_key") == self.job["attempt_key"], "provider_journal_unconfirmed")
        return result

    def plan(self, app_name, sandbox_name):
        result = self.write("plan", app_name=app_name, sandbox_name=sandbox_name,
                            source_sha256=source_fingerprint())
        # A response replay is not another allocation authorization. A lost first
        # response therefore fails closed and requires reconciliation by name.
        require(result.get("dispatch") is True, "provider_attempt_already_dispatched")

    def created(self, sandbox_id):
        result = self.write("created", sandbox_id=sandbox_id)
        require(result.get("sandbox_id") == sandbox_id, "provider_identity_unconfirmed")

    def no_allocation(self):
        # Failed downloads/adapter validation have a claimed job but no provider
        # entry yet. Record the absence atomically; never rewrite an older intent
        # that could represent another controller's ambiguous CREATE.
        result = self.write("not_created", origin="before_provider_entry", proof="create_not_invoked",
                            app_name="rendprop-spatial-worker",
                            sandbox_name="spatial-" + self.job["id"] + "-" + self.job["lease_token"],
                            source_sha256=source_fingerprint())
        require(result.get("allocation_state") == "not_created"
                and result.get("files_removed") is True and result.get("terminated") is True,
                "provider_no_allocation_unconfirmed")

    def cleanup(self, receipt):
        data = {"files_removed": receipt.get("private_files_removed") is True,
                "terminated": receipt.get("terminated") is True}
        if receipt.get("sandbox_id"):
            data["sandbox_id"] = receipt["sandbox_id"]
        terminal = receipt.get("provider_terminal", {})
        if terminal.get("reason") in ("billing_cycle_spend_limit", "provider_terminal", "unavailable"):
            data["reason_code"] = terminal["reason"]
        if type(receipt.get("exit_code")) is int and -255 <= receipt["exit_code"] <= 255:
            data["exit_code"] = receipt["exit_code"]
        if not data["terminated"]:
            data["last_error_code"] = "termination_failed"
        elif not data["files_removed"]:
            data["last_error_code"] = "files_remove_failed"
        result = self.write("cleanup", **data)
        # Another observer may already have stronger proof. Never turn a stale
        # false report into a failure when the durable flags truthfully advanced.
        require(all(type(result.get(flag)) is bool and (not data[flag] or result[flag])
                    for flag in ("files_removed", "terminated")), "provider_cleanup_receipt_unconfirmed")
