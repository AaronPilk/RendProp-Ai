#!/usr/bin/env python3
"""
Regression test for services/worker/r2.py's connect/read timeouts (external
release audit finding 4): `download_file`/`upload_file` previously ran on
boto3's undeclared, un-configurable default socket timeout. Both are now
explicit and set from env, with sane defaults.

    python3 tests/test_r2_timeouts.py

Stdlib + boto3 (already a worker dependency — see requirements.txt). Makes no
network calls: only inspects the boto3 client's resolved Config.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

FAILURES: list[str] = []


def check(label: str, cond: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'} {label}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


def load_r2_module(**env: str):
    """Import services/worker/r2.py (and settings.py) fresh with the given env."""
    for mod in ("r2", "settings"):
        sys.modules.pop(mod, None)
    for k, v in env.items():
        os.environ[k] = v
    import r2 as r2_module  # noqa: WPS433
    return r2_module


BASE_ENV = {
    "CLOUDFLARE_ACCOUNT_ID": "acct123",
    "R2_ACCESS_KEY_ID": "key",
    "R2_SECRET_ACCESS_KEY": "secret",
}


def test_default_timeouts_are_explicit_and_sane() -> None:
    print("\n1. connect/read timeouts have explicit, sane defaults when unset")
    for var in ("R2_CONNECT_TIMEOUT_S", "R2_READ_TIMEOUT_S"):
        os.environ.pop(var, None)
    r2 = load_r2_module(**BASE_ENV)
    client = r2._client()
    cfg = client.meta.config
    check("connect_timeout defaults to 10s", cfg.connect_timeout == 10.0, str(cfg.connect_timeout))
    check("read_timeout defaults to 60s", cfg.read_timeout == 60.0, str(cfg.read_timeout))
    check("neither is None (undeclared/unbounded — the bug this fixes)",
          cfg.connect_timeout is not None and cfg.read_timeout is not None)


def test_timeouts_are_configurable_via_env() -> None:
    print("\n2. R2_CONNECT_TIMEOUT_S / R2_READ_TIMEOUT_S override the defaults")
    r2 = load_r2_module(**BASE_ENV, R2_CONNECT_TIMEOUT_S="3.5", R2_READ_TIMEOUT_S="120")
    client = r2._client()
    cfg = client.meta.config
    check("connect_timeout honours the env override", cfg.connect_timeout == 3.5, str(cfg.connect_timeout))
    check("read_timeout honours the env override", cfg.read_timeout == 120.0, str(cfg.read_timeout))


def test_malformed_timeout_fails_loud() -> None:
    print("\n3. a malformed timeout value stops the worker rather than silently defaulting "
          "(consistent with settings.py's ConfigError policy — audit F-G-11)")
    os.environ["R2_CONNECT_TIMEOUT_S"] = "not-a-number"
    os.environ.pop("R2_READ_TIMEOUT_S", None)
    for mod in ("r2", "settings"):
        sys.modules.pop(mod, None)
    for k, v in BASE_ENV.items():
        os.environ[k] = v
    try:
        import settings  # noqa: WPS433
        check("importing settings with a bad timeout raises SystemExit", False, "did not raise")
    except SystemExit:
        check("importing settings with a bad timeout raises SystemExit", True)
    finally:
        os.environ.pop("R2_CONNECT_TIMEOUT_S", None)


if __name__ == "__main__":
    test_default_timeouts_are_explicit_and_sane()
    test_timeouts_are_configurable_via_env()
    test_malformed_timeout_fails_loud()
    print()
    if FAILURES:
        print(f"✗ {len(FAILURES)} failure(s): {FAILURES}")
        sys.exit(1)
    print("✓ all r2-timeout tests passed")
