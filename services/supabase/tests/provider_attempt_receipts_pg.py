#!/usr/bin/env python3
"""Disposable real-PG receipt authority/replay/race/erasure proofs. No network."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse, datetime, hashlib, json, os, shutil, subprocess, sys, tempfile, time, signal

os.umask(0o077)

ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / "services/supabase"
p = argparse.ArgumentParser()
p.add_argument("--evidence-dir", type=Path, required=True)
OUT = p.parse_args().evidence_dir.resolve()
OUT.mkdir(parents=True, exist_ok=False)
OUT.chmod(0o700)
EXTERNAL = Path("/Volumes/Rendprop Files")
DEADLINE = time.monotonic() + 600


def reserve():
    if sys.platform == "darwin":
        assert EXTERNAL.is_mount(), "External evidence volume must be mounted"
        assert OUT.is_relative_to(EXTERNAL), "Keep local database evidence on the external volume"
        assert shutil.disk_usage(Path.home()).free >= 3 * 1024**3, "Preserve internal3GiB reserve"
        assert shutil.disk_usage(EXTERNAL).free >= 8 * 1024**3, "Preserve external8GiB reserve"
    else:
        assert shutil.disk_usage(OUT).free >= 1024**3, "Preserve isolated CI evidence reserve"
    assert time.monotonic() < DEADLINE, "Whole proof deadline"


reserve()
ENV = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC", "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
pg_config = shutil.which("pg_config", path=ENV["PATH"])
if pg_config:
    bindir = subprocess.check_output([pg_config, "--bindir"], text=True, env=ENV, timeout=10).strip()
    assert Path(bindir).is_absolute() and Path(bindir).is_dir(), "PostgreSQL tool directory is required"
    ENV["PATH"] = bindir + os.pathsep + ENV["PATH"]
tool = lambda name: shutil.which(name, path=ENV["PATH"])
assert all(tool(name) for name in ["initdb", "pg_ctl", "createdb", "psql"]), "PostgreSQL tools must already be installed"
DATA = Path(tempfile.mkdtemp(prefix="provider-receipt-owned-pg-", dir=OUT))
SOCK = Path(tempfile.mkdtemp(prefix="provider-receipt-sock-", dir="/tmp"))
MIG = SQL / "migrations/20261016192846_provider_attempt_receipts.sql"
FIX = SQL / "tests/provider_attempt_receipts.sql"
MIGRATIONS = sorted((SQL / "migrations").glob("*.sql"))
SOURCES = [*MIGRATIONS, SQL / "tests/ci-bootstrap.sql", FIX, Path(__file__).resolve()]
hashes = lambda: {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in SOURCES}
r = {"passed": False, "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "sourceHashes": hashes(), "commands": [], "controls": [], "races": [], "networkCalls": 0, "providerCalls": 0, "runtime": {"platform": sys.platform, "python": sys.version, "postgresTools": {name: tool(name) for name in ["initdb", "pg_ctl", "createdb", "psql"]}, "proofDeadlineSeconds": 600}}
started = False
def terminate(_signal, _frame):
    raise SystemExit("Stopped by outer resource/wall guard")
signal.signal(signal.SIGTERM, terminate)


def run(name, command, body=None, refuses=None):
    reserve()
    child = subprocess.Popen([str(x) for x in command], stdin=subprocess.PIPE, text=True, env=ENV, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        end = time.monotonic() + 120
        while True:
            try:
                output, _ = child.communicate(input=body, timeout=.5)
                break
            except subprocess.TimeoutExpired:
                body = None
                reserve()
                assert time.monotonic() < end, "Command deadline"
    except BaseException as failure:
        child.kill()
        try:
            output, _ = child.communicate(timeout=5)
        except subprocess.TimeoutExpired as drain:
            # A descendant may still own a pipe. Do not let diagnostic output
            # prevent the exact owned-cluster cleanup in the outer finally.
            output = drain.output or ""
            if isinstance(output, bytes): output = output.decode("utf-8", "replace")
            for pipe in [child.stdin, child.stdout, child.stderr]:
                if pipe is not None: pipe.close()
            child.wait(timeout=5)
        f = OUT / (name + ".log")
        f.write_text(output)
        r["commands"].append({"name": name, "exit": child.returncode, "failure": type(failure).__name__, "logSHA256": hashlib.sha256(f.read_bytes()).hexdigest()})
        raise
    f = OUT / (name + ".log")
    f.write_text(output)
    r["commands"].append({"name": name, "exit": child.returncode, "logSHA256": hashlib.sha256(f.read_bytes()).hexdigest()})
    assert (child.returncode and refuses in output) if refuses else child.returncode == 0, (name, output[-4000:])
    return output


try:
    run("initdb", [tool("initdb"), "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [tool("pg_ctl"), "-D", DATA, "-l", OUT / "postgres.log", "-w", "-o", f"-k {SOCK} -p 55629 -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    conn = ["-h", SOCK, "-p", "55629", "-U", "postgres"]
    run("createdb", [tool("createdb"), *conn, "provider_receipts"])
    PSQL = [tool("psql"), "-X", "--no-password", *conn, "-d", "provider_receipts", "-v", "ON_ERROR_STOP=1"]
    assert run("owned-cluster-identity", [*PSQL, "-Atq", "-c", "select current_setting('data_directory'),current_setting('listen_addresses')"]).strip() == str(DATA) + "|"
    run("bootstrap", [*PSQL, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    catalog = """select jsonb_build_object('functions',(select md5(string_agg(jsonb_build_array(p.oid::regprocedure::text,md5(p.prosrc),pg_get_userbyid(p.proowner),p.prosecdef,p.provolatile,p.proconfig,p.proacl::text)::text,E'\n'order by p.oid::regprocedure::text))from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind in('f','p')and p.proname not in('provider_attempt_begin','provider_attempt_finish')),'constraints',(select md5(string_agg(conrelid::regclass||':'||conname||':'||pg_get_constraintdef(c.oid),E'\n'order by conrelid::regclass::text,conname))from pg_constraint c join pg_class t on t.oid=c.conrelid where c.connamespace='public'::regnamespace and t.relname<>'provider_attempt_receipts'),'config',(select md5(string_agg(to_jsonb(t)::text,E'\n'order by key))from app_config t),'routes',(select md5(string_agg(to_jsonb(t)::text,E'\n'order by id))from ai_routes t));"""
    for migration in MIGRATIONS:
        if migration == MIG:
            assert run("owned-objects-absent", [*PSQL, "-Atq", "-c", "select to_regclass('public.provider_attempt_receipts')is null and not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname in('provider_attempt_begin','provider_attempt_finish'))"]).strip() == "t"
            boundary = json.loads(run("before-own-boundary", [*PSQL, "-Atq", "-c", catalog]))
        run("apply-" + migration.stem, [*PSQL, "-q", "-1", "-f", migration])
        if migration == MIG:
            assert json.loads(run("after-own-boundary", [*PSQL, "-Atq", "-c", catalog])) == boundary, "Existing authority/config/routes changed"
    for stage in ["fresh", "replay"]:
        if stage == "replay": run("replay-own", [*PSQL, "-q", "-1", "-f", MIG])
        out = run(stage + "-actual", [*PSQL, "-Atq", "-f", FIX])
        rows = [json.loads(line) for line in out.splitlines() if line.startswith('{') and 'assertions' in line]
        assert len(rows) == 1 and rows[0]["passed"]
        r[stage] = rows[0]
    before = "public.provider_attempt_begin(uuid,uuid,text,text)"
    finish = "public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)"
    for label, signature, anchor, replacement, oracle in [
        ("duplicate-dispatch", before, "dispatch boolean:=false", "dispatch boolean:=true", "duplicate intent cannot dispatch"),
        ("changed-input", before, "if r.input_sha256<>p_input_sha256 then", "if false then", "altered input cannot reuse operation"),
        ("finish-scope", finish, "where id=p_attempt and actor_id=p_actor and org_id=p_org for update", "where id=p_attempt for update", "foreign actor cannot finish receipt"),
        ("immutable-terminal", finish, "if r.outcome<>'intent'then", "if false then", "identical terminal receipt replays"),
    ]:
        original = run("read-" + label, [*PSQL, "-Atq", "-c", f"select pg_get_functiondef('{signature}'::regprocedure)"])
        assert original.count(anchor) == 1
        run("compile-" + label, [*PSQL, "-Atq"], original.replace(anchor, replacement))
        run("negative-" + label, [*PSQL, "-Atq", "-f", FIX], refuses=oracle)
        run("restore-" + label, [*PSQL, "-Atq"], original)
        r["controls"].append({"name": label, "compiledActualSQL": True, "oracle": oracle})
    run("compile-direct-write-grant", [*PSQL, "-Atq", "-c", "grant insert on public.provider_attempt_receipts to service_role"])
    run("negative-direct-write-grant", [*PSQL, "-Atq", "-f", FIX], refuses="service table writes revoked")
    run("restore-direct-write-grant", [*PSQL, "-Atq", "-c", "revoke insert on public.provider_attempt_receipts from service_role"])
    r["controls"].append({"name": "direct-write-grant", "compiledActualSQL": True, "oracle": "service table writes revoked"})
    run("restored-positive", [*PSQL, "-Atq", "-f", FIX])
    actor = "a9100000-0000-4000-8000-000000000021"
    run("race-seed", [*PSQL, "-Atq"], f"insert into auth.users(id,email,is_anonymous)values('{actor}','attempt-race@fixture.invalid',false);")
    org = run("race-org", [*PSQL, "-Atq", "-c", f"select org_id from memberships where user_id='{actor}'and role='owner'limit 1"]).strip()
    barrier = Barrier(6)

    def call(index):
        barrier.wait(timeout=10)
        return run("same-operation-" + str(index), [*PSQL, "-Atq"], f"set role service_role;select public.provider_attempt_begin('{actor}','{org}',repeat('1',64),repeat('2',64));")

    with ThreadPoolExecutor(max_workers=6) as pool:
        replies = [json.loads(next(line for line in out.splitlines() if line.startswith('{'))) for out in pool.map(call, range(6))]
    assert sum(reply['dispatch'] is True for reply in replies) == 1
    assert len({reply['attempt_id'] for reply in replies}) == 1 and all(reply['outcome'] == 'intent' for reply in replies)
    r['races'].append({'name': 'same-operation-intent', 'actualConcurrentSessions': 6, 'exactlyOneDispatchGrant': True, 'oneDurableIdentity': True})
    assert hashes() == r['sourceHashes'], "Consumed source changed during proof"
    r['passed'] = True
    print(json.dumps({'passed': True, 'fresh': r['fresh'], 'replay': r['replay'], 'compiledControls': len(r['controls']), 'races': r['races']}))
finally:
    # Cleanup must still run after a deadline or reserve refusal, and may only
    # stop this driver's newly owned data directory/socket.
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
    (OUT / 'receipt.json').write_text(json.dumps(r, indent=2) + '\n')
    if r.get("ownedClusterStopped") or not started and not (DATA / "postmaster.pid").exists():
        shutil.rmtree(DATA)
        shutil.rmtree(SOCK, ignore_errors=True)
    if cleanup_error: raise RuntimeError(cleanup_error)
