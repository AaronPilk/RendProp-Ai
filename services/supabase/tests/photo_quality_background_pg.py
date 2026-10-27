#!/usr/bin/env python3
"""Actual local SQL cron/client judge race; no hosted funds/providers or schema delta."""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
import argparse,datetime,hashlib,json,os,shutil,subprocess,tempfile,uuid
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args();OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-background-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='rendprop-photo-background-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='photo-bg-sock-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/photo_quality_evidence.sql',Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
r={'passed':False,'networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[]};started=False

def raw(name,cmd,body=None):
 result=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120);f=OUT/(name+'.log');f.write_text(result.stdout);f.chmod(0o600);r['commands'].append({'name':name,'exit':result.returncode,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()});return result

def run(name,cmd,body=None,refuses=None):
 result=raw(name,cmd,body);assert (result.returncode and refuses in result.stdout)if refuses else result.returncode==0,(name,result.stdout[-4000:]);return result.stdout

def first_json(text):return json.loads(next(line for line in text.splitlines()if line.startswith('{')))
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55557 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55557','-U','postgres'];run('createdb',[tool('createdb'),*conn,'photo_background']);PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','photo_background','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for migration in partition_fresh_migrations(sorted((SQL/'migrations').glob('*.sql')))[0]:run('apply-'+migration.stem,[*PSQL,'-q','-1','-f',migration])
 # Reuse canonical independent synthetic ownership/evidence/derivative helpers.
 # Keep every forward context/payment guard installed; do NOT replay old bases.
 fixture=(SQL/'tests/photo_quality_evidence.sql').read_text();anchor="select pg_temp.ok((select value->>'enabled'";assert fixture.count(anchor)==1
 prefix=fixture[:fixture.index(anchor)]
 setup=prefix+"""update app_config set value=jsonb_set(value,'{enabled}','true')where key='photo_quality';set local role service_role;
 create temporary table prepared_background as select pg_temp.prepared(pg_temp.candidate(pg_temp.seed('background-bind-race')))x;
 select photo_quality_set_context((x#>>'{evidence,actor_id}')::uuid,(x#>>'{evidence,id}')::uuid,x#>>'{evidence,request_sha256}',jsonb_build_object('edit','declutter','style',null,'instruction',''))from prepared_background;
 select jsonb_build_object('actor_id',x#>>'{evidence,actor_id}','org_id',x#>>'{evidence,org_id}','listing_id',x#>>'{evidence,listing_id}','evidence_id',x#>>'{evidence,id}','check_id',x#>>'{check,id}','lease_token',x#>>'{check,lease_token}')from prepared_background;commit;
 """
 (OUT/'exact-local-fixture.sql').write_text(setup);reply=run('retained-prepared-fixture',[*PSQL,'-Atq'],setup);facts=json.loads(next(line for line in reversed(reply.splitlines())if line.startswith('{')));r['fixture']=facts
 actor,org,listing,evidence,check,lease=[facts[k]for k in ['actor_id','org_id','listing_id','evidence_id','check_id','lease_token']]
 def race(name,body):
  gate=Barrier(2)
  def call(index):gate.wait(timeout=10);return raw(name+'-'+str(index),[*PSQL,'-Atq'],'set role service_role;'+body)
  with ThreadPoolExecutor(max_workers=2)as pool:return list(pool.map(call,range(2)))
 claims=race('client-cron-ready-claim',f"select photo_quality_claim('{check}');")
 assert all(x.returncode==0 for x in claims);claimrows=[first_json(x.stdout)for x in claims];assert all(x['action']=='judge'and x['check']['lease_token']==lease for x in claimrows)
 reservation=str(uuid.uuid4());key='photo-quality:background-bind-race'
 # Closed local receipt fixture, identical to canonical pg_temp.bind. This is
 # not a hosted grant or a production capacity/usage acceptance claim.
 run('matching-paid-fixture',[*PSQL,'-Atq'],f"""insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited,state)values('{org}','{actor}','{key}','photo.declutter:0','gemini','gemini-3.1-flash-image',repeat('a',64),'closed-fixture',.0001,true,'succeeded');
 insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values('{org}','photo_edit','gemini','gemini-3.1-flash-image',.0001,jsonb_build_object('request_key','{key}','stage','photo.declutter:0'));
 insert into serving_cost_reservations(id,org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited)values('{reservation}','{org}','{actor}','photo-qc:{check}','photo.qc:0','anthropic','claude-sonnet-5',repeat('e',64),'closed-fixture',.0001,true);""")
 binding=f"select photo_quality_check_bind('{actor}','{check}','{lease}','{reservation}');"
 outcomes=race('client-cron-paid-bind',binding);assert sorted(x.returncode==0 for x in outcomes)==[False,True];assert 'already started' in next(x.stdout for x in outcomes if x.returncode)
 counts_sql=f"select jsonb_build_object('qc_reservations',(select count(*)from serving_cost_reservations where request_key='photo-qc:{check}'),'bound_checks',(select count(*)from photo_quality_checks where id='{check}'and state='checking'and judge_started_at is not null and reservation_id='{reservation}'));"
 counts=first_json(run('one-paid-bind-counts',[*PSQL,'-Atq','-c',counts_sql]));assert counts=={'qc_reservations':1,'bound_checks':1};r['controls'].append({'name':'actual-client-cron-paid-bind-race','sessions':2,'oneSuccessfulBind':True,'oneRefusedBind':True,**counts,'realProviderCalls':0})
 run('checking-cannot-bind-again',[*PSQL,'-Atq'],'set role service_role;'+binding,refuses='already started')
 wait=first_json(run('checking-claim-no-repeat',[*PSQL,'-Atq'],'set role service_role;'+f"select photo_quality_claim('{check}');"));assert wait['action']=='wait';r['controls'].append({'name':'inflight-checking-no-repeat','action':'wait'})
 # Remove the actual guarded transition only in this disposable database. The
 # exact second-bind refusal oracle must now fail rather than pass silently.
 original=run('read-bind-guard',[*PSQL,'-Atq','-c',"select pg_get_functiondef('public.photo_quality_bind_before_context(uuid,uuid,uuid,uuid)'::regprocedure)"])
 start="if q.state<>'derivative_ready'or q.lease_token is distinct from p_lease or q.lease_until<=now()or q.judge_started_at is not null then";assert original.count(start)==1
 run('compile-removed-dispatch-guard',[*PSQL,'-Atq'],original.replace(start,'if false then',1))
 oracle=f"""set role service_role;do $$begin begin perform photo_quality_check_bind('{actor}','{check}','{lease}','{reservation}');exception when others then if position('already started'in sqlerrm)>0 then return;end if;raise;end;raise exception'BACKGROUND FAIL: second paid judge bind was allowed';end$$;"""
 run('compiled-control-must-refuse',[*PSQL,'-Atq'],oracle,refuses='BACKGROUND FAIL: second paid judge bind was allowed');run('restore-dispatch-guard',[*PSQL,'-Atq'],original);r['controls'].append({'name':'compiled-second-dispatch-guard-removal','actualSQLCompiled':True,'independentOracleRefused':True})
 run('hold-stops-background',[*PSQL,'-Atq'],f"set role service_role;select photo_quality_failure('{actor}','{evidence}','closed_background_stop','{{\"no_provider_dispatch\":true}}');")
 held=first_json(run('held-claim-no-repeat',[*PSQL,'-Atq'],f"set role service_role;select photo_quality_claim('{check}');"));assert held['action']=='wait'and held['check']['state']=='hold';run('held-bind-no-repeat',[*PSQL,'-Atq'],'set role service_role;'+binding,refuses='already started');r['controls'].append({'name':'terminal-hold-stops-background','action':'wait'})
 run('gone-identified-actor',[*PSQL,'-Atq'],f"update auth.users set is_anonymous=true where id='{actor}';")
 run('gone-actor-no-claim',[*PSQL,'-Atq'],f"set role service_role;select photo_quality_claim('{check}');",refuses='unavailable')
 run('restore-actor-withdraw-property',[*PSQL,'-Atq'],f"update auth.users set is_anonymous=false where id='{actor}';update listings set deleted_at=now()where id='{listing}';")
 run('withdrawn-property-no-claim',[*PSQL,'-Atq'],f"set role service_role;select photo_quality_claim('{check}');",refuses='RP404: Listing not found');r['controls'].append({'name':'gone-actor-and-withdrawn-property','refusedBeforeDispatch':True})
 r['passed']=True
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 r['sourceUnchanged']=r['sourceHashes']==hashes();r['passed']=r['passed']and r['sourceUnchanged'];r['finishedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();r['clusterStopped']=started
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True);print(OUT/'receipt.json',flush=True)
