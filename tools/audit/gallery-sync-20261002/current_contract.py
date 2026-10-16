"""Current explicit/read-only boundaries; no hosted service or source mutation."""
from pathlib import Path
import datetime,hashlib,json,subprocess,re,shutil,os
os.umask(0o077)
ROOT=Path(__file__).resolve().parents[3]
def block(text,marker):
 assert text.count(marker)==1,marker
 start=text.index(marker);end=text.index('{',start)+1;depth=1
 while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
def line(text,marker):
 rows=[x for x in text.splitlines()if marker in x];assert len(rows)==1,marker;return rows[0]
def run_current(out,mode='sync',fault=None):
 out=Path(out);out.mkdir(parents=True,exist_ok=True);app=(ROOT/'apps/ios/Rendprop/RendpropApp.swift').read_text();detail=(ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift').read_text()
 paths=['apps/ios/Rendprop/RendpropApp.swift','apps/ios/Rendprop/Screens/FlythroughDetailView.swift','apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift','apps/ios/Rendprop/Photos/PhotoVersionHistory.swift','apps/ios/Rendprop/Photos/PhotoImportSequence.swift','apps/ios/Rendprop/Photos/PhotoGalleryDisclosure.swift','apps/ios/Rendprop/Photos/PhotoGalleryMutationFence.swift','apps/ios/Rendprop/Photos/PhotoCloudSelection.swift','tools/audit/gallery-sync-20261002/Fixture.swift.template','tools/audit/gallery-sync-20261002/current_contract.py','tools/audit/gallery-sync-20261002/CurrentCases.swift.fragment']
 assert shutil.disk_usage(Path.home()).free>=3*1024**3 and shutil.disk_usage(out).free>=8*1024**3
 sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p:sha(ROOT/p)for p in paths}
 sync=block(app,'    func syncGalleryPhotos(');prepare=block(app,'            prepare: { measured, org in');prepare=prepare.split(' in\n',1)[1][:-1]
 if fault=='clear-unrelated':
  needle='listings.first(where: { $0.id == listingLocalID })?.lastError?.hasPrefix(Self.photoSyncErrorPrefix) == true';assert sync.count(needle)==1;sync=sync.replace(needle,'listings.first(where: { $0.id == listingLocalID })?.lastError != nil',1)
 elif fault=='ignore-provenance':
  needle='try await self.api.attachProvenanceMedia';assert prepare.count(needle)==1;prepare=prepare.replace(needle,'try? await self.api.attachProvenanceMedia',1)
 elif fault=='stale-selection':
  needle='DirectUploader.sha256(of: file) == measured.sha256,\n                      FileStore.fileSize(file) == measured.bytes';assert prepare.count(needle)==1;prepare=prepare.replace(needle,'true',1)
 elif fault=='old-original-guard':
  needle='retainedOriginal == nil';assert prepare.count(needle)==2;prepare=prepare.replace(needle,'true')
 elif fault=='spoof-original-exemption':
  needle='version.edit != "capture", version.edit != "legacy", retainedOriginal == nil';assert prepare.count(needle)==2;prepare=prepare.replace(needle,'!["capture", "capture-original", "legacy"].contains(version.edit)')
 elif fault=='changed-original-history':
  needle='try PhotoGalleryDisclosure.requireUnchanged';assert prepare.count(needle)==1;prepare=prepare.replace(needle,'try? PhotoGalleryDisclosure.requireUnchanged',1)
 elif fault in ['ignore-original-effects','ignore-original-parent','ignore-original-sha']:pass
 elif fault is not None:raise AssertionError('Unsupported current boundary control '+fault)
 prefix=(ROOT/paths[8]).read_text().split('@main struct GallerySyncChecks')[0]
 replacements={'__ENHANCED_PHOTO__':block(detail,'struct EnhancedPhoto: Identifiable'),'__PHOTO_LOAD__':block(detail,'    nonisolated static func loadForListing('),'__PHOTO_DIRECTORY__':block(detail,'    static func directory(for listingID:'),'__ERROR_SETTER__':block(app,'    func setLastError('),'__ERROR_NOTE__':block(app,'    private func noteUploadProblem(_ message: String, listingLocalID:'),'__USER_MESSAGE__':block(app,'    static func userMessage(for error:'),'__MAX_BYTES__':line(app,'private static let maxPublishedPhotoBytes:'),'__GALLERY_MEMO__':'','__IN_FLIGHT__':line(app,'private var gallerySyncInFlight:'),'__PENDING__':line(app,'private var gallerySyncPending:'),'__REMOVAL_FENCE__':'\n'.join([line(app,'private let galleryMutationFence ='),block(app,'    func beginPhotoGalleryRemoval('),block(app,'    func endPhotoGalleryRemoval(')]),'__ERROR_PREFIX__':line(app,'static let photoSyncErrorPrefix'),'__SYNC__':sync}
 for marker,value in replacements.items():assert prefix.count(marker)==1;prefix=prefix.replace(marker,value)
 prefix=prefix.replace('import Foundation','import Foundation\nimport CryptoKit',1)
 extra='''
    var readCount = 0
    var readBoundary: (() async throws -> Void)?
    func refreshCloudPhotoSelection(listingID: UUID) async throws -> PhotoCloudSelectionProjection { readCount += 1; try await readBoundary?(); return PhotoCloudSelectionProjection() }
    var identityCurrent = true
    func prepareMeasured(_ measured: PhotoCloudLocalVersion, org: UUID, listingID: UUID, versionID: String, identity: PhotoCloudSelectionIdentity, reviewed: Bool) async throws {
        func check() throws { if !identityCurrent { throw PhotoCloudSelectionFailure.identityChanged } }
__ACTUAL_PREPARE__
    }
'''.replace('__ACTUAL_PREPARE__',prepare)
 prefix=prefix.replace('    var isBusy: Bool',extra+'    var isBusy: Bool',1)
 prefix+='''
struct PhotoCloudSelectionProjection {}
enum DirectUploader {
 static func sha256(of url: URL) -> String? { (try? Data(contentsOf:url)).map { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() } }
}
'''
 source=prefix+(ROOT/paths[10]).read_text().replace('__ORIGINAL_SHA__',hashlib.sha256(b'actual-original-original').hexdigest());main=out/'Current.swift';main.write_text(source);owned=out/'owned';owned.mkdir()
 helper=(ROOT/paths[5]).read_text()
 for name,needle,replacement in [('ignore-original-effects','version.effects.isEmpty','true'),('ignore-original-parent','version.parentID == nil','true'),('ignore-original-sha','maxBytes: maxBytes) == original','maxBytes: maxBytes) != nil')]:
  if fault==name:assert helper.count(needle)==1;helper=helper.replace(needle,replacement,1)
 helper_path=out/'PhotoGalleryDisclosure.swift';helper_path.write_text(helper)
 sources=[ROOT/paths[i]for i in [2,3,4,6,7]]+[helper_path];binary=out/'checks';compile=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',*map(str,sources),str(main),'-o',str(binary)],capture_output=True,text=True,timeout=120)
 (out/'compile.log').write_text(compile.stdout+compile.stderr);assert compile.returncode==0,'Current contract compile is not behavioral evidence: '+compile.stderr
 run=subprocess.run([str(binary),str(owned),mode],capture_output=True,text=True,timeout=60);log=run.stdout+run.stderr;(out/'runtime.log').write_text(log)
 oracle={'clear-unrelated':'Successful gallery retry clears only its own error prefix','ignore-provenance':'Missing/failed provenance never completes explicit preparation','stale-selection':'Changed prepared target never completes explicit preparation','old-original-guard':'Verified retained Original completes explicit preparation without AI disclosure','ignore-original-effects':'Altered metadata never earns a retained Original exemption: 0','ignore-original-parent':'Altered metadata never earns a retained Original exemption: 2','ignore-original-sha':'Same-size source mutation invalidates retained Original proof','spoof-original-exemption':'Spoofed capture-original cannot skip explicit provenance','changed-original-history':'Changed retained-original history cannot complete explicit preparation'}.get(fault)
 passed=run.returncode==0 if oracle is None else run.returncode!=0 and oracle in log
 receipt={'passed':passed,'checkedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'mode':mode,'fault':fault,'expectedRuntimeOracle':oracle,'compileExit':compile.returncode,'runtimeExit':run.returncode,'sourceHashes':before,'sourceStable':before=={p:sha(ROOT/p)for p in paths},'actualSyncSHA256':hashlib.sha256(replacements['__SYNC__'].encode()).hexdigest(),'actualPreparationSHA256':hashlib.sha256(prepare.encode()).hexdigest(),'runtimeSHA256':hashlib.sha256(log.encode()).hexdigest(),'networkCalls':0,'hostedWrites':0,'limits':'Actual shared read sink, actual explicit preparation closure, actual local reader/history and original certification. Upload/API/context/primitive digest boundaries are closed; no claim of a whole AppModel/phone publication run.'};(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');assert passed and receipt['sourceStable'],log;return receipt
