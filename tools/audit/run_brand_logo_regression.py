#!/usr/bin/env python3
"""Focused logo journal/publication/deletion proof in an owned disposable DB."""
from datetime import datetime,timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
from run_database_regression import invariant_rows
ROOT=pathlib.Path(__file__).resolve().parents[2]
SQL=ROOT/'services/supabase'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
TARGET=SQL/'migrations/20261005150445_scoped_business_logo.sql'
DELETION_REPAIR=SQL/'migrations/20261005172028_restore_deletion_voice_and_project_inventory.sql'
TEST=SQL/'tests/org_brand_logo.sql'
MEDIA_TEST=SQL/'tests/account_deletion_studio_inventory.sql'
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-brand-logo-',dir='/tmp'))
DATA,SOCK=OUT/'cluster',OUT/'socket';SOCK.mkdir(mode=0o700)
BINS={n:shutil.which(n)for n in ['initdb','pg_ctl','createdb','psql']};assert all(BINS.values())
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
CONN=['-h',str(SOCK),'-p','55462','-U','postgres']
PSQL=[BINS['psql'],'-X','--no-password',*CONN,'-d','rendprop_logo','-v','ON_ERROR_STOP=1']
tracked=[*MIGRATIONS,TEST,MEDIA_TEST,SQL/'tests/invariants.sql',SQL/'tests/invariant_astra_paid_gates.sql',ROOT/'tools/audit/run_database_regression.py',pathlib.Path(__file__).resolve(),SQL/'tests/ci-bootstrap.sql',SQL/'functions/me/brand-logo.ts',SQL/'functions/me/brand-image.ts',SQL/'functions/me/index.ts',SQL/'functions/_shared/r2.ts']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'commands':[],'limits':['Owned socket-only plain Postgres','Synthetic auth/storage receipts','No hosted DB, provider, Apple or real object writes'],'passed':False}
started=False

def run(name,args,expected=0,timeout=45):
 result=subprocess.run([str(x)for x in args],env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log=OUT/(name+'.log');log.write_text(result.stdout)
 receipt['commands'].append({'name':name,'exit':result.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert result.returncode==expected,(name,result.returncode,result.stdout[-2500:])
 return result.stdout

def query(name,sql,expected=0):
 path=OUT/(name+'.sql');path.write_text(sql)
 return run(name,[*PSQL,'-At','-f',path],expected)


def require_all_invariants(output, exit_code):
 names,failed=invariant_rows(output,exit_code)
 if exit_code!=0 or failed:raise RuntimeError('Every invariant must pass; no failures are accepted')
 return names

def race(label,first,second,actor,org,operation):
 f1=(OUT/(label+'-first.log')).open('w');f2=(OUT/(label+'-second.log')).open('w')
 first_proc=subprocess.Popen(PSQL,env={**ENV,'PGAPPNAME':'logo-proof-first'},text=True,stdin=subprocess.PIPE,stdout=f1,stderr=subprocess.STDOUT)
 second_proc=None
 try:
  first_proc.stdin.write("begin;set local role service_role;"+first+"\n\\echo LOGO_LOCK_HELD\n");first_proc.stdin.flush()
  deadline=time.monotonic()+5
  while 'LOGO_LOCK_HELD'not in (OUT/(label+'-first.log')).read_text():
   assert first_proc.poll()is None and time.monotonic()<deadline,label;time.sleep(.03)
  second_proc=subprocess.Popen([*PSQL,'-c','set role service_role;'+second],env={**ENV,'PGAPPNAME':'logo-proof-second'},text=True,stdout=f2,stderr=subprocess.STDOUT)
  deadline=time.monotonic()+5;blocked=False
  while time.monotonic()<deadline:
   waiting=query(label+'-lock-observation',"select count(*) from pg_stat_activity where application_name='logo-proof-second' and wait_event_type='Lock';")
   if waiting.strip()=='1':blocked=True;break
   assert second_proc.poll()is None,label;time.sleep(.03)
  assert blocked,label+' never held actual authorization/org write boundary'
  first_proc.stdin.write('commit;\n\\q\n');first_proc.stdin.flush();first_proc.wait(timeout=10);second_proc.wait(timeout=10)
  assert first_proc.returncode==second_proc.returncode==0,label
  result=query(label+'-final',f"select brand_kit->>'title'='Concurrent title' and brand_kit->>'business_logo_url' like '%{operation}.png' from orgs where id='{org}';")
  assert result.strip()=='t',result
  return{'name':label,'observedLock':True,'bothFieldsPreserved':True}
 finally:
  for process in [first_proc,second_proc]:
   if process and process.poll()is None:process.terminate();process.wait(timeout=10)
  f1.close();f2.close()

try:
 run('init',[BINS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BINS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55462 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('create',[BINS['createdb'],'--no-password',*CONN,'rendprop_logo'])
 assert query('identity',"select current_setting('data_directory')||'|'||current_setting('listen_addresses')||'|'||current_database();").strip()==f'{DATA}||rendprop_logo'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for migration in MIGRATIONS:run('apply-'+migration.stem,[*PSQL,'-q','-1','-f',migration])
 run('deletion-repair-replay',[*PSQL,'-q','-1','-f',DELETION_REPAIR])
 positive=run('logo-positive',[*PSQL,'-At','-f',TEST])
 assert 'PASS: org logo lifecycle SQL assertions; all fixtures rolled back.'in positive
 # Named runtime controls mutate current exact SQL, not a parallel implementation.
 for name,definition,anchor,replacement,reason in [
  ('drop-publish-authority','public.publish_org_brand_logo(uuid,uuid,uuid,text)','o:=public.lock_org_brand_authority(p_actor,p_org);','select * into o from public.orgs where id=p_org;','role revoked after storage blocks publication'),
  ('omit-logo-deletion-inventory','public.prepare_account_deletion(uuid,text,text)',"select object_targets||coalesce(jsonb_agg(jsonb_build_object('bucket',p_render_bucket,'key',b.object_key,'valid',", "select object_targets||coalesce(jsonb_agg(jsonb_build_object('bucket',p_render_bucket,'key',b.object_key,'valid',",'deletion inventories current and staged immutable logos'),
  ('omit-owner-transfer-preflight','public.account_deletion_integrity_preflight(uuid)',
   "  if exists(select 1 from public.memberships owner where owner.user_id=p_user and owner.role='owner'\n    and exists(select 1 from public.memberships peer where peer.org_id=owner.org_id and peer.user_id<>p_user)\n    and not exists(select 1 from public.memberships heir where heir.org_id=owner.org_id and heir.user_id<>p_user and heir.role='owner'))then\n    raise exception 'RP409: Transfer ownership of the shared workspace before deleting this account. Contact support if an ownership transfer needs assistance.';\n  end if;",'',
   'sole shared owner must transfer ownership before account deletion'),
 ]:
  body=query(name+'-definition',f"select pg_get_functiondef('{definition}'::regprocedure);")
  if name=='omit-logo-deletion-inventory':
   start=body.index('  select object_targets||coalesce(jsonb_agg(');end=body.index('  object_targets:=object_targets||spatial_keys||public.studio_voice_deletion_targets(',start)
   mutant=body[:start]+body[end:]
  else:
   assert body.count(anchor)==1;mutant=body.replace(anchor,replacement)
  query(name+'-apply',mutant)
  failed=run(name+'-negative',[*PSQL,'-At','-f',TEST],expected=3)
  assert 'LOGO FAIL: '+reason in failed,failed[-2000:]
  # Restore the exact pristine current function, not the historical logo
  # migration's older deletion body that would erase later safety overlays.
  query(name+'-restore-exact-current',body)
  assert query(name+'-restored-definition',f"select pg_get_functiondef('{definition}'::regprocedure);")==body
  restored=run(name+'-restored',[*PSQL,'-At','-f',TEST]);assert 'PASS: org logo lifecycle SQL assertions; all fixtures rolled back.'in restored
 receipt['negativeControls']=['drop-publish-authority','omit-logo-deletion-inventory','omit-owner-transfer-preflight']
 media_positive=run('studio-deletion-positive',[*PSQL,'-At','-f',MEDIA_TEST])
 assert 'PASS: Studio deletion inventory SQL assertions; all fixtures rolled back.'in media_positive
 definition=query('studio-deletion-definition',"select pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);")
 # Independent controls isolate each lost protection; the mixed-object case
 # alone cannot detect a shorter voice deadline masked by a project deadline.
 media_controls=[]
 for name,anchor,replacement,reason in [
  ('omit-voice-inventory','||public.studio_voice_deletion_targets(solo,p_upload_bucket)','','voice aliases and reservation inventoried exactly once'),
  ('omit-voice-deadline',"  select greatest(storage_after,max(write_deadline)+interval '1 hour') into storage_after\n    from public.voice_storage_reservations where org_id=any(solo);",'','voice cleanup waits for original write deadline plus one hour'),
  ('omit-project-inventory','  object_targets:=object_targets||public.studio_project_deletion_targets(p_user,solo,p_upload_bucket);','','project reserved chunks inventoried exactly once'),
  ('omit-project-deadline',"  select greatest(storage_after,max(write_deadline)+interval '1 hour') into storage_after from public.studio_project_media where actor_id=p_user or org_id=any(solo);",'','private project cleanup waits for original write deadline plus one hour'),
  ('omit-project-actor-cleanup','  delete from public.studio_project_media where actor_id=p_user;','','deleting actor private project metadata removed'),
 ]:
  assert definition.count(anchor)==1,name
  query(name+'-apply',definition.replace(anchor,replacement))
  failed=run(name+'-negative',[*PSQL,'-At','-f',MEDIA_TEST],expected=3)
  assert 'DELETION MEDIA FAIL: '+reason in failed,failed[-2000:]
  query(name+'-restore',definition)
  restored=run(name+'-restored',[*PSQL,'-At','-f',MEDIA_TEST]);assert 'PASS: Studio deletion inventory SQL assertions; all fixtures rolled back.'in restored
  media_controls.append(name)
 receipt['negativeControls']+=media_controls
 check=re.search(r'\n(\d+)\nPASS: Studio deletion inventory',media_positive);assert check,media_positive[-800:]
 receipt['studioDeletionAssertions']=int(check[1])
 races=[]
 for n,label in enumerate(['logo-first-text-waits','text-first-logo-waits'],1):
  actor=f'b0100504-0000-4000-8000-{n:012d}';operation=f'b0100505-0000-4000-8000-{n:012d}'
  query(label+'-seed',f"insert into auth.users(id,email,is_anonymous)values('{actor}','race{n}@fixture.invalid',false);")
  org=query(label+'-org',f"select org_id from memberships where user_id='{actor}';").strip()
  url=f'https://cdn.fixture.invalid/renders/{org}/brand/{operation}.png'
  query(label+'-prepare',f"set role service_role;select prepare_org_brand_logo('{actor}','{org}','{operation}',null,100,'image/png',repeat('a',64),'{url}');")
  logo=f"select publish_org_brand_logo('{actor}','{org}','{operation}','synthetic-etag');"
  text=f"select merge_org_brand_fields('{actor}','{org}','{{\"title\":\"Concurrent title\"}}','{{}}');"
  races.append(race(label,logo if n==1 else text,text if n==1 else logo,actor,org,operation))
 receipt['races']=races
 # Require the exact complete inventory, successful SQL exit and all-green footer.
 invariant_args=[*PSQL,'-f']
 invariants=run('invariants',invariant_args+[SQL/'tests/invariants.sql'])
 invariant_names=require_all_invariants(invariants,receipt['commands'][-1]['exit'])
 receipt['invariants']={'passed':len(invariant_names),'failures':[],'total':len(invariant_names)}

 # Restore only the former headroom failure in an owned SQL copy. The same
 # positive acceptance gate must refuse its complete 270-row/exit3 result.
 original=(SQL/'tests/invariants.sql').read_text()
 anchor="when 'copy.agent_reel' then 500"
 assert original.count(anchor)==1
 shutil.copyfile(SQL/'tests/invariant_astra_paid_gates.sql',OUT/'invariant_astra_paid_gates.sql')
 mutant=OUT/'invariants-former-headroom-red.sql'
 mutant.write_text(original.replace(anchor,"when 'copy.agent_reel' then 700",1))
 red=run('invariants-former-headroom-red',invariant_args+[mutant],expected=3)
 red_exit=receipt['commands'][-1]['exit']
 red_names,red_failures=invariant_rows(red,red_exit)
 assert red_names==invariant_names
 assert red_failures==["each astra ceiling clears its route's visible answer and stays under the code clamp"]
 try:require_all_invariants(red,red_exit)
 except RuntimeError:pass
 else:raise RuntimeError('Strict positive invariant gate accepted the former red assertion')
 receipt['invariantNegativeControl']={'kind':'actual-owned-SQL-former-headroom-red','exit':3,'count':len(red_names),'failed':red_failures,'positiveGateRejected':True,'sourceCopy':str(mutant),'sha256':hashlib.sha256(mutant.read_bytes()).hexdigest()}
 assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in hashes.items()),'Source changed during proof'
 check=re.search(r'\n(\d+)\nPASS: org logo lifecycle',positive);assert check,positive[-800:]
 receipt.update(passed=True,sqlAssertions=int(check[1]))
finally:
 if started and (DATA/'postmaster.pid').exists():run('stop',[BINS['pg_ctl'],'-D',DATA,'-m','fast','-w','-t','30','stop'])
 receipt['finishedAt']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 print('Logo evidence:',OUT,flush=True)
print('PASS: bounded scoped logo lifecycle, source-mutant controls and actual concurrent org serialization.',flush=True)
