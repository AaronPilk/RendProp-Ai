#!/usr/bin/env python3
"""Compile actual listing toggle/action gates with durable history, no UI/network."""
import argparse, hashlib, json, re, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', type=Path); args = p.parse_args()
OUT = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-selection-'))
OUT.mkdir(parents=True, exist_ok=True)
VIEW = ROOT / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
HISTORY = ROOT / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift'
CAPTURE = ROOT / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift'
sources = [VIEW, HISTORY, CAPTURE, Path(__file__).resolve()]
hashes = lambda: {str(x.relative_to(ROOT)): hashlib.sha256(x.read_bytes()).hexdigest() for x in sources}
before = hashes(); view = VIEW.read_text(); history = HISTORY.read_text()

def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor); i = text.index('{', start) + 1; depth = 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}'); i += 1
    return text[start:i]

review = block(view, 'struct PhotoCompareView: View {')
button = block(review, '@ViewBuilder private var useOnListingButton: some View {')
for required in ['PrimaryButton(title:', 'action: changeListingSelection)', 'isDisabled: listingSelectionDisabled', '"Remove from listing"', '.disabled(listingSelectionDisabled)', 'minHeight: 44', 'photoVersion.useOnListing']:
    assert required in button, required
save = block(review, 'private var savePhotoButton: some View {')
for required in ['SecondaryButton(title: "Save photo"', 'isDisabled: savePhotoDisabled', '.disabled(savePhotoDisabled)', 'minHeight: 44', 'photoVersion.download']:
    assert required in save, required
actual = '\n'.join(block(review, anchor).replace('private ', '', 1) for anchor in [
    'private var needsStagingReview:', 'private var needsCustomReview:',
    'private var listingSelectionDisabled:', 'private func changeListingSelection()'])

fixture = r'''
import Foundation
struct EnhancedPhoto {
    var id: String; var enhancedURL: URL; var originalURL: URL
    var savedVersion: PhotoVersionHistory.Version? {
        try? PhotoVersionHistory.load(directory: enhancedURL.deletingLastPathComponent()).versions[id]
    }
}
enum FileStore {
    static func relativePath(for url: URL) -> String { url.path }
    static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: path) }
}
struct Context { var isCurrent: Bool }
struct Listing { var id: UUID; var mainPhotoRelPath: String?; var serverShareURL: URL? = nil; var serverID: UUID? = nil; var cloudImported: Bool? = nil }
@MainActor final class Model {
    var listings: [Listing]
    init(_ listing: Listing) { listings = [listing] }
    func setMainPhoto(_ path: String?, for id: UUID) { listings[0].mainPhotoRelPath = path }
    func syncGalleryPhotos(listingLocalID: UUID, listingServerID: UUID) async {}
}
@MainActor final class Harness {
    var viewed: EnhancedPhoto; var model: Model
    var imageContext: Context? = Context(isCurrent: true)
    var selectedForListing = true; var requestedCover = false; var dismissed = false
    var selectionWorkID: UUID?
    var enhanced: Data?; var original: Data?; var selectionError: String?
    var stagingReview = PhotoVersionHistory.StagingReview()
    var customReview = PhotoVersionHistory.CustomReview()
    init(_ photo: EnhancedPhoto, _ model: Model) { viewed = photo; self.model = model }
    func clearAndDismiss() { dismissed = true }
    func beginCloudListingRemoval(listingID: UUID, serverID: UUID, directory: URL, versionID: String) { fatalError("cloud removal belongs to separate API/coordinator proof") }
__ACTUAL__
}
@main struct Checks {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); count += 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("owned-image".utf8), listing = UUID(uuidString: dir.lastPathComponent)!
        for id in ["a", "b"] { try PhotoVersionHistory.saveCapture(original: bytes, enhanced: bytes, id: id, directory: dir) }
        let a = EnhancedPhoto(id: "a", enhancedURL: dir.appendingPathComponent("enh-a.jpg"), originalURL: dir.appendingPathComponent("orig-a.jpg"))
        let b = EnhancedPhoto(id: "b", enhancedURL: dir.appendingPathComponent("enh-b.jpg"), originalURL: dir.appendingPathComponent("orig-b.jpg"))
        let model = Model(.init(id: listing, mainPhotoRelPath: a.enhancedURL.path))
        let stale = Harness(a, model); stale.imageContext = Context(isCurrent: false)
        check(stale.listingSelectionDisabled, "stale context disables selection")
        stale.changeListingSelection()
        check(stale.dismissed && (try? PhotoVersionHistory.load(directory: dir).isSelectedForListing("a")) == true, "stale account cannot modify a listing selection")
        let first = Harness(a, model)
        check(!first.listingSelectionDisabled, "selected photo can be removed without decoded pixels or new review")
        first.changeListingSelection()
        check(first.selectionError == nil && !first.selectedForListing, "actual footer action removes selection")
        check(model.listings[0].mainPhotoRelPath == b.enhancedURL.path, "actual footer replaces removed cover with remaining selected photo")
        check((try? PhotoVersionHistory.publicationVersions(directory: dir)?.map(\.id)) == ["b"], "publication after removal retains only selected sibling")
        let clean = try PhotoVersionHistory.saveEdit(jpeg: bytes, id: "a-clean", parentID: "a", sourceID: "a", edit: "declutter", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: dir)
        check((try? PhotoVersionHistory.load(directory: dir).isSelectedForListing(clean.id)) == false, "later automatic edit must not undo explicit listing removal")
        first.selectedForListing = false
        check(first.listingSelectionDisabled, "adding still requires loaded pixels")
        first.enhanced = bytes; first.original = bytes; first.requestedCover = true
        check(!first.listingSelectionDisabled, "adding a retained plain version is available")
        first.changeListingSelection()
        check(first.selectionError == nil && first.selectedForListing, "explicit re-add succeeds")
        check(model.listings[0].mainPhotoRelPath == a.enhancedURL.path, "explicit requested cover is restored")
        try PhotoVersionHistory.selectForPublication(id: clean.id, directory: dir)
        first.changeListingSelection()
        check((try? PhotoVersionHistory.load(directory: dir).isSelectedForListing(clean.id)) == true && first.selectionError != nil, "stale sheet never replaces a newer selected version")
        let stage = try PhotoVersionHistory.saveEdit(jpeg: bytes, id: "a-stage", parentID: clean.id, sourceID: clean.id, edit: "stage", style: "modern", disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: dir)
        let stagePhoto = EnhancedPhoto(id: stage.id, enhancedURL: dir.appendingPathComponent(stage.imageFile), originalURL: a.originalURL)
        let addStage = Harness(stagePhoto, model); addStage.selectedForListing = false; addStage.enhanced = bytes; addStage.original = bytes
        check(addStage.listingSelectionDisabled, "unreviewed staging stays disabled when adding")
        addStage.changeListingSelection()
        check(addStage.selectionError != nil && (try? PhotoVersionHistory.load(directory: dir).isSelectedForListing(stage.id)) == false, "actual add action cannot bypass staging review")
        addStage.stagingReview = .init(comparedSource: true, fixedFeaturesMatch: true, accessIsClear: true, furnitureMatchesOtherViews: true)
        addStage.selectionError = nil; addStage.changeListingSelection()
        check(addStage.selectedForListing && addStage.selectionError == nil, "reviewed alternate version can replace existing selected version")
        addStage.stagingReview = .init(); addStage.enhanced = nil; addStage.original = nil
        check(!addStage.listingSelectionDisabled, "selected staging removal does not demand repeat comparison")
        addStage.changeListingSelection()
        check(!addStage.selectedForListing && addStage.selectionError == nil, "selected staged family is removed while review controls are unchecked")
        let last = Harness(b, model); last.changeListingSelection()
        check((try? PhotoVersionHistory.load(directory: dir).listingSelections?.isEmpty) == true, "last removal keeps an explicit empty gallery selection")
        check((try? PhotoVersionHistory.publicationVersions(directory: dir)?.isEmpty) == true && model.listings[0].mainPhotoRelPath == nil, "last selected photo removal clears cover and cannot revive legacy defaults")
        check((try? Data(contentsOf: a.originalURL)) == bytes && (try? Data(contentsOf: stagePhoto.enhancedURL)) == bytes, "footer removal retains original and edited bytes")
        print("PASS \(count) actual listing-selection checks")
    }
}
'''
variants = [('actual', actual, history, None),
    ('stale-context', actual.replace('guard imageContext?.isCurrent == true else { clearAndDismiss(); return }', 'guard true else { clearAndDismiss(); return }'), history, 'stale account cannot modify a listing selection'),
    ('removal-needs-decode', actual.replace('if selectedForListing { return false }', 'if selectedForListing { return true }'), history, 'selected photo can be removed without decoded pixels or new review'),
    ('edit-reincludes', actual, history.replace('index.excludedListingFamilies?.insert(version.familyID)', '// dropped exclusion'), 'later automatic edit must not undo explicit listing removal'),
    ('nil-gallery', actual, history.replace('index.listingSelections?.removeValue(forKey: version.familyID)', 'index.listingSelections = nil'), 'last removal keeps an explicit empty gallery selection')]
results = []
for name, body, local_history, reason in variants:
    folder = OUT / name; folder.mkdir(exist_ok=True)
    swift = folder / 'Checks.swift'; swift.write_text(fixture.replace('__ACTUAL__', body))
    history_path = folder / 'History.swift'; history_path.write_text(local_history)
    binary = folder / 'checks'
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(CAPTURE), str(history_path), str(swift), '-o', str(binary)], capture_output=True, text=True, timeout=90)
    (folder / 'compile.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, name + ': ' + build.stderr
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30); log = run.stdout + run.stderr
    (folder / 'runtime.log').write_text(log)
    assert (run.returncode == 0 and 'PASS ' in log) if reason is None else (run.returncode != 0 and reason in log), name + ': ' + log
    results.append({'name': name, 'compileExit': build.returncode, 'runtimeExit': run.returncode, 'expectedFailure': reason})
    print(name + ': PASS', flush=True)
assert hashes() == before
receipt = {'passed': True, 'sourceHashes': before, 'results': results, 'compiledControls': len(variants)-1,
           'scope': 'Actual PhotoCompare toggle/disabled-gate declarations plus real persisted PhotoVersionHistory. Decode, model cover setter and gallery sync are closed boundaries; no UIKit/phone/network/purchase/provider execution.'}
(OUT / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(OUT / 'receipt.json')
