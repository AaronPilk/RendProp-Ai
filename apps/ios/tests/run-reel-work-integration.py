#!/usr/bin/env python3
"""Run actual banner/notification admission bodies with closed Foundation OS doubles."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
a=argparse.ArgumentParser();a.add_argument('--evidence-dir',type=Path);args=a.parse_args()
out=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-reel-work-integration-'));out.mkdir(parents=True,exist_ok=True)
paths=[root/'apps/ios/Rendprop/Render/ReelWorkBanner.swift',root/'apps/ios/Rendprop/Push/PushManager.swift',root/'apps/ios/Rendprop/RendpropApp.swift',root/'apps/ios/tests/ReelWorkIntegrationTests.swift',Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
before=hashes();banner,push,app=[p.read_text()for p in paths[:3]]
def block(s,anchor):
 assert s.count(anchor)==1,anchor
 start=s.index(anchor);begin=s.index('{',start);depth=0;quoted=False;escaped=False
 for i in range(begin,len(s)):
  c=s[i]
  if quoted:
   if escaped:escaped=False
   elif c=='\\':escaped=True
   elif c=='"':quoted=False
   continue
  if c=='"':quoted=True;continue
  if c=='{':depth+=1
  if c=='}':
   depth-=1
   if depth==0:return s[start:i+1]
 raise RuntimeError('Unclosed '+anchor)
# These consumer bindings accompany extracted-body execution. Actual SwiftUI
# rendering and the queue engine remain separate real build/engine proofs.
assert 'PhotoWorkBanner()\n            ReelWorkBanner()\n            tabs.id' in app
assert 'ReelWorkQueue.shared.resumeForeground()' in block(app,'.onChange(of: scenePhase)')
for anchor in ['.onChange(of: analyticsAuth.syncSessionRevision)','.onChange(of: reelConsent.isGranted)']:
 assert 'ReelWorkQueue.shared.reconcileIdentity()'in block(app,anchor)
assert 'ReelWorkQueue.shared.reconcileIdentity()'in block(app,'.onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged))')
assert '.sheet(item: Binding(get: { currentReviewListing }'in banner
assert 'visibleJobs: jobs.visibleJobs' in block(banner,'private var currentReviewListing:')
assert 'NativePresentationAvailability.hasPresentedController'in block(banner,'private func open(')
assert 'visibleJobs: jobs.visibleJobs'in block(banner,'private func open(')
assert 'Task.sleep(nanoseconds: 500_000_000)'in block(banner,'private func reviewPendingNotification()')
assert 'Button("Notify me when ready") { Task { await push.requestAuthorization() } }'in banner
assert 'requestAuthorization'in banner and banner.count('requestAuthorization')==1
assert 'if value == nil { reviewJobID = nil }'in banner
assert 'pendingReelJobID = nil'in block(push,'func accountWillChange(')
body='import Foundation\n'+block(banner,'enum ReelWorkBannerCopy {')+'\n'+block(banner,'@MainActor enum ReelWorkReviewAdmission {')+'\n'+block(push,'enum ReelCompletionNotice {')+'\n'
body+='''@MainActor final class PushManager {
 static var currentIdentity:PushAccountIdentity?
 static let isSuppressed=false
 var pendingRoute:PushRoute?;var pendingReelJobID:UUID?
'''
for anchor in ['    static func accepts(payload:','    func handle(payload:','    func clearPendingReelJob()']:
 body+=block(push,anchor)+'\n'
body+='}\n'
controls=[
 ('unknown-job', '$0.id == jobID', '$0.id == $0.id', 'unknown job cannot open another existing listing'),
 ('wrong-listing', '$0.id == job.listingID', '$0.id == $0.id', 'job cannot route to a different listing'),
 ('sample-review', '!listing.isSample, listing.cloudUnavailable != true', 'true, listing.cloudUnavailable != true', 'sample listing cannot receive real job result'),
 ('unavailable-review', 'listing.cloudUnavailable != true', 'true', 'unavailable listing cannot be reopened by notification'),
 ('false-paused-title', 'if paused { return "Reel paused" }', 'if paused { return "Your reel is ready" }', 'expired OS execution is not advertised as completed'),
 ('lost-job-payload', 'content.userInfo["reel_job_id"] = jobID.uuidString', 'content.userInfo["reel_job_id"] = "invalid"', 'completion payload preserves exact job and listing identity'),
 ('foreign-recipient', 'guard !Self.isSuppressed, Self.accepts(payload: payload, identity: Self.currentIdentity) else { return }', 'guard !Self.isSuppressed else { return }', 'foreign recipient cannot route a reel'),
 ('late-owner-switch', 'guard PushManager.currentIdentity == identity,', 'guard true,', 'account replacement during OS settings cannot enqueue old result'),
 ('late-foreground', 'UIApplication.shared.applicationState != .active else { return }\n                let content', 'true else { return }\n                let content', 'foreground return during settings suppresses completion notification'),
]
variants=[('actual',body,None)]+[(n,body.replace(old,new,1),reason)for n,old,new,reason in controls]
receipt={'passed':False,'sourceHashes':before,'runs':[],'externalRequests':0,'limitations':['Actual copy/admission/notice/tap methods with closed OS and listing/job doubles. No live APNs, actual OS suspension, SwiftUI rendering or queue execution proof; those require separate app/engine/phone checks.']}
try:
 for name,source,expected in variants:
  assert expected is None or source!=body,name+' mutation anchor absent'
  folder=out/name;folder.mkdir(exist_ok=True);production=folder/'Production.swift';production.write_text(source);binary=folder/'gate'
  c=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(production),str(paths[3]),'-o',str(binary)],capture_output=True,text=True,timeout=180)
  (folder/'compile.log').write_text(c.stdout+c.stderr)
  assert c.returncode==0,name+' compile failed: '+c.stderr
  run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30);log=run.stdout+run.stderr;(folder/'runtime.log').write_text(log)
  ok=run.returncode==0 if expected is None else run.returncode!=0 and 'Precondition failed: '+expected in log
  receipt['runs'].append({'case':name,'compileExit':c.returncode,'runtimeExit':run.returncode,'passed':ok,'expected':expected})
  binary.unlink()
  assert ok,name+' oracle failed: '+log
except BaseException as e:
 receipt['failure']=str(e);raise
finally:
 receipt['finalSourceHashes']=hashes();receipt['sourceBindingMatches']=before==receipt['finalSourceHashes']
 receipt['passed']='failure'not in receipt and len(receipt['runs'])==len(variants)and all(r['passed']for r in receipt['runs'])and receipt['sourceBindingMatches']
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert receipt['passed'],'Source changed during integration checks'
print((out/'actual/runtime.log').read_text().strip())
print(f'PASS: {len(controls)} compiled controls; receipt: {out / "receipt.json"}')
