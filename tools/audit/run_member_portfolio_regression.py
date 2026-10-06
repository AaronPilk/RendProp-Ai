#!/usr/bin/env python3
"""Synthetic portfolio authority/CAS proof in an owned, socket-only database."""
from datetime import datetime,timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase';MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
TARGET=SQL/'migrations/20261006164755_hosted_portfolio_selection.sql';TEST=SQL/'tests/member_portfolios.sql'
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-portfolio-db-',dir='/tmp'));DATA=OUT/'cluster';SOCK=OUT/'socket';SOCK.mkdir(mode=0o700)
BINS={n:shutil.which(n)for n in['initdb','pg_ctl','createdb','psql']};assert all(BINS.values())
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
CONN=['-h',str(SOCK),'-p','55469','-U','postgres'];PSQL=[BINS['psql'],'-X','--no-password',*CONN,'-d','rendprop_portfolio','-v','ON_ERROR_STOP=1']
EXPORT=SQL/'functions/me/export.ts';RETENTION=SQL/'tests/hosting_retention.sql';RETENTION_MIGRATION=SQL/'migrations/20261006172251_prospective_hosting_retention.sql'
tracked=[*MIGRATIONS,TEST,RETENTION,pathlib.Path(__file__).resolve(),SQL/'tests/ci-bootstrap.sql',SQL/'functions/me/portfolio.ts',SQL/'functions/me/portfolio.test.ts',SQL/'functions/portfolio/index.ts',EXPORT]
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'limits':['Owned socket-only Postgres','Synthetic members, listings and published render metadata','No hosted DB, R2, provider, Apple or customer writes'],'passed':False,'commands':[]};started=False
# Immutable SQL copies make the actual tested migration set reviewable.
SNAP=OUT/'sql';SNAP.mkdir()
for p in[*MIGRATIONS,TEST,RETENTION,SQL/'tests/ci-bootstrap.sql']:shutil.copyfile(p,SNAP/p.name)
def run(name,args,expected=0,timeout=45):
 r=subprocess.run([str(x)for x in args],env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout);log=OUT/(name+'.log');log.write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});assert r.returncode==expected,(name,r.returncode,r.stdout[-3000:]);return r.stdout

def query(name,sql,expected=0):
 p=OUT/(name+'.sql');p.write_text(sql);return run(name,[*PSQL,'-At','-f',p],expected)
try:
 run('init',[BINS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BINS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55469 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('create',[BINS['createdb'],'--no-password',*CONN,'rendprop_portfolio'])
 assert query('identity',"select current_setting('data_directory')||'|'||current_setting('listen_addresses')||'|'||current_database();").strip()==f'{DATA}||rendprop_portfolio'
 run('bootstrap',[*PSQL,'-q','-f',SNAP/'ci-bootstrap.sql'])
 for p in MIGRATIONS:run('apply-'+p.stem,[*PSQL,'-q','-1','-f',SNAP/p.name])
 for phase in['fresh','target-replayed']:
  if phase=='target-replayed':
   run('target-replay',[*PSQL,'-q','-1','-f',SNAP/TARGET.name]);run('retention-target-replay',[*PSQL,'-q','-1','-f',SNAP/RETENTION_MIGRATION.name])
  proof=run('selection-'+phase,[*PSQL,'-At','-f',SNAP/TEST.name]);assert 'PASS: member portfolio SQL assertions; all fixtures rolled back.'in proof
  # Validate every column the actual account-export query builder selects,
  # rather than a separately maintained mirror of its schema. All expressions
  # here are literal identifiers; reject a future dynamic source shape.
  source=EXPORT.read_text()
  columns=re.findall(r'(?:own|child)\("([a-z_]+)", "([a-z0-9_,]+)"',source)
  columns+=re.findall(r'name: "([a-z_]+)", fields: "([a-z0-9_,]+)"',source)
  assert len(columns)==27 and {'profiles','memberships','orgs','listings','capture_chapters','studio_documents','apple_subscriptions','serving_operation_results'}.issubset({name for name,_ in columns}),('Unknown export query inventory',columns)
  statements='set role service_role;'+''.join(f'select {fields} from public.{name} limit 0;' for name,fields in columns)
  query('account-export-schema-'+phase,statements)
  receipt.setdefault('accountExportSchema',[]).append({'phase':phase,'actualSourceSelects':len(columns),'passed':True})
  retention=run('hosting-retention-'+phase,[*PSQL,'-At','-f',SNAP/RETENTION.name]);assert'PASS hosting retention SQL: 19 assertions'in retention
  receipt.setdefault('hostingRetention',[]).append({'phase':phase,'assertions':19,'passed':True})
 body=query('selection-definition',"select pg_get_functiondef('save_member_portfolio(uuid,uuid,bigint,uuid[])'::regprocedure);")
 receipt['negativeControls']=[]
 for name,needle,replacement,denial in[
  ('remove-ownership','and l.agent_id=p_actor','', 'other member listing cannot be selected'),
  ('remove-cas','if coalesce(p.revision,0)<>p_expected then','if false then','stale different selection conflicts'),
 ]:
  assert body.count(needle)==1
  query(name+'-apply',body.replace(needle,replacement))
  rejected=run(name+'-negative',[*PSQL,'-At','-f',SNAP/TEST.name],3);assert 'PORTFOLIO FAIL: '+denial in rejected
  query(name+'-restore',body);run(name+'-restored',[*PSQL,'-At','-f',SNAP/TEST.name]);receipt['negativeControls'].append(name)
 # Concurrent empty selection writers: observe a real profile lock, then CAS loss.
 actor='ca100603-0000-4000-8000-000000000001'
 query('race-seed',f"insert into auth.users(id,email,is_anonymous)values('{actor}','portfolio-race@fixture.invalid',false);")
 org=query('race-org',f"select org_id from memberships where user_id='{actor}';").strip()
 lid='ca100604-0000-4000-8000-000000000001'
 query('race-listing-seed',f"insert into listings(id,org_id,agent_id,address,details)values('{lid}','{org}','{actor}','Synthetic race listing','{{\"allow_indexing\":true}}');insert into render_jobs(id,listing_id,status)values('{lid}','{lid}','completed');insert into renders(job_id,listing_id,slug,duration_s,published_at)values('{lid}','{lid}','fixture-portfolio-race',10,now());")
 receipt['races']=[]
 for name,firstSQL,secondSQL,expected,finalSQL in[
  ('matching-replay',f"select save_member_portfolio('{actor}','{org}',0,'{{}}');",f"select save_member_portfolio('{actor}','{org}',0,'{{}}');",0,"revision=1 and cardinality(listing_ids)=0"),
  ('different-selection',f"select save_member_portfolio('{actor}','{org}',1,array['{lid}'::uuid]);",f"select save_member_portfolio('{actor}','{org}',1,'{{}}');",3,f"revision=2 and listing_ids=array['{lid}'::uuid]")
 ]:
  first=OUT/(name+'-first.log');second=OUT/(name+'-second.log');f1=first.open('w');f2=second.open('w');p2=None
  p1=subprocess.Popen(PSQL,env={**ENV,'PGAPPNAME':'portfolio-first'},text=True,stdin=subprocess.PIPE,stdout=f1,stderr=subprocess.STDOUT)
  try:
   p1.stdin.write('begin;set local role service_role;'+firstSQL+'\n\\echo PORTFOLIO_LOCK_HELD\n');p1.stdin.flush();deadline=time.monotonic()+5
   while 'PORTFOLIO_LOCK_HELD'not in first.read_text():assert p1.poll()is None and time.monotonic()<deadline;time.sleep(.03)
   path=OUT/(name+'-second.sql');path.write_text('set role service_role;'+secondSQL)
   p2=subprocess.Popen([*PSQL,'-f',path],env={**ENV,'PGAPPNAME':'portfolio-second'},stdout=f2,stderr=subprocess.STDOUT,text=True);deadline=time.monotonic()+5;blocked=False
   while time.monotonic()<deadline:
    if query(name+'-lock',"select count(*)from pg_stat_activity where application_name='portfolio-second'and wait_event_type='Lock';").strip()=='1':blocked=True;break
    assert p2.poll()is None;time.sleep(.03)
   assert blocked,'actual portfolio writer did not wait for profile boundary'
   p1.stdin.write('commit;\n\\q\n');p1.stdin.flush();p1.wait(timeout=10);p2.wait(timeout=10);assert p1.returncode==0 and p2.returncode==expected
   if expected:assert 'RP409'in second.read_text()
   assert query(name+'-result',f"select {finalSQL} from member_portfolios where user_id='{actor}';").strip()=='t'
   receipt['races'].append({'name':name,'observedProfileLock':True,'secondWriterExit':expected,'matchingReplayPreservedRevision':expected==0,'staleDifferentSelectionRefused':expected==3})
  finally:
   for process in[p1,p2]:
    if process and process.poll()is None:process.terminate();process.wait(timeout=10)
   f1.close();f2.close()
 assert all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in hashes.items()),'Source changed during proof'
 receipt.update(passed=True,freshAndTargetReplay=True)
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BINS['pg_ctl'],'-D',DATA,'-m','fast','-w','-t','30','stop'])
 receipt['finishedAt']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('Portfolio evidence:',OUT,flush=True)
print('PASS: deliberate member portfolio selection, compiled ownership/CAS mutants and actual writer serialization.',flush=True)
