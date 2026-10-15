#!/usr/bin/env python3
"""Real selected-version history/catalog/preparation/batch filesystem regression.
UIImage preparation is a closed byte-preserving double; no UI/model/upload call.
"""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);a=p.parse_args()
out=(a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-stage-video-'))).resolve();out.mkdir(parents=True,exist_ok=True)
paths=[ROOT/x for x in ['apps/ios/Rendprop/Screens/FlythroughDetailView.swift','apps/ios/Rendprop/RendpropApp.swift','apps/ios/Rendprop/Photos/PhotoVersionHistory.swift','apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift','apps/ios/Rendprop/Photos/PhotoImportSequence.swift','apps/ios/Rendprop/Render/PropertyVideoPlanner.swift','apps/ios/Rendprop/Render/VideoMusicContract.swift','apps/ios/Rendprop/Models/ListingVideo.swift','apps/ios/Rendprop/Render/VideoAspectChoice.swift','apps/ios/Rendprop/Networking/APIClient.swift','apps/ios/tests/StagedVideoSourceTests.swift','apps/ios/tests/run-staged-video-source.py']]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before=hashes();view,app,history,capture,sequence,planner,music,metadata,aspect,api,tests=[x.read_text() for x in paths[:-1]]
def block(text,anchor):
 start=text.index(anchor);opening=text.index('{',start);depth=1;end=opening+1
 while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
reel=block(view,'struct ReelStudioView:')
assert 'refreshedPhotos = try EnhancedPhoto.loadForListing(listingID: listing.id)' in block(reel,'private func refreshVideoPhotos()')
assert '.sheet(isPresented: $showReelPhotos, onDismiss: { refreshVideoPhotos() })' in reel
assert 'photos: (try? EnhancedPhoto.loadForListing(listingID: listing.id)) ?? []' in app
assert 'photos: (try? EnhancedPhoto.loadForListing(listingID: currentListing.id)) ?? []' in view
generate=block(reel,'private func generateWithSession()')
assert 'let jpeg = try Self.preparedReelJPEG(photo: photo' in generate
assert 'try jpeg.write(to: input' in generate and 'DirectUploader.uploadPhoto(fileURL: input' in generate
assert 'photoProvenanceID: photo.savedVersion?.provenanceID' in generate
assert 'sourceAssetID: photo.sourceAssetID, photoProvenanceID: photo.photoProvenanceID' in block(reel,'nonisolated private static func completeSavedBatch(')
source='import Foundation\nimport CryptoKit\n'
source+='''enum FileStore { static var documents = URL(fileURLWithPath:"/closed-fixture"); static func url(fromRelativePath p:String)->URL { documents.appendingPathComponent(p) } }
enum AIImagePrep { static func error(_ s:String)->Error { NSError(domain:"closed",code:1,userInfo:[NSLocalizedDescriptionKey:s]) }; static func reelSource(_ image:UIImage,aspect:String)->UIImage { image }; static func downscaled(_ image:UIImage,maxDimension:Int)->UIImage { image } }
struct UIImage { let bytes:Data; init?(contentsOfFile p:String) { guard let d=try? Data(contentsOf:URL(fileURLWithPath:p)) else{return nil};bytes=d }; func jpegData(compressionQuality:Double)->Data?{bytes} }
enum AdoptionOwnedIdentity { static func pathIsOccupied(_ u:URL)->Bool { FileManager.default.fileExists(atPath:u.path) } }
enum PendingReelRequest { struct Context:Codable,Sendable,Equatable {let listingID:UUID;let serverListingID:UUID?;let owner:String;let workspace:UUID?};static func file(_ c:Context)->URL {FileStore.documents.appendingPathComponent("reels/\\(c.listingID)-request.json")} }
enum PendingReelClips { static func directory(for id:UUID)->URL {FileStore.documents.appendingPathComponent("reels/\\(id)-parked",isDirectory:true)} }
'''
source+=capture+'\n'+history+'\n'+block(sequence,'enum PhotoImportOrder {')+'\n'
source+=block(view,'private struct DatedFile:')+'\n'+block(view,'private struct DatedPhoto')+'\n'
source+='private enum DiskScan {\n'+block(view,'nonisolated static func entries(of dir:')+'\n'+block(view,'nonisolated static func createdAt(of url:')+'\n}\n'
source+=block(view,'struct EnhancedPhoto: Identifiable')+'\nextension EnhancedPhoto {\n'+'\n'.join(block(view,x) for x in ['nonisolated static func loadAll(listingID:','nonisolated static func loadForListing(','static func directory(for listingID:','nonisolated fileprivate static func dated(in entries:'])+'\n}\n'
source+=block(api,'struct AIShot: Sendable')+'\n'+block(view,'struct PendingReelBatch: Codable')+'\n'
source+='enum SourcePreparation {\n'+block(reel,'nonisolated private static func preparedReelJPEG(').replace('private static','static')+'\n'+block(reel,'nonisolated private static func requireSavedReelReview(').replace('private static','static')+'\n}\n'
source+=aspect+'\n'+music+'\n'+metadata+'\n'+planner
receipt={'passed':False,'sourceHashes':before,'runs':[],'limitations':['Actual local catalog, version review, batch save/load, source-metadata/fallback composition. UIImage decoding/resampling is a closed byte-preserving boundary; classifier is closed; no UI, paid model, actual upload or server publication executed. Existing real compositor and paid recovery gates provide separate coverage.']}
variants=[('actual',source,None),
 ('editing-preview-substitution',source.replace('return index.orderedForLibrary(choices).map { version in','return index.orderedForLibrary(index.libraryVersions(.latest)).map { version in'),'video collection resolves the reviewed staged file instead of a newer preview'),
 ('original-source-substitution',source.replace('UIImage(contentsOfFile: photo.enhancedURL.path)','UIImage(contentsOfFile: photo.originalURL.path)'), 'actual video preparation reads the saved staged pixels without reverting to original'),
 ('lost-recovery-stage-review',source.replace('if version.needsStagingReview { throw Failure.reviewRequired }','// omitted staged review'),'unreviewed newer stage stays held during recovery')]
try:
 for name,code,expected in variants:
  assert expected is None or code!=source,name
  production=out/(name+'.swift');production.write_text(code);binary=out/name
  c=subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path',str(out/'module-cache'),'-parse-as-library',str(production),str(paths[-2]),'-o',str(binary)],capture_output=True,text=True,timeout=240)
  (out/(name+'-compile.log')).write_text(c.stdout+c.stderr);assert c.returncode==0,(name,c.stderr)
  r=subprocess.run([str(binary)],capture_output=True,text=True,timeout=60);text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text)
  valid=r.returncode==0 if expected is None else r.returncode!=0 and 'FAIL: '+expected in text
  receipt['runs'].append({'name':name,'exit':r.returncode,'expectedRejection':expected,'passed':valid});assert valid,(name,text)
 receipt['sourceHashesAtEnd']=hashes();receipt['passed']=before==receipt['sourceHashesAtEnd'];receipt['compiledNegativeControls']=len(variants)-1
finally:(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert receipt['passed'];print(json.dumps({'passed':True,'compiledNegativeControls':len(variants)-1,'receipt':str(out/'receipt.json')}))
