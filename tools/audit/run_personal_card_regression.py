#!/usr/bin/env python3
"""Account-card authority/CAS/public identity proof in an owned socket-only DB."""
from datetime import datetime,timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
TARGET=SQL/'migrations/20261005160701_personal_public_card.sql';TEST=SQL/'tests/personal_public_card.sql'
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-personal-card-',dir='/tmp'));DATA=OUT/'cluster';SOCK=OUT/'socket';SOCK.mkdir(mode=0o700)
BINS={n:shutil.which(n)for n in ['initdb','pg_ctl','createdb','psql']};assert all(BINS.values())
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
CONN=['-h',str(SOCK),'-p','55463','-U','postgres'];PSQL=[BINS['psql'],'-X','--no-password',*CONN,'-d','rendprop_card','-v','ON_ERROR_STOP=1']
tracked=[*MIGRATIONS,TEST,pathlib.Path(__file__).resolve(),SQL/'tests/ci-bootstrap.sql',SQL/'functions/me/card.ts',SQL/'functions/me/card.test.ts',SQL/'functions/me/index.ts',SQL/'functions/_shared/agentcard.ts',SQL/'functions/tours/index.ts']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'limits':['Owned socket-only Postgres','Synthetic people, teams and object metadata','No hosted DB, mail, provider, Apple or real object writes'],'passed':False};started=False
def run(name,args,expected=0,timeout=45):
 r=subprocess.run([str(x)for x in args],env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout);(OUT/(name+'.log')).write_text(r.stdout)
 assert r.returncode==expected,(name,r.returncode,r.stdout[-3000:]);return r.stdout
def query(name,sql,expected=0):
 p=OUT/(name+'.sql');p.write_text(sql);return run(name,[*PSQL,'-At','-f',p],expected)
def race(name,actor,first,second,same_field=False):
 f1=(OUT/(name+'-first.log')).open('w');f2=(OUT/(name+'-second.log')).open('w');p2=None
 p1=subprocess.Popen(PSQL,env={**ENV,'PGAPPNAME':'card-proof-first'},text=True,stdin=subprocess.PIPE,stdout=f1,stderr=subprocess.STDOUT)
 try:
  p1.stdin.write('begin;set local role service_role;'+first+'\n\\echo CARD_LOCK_HELD\n');p1.stdin.flush();deadline=time.monotonic()+5
  while 'CARD_LOCK_HELD'not in(OUT/(name+'-first.log')).read_text():
   assert p1.poll()is None and time.monotonic()<deadline;time.sleep(.03)
  path=OUT/(name+'-second.sql');path.write_text('set role service_role;'+second)
  p2=subprocess.Popen([*PSQL,'-f',path],env={**ENV,'PGAPPNAME':'card-proof-second'},text=True,stdout=f2,stderr=subprocess.STDOUT);deadline=time.monotonic()+5;blocked=False
  while time.monotonic()<deadline:
   if query(name+'-lock-observation',"select count(*)from pg_stat_activity where application_name='card-proof-second'and wait_event_type='Lock';").strip()=='1':blocked=True;break
   assert p2.poll()is None;time.sleep(.03)
  assert blocked,name+' did not observe actual profile serialization';p1.stdin.write('commit;\n\\q\n');p1.stdin.flush();p1.wait(timeout=10);p2.wait(timeout=10)
  assert p1.returncode==0 and p2.returncode==(3 if same_field else 0),(name,p1.returncode,p2.returncode)
  if same_field:assert 'RP409'in(OUT/(name+'-second.log')).read_text()
  result=query(name+'-final',f"select public_card->>'phone'='First phone'and {'not(public_card?\'website\')' if same_field else 'public_card->>\'website\'=\'https://second.fixture.invalid\''} from profiles where id='{actor}';")
  assert result.strip()=='t',result
  return{'name':name,'observedLock':True,'sameFieldConflict':same_field,'unrelatedFieldsPreserved':not same_field}
 finally:
  for p in[p1,p2]:
   if p and p.poll()is None:p.terminate();p.wait(timeout=10)
  f1.close();f2.close()
try:
 run('init',[BINS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BINS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55463 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('create',[BINS['createdb'],'--no-password',*CONN,'rendprop_card'])
 assert query('identity',"select current_setting('data_directory')||'|'||current_setting('listen_addresses')||'|'||current_database();").strip()==f'{DATA}||rendprop_card'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for p in MIGRATIONS:run('apply-'+p.stem,[*PSQL,'-q','-1','-f',p])
 positive=run('card-positive',[*PSQL,'-At','-f',TEST]);assert 'PASS: personal card SQL assertions; all fixtures rolled back.'in positive
 body=query('cas-definition',"select pg_get_functiondef('merge_personal_public_card(uuid,jsonb,jsonb)'::regprocedure);")
 guard="if (current_card?k) is distinct from (e->>'present')::boolean or\n   ((e->>'present')::boolean and current_card->k is distinct from e->'value') then"
 assert body.count(guard)==1
 query('drop-cas-apply',body.replace(guard,'if false then'))
 failed=run('drop-cas-negative',[*PSQL,'-At','-f',TEST],3);assert 'CARD FAIL: stale same-field save conflicts'in failed
 run('drop-cas-restore',[*PSQL,'-q','-1','-f',TARGET]);run('drop-cas-restored',[*PSQL,'-At','-f',TEST])
 query('ordinary-grant-apply','grant update(public_card)on profiles to authenticated;')
 failed=run('ordinary-grant-negative',[*PSQL,'-At','-f',TEST],3);assert 'CARD FAIL: personal card column cannot be directly updated'in failed
 run('ordinary-grant-restore',[*PSQL,'-q','-1','-f',TARGET]);run('ordinary-grant-restored',[*PSQL,'-At','-f',TEST])
 receipt['negativeControls']=['drop-personal-card-cas','restore-direct-public-card-grant'];races=[]
 for n,same in[(1,False),(2,True)]:
  actor=f'ca100504-0000-4000-8000-{n:012d}';query(f'race{n}-seed',f"insert into auth.users(id,email,is_anonymous)values('{actor}','race{n}@fixture.invalid',false);")
  first=f"select merge_personal_public_card('{actor}','{{\"phone\":\"First phone\"}}','{{\"phone\":{{\"present\":false}}}}');"
  second=f"select merge_personal_public_card('{actor}','{{\"{'phone'if same else 'website'}\":\"{'Second phone'if same else 'https://second.fixture.invalid'}\"}}','{{\"{'phone'if same else 'website'}\":{{\"present\":false}}}}');"
  races.append(race('same-field-first-wins'if same else 'unrelated-fields-merge',actor,first,second,same))
 receipt['races']=races
 assert all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in hashes.items()),'Source changed during proof'
 check=re.search(r'\n(\d+)\nPASS: personal card SQL',positive);assert check
 receipt.update(passed=True,sqlAssertions=int(check[1]))
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BINS['pg_ctl'],'-D',DATA,'-m','fast','-w','-t','30','stop'])
 receipt['finishedAt']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('Personal card evidence:',OUT,flush=True)
print('PASS: account identity, public member fallback, profile CAS mutants and actual races.',flush=True)
