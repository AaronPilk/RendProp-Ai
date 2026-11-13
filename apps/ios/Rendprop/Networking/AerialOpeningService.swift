import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The new front-of-home protocol is separate from legacy generic aerial jobs.
/// Journals retain immutable intent, never credentials or signed preview URLs.
struct AerialOpeningManifest: Codable, Equatable, Sendable {
    var schema = 1
    var profile = "kie-kling3-omni-reference-aerial-opening-v1"
    let operationID: UUID
    let listingID: UUID
    let expectedOrgID: UUID
    let source: PropertyVideoOpeningSource
    var role = "front_of_home"
    let aspect: String
    var seconds = 5
    let reviewedCrop: AerialOpeningReviewedCrop
    enum CodingKeys: String, CodingKey {
        case schema, profile, source, role, aspect, seconds
        case operationID = "operation_id", listingID = "listing_id", expectedOrgID = "expected_org_id", reviewedCrop = "reviewed_crop"
    }
    var expectedGenerationCents: Double? {
        switch profile {
        case "kie-kling3-omni-reference-aerial-opening-v1": return 45
        case "kie-kling3-pro-aerial-opening-v1": return 45
        case "kie-kling3-4k-aerial-opening-v1": return 167.5
        default: return nil
        }
    }
    var isValid: Bool {
        schema == 1 && expectedGenerationCents != nil && role == "front_of_home" && seconds == 5 &&
        source.isWellFormed && source.photoProvenanceID == nil && source.bytes <= 52_428_800 && reviewedCrop.isValid(aspect: aspect)
    }
}
struct AerialOpeningConsent: Codable, Equatable, Sendable {
    let token: String
    let disclosureRevision: String
    let processors: [String]
    enum CodingKeys: String, CodingKey { case token, disclosureRevision = "disclosure_revision", processors }
    var isValid: Bool { token == "aerial-opening-v1" && !disclosureRevision.isEmpty && disclosureRevision.utf8.count <= 200 && processors.contains("kie") && Set(processors).count == processors.count && Set(processors).isSubset(of: ["kie", "openai", "anthropic"]) }
}
struct AerialOpeningQuote: Codable, Equatable, Sendable {
    struct Assessment: Codable, Equatable, Sendable {
        let routeID: String; let provider: String; let model: String; let cents: Double
        enum CodingKeys: String, CodingKey { case routeID = "route_id", provider, model, cents }
    }
    let schema: Int
    let profile: String
    let manifestSHA256: String
    let routeID: String
    let generationCents: Double
    let assessment: Assessment
    let quality: Assessment
    let processingCents: Double
    let maximumTotalCents: Double
    let tariffVersion: String
    let rateEvidenceSHA256: String
    let processorConsent: AerialOpeningConsent
    let expiresAt: String
    let privacyStopAt: String?
    enum CodingKeys: String, CodingKey {
        case schema, profile, assessment, quality
        case manifestSHA256 = "manifest_sha256", routeID = "route_id", generationCents = "generation_cents", processingCents = "processing_cents"
        case maximumTotalCents = "maximum_total_cents", tariffVersion = "tariff_version", rateEvidenceSHA256 = "rate_evidence_sha256"
        case processorConsent = "processor_consent", expiresAt = "expires_at", privacyStopAt = "privacy_stop_at"
    }
    func isValid(for manifest: AerialOpeningManifest, now: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
        let amounts = [generationCents, assessment.cents, quality.cents, processingCents, maximumTotalCents]
        return manifest.isValid && schema == 1 && profile == manifest.profile && processorConsent.isValid &&
            processorConsent.processors.contains(assessment.provider) && processorConsent.processors.contains(quality.provider) &&
            manifestSHA256.count == 64 && manifestSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) &&
            rateEvidenceSHA256.count == 64 && rateEvidenceSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) &&
            !routeID.isEmpty && !tariffVersion.isEmpty && expiry.map({ $0 > now }) == true &&
            amounts.allSatisfy({ $0.isFinite && $0 >= 0 }) && generationCents == manifest.expectedGenerationCents &&
            maximumTotalCents >= generationCents + assessment.cents + quality.cents + processingCents
    }
}
extension AerialOpeningQuote {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.privacyStopAt) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        schema = try c.decode(Int.self, forKey: .schema); profile = try c.decode(String.self, forKey: .profile)
        manifestSHA256 = try c.decode(String.self, forKey: .manifestSHA256); routeID = try c.decode(String.self, forKey: .routeID)
        generationCents = try c.decode(Double.self, forKey: .generationCents); assessment = try c.decode(Assessment.self, forKey: .assessment)
        quality = try c.decode(Assessment.self, forKey: .quality); processingCents = try c.decode(Double.self, forKey: .processingCents)
        maximumTotalCents = try c.decode(Double.self, forKey: .maximumTotalCents); tariffVersion = try c.decode(String.self, forKey: .tariffVersion)
        rateEvidenceSHA256 = try c.decode(String.self, forKey: .rateEvidenceSHA256)
        processorConsent = try c.decode(AerialOpeningConsent.self, forKey: .processorConsent)
        expiresAt = try c.decode(String.self, forKey: .expiresAt); privacyStopAt = try c.decodeIfPresent(String.self, forKey: .privacyStopAt)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(profile, forKey: .profile)
        try c.encode(manifestSHA256, forKey: .manifestSHA256); try c.encode(routeID, forKey: .routeID)
        try c.encode(generationCents, forKey: .generationCents); try c.encode(assessment, forKey: .assessment)
        try c.encode(quality, forKey: .quality); try c.encode(processingCents, forKey: .processingCents)
        try c.encode(maximumTotalCents, forKey: .maximumTotalCents); try c.encode(tariffVersion, forKey: .tariffVersion)
        try c.encode(rateEvidenceSHA256, forKey: .rateEvidenceSHA256); try c.encode(processorConsent, forKey: .processorConsent)
        try c.encode(expiresAt, forKey: .expiresAt); try c.encode(privacyStopAt, forKey: .privacyStopAt)
    }
}
struct AerialOpeningQuoteReply: Decodable { let manifest: AerialOpeningManifest; let quote: AerialOpeningQuote; let disclosure: String }
struct AerialOpeningStatus: Codable, Equatable, Sendable {
    let schema: Int
    let aerialJobID: UUID
    let operationID: UUID
    let actorID: UUID
    let orgID: UUID
    let selectedLibraryOrgID: UUID
    let listingID: UUID
    let manifestSHA256: String
    let manifest: AerialOpeningManifest
    let state: String
    let message: String?
    let quote: AerialOpeningQuote
    let cancelRequested: Bool
    let mayAccept: Bool
    let maySubmit: Bool
    let candidate: PropertyVideoOpening?
    var previewURL: URL?
    let opening: PropertyVideoAcceptedOpening?
    enum CodingKeys: String, CodingKey {
        case schema, manifest, state, message, quote, candidate, opening
        case aerialJobID = "aerial_job_id", operationID = "operation_id", actorID = "actor_id", orgID = "org_id"
        case selectedLibraryOrgID = "selected_library_org_id", listingID = "listing_id", manifestSHA256 = "manifest_sha256"
        case cancelRequested = "cancel_requested", mayAccept = "may_accept", maySubmit = "may_submit", previewURL = "preview_url"
    }
    var isTerminal: Bool { ["ineligible", "accepted", "failed", "cancelled"].contains(state) }
    func checked(context: PropertyVideoJobContext, physicalOrgID: UUID, intent: AerialOpeningManifest, frozenQuote: AerialOpeningQuote) throws -> Self {
        let states = ["queued_input", "preparing_input", "queued_assessment", "checking_source", "ineligible", "queued_generation", "dispatching", "ambiguous", "processing", "queued_qualification", "qualifying", "queued_quality", "checking_quality", "ready_for_acceptance", "accepted", "failed", "cancelled"]
        guard schema == 1, actorID == context.actorID, orgID == physicalOrgID, selectedLibraryOrgID == context.orgID,
              listingID == context.listingID, operationID == intent.operationID, manifest == intent, quote == frozenQuote,
              manifestSHA256 == frozenQuote.manifestSHA256, states.contains(state), !maySubmit,
              !mayAccept || (state == "ready_for_acceptance" && !cancelRequested),
              previewURL == nil || (["ready_for_acceptance", "accepted"].contains(state) && previewURL?.scheme == "https" && previewURL?.user == nil && previewURL?.password == nil),
              candidate == nil || (candidate?.source == intent.source && candidate?.isWellFormed == true && [120, 121].contains(candidate?.visibleFrames ?? 0) && ["ready_for_acceptance", "accepted"].contains(state)),
              state != "ready_for_acceptance" || (candidate != nil && previewURL != nil),
              state != "accepted" || opening != nil else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        if let opening {
            guard state == "accepted", opening.reference == candidate, opening.reference.source == intent.source, [120, 121].contains(opening.availableFrames) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            _ = try opening.checked(actorID: context.actorID, physicalOrgID: physicalOrgID, selectedLibraryOrgID: context.orgID, listingID: context.listingID, aspect: intent.aspect)
        }
        return self
    }
}
struct AerialOpeningCatalogue: Decodable {
    struct Entry: Decodable { let opening: PropertyVideoAcceptedOpening; let previewURL: URL
        enum CodingKeys: String, CodingKey { case opening, previewURL = "preview_url" }
    }
    let actorID: UUID; let orgID: UUID; let selectedLibraryOrgID: UUID; let listingID: UUID; let aspect: String; let accepted: [Entry]
    enum CodingKeys: String, CodingKey { case actorID = "actor_id", orgID = "org_id", selectedLibraryOrgID = "selected_library_org_id", listingID = "listing_id", aspect, accepted }
    func checked(context: PropertyVideoJobContext, physicalOrgID: UUID, aspect: String) throws -> Self {
        guard actorID == context.actorID, orgID == physicalOrgID, selectedLibraryOrgID == context.orgID, listingID == context.listingID,
              self.aspect == aspect, accepted.count <= 100, Set(accepted.map { $0.opening.reference.aerialJobID }).count == accepted.count else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        for item in accepted {
            _ = try item.opening.checked(actorID: context.actorID, physicalOrgID: physicalOrgID, selectedLibraryOrgID: context.orgID, listingID: context.listingID, aspect: aspect)
            guard [120, 121].contains(item.opening.availableFrames), item.previewURL.scheme == "https", item.previewURL.user == nil, item.previewURL.password == nil else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        }
        return self
    }
}
struct AerialOpeningJournal: Codable, Equatable {
    let context: PropertyVideoJobContext
    let physicalOrgID: UUID
    let manifest: AerialOpeningManifest
    let quote: AerialOpeningQuote
    let disclosure: String
    let sourcePhotoID: String
    var creditAuthorization: AerialCreditAuthorization? = nil
    var dispatched = false
    var stopRequested = false
    var notAdmittedCancelled: Bool? = nil
    var status: AerialOpeningStatus?
    var dispatchedAt: Date? = nil
    var lastStatusCheckedAt: Date? = nil
    var lastPhaseChangedAt: Date? = nil
    var completedMilestones: Int? = nil
    var progressVersion: Int? = nil

    /// Activity's Stop control is for unfinished processing. A generated
    /// candidate awaiting the person's review has no remaining work to stop.
    var canStopUnfinishedRequest: Bool {
        dispatched && !stopRequested && notAdmittedCancelled != true &&
            status?.isTerminal != true && status?.state != "ready_for_acceptance"
    }

    mutating func recordConfirmedStatus(_ result: AerialOpeningStatus, at now: Date) {
        let incoming = NativeGenerationProgress.steps(kind: "aerial", phase: result.state)
        let previous = NativeGenerationProgress.retained(
            previous: NativeGenerationProgress.normalizedAerialMilestone(completedMilestones, version: progressVersion),
            incoming: NativeGenerationProgress.steps(kind: "aerial", phase: status?.state),
            incomplete: false, total: NativeGenerationProgress.aerialTotal)
        let regressed = previous.flatMap { old in incoming.map { $0 < old } } ?? false
        // Failure and cancellation confirm a terminal outcome, not new work.
        if status?.state != result.state && !regressed && incoming != nil { lastPhaseChangedAt = now }
        lastStatusCheckedAt = now
        completedMilestones = NativeGenerationProgress.retained(previous: previous, incoming: incoming,
            incomplete: ["failed", "ineligible", "cancelled"].contains(result.state), total: NativeGenerationProgress.aerialTotal)
        progressVersion = NativeGenerationProgress.aerialProgressVersion
        status = result
    }
    func generationProgress(checkFailed: Bool = false) -> NativeGenerationProgress {
        let incomplete = notAdmittedCancelled == true || ["failed", "ineligible", "cancelled"].contains(status?.state ?? "")
        return .init(completed: NativeGenerationProgress.retained(
            previous: NativeGenerationProgress.normalizedAerialMilestone(completedMilestones, version: progressVersion),
            incoming: NativeGenerationProgress.steps(kind: "aerial", phase: status?.state), incomplete: incomplete, total: NativeGenerationProgress.aerialTotal), total: NativeGenerationProgress.aerialTotal,
            unit: "steps complete", phase: stopRequested && !incomplete ? "Waiting for stop confirmation" : NativeGenerationProgress.aerialPhase(status?.state),
            active: !incomplete && status?.isTerminal != true && status?.state != "ready_for_acceptance",
            lastCheckedAt: lastStatusCheckedAt, lastProgressAt: lastPhaseChangedAt, checksExpected: true, checkFailed: checkFailed)
    }
}
enum AerialOpeningStore {
    struct Selection: Codable, Equatable { let scope: PropertyVideoOpeningScope; let aspect: String; let reference: PropertyVideoOpening; let included: Bool }
    static func directory(_ context: PropertyVideoJobContext) -> URL {
        FileStore.documents.appendingPathComponent("aerial-openings/\(context.actorID.uuidString)/\(context.orgID.uuidString)/\(context.localListingID.uuidString)", isDirectory: true)
    }
    static func load(_ context: PropertyVideoJobContext) throws -> AerialOpeningJournal? {
        let url = directory(context).appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 262144 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let saved = try JSONDecoder().decode(AerialOpeningJournal.self, from: bytes)
        guard saved.context == context, saved.manifest.isValid,
              saved.creditAuthorization?.isValid != false,
              saved.creditAuthorization == nil || saved.manifest.profile != "kie-kling3-4k-aerial-opening-v1"
        else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return saved
    }
    static func save(_ saved: AerialOpeningJournal) throws {
        let directory = directory(saved.context); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let old = try load(saved.context) {
            if old.manifest.operationID != saved.manifest.operationID {
                guard !saved.dispatched, saved.status == nil, !saved.stopRequested, saved.notAdmittedCancelled != true,
                      !old.dispatched || old.notAdmittedCancelled == true || old.status?.isTerminal == true else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            }
            if old.manifest.operationID == saved.manifest.operationID {
                guard old.manifest == saved.manifest, old.quote == saved.quote, old.physicalOrgID == saved.physicalOrgID,
                      !old.dispatched || saved.dispatched, !old.stopRequested || saved.stopRequested else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            }
        }
        let data = try JSONEncoder().encode(saved), target = directory.appendingPathComponent("pending.json")
        try data.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == data else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        NotificationCenter.default.post(name: .init("rendpropAerialOpeningJournalChanged"), object: nil)
    }
    static func selection(_ context: PropertyVideoJobContext, aspect: String) -> Selection? {
        let url = directory(context).appendingPathComponent("selection-\(aspect == "16:9" ? "wide" : "tall").json")
        guard let data = try? Data(contentsOf: url), data.count <= 32768,
              let value = try? JSONDecoder().decode(Selection.self, from: data), value.aspect == aspect,
              value.scope.actorID == context.actorID, value.scope.selectedLibraryOrgID == context.orgID, value.scope.listingID == context.listingID else { return nil }
        return value
    }
    /// Recovery of a completed generation does not overwrite a newer explicit
    /// older-clip choice or an off preference. Initial acceptance may seed it.
    static func retainAcceptance(_ opening: PropertyVideoAcceptedOpening, context: PropertyVideoJobContext) throws -> Bool {
        if let current = selection(context, aspect: opening.aspect) {
            return current.reference == opening.reference && current.included
        }
        try select(opening, included: true, context: context)
        return true
    }
    static func select(_ opening: PropertyVideoAcceptedOpening, included: Bool, context: PropertyVideoJobContext) throws {
        guard opening.hasValidMediaIdentity, opening.scope.actorID == context.actorID, opening.scope.selectedLibraryOrgID == context.orgID, opening.scope.listingID == context.listingID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let value = Selection(scope: opening.scope, aspect: opening.aspect, reference: opening.reference, included: included)
        try FileManager.default.createDirectory(at: directory(context), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory(context).appendingPathComponent("selection-\(opening.aspect == "16:9" ? "wide" : "tall").json"), options: .atomic)
    }
    /// Turning off an unresolved saved choice needs no new media authority.
    /// Compare the exact preference so a stale screen cannot replace a newer choice.
    static func turnOff(_ expected: Selection, context: PropertyVideoJobContext) throws {
        guard expected.reference.isWellFormed, ["16:9", "9:16"].contains(expected.aspect),
              selection(context, aspect: expected.aspect) == expected else { throw PropertyVideoJobStore.Failure.identityChanged }
        let value = Selection(scope: expected.scope, aspect: expected.aspect, reference: expected.reference, included: false)
        try JSONEncoder().encode(value).write(to: directory(context).appendingPathComponent("selection-\(expected.aspect == "16:9" ? "wide" : "tall").json"), options: .atomic)
        guard selection(context, aspect: expected.aspect) == value else { throw PropertyVideoJobStore.Failure.invalidReceipt }
    }
}
@MainActor enum AerialOpeningService {
    static func catalogue(context: PropertyVideoJobContext, physicalOrgID: UUID, aspect: String) async throws -> AerialOpeningCatalogue {
        let data = try await PropertyVideoJobHTTP.data("GET", context: context, segments: ["aerial-openings"], query: scopeQuery(context) + [.init(name: "aspect", value: aspect)])
        return try JSONDecoder().decode(AerialOpeningCatalogue.self, from: data).checked(context: context, physicalOrgID: physicalOrgID, aspect: aspect)
    }
    static func quote(_ manifest: AerialOpeningManifest, context: PropertyVideoJobContext) async throws -> AerialOpeningQuoteReply {
        guard manifest.isValid, manifest.listingID == context.listingID, manifest.expectedOrgID == context.orgID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        struct Body: Encodable { let manifest: AerialOpeningManifest }
        let data = try await PropertyVideoJobHTTP.data("POST", context: context, segments: ["aerial-openings", "quote"], body: JSONEncoder().encode(Body(manifest: manifest)))
        let reply = try JSONDecoder().decode(AerialOpeningQuoteReply.self, from: data)
        guard reply.manifest == manifest, reply.quote.isValid(for: manifest), !reply.disclosure.isEmpty, reply.disclosure.utf8.count <= 8192 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return reply
    }
    static func submit(_ saved: AerialOpeningJournal, permission: Bool) async throws -> AerialOpeningStatus {
        guard permission, saved.dispatched, !saved.stopRequested, saved.status == nil, saved.quote.isValid(for: saved.manifest),
              let durable = try AerialOpeningStore.load(saved.context), durable == saved else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        struct Body: Encodable { let manifest: AerialOpeningManifest; let quote: AerialOpeningQuote; let consent: AerialOpeningConsent }
        let data = try await PropertyVideoJobHTTP.data("POST", context: saved.context, segments: ["aerial-openings"],
            body: JSONEncoder().encode(Body(manifest: saved.manifest, quote: saved.quote, consent: saved.quote.processorConsent)),
            idempotencyKey: "aerial-opening:" + saved.manifest.operationID.uuidString.lowercased(),
            aerialCredit: saved.creditAuthorization)
        return try decodeStatus(data, saved: saved)
    }
    static func refresh(_ saved: AerialOpeningJournal) async throws -> AerialOpeningStatus? {
        let data: Data
        if let status = saved.status {
            data = try await PropertyVideoJobHTTP.data("GET", context: saved.context, segments: ["aerial-openings", status.aerialJobID.uuidString.lowercased()])
        } else {
            data = try await PropertyVideoJobHTTP.data("GET", context: saved.context, segments: ["aerial-openings", "operations", saved.manifest.operationID.uuidString.lowercased()], query: scopeQuery(saved.context))
        }
        // An unconfirmed operation intentionally fails decoding; it never authorizes another POST.
        return try decodeResolution(data, saved: saved)
    }
    static func cancel(_ saved: AerialOpeningJournal) async throws -> AerialOpeningStatus? {
        guard saved.stopRequested else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        guard let job = saved.status?.aerialJobID else {
            struct Body: Encodable { let manifest: AerialOpeningManifest }
            let data = try await PropertyVideoJobHTTP.data("POST", context: saved.context,
                segments: ["aerial-openings", "operations", saved.manifest.operationID.uuidString.lowercased(), "cancel"],
                body: JSONEncoder().encode(Body(manifest: saved.manifest)), idempotencyKey: "aerial-opening:" + saved.manifest.operationID.uuidString.lowercased())
            return try decodeResolution(data, saved: saved)
        }
        let data = try await PropertyVideoJobHTTP.data("POST", context: saved.context, segments: ["aerial-openings", job.uuidString.lowercased(), "cancel"], body: Data("{}".utf8))
        return try decodeStatus(data, saved: saved)
    }
    static func accept(_ saved: AerialOpeningJournal) async throws -> PropertyVideoAcceptedOpening {
        guard !saved.stopRequested, let status = saved.status, status.mayAccept, let reference = status.candidate else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        struct Body: Encodable { let reference: PropertyVideoOpening }
        struct Reply: Decodable { let opening: PropertyVideoAcceptedOpening }
        let data = try await PropertyVideoJobHTTP.data("POST", context: saved.context, segments: ["aerial-openings", status.aerialJobID.uuidString.lowercased(), "accept"], body: JSONEncoder().encode(Body(reference: reference)))
        let opening = try JSONDecoder().decode(Reply.self, from: data).opening
        guard opening.reference == reference, [120, 121].contains(opening.availableFrames) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return try opening.checked(actorID: saved.context.actorID, physicalOrgID: saved.physicalOrgID, selectedLibraryOrgID: saved.context.orgID, listingID: saved.context.listingID, aspect: saved.manifest.aspect)
    }
    private static func decodeResolution(_ data: Data, saved: AerialOpeningJournal) throws -> AerialOpeningStatus? {
        struct Stopped: Decodable {
            let operationID: UUID; let operationConfirmed: Bool; let admitted: Bool; let cancelled: Bool; let maySubmit: Bool
            enum CodingKeys: String, CodingKey { case operationID = "operation_id", operationConfirmed = "operation_confirmed", admitted, cancelled, maySubmit = "may_submit" }
        }
        if let stopped = try? JSONDecoder().decode(Stopped.self, from: data), stopped.operationID == saved.manifest.operationID,
           stopped.operationConfirmed, !stopped.admitted, stopped.cancelled, !stopped.maySubmit { return nil }
        return try decodeStatus(data, saved: saved)
    }
    private static func decodeStatus(_ data: Data, saved: AerialOpeningJournal) throws -> AerialOpeningStatus {
        let value = try JSONDecoder().decode(AerialOpeningStatus.self, from: data).checked(context: saved.context, physicalOrgID: saved.physicalOrgID, intent: saved.manifest, frozenQuote: saved.quote)
        guard saved.status == nil || saved.status?.aerialJobID == value.aerialJobID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return value
    }
    private static func scopeQuery(_ context: PropertyVideoJobContext) -> [URLQueryItem] {
        [.init(name: "listing_id", value: context.listingID.uuidString.lowercased()), .init(name: "expected_org_id", value: context.orgID.uuidString.lowercased())]
    }
}

extension AerialOpeningService {
    struct Original: Sendable {
        let photoID: String; let url: URL; let width: Int; let height: Int; let contentType: String; let sha256: String; let bytes: Int64
    }
    nonisolated static func originals(listingID: UUID) throws -> [Original] {
        let directory = EnhancedPhoto.directory(for: listingID)
        let index = try PhotoVersionHistory.load(directory: directory)
        return index.orderedForLibrary(Array(index.versions.values)).filter {
            $0.isRetainedOriginalSource && $0.originalVerified && $0.sourceHistoryKnown && $0.provenanceID == nil && !index.hiddenFamilies.contains($0.familyID)
        }.compactMap { version in
            try? inspectOriginal(photoID: version.id, url: directory.appendingPathComponent(version.imageFile))
        }
    }
    nonisolated static func inspectOriginal(photoID: String, url: URL) throws -> Original {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true, let bytes = resource.fileSize,
              bytes > 0, bytes <= 52_428_800, let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0, let type = CGImageSourceGetType(image) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, let digest = DirectUploader.sha256(of: url) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let mime: String
        switch type {
        case "public.jpeg": mime = "image/jpeg"
        case "public.png": mime = "image/png"
        case "org.webmproject.webp": mime = "image/webp"
        case "public.heic": mime = "image/heic"
        case "public.heif": mime = "image/heif"
        default: throw PropertyVideoJobStore.Failure.invalidReceipt
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return Original(photoID: photoID, url: url, width: (5...8).contains(orientation) ? height : width,
            height: (5...8).contains(orientation) ? width : height, contentType: mime, sha256: digest, bytes: Int64(bytes))
    }
    static func register(_ original: Original, operationID: UUID, context: PropertyVideoJobContext, physicalOrgID: UUID,
                         api: APIClient, requireCurrent: @escaping @MainActor () throws -> Void) async throws -> PropertyVideoOpeningSource {
        try requireCurrent()
        // Capture the unchanged bytes into an operation-owned immutable file before
        // the upload journal can acquire a ticket. The source photo is untouched.
        let directory = AerialOpeningStore.directory(context).appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = ["image/heic": "heic", "image/heif": "heif", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"][original.contentType]
        guard let suffix else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let staged = directory.appendingPathComponent(original.sha256 + "." + suffix)
        if !FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.copyItem(at: original.url, to: staged) }
        let pinned = try inspectOriginal(photoID: original.photoID, url: staged)
        guard pinned.sha256 == original.sha256, pinned.bytes == original.bytes, pinned.width == original.width, pinned.height == original.height else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let asset = try await DirectUploader.uploadPhoto(fileURL: staged, listingID: context.listingID, role: "capture", contentType: pinned.contentType,
            keyPrefix: "aerial-original", api: api)
        try requireCurrent()
        guard let assetID = UUID(uuidString: asset), DirectUploader.sha256(of: staged) == original.sha256 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let source = PropertyVideoOpeningSource(photoAssetID: assetID, photoVersionID: "asset:" + assetID.uuidString.lowercased(), photoProvenanceID: nil, sha256: pinned.sha256, bytes: pinned.bytes)
        struct Body: Encodable {
            let operationID: UUID; let listingID: UUID; let expectedOrgID: UUID; let source: PropertyVideoOpeningSource
            enum CodingKeys: String, CodingKey { case operationID = "operation_id", listingID = "listing_id", expectedOrgID = "expected_org_id", source }
        }
        struct Reply: Decodable {
            let actorID: UUID; let orgID: UUID; let selectedLibraryOrgID: UUID; let listingID: UUID; let source: PropertyVideoOpeningSource
            enum CodingKeys: String, CodingKey { case actorID = "actor_id", orgID = "org_id", selectedLibraryOrgID = "selected_library_org_id", listingID = "listing_id", source }
        }
        let data = try await PropertyVideoJobHTTP.data("POST", context: context, segments: ["aerial-openings", "originals"],
            body: JSONEncoder().encode(Body(operationID: operationID, listingID: context.listingID, expectedOrgID: context.orgID, source: source)),
            idempotencyKey: "aerial-original:" + operationID.uuidString.lowercased(), preparationPermission: requireCurrent)
        try requireCurrent()
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.actorID == context.actorID, reply.orgID == physicalOrgID, reply.selectedLibraryOrgID == context.orgID,
              reply.listingID == context.listingID, reply.source == source else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return source
    }
    static func preview(_ status: AerialOpeningStatus, context: PropertyVideoJobContext, requireCurrent: @MainActor () throws -> Void) async throws -> URL {
        guard let url = status.previewURL, let reference = status.candidate, reference.isWellFormed,
              url.scheme == "https", url.user == nil, url.password == nil else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return try await preview(reference: reference, url: url, context: context, requireCurrent: requireCurrent)
    }
    static func preview(reference: PropertyVideoOpening, url: URL, context: PropertyVideoJobContext, requireCurrent: @MainActor () throws -> Void) async throws -> URL {
        guard reference.isWellFormed, url.scheme == "https", url.user == nil, url.password == nil else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        try requireCurrent()
        let target = AerialOpeningStore.directory(context).appendingPathComponent(reference.sha256 + ".mp4")
        if FileManager.default.fileExists(atPath: target.path), FileStore.fileSize(target) == reference.bytes,
           DirectUploader.sha256(of: target) == reference.sha256 { return target }
        var request = URLRequest(url: url); request.timeoutInterval = 120; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporary, response) = try await PropertyVideoJobHTTP.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try requireCurrent()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              FileStore.fileSize(temporary) == reference.bytes, DirectUploader.sha256(of: temporary) == reference.sha256 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}
