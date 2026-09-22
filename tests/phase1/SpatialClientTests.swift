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
        let boundedURL = URL(string: "https://upload.example.invalid/v2/11111111-1111-4111-8111-111111111111?expires=1893456000&signature=" + String(repeating: "a", count: 64))!
        func ticket(_ assetID: String) -> UploadTicket {
            UploadTicket(assetID: assetID, mode: .single, putURL: boundedURL, transportVersion: 2, uploaded: false)
        }
        let alreadyStored = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
            probe: { .complete }, renew: { originalID in
                renewCount += 1
                return ticket(originalID)
            })
        if case .complete = alreadyStored { try check(true, "Stored upload completes") }
        else { throw Failure(detail: "Already stored upload was reissued") }
        try check(renewCount == 0, "Confirmed upload must not renew a transfer")
        let pending = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
            probe: { .needsReconciliation }, renew: { originalID in
                renewCount += 1
                try check(originalID == id.uuidString, "Renew receives immutable original asset identity")
                return ticket(originalID)
            })
        if case .renew(let url) = pending { try check(url == boundedURL, "Renewed exact ticket URL") }
        else { throw Failure(detail: "Unsent upload cannot resume") }
        try check(renewCount == 1, "Pending upload only renews once")
        var denied = false
        do {
            _ = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
                probe: { throw Failure(detail: "401 unauthorized") }, renew: { originalID in
                    renewCount += 1
                    return ticket(originalID)
                })
        } catch { denied = true }
        try check(denied && renewCount == 1, "401 must not renew or schedule a transport")
        denied = false
        do {
            _ = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
                probe: { .needsReconciliation }, renew: { _ in
                    ticket(listing.uuidString)
                })
        } catch { denied = true }
        try check(denied, "Renewal cannot silently purchase a different ticket")
        let wonRace = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
            probe: { .needsReconciliation }, renew: { originalID in
                renewCount += 1
                return UploadTicket(assetID: originalID, mode: .single, uploaded: true)
            })
        if case .complete = wonRace { try check(true, "Completion won renewal race without another PUT") }
        else { throw Failure(detail: "Completion won renewal race without another PUT") }
        try check(renewCount == 2, "Completed renewal uses one metadata request and no reservation callback")
        for invalid in [UploadTicket(assetID: listing.uuidString, mode: .single, uploaded: true),
                        UploadTicket(assetID: id.uuidString, mode: .single, transportVersion: 2, uploaded: false),
                        UploadTicket(assetID: id.uuidString, mode: .single, putURL: boundedURL, transportVersion: 1),
                        UploadTicket(assetID: id.uuidString, mode: .multipart, uploaded: true)] {
            denied = false
            do {
                _ = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
                    probe: { .needsReconciliation }, renew: { _ in invalid })
            } catch { denied = true }
            try check(denied, "Malformed or different completed renewal never attaches another asset")
        }

        // Capability: the pinned two-field contract, decoded exactly, with the
        // reason mapped to a sentence the screen can show.
        let capabilityOff = try JSONDecoder().decode(SpatialCapability.self, from: #"{"enabled":false,"reason":"not_configured"}"#.data(using: .utf8)!)
        try check(!capabilityOff.enabled && capabilityOff.reason == "not_configured", "Capability decodes the pinned wire fields")
        try check(capabilityOff.explanation.contains("isn't switched on") && !capabilityOff.explanation.contains("not_configured"), "Known reason slug maps to a sentence, not the slug")
        try check(capabilityOff == SpatialCapability(enabled: false, reason: "not_configured"), "Capability is value-comparable")
        try check(SpatialCapability(enabled: false, reason: "mock").explanation.contains("offline preview"), "The mock's reason reads as the offline preview")
        try check(SpatialCapability(enabled: false, reason: "provider_paused").explanation == "Provider paused.", "Unknown slugs are humanised, never shown raw")
        try check(SpatialCapability(enabled: false, reason: "Turned off for the weekend").explanation == "Turned off for the weekend.", "A server sentence is shown as written")
        let capabilityOn = try JSONDecoder().decode(SpatialCapability.self, from: #"{"enabled":true,"reason":""}"#.data(using: .utf8)!)
        try check(capabilityOn.enabled && capabilityOn.explanation == "3D rooms are available.", "Enabled capability decodes with an empty reason")
        try rejects("A capability without the enabled field must fail") {
            _ = try JSONDecoder().decode(SpatialCapability.self, from: #"{"reason":"x"}"#.data(using: .utf8)!)
        }

        // Spatial's Wi-Fi switch is its own key with its own default; it no
        // longer shares Settings' "Ask before uploading on cellular" key.
        try check(SpatialUploadPreferences.wifiOnlyKey == "spatialWifiOnlyUploads" && SpatialUploadPreferences.wifiOnlyKey != "wifiOnlyUploads",
                  "Spatial persists its Wi-Fi-only choice under its own key")
        try check(SpatialUploadPreferences.wifiOnlyDefault && SpatialUploadPreferences.wifiOnly(stored: nil), "Wi-Fi-only defaults to on when the key was never written")
        try check(!SpatialUploadPreferences.wifiOnly(stored: false) && SpatialUploadPreferences.wifiOnly(stored: true), "An explicit choice is honoured")
        try check(!SpatialUploadPreferences.wifiOnly(stored: NSNumber(value: false)), "A plist-typed value reads the same way")
        try check(SpatialUploadPreferences.wifiOnly(stored: "garbage"), "An unreadable value falls back to the safe default, never to cellular")

        // Pruning: the retention rule the coordinator applies at enqueue, on
        // reconnect and after each job refresh. Photos are released only for a
        // room the server has fully taken; never on the way in.
        let pendingRoom = try makeRecord().validated()
        try check(pendingRoom.retention(captureExists: true, server: .unknown) == .keep, "A live room with its capture is kept")
        try check(pendingRoom.retention(captureExists: false, server: .unknown) == .forget, "A room whose capture vanished has nothing left to upload")
        var createdRoom = pendingRoom; createdRoom.jobID = id
        try check(createdRoom.retention(captureExists: true, server: .missing) == .forget, "A job the server no longer lists is dropped")
        try check(pendingRoom.retention(captureExists: true, server: .missing) == .keep, "A room without a job yet is not judged by the server list")
        let uploadingJob = try decode(payload(status: "uploading", progress: 0))
        let queuedJob = try decode(payload(status: "queued", progress: 0.25))
        let readyJob = try decode(payload(status: "ready", privacy: "approved", share: "https://tour.example.invalid/shared"))
        try check(createdRoom.retention(captureExists: true, server: .job(uploadingJob)) == .keep, "An uploading job keeps its record")
        try check(createdRoom.retention(captureExists: true, server: .job(queuedJob)) == .forget, "A queued job with unconfirmed frames is dropped without touching files")
        var takenRoom = createdRoom
        for index in takenRoom.frames.indices { takenRoom.frames[index].ticketID = id.uuidString; takenRoom.frames[index].phase = .attached }
        try check(takenRoom.isFullyConfirmed && !createdRoom.isFullyConfirmed, "Full confirmation means every frame attached")
        try check(takenRoom.retention(captureExists: true, server: .job(queuedJob)) == .cleanUpAndForget, "A queued job with every frame confirmed releases the local photos")
        try check(takenRoom.retention(captureExists: true, server: .job(readyJob)) == .cleanUpAndForget, "A ready room releases the local photos")
        var startedRoom = takenRoom; startedRoom.queued = true
        try check(startedRoom.retention(captureExists: true, server: .unknown) == .cleanUpAndForget, "The local /start receipt alone is enough to release photos")
        var cancelledPayload = payload(status: "failed"); cancelledPayload["can_resume"] = true; cancelledPayload["failure_code"] = "user_cancelled"
        let cancelledJob = try decode(cancelledPayload)
        try check(takenRoom.retention(captureExists: true, server: .job(cancelledJob)) == .keep, "A resumable cancelled room keeps its record and photos")
        var retryPayload = payload(status: "failed"); retryPayload["can_retry"] = true
        let retryableJob = try decode(retryPayload)
        try check(takenRoom.retention(captureExists: true, server: .job(retryableJob)) == .cleanUpAndForget, "A retryable failure reuses the server's inputs; local photos go")
        let deadJob = try decode(payload(status: "failed"))
        try check(createdRoom.retention(captureExists: true, server: .job(deadJob)) == .forget, "A terminal failure with unconfirmed frames is dropped, files untouched")
        try check(SpatialUploadRecord.liveRoomLimit == 32, "The cap is a live-room cap")

        // Expired tickets: a dead reservation reports `.expired` instead of
        // throwing into a Resume loop, and the frame buys a fresh ticket under
        // a NEW idempotency key a bounded number of times.
        renewCount = 0
        let deadReservation = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
            probe: { .needsReconciliation }, renew: { _ in
                renewCount += 1
                throw APIError.server(status: 409, code: "conflict", message: "upload is terminal or expired")
            })
        if case .expired = deadReservation { try check(renewCount == 1, "Expiry is learned from one renewal") }
        else { throw Failure(detail: "A dead reservation must report expiry, not loop") }
        let abortedAtProbe = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
            probe: { throw APIError.server(status: 409, code: "conflict", message: "This upload was aborted — create a new ticket") },
            renew: { originalID in renewCount += 1; return ticket(originalID) })
        if case .expired = abortedAtProbe { try check(renewCount == 1, "An aborted asset is not renewed") }
        else { throw Failure(detail: "An aborted reservation must report expiry") }
        denied = false
        do {
            _ = try await SpatialUploadRecovery.reconcile(ticketID: id.uuidString,
                probe: { .needsReconciliation }, renew: { _ in
                    throw APIError.server(status: 409, code: "conflict", message: "Completion must match the server-confirmed part receipts")
                })
        } catch { denied = true }
        try check(denied, "An unrelated conflict still fails closed")
        try check(!SpatialUploadRecovery.isTerminalReservation(APIError.server(status: 503, code: "upstream", message: "upload is terminal or expired")),
                  "Only a 409 carries the terminal verdict")
        var deadFrame = makeRecord()
        deadFrame.frames[0].ticketID = id.uuidString; deadFrame.frames[0].phase = .uploaded; deadFrame.frames[0].reconciliations = 2
        try check(deadFrame.ticketKey(index: 0) == "spatial:\(id.uuidString):0", "The first ticket keeps the historical replay key")
        try check(deadFrame.reissueTicket(index: 0), "A dead reservation can be reissued")
        try check(deadFrame.frames[0].ticketID == nil && deadFrame.frames[0].putURL == nil && deadFrame.frames[0].taskID == nil
                  && deadFrame.frames[0].phase == .pending && deadFrame.frames[0].reconciliations == 0 && deadFrame.frames[0].reissueCount == 1,
                  "Reissue forgets the dead ticket so the next pump requests a fresh one")
        try check(deadFrame.ticketKey(index: 0) == "spatial:\(id.uuidString):0:r1", "A reissued frame buys under a new idempotency key")
        try check(deadFrame.ticketKey(index: 1) == "spatial:\(id.uuidString):1", "Other frames keep their keys")
        let reissued = try JSONDecoder().decode(SpatialUploadRecord.self, from: JSONEncoder().encode(deadFrame)).validated()
        try check(reissued.frames[0].reissueCount == 1 && reissued.ticketKey(index: 0).hasSuffix(":r1"), "The reissue count survives relaunch")
        for _ in 1..<SpatialUploadRecord.maximumReissues { deadFrame.reissueTicket(index: 0) }
        try check(!deadFrame.reissueTicket(index: 0) && deadFrame.frames[0].reissueCount == SpatialUploadRecord.maximumReissues, "Reissues are bounded")
        _ = try deadFrame.validated()
        var overflow = deadFrame; overflow.frames[0].reissues = SpatialUploadRecord.maximumReissues + 1
        try rejects("An impossible reissue count is an unreadable journal") { _ = try overflow.validated() }
        var attachedFrame = makeRecord(); attachedFrame.frames[0].ticketID = id.uuidString; attachedFrame.frames[0].phase = .attached
        try check(!attachedFrame.reissueTicket(index: 0) && attachedFrame.frames[0].phase == .attached, "An attached frame is never reissued")

        // Stale PUT capability: a ticketed frame renews before any transfer
        // once its `expires` claim is inside the margin; dispatched frames
        // reconcile through /complete instead.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let signature = String(repeating: "a", count: 64)
        let freshURL = URL(string: "https://upload.example.invalid/v2/11111111-1111-4111-8111-111111111111?expires=1800003600&signature=" + signature)!
        let spentURL = URL(string: "https://upload.example.invalid/v2/11111111-1111-4111-8111-111111111111?expires=1800000100&signature=" + signature)!
        try check(SpatialUploadRecovery.capabilityIsUsable(freshURL, at: now), "A capability with an hour left is used as-is")
        try check(!SpatialUploadRecovery.capabilityIsUsable(spentURL, at: now), "A capability inside the renewal margin renews first")
        try check(!SpatialUploadRecovery.capabilityIsUsable(nil, at: now), "No capability, no transfer")
        try check(!SpatialUploadRecovery.capabilityIsUsable(URL(string: "https://upload.example.invalid/v2/11111111-1111-4111-8111-111111111111?signature=" + signature)!, at: now),
                  "A capability without an expiry is not trusted")
        try check(SpatialUploadRecovery.capabilityExpiry(freshURL) == Date(timeIntervalSince1970: 1_800_003_600), "Expiry is read from the signed claim")
        var staleFrame = makeRecord()
        staleFrame.frames[0].ticketID = id.uuidString; staleFrame.frames[0].phase = .ticketed; staleFrame.frames[0].putURL = spentURL
        try check(staleFrame.needsRenewal(index: 0, at: now), "A ticketed frame with a spent capability renews before any PUT")
        staleFrame.frames[0].putURL = freshURL
        try check(!staleFrame.needsRenewal(index: 0, at: now), "A fresh capability is not renewed")
        staleFrame.frames[0].phase = .sending
        try check(!staleFrame.needsRenewal(index: 0, at: now), "Renewal-by-age applies to undispatched tickets only")

        // Honest states survive relaunch and older journals decode without them.
        var unavailable = makeRecord(); unavailable.serviceUnavailable = true; unavailable.failure = "3D rooms aren't available yet"
        let unavailableReplay = try JSONDecoder().decode(SpatialUploadRecord.self, from: JSONEncoder().encode(unavailable)).validated()
        try check(unavailableReplay.isServiceUnavailable && !unavailableReplay.isTerminalFailure, "Not-configured state is remembered and is not a dead record")
        var dead = makeRecord(); dead.terminal = true; dead.failure = "This room capture could not be verified."
        try check(dead.isTerminalFailure, "A terminal failure is recognised")
        try check(!oldRecord.isServiceUnavailable && !oldRecord.isTerminalFailure && oldRecord.frames[0].reissueCount == 0, "Journals without the new fields read as ordinary live records")
        print("PASS SpatialClientTests \(count) assertions")
    }
}
