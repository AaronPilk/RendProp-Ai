import Foundation

@main enum SpatialClientTests {
    struct Failure: Error { let detail: String }
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        count += 1
        if !condition() { throw Failure(detail: detail) }
    }
    static func rejects(_ detail: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try check(rejected, detail)
    }
    static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000040")!
    static let listing = UUID(uuidString: "00000000-0000-4000-8000-000000000041")!
    static let revision = UUID(uuidString: "00000000-0000-4000-8000-000000000042")!
    static func payload(status: String = "review", progress: Double = 1, privacy: String = "unreviewed", share: Any = NSNull(), artifact: Any = revision.uuidString) -> [String: Any] {
        ["id": id.uuidString, "listing_id": listing.uuidString, "room_label": "Synthetic room", "status": status,
         "progress": progress, "failure_code": NSNull(), "viewer_url": "https://tour.example.invalid/s/test#access=synthetic",
         "share_url": share, "artifact_revision": artifact, "privacy_state": privacy,
         "attempt_number": 1, "retry_after": NSNull(), "can_retry": false, "can_cancel": false, "can_resume": false,
         "created_at": "2026-09-11T00:00:00Z", "updated_at": "2026-09-11T00:00:00Z"]
    }
    static func decode(_ body: [String: Any], decoder: JSONDecoder = JSONDecoder()) throws -> SpatialJob {
        try decoder.decode(SpatialJob.self, from: JSONSerialization.data(withJSONObject: body)).validated()
    }
    static func makeRecord() -> SpatialUploadRecord {
        let frames = (1...20).map { n in
            SpatialUploadRecord.Frame(imagePath: String(format: "images/%06d.jpg", n),
                sidecarPath: String(format: "frames/%06d.json", n), bytes: 100,
                sha256: String(repeating: "a", count: 64))
        }
        return .init(id: id, ownerID: listing.uuidString, listingLocalID: listing, listingID: listing,
                     captureID: revision, roomLabel: "Synthetic room", allowCellular: false, frames: frames)
    }
    static func main() async throws {
        let job = try decode(payload())
        try check(job.listingID == listing && job.roomLabel == "Synthetic room", "Exact snake_case decode lost fields")
        try check(job.artifactRevision == revision && job.privacyState == .unreviewed, "Artifact/privacy decode failed")
        let wrong = JSONDecoder(); wrong.keyDecodingStrategy = .convertFromSnakeCase
        try rejects("The deliberate wrong-decoder control must fail") { _ = try decode(payload(), decoder: wrong) }
        for bad in [-1.0, 1.001] {
            try rejects("Out-of-range progress must fail") { _ = try decode(payload(progress: bad)) }
        }
        for state in ["review", "ready"] {
            try rejects("An artifactless room cannot be ready") { _ = try decode(payload(status: state, artifact: NSNull())) }
        }
        for privacy in ["unreviewed", "excluded", "redaction_required"] {
            try rejects("Nonapproved artifacts cannot expose share links") {
                _ = try decode(payload(status: "ready", privacy: privacy, share: "https://tour.example.invalid/shared"))
            }
        }
        try rejects("A review-only artifact cannot expose a share link") {
            _ = try decode(payload(status: "review", privacy: "approved", share: "https://tour.example.invalid/shared"))
        }
        let ready = try decode(payload(status: "ready", privacy: "approved", share: "https://tour.example.invalid/shared"))
        try check(ready.shareURL != nil, "Approved published room should expose sharing")
        for url in ["http://tour.example.invalid/s/x", "file:///tmp/room.sog", "https://user:password@tour.example.invalid/s/x"] {
            var body = payload(); body["viewer_url"] = url
            try rejects("Unexpected viewer URL rejected") { _ = try decode(body) }
        }
        var body = payload(); body["status"] = "done"
        try rejects("Unknown status must fail rather than default ready") { _ = try decode(body) }
        body = payload(); body.removeValue(forKey: "privacy_state")
        try rejects("Missing privacy state must fail") { _ = try decode(body) }
        body = payload(); body.removeValue(forKey: "can_retry")
        try rejects("Missing server recovery authority must fail") { _ = try decode(body) }
        body = payload(); body["can_retry"] = true
        try rejects("A review-ready room cannot silently start a paid retry") { _ = try decode(body) }
        body = payload(status: "failed"); body["can_retry"] = true; body["attempt_number"] = 3
        try rejects("Retry cannot exceed three attempts") { _ = try decode(body) }
        body = payload(status: "processing"); body["can_cancel"] = true
        try rejects("Client must not promise to cancel running cloud compute") { _ = try decode(body) }
        body = payload(status: "failed"); body["can_resume"] = true
        try rejects("Resume requires an actual cancelled-room receipt") { _ = try decode(body) }
        body["failure_code"] = "user_cancelled"
        let cancelled = try decode(body)
        try check(cancelled.canResume, "Cancelled room can resume its preserved inputs")
        body = payload(status: "failed"); body["can_retry"] = true
        let firstRetry = try decode(body)
        let replayRetry = try decode(body)
        try check(firstRetry.retryOperationID == replayRetry.retryOperationID, "Retry key survives decode/relaunch without a second charge")
        body["attempt_number"] = 2
        let secondRetry = try decode(body)
        try check(firstRetry.retryOperationID != secondRetry.retryOperationID, "New failed attempt receives a distinct retry key")
        try check(firstRetry.retryOperationID.uuidString.range(of: #"^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"#, options: .regularExpression) != nil,
                  "Retry key has valid UUID version and variant")
        let expectation = SpatialViewerExpectation(sceneID: id, revision: revision, url: URL(string: "https://tour.example.invalid/s/room#access=synthetic")!)
        var receipt: [String: Any] = ["type": "spatial-ready", "scene_id": id.uuidString, "artifact_revision": revision.uuidString]
        try check(expectation.accepts(receipt, isMainFrame: true, scheme: "https", host: "tour.example.invalid", port: 443), "Actual matching renderer receipt accepted")
        try check(!expectation.accepts(receipt, isMainFrame: false, scheme: "https", host: "tour.example.invalid", port: 443), "Subframe cannot approve room review")
        try check(!expectation.accepts(receipt, isMainFrame: true, scheme: "https", host: "other.example.invalid", port: 443), "Other origin cannot approve room review")
        try check(!expectation.accepts(receipt, isMainFrame: true, scheme: "https", host: "tour.example.invalid", port: 444), "Other port cannot approve room review")
        try check(!expectation.accepts(receipt, isMainFrame: true, scheme: "http", host: "tour.example.invalid", port: 443), "Insecure origin cannot approve room review")
        receipt["artifact_revision"] = listing.uuidString
        try check(!expectation.accepts(receipt, isMainFrame: true, scheme: "https", host: "tour.example.invalid", port: 443), "Wrong artifact revision cannot approve room review")
        receipt["artifact_revision"] = revision.uuidString; receipt["scene_id"] = listing.uuidString
        try check(!expectation.accepts(receipt, isMainFrame: true, scheme: "https", host: "tour.example.invalid", port: 443), "Wrong scene cannot approve room review")
        receipt["scene_id"] = id.uuidString; receipt["type"] = "url-loaded"
        try check(!expectation.accepts(receipt, isMainFrame: true, scheme: "https", host: "tour.example.invalid", port: 443), "URL retrieval cannot approve room review")
        let handoff = SpatialCaptureHandoff(id: id, ownerID: listing.uuidString)
        try check(handoff.accepts(presentationID: id, currentOwner: listing.uuidString), "Current capture hands off to its original owner")
        try check(!handoff.accepts(presentationID: id, currentOwner: revision.uuidString), "Account switch cannot adopt a late capture callback")
        try check(!handoff.accepts(presentationID: nil, currentOwner: listing.uuidString), "Dismissed capture callback cannot restart upload")
        try check(!handoff.accepts(presentationID: revision, currentOwner: listing.uuidString), "Older capture cannot complete a newer presentation")
        try check(!handoff.accepts(presentationID: id, currentOwner: nil), "Signout cannot own an earlier capture callback")
        let json = #"{"camera_to_world":[[1,0,0,1.2345678806304932],[0,1,0,0],[0,0,1,0],[0,0,0,1]],"point":{"id":"18446744073709551615"},"tracking_state":{"state":"normal","reason":null}}"#.data(using: .utf8)!
        let raw = try JSONDecoder().decode(SpatialJSON.self, from: json)
        let roundtrip = try JSONDecoder().decode(SpatialJSON.self, from: JSONEncoder().encode(raw))
        try check(raw == roundtrip, "Pose or UInt64 point identifier changed during transport")
        let create = SpatialCreateRequest(listingID: listing, roomLabel: "Synthetic room", captureID: revision, manifest: raw)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(create)) as! [String: Any]
        try check(Set(object.keys) == ["listing_id", "room_label", "capture_id", "manifest"], "Create wire keys differ")
        let input = SpatialInput(ticketID: id.uuidString, relativePath: "images/000001.jpg", frame: raw)
        let inputs = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
        try check(Set(inputs.keys) == ["ticket_id", "relative_path", "frame"], "Input wire keys differ")
        let review = SpatialReviewRequest(artifactRevision: revision, approved: true, excludeRoom: false, redactions: [])
        let reviews = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as! [String: Any]
        try check(Set(reviews.keys) == ["artifact_revision", "approved", "exclude_room", "redactions"], "Review wire keys differ")

        var record = try makeRecord().validated()
        try check(record.bytesTotal == 2000 && record.bytesConfirmed == 0 && record.uploadProgress == 0, "Pending bytes aren't confirmed")
        record.frames[0].ticketID = id.uuidString
        record.frames[0].phase = .sending
        try check(record.uploadProgress == 0 && record.confirmedCount == 0, "An OS dispatched PUT is not server completion")
        record.frames[0].phase = .uploaded
        try check(record.uploadProgress == 0 && record.confirmedCount == 0, "A transport 2xx is not attached server completion")
        record.frames[0].phase = .attached
        try check(record.uploadProgress == 0.05 && record.confirmedCount == 1 && record.bytesConfirmed == 100, "Progress uses only server-confirmed attached bytes")
        let persisted = try JSONDecoder().decode(SpatialUploadRecord.self, from: JSONEncoder().encode(record)).validated()
        try check(persisted.frames[0].phase == .attached && persisted.id == id, "Journal replay lost stable task state")
        try check(persisted.taskPrefix == "spatial:\(id.uuidString):", "Background task correlation changed")
        var callback = makeRecord()
        callback.frames[0].ticketID = id.uuidString
        callback.frames[0].phase = .sending
        callback.frames[0].taskID = 2
        try check(!callback.acceptTransportReceipt(index: 0, taskID: 1, success: true), "Stale task callback cannot finish a replacement")
        try check(callback.frames[0].phase == .sending && callback.frames[0].taskID == 2, "Stale callback must preserve current OS task")
        try check(callback.acceptTransportReceipt(index: 0, taskID: 2, success: true), "Matching OS callback accepted")
        try check(callback.frames[0].phase == .uploaded && callback.frames[0].taskID == nil, "Only matching receipt changes transport state")
        try check(!callback.acceptTransportReceipt(index: 0, taskID: 2, success: false), "Duplicate callback cannot regress completed transport")
        callback.pausedByUser = true
        let paused = try JSONDecoder().decode(SpatialUploadRecord.self, from: JSONEncoder().encode(callback)).validated()
        try check(paused.isUserPaused && paused.frames[0].phase == .uploaded, "Stopped uploads preserve pause and transport receipts across relaunch")
        var oldJournal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(callback)) as! [String: Any]
        oldJournal.removeValue(forKey: "pausedByUser")
        let oldRecord = try JSONDecoder().decode(SpatialUploadRecord.self, from: JSONSerialization.data(withJSONObject: oldJournal)).validated()
        try check(!oldRecord.isUserPaused, "Existing journals without new pause field remain readable")
        var insufficient = makeRecord(); insufficient.frames.removeLast()
        try rejects("Too few frames fails before upload") { _ = try insufficient.validated() }
        var duplicate = makeRecord(); duplicate.frames[1] = duplicate.frames[0]
        try rejects("Duplicate paths fail before upload") { _ = try duplicate.validated() }
        var noTicket = makeRecord(); noTicket.frames[0].phase = .sending
        try rejects("Sending without a durable ticket cannot recover") { _ = try noTicket.validated() }
        var traversal = makeRecord()
        traversal.frames[0] = .init(imagePath: "images/../secrets.jpg", sidecarPath: "frames/000001.json", bytes: 100, sha256: String(repeating: "a", count: 64))
        try rejects("Traversal cannot escape the capture directory") { _ = try traversal.validated() }
        var oversized = makeRecord()
        oversized.frames[0] = .init(imagePath: "images/000001.jpg", sidecarPath: "frames/000001.json", bytes: 32 * 1024 * 1024 + 1, sha256: String(repeating: "a", count: 64))
        try rejects("Oversized photos cannot use the single-write ticket path") { _ = try oversized.validated() }
        var capability = makeRecord()
        capability.frames[0].putURL = URL(string: "https://user:password@wrong.example.invalid/")
        try rejects("Embedded credentials are never recovered as upload URLs") { _ = try capability.validated() }
        var renewCount = 0
        let alreadyStored = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
            probe: { .complete }, renew: {
                renewCount += 1
                return .init(ticketID: id.uuidString, putURL: URL(string: "https://upload.example.invalid/same-ticket")!)
            })
        if case .complete = alreadyStored { try check(true, "Stored upload completes") }
        else { throw Failure(detail: "Already stored upload was reissued") }
        try check(renewCount == 0, "Confirmed upload must not renew a transfer")
        let pending = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
            probe: { .needsReconciliation }, renew: {
                renewCount += 1
                return .init(ticketID: id.uuidString, putURL: URL(string: "https://upload.example.invalid/same-ticket")!)
            })
        if case .renew(let url) = pending { try check(url.lastPathComponent == "same-ticket", "Renewed exact ticket URL") }
        else { throw Failure(detail: "Unsent upload cannot resume") }
        try check(renewCount == 1, "Pending upload only renews once")
        var denied = false
        do {
            _ = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
                probe: { throw Failure(detail: "401 unauthorized") }, renew: {
                    renewCount += 1
                    return .init(ticketID: id.uuidString, putURL: URL(string: "https://upload.example.invalid/must-not-run")!)
                })
        } catch { denied = true }
        try check(denied && renewCount == 1, "401 must not renew or schedule a transport")
        denied = false
        do {
            _ = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
                probe: { .needsReconciliation }, renew: {
                    .init(ticketID: listing.uuidString, putURL: URL(string: "https://upload.example.invalid/new-paid-ticket")!)
                })
        } catch { denied = true }
        try check(denied, "Renewal cannot silently purchase a different ticket")
        print("PASS SpatialClientTests \(count) assertions")
    }
}
