#!/usr/bin/env python3
"""Verify an exact guarded migration refuses its own second application in CI."""

import hashlib
from pathlib import Path
import subprocess
import sys

from run_database_regression import GUARDED_ONE_SHOT_MIGRATIONS


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_guarded_one_shot_refusal.py migration.sql")
    path = Path(sys.argv[1])
    expected_path = Path(__file__).resolve().parents[2] / "services/supabase/migrations" / path.name
    if path.resolve() != expected_path.resolve() or path.name not in GUARDED_ONE_SHOT_MIGRATIONS:
        raise SystemExit("Refusal check requires an exact classified migration path")
    digest, refusal = GUARDED_ONE_SHOT_MIGRATIONS[path.name]
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"Guarded one-shot migration changed: {path.name}")
    result = subprocess.run(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-q", "-1", "-f", str(path)],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            check=False, timeout=300)
    if result.returncode != 3 or refusal not in result.stdout:
        raise SystemExit(f"{path.name}: second application did not refuse for its pinned reason "
                         f"(exit {result.returncode})")
    print(f"PASS: guarded second application refused: {path.name}")


if __name__ == "__main__":
    main()
