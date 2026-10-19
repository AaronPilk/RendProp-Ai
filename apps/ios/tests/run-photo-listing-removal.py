#!/usr/bin/env python3
"""Compile the actual removal journal/models with bounded corruption controls."""
from pathlib import Path
import argparse,datetime,hashlib,json,re,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output-dir',type=Path);args=p.parse_args()
out=args.output_dir or Path(tempfile.mkdtemp(prefix='rendprop-removal-journal-'));out.mkdir(parents=True,exist_ok=True)
paths=['apps/ios/Rendprop/Photos/PhotoListingRemoval.swift','apps/ios/tests/PhotoListingRemovalTests.swift','apps/ios/tests/run-photo-listing-removal.py']
sha=lambda b:hashlib.sha256(b).hexdigest()
before={p:sha((ROOT/p).read_bytes())for p in paths};source=(ROOT/paths[0]).read_text()
controls=[
 ('replace-unknown-intent','guard saved.hasSameIntent(as: proposed) else { throw Failure.pendingOperation }','', 'Changed pending intent must not overwrite saved operation'),
 ('finish-only-nonce','guard saved == operation else','guard saved.operationID == operation.operationID else','Same UUID with changed body cannot finish pending request'),
 ('adopt-foreign-envelope','entry.schema == 1, entry.scope == scope, entry.operation.scope == scope','entry.schema == 1','A foreign copied envelope cannot bypass scope digest'),
]
r={'checkedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceHashes':before,'networkCalls':0,'hostedMutations':0,'UIExecutions':0,'controls':[]}
for name,old,new,oracle in [('positive',None,None,None),*controls]:
 folder=out/name;folder.mkdir(exist_ok=True);projected=source
 if old is not None:
  assert source.count(old)==1;projected=source.replace(old,new)
 local=folder/'PhotoListingRemoval.swift';local.write_text(projected)
 binary=folder/'checks';files=folder/'owned-fixtures';files.mkdir(exist_ok=True)
 cmd=['xcrun','swiftc','-swift-version','5','-parse-as-library',str(local),str(ROOT/paths[1]),'-o',str(binary)]
 c=subprocess.run(cmd,capture_output=True,text=True,timeout=90);(folder/'compile.log').write_text(c.stdout+c.stderr)
 assert c.returncode==0,f'{name}: compiler failure is not runtime proof; see {folder}'
 e=subprocess.run([str(binary),str(files)],capture_output=True,text=True,timeout=90);log=e.stdout+e.stderr;(folder/'runtime.log').write_text(log)
 if oracle is None:
  assert e.returncode==0,f'Positive runtime failed: {folder}'
  count=re.search(r'(\d+) assertions',log);assert count;r['assertions']=int(count[1])
 else:
  assert e.returncode!=0 and oracle in log,f'{name}: expected runtime oracle missing'
  r['controls'].append({'name':name,'compiled':True,'runtimeRejected':True,'oracle':oracle})
 print(name,'PASS',flush=True)
assert before=={p:sha((ROOT/p).read_bytes())for p in paths},'Consumed source changed during proof'
r['passed']=True;(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps({'passed':True,'assertions':r['assertions'],'compiledControls':len(r['controls']),'receipt':str(out/'receipt.json')}))
