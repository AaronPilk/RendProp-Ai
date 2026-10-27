#!/usr/bin/env python3
"""Actual isolated PG proof of recorded temporal motion verdicts
(20261017191000_property_video_temporal_verdict.sql).

Chronology: bootstrap, every migration before the own one, committed property-
video history at the predecessor schema (a paid shot under review, and a job
whose assembly recovery snapshot was already recorded), first apply (exact
catalog delta: one table, two functions, one trigger; the shot table and every
existing row byte-identical), immediate own replay (no-op), refused unknown
same-name objects (catalog and rows unchanged by every refusal), client
ACL/RLS, a recorded verdict that writes nothing else, the recorded assembly
snapshot still matching after the migration (with a negative control showing a
shot-row column would break it), the operator rollback in a clone (exact
predecessor catalog, untouched rows, refused changed object, idempotent rerun,
clean re-apply), the remaining migrations, then the actual SQL fixture fresh
and replayed, existing paid-retry regression, compiled defect controls and a
two-writer first-record race in a clone. No production connection, media,
model, provider or network: Unix-socket PostgreSQL only.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='temporal-verdict-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
OWN='20261017191000_property_video_temporal_verdict.sql'
MIG=SQL/'migrations'/OWN;FIX=SQL/'tests/property_video_temporal.sql';BASE=SQL/'tests/property_video_jobs.sql';DERIVED=SQL/'tests/property_video_derived_retry.sql'
COMPOSE=SQL/'tests/property_video_compose_recovery.sql';ROLLBACK=ROOT/'docs/handoff/PROPERTY-VIDEO-TEMPORAL-ROLLBACK.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));assert MIGRATIONS.count(MIG)==1,'Own migration required';OWN_INDEX=MIGRATIONS.index(MIG)
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',BASE,FIX,DERIVED,COMPOSE,ROLLBACK,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'scope':'disposable actual PostgreSQL/schema/roles/concurrency, synthetic receipts only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'replayControls':[],'controls':[],'races':[]}
RPC='public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)';GUARD='public.property_video_temporal_verdict_guard()'
SOURCES_REL='public.property_video_job_sources';REL='public.property_video_job_temporal_verdicts'
ADDED={'property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','property_video_temporal_verdict_guard()'}
# One digest per public function (definition, owner, ACL, security, config), the
# public relations, and the exact shape of the shot table and the verdict table.
FUNCS="select coalesce(jsonb_object_agg(oid::regprocedure::text,md5(pg_get_functiondef(oid)||pg_get_userbyid(proowner)||coalesce(proacl::text,'')||prosecdef::text||coalesce(proconfig::text,''))),'{}')from pg_proc where pronamespace='public'::regnamespace and prokind='f'"
TABLES="select coalesce(jsonb_agg(relname::text order by relname),'[]')from pg_class where relnamespace='public'::regnamespace and relkind in('r','v','m','p')"
SHAPE=("select jsonb_build_object("
 "'columns',(select jsonb_agg(a.attname||' '||format_type(a.atttypid,a.atttypmod)||case when a.attnotnull then' not null'else''end||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),'')||coalesce(' acl '||a.attacl::text,'')order by a.attnum)from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where a.attrelid=to_regclass('%(r)s')and a.attnum>0 and not a.attisdropped),"
 "'constraints',(select jsonb_agg(conname||': '||pg_get_constraintdef(oid)order by conname)from pg_constraint where conrelid=to_regclass('%(r)s')),"
 "'referenced_by',(select jsonb_agg(conrelid::regclass::text||'.'||conname order by 1)from pg_constraint where confrelid=to_regclass('%(r)s')),"
 "'indexes',(select jsonb_agg(pg_get_indexdef(indexrelid)order by indexrelid::regclass::text)from pg_index where indrelid=to_regclass('%(r)s')),"
 "'triggers',(select jsonb_agg(tgname||' '||tgenabled::text||' '||pg_get_triggerdef(oid)order by tgname)from pg_trigger where tgrelid=to_regclass('%(r)s')and not tgisinternal),"
 "'policies',(select coalesce(jsonb_agg(polname||' '||polcmd::text||' '||coalesce(pg_get_expr(polqual,polrelid),'')order by polname),'[]')from pg_policy where polrelid=to_regclass('%(r)s')),"
 "'acl',(select relacl::text from pg_class where oid=to_regclass('%(r)s')),'owner',(select pg_get_userbyid(relowner)from pg_class where oid=to_regclass('%(r)s')),"
 "'rls',(select relrowsecurity from pg_class where oid=to_regclass('%(r)s')),'force_rls',(select relforcerowsecurity from pg_class where oid=to_regclass('%(r)s')))")
started=False
def run(name,cmd,body=None,refuses=None):
 r=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode and refuses in r.stdout)if refuses else r.returncode==0,(name,r.stdout[-6000:]);return r.stdout
def race(name,bodies):
 barrier=Barrier(len(bodies))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10)
  r=subprocess.run([*RACE,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  (OUT/f'{name}-{i}.log').write_text(r.stdout);return{'exit':r.returncode,'output':r.stdout}
 with ThreadPoolExecutor(max_workers=len(bodies))as pool:return list(pool.map(call,enumerate(bodies)))
base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')];helpers=base[base.index('create function pg_temp.paid_clip'):base.index('insert into auth.users')]
fixture='begin;\n'+FIX.read_text()[:FIX.read_text().index('create function pg_temp.recipe')]+helpers+'\n'+seed+'\n'+FIX.read_text()[FIX.read_text().index('create function pg_temp.recipe'):]
def shifted(text,prefix):
 # Disjoint identities for committed history: the fixtures reuse the originals.
 out=text
 for old,new in [("'f1100000-","'f1%s10000-"),("'f1300000-","'f1%s30000-"),("'f1700000-","'f1%s70000-"),("'f3700000-","'f3%s70000-"),("'f3800000-","'f3%s80000-")]:out=out.replace(old,new%prefix)
 out=out.replace("'bg-photo:'","'bg-history-%s-photo:'"%prefix).replace("'background-owner@fixture.invalid'","'history-%s-owner@fixture.invalid'"%prefix).replace("'background-other@fixture.invalid'","'history-%s-other@fixture.invalid'"%prefix)
 assert 'background-'not in out and "'bg-photo:'"not in out and "'f1100000-"not in out and out!=text,'History identities must be disjoint from the fixtures'
 return out
# (1) One paid shot under a live quality-review lease and one pending shot.
HISTORY_OPERATION='f1970000-0000-4000-8000-000000000001'
HISTORY=('begin;\n'+helpers+'\n'+shifted(seed,'9')+"""
reset role;update listings set status='draft'where id=(select listing from bf);update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';
create temporary table hm as select jsonb_set(jsonb_set(m,'{sources}',(select jsonb_agg(value order by ord)from jsonb_array_elements(m->'sources')with ordinality e(value,ord)where ord<=2)),'{presentation,shot_labels}','[null,null]'::jsonb)m from bm;grant select on hm to service_role;
set local role service_role;
create temporary table hj as select(property_video_job_enqueue((select actor from bf),(select m from hm))).*;
select pg_temp.paid_clip(property_video_job_claim((select id from hj),'slot-0'));
reset role;commit;""")
assert HISTORY_OPERATION in HISTORY
HISTORY_IDS="select jsonb_build_object('job',s.job_id,'lease',s.lease_token,'attempt',s.attempt_id,'state',s.state)from public.property_video_jobs j join public.property_video_job_sources s on s.job_id=j.id and s.position=0 where j.operation_id='%s'"%HISTORY_OPERATION
# (2) A job whose assembly recovery began (snapshot recorded) before the migration:
# its next claim compares property_video_compose_snapshot() with that record.
compose_text=COMPOSE.read_text();cut=compose_text.index('\n',compose_text.index('create temporary table cj as'))+1
COMPOSE_OPERATION='f3880000-0000-4000-8000-000000009001'
COMPOSE_HISTORY=shifted(compose_text[:cut],'8')+"reset role;set local role service_role;select 'resumed:'||(property_video_job_resume((select actor from bf),(select id from cj),0)).state;reset role;commit;"
assert "'f3880000-0000-4000-8000-'||lpad(i::text,12,'0')" in COMPOSE_HISTORY and 'ready_recipe(9001)'in COMPOSE_HISTORY and COMPOSE_HISTORY.lstrip().startswith('\\set ON_ERROR_STOP on\nbegin;')
COMPOSE_JOB="(select id from public.property_video_jobs where operation_id='%s')"%COMPOSE_OPERATION
COMPOSE_STATE="select jsonb_build_object('state',state,'recoveries',compose_recoveries,'recorded',compose_recovery_history#>>'{0,sources_sha256}')from public.property_video_jobs where id=%s"%COMPOSE_JOB
COMPOSE_CLAIM="set role service_role;select jsonb_build_object('action',property_video_job_claim(%s,'slot-0')->>'action');"%COMPOSE_JOB
# Owned data and socket directories exist only once every source check above passed.
DATA=Path(tempfile.mkdtemp(prefix='temporal-verdict-owned-pg-',dir='/Volumes/Rendprop Files/Builds/Active' if Path('/Volumes/Rendprop Files/Builds/Active').is_dir()else None));SOCK=Path(tempfile.mkdtemp(prefix='temporal-verdict-socket-',dir='/tmp'))
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55633 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55633','-U','postgres'];run('createdb',[tool('createdb'),*conn,'temporal_verdict_proof'])
 psql_for=lambda db:[tool('psql'),'-X','--no-password',*conn,'-d',db,'-v','ON_ERROR_STOP=1']
 PSQL=psql_for('temporal_verdict_proof')
 def q(name,sql,db_psql=None):
  out=run(name,[*(db_psql or PSQL),'-Atq'],sql).strip();return json.loads(out)if out else None
 def catalog(name,db_psql=None):return{'functions':q(name+'-functions',FUNCS,db_psql),'tables':q(name+'-tables',TABLES,db_psql),
  'sources':q(name+'-sources-relation',SHAPE%{'r':SOURCES_REL},db_psql),'verdicts':q(name+'-verdict-relation',SHAPE%{'r':REL},db_psql)}
 # Every existing property-video row, whole (row_to_json), plus money/provenance counts.
 DATA_SNAPSHOT=("select jsonb_build_object('sources',(select md5(string_agg(md5(row_to_json(s)::text),','order by job_id,position))from public.property_video_job_sources s),'source_rows',(select count(*)from public.property_video_job_sources),"
  "'jobs',(select md5(string_agg(md5(row_to_json(j)::text),','order by id))from public.property_video_jobs j),'provenance',(select count(*)from public.media_provenance),'ledger',(select count(*)from public.cost_ledger),'reservations',(select count(*)from public.app_video_cost_reservations))")
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in MIGRATIONS[:OWN_INDEX]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 # ── committed history at the predecessor schema ─────────────────────────────
 run('seed-history',[*PSQL,'-Atq'],HISTORY);out=run('seed-compose-history',[*PSQL,'-Atq'],COMPOSE_HISTORY);assert 'resumed:generating'in out,out
 pre=catalog('before-own');history=q('history-ids',HISTORY_IDS);assert history and history['state']=='quality_review','Seeded history needs a paid shot under review'
 compose_before=q('compose-history-state',COMPOSE_STATE);assert compose_before['recoveries']==1 and compose_before['state']=='generating'and len(compose_before['recorded'])==64,compose_before
 assert pre['verdicts']['columns']is None and 'property_video_job_temporal_verdicts'not in pre['tables']
 hist0=q('history-snapshot-before-own',DATA_SNAPSHOT);assert hist0['source_rows']>=5,hist0
 run('clone-compose-baseline',[tool('createdb'),*conn,'-T','temporal_verdict_proof','temporal_compose_baseline'])
 baseline=q('compose-claim-without-migration',COMPOSE_CLAIM,psql_for('temporal_compose_baseline'));assert baseline=={'action':'compose'},baseline
 run('drop-compose-baseline',[tool('dropdb'),*conn,'temporal_compose_baseline'])
 # ── first apply ───────────────────────────────────────────────────────────────
 run('apply-'+MIG.stem,[*PSQL,'-q','-1','-f',MIG])
 after=catalog('after-own-first-apply')
 changed={k for k,v in pre['functions'].items()if after['functions'].get(k)!=v};added=set(after['functions'])-set(pre['functions']);dropped=set(pre['functions'])-set(after['functions'])
 assert not changed and added==ADDED and not dropped,('Own migration touched other functions',sorted(changed),sorted(added),sorted(dropped))
 assert sorted(set(after['tables'])-set(pre['tables']))==['property_video_job_temporal_verdicts']and set(pre['tables'])<=set(after['tables']),'Own migration adds exactly one relation'
 s0,s1=pre['sources'],after['sources'];assert {k:v for k,v in s1.items()if k!='referenced_by'}=={k:v for k,v in s0.items()if k!='referenced_by'},'The shot table keeps its exact shape, constraints, triggers, policies, ACL and RLS'
 assert sorted(set(s1['referenced_by']or[])-set(s0['referenced_by']or[]))==['property_video_job_temporal_verdicts.property_video_job_temporal_verdicts_source_fkey'],'Only the new verdict key references the shot table'
 v=after['verdicts']
 assert v['columns']==['job_id uuid not null','position integer not null','attempt_id uuid not null','limits_sha256 text not null','record jsonb not null','recorded_at timestamp with time zone not null default now()'],v['columns']
 assert v['constraints']==["property_video_job_temporal_verdicts_limits_check: CHECK ((limits_sha256 ~ '^[a-f0-9]{64}$'::text))",'property_video_job_temporal_verdicts_pkey: PRIMARY KEY (job_id, "position", attempt_id, limits_sha256)',
  "property_video_job_temporal_verdicts_record_check: CHECK (((jsonb_typeof(record) = 'object'::text) AND ((record ->> 'attempt_id'::text) = (attempt_id)::text) AND ((record #>> '{limits,sha256}'::text[]) = limits_sha256)))",
  'property_video_job_temporal_verdicts_source_fkey: FOREIGN KEY (job_id, "position") REFERENCES property_video_job_sources(job_id, "position") ON DELETE CASCADE'],v['constraints']
 assert v['triggers']==['property_video_temporal_verdict_guard O CREATE TRIGGER property_video_temporal_verdict_guard BEFORE UPDATE ON public.property_video_job_temporal_verdicts FOR EACH ROW EXECUTE FUNCTION property_video_temporal_verdict_guard()'],v['triggers']
 assert v['indexes']==['CREATE UNIQUE INDEX property_video_job_temporal_verdicts_pkey ON public.property_video_job_temporal_verdicts USING btree (job_id, "position", attempt_id, limits_sha256)']and v['policies']==[]and v['rls']is True and v['force_rls']is False and v['owner']=='postgres'and v['referenced_by']is None,v
 # PostgreSQL 17 adds MAINTAIN (`m`) to the table owner's default ACL.
 # Pin the complete ACL for the server version; service_role remains SELECT-only.
 maintain='m' if q('server-version-for-verdict-acl',"select current_setting('server_version_num')::int")>=170000 else ''
 assert v['acl']=='{postgres=arwdDxt%s/postgres,service_role=r/postgres}'%maintain,v['acl']
 assert q('history-snapshot-after-own',DATA_SNAPSHOT)==hist0,'No historical DML: every existing row byte-identical'
 receipt['firstApply']={'changedFunctions':[],'addedFunctions':sorted(added),'addedRelation':REL,'shotTableShapeUnchanged':True,'historyIdentical':True}
 # ── immediate own replay ──────────────────────────────────────────────────────
 run('own-replay',[*PSQL,'-q','-1','-f',MIG])
 assert catalog('after-own-replay')==after and q('history-snapshot-after-replay',DATA_SNAPSHOT)==hist0,'Unchanged own replay must be a no-op'
 receipt['ownReplayNoop']=True
 # ── client ACL / RLS ──────────────────────────────────────────────────────────
 acl=q('client-acl',"select jsonb_build_object('rls',(select relrowsecurity from pg_class where oid='%(r)s'::regclass),'policies',(select count(*)from pg_policy where polrelid='%(r)s'::regclass),"
  "'client_table',(select bool_or(has_table_privilege(r,'%(r)s',p))from unnest(array['anon','authenticated'])r,unnest(array['select','insert','update','delete','truncate','references','trigger'])p),"
  "'client_columns',(select bool_or(has_any_column_privilege(r,'%(r)s',p))from unnest(array['anon','authenticated'])r,unnest(array['select','insert','update','references'])p),"
  "'service_writes',(select bool_or(has_table_privilege('service_role','%(r)s',p))from unnest(array['insert','update','delete','truncate','references','trigger'])p),'service_read',has_table_privilege('service_role','%(r)s','select'),"
  "'client_functions',(select bool_or(has_function_privilege(r,f,'execute'))from unnest(array['anon','authenticated'])r,unnest(array['%(rpc)s','%(guard)s'])f),"
  "'public_execute',(select bool_or(a.grantee=0)from pg_proc p,aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where p.oid in('%(rpc)s'::regprocedure,'%(guard)s'::regprocedure)),"
  "'service_rpc',has_function_privilege('service_role','%(rpc)s','execute'))"%{'r':REL,'rpc':RPC,'guard':GUARD})
 assert acl=={'rls':True,'policies':0,'client_table':False,'client_columns':False,'service_writes':False,'service_read':True,'client_functions':False,'public_execute':False,'service_rpc':True},acl
 run('authenticated-cannot-read-verdicts',[*PSQL,'-Atq'],'set role authenticated;select record from %s limit 1;'%REL,refuses='permission denied for table property_video_job_temporal_verdicts')
 run('anon-cannot-record',[*PSQL,'-Atq'],"set role anon;select %s(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),repeat('e',64),'{}');"%RPC.split('(')[0],refuses='permission denied for function property_video_job_temporal')
 run('authenticated-cannot-record',[*PSQL,'-Atq'],"set role authenticated;select %s(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),repeat('e',64),'{}');"%RPC.split('(')[0],refuses='permission denied for function property_video_job_temporal')
 run('owner-session-needs-service-role',[*PSQL,'-Atq'],"select %s(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),repeat('e',64),'{}');"%RPC.split('(')[0],refuses='insufficient_privilege')
 receipt['clientAccess']=acl
 # ── a recorded verdict writes only its own verdict row ───────────────────────
 report="jsonb_build_object('profile','temporal-motion-v2','limits',jsonb_build_object('profile','temporal-motion-v2','sha256',repeat('1',64)),'metrics',jsonb_build_object('profile','temporal-motion-v2','fps',24),'verdict',jsonb_build_object('profile','temporal-motion-v2','pass',false,'reasons',jsonb_build_array('vertical_bob')))"
 recorded=q('record-history-verdict',"set role service_role;select %s('%s','%s','%s',repeat('e',64),%s);"%(RPC.split('(')[0],history['job'],history['lease'],history['attempt'],report))
 assert recorded['attempt_id']==history['attempt']and recorded['verdict']['reasons']==['vertical_bob'],recorded
 assert q('history-snapshot-after-record',DATA_SNAPSHOT)==hist0,'Recording a verdict changes no shot, job, lease, receipt, clip, provenance or cost row'
 VERDICTS="select coalesce(jsonb_agg(jsonb_build_array(job_id,\"position\",attempt_id,limits_sha256,record,recorded_at)order by job_id,\"position\",attempt_id,limits_sha256),'[]')from %s"%REL
 verdict_rows=q('verdict-rows',VERDICTS);assert len(verdict_rows)==1 and verdict_rows[0][4]==recorded,verdict_rows
 # ── the recorded assembly snapshot still matches after the migration ─────────
 assert q('compose-history-after-own',COMPOSE_STATE)==compose_before
 run('clone-compose-after',[tool('createdb'),*conn,'-T','temporal_verdict_proof','temporal_compose_after'])
 resumed=q('compose-claim-after-migration',COMPOSE_CLAIM,psql_for('temporal_compose_after'));assert resumed=={'action':'compose'},('A job in assembly recovery must keep composing after the migration',resumed)
 run('drop-compose-after',[tool('dropdb'),*conn,'temporal_compose_after'])
 # Negative control: a column on the shot table (what this migration avoids) changes
 # every whole-row snapshot, so the same job would be sent to needs_reconciliation.
 run('clone-compose-hazard',[tool('createdb'),*conn,'-T','temporal_verdict_proof','temporal_compose_hazard']);HZ=psql_for('temporal_compose_hazard')
 run('compose-hazard-column',[*HZ,'-Atq'],'alter table %s add column hazard jsonb;'%SOURCES_REL)
 hazard=q('compose-claim-with-shot-column',COMPOSE_CLAIM,HZ);hazard_state=q('compose-state-with-shot-column',COMPOSE_STATE,HZ)
 assert hazard=={'action':'done'}and hazard_state['state']=='needs_reconciliation',('Control must reproduce the snapshot hazard',hazard,hazard_state)
 run('drop-compose-hazard',[tool('dropdb'),*conn,'temporal_compose_hazard'])
 receipt['assemblyRecoverySnapshot']={'recordedBeforeMigration':compose_before['recorded'],'claimWithoutMigration':'compose','claimAfterMigration':'compose','negativeControlShotColumn':'needs_reconciliation'}
 # ── unknown same-name objects are refused; refusals change nothing ───────────
 rpc_def=run('read-rpc',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%RPC]).rstrip('\n');guard_def=run('read-guard',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%GUARD]).rstrip('\n')
 RPC_ANCHOR=' perform public.property_video_job_worker_scope(';GUARD_ANCHOR=" raise exception'RP409: A recorded temporal verdict is immutable';"
 assert rpc_def.count(RPC_ANCHOR)==1 and guard_def.count(GUARD_ANCHOR)==1
 HELPER='Review changed temporal verdict helper: ';RELATION='Review changed temporal verdict relation: public.property_video_job_temporal_verdicts';PARTIAL='Review partial or unknown temporal verdict objects'
 def control(name,mutate,restore,oracle):
  prior=catalog('control-'+name+'-before');run('control-'+name+'-mutate',[*PSQL,'-Atq'],mutate)
  mutated=catalog('control-'+name+'-mutated');assert mutated!=prior,'Control must actually change the catalog: '+name
  run('control-'+name+'-replay',[*PSQL,'-q','-1','-f',MIG],refuses=oracle)
  assert catalog('control-'+name+'-after-refusal')==mutated and q('control-'+name+'-history',DATA_SNAPSHOT)==hist0 and q('control-'+name+'-verdicts',VERDICTS)==verdict_rows,'A refused replay must not mutate anything: '+name
  run('control-'+name+'-restore',[*PSQL,'-Atq'],restore)
  assert catalog('control-'+name+'-restored')==after,'Restore must return the exact first-apply catalog: '+name
  receipt['replayControls'].append({'name':name,'actualCompiledSQL':True,'refusal':oracle,'catalogAndRowsUnchangedOnRefusal':True})
 G={'r':REL,'g':GUARD}
 control('changed-rpc-body',rpc_def.replace(RPC_ANCHOR,' -- unknown privileged body\n'+RPC_ANCHOR,1)+';',rpc_def+';',HELPER+RPC)
 control('changed-guard-body',guard_def.replace(GUARD_ANCHOR,' -- unknown guard body\n'+GUARD_ANCHOR,1)+';',guard_def+';',HELPER+GUARD)
 control('rpc-execute-widened','grant execute on function %s to authenticated;'%RPC,'revoke execute on function %s from authenticated;'%RPC,HELPER+RPC)
 control('rpc-security-invoker','alter function %s security invoker;'%RPC,'alter function %s security definer;'%RPC,HELPER+RPC)
 control('rpc-search-path-dropped','alter function %s reset search_path;'%RPC,"alter function %s set search_path='';"%RPC,HELPER+RPC)
 control('unknown-overload',"create function public.property_video_job_temporal(p_job text)returns jsonb language sql as $$select null::jsonb$$;",'drop function public.property_video_job_temporal(text);',PARTIAL)
 control('extra-column','alter table %(r)s add column extra integer;'%G,'alter table %(r)s drop column extra;'%G,RELATION)
 control('client-select-grant','grant select on %(r)s to authenticated;'%G,'revoke select on %(r)s from authenticated;'%G,RELATION)
 control('client-column-grant','grant select(record) on %(r)s to authenticated;'%G,'revoke select(record) on %(r)s from authenticated;'%G,RELATION)
 control('service-write-grant','grant insert,update on %(r)s to service_role;'%G,'revoke insert,update on %(r)s from service_role;'%G,RELATION)
 control('added-policy','create policy unknown_open on %(r)s for select using(true);'%G,'drop policy unknown_open on %(r)s;'%G,RELATION)
 control('disabled-rls','alter table %(r)s disable row level security;'%G,'alter table %(r)s enable row level security;'%G,RELATION)
 control('weakened-record-check','alter table %(r)s drop constraint property_video_job_temporal_verdicts_record_check;alter table %(r)s add constraint property_video_job_temporal_verdicts_record_check check(true);'%G,
  "alter table %(r)s drop constraint property_video_job_temporal_verdicts_record_check;alter table %(r)s add constraint property_video_job_temporal_verdicts_record_check check(jsonb_typeof(record)='object'and record->>'attempt_id'=attempt_id::text and record#>>'{limits,sha256}'=limits_sha256);"%G,RELATION)
 control('extra-index','create index temporal_unknown_index on %(r)s(recorded_at);'%G,'drop index public.temporal_unknown_index;',RELATION)
 control('disabled-guard-trigger','alter table %(r)s disable trigger property_video_temporal_verdict_guard;'%G,'alter table %(r)s enable trigger property_video_temporal_verdict_guard;'%G,RELATION)
 control('widened-guard-trigger','drop trigger property_video_temporal_verdict_guard on %(r)s;create trigger property_video_temporal_verdict_guard before update or delete on %(r)s for each row execute function %(g)s;'%G,
  'drop trigger property_video_temporal_verdict_guard on %(r)s;create trigger property_video_temporal_verdict_guard before update on %(r)s for each row execute function %(g)s;'%G,RELATION)
 control('missing-guard-trigger','drop trigger property_video_temporal_verdict_guard on %(r)s;'%G,'create trigger property_video_temporal_verdict_guard before update on %(r)s for each row execute function %(g)s;'%G,PARTIAL)
 run('own-replay-after-controls',[*PSQL,'-q','-1','-f',MIG])
 assert catalog('after-final-replay')==after and q('history-snapshot-after-controls',DATA_SNAPSHOT)==hist0 and q('verdicts-after-controls',VERDICTS)==verdict_rows,'Final own replay must be a no-op'
 # ── operator rollback, proven in a clone taken at this own boundary ─────────
 run('clone-for-rollback',[tool('createdb'),*conn,'-T','temporal_verdict_proof','temporal_rollback_proof'])
 RB=psql_for('temporal_rollback_proof')
 prior=catalog('rollback-control-before',RB);run('rollback-control-mutate',[*RB,'-Atq'],rpc_def.replace(RPC_ANCHOR,' -- unknown privileged body\n'+RPC_ANCHOR,1)+';')
 mutated=catalog('rollback-control-mutated',RB);assert mutated!=prior
 run('rollback-refuses-changed-object',[*RB,'-q','-f',ROLLBACK],refuses='PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: '+RPC+" differs from the migration's own. Nothing changed.")
 assert catalog('rollback-control-after-refusal',RB)==mutated and q('rollback-control-history',DATA_SNAPSHOT,RB)==hist0 and q('rollback-control-verdicts',VERDICTS,RB)==verdict_rows,'A refused rollback changes nothing'
 run('rollback-control-restore',[*RB,'-Atq'],rpc_def+';');assert catalog('rollback-control-restored',RB)==after
 out=run('rollback',[*RB,'-q','-f',ROLLBACK]);assert 'PROPERTY-VIDEO-TEMPORAL-ROLLBACK done'in out and 'discarded 1 recorded temporal verdicts'in out,out
 assert catalog('after-rollback',RB)==pre,'Rollback must restore the exact predecessor catalog'
 assert q('history-snapshot-after-rollback',DATA_SNAPSHOT,RB)==hist0,'Rollback leaves every existing row untouched'
 out=run('rollback-again',[*RB,'-q','-f',ROLLBACK]);assert 'nothing to roll back'in out and catalog('after-second-rollback',RB)==pre,'A second rollback is a no-op'
 run('reapply-after-rollback',[*RB,'-q','-1','-f',MIG]);assert catalog('after-reapply',RB)==after,'The migration re-applies cleanly after a rollback'
 assert q('reapply-verdicts',VERDICTS,RB)==[]and q('history-snapshot-after-reapply',DATA_SNAPSHOT,RB)==hist0
 run('replay-after-reapply',[*RB,'-q','-1','-f',MIG]);assert catalog('after-reapply-replay',RB)==after
 receipt['rollback']={'path':str(ROLLBACK.relative_to(ROOT)),'refusedChangedObject':True,'exactPredecessorCatalog':True,'rowsUntouched':True,'discardedVerdicts':1,'idempotent':True,'reapplied':True}
 run('drop-rollback-clone',[tool('dropdb'),*conn,'temporal_rollback_proof'])
 # ── remaining chronology, then the actual fixture ─────────────────────────────
 for m in (m for m in partition_fresh_migrations(MIGRATIONS)[0] if m.name>MIG.name):run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 head=catalog('catalog-head')
 for stage in ['fresh','replay']:
  out=run(stage+'-actual-temporal',[*PSQL,'-Atq'],fixture);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 assert receipt['fresh']['assertions']==receipt['replay']['assertions'],'Fresh and replayed fixture runs must agree'
 # The existing paid-retry and background-job authority is untouched by the new table, trigger and RPC.
 baseline=run('existing-derived-retry',[*PSQL,'-Atq','-f',DERIVED]);receipt['existingDerivedRetryRegression']=next(json.loads(x)for x in baseline.splitlines()if x.startswith('{')and'assertions'in x)
 FIRST_WINS=(RPC,"if rec is not null then return rec;end if;","")
 PKEY=('alter table %(r)s drop constraint property_video_job_temporal_verdicts_pkey;'%G,'alter table %(r)s add constraint property_video_job_temporal_verdicts_pkey primary key(job_id,position,attempt_id,limits_sha256);'%G)
 RECORD_CHECK=('alter table %(r)s drop constraint property_video_job_temporal_verdicts_record_check;alter table %(r)s add constraint property_video_job_temporal_verdicts_record_check check(true);'%G,
  "alter table %(r)s drop constraint property_video_job_temporal_verdicts_record_check;alter table %(r)s add constraint property_video_job_temporal_verdicts_record_check check(jsonb_typeof(record)='object'and record->>'attempt_id'=attempt_id::text and record#>>'{limits,sha256}'=limits_sha256);"%G)
 NO_CASCADE=('alter table %(r)s drop constraint property_video_job_temporal_verdicts_source_fkey;alter table %(r)s add constraint property_video_job_temporal_verdicts_source_fkey foreign key(job_id,position)references public.property_video_job_sources(job_id,position);'%G,
  'alter table %(r)s drop constraint property_video_job_temporal_verdicts_source_fkey;alter table %(r)s add constraint property_video_job_temporal_verdicts_source_fkey foreign key(job_id,position)references public.property_video_job_sources(job_id,position)on delete cascade;'%G)
 for label,mutations,sql_mutations,oracle in [
  ('clip-identity',[(RPC,"or p_clip_sha256 is distinct from s.clip->>'sha256'",'')],[],'wrong clip sha refused'),
  # Without the RPC's first-wins return the key alone still refuses a second record.
  ('first-wins-rpc-only-backstopped-by-key',[FIRST_WINS],[],'duplicate key value violates unique constraint "property_video_job_temporal_verdicts_pkey"'),
  ('first-wins-both-layers',[FIRST_WINS],[PKEY],'first recorded verdict wins'),
  ('immutable',[(GUARD,"raise exception'RP409: A recorded temporal verdict is immutable';","return new;")],[],'direct edit of a recorded verdict refused'),
  ('record-identity-check',[],[RECORD_CHECK],'a record must name its own attempt and limit version'),
  ('erasure-cascade',[],[NO_CASCADE],'violates foreign key constraint "property_video_job_temporal_verdicts_source_fkey"')]:
  originals={s:run('read-'+label+'-'+s.split('(')[0].split('.')[1],[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%s])for s in dict.fromkeys(m[0]for m in mutations)}
  mutated=dict(originals)
  for signature,anchor,replacement in mutations:assert mutated[signature].count(anchor)==1,(label,'exact production anchor');mutated[signature]=mutated[signature].replace(anchor,replacement,1)
  for s in mutated:run('compile-'+label+'-'+s.split('(')[0].split('.')[1],[*PSQL,'-Atq'],mutated[s])
  for i,(mutate,_)in enumerate(sql_mutations):run('mutate-'+label+'-'+str(i),[*PSQL,'-Atq'],mutate)
  run('negative-'+label,[*PSQL,'-Atq'],fixture,refuses=oracle)
  for i,(_,restore)in enumerate(sql_mutations):run('restore-'+label+'-'+str(i),[*PSQL,'-Atq'],restore)
  for s in originals:run('restore-'+label+'-'+s.split('(')[0].split('.')[1],[*PSQL,'-Atq'],originals[s])
  assert catalog('catalog-after-'+label)==head,'Control restoration must preserve the head catalog: '+label
  receipt['controls'].append({'name':label,'functionMutations':len(mutations),'sqlMutations':len(sql_mutations),'compiledActualSQL':True,'unsafeMutationRejected':True,'oracle':oracle})
 # ── race: two first writes with different reports for the same live attempt ──
 run('clone-for-race',[tool('createdb'),*conn,'-T','temporal_verdict_proof','temporal_race_proof']);RACE=psql_for('temporal_race_proof')
 setup=fixture[:fixture.index('-- Closed report shape and clip identity.')].replace('set local ','set ')
 setup+="reset role;create table public.temporal_race as select job,lease,attempt from rv_ids;grant select on public.temporal_race to service_role;commit;"
 run('race-setup',[*RACE,'-Atq'],setup)
 statement=lambda reasons:"select (property_video_job_temporal(job,lease,attempt,repeat('e',64),public.temporal_race_report('{%s}')))->'verdict' from public.temporal_race;"%reasons
 run('race-report-helper',[*RACE,'-Atq'],"create or replace function public.temporal_race_report(reasons text[])returns jsonb language sql as $$select jsonb_build_object('profile','temporal-motion-v2','limits',jsonb_build_object('profile','temporal-motion-v2','sha256',repeat('1',64)),'metrics',jsonb_build_object('profile','temporal-motion-v2','fps',24),'verdict',jsonb_build_object('profile','temporal-motion-v2','pass',cardinality(reasons)=0,'reasons',to_jsonb(reasons)))$$;grant execute on function public.temporal_race_report(text[])to service_role;")
 results=race('same-attempt-first-write',[statement('vertical_bob'),statement('')]);assert all(x['exit']==0 for x in results),results
 verdicts={x['output'].strip()for x in results};assert len(verdicts)==1,('both callers must read the one recorded verdict',results)
 stored=run('race-stored',[*RACE,'-Atq','-c',"select count(*)||':'||max((v.record->'verdict')::text) from %s v join public.temporal_race r on v.job_id=r.job and v.attempt_id=r.attempt;"%REL]).strip()
 assert stored.split(':',1)[0]=='1' and stored.split(':',1)[1]==next(iter(verdicts)),stored
 receipt['races'].append({'name':'same-attempt-first-write','requests':2,'oneRecord':True,'supplierPOSTs':0})
 run('drop-race-clone',[tool('dropdb'),*conn,'temporal_race_proof'])
 assert hashes()==receipt['sourceHashes'],'Source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':receipt['fresh']['assertions'],'replayAssertions':receipt['replay']['assertions'],'replayControls':len(receipt['replayControls']),'controls':len(receipt['controls']),'races':len(receipt['races']),'rollback':True,'assemblyRecoverySnapshot':'kept','derivedRetryAssertions':receipt['existingDerivedRetryRegression'].get('assertions'),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or not (DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
