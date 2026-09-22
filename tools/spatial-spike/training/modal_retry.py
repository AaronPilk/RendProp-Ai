#!/usr/bin/env python3
"""One reviewed continuation of the existing $25 room approval; never auto-retry.

`plan` hashes private evidence without touching Modal. `run` is a separate,
explicitly confirmed operation and will reserve a new immutable marker under
the original approval lock before exactly one call to the existing runner.
"""
import argparse
from datetime import datetime, timezone
from decimal import Decimal
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import sys

import modal_room as room

PRIVATE_ROOT = Path.home() / "LocalSpatialExperiments"
ORIGINAL_MARKER = "room-approval-20260910.allocation.json"
RETRY_MARKER = "room-approval-20260910.retry-20260911.allocation.json"
EXPECTED_PRIOR_SANDBOX = "sb-YlvxENnLUiOzkWOg2854hq"
EXPECTED_PRIOR_APP = "ap-tAGAjTGmmAYtfOCfaayO1y"
PRIOR_SPENT = Decimal("1.09974939")
SOURCE_NAMES = (*room.SOURCE_FILES, "modal_room.py", "modal_retry.py")


def private_path(path, *, must_exist=True):
    room.require(not path.is_symlink() and path.resolve().is_relative_to(PRIVATE_ROOT.resolve()),
                 "private evidence must remain under LocalSpatialExperiments")
    if must_exist:
        room.require(path.exists(), "private evidence is missing")
    return path.resolve()


def bounded_json(path):
    private_path(path)
    room.require(path.is_file() and path.stat().st_size <= 2 * 1024**2, "invalid evidence file")
    result = json.loads(path.read_text())
    room.require(isinstance(result, dict), "evidence must be a JSON object")
    return result


def source_hashes():
    root = Path(__file__).resolve().parent
    return {name: room.sha(root / name) for name in SOURCE_NAMES}


def prepare(dataset, prior_state):
    dataset, prior_state = private_path(dataset), private_path(prior_state)
    marker_path = PRIVATE_ROOT / ORIGINAL_MARKER
    marker = bounded_json(marker_path)
    prior_path, billing_path = prior_state / "provider-receipt.json", prior_state / "provider-terminal-readback.json"
    prior, billing = bounded_json(prior_path), bounded_json(billing_path)
    room.require(marker.get("state") == str(prior_state) and marker.get("reserved_usd") == "25.00"
                 and marker.get("status") == "rental_attempt_reserved", "original approval lineage mismatch")
    room.require(prior.get("sandbox_id") == EXPECTED_PRIOR_SANDBOX and prior.get("app_id") == EXPECTED_PRIOR_APP
                 and prior.get("outcome") == "failed", "unexpected prior allocation")
    room.require(billing.get("sandbox_id") == EXPECTED_PRIOR_SANDBOX and billing.get("exit_code") == 137
                 and billing.get("actual_provider_report_usd") == str(PRIOR_SPENT), "prior usage not reconciled")
    files = room.inventory(dataset)
    room.require(sum(x["path"].startswith("images/") for x in files) == 153, "this retry is the approved 153-frame capture")
    fingerprint = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    cost = Decimal(room.policy()["compute_upper_bound_usd"])
    remaining = Decimal("25.00") - PRIOR_SPENT
    room.require(cost < remaining, "fresh full-lifetime bound exceeds remaining approval")
    return {"schema_version": 1, "approval_total_usd": "25.00", "prior_spent_usd": str(PRIOR_SPENT),
            "remaining_before_retry_usd": str(remaining), "fresh_compute_upper_bound_usd": str(cost),
            "combined_prior_plus_fresh_bound_usd": str(PRIOR_SPENT + cost),
            "allocation_count": 1, "automatic_retries": 0, "policy": room.policy(),
            "prior_state": str(prior_state), "original_marker_sha256": room.sha(marker_path),
            "prior_receipt_sha256": room.sha(prior_path), "billing_receipt_sha256": room.sha(billing_path),
            "prior_remote_directory_deletion_confirmed": billing.get("explicit_remote_directory_deletion_confirmed") is True,
            "dataset": str(dataset), "dataset_inventory_sha256": fingerprint,
            "dataset_files": len(files), "dataset_bytes": sum(x["bytes"] for x in files),
            "source_files": source_hashes(), "allocation_eligibility": "unknown_until_one_create_attempt"}


def run_retry(modal, plan_path, state):
    room.require(modal.__version__ == "1.5.3", "use pinned Modal SDK 1.5.3")
    plan = bounded_json(plan_path)
    expected = prepare(Path(plan["dataset"]), Path(plan["prior_state"]))
    room.require(plan == expected, "reconciliation, source, policy or capture changed since review")
    private_path(state, must_exist=False)
    room.require(not state.exists() and state.parent.is_dir(), "fresh private state directory required")
    room.source_binding()  # Includes committed-and-clean verification BEFORE reservation.
    marker = PRIVATE_ROOT / RETRY_MARKER
    room.require(not marker.exists(), "the one approved retry has already been attempted")
    app = modal.App.lookup(room.APP_NAME, create_if_missing=False)
    room.require(app.app_id == EXPECTED_PRIOR_APP, "experiment namespace changed")
    active = list(modal.Sandbox.list(app_id=app.app_id))
    room.require(len(active) == 0, "an experiment sandbox is still active")
    previous = modal.Sandbox.from_id(EXPECTED_PRIOR_SANDBOX)
    try:
        room.require(previous.poll() is not None, "previous allocation is not terminal")
    finally:
        previous.detach()
    # No erase/reset of the old marker. Even CREATE timeout consumes this marker;
    # another paid attempt needs a separately reviewed continuation, not a loop.
    room.save(marker, {"status": "single_retry_reserved", "utc": datetime.now(timezone.utc).isoformat(),
                       "state": str(state.resolve()), "plan_sha256": room.sha(plan_path),
                       "original_marker_sha256": plan["original_marker_sha256"],
                       "prior_spent_usd": plan["prior_spent_usd"],
                       "fresh_compute_upper_bound_usd": plan["fresh_compute_upper_bound_usd"],
                       "scoped_active_sandboxes_before_create": 0})
    room.run(modal, Path(plan["dataset"]), state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run"))
    parser.add_argument("--dataset", type=Path)
    parser.add_argument("--prior-state", type=Path)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--confirm-one-allocation", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "plan":
        room.require(args.dataset is not None and args.prior_state is not None, "dataset and prior-state required")
        private_path(args.plan, must_exist=False)
        room.require(not args.plan.exists() and args.plan.parent.is_dir(), "new private plan path required")
        result = prepare(args.dataset, args.prior_state)
        room.save(args.plan, result)
        print("PASS: private plan saved; no provider API or allocation invoked")
        return
    room.require(args.confirm_one_allocation and args.state is not None, "explicit one-allocation confirmation and state required")
    # Same approval lock used by the original runner; two processes cannot pass
    # the marker check simultaneously even if given different output paths.
    with (PRIVATE_ROOT / "room-approval-20260910.lock").open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ["MODAL_PROFILE"] = room.PROFILE
        import modal
        run_retry(modal, args.plan, args.state)


if __name__ == "__main__":
    def request_cleanup(signum, _frame):
        raise InterruptedError(f"experiment interrupted by signal {signum}")
    for experiment_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(experiment_signal, request_cleanup)
    try:
        main()
    except Exception as error:
        print("FAIL:", type(error).__name__, "inspect private receipts; no automatic retry", file=sys.stderr)
        sys.exit(1)
