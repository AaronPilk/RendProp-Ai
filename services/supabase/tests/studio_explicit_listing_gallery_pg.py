#!/usr/bin/env python3
"""Owned socket-only PG proof; no hosted account, media bytes or paid API calls."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse,datetime,hashlib,json,os,shutil,subprocess,tempfile,time,uuid
os.umask(0o077)
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=(args.evidence_dir or Path(tempfile.mkdtemp(prefix='studio-explicit-gallery-'))).resolve();OUT.mkdir(mode=0o700,parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
assert shutil.disk_usage(OUT).free>=8*1024**3,'Preserve external8GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='owned-gallery-pg-',dir=OUT));SOCK=Path(tempfile.mkdtemp(prefix='explicit-gallery-socket-',dir='/tmp'))
ENV={'PATH':os.pathsep.join([os.environ.get('PATH','/usr/bin:/bin'),'/opt/homebrew/opt/postgresql@17/bin','/opt/homebrew/bin','/usr/bin','/bin']),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n,path=ENV['PATH'])
assert all(tool(n)for n in ['initdb','pg_ctl','createdb','psql'])
MIG=SQL/'migrations/20261015221527_studio_explicit_listing_gallery.sql';FIX=SQL/'tests/studio_explicit_listing_gallery.sql';MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));assert MIG in MIGRATIONS
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',FIX,SQL/'tests/listing_gallery_append_capacity.sql',Path(__file__).resolve()]
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
  locker.stdin.write("begin;select id from listings where id=(select listing from public.explicit_gallery_race)for update;\\echo LOCKED\n");locker.stdin.flush()
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
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55624 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=12",'start']);started=True
 conn=['-h',SOCK,'-p','55624','-U','postgres'];run('createdb',[tool('createdb'),*conn,'studio_explicit_gallery_proof']);PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','studio_explicit_gallery_proof','-v','ON_ERROR_STOP=1']
 assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for i,m in enumerate(MIGRATIONS):
  if m==MIG:before=catalog('before-own')
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   boundary=catalog('own-boundary');run('own-boundary-replay',[*PSQL,'-q','-1','-f',MIG]);assert catalog('own-boundary-replayed')==boundary
  if i%30==0:print('Applied',i+1,'of',len(MIGRATIONS),flush=True)
 after=catalog('current-catalog');old={x['signature']:x for x in before};new={x['signature']:x for x in boundary};changed=['reserve_upload_assets(uuid,jsonb)','settle_upload_reservation(uuid,boolean,uuid,jsonb)']
 assert {k:v for k,v in old.items()if k not in changed}=={k:v for k,v in new.items()if k in old and k not in changed}
 for k in changed:assert {a:b for a,b in old[k].items()if a!='definition'}=={a:b for a,b in new[k].items()if a!='definition'}
 receipt['catalog']={'existing_changed_functions_only':changed,'existing_owner_ACL_security_config_exact':True,'own_migration_replay_exact':True,'new_function_count':len(new)-len(old)}
 for stage in ['fresh','repeated']:
  out=run(stage,[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed']and rows[0]['assertions']>=30;receipt[stage]=rows[0];print(stage,rows[0],flush=True)
 for label,signature,needle,replacement,oracle in [
  ('missing-reservation-freeze','public.reserve_upload_assets(uuid,jsonb)','perform public.freeze_listing_gallery_for_upload(p_actor,l.org_id,l.id);','null;','gallery reservation freezes legacy100 before inserting unuploaded candidate'),
  ('missing-completion-freeze','public.settle_upload_reservation(uuid,boolean,uuid,jsonb)','perform public.freeze_listing_gallery_for_upload(r.actor_id,r.org_id,r.listing_id);','null;','preexisting open ticket freezes NULL before uploaded transition'),
  ('missing-selection-CAS','public.studio_gallery_selection_change(uuid,uuid,uuid,text,uuid,jsonb,jsonb,jsonb,boolean)','if p_expected is distinct from jsonb_build_object','if false and p_expected is distinct from jsonb_build_object','stale explicit selection is rejected'),
  ('unsafe-held-edit','public.studio_gallery_photo_choice(uuid,uuid,uuid)',"or(m.qc is not null and(m.qc->'publishable'is distinct from'true'::jsonb or coalesce(m.qc->>'action','')not in('accept','pass')))",'','accepted altered edit needs explicit review while held edit refuses'),
  ('lost-unknown-anchors','public.studio_gallery_selection_change(uuid,uuid,uuid,text,uuid,jsonb,jsonb,jsonb,boolean)','else next_ids:=array_append(next_ids,item);','else null;','reorder moves mapped selected slots and preserves unknown anchors cover and exclusions')]:
  original=query('read-'+label,"select pg_get_functiondef('%s'::regprocedure);"%signature);assert original.count(needle)==1,label;query('compile-'+label,original.replace(needle,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);query('restore-'+label,original);receipt['controls'].append({'name':label,'actual_compiled_SQL':True,'unsafe_omission_detected':True})
 # New API refuses clients and unseen body changes without weakening any guard.
 query('authenticated-refusal',"set role authenticated;select studio_gallery_selection_snapshot(gen_random_uuid(),gen_random_uuid(),gen_random_uuid());",refuses='permission denied')
 original=query('read-reserve',"select pg_get_functiondef('public.reserve_upload_assets(uuid,jsonb)'::regprocedure);");needle='declare\n  s jsonb;';assert original.count(needle)==1;query('compile-unknown',original.replace(needle,'declare\n  -- Synthetic privileged unknown-body control\n  s jsonb;',1));prior=catalog('before-unknown-replay');run('unknown-replay',[*PSQL,'-q','-1','-f',MIG],refuses='Review changed gallery upload reservation');assert catalog('after-unknown-replay')==prior;query('restore-reserve',original);receipt['controls'].append({'name':'unknown-body-replay','full_catalog_unchanged':True})
 setup=FIX.read_text().split('-- BEGIN FIXTURE\n',1)[1].split('-- END FIXTURE',1)[0];query('race-fixture','begin;'+setup+'create table public.explicit_gallery_race as select *from bf;grant select on public.explicit_gallery_race to service_role;commit;');fixture=json.loads(query('race-identities','select row_to_json(f)from public.explicit_gallery_race f;').strip())
 def reset():query('race-reset-'+str(time.monotonic_ns()),"update listings set gallery_asset_ids=null,main_photo_key=null where id=(select listing from public.explicit_gallery_race);update photos p set sort=(q.n-1)::smallint from public.explicit_gallery_race f,unnest(f.photo_ids)with ordinality q(id,n)where p.id=q.id;")
 def reserve(key):
  asset=str(uuid.uuid4());return "select reserve_upload_assets(actor,jsonb_build_array(jsonb_build_object('id','%s','listing_id',listing,'kind','photo','bucket','renders','storage_key','renders/'||org||'/'||listing||'/gallery-%s.jpg','bytes',100,'content_type','image/jpeg','content_type_declared',true,'idem_key','%s')))from public.explicit_gallery_race;"%(asset,asset,key)
 reset();r=race('first-reserve-vs-use',[reserve('race-reserve-use'),"select studio_gallery_selection_change(actor,org,listing,'use_cover',photo_ids[1],'{\"gallery_asset_ids\":null,\"main_photo_key\":null}',null,null,false)from public.explicit_gallery_race;"]);assert r[0]['exit']==0 and(r[1]['exit']==0 or'The listing photo selection changed'in r[1]['output']),r
 assert query('race-use-preserved',"select cardinality(l.gallery_asset_ids)=100 and l.gallery_asset_ids@>f.ids[1:100]from listings l join public.explicit_gallery_race f on f.listing=l.id;").strip()=='t';receipt['races'].append({'name':'first-reservation-versus-explicit-use','reservation_success':True,'use_success_or_CAS_refusal':True,'all_prior100_and_no_candidate_retained':True})
 reset();ord=json.dumps(fixture['photo_ids']);desired=json.dumps([fixture['photo_ids'][1],fixture['photo_ids'][0],*fixture['photo_ids'][2:]])
 r=race('first-reserve-vs-reorder',[reserve('race-reserve-order'),"select studio_gallery_selection_change(actor,org,listing,'reorder_selected',null,'{\"gallery_asset_ids\":null,\"main_photo_key\":null}','%s','%s',false)from public.explicit_gallery_race;"%(ord,desired)]);assert r[0]['exit']==0 and(r[1]['exit']==0 or'The listing photo selection changed'in r[1]['output']),r
 assert query('race-order-preserved',"select cardinality(l.gallery_asset_ids)=100 and l.gallery_asset_ids@>f.ids[1:100]from listings l join public.explicit_gallery_race f on f.listing=l.id;").strip()=='t';receipt['races'].append({'name':'first-reservation-versus-reorder','same100_member_set':True,'order_success_or_CAS_refusal':True})
 reset();r=race('first-reserve-vs-canonical-trash',[reserve('race-reserve-trash'),"select trash_listing(actor,listing)from public.explicit_gallery_race;"]);assert r[1]['exit']==0 and(r[0]['exit']==0 or'upload workspace is not writable'in r[0]['output']),r
 assert query('race-deleted-private',"select deleted_at is not null from listings where id=(select listing from public.explicit_gallery_race);").strip()=='t';receipt['races'].append({'name':'first-reservation-versus-canonical-trash','canonical_delete_success':True,'reservation_finishes_first_or_refuses_deleted_listing':True})
 assert catalog('final-catalog')==after,'Controls/races changed function catalog';assert hashes()==receipt['source_hashes'],'Consumed source changed';receipt['passed']=True;receipt['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();print(json.dumps({'passed':True,'fresh':receipt['fresh']['assertions'],'repeated':receipt['repeated']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}),flush=True)
finally:
 if started:
  # Cleanup remains necessary even if the reserve guard stops proof execution.
  subprocess.run([tool('pg_ctl'),'-D',str(DATA),'-m','immediate','-w','stop'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=30)
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if receipt['passed']or not started:shutil.rmtree(DATA)
 shutil.rmtree(SOCK,ignore_errors=True)
