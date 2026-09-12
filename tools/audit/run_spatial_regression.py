#!/usr/bin/env python3
"""Run real 0040 transactions only in a newly owned, socket-only PostgreSQL.

Proves the test is red before the migration and after a deliberately weakened
publish guard. No environment DB URL, existing database, or production traffic.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile
import time


def main():
    root=Path(__file__).resolve().parents[2]
    # Discover a single PostgreSQL bin dir from PATH (CI ubuntu, this Mac) with
    # the Homebrew @17 location as the fallback the original runner hardcoded.
    import shutil
    found=shutil.which('initdb')
    bins=Path(found).resolve().parent if found else Path('/opt/homebrew/opt/postgresql@17/bin')
    assert all((bins/n).is_file() for n in ('initdb','pg_ctl','psql','createdb')),f'PostgreSQL binaries not found near {bins}'
    out=Path(tempfile.mkdtemp(prefix='rendprop-spatial-db-',dir='/tmp'))
    cluster=out/'cluster'; socket=out/'socket';socket.mkdir(mode=0o700)
    env={'PATH':'/usr/bin:/bin','LC_ALL':'C','TZ':'UTC'}
    receipt={'accepted':False,'commands':[],'clusterStopped':False}
    print(f'EVIDENCE: {out}',flush=True)
    def run(name,command,expected=0,input_text=None):
        p=subprocess.run(list(map(str,command)),cwd=root,env=env,text=True,input=input_text,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
        log=out/f'{name}.log';log.write_text(p.stdout)
        receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
        assert p.returncode==expected,f'{name}: exit {p.returncode}, expected {expected}; {log}'
        print(f'{name}: exit={p.returncode}',flush=True);return p.stdout
    connection=['-h',socket,'-p','55447','-U','postgres']
    psql=[bins/'psql','-X','--no-password',*connection,'-d','rendprop_spatial_audit','-v','ON_ERROR_STOP=1']
    target=root/'services/supabase/migrations/0040_spatial_jobs.sql'; test=root/'services/supabase/tests/spatial_jobs.sql'
    # 0041 (provider journal) and 0043 (cancel refund / expiry / tolerant cancel
    # access) replace 0040 functions with the same signatures; the suite asserts
    # the 0043 shapes, so they are applied after 0040 and re-applied after every
    # restore of 0040 (which would otherwise resurrect 0040's bodies).
    followups=[root/'services/supabase/migrations/0041_spatial_provider_attempts.sql',
               root/'services/supabase/migrations/0043_spatial_hardening.sql']
    EXPECT='PASS: 114 spatial SQL assertions'
    def apply_followups(tag):
        for m in followups: run(f'{tag}-'+m.stem[:4],psql+['-q','-1','-f',m])
    started=False
    try:
        run('initdb',[bins/'initdb','-D',cluster,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
        run('start',[bins/'pg_ctl','-D',cluster,'-l',out/'postgres.log','-w','-t','30','-o',f"-k {socket} -p 55447 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=10",'start']);started=True
        run('createdb',[bins/'createdb','--no-password',*connection,'rendprop_spatial_audit'])
        assert run('identity',psql+['-Atc',"select current_setting('data_directory'),current_setting('listen_addresses'),current_database();"]).strip()==f'{cluster}||rendprop_spatial_audit'
        env['PGOPTIONS']='-c statement_timeout=15000 -c lock_timeout=5000'
        run('bootstrap',psql+['-q','-f',root/'services/supabase/tests/ci-bootstrap.sql'])
        run('auth-schema',psql+['-qc','alter table auth.users add column is_anonymous boolean not null default false;'])
        for migration in sorted((root/'services/supabase/migrations').glob('*.sql')):
            if migration.name<'0040':run('apply-'+migration.stem,psql+['-q','-1','-f',migration])
        assert 'spatial assertion failed: durable spatial table exists' in run('before',psql+['-f',test],3)
        run('apply-0040',psql+['-q','-1','-f',target]); apply_followups('apply')
        for phase in ('after','replayed'):
            if phase=='replayed':run('replay-0040',psql+['-q','-1','-f',target]); apply_followups('replay')
            output=run(phase,psql+['-f',test]);assert EXPECT in output, output[-600:]
        definition=run('publish-definition',psql+['-Atc',"select pg_get_functiondef('spatial_publish(uuid,uuid)'::regprocedure);"])
        needle="if j.status not in ('review','ready') or not j.approved or j.excluded or j.review_revision is distinct from j.artifact_revision"
        assert definition.count(needle)==1
        mutant=definition.replace(needle,"if false and (j.status not in ('review','ready') or not j.approved or j.excluded or j.review_revision is distinct from j.artifact_revision").replace("or j.redactions<>'[]'::jsonb then","or j.redactions<>'[]'::jsonb) then")
        run('mutate-publish',psql,input_text=mutant)
        assert 'wrong failure for publication without review rejected: fixture accepted forbidden operation' in run('reject-mutant',psql+['-f',test],3)
        run('restore',psql+['-q','-1','-f',target]); apply_followups('restore')
        assert EXPECT in run('restored',psql+['-f',test])
        # Two real sessions contend on the same ownership/budget locks. Observing
        # wait_event_type=Lock prevents a merely sequential run claiming a race.
        user='a0409000-0000-4000-8000-000000000001'
        listing='a0409000-0000-4000-8000-000000000002'
        jobs=['a0409000-0000-4000-8000-000000000003','a0409000-0000-4000-8000-000000000004']
        setup=f"""
insert into auth.users(id,email,raw_user_meta_data) values('{user}','spatial-race@fixture.invalid','{{}}');
insert into listings(id,org_id,agent_id) select '{listing}',org_id,'{user}' from memberships where user_id='{user}';
insert into spatial_jobs(id,org_id,listing_id,actor_id,capture_id,idem_key,room_label,capture_manifest)
select x.id::uuid,l.org_id,l.id,'{user}',x.id::uuid,x.id::uuid,'Race',jsonb_build_object('image_bytes',2000,'frames',(select jsonb_agg('frames/'||lpad(i::text,6,'0')||'.json') from generate_series(1,20)g(i)))
from listings l cross join (values('{jobs[0]}'),('{jobs[1]}'))x(id) where l.id='{listing}';
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,uploaded,transport_version,content_type)
select ('a0409100-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'{listing}','photo','uploads','uploads/race/'||i||'.jpg',100,true,2,'image/jpeg' from generate_series(1,20)g(i);
insert into spatial_inputs(job_id,relative_path,ticket_id,storage_key,bytes,frame)
select j.id,'images/'||lpad(i::text,6,'0')||'.jpg',('a0409100-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'uploads/race/'||i||'.jpg',100,jsonb_build_object('timestamp',i,'raw_feature_points',jsonb_build_array(jsonb_build_object('id','1','position',jsonb_build_array(0,0,-1))))
from spatial_jobs j cross join generate_series(1,20)g(i) where j.listing_id='{listing}';
update spatial_runtime set enabled=true,daily_budget_cents=600,org_monthly_budget_cents=600;
"""
        run('race-setup',psql+['-qc',setup])
        def race(label,first_query,second_query,second_exit):
            first_sql=f"begin;set local application_name='spatial-first';set local role service_role;{first_query} select pg_sleep(2);commit;"
            second_sql=f"begin;set local application_name='spatial-second';set local role service_role;{second_query} commit;"
            first=subprocess.Popen(list(map(str,psql+['-Atqc',first_sql])),cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            second=None
            try:
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    state=subprocess.run(list(map(str,psql+['-Atqc',"select count(*) from pg_stat_activity where application_name='spatial-first' and wait_event='PgSleep';"])),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=5)
                    if state.returncode==0 and state.stdout.strip()=='1':break
                    time.sleep(.03)
                else:raise AssertionError('First transaction never reached held-lock sleep')
                second=subprocess.Popen(list(map(str,psql+['-Atqc',second_sql])),cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
                observed=False;deadline=time.monotonic()+1.5
                while time.monotonic()<deadline:
                    state=subprocess.run(list(map(str,psql+['-Atqc',"select count(*) from pg_stat_activity where application_name='spatial-second' and wait_event_type='Lock';"])),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=5)
                    if state.returncode==0 and state.stdout.strip()=='1':observed=True;break
                    time.sleep(.03)
                assert observed,'No real lock wait was observed'
                first_output=first.communicate(timeout=10)[0];second_output=second.communicate(timeout=10)[0]
                (out/f'{label}-first.log').write_text(first_output);(out/f'{label}-second.log').write_text(second_output)
                assert first.returncode==0 and second.returncode==second_exit
                receipt.setdefault('concurrentCases',[]).append({'name':label,'lockWaitObserved':True,'firstExit':first.returncode,'secondExit':second.returncode})
                return second_output
            finally:
                for process in (first,second):
                    if process and process.poll() is None:process.terminate();process.wait(timeout=10)
        rejected=race('budget',f"select spatial_start('{user}','{jobs[0]}');",f"select spatial_start('{user}','{jobs[1]}');",1)
        assert 'RP429: 3D generation capacity is reached' in rejected
        state=run('budget-race-state',psql+['-Atqc',"select count(*) filter(where status='queued'),count(*) filter(where status='uploading'),(select sum(committed_cents) from spatial_budget_windows) from spatial_jobs;"])
        assert state.strip()=='1|1|1200'
        race('claim',"select spatial_claim('a0409200-0000-4000-8000-000000000001');","select coalesce(spatial_claim('a0409200-0000-4000-8000-000000000002')::text,'NO_JOB');",0)
        assert 'NO_JOB' in (out/'claim-second.log').read_text()
        state=run('claim-race-state',psql+['-Atqc',"select count(*) filter(where status='processing'),count(distinct lease_token) from spatial_jobs;"])
        assert state.strip()=='1|1'
        # A retry is a distinct user action, while retrying that HTTP request
        # with its SAME key must not reserve a second paid GPU attempt.
        run('retry-race-setup',psql+['-qc',f"set role service_role; select spatial_worker_update(id,lease_token,'fail','{{\"failure_code\":\"fixture_failure\",\"cost_cents\":600,\"provider_stopped\":true}}') from spatial_jobs where status='processing'; update spatial_runtime set daily_budget_cents=1800,org_monthly_budget_cents=1800;"])
        operation='a0409300-0000-4000-8000-000000000001'
        retry=f"select spatial_recover('{user}','{jobs[0]}','retry','{operation}');"
        race('retry-idempotency',retry,retry,0)
        state=run('retry-race-state',psql+['-Atqc',f"select attempt_number,status,(select count(*) from spatial_attempt_history),(select sum(committed_cents) from spatial_budget_windows) from spatial_jobs where id='{jobs[0]}';"])
        assert state.strip()=='2|queued|1|2400'
        receipt['accepted']=True
    finally:
        if started:
            result=subprocess.run([str(bins/'pg_ctl'),'-D',str(cluster),'-m','fast','-w','-t','30','stop'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
            receipt['clusterStopped']=result.returncode==0
        receipt['sourceSha256']={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (target,test,Path(__file__))}
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    assert receipt['accepted'] and receipt['clusterStopped']


if __name__=='__main__':main()
