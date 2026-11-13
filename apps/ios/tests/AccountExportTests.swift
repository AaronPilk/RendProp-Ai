import Foundation
func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { if !condition() { throw NSError(domain: label, code: 1) } }
let owner = UUID(uuidString: "ea100601-0000-4000-8000-000000000001")!
let other = UUID(uuidString: "ea100601-0000-4000-8000-000000000009")!
func bytes(actor: UUID = owner, truncated: Bool = false, count: Int = 1) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["manifest": ["version": "rendprop-account-export-v1", "actor_id": actor.uuidString, "generated_at": "2026-10-06T12:00:00.000Z", "scope": "current-account-owned-cloud-records", "complete_within_scope": true, "truncated": truncated, "collections": ["profiles": ["count": count]], "omissions": [["collection": "binary_media", "reason": "Original files are excluded."]]], "data": ["profiles": [["id": actor.uuidString]]]])
}
func rejected(_ body: () throws -> Void, _ label: String) throws { do { try body() } catch { return }; throw NSError(domain: label, code: 2) }
@main struct Tests {
    @MainActor static func main() async throws {
        let context = AccountExportContext(actor: owner, revision: 7)
        let prospective = HostingRetentionSummary(orgId: owner, policy: "prospective_90_day_grace", protected: false, retentionEndsAt: "2030-01-01T00:00:00Z", hostingAvailable: true)
        try check(prospective.checked(org: owner)?.deadline != nil, "retention-receipt")
        try check(prospective.checked(org: other) == nil, "retention-workspace")
        try check(HostingRetentionSummary(orgId: owner, policy: "preserved", protected: true, retentionEndsAt: nil, hostingAvailable: true).checked(org: owner) != nil, "retention-qa-preserved")
        try check(HostingRetentionSummary(orgId: owner, policy: "prospective_90_day_grace", protected: false, retentionEndsAt: "invalid", hostingAvailable: true).checked(org: owner) == nil, "retention-invalid-date")
        try check(context.matches(owner: owner.uuidString, revision: 7, identified: true), "current-account")
        try check(!context.matches(owner: other.uuidString, revision: 7, identified: true), "foreign-account")
        try check(!context.matches(owner: owner.uuidString, revision: 8, identified: true), "session-revision")
        try check(!context.matches(owner: owner.uuidString, revision: 7, identified: false), "signed-out")
        let valid = try bytes(); let receipt = try AccountExportReceipt.checked(valid, context: context)
        try check(receipt.rows == 1 && receipt.omissions.count == 1, "verified-manifest")
        try rejected({ _ = try AccountExportReceipt.checked(bytes(actor: other), context: context) }, "foreign-receipt")
        var wrongManifest = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        var manifest = wrongManifest["manifest"] as! [String: Any]; manifest["actor_id"] = other.uuidString; wrongManifest["manifest"] = manifest
        let mismatchedActor = try JSONSerialization.data(withJSONObject: wrongManifest)
        try rejected({ _ = try AccountExportReceipt.checked(mismatchedActor, context: context) }, "foreign-manifest-actor")
        try rejected({ _ = try AccountExportReceipt.checked(bytes(truncated: true), context: context) }, "truncated-receipt")
        try rejected({ _ = try AccountExportReceipt.checked(bytes(count: 2), context: context) }, "count-mismatch")
        try rejected({ _ = try AccountExportReceipt.checked(Data("{}".utf8), context: context) }, "missing-manifest")
        let neighbor = AccountExportFiles.directory.deletingLastPathComponent().appendingPathComponent("rendprop-export-neighbor-test")
        try valid.write(to: neighbor); defer { try? FileManager.default.removeItem(at: neighbor); AccountExportFiles.purge() }
        AccountExportFiles.purge(); let first = UUID(), second = UUID()
        let a = try AccountExportFiles.save(valid, generation: first), b = try AccountExportFiles.save(valid, generation: second)
        let mode = try FileManager.default.attributesOfItem(atPath: b.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "private-file-mode")
        AccountExportFiles.remove(generation: first)
        try check(!FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path), "generation-owned-cleanup")
        AccountExportFiles.purge()
        try check(!FileManager.default.fileExists(atPath: b.path) && FileManager.default.fileExists(atPath: neighbor.path), "relaunch-owned-purge")
        // Execute the actual download/clear methods with only Auth/API/UI state
        // closed. A cancelled old request completes after a same-account retry.
        let auth = FakeAuth(), gate = Gate(), view = ExportFixture(auth: auth, gate: gate)
        auth.userID = owner.uuidString; auth.syncSessionRevision = 7; auth.isIdentified = true
        view.download(); await gate.waitFor(1); let oldGeneration = view.generation
        view.download(); await gate.waitFor(2); let newGeneration = view.generation
        try check(oldGeneration != newGeneration && view.loading, "retry-generation")
        view.finishShare(oldGeneration!)
        try check(view.generation == newGeneration && view.loading, "old-share-dismissal-preserves-newer-download")
        await gate.finish(0, valid)
        for _ in 0..<10 { await Task.yield() }
        try check(view.generation == newGeneration && view.loading && view.file == nil, "stale-completion-preserves-newer-download")
        await gate.finish(1, valid)
        for _ in 0..<100 where view.loading { await Task.yield() }
        try check(view.receipt?.rows == 1 && view.file != nil && view.current, "verified-save")
        let saved = view.file!
        auth.syncSessionRevision = 8
        try check(!view.current, "session-change-hides-result")
        view.clear(); try check(!FileManager.default.fileExists(atPath: saved.path) && view.file == nil, "account-change-removes-file")
        view.download(); await gate.waitFor(3); auth.userID = other.uuidString; await gate.finish(2, valid)
        for _ in 0..<100 where view.loading { await Task.yield() }
        try check(view.file == nil && view.receipt == nil, "changed-actor-before-save")
        print("Account export: manifest, actor/session, generation race, private save, cancellation and relaunch checks passed")
    }
}
