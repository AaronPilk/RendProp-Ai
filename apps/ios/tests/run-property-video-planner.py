#!/usr/bin/env python3
"""Actual scene planner/cache/order and extracted Live wire method; no UI/vendor."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);a=p.parse_args()
out=(a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-scene-planner-'))).resolve();out.mkdir(parents=True,exist_ok=True)
paths=[ROOT/x for x in ['apps/ios/Rendprop/Render/PropertyVideoPlanner.swift','apps/ios/Rendprop/Render/VideoAspectChoice.swift','apps/ios/Rendprop/Networking/LiveAPIClient.swift','apps/ios/Rendprop/Screens/FlythroughDetailView.swift','apps/ios/Rendprop/Networking/NativeReelDraft.swift','apps/ios/tests/PropertyVideoPlannerTests.swift','apps/ios/tests/run-property-video-planner.py']]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before=hashes();planner,aspect,live,view,draft,tests=[x.read_text() for x in paths[:-1]]
def block(text,anchor):
 start=text.index(anchor);opening=text.index('{',text.index(') async throws -> URL {',start)) if 'makeClip(' in anchor else text.index('{',start);depth=1;end=opening+1
 while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
reel=block(view,'struct ReelStudioView:')
generate=block(reel,'private func generateWithSession()')
assert generate.index('DirectUploader.uploadPhoto(')<generate.index('PropertyVideoPlanner.plan(')<generate.index('try batch?.save()')<generate.index('Self.makeClip(')
assert 'motion: shot?.motion ?? selectedMove' in generate
assert 'plan = prepared.compactMap { $0.shot?.value }' in generate and 'ordered = Self.reordered(chosen, by: plan)' in generate
assert 'api as? PropertyVideoPlanningAPI' in generate and 'requireCurrent: requireCurrent' in generate
assert 'scenePlanVersion == 1 ? photo.shot?.motion ?? batch.motion : batch.motion' in block(view,'nonisolated private static func completeSavedBatch(')
assert 'batch.scenePlanVersion != 1 || (batch.photos[index].shot?.motion ?? batch.motion) == motion' in block(view,'nonisolated private static func makeClip(')
assert '@State private var cameraMove: ReelCameraMove? = nil' in view
assert '@State private var bigCaptionsOn = false' in view and '@State private var captionsOn = false' in view
assert 'voiceMode = .aiVoice' not in reel[reel.index('.onAppear {'):reel.index('.onDisappear {')]
assert 'voiceMode != .off && wordCaptionsOn' in block(reel,'private func snapshotReelConfiguration()')
assert 'voiceMode != .off && wordCaptionsOn' in generate
assert 'use motion from your original photo' not in view and 'we use motion from your selected photo' not in view
assert 'stepVoiceCard' not in block(view,'@ViewBuilder private var configuredSetupSection:')
assert 'stepVoiceCard' in block(view,'private var videoAdvancedControls:')
assert 'automaticOrder: automaticOrder' in view and 'let planning = draft.planningSetup' in view and 'automaticOrder = planning.automaticOrder' in view and 'var automaticOrder: Bool?' in draft
wire=block(live,'@MainActor func propertyVideoPlan(')
source=aspect+'\n'+planner
fixture=tests.replace("__ACTUAL_PLAN_WIRE__",wire)
receipt={'passed':False,'sourceHashes':before,'runs':[],'limitations':['Actual Foundation planner/order/cache and production call-site checks. Scene provider is a closed typed interface; no paid models, user photos, UI or Apple accessed.']}
variants=[('actual',source,fixture,None),
 ('twenty-photo-truncation',source.replace('let missing = inputs.filter { rows[$0.photoID] == nil }','let missing = Array(inputs.filter { rows[$0.photoID] == nil }.prefix(20))').replace('let row = rows[input.photoID]!','let row = rows[input.photoID] ?? PropertyVideoSceneRow(photoID:input.photoID,assetID:input.assetID,scene:.unknown,confidence:0,motion:.pushIn,seconds:5)'),fixture,'one hundred sources are classified in five bounded batches'),
 ('lost-uncertain-position',source.replace('photos.enumerated().filter { $0.element.confident }','photos.enumerated()').replace('return photos.map { $0.confident ? iterator.next()! : $0 }','return photos.map { _ in iterator.next()! }'),fixture,'uncertain scenes preserve their original absolute positions'),
 ('lost-byte-cache-binding',source.replace('input.jpegDigest])','"same bytes"])').replace('saved.input.jpegDigest == input.jpegDigest','true'),fixture,'changed JPEG bytes cannot reuse cached visual decisions'),
 ('accepted-partial-reply',source.replace('photos.count == requested.count','true').replace('Set(photos.map(\\.photoID)).count == photos.count','true').replace('let row = rows[input.photoID]!','let row = rows[input.photoID] ?? PropertyVideoSceneRow(photoID:input.photoID,assetID:input.assetID,scene:.unknown,confidence:0,motion:.pushIn,seconds:5)'),fixture,'invalid or unavailable batch falls back exactly once to complete original order'),
 ('lost-return-identity-fence',source.replace('try await requireCurrent()\n                let checked','// omitted return fence\n                let checked').replace('try await requireCurrent() // Never turn','// omitted error fence // Never turn').replace('        try await requireCurrent()\n        let planned','        // omitted final fence\n        let planned'),fixture,'account revocation must stop before applying a plan'),
 ('lost-restrained-unknown-motion',source.replace('confident ? motion.dispatchValue : "push_in"','motion.dispatchValue'),fixture,'uncertain scenes get restrained v1 motion and no invented room captions'),
 ('lost-wire-photo-set',source,fixture.replace('"photos": photos.map','"photos": photos.prefix(1).map'),'actual wire sends every exact private source reference without street, room claims or raw images'),
 ('lost-wire-return-fence',source,fixture.replace('try requireCurrent()\n        guard data.count','// omitted wire return fence\n        guard data.count'),'stale wire reply must reject before returning scenes')]
try:
 for name,code,test,expected in variants:
  assert expected is None or code!=source or test!=fixture,name+' mutation anchor missing'
  production=out/(name+'.swift');test_path=out/(name+'-tests.swift');binary=out/name
  production.write_text(code);test_path.write_text(test)
  c=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(production),str(test_path),'-o',str(binary)],capture_output=True,text=True,timeout=240)
  (out/(name+'-compile.log')).write_text(c.stdout+c.stderr);assert c.returncode==0,(name,c.stderr)
  r=subprocess.run([str(binary)],capture_output=True,text=True,timeout=60);output=r.stdout+r.stderr
  (out/(name+'.log')).write_text(output)
  valid=r.returncode==0 if expected is None else r.returncode!=0 and 'FAIL: '+expected in output
  receipt['runs'].append({'name':name,'exit':r.returncode,'expectedRejection':expected,'passed':valid});assert valid,(name,output)
 receipt['sourceHashesAtEnd']=hashes();receipt['passed']=before==receipt['sourceHashesAtEnd'];receipt['compiledNegativeControls']=len(variants)-1
finally:(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert receipt['passed'];print(json.dumps({'passed':True,'compiledNegativeControls':len(variants)-1,'receipt':str(out/'receipt.json')}))
