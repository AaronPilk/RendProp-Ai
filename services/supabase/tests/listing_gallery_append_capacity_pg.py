#!/usr/bin/env python3
"""Actual socket-only PG append capacity, preserved authority and concurrent union.
No production connection, uploads, credentials, AI or new selection policy.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse,datetime,hashlib,json,os,shutil,subprocess,tempfile,time,uuid
os.umask(0o077)
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=(args.evidence_dir or Path(tempfile.mkdtemp(prefix='gallery-append-capacity-proof-'))).resolve();OUT.mkdir(mode=0o700,parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
assert shutil.disk_usage(OUT).free>=8*1024**3,'Preserve external8GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='owned-append-pg-',dir=OUT));SOCK=Path(tempfile.mkdtemp(prefix='append-pg-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/opt/postgresql@17/bin:/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n,path=ENV['PATH'])
assert all(tool(n)for n in ['initdb','pg_ctl','createdb','psql'])
MIG=SQL/'migrations/20261015215817_listing_gallery_append_capacity.sql';FIX=SQL/'tests/listing_gallery_append_capacity.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));assert MIG in MIGRATIONS
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',FIX,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'migration_count':len(MIGRATIONS),'scope':'Actual disposable PostgreSQL/full current schema with synthetic metadata; source-only release proof','network_calls':0,'production_mutations':0,'provider_calls':0,'source_hashes':hashes(),'commands':[],'controls':[],'races':[]};started=False
SIGNATURE='public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text)'
CATALOG="select coalesce(jsonb_agg(jsonb_build_object('signature',oid::regprocedure::text,'definition',pg_get_functiondef(oid),'owner',pg_get_userbyid(proowner),'acl',proacl,'security',prosecdef,'config',proconfig)order by oid::regprocedure::text),'[]')from pg_proc where pronamespace='public'::regnamespace and prokind='f';"
def run(name,cmd,body=None,refuses=None):
 result=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 log=OUT/(name+'.log');log.write_text(result.stdout);receipt['commands'].append({'name':name,'exit':result.returncode,'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert(result.returncode!=0 and refuses in result.stdout)if refuses else result.returncode==0,(name,result.stdout[-5000:]);return result.stdout

def query(name,body,refuses=None):return run(name,[*PSQL,'-Atq'],body,refuses)
def catalog(name):return json.loads(query(name,CATALOG).strip())
def race(name,commands):
 # Hold the exact shared org lock until BOTH real sessions are waiting.
 locker=subprocess.Popen([*PSQL,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV,cwd=ROOT)
 try:
  locker.stdin.write("begin;select org from public.append_capacity_race for update;select id from orgs where id=(select org from public.append_capacity_race)for update;\\echo LOCKED\n");locker.stdin.flush()
  assert locker.stdout.readline().strip()==fixture['org']
  assert locker.stdout.readline().strip()==fixture['org']
  assert locker.stdout.readline().strip()=='LOCKED'
  def call(pair):
   i,body=pair;r=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
   (OUT/f'{name}-{i}.log').write_text(r.stdout);return{'exit':r.returncode,'output':r.stdout}
  with ThreadPoolExecutor(max_workers=2)as pool:
   jobs=[pool.submit(call,pair)for pair in enumerate(commands)];deadline=time.monotonic()+10
   while True:
    count=query(name+'-waiting-'+str(time.monotonic_ns()),"select count(*)from pg_stat_activity where datname=current_database()and wait_event_type='Lock'and pid<>pg_backend_pid();").strip()
    if count=='2':break
    assert time.monotonic()<deadline,'Both real sessions must overlap at org lock';time.sleep(.03)
   locker.stdin.write('commit;\n');locker.stdin.flush();locker.stdin.close();locker.wait(timeout=10)
   result=[job.result()for job in jobs]
  (OUT/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n');return result
 finally:
  if locker.poll()is None:locker.kill();locker.wait()
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55621 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=12",'start']);started=True
 conn=['-h',SOCK,'-p','55621','-U','postgres'];run('createdb',[tool('createdb'),*conn,'gallery_append_capacity_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','gallery_append_capacity_proof','-v','ON_ERROR_STOP=1']
 identity=query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip();assert identity==str(DATA)+'|'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for i,m in enumerate(MIGRATIONS):
  if m==MIG:before=catalog('catalog-before')
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   boundary=catalog('own-boundary-after');old={x['signature']:x for x in before};new={x['signature']:x for x in boundary}
   key='append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text)';assert old.keys()==new.keys()
   assert {k:v for k,v in old.items()if k!=key}=={k:v for k,v in new.items()if k!=key}
   assert {k:v for k,v in old[key].items()if k!='definition'}=={k:v for k,v in new[key].items()if k!='definition'}
   run('replay-own-boundary',[*PSQL,'-q','-1','-f',MIG]);assert catalog('own-boundary-replayed')==boundary
   receipt['own_boundary']={'only_function_body_changed':key,'all_other_catalog_owner_ACL_security_config_exact':True,'migration_replay_catalog_exact':True}
  if i%30==0:print('Applied',i+1,'of',len(MIGRATIONS),flush=True)
 after=catalog('current-head-catalog')
 for stage in ['fresh','replay']:
  out=run(stage,[*PSQL,'-Atq','-f',FIX]);values=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(values)==1 and values[0]['passed']and values[0]['assertions']>=25
  receipt[stage]=values[0];print(stage,values[0],flush=True)
 receipt['fixture_scope']='Both unchanged fixture executions and all controls/races run at full current head; own migration replay runs only at its chronological boundary.'
 original=query('read-current-function',f"select pg_get_functiondef('{SIGNATURE}'::regprocedure);")
 for label,needle,replacement,oracle in [
  ('old-input40','cardinality(p_add)>100','cardinality(p_add)>40','RP400: Choose up to 100 distinct uploaded gallery photos.'),
  ('old-auto40','order by a.created_at,a.id limit 100','order by a.created_at,a.id limit 40','NULL automatic conversion preserves full100'),
  ('missing-result-bound','if cardinality(selected)>100 then','if false then','101st union refuses own capacity fence'),
  ('empty-rebuilt','if l.gallery_asset_ids is null then','if l.gallery_asset_ids is null or cardinality(l.gallery_asset_ids)=0 then','41 distinct additions are admitted'),
  ('duplicate-cover-key','if p_set_main and p_main_photo_key is not null and not(p_main_photo_key=any(candidate_keys))then','if p_set_main and p_main_photo_key is not null then','Choose a bounded media visibility batch'),
  ('caller-authority','perform public.client_listing_access(p_user,p_org,p_listing,true);','null;','outsider cannot use privileged append')]:
  assert original.count(needle)==1,label;query('compile-'+label,original.replace(needle,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);query('restore-'+label,original)
  receipt['controls'].append({'name':label,'actual_compiled_SQL':True,'unsafe_delta_detected':True})
 unknown=original.replace('declare\n l public.listings;','declare\n -- Synthetic privileged unknown-body control\n l public.listings;',1);assert unknown!=original
 query('install-unknown-body',unknown);unknown_catalog=catalog('unknown-catalog-before');run('guard-unknown-body',[*PSQL,'-q','-1','-f',MIG],refuses='Review changed append_listing_gallery');assert catalog('unknown-catalog-after')==unknown_catalog;query('restore-reviewed-body',original)
 receipt['controls'].append({'name':'unknown-production-body','refused_before_change':True,'full_catalog_unchanged':True})
 # Reuse the same authority fixture, committed ONLY in this owned local DB.
 fixture_text=FIX.read_text().split('-- BEGIN FIXTURE\n',1)[1].split('-- END FIXTURE',1)[0]
 query('race-fixture','begin;'+fixture_text+'create table public.append_capacity_race as select *from af;grant select on public.append_capacity_race to service_role;commit;')
 fixture=json.loads(query('race-identities','select row_to_json(f)from public.append_capacity_race f;').strip())
 def reset(count):query('race-reset-'+str(time.monotonic_ns()),"update listings l set gallery_asset_ids=f.ids[1:%s],main_photo_key='renders/'||f.org||'/'||f.listing||'/gallery-'||f.ids[1]||'.jpg'from public.append_capacity_race f where l.id=f.listing;"%count)
 def append(index):return "select append_listing_gallery(actor,org,listing,array[ids[%s]])from public.append_capacity_race;"%index
 reset(99);rows=race('competing100th',[append(100),append(101)]);assert sum(r['exit']==0 for r in rows)==1 and sum('can contain up to 100'in r['output']for r in rows)==1,rows
 assert query('race-overflow-preserved',"select cardinality(l.gallery_asset_ids)=100 and l.gallery_asset_ids[1:99]=f.ids[1:99]and l.main_photo_key='renders/'||f.org||'/'||f.listing||'/gallery-'||f.ids[1]||'.jpg'from listings l join public.append_capacity_race f on f.listing=l.id;").strip()=='t'
 receipt['races'].append({'name':'two-competing100th-additions','one_winner':True,'one_capacity_refusal':True,'all_prior99_and_cover_preserved':True})
 reset(99);rows=race('same100th',[append(100),append(100)]);assert all(r['exit']==0 for r in rows),rows
 assert query('race-repeat-idempotent',"select l.gallery_asset_ids=f.ids[1:100]from listings l join public.append_capacity_race f on f.listing=l.id;").strip()=='t'
 receipt['races'].append({'name':'same100th-addition','two_success':True,'one_append_no_duplicates':True})
 reset(99);operation=str(uuid.uuid4());removal="select remove_listing_gallery(actor,org,listing,'%s',array[ids[1]],ids[1:99],'renders/'||org||'/'||listing||'/gallery-'||ids[1]||'.jpg')from public.append_capacity_race;"%operation
 rows=race('remove-and-append',[removal,append(100)]);assert rows[1]['exit']==0 and(rows[0]['exit']==0 or'The listing photo selection changed'in rows[0]['output']),rows
 assert query('race-remove-preserved',"select l.gallery_asset_ids@>f.ids[2:99]and f.ids[100]=any(l.gallery_asset_ids)and cardinality(l.gallery_asset_ids)between 99 and 100 from listings l join public.append_capacity_race f on f.listing=l.id;").strip()=='t'
 receipt['races'].append({'name':'atomic-remove-versus-append','append_success':True,'remove_success_or_freshCAS_refusal':True,'unrelated98_and_explicit_addition_preserved':True})
 assert catalog('final-catalog')==after,'Controls/races changed production function catalog'
 assert hashes()==receipt['source_hashes'],'Consumed source changed during proof'
 receipt['passed']=True;receipt['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 print(json.dumps({'passed':True,'fresh':receipt['fresh']['assertions'],'replay':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}),flush=True)
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if receipt['passed']or not started:shutil.rmtree(DATA)
 shutil.rmtree(SOCK,ignore_errors=True)
