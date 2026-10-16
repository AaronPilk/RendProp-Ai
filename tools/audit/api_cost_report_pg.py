#!/usr/bin/env python3
"""Disposable real-PostgreSQL proof of the owner accounting export path.

Boots an owned cluster, applies tests/ci-bootstrap.sql plus every migration,
seeds synthetic accounts through the actual RPCs/triggers, runs
`api_cost_snapshot.sql` exactly as the authenticated export would, and feeds
the result through `api_cost_report.py` (library and CLI). No network, no
provider call, no real account data. Evidence lands in --evidence-dir.

Proves, against the live schema rather than hand-written fixtures:
  * provider_attempt_receipts rows (unresolved intent, lost transport, priced
    hit with its ledger row, priced no_record without one) reach the report;
  * billing attribution follows billing_org_id stamped by the ledger trigger;
  * an uncertain studio-style receipt with no serving hold is disclosed;
  * an uncertain receipt WITH its hold reconciles instead of double counting;
  * two receipts with one attempt identity are flagged, never netted;
  * a tenant-scoped (authenticated, RLS) export is refused by the report, so a
    member-filtered read can never masquerade as whole-app accounting.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, os, shutil, subprocess, sys, tempfile, time

os.umask(0o077)
ROOT = Path(__file__).resolve().parents[2]
SQL = ROOT / "services/supabase"
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from api_cost_report import accounting_report  # noqa: E402

p = argparse.ArgumentParser()
p.add_argument("--evidence-dir", type=Path, required=True)
OUT = p.parse_args().evidence_dir.resolve()
OUT.mkdir(parents=True, exist_ok=False)
OUT.chmod(0o700)
EXTERNAL = Path("/Volumes/Rendprop Files")
DEADLINE = time.monotonic() + 900


def reserve():
    if sys.platform == "darwin":
        assert EXTERNAL.is_mount(), "External evidence volume must be mounted"
        assert OUT.is_relative_to(EXTERNAL), "Keep local database evidence on the external volume"
        assert shutil.disk_usage(Path.home()).free >= 3 * 1024**3, "Preserve internal 3GiB reserve"
        assert shutil.disk_usage(EXTERNAL).free >= 8 * 1024**3, "Preserve external 8GiB reserve"
    else:
        assert shutil.disk_usage(OUT).free >= 1024**3, "Preserve isolated CI evidence reserve"
    assert time.monotonic() < DEADLINE, "Whole proof deadline"


reserve()
ENV = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC", "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
pg_config = shutil.which("pg_config", path=ENV["PATH"])
if pg_config:
    bindir = subprocess.check_output([pg_config, "--bindir"], text=True, env=ENV, timeout=10).strip()
    ENV["PATH"] = bindir + os.pathsep + ENV["PATH"]
tool = lambda name: shutil.which(name, path=ENV["PATH"])
assert all(tool(name) for name in ["initdb", "pg_ctl", "createdb", "psql"]), "PostgreSQL tools must already be installed"
DATA = Path(tempfile.mkdtemp(prefix="cost-report-owned-pg-", dir=OUT))
SOCK = Path(tempfile.mkdtemp(prefix="cost-report-sock-", dir="/tmp"))
MIGRATIONS = sorted((SQL / "migrations").glob("*.sql"))
SNAPSHOT_SQL = HERE / "api_cost_snapshot.sql"
SOURCES = [*MIGRATIONS, SQL / "tests/ci-bootstrap.sql", SNAPSHOT_SQL, HERE / "api_cost_report.py", Path(__file__).resolve()]
hashes = lambda: {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in SOURCES}
r = {"passed": False, "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "sourceHashes": hashes(), "commands": [], "assertions": [], "networkCalls": 0, "providerCalls": 0, "liveMutations": False}
started = False
PORT = "55633"


def run(name, command, body=None, refuses=None):
    reserve()
    child = subprocess.run([str(x) for x in command], input=body, text=True, env=ENV, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    f = OUT / (name + ".log")
    f.write_text(child.stdout)
    r["commands"].append({"name": name, "exit": child.returncode, "logSHA256": hashlib.sha256(f.read_bytes()).hexdigest()})
    assert (child.returncode and refuses in child.stdout) if refuses else child.returncode == 0, (name, child.stdout[-4000:])
    return child.stdout


def check(ok, label):
    assert ok, "COST REPORT FAIL: " + label
    r["assertions"].append(label)


ACTOR = "a9200000-0000-4000-8000-000000000031"
MEMBER = "a9200000-0000-4000-8000-000000000032"
OTHER = "a9200000-0000-4000-8000-000000000033"

try:
    run("initdb", [tool("initdb"), "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [tool("pg_ctl"), "-D", DATA, "-l", OUT / "postgres.log", "-w", "-o", f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    conn = ["-h", SOCK, "-p", PORT, "-U", "postgres"]
    run("createdb", [tool("createdb"), *conn, "cost_report"])
    PSQL = [tool("psql"), "-X", "--no-password", *conn, "-d", "cost_report", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*PSQL, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for migration in MIGRATIONS:
        run("apply-" + migration.stem, [*PSQL, "-q", "-1", "-f", migration])
    r["migrationsApplied"] = len(MIGRATIONS)

    # ── Seed through the real triggers/RPCs (service role; no provider call) ──
    seed = f"""
begin;
insert into auth.users(id,email,is_anonymous)values
 ('{ACTOR}','cost-owner@fixture.invalid',false),('{MEMBER}','cost-member@fixture.invalid',false),('{OTHER}','cost-other@fixture.invalid',false);
create temporary table scope as select
 (select org_id from memberships where user_id='{ACTOR}'and role='owner'limit 1)org,
 (select org_id from memberships where user_id='{MEMBER}'and role='owner'limit 1)member_org,
 (select org_id from memberships where user_id='{OTHER}'and role='owner'limit 1)other_org;
grant select on scope to service_role;
set local role service_role;
-- Provider attempt journal through the actual RPCs.
create temporary table a_intent as select public.provider_attempt_begin('{ACTOR}',(select org from scope),repeat('1',64),repeat('a',64))r;
create temporary table a_lost as select public.provider_attempt_begin('{ACTOR}',(select org from scope),repeat('2',64),repeat('a',64))r;
select public.provider_attempt_finish('{ACTOR}',(select org from scope),(select(r->>'attempt_id')::uuid from a_lost),'transport_unknown',null,null,null,'not_booked');
create temporary table a_hit as select public.provider_attempt_begin('{ACTOR}',(select org from scope),repeat('3',64),repeat('a',64))r;
select public.provider_attempt_finish('{ACTOR}',(select org from scope),(select(r->>'attempt_id')::uuid from a_hit),'hit',200,'0f1e2d3c-4b5a-4968-8776-655443322110',7,'recorded');
insert into public.cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
 select org,'property_lookup','rentcast','properties',1,7,7,jsonb_build_object('result','hit','provider_attempt_id',(select r->>'attempt_id' from a_hit),'cost_basis','configured_per_call_estimate') from scope;
create temporary table a_miss as select public.provider_attempt_begin('{ACTOR}',(select org from scope),repeat('4',64),repeat('a',64))r;
select public.provider_attempt_finish('{ACTOR}',(select org from scope),(select(r->>'attempt_id')::uuid from a_miss),'no_record',404,null,7,'unconfirmed');
create temporary table a_err as select public.provider_attempt_begin('{OTHER}',(select other_org from scope),repeat('5',64),repeat('a',64))r;
select public.provider_attempt_finish('{OTHER}',(select other_org from scope),(select(r->>'attempt_id')::uuid from a_err),'http_error',500,null,null,'not_booked');
-- Studio-style uncertain receipt with NO hold (booked in finally after a funding refusal).
insert into public.cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
 select org,'copy_assist','openai','gpt-5.6-mini',1,0.41,0.41,jsonb_build_object('kind','edit_plan','attempts',1,'outcome','uncertain','price_estimated',true,'request_key','req-nohold','stage','studio.edit_plan') from scope;
-- Uncertain receipt WITH its uncertain ceiling hold (lost reply after dispatch).
-- Holds are seeded as the migrating superuser: the funded-serving RPC chain
-- (funding, allowance, quote) is not under test here; the export path is.
reset role;
insert into public.serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,state,budget_source)
 select org,'{ACTOR}','req-held','studio.edit_plan','openai','gpt-5.6-mini',repeat('b',64),'copy-20261010',0.41,'uncertain','ceiling' from scope;
set local role service_role;
insert into public.cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
 select org,'copy_assist','openai','gpt-5.6-mini',1,0.41,0.41,jsonb_build_object('kind','edit_plan','attempts',1,'outcome','uncertain','price_estimated',true,'request_key','req-held','stage','studio.edit_plan') from scope;
-- Two receipts, one attempt identity (lost reply + retried write).
insert into public.cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
 select org,'photo_helper','gemini','gemini-3.6-flash',1,0.2,0.2,jsonb_build_object('request_key','req-dup','stage','photo.suggest') from scope union all
 select org,'photo_helper','gemini','gemini-3.6-flash',1,0.2,0.2,jsonb_build_object('request_key','req-dup','stage','photo.suggest') from scope;
-- A foreign library's receipt: must appear in the whole-app export and never in a tenant export.
insert into public.cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
 select other_org,'photo_edit','gemini','gemini-3.1-flash-image',1,3.9,3.9,jsonb_build_object('request_key','req-other','stage','photo.stage:0') from scope;
-- An open serving hold that lost its reply and was never booked.
reset role;
insert into public.serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,state,budget_source)
 select other_org,'{OTHER}','req-lost','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('c',64),'photo-20261010',3.9,'uncertain','ceiling' from scope;
select jsonb_build_object('org',org,'other_org',other_org,'hit',(select r->>'attempt_id' from a_hit),'miss',(select r->>'attempt_id' from a_miss)) from scope;
commit;
"""
    seeded = json.loads([line for line in run("seed", [*PSQL, "-Atq"], seed).splitlines() if line.startswith("{")][-1])
    r["seed"] = {"ledgerRows": 6, "servingHolds": 2, "providerAttempts": 5}

    snapshot_sql = SNAPSHOT_SQL.read_text()
    # ── Whole-app export exactly as the owner runs it (service role, RLS bypass) ──
    whole = json.loads(run("snapshot-service-role", [*PSQL, "-Atq"], "set role service_role;\n" + snapshot_sql))
    (OUT / "snapshot.private.json").write_text(json.dumps(whole, indent=2))
    check(whole["schema"] == 2 and whole["authority"]["bypass_rls"] is True, "service export carries schema 2 and RLS-bypass authority")
    check(whole["counts"]["provider_attempts"] == 5 and len(whole["provider_attempts"]) == 5, "all five attempt receipts exported with a matching count")
    check(whole["counts"]["ledger"] == 6 and whole["counts"]["serving"] == 2, "ledger and serving counts match seeded rows")
    check(all(set(a) >= {"outcome", "estimated_cents", "price_basis", "ledger_status", "actual_cents", "billing_org_id"} for a in whole["provider_attempts"]), "attempt export carries outcome/estimate/basis/ledger-status/billing columns")
    check(not any("operation_sha256" in a or "input_sha256" in a for a in whole["provider_attempts"]), "attempt export excludes operation/input hashes")
    report = accounting_report(whole)
    (OUT / "report.private.json").write_text(json.dumps(report, indent=2))
    journal = report["provider_attempt_journal"]
    check(journal["exported"] and journal["by_outcome"] == {"intent": 1, "hit": 1, "no_record": 1, "http_error": 1, "invalid_response": 0, "transport_unknown": 1}, "report counts every attempt outcome")
    check(len(journal["unknown_outcome_attempts"]) == 2 and all(x["estimated_cents"] is None for x in journal["unknown_outcome_attempts"]) and journal["unknown_outcome_cents"] is None, "unresolved intent and lost transport are unknown, not zero")
    check(journal["priced_attempt_estimate_cents_not_added_to_ledger_total"] == "14.0000" and report["totals"]["recorded_ledger_cents"] == "12.1200", "attempt estimates are not added to recorded consumption")
    check([m["outcome"] for m in journal["priced_attempts_without_retained_ledger_row"]] == ["no_record"] and journal["priced_attempts_without_retained_ledger_cents"] == "7.0000", "priced no_record without a ledger row is a reconciliation item")
    hit = next(x for x in journal["priced_attempts"] if x["outcome"] == "hit")
    check(len(hit["retained_ledger_ids"]) == 1 and hit["supplier_request_id"] == "0f1e2d3c-4b5a-4968-8776-655443322110", "priced hit links to its retained ledger row and supplier request id")
    lines = {line["stage"]: line for line in report["ledger"] if line["stage"]}
    by_id = {line["ledger_id"]: line for line in report["ledger"]}
    uncertain = [line for line in report["ledger"] if line["uncertain_dispatch_context"]]
    check(len(uncertain) == 2, "both uncertain studio receipts are disclosed")
    check(sum(line["recorded_without_matching_attempt_hold"] for line in uncertain) == 1, "exactly the hold-less uncertain receipt is flagged as possibly never dispatched")
    check(report["totals"]["recorded_in_uncertain_dispatch_context_cents"] == "0.8200" and report["totals"]["recorded_without_matching_attempt_hold_cents"] == "0.4100", "uncertain context totals stay recorded, never discounted")
    held = [h for h in report["unledgered_holds"]]
    check(len(held) == 1 and held[0]["hold_cents"] == "3.9000" and held[0]["state"] == "uncertain", "the lost-reply hold without a receipt is the only unledgered hold; the held studio receipt reconciled by attempt identity")
    dups = report["possible_duplicate_attempt_rows"]
    check(len(dups) == 1 and len(dups[0]["ledger_ids"]) == 2 and dups[0]["stage"] == "photo.suggest", "two receipts with one attempt identity are flagged")
    check(report["totals"]["recorded_ledger_cents"] == "12.1200", "duplicate candidates are flagged, not netted")
    # Billing attribution stamped by the live trigger (solo libraries bill to themselves here).
    accounts = {s["scope"]: s["recorded_cents"] for s in report["scope_totals"] if s["dimension"] == "account"}
    check(len(accounts) == 2 and all(v != "0.0000" for v in accounts.values()), "two paying accounts attributed from trigger-stamped billing_org_id")
    check(all(row.get("billing_org_id") for row in whole["ledger"]), "every seeded ledger row carries a trigger-stamped billing_org_id")
    text = json.dumps(report)
    check("fixture.invalid" not in text and ACTOR not in text and seeded["org"] not in text and "req-dup" not in text, "report pseudonymises accounts, actors and request keys")

    # ── Tenant-scoped export: provider_attempt_receipts is revoked from the
    # authenticated role, so a member-scoped run of the export fails outright
    # instead of silently returning that member's slice.
    run("snapshot-authenticated-refused", [*PSQL, "-Atq"], "set role authenticated;\n" + snapshot_sql, refuses="permission denied")
    check(True, "tenant role cannot run the whole-app export at all (provider_attempt_receipts is service-only)")
    # A forged tenant snapshot without bypass authority is refused by the report.
    forged = {**whole, "authority": {"database_role": "authenticated", "bypass_rls": False}}
    try:
        accounting_report(forged); check(False, "unreachable")
    except ValueError as error:
        check("all-account read authority" in str(error), "report refuses a member-scoped export as whole-app accounting")

    # ── CLI path writes private files and a manifest ──
    cli_out = OUT / "cli"
    run("cli", [sys.executable, "-I", HERE / "api_cost_report.py", "--snapshot", OUT / "snapshot.private.json", "--out", cli_out])
    manifest = json.loads((cli_out / "manifest.json").read_text())
    check(manifest["live_mutations"] is False and manifest["provider_calls"] is False, "CLI manifest records no mutation and no provider call")
    check(oct((cli_out / "report.private.json").stat().st_mode & 0o777) == "0o600", "CLI report file is private (0600)")
    csv_head = (cli_out / "ledger.private.csv").read_text().splitlines()[0]
    check("uncertain_dispatch_context" in csv_head and "recorded_without_matching_attempt_hold" in csv_head, "CSV exposes the new context columns")

    check(hashes() == r["sourceHashes"], "consumed sources unchanged during proof")
    r["passed"] = True
    print(json.dumps({"passed": True, "assertions": len(r["assertions"]), "migrations": r["migrationsApplied"], "evidence": str(OUT)}))
finally:
    cleanup_error = None
    if started or (DATA / "postmaster.pid").exists():
        try:
            stop = subprocess.run([tool("pg_ctl"), "-D", str(DATA), "-m", "immediate", "-w", "stop"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV, timeout=30)
            (OUT / "stop.log").write_text(stop.stdout)
            r["ownedClusterStopped"] = stop.returncode == 0
            if stop.returncode: cleanup_error = "Owned PostgreSQL cleanup failed"
        except BaseException as error:
            r["ownedClusterStopped"] = False
            cleanup_error = "Owned PostgreSQL cleanup failed: " + type(error).__name__
    if cleanup_error: r["passed"] = False
    r["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (OUT / "receipt.json").write_text(json.dumps(r, indent=2) + "\n")
    if r.get("ownedClusterStopped") or not started and not (DATA / "postmaster.pid").exists():
        shutil.rmtree(DATA, ignore_errors=True)
        shutil.rmtree(SOCK, ignore_errors=True)
    if cleanup_error: raise RuntimeError(cleanup_error)
