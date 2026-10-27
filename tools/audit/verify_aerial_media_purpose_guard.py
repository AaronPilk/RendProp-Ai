#!/usr/bin/env python3
"""Prove the aerial-purpose guard still refuses default and metadata changes.

Run immediately before the exact source migration on a disposable database.
Each mutant is submitted as one transaction and must leave all three function
definitions unchanged after its guard refuses the migration.
"""

import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile

from run_database_regression import GUARDED_ONE_SHOT_MIGRATIONS


MIGRATION = "20261023191327_studio_internal_aerial_media_purpose_20261023.sql"
REFUSAL = "Aerial media purpose changed unrelated metadata or body"
SIGNATURES = (
    "public.assert_recorded_render_source(uuid,uuid)",
    "public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)",
    "public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)",
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("migration", type=Path)
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--host")
    parser.add_argument("--port")
    parser.add_argument("--user")
    parser.add_argument("--database")
    args = parser.parse_args()
    source = args.migration
    exact = Path(__file__).resolve().parents[2] / "services/supabase/migrations" / MIGRATION
    require(source.resolve() == exact.resolve(), "Use the exact repository aerial-purpose migration")
    require(hashlib.sha256(source.read_bytes()).hexdigest() == GUARDED_ONE_SHOT_MIGRATIONS[MIGRATION][0],
            "Aerial-purpose source hash changed")
    sql = source.read_text()
    match = re.search(r"\$new1\$(.*?)\$new1\$;", sql, re.DOTALL)
    require(match is not None, "Aerial-purpose gallery replacement missing")

    connection = [args.psql, "-X", "--no-password", "-v", "ON_ERROR_STOP=1"]
    for flag, value in (("-h", args.host), ("-p", args.port), ("-U", args.user), ("-d", args.database)):
        if value is not None:
            connection.extend((flag, value))

    signatures = ",".join("to_regprocedure('" + signature + "')" for signature in SIGNATURES)
    snapshot_sql = ("select proname||':'||md5(pg_get_functiondef(oid))||':'||"
                    "coalesce(pg_get_expr(proargdefaults,0),'') from pg_proc "
                    f"where oid in ({signatures}) order by proname")

    def snapshot():
        result = subprocess.run(connection + ["-At", "-c", snapshot_sql], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        require(result.returncode == 0, "Aerial-purpose function snapshot failed")
        rows = result.stdout.splitlines()
        require(len(rows) == len(SIGNATURES), "Aerial-purpose predecessor functions missing")
        return rows

    before = snapshot()
    cases = (
        ("default", "p_provenance uuid DEFAULT NULL::uuid",
         "p_provenance uuid DEFAULT '00000000-0000-0000-0000-000000000000'::uuid"),
        ("volatility", "LANGUAGE plpgsql\n STABLE SECURITY DEFINER",
         "LANGUAGE plpgsql\n VOLATILE SECURITY DEFINER"),
    )
    for name, old, new in cases:
        require(match.group(1).count(old) == 1, f"{name} mutation no longer matches one replacement clause")
        changed = match.group(1).replace(old, new)
        mutant = sql[:match.start(1)] + changed + sql[match.end(1):]
        with tempfile.TemporaryDirectory(prefix="rp-aerial-purpose-") as owned:
            path = Path(owned) / (name + ".sql")
            path.write_text(mutant)
            result = subprocess.run(connection + ["-q", "-1", "-f", str(path)], text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        require(result.returncode == 3 and REFUSAL in result.stdout,
                f"{name} mutation did not refuse for the expected guard (exit {result.returncode})")
        require(snapshot() == before, f"{name} mutation changed a function despite transaction rollback")
        print(f"PASS: aerial-purpose {name} mutation refused atomically")


if __name__ == "__main__":
    main()
