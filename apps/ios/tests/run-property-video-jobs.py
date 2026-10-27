#!/usr/bin/env python3
"""Execute actual native receipt/storage policies. Network/AV/UI are closed."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', type=Path); args = p.parse_args()
out = (args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-property-video-jobs-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
core = [ROOT / x for x in ['apps/ios/Rendprop/Render/VideoAspectChoice.swift', 'apps/ios/Rendprop/Render/VideoMusicContract.swift',
    'apps/ios/Rendprop/Render/VideoMusicCatalog.swift', 'apps/ios/Rendprop/Models/ListingVideo.swift', 'apps/ios/Rendprop/Render/PropertyVideoProcessorConsent.swift', 'apps/ios/Rendprop/Render/PropertyVideoJob.swift', 'apps/ios/Rendprop/Render/PropertyVideoAdmission.swift', 'apps/ios/Rendprop/Networking/PropertyVideoJobCancellation.swift']]
fixture = ROOT / 'apps/ios/tests/PropertyVideoJobTests.swift'
bindings = core + [fixture, Path(__file__), *[ROOT / x for x in ['apps/ios/Rendprop/Networking/PropertyVideoJobsAPI.swift',
    'apps/ios/Rendprop/Networking/PropertyVideoNarrationUpload.swift', 'apps/ios/Rendprop/Render/PropertyVideoJobRunner.swift',
    'apps/ios/Rendprop/Render/ReelWorkQueue.swift', 'apps/ios/Rendprop/Render/ReelWorkBanner.swift',
    'apps/ios/Rendprop/Screens/FlythroughDetailView.swift', 'apps/ios/Rendprop/Push/PushManager.swift']]]
hashes = lambda: {str(x.relative_to(ROOT)): hashlib.sha256(x.read_bytes()).hexdigest() for x in bindings}
before = hashes(); production = '\n'.join(x.read_text() for x in core)
def block(text, anchor):
    start=text.index(anchor);opening=text.index('{',start);depth=1;end=opening+1
    while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[start:end]
def declaration(text, anchor):
    return next(line for line in text.splitlines() if line.strip().startswith(anchor))
network_source=(ROOT/'apps/ios/Rendprop/Networking/PropertyVideoJobsAPI.swift').read_text()
runner_source=(ROOT/'apps/ios/Rendprop/Render/PropertyVideoJobRunner.swift').read_text()
production += '\n'+block(network_source,'extension PropertyVideoJobContext {')
watch = block(runner_source, 'private struct Watch {')
scope = '\n'.join([watch, declaration(runner_source, 'private var watches:'),
    declaration(runner_source, 'private var retiredPresentations:'),
    block(runner_source, 'private func requireIdentity('), block(runner_source, 'private func requireCurrent(')])
production += '\n@MainActor final class ActualRunnerScopeGuard {\n'+scope+r"""
    func frozen(context:PropertyVideoJobContext,work:ReelWorkJob,model:AppModel)->()throws->Void{
        let watch=Watch(work:work,model:model,api:ClosedJobsAPI(),context:context,operationID:UUID(),revision:AuthStore.shared.syncSessionRevision,consentRevision:AIConsent.shared.revocationRevision)
        watches[work.id]=watch
        return {try self.requireCurrent(watch)}
    }
}
"""
schedule=block(runner_source,'private func schedule(')
preface=schedule[:schedule.index('        tasks[watch.work.id] = Task')]
production += '\n@MainActor final class ActualFirstEnqueueSerialization {\n'+scope+'\n'+declaration(runner_source, 'private var taskIDs:')+r"""
var requests=0;var tasks:[UUID:Int]=[:]
"""+preface+r"""
 requests+=1;tasks[watch.work.id]=1
}
func schedule(work:ReelWorkJob,model:AppModel){
    guard let saved=work.serverJob else { return }
    let watch=Watch(work:work,model:model,api:ClosedJobsAPI(),context:saved.context,operationID:saved.request.operationID,
        revision:AuthStore.shared.syncSessionRevision,consentRevision:AIConsent.shared.revocationRevision)
    watches[work.id]=watch
    schedule(watch)
}
}
"""
view = (ROOT / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift').read_text()
intercept = view[view.index('if !isSample, extras.isEmpty, let prepared = batch'):view.index('                for (i, photo) in ordered.enumerated()', view.index('if !isSample, extras.isEmpty, let prepared = batch'))]
assert intercept.index('PropertyVideoJobStore.start(') < intercept.index('PropertyVideoJobRunner.shared.enqueue(') < intercept.index('return // No native provider polling')
assert 'PropertyVideoNarrationUpload.upload(' in intercept and 'music: frozenMusic' in intercept
assert 'photoProvenanceID: photo.photoProvenanceID' in intercept
assert 'if work.serverJob != nil { serverVideoAttentionSection }' in view
network = (ROOT / 'apps/ios/Rendprop/Networking/PropertyVideoJobsAPI.swift').read_text()
assert 'property-video:' in network and 'property-video-jobs-v1' in network
assert 'status == 402, code == "capacity_refused"' in network and 'PropertyVideoOperationLookup.self' in network
assert 'request.operationID.uuidString.lowercased()' in network and 'case .accepted(let job): return job' in network
assert 'if saved.wasRefusedBeforeAdmission' in runner_source and 'rejected.capacityRefusal = refusal' in runner_source
assert 'previous.mayResume' in network and 'action: "resume"' in network
resume = block(runner_source, 'func resume(_ work: ReelWorkJob)')
assert 'resuming.insert(work.id).inserted' in resume and 'saved.reply?.mayResume == true' in resume
assert resume.index('resuming.insert(work.id).inserted') < resume.index('PropertyVideoJobStore.load(') < resume.index('saved.reply?.mayResume == true') < resume.index('watch.api.resumePropertyVideoJob(saved)')
assert resume.index('guard saved.stopRequested != true else') < resume.index('watch.api.resumePropertyVideoJob(saved)')
assert 'work.serverJob?.reply?.mayResume == true' in view and 'video.server.resume' in view

download = network[network.index('static func download('):]
assert 'Authorization' not in download and 'apikey' not in download
controls = [
    ('actual', production, None),
    ('lost-operation-closure-proof', production.replace('guard lookup.operationClosed else', 'guard true else'), 'plain unknown operation cannot unlock a new paid recipe'),
    ('lost-capacity-status-fence', production.replace('guard status == 402 && code == "capacity_refused" else', 'guard true else'), '403/409/unknown replies never unlock new paid work'),
    ('lost-capacity-operation-fence', production.replace('lookup.operationID == request.operationID', 'true'), "a different operation's refusal cannot unlock this recipe"),
    ('initial-enqueue-overlap', production.replace('watch.work.running && watch.work.serverJob?.reply == nil', 'false'), 'reopen cannot race the still-running first enqueue with another POST'),
    ('lost-admission-monotonicity', production.replace('if existing.reply != nil { guard saved.reply != nil, saved.capacityRefusal == nil else { throw Failure.invalidReceipt } }', ''), 'an accepted job cannot be erased by a late pre-acknowledgment writer'),
    ('lost-refusal-monotonicity', production.replace('if existing.wasRefusedBeforeAdmission { guard saved.reply == nil, saved.capacityRefusal == existing.capacityRefusal else { throw Failure.invalidReceipt } }', ''), 'a closed refusal cannot be reopened by a late accepted writer'),
    ('lost-resume-state-boundary', production.replace('resumeAvailable != true || state == "failed",', 'true,'), 'only a failed saved job may advertise capacity resume'),
    ('lost-resume-explicit-proof', production.replace('var mayResume: Bool { state == "failed" && resumeAvailable == true }', 'var mayResume: Bool { state == "failed" }'), 'an ordinary or uncertain failure never enables paid resume'),
    ('lost-session-revision', production.replace('AuthStore.shared.syncSessionRevision == watch.revision','true'), 'an old session revision must stop the actual job status/download guard'),
    ('lost-consent-revision', production.replace('AIConsent.shared.revocationRevision == watch.consentRevision','true'), 'revoked AI consent revision must stop the actual job status/download guard'),
    ('lost-watch-operation-fence', production.replace('watches[watch.work.id]?.operationID == watch.operationID', 'true'), 'a replaced operation must stop the old status/download guard'),
    ('lost-library-fence', production.replace('selectedLibraryOrgID == request.expectedOrgID, sourceCount == request.sources.count', 'true, sourceCount == request.sources.count'), 'foreign logical library must refuse'),
    ('lost-manifest-identity', production.replace('previous!.manifestSHA256 == manifestSHA256', 'true'), 'same operation cannot switch its normalized manifest'),
    ('lost-ordered-source-identity', production.replace('source.photoVersionID == frozen.photoVersionID', 'true').replace('source.photoAssetID.flatMap(UUID.init(uuidString:)) == frozen.photoAssetID', 'true').replace('source.photoProvenanceID.flatMap(UUID.init(uuidString:)) == frozen.photoProvenanceID', 'true'), 'ready output cannot silently substitute or reorder'),
    ('lost-resolution-floor', production.replace('width >= size.0, height >= size.1', 'true'), '720p result cannot satisfy listing master'),
    ('lost-private-capability-redaction', production.replace('result.downloadURL = nil;', ''), 'durable receipt never retains a signed download capability'),
    ('lost-uncertain-enqueue-fence', production.replace('guard existing.mayReplaceAfterResolution else', 'guard true else'), 'uncertain enqueue must block a fresh paid operation'),
]
receipt = {'passed': False, 'sourceHashes': before, 'runs': [], 'limitations': ['Actual Foundation receipt checking, frozen100-photo source/version/order, hashing and atomicfilesystem storage. Network/provider/AVFoundation/UI are closed boundaries. No phone or paid generation performed by this proof.']}
for name, source, expected in controls:
    directory = out / name; directory.mkdir(exist_ok=True)
    actual = directory / 'Production.swift'; actual.write_text(source)
    binary = directory / 'checks'
    build = subprocess.run(['xcrun','swiftc','-parse-as-library',str(actual),str(fixture),'-o',str(binary)], capture_output=True, text=True)
    (directory/'build.log').write_text(build.stdout + build.stderr)
    if build.returncode: raise SystemExit(build.stderr)
    run = subprocess.run([str(binary)], capture_output=True, text=True)
    (directory/'run.log').write_text(run.stdout + run.stderr)
    passed = run.returncode == 0 if expected is None else run.returncode != 0 and expected in run.stderr
    receipt['runs'].append({'name':name,'exit':run.returncode,'passed':passed,'expectedRejection':expected,'stdout':run.stdout.strip()})
    if not passed:
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n'); raise SystemExit(f'{name} did not prove its boundary')
receipt['sourceHashesAtEnd'] = hashes(); receipt['passed'] = receipt['sourceHashesAtEnd'] == before
receipt['compiledNegativeControls'] = len(controls)-1
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'passed':receipt['passed'],'compiledNegativeControls':len(controls)-1,'receipt':str(out/'receipt.json')}))
