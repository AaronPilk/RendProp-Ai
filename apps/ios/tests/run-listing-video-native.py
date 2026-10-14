#!/usr/bin/env python3
"""Actual Foundation source storage and extracted native selection/publication.
Media files/network/Photos/StoreKit boundaries are closed. No UI or vendor calls.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', type=Path); a = p.parse_args()
out = (a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-listing-video-native-'))).resolve(); out.mkdir(parents=True, exist_ok=True)
paths = [ROOT / x for x in ['apps/ios/Rendprop/Models/ListingVideo.swift', 'apps/ios/Rendprop/Render/VideoAspectChoice.swift',
    'apps/ios/Rendprop/RendpropApp.swift', 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift',
    'apps/ios/Rendprop/Networking/APIClient.swift', 'apps/ios/Rendprop/Networking/LiveAPIClient.swift',
    'apps/ios/tests/ListingVideoNativeTests.swift', 'apps/ios/tests/run-listing-video-native.py']]
hashes = lambda: {str(x.relative_to(ROOT)): hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before = hashes(); metadata, aspect, app, view, api, live, fixture = [x.read_text() for x in paths[:-1]]
def block(text, anchor):
    start = text.index(anchor); opening = text.index('{', start); depth = 1; end = opening + 1
    while depth: depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]
methods = '\n'.join(block(app, x) for x in ['func selectWebsiteVideo(', 'private func publishSelectedWebsiteVideo('])
fixture = fixture.replace('__ACTUAL_MODEL_METHODS__', methods)
production = aspect + '\n' + metadata + '\n' + '\n'.join(block(api, x) for x in ['struct UploadMetadata:', 'struct PublishedTour:', 'enum APIError:'])
# Real completion must write metadata before retiring a recipe or its paid clips.
reel_view = block(view, 'struct ReelStudioView:')
for anchor, clear in [('private func generateWithSession()', 'batch?.clear()'), ('private func continueSavedBatch(', 'batch.clear()'), ('private func finishParkedReel()', 'pendingBatch?.clear()')]:
    body = block(reel_view, anchor); assert body.index('ListingVideoPreparation.retain(') < body.index(clear), anchor
assert 'source_asset_id' in live and 'source_provenance_id' in live and 'body["asset_id"] = source' in live
assert 'presentationKind == "photo_video"' in live and 'dto.presentationAssetId == assetID' in live
assert 'dto.publicationId.flatMap(UUID.init(uuidString:)) == publicationID' in live and 'photo-video:' in live
assert 'guard posterID != nil else' in methods
assert 'ordered = Self.reordered(chosen, by: plan)' in view and 'PropertyVideoPlanner.plan(' in view
assert 'selectedExtras = [] // Saved aerials' in view
assert block(reel_view, 'private func snapshotReelConfiguration()').count('VideoBrandingPolicy.titleCard(') == 1
for path in ['private func generateWithSession()', 'private func continueSavedBatch(', 'private func finishParkedReel()']:
    assert 'VideoBrandingPolicy.titleCard(' in block(reel_view, path), path
assert 'guard path != selected, path != pending' in block(view, 'nonisolated private static func pruneReels(')
receipt = {'passed': False, 'sourceHashes': before, 'runs': [], 'limitations': ['Actual Foundation hashing, filesystem and selection/publication methods. Encoded video/Uploads/API/Poster/StoreKit/UI are closed boundaries; no customer files, account or vendor accessed.']}
variants = [('actual', production, fixture, None),
    ('lost-byte-identity', production.replace('guard try digest(url) == record.sha256 else', 'guard true else'), fixture, 'changed bytes must refuse before upload'),
    ('lost-owner-fence', production.replace('record.ownerID == ownerID', 'true'), fixture, 'foreign owner must refuse'),
    ('lost-pending-pin', production, fixture.replace('try ListingVideoStore.pending(listingID: id, documents: FileStore.documents) == nil', 'true').replace('!pendingPublish.contains(id),', 'true,'), 'pending publication must keep its source'),
    ('automatic-publish-on-choice', production, fixture.replace('listings[i].websiteVideo = record', 'listings[i].websiteVideo = record\n        _ = try await publishSelectedWebsiteVideo(listingID: id)'), 'selecting a reviewed output remains local and performs no publication or upload'),
    ('lost-publication-operation', production.replace('return existing', 'return ListingVideoPublication(operationID: UUID(), record: existing.record, createdAt: Date(), posterAssetID: existing.posterAssetID, outputAssetID: existing.outputAssetID)').replace('saved.operationID == publication.operationID, saved.record == publication.record', 'saved.record == publication.record'), fixture, 'lost reply and relaunch preserve one publication operation'),
    ('lost-cover-receipt', production, fixture.replace('var posterID = publication.posterAssetID', 'var posterID: String? = nil'), 'lost reply reuses the immutable first-clip cover'),
    ('listing-brand-leak', production.replace('aspect == "9:16" ? requested : nil', 'requested'), fixture, 'listing composition removes a recovered brand while social settings keep it')]
try:
    for name, source, tests, rejection in variants:
        source_path = out / (name + '.swift'); fixture_path = out / (name + '-fixture.swift'); executable = out / name
        source_path.write_text(source); fixture_path.write_text(tests)
        compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(source_path), str(fixture_path), '-o', str(executable)], capture_output=True, text=True, timeout=240)
        (out / (name + '-compile.log')).write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode: raise RuntimeError(compiled.stderr)
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
        output = run.stdout + run.stderr; (out / (name + '.log')).write_text(output)
        valid = run.returncode == 0 if rejection is None else run.returncode != 0 and rejection in output
        receipt['runs'].append({'name': name, 'exit': run.returncode, 'expectedRejection': rejection, 'passed': valid})
        assert valid, output
    receipt['sourceHashesAtEnd'] = hashes(); receipt['passed'] = before == receipt['sourceHashesAtEnd']; receipt['compiledNegativeControls'] = len(variants) - 1
finally: (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed']; print(json.dumps({'passed': True, 'compiledNegativeControls': len(variants)-1, 'receipt': str(out / 'receipt.json')}))
