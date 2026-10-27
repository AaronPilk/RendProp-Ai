#!/usr/bin/env python3
"""Actual Swift consent/HTTP/store/recovery with closed URLProtocol and AV boundary."""
from pathlib import Path
import argparse, hashlib, json, os, shutil, signal, subprocess, time
ROOT = Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output-dir',type=Path,required=True);p.add_argument('--controls',action='store_true');args=p.parse_args()
out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=False)
def floor():
    if shutil.disk_usage(ROOT).free<3*1024**3 or shutil.disk_usage(out).free<8*1024**3:raise RuntimeError('3/8 GiB storage reserve')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def block(s,anchor):
    start=s.index(anchor);o=s.index('{',start);depth=1;e=o+1
    while depth:depth+=(s[e]=='{')-(s[e]=='}');e+=1
    return s[start:e]
rels=['apps/ios/Rendprop/Render/VideoAspectChoice.swift','apps/ios/Rendprop/Render/VideoMusicContract.swift','apps/ios/Rendprop/Render/VideoMusicCatalog.swift','apps/ios/Rendprop/Models/ListingVideo.swift','apps/ios/Rendprop/Render/PropertyVideoProcessorConsent.swift','apps/ios/Rendprop/Render/PropertyVideoJob.swift','apps/ios/Rendprop/Render/PropertyVideoAdmission.swift','apps/ios/Rendprop/Networking/PropertyVideoJobsAPI.swift','apps/ios/Rendprop/Networking/PropertyVideoJobCancellation.swift','apps/ios/Rendprop/Render/PropertyVideoJobRunner.swift','apps/ios/tests/PropertyVideoProcessorTests.swift','packages/client-contracts/property-video-processor-disclosure.json',str(Path(__file__).relative_to(ROOT)), 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift','apps/ios/Rendprop/RendpropApp.swift','apps/ios/Rendprop/Models/PublishedListingVideoState.swift','apps/ios/Rendprop/Models/CreditWallet.swift']
hashes={r:sha(ROOT/r) for r in rels};floor();(out/'tmp').mkdir()
# Original-master upload belongs to the photo-motion source gate. Keep this
# processor proof's compiled API surface focused on job admission and recovery.
network=(ROOT/rels[7]).read_text()
network=network.replace(block(network,'enum PropertyVideoOriginalMaster {'),'')
source='\n'.join(network if i==7 else (ROOT/r).read_text() for i,r in enumerate(rels[:9]))
# These unrelated selected-download and aerial-credit signatures are part of
# the current transport source. Compile their actual value/validation bodies;
# close only the enclosing types that this processor-permission test never runs.
source+='\nenum PublishedListingVideoState { enum StateError: Error { case invalid } }\n'
source+=block((ROOT/rels[15]).read_text(),'struct SelectedListingVideoDownload:')+'\n'
source+='\nstruct CreditWalletSnapshot { struct Quote { let operation: String; let tariffVersion: String; let credits: Int } }\nenum CloudSyncError: Error { case invalidResponse }\n'
source+=block((ROOT/rels[16]).read_text(),'struct AerialCreditAuthorization:')+'\n'
runner=(ROOT/rels[9]).read_text().replace('import UIKit','').replace('import AVFoundation','')
ready=block(runner,'    private func retainReady(')
runner=runner.replace(ready,'    private func retainReady(_ saved: PropertyVideoSavedJob, watch: Watch) async throws { throw PropertyVideoJobStore.Failure.invalidReceipt }')
source+='\n'+runner
view=(ROOT/rels[13]).read_text();view=view[view.index('struct ReelStudioView: View'):] 
preparation=block(view,'    private func requireProcessorPreparation(').replace('private func','func',1)
baseConsent=(ROOT/rels[14]).read_text();baseConsent=baseConsent[baseConsent.index('final class AIConsent:'):];source+='\nextension AIConsent {\n'+block(baseConsent,'    func revoke()')+'\n}\n'
assert 'private static let storageKey = "ai.thirdPartyProcessing.consent.v3"' in baseConsent
source+='\n@MainActor struct ActualPreparationGate { let listing:ClosedListing;let model:AppModel;let processorConsent=PropertyVideoProcessorConsent.shared;let auth=AuthStore.shared;\n'+preparation+'\n}\n'
# The real UI wrappers gate each paid path; this is supplemental ordering evidence,
# while the extracted actual predicate is executed in Swift below.
for name,paid in [('runScriptWriter','runScriptWriterWithSession()'),('generateAIVoice','generateAIVoiceWithSession()')]:
    assert 'authorizeVideoPreparation { '+paid+' }' in block(view,'    private func '+name+'()')
assert 'authorizeVideoPreparation { generateWithSession() }' in block(view,'    private func generate()')
assert 'try requirePreparedProcessor()' in block(view,'    private func generateWithSession()')
assert 'processorPermission: frozenProcessorPermission' in block(view,'    private func generateWithSession()')
variants=[('actual',source,None)]
if args.controls:
    mutations=[
      ('unknown-contract','guard value.isKnown else','guard true else','unknown disclosure must fail closed'),
      ('scope','actorID == context.actorID && orgID == context.orgID','true','another actor cannot borrow permission'),
      ('immutable-snapshot',', existing.processorPermission == saved.processorPermission','', 'saved operation cannot lose or upgrade its permission snapshot'),
      ('unknown-metadata','guard processorMetadataUnknown != true else','guard true else','partial own metadata keys never enable paid resume'),
      ('resume-v2-downgrade','paid = .processor(permission)','paid = .legacy','actual saved-v2 FAL resume keeps frozen v2 independent of endpoint'),
      ('current-grant','snapshot.matches(context) && grant(for: context)?.contract == snapshot.contract','snapshot.matches(context)','revoked permission cannot sign prospective requests'),
      ('legacy-fallback','status == 404, code == "processor_disclosure_unpublished"','status == 404','other disclosure failures cannot become v1'),
      ('stop-durability','saved.stopRequested = true\n            try save(saved','saved.stopRequested = false\n            try save(saved','Kie revoke clears grant and persists exact stop before async cancellation'),
      ('stale-read-watch','revision: AuthStore.shared.syncSessionRevision, consentRevision: AIConsent.shared.revocationRevision)','revision: old.revision, consentRevision: old.consentRevision)','displayed status watch reattaches after revoke without new paid work'),
      ('paid-preparation-session','auth.syncSessionRevision == sessionEpoch,','true,','pending paid preparation cannot borrow a later session'),
      ('durable-resume-stop','guard saved.stopRequested != true else','guard true else','explicit resume reloads durable stop instead of borrowing stale in-memory authority'),
      ('base-revoke-supplement','PropertyVideoProcessorConsent.shared.revoke()','/* compiled omitted supplementary revoke */','actual base revoke synchronously clears supplemental grant and journals stop'),
      ('abandon-scope','operationID == request.operationID && listingID == request.listingID && selectedLibraryOrgID == request.expectedOrgID && closedReason == "abandoned"','closedReason == "abandoned"','another operation cannot supply this abandonment'),
    ]
    for name,old,new,oracle in mutations:
      if old not in source:raise RuntimeError('Mutation anchor missing '+name)
      changed=source.replace(old,new,1)
      if name=='durable-resume-stop':changed=changed.replace('current.request == saved.request, current.stopRequested != true','current.request == saved.request, true')
      variants.append((name,changed,oracle))
receipt={'passed':False,'sourceHashes':hashes,'runs':[],'closedBoundaries':['AV retainReady deliberately refuses; no media/download/UI/phone acceptance','Every URL intercepted by actual URLProtocol; no external/provider requests'],'wholeDeadlineSeconds':240}
env={k:v for k,v in os.environ.items() if k in ['PATH','HOME','USER','LOGNAME','DEVELOPER_DIR','SDKROOT']};env['TMPDIR']=str(out/'tmp')+'/';env['CANONICAL_DISCLOSURE']=str(ROOT/rels[11]);started=time.monotonic()
def run(cmd,log):
    floor()
    with log.open('w') as f:
      process=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT,env=env,start_new_session=True)
      try:
       while process.poll() is None:
        floor()
        if time.monotonic()-started>240:raise RuntimeError('Whole proof deadline')
        time.sleep(.2)
      except BaseException:
       os.killpg(process.pid,signal.SIGTERM)
       try:process.wait(timeout=3)
       except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
       raise
    return process.returncode
try:
 for name,text,oracle in variants:
    d=out/name;d.mkdir();(d/'Production.swift').write_text(text)
    build=run(['xcrun','swiftc','-parse-as-library',str(d/'Production.swift'),str(ROOT/rels[10]),'-o',str(d/'checks')],d/'build.log')
    if build:raise RuntimeError('Compile failed: '+name)
    exit=run([str(d/'checks')],d/'run.log');log=(d/'run.log').read_text()
    passed=exit==0 if oracle is None else exit!=0 and oracle in log
    receipt['runs'].append({'name':name,'exit':exit,'oracle':oracle,'passed':passed,'logSHA256':sha(d/'run.log')})
    if not passed:raise RuntimeError('Actual intended oracle not proved: '+name)
 receipt['sourceHashesAtEnd']={r:sha(ROOT/r) for r in rels};receipt['passed']=receipt['sourceHashesAtEnd']==hashes
 if not receipt['passed']:raise RuntimeError('Source drift')
except BaseException as e:
 receipt['error']=str(e);raise
finally:
 receipt['elapsedSeconds']=time.monotonic()-started;(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'passed':receipt['passed'],'runs':len(receipt['runs']),'receipt':str(out/'receipt.json')}))
