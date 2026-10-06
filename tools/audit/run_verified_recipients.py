#!/usr/bin/env python3
"""Actual recipient/privacy migration proof in an owned socket-only Postgres."""
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile
from datetime import datetime,timezone
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
TARGET=SQL/'migrations/20261005220001_verified_notification_and_client_recipients.sql'
TEST=SQL/'tests/verified_recipients.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-verified-recipients-',dir='/tmp'));SOCK=OUT/'socket';DATA=OUT/'cluster';SOCK.mkdir(mode=0o700)
BIN={n:shutil.which(n)for n in('initdb','pg_ctl','createdb','psql')};assert all(BIN.values())
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
CONN=['-h',str(SOCK),'-p','55479','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_privacy_audit','-v','ON_ERROR_STOP=1','-Atq']
tracked=[*MIGRATIONS,TEST,pathlib.Path(__file__).resolve(),SQL/'tests/ci-bootstrap.sql']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'passed':False,'commands':[],'productionMutations':0,'providerCalls':0}
def run(name,args,stdin=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout);receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert p.returncode==expected,(name,p.returncode,p.stdout[-2500:])
 return p.stdout
def query(name,text,expected=0):return run(name,PSQL,text,expected)
def positive(name):
 out=query(name,TEST.read_text());m=re.search(r'\n(\d+)\nPASS: recipient privacy assertions; fixtures rolled back\.',out);assert m and int(m[1])==58,(name,out[-1000:]);return int(m[1])
started=False
print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55479 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_privacy_audit'])
 assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in MIGRATIONS:query('migration-'+p.stem,p.read_text())
 receipt['freshAssertions']=positive('fresh')
 query('replay',TARGET.read_text());receipt['replayAssertions']=positive('replayed')
 faults=[
  ('auth-profile-destination','public.notification_verified_recipients(uuid[])','lower(btrim(u.email))','lower(btrim(p.email))','private notification uses verified Auth not editable profile'),
  ('auth-anonymous-recipient','public.notification_verified_recipients(uuid[])','and not u.is_anonymous','and true','anonymous Auth never receives private notification'),
  ('auth-unconfirmed-recipient','public.notification_verified_recipients(uuid[])','and u.email_confirmed_at is not null','and true','unconfirmed Auth never receives private notification'),
  ('unverified-buyer-enqueue','public.client_lead_enqueue(uuid,uuid,uuid)','or not public.client_recipient_verified(c.listing_id,c.recipient_email)','or false ','unverified recipient gets no buyer snapshot'),
  ('nonce-revision-binding','public.client_recipient_verification_consume(text)','or c.revision is distinct from v.contact_revision','or false','nonce cannot cross contact revision edit'),
  ('nonce-expiry-binding','public.client_recipient_verification_consume(text)','v.expires_at<=now()','false ','expired nonce cannot verify recipient'),
  ('nonce-live-listing','public.client_recipient_verification_consume(text)','not public.client_routing_active(v.org_id,v.listing_id)','false ','deleted listing cannot verify recipient'),
 ]
 controls=[]
 for name,fn,old,new,label in faults:
  original=query(name+'-definition',f"select pg_get_functiondef('{fn}'::regprocedure);")
  assert original.count(old)==1,(name,'missing precise fault anchor')
  query(name+'-compile',original.replace(old,new))
  failure=query(name+'-run',TEST.read_text(),3);assert 'PRIVACY FAIL: '+label in failure,(name,failure[-1200:])
  query(name+'-restore',original);assert positive(name+'-restored')==receipt['freshAssertions']
  controls.append({'name':name,'failedBoundary':label,'compiled':True,'restored':True})
 assert hashes=={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked},'Source changed during proof'
 receipt.update(passed=True,controls=controls,finishedAt=datetime.now(timezone.utc).isoformat())
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS:',receipt['freshAssertions'],'recipient assertions +',len(receipt['controls']),'compiled semantic controls',flush=True)
