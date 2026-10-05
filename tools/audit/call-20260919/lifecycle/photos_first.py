#!/usr/bin/env python3
"""Execute actual photos-first and video draft transitions at closed boundaries.

Current source includes the real form, identity snapshots/predicate, edit-intent
helper and model modification code. Historical --revision remains a reproduction
of the original photos-first correction defect, with an explicitly smaller form
and model boundary. Neither path exercises a camera or production service.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from run import ROOT, block


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def historical_code(source_text):
    actual = block(source_text, "    private func startWithPhotos()")
    code = r'''
import Foundation
struct Coordinate { var latitude: Double; var longitude: Double }
struct Listing { var id = UUID(); var address: String; var latitude: Double?; var longitude: Double? }
struct Form {
    var address = ""
    var isValid: Bool { !address.isEmpty }
    func apply(to listing: inout Listing) { listing.address = address }
    func makeListing(coordinate: Coordinate?) -> Listing {
        Listing(address: address, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
    }
}
final class Model {
    var listings: [Listing] = []
    func add(_ listing: Listing) { listings.append(listing) }
    func modify(_ id: UUID, sync: Bool, _ mutation: (inout Listing) -> Void) {
        if let i = listings.firstIndex(where: { $0.id == id }) { mutation(&listings[i]) }
    }
}
enum SpaceType: String { case realEstate; static let current = SpaceType.realEstate }
enum Analytics { static func track(_ name: String, _ attributes: [String: String]) {} }
enum Haptics { static func selection() {} }
final class Flow {
    let model = Model()
    var form = Form()
    var addressFocused = false
    var photosListing: Listing?
    var createdListing: Listing?
    var goToPhotos = false
    var pendingCoord: Coordinate?
__ACTUAL__
    func tap() { startWithPhotos() }
}
@main struct Checks {
    static func main() throws {
        let flow = Flow()
        flow.tap()
        precondition(flow.addressFocused && flow.model.listings.isEmpty)
        flow.form.address = "100 Original Avenue"
        flow.pendingCoord = Coordinate(latitude: 27.7, longitude: -82.6)
        flow.tap()
        let id = flow.model.listings[0].id
        precondition(flow.goToPhotos && flow.model.listings.count == 1)
        flow.tap()
        precondition(flow.model.listings.count == 1, "Repeated tap must not duplicate listing")
        flow.goToPhotos = false
        flow.form.address = "200 Corrected Avenue"
        flow.pendingCoord = Coordinate(latitude: 28.0, longitude: -82.0)
        flow.tap()
        let stored = flow.model.listings[0]
        precondition(stored.id == id && stored.address == "100 Original Avenue" && stored.latitude == 27.7)
        precondition(flow.photosListing?.address == "100 Original Avenue")
        let result: [String: Any] = ["empty_form_blocks":true,"repeated_tap_duplicates":false,
            "entered_address":flow.form.address,"stored_address":stored.address,
            "destination_address":flow.photosListing!.address,"stored_latitude":stored.latitude!,
            "changed_latitude":flow.pendingCoord!.latitude,"corrected_form_discarded":true]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
    }
}
'''.replace("__ACTUAL__", actual)
    return code


def current_code(source_text, app_text, fault):
    photo = block(source_text, "    private func startWithPhotos()")
    creation_region = source_text[:source_text.index("// MARK: - Video source picker")]
    receive = block(creation_region, "    private func receive(_ asset: CaptureAsset)")
    helper = block(source_text, "    private func applyExistingEdits(")
    predicate = block(source_text, "    private var formContextIsCurrent: Bool")
    snapshots = []
    for name in ["formOwnerID", "formSessionRevision", "formWorkspaceID"]:
        matches = re.findall(r"^    @State private var " + name + r" = .+$", source_text, re.MULTILINE)
        assert len(matches) == 1, f"Expected exactly one actual {name} initializer"
        snapshots.append(matches[0].replace("@State private ", ""))
    if fault == "discard-edits":
        needle = "            form.applyEdits(from: originalForm, to: &$0)"
        assert helper.count(needle) == 1
        helper = helper.replace(needle, "            _ = originalForm // injected loss of entered corrections")
    elif fault:
        needle = "guard form.isValid, formContextIsCurrent else"
        selected = photo if fault == "photos-context" else receive
        assert selected.count(needle) == 1
        selected = selected.replace(needle, "guard form.isValid else")
        if fault == "photos-context": photo = selected
        else: receive = selected
    code = CURRENT_TEMPLATE
    for token, actual in [
        ("__UNIT__", block(source_text, "enum ListingUnitAddress")),
        ("__FORM__", block(source_text, "struct ListingFormData: Equatable")),
        ("__SNAPSHOTS__", "\n".join(snapshots)), ("__PREDICATE__", predicate),
        ("__PHOTO__", photo), ("__RECEIVE__", receive), ("__HELPER__", helper),
        ("__MODIFY__", block(app_text, "    func modify(_ id: UUID,")),
    ]:
        assert code.count(token) == 1, token
        code = code.replace(token, actual)
    return code


CURRENT_TEMPLATE = r'''
import Foundation
struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double }
struct CaptureAsset { var localURL: URL; var motionSidecarURL: URL? }
enum FileStore {
    static var removed: [URL] = []
    static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/isolated/" + path) }
    static func removeVideoAndPreview(_ url: URL) { removed.append(url) }
}
enum Config { static let useLiveBackend = true }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID(uuidString: "22222222-2222-4222-8222-222222222222") }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "11111111-1111-4111-8111-111111111111"
    var syncSessionRevision: UInt64 = 1
}
enum Analytics { static func track(_ name: String, _ attributes: [String: String]) {} }
enum Haptics { static func selection() {} }
__UNIT__
__FORM__
@MainActor final class Model {
    var listings: [Listing] = []
    var assets: [UUID: CaptureAsset] = [:]
    var tours: [UUID: String] = [:]
    var syncWrites = 0
    func index(of id: UUID) -> Int? { listings.firstIndex { $0.id == id } }
    func add(_ listing: Listing) { listings.append(listing) }
    func syncListing(_ id: UUID) async { syncWrites += 1 }
__MODIFY__
}
@MainActor final class Flow {
    let model = Model()
    var form = ListingFormData()
    var pendingCoord: CLLocationCoordinate2D?
    var addressFocused = false
    var photosListing: Listing?
    var createdListing: Listing?
    var pendingAsset: CaptureAsset?
    var goToPhotos = false
    var goToReview = false
__SNAPSHOTS__
__PREDICATE__
__PHOTO__
__RECEIVE__
__HELPER__
    func act(_ entry: String) {
        if entry == "photos" { startWithPhotos() }
        else { receive(CaptureAsset(localURL: URL(fileURLWithPath: "/isolated/retained.mov"))) }
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name); count += 1
        }
        func reset() {
            AuthStore.shared.userID = "11111111-1111-4111-8111-111111111111"
            AuthStore.shared.syncSessionRevision = 1
            WorkspaceContext.selectedOrgID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")
            FileStore.removed = []
        }
        func seed(_ flow: Flow, _ kind: String) -> Listing? {
            guard kind != "fresh" else { return nil }
            var original = Listing(address: "100 Original Avenue", beds: 2, baths: 1, sqft: 900, price: Money(cents: 100))
            original.serverID = UUID()
            original.serverOrgID = WorkspaceContext.selectedOrgID
            original.needsServerSync = false
            original.mainPhotoRelPath = "Photos/retained.jpg"
            original.latitude = 27.7; original.longitude = -82.6
            flow.model.listings = [original]
            flow.createdListing = original
            if kind == "photos_draft" { flow.photosListing = original }
            flow.model.assets[original.id] = CaptureAsset(localURL: URL(fileURLWithPath: "/isolated/retained.mov"))
            flow.form = ListingFormData(listing: original)
            return original
        }
        for entry in ["photos", "receive"] {
            reset()
            let empty = Flow()
            empty.act(entry)
            check(empty.model.listings.isEmpty && empty.model.assets.isEmpty, "\(entry): empty form creates no listing or asset")
            check(!empty.goToPhotos && !empty.goToReview && empty.pendingAsset == nil, "\(entry): empty form must not navigate")
            check(empty.addressFocused == (entry == "photos"), "\(entry): blocked feedback follows the actual consumer")
            for draft in ["fresh", "photos_draft", "video_draft"] {
                reset()
                let flow = Flow()
                let original = seed(flow, draft)
                flow.form.address = "200 Corrected Avenue"
                flow.pendingCoord = CLLocationCoordinate2D(latitude: 28.0, longitude: -82.0)
                flow.act(entry)
                let label = "\(entry)/matching/\(draft)"
                check(flow.model.listings.count == 1, "\(label): exactly one listing")
                let saved = flow.model.listings[0]
                check(saved.address == "200 Corrected Avenue", "\(label): entered correction must reach retained listing")
                check(saved.latitude == 28.0 && saved.longitude == -82.0, "\(label): newly chosen coordinate must survive")
                check(flow.createdListing?.id == saved.id, "\(label): created destination retains actual identity")
                check(flow.goToPhotos == (entry == "photos") && flow.goToReview == (entry == "receive"), "\(label): correct destination opens")
                check(flow.pendingAsset?.localURL == (entry == "receive" ? URL(fileURLWithPath: "/isolated/retained.mov") : nil), "\(label): selected video is attached only by video consumer")
                if let original {
                    check(saved.id == original.id && saved.serverID == original.serverID, "\(label): reuse retains local and server identity")
                    check(saved.mainPhotoRelPath == original.mainPhotoRelPath, "\(label): reuse preserves original photo")
                    check(saved.needsServerSync == true, "\(label): corrected facts remain queued for sync")
                    check(saved.factsSync?.fields["address"]?.value == .text("200 Corrected Avenue"), "\(label): actual model stages typed edit intent")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
                check(flow.model.syncWrites == (original == nil ? 0 : 1), "\(label): reuse dispatches exactly one write")
                check(FileStore.removed.isEmpty, "\(label): unchanged source video must not be removed")
            }
        }
        reset()
        let repeated = Flow()
        repeated.form.address = "300 Original Avenue"
        repeated.act("photos")
        let firstID = repeated.model.listings[0].id
        repeated.act("photos")
        check(repeated.model.listings.count == 1 && repeated.photosListing?.id == firstID, "Repeated photo entry must not duplicate listing")
        repeated.model.listings = []
        repeated.act("photos")
        check(repeated.model.listings.count == 1 && repeated.model.listings[0].id != firstID, "Deleted photo draft must never be resurrected")
        for entry in ["photos", "receive"] {
            for change in ["account_switch", "session_revision", "workspace_switch", "workspace_removed", "live_without_workspace"] {
                for draft in ["fresh", "photos_draft", "video_draft"] {
                    reset()
                    if change == "live_without_workspace" { WorkspaceContext.selectedOrgID = nil }
                    let flow = Flow()
                    _ = seed(flow, draft)
                    flow.form.address = "400 Unsubmitted Avenue"
                    flow.pendingCoord = CLLocationCoordinate2D(latitude: 28.8, longitude: -82.8)
                    switch change {
                    case "account_switch": AuthStore.shared.userID = "33333333-3333-4333-8333-333333333333"
                    case "session_revision": AuthStore.shared.syncSessionRevision += 1
                    case "workspace_switch": WorkspaceContext.selectedOrgID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")
                    case "workspace_removed": WorkspaceContext.selectedOrgID = nil
                    default: break
                    }
                    let before = flow.model.listings
                    let beforeAssets = flow.model.assets.mapValues { $0.localURL }
                    let beforeCreated = flow.createdListing; let beforePhotos = flow.photosListing
                    let beforeForm = flow.form
                    let label = "\(entry)/\(change)/\(draft)"
                    flow.act(entry)
                    check(flow.model.listings == before, "\(label): stale context must not create or change a listing")
                    check(flow.model.assets.mapValues { $0.localURL } == beforeAssets, "\(label): stale context preserves retained assets")
                    check(flow.createdListing == beforeCreated && flow.photosListing == beforePhotos, "\(label): stale context preserves draft snapshots")
                    check(flow.pendingAsset == nil && !flow.goToPhotos && !flow.goToReview, "\(label): stale context must not attach a video or navigate")
                    check(flow.form == beforeForm && flow.pendingCoord?.latitude == 28.8 && flow.pendingCoord?.longitude == -82.8, "\(label): unsubmitted form remains intact")
                    try await Task.sleep(nanoseconds: 1_000_000)
                    check(flow.model.syncWrites == 0 && FileStore.removed.isEmpty, "\(label): stale context must not write or remove source")
                }
            }
            for draft in ["photos_draft", "video_draft"] {
                reset()
                let flow = Flow(); _ = seed(flow, draft)
                flow.model.listings[0].serverOrgID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")
                let before = flow.model.listings
                flow.form.address = "500 Rejected Correction Avenue"
                flow.act(entry)
                check(flow.model.listings == before, "\(entry)/\(draft): actual helper rejects foreign server workspace")
                check(!flow.goToPhotos && !flow.goToReview && flow.pendingAsset == nil, "\(entry)/\(draft): foreign draft must not navigate")
                try await Task.sleep(nanoseconds: 1_000_000)
                check(flow.model.syncWrites == 0 && FileStore.removed.isEmpty, "\(entry)/\(draft): foreign draft must not write or remove source")
            }
        }
        reset()
        print("PASSED: \(count) photos-first and video draft/context assertions")
    }
}
'''


def main():
    target = ROOT / "apps/ios/Rendprop/Screens/NewListingView.swift"
    app_path = ROOT / "apps/ios/Rendprop/RendpropApp.swift"
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--revision", help="Reproduce the original photos-first defect from an actual Git revision")
    modes.add_argument("--inject-fault", choices=["discard-edits", "photos-context", "receive-context"])
    parser.add_argument("--output-directory", type=Path)
    args = parser.parse_args()
    if args.output_directory:
        out = args.output_directory.resolve(); out.mkdir(parents=True, exist_ok=True)
        if any(out.iterdir()): parser.error("The output directory must be empty")
    else:
        out = Path(tempfile.mkdtemp(prefix="rendprop-call-photos-first-"))
    if args.revision:
        source_text = subprocess.check_output(["git", "show", f"{args.revision}:{target.relative_to(ROOT)}"], cwd=ROOT, text=True)
        code = historical_code(source_text)
        sources = []
        inputs = [Path(__file__).resolve(), ROOT / "tools/audit/call-20260919/lifecycle/run.py"]
        scope = "Actual historical startWithPhotos; in-memory model/form boundary reproduces discarded correction. No current-context claim."
    else:
        source_text = target.read_text()
        code = current_code(source_text, app_path.read_text(), args.inject_fault)
        sources = [ROOT / ("apps/ios/Rendprop/" + name) for name in [
            "Models/Listing.swift", "Models/ListingClientContact.swift", "Models/Money.swift", "Networking/WorkspaceSync.swift",
            "Networking/NativeReelDraft.swift", "Push/NotificationPrefs.swift", "Voice/VoiceTypes.swift",
        ]]
        inputs = sources + [target, app_path, Path(__file__).resolve(), ROOT / "tools/audit/call-20260919/lifecycle/run.py"]
        scope = "Actual creation consumers, form snapshot initializers/predicate/edit helper and model modify with actual Listing/form models; closed Auth/workspace/capture/sync boundaries."
    generated = out / "PhotosFirst.swift"; binary = out / "photos-first"
    generated.write_text(code)
    hashes = {str(p.relative_to(ROOT)): sha(p) for p in inputs}
    receipt = {"passed": False, "compiled": False, "hardware_validation": False, "revision": args.revision,
               "injected_fault": args.inject_fault, "source": str(target.relative_to(ROOT)),
               "sha256": hashlib.sha256(source_text.encode()).hexdigest(), "source_sha256": hashes,
               "generatedHarnessSha256": sha(generated), "scope": scope, "commands": []}
    receipt_path = out / "receipt.json"
    print("EVIDENCE:", out, flush=True)
    try:
        for label, command in [
            ("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, sources), str(generated), "-o", str(binary)]),
            ("execute", [str(binary)]),
        ]:
            result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
            (out / (label + ".log")).write_text(result.stdout)
            receipt["commands"].append({"label": label, "exit": result.returncode, "command": command})
            if label == "compile": receipt["compiled"] = result.returncode == 0
            if label == "execute":
                expected = {
                    "discard-edits": "photos/matching/photos_draft: entered correction must reach retained listing",
                    "photos-context": "photos/account_switch/fresh: stale context must not create or change a listing",
                    "receive-context": "receive/account_switch/fresh: stale context must not create or change a listing",
                }.get(args.inject_fault)
                receipt["expectedFaultAssertion"] = expected
                receipt["expectedFaultAssertionRejected"] = bool(expected and receipt["compiled"] and result.returncode != 0 and expected in result.stdout)
                if result.returncode == 0:
                    if args.revision: receipt["results"] = json.loads(result.stdout)
                    else:
                        matches = re.findall(r"PASSED: (\d+) ", result.stdout)
                        assert len(matches) == 1, "Expected one actual assertion summary"
                        receipt["assertionsPassed"] = int(matches[0])
            print(label, result.returncode, result.stdout[-4000:] if result.returncode == 0 or label == "compile" else "Compiled acceptance assertion rejected", flush=True)
            if result.returncode: raise SystemExit(1)
        receipt["sourceBoundAtEnd"] = hashes == {str(p.relative_to(ROOT)): sha(p) for p in inputs}
        if not receipt["sourceBoundAtEnd"]: raise RuntimeError("Source drift while testing")
        receipt["passed"] = True
        receipt["completed"] = True
    finally:
        receipt["sourceBoundAtEnd"] = hashes == {str(p.relative_to(ROOT)): sha(p) for p in inputs}
        if not receipt["sourceBoundAtEnd"]: receipt["passed"] = False
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__": main()
