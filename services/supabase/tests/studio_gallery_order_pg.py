#!/usr/bin/env python3
"""Studio gallery upload order: actual migrations/RPCs/roles in an owned
socket-only PostgreSQL, real concurrent attach/reorder sessions, and compiled
negative controls of the real SQL. No network, provider or production access.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
TEST=SQL/'tests/studio_gallery_order.sql';MIGRATION=next((SQL/'migrations').glob('*_studio_gallery_upload_order.sql'))
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-gallery-order-pg-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='rendprop-gallery-order-owned-pg-',dir=os.environ.get('RENDPROP_PG_DATA_ROOT','/tmp')));SOCK=Path(tempfile.mkdtemp(prefix='rendprop-gallery-order-socket-',dir='/tmp'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
assert all(Path(t).is_file()and os.access(t,os.X_OK)for t in TOOLS.values())
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SCHEMA_MIGRATIONS,LIVE_STATE_MIGRATIONS=partition_fresh_migrations(MIGRATIONS)
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',TEST,Path(__file__).resolve()]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in SOURCES}
receipt={'passed':False,'scope':'owned disposable PostgreSQL; actual schema/RPC/roles and concurrent sessions; no transport','networkCalls':0,'sourceHashes':hashes(),'liveStateOnlyMigrations':[m.name for m in LIVE_STATE_MIGRATIONS],'commands':[],'races':[],'negativeControls':[]}
def run(name,argv,sql=None,expect=0):
 r=subprocess.run([str(a)for a in argv],input=sql,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode==0)if expect==0 else(r.returncode!=0),(name,r.returncode,r.stdout[-3000:]);return r.stdout
def race(name,statements,role='service_role'):
 barrier=Barrier(len(statements))
 def invoke(pair):
  i,statement=pair;barrier.wait(timeout=20);start=time.monotonic()
  r=subprocess.run([*PSQL,'-Atq'],input=f'set role {role};\n'+statement,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
  (OUT/f'{name}-{i}.log').write_text(r.stdout);return{'exit':r.returncode,'output':r.stdout,'seconds':round(time.monotonic()-start,3)}
 with ThreadPoolExecutor(max_workers=len(statements))as pool:return list(pool.map(invoke,enumerate(statements)))
started=False
try:
 run('version',[TOOLS['psql'],'--version']);run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55547 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55547','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'studio_gallery_order'])
 PSQL=[TOOLS['psql'],'-X','--no-password',*conn,'-d','studio_gallery_order','-v','ON_ERROR_STOP=1']
 def psql(name,sql,expect=0):return run(name,[*PSQL,'-Atq'],sql,expect)
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for migration in SCHEMA_MIGRATIONS:run('apply-'+migration.stem,[*PSQL,'-q','-1','-f',migration])
 run('replay-'+MIGRATION.stem,[*PSQL,'-q','-1','-f',MIGRATION])
 def unit(name):
  out=run(name,[*PSQL,'-Atq','-f',TEST]);rows=[json.loads(s)for s in out.splitlines()if s.startswith('{')and'assertions'in s];assert len(rows)==1 and rows[0]['passed'];return rows[0]
 receipt['unit']=unit('actual-gallery-order')
 # Compiled actual SQL mutants: the unchanged test must name the broken guarantee.
 for control,signature,needle,replacement,expected in [
  ('attach-at-sort-zero','public.studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid)','select least(coalesce(max(p.sort)+1,0),32767)::smallint into next_sort from public.photos p where p.listing_id=p_listing;','next_sort:=0;','ORDER FAIL: two uploads with repeated filenames and tied attach times keep upload order'),
  ('reorder-ignores-attach-time','public.studio_gallery_update_v2(uuid,uuid,uuid,text,uuid,jsonb,jsonb)','jsonb_agg(id order by sort,created_at,id)','jsonb_agg(id order by sort,id)','the current client reorders a tied legacy gallery by its displayed order'),
  ('reorder-refuses-prefix-client','public.studio_gallery_update_v2(uuid,uuid,uuid,text,uuid,jsonb,jsonb)','if current_order is distinct from p_expected and legacy_order is distinct from p_expected then','if current_order is distinct from p_expected then','ORDER FAIL: a pre-fix client naming (sort,id) still reorders the same tied snapshot')]:
  original=run('read-'+control,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(needle)==1,(control,'source anchor')
  run('compile-'+control,[*PSQL,'-Atq'],original.replace(needle,replacement,1))
  mutant=run('negative-'+control,[*PSQL,'-Atq','-f',TEST],expect=1);assert expected in mutant,(control,mutant[-3000:])
  receipt['negativeControls'].append({'name':control,'rejected':True,'concreteFailure':expected,'compiledActualSQL':True})
  run('restore-'+control,[*PSQL,'-Atq'],original)
 receipt['unitAfterRestore']=unit('actual-gallery-order-restored')

 text=TEST.read_text();psql('race-fixture',text[text.index('-- fixture:begin'):text.index('-- fixture:end')])
 ident=json.loads(psql('race-identity',"select jsonb_build_object('actor',actor,'org',org,'listing',race_listing)from order_bf;").strip());A,O,L=ident['actor'],ident['org'],ident['listing']
 TEAMMATE='fc100000-0000-4000-8000-000000000003'
 # The owner and a teammate upload to the same property at the same time.
 def attach(label,actor=None):return "select studio_attach_photo('%s','%s','%s',(select id from order_assets where label='%s'),(select caption from order_assets where label='%s'),null);"%(actor or A,O,L,label,label)
 def order():return json.loads(psql('race-order',"select jsonb_build_object('labels',coalesce(jsonb_agg(a.label order by p.sort,p.created_at,p.id),'[]'),'ids',coalesce(jsonb_agg(p.id order by p.sort,p.created_at,p.id),'[]'),'sorts',count(distinct p.sort),'rows',count(*))from photos p join order_assets a on a.id=p.id where p.listing_id='%s';"%L).strip())
 def reorder(expected,value):return "select studio_gallery_update_v2('%s','%s','%s','reorder',null,'%s','%s');"%(A,O,L,json.dumps(expected),json.dumps(value))
 # 1. Concurrent uploads each get their own position: no duplicate sort, no lost photo.
 result=race('concurrent-attaches',[attach('R%d'%i,TEAMMATE if i%2 else A)for i in range(1,9)]);s=order()
 assert all(r['exit']==0 for r in result)and s['rows']==8 and s['sorts']==8,(s,result)
 receipt['races'].append({'name':'concurrent-attaches','actualConcurrentRequests':8,'distinctPositions':s['sorts']})
 # 2. A reorder holding the lock: the waiting upload lands underneath the saved order.
 before=order();reversed_ids=list(reversed(before['ids']))
 result=race('reorder-commits-while-attach-waits',['begin;'+reorder(before['ids'],reversed_ids)+'select pg_sleep(1.2);commit;','select pg_sleep(0.3);'+attach('R9',TEAMMATE)]);s=order()
 assert result[0]['exit']==0 and result[1]['exit']==0 and result[1]['seconds']>=0.8 and s['ids'][:8]==reversed_ids and s['labels'][-1]=='R9' and s['sorts']==9,(s,result)
 receipt['races'].append({'name':'reorder-commits-while-attach-waits','attachWaitedSeconds':result[1]['seconds'],'newPhotoLast':True})
 # 3. An upload holding the lock: the stale reorder is refused instead of dropping the new photo.
 before=order()
 result=race('attach-commits-while-reorder-waits',['begin;'+attach('R10',TEAMMATE)+'select pg_sleep(1.2);commit;','select pg_sleep(0.3);'+reorder(before['ids'],list(reversed(before['ids'])))]);s=order()
 assert result[0]['exit']==0 and result[1]['exit']!=0 and'RP409:'in result[1]['output']and s['ids'][:9]==before['ids']and s['labels'][-1]=='R10'and s['sorts']==10,(s,result)
 receipt['races'].append({'name':'attach-commits-while-reorder-waits','staleReorderRefused':True,'newPhotoKept':True})
 # 4. Compiled race mutant: the append relies on studio_photo_authority's listing/org
 # row locks. Without them, two people's concurrent uploads collide on a position.
 attach_sig='public.studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid)';authority_sig='public.studio_photo_authority(uuid,uuid,uuid)'
 attach_original=run('read-attach',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%attach_sig])
 authority_original=run('read-authority',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%authority_sig])
 window='into next_sort from public.photos p where p.listing_id=p_listing;';assert attach_original.count(window)==1 and authority_original.count('deleted_at is null for update;')==2
 run('install-attach-window',[*PSQL,'-Atq'],attach_original.replace(window,window+'perform pg_sleep(0.3);',1))
 run('install-unlocked-authority',[*PSQL,'-Atq'],authority_original.replace('deleted_at is null for update;','deleted_at is null;'))
 psql('negative-reset',"delete from photos where listing_id='%s';"%L)
 race('negative-unlocked-gallery',[attach('R1'),attach('R2',TEAMMATE)]);s=order()
 assert s['rows']==2 and s['sorts']==1,('lock mutant was not detected',s)
 receipt['negativeControls'].append({'name':'unlocked-gallery-attach','rejected':True,'concreteFailure':'two people uploading at once received the same gallery position','observed':s})
 run('restore-authority',[*PSQL,'-Atq'],authority_original);run('restore-attach',[*PSQL,'-Atq'],attach_original)
 psql('restored-reset',"delete from photos where listing_id='%s';"%L)
 race('restored-unlocked-check',[attach('R1'),attach('R2',TEAMMATE)]);s=order();assert s['rows']==2 and s['sorts']==2,s
 assert hashes()==receipt['sourceHashes'],'Source changed during verification';receipt['passed']=True
 print(json.dumps({'passed':True,'assertions':receipt['unit']['assertions'],'races':len(receipt['races']),'negativeControls':len(receipt['negativeControls']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','-t','30','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or receipt['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
