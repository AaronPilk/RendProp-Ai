#!/usr/bin/env python3
"""Real service/tenant cleanup boundaries; owned socket-only synthetic cluster."""
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile
from datetime import datetime,timezone
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase';TARGET=SQL/'migrations/20261005220002_privacy_cleanup_inventory.sql';TEST=SQL/'tests/privacy_cleanup_inventory.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-privacy-cleanup-',dir='/tmp'));SOCK=OUT/'socket';DATA=OUT/'cluster';SOCK.mkdir(mode=0o700)
BIN={n:shutil.which(n)for n in('initdb','pg_ctl','createdb','psql')};assert all(BIN.values())
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
CONN=['-h',str(SOCK),'-p','55480','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_privacy_audit','-v','ON_ERROR_STOP=1','-Atq']
tracked=[*MIGRATIONS,TEST,pathlib.Path(__file__).resolve(),SQL/'tests/ci-bootstrap.sql'];hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'passed':False,'commands':[],'productionMutations':0,'providerCalls':0}
def run(name,args,stdin=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout);receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});assert p.returncode==expected,(name,p.returncode,p.stdout[-2500:]);return p.stdout
def query(name,text,expected=0):return run(name,PSQL,text,expected)
def positive(name):
 out=query(name,TEST.read_text());m=re.search(r'\n(\d+)\nPASS: cleanup inventory assertions; fixtures rolled back\.',out);assert m and int(m[1])==61,(name,out[-1000:]);return int(m[1])
started=False;print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55480 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_privacy_audit']);assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in MIGRATIONS:query('migration-'+p.stem,p.read_text())
 receipt['freshAssertions']=positive('fresh');query('replay',TARGET.read_text());receipt['replayAssertions']=positive('replayed')
 faults=[
  ('output-foreign-actor','public.register_private_ai_output(uuid,uuid,uuid,text,text,bigint)',"or not exists(select 1 from public.memberships where user_id=p_user and org_id=p_org)","or false ",'foreign actor cannot journal another org output'),
  ('output-live-listing','public.register_private_ai_output(uuid,uuid,uuid,text,text,bigint)',"where id=p_listing and org_id=p_org and deleted_at is null for update","where id=p_listing and org_id=p_org for update",'deleted listing blocks fresh output write intent'),
  ('cleanup-exact-lease','public.privacy_cleanup_finish(uuid,uuid,jsonb,text)',"or row.lease_token is distinct from p_token","or false ",'stale cleanup token cannot acknowledge deletion'),
  ('cleanup-target-subset','public.privacy_cleanup_finish(uuid,uuid,jsonb,text)',"not((row.remaining->field) @> (p_remaining->field))","false ",'cleanup cannot retarget foreign object'),
  ('cleanup-unknown-category','public.privacy_cleanup_finish(uuid,uuid,jsonb,text)',"or exists(select 1 from jsonb_object_keys(p_remaining)k where k not in('r2','stream_uids','ghl_targets'))","or false ",'unknown cleanup category cannot be dropped'),
  ('lead-complete-scrub','public.privacy_cleanup_finish(uuid,uuid,jsonb,text)',"payload=case when done then p_remaining else payload end","payload=payload",'completed lead cleanup erases original email phone inventory'),
  ('output-retain-unconfirmed','public.privacy_cleanup_finish(uuid,uuid,jsonb,text)',"if done and row.kind='listing'","if row.kind='listing'",'pending listing cleanup retains exact output journal'),
  ('output-prune-exact-listing','public.privacy_cleanup_finish(uuid,uuid,jsonb,text)',"where org_id=row.org_id and listing_id=row.source_id","where org_id=row.org_id",'listing completion preserves unrelated account output journal'),
  ('account-output-drain','public.finish_account_deletion(uuid,uuid,jsonb,text)',"if r.payload->>'storage_not_before'is not null and(r.payload->>'storage_not_before')::timestamptz>clock_timestamp()then","if false then",'account output prefix waits for admitted write deadline'),
 ]
 controls=[]
 for name,fn,old,new,label in faults:
  original=query(name+'-definition',f"select pg_get_functiondef('{fn}'::regprocedure);")
  assert original.count(old)==1,(name,'missing precise fault anchor',original.count(old))
  query(name+'-compile',original.replace(old,new))
  failure=query(name+'-run',TEST.read_text(),3);assert label in failure and('CLEANUP DENIAL:'in failure or 'CLEANUP FAIL:'in failure),(name,failure[-1400:])
  query(name+'-restore',original);assert positive(name+'-restored')==receipt['freshAssertions'];controls.append({'name':name,'failedBoundary':label,'compiled':True,'restored':True})
 receipt['controls']=controls
 assert hashes=={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked},'Source changed during proof'
 receipt.update(passed=True,finishedAt=datetime.now(timezone.utc).isoformat())
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS:',receipt['freshAssertions'],'cleanup assertions on fresh/replay',flush=True)
