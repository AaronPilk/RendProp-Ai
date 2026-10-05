#!/usr/bin/env python3
"""Execute draft-reuse transitions against the real dirty-write and cloud merge code.

Only UI, network and capture-asset boundaries are doubles. No camera, provider,
production data or filesystem removal is exercised. --inject-fault restores the
missing dirty-write bug and must fail the same acceptance assertions.
--inject-context-fault removes one real creation consumer's account/workspace
guard; the unchanged stale-context checks must reject that compiled mutation.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("lifecycle", ROOT / "tools/audit/call-20260919/lifecycle/run.py")
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


def main():
    parser = argparse.ArgumentParser()
    faults = parser.add_mutually_exclusive_group()
    faults.add_argument("--inject-fault", action="store_true")
    faults.add_argument("--inject-context-fault", choices=["photos", "receive"])
    parser.add_argument("--output-directory", type=Path)
    args = parser.parse_args()
    if args.output_directory:
        out = args.output_directory.resolve()
        out.mkdir(parents=True, exist_ok=True)
        if any(out.iterdir()):
            parser.error("The output directory must be empty")
    else:
        out = Path(tempfile.mkdtemp(prefix="rendprop-photos-cloud-sync-"))
    new_path = ROOT / "apps/ios/Rendprop/Screens/NewListingView.swift"
    app_path = ROOT / "apps/ios/Rendprop/RendpropApp.swift"
    new, app = new_path.read_text(), app_path.read_text()
    photo = lifecycle.block(new, "    private func startWithPhotos()")
    # NewListingView and AddVideoSheet each own a receive method. Select the
    # creation view's source region before extracting its exact method body.
    receive = lifecycle.block(new[:new.index("// MARK: - Video source picker")], "    private func receive(_ asset: CaptureAsset)")
    reuse = lifecycle.block(new, "    private func applyExistingEdits(")
    context = lifecycle.block(new, "    private var formContextIsCurrent: Bool")
    snapshots = []
    for name in ["formOwnerID", "formSessionRevision", "formWorkspaceID"]:
        matches = re.findall(r"^    @State private var " + name + r" = .+$", new, re.MULTILINE)
        assert len(matches) == 1, f"Expected one actual {name} snapshot declaration"
        snapshots.append(matches[0].replace("@State private ", ""))
    unit_address = lifecycle.block(new, "enum ListingUnitAddress")
    form = lifecycle.block(new, "struct ListingFormData: Equatable")
    if args.inject_fault:
        # The three real reuse branches now share one actual form-intent helper.
        # Disable its dirty staging/dispatch to restore the original regression.
        needle = "model.modify(existing.id, expectedFacts: existing)"
        assert photo.count("applyExistingEdits(existing)") == 2 and receive.count("applyExistingEdits(existing)") == 1
        assert reuse.count(needle) == 1
        reuse = reuse.replace(needle, "model.modify(existing.id, sync: false, expectedFacts: existing)")
    if args.inject_context_fault:
        needle = "guard form.isValid, formContextIsCurrent else"
        selected = photo if args.inject_context_fault == "photos" else receive
        assert selected.count(needle) == 1, "Mutate exactly the selected creation consumer"
        selected = selected.replace(needle, "guard form.isValid else")
        if args.inject_context_fault == "photos":
            photo = selected
        else:
            receive = selected
    modify = lifecycle.block(app, "    func modify(_ id: UUID,")
    dirty = lifecycle.block(app, "    func markDirty(_ id: UUID)")
    sources = [ROOT / ("apps/ios/Rendprop/" + name) for name in [
        "Models/Listing.swift", "Models/ListingClientContact.swift", "Models/Money.swift", "Networking/WorkspaceSync.swift",
        "Networking/NativeReelDraft.swift", "Push/NotificationPrefs.swift", "Voice/VoiceTypes.swift",
    ]]
    swift = r'''
import Foundation
enum FileStore {
    static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/isolated/\(path)") }
    static func removeVideoAndPreview(_ url: URL) { preconditionFailure("This test must not remove a source") }
}
struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double }
typealias Coordinate = CLLocationCoordinate2D
struct CaptureAsset { var localURL: URL; var motionSidecarURL: URL? }
enum Config { static let useLiveBackend = true }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID(uuidString: "22222222-2222-4222-8222-222222222222") }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "11111111-1111-4111-8111-111111111111"
    var syncSessionRevision: UInt64 = 1
}
__UNIT_ADDRESS__
__FORM__
enum Analytics { static func track(_ name: String, _ attributes: [String: String]) {} }
enum Haptics { static func selection() {} }
@MainActor final class Model {
    var listings: [Listing] = []; var writes = 0
    var assets: [UUID: CaptureAsset] = [:]; var tours: [UUID: String] = [:]
    func add(_ listing: Listing) { listings.append(listing) }
    func index(of id: UUID) -> Int? { listings.firstIndex { $0.id == id } }
    func syncListing(_ id: UUID) async { writes += 1 }
__MODIFY__
__DIRTY__
}
@MainActor final class Flow {
    let model = Model(); var form = ListingFormData(); var addressFocused = false
__SNAPSHOTS__
    var photosListing: Listing?; var createdListing: Listing?; var pendingCoord: Coordinate?
    var goToPhotos = false; var goToReview = false; var pendingAsset: CaptureAsset?
__CONTEXT__
__PHOTO__
__RECEIVE__
__REUSE__
    func photoTap() { startWithPhotos() }
    func videoReceived() { receive(CaptureAsset(localURL: URL(fileURLWithPath: "/isolated/new.mov"))) }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) {
            precondition(value(), reason); count += 1
        }
        func resetContext() {
            AuthStore.shared.userID = "11111111-1111-4111-8111-111111111111"
            AuthStore.shared.syncSessionRevision = 1
            WorkspaceContext.selectedOrgID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        }
        for scenario in ["photos_reused", "video_draft_to_photos", "video_draft_reused"] {
            resetContext()
            let flow = Flow()
            var original = Listing(address: "Original address", beds: 2, baths: 1, sqft: 900, price: Money(cents: 100))
            original.serverID = UUID(); original.serverOrgID = WorkspaceContext.selectedOrgID; original.needsServerSync = false
            original.mainPhotoRelPath = "Photos/retained.jpg"
            flow.model.listings = [original]; flow.createdListing = original
            if scenario == "photos_reused" { flow.photosListing = original }
            flow.form = ListingFormData(listing: original)
            flow.form.address = "Corrected address"
            flow.pendingCoord = Coordinate(latitude: 28.0, longitude: -82.0)
            if scenario == "video_draft_reused" { flow.videoReceived() } else { flow.photoTap() }
            let corrected = flow.model.listings[0]
            check(corrected.needsServerSync == true, "\(scenario): corrected facts must be queued for sync")
            check(corrected.address == "Corrected address" && corrected.latitude == 28.0, "Corrected facts reach local draft")
            var remote = original; remote.id = original.serverID!
            let merged = try CloudListingMerge.merge(local: [corrected], remote: [remote], protected: [])[0]
            check(merged.address == "Corrected address" && merged.latitude == 28.0, "Old cloud snapshot must not erase correction")
            check(merged.id == original.id && merged.serverID == original.serverID, "Reuse same phone and cloud identities")
            check(merged.mainPhotoRelPath == original.mainPhotoRelPath, "Keep the original phone photo")
            check(flow.model.listings.count == 1, "Reuse must not duplicate listing")
            try await Task.sleep(nanoseconds: 1_000_000)
            check(flow.model.writes == 1, "Dispatch correction to existing sync loop exactly once")
        }
        for entry in ["photos", "receive"] {
            resetContext()
            let flow = Flow()
            flow.form.address = "100 New Listing Avenue"
            flow.pendingCoord = Coordinate(latitude: 27.7, longitude: -82.6)
            if entry == "photos" { flow.photoTap() } else { flow.videoReceived() }
            check(flow.model.listings.count == 1, "\(entry): matching context creates exactly one listing")
            let created = flow.model.listings[0]
            check(created.address == flow.form.address && created.latitude == 27.7,
                  "\(entry): matching context preserves entered facts")
            check(flow.createdListing?.id == created.id, "\(entry): destination retains the created draft")
            check(flow.goToPhotos == (entry == "photos") && flow.goToReview == (entry == "receive"),
                  "\(entry): matching context opens the requested destination")
            check(flow.model.assets.count == (entry == "receive" ? 1 : 0),
                  "\(entry): only the video path attaches an asset")
            check(flow.pendingAsset?.localURL == (entry == "receive" ? URL(fileURLWithPath: "/isolated/new.mov") : nil),
                  "\(entry): video review receives the selected asset")
            check(flow.photosListing?.id == (entry == "photos" ? created.id : nil),
                  "\(entry): the photo path keeps its own draft destination")
        }
        for entry in ["photos", "receive"] {
            for change in ["account_switch", "session_revision", "workspace_switch", "workspace_removed", "live_without_workspace"] {
                for draft in ["fresh", "photos_draft", "video_draft"] {
                    resetContext()
                    if change == "live_without_workspace" { WorkspaceContext.selectedOrgID = nil }
                    let flow = Flow()
                    flow.form.address = "100 Unsubmitted Avenue"
                    flow.pendingCoord = Coordinate(latitude: 28.0, longitude: -82.0)
                    if draft != "fresh" {
                        var original = Listing(address: "Retained original", beds: 2, baths: 1,
                                               sqft: 900, price: Money(cents: 100))
                        original.serverID = UUID(); original.serverOrgID = WorkspaceContext.selectedOrgID
                        original.needsServerSync = false; original.mainPhotoRelPath = "Photos/retained.jpg"
                        flow.model.listings = [original]; flow.createdListing = original
                        if draft == "photos_draft" { flow.photosListing = original }
                        flow.model.assets[original.id] = CaptureAsset(localURL: URL(fileURLWithPath: "/isolated/retained.mov"))
                    }
                    switch change {
                    case "account_switch": AuthStore.shared.userID = "33333333-3333-4333-8333-333333333333"
                    case "session_revision": AuthStore.shared.syncSessionRevision += 1
                    case "workspace_switch": WorkspaceContext.selectedOrgID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")
                    case "workspace_removed": WorkspaceContext.selectedOrgID = nil
                    default: break
                    }
                    let beforeListings = flow.model.listings
                    let beforeAssets = flow.model.assets.mapValues { $0.localURL }
                    let beforeCreated = flow.createdListing; let beforePhotos = flow.photosListing
                    let beforeForm = flow.form; let beforeCoord = flow.pendingCoord
                    let label = "\(entry)/\(change)/\(draft)"
                    if entry == "photos" { flow.photoTap() } else { flow.videoReceived() }
                    check(flow.model.listings == beforeListings,
                          "\(label): stale context must not create or change a listing")
                    check(flow.model.assets.mapValues { $0.localURL } == beforeAssets,
                          "\(label): stale context must not replace retained video")
                    check(flow.createdListing == beforeCreated && flow.photosListing == beforePhotos,
                          "\(label): retain draft identities and original facts")
                    check(flow.pendingAsset == nil && !flow.goToPhotos && !flow.goToReview,
                          "\(label): stale context must not attach video or navigate")
                    check(flow.form == beforeForm && flow.pendingCoord?.latitude == beforeCoord?.latitude
                          && flow.pendingCoord?.longitude == beforeCoord?.longitude,
                          "\(label): keep unsubmitted details for deliberate recovery")
                    check(flow.addressFocused == (entry == "photos"),
                          "\(label): preserve the actual blocked photo action feedback")
                    try await Task.sleep(nanoseconds: 1_000_000)
                    check(flow.model.writes == 0, "\(label): stale context must not dispatch a cloud write")
                }
            }
        }
        resetContext()
        print("PASSED: \(count) draft/cloud sync and account/workspace context assertions")
    }
}
'''
    for token, code in [("__MODIFY__", modify), ("__DIRTY__", dirty), ("__PHOTO__", photo), ("__RECEIVE__", receive), ("__REUSE__", reuse), ("__CONTEXT__", context), ("__SNAPSHOTS__", "\n".join(snapshots)), ("__UNIT_ADDRESS__", unit_address), ("__FORM__", form)]:
        swift = swift.replace(token, code)
    checks = out / "Checks.swift"
    checks.write_text(swift)
    input_paths = sources + [new_path, app_path, Path(__file__).resolve()]
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in input_paths}
    receipt = {"hardware_validation": False, "injected_fault": args.inject_fault,
               "injected_context_fault": args.inject_context_fault, "passed": False,
               "compiled": False, "sources": source_hashes,
               "generatedHarnessSha256": hashlib.sha256(checks.read_bytes()).hexdigest(), "commands": []}
    print("Evidence:", out, flush=True)
    for label, cmd in [("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, sources), str(checks), "-o", str(out / "checks")]), ("run", [str(out / "checks")])]:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        (out / f"{label}.log").write_text(result.stdout)
        receipt["commands"].append({"label": label, "exit_code": result.returncode, "command": cmd})
        receipt["sourceBoundAtEnd"] = source_hashes == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in input_paths}
        if label == "compile":
            receipt["compiled"] = result.returncode == 0
        if label == "run":
            receipt["passed"] = result.returncode == 0 and receipt["sourceBoundAtEnd"]
            receipt["expectedDirtyAssertionRejected"] = args.inject_fault and result.returncode != 0 and "photos_reused: corrected facts must be queued for sync" in result.stdout
            expected_context = f"{args.inject_context_fault}/account_switch/fresh: stale context must not create or change a listing"
            receipt["expectedContextAssertionRejected"] = bool(args.inject_context_fault) and result.returncode != 0 and expected_context in result.stdout and receipt["compiled"] and receipt["sourceBoundAtEnd"]
            matches = re.findall(r"PASSED: (\d+) ", result.stdout)
            receipt["assertionsPassed"] = int(matches[0]) if result.returncode == 0 and len(matches) == 1 else None
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(label, result.returncode, result.stdout[-2000:] if result.returncode == 0 or label == "compile" else "Acceptance assertion rejected compiled regression", flush=True)
        if result.returncode or not receipt["sourceBoundAtEnd"]:
            print("Evidence:", out)
            raise SystemExit(1)
    print("Evidence:", out)


if __name__ == "__main__":
    main()
