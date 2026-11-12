#!/usr/bin/env python3
"""Actual queue/layout policy plus source-bound unchanged review/privacy actions.
Headless host execution/SDK-independent; no simulator/phone/provider control.
"""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path);a=p.parse_args();OUT=a.output or Path(tempfile.mkdtemp(prefix='rendprop-photo-review80-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
paths={'detail':ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift','queue':ROOT/'apps/ios/Rendprop/Photos/PhotoWorkQueue.swift','service':ROOT/'apps/ios/Rendprop/Photos/PhotoEditService.swift','test':ROOT/'tests/phase1/PhotoWorkProgressTests.swift','theme':ROOT/'apps/ios/Rendprop/DesignSystem/Theme.swift','banner':ROOT/'apps/ios/Rendprop/Photos/PhotoWorkBanner.swift','components':ROOT/'apps/ios/Rendprop/DesignSystem/Components.swift'}
sources={k:q.read_text()for k,q in paths.items()}
def block(s,needle):
 start=s.index(needle);op=s.index('{',start);i=op+1;n=1
 while n:
  if s[i]=='{':n+=1
  elif s[i]=='}':n-=1
  i+=1
 return s[start:i]
def compact(s):return re.sub(r'\s+','',s)
def review_action(s,needle):
 view=block(s,'struct PhotoCompareView: View {')
 if needle=='try PhotoVersionHistory.selectForPublication':return block(view,'private func changeListingSelection()')
 save=block(view,'private var savePhotoButton: some View {');start=save.index('{',save.index('SecondaryButton('));return block(save[start:],'{')
# The last approved implementation is immutable Git data, not a second model
# of the gates. Preserve the exact source/hash/custom-review action bodies.
base=subprocess.check_output(['git','show','d643afee:apps/ios/Rendprop/Screens/FlythroughDetailView.swift'],cwd=ROOT,text=True)
for needle in ['try PhotoVersionHistory.selectForPublication','try PhotoVersionHistory.confirmCustomReview']:
 assert compact(review_action(sources['detail'],needle))==compact(review_action(base,needle)),'A review/publication action body changed'
review=block(sources['detail'],'struct PhotoCompareView: View {');full=block(sources['detail'],'private struct PhotoFullSizeComparison: View {')
def boundary(s):
 r=block(s,'struct PhotoCompareView: View {');f=block(s,'private struct PhotoFullSizeComparison: View {')
 assert '.environment(\\.colorScheme, .dark)'not in r+f and 'Color.black'not in r+f,'Review must inherit adaptive appearance'
 assert 'Theme.bg' in r and 'Theme.ink'in r and '.thinMaterial'in r and '.regularMaterial'in r,'Adaptive glass review surfaces missing'
 assert '.safeAreaInset(edge: .bottom'in r and 'actionFooter(stacked:'in r,'Save/Use actions must have an independent safe-area footer'
 assert r.count('SecondaryButton(title: "Compare"')==1 and 'Picker("Photo version"'not in r,'Main review must have one comparison action and no duplicated segmented control'
 assert r.index('reviewTools(stacked:')<r.index('.accessibilityIdentifier("photoVersion.preview")'),'Edit and Compare must precede the image instead of falling below a portrait preview'
 assert '.resizable().scaledToFit()'in r,'Review cannot crop the source image'
 assert 'imageSize: (showOriginal ? original : enhanced)?.size' in r and 'availableWidth: max(0, min(760, geometry.size.width) - 32)' in r,'Review height must use the actual displayed image and padded content width'
 assert '.frame(height: 48)'not in r,'Saved choices must not clip larger text'
 for needle in ['try PhotoVersionHistory.selectForPublication','try PhotoVersionHistory.confirmCustomReview']:
  assert compact(review_action(s,needle))==compact(review_action(base,needle)),'Review/hash/privacy gate changed'
 for literal in ['.onChange(of: auth.userID)', '.onChange(of: auth.syncSessionRevision)', '.rendpropWorkspaceChanged', 'guard context.isCurrent, viewed.id == target.id', 'if showing, imageContext?.isCurrent == true, original != nil']:
  assert literal in r,'Actor/generation/comparison boundary missing: '+literal
 assert r.count('guard imageContext?.isCurrent == true else { clearAndDismiss(); return }')==3,'Every Compare/Save/Use tap must recheck its captured current scope'
 assert 'Menu {'in r and 'ForEach(viewed.history)'in r,'All saved styles must remain accessible'
 assert 'reviewCheck("Windows, walls and fixtures match", detail: "Windows, walls and fixed appliances match the source", isOn: $stagingReview.fixedFeaturesMatch)' in r,'Staging check must name the actual source features while preserving accessibility and binding'
boundary(sources['detail']);controls=[]
for literal in ['if let job = jobs.visibleJob', 'Text(PhotoWorkBannerCopy.phaseSummary(for: job))', '.accessibilityValue(PhotoWorkBannerCopy.completedSummary(for: job))', '.onChange(of: auth.userID)', '.rendpropWorkspaceChanged']:
 assert literal in sources['banner'],'Global progress phase/count/privacy wiring missing: '+literal
assert 'job.percent' not in sources['banner'],'Global banner must not imply provider percentage'
for name,old,new in [('forced-dark','.background(Theme.bg.ignoresSafeArea())','.background(Theme.bg.ignoresSafeArea()).environment(\\.colorScheme, .dark)'),('no-fixed-actions','.safeAreaInset(edge: .bottom','.overlay(alignment: .bottom'),('crop-preview','.resizable().scaledToFit()','.resizable().scaledToFill()'),('bypass-stage-review','guard !needsStagingReview || stagingReview.isComplete else {','guard true else {'),('bypass-current-account','guard imageContext?.isCurrent == true else { clearAndDismiss(); return }','guard true else { clearAndDismiss(); return }')]:
 changed=sources['detail'];st=changed.index('struct PhotoCompareView: View {');section=changed[st:];assert old in section,name;mutant=changed[:st]+section.replace(old,new,1)
 try:boundary(mutant)
 except AssertionError:controls.append(name)
 else:raise AssertionError('Source control was accepted: '+name)
layout=block(sources['detail'],'private enum PhotoReviewLayout {')
fixture='''import Foundation
LAYOUT
@main struct LayoutTest {
 static func main() {
  var n=0
  for (width,height) in [(320.0,568.0),(375,667),(390,844),(430,932),(768,1024),(1024,768)] {
   let available=max(0,min(760,width)-32)
   for size in [CGSize(width:4032,height:3024),CGSize(width:3840,height:2160),
                CGSize(width:2000,height:2000),CGSize(width:3024,height:4032),
                CGSize(width:1080,height:1920)] {
    let image=PhotoReviewLayout.previewHeight(imageSize:size,availableWidth:available,viewportHeight:height)
    let expected=min(420,height*0.50,available*size.height/size.width)
    precondition(abs(image-expected)<0.001,"Loaded landscape/square/portrait image uses actual fit geometry")
    precondition(image>0 && image<=420 && image<=height*0.52,"Preview leaves room for compact review actions")
    n+=2
   }
   let placeholder=PhotoReviewLayout.previewHeight(imageSize:nil,availableWidth:available,viewportHeight:height)
   precondition(placeholder==200,"Unavailable image has a safe compact placeholder")
   precondition(PhotoReviewLayout.stacksActions(width:width,accessibilityType:false)==(width<320),"Compact footer remains readable")
   precondition(PhotoReviewLayout.stacksActions(width:width,accessibilityType:true),"Accessibility text uses stacked actions")
   n+=3
  }
  for size in [CGSize(width:0,height:0),CGSize(width:-1,height:100),CGSize(width:100,height:-1),
               CGSize(width:CGFloat.infinity,height:100),CGSize(width:100,height:CGFloat.nan)] {
   precondition(PhotoReviewLayout.previewHeight(imageSize:size,availableWidth:288,viewportHeight:568)==200,"Invalid image dimensions cannot create a nonfinite layout")
   n+=1
  }
  precondition(PhotoReviewLayout.previewHeight(imageSize:nil,availableWidth:288,viewportHeight:100)==50,"Placeholder respects a short viewport")
  precondition(PhotoReviewLayout.previewHeight(imageSize:CGSize(width:4000,height:3000),availableWidth:0,viewportHeight:568)==200,"Unmeasured width uses a safe placeholder")
  precondition(PhotoReviewLayout.previewHeight(imageSize:CGSize(width:4000,height:3000),availableWidth:288,viewportHeight:0)==0,"Preview never exceeds an empty viewport")
  n+=3
  print("PASS \\(n) actual photo layout policy assertions; source geometry unchanged")
 }
}'''.replace('LAYOUT',layout)
lf=OUT/'ActualLayout.swift';lf.write_text(fixture)
commands=[]
def run(label,args):
 r=subprocess.run(list(map(str,args)),cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120);(OUT/(label+'.log')).write_text(r.stdout);commands.append({'label':label,'exit':r.returncode});assert r.returncode==0,label+': '+r.stdout[-2000:];return r.stdout
run('layout-compile',['xcrun','swiftc','-parse-as-library',lf,'-o',OUT/'layout']);run('layout-runtime',[OUT/'layout'])
# Compile the actual changed SwiftUI controls on the host, without presenting
# UI. Theme/haptics and action effects are closed; action semantics are checked
# above and by the existing listing-selection/single-edit executable gates.
components='\n'.join(block(sources['components'],x)for x in ['struct PrimaryButton: View {','struct SecondaryButton: View {'])
assert components.count('var isCompact = false')==2,'Compact sizing must be opt-in, never resize other screens'
save=block(review,'private var savePhotoButton: some View {');begin=save.index('SecondaryButton(');end=save.index('{',begin)
ui='''import SwiftUI
enum Theme { static let disabledFill=Color.gray;static let disabledInk=Color.gray;static let accent=Color.purple;static let border=Color.gray;static let accentSoft=Color.purple.opacity(0.12);static let inkDim=Color.secondary }
enum Haptics { static func selection() {} }
extension Font { static var rpBody: Font { .body } }
struct ScalePressStyle: ButtonStyle { func makeBody(configuration:Configuration)->some View { configuration.label } }
struct Context { var isCurrent=true }
struct Photo { var savedVersion:Int?=1 }
'''+components+'''
struct CompactReviewControls: View {
 var familyPosition:Int?=1;var familyPhotos=[1,2,3];var canNavigateFamilies=true
 var enhanced:Int?=1;var imageContext:Context?=Context();var showOriginal=false
 var viewed=Photo();var selectionWorkID:UUID?;var selectedForListing=true
 var listingSelectionDisabled=false;var savePhotoDisabled=false
 @State var showFullComparison=false
 func clearAndDismiss() {}\n func movePhotoFamily(_ offset:Int) {}\n func changeListingSelection() {}
 var singlePhotoEditing:some View { Text("Edit original photo") }
 var savePhotoButton:some View { '''+save[begin:end]+'''{} }
 var body:some View { VStack { familyNavigation;reviewTools(stacked:false);actionFooter(stacked:false) } }
'''+ '\n'.join(block(review,x)for x in ['@ViewBuilder private var familyNavigation:', 'private func reviewTools(', 'private var comparisonButton:', 'private func actionFooter(', '@ViewBuilder private var useOnListingButton:'])+'''
}
@main struct ControlValues {
 @MainActor static func main() {
  precondition(!PrimaryButton(title:"Default",action:{}).isCompact && !SecondaryButton(title:"Default",action:{}).isCompact,"Existing screens keep default button sizing")
  precondition(PrimaryButton(title:"Compact",isCompact:true,action:{}).isCompact && SecondaryButton(title:"Compact",isCompact:true,action:{}).isCompact,"Review opts into compact brand sizing")
  print("PASS actual compact SwiftUI control bodies and unchanged default constructors")
 }
}
'''
uf=OUT/'ActualCompactControls.swift';uf.write_text(ui)
run('controls-compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',uf,'-o',OUT/'controls']);run('controls-runtime',[OUT/'controls'])
banner=block(sources['banner'],'@MainActor private enum PhotoWorkBannerCopy {').replace('private enum','enum',1)
banner_file=OUT/'ActualBannerCopy.swift';banner_file.write_text('import Foundation\n'+banner+'\n')
run('progress-compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',paths['queue'],banner_file,paths['test'],'-o',OUT/'progress']);run('progress-runtime',[OUT/'progress'])
compiled_controls=[]
for name,old,new,reason in [
 ('banner-stale-phase','job.phase?.title ?? PhotoWorkQueue.Phase.preparing.title','PhotoWorkQueue.Phase.preparing.title','Global banner exposes the actual observed phase'),
 ('banner-failed-as-saved','\\(job.done) of \\(job.total) saved','\\(job.attempted) of \\(job.total) saved','Global saved count excludes attempted photos that failed'),
 ('banner-position-is-saved','min(max(1, job.current), job.total)','min(max(1, job.done), job.total)','Global banner reports the current photo position')]:
 assert old in banner,name
 changed=OUT/(name+'.swift');changed.write_text('import Foundation\n'+banner.replace(old,new,1)+'\n')
 run(name+'-compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',paths['queue'],changed,paths['test'],'-o',OUT/name])
 r=subprocess.run([str(OUT/name)],cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
 (OUT/(name+'-runtime.log')).write_text(r.stdout)
 assert r.returncode!=0 and reason in r.stdout,name+' did not fail at its intended consumer invariant'
 compiled_controls.append({'name':name,'compileExit':0,'runtimeExit':r.returncode,'expectedFailure':reason})
assert all(q.read_text()==sources[k]for k,q in paths.items()),'Source changed during proof'
receipt={'passed':True,'sourceHashes':{str(q.relative_to(ROOT)):hashlib.sha256(q.read_bytes()).hexdigest()for q in paths.values()},'reviewActionBodiesUnchangedFrom':'d643afee','sourceNegativeControls':controls,'compiledBannerControls':compiled_controls,'layoutRuntimeAssertions':86,'commands':commands,'liveCalls':0,'uiExecution':False,'physicalPhoneAcceptance':'Parent checks the integrated build; no simulator UI was used.'}
(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
