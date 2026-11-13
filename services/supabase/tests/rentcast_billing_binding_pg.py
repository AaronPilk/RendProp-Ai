#!/usr/bin/env python3
"""Owned PostgreSQL + actual property handler, with closed supplier transport.

Use already-installed PostgreSQL and Deno; this runner never installs, warms
imports, reads application credentials or connects to an existing database.
"""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import argparse, datetime, hashlib, json, os, re, secrets, shutil, signal, subprocess, sys, tempfile, time

os.umask(0o077)
ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / 'services/supabase'
OWN = SQL / 'migrations/20261017110114_freeze_property_attempt_liability.sql'
FIX = SQL / 'tests/rentcast_billing_binding.fixture.ts'
FIXTURES = SQL / 'tests/fixtures/rentcast-billing-binding'
WHOLE_SECONDS, LOG_CAP = 360, 16 * 1024**2

def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence-dir', type=Path, required=True)
    p.add_argument('--pg-bin', type=Path, help='Existing PostgreSQL binary directory; otherwise pg_config/PATH')
    p.add_argument('--deno-binary', type=Path, help='Existing Deno executable; otherwise PATH')
    p.add_argument('--deno-cache-dir', type=Path, help='Existing prepared cache; no warming or copying')
    p.add_argument('--node-modules-dir', choices=['none', 'manual'], default='none')
    return p

def digest(p):
    d = hashlib.sha256()
    with Path(p).open('rb') as f:
        for block in iter(lambda: f.read(4 * 1024**2), b''): d.update(block)
    return d.hexdigest()

def write(p, value):
    with p.open('x') as f:
        os.chmod(p, 0o600); json.dump(value, f, indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())

def runtime_sources():
    # Hash the actual first-party import closure, including auth boundaries
    # replaced only in the closed fixture. No node_modules/global cache scan.
    pending = [SQL / 'functions/property/index.ts']; seen = set()
    pattern = re.compile(r'(?:from\s*|import\s*\(|import\s*)[\"\x27]([^\"\x27]+)[\"\x27]')
    while pending:
        f = pending.pop().resolve()
        if f in seen: continue
        assert f.is_relative_to(SQL / 'functions') and f.is_file(), 'First-party import outside function tree'
        seen.add(f)
        for spec in pattern.findall(f.read_text()):
            if spec.startswith('.'):
                child = (f.parent / spec).resolve()
                assert child.is_file(), 'Missing literal local import: ' + str(child)
                pending.append(child)
    return sorted(seen)


def migration_stages(migrations, own):
    assert own in migrations and len(migrations)==len(set(migrations)), 'Unique binding migration required'
    return [x for x in migrations if x.name < own.name], [x for x in migrations if x.name > own.name]

def require_summary(text, passed, failed, witnesses=()):
    summaries = re.findall(r'(?m)^(ok|FAILED) \| (\d+) passed \| (\d+) failed(?:[^\n]*)$', text)
    expected = ('FAILED' if failed else 'ok', str(passed), str(failed))
    assert summaries == [expected], 'Exact phase result inventory'
    for witness in witnesses: assert witness in text, 'Wrong omission witness: ' + witness

def main(argv=None):
    a = parser().parse_args(argv)
    out = a.evidence_dir.resolve()
    assert not out.is_relative_to(ROOT), 'Evidence must be outside the source tree'
    out.mkdir(parents=True, exist_ok=False); out.chmod(0o700)
    start = time.monotonic(); minimum = {}; child = None; started = False
    data, sock = out / 'owned-data', None
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C', 'TZ': 'UTC', 'PGOPTIONS': '-c statement_timeout=30000 -c lock_timeout=15000'}
    r = {'passed': False, 'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'commands': [], 'externalNetworkCalls': 0, 'liveProviderCalls': 0, 'database': 'new owned socket-only cluster', 'currentMigrationCount': None}
    def guard():
        assert time.monotonic() - start < WHOLE_SECONDS, 'Whole proof deadline'
        for name, location, floor in [('internal', '/', 3 * 1024**3), ('evidence', out, (8 if sys.platform == 'darwin' else 1) * 1024**3)]:
            n = shutil.disk_usage(location).free; minimum[name] = min(minimum.get(name, n), n)
            assert n >= floor, 'Storage reserve: ' + name
    def run(name, command, body=None, expected=0, limit=30, cleanup=False):
        nonlocal child
        if not cleanup: guard()
        assert re.fullmatch(r'[a-z0-9-]+', name), 'Safe unique evidence name'
        rec = {'name': name, 'argv': [str(x) for x in command], 'expectedExit': expected, 'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        write(out / (name + '-intent.json'), rec)
        log = out / (name + '.log'); began = time.monotonic(); problem = None; input_file = None
        try:
            if body is not None:
                input_path = out / (name + '.input.sql'); input_path.write_text(body); input_path.chmod(0o600)
                input_file = input_path.open('rb'); rec['inputSHA256'] = digest(input_path)
            with log.open('xb') as f:
                child = subprocess.Popen(rec['argv'], stdin=input_file or subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT, env=env, cwd=ROOT, start_new_session=True)
                while child.poll() is None:
                    if not cleanup: guard()
                    assert time.monotonic() - began < limit, 'Command deadline: ' + name
                    assert log.stat().st_size <= LOG_CAP, 'Command output cap'
                    time.sleep(.1)
                child.wait(timeout=2)
            if not cleanup: guard()
            assert time.monotonic() - began < limit and log.stat().st_size <= LOG_CAP, 'Terminal command bounds'
            assert child.returncode == expected, name + ' unexpected exit'
        except BaseException as e:
            problem = e; rec['failure'] = type(e).__name__ + ': ' + str(e)
        finally:
            if input_file: input_file.close()
            if child is not None and child.poll() is None:
                try: os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try: os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    try: child.wait(timeout=3)
                    except BaseException as e: rec['cleanupFailure'] = type(e).__name__
            rec.update(exit=child.returncode if child else None, elapsedSeconds=time.monotonic()-began, childTerminal=child is None or child.poll() is not None, logSHA256=digest(log) if log.exists() else None)
            write(out / (name + '.json'), rec); r['commands'].append(rec)
        if problem: raise problem
        assert not rec.get('cleanupFailure'), 'Child cleanup failure'
        return log.read_text().strip()
    def terminate(_signum, _frame): raise RuntimeError('Outer process termination requested')
    signal.signal(signal.SIGTERM, terminate); signal.signal(signal.SIGINT, terminate)
    try:
        guard()
        pg_bin = a.pg_bin.resolve() if a.pg_bin else None
        if pg_bin is None:
            pg_config = shutil.which('pg_config', path=env['PATH'])
            if pg_config: pg_bin = Path(run('pg-config', [pg_config, '--bindir'])).resolve()
        def tool(name):
            value = pg_bin / name if pg_bin else Path(shutil.which(name, path=env['PATH']) or '/missing-tool')
            assert value.is_file() and os.access(value, os.X_OK), 'Already-installed tool required: ' + name
            return value.resolve()
        pg = {name: tool(name) for name in ['initdb', 'pg_ctl', 'postgres', 'psql']}
        deno = (a.deno_binary or Path(shutil.which('deno', path=env['PATH']) or '/missing-deno')).resolve()
        assert deno.is_file() and os.access(deno, os.X_OK), 'Already-installed Deno required'
        env['PATH'] = str(pg['psql'].parent) + os.pathsep + env['PATH']
        for name in ['home', 'tmp', 'case-evidence']: (out / name).mkdir(mode=0o700)
        env.update(HOME=str(out/'home'), TMPDIR=str(out/'tmp'), DENO_NO_UPDATE_CHECK='1', DENO_NO_PACKAGE_JSON='1', DENO_NO_PROMPT='1', NO_COLOR='1')
        cache = a.deno_cache_dir or (Path(os.environ['DENO_DIR']) if os.environ.get('DENO_DIR') else None)
        if cache:
            assert cache.is_dir(), 'Prepared Deno cache required'
            env['DENO_DIR'] = str(cache.resolve())
        sock = Path(tempfile.mkdtemp(prefix='rp-rentcast-', dir='/tmp')).resolve()
        assert len(str(sock).encode()) <= 80 and sock.stat().st_uid == os.getuid(), 'Owned bounded Unix socket path'
        port = str(55000 + secrets.randbelow(10000))
        psql = [str(pg['psql']), '-X', '--no-password', '-h', str(sock), '-p', port, '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq']
        migrations = sorted((SQL/'migrations').glob('*.sql')); assert OWN in migrations, 'Binding migration required'
        before, later = migration_stages(partition_fresh_migrations(migrations)[0], OWN)
        sources = sorted(set([*migrations, SQL/'tests/ci-bootstrap.sql', FIX, *FIXTURES.iterdir(), Path(__file__).resolve(), *runtime_sources()]))
        assert all(p.is_file() and not p.is_symlink() for p in sources), 'Regular first-party sources required'
        def hashes(): return {str(p.relative_to(ROOT)): digest(p) for p in sources}
        source_hashes = hashes(); tools = {str(p): digest(p) for p in [*pg.values(), deno]}
        r.update(sourceHashes=source_hashes, toolHashes=tools, currentMigrationCount=len(migrations), migrationsBeforeOwn=len(before), laterMigrations=len(later), nodeModulesMode=a.node_modules_dir, denoVersion=run('deno-version', [deno, '--version'], limit=10), postgresVersion=run('postgres-version', [pg['postgres'], '--version'], limit=10))
        run('initdb', [pg['initdb'], '-D', data, '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
        run('start', [pg['pg_ctl'], '-D', data, '-l', out/'server.log', '-w', '-o', f"-k {sock} -p {port} -c listen_addresses='' -c shared_buffers=16MB -c unix_socket_permissions=0700", 'start']); started=True
        identity = json.loads(run('owned-identity', psql, "select json_build_object('data',current_setting('data_directory'),'listen',current_setting('listen_addresses'),'port',current_setting('port'))"))
        assert Path(identity['data']).resolve()==data.resolve() and identity['listen']=='' and identity['port']==port, 'Only the new owned database'
        run('bootstrap', psql, (SQL/'tests/ci-bootstrap.sql').read_text())
        for i, migration in enumerate(before): run('before-'+str(i).zfill(3), psql, migration.read_text())
        run('fixture-seed', psql, (FIXTURES/'seed.sql').read_text())
        legacy_trigger = run('read-before-binding-trigger', psql, "select pg_get_functiondef('public.stamp_library_financial_liability()'::regprocedure)")
        fixture = out/'fixture.json'; write(fixture, {'psql':psql, 'psqlEnv':env, 'output':str(out/'case-evidence'), 'migration':str(OWN), 'legacyTriggerDefinition':legacy_trigger})
        args = [str(deno), 'test', '--no-config', '--no-lock', '--cached-only', '--node-modules-dir='+a.node_modules_dir, '--deny-net', '--allow-env', '--allow-read='+str(SQL/'functions')+','+str(SQL/'tests')+','+str(OWN)+','+str(fixture), '--allow-write='+str(out/'case-evidence'), '--allow-run='+str(pg['psql']), str(FIX)]
        env['RENTCAST_FLIGHT_PG_FIXTURE'] = str(fixture)
        env['RENTCAST_BILLING_PHASE'] = 'legacy'
        legacy = run('legacy-across-own-migration', args, limit=120)
        require_summary(legacy, 1, 0)
        for i, migration in enumerate(later): run('later-'+str(i).zfill(3), psql, migration.read_text())
        env['RENTCAST_BILLING_PHASE'] = 'current'
        positive = run('current-actual-handler', args, limit=120)
        require_summary(positive, 8, 0)
        evidence = {p.stem:json.loads(p.read_text()) for p in (out/'case-evidence').glob('*.json')}
        assert len(evidence)==16 and len(evidence['receipt-identity-controls']['witnesses'])==14, 'Exact case/witness inventory'
        env['RENTCAST_BILLING_PHASE']='helper-old-control'
        old_helper=run('old-helper-wrong-payer',args,expected=1,limit=120)
        require_summary(old_helper,0,1,("error: AssertionError: Values are not equal: foreign frozen payer cannot be confirmed by ledger readback",))
        env['RENTCAST_BILLING_PHASE']='helper'
        helper_cases=run('receipt-validated-helper',args,limit=120)
        require_summary(helper_cases,3,0)
        helper_evidence=json.loads((out/'case-evidence/helper-receipt-refusals.json').read_text())
        assert len(helper_evidence['outcomes'])==12 and helper_evidence['readErrorRecorded'] is False, 'Exact receipt read refusals'
        original = run('read-current-trigger',psql,"select pg_get_functiondef('public.stamp_library_financial_liability()'::regprocedure)")
        needle='b:=attempt.billing_org_id;'; assert original.count(needle)==1, 'Current actual frozen-payer assignment'
        run('compile-omit-frozen-payer',psql,original.replace(needle,'b:=null; -- omitted frozen authority'))
        env['RENTCAST_BILLING_PHASE']='control'
        negative=run('omitted-frozen-payer',args,expected=1,limit=120)
        require_summary(negative, 0, 2, tuple(name+' receipt/ledger billing organization must match' for name in ['in-flight-hit-control','in-flight-miss-control']))
        run('restore-current-trigger',psql,original)
        assert hashes()==source_hashes and all(digest(p)==v for p,v in tools.items()), 'Source/tool change during proof'
        r.update(passed=True,positiveTests=12,identityRefusals=14,receiptReadRefusals=13,oldHelperWrongPayerFailure=1,compiledOmissionFailures=2,sourceToolsUnchanged=True)
    except BaseException as e:
        r.update(failure=type(e).__name__+': '+str(e))
    finally:
        try:
            pidfile=data/'postmaster.pid'
            if started or pidfile.exists():
                assert data.is_dir() and not data.is_symlink() and data.stat().st_uid==os.getuid(), 'Owned data identity'
                lines=pidfile.read_text().splitlines(); assert len(lines)>3 and Path(lines[1]).resolve()==data.resolve(), 'Owned postmaster data identity'
                run('owned-stop',[pg['pg_ctl'],'-D',data,'-m','fast','-w','stop'],limit=30,cleanup=True)
            assert not pidfile.exists(), 'Owned postmaster remains'
            if data.exists(): shutil.rmtree(data)
            if sock is not None:
                assert not list(sock.iterdir()), 'Owned socket directory not empty'
                sock.rmdir()
            r.update(ownedClusterStopped=True,ownedDataRemoved=not data.exists(),ownedSocketRemoved=sock is None or not sock.exists())
        except BaseException as e: r.update(passed=False,cleanupFailure=type(e).__name__+': '+str(e))
        r.update(finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),elapsedSeconds=time.monotonic()-start,minimumFreeBytes=minimum,allCommandChildrenTerminal=child is None or child.poll() is not None)
        write(out/'receipt.json',r)
        print(json.dumps({k:v for k,v in r.items() if k not in ['commands','sourceHashes','toolHashes']},indent=2))
    return 0 if r['passed'] else 1

if __name__=='__main__': raise SystemExit(main())
