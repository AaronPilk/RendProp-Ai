#!/usr/bin/env python3
"""Compile actual draft creation, pause/retry and typed APIError against closed I/O."""
import hashlib,json,os,re,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
out=Path(tempfile.mkdtemp(prefix="rendprop-listing-create-plan-",dir=os.environ.get("RUNNER_TEMP")))
app=root/"apps/ios/Rendprop/RendpropApp.swift"
api=root/"apps/ios/Rendprop/Networking/APIClient.swift"
template=Path(__file__).with_name("ListingCreatePlanRefusalTests.swift")
def block(source,marker):
    assert source.count(marker)==1,marker
    start=source.index(marker); opening=source.index("{",start); end=opening+1; depth=1
    while depth:
        depth+=(source[end]=="{")-(source[end]=="}");end+=1
    return source[start:end]
a,b=app.read_text(),api.read_text()
assert "await self?.refreshCloudWorkspaceAfterCurrent(retryPlanRequired: false)" in a
refresh=block(a,"    func refreshCloudWorkspace() async")
assert "let planBatch = self.beginDraftCreationPlanBatch()" in refresh and "defer { self.endDraftCreationPlanBatch(planBatch) }" in refresh
markers={"SYNC":"    func syncListing(_ id: UUID)","DIRTY":"    func syncDirtyListings()","BEGIN_BATCH":"    private func beginDraftCreationPlanBatch()","END_BATCH":"    private func endDraftCreationPlanBatch(","RETRY":"    func retryCloudWorkspace()","AFTER_CURRENT":"    private func refreshCloudWorkspaceAfterCurrent(","CAN_RETRY":"    private func canRetryDraftCreation(","FAILURE":"    private func noteDraftCreationFailure(","ENSURE":"    func ensureServerListing(_ listing: Listing)","WORKSPACE":"    func isInSelectedWorkspace(_ listing: Listing)","PUBLISH_ERROR":"    enum PublishError:","USER_MESSAGE":"    static func userMessage(for error: Error)"}
parts={k:block(a,m) for k,m in markers.items()}
parts["MESSAGE"]=next(line for line in a.splitlines() if line.startswith("    static let draftCreationPlanMessage = "))
parts["BATCH_STATE"]=next(line for line in a.splitlines() if line.startswith("    private var draftCreationPlanBatch: "))
parts["API_ERROR"]=block(b,"enum APIError:")
parts["ENTITLEMENTS"]=block(b,"struct Entitlements:")
models=[root/('apps/ios/Rendprop/'+p) for p in ['Models/Listing.swift','Models/ListingClientContact.swift','Models/Money.swift','Networking/NativeReelDraft.swift','Auth/AnonymousAdoptionRecovery.swift','Auth/AdoptionLocalBindings.swift','Networking/WorkspaceSync.swift']]
consumed=[app,api,*models,template,Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
initial={str(p.relative_to(root)):sha(p) for p in consumed}
receipt={"passed":False,"sourceHashes":initial,"actualBodyHashes":{k:hashlib.sha256(v.encode()).hexdigest() for k,v in parts.items()},"runs":[],"scope":"Actual Swift model, typed error, AppModel create/pause/retry/identity methods. Auth, workspace and HTTP are closed controlled doubles. No network, credentials, customer files, simulator or service mutation."}
controls={
 "untyped-refusal":("API_ERROR",'status == 402 && code == "plan_required"','true','Generic errors retain automatic recovery'),
 "repeat-create":("CAN_RETRY",'if listings[i].cloudCreatePlanBlocked == true {','if false {','Known refusal suppresses fifteen automatic creates'),
 "stale-plan-revision":("CAN_RETRY",'AuthStore.shared.syncSessionRevision == revision,','true,','Stale plan response cannot create after session change'),
 "same-plan":("CAN_RETRY",'newlyObservedPaidPlan || (previous != nil && previous != signature)','true','Known refusal suppresses fifteen automatic creates'),
 "foreign-retry":("AFTER_CURRENT",' && isInSelectedWorkspace(listings[i])','', 'Explicit retry preserves another library pause'),
 "direct-bypass":("ENSURE",'if listings.first(where: { $0.id == localID })?.cloudCreatePlanBlocked == true {','if false {','Direct creation honors the saved pause'),
 "batch-read":("CAN_RETRY",'if sharesBatch, let batch, batch.hasRead {','if sharesBatch, let batch, false {','Paused drafts share one fresh plan read per batch'),
 "unknown-paid":("CAN_RETRY",'previous == nil && entitlement.map { ["starter", "solo", "legacy_pro", "pro", "max", "ultra", "team"].contains($0.plan) } == true','false','A paid grant before the first paused refresh recovers automatically'),
 "retry-wait":("AFTER_CURRENT",'            await existing.value','            // injected skipped wait','Explicit retry waits for an existing refresh before creating'),
 "retry-identity":("AFTER_CURRENT",'AuthStore.shared.syncSessionRevision == revision,','true,','A retry requested by an old session preserves the saved pause'),
 "event-cache":("AFTER_CURRENT",'if !retryPlanRequired, let batch = draftCreationPlanBatch,','if false, let batch = draftCreationPlanBatch,','Plan event discards the old standalone batch plan read'),
 "late-failure":("FAILURE",'AuthStore.shared.syncSessionRevision == revision,','true,','Late refusal cannot poison a replacement session'),
}
try:
 for label,mutation in [("actual",None),*controls.items()]:
    compiled=parts.copy()
    if mutation:
        key,old,new,expected=mutation;assert compiled[key].count(old)==(2 if label=="stale-plan-revision" else 1),(label,old);compiled[key]=compiled[key].replace(old,new)
        if label=="repeat-create":
            # The central ensure fence independently prevents automatic POSTs.
            old='if listings.first(where: { $0.id == localID })?.cloudCreatePlanBlocked == true {'
            assert compiled["ENSURE"].count(old)==1
            compiled["ENSURE"]=compiled["ENSURE"].replace(old,"if false {")
    source=template.read_text()
    for key,value in compiled.items():source=source.replace('__'+key+'__',value)
    assert not re.search(r'__[A-Z_]+__',source)
    swift=out/(label+'.swift');swift.write_text(source)
    row={"name":label,"compiledBodyHashes":{k:hashlib.sha256(v.encode()).hexdigest() for k,v in compiled.items()},"commands":[]};receipt['runs'].append(row)
    for stage,command,seconds in [('compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',*map(str,models),str(swift),'-o',str(out/label)],180),('run',[str(out/label)],45)]:
        log=out/(label+'-'+stage+'.log')
        with log.open('w') as f:r=subprocess.run(command,cwd=root,stdout=f,stderr=subprocess.STDOUT,timeout=seconds)
        output=log.read_text();row['commands'].append({'stage':stage,'exit':r.returncode,'log':str(log),'sha256':sha(log)})
        if stage=='compile' and r.returncode:raise RuntimeError(output)
        if stage=='run':
            if mutation:
                assert r.returncode==1 and expected in output,(label,output)
                row['expectedRejection']=expected
            else:
                assert r.returncode==0,output
                row['assertions']=int(re.search(r'(\d+) assertions',output)[1])
    row['passed']=True
    print(label,'PASS',flush=True)
 receipt['sourceBoundAtEnd']=initial=={str(p.relative_to(root)):sha(p) for p in consumed}
 assert receipt['sourceBoundAtEnd']
 receipt['passed']=True
finally:
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 print('Evidence:',out,flush=True)
