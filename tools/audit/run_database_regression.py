#!/usr/bin/env python3
"""Replay repo migrations and invariants in a new local, socket-only cluster.

Never connects to an existing database or accepts a database URL. Child processes
get no inherited PG/service credentials. Data/logs are retained for diagnosis;
only the exact cluster created by this run is stopped in finally.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

# Assertions the owner has decided to keep red on purpose. Each entry is the
# exact `name` string tests/invariants.sql prints for that row, and the
# assertion's own comment there is the authority on why it stays visible
# instead of being weakened. A run whose ONLY failing assertions are in this
# set is accepted (exit 0) and announced loudly; any other failing assertion
# still exits 1. An entry that starts passing is a stale exception and also
# exits 1, so the list has to be trimmed in the same change that fixes it.
KEPT_RED = {
    # tests/invariants.sql, "each astra ceiling clears its route's visible
    # answer": the 0034 agent-reel seed sets max_output_tokens to 700, equal
    # to the visible MAX_AGENT_REEL_TOKENS answer, and that comment says to
    # keep the failure visible rather than enlarge the provider budget or
    # weaken > to >=. Owner decision: neither the invariant nor the ceiling
    # changes.
    "each astra ceiling clears its route's visible answer and stays under the code clamp",
}

# Exact size of the tests/invariants.sql inventory. A suite that prints fewer
# rows is rejected even when its footer agrees with itself, so this number has
# to move in the same change that adds or removes an assertion (234 since the
# 0046 commercial-telemetry section — activation stamp, org_is_real, cancelled_at,
# admin_cohorts/admin_churn; 213 for the 0044 plan-rework / industry-trial
# section; 198 before that).
INVARIANT_COUNT = 234


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def classify_failures(names, failed):
    """Split one invariant run's failures into the documented kept-red set and
    everything else. `stale` lists kept-red assertions that are present in the
    inventory but no longer fail."""
    kept = [name for name in failed if name in KEPT_RED]
    unexpected = [name for name in failed if name not in KEPT_RED]
    stale = sorted(name for name in KEPT_RED if name in names and name not in failed)
    return kept, unexpected, stale


def announce_kept_red(phase, names, kept):
    print("=" * 72, flush=True)
    print(f"KEPT-RED ({phase}): {len(kept)} assertion(s) failed and are accepted by owner decision", flush=True)
    for name in kept:
        print(f"  #{names.index(name) + 1} {name}", flush=True)
    print("  rationale: the assertion's own comment in services/supabase/tests/invariants.sql;", flush=True)
    print("  the exception list is KEPT_RED at the top of tools/audit/run_database_regression.py", flush=True)
    print("=" * 72, flush=True)


def invariant_rows(output, exit_code):
    # The independent inventory prevents a shortened table from becoming a
    # green suite merely because its printed footer matches the shorter count.
    rows = re.findall(r"^\s*(\d+) \| (.*?) \|\s*(t|f)?\s*\|", output, re.MULTILINE)
    require(len(rows) == INVARIANT_COUNT and [int(row[0]) for row in rows] == list(range(1, INVARIANT_COUNT + 1)),
            f"Missing/incomplete invariant inventory: expected {INVARIANT_COUNT} assertions")
    names = [name.strip() for _, name, _ in rows]
    require(len(set(names)) == len(names), "Duplicate invariant names")
    required = {
        "all three explicit Astra writing seats keep their 0030/0034 paid-plan gates",
        "no gpt-6-astra row is reachable on the free or trial tier",
        "plan_entitlements match paid plans and 0032 trial/free for every metered feature",
        "org_entitlement on a fitness trial org is the single-location free week (1/60/4/1/1, 1 seat, 1000¢)",
    }
    require(required.issubset(names), "Required paid-plan/entitlement gates absent")
    failed = [name.strip() for _, name, passed in rows if passed != "t"]
    require((not failed and exit_code == 0 and f"All {INVARIANT_COUNT} invariants passed." in output)
            or (failed and exit_code == 3 and f"INVARIANTS FAILED: {len(failed)} assertion(s)" in output),
            "Invariant exit/status disagrees with actual assertions")
    return names, failed


def main():
    root = Path(__file__).resolve().parents[2]
    require(not subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip(),
            "Checkpoint a clean source tree before database verification")
    environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC"}
    bins = {name: shutil.which(name) for name in ("initdb", "pg_ctl", "psql", "createdb")}
    require(all(bins.values()), "Use an already installed PostgreSQL distribution")
    require(shutil.disk_usage("/tmp").free >= 1024**3, "Less than 1 GiB available on the evidence filesystem")
    out = Path(tempfile.mkdtemp(prefix="rendprop-db-audit-", dir="/tmp"))
    data, sockets = out / "cluster", out / "socket"
    sockets.mkdir(mode=0o700)
    receipt = {"sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
               "startedAt": datetime.now(timezone.utc).isoformat(), "evidence": str(out), "commands": [],
               "network": "Unix socket only; listen_addresses empty", "accepted": False,
               "limits": ["Plain local Postgres, not hosted Supabase", "Minimal synthetic auth schema",
                          "No actual JWT verification or HTTP Data API", "No deployed cron verification"]}
    sqlroot = root / "services/supabase"
    migrations = sorted((sqlroot / "migrations").glob("*.sql"))
    sources = migrations + list(sorted((sqlroot / "tests").glob("*.sql"))) + [Path(__file__).resolve()]
    receipt["sourceHashes"] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    print("EVIDENCE:", out, flush=True)

    def run(name, command, expected=0, input_text=None):
        timed_out = False
        try:
            result = subprocess.run(command, env=environment, cwd=root, input=input_text, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
            output, code = result.stdout, result.returncode
        except subprocess.TimeoutExpired as error:
            output = error.stdout or ""
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            code, timed_out = None, True
        log = out / (name + ".log")
        log.write_text(output)
        receipt["commands"].append({"name": name, "command": command, "exit": code, "timedOut": timed_out,
                                    "log": str(log), "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
        require(not timed_out, f"{name} timed out; partial output retained in {log}")
        allowed = expected if isinstance(expected, tuple) else (expected,)
        require(code in allowed, f"{name} exited {code}, expected {expected}; see {log}")
        print(name + ": exit=" + str(code), flush=True)
        return output

    connection = ["-h", str(sockets), "-p", "55439", "-U", "postgres"]
    psql = [bins["psql"], "-X", "--no-password", *connection, "-d", "rendprop_audit",
            "-v", "ON_ERROR_STOP=1"]
    started = False
    prior_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP)}
    def interrupted(signum, _frame):
        raise RuntimeError(f"Audit interrupted by signal {signum}")
    for sig in prior_handlers:
        signal.signal(sig, interrupted)
    try:
        run("version", [bins["psql"], "--version"])
        run("initdb", [bins["initdb"], "-D", str(data), "-U", "postgres", "-A", "trust",
                       "--no-locale", "--encoding=UTF8"])
        run("start", [bins["pg_ctl"], "-D", str(data), "-l", str(out / "postgres.log"), "-w", "-t", "30",
                      "-o", f"-k {sockets} -p 55439 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20", "start"])
        started = True
        run("createdb", [bins["createdb"], "--no-password", *connection, "rendprop_audit"])
        identity = run("identity", psql + ["-Atc", "select current_setting('data_directory'),current_setting('listen_addresses'),current_database();"])
        require(identity.strip() == f"{data}||rendprop_audit", "Cluster identity/network mismatch")
        environment["PGOPTIONS"] = "-c statement_timeout=30000 -c lock_timeout=5000"
        run("bootstrap", psql + ["-q", "-f", str(sqlroot / "tests/ci-bootstrap.sql")])
        for migration in migrations:
            run("apply-" + migration.stem, psql + ["-q", "-1", "-f", str(migration)])
        counts = []
        receipt["invariantRuns"] = []
        for phase in ("initial", "replayed"):
            if phase == "replayed":
                replay = [p for p in migrations if p.name.startswith(("0005b_", "0008b_")) or p.name >= "0009"]
                for migration in replay:
                    run("replay-" + migration.stem, psql + ["-q", "-1", "-f", str(migration)])
                receipt["replayedMigrations"] = len(replay)
            output = run("invariants-" + phase, psql + ["-f", str(sqlroot / "tests/invariants.sql")], expected=(0, 3))
            # Preserve a genuine red suite, but still test migration replay.
            # A SQL/load error is not a completed red suite and aborts here.
            exit_code = receipt["commands"][-1]["exit"]
            names, failed_names = invariant_rows(output, exit_code)
            if receipt["invariantRuns"]:
                require(names == receipt["invariantRuns"][0]["names"], "Assertion identities changed on replay")
            kept, unexpected, stale = classify_failures(names, failed_names)
            if kept:
                announce_kept_red(phase, names, kept)
            receipt["invariantRuns"].append({"phase": phase, "count": len(names), "names": names, "failed": failed_names,
                                             "keptRedFailures": kept, "unexpectedFailures": unexpected,
                                             "staleKeptRed": stale})
            counts.append(len(names))
        require(counts[0] == counts[1], "Invariant count changed on replay")
        paid = run("negative-paid-gates", psql + ["-f", str(sqlroot / "tests/negative_astra_paid_gates.sql")])
        require("PASS: exact paid-plan predicates registered 6 expected outcomes across baseline and 2 negative fixtures; all mutations rolled back." in paid,
                "Paid gate negative fixture did not complete")
        receipt["paidGateNegativeControl"] = {"outcomes": 6, "fixtures": 2, "rolledBack": True}
        # The HTTP/Python mocks cannot prove a Postgres publication fence. Run
        # the real transaction/trigger fixtures, then deliberately remove each
        # relevant guard in THIS owned disposable database. A missing guard
        # must fail for the intended invariant, not merely a syntax/ACL error.
        publication_specs = [
            ("worker", "worker_publish_transaction.sql", "0035_worker_publish_transaction.sql",
             "WORKER_PUBLISH_TRANSACTION_PASS_22", "stale A accepted", 22),
            ("uploads", "negative_upload_publication.sql", "0036_upload_publication_immutability.sql",
             "PASS: 19 upload publication trigger checks; all synthetic mutations rolled back.",
             "Missing publication rejection: completed: uploaded = false", 19),
        ]
        receipt["publicationFixtures"] = []
        for name, fixture, migration_name, marker, failure, count in publication_specs:
            script = sqlroot / "tests" / fixture
            migration = sqlroot / "migrations" / migration_name
            require(script in sources and migration in sources, "Required publication sources missing from receipt")
            output = run("publication-" + name, psql + ["-f", str(script)])
            require(marker in output, f"{name} publication fixture did not finish")
            if name == "worker":
                mutant = migration.read_text()
                for guard in ("or v_job.worker_id is distinct from p_worker",
                              "or v_job.attempts is distinct from p_attempt"):
                    require(mutant.count(guard) == 1, "Worker mutation no longer matches one exact ownership guard")
                    mutant = mutant.replace(guard, "or false /* deliberate isolated ownership mutant */")
                run("mutate-publication-worker", psql, input_text=mutant)
            else:
                run("mutate-publication-uploads", psql + ["-c",
                    "alter table public.capture_assets disable trigger trg_capture_asset_publication;"])
            broken = run("negative-publication-" + name, psql + ["-f", str(script)], expected=3)
            require(failure in broken, f"{name} negative fixture failed for an unexpected reason")
            run("restore-publication-" + name, psql + ["-q", "-1", "-f", str(migration)])
            restored = run("restored-publication-" + name, psql + ["-f", str(script)])
            require(marker in restored, f"{name} publication fixture failed after restoring the source migration")
            receipt["publicationFixtures"].append({"name": name, "checksPerRun": count,
                "runs": 2, "negativeControlDetected": True, "sourceRestored": True})
            if name == "worker":
                guards = [
                    ("video", [("and a.kind = 'video' and a.uploaded", "and a.uploaded")],
                     "photo capture accepted as raw video"),
                    ("scalars", [(line, "") for line in (
                        "     or jsonb_typeof(p_render->'duration_s') is distinct from 'number'\n",
                        "     or jsonb_typeof(p_render->'speed_factor') is distinct from 'number'\n",
                        "     or round(v_duration, 2) is distinct from v_duration\n",
                        "     or round(v_speed, 2) is distinct from v_speed\n")],
                     "noncanonical scalar accepted:"),
                ]
                receipt["workerInputNegativeControls"] = []
                for guard_name, replacements, reason in guards:
                    mutant = migration.read_text()
                    for old, new in replacements:
                        require(mutant.count(old) == 1, f"{guard_name} mutation no longer matches exactly")
                        mutant = mutant.replace(old, new)
                    mutant += f"\n-- deliberate isolated worker-{guard_name} mutant\n"
                    run("mutate-worker-" + guard_name, psql, input_text=mutant)
                    broken = run("negative-worker-" + guard_name, psql + ["-f", str(script)], expected=3)
                    require(reason in broken, f"{guard_name} negative failed for the wrong reason")
                    run("restore-worker-" + guard_name, psql + ["-q", "-1", "-f", str(migration)])
                    restored = run("restored-worker-" + guard_name, psql + ["-f", str(script)])
                    require(marker in restored, f"{guard_name} restored fixture did not finish")
                    receipt["publicationFixtures"][-1]["runs"] += 1
                    receipt["workerInputNegativeControls"].append({"guard": guard_name,
                        "detected": True, "sourceRestored": True})
        # Break actual entitlement data in this synthetic database. A gate that
        # only prints results must not pass when the published contract is false.
        run("mutate-negative", psql + ["-c", "update public.plan_entitlements set seats=999 where plan='team';"])
        failed = run("negative-invariants", psql + ["-f", str(sqlroot / "tests/invariants.sql")], expected=3)
        require("INVARIANTS FAILED:" in failed, "Negative control failed for the wrong reason")
        require(re.search(r"plan_entitlements match[^\n]*\| f\s+\|[^\n]*team", failed),
                "Negative control did not detect the deliberately corrupted team entitlement")
        require(all(hashlib.sha256(p.read_bytes()).hexdigest() == receipt["sourceHashes"][str(p.relative_to(root))]
                    for p in sources), "SQL sources changed during run")
        # Only the documented kept-red set may be red. Anything else failing,
        # or a kept-red entry that has quietly started passing, is a real
        # result the receipt must not paper over.
        stale_kept_red = sorted({name for phase in receipt["invariantRuns"] for name in phase["staleKeptRed"]})
        receipt.update({"accepted": all(not phase["unexpectedFailures"] for phase in receipt["invariantRuns"])
                                    and not stale_kept_red,
                        "keptRed": sorted(KEPT_RED),
                        "keptRedFailures": sorted({name for phase in receipt["invariantRuns"] for name in phase["keptRedFailures"]}),
                        "staleKeptRed": stale_kept_red,
                        "appliedMigrations": len(migrations), "invariantsEachRun": counts[0],
                        "negativeControl": "Actual team entitlement corrupted; real invariant gate exited 3"})
    except BaseException as error:
        receipt.update({"accepted": False, "failure": f"{type(error).__name__}: {error}"})
        raise
    finally:
        try:
            if started or (data / "postmaster.pid").exists():
                run("stop", [bins["pg_ctl"], "-D", str(data), "-w", "-t", "30", "-m", "fast", "stop"])
            receipt["clusterStopped"] = not (data / "postmaster.pid").exists()
            require(receipt["clusterStopped"], "Owned cluster still has a PID file after stop")
        except BaseException as error:
            receipt.update({"accepted": False, "cleanupFailure": f"{type(error).__name__}: {error}"})
            raise
        finally:
            for sig, handler in prior_handlers.items():
                signal.signal(sig, handler)
            receipt["finishedAt"] = datetime.now(timezone.utc).isoformat()
            (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if receipt.get("staleKeptRed"):
        require(False, "Kept-red assertions now pass; remove them from KEPT_RED in the same change: "
                       + ", ".join(receipt["staleKeptRed"]))
    unexpected = sorted({name for phase in receipt["invariantRuns"] for name in phase["unexpectedFailures"]})
    require(receipt["accepted"], "Database assertions remain red outside the documented kept-red set ("
                                 + ", ".join(unexpected) + f"); full replay/negative evidence: {out / 'receipt.json'}")
    kept = receipt["keptRedFailures"]
    print("PASS: migrations, replay, actual invariants and negative control;", out / "receipt.json", flush=True)
    if kept:
        print(f"PASS WITH {len(kept)} KEPT-RED ASSERTION(S) still failing by owner decision: " + "; ".join(kept), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("FAIL:", type(error).__name__, str(error), flush=True)
        sys.exit(1)
