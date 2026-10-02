#!/usr/bin/env python3
"""Compile actual gallery-sync/source methods against isolated async boundaries.
All image/history files are synthetic and owned under the temporary evidence dir.
No network, credentials, production photos or runtime-source edits are used.
"""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[3]
APP=ROOT/'apps/ios/Rendprop/RendpropApp.swift'
DETAIL=ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
TEMPLATE=Path(__file__).with_name('Fixture.swift.template')

def block(source, marker):
    assert source.count(marker)==1, marker
    start=source.index(marker); opening=source.index('{',start); depth=1; end=opening+1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]

def line(source, marker):
    lines=[s for s in source.splitlines() if marker in s]
    assert len(lines)==1, marker
    return lines[0]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--inject-fault',choices=['clear-unrelated','stale-selection','ignore-provenance'])
    args=parser.parse_args()
    out=Path(tempfile.mkdtemp(prefix='rendprop-gallery-sync-fixture-',dir='/tmp'))
    fixtures=out/'isolated-documents';fixtures.mkdir()
    app=APP.read_text();detail=DETAIL.read_text()
    sync=block(app,'    func syncGalleryPhotos(listingLocalID:')
    actual_sync=sync
    if args.inject_fault=='clear-unrelated':
        before='listings.first(where: { $0.id == listingLocalID })?.lastError?.hasPrefix(Self.photoSyncErrorPrefix) == true'
        assert before in sync;sync=sync.replace(before,'listings.first(where: { $0.id == listingLocalID })?.lastError != nil')
    elif args.inject_fault=='stale-selection':
        before='''guard try selectedPhotos().map(\\.id) == photos.map(\\.id),
                  listings.first(where: { $0.id == listingLocalID })?.mainPhotoRelPath == mainPath else {'''
        assert before in sync;sync=sync.replace(before,'if false {')
    elif args.inject_fault=='ignore-provenance':
        before='try await api.attachProvenanceMedia';assert before in sync;sync=sync.replace(before,'try? await api.attachProvenanceMedia')
    replacements={
        '__ENHANCED_PHOTO__':block(detail,'struct EnhancedPhoto: Identifiable'),
        '__PHOTO_LOAD__':block(detail,'    nonisolated static func loadForListing('),
        '__PHOTO_DIRECTORY__':block(detail,'    static func directory(for listingID:'),
        '__ERROR_SETTER__':block(app,'    func setLastError('),
        '__ERROR_NOTE__':block(app,'    private func noteUploadProblem(_ message: String, listingLocalID:'),
        '__USER_MESSAGE__':block(app,'    static func userMessage(for error:'),
        '__MAX_BYTES__':line(app,'private static let maxPublishedPhotoBytes:'),
        '__GALLERY_MEMO__':line(app,'private var publishedGalleryAssets:'),
        '__IN_FLIGHT__':line(app,'private var gallerySyncInFlight:'),
        '__PENDING__':line(app,'private var gallerySyncPending:'),
        '__ERROR_PREFIX__':line(app,'static let photoSyncErrorPrefix'),
        '__SYNC__':sync,
    }
    source=TEMPLATE.read_text()
    for key,value in replacements.items():assert source.count(key)==1;source=source.replace(key,value)
    checks=out/'ActualGallerySync.swift'; checks.write_text(source)
    production_sources=[APP,DETAIL,ROOT/'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift',ROOT/'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift']
    receipt={'productionMutations':0,'networkCalls':0,'userPhotosAccessed':0,'injectedFault':args.inject_fault,
        'sourceHashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in production_sources},
        'actualSyncBodySha256':hashlib.sha256(actual_sync.encode()).hexdigest(),
        'compiledSyncBodySha256':hashlib.sha256(sync.encode()).hexdigest(),'commands':[]}
    compile=['xcrun','swiftc','-swift-version','5','-parse-as-library',str(production_sources[2]),str(production_sources[3]),str(checks),'-o',str(out/'checks')]
    for label,command in [('compile',compile),('run',[str(out/'checks'),str(fixtures)])]:
        result=subprocess.run(command,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
        log=out/(label+'.log');log.write_text(result.stdout)
        receipt['commands'].append({'name':label,'exit':result.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
        if label=='run':
            expected_assertion={
                'clear-unrelated':'Successful gallery retry clears only its own error prefix',
                'stale-selection':'Queued pass publishes only the newer selected version and main photo',
                'ignore-provenance':'Missing/failed provenance publishes no photo selection',
            }.get(args.inject_fault)
            receipt['passed']=result.returncode==0 if not args.inject_fault else result.returncode!=0 and expected_assertion in result.stdout
            if args.inject_fault:receipt['expectedRejection']=expected_assertion
            if receipt['passed'] and not args.inject_fault:
                count=re.search(r'(\d+) assertions',result.stdout);assert count;receipt['assertions']=int(count[1])
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print(label,result.returncode,result.stdout[-2500:] if label=='compile' or result.returncode==0 else 'Acceptance rejected the injected regression',flush=True)
        if (label=='compile' and result.returncode) or (label=='run' and not receipt['passed']):
            print('Evidence:',out,flush=True);raise SystemExit(1)
    print('Evidence:',out,flush=True)
if __name__=='__main__':main()
