#!/usr/bin/env python3
"""Actual isolated PG proof of recorded temporal motion verdicts
(20261017191000_property_video_temporal_verdict.sql).

Chronology: bootstrap, every migration before the own one, committed property-
video history at the predecessor schema, first apply (exact catalog delta, no
historical DML), immediate own replay (no-op), refused unknown same-name
objects (catalog and rows unchanged by every refusal), client ACL/RLS, a
recorded verdict that writes nothing else, the operator rollback in a clone of
that database (exact predecessor catalog, untouched rows, refused changed
object, idempotent rerun, clean re-apply), the remaining migrations, then the
actual SQL fixture fresh and replayed, existing paid-retry regression, compiled
defect controls and a two-writer first-record race in a clone. No production
connection, media, model, provider or network: Unix-socket PostgreSQL only.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='temporal-verdict-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='temporal-verdict-owned-pg-',dir='/Volumes/Rendprop Files/Builds/Active' if Path('/Volumes/Rendprop Files/Builds/Active').is_dir()else None));SOCK=Path(tempfile.mkdtemp(prefix='temporal-verdict-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
OWN='20261017191000_property_video_temporal_verdict.sql'
MIG=SQL/'migrations'/OWN;FIX=SQL/'tests/property_video_temporal.sql';BASE=SQL/'tests/property_video_jobs.sql';DERIVED=SQL/'tests/property_video_derived_retry.sql'
ROLLBACK=ROOT/'docs/handoff/PROPERTY-VIDEO-TEMPORAL-ROLLBACK.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));assert MIGRATIONS.count(MIG)==1,'Own migration required';OWN_INDEX=MIGRATIONS.index(MIG)
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',BASE,FIX,DERIVED,ROLLBACK,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'scope':'disposable actual PostgreSQL/schema/roles/concurrency, synthetic receipts only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'replayControls':[],'controls':[],'races':[]}
RPC='public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)';GUARD='public.property_video_temporal_guard()';REL='public.property_video_job_sources'
ADDED={'property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','property_video_temporal_guard()'}
# One digest per public function (definition, owner, ACL, security, config) and
# the exact shape of the one relation this migration touches.
FUNCS="select coalesce(jsonb_object_agg(oid::regprocedure::text,md5(pg_get_functiondef(oid)||pg_get_userbyid(proowner)||coalesce(proacl::text,'')||prosecdef::text||coalesce(proconfig::text,''))),'{}')from pg_proc where pronamespace='public'::regnamespace and prokind='f'"
TABLES="select coalesce(jsonb_agg(relname::text order by relname),'[]')from pg_class where relnamespace='public'::regnamespace and relkind in('r','v','m','p')"
SHAPE=("select jsonb_build_object("
 "'columns',(select jsonb_agg(a.attname||' '||format_type(a.atttypid,a.atttypmod)||case when a.attnotnull then' not null'else''end||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),'')||coalesce(' acl '||a.attacl::text,'')order by a.attnum)from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where a.attrelid='%(r)s'::regclass and a.attnum>0 and not a.attisdropped),"
 "'constraints',(select jsonb_agg(conname||': '||pg_get_constraintdef(oid)order by conname)from pg_constraint where conrelid='%(r)s'::regclass),"
 "'indexes',(select jsonb_agg(pg_get_indexdef(indexrelid)order by indexrelid::regclass::text)from pg_index where indrelid='%(r)s'::regclass),"
 "'triggers',(select jsonb_agg(tgname||' '||tgenabled::text||' '||pg_get_triggerdef(oid)order by tgname)from pg_trigger where tgrelid='%(r)s'::regclass and not tgisinternal),"
 "'policies',(select coalesce(jsonb_agg(polname||' '||polcmd::text||' '||coalesce(pg_get_expr(polqual,polrelid),'')order by polname),'[]')from pg_policy where polrelid='%(r)s'::regclass),"
 "'acl',(select relacl::text from pg_class where oid='%(r)s'::regclass),'owner',(select pg_get_userbyid(relowner)from pg_class where oid='%(r)s'::regclass),"
 "'rls',(select relrowsecurity from pg_class where oid='%(r)s'::regclass),'force_rls',(select relforcerowsecurity from pg_class where oid='%(r)s'::regclass))")%{'r':REL}
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
# Committed history at the PREDECESSOR schema, with identities disjoint from the
# fixture's: one paid shot under a live quality-review lease and one pending shot.
HISTORY_OPERATION='f1970000-0000-4000-8000-000000000001'
history_seed=(seed.replace("'f1100000-","'f1910000-").replace("'f1300000-","'f1930000-").replace("'f1700000-","'f1970000-").replace("'bg-photo:'","'bg-history-photo:'")
 .replace("'background-owner@fixture.invalid'","'history-owner@fixture.invalid'").replace("'background-other@fixture.invalid'","'history-other@fixture.invalid'"))
assert history_seed.count("'f1910000-")>=2 and history_seed.count("'bg-history-photo:'")==2 and HISTORY_OPERATION in history_seed and 'background-'not in history_seed,'History identities must be disjoint from the fixture'
HISTORY=('begin;\n'+helpers+'\n'+history_seed+"""
reset role;update listings set status='draft'where id=(select listing from bf);update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';
create temporary table hm as select jsonb_set(jsonb_set(m,'{sources}',(select jsonb_agg(value order by ord)from jsonb_array_elements(m->'sources')with ordinality e(value,ord)where ord<=2)),'{presentation,shot_labels}','[null,null]'::jsonb)m from bm;grant select on hm to service_role;
set local role service_role;
create temporary table hj as select(property_video_job_enqueue((select actor from bf),(select m from hm))).*;
select pg_temp.paid_clip(property_video_job_claim((select id from hj),'slot-0'));
reset role;commit;""")
HISTORY_IDS="select jsonb_build_object('job',s.job_id,'lease',s.lease_token,'attempt',s.attempt_id,'state',s.state)from public.property_video_jobs j join public.property_video_job_sources s on s.job_id=j.id and s.position=0 where j.operation_id='%s'"%HISTORY_OPERATION
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55633 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55633','-U','postgres'];run('createdb',[tool('createdb'),*conn,'temporal_verdict_proof'])
 psql_for=lambda db:[tool('psql'),'-X','--no-password',*conn,'-d',db,'-v','ON_ERROR_STOP=1']
 PSQL=psql_for('temporal_verdict_proof')
 def q(name,sql,db_psql=None):
  out=run(name,[*(db_psql or PSQL),'-Atq'],sql).strip();return json.loads(out)if out else None
 def catalog(name,db_psql=None):return{'functions':q(name+'-functions',FUNCS,db_psql),'tables':q(name+'-tables',TABLES,db_psql),'relation':q(name+'-relation',SHAPE,db_psql)}
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in MIGRATIONS[:OWN_INDEX]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 # ── committed history at the predecessor schema ─────────────────────────────
 run('seed-history',[*PSQL,'-Atq'],HISTORY)
 pre=catalog('before-own');history=q('history-ids',HISTORY_IDS);assert history and history['state']=='quality_review','Seeded history needs a paid shot under review'
 pre_columns=[c.split(' ')[0]for c in pre['relation']['columns']];assert 'temporal'not in pre_columns
 DATA_SNAPSHOT=("select jsonb_build_object('sources',(select md5(string_agg(md5(jsonb_build_array(%s)::text),','order by job_id,position))from public.property_video_job_sources),'source_rows',(select count(*)from public.property_video_job_sources),"
  "'jobs',(select md5(string_agg(md5(row_to_json(j)::text),','order by id))from public.property_video_jobs j),'provenance',(select count(*)from public.media_provenance),'ledger',(select count(*)from public.cost_ledger),'reservations',(select count(*)from public.app_video_cost_reservations))")%','.join('"%s"'%c for c in pre_columns)
 hist0=q('history-snapshot-before-own',DATA_SNAPSHOT);assert hist0['source_rows']>=2,hist0
 # ── first apply ───────────────────────────────────────────────────────────────
 run('apply-'+MIG.stem,[*PSQL,'-q','-1','-f',MIG])
 after=catalog('after-own-first-apply')
 changed={k for k,v in pre['functions'].items()if after['functions'].get(k)!=v};added=set(after['functions'])-set(pre['functions']);dropped=set(pre['functions'])-set(after['functions'])
 assert not changed and added==ADDED and not dropped,('Own migration touched other functions',sorted(changed),sorted(added),sorted(dropped))
 assert after['tables']==pre['tables'],'Own migration adds no relation'
 a,b=pre['relation'],after['relation']
 assert b['columns']==a['columns']+['temporal jsonb','temporal_history jsonb not null default \'[]\'::jsonb'],('Exactly two new columns, no column ACL',b['columns'][-3:])
 assert sorted(set(b['constraints'])-set(a['constraints']))==["property_video_job_sources_temporal_check: CHECK (((temporal IS NULL) OR (jsonb_typeof(temporal) = 'object'::text)))","property_video_job_sources_temporal_history_check: CHECK ((jsonb_typeof(temporal_history) = 'array'::text))"]and set(a['constraints'])<=set(b['constraints']),'Exactly two new CHECK constraints'
 assert set(b['triggers'])-set(a['triggers'])=={'property_video_temporal_guard O CREATE TRIGGER property_video_temporal_guard BEFORE UPDATE OF temporal, temporal_history ON public.property_video_job_sources FOR EACH ROW EXECUTE FUNCTION property_video_temporal_guard()'}and set(a['triggers'])<=set(b['triggers']),'Exactly one new guard trigger'
 assert {k:b[k]for k in['indexes','policies','acl','owner','rls','force_rls']}=={k:a[k]for k in['indexes','policies','acl','owner','rls','force_rls']},'Indexes, policies, table ACL, owner and RLS unchanged'
 assert q('history-snapshot-after-own',DATA_SNAPSHOT)==hist0,'No historical DML: existing rows byte-identical'
 assert q('history-new-columns',"select jsonb_build_object('temporal',count(*)filter(where temporal is not null),'history',count(*)filter(where temporal_history<>'[]'))from public.property_video_job_sources")=={'temporal':0,'history':0},'Existing shots start without a verdict'
 receipt['firstApply']={'changedFunctions':[],'addedFunctions':sorted(added),'addedColumns':2,'addedConstraints':2,'addedTriggers':1,'historyIdentical':True}
 # ── immediate own replay ──────────────────────────────────────────────────────
 run('own-replay',[*PSQL,'-q','-1','-f',MIG])
 assert catalog('after-own-replay')==after and q('history-snapshot-after-replay',DATA_SNAPSHOT)==hist0,'Unchanged own replay must be a no-op'
 receipt['ownReplayNoop']=True
 # ── client ACL / RLS ──────────────────────────────────────────────────────────
 acl=q('client-acl',"select jsonb_build_object('rls',(select relrowsecurity from pg_class where oid='%(r)s'::regclass),'policies',(select count(*)from pg_policy where polrelid='%(r)s'::regclass),"
  "'client_table',(select bool_or(has_table_privilege(r,'%(r)s',p))from unnest(array['anon','authenticated'])r,unnest(array['select','insert','update','delete','truncate','references','trigger'])p),"
  "'client_columns',(select bool_or(has_column_privilege(r,'%(r)s',c,p))from unnest(array['anon','authenticated'])r,unnest(array['temporal','temporal_history'])c,unnest(array['select','insert','update','references'])p),"
  "'client_functions',(select bool_or(has_function_privilege(r,f,'execute'))from unnest(array['anon','authenticated'])r,unnest(array['%(rpc)s','%(guard)s'])f),"
  "'public_execute',(select bool_or(a.grantee=0)from pg_proc p,aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where p.oid in('%(rpc)s'::regprocedure,'%(guard)s'::regprocedure)),"
  "'service_rpc',has_function_privilege('service_role','%(rpc)s','execute'))"%{'r':REL,'rpc':RPC,'guard':GUARD})
 assert acl=={'rls':True,'policies':0,'client_table':False,'client_columns':False,'client_functions':False,'public_execute':False,'service_rpc':True},acl
 run('authenticated-cannot-read-verdicts',[*PSQL,'-Atq'],'set role authenticated;select temporal from %s limit 1;'%REL,refuses='permission denied for table property_video_job_sources')
 run('anon-cannot-record',[*PSQL,'-Atq'],"set role anon;select %s(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),repeat('e',64),'{}');"%RPC.split('(')[0],refuses='permission denied for function property_video_job_temporal')
 run('authenticated-cannot-record',[*PSQL,'-Atq'],"set role authenticated;select %s(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),repeat('e',64),'{}');"%RPC.split('(')[0],refuses='permission denied for function property_video_job_temporal')
 run('owner-session-needs-service-role',[*PSQL,'-Atq'],"select %s(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),repeat('e',64),'{}');"%RPC.split('(')[0],refuses='insufficient_privilege')
 receipt['clientAccess']=acl
 # ── a recorded verdict writes only the two new columns of that shot ──────────
 report="jsonb_build_object('profile','temporal-motion-v2','limits',jsonb_build_object('profile','temporal-motion-v2','sha256',repeat('1',64)),'metrics',jsonb_build_object('profile','temporal-motion-v2','fps',24),'verdict',jsonb_build_object('profile','temporal-motion-v2','pass',false,'reasons',jsonb_build_array('vertical_bob')))"
 recorded=q('record-history-verdict',"set role service_role;select %s('%s','%s','%s',repeat('e',64),%s);"%(RPC.split('(')[0],history['job'],history['lease'],history['attempt'],report))
 assert recorded['attempt_id']==history['attempt']and recorded['verdict']['reasons']==['vertical_bob'],recorded
 assert q('history-snapshot-after-record',DATA_SNAPSHOT)==hist0,'Recording a verdict changes no state, lease, receipt, clip, provenance, cost or other column'
 assert q('history-recorded-count',"select count(*)from public.property_video_job_sources where temporal is not null")==1
 recorded_snapshot=q('verdict-snapshot',"select jsonb_build_object('temporal',jsonb_agg(temporal order by job_id,position),'history',jsonb_agg(temporal_history order by job_id,position))from public.property_video_job_sources")
 # ── unknown same-name objects are refused; refusals change nothing ───────────
 rpc_def=run('read-rpc',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%RPC]).rstrip('\n');guard_def=run('read-guard',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%GUARD]).rstrip('\n')
 assert rpc_def.count(' perform public.property_video_job_worker_scope(')==1 and guard_def.count(' for i in 0..')==1
 HELPER='Review changed temporal verdict helper: ';RELATION='Review changed temporal verdict relation objects: public.property_video_job_sources';PARTIAL='Review partial or unknown temporal verdict objects'
 def control(name,mutate,restore,oracle):
  prior=catalog('control-'+name+'-before');run('control-'+name+'-mutate',[*PSQL,'-Atq'],mutate)
  mutated=catalog('control-'+name+'-mutated');assert mutated!=prior,'Control must actually change the catalog: '+name
  run('control-'+name+'-replay',[*PSQL,'-q','-1','-f',MIG],refuses=oracle)
  assert catalog('control-'+name+'-after-refusal')==mutated and q('control-'+name+'-history',DATA_SNAPSHOT)==hist0,'A refused replay must not mutate anything: '+name
  run('control-'+name+'-restore',[*PSQL,'-Atq'],restore)
  assert catalog('control-'+name+'-restored')==after,'Restore must return the exact first-apply catalog: '+name
  receipt['replayControls'].append({'name':name,'actualCompiledSQL':True,'refusal':oracle,'catalogAndRowsUnchangedOnRefusal':True})
 control('changed-rpc-body',rpc_def.replace(' perform public.property_video_job_worker_scope(',' -- unknown privileged body\n perform public.property_video_job_worker_scope(',1)+';',rpc_def+';',HELPER+RPC)
 control('changed-guard-body',guard_def.replace(' for i in 0..',' -- unknown guard body\n for i in 0..',1)+';',guard_def+';',HELPER+GUARD)
 control('rpc-execute-widened','grant execute on function %s to authenticated;'%RPC,'revoke execute on function %s from authenticated;'%RPC,HELPER+RPC)
 control('rpc-security-invoker','alter function %s security invoker;'%RPC,'alter function %s security definer;'%RPC,HELPER+RPC)
 control('rpc-search-path-dropped','alter function %s reset search_path;'%RPC,"alter function %s set search_path='';"%RPC,HELPER+RPC)
 control('unknown-overload',"create function public.property_video_job_temporal(p_job text)returns jsonb language sql as $$select null::jsonb$$;",'drop function public.property_video_job_temporal(text);',PARTIAL)
 control('changed-history-default',"alter table %s alter column temporal_history set default '[{}]'::jsonb;"%REL,"alter table %s alter column temporal_history set default '[]'::jsonb;"%REL,RELATION)
 control('client-column-grant','grant select(temporal) on %s to authenticated;'%REL,'revoke select(temporal) on %s from authenticated;'%REL,RELATION)
 control('weakened-check',"alter table %(r)s drop constraint property_video_job_sources_temporal_check;alter table %(r)s add constraint property_video_job_sources_temporal_check check(true);"%{'r':REL},
  "alter table %(r)s drop constraint property_video_job_sources_temporal_check;alter table %(r)s add constraint property_video_job_sources_temporal_check check(temporal is null or jsonb_typeof(temporal)='object');"%{'r':REL},RELATION)
 control('disabled-guard-trigger','alter table %s disable trigger property_video_temporal_guard;'%REL,'alter table %s enable trigger property_video_temporal_guard;'%REL,RELATION)
 control('narrowed-guard-trigger','drop trigger property_video_temporal_guard on %(r)s;create trigger property_video_temporal_guard before update of temporal on %(r)s for each row execute function %(g)s;'%{'r':REL,'g':GUARD},
  'drop trigger property_video_temporal_guard on %(r)s;create trigger property_video_temporal_guard before update of temporal,temporal_history on %(r)s for each row execute function %(g)s;'%{'r':REL,'g':GUARD},RELATION)
 control('missing-guard-trigger','drop trigger property_video_temporal_guard on %s;'%REL,'create trigger property_video_temporal_guard before update of temporal,temporal_history on %s for each row execute function %s;'%(REL,GUARD),PARTIAL)
 run('own-replay-after-controls',[*PSQL,'-q','-1','-f',MIG])
 assert catalog('after-final-replay')==after and q('history-snapshot-after-controls',DATA_SNAPSHOT)==hist0,'Final own replay must be a no-op'
 assert q('verdict-snapshot-after-controls',"select jsonb_build_object('temporal',jsonb_agg(temporal order by job_id,position),'history',jsonb_agg(temporal_history order by job_id,position))from public.property_video_job_sources")==recorded_snapshot,'Controls and replays left the recorded verdict unchanged'
 # ── operator rollback, proven in a clone taken at this own boundary ─────────
 run('clone-for-rollback',[tool('createdb'),*conn,'-T','temporal_verdict_proof','temporal_rollback_proof'])
 RB=psql_for('temporal_rollback_proof')
 prior=catalog('rollback-control-before',RB);run('rollback-control-mutate',[*RB,'-Atq'],rpc_def.replace(' perform public.property_video_job_worker_scope(',' -- unknown privileged body\n perform public.property_video_job_worker_scope(',1)+';')
 mutated=catalog('rollback-control-mutated',RB);assert mutated!=prior
 run('rollback-refuses-changed-object',[*RB,'-q','-f',ROLLBACK],refuses='PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: '+RPC+" differs from the migration's own. Nothing changed.")
 assert catalog('rollback-control-after-refusal',RB)==mutated and q('rollback-control-history',DATA_SNAPSHOT,RB)==hist0,'A refused rollback changes nothing'
 run('rollback-control-restore',[*RB,'-Atq'],rpc_def+';');assert catalog('rollback-control-restored',RB)==after
 out=run('rollback',[*RB,'-q','-f',ROLLBACK]);assert 'PROPERTY-VIDEO-TEMPORAL-ROLLBACK done'in out and 'discarded 1 current and 0 archived temporal verdicts'in out,out
 assert catalog('after-rollback',RB)==pre,'Rollback must restore the exact predecessor catalog'
 assert q('history-snapshot-after-rollback',DATA_SNAPSHOT,RB)==hist0,'Rollback leaves every existing row and column untouched'
 out=run('rollback-again',[*RB,'-q','-f',ROLLBACK]);assert 'nothing to roll back'in out and catalog('after-second-rollback',RB)==pre,'A second rollback is a no-op'
 run('reapply-after-rollback',[*RB,'-q','-1','-f',MIG]);assert catalog('after-reapply',RB)==after,'The migration re-applies cleanly after a rollback'
 assert q('reapply-new-columns',"select jsonb_build_object('temporal',count(*)filter(where temporal is not null),'history',count(*)filter(where temporal_history<>'[]'))from public.property_video_job_sources",RB)=={'temporal':0,'history':0}
 assert q('history-snapshot-after-reapply',DATA_SNAPSHOT,RB)==hist0
 run('replay-after-reapply',[*RB,'-q','-1','-f',MIG]);assert catalog('after-reapply-replay',RB)==after
 receipt['rollback']={'path':str(ROLLBACK.relative_to(ROOT)),'refusedChangedObject':True,'exactPredecessorCatalog':True,'rowsUntouched':True,'discardedVerdicts':{'current':1,'archived':0},'idempotent':True,'reapplied':True}
 run('drop-rollback-clone',[tool('dropdb'),*conn,'temporal_rollback_proof'])
 # ── remaining chronology, then the actual fixture ─────────────────────────────
 for m in MIGRATIONS[OWN_INDEX+1:]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 head=catalog('catalog-head')
 for stage in ['fresh','replay']:
  out=run(stage+'-actual-temporal',[*PSQL,'-Atq'],fixture);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 assert receipt['fresh']['assertions']==receipt['replay']['assertions'],'Fresh and replayed fixture runs must agree'
 # The existing paid-retry and background-job authority is untouched by the new column, trigger and RPC.
 baseline=run('existing-derived-retry',[*PSQL,'-Atq','-f',DERIVED]);receipt['existingDerivedRetryRegression']=next(json.loads(x)for x in baseline.splitlines()if x.startswith('{')and'assertions'in x)
 FIRST_WINS=(RPC,"and s.temporal#>>'{limits,sha256}'=p_report#>>'{limits,sha256}'then return s.temporal;end if;","and false then return s.temporal;end if;")
 SAME_ATTEMPT=(GUARD,"then raise exception'RP409: The first temporal verdict for this attempt and limit version stands';","then return new;")
 for label,mutations,oracle in [
  ('clip-identity',[(RPC,"or p_clip_sha256 is distinct from s.clip->>'sha256'",'')],'wrong clip sha refused'),
  # Without the RPC's first-wins return the table guard alone still refuses the
  # overwrite (same transaction: the identical exact-replay record is refused as
  # an archive without replacement, i.e. the same attempt and limit version).
  ('first-wins-rpc-only-backstopped-by-guard',[FIRST_WINS],"RP409: The first temporal verdict for this attempt and limit version stands"),
  ('first-wins-both-layers',[FIRST_WINS,SAME_ATTEMPT],'first recorded verdict wins'),
  ('immutable',[(GUARD,"raise exception'RP409: A recorded temporal verdict is immutable'",'return new')],'direct edit of a recorded verdict refused'),
  ('same-attempt-replacement',[SAME_ATTEMPT],'archiving without a replacement refused')]:
  originals={s:run('read-'+label+'-'+s.split('(')[0].split('.')[1],[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%s])for s in dict.fromkeys(m[0]for m in mutations)}
  mutated=dict(originals)
  for signature,anchor,replacement in mutations:assert mutated[signature].count(anchor)==1,(label,'exact production anchor');mutated[signature]=mutated[signature].replace(anchor,replacement,1)
  for s in mutated:run('compile-'+label+'-'+s.split('(')[0].split('.')[1],[*PSQL,'-Atq'],mutated[s])
  run('negative-'+label,[*PSQL,'-Atq'],fixture,refuses=oracle)
  for s in originals:run('restore-'+label+'-'+s.split('(')[0].split('.')[1],[*PSQL,'-Atq'],originals[s])
  receipt['controls'].append({'name':label,'mutations':len(mutations),'compiledActualSQL':True,'unsafeMutationRejected':True,'oracle':oracle})
 assert catalog('catalog-after-controls')==head,'Control restoration must preserve the head catalog'
 # ── race: two first writes with different reports for the same live attempt ──
 run('clone-for-race',[tool('createdb'),*conn,'-T','temporal_verdict_proof','temporal_race_proof']);RACE=psql_for('temporal_race_proof')
 setup=fixture[:fixture.index('-- Closed report shape and clip identity.')].replace('set local ','set ')
 setup+="reset role;create table public.temporal_race as select job,lease,attempt from rv_ids;grant select on public.temporal_race to service_role;commit;"
 run('race-setup',[*RACE,'-Atq'],setup)
 statement=lambda reasons:"select (property_video_job_temporal(job,lease,attempt,repeat('e',64),public.temporal_race_report('{%s}')))->'verdict' from public.temporal_race;"%reasons
 run('race-report-helper',[*RACE,'-Atq'],"create or replace function public.temporal_race_report(reasons text[])returns jsonb language sql as $$select jsonb_build_object('profile','temporal-motion-v2','limits',jsonb_build_object('profile','temporal-motion-v2','sha256',repeat('1',64)),'metrics',jsonb_build_object('profile','temporal-motion-v2','fps',24),'verdict',jsonb_build_object('profile','temporal-motion-v2','pass',cardinality(reasons)=0,'reasons',to_jsonb(reasons)))$$;grant execute on function public.temporal_race_report(text[])to service_role;")
 results=race('same-attempt-first-write',[statement('vertical_bob'),statement('')]);assert all(x['exit']==0 for x in results),results
 verdicts={x['output'].strip()for x in results};assert len(verdicts)==1,('both callers must read the one recorded verdict',results)
 stored=run('race-stored',[*RACE,'-Atq','-c',"select (temporal->'verdict')::text||':'||jsonb_array_length(temporal_history) from property_video_job_sources s join public.temporal_race r on s.job_id=r.job and s.attempt_id=r.attempt;"]).strip()
 assert stored.split(':')[-1]=='0' and stored.rsplit(':',1)[0]==next(iter(verdicts)),stored
 receipt['races'].append({'name':'same-attempt-first-write','requests':2,'oneRecord':True,'archived':0,'supplierPOSTs':0})
 run('drop-race-clone',[tool('dropdb'),*conn,'temporal_race_proof'])
 assert hashes()==receipt['sourceHashes'],'Source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':receipt['fresh']['assertions'],'replayAssertions':receipt['replay']['assertions'],'replayControls':len(receipt['replayControls']),'controls':len(receipt['controls']),'races':len(receipt['races']),'rollback':True,'derivedRetryAssertions':receipt['existingDerivedRetryRegression'].get('assertions'),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or not (DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
