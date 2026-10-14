import Foundation

@MainActor protocol PropertyVideoJobsAPI {
    func enqueuePropertyVideo(_ request: PropertyVideoJobRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoJobReply
    func propertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
    func cancelPropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
    func resumePropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply
}

extension PropertyVideoJobContext {
    @MainActor var isCurrent: Bool {
        AuthStore.shared.isIdentified && AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == actorID &&
        WorkspaceContext.selectedOrgID == orgID && AIConsent.shared.isGranted
    }
}

extension LiveAPIClient: PropertyVideoJobsAPI {
    @MainActor func enqueuePropertyVideo(_ request: PropertyVideoJobRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoJobReply {
        guard request.isValid, request.listingID == context.listingID, request.expectedOrgID == context.orgID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        try await PropertyVideoJobCancellation.shared.acknowledgePending(actorID: context.actorID)
        let data = try JSONEncoder().encode(request)
        do {
            return try await PropertyVideoJobHTTP.perform("POST", context: context, body: data,
                idempotencyKey: "property-video:" + request.operationID.uuidString.lowercased()).checked(request: request)
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
        return try await PropertyVideoJobHTTP.perform("POST", context: saved.context, jobID: previous.jobID, action: "resume",
            body: Data("{}".utf8)).checked(request: saved.request, previous: previous)
    }
}

@MainActor enum PropertyVideoJobHTTP {
    private static let session = URLSession(configuration: .ephemeral, delegate: PropertyVideoJobRedirectPolicy(), delegateQueue: nil)
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
                        body: Data? = nil, idempotencyKey: String? = nil) async throws -> PropertyVideoJobReply {
        var segments: [String] = []
        if let jobID { segments.append(jobID.uuidString.lowercased()) }
        if let action { segments.append(action) }
        return try JSONDecoder().decode(PropertyVideoJobReply.self,
            from: await data(method, context: context, segments: segments, body: body, idempotencyKey: idempotencyKey))
    }
    static func data(_ method: String, context: PropertyVideoJobContext, segments: [String],
                     body: Data? = nil, idempotencyKey: String? = nil, query: [URLQueryItem] = []) async throws -> Data {
        guard context.isCurrent, var url = Config.apiBaseURL else { throw PropertyVideoJobStore.Failure.identityChanged }
        let revision = AuthStore.shared.syncSessionRevision, consent = AIConsent.shared.revocationRevision
        func requireCurrent() throws {
            try Task.checkCancellation()
            guard context.isCurrent, AuthStore.shared.syncSessionRevision == revision,
                  AIConsent.shared.revocationRevision == consent else { throw PropertyVideoJobStore.Failure.identityChanged }
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
        request.setValue("property-video-jobs-v1", forHTTPHeaderField: "x-rendprop-ai-consent")
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
