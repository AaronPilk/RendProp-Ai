#!/usr/bin/env python3
"""Portable owned-PostgreSQL proof of actual pipeline cost/admission linkage.

Uses installed Python/PostgreSQL only. No install, live DB, provider or credential.
Chronology: bootstrap, every migration before the own one, seeded financial history,
first apply, immediate own replay, refused unknown same-name objects, the remaining
migrations, then the actual closed-transport pipeline cases and the omission witness.
"""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import argparse,datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,tempfile,time
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[3]
OWN='20261017115012_conservative_pipeline_cost_binding.sql'
CHANGED={'serving_ceiling_spent_cents(uuid,timestamp with time zone,timestamp with time zone)','serving_cost_finish(uuid,uuid,text,text,text,integer)'}
ADDED={'pipeline_record_provider_cost(uuid,uuid,uuid,text,text,text,text,text,uuid,text,numeric,numeric,numeric,jsonb)','pipeline_cost_covered_cents(uuid,timestamp with time zone,timestamp with time zone)'}
RELATION='public.pipeline_provider_cost_bindings'
# One digest per public function (definition, owner, ACL, security, config) keeps
# every catalog comparison exact while the retained logs stay a few KB each.
CATALOG="select coalesce(jsonb_object_agg(oid::regprocedure::text,md5(pg_get_functiondef(oid)||pg_get_userbyid(proowner)||coalesce(proacl::text,'')||prosecdef::text||coalesce(proconfig::text,''))),'{}')from pg_proc where pronamespace='public'::regnamespace and prokind='f'"
TABLES="select coalesce(jsonb_agg(relname order by relname),'[]')from pg_class where relnamespace='public'::regnamespace and relkind='r'"
SHAPE=("select jsonb_build_object('columns',(select string_agg(a.attname||' '||format_type(a.atttypid,a.atttypmod)||a.attnotnull::text||coalesce(pg_get_expr(d.adbin,d.adrelid),''),','order by a.attnum)from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where a.attrelid=%s::regclass and a.attnum>0 and not a.attisdropped),"
 "'constraints',(select string_agg(conname||':'||pg_get_constraintdef(oid),';'order by conname)from pg_constraint where conrelid=%s::regclass),'indexes',(select string_agg(indexrelid::regclass::text,','order by 1)from pg_index where indrelid=%s::regclass),"
 "'acl',(select relacl::text from pg_class where oid=%s::regclass),'rls',(select relrowsecurity from pg_class where oid=%s::regclass),'policies',(select count(*)from pg_policy where polrelid=%s::regclass),'triggers',(select count(*)from pg_trigger where tgrelid=%s::regclass and not tgisinternal))")%((repr(RELATION),)*7)
# Seeded BEFORE the own migration at the predecessor schema: two libraries, holds in
# every state through the real reserve/finish RPCs, one legacy ledger row that the
# existing settle trigger links to a succeeded hold, one unlinked legacy row.
HISTORY="""
insert into auth.users(id,email,is_anonymous)values('b1000000-0000-4000-8000-000000000001','history-one@fixture.invalid',false),('b1000000-0000-4000-8000-000000000002','history-two@fixture.invalid',false);
create temp table h as select (select org_id from public.memberships where user_id='b1000000-0000-4000-8000-000000000001')as org1,(select org_id from public.memberships where user_id='b1000000-0000-4000-8000-000000000002')as org2;
insert into public.listings(id,org_id,agent_id,address)select 'b1000000-0000-4000-8000-000000000011',org1,'b1000000-0000-4000-8000-000000000001','History one'from h;
insert into public.listings(id,org_id,agent_id,address)select 'b1000000-0000-4000-8000-000000000012',org2,'b1000000-0000-4000-8000-000000000002','History two'from h;
insert into public.render_jobs(id,listing_id,status,source)values('b1000000-0000-4000-8000-000000000021','b1000000-0000-4000-8000-000000000011','created','worker'),('b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000012','created','worker');
grant select on h to service_role;
set local role service_role;
select public.serving_cost_reserve('b1000000-0000-4000-8000-000000000001',org1,'b1000000-0000-4000-8000-000000000021','worker:'||repeat('a',48),'fal','fal-ai/flux-pro/kontext',repeat('a',64),4,'published-standard-20261006')from h;
select public.serving_cost_finish('b1000000-0000-4000-8000-000000000001',org1,'b1000000-0000-4000-8000-000000000021','worker:'||repeat('a',48),'uncertain',null)from h;
select public.serving_cost_reserve('b1000000-0000-4000-8000-000000000001',org1,'b1000000-0000-4000-8000-000000000021','worker:'||repeat('b',48),'fal','fal-ai/flux-pro/kontext',repeat('b',64),4,'published-standard-20261006')from h;
select public.serving_cost_finish('b1000000-0000-4000-8000-000000000001',org1,'b1000000-0000-4000-8000-000000000021','worker:'||repeat('b',48),'succeeded',null)from h;
select public.serving_cost_reserve('b1000000-0000-4000-8000-000000000001',org1,'b1000000-0000-4000-8000-000000000021','worker:'||repeat('c',48),'fal','fal-ai/flux-pro/kontext',repeat('c',64),4,'published-standard-20261006')from h;
select public.serving_cost_finish('b1000000-0000-4000-8000-000000000001',org1,'b1000000-0000-4000-8000-000000000021','worker:'||repeat('c',48),'rejected',429)from h;
select public.serving_cost_reserve('b1000000-0000-4000-8000-000000000002',org2,'b1000000-0000-4000-8000-000000000022','worker:'||repeat('d',48),'gemini','gemini-3.1-flash-image',repeat('d',64),20,'published-standard-20261006')from h;
reset role;
insert into public.cost_ledger(job_id,org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)select 'b1000000-0000-4000-8000-000000000021',org1,'restage','fal','fal-ai/flux-pro/kontext',1,4,4,jsonb_build_object('request_key','b1000000-0000-4000-8000-000000000021','stage','worker:'||repeat('b',48),'fallback','flux_kontext'),'legacy-history-linked' from h;
insert into public.cost_ledger(job_id,org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)select 'b1000000-0000-4000-8000-000000000021',org1,'qc','anthropic','claude-haiku',2,.5,1,jsonb_build_object('verdict','pass'),'legacy-history-unlinked' from h;
"""
SNAPSHOT="""select jsonb_build_object('ledger',(select coalesce(string_agg(md5(row_to_json(l)::text),','order by l.id),'')from public.cost_ledger l),'ledger_rows',(select count(*)from public.cost_ledger),
 -- Later credit migrations append nullable funding columns. Compare the exact
 -- predecessor financial row, not its later JSON schema shape.
 'holds',(select coalesce(string_agg(md5((to_jsonb(r)-'credit_hold_id'-'credit_environment')::text),','order by r.id),'')from public.serving_cost_reservations r),'hold_rows',(select count(*)from public.serving_cost_reservations),
 'linked',(select count(*)from public.serving_cost_reservations where ledger_id is not null),
 'ceiling_one',(select public.serving_ceiling_spent_cents(org_id,null,null)from public.memberships where user_id='b1000000-0000-4000-8000-000000000001'),
 'ceiling_two',(select public.serving_ceiling_spent_cents(org_id,null,null)from public.memberships where user_id='b1000000-0000-4000-8000-000000000002'))"""
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,v):
 with p.open('x')as f:os.chmod(p,0o600);json.dump(v,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--evidence-dir',type=Path,required=True);ap.add_argument('--pg-bin',type=Path);ap.add_argument('--socket-dir',type=Path);a=ap.parse_args()
 out=a.evidence_dir.resolve();assert not out.is_relative_to(ROOT)and not out.exists(),'Fresh evidence outside repository required';out.mkdir(parents=True,mode=0o700)
 start=time.monotonic();mins={};child=None;server=False;socket=None;commands=[];data=out/'data';r={'passed':False,'liveProviderCalls':0,'scope':'actual pipeline closed-transport + chronological owned PostgreSQL','startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 def guard():
  assert time.monotonic()-start<420,'Whole420s deadline'
  for k,p,f in [('internal','/',3*1024**3),('evidence',out,(8 if sys.platform=='darwin'else 1)*1024**3)]:
   n=shutil.disk_usage(p).free;mins[k]=min(mins.get(k,n),n);assert n>=f,'Storage reserve:'+k
 env={'PATH':'/usr/bin:/bin','HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),'PYTHONDONTWRITEBYTECODE':'1','LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
 def run(name,args,limit=30,body=None,expected=0,cleanup=False,refuses=None):
  nonlocal child
  if not cleanup:guard()
  p=out/(str(len(commands)).zfill(3)+'-'+name+'.log');began=time.monotonic()
  with p.open('xb')as stream:
   child=subprocess.Popen(list(map(str,args)),stdin=subprocess.PIPE if body else subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,env=env,cwd=ROOT,start_new_session=True)
   if body:child.stdin.write(body.encode());child.stdin.close()
   while child.poll()is None:
    if not cleanup:guard()
    assert time.monotonic()-began<limit and p.stat().st_size<=4*1024**2,'Child budget/log cap:'+name;time.sleep(.05)
   child.wait(timeout=2);assert time.monotonic()-began<limit and p.stat().st_size<=4*1024**2,'Terminal budget/log cap:'+name
   if not cleanup:guard()
  text=p.read_text();rec={'name':name,'argv':list(map(str,args)),'exitCode':child.returncode,'seconds':time.monotonic()-began,'log':str(p),'sha256':sha(p)};commands.append(rec);child=None
  if refuses:assert rec['exitCode']!=0 and refuses in text,'Expected refusal missing:'+name+':'+text[-1800:]
  else:assert rec['exitCode']==expected,'Unexpected command exit:'+name+':'+text[-1800:]
  return text
 try:
  guard();(out/'home').mkdir();(out/'tmp').mkdir()
  if a.pg_bin:pg=a.pg_bin.resolve()
  else:
   config=shutil.which('pg_config');assert config,'Installed pg_config or --pg-bin required';pg=Path(subprocess.check_output([config,'--bindir'],timeout=10,text=True).strip()).resolve()
  assert all((pg/n).is_file()and os.access(pg/n,os.X_OK)for n in ['initdb','pg_ctl','postgres','psql']),'Existing PostgreSQL tools required'
  migrations=sorted((ROOT/'services/supabase/migrations').glob('*.sql'));assert len([p for p in migrations if p.name==OWN])==1,'Own migration required'
  own=[p for p in migrations if p.name==OWN][0];own_index=migrations.index(own)
  inputs=[*migrations,ROOT/'services/supabase/tests/ci-bootstrap.sql',Path(__file__),ROOT/'services/supabase/tests/pipeline_cost_binding_cases.py']
  inputs+=sorted((ROOT/'services/pipeline').glob('*.py'))+sorted((ROOT/'services/pipeline/providers').glob('*.py'))
  pins={str(p):sha(p)for p in inputs};tools={str(p):sha(p)for p in [Path(sys.executable).resolve(),*[pg/n for n in ['initdb','pg_ctl','postgres','psql']]]}
  def verify():
   for p,v in {**pins,**tools}.items():assert sha(p)==v,'Consumed source/tool drift:'+p
  socket_root=Path(os.environ.get('RENDPROP_PG_SOCKET_ROOT','/tmp')).resolve()
  if a.socket_dir:
   socket=a.socket_dir.absolute();assert socket.parent.resolve()==socket_root and socket.name.startswith('rp-pipeline-')and not socket.exists(),'Exclusive short owned socket path required';socket.mkdir(mode=0o700)
  else:socket=Path(tempfile.mkdtemp(prefix='rp-pipeline-',dir=socket_root))
  port=52000+os.getpid()%10000
  write(out/'INTENT.json',{'sourcePins':pins,'toolPins':tools,'migrations':len(migrations),'ownMigration':OWN,'network':'Supplier and REST HTTP are closed fixture functions; PostgreSQL Unix socket only','wholeSeconds':420,'childCaseSeconds':120})
  run('initdb',[pg/'initdb','-D',data,'-A','trust','-U','postgres','--no-locale','-E','UTF8'])
  run('start',[pg/'pg_ctl','-D',data,'-l',out/'postgres.log','-o',"-F -c listen_addresses='' -k '"+str(socket)+"' -p "+str(port),'-w','start']);server=True
  psql=[str(pg/'psql'),'-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h',str(socket),'-p',str(port),'-U','postgres','-d','postgres']
  def q(name,sql,refuses=None):
   text=run(name,psql,body=sql,refuses=refuses)
   if refuses:return None
   text=text.strip();return json.loads(text)if text else None
  def catalog(name):return {'functions':q(name+'-functions',CATALOG),'tables':q(name+'-tables',TABLES)}
  def shape(name):return q(name,SHAPE)
  run('bootstrap',psql+['-f',ROOT/'services/supabase/tests/ci-bootstrap.sql'])
  for i,m in enumerate(migrations[:own_index]):run('migration-'+str(i).zfill(3),psql+['-f',m])
  # ── financial history at the predecessor schema ──────────────────────────
  run('seed-history',psql,body='begin;'+HISTORY+'commit;')
  history_before=q('history-before',SNAPSHOT);before=catalog('before-own')
  assert history_before['ledger_rows']==2 and history_before['hold_rows']==4 and history_before['linked']==1,('Seeded history inventory',history_before)
  assert history_before['ceiling_one']==9 and history_before['ceiling_two']==20,('Predecessor ceiling: 4 uncertain hold + 4 linked ledger + 1 unlinked ledger (linked succeeded hold released); 20 reserved hold',history_before)
  # ── first apply ──────────────────────────────────────────────────────────
  run('migration-'+str(own_index).zfill(3)+'-own-first-apply',psql+['-f',own])
  after=catalog('after-own-first-apply');history_after=q('history-after-first-apply',SNAPSHOT);shape_first=shape('shape-after-first-apply')
  assert history_after==history_before,('Financial history must be byte-identical after the own migration',history_before,history_after)
  changed={k for k,v in before['functions'].items()if after['functions'].get(k)!=v};added=set(after['functions'])-set(before['functions']);dropped=set(before['functions'])-set(after['functions'])
  assert changed==CHANGED and added==ADDED and not dropped,('Own migration touched other functions',sorted(changed),sorted(added),sorted(dropped))
  assert set(after['tables'])-set(before['tables'])=={RELATION.split('.')[1]}and set(before['tables'])<=set(after['tables']),'Own migration adds exactly one relation'
  r['firstApply']={'historyIdentical':True,'changedFunctions':sorted(changed),'addedFunctions':sorted(added),'addedRelation':RELATION,'predecessorCeiling':{'one':history_before['ceiling_one'],'two':history_before['ceiling_two']}}
  # ── immediate own replay ─────────────────────────────────────────────────
  run('own-replay',psql+['-f',own])
  assert catalog('after-own-replay')==after and shape('shape-after-own-replay')==shape_first and q('history-after-own-replay',SNAPSHOT)==history_before,'Unchanged own replay must be a no-op'
  # ── unknown same-name objects are refused, nothing mutates ──────────────
  rec='public.pipeline_record_provider_cost(uuid,uuid,uuid,text,text,text,text,text,uuid,text,numeric,numeric,numeric,jsonb)';cov='public.pipeline_cost_covered_cents(uuid,timestamptz,timestamptz)'
  ceiling='public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)';finish='public.serving_cost_finish(uuid,uuid,text,text,text,integer)'
  def definition(name,signature):return run(name,psql,body='select pg_get_functiondef(%s::regprocedure);'%repr(signature)).rstrip('\n')
  controls=[]
  def control(name,mutate,restore,oracle):
   prior_catalog=catalog('control-'+name+'-before');prior_shape=shape('control-'+name+'-shape-before')
   run('control-'+name+'-mutate',psql,body=mutate)
   mutated_catalog=catalog('control-'+name+'-mutated');mutated_shape=shape('control-'+name+'-shape-mutated')
   assert (mutated_catalog,mutated_shape)!=(prior_catalog,prior_shape),'Control must actually change the catalog:'+name
   run('control-'+name+'-replay',psql+['-f',own],refuses=oracle)
   assert catalog('control-'+name+'-after-refusal')==mutated_catalog and shape('control-'+name+'-shape-after-refusal')==mutated_shape and q('control-'+name+'-history',SNAPSHOT)==history_before,'A refused replay must not mutate anything:'+name
   run('control-'+name+'-restore',psql,body=restore)
   assert catalog('control-'+name+'-restored')==after and shape('control-'+name+'-shape-restored')==shape_first,'Restore must return the exact first-apply catalog:'+name
   controls.append({'name':name,'actual_compiled_SQL':True,'refusal':oracle,'catalog_and_history_unchanged_on_refusal':True})
  original=definition('read-record',rec);assert original.count('\nbegin\n')==1
  control('changed-record-body',original.replace('\nbegin\n','\nbegin -- unknown privileged body\n',1)+';',original+';','Review changed pipeline cost binding helper: '+rec)
  original_cov=definition('read-covered',cov)
  control('changed-covered-acl','grant execute on function '+cov+' to authenticated;','revoke execute on function '+cov+' from authenticated;','Review changed pipeline cost binding helper: '+cov)
  control('changed-covered-security',original_cov.replace('SECURITY DEFINER','',1)+';',original_cov+';','Review changed pipeline cost binding helper: '+cov)
  control('changed-relation-shape','alter table '+RELATION+' add column extra integer;','alter table '+RELATION+' drop column extra;','Review changed pipeline cost binding relation: '+RELATION)
  control('changed-relation-acl','grant insert on '+RELATION+' to service_role;','revoke insert on '+RELATION+' from service_role;','Review changed pipeline cost binding relation: '+RELATION)
  control('added-relation-policy','create policy unknown_open on '+RELATION+' for select using(true);','drop policy unknown_open on '+RELATION+';','Review changed pipeline cost binding relation: '+RELATION)
  control('disabled-relation-rls','alter table '+RELATION+' disable row level security;','alter table '+RELATION+' enable row level security;','Review changed pipeline cost binding relation: '+RELATION)
  original_ceiling=definition('read-ceiling',ceiling);anchor=' select coalesce((select sum(total_cents)';assert original_ceiling.count(anchor)==1
  control('changed-ceiling-body',original_ceiling.replace(anchor,' select 0+coalesce((select sum(total_cents)',1)+';',original_ceiling+';','Review changed serving ceiling authority')
  original_finish=definition('read-finish',finish);anchor=" if r.id is null then raise exception 'RP404: Provider attempt not found';end if;";assert original_finish.count(anchor)==1
  control('changed-finish-body',original_finish.replace(anchor,anchor+' -- unknown body',1)+';',original_finish+';','Review changed serving finish authority')
  r['replayControls']=controls
  run('own-replay-after-controls',psql+['-f',own]);assert catalog('after-final-replay')==after and shape('shape-after-final-replay')==shape_first and q('history-after-controls',SNAPSHOT)==history_before,'Final own replay must be a no-op'
  # ── remaining chronology, then the actual pipeline cases ─────────────────
  for i,m in enumerate((m for m in partition_fresh_migrations(migrations)[0] if m.name>own.name),own_index+1):run('migration-'+str(i).zfill(3),psql+['-f',m])
  history_final=q('history-final',SNAPSHOT)
  assert history_final==history_before,'Later migrations must not rewrite seeded financial history'
  assert q('history-new-credit-columns',"select count(*) from public.serving_cost_reservations where actor_id in ('b1000000-0000-4000-8000-000000000001','b1000000-0000-4000-8000-000000000002') and (credit_hold_id is not null or credit_environment is not null)")==0,'Later migrations must not fund legacy holds with credits'
  tampered=q('history-hold-tamper-control',"begin; update public.serving_cost_reservations set hold_cents=hold_cents+1 where actor_id='b1000000-0000-4000-8000-000000000001';"+SNAPSHOT+";rollback;")
  assert tampered!=history_final and tampered['holds']!=history_final['holds'],'Financial history snapshot must reject altered hold amounts'
  assert q('history-after-tamper-rollback',SNAPSHOT)==history_final,'Financial history control must roll back'
  write(out/'fixture.json',{'psql':psql,'env':env})
  env['PIPELINE_COST_PG_FIXTURE']=str(out/'fixture.json');env['PIPELINE_COST_CASE_EVIDENCE']=str(out/'positive-cases.json')
  positive=run('actual-pipeline-and-sql',[sys.executable,'-B','-u',ROOT/'services/supabase/tests/pipeline_cost_binding_cases.py','-v'],limit=120)
  # stdout (pipeline prints) and stderr (unittest) are merged; judge the
  # unittest summary by lines, not by the last byte of the stream.
  lines=[x.strip()for x in positive.splitlines()];summary=[i for i,x in enumerate(lines)if re.match(r'^Ran [1-9][0-9]* tests? in ',x)]
  assert len(summary)==1 and 'OK'in lines[summary[0]:]and not any(x.startswith(('FAILED','ERROR:','Traceback'))for x in lines),'Actual case inventory required'
  r['caseCount']=int(re.match(r'^Ran ([1-9][0-9]*)',lines[summary[0]]).group(1));r['positiveCases']=str(out/'positive-cases.json')
  env['PIPELINE_COST_FAULT']='omit-python-binding';env['PIPELINE_COST_CASE_EVIDENCE']=str(out/'omission-cases.json')
  omitted=run('omit-python-binding',[sys.executable,'-B','-u',ROOT/'services/supabase/tests/pipeline_cost_binding_cases.py','PipelineCostTests.test_actual_pipeline_same_attempt_once','-v'],limit=30,expected=1)
  assert 'AssertionError: 8.0 != 4 : Pipeline same attempt counted twice'in omitted or 'AssertionError: 8 != 4 : Pipeline same attempt counted twice'in omitted,'Exact old-defect omission witness required'
  assert 'Ran 1 test'in omitted and 'FAILED (failures=1)'in omitted and 'ERROR:'not in omitted and 'errors='not in omitted,'No setup failures admitted as omission'
  env.pop('PIPELINE_COST_FAULT');verify();guard();r.update(passed=True,currentMigrationCount=len(migrations),sourceUnchanged=True,sourcePins=pins,toolPins=tools,actualBindingOmissionRefused=True,historyPreserved=True,ownReplayNoop=True)
 except BaseException as e:r['error']=type(e).__name__+': '+str(e)[:4000]
 finally:
  cleanup=[]
  if child and child.poll()is None:
   try:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=3)
   except BaseException as e:cleanup.append('active child:'+str(e))
  marker=data/'postmaster.pid'
  if server:
   try:run('stop',[pg/'pg_ctl','-D',data,'-m','immediate','-w','stop'],cleanup=True,limit=15)
   except BaseException as e:cleanup.append('stop:'+str(e))
  try:
   if marker.exists():
    pid=abs(int(marker.read_text().splitlines()[0]));alive=True
    try:os.kill(pid,0)
    except ProcessLookupError:alive=False
    assert not alive,'Owned PostgreSQL PID remains active'
   if data.exists():shutil.rmtree(data)
   if socket and socket.exists():shutil.rmtree(socket)
  except BaseException as e:cleanup.append('owned cleanup:'+str(e))
  try:
   if 'verify'in locals():verify()
   guard()
  except BaseException as e:cleanup.append('terminal guard/binding:'+str(e))
  r.update(commands=commands,cleanupErrors=cleanup,ownedDataRemoved=not data.exists(),ownedSocketRemoved=not socket or not socket.exists(),minimumFreeBytes=mins,seconds=time.monotonic()-start)
  if cleanup:r['passed']=False
  write(out/'receipt.json',r);print(json.dumps({k:r[k]for k in ['passed','error','caseCount','currentMigrationCount','cleanupErrors','seconds','minimumFreeBytes']if k in r}),flush=True)
 return 0 if r['passed']else 1
if __name__=='__main__':raise SystemExit(main())
