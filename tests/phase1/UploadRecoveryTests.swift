import Foundation

@main struct UploadRecoveryTests {
    static var assertions = 0
    static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        if !condition { FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8)); exit(1) }
    }
    static func expectFailure(_ message: String, _ operation: () async throws -> Void) async {
        do { try await operation(); check(false, message) } catch { assertions += 1 }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = root.appendingPathComponent("original.jpg")
        let bytes = Data("synthetic upload fixture — no customer media".utf8)
        try bytes.write(to: file)
        let original = DirectUploader.sha256(of: file)
        let listing = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        func upload(_ api: RecoveryAPI, _ label: String) async throws -> String {
            try await DirectUploader.uploadPhoto(fileURL: file, listingID: listing, role: "capture",
                contentType: "image/jpeg", keyPrefix: "photo", api: api,
                journalStore: DirectUploadJournal(directory: root.appendingPathComponent(label)),
                transfer: api.transfer, delay: { _ in })
        }

        let completeLoss = RecoveryAPI(); completeLoss.loseCompleteOnce = true
        check(try await upload(completeLoss, "complete-loss") == completeLoss.oldID, "Lost completion returns original asset")
        check(completeLoss.physicalWrites == 1 && completeLoss.transfers == 1,
              "Lost complete response must not resend PUT bytes")
        check(completeLoss.creates == 1 && completeLoss.renews == 0, "Completed asset cannot be re-reserved")
        check(completeLoss.log == ["create", "put", "complete", "complete"], "Completion is probed before any reissue")

        AuthStore.currentAccessToken = nil
        let firstLaunch = RecoveryAPI()
        _ = try await upload(firstLaunch, "first-launch")
        check(AuthStore.connections == 1 && firstLaunch.physicalWrites == 1,
              "Anonymous connection is established before binding upload owner")

        let putLoss = RecoveryAPI(); putLoss.loseTransferReplyOnce = true
        _ = try await upload(putLoss, "put-loss")
        check(putLoss.transfers == 1 && putLoss.physicalWrites == 1 && putLoss.creates == 1,
              "Lost PUT response must reconcile before transfer")

        let noDispatch = RecoveryAPI(); noDispatch.failTransferBeforeWriteOnce = true
        _ = try await upload(noDispatch, "not-dispatched")
        check(noDispatch.transfers == 2 && noDispatch.physicalWrites == 1,
              "Only server-authorized undispatched transfer may run")
        check(noDispatch.creates == 1 && noDispatch.renews == 1, "Same reservation renewed after a pre-dispatch failure")
        check(noDispatch.log == ["create", "put", "complete", "renew", "put", "complete"], "Complete precedes renewal and second transfer")

        let uncertain = RecoveryAPI(); uncertain.uncertain = true
        await expectFailure("Unprovable storage cannot report success") { _ = try await upload(uncertain, "uncertain") }
        check(uncertain.transfers == 1 && uncertain.creates == 1 && uncertain.cancels == 0,
              "Uncertain v2 cannot resend or silently cancel")

        let legacy = RecoveryAPI(); legacy.legacy = true
        await expectFailure("Legacy replacement requires explicit resume") { _ = try await upload(legacy, "legacy") }
        check(legacy.cancels == 0 && legacy.transfers == 0, "Automatic legacy detection must not cancel")
        check(try await upload(legacy, "legacy") == legacy.newID, "Explicit legacy resume returns new ticket")
        check(legacy.cancels == 1 && legacy.creates == 2, "Exactly one retired ticket cancelled, one replacement created")
        check(Set(legacy.keys).count == 1, "Legacy migration keeps exact stable idempotency key")
        check(legacy.physicalWrites == 1, "Legacy migration sends original only once")
        check(legacy.log.prefix(3) == ["create", "complete", "complete"], "Legacy cancellation follows fresh complete probe")

        let lostAbort = RecoveryAPI(); lostAbort.legacy = true; lostAbort.failAbortOnce = true
        await expectFailure("First call asks for legacy resume") { _ = try await upload(lostAbort, "abort-loss") }
        _ = try await upload(lostAbort, "abort-loss")
        check(lostAbort.cancels == 1 && lostAbort.creates == 2 && Set(lostAbort.keys).count == 1,
              "Lost abort response resumes persisted cancellation without duplicate cancel or key")

        let rolledBack = RecoveryAPI(); rolledBack.failTransferBeforeWriteOnce = true; rolledBack.rollback = true
        await expectFailure("Rollback cannot relabel a reservation") { _ = try await upload(rolledBack, "rollback") }
        check(rolledBack.transfers == 1 && rolledBack.creates == 1 && rolledBack.cancels == 0,
              "Versionless renewal cannot authorize a second PUT")

        let expired = RecoveryAPI()
        expired.completionFailure = .server(status: 409, code: "CONFLICT", message: "upload is terminal or expired")
        await expectFailure("Expired ticket cannot pretend upload succeeded") { _ = try await upload(expired, "expired") }
        check(expired.transfers == 1 && expired.creates == 1 && expired.renews == 0 && expired.cancels == 0,
              "Expired reservation is preserved without a silent replacement or redispatch")
        let revoked = RecoveryAPI()
        revoked.completionFailure = .server(status: 403, code: "FORBIDDEN", message: "workspace changed")
        await expectFailure("Revoked workspace cannot publish") { _ = try await upload(revoked, "revoked") }
        check(revoked.transfers == 1 && revoked.renews == 0 && revoked.cancels == 0,
              "Permission failure never authorizes another physical write")

        check(UploadRecovery.sameAsset(legacy.oldID, legacy.oldID.uppercased()), "UUID case differences refer to same ticket")
        check(!UploadRecovery.sameAsset("token-A", "token-a"), "Opaque identity case is preserved")
        check(UploadRecovery.isLegacyRetired(APIError.server(status: 409, code: "CONFLICT",
            message: "Legacy upload must be reticketed after rollout cleanup")), "HTTP status and exact message survive upper-case code")
        check(!UploadRecovery.isLegacyRetired(APIError.server(status: 409, code: "conflict",
            message: "Another legacy upload is still in progress")), "Generic conflict never authorizes cancellation")
        check(!UploadRecovery.isLegacyRetired(APIError.server(status: 403, code: "conflict",
            message: "Legacy upload must be reticketed after rollout cleanup")), "Wrong HTTP status cannot authorize cancellation")
        check(!UploadRecovery.isBoundedCapability(URL(string: "https://r2.invalid/a?X-Amz-Signature=abc")!),
              "Old host-only capability cannot renew bounded transport")
        check(!UploadRecovery.isBoundedCapability(URL(string: "http://upload.invalid/v2/11111111-1111-4111-8111-111111111111?expires=12&signature=" + String(repeating: "a", count: 64))!),
              "Plain HTTP cannot renew bounded transport")

        let renewal = noDispatch.ticket()
        // The actual production model is immutable by asset id, so construct a
        // different server identity instead of mutating the fixture's original.
        let different = UploadTicket(assetID: legacy.newID, mode: .single, putURL: renewal.putURL, transportVersion: 2)
        do { _ = try UploadRecovery.validatedRenewal(different, previous: renewal); check(false, "Changed asset must be rejected") }
        catch { assertions += 1 }
        let journal = UploadRecovery.Journal(ticket: renewal, cancellationAuthorizedFor: legacy.oldID, dispatched: true)
        let decoded = try JSONDecoder().decode(UploadRecovery.Journal.self, from: JSONEncoder().encode(journal))
        check(decoded.ticket?.assetID == renewal.assetID && decoded.dispatched,
              "Ambiguous dispatch identity survives relaunch")
        check(decoded.cancellationAuthorizedFor == legacy.oldID, "Cancellation intent survives relaunch")
        let oldState = Data(#"{"filePath":"original.mov","bytesTotal":343000000,"bytesSent":67000000,"status":"failed","mode":"multipart","assetID":"legacy-id","uploadID":"old-session","parts":[{"number":1,"offset":0,"length":67000000,"status":"done","etag":"old-etag"}],"terminalError":"conflict"}"#.utf8)
        let persisted = try JSONDecoder().decode(UploadManager.State.self, from: oldState)
        check(persisted.assetID == "legacy-id" && persisted.parts.first?.etag == "old-etag", "Old video records retain asset and part receipts")
        check(persisted.transportVersion == nil && persisted.ticketKey == nil, "Old record is not silently relabelled v2")
        check(persisted.legacyRecoveryApproved == nil, "Relaunch does not manufacture legacy consent")
        var resuming = persisted
        resuming.prepareForExplicitResume()
        check(resuming.assetID == persisted.assetID && resuming.uploadID == persisted.uploadID &&
              resuming.parts.first?.etag == persisted.parts.first?.etag,
              "Explicit Resume preserves legacy identity and completed parts")
        check(resuming.id == persisted.id && resuming.ticketKey == persisted.ticketKey && resuming.transportVersion == nil,
              "Explicit Resume keeps original operation key and transport version")
        check(resuming.terminalError == nil && resuming.legacyRecoveryApproved == true && resuming.status == .uploading,
              "Explicit Resume allows reconciliation without inventing completion")
        let cancellation = try JSONDecoder().decode(UploadAbortReceipt.self, from: Data(#"{"ok":true,"upload_aborted":true,"cleanup_pending":true}"#.utf8))
        check(cancellation.isConfirmed, "Exact snake-case cancellation receipt decodes")
        let incompleteCancellation = try JSONDecoder().decode(UploadAbortReceipt.self, from: Data(#"{"ok":true,"upload_aborted":false}"#.utf8))
        check(!incompleteCancellation.isConfirmed, "HTTP success without cancellation cannot authorize replacement")
        do { _ = try JSONDecoder().decode(UploadAbortReceipt.self, from: Data(#"{"ok":true}"#.utf8)); check(false, "Missing cancellation flag cannot authorize replacement") }
        catch { assertions += 1 }
        let finalBytes = try Data(contentsOf: file)
        check(DirectUploader.sha256(of: file) == original && finalBytes == bytes,
              "Original media remains byte-identical after every recovery")
        print("PASS UploadRecoveryTests \(assertions) assertions")
    }
}
