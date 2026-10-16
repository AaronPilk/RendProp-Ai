#!/usr/bin/env python3
"""Actual disposable PostgreSQL proof; never connects to a hosted service."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,shutil,subprocess,tempfile,time,uuid
from concurrent.futures import ThreadPoolExecutor
os.umask(0o077)
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path,required=True);args=p.parse_args()
OUT=args.evidence_dir.resolve();OUT.mkdir(mode=0o700,parents=True,exist_ok=False)
INTERNAL=Path('/Users/pilksclaes');EXTERNAL=Path('/Volumes/Rendprop Files')
def guard():
 assert EXTERNAL.is_mount(),'External evidence volume must be mounted'
 assert shutil.disk_usage(INTERNAL).free>=3*1024**3,'Preserve internal 3GiB'
 assert shutil.disk_usage(EXTERNAL).free>=8*1024**3,'Preserve external 8GiB'
 assert time.monotonic()<DEADLINE,'Whole proof deadline'
DEADLINE=time.monotonic()+600;guard()
DATA=Path(tempfile.mkdtemp(prefix='owned-native-pg-',dir=OUT));SOCK=Path(tempfile.mkdtemp(prefix='native-pg-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/opt/homebrew/opt/postgresql@17/bin:/usr/bin:/bin','LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda x:shutil.which(x,path=ENV['PATH'])
assert all(tool(x)for x in ['initdb','pg_ctl','createdb','psql'])
MIG=SQL/'migrations/20261016163911_native_photo_family_selection.sql';FIX=SQL/'tests/native_photo_family_selection.sql';MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',FIX,Path(__file__).resolve()]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in SOURCES}
receipt={'passed':False,'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_hashes':hashes(),'commands':[],'live_calls':0,'provider_calls':0};started=False
CATALOG="select coalesce(jsonb_agg(jsonb_build_object('signature',oid::regprocedure::text,'definition',pg_get_functiondef(oid),'owner',pg_get_userbyid(proowner),'acl',proacl,'security',prosecdef,'config',proconfig)order by oid::regprocedure::text),'[]')from pg_proc where pronamespace='public'::regnamespace and prokind='f';"
def run(name,cmd,body=None,refuses=None):
 guard();child=subprocess.Popen([str(x)for x in cmd],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV,cwd=ROOT)
 try:
  end=time.monotonic()+120
  while True:
   try:out,_=child.communicate(input=body,timeout=.5);break
   except subprocess.TimeoutExpired:body=None;guard();assert time.monotonic()<end,'Command deadline'
 except BaseException:child.kill();child.communicate();raise
 log=OUT/(name+'.log');log.write_text(out);receipt['commands'].append({'name':name,'exit':child.returncode,'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert (child.returncode!=0 and refuses in out) if refuses else child.returncode==0,(name,out[-8000:]);return out

def query(name,body,refuses=None):return run(name,[*PSQL,'-Atq'],body,refuses)
def catalog(name):return json.loads(query(name,CATALOG).strip())
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55639 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=12",'start']);started=True
 conn=['-h',SOCK,'-p','55639','-U','postgres'];run('createdb',[tool('createdb'),*conn,'native_selection_proof']);PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','native_selection_proof','-v','ON_ERROR_STOP=1']
 assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for i,m in enumerate(MIGRATIONS):
  if m==MIG:before=catalog('before-own')
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if i%40==0:print('Applied',i+1,'of',len(MIGRATIONS),flush=True)
 after=catalog('after-own');old={x['signature']:x for x in before};new={x['signature']:x for x in after};assert all(new[k]==v for k,v in old.items()),'Existing function changed'
 assert len(new)-len(old)==4,'Only four prospective helpers/RPCs'
 run('own-replay',[*PSQL,'-q','-1','-f',MIG]);assert catalog('after-replay')==after
 for label in ['fresh','repeated']:
  out=run(label,[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'] and rows[0]['assertions']==44,(label,rows);receipt[label]=rows[0];print(label,rows[0],flush=True)

 # Compile real unsafe omissions and require the corresponding strict fixture oracle.
 receipt['controls']=[]
 for name,signature,needle,replacement,oracle in [
 ('missing-CAS','native_gallery_selection_change(uuid,uuid,uuid,uuid,uuid,jsonb)',"if p_request->'expected_selection'is distinct from", "if false and p_request->'expected_selection'is distinct from",'NATIVE SELECTION FAIL: stale ordered selection refuses before mutation'),
 ('lost-unrelated-slot','native_gallery_selection_change(uuid,uuid,uuid,uuid,uuid,jsonb)','else next_ids:=array_append(next_ids,item);','else null;','NATIVE SELECTION FAIL: Original replaces edited family in place'),
 ('changed-fingerprint','native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)','or a.sha256 is distinct from p_sha','', 'NATIVE SELECTION FAIL: changed target fingerprint refuses'),
 ('calibration-promotion','native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)',"or purpose='calibration'",'', 'NATIVE SELECTION FAIL: accepted calibration evidence is never deliverable'),
 ('non-photo-evidence','native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)',"or m.kind not in('photo_edit','virtual_stage','declutter')",'', 'NATIVE SELECTION FAIL: non-photo provenance cannot justify edited photo'),
 ('self-original','native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)',"or m.original_key=a.storage_key",'', 'NATIVE SELECTION FAIL: edited target cannot be its own retained original'),
 ]:
  original=query('read-'+name,"select pg_get_functiondef('public.%s'::regprocedure);"%signature);assert original.count(needle)==1,name
  mutant=original.replace(needle,replacement,1)
  if name=='lost-unrelated-slot':
   second='if l.gallery_asset_ids is distinct from next_ids or l.main_photo_key is distinct from next_cover';assert mutant.count(second)==1;mutant=mutant.replace(second,'if false and (l.gallery_asset_ids is distinct from next_ids or l.main_photo_key is distinct from next_cover)',1)
  query('compile-'+name,mutant);run('negative-'+name,[*PSQL,'-Atq','-f',FIX],refuses=oracle);query('restore-'+name,original)
  receipt['controls'].append({'name':name,'actual_compiled_SQL':True,'expected_strict_oracle':oracle})
 original=query('read-unknown',"select pg_get_functiondef('public.native_gallery_selection_ids(jsonb,boolean)'::regprocedure);")
 assert original.count('declare ids uuid[];begin')==1
 query('compile-unknown',original.replace('declare ids uuid[];begin','declare ids uuid[];begin -- privileged unknown control\n',1));prior=catalog('unknown-before')
 run('unknown-replay',[*PSQL,'-q','-1','-f',MIG],refuses='Review changed native photo selection helper');assert catalog('unknown-after')==prior;query('restore-unknown',original)
 receipt['controls'].append({'name':'unknown-body-replay','full_catalog_unchanged':True})
 query('authenticated-denied',"set role authenticated;select native_gallery_selection_snapshot(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),null);",refuses='permission denied')
 setup=FIX.read_text().split('-- BEGIN FIXTURE\n',1)[1].split('-- END FIXTURE',1)[0].replace('grant select,insert on checks to service_role;','')
 query('race-setup','begin;'+setup+'create table public.native_selection_race as select *from gf;grant select on public.native_selection_race to service_role;commit;')
 f=json.loads(query('race-identities','select row_to_json(x)from public.native_selection_race x;').strip())
 k=lambda asset:'renders/'+f['org']+'/'+f['listing']+'/gallery-'+asset+'.jpg'
 def intent(target):return {'family_asset_ids':[f['p1'],f['p2']],'target':None if target is None else {'asset_id':target,'sha256':'1'*64,'bytes':100},'expected_selection':{'gallery_asset_ids':[f['p3'],f['p2']],'main_photo_key':k(f['p3'])},'follow_family_cover':False,'reviewed':False}
 def command(op,body):return "set role service_role;select native_gallery_selection_change(actor,org,org,listing,'%s','%s')from public.native_selection_race;"%(op,json.dumps(body))
 def reset(label):query(label,"delete from native_gallery_selection_operations;update listings l set gallery_asset_ids=array[f.p3,f.p2],main_photo_key='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p3||'.jpg'from native_selection_race f where l.id=f.listing;")
 def race(label,bodies):
  locker=subprocess.Popen([*PSQL,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV,cwd=ROOT)
  try:
   locker.stdin.write("begin;select id from listings where id=(select listing from native_selection_race)for update;\\echo LOCKED\n");locker.stdin.flush()
   assert locker.stdout.readline().strip()==f['listing']and locker.stdout.readline().strip()=='LOCKED'
   def worker(pair):
    i,body=pair;child=subprocess.run([*PSQL,'-Atq'],input=body,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,cwd=ROOT,timeout=40)
    log=OUT/(label+'-'+str(i)+'.log');log.write_text(child.stdout);return {'exit':child.returncode,'output':child.stdout,'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest()}
   with ThreadPoolExecutor(max_workers=2)as pool:
    jobs=[pool.submit(worker,x)for x in enumerate(bodies)];end=time.monotonic()+10
    while True:
     waits=query(label+'-wait-'+str(time.monotonic_ns()),"select count(*)from pg_stat_activity where datname=current_database()and wait_event_type='Lock'and pid<>pg_backend_pid();").strip()
     if waits=='2':break
     guard();assert time.monotonic()<end,'Both writers must actually overlap';time.sleep(.03)
    locker.stdin.write('commit;\n');locker.stdin.flush();locker.stdin.close();locker.wait(timeout=10)
    return [j.result()for j in jobs]
  finally:
   if locker.poll()is None:locker.kill();locker.wait()
 receipt['races']=[]
 reset('race-distinct-reset');rows=race('distinct-operations',[command(str(uuid.uuid4()),intent(f['p1'])),command(str(uuid.uuid4()),intent(None))])
 assert sorted(x['exit']for x in rows)==[0,3]and sum('The listing photo selection changed'in x['output']for x in rows)==1,rows
 assert query('race-distinct-effect',"select cardinality(l.gallery_asset_ids)in(1,2)and l.gallery_asset_ids[1]=f.p3 and l.main_photo_key='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p3||'.jpg'and(select count(*)from native_gallery_selection_operations)=1 from listings l join native_selection_race f on f.listing=l.id;").strip()=='t'
 receipt['races'].append({'name':'two-distinct-operations-one-CAS-winner','rows':rows,'unrelated_slot_cover_preserved':True})
 reset('race-same-reset');op=str(uuid.uuid4());body=command(op,intent(f['p1']));rows=race('same-operation',[body,body]);assert all(x['exit']==0 for x in rows),rows
 replies=[json.loads(x['output'].strip())for x in rows];assert sorted(x['replayed']for x in replies)==[False,True]
 assert query('race-same-receipt','select count(*)from native_gallery_selection_operations;').strip()=='1'
 receipt['races'].append({'name':'same-operation-one-receipt-no-reapply','rows':rows})
 reset('race-trash-reset');rows=race('canonical-trash',[command(str(uuid.uuid4()),intent(f['p1'])),"set role service_role;select trash_listing(actor,listing)from native_selection_race;"])
 assert rows[1]['exit']==0 and (rows[0]['exit']==0 or rows[0]['exit']==3 and 'RP404:' in rows[0]['output']),rows
 assert query('race-trash-final',"select deleted_at is not null from listings where id=(select listing from native_selection_race);").strip()=='t'
 query('race-trash-receipt-refusal',"set role service_role;select native_gallery_selection_snapshot(actor,org,org,listing,null)from native_selection_race;",refuses='RP404:')
 receipt['races'].append({'name':'canonical-trash-versus-choice','rows':rows,'trashed_home_cannot_read_historical_receipt':True})
 assert catalog('final-catalog')==after,'Control or race changed function authority'
 assert hashes()==receipt['source_hashes'],'Consumed source changed';receipt['passed']=True
finally:
 if started:
  result=subprocess.run([tool('pg_ctl'),'-D',str(DATA),'-m','immediate','-w','stop'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV,timeout=30);(OUT/'stop.log').write_text(result.stdout);receipt['owned_cluster_stopped']=result.returncode==0
 receipt['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if receipt.get('owned_cluster_stopped')or not started:shutil.rmtree(DATA)
 shutil.rmtree(SOCK,ignore_errors=True)
print(json.dumps({'passed':True,'receipt':str(OUT/'receipt.json')}))
