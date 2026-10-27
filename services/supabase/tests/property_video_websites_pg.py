#!/usr/bin/env python3
"""Actual local migration/RPC/role tests plus consumable-assignment races.
No inherited credentials, TCP listener, Apple/R2 or production database.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-property-sites-pg-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='rendprop-property-sites-owned-pg-',dir='/tmp'));SOCK=Path(tempfile.mkdtemp(prefix='rendprop-property-sites-socket-',dir='/tmp'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
assert all(Path(t).is_file()and os.access(t,os.X_OK)for t in TOOLS.values())
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/property_video_websites.sql',Path(__file__).resolve()]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in SOURCES}
receipt={'passed':False,'scope':'owned disposable PostgreSQL, actual schema/RPC/roles/races; transport/provider fixtures closed','networkCalls':0,'AppleCalls':0,'sourceHashes':hashes(),'commands':[],'races':[]}
def run(name,argv,sql=None):
 r=subprocess.run([str(a)for a in argv],input=sql,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert r.returncode==0,(name,r.stdout[-3000:]);return r.stdout
def race(name,statements,role="service_role"):
 barrier=Barrier(len(statements))
 def invoke(pair):
  i,statement=pair;barrier.wait(timeout=10)
  r=subprocess.run([*PSQL,'-Atq'],input=f'set role {role};'+statement,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  (OUT/f'{name}-{i}.log').write_text(r.stdout);return {'exit':r.returncode,'output':r.stdout}
 with ThreadPoolExecutor(max_workers=len(statements))as pool:return list(pool.map(invoke,enumerate(statements)))
started=False
try:
 run('version',[TOOLS['psql'],'--version']);run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55537 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55537','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'property_sites'])
 PSQL=[TOOLS['psql'],'-X','--no-password',*conn,'-d','property_sites','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for migration in partition_fresh_migrations(sorted((SQL / 'migrations').glob('*.sql')))[0]:run('apply-'+migration.stem,[*PSQL,'-q','-1','-f',migration])
 newest=SQL/'migrations/20261014162938_property_video_websites.sql';run('replay-property-migration',[*PSQL,'-q','-1','-f',newest])
 for newer in sorted(set((SQL/'migrations').glob('20261014*property_video*.sql'))|set((SQL/'migrations').glob('20261014*registered_background_video_delivery.sql'))):
  if newer.name!='20261014162938_property_video_websites.sql':run('replay-'+newer.stem,[*PSQL,'-q','-1','-f',newer])
 unit=run('actual-rpc-roles',[*PSQL,'-Atq','-f',SQL/'tests/property_video_websites.sql']);rows=[json.loads(s)for s in unit.splitlines()if s.startswith('{')and 'assertions'in s];assert len(rows)==1 and rows[0]['passed'];receipt['unit']=rows[0]
 actor='eb100000-0000-4000-8000-000000000001';listings=[f'eb300000-0000-4000-8000-00000000000{i}'for i in range(1,5)]
 run('race-fixtures',[*PSQL,'-Atq'],f"""insert into auth.users(id,email,is_anonymous)values('{actor}','race-upgrade@fixture.invalid',false);
 update property_website_products set production_enabled=true;
 insert into listings(id,org_id,agent_id,address)select x::uuid,(select org_id from memberships where user_id='{actor}'and role='owner'limit 1),'{actor}','Synthetic race property'from unnest(array{listings!r}::text[])x;""")
 org=run('race-org',[*PSQL,'-Atq','-c',f"select org_id from memberships where user_id='{actor}'and role='owner'limit 1"]).strip()
 def claim(tx,listing):return f"select property_website_transaction('{actor}','{listing}','{org}','Production','{tx}','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:01Z',null,'purchase');"
 result=race('one-transaction-two-properties',[claim('race-one',x)for x in listings[:2]])
 assert sum(r['exit']==0 for r in result)==1 and any('RP409:'in r['output']for r in result),result
 receipt['races'].append({'name':'one-transaction-two-properties','exactlyOneAssigned':True,'loserRefused':True})
 result=race('two-transactions-one-property',[claim('race-two-a',listings[2]),claim('race-two-b',listings[2])]);assert all(r['exit']==0 for r in result),result
 outcomes=[json.loads(next(line for line in r['output'].splitlines()if line.startswith('{')))for r in result]
 assert sum(x['assigned']is True for x in outcomes)==1 and sum(x['credit_available']is True for x in outcomes)==1,outcomes
 receipt['races'].append({'name':'two-transactions-one-property','exactlyOneAssigned':True,'otherPaidCreditDurablyRetained':True})
 # Removing only the property lock and forcing the same observed empty slot
 # loses the second paid credit to the unique constraint. Safety is more than
 # avoiding double grants: the durable purchase must survive that refusal.
 signature='public.property_website_transaction(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,boolean)'
 original=run('read-assignment-function',[*PSQL,'-Atq','-c',f"select pg_get_functiondef('{signature}'::regprocedure)"])
 old="if p_listing is not null then perform pg_advisory_xact_lock(hashtextextended('property_upgrade:'||p_environment||':'||p_listing,42));end if;";assert old in original
 mutated=original.replace(old,'-- omitted property assignment lock',1)
 needle='  update public.property_website_transactions set assigned_listing_id=p_listing';assert needle in mutated
 mutated=mutated.replace(needle,'  perform pg_sleep(0.3);\n'+needle,1);run('install-assignment-mutant',[*PSQL,'-Atq'],mutated)
 result=race('negative-no-property-lock',[claim('negative-a',listings[3]),claim('negative-b',listings[3])]);assert sum(r['exit']==0 for r in result)==1 and any('duplicate key'in r['output']for r in result),result
 count=run('negative-retained-count',[*PSQL,'-Atq','-c',"select count(*)from property_website_transactions where transaction_id in('negative-a','negative-b')"]).strip();assert count=='1'
 receipt['races'].append({'name':'negative-no-property-lock','rejected':True,'concreteFailure':'one paid receipt rolled back instead of being retained unassigned'})
 run('restore-assignment-function',[*PSQL,'-Atq'],original)
 # Actual concurrent selection operations, not client-generated URL fixtures.
 photo='ec400000-0000-4000-8000-000000000001';poster='ec400000-0000-4000-8000-000000000002';videos=[f'ec400000-0000-4000-8000-00000000000{i}'for i in [3,4,5]];target=listings[0]
 assets=[(photo,'photo','uploads','source.jpg'),(poster,'photo','renders','first-clip.jpg'),*[(v,'video','renders',f'output-{i}.mp4')for i,v in enumerate(videos)]]
 inserts=','.join(f"('{a}','{target}','{kind}','{bucket}','{bucket}/{org}/{target}/{filename}',1000,'{'a'*64}',true,2,'{'video/mp4'if kind=='video'else'image/jpeg'}')"for a,kind,bucket,filename in assets)
 run('video-race-fixtures',[*PSQL,'-Atq'],f"""set session_replication_role=replica;
 insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)values {inserts};
 insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)select id,'{org}',listing_id,'{actor}',current_date,'{{}}',0,bytes,'completed',now()from capture_assets where id::text like 'ec400000-%';
 insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)select id,'copy',bucket,storage_key,bytes,bytes,content_type,true,kind,'retained','"race-etag"'from capture_assets where id::text like 'ec400000-%';
 insert into render_jobs(id,listing_id,capture_asset_id,status,source)values('ec500000-0000-4000-8000-000000000001','{target}','{videos[2]}','ready','app');
 insert into renders(id,job_id,listing_id,slug,duration_s,video_key,published_at)values('ec600000-0000-4000-8000-000000000001','ec500000-0000-4000-8000-000000000001','{target}','synthetic-race-website',15,'renders/{org}/{target}/recorded.mp4',now());
 set session_replication_role=origin;set role service_role;
 """+''.join(f"select record_property_video_attestation('{actor}','{target}','{v}','\"race-etag\"',1000,1920,1080,15);"for v in videos))
 manifest=json.dumps({'schema':1,'purpose':'listing','aspect':'16:9','branding_policy':'unbranded','sources':[{'photo_asset_id':photo,'photo_version_id':'private-source-version','motion_kind':'original_photo'}]},separators=(',',':'))
 def select_video(video,op):return f"set request.jwt.claim.sub='{actor}';select (publish_property_video('{target}','{video}','{manifest}'::jsonb,'{poster}','photo-video:{op}')).slug;"
 op1='ec700000-0000-4000-8000-000000000001';op2='ec700000-0000-4000-8000-000000000002'
 result=race('concurrent-new-video-selections',[select_video(videos[0],op1),select_video(videos[1],op2)],'authenticated');assert all(r['exit']==0 for r in result),result
 selected=run('selected-after-race',[*PSQL,'-Atq','-c',f"select c.asset_id||'|'||o.operation_key from property_video_publication_ops o join property_video_compositions c on c.id=o.composition_id where o.listing_id='{target}'order by o.selection_revision desc limit 1"]).strip();selected_asset,latest_key=selected.split('|');latest_op=latest_key.split(':',1)[1];old_op=op1 if latest_op==op2 else op2;old_asset=videos[0]if old_op==op1 else videos[1]
 result=race('lost-reply-old-versus-current',[select_video(old_asset,old_op),select_video(selected_asset,latest_op)],'authenticated');assert sum(r['exit']==0 for r in result)==1 and any('publication_superseded:'in r['output']for r in result),result
 assert run('selection-revisions',[*PSQL,'-Atq','-c',f"select count(*)||'|'||max(selection_revision)from property_video_publication_ops where listing_id='{target}'"]).strip()=='2|2'
 result=race('explicit-reselect-old',[select_video(old_asset,'ec700000-0000-4000-8000-000000000003')],'authenticated');assert result[0]['exit']==0,result
 assert run('explicit-reselect-state',[*PSQL,'-Atq','-c',f"select asset_id from property_video_compositions where listing_id='{target}'and selected"]).strip()==old_asset
 receipt['races'].append({'name':'concurrent-selections-and-lost-reply','bothExplicitOpsPersisted':True,'oldRetryRefusedWithoutBackwardsSelection':True,'currentRetryNoNewRevision':True,'freshReselectOldSucceeds':True})
 # A deliberate omission of the operation lock lets both select revision1.
 pubsig='public.publish_property_video(uuid,uuid,jsonb,uuid,text)';originalpub=run('read-publication-function',[*PSQL,'-Atq','-c',f"select pg_get_functiondef('{pubsig}'::regprocedure)"])
 lock=" perform pg_advisory_xact_lock(hashtextextended('property_video:'||p_listing::text,42));";assert lock in originalpub
 # Pause after observing immutable output and latest state. Clearing prior
 # rows leaves an exact empty selection slot for this isolated negative.
 run('video-race-negative-reset',[*PSQL,'-Atq'],f"delete from property_video_publication_ops where listing_id='{target}';delete from property_video_compositions where listing_id='{target}';")
 mutatedpub=originalpub.replace(lock,' -- omitted selection operation lock',1).replace(' update public.property_video_compositions set selected=false where listing_id=p_listing and selected;', ' update public.property_video_compositions set selected=false where listing_id=p_listing and selected;\n perform pg_sleep(0.3);',1)
 run('install-selection-mutant',[*PSQL,'-Atq'],mutatedpub)
 result=race('negative-no-selection-lock',[select_video(videos[0],'ec700000-0000-4000-8000-000000000004'),select_video(videos[1],'ec700000-0000-4000-8000-000000000005')],'authenticated');assert sum(r['exit']==0 for r in result)==1 and any('duplicate key'in r['output']for r in result),result
 receipt['races'].append({'name':'negative-no-selection-lock','rejected':True,'concreteFailure':'one valid explicit selection rolls back on shared selected/revision invariant'})
 run('restore-selection-function',[*PSQL,'-Atq'],originalpub)
 assert hashes()==receipt['sourceHashes'],'Source changed during verification';receipt['passed']=True
 print(json.dumps({'passed':True,'assertions':receipt['unit']['assertions'],'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','-t','30','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or receipt['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
