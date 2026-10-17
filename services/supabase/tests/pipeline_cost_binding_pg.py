#!/usr/bin/env python3
"""Portable owned-PostgreSQL proof of actual pipeline cost/admission linkage.

Uses installed Python/PostgreSQL only. No install, live DB, provider or credential.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,tempfile,time
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[3]
OWN='20261017115012_conservative_pipeline_cost_binding.sql'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,v):
 with p.open('x')as f:os.chmod(p,0o600);json.dump(v,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--evidence-dir',type=Path,required=True);ap.add_argument('--pg-bin',type=Path);ap.add_argument('--socket-dir',type=Path);a=ap.parse_args()
 out=a.evidence_dir.resolve();assert not out.is_relative_to(ROOT)and not out.exists(),'Fresh evidence outside repository required';out.mkdir(parents=True,mode=0o700)
 start=time.monotonic();mins={};child=None;server=False;socket=None;commands=[];data=out/'data';r={'passed':False,'liveProviderCalls':0,'scope':'actual pipeline closed-transport + chronological owned PostgreSQL','startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 def guard():
  assert time.monotonic()-start<300,'Whole300s deadline'
  for k,p,f in [('internal','/',3*1024**3),('evidence',out,(8 if sys.platform=='darwin'else 1)*1024**3)]:
   n=shutil.disk_usage(p).free;mins[k]=min(mins.get(k,n),n);assert n>=f,'Storage reserve:'+k
 env={'PATH':'/usr/bin:/bin','HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),'PYTHONDONTWRITEBYTECODE':'1','LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
 def run(name,args,limit=30,body=None,expected=0,cleanup=False):
  nonlocal child
  if not cleanup:guard()
  p=out/(str(len(commands)).zfill(3)+'-'+name+'.log');began=time.monotonic()
  with p.open('xb')as stream:
   child=subprocess.Popen(list(map(str,args)),stdin=subprocess.PIPE if body else subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,env=env,cwd=ROOT,start_new_session=True)
   if body:child.stdin.write(body.encode());child.stdin.close()
   while child.poll()is None:
    if not cleanup:guard()
    assert time.monotonic()-began<limit and p.stat().st_size<=4*1024**2,'Child budget/log cap:'+name;time.sleep(.05)
   child.wait(timeout=2);assert time.monotonic()-began<limit and p.stat().st_size<=4*1024**2,'Terminal budget/log cap:'+name
   if not cleanup:guard()
  rec={'name':name,'argv':list(map(str,args)),'exitCode':child.returncode,'seconds':time.monotonic()-began,'log':str(p),'sha256':sha(p)};commands.append(rec);child=None
  assert rec['exitCode']==expected,'Unexpected command exit:'+name+':'+p.read_text()[-1800:]
  return p.read_text()
 try:
  guard();(out/'home').mkdir();(out/'tmp').mkdir()
  if a.pg_bin:pg=a.pg_bin.resolve()
  else:
   config=shutil.which('pg_config');assert config,'Installed pg_config or --pg-bin required';pg=Path(subprocess.check_output([config,'--bindir'],timeout=10,text=True).strip()).resolve()
  assert all((pg/n).is_file()and os.access(pg/n,os.X_OK)for n in ['initdb','pg_ctl','postgres','psql']),'Existing PostgreSQL tools required'
  migrations=sorted((ROOT/'services/supabase/migrations').glob('*.sql'));assert len([p for p in migrations if p.name==OWN])==1,'Own migration required'
  inputs=[*migrations,ROOT/'services/supabase/tests/ci-bootstrap.sql',Path(__file__),ROOT/'services/supabase/tests/pipeline_cost_binding_cases.py']
  inputs+=sorted((ROOT/'services/pipeline').glob('*.py'))+sorted((ROOT/'services/pipeline/providers').glob('*.py'))
  pins={str(p):sha(p)for p in inputs};tools={str(p):sha(p)for p in [Path(sys.executable).resolve(),*[pg/n for n in ['initdb','pg_ctl','postgres','psql']]]}
  def verify():
   for p,v in {**pins,**tools}.items():assert sha(p)==v,'Consumed source/tool drift:'+p
  if a.socket_dir:
   socket=a.socket_dir.absolute();assert socket.parent.resolve()==Path('/tmp').resolve()and socket.name.startswith('rp-pipeline-')and not socket.exists(),'Exclusive short owned socket path required';socket.mkdir(mode=0o700)
  else:socket=Path(tempfile.mkdtemp(prefix='rp-pipeline-',dir='/tmp'))
  port=52000+os.getpid()%10000
  write(out/'INTENT.json',{'sourcePins':pins,'toolPins':tools,'migrations':len(migrations),'network':'Supplier and REST HTTP are closed fixture functions; PostgreSQL Unix socket only','wholeSeconds':300,'childCaseSeconds':90})
  run('initdb',[pg/'initdb','-D',data,'-A','trust','-U','postgres','--no-locale','-E','UTF8'])
  run('start',[pg/'pg_ctl','-D',data,'-l',out/'postgres.log','-o',"-F -c listen_addresses='' -k "+str(socket)+' -p '+str(port),'-w','start']);server=True
  psql=[str(pg/'psql'),'-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h',str(socket),'-p',str(port),'-U','postgres','-d','postgres']
  run('bootstrap',psql+['-f',ROOT/'services/supabase/tests/ci-bootstrap.sql'])
  for i,m in enumerate(migrations):run('migration-'+str(i).zfill(3),psql+['-f',m])
  write(out/'fixture.json',{'psql':psql,'env':env})
  env['PIPELINE_COST_PG_FIXTURE']=str(out/'fixture.json');env['PIPELINE_COST_CASE_EVIDENCE']=str(out/'positive-cases.json')
  positive=run('actual-pipeline-and-sql',[sys.executable,'-B',ROOT/'services/supabase/tests/pipeline_cost_binding_cases.py','-v'],limit=90)
  assert re.search(r'Ran [1-9][0-9]* tests',positive)and positive.rstrip().endswith('OK'),'Actual case inventory required'
  r['caseCount']=int(re.search(r'Ran ([1-9][0-9]*) tests',positive).group(1));r['positiveCases']=str(out/'positive-cases.json')
  env['PIPELINE_COST_FAULT']='omit-python-binding';env['PIPELINE_COST_CASE_EVIDENCE']=str(out/'omission-cases.json')
  omitted=run('omit-python-binding',[sys.executable,'-B',ROOT/'services/supabase/tests/pipeline_cost_binding_cases.py','PipelineCostTests.test_actual_pipeline_same_attempt_once','-v'],limit=30,expected=1)
  assert 'AssertionError: 8.0 != 4 : Pipeline same attempt counted twice'in omitted or 'AssertionError: 8 != 4 : Pipeline same attempt counted twice'in omitted,'Exact old-defect omission witness required'
  assert 'Ran 1 test'in omitted and 'FAILED (failures=1)'in omitted and 'ERROR:'not in omitted,'No setup failures admitted as omission'
  env.pop('PIPELINE_COST_FAULT');verify();guard();r.update(passed=True,currentMigrationCount=len(migrations),sourceUnchanged=True,sourcePins=pins,toolPins=tools,actualBindingOmissionRefused=True)
 except BaseException as e:r['error']=type(e).__name__+': '+str(e)
 finally:
  cleanup=[]
  if child and child.poll()is None:
   try:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=3)
   except BaseException as e:cleanup.append('active child:'+str(e))
  marker=data/'postmaster.pid'
  if server:
   try:run('stop',[pg/'pg_ctl','-D',data,'-m','immediate','-w','stop'],cleanup=True,limit=15)
   except BaseException as e:cleanup.append('stop:'+str(e))
  try:
   if marker.exists():
    pid=abs(int(marker.read_text().splitlines()[0]));alive=True
    try:os.kill(pid,0)
    except ProcessLookupError:alive=False
    assert not alive,'Owned PostgreSQL PID remains active'
   if data.exists():shutil.rmtree(data)
   if socket and socket.exists():shutil.rmtree(socket)
  except BaseException as e:cleanup.append('owned cleanup:'+str(e))
  try:
   if 'verify'in locals():verify()
   guard()
  except BaseException as e:cleanup.append('terminal guard/binding:'+str(e))
  r.update(commands=commands,cleanupErrors=cleanup,ownedDataRemoved=not data.exists(),ownedSocketRemoved=not socket or not socket.exists(),minimumFreeBytes=mins,seconds=time.monotonic()-start)
  if cleanup:r['passed']=False
  write(out/'receipt.json',r);print(json.dumps({k:r[k]for k in ['passed','error','caseCount','currentMigrationCount','cleanupErrors','seconds','minimumFreeBytes']if k in r}),flush=True)
 return 0 if r['passed']else 1
if __name__=='__main__':raise SystemExit(main())
