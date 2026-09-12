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

        // A ticket whose rounds all ran dry used to be probed forever: every
        // later attempt reconciled the same dead reservation under the same
        // content key and failed the same way, so that photo could never be
        // uploaded again. The first call still never replaces anything on its
        // own; it journals the exhaustion, and only the NEXT explicit attempt
        // may retire the ticket and reserve afresh.
        let stuck = RecoveryAPI()
        stuck.completionFailure = .server(status: 503, code: "UPSTREAM", message: "Stored receipt is not yet provable")
        stuck.refuseRenewal = true
        await expectFailure("A call whose rounds all fail reports the failure") { _ = try await upload(stuck, "stuck") }
        check(stuck.physicalWrites == 1 && stuck.creates == 1 && stuck.cancels == 0 && stuck.renews == 2,
              "First call never retires or replaces the reservation on its own")
        let contentKey = "\(AuthStore.jwtSubject("fixture")!)|photo:"
            + DirectUploader.sha256Hex("\(listing.uuidString)|capture|\(original!)|\(bytes.count)")
        let stuckJournal = try await DirectUploadJournal(directory: root.appendingPathComponent("stuck")).load(contentKey)
        check(stuckJournal?.recoveryExhausted == true && stuckJournal?.dispatched == true
              && stuckJournal?.ticket?.assetID == stuck.oldID,
              "Exhaustion is journaled without forgetting the dispatch or the ticket")
        // The server caught up (its bounded re-plan proved the receipt): the
        // same ticket completes — no abort, no second reservation.
        stuck.completionFailure = nil
        check(try await upload(stuck, "stuck") == stuck.oldID, "Later attempt completes the same ticket once the server can prove it")
        check(stuck.creates == 1 && stuck.cancels == 0 && stuck.physicalWrites == 1, "A ticket that recovered is never replaced")

        let dead = RecoveryAPI()
        dead.completionFailure = .server(status: 503, code: "UPSTREAM", message: "Stored receipt is not yet provable")
        dead.refuseRenewal = true
        await expectFailure("Exhausted first call fails") { _ = try await upload(dead, "dead") }
        check(dead.cancels == 0 && dead.creates == 1, "Exhaustion alone does not abort anything")
        // Still no receipt and still no re-plan on the deliberate retry: retire
        // the ticket (durable intent, then abort) and send under a fresh one.
        dead.completionFailure = nil; dead.stored = false; dead.abortable = true
        check(try await upload(dead, "dead") == dead.newID, "Deliberate retry after exhaustion replaces an unplannable ticket")
        check(dead.cancels == 1 && dead.creates == 2 && Set(dead.keys).count == 1,
              "Exactly one abort and one replacement, under the same content key")
        check(dead.physicalWrites == 2 && dead.log.suffix(6) == ["complete", "renew", "cancel", "create", "put", "complete"],
              "Replacement probes, cancels, reserves and only then writes once more")

        let vanished = RecoveryAPI()
        vanished.completionFailure = .server(status: 404, code: "not_found", message: "Asset not found")
        await expectFailure("A vanished reservation fails the call that finds it gone") { _ = try await upload(vanished, "vanished") }
        check(vanished.transfers == 1 && vanished.renews == 0 && vanished.cancels == 0 && vanished.creates == 1,
              "A gone row stops the rounds at once, without a silent replacement")
        vanished.completionFailure = nil; vanished.missing = true
        check(try await upload(vanished, "vanished") == vanished.newID, "Deliberate retry reserves afresh for a vanished row")
        check(vanished.cancels == 0 && vanished.creates == 2, "Nothing is aborted when the row is already gone")

        let refused = RecoveryAPI()
        refused.completionFailure = .server(status: 413, code: "payload_too_large", message: "That file is too large to send.")
        await expectFailure("Request-side rejection fails at once") { _ = try await upload(refused, "refused") }
        refused.completionFailure = nil; refused.stored = false; refused.refuseRenewal = true; refused.abortable = true
        await expectFailure("Unplannable ticket still fails without a prior exhausted call") { _ = try await upload(refused, "refused") }
        check(refused.cancels == 0 && refused.creates == 1,
              "A request-side rejection never licenses a replacement on the next attempt")

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
        try await boundedRecoveryTests(root: root)
        print("PASS UploadRecoveryTests \(assertions) assertions")
    }

    @MainActor static func until(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { check(true, message); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check(false, message)
    }

    /// The engine's recovery must be bounded and its dead ends must offer a
    /// real way out. Part-URL refusals used to loop every five seconds forever
    /// with nothing on screen; per-part transport failures used to spend one
    /// whole-upload budget between them; and an exhausted ticket had only a
    /// Resume that failed the same way. Real manager, fixture session.
    @MainActor static func boundedRecoveryTests(root: URL) async throws {
        FileStore.documents = root
        let originalURL = root.appendingPathComponent("bounded.mov")
        let originalBytes = Data(repeating: 98, count: 64)
        try originalBytes.write(to: originalURL)
        func state(_ api: MultipartRecoveryAPI) -> UploadManager.State {
            var record = UploadManager.State(filePath: "bounded.mov", bytesTotal: 64,
                status: .paused, mode: "multipart", assetID: api.assetID,
                uploadID: "fixture-session", partSize: 16, partCount: 4)
            record.parts = (1...4).map { .init(number: $0, offset: Int64($0 - 1) * 16, length: 16) }
            record.transportVersion = 2
            record.ticketKey = "immutable-batch-fixture"
            return record
        }
        func running(_ session: RecoverySession, _ api: MultipartRecoveryAPI, part n: Int) -> RecoveryTask? {
            session.fixtureTasks.last { $0.taskDescription == "part:\(api.assetID):\(n)" && $0.fixtureState == .running }
        }
        func drop(_ manager: UploadManager, _ session: RecoverySession, _ task: RecoveryTask?) {
            guard let task else { check(false, "Expected an in-flight fixture task to fail"); return }
            task.fixtureState = .completed
            manager.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        }
        func land(_ manager: UploadManager, _ session: RecoverySession, _ task: RecoveryTask?, _ etag: String) {
            guard let task else { check(false, "Expected an in-flight fixture task to land"); return }
            task.fixtureResponse = HTTPURLResponse(url: URL(string: "https://fixture.invalid/")!,
                statusCode: 200, httpVersion: nil, headerFields: ["ETag": etag])
            task.fixtureState = .completed
            manager.urlSession(session, task: task, didCompleteWithError: nil)
        }

        // 1. Storage keeps refusing to plan parts: eight bounded retries with
        //    backoff, then a visible failed state that offers Start over and
        //    keeps the ticket (a regained network may still finish it).
        let refusing = MultipartRecoveryAPI()
        refusing.partURLFailure = .server(status: 503, code: "upstream",
            message: "Transfer needs recovery or cancellation; no second physical write is authorized")
        let refusingSession = RecoverySession()
        var refusingPersisted: UploadManager.State?
        let refusingManager = UploadManager(api: refusing, session: refusingSession, recovering: state(refusing),
                                            persistState: { refusingPersisted = $0; return true })
        refusingManager.retryDelayScale = 0.0002
        refusingManager.resume()
        await until("Part-URL refusals end in a visible failure, not an endless five-second loop") {
            refusingManager.state?.status == .failed
        }
        check(refusing.partRequests.count == 9, "Eight bounded retries after the first refusal, then it stops")
        check(refusingManager.state?.recoveryExhausted == true && refusingManager.state?.canStartOver == true,
              "Exhausted part-URL recovery offers Start over")
        check(refusingManager.state?.terminalError == nil && refusingManager.state?.assetID == refusing.assetID,
              "The exhausted record keeps its ticket and stays resumable on a network regain")
        check(refusingManager.state?.failureMessage?.contains("Start over") == true, "The failure says what to do next")
        check(refusingPersisted?.recoveryExhausted == true, "Exhaustion survives a relaunch")
        check(refusingSession.fixtureTasks.isEmpty && refusing.creates == 0, "Nothing was dispatched or re-reserved without a planned URL")

        // 2. Start over: retire that ticket, reserve afresh under a NEW
        //    operation key, and send from part one. The original is untouched.
        let freshID = UUID().uuidString
        refusing.partURLFailure = nil
        refusing.freshTicket = UploadTicket(assetID: freshID, mode: .multipart, uploadID: "fixture-session",
            partSize: 16, partCount: 4, transportVersion: 2, uploaded: false, replayed: false)
        refusingManager.startOver()
        await until("Start over reserves afresh and dispatches the first parts") { refusingSession.fixtureTasks.count == 3 }
        await until("Start over retires the old ticket exactly once") { refusing.aborts == 1 }
        check(refusing.creates == 1 && refusing.keys.last?.hasPrefix("ticket:") == true
              && refusing.keys.last != "immutable-batch-fixture",
              "One replacement reservation, under a new operation key rather than the retired one")
        check(refusingManager.state?.assetID == freshID && refusingManager.state?.status == .uploading
              && refusingManager.state?.recoveryExhausted == nil
              && refusingManager.state?.ticketKey != "immutable-batch-fixture",
              "The record now belongs to the replacement ticket")
        check(refusing.partRequests.last == [1, 2, 3], "The fresh ticket starts from part one")
        check(refusingPersisted?.assetID == freshID, "Replacement identity is durable before dispatch")
        check(try Data(contentsOf: originalURL) == originalBytes, "Start over never touches the original")

        // 3. Per-part accounting: seven transport failures spread over parts 1
        //    and 3, with parts 2 and 4 landing in between. The old whole-upload
        //    budget failed this at the fifth; each part now carries its own.
        let flaky = MultipartRecoveryAPI()
        let flakySession = RecoverySession()
        let flakyManager = UploadManager(api: flaky, session: flakySession, recovering: state(flaky), persistState: { _ in true })
        flakyManager.resume()
        await until("Flaky-link fixture dispatches three parts") { flakySession.fixtureTasks.count == 3 }
        drop(flakyManager, flakySession, running(flakySession, flaky, part: 1))
        await until("Part 1 relaunches after its first failure") { flakySession.fixtureTasks.count == 4 }
        land(flakyManager, flakySession, running(flakySession, flaky, part: 2), "e2")
        await until("Part 4 dispatches once part 2 lands") { flakySession.fixtureTasks.count == 5 }
        drop(flakyManager, flakySession, running(flakySession, flaky, part: 3))
        await until("Part 3 relaunches") { flakySession.fixtureTasks.count == 6 }
        drop(flakyManager, flakySession, running(flakySession, flaky, part: 1))
        await until("Part 1 relaunches a second time") { flakySession.fixtureTasks.count == 7 }
        land(flakyManager, flakySession, running(flakySession, flaky, part: 4), "e4")
        drop(flakyManager, flakySession, running(flakySession, flaky, part: 3))
        await until("Part 3 relaunches a second time") { flakySession.fixtureTasks.count == 8 }
        drop(flakyManager, flakySession, running(flakySession, flaky, part: 1))
        await until("Part 1 relaunches a third time") { flakySession.fixtureTasks.count == 9 }
        drop(flakyManager, flakySession, running(flakySession, flaky, part: 3))
        await until("Part 3 relaunches a third time") { flakySession.fixtureTasks.count == 10 }
        drop(flakyManager, flakySession, running(flakySession, flaky, part: 1))
        await until("Part 1 relaunches a fourth time") { flakySession.fixtureTasks.count == 11 }
        check(flakyManager.state?.status == .uploading,
              "Seven part failures across two parts are not five strikes against the upload")
        check(flakyManager.state?.parts.map(\.retryCount) == [4, 0, 3, 0], "Each part carries only its own failures")
        land(flakyManager, flakySession, running(flakySession, flaky, part: 1), "e1")
        land(flakyManager, flakySession, running(flakySession, flaky, part: 3), "e3")
        await until("Upload completes once every part has landed") { flakyManager.state?.status == .done }
        check(flaky.acceptedParts?.map(\.etag) == ["e1", "e2", "e3", "e4"] && flaky.creates == 0,
              "Completion carries every receipt and never a new reservation")

        // 4. One part failing its own transfer six times, with progress
        //    elsewhere, fails the upload as that part's problem — resumable,
        //    not exhausted — and an explicit Resume relaunches only that part.
        let stubborn = MultipartRecoveryAPI()
        let stubbornSession = RecoverySession()
        let stubbornManager = UploadManager(api: stubborn, session: stubbornSession, recovering: state(stubborn), persistState: { _ in true })
        stubbornManager.resume()
        await until("Stubborn-part fixture dispatches three parts") { stubbornSession.fixtureTasks.count == 3 }
        for round in 1...3 {
            drop(stubbornManager, stubbornSession, running(stubbornSession, stubborn, part: 1))
            await until("Part 1 relaunches (\(round))") { stubbornSession.fixtureTasks.count == 3 + round }
        }
        land(stubbornManager, stubbornSession, running(stubbornSession, stubborn, part: 2), "s2")
        await until("Part 4 dispatches after part 2 lands") { stubbornSession.fixtureTasks.count == 7 }
        for round in 4...5 {
            drop(stubbornManager, stubbornSession, running(stubbornSession, stubborn, part: 1))
            await until("Part 1 relaunches (\(round))") { stubbornSession.fixtureTasks.count == 4 + round }
        }
        drop(stubbornManager, stubbornSession, running(stubbornSession, stubborn, part: 1))
        await until("The sixth failure of one part fails the upload") { stubbornManager.state?.status == .failed }
        check(stubbornManager.state?.parts.first?.status == .failed
              && stubbornManager.state?.failureMessage?.contains("Part 1") == true,
              "The failure names the part that kept failing")
        check(stubbornManager.state?.recoveryExhausted == nil && stubbornManager.state?.canStartOver == false
              && stubbornManager.state?.terminalError == nil,
              "A part's own exhaustion is resumable, not a dead ticket")
        stubbornManager.resume()
        await until("Resume relaunches only the failed part") { stubbornSession.fixtureTasks.count == 10 }
        check(stubborn.partRequests.last == [1] && stubborn.creates == 0, "Resume keeps the ticket and the landed receipts")
        land(stubbornManager, stubbornSession, running(stubbornSession, stubborn, part: 1), "s1")
        land(stubbornManager, stubbornSession, running(stubbornSession, stubborn, part: 3), "s3")
        land(stubbornManager, stubbornSession, running(stubbornSession, stubborn, part: 4), "s4")
        await until("Stubborn upload completes after Resume") { stubbornManager.state?.status == .done }
        check(stubborn.acceptedParts?.map(\.etag) == ["s1", "s2", "s3", "s4"], "Every retained receipt reaches completion")
        check(try Data(contentsOf: originalURL) == originalBytes, "Bounded recovery preserves original bytes")
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
        check(try Data(contentsOf: originalURL) == originalBytes, "Multipart pause and recovery preserve original bytes")
    }
}
