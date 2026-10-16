#!/usr/bin/env python3
"""Owned socket-only PG proof; no hosted account, media bytes or paid API calls."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse,datetime,hashlib,json,os,shutil,subprocess,tempfile,time,uuid
os.umask(0o077)
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=(args.evidence_dir or Path(tempfile.mkdtemp(prefix='studio-gallery-copy-'))).resolve();OUT.mkdir(mode=0o700,parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
assert shutil.disk_usage(OUT).free>=8*1024**3,'Preserve external8GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='owned-copy-pg-',dir=OUT));SOCK=Path(tempfile.mkdtemp(prefix='gallery-copy-socket-',dir='/tmp'))
ENV={'PATH':os.pathsep.join([os.environ.get('PATH','/usr/bin:/bin'),'/opt/homebrew/opt/postgresql@17/bin','/opt/homebrew/bin','/usr/bin','/bin']),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n,path=ENV['PATH'])
assert all(tool(n)for n in ['initdb','pg_ctl','createdb','psql'])
MIG=SQL/'migrations/20261015234310_studio_gallery_source_copy.sql';FIX=SQL/'tests/studio_gallery_source_copy.sql';MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));assert MIG in MIGRATIONS
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',FIX,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Actual PostgreSQL roles/transactions/concurrency with synthetic metadata, no actual uploaded media or live authority','migration_count':len(MIGRATIONS),'source_hashes':hashes(),'production_mutations':0,'provider_calls':0,'commands':[],'controls':[],'races':[]};started=False
CATALOG="select coalesce(jsonb_agg(jsonb_build_object('signature',oid::regprocedure::text,'definition',pg_get_functiondef(oid),'owner',pg_get_userbyid(proowner),'acl',proacl,'security',prosecdef,'config',proconfig)order by oid::regprocedure::text),'[]')from pg_proc where pronamespace='public'::regnamespace and prokind='f';"
def guard():assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
def run(name,cmd,body=None,refuses=None):
 guard();process=subprocess.Popen([str(x)for x in cmd],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV,cwd=ROOT)
 try:
  deadline=time.monotonic()+180
  while True:
   try:out,_=process.communicate(input=body,timeout=.5);break
   except subprocess.TimeoutExpired:
    body=None;guard();assert time.monotonic()<deadline,'Bounded PG command deadline'
 except BaseException:process.kill();process.communicate();raise
 log=OUT/(name+'.log');log.write_text(out);receipt['commands'].append({'name':name,'exit':process.returncode,'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert(process.returncode!=0 and refuses in out)if refuses else process.returncode==0,(name,out[-6000:]);return out

def query(name,body,refuses=None):return run(name,[*PSQL,'-Atq'],body,refuses)
def catalog(name):return json.loads(query(name,CATALOG).strip())
def race(name,commands):
 locker=subprocess.Popen([*PSQL,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV,cwd=ROOT)
 try:
  locker.stdin.write("begin;select id from listings where id=(select listing from public.gallery_copy_race)for update;\\echo LOCKED\n");locker.stdin.flush()
  assert locker.stdout.readline().strip()==fixture['listing'] and locker.stdout.readline().strip()=='LOCKED'
  def call(pair):
   i,body=pair;r=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40);(OUT/f'{name}-{i}.log').write_text(r.stdout);return{'exit':r.returncode,'output':r.stdout}
  with ThreadPoolExecutor(max_workers=2)as pool:
   jobs=[pool.submit(call,pair)for pair in enumerate(commands)];deadline=time.monotonic()+10
   while True:
    if query(name+'-waiting-'+str(time.monotonic_ns()),"select count(*)from pg_stat_activity where datname=current_database()and wait_event_type='Lock'and pid<>pg_backend_pid();").strip()=='2':break
    assert time.monotonic()<deadline,'Both real callers must overlap behind listing lock';time.sleep(.03)
   locker.stdin.write('commit;\n');locker.stdin.flush();locker.stdin.close();locker.wait(timeout=10);rows=[job.result()for job in jobs]
  (OUT/(name+'.json')).write_text(json.dumps(rows,indent=2)+'\n');return rows
 finally:
  if locker.poll()is None:locker.kill();locker.wait()
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55625 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=12",'start']);started=True
 conn=['-h',SOCK,'-p','55625','-U','postgres'];run('createdb',[tool('createdb'),*conn,'gallery_copy_proof']);PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','gallery_copy_proof','-v','ON_ERROR_STOP=1']
 assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for i,m in enumerate(MIGRATIONS):
  if m==MIG:before=catalog('before-own')
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   boundary=catalog('own-boundary');run('own-boundary-replay',[*PSQL,'-q','-1','-f',MIG]);assert catalog('own-boundary-replayed')==boundary
  if i%30==0:print('Applied',i+1,'of',len(MIGRATIONS),flush=True)
 after=catalog('current-catalog');old={x['signature']:x for x in before};new={x['signature']:x for x in boundary};changed=[]
 assert {k:v for k,v in old.items()if k not in changed}=={k:v for k,v in new.items()if k in old and k not in changed}
 for k in changed:assert {a:b for a,b in old[k].items()if a!='definition'}=={a:b for a,b in new[k].items()if a!='definition'}
 receipt['catalog']={'existing_changed_functions_only':changed,'existing_owner_ACL_security_config_exact':True,'own_migration_replay_exact':True,'new_function_count':len(new)-len(old)}
 for stage in ['fresh','repeated']:
  out=run(stage,[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed']and rows[0]['assertions']>=35;receipt[stage]=rows[0];print(stage,rows[0],flush=True)
 for label,signature,needle,replacement,oracle in [
  ('drop-destination-binding','public.studio_gallery_copy_bind(uuid,uuid,uuid,uuid,uuid)',"if r.destination_asset_id is not null then",'if false and r.destination_asset_id is not null then','different upload cannot replace bound destination'),
  ('drop-hold','public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)',"or(m.qc is not null and(m.qc->'publishable'is distinct from'true'::jsonb or coalesce(m.qc->>'action','')not in('accept','pass')))",'','held edit refuses before copy reservation'),
  ('drop-original-proof','public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)',"if not exists(select 1 from public.upload_reservations r",'if false and not exists(select 1 from public.upload_reservations r','unknown renders source is not relabelled Original'),
  ('drop-source-snapshot','public.studio_gallery_copy_response(uuid,uuid,uuid,uuid)',"if current_source is distinct from r.source_snapshot",'if false and current_source is distinct from r.source_snapshot','changed source snapshot refuses recovery')]:
  original=query('read-'+label,"select pg_get_functiondef('%s'::regprocedure);"%signature);assert original.count(needle)==1,label;query('compile-'+label,original.replace(needle,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);query('restore-'+label,original);receipt['controls'].append({'name':label,'actual_compiled_SQL':True,'unsafe_omission_detected':True})
 query('authenticated-refusal',"set role authenticated;select studio_gallery_copy_prepare(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),'');",refuses='permission denied')
 setup=FIX.read_text().split('-- BEGIN FIXTURE\n',1)[1].split('-- END FIXTURE',1)[0]
 helper=FIX.read_text().split('create function pg_temp.copy_ticket',1)[1].split('grant all on checks',1)[0]
 query('race-fixture','begin;'+setup+'create table public.gallery_copy_race as select *from cf;grant select on public.gallery_copy_race to service_role;commit;')
 fixture=json.loads(query('race-identities','select row_to_json(f)from public.gallery_copy_race f;').strip())
 prepare=lambda op:"select studio_gallery_copy_prepare(actor,org,listing,original,'%s','Race original')from public.gallery_copy_race;"%op
 r=race('same-source-prepare',[prepare(str(uuid.uuid4())),prepare(str(uuid.uuid4()))]);assert all(x['exit']==0 for x in r),r
 assert query('one-operation',"select count(*)from studio_gallery_copies where source_asset_id=(select original from public.gallery_copy_race);").strip()=='1';receipt['races'].append({'name':'same-owner-two-prepare-operations','one_canonical_operation':True})
 op=query('canonical-operation',"select operation_id from studio_gallery_copies where source_asset_id=(select original from public.gallery_copy_race);").strip()
 # Use the real upload reservation/claim/finish/settle functions, with synthetic
 # transfer receipts only; no storage network or real media claims.
 helper=helper.replace('f cf','f public.gallery_copy_race')
 query('race-copy-upload','create function pg_temp.copy_ticket'+helper+"set role service_role;do $$declare f public.gallery_copy_race;id uuid;begin select *into f from public.gallery_copy_race;id:=pg_temp.copy_ticket(f,100,'race-bound-copy');perform public.studio_gallery_copy_bind(f.actor,f.org,f.listing,'%s',id);perform pg_temp.complete(id);end$$;"%op)
 finish="select studio_gallery_copy_finish(actor,org,listing,'%s',repeat('a',64),100)from public.gallery_copy_race;"%op
 r=race('same-copy-finish',[finish,finish]);assert all(x['exit']==0 for x in r),r
 assert query('one-private-photo',"select count(*)=1 and bool_and(p.is_staged=false)from photos p join studio_gallery_copies c on p.id=c.destination_asset_id where c.operation_id='%s';"%op).strip()=='t';receipt['races'].append({'name':'lost-finish-reply-versus-concurrent-finish','one_private_history_row':True,'no_realias_or_selection':True})
 # Canonical listing trash races an actual same-source replay. It either runs
 # after the current-scope read or causes the read to refuse; no row reappears.
 r=race('prepare-vs-trash',[prepare(str(uuid.uuid4())),"select trash_listing(actor,listing)from public.gallery_copy_race;"]);assert r[1]['exit']==0 and(r[0]['exit']==0 or'RP404:'in r[0]['output']or'RP409:'in r[0]['output']),r
 assert query('deleted-private',"select deleted_at is not null and gallery_asset_ids='{}'::uuid[]and main_photo_key is null from listings where id=(select listing from public.gallery_copy_race);").strip()=='t';receipt['races'].append({'name':'same-source-replay-versus-canonical-trash','current_authority_or_refusal':True,'no_selection_or_recreation':True})
 assert catalog('final-catalog')==after,'Controls/races changed function catalog';assert hashes()==receipt['source_hashes'],'Consumed source changed';receipt['passed']=True;receipt['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();print(json.dumps({'passed':True,'fresh':receipt['fresh']['assertions'],'repeated':receipt['repeated']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}),flush=True)
finally:
 if started:
  subprocess.run([tool('pg_ctl'),'-D',str(DATA),'-m','immediate','-w','stop'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=30)
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if receipt['passed']or not started:shutil.rmtree(DATA)
 shutil.rmtree(SOCK,ignore_errors=True)
