#!/usr/bin/env python3
"""Causal old/new actual automatic gallery sink; all network/upload dependencies closed."""
from pathlib import Path
import argparse,datetime,hashlib,json,shutil,subprocess
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output-dir',type=Path,required=True);a=p.parse_args();a.output_dir.mkdir(parents=True,exist_ok=False)
paths=['apps/ios/Rendprop/RendpropApp.swift','apps/ios/Rendprop/Networking/APIClient.swift','apps/ios/Rendprop/Networking/LiveAPIClient.swift','apps/ios/Rendprop/Networking/MockAPIClient.swift','apps/ios/tests/PhotoCloudAutomaticSyncTests.swift','apps/ios/tests/run-photo-cloud-automatic-sync.py']
h=lambda b:hashlib.sha256(b).hexdigest();source={x:h((ROOT/x).read_bytes())for x in paths}
assert shutil.disk_usage('/').free>=3*1024**3 and shutil.disk_usage(a.output_dir).free>=8*1024**3
baseline='1eb0fbe1475ad47d0a06c548cec6ab4ed88fb77e'
old=subprocess.check_output(['git','show',baseline+':'+paths[0]],cwd=ROOT,text=True)
new=(ROOT/paths[0]).read_text();fixture=(ROOT/paths[4]).read_text()
def block(s,marker):
 assert s.count(marker)==1,marker
 start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
results=[]
for name,text,red in [('delivered87-old',old,True),('current',new,False)]:
 folder=a.output_dir/name;folder.mkdir();owned=folder/'fixtures';owned.mkdir()
 actual=block(text,'    func syncGalleryPhotos(');end=block(text,'    func endPhotoGalleryRemoval(')
 main=fixture.replace('// __ACTUAL_SYNC__',actual).replace('// __ACTUAL_END_REMOVAL__',end);(folder/'Main.swift').write_text(main)
 c=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(folder/'Main.swift'),'-o',str(folder/'checks')],capture_output=True,text=True,timeout=120)
 (folder/'compile.log').write_text(c.stdout+c.stderr);assert c.returncode==0,name+': compile failure is not behavioral proof'
 r=subprocess.run([str(folder/'checks'),str(owned)],capture_output=True,text=True,timeout=60);log=r.stdout+r.stderr;(folder/'runtime.log').write_text(log)
 assert (r.returncode!=0 and 'Automatic callbacks must never upload or mutate gallery/cover'in log)if red else r.returncode==0,name+': intended causal oracle missing'
 results.append({'name':name,'exit':r.returncode,'expectedRefusal':red,'actualMethodSHA256':h(actual.encode()),'actualFenceReleaseSHA256':h(end.encode()),'runtimeSHA256':h(log.encode())})
for path in paths[1:4]:
 text=(ROOT/path).read_text();assert 'func selectListingPhotos('not in text and 'func addListingPhotos('not in text,'Legacy bulk capability remains: '+path
assert source=={x:h((ROOT/x).read_bytes())for x in paths},'Consumed source changed'
receipt={'passed':True,'checkedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'baselineCommit':baseline,'sourceHashes':source,'results':results,'nativeAPIClosesBothBulkCapabilities':True,'externalNetworkCalls':0,'hostedWrites':0,'UIExecutions':0,'limits':'Actual shared sink and fence release compiled. Callback labels exercise the common sink; they do not claim separate SwiftUI/device event acceptance.'}
(a.output_dir/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'passed':True,'results':results}))
