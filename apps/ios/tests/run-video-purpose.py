#!/usr/bin/env python3
"""Actual purpose getter, frozen work snapshot and saved-aspect recovery bodies.
No UI, account, provider, media or Apple calls; navigation/voice interfaces closed.
"""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);a=p.parse_args()
out=(a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-video-purpose-'))).resolve();out.mkdir(parents=True,exist_ok=True)
paths=[ROOT/'apps/ios/Rendprop/Render/VideoAspectChoice.swift',ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift',ROOT/'apps/ios/Rendprop/Render/ReelWorkQueue.swift',Path(__file__).resolve(),ROOT/'apps/ios/Rendprop/Models/ListingVideo.swift',ROOT/'apps/ios/Rendprop/Networking/NativeReelDraft.swift']
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before=hashes();helper,source,queue=[x.read_text() for x in paths[:3]]
def block(text,anchor):
 start=text.index(anchor)
 begin=text.index('{',text.index(') async throws -> URL {',start)) if 'makeClip(' in anchor else text.index('{',start)
 depth=1;end=begin+1
 while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
helper += '\n' + block(paths[4].read_text(),'enum VideoBrandingPolicy {')
helper += '\n' + block(paths[5].read_text(),'struct NativeReelPlanningSetup:')
assert 'let planning = draft.planningSetup' in source and 'bigCaptionsOn = planning.pictureLabels' in source
assert 'cameraMove = planning.motionPreset.flatMap' in source and 'planning.notice.map' in source
view=block(source,'struct ReelStudioView:')
assert 'if videoPurpose == nil' in block(view,'@ViewBuilder private var setupSection:')
assert 'videoPurposeChooser' in block(view,'@ViewBuilder private var setupSection:')
assert 'videoPurpose = choice' in block(view,'private var videoPurposeChooser:')
assert 'Picker("Shape"' not in view
assert 'portrait = draft.portrait' in block(view,'@MainActor private func syncNativeSetup(')
assert 'portrait: portrait' in block(view,'@MainActor private func syncNativeSetup(')
gen=block(view,'private func generateWithSession()')
for token in ['let isPortrait = portrait','aspect: isPortrait ? "9:16" : "16:9"','let renderSize = isPortrait ? CGSize(width: 1080, height: 1920)',': CGSize(width: 1920, height: 1080)','PropertyVideoPlanner.plan(','for photo in chosen','await Task.yield()']:
 assert token in gen,token
assert 'preparedJPEG: batch.flatMap { Data(base64Encoded: $0.photos[i].jpegBase64) }' in gen
assert 'framing: batch?.framing' in gen
assert 'prefix(' not in gen,'Large photo recipes cannot silently truncate selected sources'
continued=block(view,'private func continueSavedBatch(')
assert 'renderSize: batch.aspect == "9:16" ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)' in continued
for token in ['aspect: aspect, framing: framing, presetVersion: 1,','sourceSpaceType: spaceType, qualityAttempt: attempt, framing: framing, outputAspect: aspect']:
 assert token in block(view,'nonisolated private static func makeClip('),token
parts='\n'.join(block(view,x) for x in ['private var portrait:', 'private func restoreVideoPurposeForSavedWork()', 'private func snapshotReelConfiguration()', 'nonisolated private static func parkedReelSettings('])
config=block(queue,'struct Configuration {')
interfaces=r'''
import Foundation
func check(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { FileHandle.standardError.write(Data(("FAIL: "+message+"\n").utf8));exit(1) } }
func sized(_ value:CGSize,_ width:Double,_ height:Double)->Bool {value.width==width && value.height==height}
@propertyWrapper struct FixtureState<Value> { final class Box {var value:Value;init(_ v:Value){value=v}};let box:Box;init(wrappedValue:Value){box=Box(wrappedValue)};var wrappedValue:Value{get{box.value}nonmutating set{box.value=newValue}} }
struct ReelTitleCard {}
struct Voiceover {}
enum CaptionStyle {case standard,off}
enum ReelComposer {enum ShotCaptionStyle {case lowerThird,off};enum Transition {case cut}}
enum ReelWorkJob {
'''+config+r'''
}
final class ClosedWork {var configuration:ReelWorkJob.Configuration?}
struct ClosedBatch {var aspect:String}
struct ClosedRequest {var outputAspect:String?}
struct VideoFixture {
 @FixtureState var videoPurpose:VideoAspectChoice?=nil
 var selectedExtras:[URL]=[];var captionsOn=false;var listing="fixture";var voiceMode=VoiceMode.off;var voiceover:Voiceover?;var wordCaptionsOn=false;var bigCaptionsOn=false;var bigCaptionStyle=ReelComposer.ShotCaptionStyle.lowerThird;var reelTransition=ReelComposer.Transition.cut
 enum VoiceMode {case off,on}
 var pendingBatch:ClosedBatch?;var pendingRequest:ClosedRequest?;var parkedClips:Bool?;var isWorking=false
 let work=ClosedWork()
 static func reelCaptions(for listing:String)->ReelTitleCard{ReelTitleCard()}
'''+parts+r'''
 func frozen()->ReelWorkJob.Configuration {snapshotReelConfiguration()}
 func restore(){restoreVideoPurposeForSavedWork()}
 var isPortrait:Bool {portrait}
 func setLegacyPortrait(_ value:Bool){portrait=value}
 static func parked(_ configuration:ReelWorkJob.Configuration?,_ aspect:String?,_ fallback:ReelWorkJob.Configuration)->CGSize{parkedReelSettings(configuration:configuration,batchAspect:aspect,fallback:fallback).renderSize}
}
@main struct PurposeTests {
 static func main() {
  let migrated=NativeReelPlanningSetup(automaticOrder:nil,motionPreset:"fly_through",pictureLabels:true)
  check(migrated.automaticOrder && migrated.motionPreset==nil && !migrated.pictureLabels && migrated.notice != nil,"legacy setup loads automatic per-photo motion with labels off and a visible notice")
  let explicit=NativeReelPlanningSetup(automaticOrder:true,motionPreset:"fly_through",pictureLabels:true)
  check(explicit.automaticOrder && explicit.motionPreset=="fly_through" && explicit.pictureLabels && explicit.notice==nil,"new setup retains explicit global motion and picture label choices")
  let manual=NativeReelPlanningSetup(automaticOrder:false,motionPreset:nil,pictureLabels:false)
  check(!manual.automaticOrder && manual.motionPreset==nil && !manual.pictureLabels,"new setup retains deliberate original photo order")
  let fresh=VideoFixture();check(fresh.videoPurpose==nil,"fresh video creation asks for a purpose");check(fresh.isPortrait,"legacy default is portrait")
  var social=VideoFixture();social.videoPurpose = .socialMedia;social.captionsOn=true
  var listing=VideoFixture();listing.videoPurpose = .listing;listing.captionsOn=true
  check(social.isPortrait && !listing.isPortrait,"purpose selects the actual studio orientation")
  check(social.frozen().captions != nil && listing.frozen().captions == nil,"frozen listing master omits the social title and Rendprop mark")
  var silent=VideoFixture();silent.videoPurpose = .listing;silent.wordCaptionsOn=true
  check(silent.frozen().voice==nil && silent.frozen().captionStyle == .off && silent.frozen().shotStyle == .off,"voice-off default has no spoken captions or picture labels")
  silent.voiceMode = .on;silent.voiceover=Voiceover()
  check(silent.frozen().voice != nil && silent.frozen().captionStyle == .standard,"optional spoken captions activate with chosen narration")
  check(social.frozen().aspect=="9:16" && listing.frozen().aspect=="16:9","chosen purpose survives actual frozen generation settings")
  check(VideoAspectChoice.socialMedia.width==1080 && VideoAspectChoice.socialMedia.height==1920 && VideoAspectChoice.listing.width==1920 && VideoAspectChoice.listing.height==1080,"both purposes are real 1080p delivery canvases")
  check(sized(VideoFixture.parked(social.frozen(),"16:9",social.frozen()),1920,1080),"saved batch canvas outranks current UI settings")
  check(sized(VideoFixture.parked(listing.frozen(),nil,social.frozen()),1920,1080),"saved work canvas survives reopen and export")
  check(sized(VideoFixture.parked(nil,nil,fresh.frozen()),1080,1920),"legacy parked video remains portrait")
  var recovered=VideoFixture();recovered.pendingBatch = .init(aspect:"16:9");recovered.pendingRequest = .init(outputAspect:"9:16");recovered.work.configuration=social.frozen();recovered.restore()
  check(recovered.videoPurpose == .listing,"saved batch purpose outranks request and current work")
  var old=VideoFixture();old.pendingRequest = .init(outputAspect:nil);old.restore();check(old.videoPurpose == .socialMedia,"legacy accepted request reopens without asking to replace it")
  let reopened=VideoFixture();reopened.work.configuration=listing.frozen();reopened.restore();check(reopened.videoPurpose == .listing,"live background work retains its chosen purpose")
  fresh.setLegacyPortrait(false);check(fresh.videoPurpose == .listing,"loading a saved landscape draft restores listing purpose")
  for n in [9,12,50,100] {check(VideoSelectionCapacity.canCreate(photoCount:n,totalCount:n),"larger listings are admitted without an eight-photo cap")}
  check(!VideoSelectionCapacity.canCreate(photoCount:101,totalCount:101),"explicit photo engineering bound refuses without dropping a prefix")
  check(VideoSelectionCapacity.canCreate(photoCount:100,totalCount:101),"one opening clip remains available with a hundred photos")
  print("PASS: actual purpose/orientation/frozen settings/recovery; both 1080p canvases; legacy default; 9–100 photo selection")
 }
}
'''
actual=helper+interfaces
variants=[('actual',actual,None),
 ('wrong-purpose-orientation',actual.replace('get { videoPurpose?.portrait ?? true }','get { true }'),'purpose selects the actual studio orientation'),
 ('lost-snapshot-aspect',actual.replace('            aspect: portrait ? "9:16" : "16:9")','            aspect: nil)'),'chosen purpose survives actual frozen generation settings'),
 ('lost-batch-shape',actual.replace('let aspect = batchAspect ?? settings.aspect ?? fallback.aspect','let aspect = settings.aspect ?? fallback.aspect'),'saved batch canvas outranks current UI settings'),
 ('lost-purpose-recovery',actual.replace('let savedAspect = pendingBatch?.aspect ?? pendingRequest?.outputAspect ?? work.configuration?.aspect','let savedAspect = pendingRequest?.outputAspect ?? work.configuration?.aspect'),'saved batch purpose outranks request and current work'),
 ('restored-eight-photo-cap',actual.replace('static let maximumPhotos = 100','static let maximumPhotos = 8'),'larger listings are admitted without an eight-photo cap'),
 ('listing-brand-leak',actual.replace('aspect == "9:16" ? requested : nil','requested'),'frozen listing master omits the social title and Rendprop mark'),
 ('lost-legacy-setup-migration',actual.replace('self.motionPreset = nil\n            self.pictureLabels = false','self.motionPreset = motionPreset\n            self.pictureLabels = pictureLabels'),'legacy setup loads automatic per-photo motion with labels off and a visible notice')]
runs=[]
for label,code,expected in variants:
 swift=out/(label+'.swift');binary=out/label;swift.write_text(code)
 c=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(binary)],capture_output=True,text=True)
 (out/(label+'-compile.log')).write_text(c.stdout+c.stderr);assert c.returncode==0,(label,c.stderr)
 r=subprocess.run([str(binary)],capture_output=True,text=True);(out/(label+'.log')).write_text(r.stdout+r.stderr)
 assert r.returncode==(1 if expected else 0),(label,r.stdout,r.stderr)
 if expected:assert 'FAIL: '+expected in r.stderr,(label,r.stderr)
 runs.append({'name':label,'exit':r.returncode,'expectedRejection':expected,'sourceSHA256':hashlib.sha256(swift.read_bytes()).hexdigest()})
after=hashes();assert before==after,'Source changed during purpose proof'
receipt={'passed':True,'sourceHashes':before,'sourceHashesAtEnd':after,'runs':runs,'compiledNegativeControls':7,'actualBodySHA256':hashlib.sha256(parts.encode()).hexdigest(),'limitations':['Actual studio orientation getter, frozen configuration and parked settings/restore bodies execute with closed voice/queue interfaces. Generation batch/wire/render consumers are source-bound here and have separate actual recovery/encoding gates. No UI, customer, provider or Apple call.']}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'passed':True,'compiledNegativeControls':7,'receipt':str(out/'receipt.json')}))
