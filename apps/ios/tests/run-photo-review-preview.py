#!/usr/bin/env python3
"""Actual local-only video resolver and photo-review decode fences, without UI."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, tempfile
root = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', type=Path); args=p.parse_args()
out=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-review-')); out.mkdir(parents=True,exist_ok=True)
paths=[root/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift',root/'apps/ios/Rendprop/Screens/QuickStartVideo.swift',root/'apps/ios/Rendprop/Screens/RenderStatusView.swift',root/'apps/ios/tests/PhotoReviewPreviewTests.swift',Path(__file__).resolve()]
hashes=lambda:{str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before=hashes(); fly, video, account=[x.read_text() for x in paths[:3]]
def block(text,anchor):
    assert text.count(anchor)==1,anchor
    start=text.index(anchor); pos=text.index('{',start); depth=1; end=pos+1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}'); end+=1
    return text[start:end]
review=block(fly,'struct PhotoCompareView: View {')
full=block(fly,'private struct PhotoFullSizeComparison: View {')
# These are wiring checks, not a SwiftUI render or an approval-policy proof.
for text in ['.frame(height: PhotoReviewLayout.previewHeight(', 'imageSize: (showOriginal ? original : enhanced)?.size', 'availableWidth: max(0, min(760, geometry.size.width) - 32)', 'viewportHeight: geometry.size.height)', 'photoVersion.reviewControls','photoVersion.fullSize','.onChange(of: auth.userID)', '.onChange(of: auth.syncSessionRevision)', '.rendpropWorkspaceChanged']:
    assert text in review,text
for forbidden in ['selectForPublication','confirmCustomReview','PhotoExportSheet','setMainPhoto','stagingReview','customReview']:
    assert forbidden not in full,forbidden
for text in ['guard !needsStagingReview || stagingReview.isComplete','guard !needsCustomReview || customReview.isComplete','try PhotoVersionHistory.selectForPublication','try PhotoVersionHistory.confirmCustomReview']:
    assert text in review,text
for text in ['!versionChoices.contains(where: isRetainedSource)', 'selected: showOriginal ? isRetainedSource(version) : choiceTitle(viewed) == choiceTitle(version)']:
    assert text in review,'Saved source selection must follow the displayed source: '+text
signin=block(account,'struct SignInView: View {')
assert re.search(r'if requiresAccount\s*\{\s*Button\s*\{\s*showQuickStart = true\s*\}', signin)
assert 'QuickStartVideoView()' in signin and 'if !requiresAccount {' in signin and '.interactiveDismissDisabled(requiresAccount || isExchanging)' in signin
for forbidden in ['URLSession','APIClient','AuthStore','AIConsent','requestAuthorization','requestWhenInUseAuthorization']:
    assert forbidden not in video,forbidden
assert 'VideoPlayer(player: player)' in video and 'Read the video transcript' in video
assert 'Skip checks and return to sign-in' in video and 'Try 3 quick checks (optional)' in video
assert 'answers' not in signin
assert 'if phase != .active { stopPlayback() }' in video and '.onDisappear { playbackOpen = false; stopPlayback(); player = nil }' in video
assert 'if scenePhase == .active, enableAudio(for: localPlayer) { localPlayer.play() }' in video
assert 'guard playbackOpen, scenePhase == .active else { stopPlayback(); return }' in video
assert '.onReceive(player.publisher(for: \\.timeControlStatus))' in video
actual=block(fly,'@MainActor private struct NativeMediaExportContext {').replace('private struct','struct',1)+'\n'+block(video,'enum QuickStartVideoAsset {').replace('Bundle','ControlledBundle')+'\n'+block(video,'struct QuickStartKnowledgeCheck: Identifiable {')+'\n'
actual+=block(video,'@MainActor private final class QuickStartPlaybackAudio {').replace('private final class','final class',1)+'\n'
playback_methods='\n'.join(block(video,x).replace('private func','func',1) for x in ['@discardableResult private func enableAudio(','private func stopPlayback()'])
actual+='''@MainActor final class QuickStartPlaybackHarness {
var player: AVPlayer? = AVPlayer()
var playbackAudio = QuickStartPlaybackAudio()
var audioError: String?
'''+playback_methods+'\n}\n'
task=block(review,'.task(id: viewed.id) {'); task=task[task.index('{'):]
change=block(review,'.onChange(of: showOriginal) {'); change=change[change.index('{'):].replace('{ showing in','{',1)
methods='\n'.join(block(review,x).replace('private func','func',1) for x in ['private func clearAndDismiss()','private func chooseVersion(','private func isRetainedSource('])
actual+='''// The decode/privacy fixture takes the local branch. Cloud selection has
// separate actual-source gates; this closed read boundary only supplies the
// new view dependency and never performs a request or changes a selection.
@MainActor final class PhotoReviewCloudReadBoundary {
func refreshCloudPhotoSelection(listingID: UUID) async throws {}
}
@MainActor final class PhotoReviewHarness {
let photo=EnhancedPhoto(id:"photo",enhancedURL:URL(fileURLWithPath:"/local/edited.jpg"),originalURL:URL(fileURLWithPath:"/local/original.jpg"))
let model=PhotoReviewCloudReadBoundary()
var isCloudListing=false;var photoListingID:UUID?;var selectionError:String?
var selectedVersion: EnhancedPhoto?; var viewed: EnhancedPhoto { selectedVersion ?? photo }
var enhanced:UIImage?;var original:UIImage?;var imageLoadComplete=false;var selectedForListing=false
var selectionWorkID:UUID?
var stagingReview=PhotoVersionHistory.StagingReview();var customReview=PhotoVersionHistory.CustomReview()
var showOriginal=false;var showFullComparison=false;var showAccessibilityFeedback=false;var exporting:Bool?;var imageContext:NativeMediaExportContext?;var dismissCount=0
func dismiss(){dismissCount+=1}
// Single-photo edit cleanup has its own actual-source executable controls.
func clearSinglePhotoEdit() {}
func loadImages() async '''+task+'\nfunc sourceChanged(_ showing:Bool) '+change+'\n'+methods+'\n}\n'
fixture=paths[3].read_text()
variants=[('actual',actual,None),
 ('negative-video-remote',actual.replace('url.isFileURL','true'), 'preauth playback cannot accept a remote video URL'),
 ('negative-owner',actual.replace('AuthStore.shared.userID == owner','true'),'owner change during decode rejects the stale completed preview'),
 ('negative-revision',actual.replace('AuthStore.shared.syncSessionRevision == revision','true'),'revision change during decode rejects the stale completed preview'),
 ('negative-workspace',actual.replace('WorkspaceContext.selectedOrgID == workspace','true'),'workspace change during decode rejects the stale completed preview'),
 ('negative-photo',actual.replace('viewed.id == target.id','true'),'photo change during decode rejects the stale completed preview'),
 ('negative-late-decode',actual.replace('guard context.isCurrent, viewed.id == target.id else { return }','guard true else { return }'),'owner change during decode rejects the stale completed preview'),
 ('negative-dismissed-fullsize',actual.replace('        showFullComparison = false\n        exporting = nil','        exporting = nil'),'dismissal clears enlarged preview and export context'),
 ('negative-dismissed-feedback',actual.replace('        showAccessibilityFeedback = false','        // feedback sheet cleanup omitted'),'dismissal closes optional feedback before clearing the photo'),
 ('negative-stale-version',actual.replace('        imageContext = nil\n        enhanced = nil\n        original = nil\n        imageLoadComplete = false','        imageLoadComplete = false'),'version switch clears prior preview before the next decode'),
 ('negative-same-version',actual.replace('        if version.id == viewed.id {\n            showOriginal = false\n            return\n        }\n',''),'choosing the current version preserves loaded pixels because the decode task ID is unchanged'),
 ('negative-same-version-original',actual.replace('        if version.id == viewed.id {\n            showOriginal = false','        if version.id == viewed.id {\n            // lost source toggle'),'choosing the current edited chip switches back from Original without reloading'),
 ('negative-source-label-only',actual.replace('return version.enhancedURL.standardizedFileURL == viewed.originalURL.standardizedFileURL','return true'),'an Original or Earlier source label cannot select a different retained file'),
 ('negative-edited-source',actual.replace('        guard let saved = version.savedVersion,\n              saved.parentID == nil, saved.imageFile == saved.originalFile else { return false }\n',''),'an edited descendant cannot impersonate the saved source chip'),
 ('negative-source-normalization',actual.replace('version.enhancedURL.standardizedFileURL == viewed.originalURL.standardizedFileURL','version.enhancedURL == viewed.originalURL'),'equivalent retained file paths keep their exact normalized source identity'),
 ('negative-audio-category',actual.replace('try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])','try session.setCategory(.ambient, mode: .moviePlayback, options: [.mixWithOthers])'),'explicit introduction playback uses movie audio that is not silenced by the ringer category'),
 ('negative-audio-restore',actual.replace('try? session.setCategory(saved.category, mode: saved.mode, options: saved.options)','// omitted prior configuration restoration'),'audio cleanup restores the exact prior category mode and options'),
 ('negative-audio-deactivate',actual.replace('try? session.setActive(false, options: .notifyOthersOnDeactivation)','// omitted deactivation'),'audio cleanup deactivates with notifyOthersOnDeactivation'),
 ('negative-audio-owner',actual.replace('guard ownsConfiguration else { return }','guard true else { return }'),'category takeover by another audio activity prevents stale restoration or deactivation'),
 ('negative-audio-mode',actual.replace('session.mode == .moviePlayback','true'),'mode takeover by another audio activity prevents stale restoration or deactivation'),
 ('negative-audio-options',actual.replace('session.categoryOptions == [.mixWithOthers]','true'),'options takeover by another audio activity prevents stale restoration or deactivation'),
 ('negative-audio-reactivate',actual.replace('guard ownsConfiguration else {\n                previous = nil','guard true else {\n                previous = nil'),'changed audio owner must throw'),
 ('negative-audio-view-cleanup',actual.replace('        playbackAudio.restore()','        // audio cleanup omitted'),'view background or dismissal pauses playback before releasing its audio scope')]
results=[]
for name,source,reason in variants:
    assert reason is None or source!=actual,name
    swift=out/(name+'.swift'); swift.write_text('import Foundation\n'+source+'\n'+fixture.replace('import Foundation','',1)); binary=out/name
    build=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(binary)],capture_output=True,text=True,timeout=90)
    (out/(name+'-compile.log')).write_text(build.stdout+build.stderr)
    assert build.returncode==0,name+' compile failed: '+build.stderr
    run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30); log=run.stdout+run.stderr
    (out/(name+'-run.log')).write_text(log)
    okay=(run.returncode==0 and 'PASS ' in log) if reason is None else run.returncode!=0 and reason in log
    results.append({'name':name,'compile_exit':build.returncode,'runtime_exit':run.returncode,'passed':okay,'expected_failure':reason})
    assert okay,name+' failed classification: '+log
    print(name+': PASS')
receipt={'passed':True,'assertions':int(re.search(r'PASS (\d+)',(out/'actual-run.log').read_text())[1]),'negative_controls':len(variants)-1,'source_binding':hashes()==before,'source_hashes':before,'actual_extraction_sha256':hashlib.sha256(actual.encode()).hexdigest(),'source_wiring_checks':['aspect-fit preview helper wiring and scrolling controls','read-only full-screen inspection','account/revision/workspace dismissal','unchanged staging/custom approval actions','same-version selection preserves loaded images','preauth required-only video entry','local-only video and transcript','scoped playback activation and prior audio restoration','playback pause on background and dismissal'],'scope':'Actual local resource resolver, photo decode/context/select/clear, and scoped audio activation/restoration plus view enable/stop bodies; resource lookup, OS AVAudioSession/AVPlayer, UIImage/decoder/history and presentation are closed. Actual bundled video metadata/inclusion verified separately. No UIKit rendering, physical Silent Mode observation or persisted approval-policy proof.','results':results}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n'); assert receipt['source_binding']; print(json.dumps({'passed':True,'assertions':receipt['assertions'],'negative_controls':receipt['negative_controls'],'receipt':str(out/'receipt.json')}))
