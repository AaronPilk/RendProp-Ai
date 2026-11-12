#!/usr/bin/env python3
"""Actual empty-gallery cloud loader/view context with closed metadata transport."""
import argparse, hashlib, json, os, re, subprocess, tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path);args=p.parse_args()
out=args.out or Path(tempfile.mkdtemp(prefix='rendprop-cloud-photo-preview-',dir=os.environ.get('RUNNER_TEMP')))
out.mkdir(parents=True,exist_ok=True)
view=root/'apps/ios/Rendprop/Screens/CloudMediaView.swift'; sync=root/'apps/ios/Rendprop/Networking/WorkspaceSync.swift'; studio=root/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'; fixture=Path(__file__).with_name('CloudPhotoPreviewTests.swift')
def block(text,marker):
 assert text.count(marker)==1,marker
 start=text.index(marker);end=text.index('{',start)+1;depth=1
 while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
a,b,c=view.read_text(),sync.read_text(),studio.read_text()
parts={'LOADER':block(a,'@MainActor final class CloudPhotoPreviewLoader:'),'SCOPE':block(a,'    private var scope:'),'VISIBLE':block(a,'    private var visiblePhotos:'),'LOAD':block(a,'    @MainActor private func load(force:'),'ACCESSIBILITY':block(a,'    private func photoAccessibilityLabel('),'PAGE':block(b,'struct CloudMediaPage:'),'ERROR':block(b,'enum CloudSyncError:'),'CONTEXT':block(b,'struct CloudMediaAccessContext:'),'VALIDATE':block(b,'    static func validateMedia('),'DATE':block(b,'    static func date('),'MEDIA_KEY':block(b,'    static func validatedMediaKey(')}
empty=block(c,'    private var photosEmptyState:')
assert 'CloudPhotoLibraryPreview(listing: current)' in empty
assert 'if localPhotoLibraryLoaded { CloudPhotoLibraryPreview(listing: current) }' in empty
assert '@State private var localPhotoLibraryLoaded = false' in c
assert 'loadExisting()\n            receivePhotoWork' in c
assert c.index('localPhotoLibraryLoaded = true') > c.index('seedPhotosForUIWalk()\n            refreshListingPhotoSelection()')
assert 'if photos.isEmpty && !isProcessing {\n                photosEmptyState' in c
assert '.task(id: scope) { await load() }' in a
assert r'ForEach(Array(visiblePhotos.prefix(6).enumerated()), id: \.element.id)' in a
assert '.accessibilityLabel(photoAccessibilityLabel(photo, ordinal: item.offset + 1))' in a
assert '.accessibilityHint("Opens available cloud files and saving options.")' in a
assert 'Cloud copy · original unavailable' in a and 'CloudMediaView(listing: listing)' in a
assert 'photos.isEmpty && cloudRecoveryListing != nil ? "Photos"' in c
assert '"Cloud photos · \\(visiblePhotos.count)\\(loader.hasMore ? "+" : "")"' in a
assert 'original_url' not in parts['LOAD'] and 'nativePhotoVersions' not in parts['LOADER']
controls={
 'late-context':('LOADER','guard generation == operation, isCurrent() else','guard generation == operation, true else','Changed context cannot retain late private previews'),
 'foreign-envelope':('LOADER','_ = try page.checked(listingID: requested.listingID, orgID: requested.orgID,\n                                     offset: offset, actorID: requested.actorID)','// injected missing envelope validation','Foreign listing response is not previewed'),
 'inflight-dedupe':('LOADER','        guard context != requested || !loading else { return }','', 'Same-scope in-flight metadata fetch is coalesced'),
 'completed-cache':('LOADER','        guard force || context != requested || !loaded else { return }','', 'Completed same-scope preview does not refetch'),
 'preview-bound':('LOADER','if found.count < 6, let next','if true, let next','Six previews stop further automatic metadata reads'),
 'visible-scope':('VISIBLE','loader.context == scope && scope != nil ? loader.photos : []','loader.photos','Account change immediately hides prior preview URLs'),
 'page-bound':('LOADER','0..<4','0..<5','Metadata pagination stops at four pages'),
}
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
consumed=[view,sync,studio,fixture,Path(__file__).resolve()];initial={str(x.relative_to(root)):sha(x) for x in consumed}
receipt={'passed':False,'sourceHashes':initial,'actualBodyHashes':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in parts.items()},'runs':[],'scope':'Actual loader, DTO validation, private-media URL validation, view context and visibility; controlled Auth/workspace/HTTP, no network, thumbnails, local photo writes, restore, AI, selection or live service mutation. SwiftUI presentation wiring is source checked; integrated app compile is separate.'}
try:
 for label,mutation in [('actual',None),*controls.items()]:
  current=parts.copy()
  if mutation:
   key,old,new,expected=mutation;assert current[key].count(old)==1,(label,old);current[key]=current[key].replace(old,new)
   if label=='page-bound':
    assert current[key].count('pageNumber < 3')==1;current[key]=current[key].replace('pageNumber < 3','pageNumber < 4')
  source=fixture.read_text()
  for key,value in current.items():source=source.replace('__'+key+'__',value)
  assert not re.search(r'__[A-Z_]+__',source)
  swift=out/(label+'.swift');swift.write_text(source)
  row={'name':label,'commands':[],'compiledBodyHashes':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in current.items()}};receipt['runs'].append(row)
  for stage,argv,deadline in [('compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(out/label)],120),('run',[str(out/label)],45)]:
   log=out/(label+'-'+stage+'.log')
   with log.open('w') as f:r=subprocess.run(argv,cwd=root,stdout=f,stderr=subprocess.STDOUT,timeout=deadline)
   text=log.read_text();row['commands'].append({'stage':stage,'exit':r.returncode,'log':str(log),'sha256':sha(log)})
   if stage=='compile':assert r.returncode==0,text
   elif mutation:assert r.returncode==1 and expected in text,(label,text)
   else:assert r.returncode==0,text;row['assertions']=int(re.search(r'PASS (\d+)',text)[1])
  row['passed']=True;print(label,'PASS',flush=True)
 receipt['sourceBoundAtEnd']=initial=={str(x.relative_to(root)):sha(x) for x in consumed};assert receipt['sourceBoundAtEnd'];receipt['passed']=True
finally:
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('Evidence:',out,flush=True)
