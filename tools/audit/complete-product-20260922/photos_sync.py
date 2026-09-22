#!/usr/bin/env python3
"""Execute draft-reuse transitions against the real dirty-write and cloud merge code.

Only UI, network and capture-asset boundaries are doubles. No camera, provider,
production data or filesystem removal is exercised. --inject-fault restores the
missing dirty-write bug and must fail the same acceptance assertions.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("lifecycle", ROOT / "tools/audit/call-20260919/lifecycle/run.py")
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inject-fault", action="store_true")
    args = parser.parse_args()
    out = Path(tempfile.mkdtemp(prefix="rendprop-photos-cloud-sync-"))
    new_path = ROOT / "apps/ios/Rendprop/Screens/NewListingView.swift"
    app_path = ROOT / "apps/ios/Rendprop/RendpropApp.swift"
    new, app = new_path.read_text(), app_path.read_text()
    photo = lifecycle.block(new, "    private func startWithPhotos()")
    # NewListingView and AddVideoSheet each own a receive method. Select the
    # creation view's source region before extracting its exact method body.
    receive = lifecycle.block(new[:new.index("// MARK: - Video source picker")], "    private func receive(_ asset: CaptureAsset)")
    if args.inject_fault:
        assert photo.count("sync: true") == 2 and receive.count("sync: true") == 1
        photo = photo.replace("sync: true", "sync: false")
        receive = receive.replace("sync: true", "sync: false")
    modify = lifecycle.block(app, "    func modify(_ id: UUID,")
    dirty = lifecycle.block(app, "    func markDirty(_ id: UUID)")
    sources = [ROOT / ("apps/ios/Rendprop/" + name) for name in [
        "Models/Listing.swift", "Models/Money.swift", "Networking/WorkspaceSync.swift",
        "Networking/NativeReelDraft.swift", "Push/NotificationPrefs.swift", "Voice/VoiceTypes.swift",
    ]]
    swift = r'''
import Foundation
enum FileStore {
    static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/isolated/\(path)") }
    static func removeVideoAndPreview(_ url: URL) { preconditionFailure("This test must not remove a source") }
}
struct Coordinate { var latitude: Double; var longitude: Double }
struct CaptureAsset { var localURL: URL; var motionSidecarURL: URL? }
struct Form {
    var address = ""
    var isValid: Bool { !address.isEmpty }
    func apply(to listing: inout Listing) { listing.address = address }
    func makeListing(coordinate: Coordinate?) -> Listing {
        var listing = Listing(address: address, beds: 0, baths: 0, sqft: 0, price: Money(cents: 0))
        listing.latitude = coordinate?.latitude; listing.longitude = coordinate?.longitude
        return listing
    }
}
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
    let model = Model(); var form = Form(); var addressFocused = false
    var photosListing: Listing?; var createdListing: Listing?; var pendingCoord: Coordinate?
    var goToPhotos = false; var goToReview = false; var pendingAsset: CaptureAsset?
__PHOTO__
__RECEIVE__
    func photoTap() { startWithPhotos() }
    func videoReceived() { receive(CaptureAsset(localURL: URL(fileURLWithPath: "/isolated/new.mov"))) }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) {
            precondition(value(), reason); count += 1
        }
        for scenario in ["photos_reused", "video_draft_to_photos", "video_draft_reused"] {
            let flow = Flow()
            var original = Listing(address: "Original address", beds: 2, baths: 1, sqft: 900, price: Money(cents: 100))
            original.serverID = UUID(); original.serverOrgID = UUID(); original.needsServerSync = false
            original.mainPhotoRelPath = "Photos/retained.jpg"
            flow.model.listings = [original]; flow.createdListing = original
            if scenario == "photos_reused" { flow.photosListing = original }
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
        print("PASSED: \(count) draft/cloud sync assertions across three real creation transitions")
    }
}
'''
    for token, code in [("__MODIFY__", modify), ("__DIRTY__", dirty), ("__PHOTO__", photo), ("__RECEIVE__", receive)]:
        swift = swift.replace(token, code)
    checks = out / "Checks.swift"
    checks.write_text(swift)
    receipt = {"hardware_validation": False, "injected_fault": args.inject_fault,
               "sources": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [new_path, app_path]}, "commands": []}
    for label, cmd in [("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, sources), str(checks), "-o", str(out / "checks")]), ("run", [str(out / "checks")])]:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        (out / f"{label}.log").write_text(result.stdout)
        receipt["commands"].append({"label": label, "exit_code": result.returncode})
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(label, result.returncode, result.stdout[-2000:] if result.returncode == 0 or label == "compile" else "Acceptance assertion rejected injected dirty-write regression")
        if result.returncode:
            print("Evidence:", out)
            raise SystemExit(1)
    print("Evidence:", out)


if __name__ == "__main__":
    main()
