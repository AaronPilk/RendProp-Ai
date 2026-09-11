#!/usr/bin/env python3
"""Owned socket-only PostgreSQL fixture; no DB URL or inherited credentials.

Applies existing migrations, proves the new assertion fails BEFORE 0038, then
applies/replays 0038 and runs the same real SQL. Never connects to an existing
database. Small cluster/logs retained; only its exact PGDATA is stopped.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time


def main():
    root = Path(__file__).resolve().parents[2]
    binaries = Path('/opt/homebrew/opt/postgresql@17/bin')
    assert all((binaries / name).is_file() for name in ['initdb', 'pg_ctl', 'psql', 'createdb'])
    assert shutil.disk_usage('/tmp').free >= 1024**3, 'Need 1 GiB free; no cleanup performed'
    out = Path(tempfile.mkdtemp(prefix='rendprop-adoption-db-', dir='/tmp'))
    cluster, socket = out / 'cluster', out / 'socket'
    socket.mkdir(mode=0o700)
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'TZ': 'UTC'}
    receipt = {'accepted': False, 'commands': [], 'sourceHashes': {}, 'clusterStopped': False}
    migrations = sorted((root / 'services/supabase/migrations').glob('*.sql'))
    target = root / 'services/supabase/migrations/0038_anonymous_adoption_recovery.sql'
    test = root / 'services/supabase/tests/anonymous_adoption_recovery.sql'
    bootstrap = root / 'services/supabase/tests/ci-bootstrap.sql'
    for path in [*migrations, test, bootstrap, Path(__file__)]:
        receipt['sourceHashes'][str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f'EVIDENCE: {out}', flush=True)

    def run(name, command, expected=0):
        result = subprocess.run(command, cwd=root, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=90)
        log = out / f'{name}.log'
        log.write_text(result.stdout)
        receipt['commands'].append({'name': name, 'exit': result.returncode, 'command': list(map(str, command)),
                                    'log': str(log), 'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        assert result.returncode == expected, f'{name}: exit {result.returncode}, expected {expected}; {log}'
        print(f'{name}: exit={result.returncode}', flush=True)
        return result.stdout

    connection = ['-h', str(socket), '-p', '55441', '-U', 'postgres']
    psql = [str(binaries / 'psql'), '-X', '--no-password', *connection, '-d', 'rendprop_adoption_audit', '-v', 'ON_ERROR_STOP=1']
    started = False
    prior_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP)}
    def interrupted(signum, _frame):
        raise RuntimeError(f'Adoption fixture interrupted by signal {signum}')
    for sig in prior_handlers:
        signal.signal(sig, interrupted)
    try:
        run('version', [str(binaries / 'psql'), '--version'])
        run('initdb', [str(binaries / 'initdb'), '-D', str(cluster), '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
        run('start', [str(binaries / 'pg_ctl'), '-D', str(cluster), '-l', str(out / 'postgres.log'), '-w', '-t', '30', '-o',
                      f"-k {socket} -p 55441 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=10", 'start'])
        started = True
        run('createdb', [str(binaries / 'createdb'), '--no-password', *connection, 'rendprop_adoption_audit'])
        identity = run('identity', psql + ['-Atc', "select current_setting('data_directory'),current_setting('listen_addresses'),current_database();"])
        assert identity.strip() == f'{cluster}||rendprop_adoption_audit'
        env['PGOPTIONS'] = '-c statement_timeout=15000 -c lock_timeout=5000'
        run('bootstrap', psql + ['-q', '-f', str(bootstrap)])
        run('auth-fixture-schema', psql + ['-qc', 'alter table auth.users add column is_anonymous boolean not null default false;'])
        for migration in migrations:
            if migration != target:
                run('apply-' + migration.stem, psql + ['-q', '-1', '-f', str(migration)])
        before = run('before', psql + ['-f', str(test)], expected=3)
        assert 'adoption assertion failed: durable receipt table exists' in before, 'Wrong-reason baseline failure'
        run('apply-0038', psql + ['-q', '-1', '-f', str(target)])
        for name in ['after', 'replayed']:
            if name == 'replayed': run('replay-0038', psql + ['-q', '-1', '-f', str(target)])
            output = run(name, psql + ['-f', str(test)])
            assert 'PASS: 35 adoption SQL assertions; all fixtures rolled back.' in output
        definition = run('receipt-definition', psql + ['-Atc', "select pg_get_functiondef('public.adoption_receipt(uuid,uuid,uuid)'::regprocedure);"])
        needle = 'if v.source_user_id <> p_anon_user or v.destination_user_id <> p_user then'
        assert definition.count(needle) == 1, 'Mutation target missing or ambiguous'
        mutant = definition.replace(needle, 'if false then')
        # Author only a copied function in this owned DB, never source/migrations.
        mutation_file = out / 'receipt-mutant.sql'
        mutation_file.write_text(mutant)
        run('apply-receipt-mutant', psql + ['-f', str(mutation_file)])
        rejected = run('reject-receipt-mutant', psql + ['-f', str(test)], expected=3)
        assert 'wrong failure for cross-source replay rejected: fixture accepted forbidden operation' in rejected, 'Wrong-reason mutant failure'
        run('restore-0038', psql + ['-q', '-1', '-f', str(target)])
        restored = run('restored', psql + ['-f', str(test)])
        assert 'PASS: 35 adoption SQL assertions; all fixtures rolled back.' in restored
        receipt['concurrentCases'] = []
        for case, legacy, promotion, prefix in [
            ('legacy-same-operation', True, None, 'a0385000'),
            ('new-competing-destination', False, None, 'a0386000'),
            ('committed-source-promotion', False, 'commit', 'a0387000'),
            ('rolled-back-source-promotion', False, 'rollback', 'a0388000'),
        ]:
            source, dest, other = [f'{prefix}-0000-4000-8000-{i:012d}' for i in (1, 2, 3)]
            ids = ','.join(f"('{uid}','concurrent-{uid}@fixture.invalid','{{}}',{str(uid == source).lower()})" for uid in (source, dest, other))
            run(case + '-setup', psql + ['-qc', f'insert into auth.users(id,email,raw_user_meta_data,is_anonymous) values {ids};'])
            org = run(case + '-org', psql + ['-Atc', f"select org_id from public.memberships where user_id='{source}';"]).strip()
            assert len(org) == 36
            def call(destination, operation):
                args = f"'{destination}','{source}','{org}'"
                if not legacy:
                    args += f",'{operation}'"
                return f'select public.adopt_anonymous_org({args});'
            operation = f'{prefix}-0000-4000-8000-000000000004'
            first_sql = f"begin; set local application_name='adoption-first'; set local role service_role; {call(dest, operation)} select pg_sleep(1); commit;"
            if promotion:
                first_sql = f"begin; set local application_name='adoption-first'; update auth.users set is_anonymous=false where id='{source}'; select pg_sleep(1); {promotion};"
            first = subprocess.Popen(psql + ['-Atqc', first_sql], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            second = None
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    observed = subprocess.run(psql + ['-Atqc', "select count(*) from pg_stat_activity where application_name='adoption-first' and wait_event='PgSleep';"], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
                    assert observed.returncode == 0
                    if observed.stdout.strip() == '1':
                        break
                    time.sleep(0.02)
                else:
                    raise AssertionError('First transaction never reached the overlap barrier')
                second_sql = 'set role service_role; ' + call(dest if legacy or promotion else other, operation if legacy or promotion else f'{prefix}-0000-4000-8000-000000000005')
                second = subprocess.Popen(psql + ['-Atqc', second_sql], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                # Explicitly observe second waiting on the first transaction's
                # profile lock, not merely launch two sequential calls quickly.
                blocked = False
                deadline = time.monotonic() + 0.8
                while time.monotonic() < deadline:
                    observed = subprocess.run(psql + ['-Atqc', "select count(*) from pg_stat_activity where wait_event_type='Lock' and query like '%adopt_anonymous_org%';"], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
                    assert observed.returncode == 0
                    if observed.stdout.strip() == '1':
                        blocked = True
                        break
                    time.sleep(0.02)
                assert blocked, 'Second transaction did not actually overlap the first'
                outputs = [first.communicate(timeout=10)[0], second.communicate(timeout=10)[0]]
                exits = [first.returncode, second.returncode]
                for i, output in enumerate(outputs):
                    (out / f'{case}-{i}.log').write_text(output)
                # psql -c reports a SQL error as1; -f ON_ERROR_STOP above uses3.
                assert exits == ([0, 0] if legacy or promotion == 'rollback' else [0, 1]), f'Unexpected concurrent exits: {exits}'
                if legacy:
                    objects = [json.loads(next(line for line in output.splitlines() if line.startswith('{'))) for output in outputs]
                    assert objects[0] == objects[1], 'Concurrent legacy replies differ'
                elif promotion == 'commit':
                    assert 'RP403: current source and destination identity types do not permit transfer' in outputs[1]
                elif not promotion:
                    assert 'RP409: this source already has a different handoff' in outputs[1]
                state = run(case + '-state', psql + ['-Atc', f"select (select count(*) from public.anonymous_adoption_receipts where source_user_id='{source}'),(select count(*) from public.memberships where user_id='{dest}' and org_id='{org}'),(select count(*) from public.memberships where user_id='{other}' and org_id='{org}'),(select count(*) from public.memberships where user_id='{source}');"])
                assert state.strip() == ('0|0|0|1' if promotion == 'commit' else '1|1|0|0'), 'Concurrent publication state mismatch'
                receipt['concurrentCases'].append({'name': case, 'exits': exits, 'overlapObserved': blocked, 'state': state.strip()})
            finally:
                for child in [first, second]:
                    if child is not None and child.poll() is None:
                        child.terminate()
                        child.communicate(timeout=10)
        receipt['accepted'] = True
    finally:
        if started:
            stopped = subprocess.run([str(binaries / 'pg_ctl'), '-D', str(cluster), '-m', 'fast', '-w', '-t', '30', 'stop'],
                                     env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
            (out / 'stop.log').write_text(stopped.stdout)
            receipt['clusterStopped'] = stopped.returncode == 0
            receipt['accepted'] = receipt['accepted'] and receipt['clusterStopped']
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        for sig, prior in prior_handlers.items():
            signal.signal(sig, prior)
    assert receipt['accepted'], f'Failed adoption gate: {out}'


if __name__ == '__main__':
    main()
