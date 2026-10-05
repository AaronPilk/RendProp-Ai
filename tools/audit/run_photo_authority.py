#!/usr/bin/env python3
"""Owned socket-only photo/pricing authority regression; no remote connections."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path);args=parser.parse_args()
OUT=args.output or Path(tempfile.mkdtemp(prefix='rendprop-photo-authority-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
TMP=Path(tempfile.mkdtemp(prefix='rendprop-photo-pg-',dir='/tmp'));DATA=TMP/'cluster';SOCK=TMP/'socket';SOCK.mkdir()
ENV={'PATH':os.environ['PATH'],'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
B={n:shutil.which(n)for n in('initdb','pg_ctl','createdb','psql')};assert all(B.values()),'Local PostgreSQL required'
CONN=['-h',str(SOCK),'-p','55469','-U','postgres'];DB='rendprop_photo_authority'
TARGET=ROOT/'services/supabase/migrations/20261005215832_photo_authority_acl_contract.sql'
files=sorted(TARGET.parent.glob('*.sql'));fixture=ROOT/'services/supabase/tests/photo_authority.sql'
owned=[TARGET.parent/n for n in ['20261005215707_brokerage_pricing_service_acl.sql','20261005215724_photo_authority_rpc_expand.sql',TARGET.name]]
bound=[*files,fixture,Path(__file__).resolve(),ROOT/'services/supabase/functions/studio/listing-actions.ts',ROOT/'services/supabase/functions/studio/listing-actions.test.ts',ROOT/'services/supabase/tests/ci-bootstrap.sql']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in bound}
r={'passed':False,'sourceHashes':hashes,'migrationCount':len(files),'limits':['Synthetic local socket-only database','No provider calls/live writes','Proves existing declared provenance authority; does not classify re-uploaded image semantics']}
def run(name,command,ok=True):
 v=subprocess.run(command,env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90);(OUT/(name+'.log')).write_text(v.stdout)
 if ok:assert v.returncode==0,(name,v.stdout[-2500:])
 return v
try:
 run('init',[B['initdb'],'-D',str(DATA),'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[B['pg_ctl'],'-D',str(DATA),'-l',str(OUT/'postgres.log'),'-w','-o',f"-k {SOCK} -p 55469 -c listen_addresses='' -c shared_buffers=16MB",'start'])
 run('create',[B['createdb'],*CONN,DB]);PS=[B['psql'],'-X','--no-password',*CONN,'-d',DB,'-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PS,'-q','-f',str(ROOT/'services/supabase/tests/ci-bootstrap.sql')])
 for f in files:
  if f==TARGET:
   stage=run('expand-before-contract',[*PS,'-Atqc',"select has_table_privilege('authenticated','photos','UPDATE') and has_function_privilege('service_role','studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid)','EXECUTE')"])
   assert stage.stdout.strip()=='t';r['expandSupportsNewRPCBeforeLegacyRevoke']=True
  run('apply-'+f.stem,[*PS,'-q','-f',str(f)])
 def proof(name):
  v=run(name,[*PS,'-Atq','-f',str(fixture)]);assert 'PASS: photo authority SQL assertions; all fixtures rolled back.'in v.stdout
  nums=re.findall(r'^\d+$',v.stdout,re.M);assert len(nums)==1;return int(nums[0])
 r['fresh']=proof('fresh')
 for f in owned:run('replay-'+f.stem,[*PS,'-q','-f',str(f)])
 r['replay']=proof('replay')
 controls=[('direct-DML','grant update on photos to authenticated','client photo mutations revoked',None),
  ('public-price','grant execute on function brokerage_price_cents(integer)to anon','brokerage pricing private',None),
  ('missing-membership','studio_photo_authority(uuid,uuid,uuid)',"if not found then raise exception 'RP403: Your role does not permit editing photos';end if;",'outsider actor denied'),
  ('caption-CAS','studio_photo_caption(uuid,uuid,uuid,uuid,text,text)',"if photo.caption is distinct from p_expected and photo.caption is distinct from desired then\n  raise exception 'RP409: This caption changed on another device. Refresh before saving again';end if;",'stale caption conflict'),
  ('lost-disclosure','studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid)','staged:=true;original:=mp.original_key;','known altered photo disclosure derived')]
 r['controls']=[]
 for name,target,needle,label in controls:
  if label is None:run('compile-'+name,[*PS,'-qc',target]);expected=needle
  else:
   definition=run('original-'+name,[*PS,'-Atqc',f"select pg_get_functiondef('{target}'::regprocedure)"]).stdout
   assert definition.count(needle)==1,(name,'anchor mismatch')
   mutant=definition.replace(needle,'staged:=false;original:=mp.original_key;'if name=='lost-disclosure'else'',1)
   run('compile-'+name,[*PS,'-qc',mutant]);expected=label
  v=run('control-'+name,[*PS,'-Atq','-f',str(fixture)],False)
  assert v.returncode!=0 and 'PHOTO FAIL: '+expected in v.stdout,(name,v.stdout[-2000:]);r['controls'].append({'name':name,'exactFailure':expected,'compiled':True})
  if label is None:
   restore='revoke update on photos from authenticated'if name=='direct-DML'else'revoke execute on function brokerage_price_cents(integer)from anon'
   run('restore-'+name,[*PS,'-qc',restore])
  else:run('restore-'+name,[*PS,'-qc',definition])
  assert proof('restored-'+name)==r['fresh']
 assert all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in hashes.items());r['sourceBoundAtEnd']=True;r['passed']=True
finally:
 if(DATA/'postmaster.pid').exists():run('stop',[B['pg_ctl'],'-D',str(DATA),'-m','fast','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2));print(json.dumps({'output':str(OUT),'passed':r['passed'],'fresh':r.get('fresh'),'replay':r.get('replay'),'controls':len(r.get('controls',[]))}))
