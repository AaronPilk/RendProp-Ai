#!/usr/bin/env python3
"""Real service/tenant cleanup boundaries; owned socket-only synthetic cluster."""
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile
from datetime import datetime,timezone
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase';TARGET=SQL/'migrations/20261005222001_upload_identity_monthly_technical_ceiling.sql';TEST=SQL/'tests/upload_privacy_admission.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-upload-privacy-',dir='/tmp'));SOCK=OUT/'socket';DATA=OUT/'cluster';SOCK.mkdir(mode=0o700)
BIN={n:shutil.which(n)for n in('initdb','pg_ctl','createdb','psql')};assert all(BIN.values())
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
CONN=['-h',str(SOCK),'-p','55481','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_privacy_audit','-v','ON_ERROR_STOP=1','-Atq']
tracked=[*MIGRATIONS,TEST,pathlib.Path(__file__).resolve(),SQL/'tests/ci-bootstrap.sql'];hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'passed':False,'commands':[],'productionMutations':0,'providerCalls':0}
def run(name,args,stdin=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout);receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});assert p.returncode==expected,(name,p.returncode,p.stdout[-2500:]);return p.stdout
def query(name,text,expected=0):return run(name,PSQL,text,expected)
def positive(name):
 out=query(name,TEST.read_text());m=re.search(r'\n(\d+)\nPASS: upload privacy assertions; fixtures rolled back\.',out);assert m and int(m[1])>=15,(name,out[-1000:]);return int(m[1])
started=False;print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55481 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_privacy_audit']);assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in MIGRATIONS:query('migration-'+p.stem,p.read_text())
 receipt['freshAssertions']=positive('fresh')
 # Replay the historical migration before the later launch patches; applying
 # it backwards to the final schema would replace current security guards.
 final_psql=PSQL
 run('create-historical',[BIN['createdb'],'--no-password',*CONN,'rendprop_privacy_audit_replay'])
 PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_privacy_audit_replay','-v','ON_ERROR_STOP=1','-Atq']
 query('bootstrap-historical',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in MIGRATIONS:
  query('historical-'+p.stem,p.read_text())
  if p==TARGET:query('ordered-replay-'+p.stem,p.read_text())
 receipt['replayAssertions']=positive('replayed')
 receipt['replayMode']='second clean database; target migration twice at historical schema point'
 PSQL=final_psql

 faults=[
  ('anonymous-retail-admission','public.upload_new_admission(uuid,uuid,bigint)',"if anonymous then","if false then",'unpaid anonymous cannot reserve upload'),
  ('sandbox-receipt-admission','public.upload_new_admission(uuid,uuid,bigint)',"s.environment='Production'","s.environment in('Production','Sandbox')",'Sandbox receipt cannot fund anonymous upload'),
  ('guest-receipt-actor','public.upload_new_admission(uuid,uuid,bigint)',"s.user_id=p_actor","true",'guest cannot borrow another account paid receipt'),
  ('monthly-byte-ceiling','public.upload_new_admission(uuid,uuid,bigint)',"if used+p_hold>cap then","if false then",'monthly physical bytes include historical spent plus current held'),
 ]
 controls=[]
 for name,fn,old,new,label in faults:
  original=query(name+'-definition',f"select pg_get_functiondef('{fn}'::regprocedure);")
  assert original.count(old)==1,(name,'missing exact fault anchor')
  query(name+'-compile',original.replace(old,new))
  failure=query(name+'-run',TEST.read_text(),3)
  assert label in failure and ('UPLOAD DENIAL:'in failure or 'UPLOAD FAIL:'in failure),(name,failure[-1600:])
  query(name+'-restore',original);assert positive(name+'-restored')==receipt['freshAssertions']
  controls.append({'name':name,'failedBoundary':label,'compiled':True,'restored':True})
 receipt['controls']=controls

 assert hashes=={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked},'Source changed during proof'
 receipt.update(passed=True,finishedAt=datetime.now(timezone.utc).isoformat())
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS:',receipt['freshAssertions'],'upload privacy assertions on fresh/replay',flush=True)
