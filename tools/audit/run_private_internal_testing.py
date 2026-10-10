#!/usr/bin/env python3
"""Source-bound private tester proof in a new owned socket-only PostgreSQL."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

argparse.ArgumentParser(description=__doc__).parse_args()
ROOT = Path(__file__).resolve().parents[2]
SQL = ROOT / 'services/supabase'
TARGET = SQL / 'migrations/20261005200559_private_internal_testing_sponsorships.sql'
MASTER = SQL / 'migrations/20261005195004_workspace_internal_testing_grants.sql'
MIGRATIONS = sorted(p for p in (SQL / 'migrations').glob('*.sql') if p.name <= TARGET.name)
TEST = SQL / 'tests/private_internal_testing.sql'
LEGACY_TEST = SQL / 'tests/private_internal_testing_legacy.sql'
FINAL_TARGET = SQL / 'migrations/20261010030225_reaudit_library_session_settlement.sql'
FINAL_OVERLAY = SQL / 'migrations/20261010042000_legacy_notification_session_retirement.sql'
FINAL_MIGRATIONS = sorted((SQL / 'migrations').glob('*.sql'))
OUT = Path(tempfile.mkdtemp(prefix='rendprop-private-testing-', dir='/tmp'))
DATA, SOCK = OUT / 'cluster', OUT / 'socket'
SOCK.mkdir(mode=0o700)
BINS = {n: shutil.which(n) for n in ('initdb', 'pg_ctl', 'createdb', 'psql')}
assert all(BINS.values()), 'Use existing PostgreSQL distribution'
ENV = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C', 'TZ': 'UTC',
       'PGOPTIONS': '-c statement_timeout=30000 -c lock_timeout=5000'}
CONN = ['-h', str(SOCK), '-p', '55468', '-U', 'postgres']
DB = 'rendprop_private_testing'
tracked = [*FINAL_MIGRATIONS, TEST, LEGACY_TEST, Path(__file__).resolve(), SQL / 'tests/ci-bootstrap.sql']
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
receipt = {'startedAt': datetime.now(timezone.utc).isoformat(), 'sourceHashes': hashes, 'passed': False,
 'limits': ['Owned socket-only PostgreSQL and synthetic identities; no inherited DB credentials',
            'No provider dispatch, email, Apple operation or live deployment',
            'Internal testing only; Int32.max is finite legacy compatibility, private seats remain one',
            'Master revocation does not cancel previously admitted work or settlement']}
SNAPSHOT = """select json_object_agg(p.oid::regprocedure::text,json_build_object(
 'definition',pg_get_functiondef(p.oid),'acl',p.proacl,'owner',p.proowner,
 'definer',p.prosecdef,'volatility',p.provolatile,'config',p.proconfig))
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public';"""
RETAIL = """select json_build_object(
 'plans',(select jsonb_agg(to_jsonb(p)order by plan)from plan_entitlements p),
 'industries',(select jsonb_agg(to_jsonb(p)order by plan,space_type)from plan_entitlement_overrides p),
 'routes',(select jsonb_agg(to_jsonb(p)order by id)from ai_routes p),
 'configuration',(select jsonb_agg(to_jsonb(p)order by key)from app_config p));"""
ENT_INSERT = ("  if public.org_has_private_internal_testing(p_org) then\n    v_base.plan := 'team';\n"
 '    v_base.seats := 1;\n    v_base.renders_per_month := 2147483647;\n'
 '    v_base.photo_edits_per_month := 2147483647;\n    v_base.reels_per_month := 2147483647;\n'
 '    v_base.aerials_per_month := 2147483647;\n    v_base.topaz_per_month := 2147483647;\n'
 '    v_base.cogs_ceiling_cents := 2147483647;\n    return v_base;\n  end if;\n')
MASTER_DENY = '  if exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and s.revoked_at is null) then return false; end if;\n'
SEAT_INSERT = '    (select 1 where public.org_has_private_internal_testing(p_org)),\n'
USED_INSERT = ('\n        + (select count(*) from public.private_internal_testing_sponsorships s\n'
 '            where s.sponsor_org_id=p_org and s.revoked_at is null and s.starts_at<=now()\n'
 '              and(s.expires_at is null or s.expires_at>now())\n'
 '              and not exists(select 1 from public.memberships m where m.org_id=p_org and m.user_id=s.beneficiary_user_id))')
ACCEPT_DECLARE = '  v_private_result jsonb;\n'
ACCEPT_BRANCH = ('  v_private_result := public.accept_private_internal_test_invite(p_user,p_token_hash);\n'
 '  if v_private_result is not null then return v_private_result; end if;\n')

def psql(database=DB):
 return [BINS['psql'], '-X', '--no-password', *CONN, '-d', database, '-v', 'ON_ERROR_STOP=1']

def run(name, args, expected=0, timeout=60):
 r = subprocess.run([str(x) for x in args], env=ENV, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
 (OUT / (name + '.log')).write_text(r.stdout)
 assert r.returncode == expected, (name, r.returncode, r.stdout[-4500:])
 return r.stdout

def query(name, command, database=DB, expected=0):
 file = OUT / (name + '.sql'); file.write_text(command)
 return run(name, [*psql(database), '-Atq', '-f', file], expected)

def positive(name, test=LEGACY_TEST):
 output = run(name, [*psql(), '-Atq', '-f', test])
 match = re.search(r'\n(\d+)\nPASS: private internal testing SQL assertions; fixtures rolled back\.', output)
 # Four table privilege cases, two RLS tables and seven service-only RPCs.
 expected = len(re.findall(r'select pg_temp\.private_(?:ok|denied)\(', test.read_text())) + 3 + 1 + 6
 assert match and int(match[1]) == expected, (name, 'Incomplete exact assertion inventory', expected, output[-400:])
 return int(match[1])

def compare(before, after):
 inserts = {'org_has_internal_testing_grant(uuid)': [MASTER_DENY], 'org_entitlement(uuid)': [ENT_INSERT],
  'org_seats_allowed(uuid)': [SEAT_INSERT], 'org_seats_used(uuid)': [USED_INSERT],
  'accept_org_invite(uuid,text)': [ACCEPT_DECLARE, ACCEPT_BRANCH]}
 for name, old in before.items():
  new = after[name].copy()
  for insertion in inserts.get(name, []):
   assert new['definition'].count(insertion) == 1, (name, 'Missing/duplicated reviewed insertion')
   new['definition'] = new['definition'].replace(insertion, '')
  assert new == old, ('Unreviewed function/ACL/owner/mode/volatility/path changed', name)

def rollout_seed():
 return """insert into auth.users(id,email,is_anonymous)values
 ('cb100509-0000-4000-8000-000000000001','rollout-host@fixture.invalid',false),
 ('cb100509-0000-4000-8000-000000000002','rollout-retail@fixture.invalid',false),
 ('cb100509-0000-4000-8000-000000000003','rollout-removed@fixture.invalid',false);
 update profiles set is_admin=true where id='cb100509-0000-4000-8000-000000000001';
 update orgs set plan='team',plan_source='manual'where id in(select org_id from memberships where user_id in('cb100509-0000-4000-8000-000000000001','cb100509-0000-4000-8000-000000000002'));
 insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)
 select org_id,user_id,true from memberships where user_id='cb100509-0000-4000-8000-000000000001';
 insert into org_invites(org_id,invited_by,token_hash,role)
 select org_id,user_id,repeat('b',64),'agent'from memberships where user_id='cb100509-0000-4000-8000-000000000001';
 insert into org_invites(org_id,invited_by,token_hash,role,accepted_at,accepted_by)
 select org_id,user_id,repeat('c',64),'agent',now(),'cb100509-0000-4000-8000-000000000003'from memberships where user_id='cb100509-0000-4000-8000-000000000001';
 insert into org_invites(org_id,invited_by,token_hash,role)
 select org_id,user_id,repeat('d',64),'agent'from memberships where user_id='cb100509-0000-4000-8000-000000000002';"""

def rollout_check():
 return """do $$begin
 if not(select private_testing from org_invites where token_hash=repeat('b',64))
 or(select private_testing from org_invites where token_hash=repeat('c',64))
 or(select private_testing from org_invites where token_hash=repeat('d',64))then raise exception 'PRIVATE TESTING FAIL: rollout capture crosses accepted or retail boundary';end if;
 begin perform accept_org_invite('cb100509-0000-4000-8000-000000000003',repeat('c',64));
 raise exception 'PRIVATE TESTING FAIL: removed legacy code became reusable';exception when others then if sqlerrm not like'RP404:%'then raise;end if;end;
 end$$;"""

def admission_race():
 # A hold that passes authority before master revocation may complete; a
 # subsequent fresh reservation after the revoke commits must use raw caps.
 query('race-seed', """insert into auth.users(id,email,is_anonymous)values
 ('cb100510-0000-4000-8000-000000000001','race-host@fixture.invalid',false),
 ('cb100510-0000-4000-8000-000000000002','race-benef@fixture.invalid',false);
 update profiles set is_admin=true where id='cb100510-0000-4000-8000-000000000001';
 update orgs set plan='team',plan_source='manual'where id=(select org_id from memberships where user_id='cb100510-0000-4000-8000-000000000001');
 update orgs set trial_ends_at=now()-interval '1 day'where id=(select org_id from memberships where user_id='cb100510-0000-4000-8000-000000000002');
 insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)select org_id,user_id,true from memberships where user_id='cb100510-0000-4000-8000-000000000001';
 set role service_role;
 select enroll_private_internal_tester('cb100510-0000-4000-8000-000000000001',(select org_id from memberships where user_id='cb100510-0000-4000-8000-000000000001'),'cb100510-0000-4000-8000-000000000002',null);""")
 orgs = json.loads(query('race-orgs', "select json_object_agg(user_id,org_id)from memberships where user_id in('cb100510-0000-4000-8000-000000000001','cb100510-0000-4000-8000-000000000002');"))
 host, benef = 'cb100510-0000-4000-8000-000000000001', 'cb100510-0000-4000-8000-000000000002'
 handle = (OUT / 'race-held-admission.log').open('w')
 first = subprocess.Popen(psql(), env=ENV, text=True, stdin=subprocess.PIPE, stdout=handle, stderr=subprocess.STDOUT)
 try:
  first.stdin.write(f"begin;set local role service_role;select app_video_cost_reserve('{benef}','{orgs[benef]}','before-master-revoke','reel','fal','fixture-model',repeat('a',64),6001,1,6001,'{{}}');\n\\echo PRIVATE_HOLD_ADMITTED\n");first.stdin.flush()
  deadline = time.monotonic() + 5
  while 'PRIVATE_HOLD_ADMITTED' not in (OUT / 'race-held-admission.log').read_text():
   assert first.poll() is None and time.monotonic() < deadline;time.sleep(.03)
  query('race-master-revoke', f"set role service_role;update org_internal_testing_grants set revoked_at=now()where org_id='{orgs[host]}';")
  first.stdin.write('commit;\n\\q\n');first.stdin.flush();first.wait(timeout=10);assert first.returncode == 0
  denied = query('race-post-revoke-denied', f"set role service_role;select app_video_cost_reserve('{benef}','{orgs[benef]}','after-master-revoke','reel','fal','fixture-model',repeat('a',64),1,1,1,'{{}}');", expected=3)
  assert 'RP402:' in denied
  query('race-settlement', f"set role service_role;select app_video_cost_settle('{benef}','{orgs[benef]}','before-master-revoke','admitted-before-revocation');")
  return {'admittedBeforeRevokeMayCommit': True, 'freshAfterRevokeDenied': True, 'priorReceiptSettlementRetained': True, 'providerCalls': 0}
 finally:
  if first.poll() is None:first.terminate();first.wait(timeout=10)
  handle.close()

def invitation_race(finish):
 name = 'invite-race-' + finish
 prefix = 'cb100511' if finish == 'commit' else 'cb100512'
 host, left, right = [prefix + '-0000-4000-8000-' + f'{i:012d}' for i in (1, 2, 3)]
 token = '4' * 64 if finish == 'commit' else '5' * 64
 query(name + '-seed', f"""insert into auth.users(id,email,is_anonymous)values
 ('{host}','{name}-host@fixture.invalid',false),('{left}','{name}-left@fixture.invalid',false),('{right}','{name}-right@fixture.invalid',false);
 update profiles set is_admin=true where id='{host}';
 update orgs set plan='team',plan_source='manual'where id=(select org_id from memberships where user_id='{host}');
 insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)select org_id,user_id,true from memberships where user_id='{host}';
 set role service_role;select create_org_invite('{host}',(select org_id from memberships where user_id='{host}'),null,'agent','{token}');""")
 handles = [(OUT / (name + '-first.log')).open('w'), (OUT / (name + '-second.log')).open('w')]
 first = subprocess.Popen(psql(), env={**ENV, 'PGAPPNAME': name + '-first'}, text=True, stdin=subprocess.PIPE, stdout=handles[0], stderr=subprocess.STDOUT)
 second = None
 try:
  first.stdin.write(f"begin;set local role service_role;select accept_org_invite('{left}','{token}');\n\\echo PRIVATE_JOIN_HELD\n");first.stdin.flush()
  deadline = time.monotonic() + 5
  while 'PRIVATE_JOIN_HELD' not in (OUT / (name + '-first.log')).read_text():
   assert first.poll() is None and time.monotonic() < deadline;time.sleep(.03)
  file = OUT / (name + '-second.sql');file.write_text(f"set role service_role;select accept_org_invite('{right}','{token}');")
  second = subprocess.Popen([*psql(), '-f', file], env={**ENV, 'PGAPPNAME': name + '-second'}, text=True, stdout=handles[1], stderr=subprocess.STDOUT)
  deadline = time.monotonic() + 5
  while True:
   if query(name + '-lock-observed', f"select count(*)from pg_stat_activity where application_name='{name}-second'and wait_event_type='Lock';").strip() == '1':break
   assert second.poll() is None and time.monotonic() < deadline;time.sleep(.03)
  first.stdin.write(f'{finish};\n\\q\n');first.stdin.flush();first.wait(timeout=10);second.wait(timeout=10)
  assert first.returncode == 0 and second.returncode == (3 if finish == 'commit' else 0)
  if finish == 'commit':assert 'RP404:' in (OUT / (name + '-second.log')).read_text()
  winner, loser = (left, right) if finish == 'commit' else (right, left)
  query(name + '-final-boundaries', f"""do $$declare host_org uuid;begin
   select org_id into host_org from memberships where user_id='{host}';
   if(select accepted_by from org_invites where token_hash='{token}')is distinct from '{winner}'::uuid
    or(select count(*)from private_internal_testing_sponsorships where sponsor_org_id=host_org and revoked_at is null)<>1
    or exists(select 1 from memberships where org_id=host_org and user_id in('{left}','{right}'))
    or exists(select 1 from user_workspace_state where user_id='{loser}')
    or org_seats_used(host_org)<>2 then raise exception 'PRIVATE TESTING FAIL: concurrent invite gave two seats/shared access or changed losing default';end if;
   end$$;""")
  return {'transaction': finish, 'actualProfileLockWaitObserved': True, 'onePrivateWinnerNoSharedMembership': True, 'losingWorkspaceUnchanged': True}
 finally:
  for p in (first, second):
   if p and p.poll() is None:p.terminate();p.wait(timeout=10)
  for h in handles:h.close()

started = False
try:
 run('init', [BINS['initdb'], '-D', DATA, '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
 run('start', [BINS['pg_ctl'], '-D', DATA, '-l', OUT / 'postgres.log', '-w', '-t', '30', '-o',
  f"-k {SOCK} -p 55468 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=12", 'start']);started = True
 run('create', [BINS['createdb'], '--no-password', *CONN, DB])
 assert query('owned-identity', "select current_setting('data_directory')||'|'||current_setting('listen_addresses')||'|'||current_database();").strip() == f'{DATA}||{DB}'
 run('bootstrap', [*psql(), '-q', '-f', SQL / 'tests/ci-bootstrap.sql'])
 for migration in MIGRATIONS:
  if migration == TARGET:break
  run('apply-' + migration.stem, [*psql(), '-q', '-f', migration])
 before = json.loads(query('before-functions', SNAPSHOT));retail = query('before-retail', RETAIL)
 query('rollout-pre-sponsorship-seed', rollout_seed())
 run('apply-private-sponsorship', [*psql(), '-q', '-f', TARGET])
 after = json.loads(query('after-functions', SNAPSHOT));compare(before, after)
 assert query('after-retail', RETAIL) == retail
 query('rollout-capture-and-removed-legacy-code', rollout_check())
 # Remove synthetic rollout rows before the rolled-back isolated fixtures.
 query('rollout-clean-owned-fixture-only', "delete from orgs where id in(select org_id from memberships where user_id::text like'cb100509-%');delete from auth.users where id::text like'cb100509-%';")
 receipt['fullMigrationCount'] = len(MIGRATIONS)
 receipt['freshSQLAssertions'] = positive('fresh-positive')
 run('replay-private-sponsorship', [*psql(), '-q', '-f', TARGET])
 assert json.loads(query('replay-functions', SNAPSHOT)) == after
 receipt['replaySQLAssertions'] = positive('replay-positive')
 receipt['preservation'] = {'allExistingFunctionsUnchangedExceptFiveReviewedInsertions': True,
  'allExistingACLsOwnerModesVolatilityPathsUnchanged': True, 'retailRowsRoutesAndConfigurationUnchanged': True,
  'replayDefinitionsUnchanged': True, 'pendingActiveOnlyCapturedWithoutLegacyAcceptedReplay': True}
 controls = []
 helper = after['org_has_private_internal_testing(uuid)']['definition']
 trigger = after['stamp_private_internal_testing_invite()']['definition']
 for name, function, anchor, replacement, failure in (
  ('private-caller-denial', helper, ' if not(', ' if false and not(', 'host cannot borrow beneficiary private allowance'),
  ('private-named-beneficiary', helper, 'u.is_anonymous is false', 'true', 'anonymous beneficiary cannot inherit benefits'),
  ('private-owner-boundary', helper, "m.role='owner'", "m.role in('owner','agent')", 'beneficiary ownership loss disables benefit'),
  ('private-solo-boundary', helper, 'not exists(select 1 from public.memberships x where x.org_id=s.private_org_id and x.user_id<>s.beneficiary_user_id)', 'true', 'private org sharing disables projection'),
  ('private-content-separation', helper, 'not exists(select 1 from public.memberships x where x.org_id=s.sponsor_org_id and x.user_id=s.beneficiary_user_id)', 'true', 'host content membership disables private status'),
  ('private-revocation', helper, 's.revoked_at is null', 'true', 'revoked sponsorship restores raw allowance'),
  ('private-expiry', helper, '(s.expires_at is null or s.expires_at>now())', '(true)', 'expired sponsorship disables benefits'),
  ('private-master-authority', helper, 'public.private_internal_testing_master_owner(s.sponsor_org_id)=s.sponsor_owner_user_id', 'true', 'host admin revocation disables private benefit'),
  ('private-seat-one', after['org_seats_allowed(uuid)']['definition'], SEAT_INSERT, SEAT_INSERT.replace('select 1 ', 'select 2147483647 '), 'beneficiary allowance has Team max business but one seat'),
  ('private-agent-invite', trigger, "if new.role<>'agent'then", "if false and new.role<>'agent'then", 'private host refuses admin invitations'),
  ('private-inactive-invite', trigger, 'if public.private_internal_testing_master_owner(new.org_id)is null then', 'if false and public.private_internal_testing_master_owner(new.org_id)is null then', 'inactive host trigger independently refuses invitation'),
  ('private-accepted-fence', trigger, "if tg_op='UPDATE'and old.private_testing and old.accepted_at is not null", "if false and tg_op='UPDATE'and old.private_testing and old.accepted_at is not null", 'accepted private receipt cannot be retargeted'),
  ('private-no-chain', after['org_has_internal_testing_grant(uuid)']['definition'], MASTER_DENY, '', 'no sponsored org chaining'),
  ('private-accept-routing', after['accept_org_invite(uuid,text)']['definition'], ACCEPT_BRANCH, '', 'old accept contract routes own org and owner role'),
 ):
  assert function.count(anchor) >= 1, (name, 'Control anchor missing')
  query(name + '-compile', function.replace(anchor, replacement))
  output = run(name + '-denied', [*psql(), '-Atq', '-f', LEGACY_TEST], 3)
  assert 'PRIVATE TESTING FAIL: ' + failure in output, (name, 'Failed at unrelated boundary', output[-2500:])
  query(name + '-restore', function)
  controls.append({'name': name, 'compiled': True, 'namedBoundary': failure, 'restoredSQLAssertions': positive(name + '-restored')})
 receipt['compiledFaultControls'] = controls
 unknown = after['org_entitlement(uuid)']['definition'].replace('begin\n', 'begin\n -- unknown future deployment\n', 1)
 query('unknown-body-compile', unknown);unknown_before = json.loads(query('unknown-before-failed-migration', SNAPSHOT))
 failed = run('unknown-migration-denied', [*psql(), '-q', '-f', TARGET], 3)
 assert 'org_entitlement definition changed; review private sponsorship' in failed
 assert json.loads(query('unknown-after-failed-migration', SNAPSHOT)) == unknown_before
 query('unknown-body-restore', after['org_entitlement(uuid)']['definition'])
 receipt['unknownBodyRefusedWithoutOverwrite'] = True
 receipt['admissionRevocationRace'] = admission_race()
 receipt['invitationRaces'] = [invitation_race('commit'), invitation_race('rollback')]
 # Exact standalone deployment compatibility with pre-beta PR27 definitions.
 standalone = 'rendprop_private_standalone'
 run('standalone-create', [BINS['createdb'], '--no-password', *CONN, standalone])
 run('standalone-bootstrap', [*psql(standalone), '-q', '-f', SQL / 'tests/ci-bootstrap.sql'])
 prior = [p for p in MIGRATIONS if p.name < '20261005150445']
 for migration in [*prior, MASTER, TARGET]:run('standalone-' + migration.stem, [*psql(standalone), '-q', '-f', migration])
 run('drop-full-owned-db', [*psql('postgres'), '-c', f'drop database {DB};'])
 run('standalone-clone', [BINS['createdb'], '--no-password', *CONN, '--template', standalone, DB])
 receipt['standaloneMigrationCount'] = len(prior) + 2
 receipt['standalonePreBetaSQLAssertions'] = positive('standalone-pre-beta-positive')
 assert len(MIGRATIONS) - len(prior) - 2 == 5
 receipt['standaloneExcludesFivePendingBetaMigrations'] = True
 # Current launch authority is a separate fresh schema. Never restore/replay
 # the historical grant migration over its new Team-private definitions.
 run('drop-historical-clone', [*psql('postgres'), '-c', f'drop database {DB};'])
 run('create-current-final', [BINS['createdb'], '--no-password', *CONN, DB])
 run('current-bootstrap', [*psql(), '-q', '-f', SQL / 'tests/ci-bootstrap.sql'])
 for migration in FINAL_MIGRATIONS:
  run('current-' + migration.stem, [*psql(), '-q', '-f', migration])
  if migration == FINAL_TARGET:
   historical_followup = json.loads(query('historical-followup-functions', SNAPSHOT))
   run('historical-followup-exact-replay', [*psql(), '-q', '-f', FINAL_TARGET])
   assert json.loads(query('historical-followup-replayed-functions', SNAPSHOT)) == historical_followup
   receipt['historicalFollowupSQLAssertions'] = positive('historical-followup-private-positive', TEST)
   receipt['historicalFollowupReplayAtOwnSchemaPoint'] = True
 receipt['currentMigrationCount'] = len(FINAL_MIGRATIONS)
 receipt['currentSQLAssertions'] = positive('current-final-private-positive', TEST)
 current_snapshot = json.loads(query('current-final-functions', SNAPSHOT))
 refused = run('superseded-followup-refused', [*psql(), '-q', '-f', FINAL_TARGET], 3)
 assert 'Review changed function notification_register_device_session' in refused
 assert json.loads(query('superseded-followup-refusal-functions', SNAPSHOT)) == current_snapshot, 'Historical overlay must not overwrite newer reviewed functions'
 receipt['supersededFollowupRefusedAtomic'] = True
 run('replay-current-private-authority', [*psql(), '-q', '-f', FINAL_OVERLAY])
 assert json.loads(query('current-final-replayed-functions', SNAPSHOT)) == current_snapshot
 receipt['currentReplaySQLAssertions'] = positive('current-final-private-replayed', TEST)
 receipt['currentAuthorityReplayOnly'] = FINAL_OVERLAY.name

 assert all(hashlib.sha256((ROOT / n).read_bytes()).hexdigest() == h for n, h in hashes.items()), 'Consumed source changed during proof'
 receipt['sourceBoundAtEnd'] = True;receipt['passed'] = True
finally:
 if started and (DATA / 'postmaster.pid').exists():run('stop', [BINS['pg_ctl'], '-D', DATA, '-m', 'fast', '-w', '-t', '30', 'stop'])
 receipt['finishedAt'] = datetime.now(timezone.utc).isoformat()
 (OUT / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
 print('Private internal testing evidence:', OUT, flush=True)
print('PASS: source/ACL preservation, fresh/replay/standalone, actual privacy/deletion/accounting and compiled controls.', flush=True)
