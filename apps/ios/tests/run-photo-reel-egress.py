#!/usr/bin/env python3
"""Actual filesystem review policy and extracted saved-reel settings, with classified controls."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(); parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args(); out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='photo-reel-egress-'))
out.mkdir(parents=True, exist_ok=True)
view = root/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
history = root/'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift'
queue = root/'apps/ios/Rendprop/Render/ReelWorkQueue.swift'
fixture = root/'apps/ios/tests/PhotoReelEgressTests.swift'

def block(text, anchor):
    start=text.index(anchor); opening=text.index('{', start); depth=1; p=opening+1
    while depth:
        depth += (text[p]=='{')-(text[p]=='}'); p += 1
    return text[start:p]

v=view.read_text().split('struct ReelStudioView: View {', 1)[1]; h=history.read_text()
settings=block(v, '    nonisolated private static func parkedReelSettings(').replace('nonisolated private static', 'static')
configuration=block(queue.read_text(), '    struct Configuration {')
closed='''import Foundation
 typealias ReelTitleCard = String
 typealias Voiceover = String
 enum CaptionStyle { case off, standard }
 enum ReelComposer { enum ShotCaptionStyle { case off, highlightBox }; enum Transition { case cut, whip } }
 enum ReelWorkJob { CONFIG }
 enum ReelDecision { SETTINGS }
'''.replace('CONFIG', configuration).replace('SETTINGS', settings)
source_gates={
 'grid refuses unreviewed sources': '.disabled(!reviewed)' in block(v,'    private func selectThumb('),
 'selection checks review before append': block(v,'    private func toggle(').index('requireReelReview') < block(v,'    private func toggle(').index('selected.append'),
 'generation checks before any API snapshot': block(v,'    private func generateWithSession(').index('requireReelReview') < block(v,'    private func generateWithSession(').index('let api ='),
 'JPEG preparation checks actual persisted source': block(v,'    nonisolated private static func preparedReelJPEG(').index('requireReelReview') < block(v,'    nonisolated private static func preparedReelJPEG(').index('UIImage('),
 'remaining batch checks before dispatch loop': block(v,'    nonisolated private static func completeSavedBatch(').index('requireSavedReelReview') < block(v,'    nonisolated private static func completeSavedBatch(').index('while batch.'),
 'parked composition checks before compositor': block(v,'    private func finishParkedReel(').index('requireSavedReelReview') < block(v,'    private func finishParkedReel(').index('ReelComposer.compose'),
 'parked composition consumes saved size and options': all(s in block(v,'    private func finishParkedReel(') for s in ['settings.renderSize','configuration.extras','configuration.captions','configuration.voice','configuration.captionStyle','configuration.shotStyle','configuration.transition']),
 'retry checks history before new intent': block(v,'    nonisolated private static func resolveSavedQualityRetry(').index('requireSavedReelReview') < block(v,'    nonisolated private static func resolveSavedQualityRetry(').index('PendingReelRequest('),
 'recovery checks without clearing paid receipt': 'requireSavedReelReview' in block(v,'    private func recoverPendingRequest('),
}
assert all(source_gates.values()), source_gates
consumed=[view,history,queue,fixture,Path(__file__).resolve(),root/'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift']
receipt={'passed':False,'source_gates':source_gates,'source_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed},'runs':[], 'limitations':['Filesystem policy and saved-settings decision executed from production source. UIKit, SwiftUI and media fields are closed doubles; no app, provider, Photos or network calls. UI route enforcement is source-bound, not a UI-test result. Unknown legacy history does not grant or invent approval.']}
variants={
 'actual':(h,closed,None),
 'remove-custom-review':(h.replace('if version.needsCustomReview { throw Failure.customReviewRequired }','/* custom review removed */'),closed,'saved custom source remains held before reel continuation'),
 'remove-staging-review':(h.replace('if version.needsStagingReview { throw Failure.reviewRequired }','/* stage review removed */'),closed,'saved staging source remains held before reel composition'),
 'replace-saved-configuration':(h,closed.replace('let settings = configuration ?? fallback','let settings = fallback'),'parked reel keeps saved extras title voice and caption transition choices'),
 'replace-saved-aspect':(h,closed.replace('batchAspect ?? settings.aspect ?? fallback.aspect','fallback.aspect'),'parked reel keeps saved wide shape despite reopened tall setup'),
}
try:
 for name,(policy,decision,expected) in variants.items():
    directory=out/name; directory.mkdir(exist_ok=True)
    policy_path=directory/'PhotoVersionHistory.swift'; policy_path.write_text(policy)
    decision_path=directory/'ReelDecision.swift'; decision_path.write_text(decision)
    executable=directory/'check'
    command=['xcrun','swiftc','-parse-as-library',str(root/'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift'),str(policy_path),str(decision_path),str(fixture),'-o',str(executable)]
    compile_run=subprocess.run(command,capture_output=True,text=True,timeout=120)
    (directory/'compile.log').write_text(compile_run.stdout+compile_run.stderr)
    assert compile_run.returncode==0, f'{name} compile failure, not a valid control: {compile_run.stderr}'
    run=subprocess.run([str(executable)],capture_output=True,text=True,timeout=30)
    log=run.stdout+run.stderr; (directory/'run.log').write_text(log)
    passed=(run.returncode==0 and 'Photo reel egress: 10 passed' in log) if expected is None else run.returncode!=0 and expected in log
    receipt['runs'].append({'name':name,'compile_exit':compile_run.returncode,'runtime_exit':run.returncode,'expected_failure':expected,'passed':passed})
    assert passed,f'{name}: {log}'
 receipt['source_binding_matches']=all(hashlib.sha256(p.read_bytes()).hexdigest()==receipt['source_sha256'][str(p.relative_to(root))] for p in consumed)
 receipt['passed']=receipt['source_binding_matches']
finally:
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'passed':receipt['passed'],'actual_assertions':10,'compiled_controls':4,'source_gates':len(source_gates),'receipt':str(out/'receipt.json')}))
