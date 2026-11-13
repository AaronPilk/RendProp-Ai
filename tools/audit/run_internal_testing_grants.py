#!/usr/bin/env python3
"""Source-bound internal-testing proof; creates only an owned socket-only DB."""
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

# --help must remain a read-only command, before any disposable DB is created.
argparse.ArgumentParser(description=__doc__).parse_args()

ROOT = Path(__file__).resolve().parents[2]
SQL = ROOT / 'services/supabase'
TARGET = SQL / 'migrations/20261005195004_workspace_internal_testing_grants.sql'
MIGRATIONS = sorted(p for p in (SQL / 'migrations').glob('*.sql') if p.name <= TARGET.name)
TEST = SQL / 'tests/internal_testing_grants.sql'
OUT = Path(tempfile.mkdtemp(prefix='rendprop-testing-grant-', dir='/tmp'))
DATA = OUT / 'cluster'
SOCK = OUT / 'socket'
SOCK.mkdir(mode=0o700)
BINS = {n: shutil.which(n) for n in ('initdb', 'pg_ctl', 'createdb', 'psql')}
assert all(BINS.values()), 'Use the existing PostgreSQL distribution'
ENV = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C', 'TZ': 'UTC',
       'PGOPTIONS': '-c statement_timeout=30000 -c lock_timeout=5000'}
CONN = ['-h', str(SOCK), '-p', '55467', '-U', 'postgres']
DB = 'rendprop_testing_grant'
tracked = [*MIGRATIONS, TEST, Path(__file__).resolve(), SQL / 'tests/ci-bootstrap.sql']
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
receipt = {'startedAt': datetime.now(timezone.utc).isoformat(), 'sourceHashes': hashes,
           'limits': ['Owned new socket-only PostgreSQL; no inherited DB credentials',
                      'Synthetic identities, invites, jobs and cost rows; no provider dispatch or email',
                      'No live deployment; Int32.max is legacy compatibility, not mathematical infinity'],
           'passed': False}
started = False
ENT_INSERT = ('  if public.org_has_internal_testing_grant(p_org) then\n'
              '    v_base.seats := 2147483647;\n    v_base.renders_per_month := 2147483647;\n'
              '    v_base.photo_edits_per_month := 2147483647;\n    v_base.reels_per_month := 2147483647;\n'
              '    v_base.aerials_per_month := 2147483647;\n    v_base.topaz_per_month := 2147483647;\n'
              '    v_base.cogs_ceiling_cents := 2147483647;\n    return v_base;\n  end if;\n')
SEAT_INSERT = '    (select 2147483647 where public.org_has_internal_testing_grant(p_org)),\n'
SNAPSHOT = """select json_object_agg(p.oid::regprocedure::text,json_build_object(
 'definition',pg_get_functiondef(p.oid),'acl',p.proacl,'owner',p.proowner,
 'definer',p.prosecdef,'volatility',p.provolatile,'config',p.proconfig))
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public';"""
RETAIL = """select json_build_object(
 'plans',(select jsonb_agg(to_jsonb(p)order by plan)from plan_entitlements p),
 'industries',(select jsonb_agg(to_jsonb(p)order by plan,space_type)from plan_entitlement_overrides p),
 'routes',(select jsonb_agg(to_jsonb(p)order by id)from ai_routes p),
 'configuration',(select jsonb_agg(to_jsonb(p)order by key)from app_config p));"""
SHADOW_PROBE = """begin;
do $$begin if current_database()<>'rendprop_testing_grant' or inet_server_addr() is not null then raise exception 'Owned fixture only';end if;end$$;
insert into auth.users(id,email,is_anonymous)values('cb100507-0000-4000-8000-000000000001','shadow-owner@fixture.invalid',false);
update profiles set is_admin=true where id='cb100507-0000-4000-8000-000000000001';
update orgs set plan='team',plan_source='manual'where id=(select org_id from memberships where user_id='cb100507-0000-4000-8000-000000000001');
insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)
 select org_id,user_id,true from memberships where user_id='cb100507-0000-4000-8000-000000000001';
insert into brokerage_contracts(org_id,seats,price_cents_per_seat)
 select org_id,10,14900 from memberships where user_id='cb100507-0000-4000-8000-000000000001';
select set_config('request.jwt.claim.sub','cb100507-0000-4000-8000-000000000001',true);
set local role authenticated;
create temp table brokerage_contracts(org_id uuid,status text,starts_at timestamptz,ends_at timestamptz);
discard plans;
do $$begin
 if public.org_has_internal_testing_grant((select org_id from public.memberships where user_id=auth.uid())) is distinct from false then
  raise exception 'TESTING GRANT FAIL: authority ignores authenticated caller temp-shadowed contract';
 end if;
end$$;
rollback;"""

def psql(database=DB):
    return [BINS['psql'], '-X', '--no-password', *CONN, '-d', database, '-v', 'ON_ERROR_STOP=1']

def run(name, args, expected=0, timeout=60):
    result = subprocess.run([str(x) for x in args], env=ENV, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    (OUT / (name + '.log')).write_text(result.stdout)
    assert result.returncode == expected, (name, result.returncode, result.stdout[-3500:])
    return result.stdout

def query(name, command, database=DB, expected=0):
    file = OUT / (name + '.sql')
    file.write_text(command)
    return run(name, [*psql(database), '-Atq', '-f', file], expected)

def positive(name, database=DB):
    output = run(name, [*psql(database), '-Atq', '-f', TEST])
    match = re.search(r'\n(\d+)\nPASS: internal testing grant SQL assertions; all fixtures rolled back\.', output)
    expected = len(re.findall(r'select pg_temp\.testing_(?:ok|denied)\(', TEST.read_text())) + 1
    assert match and int(match[1]) == expected, (name, 'Incomplete exact assertion inventory', expected)
    return int(match[1])

def compare_functions(before, after):
    for name, old in before.items():
        new = after[name].copy()
        if name in ('org_entitlement(uuid)', 'org_seats_allowed(uuid)'):
            insertion = ENT_INSERT if name.startswith('org_entitlement') else SEAT_INSERT
            assert new['definition'].count(insertion) == 1
            new['definition'] = new['definition'].replace(insertion, '')
        assert old == new, ('Unrelated body/ACL/owner/security/volatility/path changed', name)

def revocation_race(finish):
    name = 'revocation-' + finish
    ids = ['cb100506-0000-4000-8000-' + f'{(1 if finish == "commit" else 2) * 10+i:012d}' for i in (1, 2)]
    query(name + '-seed', f"insert into auth.users(id,email,is_anonymous)values('{ids[0]}','race-owner-{finish}@fixture.invalid',false),('{ids[1]}','race-member-{finish}@fixture.invalid',false);")
    org = query(name + '-org', f"select org_id from memberships where user_id='{ids[0]}';").strip()
    query(name + '-grant', f"update profiles set is_admin=true where id='{ids[0]}';update orgs set plan='team',plan_source='manual'where id='{org}';insert into memberships(user_id,org_id,role)values('{ids[1]}','{org}','agent');set role service_role;insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)values('{org}','{ids[0]}',true);")
    handles = [(OUT / (name + '-first.log')).open('w'), (OUT / (name + '-second.log')).open('w')]
    second = None
    first = subprocess.Popen(psql(), env={**ENV, 'PGAPPNAME': name + '-first'}, text=True,
                             stdin=subprocess.PIPE, stdout=handles[0], stderr=subprocess.STDOUT)
    try:
        first.stdin.write(f"begin;set local role service_role;update org_internal_testing_grants set revoked_at=now()where org_id='{org}';\n\\echo GRANT_ORG_LOCK_HELD\n")
        first.stdin.flush()
        deadline = time.monotonic() + 5
        while 'GRANT_ORG_LOCK_HELD' not in (OUT / (name + '-first.log')).read_text():
            assert first.poll() is None and time.monotonic() < deadline
            time.sleep(.03)
        command = OUT / (name + '-second.sql')
        command.write_text(f"set role service_role;select create_org_invite('{ids[0]}','{org}',null,'agent',repeat('d',64));")
        second = subprocess.Popen([*psql(), '-f', command], env={**ENV, 'PGAPPNAME': name + '-second'}, text=True,
                                  stdout=handles[1], stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 5
        blocked = False
        while time.monotonic() < deadline:
            if query(name + '-observe-lock', f"select count(*)from pg_stat_activity where application_name='{name}-second'and wait_event_type='Lock';").strip() == '1':
                blocked = True
                break
            assert second.poll() is None
            time.sleep(.03)
        assert blocked, 'Actual invite did not wait at grant revocation org lock'
        first.stdin.write(f'{finish};\n\\q\n')
        first.stdin.flush()
        first.wait(timeout=10)
        second.wait(timeout=10)
        assert first.returncode == 0 and second.returncode == (3 if finish == 'commit' else 0)
        if finish == 'commit':
            assert 'RP402:' in (OUT / (name + '-second.log')).read_text()
        state = query(name + '-final', f"set role service_role;select org_seats_used('{org}');").strip()
        assert state == ('2' if finish == 'commit' else '3')
        return {'transaction': finish, 'actualOrgLockObserved': True, 'seatsUsed': int(state)}
    finally:
        for process in (first, second):
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        for handle in handles:
            handle.close()

try:
    run('init', [BINS['initdb'], '-D', DATA, '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
    run('start', [BINS['pg_ctl'], '-D', DATA, '-l', OUT / 'postgres.log', '-w', '-t', '30', '-o',
                  f"-k {SOCK} -p 55467 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=12", 'start'])
    started = True
    run('create', [BINS['createdb'], '--no-password', *CONN, DB])
    assert query('owned-identity', "select current_setting('data_directory')||'|'||current_setting('listen_addresses')||'|'||current_database();").strip() == f'{DATA}||{DB}'
    run('bootstrap', [*psql(), '-q', '-f', SQL / 'tests/ci-bootstrap.sql'])
    for migration in MIGRATIONS:
        if migration == TARGET:
            break
        run('apply-' + migration.stem, [*psql(), '-q', '-f', migration])
    before = json.loads(query('before-functions', SNAPSHOT))
    retail = query('before-retail-and-provider-config', RETAIL)
    run('apply-testing-grant', [*psql(), '-q', '-f', TARGET])
    after = json.loads(query('after-functions', SNAPSHOT))
    compare_functions(before, after)
    assert query('after-retail-and-provider-config', RETAIL) == retail
    receipt['fullMigrationCount'] = len(MIGRATIONS)
    receipt['freshSQLAssertions'] = positive('fresh-positive')
    run('replay-testing-grant', [*psql(), '-q', '-f', TARGET])
    assert json.loads(query('replayed-functions', SNAPSHOT)) == after
    receipt['replaySQLAssertions'] = positive('replayed-positive')
    receipt['preservation'] = {'allExistingFunctionsUnchangedExceptTwoReviewedInsertions': True,
                               'ACLsOwnerDefinerVolatilityAndPathUnchanged': True,
                               'allRetailRowsRoutesAndConfigurationUnchanged': True,
                               'replayFunctionDefinitionsExactlyUnchanged': True}
    helper = after['org_has_internal_testing_grant(uuid)']['definition']
    controls = []
    for name, anchor, replacement, failure in (
        ('remove-caller-boundary', '  if not (', '  if false and not (', 'foreign authenticated caller never receives testing benefit'),
        ('remove-admin-authority', 'p.is_admin is true', 'true', 'product admin removal disables authority'),
        ('remove-owner-role', "m.role = 'owner'", "m.role in ('owner','admin')", 'workspace owner role removal disables authority'),
        ('remove-named-identity', 'u.is_anonymous is false', 'true', 'anonymous identity cannot own testing authority'),
        ('remove-revocation', 'g.revoked_at is null', 'true', 'revoked authority returns retail limits'),
        ('remove-contract-precedence', "and not exists (select 1 from public.brokerage_contracts c\n        where c.org_id = p_org and c.status = 'active'\n          and c.starts_at <= now() and (c.ends_at is null or c.ends_at > now()))", '', 'active contract takes precedence over stale manual Team'),
    ):
        assert helper.count(anchor) == 1, name
        query(name + '-compile', helper.replace(anchor, replacement))
        failed = run(name + '-negative', [*psql(), '-Atq', '-f', TEST], 3)
        assert 'TESTING GRANT FAIL: ' + failure in failed, name
        query(name + '-restore', helper)
        positive(name + '-restored')
        controls.append({'name': name, 'compiled': True, 'namedFailure': failure, 'restoredPassed': True})
    # Explicitly faulty new helper, not a claim about old effective_plan (its
    # current contract lookup is already qualified). Both protections matter:
    # this mutant widens the path AND unqualifies the private contract lookup.
    assert helper.count("SET search_path TO ''") == 1
    assert helper.count('from public.brokerage_contracts c') == 1
    shadow_fault = helper.replace("SET search_path TO ''", 'SET search_path TO public').replace(
        'from public.brokerage_contracts c', 'from brokerage_contracts c')
    query('authenticated-shadow-probe-positive', SHADOW_PROBE)
    query('unpin-and-unqualify-contract-compile', shadow_fault)
    failed = query('unpin-and-unqualify-contract-negative', SHADOW_PROBE, expected=3)
    assert 'TESTING GRANT FAIL: authority ignores authenticated caller temp-shadowed contract' in failed
    query('unpin-and-unqualify-contract-restore', helper)
    positive('unpin-and-unqualify-contract-restored')
    controls.append({'name': 'unpin-and-unqualify-contract', 'compiled': True,
                     'namedFailure': 'authority ignores authenticated caller temp-shadowed contract',
                     'restoredPassed': True, 'scope': 'Deliberate faulty new helper; old helper bypass not reproduced'})
    entitlement = after['org_entitlement(uuid)']['definition']
    query('unknown-definition-compile', entitlement.replace(ENT_INSERT, '').replace('begin\n', 'begin\n  -- unknown deployed change\n', 1))
    unknown_before = json.loads(query('unknown-definition-before-failed-migration', SNAPSHOT))
    failed = run('unknown-definition-migration-denied', [*psql(), '-q', '-f', TARGET], 3)
    assert 'org_entitlement definition changed; review before installing testing grant' in failed
    assert json.loads(query('unknown-definition-after-failed-migration', SNAPSHOT)) == unknown_before
    query('unknown-definition-restore', entitlement)
    assert json.loads(query('controls-final-functions', SNAPSHOT)) == after
    receipt['compiledNegativeControls'] = controls
    receipt['unknownLiveDefinitionGuard'] = {'compiledUnknownBody': True, 'migrationRefusedWithoutOverwriting': True}
    receipt['races'] = [revocation_race(finish) for finish in ('commit', 'rollback')]

    # Standalone expansion on the deployed PR27 schema: none of the five
    # pending beta migrations/functions are required by this grant.
    standalone = 'rendprop_testing_grant_standalone'
    run('standalone-create', [BINS['createdb'], '--no-password', *CONN, standalone])
    run('standalone-bootstrap', [*psql(standalone), '-q', '-f', SQL / 'tests/ci-bootstrap.sql'])
    prior = [p for p in MIGRATIONS if p.name < '20261005150445_scoped_business_logo.sql']
    for migration in prior:
        run('standalone-' + migration.stem, [*psql(standalone), '-q', '-f', migration])
    standalone_before = json.loads(query('standalone-before-functions', SNAPSHOT, standalone))
    run('standalone-apply-testing', [*psql(standalone), '-q', '-f', TARGET])
    compare_functions(standalone_before, json.loads(query('standalone-after-functions', SNAPSHOT, standalone)))
    # The fixture enforces its owned database name; clone the tested schema to
    # that exact fixture name instead of weakening its safety guard.
    run('drop-completed-full-fixture', [BINS['psql'], '-X', '--no-password', *CONN, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-c', f'drop database {DB};'])
    run('standalone-fixture-clone', [BINS['createdb'], '--no-password', *CONN, '--template', standalone, DB])
    receipt['standalonePreBetaSQLAssertions'] = positive('standalone-pre-beta-positive')
    receipt['standaloneMigrationCount'] = len(prior) + 1
    receipt['standaloneExcludesFivePendingBetaMigrations'] = len(MIGRATIONS) - len(prior) - 1 == 5
    assert receipt['standaloneExcludesFivePendingBetaMigrations']
    assert all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items()), 'Consumed source changed during proof'
    receipt['sourceBoundAtEnd'] = True
    receipt['passed'] = True
finally:
    if started and (DATA / 'postmaster.pid').exists():
        run('stop', [BINS['pg_ctl'], '-D', DATA, '-m', 'fast', '-w', '-t', '30', 'stop'])
    receipt['finishedAt'] = datetime.now(timezone.utc).isoformat()
    (OUT / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Internal testing grant evidence:', OUT, flush=True)
print('PASS: exact source/ACL preservation, fresh/replay/standalone SQL, compiled controls and actual revocation races.', flush=True)
