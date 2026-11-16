#!/usr/bin/env python3
"""Actual isolated PostgreSQL paid/direct-provenance proof. No hosted/provider IO."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path,required=True);a=p.parse_args();OUT=a.evidence_dir;OUT.mkdir(parents=True,exist_ok=True);OUT.chmod(0o700)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='direct-provenance-pg-',dir='/Volumes/Rendprop Files/Builds/Active'if Path('/Volumes/Rendprop Files/Builds/Active').is_dir()else None));SOCK=Path(tempfile.mkdtemp(prefix='direct-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
CANDIDATE,=list((SQL/'migrations').glob('*_direct_property_video_source_provenance.sql'));FIX=SQL/'tests/direct_property_video_source.sql';MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
ERASURE=SQL/'tests/direct_property_video_erasure.sql'
ERASE_MIGRATION,=list((SQL/'migrations').glob('*_direct_property_video_account_erasure_order.sql'))
SOURCES=[*MIGRATIONS,FIX,ERASURE,SQL/'tests/ci-bootstrap.sql',SQL/'tests/app_video_submission_receipts.sql',SQL/'tests/account_deletion_integrity.sql',SQL/'tests/account_deletion_studio_inventory.sql',Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'scope':'actual complete migration chain/roles/settlement/current source/immutable binding/concurrency, synthetic transport facts only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'migrationCount':len(partition_fresh_migrations(MIGRATIONS)[0]),'commands':[],'controls':[],'races':[]};started=False
SIGNATURE='record_direct_property_video_source(uuid,uuid,text,uuid,uuid,uuid,text,text,text,text,text,text)'
def run(name,cmd,body=None,refuses=None):
 r=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 (OUT/(name+'.log')).write_text(r.stdout);(OUT/(name+'.log')).chmod(0o600);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode and refuses in r.stdout)if refuses else r.returncode==0,(name,r.stdout[-5000:]);return r.stdout

def race(name,bodies):
 barrier=Barrier(len(bodies))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10);r=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  path=OUT/f'{name}-{i}.log';path.write_text(r.stdout);path.chmod(0o600);return{'exit':r.returncode,'output':r.stdout.strip()}
 with ThreadPoolExecutor(max_workers=len(bodies))as pool:return list(pool.map(call,enumerate(bodies)))
def statement(i,edited=False):
 asset="'f8540000-0000-4000-8000-000000000002'"if edited else"'f8540000-0000-4000-8000-000000000001'"
 prov="'f8580000-0000-4000-8000-000000000002'"if edited else'null';sha='b'if edited else'a'
 return f"select record_direct_property_video_source(actor,org,'direct-fixture:{i}',listing,{asset},{prov},'accepted-{i}',repeat('{sha}',64),repeat('a',32),'Kitchen','side_glide','same source')->>'provenance_id'from public.direct_race_scope;"
def held_race(name,holder,reader,needle):
 proc=subprocess.Popen([*PSQL,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV,cwd=ROOT)
 proc.stdin.write(holder);proc.stdin.close();lines=[]
 while True:
  line=proc.stdout.readline();
  if not line:
   path=OUT/(name+'-holder-failed.log');path.write_text(''.join(lines));path.chmod(0o600);raise AssertionError((name,'holder failed before lock marker',''.join(lines)[-3000:]))
  lines.append(line)
  if line.strip()=='LOCKED':break
 run(name+'-late-call',[*PSQL,'-Atq'],reader,refuses=needle)
 lines.append(proc.stdout.read());assert proc.wait(timeout=20)==0,''.join(lines)[-3000:]
 path=OUT/(name+'-holder.log');path.write_text(''.join(lines));path.chmod(0o600)
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55589 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55589','-U','postgres'];run('createdb',[tool('createdb'),*conn,'direct_provenance'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','direct_provenance','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 erasure_before=None
 catalog="select jsonb_build_object('owner',proowner,'security_definer',prosecdef,'config',proconfig,'acl',proacl)from pg_proc where oid='prepare_account_deletion(uuid,text,text)'::regprocedure"
 for m in partition_fresh_migrations(MIGRATIONS)[0]:
  if m==ERASE_MIGRATION:erasure_before=run('erasure-catalog-before',[*PSQL,'-Atq','-c',catalog])
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==ERASE_MIGRATION:assert run('erasure-catalog-after',[*PSQL,'-Atq','-c',catalog])==erasure_before,'Canonical erasure authority metadata changed'
 run('replay-erasure-migration',[*PSQL,'-q','-1','-f',ERASE_MIGRATION])
 erasure_sql=FIX.read_text().split('-- END SYNTHETIC FIXTURE')[0]+ERASURE.read_text()
 erasure_result=run('actual-direct-background-erasure',[*PSQL,'-Atq'],erasure_sql)
 receipt['erasure']=next(json.loads(x)for x in erasure_result.splitlines()if x.startswith('{')and'erasureAssertions'in x)
 erased_definition=run('read-erasure-body',[*PSQL,'-Atq','-c',"select pg_get_functiondef('prepare_account_deletion(uuid,text,text)'::regprocedure)"])
 for label,line,foreign_key in [
  ('direct-bindings','  delete from public.property_video_sources where listing_id=any(listing_ids);','property_video_sources_source_asset_id_fkey'),
  ('background-bindings','  delete from public.property_video_job_sources where job_id in(select id from public.property_video_jobs where listing_id=any(listing_ids));','property_video_job_sources_asset_id_fkey'),
  ('prepared-bindings','  delete from public.property_video_preparations where listing_id=any(listing_ids);','property_video_preparations_original_asset_id_fkey'),
  ('composition-bindings','  delete from public.property_video_compositions where listing_id=any(listing_ids);','property_video_compositions_asset_id_fkey')]:
  assert erased_definition.count(line)==1
  run('compile-erasure-'+label,[*PSQL,'-Atq'],erased_definition.replace(line,'',1))
  run('negative-erasure-'+label,[*PSQL,'-Atq'],erasure_sql,refuses=foreign_key)
  run('restore-erasure-'+label,[*PSQL,'-Atq'],erased_definition);receipt['controls'].append('compiled omitted erasure '+label+' reproduces restrictive FK failure')
 for name in ['account_deletion_integrity','account_deletion_studio_inventory']:
  run('existing-'+name,[*PSQL,'-Atq','-f',SQL/('tests/'+name+'.sql')])
 receipt['existingDeletionFixtures']=['actual29-assertion account_deletion_integrity','actual Studio/voice/logo deletion inventory']
 for stage in ['fresh','replay']:
  if stage=='replay':run('replay-own-migration',[*PSQL,'-q','-1','-f',CANDIDATE])
  output=run(stage,[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in output.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 original=run('read-candidate',[*PSQL,'-Atq','-c',f"select pg_get_functiondef('{SIGNATURE}'::regprocedure)"])
 # Compiled actual SQL regressions must fail the same acceptance oracles.
 anchor="  insert into public.media_provenance(org_id,listing_id,kind,model_id,edit,label,style,prompt_summary,disclosure)";assert original.count(anchor)==1
 mutated=original.replace(anchor,"  select *into g from public.media_provenance where listing_id=p_listing and kind='reel'order by created_at desc limit 1;\n  if g.id is null then\n"+anchor,1)
 needle="public.provenance_disclosure('reel','reel'))returning *into g;";assert mutated.count(needle)==1
 mutated=mutated.replace(needle,needle+'\n  end if;',1)
 run('compile-old-dedupe',[*PSQL,'-Atq'],mutated);run('negative-old-dedupe',[*PSQL,'-Atq','-f',FIX],refuses='different paid requests within60s');run('restore-old-dedupe',[*PSQL,'-Atq'],original);receipt['controls'].append('compiled legacy60s-style shared provenance regression detected')
 needle="  bound:=public.bind_property_video_source(p_actor,p_listing,p_asset,p_photo_provenance,\n   p_request,g.id,p_sha256,p_qc_hash);";assert original.count(needle)==1
 run('compile-missing-bind',[*PSQL,'-Atq'],original.replace(needle,"  bound:='{\"bound\":true}'::jsonb;",1));run('negative-missing-bind',[*PSQL,'-Atq','-f',FIX],refuses='same request replays exact provenance');run('restore-bind',[*PSQL,'-Atq'],original);receipt['controls'].append('compiled missing atomic bind regression detected')
 run('compatibility-submission-receipts',[*PSQL,'-Atq','-f',SQL/'tests/app_video_submission_receipts.sql'])
 setup=FIX.read_text().split('-- END SYNTHETIC FIXTURE')[0].replace('set local ','set ')
 setup+="create table public.direct_race_scope as select*from vf;grant select on public.direct_race_scope to service_role;commit;"
 run('race-setup',[*PSQL,'-Atq'],setup)
 results=race('same-paid-request',[statement(8),statement(8)]);assert all(x['exit']==0 for x in results)and results[0]['output']==results[1]['output'],results
 assert run('race-one-row',[*PSQL,'-Atq','-c',"select count(*)from property_video_sources where request_id='accepted-8'"]).strip()=='1'
 receipt['races'].append({'name':'same-paid-request','bothReturnSameProvenance':True,'oneBinding':True})
 # Removing only the reservation exclusivity makes concurrent first calls
 # disagree. Forced post-read pause is a negative-control interleaving only.
 needle='where actor_id=p_actor and org_id=p_org and idempotency_key=p_key for update;';assert original.count(needle)==1
 mutant=original.replace(needle,needle.replace('for update','for share'),1)
 needle='select *into s from public.property_video_sources where request_id=p_request;';assert mutant.count(needle)==1;mutant=mutant.replace(needle,needle+'\n perform pg_sleep(0.4);',1)
 run('compile-missing-reservation-lock',[*PSQL,'-Atq'],mutant)
 results=race('negative-missing-reservation-lock',[statement(10),statement(10)]);assert sum(x['exit']==0 for x in results)==1 and any('immutable'in x['output']for x in results),results
 run('restore-reservation-lock',[*PSQL,'-Atq'],original);receipt['controls'].append('compiled missing exclusive reservation lock loses exact concurrent replay')
 held_race('source-withdrawal',"begin;set role service_role;select record_media_qc('f8580000-0000-4000-8000-000000000002',org,'{\"publishable\":false,\"action\":\"hold\"}')from public.direct_race_scope;select 'LOCKED';select pg_sleep(1);commit;",'set role service_role;'+statement(9,edited=True),'RP409:')
 assert run('no-row-after-withdrawal',[*PSQL,'-Atq','-c',"select count(*)from property_video_sources where request_id='accepted-9'"]).strip()=='0'
 receipt['races'].append({'name':'source-withdrawal-vs-late-binding','currentRowRefused':True,'noBindingOrOrphan':True})
 held_race('canonical-account-deletion',"begin;set role service_role;select prepare_account_deletion(actor,'fixture-uploads','fixture-renders')from public.direct_race_scope;select 'LOCKED';select pg_sleep(1);commit;",'set role service_role;'+statement(11),'RP404:')
 assert run('no-row-after-deletion',[*PSQL,'-Atq','-c',"select count(*)from property_video_sources"]).strip()=='0'
 receipt['races'].append({'name':'canonical-account-deletion-vs-late-binding','noResurrection':True,'actualProductionDeletion':True})
 assert hashes()==receipt['sourceHashes'],'Consumed source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'fresh':receipt['fresh']['assertions'],'replay':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');(OUT/'receipt.json').chmod(0o600)
 if not started or not(DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
