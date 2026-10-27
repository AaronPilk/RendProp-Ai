#!/usr/bin/env python3
"""Closed owned-PG authority gate; no provider/live connection or production edits.
All root migrations plus both frozen Kie migrations run unchanged. This gate is
independent of operator activation scripts, which require a later scoped review.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,time,sys,signal
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path,required=True);a=p.parse_args();OUT=a.evidence_dir.resolve();OUT.mkdir(exist_ok=False,parents=True);OUT.chmod(0o700)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
WHOLE_SECONDS=450;DATA_PREFIX='kie-scope-owned-pg-';SOCK_PREFIX='kie-scope-sock-'

os.umask(0o077)
EXTERNAL=Path('/Volumes/Rendprop Files')
PROOF_DEADLINE=time.monotonic()+WHOLE_SECONDS

def guard():
 assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve source3GiB reserve'
 assert shutil.disk_usage(OUT).free>=1024**3,'Preserve isolated evidence1GiB reserve'
 if sys.platform=='darwin':
  assert EXTERNAL.is_mount() and OUT.is_relative_to(EXTERNAL),'Keep local PG evidence on the mounted external volume'
 if EXTERNAL.is_mount() and OUT.is_relative_to(EXTERNAL):
  assert shutil.disk_usage(EXTERNAL).free>=8*1024**3,'Preserve external8GiB reserve'
 assert time.monotonic()<PROOF_DEADLINE,'Whole proof deadline'

guard()
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
pg_config=shutil.which('pg_config',path=ENV['PATH'])
if pg_config:
 bindir=subprocess.check_output([pg_config,'--bindir'],text=True,env=ENV,timeout=10).strip()
 assert Path(bindir).is_absolute() and Path(bindir).is_dir(),'PostgreSQL tool directory required'
 ENV['PATH']=bindir+os.pathsep+ENV['PATH']
tool=lambda name:shutil.which(name,path=ENV['PATH'])
assert all(tool(n)for n in ['initdb','pg_ctl','createdb','psql']),'Already-installed PostgreSQL tools required'
DATA=Path(tempfile.mkdtemp(prefix=DATA_PREFIX,dir=OUT));SOCK=Path(tempfile.mkdtemp(prefix=SOCK_PREFIX,dir='/tmp'));started=False

def terminate(_signal,_frame):raise SystemExit('Stopped by outer resource/wall guard')
signal.signal(signal.SIGTERM,terminate)

def execute(cmd,body=None,env=None,timeout=120,guarded=True):
 # Own a new child process group and bound both command and exceptional drain.
 if guarded:guard()
 child=subprocess.Popen([str(x)for x in cmd],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env or ENV,cwd=ROOT,start_new_session=True)
 end=time.monotonic()+timeout
 try:
  while True:
   try:
    output,_=child.communicate(input=body,timeout=.5)
    return subprocess.CompletedProcess(cmd,child.returncode,output)
   except subprocess.TimeoutExpired:
    body=None
    if guarded:guard()
    assert time.monotonic()<end,'Command deadline'
 except BaseException as error:
  try:os.killpg(child.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  try:output,_=child.communicate(timeout=5)
  except subprocess.TimeoutExpired as drain:
   output=drain.output or ''
   if isinstance(output,bytes):output=output.decode('utf-8','replace')
   for pipe in [child.stdin,child.stdout,child.stderr]:
    if pipe is not None:pipe.close()
   child.wait(timeout=5)
  error.proof_output=output;error.proof_returncode=child.returncode
  raise

def log_command(name,c,error=None):
 f=OUT/(name+'.log');f.write_text(c.stdout);f.chmod(0o600)
 entry={'name':name,'exit':c.returncode,'logSHA256':hashlib.sha256(f.read_bytes()).hexdigest()}
 if error is not None:entry['failure']=type(error).__name__
 r['commands'].append(entry)

def cleanup_owned():
 # A failed start reply may still leave this exact postmaster running.
 pidfile=DATA/'postmaster.pid'
 if started or pidfile.exists():
  assert DATA.is_dir() and not DATA.is_symlink() and DATA.stat().st_uid==os.getuid(),'Owned data directory identity'
  assert pidfile.is_file() and not pidfile.is_symlink(),'Owned postmaster identity required'
  lines=pidfile.read_text().splitlines();assert len(lines)>1 and int(lines[0])>1 and Path(lines[1]).resolve()==DATA.resolve(),'Owned postmaster data identity'
  state=subprocess.run(['ps','-p',lines[0],'-o','command='],capture_output=True,text=True,timeout=5)
  assert state.returncode==0 and str(DATA)in state.stdout and 'postgres'in state.stdout,'Owned postmaster process identity'
  stopped=execute([tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'],timeout=30,guarded=False);log_command('stop',stopped)
  assert stopped.returncode==0,'Owned cluster cleanup failed'
 assert not pidfile.exists(),'Owned postmaster remains'
 shutil.rmtree(DATA);shutil.rmtree(SOCK)
 r['ownedClusterRemoved']=not DATA.exists() and not SOCK.exists()

# The whole current catalog is applied; the floor refuses a branch that lost
# migrations, while later migrations (added after this harness) still apply.
MIGS=sorted((SQL/'migrations').glob('*.sql'));assert len(MIGS)>=181,len(MIGS)
OWN=SQL/'migrations/20261016110000_property_video_kie_scope_consent_drain.sql';assert OWN in MIGS
BASE=SQL/'tests/property_video_jobs.sql';KIE=SQL/'tests/property_video_kie_profile.sql';FIX=SQL/'tests/property_video_kie_scope_consent.sql';IDENT=SQL/'functions/_shared/property-video-kie-identity.json'
SOURCES=[*MIGS,SQL/'tests/ci-bootstrap.sql',BASE,KIE,FIX,IDENT,SQL/'tests/property_video_quality_profile.sql',SQL/'tests/property_video_steady_v2.sql',Path(__file__).resolve(),SQL/'functions/ai-video/index.ts',SQL/'functions/property-video-worker/engine.ts']
CLOSED_TESTS=[SQL/'functions/ai-video/property-video-kie-dispatch.test.ts',SQL/'functions/property-video-worker/kie-dispatch-authority.test.ts']
SOURCES.extend(sorted(f for f in(SQL/'functions').rglob('*')if f.is_file()and f.suffix in['.ts','.json']and'node_modules'not in f.parts))
hashes=lambda:{str(f.relative_to(ROOT)):sha(f)for f in SOURCES}
PORT='55783';PSQL=[];t0=time.monotonic()
r={'passed':False,'scope':'owned local PG consent/grant/dispatch authority; closed actual handler tests, no provider or owner approval','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'regressions':{},'races':[],'productFindings':[],'checks':[]}
def run(name,cmd,body=None,expect=None,require=True):
 try:c=execute(cmd,body,timeout=60)
 except BaseException as error:
  c=subprocess.CompletedProcess(cmd,getattr(error,'proof_returncode',None),getattr(error,'proof_output',''));log_command(name,c,error);raise
 log_command(name,c)
 if require:assert (c.returncode!=0 and expect in c.stdout)if expect else c.returncode==0,(name,c.stdout[-5000:])
 return c
def sql(name,body,expect=None,require=True):return run(name,[*PSQL,'-Atq'],body,expect,require)
def one(name,body):
 c=sql(name,body);lines=[json.loads(l)for l in c.stdout.splitlines()if l.startswith('{')];assert len(lines)==1,(name,c.stdout[-4000:]);return lines[0]
def check(label,passed,detail=None):
 r['checks'].append({'name':label,'passed':passed,'detail':detail});assert passed,(label,detail)
def race(name,bodies):
 barrier=Barrier(len(bodies))
 def call(pair):
  i,b=pair;barrier.wait(timeout=10);start=time.monotonic();c=sql(name+'-'+str(i),b,require=False);return{'exit':c.returncode,'output':c.stdout,'seconds':time.monotonic()-start}
 with ThreadPoolExecutor(max_workers=len(bodies))as pool:return list(pool.map(call,enumerate(bodies)))
CAT="""select jsonb_build_object('functions',(select md5(string_agg((jsonb_build_object('sig',p.oid::regprocedure::text,'body',p.prosrc,'owner',pg_get_userbyid(p.proowner),'def',p.prosecdef,'vol',p.provolatile,'cfg',p.proconfig,'acl',p.proacl::text,'result',pg_get_function_result(p.oid)))::text,E'\\n'order by p.oid::regprocedure::text))from pg_proc p where p.pronamespace='public'::regnamespace),'relations',(select md5(string_agg(jsonb_build_object('name',relname,'kind',relkind,'acl',relacl::text,'rls',relrowsecurity,'force',relforcerowsecurity)::text,E'\\n'order by relname))from pg_class where relnamespace='public'::regnamespace),'constraints',(select md5(string_agg(conrelid::regclass||':'||conname||':'||pg_get_constraintdef(oid),E'\\n'order by conrelid::regclass::text,conname))from pg_constraint where connamespace='public'::regnamespace),'indexes',(select md5(string_agg(indexrelid::regclass||':'||pg_get_indexdef(indexrelid),E'\\n'order by indexrelid::regclass::text))from pg_index where indrelid in(select oid from pg_class where relnamespace='public'::regnamespace)),'triggers',(select md5(string_agg(tgrelid::regclass||':'||tgname||':'||pg_get_triggerdef(oid)||':'||tgenabled::text,E'\\n'order by tgrelid::regclass::text,tgname))from pg_trigger where not tgisinternal and tgrelid in(select oid from pg_class where relnamespace='public'::regnamespace)),'policies',(select md5(string_agg(to_jsonb(p)::text,E'\\n'order by tablename,policyname))from pg_policies p where schemaname='public'),'config',(select md5(string_agg(to_jsonb(c)::text,E'\\n'order by key))from app_config c),'routes',(select md5(string_agg(to_jsonb(a)::text,E'\\n'order by id))from ai_routes a));"""
catalog=lambda n:one(n,CAT)
base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')];basehelpers=base[base.index('create function pg_temp.paid_clip'):base.index('insert into auth.users')]
ktext=KIE.read_text();money=ktext[ktext.index('create function pg_temp.kie_hold'):ktext.index('-- Explicit publication surfaces')]
ftext=FIX.read_text();helpers=ftext[:ftext.index('-- Migration defaults')]
identity='create temporary table kie_identity_file as select $ki$'+IDENT.read_text()+'$ki$::jsonb j;grant select on kie_identity_file to service_role;'
paid="update app_config set value='{\"mode\":\"ceiling\",\"free_published_listings\":1}'where key='serving_mode';update app_config set value=jsonb_set(value,'{enabled}','true')where key='paid_quality_processing';update app_config set value='{\"enabled\":false}'where key='photo_preservation_quality';set local role service_role;select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'owned-scope-fixture-original','owned-scope-fixture-transaction','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');reset role;"
# The shared seed's manual Starter plan only admits its synthetic listing;
# release it before the verified Apple receipt supplies this fixture's authority.
release_seed_grant="update public.orgs set plan='free',plan_source=null,plan_expires_at=null where id=(select org from bf);"
prefix='begin;'+seed+release_seed_grant+paid+identity+money
published="update ai_routes set enabled=true where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';insert into app_config(key,value)values('property_video_processor_consent','{\"token\":\"property-video-jobs-v2\",\"disclosure_revision\":\"owned-db-fixture-r1\",\"processors\":[\"fal\",\"kie\"],\"profiles\":[\"kie-kling3-4k-steady-v1\"]}');"
reuse="begin;create temporary table bf as select actor,other,org,other_org,listing from public.kg_seed;grant select on bf to service_role,authenticated;create temporary table bm as select m from public.kg_seed;grant select on bm to service_role,authenticated;"+identity+helpers
ROLE='set role service_role;'
state=lambda gid:f"select jsonb_build_object('creates',(select creates_used from property_video_kie_test_grants where id='{gid}'),'cents',(select cents_used from property_video_kie_test_grants where id='{gid}'),'uses',(select count(*)from property_video_kie_test_grant_uses where grant_id='{gid}'),'holds',(select count(*)from app_video_cost_reservations),'ledger',(select count(*)from cost_ledger));"
gid=lambda i:'f8b00000-0000-4000-8000-%012d'%i
claimargs=lambda c:"'%s'::uuid,'%s'::uuid,'%s'::uuid"%(c['job']['id'],c['source']['lease_token'],c['source']['attempt_id'])
try:
 deno=shutil.which('deno',path=ENV['PATH']);assert deno,'Already-installed Deno required for closed handler/worker proof'
 deno_env={**ENV,'DENO_NO_UPDATE_CHECK':'1','DENO_NO_PACKAGE_JSON':'1','DENO_NO_PROMPT':'1','NO_COLOR':'1'}
 if os.environ.get('DENO_DIR'):deno_env['DENO_DIR']=os.environ['DENO_DIR']
 version=execute([deno,'--version'],env=deno_env,timeout=10);assert version.returncode==0
 closed=execute([deno,'test','--no-config','--no-lock','--node-modules-dir=none','--cached-only','--deny-net','--deny-run','--deny-write','--allow-env','--allow-read='+str(SQL/'functions'),*CLOSED_TESTS],env=deno_env,timeout=120)
 log_command('actual-closed-handler-worker',closed)
 assert closed.returncode==0,'Closed handler/worker authority proof failed: '+closed.stdout[-4000:]
 import re
 summaries=re.findall(r'^ok \| (\d+) passed \| 0 failed',closed.stdout,re.M);assert len(summaries)==1 and int(summaries[0])>0,'Closed Deno test summary missing'
 r['dispatchBoundaryClosedHTTPProof']={'executed':True,'testCount':int(summaries[0]),'logSHA256':sha(OUT/'actual-closed-handler-worker.log'),'runtimeVersion':version.stdout,'runtimeSHA256':sha(Path(deno).resolve()),'testSourceHashes':{str(f.relative_to(ROOT)):sha(f)for f in CLOSED_TESTS},'scope':'Actual handler/worker closed transports; deny-net/deny-run/deny-write and no supplier credentials; separately bound actual owned SQL, not combined live provider proof'}
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p',PORT,'-U','postgres'];run('createdb',[tool('createdb'),*conn,'kie_scope']);PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','kie_scope','-v','ON_ERROR_STOP=1']
 assert sql('owned-cluster-identity',"select current_setting('data_directory'),current_setting('listen_addresses')").stdout.strip()==str(DATA)+'|'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGS)[0]:
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==OWN:
   run('copy-scope-migration-boundary',[tool('createdb'),*conn,'-T','kie_scope','kie_scope_boundary'])
 r['migrationCount']=len(partition_fresh_migrations(MIGS)[0]);baseline=catalog('all-final-catalog')
 one('review-helper-metadata',"select jsonb_build_object('helpers',(select jsonb_agg(jsonb_build_object('sig',p.oid::regprocedure::text,'body_md5',md5(p.prosrc),'owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,'volatility',p.provolatile,'config',p.proconfig,'acl',p.proacl::text,'result',pg_get_function_result(p.oid),'arguments',p.proargnames,'strict',p.proisstrict,'parallel',p.proparallel))from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in('property_video_kie_test_grant_guard','property_video_kie_test_grant_use_guard','property_video_processor_consent_current','property_video_processor_consent_record','property_video_kie_test_grant_scope','property_video_quality_profile_for','property_video_job_admit_v2','property_video_kie_dispatch_authority')));")
 functional_output=sql('actual-scope-consent-fixture',prefix+ftext).stdout;functional_rows=[json.loads(l)for l in functional_output.splitlines()if l.startswith('{')and'assertions'in l];assert len(functional_rows)==1;functional=functional_rows[0];check('actual consent scope authority fixture',functional['passed'],functional);r['functional']=functional
 check('functional rollback preserves all finalcatalog',catalog('after-functional-catalog')==baseline)
 # Historical FAL requests retain their original v1 API and saved identity.
 for label,file,prep in [('v1',SQL/'tests/property_video_quality_profile.sql','begin;'+seed),('steady',SQL/'tests/property_video_steady_v2.sql','begin;'+seed+basehelpers),('jobs',BASE,'')]:
  out=sql('final-schema-regression-'+label,prep+file.read_text()).stdout;lines=[json.loads(l)for l in out.splitlines()if l.startswith('{')and'assertions'in l];assert len(lines)==1 and lines[0]['passed'];r['regressions'][label]=lines[0]
 check('regression rollbacks preserve finalcatalog',catalog('after-regressions-catalog')==baseline)
 # A later prompt migration deliberately replaced the guarded dispatch helper.
 # Replaying this historical migration against the final schema must refuse
 # without touching anything; its idempotent replay belongs at its own boundary.
 run('replay-final-scope-refuses',[*PSQL,'-q','-1','-f',OWN],expect='Review changed Kie scope helper: public.property_video_kie_dispatch_authority(uuid,uuid,uuid)')
 check('final-schema scope replay refused without mutation',catalog('after-final-replay-refusal')==baseline)
 final_psql=PSQL;final_baseline=baseline
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','kie_scope_boundary','-v','ON_ERROR_STOP=1']
 baseline=catalog('scope-boundary-catalog')
 run('replay-known-scope-boundary',[*PSQL,'-q','-1','-f',OWN]);check('known replay preserves historical boundary catalog',catalog('after-known-boundary-replay')==baseline)
 # Replay security controls record defects at that exact migration boundary;
 # a final-schema replay refusal must not mask their independent oracles.
 sig='public.property_video_processor_consent_current()';definition=sql('read-replay-control-function',"select pg_get_functiondef('%s'::regprocedure);"%sig).stdout.strip();assert definition.count('declare c jsonb;begin')==1
 sql('compile-unknown-body-control',definition.replace('declare c jsonb;begin','declare c jsonb;begin /* OWNED UNKNOWN-BODY CONTROL */',1));changed=catalog('unknown-body-before-replay')
 c=run('replay-unknown-body-control',[*PSQL,'-q','-1','-f',OWN],require=False);after=catalog('unknown-body-after-replay');safe=c.returncode!=0 and after==changed
 r['checks'].append({'name':'unknown new helper replay refuses and preserves catalog','passed':safe,'exit':c.returncode})
 if not safe:r['productFindings'].append({'name':'new-helper-unknown-body-overwritten-on-replay','expected':'refuse unchanged unknown helper','actualExit':c.returncode,'catalogOverwritten':after!=changed})
 sql('restore-unknown-body-control',definition);check('unknown helper control fully restored',catalog('after-function-restore')==baseline)
 sql('disable-grant-trigger-control','alter table property_video_kie_test_grants disable trigger property_video_kie_test_grant_guard;');changed=catalog('disabled-trigger-before-replay')
 c=run('replay-disabled-trigger-control',[*PSQL,'-q','-1','-f',OWN],require=False);after=catalog('disabled-trigger-after-replay');safe=c.returncode!=0 and after==changed
 r['checks'].append({'name':'disabled privileged trigger replay refuses and preserves catalog','passed':safe,'exit':c.returncode})
 if not safe:r['productFindings'].append({'name':'disabled-privileged-trigger-overwritten-on-replay','actualExit':c.returncode,'catalogOverwritten':after!=changed})
 sql('restore-trigger-control','alter table property_video_kie_test_grants enable trigger property_video_kie_test_grant_guard;');check('trigger control fully restored',catalog('after-trigger-restore')==baseline)
 PSQL=final_psql;baseline=final_baseline
 r['replayScopes']={'historicalBoundary':'idempotent; changed helper body and disabled guard trigger each refuse unchanged','finalSchema':'refuses deliberately replaced prompt dispatch helper unchanged'}
 # A separately committed owned fixture permits actual independent SQL sessions.
 sql('committed-fixture',prefix+helpers+published+'create table public.kg_seed as select bf.*,bm.m from bf,bm;grant select on public.kg_seed to service_role;commit;')
 fixture_catalog=catalog('committed-fixture-catalog')
 def setup(i,extra='{}',ops=None):
  extra_sql="'"+extra.replace("'","''")+"'::jsonb"
  body=reuse+f"select pg_temp.kg_grant({i},1,{extra_sql});"+ROLE+f"create temporary table admission as select pg_temp.kg_admit({i},pg_temp.kg_id({i}),1)a;select jsonb_build_object('claim',property_video_job_claim((select(a#>>'{{job,id}}')::uuid from admission),'slot-0'));commit;"
  return one('setup-'+str(i),body)['claim']
 def cancel(c,label):sql('cancel-'+label,ROLE+f"select property_video_job_cancel('f1100000-0000-4000-8000-000000000001','{c['job']['id']}');")
 c=setup(200);args=claimargs(c);out=race('same-attempt-authority',[ROLE+f'select property_video_kie_dispatch_authority({args});'for _ in range(4)])
 s=one('same-attempt-state',state(gid(200)));check('concurrent same-attempt exactly one grantuse',all(x['exit']==0 for x in out)and s['creates']==1 and s['uses']==1 and s['cents']==167.5,{'outcomes':out,'state':s});r['races'].append({'name':'same-attempt-one-winner','sessions':4,'state':s});cancel(c,'200')
 # The actual handler proof above exercises its own guardGenerate failure and
 # proves zero authority calls. Separately, a real SQL allowance refusal here
 # preserves the prospective grant budget; only accepted preparation may call authority.
 c=setup(210);before=one('allowance-before',state(gid(210)));billing=c['job']['org_id'];key='aivideo:'+billing
 prime=one('allowance-prime',ROLE+f"select bump_rate_receipt('{key}',300,1,1);");check('actual allowance window primed',prime['accepted']is True)
 refused=one('actual-allowance-refusal',ROLE+f"select bump_rate_receipt('{key}',300,1,1);");check('actual next allowance is refused',refused['accepted']is False)
 # No authority call on this refused path, as demonstrated by the actual closed handler.
 after=one('allowance-after',state(gid(210)));probe={'before':before,'allowance':refused,'after':after,'authorityCallsAfterRefusal':0,'noProviderCall':True,'desiredNoIrreversibleCreate':after['creates']==before['creates']and after['uses']==before['uses']};r['preAllowanceProbe']=probe
 check('refused allowance preserves grant counters and use receipts',probe['desiredNoIrreversibleCreate'],probe)
 cancel(c,'210')
 # Expiry is a REAL transaction-clock transition, not forged revoked data.
 exp=reuse+"select pg_temp.kg_grant(220,1,jsonb_build_object('expires_at',now()+interval'2 seconds'));"+ROLE+"create temporary table admission as select pg_temp.kg_admit(220,pg_temp.kg_id(220),1)a;select jsonb_build_object('claim',property_video_job_claim((select(a#>>'{job,id}')::uuid from admission),'slot-0'));commit;"
 c=one('setup-expiry',exp)['claim'];time.sleep(2.2);sql('expired-authority',ROLE+f'select property_video_kie_dispatch_authority({claimargs(c)});',expect='RP403: The owner quality-test permission has ended');s=one('expiry-state',state(gid(220)));check('expired grant consumes no create',s['creates']==0 and s['uses']==0,s);cancel(c,'220')
 # A revocation committed before dispatch wins under the SAME grant row lock.
 c=setup(230);out=race('revoke-wins',[f"begin;update property_video_kie_test_grants set revoked_at=now(),revoked_reason='owned-revoke-first'where id='{gid(230)}';select pg_sleep(.2);commit;",'select pg_sleep(.05);'+ROLE+f'select property_video_kie_dispatch_authority({claimargs(c)});'])
 s=one('revoke-wins-state',state(gid(230)));check('revocation-first refuses new authority',out[0]['exit']==0 and out[1]['exit']!=0 and 'RP403:'in out[1]['output']and s['creates']==0 and s['uses']==0,{'outcomes':out,'state':s});r['races'].append({'name':'revocation-wins','state':s});cancel(c,'230')
 c=setup(240);out=race('authority-wins',['begin;'+ROLE+f'select property_video_kie_dispatch_authority({claimargs(c)});select pg_sleep(.2);commit;',f"select pg_sleep(.05);update property_video_kie_test_grants set revoked_at=now(),revoked_reason='owned-authority-first'where id='{gid(240)}';"])
 s=one('authority-wins-state',state(gid(240)));check('authority-first receipt survives later revoke',all(x['exit']==0 for x in out)and s['creates']==1 and s['uses']==1,{'outcomes':out,'state':s});r['races'].append({'name':'authority-wins','state':s})
 # Losing the first authority reply must not turn its accounting replay into a
 # fresh POST permission after revoke/expiry while source is STILL unsent.
 def ended_replay(label,claim,grant):
  c0=sql(label+'-same-attempt-rpc',ROLE+f'select property_video_kie_dispatch_authority({claimargs(claim)});',require=False)
  rows=[json.loads(l)for l in c0.stdout.splitlines()if l.startswith('{')]
  if c0.returncode==0:assert len(rows)==1 and rows[0].get('replayed')is True and rows[0].get('authority')=='owner_quality_test'
  else:assert 'RP403: The owner quality-test permission has ended'in c0.stdout,(label,c0.stdout)
  st=one(label+'-state',state(grant));check(label+' no extra counter debit',st['creates']==1 and st['uses']==1 and st['cents']==167.5 and st['holds']==0 and st['ledger']==0,st)
  result={'rpcExit':c0.returncode,'response':rows[0]if rows else None,'state':st,'providerOrAdapterPOSTExecuted':False,'desiredRefusal':c0.returncode!=0,'sourceStillUnsent':True}
  if c0.returncode==0:r['productFindings'].append({'name':label+'-unsent-authority-replay-reauthorizes','probe':result})
  return result
 r['lostAuthorityReply']={'revoked':ended_replay('revoked-grant',c,gid(240))};cancel(c,'240')
 exp2=reuse+"select pg_temp.kg_grant(241,1,jsonb_build_object('expires_at',now()+interval'2 seconds'));"+ROLE+"create temporary table admission as select pg_temp.kg_admit(241,pg_temp.kg_id(241),1)a;create temporary table claimed as select property_video_job_claim((select(a#>>'{job,id}')::uuid from admission),'slot-0')c;create temporary table authority as select pg_temp.kg_authority((select c from claimed))a;select jsonb_build_object('claim',(select c from claimed),'authority',(select a from authority));commit;"
 expired_first=one('setup-expiry-after-authority',exp2);check('authority before real expiry debits once',expired_first['authority']['replayed']is False)
 time.sleep(2.2);r['lostAuthorityReply']['expired']=ended_replay('expired-grant',expired_first['claim'],gid(241));cancel(expired_first['claim'],'241')
 # Two already-admitted one-source operations share one prospective-create slot.
 extra=json.dumps({'operation_ids':['f8a00000-0000-4000-8000-%012d'%i for i in [250,251]]})
 q=reuse+f"select pg_temp.kg_grant(250,1,'{extra}'::jsonb);"+ROLE+"create temporary table a1 as select pg_temp.kg_admit(250,pg_temp.kg_id(250),1)a;create temporary table a2 as select pg_temp.kg_admit(251,pg_temp.kg_id(250),1)a;select jsonb_build_object('c1',property_video_job_claim((select(a#>>'{job,id}')::uuid from a1),'slot-0'),'c2',property_video_job_claim((select(a#>>'{job,id}')::uuid from a2),'slot-1'));commit;"
 pair=one('quota-setup',q);out=race('last-grant-slot',[ROLE+f'select property_video_kie_dispatch_authority({claimargs(pair[k])});'for k in ['c1','c2']]);s=one('last-slot-state',state(gid(250)))
 check('last grant slot admits exactly one different attempt',sum(x['exit']==0 for x in out)==1 and sum('RP403: The owner quality-test budget is used up'in x['output']for x in out)==1 and s['creates']==1 and s['uses']==1 and s['cents']==167.5,{'outcomes':out,'state':s});r['races'].append({'name':'two-operations-last-slot','state':s})
 for k in ['c1','c2']:cancel(pair[k],'250-'+k)
 check('all races preserve complete committed fixture catalog',catalog('final-race-catalog')==fixture_catalog)
 r['passed']=not r['productFindings']and all(x['passed']for x in r['checks'])
except BaseException as e:
 r['error']=repr(e);raise
finally:
 original_failure=sys.exc_info()[0]is not None;cleanup_error=None
 r['sourceUnchanged']=hashes()==r['sourceHashes']
 if not r['sourceUnchanged']:r['passed']=False
 try:cleanup_owned()
 except BaseException as error:cleanup_error=repr(error);r['cleanupError']=cleanup_error;r['passed']=False
 r['seconds']=time.monotonic()-t0
 r['runtime']={'platform':sys.platform,'proofDeadlineSeconds':WHOLE_SECONDS,'postgresTools':{n:tool(n)for n in ['initdb','pg_ctl','createdb','psql']}}
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2,default=str)+'\n');print(json.dumps({'passed':r['passed'],'error':r.get('error'),'productFindings':[x['name']for x in r['productFindings']],'sourceUnchanged':r['sourceUnchanged'],'seconds':r['seconds'],'receiptSHA256':sha(OUT/'receipt.json')}),flush=True)
 if cleanup_error and not original_failure:raise RuntimeError(cleanup_error)

if not r['passed']:raise SystemExit(1)
