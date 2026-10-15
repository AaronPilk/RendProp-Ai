#!/usr/bin/env python3
"""Actual socket-only PG point authority; external DATA supported, no hosted calls."""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, tempfile, time

ROOT=Path(__file__).resolve().parents[3]; SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);p.add_argument('--data-root',type=Path);a=p.parse_args()
OUT=a.evidence_dir or Path(tempfile.mkdtemp(prefix='photo-delivery-evidence-'))
if OUT.exists():assert not any(OUT.iterdir()),'Use a fresh evidence directory; preserve prior attempts'
OUT.mkdir(parents=True,exist_ok=True)
if os.uname().sysname=='Darwin':
    assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve 3GiB internal reserve'
    assert a.data_root or os.environ.get('RENDPROP_PG_DATA_ROOT'),'Use external PG DATA on this Mac'
DATA=Path(tempfile.mkdtemp(prefix='photo-delivery-pg-',dir=a.data_root or os.environ.get('RENDPROP_PG_DATA_ROOT')))
SOCK=Path(tempfile.mkdtemp(prefix='pds-',dir='/tmp'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
MIG=SQL/'migrations/20261015181343_published_photo_delivery.sql';TEST=SQL/'tests/published_photo_delivery.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
FILES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',TEST,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in FILES}
r={'passed':False,'scope':'Actual isolated socket-only PostgreSQL, synthetic published property; no hosted/provider/media requests',
   'sourceHashes':hashes(),'commands':[],'controls':[],'races':[],'dataExternal':DATA.stat().st_dev!=ROOT.stat().st_dev,'networkCalls':0};started=False
fixture=TEST.read_text();anchor="select pg_temp.ok(not has_function_privilege";assert fixture.count(anchor)==1
setup=fixture[:fixture.index(anchor)]
def run(name,args,stdin=None,okay=True):
    x=subprocess.run([str(v)for v in args],input=stdin,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    (OUT/(name+'.log')).write_text(x.stdout)
    r['commands'].append({'name':name,'exit':x.returncode,'sha256':hashlib.sha256(x.stdout.encode()).hexdigest()})
    assert not okay or x.returncode==0,(name,x.stdout[-4000:]);return x

def malformed(name,sql,needle):
    tail=f"""set local role service_role;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,123)','photo-authority',prefix||'gallery-stage-complete-v1.jpg'),'{needle}','{name}')from f;
reset role;
select pg_temp.ok(not exists(select 1 from media_serving_usage where org_id=(select org from f)),'refusal rolls back all metering');
select jsonb_build_object('passed',true,'assertions',(select n from checks));rollback;"""
    run(name,[*P,'-Atq'],setup+sql+';\n'+tail)
    r['controls'].append({'name':name,'actualSQL':True,'refusal':needle,'meterRollback':True})

def race(name,change,expected_refusal=True):
    # The actual admission UPSERT is the synchronization barrier. No production
    # function is instrumented and no permission result is cached in this test.
    run(name+'-reset',P+['-Atq'],f"""update listings set gallery_asset_ids=array['d1800000-0000-4000-8000-000000000010'::uuid,'d1800000-0000-4000-8000-000000000011'::uuid,'d1800000-0000-4000-8000-000000000012'::uuid]where id='{LISTING}';
update renders set published_at=now()where slug='photo-authority';
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes,sha256,content_type)values('d1800000-0000-4000-8000-000000000020','{LISTING}','photo','renders','{PREFIX}original-master.jpg',true,1000,repeat('a',64),'image/jpeg')on conflict(id)do nothing;
update media_provenance set original_key='{PREFIX}original-master.jpg'where id='d1800000-0000-4000-8000-000000000041';
update studio_presenter_jobs set import_storage_key=null where id='d1800000-0000-4000-8000-000000000050';
insert into media_serving_usage(org_id,usage_day,used_requests,used_bytes)values('{ORG}',(now()at time zone'UTC')::date,0,0)on conflict(org_id,usage_day)do update set used_requests=0,used_bytes=0;""")
    blocker=subprocess.Popen([str(v)for v in P+['-Atq']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV)
    worker=None
    try:
        blocker.stdin.write(f"begin;select 1 from media_serving_usage where org_id='{ORG}'for update;\n\\echo BARRIER_LOCKED\n");blocker.stdin.flush()
        while True:
            line=blocker.stdout.readline()
            assert line,(name,'barrier process exited')
            if 'BARRIER_LOCKED'in line:break
        env={**ENV,'PGAPPNAME':name}
        worker=subprocess.Popen([str(v)for v in P+['-Atq']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env)
        worker.stdin.write(f"set role service_role;select published_photo_delivery('photo-authority','{PREFIX}gallery-stage-complete-v1.jpg',123);");worker.stdin.close()
        deadline=time.monotonic()+10;poll=0
        while True:
            x=run(name+'-wait-'+str(poll),P+['-Atq','-c',f"select count(*)from pg_stat_activity where application_name='{name}'and wait_event_type='Lock'"])
            if x.stdout.strip()=='1':break
            assert time.monotonic()<deadline,(name,'RPC did not reach real admission barrier');poll+=1;time.sleep(.05)
        run(name+'-withdraw',P+['-Atq'],change)
        blocker.stdin.write('commit;\n\\q\n');blocker.stdin.close();blocker.wait(timeout=10)
        worker.wait(timeout=30);out=worker.stdout.read();(OUT/(name+'-rpc.log')).write_text(out)
        denied=worker.returncode!=0 and 'RP404:'in out
        assert denied==expected_refusal,(name,worker.returncode,out)
        counts=run(name+'-meter',P+['-Atq','-c',f"select used_requests||':'||used_bytes from media_serving_usage where org_id='{ORG}'"]).stdout.strip()
        assert counts==('0:0'if expected_refusal else'1:123'),(name,counts)
        r['races'].append({'name':name,'realAdmissionRowLock':True,'withdrawalCommittedBeforeReturn':True,'refused':denied,'meter':counts})
    finally:
        for child in [worker,blocker]:
            if child and child.poll()is None:child.kill();child.wait(timeout=10)
try:
    run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
    run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55568 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
    conn=['-h',SOCK,'-p','55568','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'photo_delivery'])
    P=[TOOLS['psql'],'-X','--no-password',*conn,'-d','photo_delivery','-v','ON_ERROR_STOP=1']
    run('bootstrap',P+['-q','-f',SQL/'tests/ci-bootstrap.sql'])
    for m in MIGRATIONS:run('apply-'+m.stem,P+['-q','-1','-f',m])
    for name in ['fresh','replay']:
        if name=='replay':run('replay-migration',P+['-q','-1','-f',MIG])
        x=run(name,P+['-Atq'],fixture);proof=[json.loads(l)for l in x.stdout.splitlines()if l.startswith('{')and'assertions'in l]
        assert len(proof)==1 and proof[0]['passed'];r[name]=proof[0]
    sig='public.published_photo_delivery(text,text,bigint)'
    definition=run('definition',P+['-Atq','-c',f"select pg_get_functiondef('{sig}'::regprocedure)"]).stdout
    # Compiled faults must be rejected by the actual current fixture oracle.
    mutants=[('preview-bound', [('p_bytes not between 0 and 2097152','p_bytes not between 0 and 4194304')],'preview upper bound'),
        ('invented-kind-policy',[("if p.original_key is null then return null;end if;","if p.kind='other' then return null;end if;\n    if p.original_key is null then return null;end if;")],'uploads original and existing non-whitelisted kind supported'),
        ('legacy-missing-source-policy',[("      -- The generic authority permits", "      raise exception 'RP404: invented missing source policy';\n      -- The generic authority permits")],'invented missing source policy'),
        ('meter-omission',[("admission:=public.media_delivery_admit(l.org_id,p_bytes,true);","admission:=jsonb_build_object('admitted',true,'legacy_unbudgeted',false);")],'required exact request/byte meter')]
    for name,edits,needle in mutants:
        changed=definition
        for before,after in edits:assert changed.count(before)==1,(name,before);changed=changed.replace(before,after)
        run('install-'+name,P+['-Atq'],changed);x=run('fault-'+name,P+['-Atq'],fixture,False)
        assert x.returncode!=0 and needle in x.stdout,(name,x.stdout[-2000:]);r['controls'].append({'name':name,'compiledActualRPC':True,'oracleRejected':needle})
        run('restore-'+name,P+['-Atq'],definition)
    visibility=run('visibility-definition',P+['-Atq','-c',"select pg_get_functiondef('public.studio_presenter_media_visibility(uuid,uuid[],uuid[],text[])'::regprocedure)"]).stdout
    for name,old,new in [('visibility-missing','return jsonb_build_object(\'assets\',assets,\'renders\',renders,\'keys\',keys);',"return '{}'::jsonb;"),
                         ('visibility-string-boolean',"jsonb_build_object('assets',assets,'renders',renders,'keys',keys)","replace(jsonb_build_object('assets',assets,'renders',renders,'keys',keys)::text,': true',': \"true\"')::jsonb")]:
        assert visibility.count(old)==1,(name,old)
        changed=visibility.replace(old,new)
        malformed(name,changed,'RP404:');run('restore-'+name,P+['-Atq'],visibility)
    admit=run('admission-definition',P+['-Atq','-c',"select pg_get_functiondef('public.media_delivery_admit(uuid,bigint,boolean)'::regprocedure)"]).stdout
    for name,old,new in [('admission-string-boolean',"'admitted',true","'admitted','true'::text"),('admission-string-bytes',"'bytes_counted',p_bytes","'bytes_counted',p_bytes::text")]:
        assert admit.count(old)==1
        malformed(name,admit.replace(old,new),'RP503:');run('restore-'+name,P+['-Atq'],admit)
    hosting=run('hosting-definition',P+['-Atq','-c',"select pg_get_functiondef('public.hosting_retention_state(uuid)'::regprocedure)"]).stdout
    # Keep the same signature/ACL but exercise malformed receipt and wall-clock
    # expiry independently of the existing subscription business logic.
    for name,ends,expected in [('hosting-infinite','infinity','RP503:'),('hosting-expired','2000-01-01T00:00:00Z','RP404:'),('hosting-missing-field',None,'RP503:')]:
        body="select jsonb_build_object('org_id',p_org,'hosting_available',true,'protected',false,'policy','prospective_90_day_grace','retention_ends_at','"+str(ends)+"');"
        if ends is None:body="select jsonb_build_object('org_id',p_org,'hosting_available',true,'protected',false,'policy','preserved');"
        start=hosting.index('AS $function$');stop=hosting.index('$function$',start+14)
        changed=hosting[:start]+ 'AS $function$\n'+body+'\n'+hosting[stop:]
        malformed(name,changed,expected);run('restore-'+name,P+['-Atq'],hosting)
    run('install-unknown-body',P+['-Atq'],definition.replace('declare\n','declare\n-- future unknown runtime\n',1))
    x=run('unknown-body-replay',P+['-q','-1','-f',MIG],okay=False)
    assert x.returncode!=0 and 'Review changed published photo authority'in x.stdout
    r['controls'].append({'name':'unknown-body-replay','compiledActualRPC':True,'oracleRejected':True});run('restore-unknown',P+['-Atq'],definition)
    run('race-setup',P+['-Atq'],setup+"commit;")
    ORG=run('race-org',P+['-Atq','-c',"select org_id from memberships where user_id='d1800000-0000-4000-8000-000000000001'limit 1"]).stdout.strip()
    LISTING='d1800000-0000-4000-8000-000000000002';PREFIX=f'renders/{ORG}/{LISTING}/'
    run('race-revocation-source',P+['-Atq'],f"""insert into studio_presenter_jobs(id,org_id,listing_id,actor_id,subject_user_id,author_user_id,draft_id,profile_id,draft_revision,profile_revision,quote_id,idempotency_key,runtime_revision,price_version,quote_cents,hold_cents,held_cents,state,output_key)
values('d1800000-0000-4000-8000-000000000050','{ORG}','{LISTING}','d1800000-0000-4000-8000-000000000001','d1800000-0000-4000-8000-000000000001','d1800000-0000-4000-8000-000000000001',gen_random_uuid(),gen_random_uuid(),1,1,gen_random_uuid(),gen_random_uuid(),1,'synthetic',1,1,0,'invalidated','presenter-private/{ORG}/d1800000-0000-4000-8000-000000000050/output.mp4');""")
    race('source-withdrawal',"delete from capture_assets where id='d1800000-0000-4000-8000-000000000020';")
    race('selection-withdrawal',f"update listings set gallery_asset_ids='{{}}'where id='{LISTING}';")
    race('publication-withdrawal',"update renders set published_at=null where slug='photo-authority';")
    race('provenance-withdrawal',"update media_provenance set original_key=null where id='d1800000-0000-4000-8000-000000000041';")
    revoke=f"update studio_presenter_jobs set import_storage_key='{PREFIX}original-master.jpg'where id='d1800000-0000-4000-8000-000000000050';"
    race('canonical-revocation',revoke)
    needle='visible:=public.studio_presenter_media_visibility(l.id,asset_refs,array[r.id],key_refs);'
    i=definition.rfind(needle);assert i>=0
    run('install-final-visibility-omission',P+['-Atq'],definition[:i]+'null; -- omitted final canonical refresh'+definition[i+len(needle):])
    race('fault-final-canonical-revocation',revoke,False)
    r['controls'].append({'name':'final-visibility-omission','compiledActualRPC':True,'realConcurrentRevocationWouldLeak':True})
    run('restore-final-visibility',P+['-Atq'],definition)
    assert hashes()==r['sourceHashes'],'Bound source changed during proof'
    assert sorted((SQL/'migrations').glob('*.sql'))==MIGRATIONS,'Migration set changed during proof'
    r['passed']=True
finally:
    if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
    r['clusterStopped']=not(DATA/'postmaster.pid').exists();shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True)
    r['dataRemoved']=not DATA.exists();r['socketRemoved']=not SOCK.exists()
    (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({'passed':r['passed'],'receipt':str(OUT/'receipt.json')}))
