import Foundation
import CryptoKit
import Darwin

@MainActor protocol PropertyVideoJobsAPI {
    func photoMotionCatalogue(context: PropertyVideoJobContext, physicalOrgID: UUID, requireCurrent: @escaping @MainActor () throws -> Void) async throws -> [PropertyVideoPhotoCatalogue.Source]
    func prepareChosenVideoSource(_ request: PropertyVideoPrivateSourceRequest, context: PropertyVideoJobContext, requireCurrent: @escaping @MainActor () throws -> Void) async throws -> PropertyVideoPrivateSourceReply
    func chosenVideoSource(_ request: PropertyVideoPrivateSourceRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoPrivateSourceReply
    func enqueuePropertyVideo(_ request: PropertyVideoJobRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoJobReply
    func enqueuePropertyVideo(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
    func propertyVideoProcessorContract(context: PropertyVideoJobContext) async throws -> PropertyVideoProcessorContract?
    func propertyVideoOperation(_ saved: PropertyVideoSavedJob, abandon: Bool) async throws -> PropertyVideoOperationLookup
    func propertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
    func cancelPropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
    func resumePropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
}

extension PropertyVideoJobsAPI {
    func photoMotionCatalogue(context: PropertyVideoJobContext, physicalOrgID: UUID, requireCurrent: @escaping @MainActor () throws -> Void) async throws -> [PropertyVideoPhotoCatalogue.Source] { throw PropertyVideoJobStore.Failure.invalidReceipt }
    func prepareChosenVideoSource(_ request: PropertyVideoPrivateSourceRequest, context: PropertyVideoJobContext, requireCurrent: @escaping @MainActor () throws -> Void) async throws -> PropertyVideoPrivateSourceReply { throw PropertyVideoJobStore.Failure.invalidReceipt }
    func chosenVideoSource(_ request: PropertyVideoPrivateSourceRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoPrivateSourceReply { throw PropertyVideoJobStore.Failure.invalidReceipt }
    func enqueuePropertyVideo(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply {
        guard saved.processorPermission == nil else { throw PropertyVideoProcessorFailure.permissionRequired }
        return try await enqueuePropertyVideo(saved.request, context: saved.context)
    }
    func propertyVideoProcessorContract(context: PropertyVideoJobContext) async throws -> PropertyVideoProcessorContract? { throw PropertyVideoProcessorFailure.unknownDisclosure }
    func propertyVideoOperation(_ saved: PropertyVideoSavedJob, abandon: Bool) async throws -> PropertyVideoOperationLookup { throw PropertyVideoProcessorFailure.operationPending }
}

extension PropertyVideoJobContext {
    @MainActor var isCurrent: Bool { hasCurrentIdentity && AIConsent.shared.isGranted }
    @MainActor var hasCurrentIdentity: Bool {
        AuthStore.shared.isIdentified && AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == actorID &&
        WorkspaceContext.selectedOrgID == orgID
    }
}

/// A private Photo motion Original uses the existing capture upload authority,
/// independently of the smaller public-gallery delivery. No catalogue proof is
/// invented: normal job admission verifies the completed owned upload again.
enum PropertyVideoOriginalMaster {
    static func isOriginal(_ version: PhotoVersionHistory.Version, imageURL: URL, originalURL: URL) throws -> Bool {
        try version.provenanceID == nil && !version.provenanceRecorded &&
            (try PhotoGalleryDerivativeStore.verifiedCapture(version, imageURL: imageURL, originalURL: originalURL))
    }
    /// Read-only cold restoration: a saved J request can restore its local H
    /// timing only while the exact durable Original→browser binding and completed
    /// upload still prove that same asset. Never regenerate or rewrite a request.
    @MainActor static func restoredTimingKey(_ source: PropertyVideoJobSource,
        version: PhotoVersionHistory.Version, imageURL: URL, originalURL: URL,
        context: PropertyVideoJobContext, physicalOrgID: UUID,
        derivatives: PhotoGalleryDerivativeStore = .shared, journal: DirectUploadJournal = .shared,
        requireCurrent: @escaping @MainActor () throws -> Void) async throws -> String? {
        try requireCurrent()
        guard context.hasCurrentIdentity, source.photoID == version.id, source.photoProvenanceID == nil,
              source.photoVersionID == "asset:" + source.photoAssetID.uuidString.lowercased(),
              PhotoMotionContract.frames.contains(source.visibleFrames ?? 0),
              try isOriginal(version, imageURL: imageURL, originalURL: originalURL) else { return nil }
        let raw = try PhotoGalleryDerivativeStore.measure(imageURL)
        let history = try PhotoGalleryDerivativeStore.historySHA256(version, directory: imageURL.deletingLastPathComponent())
        if source.sourceSHA256 == raw.sha256, source.sourceBytes == raw.bytes {
            return PhotoMotionContract.timingKey(photoID: source.photoID, provenanceID: nil, sha256: raw.sha256)
        }
        let identity = PhotoCloudSelectionIdentity(actorID: context.actorID, libraryOrgID: context.orgID,
            localListingID: context.localListingID, serverListingID: context.listingID)
        let binding = PhotoGalleryDerivativeStore.Source(identity: identity, versionID: version.id, familyID: version.familyID,
            imageFile: version.imageFile, historySHA256: history, sha256: raw.sha256, bytes: raw.bytes)
        guard let copy = try await derivatives.lookup(sourceURL: imageURL, source: binding),
              copy.delivery.physicalOrgID == physicalOrgID, copy.delivery.sha256 == source.sourceSHA256,
              copy.delivery.bytes == source.sourceBytes else { return nil }
        let key = DirectUploader.photoJournalKey(owner: context.actorID.uuidString.lowercased(), listingID: context.listingID,
            role: "gallery", keyPrefix: "gallery", digest: copy.delivery.sha256, bytes: copy.delivery.bytes)
        guard let upload = try await journal.load(key), upload.completed, let ticket = upload.ticket,
              UUID(uuidString: ticket.assetID) == source.photoAssetID else { return nil }
        try await DirectUploader.requireGalleryReceipt(fileURL: copy.url, ownerID: context.actorID,
            listingID: context.listingID, assetID: source.photoAssetID, sha256: copy.delivery.sha256,
            bytes: copy.delivery.bytes, storageKey: ticket.storageKey, journalStore: journal)
        try requireCurrent()
        guard context.hasCurrentIdentity, try isOriginal(version, imageURL: imageURL, originalURL: originalURL),
              (try PhotoGalleryDerivativeStore.measure(imageURL)) == raw,
              (try PhotoGalleryDerivativeStore.historySHA256(version, directory: imageURL.deletingLastPathComponent())) == history else { return nil }
        return PhotoMotionContract.timingKey(photoID: source.photoID, provenanceID: nil, sha256: raw.sha256)
    }
    @MainActor static func upload(version: PhotoVersionHistory.Version, imageURL: URL, originalURL: URL,
        sha256: String, bytes: Int64, context: PropertyVideoJobContext, api: APIClient,
        documents: URL = FileStore.documents, journal: DirectUploadJournal = .shared,
        requireCurrent: @escaping @MainActor () throws -> Void,
        transfer: (URLRequest, URL) async throws -> URLResponse = { request, file in
            try await URLSession.shared.upload(for: request, fromFile: file).1
        }) async throws -> UUID {
        try requireCurrent()
        guard context.hasCurrentIdentity, try isOriginal(version, imageURL: imageURL, originalURL: originalURL),
              bytes > 0, bytes <= 52_428_800 else { throw PhotoCloudSelectionFailure.changed }
        let history = try PhotoGalleryDerivativeStore.historySHA256(version, directory: imageURL.deletingLastPathComponent())
        let body = try DirectUploader.browserPhoto(imageURL)
        guard body.sha256 == sha256, body.bytes == bytes else { throw PhotoCloudSelectionFailure.changed }
        let directory = documents.appendingPathComponent("reels/PhotoMotionOriginals", isDirectory: true)
            .appendingPathComponent(context.actorID.uuidString + "-" + context.orgID.uuidString + "-" + context.listingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in [directory, directory.deletingLastPathComponent(), directory.deletingLastPathComponent().deletingLastPathComponent()] {
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw PhotoCloudSelectionFailure.changed }
        }
        let suffix = body.contentType == "image/jpeg" ? "jpg" : body.contentType == "image/png" ? "png" : "webp"
        let staged = directory.appendingPathComponent(body.sha256 + "." + suffix)
        if !FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.copyItem(at: imageURL, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        }
        guard try DirectUploader.browserPhoto(staged) == body else { throw PhotoCloudSelectionFailure.changed }
        func check() throws {
            try requireCurrent()
            guard context.hasCurrentIdentity, try isOriginal(version, imageURL: imageURL, originalURL: originalURL),
                  (try PhotoGalleryDerivativeStore.historySHA256(version, directory: imageURL.deletingLastPathComponent())) == history,
                  (try DirectUploader.browserPhoto(imageURL)) == body,
                  (try DirectUploader.browserPhoto(staged)) == body else { throw PhotoCloudSelectionFailure.changed }
        }
        try check()
        let result = try await DirectUploader.uploadPhoto(fileURL: staged, listingID: context.listingID,
            role: "capture", contentType: body.contentType, keyPrefix: "photo-motion-original", api: api,
            journalStore: journal, transfer: { request, file in
                try check()
                let response = try await transfer(request, file)
                try check()
                return response
            })
        try check()
        guard let asset = UUID(uuidString: result) else { throw PhotoCloudSelectionFailure.unmapped }
        return asset
    }
}

extension LiveAPIClient: PropertyVideoJobsAPI {
    @MainActor func photoMotionCatalogue(context: PropertyVideoJobContext, physicalOrgID: UUID, requireCurrent: @escaping @MainActor () throws -> Void) async throws -> [PropertyVideoPhotoCatalogue.Source] {
        var sources: [PropertyVideoPhotoCatalogue.Source] = [], offset = 0, count: Int?
        repeat {
            try requireCurrent()
            let data = try await PropertyVideoJobHTTP.data("GET", context: context, segments: ["sources", "versions"], query: [
                .init(name: "listing_id", value: context.listingID.uuidString.lowercased()),
                .init(name: "expected_org_id", value: context.orgID.uuidString.lowercased()),
                .init(name: "offset", value: String(offset))])
            try requireCurrent()
            let page = try JSONDecoder().decode(PropertyVideoPhotoCatalogue.self, from: data).checked(context: context, physicalOrgID: physicalOrgID, offset: offset)
            guard count == nil || count == page.selectedCount else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            count = page.selectedCount; sources += page.sources
            guard Set(sources.map(\.assetID)).count == sources.count else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            guard let next = page.nextOffset else { return sources }
            offset = next
        } while offset < 1000
        throw PropertyVideoJobStore.Failure.invalidReceipt
    }
    @MainActor func prepareChosenVideoSource(_ request: PropertyVideoPrivateSourceRequest, context: PropertyVideoJobContext, requireCurrent: @escaping @MainActor () throws -> Void) async throws -> PropertyVideoPrivateSourceReply {
        try requireCurrent()
        guard context.isCurrent, request.listingID == context.listingID, request.expectedOrgID == context.orgID else { throw PropertyVideoJobStore.Failure.identityChanged }
        let data = try await PropertyVideoJobHTTP.data("POST", context: context, segments: ["sources", "prepare-chosen"], body: JSONEncoder().encode(request), idempotencyKey: "property-video-source:" + request.operationID.uuidString.lowercased(), preparationPermission: requireCurrent)
        try requireCurrent()
        return try JSONDecoder().decode(PropertyVideoPrivateSourceReply.self, from: data).checked(context: context, request: request)
    }
    @MainActor func chosenVideoSource(_ request: PropertyVideoPrivateSourceRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoPrivateSourceReply {
        let data = try await PropertyVideoJobHTTP.data("GET", context: context, segments: ["sources", "prepare-chosen"], query: [.init(name: "operation_id", value: request.operationID.uuidString.lowercased()), .init(name: "listing_id", value: context.listingID.uuidString.lowercased()), .init(name: "expected_org_id", value: context.orgID.uuidString.lowercased())])
        return try JSONDecoder().decode(PropertyVideoPrivateSourceReply.self, from: data).checked(context: context, request: request)
    }
    @MainActor func enqueuePropertyVideo(_ request: PropertyVideoJobRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoJobReply {
        let contract = request.isPhotoMotion ? nil : (try await propertyVideoProcessorContract(context: context))
        guard contract == nil else { throw PropertyVideoProcessorFailure.permissionRequired }
        return try await enqueuePropertyVideo(PropertyVideoSavedJob(context: context, request: request, createdAt: Date()))
    }
    @MainActor func propertyVideoProcessorContract(context: PropertyVideoJobContext) async throws -> PropertyVideoProcessorContract? {
        do {
            return try PropertyVideoProcessorContract.decodePublished(await PropertyVideoJobHTTP.data("GET", context: context, segments: ["processor-consent"]))
        } catch let error as APIError {
            if case let .server(status, code, _) = error, status == 404, code == "processor_disclosure_unpublished" { return nil }
            throw error
        }
    }
    @MainActor func propertyVideoOperation(_ saved: PropertyVideoSavedJob, abandon: Bool) async throws -> PropertyVideoOperationLookup {
        let request = saved.request
        let data: Data
        if abandon {
            let body = try JSONSerialization.data(withJSONObject: ["listing_id": request.listingID.uuidString.lowercased(), "expected_org_id": request.expectedOrgID.uuidString.lowercased()], options: [.sortedKeys])
            data = try await PropertyVideoJobHTTP.data("POST", context: saved.context,
                segments: ["operations", request.operationID.uuidString.lowercased(), "abandon"], body: body,
                idempotencyKey: "property-video-abandon:" + request.operationID.uuidString.lowercased())
        } else {
            data = try await PropertyVideoJobHTTP.data("GET", context: saved.context, segments: [], query: [
                .init(name: "listing_id", value: request.listingID.uuidString.lowercased()),
                .init(name: "expected_org_id", value: request.expectedOrgID.uuidString.lowercased()),
                .init(name: "operation_id", value: request.operationID.uuidString.lowercased())])
        }
        return try JSONDecoder().decode(PropertyVideoOperationLookup.self, from: data).checked(request: request)
    }
    @MainActor func enqueuePropertyVideo(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply {
        let request = saved.request, context = saved.context
        guard saved.reply == nil, saved.stopRequested != true, saved.abandoned == nil,
              request.isValid, request.listingID == context.listingID, request.expectedOrgID == context.orgID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        if request.isPhotoMotion {
            guard saved.processorPermission == nil else { throw PropertyVideoProcessorFailure.permissionRequired }
        } else {
            let currentContract = try await propertyVideoProcessorContract(context: context)
            guard currentContract == saved.processorPermission?.contract else { throw PropertyVideoProcessorFailure.permissionRequired }
        }
        try await PropertyVideoJobCancellation.shared.acknowledgePending(actorID: context.actorID)
        guard let durable = try PropertyVideoJobStore.load(context: context, documents: FileStore.documents),
              durable.request == request, durable.processorPermission == saved.processorPermission,
              durable.reply == nil, durable.stopRequested != true, durable.abandoned == nil else { throw PropertyVideoProcessorFailure.operationPending }
        let data = try JSONEncoder().encode(request)
        do {
            return try await PropertyVideoJobHTTP.perform("POST", context: context, body: data,
                idempotencyKey: "property-video:" + request.operationID.uuidString.lowercased(), paid: request.isPhotoMotion ? nil : (saved.processorPermission.map(PropertyVideoPaidAuthorization.processor) ?? .legacy)).checked(request: request)
        } catch let error as APIError {
            guard case let .server(status, code, message) = error, status == 402, code == "capacity_refused" else { throw error }
            let current = try await PropertyVideoJobHTTP.data("GET", context: context, segments: [], query: [
                .init(name: "listing_id", value: request.listingID.uuidString.lowercased()),
                .init(name: "expected_org_id", value: request.expectedOrgID.uuidString.lowercased()),
                .init(name: "operation_id", value: request.operationID.uuidString.lowercased()),
            ])
            let lookup = try JSONDecoder().decode(PropertyVideoOperationLookup.self, from: current)
            switch try PropertyVideoAdmissionResolution.resolve(status: status, code: code, message: message, request: request, lookup: lookup) {
            case .accepted(let job): return job
            case .refused(let refusal): throw refusal
            case nil: throw error
            }
        }
    }
    @MainActor func propertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply {
        guard let jobID = saved.reply?.jobID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return try await PropertyVideoJobHTTP.perform("GET", context: saved.context, jobID: jobID)
            .checked(request: saved.request, previous: saved.reply)
    }
    @MainActor func cancelPropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply {
        guard let jobID = saved.reply?.jobID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return try await PropertyVideoJobHTTP.perform("POST", context: saved.context, jobID: jobID, action: "cancel",
            body: Data("{}".utf8), idempotencyKey: "property-video-cancel:" + jobID.uuidString.lowercased())
            .checked(request: saved.request, previous: saved.reply)
    }
    @MainActor func resumePropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply {
        guard let previous = saved.reply, previous.mayResume else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        if let durable = try PropertyVideoJobStore.load(context: saved.context, documents: FileStore.documents) {
            guard durable.request == saved.request, durable.processorPermission == saved.processorPermission, durable.stopRequested != true, durable.abandoned == nil else { throw PropertyVideoProcessorFailure.operationPending }
        }
        let paid: PropertyVideoPaidAuthorization?
        if saved.request.isPhotoMotion, previous.resumeConsentToken == "photo-motion-v1" { paid = nil }
        else if previous.resumeConsentToken == "property-video-jobs-v1" { paid = .legacy }
        else if previous.resumeConsentToken == "property-video-jobs-v2", let permission = PropertyVideoProcessorConsent.shared.grant(for: saved.context) {
            paid = .processor(permission)
        } else { throw PropertyVideoProcessorFailure.unknownSavedAuthority }
        return try await PropertyVideoJobHTTP.perform("POST", context: saved.context, jobID: previous.jobID, action: "resume",
            body: Data("{}".utf8), paid: paid).checked(request: saved.request, previous: previous)
    }
}

@MainActor enum PropertyVideoJobHTTP {
    // Internal transport seam for closed URLProtocol tests; consent and scope
    // checks remain in data(), regardless of transport.
    static var session = URLSession(configuration: .ephemeral, delegate: PropertyVideoJobRedirectPolicy(), delegateQueue: nil)
    static func selectedListingDownload(context: PropertyVideoJobContext, physicalOrgID: UUID?,
                                        liveDuration: Double) async throws -> SelectedListingVideoDownload {
        let data = try await PropertyVideoJobHTTP.data("GET", context: context, segments: ["selected-download"], query: [
            .init(name: "listing_id", value: context.listingID.uuidString.lowercased()),
            .init(name: "expected_org_id", value: context.orgID.uuidString.lowercased())])
        return try JSONDecoder().decode(SelectedListingVideoDownload.self, from: data).checked(
            listingID: context.listingID, libraryID: context.orgID,
            physicalOrgID: physicalOrgID, liveDuration: liveDuration)
    }
    static func stopOwnedJobs(_ intent: PropertyVideoCancellationIntent) async throws {
        guard intent.isValid, var url = Config.apiBaseURL else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let revision = AuthStore.shared.syncSessionRevision
        func requireActor() throws {
            guard AuthStore.shared.isIdentified, AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == intent.actorID,
                  AuthStore.shared.syncSessionRevision == revision else { throw PropertyVideoJobStore.Failure.identityChanged }
        }
        try requireActor()
        guard let token = await AuthStore.validAccessToken(), AuthStore.jwtSubject(token).flatMap(UUID.init(uuidString:)) == intent.actorID else {
            throw PropertyVideoJobStore.Failure.identityChanged
        }
        try requireActor()
        url.appendPathComponent("property-video-jobs"); url.appendPathComponent("cancel-all")
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("property-video-stop:" + intent.operationID.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["operation_id": intent.operationID.uuidString.lowercased(), "reason": intent.reason], options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        try requireActor()
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw LiveAPIClient.serverError(status: http.statusCode, data: data) }
        guard data.count <= 4096, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = body["cancelled_count"] as? Int, count >= 0 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
    }
    static func perform(_ method: String, context: PropertyVideoJobContext, jobID: UUID? = nil, action: String? = nil,
                        body: Data? = nil, idempotencyKey: String? = nil, paid: PropertyVideoPaidAuthorization? = nil) async throws -> PropertyVideoJobReply {
        var segments: [String] = []
        if let jobID { segments.append(jobID.uuidString.lowercased()) }
        if let action { segments.append(action) }
        return try JSONDecoder().decode(PropertyVideoJobReply.self,
            from: await data(method, context: context, segments: segments, body: body, idempotencyKey: idempotencyKey, paid: paid))
    }
    static func data(_ method: String, context: PropertyVideoJobContext, segments: [String],
                     body: Data? = nil, idempotencyKey: String? = nil, query: [URLQueryItem] = [], paid: PropertyVideoPaidAuthorization? = nil, aerialCredit: AerialCreditAuthorization? = nil, preparationPermission: (@MainActor () throws -> Void)? = nil) async throws -> Data {
        guard context.hasCurrentIdentity, var url = Config.apiBaseURL else { throw PropertyVideoJobStore.Failure.identityChanged }
        let revision = AuthStore.shared.syncSessionRevision, consent = AIConsent.shared.revocationRevision
        let processorEpoch = PropertyVideoProcessorConsent.shared.revision
        func requireCurrent() throws {
            try Task.checkCancellation()
            guard context.hasCurrentIdentity, AuthStore.shared.syncSessionRevision == revision,
                  AIConsent.shared.revocationRevision == consent else { throw PropertyVideoJobStore.Failure.identityChanged }
            if let paid {
                if case .processor = paid, PropertyVideoProcessorConsent.shared.revision != processorEpoch { throw PropertyVideoProcessorFailure.permissionRequired }
                _ = try paid.headers(context: context)
            }
            if let aerialCredit {
                guard aerialCredit.isValid, segments == ["aerial-openings"], method == "POST" else {
                    throw PropertyVideoJobStore.Failure.invalidReceipt
                }
            }
        }
        url.appendPathComponent("property-video-jobs")
        for segment in segments { url.appendPathComponent(segment) }
        if !query.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            components.queryItems = query
            guard let target = components.url else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            url = target
        }
        guard let token = await AuthStore.validAccessToken(), AuthStore.jwtSubject(token).flatMap(UUID.init(uuidString:)) == context.actorID else {
            throw PropertyVideoJobStore.Failure.identityChanged
        }
        try requireCurrent()
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(context.orgID.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id")
        if let paid { for (key, value) in try paid.headers(context: context) { request.setValue(value, forHTTPHeaderField: key) } }
        if let aerialCredit {
            request.setValue(aerialCredit.tariffVersion, forHTTPHeaderField: "X-Rendprop-Credit-Tariff")
            request.setValue(aerialCredit.environment, forHTTPHeaderField: "X-Rendprop-Credit-Environment")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        try preparationPermission?()
        let (data, response) = try await session.data(for: request)
        try requireCurrent()
        try preparationPermission?()
        guard let response = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(response.statusCode) else { throw LiveAPIClient.serverError(status: response.statusCode, data: data) }
        guard data.count <= 262144 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return data
    }
    static func putAudio(url: URL, headers: [String: String], file: URL, requireCurrent: @MainActor () throws -> Void) async throws {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              headers.keys.allSatisfy({ ["content-type", "content-length", "if-none-match"].contains($0.lowercased()) || $0.lowercased().hasPrefix("x-amz-") }) else {
            throw PropertyVideoJobStore.Failure.invalidReceipt
        }
        try requireCurrent()
        var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 120
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await session.upload(for: request, fromFile: file)
        try requireCurrent()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
    /// The renewed private capability is sent alone: no Supabase bearer, cookies,
    /// redirects or signed URL is retained in the durable receipt after download.
    static func download(_ result: PropertyVideoJobResult, requireCurrent: @MainActor () throws -> Void) async throws -> URL {
        guard let downloadURL = result.downloadURL else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return try await downloadVerified(url: downloadURL, bytes: result.bytes, sha256: result.sha256, requireCurrent: requireCurrent)
    }
    static func downloadSelected(_ selected: SelectedListingVideoDownload,
                                 requireCurrent: @MainActor () throws -> Void) async throws -> URL {
        try await downloadVerified(url: selected.downloadURL, bytes: selected.bytes,
                                   sha256: selected.sha256, requireCurrent: requireCurrent)
    }
    private static func downloadVerified(url: URL, bytes: Int64, sha256: String,
                                         requireCurrent: @MainActor () throws -> Void) async throws -> URL {
        try requireCurrent()
        var request = URLRequest(url: url); request.timeoutInterval = 180
        let (file, response) = try await session.download(for: request)
        do {
            try requireCurrent()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("video/") ?? false),
                  FileStore.fileSize(file) == bytes else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            let digest = try await Task.detached(priority: .utility) { try ListingVideoStore.digest(file) }.value
            try requireCurrent()
            guard digest == sha256 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
}

private final class PropertyVideoJobRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

// MARK: Durable private source preparation (no provider request)
@MainActor enum PropertyVideoPrivateSourceRunner {
    struct Binding: Codable, Equatable { let preparationID: UUID; let orgID: UUID; let provenanceID: UUID?; var ready: PropertyVideoPrivateSourceReply.Source? = nil }
    struct Journal: Codable, Equatable {
        let context: PropertyVideoJobContext
        let master: PropertyVideoChosenMaster
        let request: PropertyVideoPrivateSourceRequest
        let attempted: Bool
        var binding: Binding? = nil
    }
    enum Failure: Error, LocalizedError, Equatable {
        case pending, failed
        var errorDescription: String? { self == .pending ? "This exact photo preparation is saved. Try Create again to check it; no new preparation will be sent." : "This chosen photo could not be prepared. Its original and listing selection are kept." }
    }
    static func file(context: PropertyVideoJobContext, master: PropertyVideoChosenMaster, documents: URL) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = try encoder.encode(Journal(context: context, master: master, request: .init(operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, context: context, master: master), attempted: false))
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return documents.appendingPathComponent("video-source-preparations", isDirectory: true).appendingPathComponent(key + ".json")
    }
    static func prepare(master: PropertyVideoChosenMaster, context: PropertyVideoJobContext, api: any PropertyVideoJobsAPI,
                        documents: URL, requireCurrent: @escaping @MainActor () throws -> Void,
                        delay: @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> PropertyVideoPrivateSourceReply {
        try requireCurrent()
        guard master.isValid else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let path = try file(context: context, master: master, documents: documents)
        var journal: Journal
        let first: Bool
        if AdoptionOwnedIdentity.pathIsOccupied(path) {
            let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= 16384 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.read(upToCount: 16385) ?? Data()
            guard data.count <= 16384 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            journal = try JSONDecoder().decode(Journal.self, from: data)
            guard journal.context == context, journal.master == master, journal.attempted,
                  journal.request.matches(context: context, master: master) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            first = false
        } else {
            journal = .init(context: context, master: master, request: .init(operationID: UUID(), context: context, master: master), attempted: true)
            let data = try JSONEncoder().encode(journal)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            guard try Data(contentsOf: path) == data else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            first = true // Attempt marker is durable BEFORE the only POST.
        }
        try requireCurrent()
        var reply = first ? try await api.prepareChosenVideoSource(journal.request, context: context, requireCurrent: requireCurrent)
                          : try await api.chosenVideoSource(journal.request, context: context)
        try requireCurrent(); reply = try reply.checked(context: context, request: journal.request)
        func bind(_ value: PropertyVideoPrivateSourceReply) throws {
            let next = Binding(preparationID: value.preparationID, orgID: value.orgID, provenanceID: value.master.photoProvenanceID, ready: value.source)
            if let prior = journal.binding {
                guard prior.preparationID == next.preparationID, prior.orgID == next.orgID, prior.provenanceID == next.provenanceID,
                      prior.ready == nil || prior.ready == next.ready else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            }
            if journal.binding != next {
                journal.binding = next
                try JSONEncoder().encode(journal).write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
        }
        try bind(reply)
        let started = Date()
        for _ in 0..<60 {
            if reply.state == "ready" { return reply }
            if reply.state == "failed" { throw Failure.failed }
            guard Date().timeIntervalSince(started) < 120 else { throw Failure.pending }
            try await delay(2_000_000_000); try requireCurrent()
            let fresh = try await api.chosenVideoSource(journal.request, context: context)
            try requireCurrent(); reply = try fresh.checked(context: context, request: journal.request, previous: reply); try bind(reply)
        }
        throw Failure.pending
    }
}
