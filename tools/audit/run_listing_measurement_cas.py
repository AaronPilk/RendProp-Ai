#!/usr/bin/env python3
"""Actual measurement CAS/legacy preservation in an owned disposable PostgreSQL.
No inherited credentials, hosted DB, network listener, provider calls or user edits.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
SQL = ROOT / 'services/supabase'
MIGRATION = SQL / 'migrations/20261004220253_listing_measurement_compare_and_set.sql'
FIXTURE = SQL / 'tests/listing_measurement_cas.sql'
TOOLS = {name: shutil.which(name) or str(Path('/opt/homebrew/opt/postgresql@17/bin') / name)
         for name in ('initdb', 'pg_ctl', 'psql', 'createdb')}
assert all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()), 'Use existing PostgreSQL binaries'
OUT = Path(tempfile.mkdtemp(prefix='rendprop-measurement-cas-pg-', dir='/tmp'))
DATA, SOCK = OUT / 'data', OUT / 'socket'
SOCK.mkdir()
ENV = {'PATH': '/opt/homebrew/bin:/usr/bin:/bin', 'LC_ALL': 'C', 'PGOPTIONS': '-c statement_timeout=30000 -c lock_timeout=15000'}
PORT = '55479'
SOURCES = [*sorted((SQL / 'migrations').glob('*.sql')), SQL / 'tests/ci-bootstrap.sql', FIXTURE, Path(__file__).resolve()]
receipt = {'kind': 'owned disposable local PostgreSQL; no hosted DB/providers', 'output': str(OUT), 'commands': [],
           'sourceHashes': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}}

def run(name, args, sql=None, refuses=None):
    p = subprocess.run([str(x) for x in args], input=sql, env=ENV, cwd=ROOT, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    log = OUT / (name + '.log')
    log.write_text(p.stdout)
    receipt['commands'].append({'name': name, 'exit': p.returncode, 'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
    if refuses:
        assert p.returncode != 0 and refuses in p.stdout, f'{name}: expected {refuses}, got {p.stdout}'
    elif p.returncode:
        raise RuntimeError(f'{name} failed: {p.stdout[-2500:]} ({log})')
    print(name + ': pass', flush=True)
    return p.stdout

started = False
try:
    receipt['postgresVersion'] = run('version', [TOOLS['psql'], '--version']).strip()
    run('initdb', [TOOLS['initdb'], '-D', DATA, '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
    run('start', [TOOLS['pg_ctl'], '-D', DATA, '-l', OUT / 'server.log', '-w', '-t', '30', '-o',
                  f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", 'start'])
    started = True
    conn = ['-h', SOCK, '-p', PORT, '-U', 'postgres']
    run('createdb', [TOOLS['createdb'], *conn, 'measurement_cas_audit'])
    psql = [TOOLS['psql'], '-X', '--no-password', *conn, '-d', 'measurement_cas_audit', '-v', 'ON_ERROR_STOP=1']
    run('bootstrap', [*psql, '-q', '-f', SQL / 'tests/ci-bootstrap.sql'])
    for m in sorted((SQL / 'migrations').glob('*.sql')):
        run('apply-' + m.stem, [*psql, '-q', '-1', '-f', m])
    receipt['fresh'] = json.loads(run('fresh', [*psql, '-Atq', '-f', FIXTURE]).strip())
    run('replay', [*psql, '-q', '-1', '-f', MIGRATION])
    receipt['replay'] = json.loads(run('replay-fixture', [*psql, '-Atq', '-f', FIXTURE]).strip())
    actor, second, org, listing = [str(uuid.uuid4()) for _ in range(4)]
    old = '{"version":1,"unit":"meters","rooms":[],"updatedAt":812345678}'
    def plan(room_name):
        return json.dumps({'version': 2, 'unit': 'meters', 'updatedAt': 812345678, 'outlines': [],
                           'rooms': [{'id': str(uuid.uuid4()), 'name': room_name, 'floor': 0,
                                      'widthMeters': 4, 'lengthMeters': 3, 'xMeters': 0, 'yMeters': 0,
                                      'rotationQuarterTurns': 0, 'source': 'manual'}]}, separators=(',', ':'))
    left, right = plan('Kitchen'), plan('Bedroom')
    def quote(s): return "'" + s.replace("'", "''") + "'"
    run('race-setup', [*psql, '-q'], f"""
insert into auth.users(id,email) values('{actor}','race-cas-owner@example.invalid'),('{second}','race-cas-second@example.invalid');
insert into orgs(id,name,plan) values('{org}','Synthetic two writers','pro');
insert into memberships(user_id,org_id,role) values('{actor}','{org}','owner'),('{second}','{org}','agent');
insert into listings(id,org_id,agent_id,address,sqft,status,sold_at,price_cents,details)
values('{listing}','{org}','{actor}','Synthetic race property',2345,'archived','2026-09-30 12:00:00+00',50000000,
jsonb_build_object('floor_measurements_v1',{quote(old)},'floor_plan_asset_id','studio-attachment','floorMeasurementsV9','future-opaque'));
""")
    barrier = Barrier(2)
    race_label = 'positive-race'
    def writer(item):
        i, user, value = item
        barrier.wait(timeout=10)
        query = f"begin; set local role service_role; select save_listing_measurements('{user}','{org}','{listing}',{quote(old)},{quote(value)})->'details'->>'floor_measurements_v1'; select pg_sleep(0.2); commit;"
        p = subprocess.run([str(x) for x in [*psql, '-Atq']], input=query, env=ENV, cwd=ROOT, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)
        log = OUT / f'{race_label}-writer-{i}.log'; log.write_text(p.stdout)
        receipt['commands'].append({'name': f'{race_label}-writer-{i}', 'exit': p.returncode, 'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        return {'actor': user, 'value': value, 'exit': p.returncode, 'conflict': p.returncode != 0 and 'Measurements changed elsewhere' in p.stdout}
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(writer, [(0, actor, left), (1, second, right)]))
    assert sum(r['exit'] == 0 for r in results) == 1 and sum(r['conflict'] for r in results) == 1, results
    winning = next(r for r in results if r['exit'] == 0)
    actual = json.loads(run('race-final', [*psql, '-Atq'], f"select jsonb_build_object('sqft',sqft,'status',status,'sold',sold_at is not null,'price',price_cents,'attachment',details->>'floor_plan_asset_id','future',details->>'floorMeasurementsV9','plan',details->>'floor_measurements_v1') from listings where id='{listing}';").strip())
    assert actual == {'sqft': 2345, 'status': 'archived', 'sold': True, 'price': 50000000, 'attachment': 'studio-attachment', 'future': 'future-opaque', 'plan': winning['value']}, actual
    receipt['twoWriterRace'] = {'results': results, 'final': actual}
    # Actual client roles cannot call the service RPC or exploit the GUC.
    for role in ('anon', 'authenticated'):
        auth = f"set role {role}; set request.jwt.claim.sub='{actor}'; set request.jwt.claim.role='{role}';\n"
        run('rpc-denied-' + role, [*psql, '-Atq'], auth + f"select save_listing_measurements('{actor}','{org}','{listing}',{quote(old)},{quote(left)});", refuses='permission denied')
    auth = f"set role authenticated; set request.jwt.claim.sub='{actor}'; set request.jwt.claim.role='authenticated'; set rendprop.measurement_cas='allowed';\n"
    run('client-guc-cannot-bypass', [*psql, '-Atq'], auth + f"update listings set details=jsonb_build_object('floorMeasurementsV1',{quote(old)}) where id='{listing}';")
    protected = run('guc-final', [*psql, '-Atq'], f"select details->>'floor_measurements_v1' from listings where id='{listing}';").strip()
    assert protected == winning['value'], protected
    # Remove the exact production precondition. The same concurrent invariant
    # must now catch both writers succeeding and one room silently being lost.
    mutation = MIGRATION.read_text().replace('if current_plan is distinct from p_expected then', 'if false then')
    assert mutation != MIGRATION.read_text(), 'CAS mutation anchor changed'
    run('install-missing-precondition-control', [*psql, '-q', '-1'], mutation)
    listing = str(uuid.uuid4())
    run('negative-race-setup', [*psql, '-q'], f"""
insert into listings(id,org_id,agent_id,address,sqft,status,sold_at,price_cents,details)
values('{listing}','{org}','{actor}','Synthetic negative race',2345,'archived','2026-09-30 12:00:00+00',50000000,
jsonb_build_object('floor_measurements_v1',{quote(old)},'floor_plan_asset_id','studio-attachment','floorMeasurementsV9','future-opaque'));
""")
    barrier = Barrier(2)
    race_label = 'missing-precondition-control'
    with ThreadPoolExecutor(max_workers=2) as pool:
        negative = list(pool.map(writer, [(0, actor, left), (1, second, right)]))
    try:
        assert sum(r['exit'] == 0 for r in negative) == 1 and sum(r['conflict'] for r in negative) == 1
    except AssertionError:
        assert all(r['exit'] == 0 for r in negative), negative
        receipt['negativeControl'] = {'removed': 'exact cached-plan precondition', 'caught': True, 'results': negative}
    else:
        raise AssertionError('Missing precondition control failed to violate the one-writer invariant')
    run('restore-cas-after-control', [*psql, '-q', '-1', '-f', MIGRATION])
    lockless = MIGRATION.read_text().replace(' for update;', ';').replace(
        "current_plan:=d->>'floor_measurements_v1';", "current_plan:=d->>'floor_measurements_v1'; perform pg_sleep(0.4);")
    assert lockless != MIGRATION.read_text() and 'perform pg_sleep(0.4)' in lockless
    run('install-no-locks-control', [*psql, '-q', '-1'], lockless)
    listing = str(uuid.uuid4())
    run('no-lock-race-setup', [*psql, '-q'], f"""
insert into listings(id,org_id,agent_id,address,details)
values('{listing}','{org}','{actor}','Synthetic no-lock race',jsonb_build_object('floor_measurements_v1',{quote(old)}));
""")
    barrier = Barrier(2)
    race_label = 'no-locks-control'
    with ThreadPoolExecutor(max_workers=2) as pool:
        negative = list(pool.map(writer, [(0, actor, left), (1, second, right)]))
    try:
        assert sum(r['exit'] == 0 for r in negative) == 1 and sum(r['conflict'] for r in negative) == 1
    except AssertionError:
        assert all(r['exit'] == 0 for r in negative), negative
        receipt['lockingNegativeControl'] = {'removed': 'workspace and listing serialization', 'caught': True, 'results': negative}
    else:
        raise AssertionError('Removed-locks control failed to violate the one-writer invariant')
    run('restore-cas-after-lock-control', [*psql, '-q', '-1', '-f', MIGRATION])
    receipt['passed'] = True
finally:
    if started:
        run('stop', [TOOLS['pg_ctl'], '-D', DATA, '-m', 'fast', '-w', 'stop'])
        assert not (DATA / 'postmaster.pid').exists(), 'Do not delete an active cluster'
        shutil.rmtree(DATA)
        receipt['disposableClusterRemoved'] = True
    (OUT / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(str(OUT / 'receipt.json'), flush=True)
