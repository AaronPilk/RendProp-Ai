#!/usr/bin/env python3
"""Actual queue/layout policy plus source-bound unchanged review/privacy actions.
Headless host execution/SDK-independent; no simulator/phone/provider control.
"""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path);a=p.parse_args();OUT=a.output or Path(tempfile.mkdtemp(prefix='rendprop-photo-review80-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
paths={'detail':ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift','queue':ROOT/'apps/ios/Rendprop/Photos/PhotoWorkQueue.swift','service':ROOT/'apps/ios/Rendprop/Photos/PhotoEditService.swift','test':ROOT/'tests/phase1/PhotoWorkProgressTests.swift','theme':ROOT/'apps/ios/Rendprop/DesignSystem/Theme.swift'}
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
 view=block(s,'struct PhotoCompareView: View {');at=view.index(needle);start=view.rfind('Button {',0,at);return block(view[start:],'Button {')
# The last approved implementation is immutable Git data, not a second model
# of the gates. Preserve the exact source/hash/custom-review action bodies.
base=subprocess.check_output(['git','show','1955b70:apps/ios/Rendprop/Screens/FlythroughDetailView.swift'],cwd=ROOT,text=True)
for needle in ['try PhotoVersionHistory.selectForPublication','try PhotoVersionHistory.confirmCustomReview']:
 assert compact(review_action(sources['detail'],needle))==compact(review_action(base,needle)),'A review/publication action body changed'
review=block(sources['detail'],'struct PhotoCompareView: View {');full=block(sources['detail'],'private struct PhotoFullSizeComparison: View {')
def boundary(s):
 r=block(s,'struct PhotoCompareView: View {');f=block(s,'private struct PhotoFullSizeComparison: View {')
 assert '.environment(\\.colorScheme, .dark)'not in r+f and 'Color.black'not in r+f,'Review must inherit adaptive appearance'
 assert 'Theme.bg' in r and 'Theme.ink'in r and '.thinMaterial'in r and '.regularMaterial'in r,'Adaptive glass review surfaces missing'
 assert '.safeAreaInset(edge: .bottom'in r and 'actionFooter(stacked:'in r,'Save/Use actions must have an independent safe-area footer'
 assert r.count('Label("Compare",')==1 and 'Picker("Photo version"'not in r,'Main review must have one comparison action and no duplicated segmented control'
 assert '.resizable().scaledToFit()'in r,'Review cannot crop the source image'
 assert 'imageSize: (showOriginal ? original : enhanced)?.size' in r and 'availableWidth: max(0, min(760, geometry.size.width) - 32)' in r,'Review height must use the actual displayed image and padded content width'
 assert '.frame(height: 48)'not in r,'Saved choices must not clip larger text'
 for needle in ['try PhotoVersionHistory.selectForPublication','try PhotoVersionHistory.confirmCustomReview']:
  assert compact(review_action(s,needle))==compact(review_action(base,needle)),'Review/hash/privacy gate changed'
 for literal in ['.onChange(of: auth.userID)', '.onChange(of: auth.syncSessionRevision)', '.rendpropWorkspaceChanged', 'guard context.isCurrent, viewed.id == target.id', 'if showing, imageContext?.isCurrent == true, original != nil']:
  assert literal in r,'Actor/generation/comparison boundary missing: '+literal
 assert r.count('guard imageContext?.isCurrent == true else { clearAndDismiss(); return }')==3,'Every Compare/Save/Use tap must recheck its captured current scope'
 assert 'Menu {'in r and 'ForEach(photo.history)'in r,'All saved styles must remain accessible'
 assert 'reviewCheck("Windows, walls and fixtures match", detail: "Windows, walls and fixed appliances match the source", isOn: $stagingReview.fixedFeaturesMatch)' in r,'Staging check must name the actual source features while preserving accessibility and binding'
boundary(sources['detail']);controls=[]
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
    let expected=min(560,height,available*size.height/size.width)
    precondition(abs(image-expected)<0.001,"Loaded landscape/square/portrait image uses actual fit geometry")
    precondition(image>0 && image<=560 && image<=height,"Preview is bounded by viewport and max height")
    n+=2
   }
   let placeholder=PhotoReviewLayout.previewHeight(imageSize:nil,availableWidth:available,viewportHeight:height)
   precondition(placeholder==200,"Unavailable image has a safe compact placeholder")
   precondition(PhotoReviewLayout.stacksActions(width:width,accessibilityType:false)==(width<360),"Compact footer remains readable")
   precondition(PhotoReviewLayout.stacksActions(width:width,accessibilityType:true),"Accessibility text uses stacked actions")
   n+=3
  }
  for size in [CGSize(width:0,height:0),CGSize(width:-1,height:100),CGSize(width:100,height:-1),
               CGSize(width:CGFloat.infinity,height:100),CGSize(width:100,height:CGFloat.nan)] {
   precondition(PhotoReviewLayout.previewHeight(imageSize:size,availableWidth:288,viewportHeight:568)==200,"Invalid image dimensions cannot create a nonfinite layout")
   n+=1
  }
  precondition(PhotoReviewLayout.previewHeight(imageSize:nil,availableWidth:288,viewportHeight:100)==100,"Placeholder respects a short viewport")
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
run('progress-compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',paths['queue'],paths['test'],'-o',OUT/'progress']);run('progress-runtime',[OUT/'progress'])
assert all(q.read_text()==sources[k]for k,q in paths.items()),'Source changed during proof'
receipt={'passed':True,'sourceHashes':{str(q.relative_to(ROOT)):hashlib.sha256(q.read_bytes()).hexdigest()for q in paths.values()},'reviewActionBodiesUnchangedFrom':'1955b70','sourceNegativeControls':controls,'layoutRuntimeAssertions':86,'commands':commands,'liveCalls':0,'uiExecution':False,'physicalPhoneAcceptance':'Parent checks the integrated build; no simulator UI was used.'}
(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
