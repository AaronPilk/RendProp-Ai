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
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        FileStore.documents = root
        let file = root.appendingPathComponent("original.jpg")
        let bytes = Data("synthetic upload fixture — no customer media".utf8)
        try bytes.write(to: file)
        let original = DirectUploader.sha256(of: file)
        let listing = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        func upload(_ api: RecoveryAPI, _ label: String, restart: Bool = false) async throws -> String {
            try await DirectUploader.uploadPhoto(fileURL: file, listingID: listing, role: "capture",
                contentType: "image/jpeg", keyPrefix: "photo", api: api,
                journalStore: DirectUploadJournal(directory: root.appendingPathComponent(label)),
                confirmRestart: restart,
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
        check(expired.transfers == 1 && expired.creates == 1 && expired.renews == 1 && expired.cancels == 0 && expired.replacements == 0,
              "Expired reservation is preserved without a silent replacement or redispatch")
        let revoked = RecoveryAPI()
        revoked.completionFailure = .server(status: 403, code: "FORBIDDEN", message: "workspace changed")
        await expectFailure("Revoked workspace cannot publish") { _ = try await upload(revoked, "revoked") }
        check(revoked.transfers == 1 && revoked.renews == 0 && revoked.cancels == 0,
              "Permission failure never authorizes another physical write")

        let pending = try await DirectUploadJournal(directory: root.appendingPathComponent("expired"))
            .pendingPhotos(ownerID: AuthStore.jwtSubject(AuthStore.currentAccessToken!)!)
        check(pending.count == 1 && pending[0].needsRestart && pending[0].source.bytes == bytes.count,
              "Expired photo is an actionable durable recovery item")
        check(try await upload(expired, "expired", restart: true) == expired.newID,
              "Explicit photo Restart returns the replacement asset")
        check(expired.replacements == 1 && expired.creates == 1 && expired.restartKeys.count == 1,
              "Explicit restart calls linked route once and never fresh reservation")
        check(expired.log.suffix(4) == ["complete", "restart", "put", "complete"],
              "Explicit restart probes original completion before replacement bytes")
        let cleared = try await DirectUploadJournal(directory: root.appendingPathComponent("expired"))
            .pendingPhotos(ownerID: AuthStore.jwtSubject(AuthStore.currentAccessToken!)!)
        check(cleared.isEmpty, "Completed photo leaves the recovery list without deleting original")

        let killedStore = DirectUploadJournal(directory: root.appendingPathComponent("killed-photo"))
        var killed = UploadRecovery.Journal(ticket: expired.ticket(), dispatched: true)
        killed.source = pending[0].source
        try await killedStore.save(killed, for: "force-kill-fixture")
        let killedPending = try await killedStore.pendingPhotos(ownerID: killed.source!.ownerID)
        check(killedPending.count == 1 && !killedPending[0].needsRestart,
              "App death without catch still exposes metadata-first photo recovery")
        check(killedPending[0].message.contains("saved progress"), "Uncaught interruption has an actionable fallback message")
        try await killedStore.acquire("force-kill-fixture")
        check(try await killedStore.pendingPhotos(ownerID: killed.source!.ownerID).isEmpty,
              "Active photo transfer is not falsely labelled interrupted")
        await killedStore.release("force-kill-fixture")
        check(try await killedStore.pendingPhotos(ownerID: killed.source!.ownerID).count == 1,
              "Released unfinished photo stays discoverable for recovery")

        let restartLoss = RecoveryAPI()
        restartLoss.completionFailure = .server(status: 409, code: "conflict", message: "upload is terminal or expired")
        restartLoss.loseRestartReplyOnce = true
        await expectFailure("Expired photo initially requires confirmation") { _ = try await upload(restartLoss, "restart-loss") }
        await expectFailure("Lost restart reply cannot pretend success") { _ = try await upload(restartLoss, "restart-loss", restart: true) }
        check(try await upload(restartLoss, "restart-loss", restart: true) == restartLoss.newID,
              "Lost linked restart response recovers exact child")
        check(restartLoss.restartKeys.count == 2 && Set(restartLoss.restartKeys).count == 1 && restartLoss.replacements == 1,
              "Restart intent survives lost response and reuses one UUID")
        check(restartLoss.creates == 1 && restartLoss.transfers == 2,
              "Lost restart response cannot purchase a second child or resend it twice")

        let completedRace = RecoveryAPI()
        completedRace.completionFailure = .server(status: 409, code: "conflict", message: "upload is terminal or expired")
        await expectFailure("Unresolved photo gets confirmation before race") { _ = try await upload(completedRace, "complete-wins") }
        completedRace.completionWinsRestart = true
        check(try await upload(completedRace, "complete-wins", restart: true) == completedRace.oldID,
              "Original completion wins concurrent server restart")
        check(completedRace.replacements == 0 && completedRace.transfers == 1,
              "Completion-winning restart must not send replacement bytes")

        let switched = RecoveryAPI()
        switched.completionFailure = .server(status: 409, code: "conflict", message: "upload is terminal or expired")
        await expectFailure("Interrupted photo cannot silently start over") { _ = try await upload(switched, "restart-owner") }
        switched.switchOwnerOnRestart = true
        await expectFailure("Account switch fences restarted media dispatch") { _ = try await upload(switched, "restart-owner", restart: true) }
        check(switched.transfers == 1, "Different owner never uploads restarted original")
        let otherPending = try await DirectUploadJournal(directory: root.appendingPathComponent("restart-owner"))
            .pendingPhotos(ownerID: AuthStore.jwtSubject(AuthStore.currentAccessToken!)!)
        check(otherPending.isEmpty, "Recovery list never reveals another owner's photo")
        AuthStore.currentAccessToken = "offline-fixture-only"

        let oldTicket = RecoveryAPI().ticket()
        let intent = UploadRecovery.RestartIntent(assetID: oldTicket.assetID, ownerID: AuthStore.jwtSubject(AuthStore.currentAccessToken!)!)
        var replacementCalls = 0
        let probeWon = try await UploadRecovery.restart(intent, ticket: oldTicket,
            currentOwner: { intent.ownerID }, complete: { }, replace: { _, _ in replacementCalls += 1; return oldTicket })
        check(probeWon.uploaded == true && replacementCalls == 0, "Completion probe winner never calls restart route")
        await expectFailure("Unavailable restart route preserves saved intent") {
            _ = try await UploadRecovery.restart(intent, ticket: oldTicket, currentOwner: { intent.ownerID },
                complete: { throw APIError.server(status: 409, code: "conflict", message: "upload is terminal or expired") },
                replace: { _, _ in throw APIError.badResponse(404) })
        }
        await expectFailure("Generic conflict is not restart permission") {
            _ = try await UploadRecovery.restart(intent, ticket: oldTicket, currentOwner: { intent.ownerID },
                complete: { throw APIError.server(status: 409, code: "conflict", message: "some unrelated conflict") },
                replace: { _, _ in replacementCalls += 1; return oldTicket })
        }
        check(replacementCalls == 0, "Unrelated conflict cannot reach replacement endpoint")
        var waiting = oldTicket; waiting.putURL = nil; waiting.retryAfterSeconds = 120
        let acceptedWaiting = try UploadRecovery.validatedRenewal(waiting, previous: oldTicket)
        check(acceptedWaiting.retryAfterSeconds == 120 && acceptedWaiting.putURL == nil,
              "Active transport wait is valid metadata, not a malformed ticket")
        let corrupted = RecoveryAPI()
        _ = try await upload(corrupted, "corrupt-journal")
        let corruptURL = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("corrupt-journal"),
            includingPropertiesForKeys: nil).first!
        let corruptBytes = Data("deliberately unreadable receipt; preserve exact bytes".utf8)
        try corruptBytes.write(to: corruptURL)
        await expectFailure("Corrupt journal cannot authorize a new reservation") { _ = try await upload(corrupted, "corrupt-journal") }
        check(try Data(contentsOf: corruptURL) == corruptBytes && corrupted.creates == 1,
              "Failed journal load must never overwrite the original receipt")

        let parallel = RecoveryAPI(); parallel.holdTransfer = true
        let parallelStore = DirectUploadJournal(directory: root.appendingPathComponent("concurrent-journal"))
        func parallelUpload() async throws -> String {
            try await DirectUploader.uploadPhoto(fileURL: file, listingID: listing, role: "capture",
                contentType: "image/jpeg", keyPrefix: "photo", api: parallel, journalStore: parallelStore,
                transfer: parallel.transfer, delay: { _ in })
        }
        let firstUpload = Task { try await parallelUpload() }
        for _ in 0..<200 where parallel.heldTransfer == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        check(parallel.heldTransfer != nil, "Concurrent first upload actually reached transport")
        await expectFailure("Concurrent same-photo call cannot reserve again") { _ = try await parallelUpload() }
        parallel.heldTransfer?.resume()
        _ = try await firstUpload.value
        check(parallel.creates == 1 && parallel.transfers == 1,
              "Per-journal actor reservation prevents concurrent duplicate upload")

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
        let multi = UploadTicket(assetID: legacy.oldID, mode: .multipart, uploadID: "unchanged-session",
            partSize: 16, partCount: 4, transportVersion: 2)
        for invalidParts in [[UploadTicket.ConfirmedPart(number: 0, etag: "zero")],
                             [.init(number: 5, etag: "outside")], [.init(number: 1, etag: "")],
                             [.init(number: 1, etag: "a"), .init(number: 1, etag: "b")]] {
            var invalid = multi; invalid.confirmedParts = invalidParts
            await expectFailure("Invalid server part coverage cannot become confirmed progress") {
                _ = try UploadRecovery.validatedRenewal(invalid, previous: multi)
            }
        }
        var otherSession = multi; otherSession.uploadID = "another-session"
        await expectFailure("Multipart renewal cannot change upload session") {
            _ = try UploadRecovery.validatedRenewal(otherSession, previous: multi)
        }

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
        try await multipartRuntimeTests(root: root)
        try await videoRestartRuntimeTests(root: root)
        print("PASS UploadRecoveryTests \(assertions) assertions")
    }

    @MainActor static func multipartRuntimeTests(root: URL) async throws {
        FileStore.documents = root
        let originalURL = root.appendingPathComponent("multipart.mov")
        let originalBytes = Data(repeating: 97, count: 64)
        try originalBytes.write(to: originalURL)
        func state(_ api: MultipartRecoveryAPI) -> UploadManager.State {
            var record = UploadManager.State(filePath: "multipart.mov", bytesTotal: 64,
                status: .paused, mode: "multipart", assetID: api.assetID,
                uploadID: "fixture-session", partSize: 16, partCount: 4)
            record.parts = (1...4).map { .init(number: $0, offset: Int64($0 - 1) * 16, length: 16) }
            record.transportVersion = 2
            record.ownerID = AuthStore.jwtSubject(AuthStore.currentAccessToken!)
            record.ticketKey = "immutable-batch-fixture"
            return record
        }
        func until(_ message: String, _ predicate: () -> Bool) async {
            for _ in 0..<200 {
                if predicate() { check(true, message); return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            check(false, message)
        }
        let api = MultipartRecoveryAPI()
        let session = RecoverySession()
        var persisted: UploadManager.State?
        let manager = UploadManager(api: api, session: session, recovering: state(api), persistState: { persisted = $0; return true })
        manager.resume()
        await until("Real manager schedules three bounded parts") { session.fixtureTasks.filter { $0.starts == 1 }.count == 3 }
        check(api.partRequests == [[1, 2, 3]] && api.creates == 0, "Multipart resume reuses original asset without fresh reserve")
        manager.pause()
        try await Task.sleep(nanoseconds: 20_000_000)
        check(session.fixtureTasks.allSatisfy { $0.cancellations == 0 && $0.suspensions == 0 },
              "Pause must not interrupt a dispatched one-write operation")
        check(manager.state?.parts.prefix(3).allSatisfy { $0.status == .inflight } == true,
              "Pause retains in-flight task identities until receipts settle")
        for task in session.fixtureTasks {
            task.fixtureResponse = HTTPURLResponse(url: URL(string: "https://fixture.invalid/")!,
                statusCode: 200, httpVersion: nil, headerFields: ["ETag": "etag-\(task.fixtureID)"])
            task.fixtureState = .completed
            manager.urlSession(session, task: task, didCompleteWithError: nil)
        }
        await until("Real completion delegates retain paused part ETags") { manager.state?.parts.filter { $0.status == .done }.count == 3 }
        check(manager.state?.status == .paused && session.fixtureTasks.count == 3 && api.partRequests == [[1, 2, 3]],
              "Settled paused parts cannot dispatch the fourth part")
        check(persisted?.parts.prefix(3).allSatisfy { $0.etag != nil } == true && persisted?.ticketKey == "immutable-batch-fixture",
              "Paused receipts and original batch identity persist")

        // A relaunch has lost three client callbacks, but /renew returns those
        // server-confirmed receipts. Execute real reconciliation + applyTicket.
        let confirmedAPI = MultipartRecoveryAPI()
        confirmedAPI.confirmed = (1...3).map { .init(number: $0, etag: "server-etag-\($0)") }
        let confirmedSession = RecoverySession()
        let confirmedManager = UploadManager(api: confirmedAPI, session: confirmedSession,
            recovering: state(confirmedAPI), persistState: { _ in true })
        confirmedManager.resume()
        await until("Confirmed multipart receipts skip physical retransfers") { confirmedSession.fixtureTasks.count == 1 }
        check(confirmedAPI.renews == 1 && confirmedAPI.creates == 0 && confirmedAPI.partRequests == [[4]],
              "Confirmed multipart ETags schedule only the missing part")
        check(confirmedManager.state?.parts.prefix(3).map(\.etag) == ["server-etag-1", "server-etag-2", "server-etag-3"],
              "Actual manager consumes all server-confirmed multipart ETags")
        confirmedManager.pause()
        let final = confirmedSession.fixtureTasks[0]
        final.fixtureResponse = HTTPURLResponse(url: URL(string: "https://fixture.invalid/")!,
            statusCode: 200, httpVersion: nil, headerFields: ["ETag": "server-etag-4"])
        final.fixtureState = .completed
        confirmedManager.urlSession(confirmedSession, task: final, didCompleteWithError: nil)
        await until("Final paused multipart receipt settles without publishing") { confirmedManager.state?.parts.allSatisfy { $0.status == .done } == true }
        check(confirmedAPI.acceptedParts == nil, "Pause must not complete the object automatically")
        confirmedManager.resume()
        await until("Explicit resume completes from retained multipart ETags") { confirmedManager.state?.status == .done }
        check(confirmedAPI.acceptedParts?.map(\.etag) == (1...4).map { "server-etag-\($0)" } && confirmedAPI.creates == 0,
              "Completion uses exact unique retained ETags and no new reservation")

        let lateAPI = MultipartRecoveryAPI(); lateAPI.waitForRenewal = true
        let lateManager = UploadManager(api: lateAPI, session: RecoverySession(), recovering: state(lateAPI), persistState: { _ in true })
        lateManager.resume()
        await until("Delayed renewal started for pause race") { lateAPI.delayedRenewal != nil }
        lateManager.pause()
        lateAPI.delayedRenewal?.resume(throwing: APIError.badResponse(503))
        try await Task.sleep(nanoseconds: 20_000_000)
        check(lateManager.state?.status == .paused, "Late renewal error cannot overwrite explicit Pause")

        let delayedSession = RecoverySession(); delayedSession.deferEnumeration = true
        let delayedAPI = MultipartRecoveryAPI()
        let suspended = RecoveryTask(99); suspended.taskDescription = "part:\(delayedAPI.assetID):1"
        delayedSession.fixtureTasks = [suspended]
        let delayedManager = UploadManager(api: delayedAPI, session: delayedSession, recovering: state(delayedAPI), persistState: { _ in true })
        delayedManager.resume(); delayedManager.pause()
        for callback in delayedSession.enumerations { callback([suspended]) }
        try await Task.sleep(nanoseconds: 20_000_000)
        check(suspended.starts == 0 && delayedManager.state?.status == .paused,
              "Late session enumeration cannot start a task after Pause")
        let switchedAPI = MultipartRecoveryAPI(); switchedAPI.waitForParts = true
        let switchedSession = RecoverySession()
        let switchedManager = UploadManager(api: switchedAPI, session: switchedSession,
            recovering: state(switchedAPI), persistState: { _ in true })
        switchedManager.resume()
        await until("Multipart capability fetch is actually awaiting response") { switchedAPI.heldParts != nil }
        AuthStore.currentAccessToken = "other-owner-fixture"
        switchedAPI.heldParts?.resume()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(switchedSession.fixtureTasks.isEmpty && switchedManager.state?.status == .paused,
              "Late multipart capability cannot dispatch after owner changes")
        AuthStore.currentAccessToken = "offline-fixture-only"
        check(try Data(contentsOf: originalURL) == originalBytes, "Multipart pause and recovery preserve original bytes")
    }

    @MainActor static func videoRestartRuntimeTests(root: URL) async throws {
        let owner = AuthStore.jwtSubject("offline-fixture-only")!
        func state(_ api: RecoveryAPI) -> UploadManager.State {
            var s = UploadManager.State(filePath: "original.jpg", bytesTotal: FileStore.fileSize(root.appendingPathComponent("original.jpg")),
                status: .failed, mode: "single", assetID: api.oldID)
            s.ownerID = owner; s.restartRequired = true; s.transportVersion = 2
            s.failureMessage = "Previous transfer failed"
            s.terminalError = "Previous terminal error"
            return s
        }
        func until(_ message: String, _ predicate: () -> Bool) async {
            for _ in 0..<1_000 {
                if predicate() { check(true, message); return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            check(false, message)
        }
        let delayed = RecoveryAPI(); delayed.holdRestart = true
        delayed.completionFailure = .server(status: 409, code: "conflict", message: "upload is terminal or expired")
        let session = RecoverySession()
        var writes: [UploadManager.State?] = []
        let manager = UploadManager(api: delayed, session: session, recovering: state(delayed), persistState: { writes.append($0); return true })
        let restart = Task { await manager.restartConfirmed() }
        await until("Video restart actually reaches held server response") { delayed.heldRestart != nil }
        let savedID = manager.state?.id
        let savedIntent = manager.state?.restartIntent?.operationID
        manager.cancel()
        manager.begin(fileURL: root.appendingPathComponent("multipart.mov"), cellularApproved: true)
        check(manager.state?.id == savedID && manager.state?.restartIntent?.operationID == savedIntent,
              "Cancel or new begin cannot erase an unresolved linked restart")
        delayed.heldRestart?.resume()
        await restart.value
        check(manager.state?.assetID == delayed.newID && manager.state?.restartIntent == nil,
              "Real video manager atomically adopts linked child")
        check(!writes.drop(while: { $0?.restartIntent == nil }).contains(where: {
            $0 == nil || ($0?.assetID == delayed.oldID && $0?.restartIntent == nil)
        }), "Video receipt never clears intent before child identity is durable")
        check(manager.state?.status == .uploading && manager.state?.failureMessage == nil &&
              manager.state?.terminalError == nil && manager.lastFailureMessage == nil && !manager.restartingUpload,
              "Confirmed video Restart enters uploading and clears stale failure without another Resume")
        await until("Confirmed video Restart automatically dispatches its admitted child") {
            session.fixtureTasks.count == 1 && session.fixtureTasks[0].starts == 1
        }
        check(session.fixtureTasks[0].taskDescription == "single:\(delayed.newID)",
              "Automatic restart dispatch uses the persisted child, not its parent")
        manager.pause()
        check(delayed.creates == 0 && delayed.replacements == 1, "Video restart never calls fresh reserve")

        let lost = RecoveryAPI(); lost.loseRestartReplyOnce = true
        lost.completionFailure = .server(status: 409, code: "conflict", message: "upload is terminal or expired")
        let lostManager = UploadManager(api: lost, session: RecoverySession(), recovering: state(lost), persistState: { _ in true })
        await lostManager.restartConfirmed()
        let firstIntent = lostManager.state?.restartIntent?.operationID
        lostManager.cancel()
        check(lostManager.state?.restartIntent?.operationID == firstIntent && firstIntent != nil,
              "Lost video restart response retains intent even after Cancel")
        await lostManager.restartConfirmed()
        lostManager.pause()
        check(lost.restartKeys.count == 2 && Set(lost.restartKeys).count == 1 && lost.replacements == 1,
              "Actual video retry reuses saved restart UUID after lost response")

        let completed = RecoveryAPI(); completed.completed = true
        let completedSession = RecoverySession()
        let completedManager = UploadManager(api: completed, session: completedSession, recovering: state(completed), persistState: { _ in true })
        await completedManager.restartConfirmed()
        check(completedManager.state?.status == .done && completed.restartKeys.isEmpty && completedSession.fixtureTasks.isEmpty,
              "Video completion winner uses no replacement or physical transfer")

        let ticketAPI = RecoveryAPI(); ticketAPI.holdTicket = true
        let ticketSession = RecoverySession()
        var newState = state(ticketAPI); newState.assetID = nil; newState.mode = "pending"; newState.restartRequired = false
        let ticketManager = UploadManager(api: ticketAPI, session: ticketSession, recovering: newState, persistState: { _ in true })
        ticketManager.resume()
        await until("Initial video reservation actually waits for response") { ticketAPI.heldTicket != nil }
        AuthStore.currentAccessToken = "other-owner-fixture"
        ticketAPI.heldTicket?.resume()
        await until("Late original-owner ticket is retained paused") { ticketManager.state?.assetID == ticketAPI.oldID }
        check(ticketManager.state?.status == .paused && ticketManager.state?.ownerID == owner && ticketSession.fixtureTasks.isEmpty,
              "Account change before ticket response must not dispatch original-owner media")
        ticketManager.resume()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(ticketSession.fixtureTasks.isEmpty && ticketAPI.renews == 0,
              "Another owner cannot resume existing upload or send metadata")

        AuthStore.currentAccessToken = nil
        let anonymousAPI = RecoveryAPI()
        var anonymousState = newState; anonymousState.ownerID = nil
        let anonymousSession = RecoverySession()
        let anonymousManager = UploadManager(api: anonymousAPI, session: anonymousSession, recovering: anonymousState, persistState: { _ in true })
        anonymousManager.resume()
        await until("First-launch video binds anonymous account before dispatch") { anonymousSession.fixtureTasks.count == 1 }
        check(anonymousManager.state?.ownerID == owner && anonymousAPI.creates == 1,
              "Owner fence preserves no-login first-launch upload")
        anonymousManager.pause()

        let enumerationAPI = RecoveryAPI()
        let enumerationSession = RecoverySession(); enumerationSession.deferEnumeration = true
        let suspended = RecoveryTask(92); suspended.taskDescription = "single:\(enumerationAPI.oldID)"
        enumerationSession.fixtureTasks = [suspended]
        let enumerationManager = UploadManager(api: enumerationAPI, session: enumerationSession,
            recovering: state(enumerationAPI), persistState: { _ in true })
        enumerationManager.resume()
        AuthStore.currentAccessToken = "other-owner-fixture"
        for callback in enumerationSession.enumerations { callback([suspended]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        check(suspended.starts == 0 && enumerationManager.state?.status == .paused,
              "Delayed OS enumeration cannot resume previous-owner transfer")
        AuthStore.currentAccessToken = "offline-fixture-only"

        var heldPhotos: [CheckedContinuation<String, Error>] = []
        var dispatchedPhotos = 0
        var batchNotices = 0
        let batchManager = UploadManager(api: RecoveryAPI(), session: RecoverySession(), recovering: newState,
            batchUpload: { _, _ in
                dispatchedPhotos += 1
                return try await withCheckedThrowingContinuation { heldPhotos.append($0) }
            }, persistState: { _ in true })
        let observer = NotificationCenter.default.addObserver(forName: UploadManager.photosDidCompleteNotification,
            object: batchManager, queue: nil) { _ in batchNotices += 1 }
        batchManager.beginPhotoBatch(listingID: UUID(), fileURLs: Array(repeating: root.appendingPathComponent("original.jpg"), count: 6))
        await until("Actual batch starts only three concurrent photos") { heldPhotos.count == 3 }
        AuthStore.currentAccessToken = "other-owner-fixture"
        for continuation in heldPhotos { continuation.resume(returning: UUID().uuidString) }
        try await Task.sleep(nanoseconds: 50_000_000)
        check(dispatchedPhotos == 3 && batchNotices == 0 && batchManager.photoProgress?.completed == 0,
              "Photo batch account change stops new files and stale completion notification")
        NotificationCenter.default.removeObserver(observer)
        AuthStore.currentAccessToken = "offline-fixture-only"

        let otherOwner = AuthStore.jwtSubject("other-owner-fixture")!
        let otherPhoto = DirectUploadJournal.PendingPhoto(id: "other-owner-receipt",
            source: .init(ownerID: otherOwner, relativePath: "other-original.jpg", listingID: UUID(),
                role: "capture", contentType: "image/jpeg", keyPrefix: "photo", bytes: 10,
                sha256: String(repeating: "b", count: 64)), message: "Upload interrupted", needsRestart: false, restartGeneration: nil)
        var heldPhotoRead: CheckedContinuation<[DirectUploadJournal.PendingPhoto], Error>?
        let recoveryManager = UploadManager(api: RecoveryAPI(), session: RecoverySession(), recovering: newState,
            pendingPhotos: { requestedOwner in
                if requestedOwner == owner { return try await withCheckedThrowingContinuation { heldPhotoRead = $0 } }
                return [otherPhoto]
            }, persistState: { _ in true })
        check(!recoveryManager.currentUploadOwnerMismatch, "Original workspace keeps video controls available")
        let oldRead = Task { await recoveryManager.refreshPhotoRecovery() }
        await until("Old-owner photo journal read is actually waiting") { heldPhotoRead != nil }
        AuthStore.currentAccessToken = "other-owner-fixture"
        check(recoveryManager.currentUploadOwnerMismatch, "Different workspace identifies owner-only video controls")
        await recoveryManager.refreshPhotoRecovery()
        heldPhotoRead?.resume(throwing: CocoaError(.fileReadNoPermission))
        await oldRead.value
        check(recoveryManager.pendingPhotos.map(\.id) == [otherPhoto.id] && recoveryManager.photoRecoveryError == nil,
              "Late old-owner photo read failure cannot overwrite new workspace recovery UI")

        AuthStore.currentAccessToken = "offline-fixture-only"
        heldPhotoRead = nil
        let oldSuccess = Task { await recoveryManager.refreshPhotoRecovery() }
        await until("Old-owner successful photo read is actually waiting") { heldPhotoRead != nil }
        AuthStore.currentAccessToken = "other-owner-fixture"
        await recoveryManager.refreshPhotoRecovery()
        heldPhotoRead?.resume(returning: [])
        await oldSuccess.value
        check(recoveryManager.pendingPhotos.map(\.id) == [otherPhoto.id],
              "Late old-owner photo success cannot clear current workspace receipts")
        AuthStore.currentAccessToken = "offline-fixture-only"
    }
}
