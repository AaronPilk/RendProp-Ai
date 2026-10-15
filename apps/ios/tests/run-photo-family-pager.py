#!/usr/bin/env python3
"""Compile actual photo family navigation/context/edit-entry logic; closed UI/queue."""
import argparse,hashlib,json,subprocess,tempfile,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);a=p.parse_args()
OUT=a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-family-pager-'));OUT.mkdir(parents=True,exist_ok=True)
VIEW=ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift';HISTORY=ROOT/'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift';CAPTURE=ROOT/'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift';FIXTURE=ROOT/'apps/ios/tests/PhotoFamilyPagerTests.swift'
s=VIEW.read_text()
def block(text,anchor):
 assert text.count(anchor)==1,anchor
 start=text.index(anchor);i=text.index('{',start)+1;depth=1
 while depth:depth+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[start:i]
review=block(s,'struct PhotoCompareView: View {');helper=block(s,'private enum PhotoFamilyPager {').replace('private enum','enum',1);context=block(s,'@MainActor private struct NativeMediaExportContext {').replace('private struct','struct',1)
anchors=['private var familyPhotos:', 'private var familyPosition:', 'private var canNavigateFamilies:', 'private var requestedCoverForViewed:', 'private func movePhotoFamily(', 'private var reviewListing:', 'private func openSinglePhotoEdit()', 'private func chooseVersion(', 'private func clearSinglePhotoEdit()']
methods='\n'.join(block(review,x).replace('private ','',1)for x in anchors)
for required in ['galleryPhotos: entry == .photos ? galleryFamilyPhotos : []','Text(entry == .photos ? "Photos · \\(galleryFamilyPhotos.count)" : "AI Photo Studio")','let history = viewed.history','ForEach(viewed.history)','if familyWasMain || requestedCoverForViewed','familyNavigation','DragGesture(minimumDistance: 30)','PhotoFamilyPager.swipeOffset(horizontal: Double(value.translation.width)','movePhotoFamily(offset)','photoVersion.position','photoVersion.previousPhoto','photoVersion.nextPhoto','.accessibilityAction(named: Text("Previous photo"))','.accessibilityAction(named: Text("Next photo"))']:
 assert required in s,required
navigation=block(review,'@ViewBuilder private var familyNavigation: some View {')
for required in ['movePhotoFamily(-1)','movePhotoFamily(1)','Image(systemName: "chevron.left")','Image(systemName: "chevron.right")','.disabled(!canNavigateFamilies || position == 0)','.disabled(!canNavigateFamilies || position + 1 >= familyPhotos.count)']:
 assert required in navigation,required
assert navigation.count('.frame(width: 32, height: 32)')==2 and navigation.count('.frame(width: 44, height: 44)')==2,'Compact visual controls retain full44pt hit targets'
assert 'SecondaryButton('not in navigation,'Family navigation must not become full-width pills'
assert 'PhotoCompareView(photo: presentation.photo, requestedCover: presentation.requestedCover,'in s
variants=[('actual',helper,methods,None),
 ('foreign-directory',helper.replace('photo.enhancedURL.standardizedFileURL.deletingLastPathComponent() == directory','true').replace('photo.originalURL.standardizedFileURL.deletingLastPathComponent() == directory','true'),methods,'another listing directory cannot enter the viewer'),
 ('variant-count',helper.replace('return index.orderedFamilyIDs.compactMap { families[$0] }','return candidates'),methods,'count source families once, never saved variants'),
 ('pending-navigation',helper,methods.replace('guard canNavigateFamilies else { return }','guard true else { return }'),'pending edit context fences family navigation'),
 ('remembered-version',helper.replace('if let saved = remembered[target], family(of: saved, index: index, directory: directory) == target { return saved }','if false, let saved = remembered[target] { return saved }'),methods,'return preserves the exact saved version previously viewed'),
 ('cover-follows',helper,methods.replace('return PhotoFamilyPager.family(of: viewed, index: index, directory: directory) == initial','return !initial.isEmpty'),'cover intent never follows navigation into another family'),
 ('wrong-edit-photo',helper,methods.replace('originalForEditing(id: viewed.id, directory: directory)','originalForEditing(id: photo.id, directory: directory)'),'edit action after navigation targets only displayed family Original')]
results=[]
for name,h,m,expected in variants:
 folder=OUT/name;folder.mkdir(exist_ok=True);swift=folder/'Checks.swift';swift.write_text(FIXTURE.read_text().replace('__HELPER__',h).replace('__CONTEXT__',context).replace('__METHODS__',m));binary=folder/'checks'
 build=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(OUT/'module-cache'),str(CAPTURE),str(HISTORY),str(swift),'-o',str(binary)],capture_output=True,text=True,timeout=120);(folder/'compile.log').write_text(build.stdout+build.stderr);assert build.returncode==0,name+': '+build.stderr
 run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=45);log=run.stdout+run.stderr;(folder/'runtime.log').write_text(log);assert (run.returncode==0 and 'PASS 'in log)if expected is None else(run.returncode!=0 and expected in log),name+': '+log
 results.append({'name':name,'compiled':True,'exit':run.returncode,'expectedFailure':expected});print(name+': PASS',flush=True)
assert block(VIEW.read_text(),'struct PhotoCompareView: View {')==review
paths=[HISTORY,CAPTURE,FIXTURE,Path(__file__).resolve()];r={'passed':True,'assertions':int(re.search(r'PASS (\d+)',(OUT/'actual/runtime.log').read_text())[1]),'controls':len(variants)-1,'sourceHashes':{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in paths},'fragmentHashes':{anchor:hashlib.sha256(block(s,anchor).encode()).hexdigest()for anchor in ['private enum PhotoFamilyPager {','private var galleryFamilyPhotos:','private var studioTitleBar:','struct PhotoCompareView: View {']},'results':results,'scope':'Actual retained family selection/count/order/navigation, session gates, per-photo edit Original lookup, exact saved version memory and cover intent; real Foundation/history/filesystem. UIKit/gestures/accessibility wiring source-checked only; no Simulator, phone, archive, provider or network acceptance.'};(OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(OUT/'receipt.json')
