#!/usr/bin/env python3
"""Owned socket-only billing/video/slug authority regression; no remote connections."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path);args=parser.parse_args()
OUT=args.output or Path(tempfile.mkdtemp(prefix='rendprop-billing-authority-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
TMP=Path(tempfile.mkdtemp(prefix='rendprop-billing-pg-',dir='/tmp'));DATA=TMP/'cluster';SOCK=TMP/'socket';SOCK.mkdir()
ENV={'PATH':os.environ['PATH'],'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
B={n:shutil.which(n)for n in('initdb','pg_ctl','createdb','psql')};assert all(B.values()),'Local PostgreSQL required'
CONN=['-h',str(SOCK),'-p','55469','-U','postgres'];DB='rendprop_billing_authority'
TARGET=ROOT/'services/supabase/migrations/20261005220841_render_slug_crypto_entropy.sql'
files=sorted(TARGET.parent.glob('*.sql'));fixture=ROOT/'services/supabase/tests/backend_billing_authority.sql'
owned=[TARGET.parent/n for n in ['20261005220556_app_video_allowance_receipts.sql','20261005220709_apple_sandbox_authority_fence.sql',TARGET.name]]
bound=[*files,fixture,Path(__file__).resolve(),*[ROOT/('services/supabase/functions/'+f)for f in ['ai-video/index.ts','ai-video/cost-reservation.ts','ai-video/cost-reservation.test.ts','ai-video/cost-reservation-handler_test.ts','ai-video/fal-status-handler_test.ts','ai-video/output-journal.test.ts','_shared/ratelimit.ts','_shared/ratelimit.test.ts','_shared/providers/common.ts','_shared/providers/jobtoken.ts','_shared/providers/providers_test.ts','_shared/providers/fal_submission_audit_test.ts','_shared/applejws.ts','_shared/applejws.test.ts','me/index.ts','apple-subscriptions/index.ts']],ROOT/'services/supabase/tests/ci-bootstrap.sql']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in bound}
r={'passed':False,'sourceHashes':hashes,'migrationCount':len(files),'limits':['Synthetic local socket-only database','No provider calls/live writes','Unknown charged video holds never expire; no provider reconciliation or paid output proof','Sandbox purchase never creates service testing authority; App Review fixed lifetime caps remain operationally blocked']}
def run(name,command,ok=True):
 v=subprocess.run(command,env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90);(OUT/(name+'.log')).write_text(v.stdout)
 if ok:assert v.returncode==0,(name,v.stdout[-2500:])
 return v
try:
 run('init',[B['initdb'],'-D',str(DATA),'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[B['pg_ctl'],'-D',str(DATA),'-l',str(OUT/'postgres.log'),'-w','-o',f"-k {SOCK} -p 55469 -c listen_addresses='' -c shared_buffers=16MB",'start'])
 run('create',[B['createdb'],*CONN,DB]);PS=[B['psql'],'-X','--no-password',*CONN,'-d',DB,'-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PS,'-q','-f',str(ROOT/'services/supabase/tests/ci-bootstrap.sql')])
 attrs="select jsonb_agg(to_jsonb(x)order by oid)from(select oid,proowner,proacl,prosecdef,provolatile,proconfig,prorettype,proargtypes::text from pg_proc where oid in('public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)'::regprocedure,'public.apply_apple_entitlement(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text)'::regprocedure,'public.publish_render(uuid,numeric,numeric,jsonb,uuid)'::regprocedure))x"
 prior_attrs=None
 for f in files:
  if f.name=='20261005220709_apple_sandbox_authority_fence.sql':prior_attrs=run('security-metadata-before', [*PS,'-Atqc',attrs]).stdout
  run('apply-'+f.stem,[*PS,'-q','-f',str(f)])
 def proof(name):
  v=run(name,[*PS,'-Atq','-f',str(fixture)]);assert 'PASS: backend billing authority SQL assertions; all fixtures rolled back.'in v.stdout
  nums=re.findall(r'^\d+$',v.stdout,re.M);assert len(nums)==1;return int(nums[0])
 assert prior_attrs==run('security-metadata-after', [*PS,'-Atqc',attrs]).stdout;r['existingSecurityMetadataPreserved']=True
 r['fresh']=proof('fresh')
 for f in owned:run('replay-'+f.stem,[*PS,'-q','-f',str(f)])
 r['replay']=proof('replay')
 controls=[
 ('wrong-window','refund_rate_receipt(text,integer,timestamptz,integer)','and window_start=p_window_start','old refund cannot decrement new charge window'),
 ('unowned-drift','app_video_refund_drift(uuid,uuid,text,text)','provider_request_id=p_request and','unowned invented request cannot refund'),
 ('missing-charge','app_video_cost_reserve_v2(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb,timestamptz,timestamptz,uuid)',"if p_monthly_window_start is null or p_burst_window_start is null or not exists(select 1 from public.rate_limits where key=monthly and window_start=p_monthly_window_start and window_seconds=2592000 and count>0)\n  or not exists(select 1 from public.rate_limits where key=burst and window_start=p_burst_window_start and window_seconds=300 and count>0)then raise exception 'RP409: Original video quota charge could not be confirmed';end if;",'unconfirmed charge cannot admit priced POST'),
 ('ungranted-Sandbox','record_apple_sandbox_receipt(uuid,uuid,text,text,text,text,timestamptz)',"if not(public.org_has_internal_testing_grant(org)or public.org_has_private_internal_testing(org))then raise exception 'RP403: Sandbox testing requires explicit authorized test access';end if;",'ungranted Sandbox cannot change retail plan'),
 ('low-entropy-slug','publish_render(uuid,numeric,numeric,jsonb,uuid)',"v_slug := replace(pg_catalog.gen_random_uuid()::text,'-','');",'real publishes mint two cryptographic slugs')]
 r['controls']=[]
 for name,target,needle,label in controls:
  if label is None:run('compile-'+name,[*PS,'-qc',target]);expected=needle
  else:
   definition=run('original-'+name,[*PS,'-Atqc',f"select pg_get_functiondef('{target}'::regprocedure)"]).stdout
   assert definition.count(needle)==1,(name,'anchor mismatch')
   mutant=definition.replace(needle,"v_slug := substring(replace(pg_catalog.gen_random_uuid()::text,'-','')from 1 for 10);"if name=='low-entropy-slug'else'',1)
   run('compile-'+name,[*PS,'-qc',mutant]);expected=label
  v=run('control-'+name,[*PS,'-Atq','-f',str(fixture)],False)
  assert v.returncode!=0 and 'BILLING FAIL: '+expected in v.stdout,(name,v.stdout[-2000:]);r['controls'].append({'name':name,'exactFailure':expected,'compiled':True})
  if label is None:
   restore='revoke update on photos from authenticated'if name=='direct-DML'else'revoke execute on function brokerage_price_cents(integer)from anon'
   run('restore-'+name,[*PS,'-qc',restore])
  else:run('restore-'+name,[*PS,'-qc',definition])
  assert proof('restored-'+name)==r['fresh']
 # Unknown definitions abort before overwriting any body or security metadata.
 snapshots="select jsonb_agg(to_jsonb(x)order by oid)from(select oid,prosrc,proowner,proacl,prosecdef,provolatile,proconfig from pg_proc where pronamespace='public'::regnamespace)x"
 for name,sig,migration,anchor in [
   ('unknown-slug','publish_render(uuid,numeric,numeric,jsonb,uuid)',TARGET,"v_slug := replace(pg_catalog.gen_random_uuid()::text,'-','');"),
   ('unknown-Apple','apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)',TARGET.parent/'20261005220709_apple_sandbox_authority_fence.sql','  signed_at:=greatest(p_transaction_signed_at,p_event_signed_at);')]:
  definition=run('original-'+name,[*PS,'-Atqc',f"select pg_get_functiondef('{sig}'::regprocedure)"]).stdout
  assert definition.count(anchor)==1
  run('compile-'+name,[*PS,'-qc',definition.replace(anchor,anchor+' /* unknown body control */')])
  before=run(name+'-before-failed-migration',[*PS,'-Atqc',snapshots]).stdout
  failed=run(name+'-migration',[*PS,'-q','-f',str(migration)],False)
  assert failed.returncode!=0 and ('Unknown publish_render body'in failed.stdout if name=='unknown-slug'else'Unknown apply_apple_entitlement_v2 body'in failed.stdout)
  assert before==run(name+'-immediate-after-failed-migration',[*PS,'-Atqc',snapshots]).stdout
  run('restore-'+name,[*PS,'-qc',definition]);r.setdefault('unknownDefinitionGuards',[]).append(name)
 # Two actual transactions prove either row-lock order preserves the new charge.
 r['windowRaces']=[]
 for first in ['old-refund','new-charge']:
  key='synthetic-window-race-'+first
  run(first+'-seed',[*PS,'-qc',f"insert into rate_limits(key,window_start,count,window_seconds)values('{key}',now()-interval '31 days',1,2592000)"])
  old=run(first+'-old-window',[*PS,'-Atqc',f"select window_start from rate_limits where key='{key}'"]).stdout.strip()
  refund=f"select refund_rate_receipt('{key}',2592000,'{old}',1)"
  charge=f"select bump_rate_receipt('{key}',2592000,25,1)"
  first_sql=refund if first=='old-refund'else charge;second_sql=charge if first=='old-refund'else refund
  proc=subprocess.Popen([*PS,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,text=True)
  proc.stdin.write("begin;set local role service_role;"+first_sql+";select 'HELD';select pg_sleep(1.5);commit;\n");proc.stdin.close()
  prefix=[]
  while True:
   line=proc.stdout.readline();prefix.append(line)
   assert line,'First race transaction exited before boundary'
   if line.strip()=='HELD':break
  second=run(first+'-second',[*PS,'-Atqc','set role service_role;'+second_sql])
  tail=proc.stdout.read();proc.wait(timeout=10);(OUT/(first+'-first.log')).write_text(''.join(prefix)+tail);assert proc.returncode==0
  assert run(first+'-final-count',[*PS,'-Atqc',f"select count from rate_limits where key='{key}'"]).stdout.strip()=='1'
  if first=='new-charge':assert second.stdout.strip()=='f'
  r['windowRaces'].append({'first':first,'newWindowCount':1})
 assert all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in hashes.items());r['sourceBoundAtEnd']=True;r['passed']=True
finally:
 if(DATA/'postmaster.pid').exists():run('stop',[B['pg_ctl'],'-D',str(DATA),'-m','fast','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2));print(json.dumps({'output':str(OUT),'passed':r['passed'],'fresh':r.get('fresh'),'replay':r.get('replay'),'controls':len(r.get('controls',[]))}))
