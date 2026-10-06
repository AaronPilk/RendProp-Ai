#!/usr/bin/env python3
"""Verified chronology contracts in an owned, socket-only disposable database.

No inherited credentials, hosted reads/writes, Apple calls or provider dispatch.
The disabled chronology control executes only in this owned database.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
import hashlib, json, os, re, shutil, subprocess, tempfile, uuid

ROOT=Path(__file__).resolve().parents[2]
SQL=ROOT/'services/supabase'
TARGET=SQL/'migrations/20261005024539_apple_entitlement_chronology.sql'
CUTOVER=SQL/'migrations/20261005032635_apple_entitlement_legacy_cutover.sql'
FACTS=SQL/'migrations/20261005024702_listing_facts_intent_cas.sql'
STUDIO=SQL/'functions/studio'
FLOORPLAN=SQL/'migrations/20261005034754_studio_floorplan_attachment_cas.sql'
OUT=Path(tempfile.mkdtemp(prefix='rendprop-sub-chronology-',dir='/tmp'))
DATA,SOCK=OUT/'data',OUT/'socket';SOCK.mkdir(mode=0o700)
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','TZ':'UTC','NO_COLOR':'1','DENO_NO_PROMPT':'1'}
BIN={n:shutil.which(n)for n in ['initdb','pg_ctl','psql','createdb','deno']};assert all(BIN.values())
CONN=['-h',str(SOCK),'-p','55489','-U','postgres']
PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
paths=[TARGET,CUTOVER,FACTS,SQL/'tests/ci-bootstrap.sql',SQL/'tests/invariants.sql',SQL/'tests/invariant_astra_paid_gates.sql',SQL/'tests/listing_facts_cas.sql',SQL/'tests/subscription_chronology.sql',SQL/'tests/subscription_confirmed_trial.sql',Path(__file__).resolve(),*sorted((SQL/'functions/apple-subscriptions').glob('*.ts')),SQL/'functions/me/index.ts',SQL/'functions/_shared/applejws.test.ts']
paths += [STUDIO/'listing-actions.ts',STUDIO/'listing-actions.test.ts',STUDIO/'index.ts',FLOORPLAN,SQL/'tests/studio_floorplan_cas.sql']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
migrations=[(p,p.read_text())for p in sorted((SQL/'migrations').glob('*.sql'))]
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'migrationHashes':{p.name:hashlib.sha256(s.encode()).hexdigest()for p,s in migrations},'commands':[],'productionMutations':0,'providerCalls':0,'appleCalls':0,'passed':False}
def run(name,args,sql=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=sql,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout)
 receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert p.returncode==expected,f'{name}: {p.stdout[-3000:]}'
 print(name,p.returncode,flush=True);return p.stdout
def query(name,sql,expected=0):return run(name,PSQL,sql,expected)
started=False
print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);started=True
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55489 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start'])
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit'])
 assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p,s in migrations:
  if p.name<TARGET.name:query('migration-'+p.stem,s)
 matrix="select jsonb_agg(to_jsonb(e) order by plan)::text from plan_entitlements e;"
 before_matrix=query('allowance-matrix-before',matrix)
 legacy_identity="select md5(prosrc),proconfig::text,proacl::text from pg_proc where oid='public.apply_apple_entitlement(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text)'::regprocedure;"
 before_legacy=query('legacy-writer-before-expand',legacy_identity)
 query('chronology-migration',TARGET.read_text())
 query('chronology-historical-replay',TARGET.read_text())
 assert query('legacy-writer-after-expand',legacy_identity)==before_legacy
 for race in range(4):
  staged_org=str(uuid.uuid4());staged_original='staged-first-'+str(uuid.uuid4())
  query('staged-first-org-'+str(race),f"insert into orgs(id,name,plan,plan_source)values('{staged_org}','Staged first receipt','free',null);")
  def first_writer(kind):
   if kind=='legacy':
    statement=f"set role service_role;select apply_apple_entitlement('{staged_org}',null,'{staged_original}','first-tx','com.rendprop.app.pro.monthly','pro','Sandbox','refunded',now()-interval '1 day',false,'REFUND');"
   else:
    statement=f"set role service_role;select apply_apple_entitlement_v2('{staged_org}',null,'{staged_original}','first-tx','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '30 days',true,null,date_trunc('hour',now())-interval '1000 seconds',date_trunc('hour',now())-interval '900 seconds',null,null);"
   return query('staged-first-'+str(race)+'-'+kind,statement)
  with ThreadPoolExecutor(max_workers=2)as pool:list(pool.map(first_writer,['legacy','v2']))
  assert query('staged-first-result-'+str(race),f"select s.status,o.plan,s.transaction_purchased_at is null from apple_subscriptions s join orgs o on o.id=s.org_id where s.original_transaction_id='{staged_original}';").strip()=='refunded|free|t'
  query('staged-first-clean-'+str(race),f"delete from apple_subscriptions where original_transaction_id='{staged_original}';delete from orgs where id='{staged_org}';")
 receipt['mixedFirstReceiptRaces']=4
 query('staged-handlers-before-cutover',"""
 begin;
 do $$declare legacy_org uuid;dated_org uuid;r jsonb;dates jsonb;begin
   insert into public.orgs(name,plan,plan_source)values('Staged legacy handler','free',null)returning id into legacy_org;
   perform public.apply_apple_entitlement(legacy_org,null,'staged-legacy','legacy-tx','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '30 days',true,'SUBSCRIBED');
   perform public.apply_apple_entitlement(legacy_org,null,'staged-legacy','legacy-tx','com.rendprop.app.pro.monthly','pro','Sandbox','refunded',now()-interval '1 day',false,'REFUND');
   if (select plan from public.orgs where id=legacy_org)<>'free' then raise exception 'Old handler refund was not enforced during expansion';end if;
   insert into public.orgs(name,plan,plan_source)values('Staged v2 handler','free',null)returning id into dated_org;
   perform public.apply_apple_entitlement_v2(dated_org,null,'staged-v2','dated-tx','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '30 days',true,'SUBSCRIBED',now()-interval '1000 seconds',now()-interval '900 seconds',now()-interval '800 seconds',null);
   perform public.apply_apple_entitlement_v2(dated_org,null,'staged-v2','dated-tx','com.rendprop.app.pro.monthly','pro','Sandbox','refunded',now()-interval '1 day',false,'REFUND',now()-interval '1000 seconds',now()-interval '700 seconds',now()-interval '600 seconds',null);
   r:=public.apply_apple_entitlement_v2(dated_org,null,'staged-v2','dated-tx','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '30 days',true,null,now()-interval '1000 seconds',now()-interval '900 seconds',null,null);
   if r->>'reason'<>'stale_notification' or(select plan from public.orgs where id=dated_org)<>'free' then raise exception 'Expanded v2 did not enforce signed chronology';end if;
   perform public.apply_apple_entitlement_v2(dated_org,null,'staged-v2','dated-tx','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '30 days',true,'REFUND_REVERSED',now()-interval '1000 seconds',now()-interval '500 seconds',now()-interval '400 seconds',null);
   select jsonb_build_array(transaction_purchased_at,transaction_signed_at,entitlement_signed_at,renewal_signed_at)into dates from public.apple_subscriptions where original_transaction_id='staged-v2';
   update public.apple_subscriptions set app_account_token=gen_random_uuid(),updated_at=now()where original_transaction_id='staged-v2';
   if (select jsonb_build_array(transaction_purchased_at,transaction_signed_at,entitlement_signed_at,renewal_signed_at)from public.apple_subscriptions where original_transaction_id='staged-v2')is distinct from dates then raise exception 'Token metadata invalidated verified chronology';end if;
   perform public.apply_apple_entitlement(dated_org,null,'staged-v2','dated-tx','com.rendprop.app.pro.monthly','pro','Sandbox','refunded',now()-interval '1 day',false,'REFUND');
   r:=public.apply_apple_entitlement_v2(dated_org,null,'staged-v2','dated-tx','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '30 days',true,'REFUND_REVERSED',now()-interval '1000 seconds',now()-interval '300 seconds',now()-interval '350 seconds',null);
   if r->>'reason'<>'chronology_unavailable' or(select plan from public.orgs where id=dated_org)<>'free' then raise exception 'Unordered overlap falsely retained trusted chronology and admitted old reversal';end if;
   update public.apple_subscriptions set updated_at=now()-interval '10 seconds'where original_transaction_id='staged-v2';
   perform public.apply_apple_entitlement_v2(dated_org,null,'staged-v2','newer-purchase','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '30 days',true,'SUBSCRIBED',now()-interval '5 seconds',now()-interval '4 seconds',now()-interval '3 seconds',null);
   if(select plan from public.orgs where id=dated_org)<>'pro' or(select last_transaction_id from public.apple_subscriptions where original_transaction_id='staged-v2')<>'newer-purchase' then raise exception 'Newer purchase failed after unordered overlap';end if;
 end$$;
 rollback;
 """)
 for p,s in migrations:
  if TARGET.name<p.name<CUTOVER.name:query('migration-'+p.stem,s)
 query('legacy-cutover-migration',CUTOVER.read_text())
 query('legacy-cutover-historical-replay',CUTOVER.read_text())
 assert query('legacy-writer-after-cutover',legacy_identity)!=before_legacy
 receipt['stagedRolloutAssertions']=['old eleven-argument body/config/ACL unchanged after expand','old handler refund still enforced before cutover','v2 rejects signed refund replay before cutover','token/metadata-only writes preserve all chronology','unordered overlap invalidates chronology and refuses old reversal','newer purchase succeeds after unordered overlap','legacy fence installed only by contract migration']
 for p,s in migrations:
  if p.name>CUTOVER.name:query('migration-'+p.stem,s)
 receipt['replayMode']='chronology and cutover replayed at their historical schema points; final fixtures include every later migration'
 assert query('allowance-matrix-after',matrix)==before_matrix
 receipt['allowanceAndPriceRowsPreserved']=True
 for phase in ['fresh','replayed']:
  checks=query('chronology-'+phase,(SQL/'tests/subscription_chronology.sql').read_text())
  count=checks.count('|t');assert count>=25,count
  receipt['chronologyAssertions']=count
  trial=query('confirmed-trial-'+phase,(SQL/'tests/subscription_confirmed_trial.sql').read_text());assert trial.count('|t')==26
  assert query('allowance-matrix-'+phase,matrix)==before_matrix
 facts_checks=query('facts-integration',(SQL/'tests/listing_facts_cas.sql').read_text())
 receipt['factsSQLAssertions']=json.loads(facts_checks.strip())['assertions']
 invariants=run('all-invariants',PSQL+['-f',SQL/'tests/invariants.sql'],expected=3)
 failures=[line for line in invariants.splitlines()if re.search(r'\|\s*f\s*\|',line)]
 assert len(failures)==1 and 'each astra ceiling clears its route'in failures[0],failures
 receipt['invariants']={'failures':failures,'passed':sum(bool(re.search(r'\|\s*t\s*\|',line))for line in invariants.splitlines()),'expectedFailure':'owner-retained Astra budget ceiling'}
 facts_source=query('current-facts-definition',"select pg_get_functiondef('public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb)'::regprocedure);")
 omitted=facts_source.replace('if not current_matches and not desired_matches then','if false then',1)
 assert omitted!=facts_source
 query('facts-removed-conflict-install',omitted)
 failure=query('facts-removed-conflict',(SQL/'tests/listing_facts_cas.sql').read_text(),3)
 assert 'Conflicting edits keep shared square footage did not refuse'in failure
 query('facts-restore-conflict',facts_source)
 query('facts-restored-direct-grant','grant update(address) on public.listings to authenticated;')
 failure=query('facts-restored-direct-grant-fixture',(SQL/'tests/listing_facts_cas.sql').read_text(),3)
 assert 'Direct fact writes are fenced: address'in failure
 query('facts-restore-grants','revoke update(address) on public.listings from authenticated;')
 receipt['factsNegativeControls']=['removed conflict comparison fails square-footage protection','restored direct address grant fails privilege boundary']
 floorplan_sql=(SQL/'tests/studio_floorplan_cas.sql').read_text()
 floorplan_checks=query('floorplan-service-cas',floorplan_sql)
 receipt['floorplanDatabaseAssertions']=json.loads(floorplan_checks.strip().splitlines()[-1])['assertions']
 floorplan_migration=query('current-floorplan-definition',"select pg_get_functiondef('public.studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text)'::regprocedure);")
 role_guard="if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then"
 role_fault=floorplan_migration.replace(role_guard,'if false then',1);assert role_fault!=floorplan_migration
 query('floorplan-removed-role-install',role_fault)
 failure=query('floorplan-removed-role',floorplan_sql,3)
 assert 'FLOORPLAN FAIL: Role revoked after read cannot attach did not refuse'in failure
 query('floorplan-restore-role',floorplan_migration)
 cas_fault=floorplan_migration.replace('if l.details is distinct from p_expected then','if false then',1);assert cas_fault!=floorplan_migration
 query('floorplan-removed-cas-install',cas_fault)
 failure=query('floorplan-removed-cas',floorplan_sql,3)
 assert 'FLOORPLAN FAIL: Phone detail edit after read conflicts atomically did not refuse'in failure
 query('floorplan-restore-cas',floorplan_migration)
 receipt['floorplanSQLNegativeControls']=['Removed membership/deletion guard admits revoked actor','Removed details CAS admits stale snapshot']

 # Real overlapping callers must retain the newest purchase independent of
 # transaction admission order, including concurrent first receipts.
 org=str(uuid.uuid4());original='race-'+str(uuid.uuid4())
 query('race-org',f"insert into orgs(id,name,plan,plan_source)values('{org}','Chronology race','free',null);")
 def contender(n):
  age=1000-n*50
  return query('race-'+str(n),f"set role service_role;select apply_apple_entitlement_v2('{org}',null,'{original}','race-tx-{n}','com.rendprop.app.pro.monthly','pro','Production','active',now()+interval '{n+1} days',true,'DID_RENEW',date_trunc('hour',now())-interval '{age} seconds',date_trunc('hour',now())-interval '{age-10} seconds',null,null);")
 with ThreadPoolExecutor(max_workers=8)as pool:list(pool.map(contender,range(8)))
 assert query('race-newest',f"select last_transaction_id from apple_subscriptions where original_transaction_id='{original}';").strip()=='race-tx-7'
 receipt['concurrentReceipts']=8
 # Compile the actual SQL body with its ordering guards disabled. The same
 # fixture must catch the demonstrated pre-refund replay, not just a parser.
 # Compile faults from the final effective body and restore that same exact
 # definition. Reinstalling an older migration here would erase later fences.
 sig='public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)'
 v2=query('current-chronology-definition',f"select pg_get_functiondef('{sig}'::regprocedure);")
 definition_before=query('current-chronology-security',f"select md5(prosrc),proowner,proacl::text,prosecdef,proconfig::text from pg_proc where oid='{sig}'::regprocedure;")
 reversal_fault=v2.replace(' or p_event_signed_at<=s.entitlement_signed_at','',1)
 assert reversal_fault!=v2
 query('fault-reversal-outer-install',reversal_fault)
 failed=query('fault-reversal-outer',(SQL/'tests/subscription_chronology.sql').read_text(),3)
 assert 'CHRONOLOGY FAIL: old reversal with freshly signed transaction preserves newer refund'in failed
 query('restore-reversal-outer',v2)
 receipt['reversalNegativeControl']='removed independent outer reversal chronology caught at freshly signed old reversal'
 fault=v2.replace('    if stale then','    stale:=false; -- deliberately removed ordering guard\n    if stale then',1)
 assert fault!=v2
 query('fault-install',fault)
 failed=query('fault-replay',(SQL/'tests/subscription_chronology.sql').read_text(),3)
 assert 'CHRONOLOGY FAIL: old pre-refund restore preserves refund'in failed
 receipt['negativeControl']='removed ordering guard caught at old pre-refund restore'
 query('restore-migration',v2)
 assert query('current-chronology-security-restored',f"select md5(prosrc),proowner,proacl::text,prosecdef,proconfig::text from pg_proc where oid='{sig}'::regprocedure;")==definition_before
 receipt['finalChronologyAndSandboxFenceRestored']=True
 deno=[BIN['deno'],'test','--cached-only','--no-config','--no-lock','--node-modules-dir=none','--allow-read','--allow-env','--deny-net','--deny-write','--deny-run']
 results=run('signed-adapters',deno+[SQL/'functions/_shared/applejws.test.ts',SQL/'functions/apple-subscriptions/notify.test.ts',SQL/'functions/me/billing.test.ts'])
 summary=re.findall(r'ok \| (\d+) passed \| 0 failed',results);assert len(summary)==1
 receipt['offlineAssertions']=int(summary[0])
 floorplan=run('floorplan-handler',deno+[STUDIO/'listing-actions.test.ts'])
 receipt['floorplanHandlerAssertions']=int(re.findall(r'ok \| (\d+) passed \| 0 failed',floorplan)[0])
 fault_dir=OUT/'floorplan-fault';fault_dir.mkdir()
 floorplan_source=(STUDIO/'listing-actions.ts').read_text()
 fault_source=floorplan_source.replace('context.admin.rpc("studio_attach_floorplan"','context.db.rpc("studio_attach_floorplan"',1)
 assert fault_source!=floorplan_source
 fault_source=fault_source.replace('from "../_shared/','from "'+(SQL/'functions/_shared').as_uri()+'/')
 (fault_dir/'listing-actions.ts').write_text(fault_source)
 (fault_dir/'listing-actions.test.ts').write_text((STUDIO/'listing-actions.test.ts').read_text().replace('from "../_shared/','from "'+(SQL/'functions/_shared').as_uri()+'/'))
 failed=run('floorplan-client-write-fault',deno+['--filter','floor-plan attachment preserves',fault_dir/'listing-actions.test.ts'],expected=1)
 assert 'floor-plan attachment preserves listing details and uses optimistic concurrency'in failed and 'FAILED | 0 passed | 1 failed'in failed
 receipt['floorplanNegativeControl']='Replacing request service RPC with client RPC fails actual handler boundary fixture'
 run('handler-compilation',deno[:2]+['--no-run']+deno[2:]+[SQL/'functions/apple-subscriptions/index.ts',SQL/'functions/me/index.ts',STUDIO/'index.ts'])
 assert hashes=={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths},'Billing source changed during verification'
 assert receipt['migrationHashes']=={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p,_ in migrations},'Migration sources changed during verification'
 receipt.update(passed=True,finishedAt=datetime.now(timezone.utc).isoformat(),confirmedTrialAssertions=26,limits=['Synthetic certificate trust root and owned database; no real App Store purchase or restore','Legacy deployed handlers and production schema remain unchanged','No new pricing, margin or Apple offer eligibility certification'])
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: subscription chronology',flush=True)
