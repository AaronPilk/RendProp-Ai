#!/usr/bin/env python3
"""Compile actual raw-walkthrough policy and detail entrypoints with closed UI state."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--evidence-dir', type=Path)
a = p.parse_args()
out = (a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-room-tag-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
paths = [ROOT / x for x in [
    'apps/ios/Rendprop/Screens/FlythroughDetailView.swift', 'apps/ios/Rendprop/Models/CaptureAsset.swift',
    'apps/ios/Rendprop/Models/RoomTag.swift', 'apps/ios/tests/RoomTagWalkthroughTests.swift',
    'apps/ios/tests/run-room-tag-walkthrough.py']]
hashes = lambda: {str(x.relative_to(ROOT)): hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before = hashes()
view, capture, tag, tests, _ = [x.read_text() for x in paths]

def block(text, anchor):
    start = text.index(anchor)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

detail = block(view, 'struct FlythroughDetailView: View')
grid = block(view, 'private struct ListingToolboxGrid: View')
entry_anchors = [
    'private var hasCurrentRoomTagContext:', 'private var roomTagGeneratedURLs:', 'private var roomTagAsset:',
    'private var canTagRooms:', 'private func openRoomTags()', 'private func openWalkthroughForRoomTags()',
    'private var roomTagsBinding:']
def fragment_hashes(text):
    d = block(text, 'struct FlythroughDetailView: View')
    g = block(text, 'private struct ListingToolboxGrid: View')
    start = g.index('card: ListingToolCard(title: space == .realEstate ? "Tag rooms"')
    fragments = {'policy': block(text, 'enum RoomTagWalkthroughPolicy {'),
        'tile': g[start:g.index('if !sample, hasPublishedTour', start)],
        'sheet': block(d, '.sheet(isPresented: $showRoomTagger,'),
        'help': block(d, '.alert("Add a walkthrough first"'),
        'walkthroughRoute': block(d, '.navigationDestination(isPresented: $showWalkthroughForRoomTags)'),
        'sourceAvailability': block(d, '.task(id: asset)'),
        'tagDismissal': block(d, 'private func roomTaggerDismissed()')}
    fragments.update({anchor: block(d, anchor) for anchor in entry_anchors})
    return {key: hashlib.sha256(value.encode()).hexdigest() for key, value in fragments.items()}
fragments_before = fragment_hashes(view)
assert 'sub: sample ? createFirst : (canTagRooms ? "Tap-to-jump chapters" : "Add walkthrough first")' in grid
assert 'disabled: sample, accessibilityID: "detail.roomTags", action: openRoomTagger' in grid
assert 'dimmed: !canTagRooms || sample' in grid
assert 'openRoomTagger: { openRoomTags() }' in detail
assert '.sheet(isPresented: $showRoomTagger, onDismiss: roomTaggerDismissed) {\n            if let a = roomTagAsset {' in detail
assert '.navigationDestination(isPresented: $showWalkthroughForRoomTags)' in detail
assert 'if hasCurrentRoomTagContext { RecordedWalkthroughView(listing: currentListing) }' in detail
assert 'Button("Open walkthrough") { openWalkthroughForRoomTags() }' in detail
assert 'expectedScope == presentationScope' in block(detail, 'private func roomTaggerDismissed()')
fixture = '''
struct SpaceType { static let current = Self(); var quickTags:[String] { [] } }
enum FileStore { static var documents = URL(fileURLWithPath:"/closed") }
struct Binding<Value> { let get:()->Value; let set:(Value)->Void }
struct TagFixtureListing { let id:UUID; var isSample=false; var cloudUnavailable:Bool?=false; var aerialURL:URL?=nil }
final class TagFixtureModel { var listings:[TagFixtureListing]; var assets:[UUID:CaptureAsset]=[:]; var inSelectedWorkspace=true
    init(_ listing:TagFixtureListing) { listings=[listing] }
    func isInSelectedWorkspace(_ listing:TagFixtureListing)->Bool { inSelectedWorkspace }
}
struct TagFixtureTour { let url:URL }
final class RoomTagEntryFixture {
    let listing:TagFixtureListing; let model:TagFixtureModel
    init(listing:TagFixtureListing) { self.listing=listing;model=TagFixtureModel(listing) }
    var hasCurrentPresentationContext=true
    var currentListing:TagFixtureListing { model.listings.first(where:{$0.id==listing.id}) ?? listing }
    var asset:CaptureAsset? { model.assets[listing.id] }; var tour:TagFixtureTour?=nil
    var selectedWebsiteVideoURL:URL?=nil; var availableRoomTagAsset:CaptureAsset?=nil
    var showRoomTagger=false; var showRoomTagsWalkthroughHelp=false; var showWalkthroughForRoomTags=false
    var tagsBeforeEdit:[RoomTag]=[]
'''
actual = '\n'.join(block(detail, x).replace('private ', '') for x in entry_anchors)
production = 'import Foundation\n' + capture + '\n' + tag + '\n' + block(view, 'enum RoomTagWalkthroughPolicy {') + fixture + actual + '\n}\n'
receipt = {'passed': False, 'sourceHashes': before, 'sourceFragmentHashes': fragments_before, 'runs': [], 'limitations': [
    'Actual Foundation filesystem policy, CaptureAsset/RoomTag and extracted detail entrypoint/binding methods. UI layout and SwiftUI presentation require a separate real-device check; no backend, video decode, upload, AI or publication was executed.',
    'CaptureAsset has no origin field. Eligibility relies on existing canonical recorder/validated-local-import storage paths, exact stored file size and current listing scope; untyped cloud imports fail closed rather than treating a cloud render as raw footage.']}
variants = [('actual', production, None),
    ('generated-path-bypass', production.replace('guard isRecording || isImport else { return nil }', '// injected generated path bypass'),
     'generated, untyped cloud and sample paths do not qualify: Imports/cloud-'),
    ('sample-bypass', production.replace('guard isCurrent, !isSample, let asset', 'guard isCurrent, let asset'),
     'sample listing cannot unlock tags'),
    ('tap-bypass', production.replace('guard let source = roomTagAsset else {', 'guard let source = asset else {'),
     'actual entrypoint explains upload first for generated footage'),
    ('tag-write-bypass', production.replace('if var a = self.roomTagAsset {', 'if var a = self.model.assets[self.listing.id] {'),
     'generated timeline cannot be mutated through retained tag binding'),
    ('context-bypass', production.replace('guard hasCurrentRoomTagContext else { return }', '// injected context bypass'),
     'changed account cannot enqueue tagger, help or walkthrough presentation')]
try:
    for name, code, oracle in variants:
        assert oracle is None or code != production, name
        source = out / (name + '.swift'); source.write_text(code)
        binary = out / name
        c = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(source), str(paths[3]), '-o', str(binary)], capture_output=True, text=True, timeout=180)
        (out / (name + '-compile.log')).write_text(c.stdout + c.stderr)
        assert c.returncode == 0, (name, c.stderr)
        r = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        log = r.stdout + r.stderr
        (out / (name + '.log')).write_text(log)
        accepted = r.returncode == 0 if oracle is None else r.returncode != 0 and 'FAIL: ' + oracle in log
        receipt['runs'].append({'variant': name, 'exit': r.returncode, 'expectedRejection': oracle, 'passed': accepted})
        assert accepted, (name, log)
    receipt['sourceHashesAtEnd'] = hashes()
    receipt['sourceFragmentHashesAtEnd'] = fragment_hashes(paths[0].read_text())
    receipt['compiledNegativeControls'] = len(variants) - 1
    receipt['fullViewChangedOutsideOwnedFragments'] = before[str(paths[0].relative_to(ROOT))] != receipt['sourceHashesAtEnd'][str(paths[0].relative_to(ROOT))]
    receipt['passed'] = (all(before[str(path.relative_to(ROOT))] == receipt['sourceHashesAtEnd'][str(path.relative_to(ROOT))] for path in paths[1:])
                         and fragments_before == receipt['sourceFragmentHashesAtEnd'])
finally:
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'source changed during proof'
print(json.dumps({'passed': True, 'compiledNegativeControls': len(variants) - 1, 'receipt': str(out / 'receipt.json')}))
