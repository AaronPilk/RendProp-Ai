#!/usr/bin/env python3
"""Compile exact presentation identity and detail scan/lifecycle methods.
SwiftUI wiring is source checked; Foundation boundaries use synthetic fixtures.
No app/device, network, camera, customer files, or shared-job cancellation.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess


def block(source, anchor):
    start = source.index(anchor)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == "{": depth += 1
        elif source[end] == "}": depth -= 1
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    args.out.mkdir(parents=True, exist_ok=False)
    app_path = root / "apps/ios/Rendprop/RendpropApp.swift"
    detail_path = root / "apps/ios/Rendprop/Screens/FlythroughDetailView.swift"
    test_path = root / "tests/phase1/NativePresentationPrivacyTests.swift"
    app, detail = app_path.read_text(), detail_path.read_text()
    require = lambda value, text: value or (_ for _ in ()).throw(RuntimeError(text))
    require("tabs.id(NativePresentationScope(actorID: workspaceAuth.userID," in app,
            "Tab navigation must reset on real presentation identity")
    require("orgID: workspace.snapshot?.selectedOrgID)" in app,
            "Tab navigation must include selected workspace")
    require("if hasCurrentPresentationContext {\n            VStack" in detail,
            "Listing content must be hidden before stale dismissal")
    require('.navigationTitle(hasCurrentPresentationContext ? currentListing.address : "Listing")' in detail,
            "Old listing address cannot survive a scope change")
    require(detail.count("if !hasCurrentPresentationContext { invalidatePresentation() }") == 2,
            "Both account and workspace lifecycle events must invalidate detail")
    require(detail.index(".askAI(.listing, listingID: listing.id)") < detail.index('Text("Your account or workspace changed. Reopen the listing'),
            "Ask AI must be inside the current-context content branch")
    require("private func loadCompliance() async {\n        guard !Task.isCancelled, hasCurrentPresentationContext else { return }" in detail,
            "Compliance requests must reject stale detail before dispatch")
    helper = block(app, "struct NativePresentationScope:")
    indexing = block(detail, "enum SearchIndexingDefault {")
    current = block(detail, "    private var hasCurrentPresentationContext:")
    invalidate = block(detail, "    private func invalidatePresentation()")
    load = block(detail, "    private func loadFiles(force:")
    contact = block(detail, "    @MainActor private func refreshClientContactIfCurrent()")
    template = '''import Foundation
struct FixtureListing { var id = UUID(); var isSample = false; var aerialRelPath: String?; var aerialGeneratedAt: Date? }
struct FixtureTour { var url: URL }
@MainActor final class FixtureAuth { var userID: String?; init(userID: String?) { self.userID = userID } }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? }
@MainActor final class AuthStore { static let shared = AuthStore(); var userID: String? }
@MainActor enum UserDefaults {
    static let suite = "rendprop-synthetic-indexing-" + UUID().uuidString
    static let standard = Foundation.UserDefaults(suiteName: suite)!
}
@MainActor final class FixtureConnection { var cancelled = 0; func cancel() { cancelled += 1 } }
@MainActor final class FixtureModel { var contactCalls = 0; func refreshClientContact(for id: UUID) async throws { contactCalls += 1 } }
struct ListingMediaItem {
    struct ScanRequest { let listingID: UUID; let tourURL: URL?; let aerialRelPath: String?; let aerialGeneratedAt: Date? }
    struct Scan { let stamp: Int; let items: [Int] }
    @MainActor static func scan(_ request: ScanRequest, since: Int?) async -> Scan? {
        await withCheckedContinuation { ScanFixture.pending.append($0) }
    }
}
@MainActor enum ScanFixture { static var pending: [CheckedContinuation<ListingMediaItem.Scan?, Never>] = [] }
SCOPE
INDEXING
@MainActor final class PresentationHarness {
    let auth: FixtureAuth; var presentationScope: NativePresentationScope
    var currentListing = FixtureListing(); var tour: FixtureTour?
    var listing: FixtureListing { currentListing }; let model = FixtureModel()
    var filesTask: Task<Void, Never>?; var filesStamp: Int?; var mediaItems: [Int] = []
    var availableRerenderSource: URL?; var openedFile: Int?; var filePhotoExport: Int?; var filePhotoExportAdmission: (() -> Bool)?
    var provenance: [Int] = []; var provenanceCanExport: (() -> Bool)?; var auditExport: Int?
    var showPhotosScreen = false, showRoomTagger = false, showReelStudio = false, showAerialIntro = false, showEdit = false, showListingFactsReview = false
    var qrTarget: Int?; let connection = FixtureConnection(); var dismissals = 0; var sharedAdmittedJobs = 7
    init(scope: NativePresentationScope, auth: FixtureAuth) { presentationScope = scope; self.auth = auth }
    func dismiss() { dismissals += 1 }
CURRENT
INVALIDATE
LOAD
CONTACT
}
'''
    generated = template.replace("SCOPE", helper).replace("INDEXING", indexing).replace("CURRENT", current).replace("INVALIDATE", invalidate).replace("LOAD", load).replace("CONTACT", contact)
    generated = generated.replace("    private var hasCurrentPresentationContext:", "    var hasCurrentPresentationContext:")
    generated = generated.replace("    private func invalidatePresentation()", "    func invalidatePresentation()")
    generated = generated.replace("    private func loadFiles(force:", "    func loadFiles(force:")
    generated = generated.replace("    @MainActor private func refreshClientContactIfCurrent()", "    @MainActor func refreshClientContactIfCurrent()")
    inputs = [app_path, detail_path, test_path, Path(__file__).resolve()]
    receipt = {"accepted": False, "network": 0, "camera": 0, "sourceRoot": str(root), "sourceHashes": {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}, "runs": []}
    controls = [
        ("no-account-fence", "self.actorID == actorID && self.orgID == orgID", "self.orgID == orgID", "Another account invalidates presentation"),
        ("no-workspace-fence", "self.actorID == actorID && self.orgID == orgID", "self.actorID == actorID", "Another workspace invalidates presentation"),
        ("late-scan-publishes", "hasCurrentPresentationContext else { return }", "true else { return }", "Late file scan cannot publish after account switch"),
        ("keeps-local-files", "mediaItems = []; availableRerenderSource", "availableRerenderSource", "Invalidation clears old local-file presentation"),
        ("ignores-scan-cancellation", "!Task.isCancelled, expectedScope", "true, expectedScope", "Cancelled scan cannot restore files after invalidation"),
        ("stale-contact-dispatch", "!Task.isCancelled, hasCurrentPresentationContext, !currentListing.isSample", "!Task.isCancelled, !currentListing.isSample", "Stale account cannot dispatch listing contact request"),
        ("actor-global-indexing", 'return "\\(actor.lowercased()):\\(org.uuidString.lowercased())"', 'return actor.lowercased()', "Indexing opt-in cannot carry into another workspace"),
        ("workspace-global-indexing", 'return "\\(actor.lowercased()):\\(org.uuidString.lowercased())"', 'return org.uuidString.lowercased()', "Indexing opt-in cannot carry into another account"),
        ("adopts-legacy-indexing", 'return defaults.bool(forKey: valueKey + "." + owner)', 'return defaults.bool(forKey: valueKey)', "Legacy actor-only indexing preference cannot opt a workspace in"),
    ]
    try:
        for name, text, expected in [("actual", generated, None)] + [
            (name, generated.replace(old, new, 1), failure) for name, old, new, failure in controls]:
            require(name == "actual" or text != generated, "Mutation anchor missing: " + name)
            src = args.out / (name + ".swift"); src.write_text(text)
            binary = args.out / name
            build = subprocess.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", str(src), str(test_path), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            (args.out / (name + "-compile.log")).write_text(build.stdout + build.stderr)
            require(build.returncode == 0, "Control did not compile: " + name)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            log = args.out / (name + ".log"); log.write_text(result.stdout + result.stderr)
            require((result.returncode == 0) if expected is None else
                    (result.returncode == 1 and "FAIL " + expected in log.read_text()), "Wrong behavior: " + name)
            receipt["runs"].append({"name": name, "exit": result.returncode, "log": str(log), "output": log.read_text().strip()})
        require(all(hashlib.sha256((root / path).read_bytes()).hexdigest() == digest
                    for path, digest in receipt["sourceHashes"].items()), "Source changed during proof")
        receipt["accepted"] = True
        print(json.dumps({"passed": True, "receipt": str(args.out / "receipt.json"), "compiledNegativeControls": len(controls)}))
    finally:
        (args.out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__": main()
