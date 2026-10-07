#!/usr/bin/env python3
"""Publication photo boundaries against an owned socket-only Postgres fixture."""
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor
import hashlib, json, os, pathlib, shutil, subprocess, tempfile, time, uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
SQL = ROOT / "services/supabase"
TARGET = SQL / "migrations/20261002160344_listing_gallery_selection.sql"
TEST = SQL / "tests/listing_gallery_selection.sql"
OUT = pathlib.Path(tempfile.mkdtemp(prefix="rendprop-gallery-selection-", dir="/tmp"))
SOCK, DATA = OUT / "socket", OUT / "cluster"
SOCK.mkdir(mode=0o700)
ENV = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC"}
BIN = {n: shutil.which(n) for n in ["initdb", "pg_ctl", "psql", "createdb"]}
assert all(BIN.values())
CONN = ["-h", str(SOCK), "-p", "55458", "-U", "postgres"]
PSQL = [BIN["psql"], "-X", "--no-password", *CONN, "-d", "rendprop_audit", "-v", "ON_ERROR_STOP=1", "-Atq"]
paths = [*sorted((SQL / "migrations").glob("*.sql")), SQL / "tests/ci-bootstrap.sql", TEST, pathlib.Path(__file__).resolve()]
def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
receipt = {"startedAt": datetime.now(timezone.utc).isoformat(), "sourceHashes": hashes(), "commands": [], "passed": False,
           "productionMutations": 0, "limits": ["Synthetic local database only; no phone, customer, email or provider calls"]}
def run(name, args, stdin=None, expected=0):
    p = subprocess.run(list(map(str, args)), input=stdin, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, env=ENV, cwd=ROOT, timeout=120)
    log = OUT / (name + ".log")
    log.write_text(p.stdout)
    receipt["commands"].append({"name": name, "exit": p.returncode, "log": str(log), "sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
    assert p.returncode == expected, f"{name}: {p.stdout[-3000:]}"
    print(name, p.returncode, flush=True)
    return p.stdout
def query(name, sql, expected=0):
    return run(name, PSQL, sql, expected)
started = False
print("EVIDENCE:", OUT, flush=True)
try:
    run("init", [BIN["initdb"], "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [BIN["pg_ctl"], "-D", DATA, "-l", OUT / "server.log", "-w", "-t", "30", "-o",
                  f"-k {SOCK} -p 55458 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=10", "start"])
    started = True
    run("create", [BIN["createdb"], "--no-password", *CONN, "rendprop_audit"])
    assert query("identity", "select current_setting('data_directory'),current_setting('listen_addresses');").strip() == str(DATA) + "|"
    query("bootstrap", (SQL / "tests/ci-bootstrap.sql").read_text())
    for p in sorted((SQL / "migrations").glob("*.sql")):
        query("migration-" + p.stem, p.read_text())
    counts = []
    for phase in ["fresh", "replayed"]:
        if phase == "replayed":
            query("replay", TARGET.read_text())
        result = query("gallery-" + phase, TEST.read_text())
        count = result.count("|t")
        assert count == 47, result[-3000:]
        counts.append(count)
    for name, needle in [("wrong-media-kind", "a.kind='photo' and"),
                         ("foreign-storage-prefix", "left(a.storage_key,length(prefix))=prefix and")]:
        source = TARGET.read_text()
        assert source.count(needle) == 3
        query("mutant-" + name, source.replace(needle, ""))
        failed = query("mutant-test-" + name, TEST.read_text(), expected=3)
        assert "GALLERY FAIL:" in failed
        query("restore-" + name, source)
    owner, agent, lid, first, add_a, add_b = map(str, [uuid.uuid4() for _ in range(6)])
    query("concurrent-users", f"insert into auth.users(id,email,is_anonymous)values('{owner}','append-owner@fixture.invalid',false),('{agent}','append-agent@fixture.invalid',false);")
    org = query("concurrent-org", f"select org_id from memberships where user_id='{owner}';").strip()
    prefix = f"renders/{org}/{lid}/gallery-"
    query("concurrent-fixture", f"insert into memberships(user_id,org_id,role)values('{agent}','{org}','agent');insert into listings(id,org_id,agent_id,address)values('{lid}','{org}','{owner}','Concurrent gallery fixture');insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded)values" + ",".join(f"('{asset}','{lid}','photo','renders','{prefix}{asset}.jpg',true)" for asset in [first, add_a, add_b]) + f";update listings set gallery_asset_ids=array['{first}']::uuid[],main_photo_key='{prefix}{first}.jpg'where id='{lid}';")
    def race(name, commands):
        locker = subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
        try:
            locker.stdin.write(f"begin;select id from orgs where id='{org}'for update;\n\\echo LOCKED\n")
            locker.stdin.flush()
            assert locker.stdout.readline().strip() == org and locker.stdout.readline().strip() == 'LOCKED'
            def call(command):
                p = subprocess.run(PSQL, input='set role service_role;' + command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=ENV, timeout=30)
                return {'exit': p.returncode, 'output': p.stdout}
            with ThreadPoolExecutor(max_workers=2) as pool:
                jobs = [pool.submit(call, command) for command in commands]
                deadline = time.monotonic() + 8
                while True:
                    p = subprocess.run(PSQL, input="select count(*)from pg_stat_activity where datname='rendprop_audit'and wait_event_type='Lock'and pid<>pg_backend_pid();", text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV, timeout=5)
                    if p.returncode == 0 and p.stdout.strip() == '2':
                        break
                    assert time.monotonic() < deadline, 'Both append calls must overlap behind the owned org lock'
                    time.sleep(.03)
                locker.stdin.write('commit;\n')
                locker.stdin.flush(); locker.stdin.close(); locker.wait(timeout=10)
                results = [job.result() for job in jobs]
            log = OUT / (name + '.json'); log.write_text(json.dumps(results, indent=2) + '\n')
            receipt['commands'].append({'name': name, 'log': str(log), 'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
            assert all(result['exit'] == 0 for result in results), results
        finally:
            if locker.poll() is None:
                locker.kill(); locker.wait()
    race('concurrent-different-additions', [f"select append_listing_gallery('{actor}','{org}','{lid}',array['{asset}']::uuid[]);" for actor, asset in [(owner, add_a), (agent, add_b)]])
    assert query('concurrent-union', f"select cardinality(gallery_asset_ids)=3 and gallery_asset_ids[1]='{first}'::uuid and gallery_asset_ids@>array['{add_a}','{add_b}']::uuid[]and main_photo_key='{prefix}{first}.jpg'from listings where id='{lid}';").strip() == 't'
    race('concurrent-repeat-addition', [f"select append_listing_gallery('{actor}','{org}','{lid}',array['{add_a}']::uuid[]);" for actor in [owner, agent]])
    assert query('concurrent-idempotence', f"select cardinality(gallery_asset_ids)=3 from listings where id='{lid}';").strip() == 't'
    assert receipt["sourceHashes"] == hashes(), "Source changed during verification"
    receipt.update(passed=True, sqlAssertionsEach=counts, negativeControls=["wrong-media-kind", "foreign-storage-prefix"], concurrencyChecks=['different additions preserved','repeat additions idempotent'], finishedAt=datetime.now(timezone.utc).isoformat())
finally:
    if started and (DATA / "postmaster.pid").exists():
        run("stop", [BIN["pg_ctl"], "-D", DATA, "-m", "immediate", "-w", "stop"])
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print("PASS: current gallery selection and main-photo fences", flush=True)
