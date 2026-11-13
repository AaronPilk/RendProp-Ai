#!/usr/bin/env python3
"""Execute the exact review-screen submission/lookup guards with inert boundaries.

No rendering, camera, network or provider calls. Swift functions are extracted
mechanically from production, not duplicated in the test implementation.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile


def extract(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    cursor = brace + 1
    while depth:
        depth += (source[cursor] == '{') - (source[cursor] == '}')
        cursor += 1
    return source[start:cursor]


def main():
    root = Path(__file__).resolve().parents[2]
    path = root / 'apps/ios/Rendprop/Screens/ReviewSubmitView.swift'
    source = path.read_text()
    out = Path(tempfile.mkdtemp(prefix='rendprop-render-review-fences-'))
    print(f'EVIDENCE: {out}', flush=True)
    signatures = ['private struct ReviewContext:', 'private var currentReviewContext:',
                  'private var reviewContextIsCurrent:', 'private func loadEntitlements()', 'private func start()']
    snippets = '\n'.join(extract(source, signature).replace('private ', '') for signature in signatures)
    prefix = r'''
import Foundation
enum Config { static let useLiveBackend = true }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? }
struct Listing: Equatable { let id: UUID; let org: UUID; var cloudUnavailable: Bool? }
struct CaptureAsset: Equatable { let localURL: URL; let durationS: Double; var isDrone: Bool = false }
struct Enhancements: Equatable {}
struct Render: Equatable {
    enum Tier { case smooth, premium; var usesServerAI: Bool { self != .smooth } }
    let listingID: UUID; let tier: Tier; let durationS: Double; let enhancements: Enhancements
}
struct Entitlements: Equatable { let canUseTopaz: Bool }
struct Summary { let entitlements: Entitlements }
@MainActor final class Auth {
    var userID: String? = "owner-A"
    var syncSessionRevision: UInt64 = 1
    var wait = false
    var continuation: CheckedContinuation<Bool, Never>?
    func ensureSession() async -> Bool {
        if !wait { return true }
        return await withCheckedContinuation { continuation = $0 }
    }
}
@MainActor final class API {
    var wait = false
    var calls = 0
    var continuation: CheckedContinuation<Summary, Never>?
    func me() async throws -> Summary {
        calls += 1
        if !wait { return Summary(entitlements: Entitlements(canUseTopaz: true)) }
        return await withCheckedContinuation { continuation = $0 }
    }
}
@MainActor final class Coordinator {
    var calls = 0
    var running = false
    func isRunning(_ id: UUID) -> Bool { running }
    func start(listing: Listing, asset: CaptureAsset) { calls += 1; running = true }
}
@MainActor final class Model {
    var listings: [Listing]
    var assets: [UUID: CaptureAsset]
    var renders: [UUID: Render] = [:]
    var tours: [UUID: String]
    let renderCoordinator = Coordinator()
    let api = API()
    init(listing: Listing, asset: CaptureAsset) {
        listings = [listing]; assets = [listing.id: asset]; tours = [listing.id: "keep-current-published-tour"]
    }
    func isInSelectedWorkspace(_ listing: Listing) -> Bool { listing.org == WorkspaceContext.selectedOrgID }
    func setLastError(_ error: String?, for id: UUID) {}
}
@MainActor final class Review {
    enum SourceKind { case handheld, drone }
    let auth = Auth()
    let model: Model
    let listing: Listing
    var asset: CaptureAsset
    var reviewContext: ReviewContext?
    var submitError: String?
    var sourceKind: SourceKind = .drone
    var tier: Render.Tier = .smooth
    var render: Render?
    var goToStatus = false
    var entitlements: Entitlements?
    var entitlementsChecked = false
    var isRendering: Bool { model.renderCoordinator.isRunning(listing.id) }
    var aiTiersLocked: Bool { !(entitlements?.canUseTopaz ?? false) }
    init(url: URL) {
        let org = UUID(); WorkspaceContext.selectedOrgID = org
        listing = Listing(id: UUID(), org: org)
        asset = CaptureAsset(localURL: url, durationS: 1.5)
        model = Model(listing: listing, asset: asset)
        reviewContext = currentReviewContext
    }
'''
    suffix = r'''
}
@main struct Tests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        print("FAIL: test suspension did not occur"); exit(1)
    }
    @MainActor static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = dir.appendingPathComponent("source-fixture.mp4")
        try Data([1, 2, 3]).write(to: url)
        let stable = Review(url: url)
        let originalTour = stable.model.tours
        stable.start()
        check(stable.model.renderCoordinator.calls == 1, "stable context starts actual submission boundary once")
        check(stable.model.assets[stable.listing.id]?.isDrone == true, "stable path applies selected source type")
        check(stable.model.renders.count == 1 && stable.goToStatus, "stable path stages render and progress")
        check(stable.model.tours == originalTour, "existing tour preserved until rendering")
        let cases: [(String, (Review) -> Void)] = [
            ("queued owner change", { $0.auth.userID = "owner-B" }),
            ("same owner new revision", { $0.auth.syncSessionRevision += 1 }),
            ("A to B to A", { $0.auth.userID = "owner-B"; $0.auth.syncSessionRevision += 1; $0.auth.userID = "owner-A" }),
            ("workspace change", { _ in WorkspaceContext.selectedOrgID = UUID() }),
            ("listing removed", { $0.model.listings.removeAll() }),
            ("listing access revoked", { $0.model.listings[0].cloudUnavailable = true }),
            ("listing moved", { $0.model.listings[0] = Listing(id: $0.listing.id, org: UUID()) }),
            ("already rendering", { $0.model.renderCoordinator.running = true })
        ]
        for (name, mutate) in cases {
            let review = Review(url: url)
            let assets = review.model.assets, renders = review.model.renders, tours = review.model.tours
            mutate(review)
            review.start()
            check(review.model.renderCoordinator.calls == 0, "\(name): refused submission")
            check(review.model.assets == assets && review.model.renders == renders && review.model.tours == tours,
                  "\(name): existing media and render preserved")
            check(review.submitError != nil && !review.goToStatus, "\(name): actionable error without routing")
        }
        let missing = Review(url: dir.appendingPathComponent("missing.mp4"))
        let saved = missing.model.assets
        missing.start()
        check(missing.model.renderCoordinator.calls == 0 && missing.model.assets == saved && missing.model.renders.isEmpty,
              "missing source refused without mutation")
        check(missing.submitError?.contains("source video") == true, "missing source message explains recovery")

        let lookup = Review(url: url)
        await lookup.loadEntitlements()
        check(lookup.entitlements?.canUseTopaz == true && lookup.entitlementsChecked && lookup.model.api.calls == 1,
              "unchanged lookup accepted")
        let ensure = Review(url: url)
        ensure.auth.wait = true
        let pendingEnsure = Task { await ensure.loadEntitlements() }
        await waitUntil { ensure.auth.continuation != nil }
        ensure.auth.userID = "owner-B"
        ensure.auth.syncSessionRevision += 1
        ensure.auth.continuation!.resume(returning: true)
        await pendingEnsure.value
        check(ensure.model.api.calls == 0 && ensure.entitlements == nil && !ensure.entitlementsChecked,
              "stale ensureSession result does not issue me or commit")
        let me = Review(url: url)
        me.model.api.wait = true
        let pendingMe = Task { await me.loadEntitlements() }
        await waitUntil { me.model.api.continuation != nil }
        WorkspaceContext.selectedOrgID = UUID()
        me.model.api.continuation!.resume(returning: Summary(entitlements: Entitlements(canUseTopaz: true)))
        await pendingMe.value
        check(me.entitlements == nil && !me.entitlementsChecked, "stale me result does not commit allowances")
        print("PASS: \(checks) actual review submission and suspended entitlement assertions; no provider calls")
    }
}
'''
    receipt = {'accepted': False, 'source': str(path.relative_to(root)),
               'sourceSHA256': hashlib.sha256(path.read_bytes()).hexdigest(), 'commands': [],
               'extractedSignatures': signatures, 'cameraUsed': False, 'customerWrites': False, 'paidGeneration': False}

    def execute(label, text, expect_failure=False):
        swift = out / f'{label}.swift'
        swift.write_text(prefix + text + suffix)
        binary = out / label
        compiled = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-warnings-as-errors',
                                   str(swift), '-o', str(binary)], text=True, capture_output=True, timeout=90)
        (out / f'{label}-compile.log').write_text(compiled.stdout + compiled.stderr)
        assert compiled.returncode == 0, f'Compile failed: {out / (label + "-compile.log")}'
        result = subprocess.run([str(binary), str(out)], text=True, capture_output=True, timeout=15)
        log = out / f'{label}.log'
        log.write_text(result.stdout + result.stderr)
        receipt['commands'].append({'name': label, 'exit': result.returncode, 'log': str(log),
                                   'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        if expect_failure:
            assert result.returncode == 1 and 'queued owner change: refused submission' in result.stdout, result.stdout
        else:
            assert result.returncode == 0 and 'PASS:' in result.stdout, str(log)
        print(result.stdout.strip(), flush=True)

    try:
        execute('production-fences', snippets)
        guard = '''guard reviewContextIsCurrent else {
            submitError = "Your account or workspace changed. Return to the listing and open the render settings again. Your current tour is saved."
            return
        }'''
        assert snippets.count(guard) == 1
        execute('reject-missing-confirmation-fence', snippets.replace(guard, '// Deliberate negative control: context guard removed.'), True)
        assert hashlib.sha256(path.read_bytes()).hexdigest() == receipt['sourceSHA256'], 'Production source changed during verification'
        receipt['accepted'] = True
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
