#!/usr/bin/env python3
"""Owned socket-only exact copied migration/finite-media proof; no hosted calls."""
import hashlib,json,os,pathlib,re,subprocess,tempfile,shutil
from datetime import datetime,timezone
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
# Retain every failed/positive source/log; never connect to a hosted database.
POSTGRES_TOOLS=('postgres','initdb','pg_ctl','psql','createdb')
def postgres_major(version,tool):
 if not isinstance(version,str)or len(version)>256:
  raise RuntimeError('Malformed PostgreSQL tool version: '+tool)
 match=re.fullmatch(re.escape(tool)+r' \(PostgreSQL\) ([0-9]{1,2})\.[0-9]{1,3}(?: \([A-Za-z0-9][A-Za-z0-9 .+:_~/-]{0,200}\))?\n?',version)
 if not match:raise RuntimeError('Malformed PostgreSQL tool version: '+tool)
 major=int(match[1])
 if major not in(16,17):raise RuntimeError('Supported PostgreSQL versions are 16 and 17: '+tool)
 return major
def postgres_tools(directory):
 directory=pathlib.Path(directory).expanduser().resolve()
 versions={}
 for tool in POSTGRES_TOOLS:
  executable=directory/tool
  if not executable.is_file()or not os.access(executable,os.X_OK):
   raise RuntimeError('Complete PostgreSQL tool directory required: '+str(directory))
  version=subprocess.check_output([str(executable),'--version'],text=True,stderr=subprocess.STDOUT,timeout=10)
  versions[tool]={'version':version.strip(),'major':postgres_major(version,tool),'resolvedExecutable':str(executable.resolve())}
 if len({value['major']for value in versions.values()})!=1:
  raise RuntimeError('PostgreSQL tools must use one supported major version')
 return directory,versions
def select_postgres_tools():
 selected=os.environ.get('PG_BIN')
 if selected:return postgres_tools(selected)
 # Respect the workflow's PostgreSQL PATH before platform fallbacks. Resolve
 # the real binary directory so an older compatibility symlink cannot label
 # PostgreSQL 16 as 17 or mix client and server tool installations.
 candidates=[pathlib.Path(p).resolve().parent for name in('postgres','initdb')if(p:=shutil.which(name))]
 candidates.extend(pathlib.Path(p)for p in('/opt/homebrew/opt/postgresql@16/bin','/usr/lib/postgresql/16/bin',
  '/opt/homebrew/opt/postgresql@17/bin','/usr/lib/postgresql/17/bin'))
 for directory in dict.fromkeys(p.resolve()for p in candidates):
  if all((directory/tool).is_file()and os.access(directory/tool,os.X_OK)for tool in POSTGRES_TOOLS):
   return postgres_tools(directory)
 raise RuntimeError('Installed PostgreSQL 16 or 17 tools required; no database URL is accepted')
BIN,POSTGRES_VERSIONS=select_postgres_tools()
base=os.environ.get('RENDPROP_MEDIA_AUDIT_ROOT')
if base: pathlib.Path(base).mkdir(parents=True,exist_ok=True)
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-bounded-media-',dir=base));os.chmod(OUT,0o700);os.umask(0o077)
DATA=OUT/'data';SOCK=pathlib.Path(tempfile.mkdtemp(prefix='media-socket-',dir='/tmp'));os.chmod(SOCK,0o700);INPUT=OUT/'inputs';INPUT.mkdir()
paths=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/bounded_media_delivery.sql',SQL/'tests/modern_service_transport.sql',SQL/'tests/subscription_trial_video_duration.sql',pathlib.Path(__file__).resolve()]
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
for p in paths:
 q=INPUT/p.relative_to(ROOT);q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(p.read_bytes())
ENV={'PATH':str(BIN)+':/usr/bin:/bin','LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'};CONN=['-h',str(SOCK),'-p','55368','-U','postgres'];PSQL=[str(BIN/'psql'),'-X','--no-password',*CONN,'-d','rendprop_bounded_media_audit','-v','ON_ERROR_STOP=1','-Atq']
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'passed':False,'commands':[],'socketDirectory':str(SOCK),'productionMutations':0,'providerCalls':0,'networkCalls':0,
 'postgresVersion':POSTGRES_VERSIONS['postgres']['version'],'postgresMajorVersion':POSTGRES_VERSIONS['postgres']['major'],
 'postgresToolDirectory':str(BIN),'postgresToolVersions':POSTGRES_VERSIONS}
def run(name,args,stdin=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout);receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 if p.returncode!=expected:raise RuntimeError((name,p.returncode,p.stdout[-2500:]))
 return p.stdout
def query(name,s,expected=0):return run(name,PSQL,s,expected)
def positive(name):
 s=query(name,(INPUT/'services/supabase/tests/bounded_media_delivery.sql').read_text());m=re.search(r'\n(\d+)\nPASS: bounded media assertions',s);assert m,s[-1000:];return int(m[1])
started=False;print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN/'initdb','-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);run('start',[BIN/'pg_ctl','-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55368 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('createdb',[BIN/'createdb','--no-password',*CONN,'rendprop_bounded_media_audit']);assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(INPUT/'services/supabase/tests/ci-bootstrap.sql').read_text())
 for p in sorted((INPUT/'services/supabase/migrations').glob('*.sql')):
  query('migration-'+p.stem,p.read_text())
  if p.name=='20261007135843_bounded_media_delivery.sql':
   receipt['coreFreshAssertions']=positive('core-fresh');query('core-boundary-replay',p.read_text());receipt['coreReplayAssertions']=positive('core-replay')
   core=p.read_text();begin=core.index('create or replace function public.provision_media_delivery_budget(');end=core.index('end$$;',begin)+len('end$$;');body=core[begin:end]
   assert body.count('storage_liability>p_storage')==1
   denied=query('control-core-storage-floor','begin;'+body.replace('storage_liability>p_storage','false')+'\n'+(INPUT/'services/supabase/tests/bounded_media_delivery.sql').read_text(),3)
   assert 'MEDIA DENIAL: read-only funding cannot underprice earlier physical custody' in denied
   receipt['coreStorageFloorRemovalControl']={'compiledActualFunction':True,'oracleRejected':True,'exit':3};receipt['coreRestoredAssertions']=positive('core-floor-restored')
 receipt['freshAssertions']=positive('final-pooled-fresh');query('pooled-replay',(INPUT/'services/supabase/migrations/20261007145000_pooled_media_startup.sql').read_text());receipt['replayAssertions']=positive('final-pooled-replay')
 duration=query('final-trial-video-duration',(INPUT/'services/supabase/tests/subscription_trial_video_duration.sql').read_text());assert 'TRIAL_VIDEO_CHECKS 31' in duration;receipt['trialVideoDurationAssertions']=31
 modern=query('final-modern-transport',(INPUT/'services/supabase/tests/modern_service_transport.sql').read_text());assert 'modern service transport: 7 checks passed' in modern;receipt['modernTransportAssertions']=7
 # Compile and exercise actual source guard-removal controls in transactions.
 source=(INPUT/'services/supabase/migrations/20261007135843_bounded_media_delivery.sql').read_text()
 def function(name):
  begin=source.index('create or replace function public.'+name+'(');end=source.index('end$$;',begin)+len('end$$;');return source[begin:end]
 controls=[('read-byte-cap',function('media_delivery_admit'),'p_bytes>b.byte_limit-b.used_bytes','false'),
 ('storage-scope',function('media_storage_reserve'),"if not ((p_bucket='uploads'", "if false and not ((p_bucket='uploads'"),
 ('metadata-liability',function('media_storage_before_write'),"if tg_op='INSERT'then perform public.media_storage_reserve(new.org_id,new.bucket,new.storage_key,new.bytes);end if;",'null;'),
 ('project-liability',function('media_storage_before_write'),"perform public.media_storage_reserve(new.org_id,'uploads','studio-project/'||new.org_id||'/'||new.actor_id||'/'||new.id||'/'||i,least(8388608,new.bytes-i*8388608));",'null;')]
 pooled=(INPUT/'services/supabase/migrations/20261007145000_pooled_media_startup.sql').read_text();begin=pooled.index('create or replace function public.provision_media_delivery_budget(');end=pooled.index('end$$;',begin)+len('end$$;')
 controls.append(('pooled-storage-floor',pooled[begin:end],'storage_liability>p_storage','false'))
 receipt['guardControls']=[]
 for name,body,old,new in controls:
  assert body.count(old)==1,(name,'exact guard missing')
  result=query('control-'+name,'begin;'+body.replace(old,new)+'\n'+(INPUT/'services/supabase/tests/bounded_media_delivery.sql').read_text(),3)
  assert 'MEDIA FAIL:' in result or 'MEDIA DENIAL:'in result,(name,'not an executed oracle rejection',result[-1000:])
  receipt['guardControls'].append({'name':name,'compiledActualFunction':True,'oracleRejected':True,'exit':3})
 receipt['restoredAssertions']=positive('final-restored')
 # Real competing service transactions: the startup cash cannot sponsor two
 # org budgets, and physical capacity cannot admit both distinct 60-byte PUTs.
 tariff='{"r2_a_cents_per_million":450,"r2_b_cents_per_million":36,"worker_cents_per_million":30,"worker_cpu_cents_per_million_ms":2,"edge_cents_per_million":200,"db_cents":1,"logs_cents":1,"storage_cents_per_gb_month":1.5}'
 reserves='{"delivery":3000,"compute":1500,"storage":50,"retention":50}'
 query('race-setup',"""create table public.media_synthetic_race_fixture(o uuid primary key);do $$declare a uuid;o uuid;begin for i in 1..2 loop a:=gen_random_uuid();insert into auth.users(id,email)values(a,'race-'||i||'@fixture.invalid');select org_id into o from public.memberships where user_id=a;insert into public.media_synthetic_race_fixture values(o);end loop;end$$;grant select on public.media_synthetic_race_fixture to service_role;set role service_role;select provision_media_account_reserve('synthetic-cash-race','9c332c75b96cc642621dad5d86d4bf18','owner_paid_cash',repeat('f',64),now()-interval '1 minute',now()+interval '1 day',6600,'"""+tariff+"""','{"storage":0,"delivery":1000,"compute":1000,"email":0,"support":0,"retention":0,"uncertainty":0}');""")
 orgs=query('race-orgs','select o from public.media_synthetic_race_fixture order by o;').strip().splitlines();assert len(orgs)==2
 def compete(name,statements):
  children=[subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV)for _ in statements]
  for child,statement in zip(children,statements):child.stdin.write(statement);child.stdin.close()
  outcomes=[]
  for i,child in enumerate(children):
   child.wait(timeout=30);value=child.stdout.read();log=OUT/f'{name}-{i}.log';log.write_text(value);receipt['commands'].append({'name':f'{name}-{i}','exit':child.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});outcomes.append((child.returncode,value))
  assert sorted(v[0]for v in outcomes)==[0,3],(name,outcomes)
  return outcomes
 cash=compete('cash-race',["set role service_role;select public.provision_media_delivery_budget('"+o+"','race-budget-"+str(i)+"',null,(select starts_at from media_account_reserves where receipt_ref='synthetic-cash-race'),(select ends_at from media_account_reserves where receipt_ref='synthetic-cash-race'),10,100,100,'"+tariff+"','"+reserves+"',repeat('e',64),'synthetic-cash-race');"for i,o in enumerate(orgs)])
 assert any('RP402: Account reserve has no unallocated org cash'in v for _,v in cash)
 winner=query('race-winner',"select org_id from media_delivery_budgets where account_reserve_ref='synthetic-cash-race';").strip()
 storage=compete('storage-race',["begin;set local role service_role;select media_storage_reserve('"+winner+"','uploads','uploads/"+winner+"/race-"+str(i)+"',60);select pg_sleep(0.1);commit;"for i in range(2)])
 assert any('RP429: Stored media allowance exhausted'in v for _,v in storage)
 assert query('race-postconditions',"select allocated_org_cents=4600 from media_account_reserves where receipt_ref='synthetic-cash-race';select count(*)=1 and sum(bytes)=60 from media_storage_receipts where org_id='"+winner+"';").strip()=='t\nt'
 receipt['actualRaces']={'startupCash':{'success':1,'refused':1,'code':'RP402'},'physicalStorage':{'success':1,'refused':1,'code':'RP429'}}
 receipt['currentByteMatchesCopied']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()==hashes[str(p.relative_to(ROOT))]for p in paths}
 receipt.update(passed=True,finishedAt=datetime.now(timezone.utc).isoformat())
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN/'pg_ctl','-D',DATA,'-m','immediate','-w','stop'])
 receipt['clusterStopped']=not(DATA/'postmaster.pid').exists();(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS',receipt['freshAssertions'],receipt['replayAssertions'],flush=True)
