#!/usr/bin/env python3
"""Real Foundation import/history runtime plus actual picker/native source gates.
No Photos UI, camera, network, paid generation or Apple operations.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, re, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
out=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-import-'));out.mkdir(parents=True,exist_ok=True)
inputs=['apps/ios/Rendprop/Photos/PhotoImportSequence.swift','apps/ios/Rendprop/Photos/PhotoLibraryPicker.swift','apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift','apps/ios/Rendprop/Photos/PhotoVersionHistory.swift','apps/ios/tests/PhotoImportSequenceTests.swift','apps/ios/tests/run-photo-import.py']
sha=lambda path:hashlib.sha256(Path(path).read_bytes()).hexdigest()
before={path:sha(ROOT/path) for path in inputs}
view=(ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift').read_text();picker=(ROOT/inputs[1]).read_text()
def block(text,anchor):
 start=text.index(anchor);opening=text.index('{',start);depth=1;end=opening+1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
fragments={
 'photo':block(view,'struct EnhancedPhoto: Identifiable'),
 'datedFile':block(view,'private struct DatedFile:'),
 'datedPhoto':block(view,'private struct DatedPhoto'),
 'entries':block(view,'nonisolated static func entries(of dir:'),
 'createdAt':block(view,'nonisolated static func createdAt(of url:'),
 'loadAll':block(view,'nonisolated static func loadAll(listingID:'),
 'loadPublication':block(view,'nonisolated static func loadForListing('),
 'directory':block(view,'static func directory(for listingID:'),
 'dated':block(view,'nonisolated fileprivate static func dated(in entries:'),
}
gallerySource='import Foundation\nenum FileStore { static var documents = URL(fileURLWithPath: "/closed-fixture") }\n'+fragments['datedFile']+'\n'+fragments['datedPhoto']+'\nprivate enum DiskScan {\n'+fragments['entries']+'\n'+fragments['createdAt']+'\n}\n'+fragments['photo']+'\nextension EnhancedPhoto {\n'+'\n'.join(fragments[x] for x in ['loadAll','loadPublication','directory','dated'])+'\n}\n'
gallery=out/'ActualGalleryReader.swift';gallery.write_text(gallerySource)
assert view.count('LibraryImagePicker(onBegin:')==1 and view.count('LibraryImagePicker(selectionLimit: 1,')==1
assert 'selectionLimit = 0; onPicked = nil' in picker and 'config.selection = .ordered' in picker and 'config.preferredAssetRepresentationMode = .current' in picker
assert 'loadFileRepresentation(forTypeIdentifier: type)' in picker and 'loadObject(ofClass:' not in picker
assert 'guard !results.isEmpty else { callbacks.onCancel?(); callbacks.onPicked?([]); return }' in picker
start=view.index('    private func ingest(_ batch: PhotoImportBatch)');end=view.index('    private func ingest(_ images:',start);body=view[start:end]
assert 'original: original, enhanced: jpeg' in body and '.mappedIfSafe' in body and 'PhotoImportWriter.save(batch' in body
assert 'original.jpegData(' not in body and 'image.jpegData(' not in body
assert body.count('batch.context.matches(owner: AuthStore.shared.userID,')==2
assert 'libraryImportCancellation?.cancel()' in view and 'report.message' in body
compile=['xcrun','swiftc','-swift-version','5','-parse-as-library',str(ROOT/inputs[0]),str(ROOT/inputs[2]),str(ROOT/inputs[3]),str(gallery),str(ROOT/inputs[4]),'-o',str(out/'runtime')]
r=subprocess.run(compile,capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stderr
r=subprocess.run([str(out/'runtime')],capture_output=True,text=True,timeout=60);(out/'runtime.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stderr
# Both controls compile the production sequence; only the in-memory policy
# copies change. The same actual durable-history test must reject regressions.
controls=[]
sequence=(ROOT/inputs[0]).read_text()
for name,old,new,needle in [
 ('fifteen-cutoff','total = count;','total = min(count, 15);','all selections beyond15'),
 ('completion-order-reversal','self.items.append(PhotoImportItem(position: position, url: url))','self.items.insert(PhotoImportItem(position: position, url: url), at: 0)','success order preserved'),
 ('reversed-gallery-ids','top - Int64(position)','top + Int64(position)','gallery descending IDs'),
 ('concurrent-image-decodes','DispatchQueue(label: "com.rendprop.photo-import-save", qos: .userInitiated)','DispatchQueue(label: "com.rendprop.photo-import-save", qos: .userInitiated, attributes: .concurrent)','one photo decode/write is active'),
]:
 assert old in sequence
 modified=out/(name+'.swift');modified.write_text(sequence.replace(old,new,1));cmd=list(compile);cmd[cmd.index(str(ROOT/inputs[0]))]=str(modified);cmd[-1]=str(out/name)
 c=subprocess.run(cmd,capture_output=True,text=True);(out/(name+'-compile.log')).write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
 e=subprocess.run([str(out/name)],capture_output=True,text=True,timeout=60);(out/(name+'.log')).write_text(e.stdout+e.stderr);assert e.returncode==1 and needle in e.stderr,(name,e.stdout,e.stderr)
 controls.append({'name':name,'compiled':True,'rejected':True,'expectedFailure':needle})
lostOrder=gallerySource.replace('importOrderID: history?.importOrder?[aFamily]','importOrderID: nil').replace('importOrderID: history?.importOrder?[bFamily]','importOrderID: nil')
assert lostOrder!=gallerySource
modified=out/'local-order-lost.swift';modified.write_text(lostOrder);cmd=list(compile);cmd[cmd.index(str(gallery))]=str(modified);cmd[-1]=str(out/'local-order-lost')
c=subprocess.run(cmd,capture_output=True,text=True);(out/'local-order-lost-compile.log').write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
e=subprocess.run([str(out/'local-order-lost')],capture_output=True,text=True,timeout=60);(out/'local-order-lost.log').write_text(e.stdout+e.stderr);assert e.returncode==1 and 'actual local gallery displays selected order' in e.stderr,(e.stdout,e.stderr)
controls.append({'name':'local-order-lost','compiled':True,'rejected':True,'expectedFailure':'actual local gallery displays selected order'})
assert before=={path:sha(ROOT/path) for path in inputs},'Consumed source changed during test'
r={'passed':True,'checkedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceHashes':before,'actualLibraryIngestBodySHA256':hashlib.sha256(body.encode()).hexdigest(),'actualGalleryReaderFragmentsSHA256':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in fragments.items()},'selectionTested':40,'durablePhotosAcrossRepeatedImports':63,'negativeControls':controls,'boundedProviderConcurrency':1,'boundedWriterConcurrencyAcrossBatches':1,'simultaneousBatchesTested':2,'runtime':'actual Foundation sequence + actual PhotoVersionHistory/PhotoCaptureStorage + actual EnhancedPhoto readers/DiskScan','scope':'Ordered imports, serial file admission and saving, exact bytes, partial load/save failures, repeat/simultaneous imports and cancellation. Actual local-gallery and publication readers execute against real owned files/history. Picker source settings and account fences source-checked. No real Photos/iCloud/UIImage enhancement or physical UI execution is claimed.','networkCalls':0,'AppleCalls':0,'paidProviderCalls':0,'UIExecutions':0}
(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({'passed':True,'receipt':str(out/'receipt.json'),'negativeControls':len(controls)}))
