#!/usr/bin/env python3
"""Fresh Team private-library schema, replay, raw RLS and real shared-budget race.

Owns a socket-only cluster and synthetic fixtures. No hosted data, credentials,
provider dispatch or deployment. A compiled privacy mutation must fail.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime,timezone
from decimal import Decimal
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase';TARGET=SQL/'migrations/20261010030225_reaudit_library_session_settlement.sql'
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-team-private-final-',dir='/tmp'));DATA=OUT/'cluster';SOCK=OUT/'socket';SOCK.mkdir(mode=0o700)
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC'};BIN={n:shutil.which(n)for n in ['initdb','pg_ctl','psql','createdb']};assert all(BIN.values())
CONN=['-h',str(SOCK),'-p','55478','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
TRACKED=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',*[SQL/'tests'/n for n in ['team_private_libraries.sql','workspace_selection.sql','team_readiness.sql','private_internal_testing.sql']],pathlib.Path(__file__).resolve()]
HASHES={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in TRACKED}
RECEIPT={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':HASHES,'commands':[],'passed':False,'productionMutations':0,'providerCalls':0,'limitations':['Synthetic Auth and owned socket-only PostgreSQL; no hosted JWT/phone/purchase claims']}
def run(name,args,sql=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=sql,text=True,cwd=ROOT,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120);log=OUT/(name+'.log');log.write_text(p.stdout)
 RECEIPT['commands'].append({'name':name,'exit':p.returncode,'sha256':hashlib.sha256(log.read_bytes()).hexdigest(),'log':str(log)});assert p.returncode==expected,(name,p.returncode,p.stdout[-1800:]);print(name,p.returncode,flush=True);return p.stdout
def q(name,sql,expected=0):return run(name,PSQL,sql,expected)
def race(name,commands,org):
 lock=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV)
 try:
  lock.stdin.write(f"begin;select id from public.orgs where id='{org}'for update;\n\\echo LOCKED\n");lock.stdin.flush();assert lock.stdout.readline().strip()==org;assert lock.stdout.readline().strip()=='LOCKED'
  def call(command):
   p=subprocess.run(PSQL,input='set role service_role;'+command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=30);return {'exit':p.returncode,'output':p.stdout}
  with ThreadPoolExecutor(max_workers=2)as pool:
   jobs=[pool.submit(call,c)for c in commands];deadline=time.monotonic()+8
   while True:
    p=subprocess.run(PSQL,input="select count(*)from pg_stat_activity where datname='rendprop_audit'and wait_event_type='Lock'and pid<>pg_backend_pid();",text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=ENV,timeout=5)
    if p.returncode==0 and p.stdout.strip()=='2':break
    assert time.monotonic()<deadline,'Both real transactions must wait concurrently';time.sleep(.03)
   lock.stdin.write('commit;\n');lock.stdin.flush();lock.stdin.close();lock.wait(timeout=10);values=[j.result()for j in jobs]
  (OUT/(name+'.json')).write_text(json.dumps(values,indent=2));return values
 finally:
  if lock.poll()is None:lock.kill();lock.wait()
started=False
print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);started=True
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55478 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20",'start'])
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit']);assert q('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 q('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in sorted((SQL/'migrations').glob('*.sql')):q('migration-'+p.stem,p.read_text())
 snapshot="select json_object_agg(p.oid::regprocedure::text,json_build_object('definition',pg_get_functiondef(p.oid),'acl',p.proacl,'owner',p.proowner,'config',p.proconfig,'definer',p.prosecdef))from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public';"
 before=json.loads(q('definitions-before-replay',snapshot))
 for phase in ['fresh','replay']:
  if phase=='replay':q('migration-exact-replay',TARGET.read_text());assert json.loads(q('definitions-after-replay',snapshot))==before,'Replay changes authority/ACL/body'
  for name,count in [('team_private_libraries',92),('workspace_selection',28),('team_readiness',34)]:
   r=q(name+'-'+phase,(SQL/'tests'/f'{name}.sql').read_text());assert re.search(rf'^({count})$',r,re.M)and len(re.findall(r'\|(?:true|t)$',r,re.M))==count,(name,'complete inventory')
 # A compiled exact-listing authorization defect is caught by independent raw RLS tests.
 definition=q('read-access-definition',"select pg_get_functiondef('public.listing_content_access(uuid,uuid,boolean)'::regprocedure);")
 header=definition.split('AS $function$',1)[0]
 q('install-sibling-access-control',header+'AS $function$ select true; $function$;')
 negative=q('sibling-access-control',(SQL/'tests/team_private_libraries.sql').read_text(),3);assert 'TEAM PRIVATE FAIL:'in negative
 q('restore-access-definition',definition)
 # A compiled per-child reflection meter regression must fail the actual
 # reserve/refund controls; these are the production SQL functions themselves.
 reflection=q('read-reflection-definition',"select pg_get_functiondef('public.video_erase_reserve(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric)'::regprocedure);")
 assert "'reelmo:'||billing"in reflection
 q('install-cloned-reflection-meter',reflection.replace("'reelmo:'||billing","'reelmo:'||p_org"))
 negative=q('cloned-reflection-meter-control',(SQL/'tests/team_private_libraries.sql').read_text(),3);assert 'reflection clip allowance is one parent meter'in negative
 q('restore-reflection-definition',reflection)
 # Parent and child share the same last dollar, observed concurrently behind
 # the actual parent org lock. No artificial timeout is accepted as refusal.
 owner,agent=['e9030001-0000-4000-8000-'+f'{n:012d}'for n in [1,2]]
 q('race-identities',f"insert into auth.users(id,email,is_anonymous)values('{owner}','team-race-owner@fixture.invalid',false),('{agent}','team-race-agent@fixture.invalid',false);")
 org=q('race-parent',f"select org_id from memberships where user_id='{owner}';").strip()
 q('race-binding',f"update orgs set plan='team',plan_source='manual'where id='{org}';set role service_role;select create_org_invite('{owner}','{org}',null,'agent',repeat('8',64));select accept_org_invite('{agent}',repeat('8',64));")
 child=q('race-child',f"select private_org_id from team_private_libraries where agent_user_id='{agent}'and revoked_at is null;").strip()
 ceiling=q('race-ceiling',f"select plan_serving_ceiling('{org}')->>'ceiling_cents';").strip();assert float(ceiling)>0
 commands=[f"select serving_cost_reserve('{a}','{o}','team-race-{i:03d}','copy.caption:0','gemini','fixture',repeat('a',64),{ceiling},'fixture-v1');"for i,(a,o)in enumerate([(owner,org),(agent,child)],1)]
 values=race('parent-child-last-dollar',commands,org);assert sorted(v['exit']for v in values)==[0,3]and any('RP402:'in v['output']for v in values)
 final=q('race-final',f"select count(*),min(billing_org_id::text),sum(hold_cents)from serving_cost_reservations where request_key like 'team-race-%';select serving_ceiling_spent_cents('{org}',null,null),serving_ceiling_spent_cents('{child}',null,null);")
 lines=final.strip().splitlines();row=lines[0].split('|');spent=lines[1].split('|');assert row[:2]==['1',org]and Decimal(row[2])==Decimal(ceiling)and len(spent)==2 and all(Decimal(v)==Decimal(ceiling)for v in spent),('shared immutable liability',final,ceiling)
 # Exact source remains frozen throughout schema/replay/race verification.
 assert all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in HASHES.items()),'Source changed during verification'
 RECEIPT.update(passed=True,sqlAssertions={'team_private_libraries':92,'workspace_selection':28,'team_readiness':34},replayIdentical=True,rawRLSNegativeControlDetected=True,sharedReflectionMeterNegativeControlDetected=True,realParentChildLastDollarRace=True,raceResult='one admit, one RP402; single immutable parent liability')
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 RECEIPT['finishedAt']=datetime.now(timezone.utc).isoformat();RECEIPT['sourceHashesAfter']={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest()for n in HASHES};RECEIPT['sourceUnchanged']=RECEIPT['sourceHashesAfter']==HASHES;RECEIPT['passed']=RECEIPT['passed']and RECEIPT['sourceUnchanged'];(OUT/'receipt.json').write_text(json.dumps(RECEIPT,indent=2)+'\n')
assert RECEIPT['passed'];print('PASS: current Team private libraries, exact replay, real RLS and parent/child last-dollar race',flush=True)
