#!/usr/bin/env python3
"""Stable merge check for all applicable dependency-security jobs; no API access."""
import os
import sys


def accepted(event, inventory, audit, review):
    if event not in {"push", "pull_request", "workflow_dispatch", "schedule"}:
        return False
    return (
        inventory == "success"
        and audit == "success"
        and review == ("success" if event == "pull_request" else "skipped")
    )


if __name__ == "__main__":
    ok = accepted(*(os.environ.get(key) for key in (
        "SECURITY_EVENT", "INVENTORY_RESULT", "AUDIT_RESULT", "REVIEW_RESULT"
    )))
    print("Dependency security required: " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)
