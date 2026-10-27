#!/usr/bin/env python3
"""K4: the ACTUAL docs/handoff/KIE-ACTIVATION.sql on an owned disposable Postgres.
Every migration runs unchanged; a SYNTHETIC processor-permission contract is
published; the real activation script runs with -v processor_disclosure=... and
the three exact baselines; property_video_kie_consent_seed.sql then proves the
exact seed shape and that the published contract admits a v2 job and refuses v1;
the real KIE-ROLLBACK.sql restores the saved selector. Refusals are proven too:
no published contract, a missing disclosure, and stale baselines each change
nothing. No provider, network, media or production value is involved; nothing
here is operator activation of anything outside this throwaway database.
"""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile,time,sys,signal
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase';HANDOFF=ROOT/'docs/handoff'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path,required=True);p.add_argument('--port',default='55791',help='socket port of the owned cluster (Unix socket in a private directory; no TCP listener)');a=p.parse_args()
assert re.fullmatch(r'[1-9][0-9]{3,4}',a.port)and 1024<int(a.port)<65536,'A bounded owned-cluster port is required'
OUT=a.evidence_dir.resolve();OUT.mkdir(exist_ok=False,parents=True);OUT.chmod(0o700)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
WHOLE_SECONDS=450;DATA_PREFIX='kie-seed-owned-pg-';SOCK_PREFIX='kie-seed-sock-'
os.umask(0o077)
PROOF_DEADLINE=time.monotonic()+WHOLE_SECONDS
def guard():
 assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve source3GiB reserve'
 assert shutil.disk_usage(OUT).free>=1024**3,'Preserve isolated evidence1GiB reserve'
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
def execute(cmd,body=None,env=None,timeout=120):
 guard()
 child=subprocess.Popen([str(x)for x in cmd],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env or ENV,cwd=ROOT,start_new_session=True)
 end=time.monotonic()+timeout
 try:
  while True:
   try:
    output,_=child.communicate(input=body,timeout=.5)
    return subprocess.CompletedProcess(cmd,child.returncode,output)
   except subprocess.TimeoutExpired:
    body=None;guard();assert time.monotonic()<end,'Command deadline'
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
 pidfile=DATA/'postmaster.pid'
 if started or pidfile.exists():
  assert DATA.is_dir() and not DATA.is_symlink() and DATA.stat().st_uid==os.getuid(),'Owned data directory identity'
  assert pidfile.is_file() and not pidfile.is_symlink(),'Owned postmaster identity required'
  lines=pidfile.read_text().splitlines();assert len(lines)>1 and int(lines[0])>1 and Path(lines[1]).resolve()==DATA.resolve(),'Owned postmaster data identity'
  state=subprocess.run(['ps','-p',lines[0],'-o','command='],capture_output=True,text=True,timeout=5)
  assert state.returncode==0 and str(DATA)in state.stdout and 'postgres'in state.stdout,'Owned postmaster process identity'
  stopped=subprocess.run([tool('pg_ctl'),'-D',str(DATA),'-m','immediate','-w','stop'],capture_output=True,text=True,env=ENV,timeout=30);log_command('stop',subprocess.CompletedProcess([],stopped.returncode,stopped.stdout+stopped.stderr))
  assert stopped.returncode==0,'Owned cluster cleanup failed'
 assert not pidfile.exists(),'Owned postmaster remains'
 shutil.rmtree(DATA);shutil.rmtree(SOCK)
 r['ownedClusterRemoved']=not DATA.exists() and not SOCK.exists()

MIGS=sorted((SQL/'migrations').glob('*.sql'));assert len(MIGS)>=181,len(MIGS)
BASE=SQL/'tests/property_video_jobs.sql';KIE=SQL/'tests/property_video_kie_profile.sql';SCOPE=SQL/'tests/property_video_kie_scope_consent.sql';FIX=SQL/'tests/property_video_kie_consent_seed.sql';IDENT=SQL/'functions/_shared/property-video-kie-identity.json'
ACTIVATION=HANDOFF/'KIE-ACTIVATION.sql';ROLLBACK=HANDOFF/'KIE-ROLLBACK.sql'
SOURCES=[*MIGS,SQL/'tests/ci-bootstrap.sql',BASE,KIE,SCOPE,FIX,IDENT,ACTIVATION,ROLLBACK,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):sha(f)for f in SOURCES}
PORT=a.port;PSQL=[];t0=time.monotonic()
DISCLOSURE='owned-db-fixture-privacy-policy-2026-10-17%23processors'
CONTRACT='{"token":"property-video-jobs-v2","disclosure_revision":"owned-db-fixture-r1","processors":["fal","kie"],"profiles":["kie-kling3-4k-steady-v1"]}'
r={'passed':False,'scope':'owned local PG: actual KIE-ACTIVATION.sql seed shape, v2/v1 admission, KIE-ROLLBACK.sql; synthetic contract only, no provider or owner approval','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'checks':[],'refusals':[]}
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
STATE="""select jsonb_build_object('selector',(select value from app_config where key='property_video_quality'),'selector_sha256',coalesce((select encode(sha256(convert_to(value::text,'UTF8')),'hex')from app_config where key='property_video_quality'),'absent'),'route_enabled',(select enabled from ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'),'record',(select value from app_config where key='property_video_quality_kie_activation'),'record_sha256',coalesce((select encode(sha256(convert_to(value::text,'UTF8')),'hex')from app_config where key='property_video_quality_kie_activation'),'absent'),'contract',(select value from app_config where key='property_video_processor_consent'),'config_md5',(select md5(string_agg(to_jsonb(c)::text,E'\\n'order by key))from app_config c),'routes_md5',(select md5(string_agg(to_jsonb(a)::text,E'\\n'order by id))from ai_routes a),'jobs',(select count(*)from property_video_jobs));"""
state=lambda n:one(n,STATE)
def activation(name,disclosure,selector_sha,route_enabled,record_sha,expect=None):
 vars=['-v','ON_ERROR_STOP=1','-1']
 if disclosure is not None:vars+=['-v','processor_disclosure='+disclosure]
 vars+=['-v','expected_selector_sha256='+selector_sha,'-v','expected_route_enabled='+route_enabled,'-v','expected_record_sha256='+record_sha]
 return run(name,[tool('psql'),'-X','--no-password',*CONN,'-d','kie_seed',*vars,'-f',ACTIVATION],expect=expect,require=expect is not None or True)
base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')]
ktext=KIE.read_text();money=ktext[ktext.index('create function pg_temp.kie_hold'):ktext.index('-- Explicit publication surfaces')]
stext=SCOPE.read_text();helpers=stext[:stext.index('-- Migration defaults')]
identity='create temporary table kie_identity_file as select $ki$'+IDENT.read_text()+'$ki$::jsonb j;grant select on kie_identity_file to service_role;'
paid="update app_config set value='{\"mode\":\"ceiling\",\"free_published_listings\":1}'where key='serving_mode';update app_config set value=jsonb_set(value,'{enabled}','true')where key='paid_quality_processing';update app_config set value='{\"enabled\":false}'where key='photo_preservation_quality';set local role service_role;select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'owned-seed-fixture-original','owned-seed-fixture-transaction','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');reset role;"
# The manual Starter grant in the common seed only admits its listing; the
# verified Apple receipt must become the plan authority for this fixture.
release_seed_grant="update public.orgs set plan='free',plan_source=null,plan_expires_at=null where id=(select org from bf);"
prefix='begin;'+seed+release_seed_grant+paid+identity+money+helpers
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 CONN=['-h',SOCK,'-p',PORT,'-U','postgres'];run('createdb',[tool('createdb'),*CONN,'kie_seed']);PSQL=[tool('psql'),'-X','--no-password',*CONN,'-d','kie_seed','-v','ON_ERROR_STOP=1']
 assert sql('owned-cluster-identity',"select current_setting('data_directory'),current_setting('listen_addresses')").stdout.strip()==str(DATA)+'|'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGS)[0]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 r['migrationCount']=len(partition_fresh_migrations(MIGS)[0])
 before=state('baseline-state')
 check('migrations leave the selector OFF, the row OFF, no record and no contract',before['selector']=={'enabled':False,'profile':'fal-kling3-4k-v1'}and before['route_enabled']is False and before['record']is None and before['record_sha256']=='absent'and before['contract']is None,before)
 # Refusal 1: no published processor-permission contract.
 c=activation('refuse-unpublished-contract',DISCLOSURE,before['selector_sha256'],'false','absent',expect='no processor-permission contract is published')
 r['refusals'].append({'name':'unpublished contract','exit':c.returncode});check('unpublished contract refusal changes nothing',state('after-refuse-unpublished')==before)
 # Publish the SYNTHETIC contract (committed: the activation script reads it in its own session).
 sql('publish-synthetic-contract',"insert into app_config(key,value)values('property_video_processor_consent','"+CONTRACT+"');")
 published=state('published-state');check('contract published, nothing else changed',published['contract']==json.loads(CONTRACT)and published['selector_sha256']==before['selector_sha256']and published['routes_md5']==before['routes_md5'])
 # Refusal 2: missing disclosure identifier; 3: malformed identifier (a space); 4: stale selector baseline; 5: wrong route baseline.
 for name,disc,sel,route,rec,needle in [('refuse-missing-disclosure',None,published['selector_sha256'],'false','absent','-v processor_disclosure=... is required'),
  ('refuse-malformed-disclosure','privacy policy 2026',published['selector_sha256'],'false','absent','processor_disclosure must be 1 to 200 visible ASCII'),
  ('refuse-stale-selector',DISCLOSURE,'0'*64,'false','absent','property_video_quality is not the expected baseline'),
  ('refuse-wrong-route-baseline',DISCLOSURE,published['selector_sha256'],'true','absent','is enabled=false but -v expected_route_enabled=true')]:
  c=activation(name,disc,sel,route,rec,expect=needle);r['refusals'].append({'name':name,'exit':c.returncode})
  check(name+' changes nothing',state('after-'+name)==published)
 # The ACTUAL activation with the exact baselines, inside this disposable database only.
 c=activation('actual-activation',DISCLOSURE,published['selector_sha256'],'false','absent')
 notice=re.search(r'KIE-ACTIVATION new baselines: expected_selector_sha256=([0-9a-f]{64}) expected_route_enabled=true expected_record_sha256=([0-9a-f]{64})',c.stdout);assert notice,c.stdout[-3000:]
 after=state('activated-state')
 check('activation printed the new baselines it produced',[notice.group(1),notice.group(2)]==[after['selector_sha256'],after['record_sha256']],after)
 check('activation flipped only the pinned row and the selector',after['route_enabled']is True and after['selector']=={'enabled':True,'profile':'kie-kling3-4k-steady-v1','vendor_content_license':'kie-terms-2025-08-01-section-3-owner-accepted'}and after['jobs']==0)
 r['activationRecord']=after['record']
 # Lost reply: the same baselines again refuse and overwrite nothing.
 c=activation('refuse-replay-same-baselines',DISCLOSURE,published['selector_sha256'],'false','absent',expect='property_video_quality is not the expected baseline');r['refusals'].append({'name':'replay with consumed baselines','exit':c.returncode})
 check('replay changes nothing',state('after-replay')==after)
 # The seed-shape and admission fixture, in one rolled-back transaction with the synthetic property/source seed.
 out=run('actual-consent-seed-fixture',[*PSQL,'-Atq','-v','processor_disclosure='+DISCLOSURE],prefix+FIX.read_text()).stdout
 rows=[json.loads(l)for l in out.splitlines()if l.startswith('{')and'assertions'in l];assert len(rows)==1,out[-4000:];functional=rows[0]
 check('actual seed shape and admission fixture',functional['passed'],functional);r['functional']=functional
 check('fixture rollback preserves the activated state',state('after-fixture')==after)
 # The ACTUAL rollback restores exactly the recorded previous selector and stamps the record.
 c=run('actual-rollback',[tool('psql'),'-X','--no-password',*CONN,'-d','kie_seed','-v','ON_ERROR_STOP=1','-1','-v','expected_selector_sha256='+after['selector_sha256'],'-v','expected_route_enabled=true','-v','expected_record_sha256='+after['record_sha256'],'-f',ROLLBACK])
 restored=state('rolled-back-state')
 check('rollback restored the migration-default selector and left the row as it was',restored['selector']==before['selector']and restored['selector_sha256']==before['selector_sha256']and restored['route_enabled']is True,restored)
 rec=restored['record'];check('rollback stamped the record (default mode) and kept every activation field',rec['rollback_mode']=='default'and rec['rolled_back_at']is not None and rec['route_disabled_at']is None and {k:v for k,v in rec.items()if k not in('rolled_back_at','rollback_mode')}=={k:v for k,v in after['record'].items()if k not in('rolled_back_at','rollback_mode')},rec)
 check('rollback printed its baselines',re.search(r'KIE-ROLLBACK new baselines: expected_selector_sha256='+restored['selector_sha256']+r' expected_route_enabled=true expected_record_sha256='+restored['record_sha256'],c.stdout)is not None,c.stdout[-2000:])
 r['passed']=all(x['passed']for x in r['checks'])
except BaseException as e:
 r['error']=repr(e);raise
finally:
 original_failure=sys.exc_info()[0]is not None;cleanup_error=None
 r['sourceUnchanged']=hashes()==r['sourceHashes']
 if not r['sourceUnchanged']:r['passed']=False
 try:cleanup_owned()
 except BaseException as error:cleanup_error=repr(error);r['cleanupError']=cleanup_error;r['passed']=False
 r['seconds']=time.monotonic()-t0
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2,default=str)+'\n');print(json.dumps({'passed':r['passed'],'error':r.get('error'),'checks':len(r['checks']),'refusals':len(r['refusals']),'assertions':r.get('functional',{}).get('assertions'),'sourceUnchanged':r['sourceUnchanged'],'seconds':r['seconds'],'receiptSHA256':sha(OUT/'receipt.json')}),flush=True)
 if cleanup_error and not original_failure:raise RuntimeError(cleanup_error)
if not r['passed']:raise SystemExit(1)
