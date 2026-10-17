#!/usr/bin/env python3
"""Actual isolated PG gallery authority, CAS, immutable replay and races.
No production connection, media download, provider call or copied credentials.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,uuid
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='gallery-remove-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='gallery-remove-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='gallery-remove-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
REMOVAL=SQL/'migrations/20261017110321_preserve_gallery_removal_projection_order.sql';MIG=SQL/'migrations/20261015144353_atomic_listing_gallery_remove.sql';FIX=SQL/'tests/listing_gallery_remove.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',FIX,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'scope':'disposable actual PostgreSQL/schema/roles/concurrency, synthetic metadata only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]}
started=False
def run(name,cmd,body=None,refuses=None):
 r=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode and refuses in r.stdout)if refuses else r.returncode==0,(name,r.stdout[-6000:]);return r.stdout
def race(name,bodies):
 barrier=Barrier(len(bodies))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10)
  r=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  (OUT/f'{name}-{i}.log').write_text(r.stdout);return{'exit':r.returncode,'output':r.stdout}
 with ThreadPoolExecutor(max_workers=len(bodies))as pool:return list(pool.map(call,enumerate(bodies)))
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55583 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55583','-U','postgres'];run('createdb',[tool('createdb'),*conn,'gallery_remove_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','gallery_remove_proof','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in MIGRATIONS:
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   boundary=run('old-own-boundary',[*PSQL,'-Atq','-c',"select pg_get_functiondef('public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)'::regprocedure)"]);run('replay-old-at-own-boundary',[*PSQL,'-q','-1','-f',MIG]);assert run('old-own-boundary-replayed',[*PSQL,'-Atq','-c',"select pg_get_functiondef('public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)'::regprocedure)"])==boundary
 for stage in ['fresh','replay']:
  if stage=='replay':run('replay-current-removal-migration',[*PSQL,'-q','-1','-f',REMOVAL])
  out=run(stage+'-actual-gallery-remove',[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 for label,signature,anchor,replacement,oracle in [
  ('stale-CAS','public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)','if l.gallery_asset_ids is distinct from p_expected or l.main_photo_key is distinct from p_expected_main then','if false then','ordered stale gallery CAS refuses'),
  ('asset-scope','public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)','if valid_count<>cardinality(p_remove)then','if false then','refuse unavailable or cross-property asset'),
  ('caller-authority','public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)','perform public.client_listing_access(p_user,p_org,p_listing,true);','null;','outsider cannot remove'),
  ('empty-selection','public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)','gallery_asset_ids=remaining,',"gallery_asset_ids=nullif(remaining,'{}'::uuid[]),",'last removal stores explicit empty gallery'),
  ('snapshot-selection','public.listing_gallery_snapshot(uuid,uuid,uuid)','(l.gallery_asset_ids is null or a.id=any(l.gallery_asset_ids))','(true)','snapshot cannot match an unselected historical upload')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'exact production anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  receipt['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationRejected':True})
 # Synthetic committed fixture for real concurrent sessions; all other checks rollback.
 fixture=FIX.read_text().split('-- BEGIN FIXTURE\n',1)[1].split('-- END FIXTURE',1)[0]
 run('race-setup',[*PSQL,'-Atq'],'begin;create temp table checks(label text primary key);'+fixture+'create table public.gallery_remove_race as select *from gf;grant select on public.gallery_remove_race to service_role;commit;')
 def remove(op,which='p1'):
  return "select public.remove_listing_gallery(actor,org,listing,'%s',array[%s],array[p1,p3,p2],'renders/'||org||'/'||listing||'/gallery-'||p1||'.jpg')from public.gallery_remove_race;"%(op,which)
 op=str(uuid.uuid4());results=race('same-operation',[remove(op),remove(op)]);assert all(x['exit']==0 for x in results),results
 replies=[json.loads(next(x for x in r['output'].splitlines()if x.startswith('{')))for r in results];assert sorted(r['gallery_remove']['replayed']for r in replies)==[False,True],replies
 count=run('same-operation-count',[*PSQL,'-Atq','-c',"select count(*)from public.listing_gallery_removals where operation_id='%s'"%op]).strip();assert count=='1'
 receipt['races'].append({'name':'same-operation','requests':2,'oneReceipt':True,'oneReplay':True})
 run('race-reset',[*PSQL,'-Atq'],"update public.listings l set gallery_asset_ids=array[f.p1,f.p3,f.p2],main_photo_key='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p1||'.jpg'from public.gallery_remove_race f where l.id=f.listing;")
 results=race('competing-snapshots',[remove(str(uuid.uuid4()),'p1'),remove(str(uuid.uuid4()),'p2')]);assert sum(r['exit']==0 for r in results)==1 and sum('The listing photo selection changed'in r['output']for r in results)==1,results
 receipt['races'].append({'name':'competing-snapshots','requests':2,'oneAccepted':True,'oneStaleRefused':True,'unknownRemotePreserved':True})
 assert hashes()==receipt['sourceHashes'],'Source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':receipt['fresh']['assertions'],'replayAssertions':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or receipt['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
