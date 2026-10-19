import Foundation

@MainActor protocol PropertyVideoJobsAPI {
    func enqueuePropertyVideo(_ request: PropertyVideoJobRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoJobReply
    func enqueuePropertyVideo(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
    func propertyVideoProcessorContract(context: PropertyVideoJobContext) async throws -> PropertyVideoProcessorContract?
    func propertyVideoOperation(_ saved: PropertyVideoSavedJob, abandon: Bool) async throws -> PropertyVideoOperationLookup
    func propertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
    func cancelPropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
    func resumePropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
}

extension PropertyVideoJobsAPI {
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

extension LiveAPIClient: PropertyVideoJobsAPI {
    @MainActor func enqueuePropertyVideo(_ request: PropertyVideoJobRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoJobReply {
        let contract = try await propertyVideoProcessorContract(context: context)
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
        let currentContract = try await propertyVideoProcessorContract(context: context)
        guard currentContract == saved.processorPermission?.contract else { throw PropertyVideoProcessorFailure.permissionRequired }
        try await PropertyVideoJobCancellation.shared.acknowledgePending(actorID: context.actorID)
        guard let durable = try PropertyVideoJobStore.load(context: context, documents: FileStore.documents),
              durable.request == request, durable.processorPermission == saved.processorPermission,
              durable.reply == nil, durable.stopRequested != true, durable.abandoned == nil else { throw PropertyVideoProcessorFailure.operationPending }
        let data = try JSONEncoder().encode(request)
        do {
            return try await PropertyVideoJobHTTP.perform("POST", context: context, body: data,
                idempotencyKey: "property-video:" + request.operationID.uuidString.lowercased(), paid: saved.processorPermission.map(PropertyVideoPaidAuthorization.processor) ?? .legacy).checked(request: request)
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
        let paid: PropertyVideoPaidAuthorization
        if previous.resumeConsentToken == "property-video-jobs-v1" { paid = .legacy }
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
                     body: Data? = nil, idempotencyKey: String? = nil, query: [URLQueryItem] = [], paid: PropertyVideoPaidAuthorization? = nil) async throws -> Data {
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await session.data(for: request)
        try requireCurrent()
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
        try requireCurrent()
        guard let downloadURL = result.downloadURL else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        var request = URLRequest(url: downloadURL); request.timeoutInterval = 180
        let (file, response) = try await session.download(for: request)
        do {
            try requireCurrent()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("video/") ?? false),
                  FileStore.fileSize(file) == result.bytes else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            let digest = try await Task.detached(priority: .utility) { try ListingVideoStore.digest(file) }.value
            try requireCurrent()
            guard digest == result.sha256 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
}

private final class PropertyVideoJobRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
