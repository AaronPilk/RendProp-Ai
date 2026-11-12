import Foundation

// Offline checks for optional photo feedback. No network, provider, UI or
// customer media: exact-version attribution, client key stability, the durable
// queue's dedupe, revision and adoption rules, unknown provenance, separate
// outcome signals, and photo history (review flags, selections, files) left
// exactly as it was. Compiled with PhotoCaptureStorage, PhotoVersionHistory and
// PhotoFeedback by run-photo-feedback.py.

typealias Event = PhotoFeedback.SignalEvent

/// A closed transport: every request is recorded and answered from a script.
final class ScriptedTransport {
    var sent: [(route: PhotoFeedback.Route, body: [String: Any], library: UUID)] = []
    var replies: [Result<PhotoFeedback.Reply, Error>] = []
    var current = true
    var duringSend: (() -> Void)?

    func send(_ route: PhotoFeedback.Route, _ body: [String: Any], _ library: UUID) throws -> PhotoFeedback.Reply {
        sent.append((route: route, body: body, library: library))
        let hook = duringSend
        duringSend = nil
        hook?()
        precondition(!replies.isEmpty, "a request was sent that the scenario did not expect")
        return try replies.removeFirst().get()
    }
}

enum Wire {
    static func reply(_ status: Int, _ object: [String: Any]) -> Result<PhotoFeedback.Reply, Error> {
        .success(PhotoFeedback.Reply(status: status, data: try! JSONSerialization.data(withJSONObject: object)))
    }
    static func canonical(_ body: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
    static func object(_ body: [String: Any]) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: canonical(body)) as! [String: Any]
    }
    static func output(_ body: [String: Any]) -> [String: Any] {
        object(body)["output"] as? [String: Any] ?? [:]
    }
}

@main
struct PhotoFeedbackTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-feedback-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("listing", isDirectory: true)
        let queue = root.appendingPathComponent("PhotoFeedback", isDirectory: true)
        let actor = UUID().uuidString.lowercased(), otherActor = UUID().uuidString.lowercased()
        let library = UUID(), otherLibrary = UUID()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // MARK: Exact versions, with and without a recorded provenance row

        let provenanceA = UUID().uuidString.uppercased(), provenanceB = UUID().uuidString.lowercased()
        let bytes = Data("retained-source".utf8)
        try PhotoVersionHistory.saveCapture(original: bytes, enhanced: bytes, id: "capture", directory: photos)
        let first = try PhotoVersionHistory.saveEdit(jpeg: Data("declutter-a".utf8), id: "edit-a", parentID: "capture",
            sourceID: "capture", edit: "declutter", style: nil, disclosure: "Items digitally removed.",
            provenanceID: provenanceA, provenanceRecorded: true, directory: photos)
        let second = try PhotoVersionHistory.saveEdit(jpeg: Data("declutter-b".utf8), id: "edit-b", parentID: "edit-a",
            sourceID: "edit-a", edit: "declutter", style: nil, disclosure: "Items digitally removed.",
            provenanceID: provenanceB, provenanceRecorded: true, directory: photos)
        let unrecorded = try PhotoVersionHistory.saveEdit(jpeg: Data("sky".utf8), id: "edit-c", parentID: "edit-b",
            sourceID: "edit-b", edit: "sky", style: nil, disclosure: nil,
            provenanceID: UUID().uuidString, provenanceRecorded: false, directory: photos)
        let missing = try PhotoVersionHistory.saveEdit(jpeg: Data("lawn".utf8), id: "edit-d", parentID: "edit-c",
            sourceID: "edit-c", edit: "lawn", style: nil, disclosure: nil,
            provenanceID: nil, provenanceRecorded: false, directory: photos)
        let invented = try PhotoVersionHistory.saveEdit(jpeg: Data("twilight".utf8), id: "edit-e", parentID: "edit-d",
            sourceID: "edit-d", edit: "twilight", style: nil, disclosure: nil,
            provenanceID: "provider-row", provenanceRecorded: true, directory: photos)
        guard let capture = try PhotoVersionHistory.load(directory: photos).versions["capture"] else {
            preconditionFailure("capture version saved")
        }
        let historyFile = photos.appendingPathComponent(".photo-history.json")
        let historyBefore = try Data(contentsOf: historyFile)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: photos.path).sorted()

        guard let outA = PhotoFeedback.Output(version: first), let outB = PhotoFeedback.Output(version: second) else {
            preconditionFailure("recorded provenance qualifies for feedback")
        }
        check(outA.provenanceID == provenanceA.lowercased() && outB.provenanceID == provenanceB,
              "feedback attaches to each version's own recorded provenance row")
        check(outA != outB, "two outputs from one source stay distinct")
        check(outA.outputSHA256 == nil && outB.outputSHA256 == nil,
              "no output hash is invented for versions that do not carry one")
        check(PhotoFeedback.Output(version: unrecorded) == nil, "unrecorded provenance stays unknown")
        check(PhotoFeedback.Output(version: missing) == nil, "missing provenance stays unknown")
        check(PhotoFeedback.Output(version: invented) == nil, "a non-UUID provenance value is never treated as a row id")
        check(PhotoFeedback.Output(version: capture) == nil, "originals and phone enhancements have no AI output to rate")
        let hash = String(repeating: "ab", count: 32)
        check(PhotoFeedback.Output(provenanceID: provenanceB, outputSHA256: hash.uppercased())?.outputSHA256 == hash,
              "a carried output hash is sent normalized")
        check(PhotoFeedback.Output(provenanceID: provenanceB, outputSHA256: "not-a-hash")?.outputSHA256 == nil,
              "a malformed output hash is never sent")

        // MARK: Opinions

        let messy = PhotoFeedback.Draft(verdict: .needsWork, reasons: [.other, .blockedDoorwayOrOpening, .other],
                                        note: "  door frame  ")
        check(messy.reasons == [.blockedDoorwayOrOpening, .other] && messy.note == "door frame",
              "reasons keep scope order without duplicates and notes are trimmed")
        check(PhotoFeedback.Draft(verdict: .useful, reasons: [.other], note: "x") == PhotoFeedback.Draft(verdict: .useful),
              "useful carries no reasons or note")
        check(!PhotoFeedback.Draft(verdict: .needsWork).isComplete, "needs work requires at least one reason")
        let long = String(repeating: "\u{E9}", count: 600)
        check(PhotoFeedback.Draft(verdict: .needsWork, reasons: [.other], note: long).note?.unicodeScalars.count == 500,
              "notes are bounded to 500 code points")
        check(PhotoFeedback.Reason.allCases.map(\.label) == [
            "Changed permanent property features", "Moved or changed an appliance", "Blocked a doorway or opening",
            "Inconsistent furniture between views", "Visible visual artifacts", "Requested edit was incomplete",
            "Personal style preference", "Other"], "the owner's eight reasons, in the owner's order")
        check(PhotoFeedback.Reason.allCases.map(\.rawValue) == [
            "changed_permanent_features", "moved_or_changed_appliance", "blocked_doorway_or_opening",
            "inconsistent_furniture_between_views", "visible_visual_artifacts", "requested_edit_incomplete",
            "personal_style_preference", "other"], "contract wire strings for reasons")

        // MARK: Durable queue, keys and revisions

        let store = PhotoFeedbackStore(directory: queue)
        do {
            _ = try store.record(PhotoFeedback.Draft(verdict: .needsWork), output: outA, library: library, actor: actor, now: t0)
            preconditionFailure("an incomplete needs-work opinion must not be stored")
        } catch { checks += 1 }
        check((try? store.record(.init(verdict: .useful), output: outA, library: library, actor: "test", now: t0)) == nil,
              "only a real account id can own a queue")
        let usefulA = try store.record(.init(verdict: .useful), output: outA, library: library, actor: actor, now: t0)
        check(usefulA.revision == 1 && !usefulA.delivered && usefulA.provenanceID == outA.provenanceID
                && usefulA.libraryOrgID == library, "a new opinion is stored as revision 1 before any network call")
        check(PhotoFeedback.isClientKey(usefulA.clientKey) && usefulA.clientKey.hasPrefix("ios-"),
              "client keys match the contract format")
        let wireA = Wire.object(PhotoFeedback.feedbackBody(usefulA))
        let outputA = Wire.output(PhotoFeedback.feedbackBody(usefulA))
        check(outputA["provenance_id"] as? String == outA.provenanceID && outputA["output_sha256"] == nil,
              "the body names the exact output and no invented hash")
        check(wireA["client_key"] as? String == usefulA.clientKey && wireA["revision"] as? Int == 1
                && wireA["verdict"] as? String == "useful" && (wireA["reasons"] as? [String]) == []
                && wireA["note"] == nil && wireA["platform"] as? String == "ios", "contract 4.1 request body")
        let needsWorkB = try store.record(messy, output: outB, library: library, actor: actor, now: t0.addingTimeInterval(1))
        check(needsWorkB.clientKey != usefulA.clientKey, "every output gets its own key")
        check(store.feedback(provenanceID: outA.provenanceID, actor: actor) == usefulA,
              "an opinion on another version never changes this one")
        let wireB = Wire.object(PhotoFeedback.feedbackBody(needsWorkB))
        check((wireB["reasons"] as? [String]) == ["blocked_doorway_or_opening", "other"] && wireB["note"] as? String == "door frame"
                && wireB["verdict"] as? String == "needs_work", "reasons and note travel as contract strings")
        let repeated = try store.record(.init(verdict: .useful), output: outA, library: library, actor: actor, now: t0.addingTimeInterval(5))
        check(repeated == usefulA, "the same opinion again is not a new revision")
        let revisedA = try store.record(.init(verdict: .needsWork, reasons: [.visibleVisualArtifacts]), output: outA,
                                        library: otherLibrary, actor: actor, now: t0.addingTimeInterval(10))
        check(revisedA.clientKey == usefulA.clientKey && revisedA.revision == 2 && revisedA.verdict == .needsWork
                && !revisedA.delivered, "a changed opinion bumps the revision under the same key")
        check(revisedA.libraryOrgID == library, "a revision keeps the library its output was first rated in")
        check(PhotoFeedbackStore(directory: queue).feedback(provenanceID: outA.provenanceID, actor: actor) == revisedA,
              "the queue is durable across store instances")
        let keys = (0..<256).map { _ in PhotoFeedback.newClientKey() }
        check(Set(keys).count == keys.count && keys.allSatisfy(PhotoFeedback.isClientKey), "keys are random and valid")
        let other = try store.record(.init(verdict: .useful), output: outA, library: library, actor: otherActor, now: t0)
        check(other.clientKey != usefulA.clientKey && store.feedback(provenanceID: outA.provenanceID, actor: actor)?.revision == 2,
              "another account rating the same output at the same time gets its own key and never touches this one")
        check(store.dueWork(actor: actor, library: library, now: t0.addingTimeInterval(10), ignoringBackoff: false).count == 2,
              "both unsent opinions are due")
        check(store.dueWork(actor: actor, library: otherLibrary, now: t0.addingTimeInterval(10), ignoringBackoff: false).isEmpty,
              "queued items are sent only while their own library is selected")

        // MARK: Delivery: offline, retry, duplicates and revisions

        let transport = ScriptedTransport()
        var clock = t0.addingTimeInterval(20)
        func pass(_ owner: String, ignoringBackoff: Bool = false) async -> PhotoFeedbackStore.DeliveryResult {
            await store.deliver(actor: owner, library: library, ignoringBackoff: ignoringBackoff, now: { clock },
                                isCurrent: { transport.current }, send: { try transport.send($0, $1, $2) })
        }

        transport.replies = [.failure(URLError(.notConnectedToInternet))]
        let offline = await pass(actor)
        check(offline == .deferred && transport.sent.count == 1, "an offline phone makes one attempt per pass")
        let firstBody = transport.sent[0].body
        check(transport.sent[0].route == .feedback && Wire.output(firstBody)["provenance_id"] as? String == outB.provenanceID
                && transport.sent[0].library == library, "the oldest opinion goes first, under its own library")
        let parkedB = store.feedback(provenanceID: outB.provenanceID, actor: actor)
        check(parkedB?.attempts == 1 && parkedB?.nextAttemptAt == clock.addingTimeInterval(30)
                && parkedB?.clientKey == needsWorkB.clientKey && parkedB?.delivered == false,
              "a failed send waits with backoff and keeps its key")
        check(store.dueWork(actor: actor, library: library, now: clock, ignoringBackoff: false).count == 1,
              "the postponed opinion waits while the other stays due")

        transport.replies = [
            Wire.reply(200, ["feedback_id": UUID().uuidString, "provenance_id": outB.provenanceID, "revision": 1,
                             "revision_count": 1, "state": "recorded", "verdict": "needs_work",
                             "reasons": ["blocked_doorway_or_opening", "other"], "note": "door frame"]),
            Wire.reply(503, ["error": "Database unavailable", "code": "upstream"])]
        let foreground = await pass(actor, ignoringBackoff: true)
        check(foreground == .deferred && transport.sent.count == 3,
              "a foreground retry resends the parked item, then stops at the next transient failure")
        check(Wire.canonical(transport.sent[1].body) == Wire.canonical(firstBody), "a retry sends the identical body and key")
        check(store.feedback(provenanceID: outB.provenanceID, actor: actor)?.delivered == true, "an accepted opinion is marked sent")
        let parkedA = store.feedback(provenanceID: outA.provenanceID, actor: actor)
        check(parkedA?.delivered == false && parkedA?.attempts == 1 && parkedA?.revision == 2, "a 503 keeps the opinion queued")

        clock = clock.addingTimeInterval(31)
        transport.replies = [Wire.reply(200, ["provenance_id": outA.provenanceID, "revision": 2, "revision_count": 2,
                                              "state": "revised", "verdict": "needs_work",
                                              "reasons": ["visible_visual_artifacts"], "note": NSNull()])]
        let drained = await pass(actor)
        let sentRevision = Wire.object(transport.sent[3].body)
        check(drained == .idle && transport.sent.count == 4 && sentRevision["revision"] as? Int == 2
                && sentRevision["client_key"] as? String == usefulA.clientKey, "revision 2 travels under the original key")
        let deliveredA = store.feedback(provenanceID: outA.provenanceID, actor: actor)
        check(deliveredA?.delivered == true && deliveredA?.serverRevisionCount == 2, "the revision is marked sent")
        let idle = await pass(actor, ignoringBackoff: true)
        check(idle == .idle && transport.sent.count == 4, "nothing is resent once delivered")
        _ = try store.record(.init(verdict: .needsWork, reasons: [.visibleVisualArtifacts]), output: outA, library: library,
                             actor: actor, now: clock)
        check(store.dueWork(actor: actor, library: library, now: clock, ignoringBackoff: true).isEmpty,
              "a duplicate submission of a delivered opinion queues nothing")

        _ = try store.record(.init(verdict: .useful), output: outB, library: library, actor: actor, now: clock)
        transport.duringSend = {
            _ = try? store.record(.init(verdict: .needsWork, reasons: [.changedPermanentFeatures]), output: outB,
                                  library: library, actor: actor, now: clock)
        }
        transport.replies = [
            Wire.reply(200, ["provenance_id": outB.provenanceID, "revision": 2, "revision_count": 2, "state": "revised",
                             "verdict": "useful", "reasons": [String]()]),
            Wire.reply(200, ["provenance_id": outB.provenanceID, "revision": 3, "revision_count": 3, "state": "revised",
                             "verdict": "needs_work", "reasons": ["changed_permanent_features"]])]
        let inFlight = await pass(actor)
        let inFlightRevisions = transport.sent.suffix(2).map { Wire.object($0.body)["revision"] as? Int }
        check(inFlight == .idle && inFlightRevisions == [2, 3],
              "a change made while a revision is in flight is sent next as a higher revision")
        let latestB = store.feedback(provenanceID: outB.provenanceID, actor: actor)
        check(latestB?.delivered == true && latestB?.revision == 3 && latestB?.verdict == .needsWork
                && latestB?.reasons == [.changedPermanentFeatures] && latestB?.clientKey == needsWorkB.clientKey,
              "the latest opinion wins under one key")

        _ = try store.record(.init(verdict: .useful), output: outB, library: library, actor: actor, now: clock)
        transport.replies = [Wire.reply(200, ["provenance_id": outB.provenanceID, "revision": 7, "revision_count": 5,
                                              "state": "replayed", "verdict": "needs_work",
                                              "reasons": ["inconsistent_furniture_between_views"], "note": "sofa differs"])]
        let replayed = await pass(actor)
        let heldB = store.feedback(provenanceID: outB.provenanceID, actor: actor)
        check(replayed == .idle && heldB?.delivered == true && heldB?.revision == 7 && heldB?.verdict == .needsWork
                && heldB?.reasons == [.inconsistentFurnitureBetweenViews] && heldB?.note == "sofa differs",
              "an older revision never replaces the newer opinion the server already holds")

        // MARK: Adoption on 409 feedback_exists

        let outC = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
        let localC = try store.record(.init(verdict: .needsWork, reasons: [.movedOrChangedAppliance]), output: outC,
                                      library: library, actor: actor, now: clock)
        transport.replies = [
            Wire.reply(409, ["error": "Feedback already exists", "code": "feedback_exists", "client_key": "studio:existing-key-c",
                             "revision": 4, "revision_count": 2, "verdict": "useful", "reasons": [String]()]),
            Wire.reply(200, ["provenance_id": outC.provenanceID, "revision": 5, "revision_count": 3, "state": "revised",
                             "verdict": "needs_work", "reasons": ["moved_or_changed_appliance"]])]
        let adoption = await pass(actor)
        let resent = Wire.object(transport.sent[transport.sent.count - 1].body)
        check(adoption == .idle && resent["client_key"] as? String == "studio:existing-key-c" && resent["revision"] as? Int == 5,
              "409 feedback_exists: adopt the server key and resend above its stored revision")
        let adoptedC = store.feedback(provenanceID: outC.provenanceID, actor: actor)
        check(adoptedC?.clientKey == "studio:existing-key-c" && adoptedC?.delivered == true && adoptedC?.verdict == .needsWork
                && localC.clientKey != adoptedC?.clientKey, "the adopted key now carries this phone's opinion")

        let outD = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
        _ = try store.record(.init(verdict: .useful), output: outD, library: library, actor: actor, now: clock)
        let beforeD = transport.sent.count
        transport.replies = [Wire.reply(409, ["error": "Feedback already exists", "code": "feedback_exists",
                                              "client_key": "studio:existing-key-d", "revision": 3, "revision_count": 3,
                                              "verdict": "useful", "reasons": [String]()])]
        let sameOpinion = await pass(actor)
        let adoptedD = store.feedback(provenanceID: outD.provenanceID, actor: actor)
        check(sameOpinion == .idle && transport.sent.count == beforeD + 1 && adoptedD?.clientKey == "studio:existing-key-d"
                && adoptedD?.revision == 3 && adoptedD?.delivered == true, "an identical stored opinion is adopted without resending")

        let outE = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
        _ = try store.record(.init(verdict: .useful), output: outE, library: library, actor: actor, now: clock)
        transport.replies = [
            Wire.reply(409, ["error": ["code": "feedback_exists", "client_key": "studio:nested-key-e", "revision_count": 1] as [String: Any]]),
            Wire.reply(200, ["provenance_id": outE.provenanceID, "revision": 2, "revision_count": 2, "state": "revised",
                             "verdict": "useful", "reasons": [String]()])]
        let nested = await pass(actor)
        let adoptedE = store.feedback(provenanceID: outE.provenanceID, actor: actor)
        check(nested == .idle && adoptedE?.clientKey == "studio:nested-key-e" && adoptedE?.revision == 2 && adoptedE?.delivered == true,
              "a nested error envelope is adopted the same way")

        let outF = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
        _ = try store.record(.init(verdict: .useful), output: outF, library: library, actor: actor, now: clock)
        transport.replies = [Wire.reply(409, ["error": "Feedback already exists", "code": "feedback_exists"])]
        _ = await pass(actor)
        check(store.feedback(provenanceID: outF.provenanceID, actor: actor) == nil,
              "feedback_exists without a usable key is dropped, never guessed")

        let outG = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
        _ = try store.record(.init(verdict: .useful), output: outG, library: library, actor: actor, now: clock)
        transport.replies = [Wire.reply(409, ["error": "Feedback already exists", "code": "feedback_exists",
                                              "client_key": usefulA.clientKey])]
        _ = await pass(actor)
        check(store.feedback(provenanceID: outG.provenanceID, actor: actor) == nil
                && store.feedback(provenanceID: outA.provenanceID, actor: actor)?.clientKey == usefulA.clientKey,
              "a key already bound to another output on this phone is never adopted")

        // The same refusal when the key's owner was queued after this output.
        let outH = PhotoFeedback.Output(provenanceID: UUID().uuidString)!, outI = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
        _ = try store.record(.init(verdict: .useful), output: outH, library: library, actor: actor, now: clock)
        let localI = try store.record(.init(verdict: .needsWork, reasons: [.other]), output: outI, library: library, actor: actor,
                                      now: clock.addingTimeInterval(1))
        transport.replies = [
            Wire.reply(409, ["error": "Feedback already exists", "code": "feedback_exists", "client_key": localI.clientKey]),
            Wire.reply(200, ["provenance_id": outI.provenanceID, "revision": 1, "revision_count": 1, "state": "recorded",
                             "verdict": "needs_work", "reasons": ["other"]])]
        _ = await pass(actor)
        let heldI = store.feedback(provenanceID: outI.provenanceID, actor: actor)
        check(store.feedback(provenanceID: outH.provenanceID, actor: actor) == nil && heldI?.clientKey == localI.clientKey
                && heldI?.delivered == true, "adopting a key never displaces a newer queued opinion that holds it")

        // MARK: Error classes

        func rated(_ replies: [Result<PhotoFeedback.Reply, Error>]) async throws
            -> (output: PhotoFeedback.Output, sent: PhotoFeedbackStore.FeedbackRecord,
                after: PhotoFeedbackStore.FeedbackRecord?, result: PhotoFeedbackStore.DeliveryResult) {
            let output = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
            clock = clock.addingTimeInterval(1)
            let sent = try store.record(.init(verdict: .needsWork, reasons: [.requestedEditIncomplete]), output: output,
                                        library: library, actor: actor, now: clock)
            transport.replies = replies
            // Earlier queued items are still in backoff, so only this one is due.
            let result = await pass(actor)
            return (output, sent, store.feedback(provenanceID: output.provenanceID, actor: actor), result)
        }
        let keyConflict = try await rated([Wire.reply(409, ["error": "Key belongs to another photo", "code": "feedback_key_conflict"])])
        check(keyConflict.after == nil, "409 feedback_key_conflict drops the item")
        let rerated = try store.record(.init(verdict: .useful), output: keyConflict.output, library: library, actor: actor, now: clock)
        check(rerated.clientKey != keyConflict.sent.clientKey && rerated.revision == 1, "the next opinion gets a new key")
        _ = store.apply(.drop("settled by the test"), to: rerated, actor: actor, now: clock)
        let revisionConflict = try await rated([
            Wire.reply(409, ["error": ["code": "feedback_revision_conflict"]]),
            Wire.reply(200, ["revision": 2, "revision_count": 1, "state": "revised", "verdict": "needs_work",
                             "reasons": ["requested_edit_incomplete"]])])
        check(revisionConflict.after?.revision == 2 && revisionConflict.after?.delivered == true
                && revisionConflict.after?.clientKey == revisionConflict.sent.clientKey,
              "409 feedback_revision_conflict bumps the revision and resends under the same key")
        for (status, code) in [(404, "output_not_found"), (403, "forbidden"), (400, "invalid_request"), (409, "output_mismatch")] {
            let dropped = try await rated([Wire.reply(status, ["error": "Refused", "code": code])])
            check(dropped.after == nil && dropped.result == .idle, "\(status) \(code) drops the item quietly")
        }
        for status in [401, 429, 500, 503] {
            let waiting = try await rated([Wire.reply(status, ["error": "Try again", "code": "upstream"])])
            check(waiting.after?.attempts == 1 && waiting.after?.delivered == false && waiting.after?.clientKey == waiting.sent.clientKey
                    && waiting.result == .deferred, "\(status) keeps the item queued under the same key")
        }
        let missingRoute = try await rated([Wire.reply(404, ["code": "NOT_FOUND", "message": "Requested function was not found"])])
        check(missingRoute.after?.attempts == 1 && missingRoute.after?.delivered == false && missingRoute.result == .deferred,
              "a 404 other than output_not_found (function not deployed yet) keeps the item queued")
        let foreign = try await rated([Wire.reply(200, ["provenance_id": UUID().uuidString, "revision": 1, "state": "recorded",
                                                        "verdict": "useful", "reasons": [String]()])])
        check(foreign.after == nil, "an answer naming another image never settles this one")
        let emptyBody = try await rated([.success(PhotoFeedback.Reply(status: 200, data: Data()))])
        check(emptyBody.after?.delivered == true && emptyBody.after?.revision == 1, "an empty 2xx body still settles the item")

        let lateActor = UUID().uuidString.lowercased()
        let outLate = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
        let late = try store.record(.init(verdict: .useful), output: outLate, library: library, actor: lateActor, now: clock)
        transport.duringSend = { transport.current = false }
        transport.replies = [Wire.reply(200, ["provenance_id": outLate.provenanceID, "revision": 1, "state": "recorded",
                                              "verdict": "useful", "reasons": [String]()])]
        let interrupted = await pass(lateActor)
        transport.current = true
        check(interrupted == .interrupted && store.feedback(provenanceID: outLate.provenanceID, actor: lateActor) == late,
              "an answer arriving after an account change is not applied")

        // MARK: Outcome signals stay separate from opinions

        let signalActor = UUID().uuidString.lowercased()
        func queueSignal(_ signal: PhotoFeedback.Signal, _ detail: PhotoFeedback.SignalDetail?, _ output: PhotoFeedback.Output) throws -> Bool {
            clock = clock.addingTimeInterval(1)
            return try store.recordSignal(signal, detail: detail, output: output, library: library, actor: signalActor, now: clock)
        }
        let ackQueued = try queueSignal(.accuracyAck, .stagingReview, outA)
        let ackRepeat = try queueSignal(.accuracyAck, .stagingReview, outA)
        let downloadQueued = try queueSignal(.export, .download, outA)
        let kitQueued = try queueSignal(.export, .kitExport, outA)
        let automaticQueued = try queueSignal(.automaticSelection, .listingSelection, outB)
        let publishedQueued = try queueSignal(.publication, .publishedTour, outB)
        let manualQueued = try queueSignal(.manualSelection, nil, outB)
        check(ackQueued && !ackRepeat, "repeating an action queues nothing new")
        check(downloadQueued && kitQueued && automaticQueued && publishedQueued && manualQueued,
              "different outcomes and details stay separate events")
        let queuedSignals = store.signals(actor: signalActor)
        check(queuedSignals.count == 6 && Set(queuedSignals.map(\.clientKey)).count == 6
                && queuedSignals.allSatisfy { $0.state == .pending && PhotoFeedback.isClientKey($0.clientKey) },
              "each event has its own key")
        check(store.feedback(provenanceID: outA.provenanceID, actor: signalActor) == nil, "a signal is never an opinion")
        let ackWire = Wire.object(PhotoFeedback.signalBody(queuedSignals[0]))
        check(Wire.output(PhotoFeedback.signalBody(queuedSignals[0]))["provenance_id"] as? String == outA.provenanceID
                && ackWire["signal"] as? String == "accuracy_ack" && ackWire["detail"] as? String == "staging_review"
                && ackWire["client_key"] as? String == queuedSignals[0].clientKey && ackWire["platform"] as? String == "ios",
              "contract 4.2 signal body")
        check(Wire.object(PhotoFeedback.signalBody(queuedSignals[5]))["detail"] is NSNull, "a missing detail is sent as null")
        check(PhotoFeedback.classifySignal(PhotoFeedback.Reply(status: 404, data: Data(#"{"code":"NOT_FOUND"}"#.utf8))) == .retryLater
                && PhotoFeedback.classifySignal(PhotoFeedback.Reply(status: 404, data: Data(#"{"error":"Not found","code":"output_not_found"}"#.utf8)))
                    == .drop("output_not_found"), "a signal is dropped when its output is not found, not when the route is missing")

        let beforeSignals = transport.sent.count
        transport.replies = [Wire.reply(200, ["signal_id": UUID().uuidString, "state": "recorded"]),
                             Wire.reply(404, ["error": "Not found", "code": "output_not_found"]),
                             Wire.reply(503, ["error": "Try again", "code": "upstream"])]
        let signalPass = await pass(signalActor)
        let afterSignals = store.signals(actor: signalActor)
        check(signalPass == .deferred && transport.sent.count == beforeSignals + 3
                && transport.sent[beforeSignals].route == .signal, "signals use their own route and stop at a transient failure")
        check(afterSignals[0].state == .delivered && afterSignals[1].state == .dropped && afterSignals[2].state == .pending
                && afterSignals[2].attempts == 1 && afterSignals[2].clientKey == queuedSignals[2].clientKey,
              "a sent signal is kept as sent, a refused one as dropped and a failed one waits under its key")
        let resendDelivered = try queueSignal(.accuracyAck, .stagingReview, outA)
        let resendDropped = try queueSignal(.export, .download, outA)
        check(!resendDelivered && !resendDropped, "a sent or refused event is never queued again")
        transport.replies = [Wire.reply(200, ["signal_id": UUID().uuidString, "state": "replayed"]),
                             Wire.reply(409, ["error": "Key belongs to another photo", "code": "feedback_key_conflict"]),
                             Wire.reply(200, ["signal_id": UUID().uuidString, "state": "recorded"]),
                             Wire.reply(200, ["signal_id": UUID().uuidString, "state": "recorded"])]
        let signalRetry = await pass(signalActor, ignoringBackoff: true)
        let settled = store.signals(actor: signalActor)
        check(signalRetry == .idle && settled.filter { $0.state == .pending }.isEmpty && settled[3].state == .dropped
                && Wire.canonical(transport.sent[beforeSignals + 3].body) == Wire.canonical(transport.sent[beforeSignals + 2].body),
              "a retried signal is the identical request; a key conflict is dropped")

        // MARK: Photo history is never written by feedback

        _ = PhotoFeedback.localOutcome(versionID: "edit-a", directory: photos)
        _ = PhotoFeedback.automaticallySelectedVersion(versionID: "edit-b", directory: photos)
        let historyAfter = try Data(contentsOf: historyFile)
        let filesAfter = try FileManager.default.contentsOfDirectory(atPath: photos.path).sorted()
        check(historyAfter == historyBefore && filesAfter == filesBefore,
              "feedback never writes photo history: review flags, selections and files are untouched")
        let indexAfter = try PhotoVersionHistory.load(directory: photos)
        check(indexAfter.versions["edit-a"] == first && indexAfter.versions["edit-b"] == second,
              "the rated versions keep their exact saved review flags")

        // MARK: Review, selection and automatic-selection facts

        let review = root.appendingPathComponent("review", isDirectory: true)
        try PhotoVersionHistory.saveCapture(original: bytes, enhanced: bytes, id: "room", directory: review)
        let staged = try PhotoVersionHistory.saveEdit(jpeg: Data("staged".utf8), id: "room-stage", parentID: "room",
            sourceID: "room", edit: "stage", style: "modern", disclosure: "Virtually staged.",
            provenanceID: UUID().uuidString, provenanceRecorded: true, directory: review)
        guard let stagedBefore = PhotoFeedback.localOutcome(versionID: staged.id, directory: review)?.outcome else {
            preconditionFailure("staged version readable")
        }
        check(!stagedBefore.stagingReviewed && !stagedBefore.selectedForListing,
              "a new staged preview is unreviewed and not on the listing")
        check(PhotoFeedback.automaticallySelectedVersion(versionID: staged.id, directory: review) == nil,
              "staging is never selected automatically")
        try PhotoVersionHistory.selectForPublication(id: staged.id, directory: review, reviewed: true)
        guard let stagedAfter = PhotoFeedback.localOutcome(versionID: staged.id, directory: review)?.outcome else {
            preconditionFailure("staged version readable after review")
        }
        check(PhotoFeedback.transitionSignals(from: stagedBefore, to: stagedAfter, cloudListing: false)
                == [Event(signal: .accuracyAck, detail: .stagingReview), Event(signal: .manualSelection, detail: .listingSelection)],
              "a completed staging review and a person's listing choice are separate signals")
        check(PhotoFeedback.transitionSignals(from: stagedBefore, to: stagedAfter, cloudListing: true)
                == [Event(signal: .accuracyAck, detail: .stagingReview)],
              "a cloud listing's choice is recorded where the server accepts it, not from local history")
        check(PhotoFeedback.transitionSignals(from: stagedAfter, to: stagedAfter, cloudListing: false).isEmpty, "no change, no signal")
        try PhotoVersionHistory.removeFromPublication(id: staged.id, directory: review)
        guard let removed = PhotoFeedback.localOutcome(versionID: staged.id, directory: review)?.outcome else {
            preconditionFailure("staged version readable after removal")
        }
        check(PhotoFeedback.transitionSignals(from: stagedAfter, to: removed, cloudListing: false).isEmpty,
              "removing a photo from the listing is not a signal")

        try PhotoVersionHistory.saveCapture(original: bytes, enhanced: bytes, id: "front", directory: review)
        let custom = try PhotoVersionHistory.saveEdit(jpeg: Data("custom".utf8), id: "front-custom", parentID: "front",
            sourceID: "front", edit: "custom", style: nil, disclosure: nil,
            provenanceID: UUID().uuidString, provenanceRecorded: true, directory: review)
        check(custom.needsCustomReview && PhotoFeedback.automaticallySelectedVersion(versionID: custom.id, directory: review) == nil,
              "custom edits wait for review and are not selected automatically")
        guard let customBefore = PhotoFeedback.localOutcome(versionID: custom.id, directory: review)?.outcome else {
            preconditionFailure("custom version readable")
        }
        let reviewIndex = try PhotoVersionHistory.load(directory: review)
        try PhotoVersionHistory.confirmCustomReview(id: custom.id, imageFile: custom.imageFile,
            sourceFile: custom.reviewSourceFile(in: reviewIndex),
            review: .init(comparedSource: true, fixedFeaturesMatch: true, colorsAndMaterialsMatch: true, onlyRequestedChange: true),
            directory: review)
        guard let customAfter = PhotoFeedback.localOutcome(versionID: custom.id, directory: review)?.outcome else {
            preconditionFailure("custom version readable after review")
        }
        check(PhotoFeedback.transitionSignals(from: customBefore, to: customAfter, cloudListing: true)
                == [Event(signal: .accuracyAck, detail: .customReview)],
              "a recorded custom review is an accuracy acknowledgment on any listing")
        check(!customAfter.selectedForListing, "a custom review alone never selects the photo")

        try PhotoVersionHistory.saveCapture(original: bytes, enhanced: bytes, id: "yard", directory: review)
        let lawn = try PhotoVersionHistory.saveEdit(jpeg: Data("lawn".utf8), id: "yard-lawn", parentID: "yard",
            sourceID: "yard", edit: "lawn", style: nil, disclosure: nil,
            provenanceID: UUID().uuidString, provenanceRecorded: true, directory: review)
        check(PhotoFeedback.automaticallySelectedVersion(versionID: lawn.id, directory: review)?.id == lawn.id,
              "the existing automatic rule's choice is recognized")
        try PhotoVersionHistory.removeFromPublication(id: lawn.id, directory: review)
        let sky = try PhotoVersionHistory.saveEdit(jpeg: Data("sky".utf8), id: "yard-sky", parentID: "yard-lawn",
            sourceID: "yard-lawn", edit: "sky", style: nil, disclosure: nil,
            provenanceID: UUID().uuidString, provenanceRecorded: true, directory: review)
        check(PhotoFeedback.automaticallySelectedVersion(versionID: sky.id, directory: review) == nil,
              "an edit in a family the person removed is not an automatic selection")

        // MARK: Expiry and damaged files

        let expiryActor = UUID().uuidString.lowercased()
        let stale = PhotoFeedback.Output(provenanceID: UUID().uuidString)!, kept = PhotoFeedback.Output(provenanceID: UUID().uuidString)!
        _ = try store.record(.init(verdict: .useful), output: stale, library: library, actor: expiryActor, now: t0)
        let keptRecord = try store.record(.init(verdict: .useful), output: kept, library: library, actor: expiryActor, now: t0)
        _ = store.apply(.accepted(PhotoFeedback.Receipt(provenanceID: kept.provenanceID, revision: 1, revisionCount: 1,
                                                        content: nil, state: "recorded")),
                        to: keptRecord, actor: expiryActor, now: t0)
        let later = t0.addingTimeInterval(PhotoFeedbackStore.pendingLifetime + 60)
        _ = try store.record(.init(verdict: .useful), output: PhotoFeedback.Output(provenanceID: UUID().uuidString)!,
                             library: library, actor: expiryActor, now: later)
        check(store.feedback(provenanceID: stale.provenanceID, actor: expiryActor) == nil
                && store.feedback(provenanceID: kept.provenanceID, actor: expiryActor)?.delivered == true,
              "unsent items expire quietly after 30 days; delivered opinions stay")

        let damagedActor = UUID().uuidString.lowercased()
        try Data("{not json".utf8).write(to: queue.appendingPathComponent("feedback-\(damagedActor).json"))
        check(store.dueWork(actor: damagedActor, library: library, now: t0, ignoringBackoff: true).isEmpty,
              "a damaged queue reads as empty and never blocks review")
        let recovered = try store.record(.init(verdict: .useful), output: outA, library: library, actor: damagedActor, now: t0)
        check(store.feedback(provenanceID: outA.provenanceID, actor: damagedActor) == recovered,
              "the next opinion replaces a damaged queue")
        let borrowedActor = UUID().uuidString.lowercased()
        try FileManager.default.copyItem(at: queue.appendingPathComponent("feedback-\(otherActor).json"),
                                         to: queue.appendingPathComponent("feedback-\(borrowedActor).json"))
        check(store.feedback(provenanceID: outA.provenanceID, actor: borrowedActor) == nil,
              "a queue file is only read for the account it names")

        print("PASS \(checks) photo feedback checks")
    }
}
