#!/usr/bin/env python3
"""Actual initial publication loop + actual coordinator/journal, closed transport/history boundary."""
from pathlib import Path
import argparse,datetime,hashlib,json,shutil,subprocess
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output-dir',type=Path,required=True);a=p.parse_args();a.output_dir.mkdir(parents=True,exist_ok=False)
paths=['apps/ios/Rendprop/Photos/PhotoCloudSelection.swift','apps/ios/Rendprop/Photos/PhotoCloudSelectionCoordinator.swift','apps/ios/Rendprop/RendpropApp.swift','apps/ios/tests/PhotoCloudSelectionCoordinatorTests.swift','apps/ios/tests/PhotoCloudInitialPublicationTests.swift','apps/ios/tests/run-photo-cloud-initial-publication.py']
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();source={p:h(ROOT/p)for p in paths}
assert shutil.disk_usage('/').free>=3*1024**3 and shutil.disk_usage(a.output_dir).free>=8*1024**3
app=(ROOT/paths[2]).read_text();marker='    private func publishInitialPhotoChoicesIfNeeded(';start=app.index(marker);end=app.index('{',start)+1;depth=1
while depth:depth+=(app[end]=='{')-(app[end]=='}');end+=1
actual=app[start:end].replace('private func','func',1)
marker='    func prepareCloudPhotoHide(';hs=app.index(marker);he=app.index('{',hs)+1;depth=1
while depth:depth+=(app[he]=='{')-(app[he]=='}');he+=1
hide=app[hs:he]

fixture=(ROOT/paths[3]).read_text().split('@main struct PhotoCloudSelectionChecks')[0]
main=(ROOT/paths[4]).read_text().replace('// __ACTUAL_SELECTION_FIXTURE__',fixture).replace('// __ACTUAL_INITIAL_QUEUE__',actual).replace('// __ACTUAL_HIDE_ADMISSION__',hide)
(a.output_dir/'Main.swift').write_text(main)
c=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(ROOT/paths[0]),str(ROOT/paths[1]),str(a.output_dir/'Main.swift'),'-o',str(a.output_dir/'checks')],capture_output=True,text=True,timeout=120)
(a.output_dir/'compile.log').write_text(c.stdout+c.stderr);assert c.returncode==0,'Compile failure is not behavior proof'
fixtures=a.output_dir/'fixtures';fixtures.mkdir();r=subprocess.run([str(a.output_dir/'checks'),str(fixtures)],capture_output=True,text=True,timeout=60)
(a.output_dir/'runtime.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stdout+r.stderr
assert source=={p:h(ROOT/p)for p in paths},'Consumed source changed'
v={'passed':True,'checkedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceHashes':source,'actualInitialLoopSHA256':hashlib.sha256(actual.encode()).hexdigest(),'actualHideAdmissionSHA256':hashlib.sha256(hide.encode()).hexdigest(),'output':r.stdout,'externalNetworkCalls':0,'hostedWrites':0,'UIExecutions':0,'limits':'Actual initial loop, coordinator, journal; transport and local-version enumeration closed, no publication call or physical proof.'}
(a.output_dir/'receipt.json').write_text(json.dumps(v,indent=2)+'\n');print(r.stdout)
