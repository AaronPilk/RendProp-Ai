#!/usr/bin/env python3
"""Owned socket-only PostgreSQL; tests deletion/adoption overlap without HTTP.

Retains a source-bound receipt and logs. Never accepts a database URL or uses
inherited PG credentials. Only the freshly created exact cluster is stopped.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import signal
import subprocess
import tempfile
import time

POSTGRES_TOOLS = ('initdb', 'pg_ctl', 'psql', 'createdb')
# The Homebrew keg this fixture was first written against, kept as the
# fallback for a Mac without the server tools on PATH. CI puts
# /usr/lib/postgresql/16/bin first on PATH and is found through that.
HOMEBREW_POSTGRES = Path('/opt/homebrew/opt/postgresql@17/bin')


def postgres_binaries():
    """One directory holding all four server/client tools, so the cluster this
    run creates and the psql that drives it come from the same build."""
    candidates = []
    on_path = shutil.which('initdb')
    if on_path:
        candidates.append(Path(on_path).resolve().parent)
    candidates.append(HOMEBREW_POSTGRES)
    for directory in candidates:
        if all((directory / name).is_file() for name in POSTGRES_TOOLS):
            return directory
    raise SystemExit('PostgreSQL tools (' + ', '.join(POSTGRES_TOOLS) + ') were not found together on PATH '
                     f'or in {HOMEBREW_POSTGRES}; put a server bin directory such as /usr/lib/postgresql/16/bin first on PATH')


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--provider-commit',help='Optional exact local commit for the sibling0041 migration; no checkout or remote fetch')
    args=parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    binaries = postgres_binaries()
    assert shutil.disk_usage('/tmp').free >= 1024**3, 'Need 1 GiB free; no cleanup performed'
    out = Path(tempfile.mkdtemp(prefix='rendprop-deletion-db-', dir='/tmp'))
    cluster, socket = out / 'cluster', out / 'socket'
    socket.mkdir(mode=0o700)
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'TZ': 'UTC'}
    receipt = {'accepted': False, 'commands': [], 'sourceHashes': {}, 'clusterStopped': False,
               'concurrentCases': [], 'postgresBinaries': str(binaries)}
    migrations = sorted((root / 'services/supabase/migrations').glob('*.sql'))
    target = root / 'services/supabase/migrations/0039_account_deletion_intent.sql'
    test = root / 'services/supabase/tests/account_deletion_intent.sql'
    spatial_test = root / 'services/supabase/tests/account_deletion_spatial.sql'
    bootstrap = root / 'services/supabase/tests/ci-bootstrap.sql'
    for path in [*migrations, test, spatial_test, bootstrap, Path(__file__)]:
        receipt['sourceHashes'][str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f'EVIDENCE: {out}', flush=True)
    provider_target=None
    if args.provider_commit:
        import re
        assert re.fullmatch('[0-9a-f]{40}',args.provider_commit),'Need exact local commit hash'
        provider_path='services/supabase/migrations/0041_spatial_provider_attempts.sql'
        source=subprocess.run(['/usr/bin/git','show',args.provider_commit+':'+provider_path],cwd=root,
          env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
        assert source.returncode==0,'Provider migration not found in local git objects'
        provider_target=out/'0041_spatial_provider_attempts.sql'
        provider_target.write_bytes(source.stdout)
        receipt['providerSourceCommit']=args.provider_commit
        receipt['providerMigrationSha256']=hashlib.sha256(source.stdout).hexdigest()

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

    connection = ['-h', str(socket), '-p', '55443', '-U', 'postgres']
    psql = [str(binaries / 'psql'), '-X', '--no-password', *connection, '-d', 'rendprop_deletion_audit', '-v', 'ON_ERROR_STOP=1']
    started = False
    prior_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP)}
    def interrupted(signum, _frame):
        raise RuntimeError(f'Deletion fixture interrupted by signal {signum}')
    for sig in prior_handlers:
        signal.signal(sig, interrupted)
    try:
        run('version', [str(binaries / 'psql'), '--version'])
        run('initdb', [str(binaries / 'initdb'), '-D', str(cluster), '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
        run('start', [str(binaries / 'pg_ctl'), '-D', str(cluster), '-l', str(out / 'postgres.log'), '-w', '-t', '30', '-o',
                      f"-k {socket} -p 55443 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=10", 'start'])
        started = True
        run('createdb', [str(binaries / 'createdb'), '--no-password', *connection, 'rendprop_deletion_audit'])
        identity = run('identity', psql + ['-Atc', "select current_setting('data_directory'),current_setting('listen_addresses'),current_database();"])
        assert identity.strip() == f'{cluster}||rendprop_deletion_audit'
        env['PGOPTIONS'] = '-c statement_timeout=15000 -c lock_timeout=5000'
        run('bootstrap', psql + ['-q', '-f', str(bootstrap)])
        run('auth-fixture-schema', psql + ['-qc', 'alter table auth.users add column is_anonymous boolean not null default false;'])
        for migration in migrations:
            if migration != target:
                run('apply-' + migration.stem, psql + ['-q', '-1', '-f', str(migration)])
            else:
                run('fresh-order-0039',psql+['-q','-1','-f',str(target)])
                fresh=run('before-spatial-schema',psql+['-Atqc',"""begin;
insert into auth.users(id,email,raw_user_meta_data) values('a039e000-0000-4000-8000-000000000001','pre-spatial@fixture.invalid','{}');
set local role service_role;
select public.prepare_account_deletion('a039e000-0000-4000-8000-000000000001','fixture-uploads','fixture-renders')->>'snapshot_version';
rollback;"""])
                assert fresh.strip()=='2','Fresh ordered install did not return the exact v2 receipt'
        if provider_target:
            run('apply-paired0041',psql+['-q','-1','-f',str(provider_target)])

        # The old handler snapshots org IDs in one HTTP request and destroys
        # them in later requests. This SQL schedule reproduces those exact
        # committed boundaries, with a real adoption transaction in between.
        before = out / 'stale-snapshot-before.sql'
        before.write_text("""begin;
insert into auth.users(id,email,raw_user_meta_data,is_anonymous) values
('a039f000-0000-4000-8000-000000000001','before-source@fixture.invalid','{}',true),
('a039f000-0000-4000-8000-000000000002','before-dest@fixture.invalid','{}',false);
create temp table old_snapshot as select org_id from public.memberships where user_id='a039f000-0000-4000-8000-000000000001';
set local role service_role;
select public.adopt_anonymous_org('a039f000-0000-4000-8000-000000000002','a039f000-0000-4000-8000-000000000001',
(select org_id from public.memberships where user_id='a039f000-0000-4000-8000-000000000001'),gen_random_uuid());
reset role;
delete from public.orgs where id in(select org_id from old_snapshot);
do $$ begin if not exists(select 1 from public.memberships where user_id='a039f000-0000-4000-8000-000000000002'
and org_id in(select org_id from old_snapshot)) then raise exception 'stale snapshot destroyed adoption winner'; end if; end $$;
rollback;
""")
        negative = run('before-stale-snapshot', psql + ['-f', str(before)], expected=3)
        assert 'stale snapshot destroyed adoption winner' in negative, 'Wrong-reason baseline failure'
        run('apply-0039', psql + ['-q', '-1', '-f', str(target)])
        for name in ['after', 'replayed']:
            if name == 'replayed':
                run('replay-0039', psql + ['-q', '-1', '-f', str(target)])
            output = run(name, psql + ['-f', str(test)])
            assert 'PASS: 41 deletion SQL assertions; all fixtures rolled back.' in output
            assert 'PASS: 35 spatial deletion SQL assertions; all fixtures rolled back.' in run(name+'-spatial',psql+['-f',str(spatial_test)])

        # A genuine changed-authority mutant, not a printed negative control:
        # disable the object-prefix guard in this disposable function only.
        definition = run('prepare-definition', psql + ['-Atc', "select pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);"])
        needle = "if exists(select 1 from jsonb_array_elements(object_targets) t where t->>'valid' is distinct from 'true') then"
        assert definition.count(needle) == 1, 'Mutation target missing or ambiguous'
        mutant = out / 'ownership-mutant.sql'
        mutant.write_text(definition.replace(needle, 'if false then'))
        run('apply-ownership-mutant', psql + ['-f', str(mutant)])
        output = run('reject-ownership-mutant', psql + ['-f', str(test)], expected=3)
        assert 'wrong failure for foreign photo reference fails before destruction: fixture accepted forbidden operation' in output
        run('restore-0039', psql + ['-q', '-1', '-f', str(target)])
        assert 'PASS: 41 deletion SQL assertions; all fixtures rolled back.' in run('restored', psql + ['-f', str(test)])
        provider_definition=run('provider-proof-definition',psql+['-Atc',
            "select pg_get_functiondef('public.account_deletion_provider_ready(uuid,uuid)'::regprocedure);"])
        assert provider_definition.count('return false;')==1 and provider_definition.count('return coalesce(ready,false);')==1
        provider_mutant=out/'provider-proof-mutant.sql'
        provider_mutant.write_text(provider_definition.replace('return false;','return true;').replace('return coalesce(ready,false);','return true;'))
        run('apply-provider-proof-mutant',psql+['-f',str(provider_mutant)])
        broken=run('reject-provider-proof-mutant',psql+['-f',str(spatial_test)],expected=3)
        assert 'missing provider proof is not cleanup success' in broken
        run('restore-provider-proof',psql+['-q','-1','-f',str(target)])
        assert 'PASS: 35 spatial deletion SQL assertions; all fixtures rolled back.' in run('restored-spatial',psql+['-f',str(spatial_test)])

        for number, case, first_action, end in [
            (1, 'adoption-commits-first', 'adopt', 'commit'),
            (2, 'adoption-rolls-back', 'adopt', 'rollback'),
            (3, 'deletion-commits-first', 'delete', 'commit'),
            (4, 'deletion-rolls-back', 'delete', 'rollback'),
        ]:
            prefix = f'a039e00{number}'
            source, dest, operation = [f'{prefix}-0000-4000-8000-{i:012d}' for i in (1, 2, 3)]
            run(case + '-setup', psql + ['-qc', f"insert into auth.users(id,email,raw_user_meta_data,is_anonymous) values ('{source}','{source}@fixture.invalid','{{}}',true),('{dest}','{dest}@fixture.invalid','{{}}',false);"])
            org = run(case + '-org', psql + ['-Atc', f"select org_id from public.memberships where user_id='{source}';"]).strip()
            assert len(org) == 36
            run(case + '-listing', psql + ['-qc', f"insert into public.listings(org_id,agent_id,status) values('{org}','{source}','draft');"])
            actions = {
                'adopt': f"select public.adopt_anonymous_org('{dest}','{source}','{org}','{operation}');",
                'delete': f"select public.prepare_account_deletion('{source}','fixture-uploads','fixture-renders');",
            }
            first_sql = f"begin; set local application_name='deletion-first'; set local role service_role; {actions[first_action]} select pg_sleep(2); {end};"
            second_action = 'delete' if first_action == 'adopt' else 'adopt'
            first = subprocess.Popen(psql + ['-Atqc', first_sql], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            second = None
            try:
                def observe(query, desired, timeout):
                    deadline = time.monotonic() + timeout
                    while time.monotonic() < deadline:
                        state = subprocess.run(psql + ['-Atqc', query], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
                        assert state.returncode == 0
                        if state.stdout.strip() == desired:
                            return True
                        time.sleep(0.02)
                    return False
                assert observe("select count(*) from pg_stat_activity where application_name='deletion-first' and wait_event='PgSleep';", '1', 5), 'First did not reach overlap barrier'
                second = subprocess.Popen(psql + ['-Atqc', "set application_name='deletion-second'; set role service_role; " + actions[second_action]], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                blocked = observe("select count(*) from pg_stat_activity where application_name='deletion-second' and wait_event_type='Lock';", '1', 1.5)
                assert blocked, 'Second transaction did not actually overlap under row lock'
                outputs = [first.communicate(timeout=10)[0], second.communicate(timeout=10)[0]]
                exits = [first.returncode, second.returncode]
                for i, output in enumerate(outputs):
                    (out / f'{case}-{i}.log').write_text(output)
                expected = [0, 1] if case == 'deletion-commits-first' else [0, 0]
                assert exits == expected, f'{case}: unexpected exits {exits}; {out}'
                if case == 'deletion-commits-first':
                    assert 'RP409: an account is being deleted' in outputs[1]
                state = run(case + '-state', psql + ['-Atc', f"select (select count(*) from public.orgs where id='{org}'),(select count(*) from public.memberships where org_id='{org}' and user_id='{dest}'),(select count(*) from public.deletion_requests where user_id='{source}'),(select coalesce(bool_and(jsonb_array_length(ownership_scope->'solo_orgs')=0),true) from public.deletion_requests where user_id='{source}');"]).strip()
                expected_state = {
                    'adoption-commits-first': '1|1|1|t', 'adoption-rolls-back': '0|0|1|f',
                    'deletion-commits-first': '0|0|1|f', 'deletion-rolls-back': '1|1|0|t',
                }[case]
                assert state == expected_state, f'{case}: state {state} != {expected_state}'
                receipt['concurrentCases'].append({'name': case, 'exits': exits, 'overlapObserved': blocked, 'state': state})
            finally:
                for child in [first, second]:
                    if child is not None and child.poll() is None:
                        child.terminate()
                        child.communicate(timeout=10)
        # Actual spatial_claim competes for the same ownership locks. No GPU
        # starts: this fixture exercises PostgreSQL job authority only.
        for number,first_action in enumerate(['delete','claim'],1):
            case='spatial-'+first_action+'-commits-first'
            source,listing,job,worker=[f'b039e00{number}-0000-4000-8000-{i:012d}' for i in (1,2,3,4)]
            run(case+'-setup',psql+['-qc',f"""insert into auth.users(id,email,raw_user_meta_data)
values('{source}','{source}@fixture.invalid','{{}}');
insert into public.listings(id,org_id,agent_id) select '{listing}',org_id,'{source}' from public.memberships where user_id='{source}';
insert into public.spatial_jobs(id,org_id,listing_id,actor_id,capture_id,idem_key,room_label,capture_manifest,status,
max_cost_cents,max_seconds,max_training_seconds,max_iterations,max_gaussians)
select '{job}',org_id,'{listing}','{source}',gen_random_uuid(),gen_random_uuid(),'Fixture','{{"frames":[]}}','queued',
600,7200,900,3000,500000 from public.memberships where user_id='{source}';
update public.spatial_runtime set enabled=true where singleton;"""])
            actions={'delete':f"select public.prepare_account_deletion('{source}','fixture-uploads','fixture-renders');",
                     'claim':f"select public.spatial_claim('{worker}');"}
            first=subprocess.Popen(psql+['-Atqc',"begin;set local application_name='deletion-first';set local role service_role;"+
              actions[first_action]+"select pg_sleep(2);commit;"],cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            second=None
            try:
                assert observe("select count(*) from pg_stat_activity where application_name='deletion-first' and wait_event='PgSleep';",'1',5)
                second_action='claim' if first_action=='delete' else 'delete'
                second=subprocess.Popen(psql+['-Atqc',"set application_name='deletion-second';set role service_role;"+actions[second_action]],
                  cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
                blocked=observe("select count(*) from pg_stat_activity where application_name='deletion-second' and wait_event_type='Lock';",'1',1.5)
                assert blocked,'Spatial/deletion transactions never actually overlapped'
                outputs=[first.communicate(timeout=10)[0],second.communicate(timeout=10)[0]]
                exits=[first.returncode,second.returncode]
                for i,output in enumerate(outputs):(out/f'{case}-{i}.log').write_text(output)
                assert exits==([0,1] if first_action=='delete' else [0,0]),f'{case}: {exits}'
                if first_action=='delete':assert 'RP403: workspace is unavailable' in outputs[1]
                state=run(case+'-state',psql+['-Atqc',f"""select
(select count(*) from public.spatial_jobs where id='{job}'),
(select count(*) from public.listings where id='{listing}'),
(select jsonb_array_length(payload->'provider_leases') from public.deletion_requests where user_id='{source}');"""]).strip()
                assert state==('0|0|0' if first_action=='delete' else '0|0|1'),f'{case}: {state}'
                receipt['concurrentCases'].append({'name':case,'exits':exits,'overlapObserved':blocked,'state':state})
            finally:
                for child in [first,second]:
                    if child is not None and child.poll() is None:child.terminate();child.communicate(timeout=10)
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
    assert receipt['accepted'], f'Failed deletion gate: {out}'


if __name__ == '__main__':
    main()
