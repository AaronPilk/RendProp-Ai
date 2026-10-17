import Foundation

protocol WebsiteDesignAPI {
    func websiteDesignState(context: WebsiteDesignContext) async throws -> WebsiteDesignState
    func assignWebsiteUpgrade(signedTransaction: String, context: WebsiteDesignContext) async throws -> WebsiteDesignState
    func selectWebsiteDesign(_ design: WebsiteDesign, context: WebsiteDesignContext) async throws -> WebsiteDesignState
}

extension LiveAPIClient: WebsiteDesignAPI {
    func websiteDesignState(context: WebsiteDesignContext) async throws -> WebsiteDesignState {
        try await WebsiteDesignRequest.perform("GET", context: context)
    }
    func assignWebsiteUpgrade(signedTransaction: String, context: WebsiteDesignContext) async throws -> WebsiteDesignState {
        guard !signedTransaction.isEmpty, signedTransaction.utf8.count <= 65536 else { throw CloudSyncError.invalidResponse }
        return try await WebsiteDesignRequest.perform("POST", action: "upgrade", context: context,
            body: ["signed_transaction": signedTransaction, "expected_org_id": context.orgID.uuidString.lowercased()])
    }
    func selectWebsiteDesign(_ design: WebsiteDesign, context: WebsiteDesignContext) async throws -> WebsiteDesignState {
        try await WebsiteDesignRequest.perform("PATCH", context: context,
            body: ["website_theme": design.rawValue, "expected_org_id": context.orgID.uuidString.lowercased()])
    }
}

@MainActor private enum WebsiteDesignRequest {
    private static let session = URLSession(configuration: .ephemeral,
        delegate: WebsiteDesignRedirectPolicy(), delegateQueue: nil)

    static func perform(_ method: String, action: String? = nil, context: WebsiteDesignContext,
                        body: [String: Any]? = nil) async throws -> WebsiteDesignState {
        guard context.isCurrent, var url = Config.apiBaseURL else { throw CloudSyncError.identityChanged }
        url.appendPathComponent("property-sites"); url.appendPathComponent(context.listingID.uuidString.lowercased())
        if let action { url.appendPathComponent(action) }
        guard let token = await AuthStore.validAccessToken(), context.isCurrent,
              AuthStore.jwtSubject(token).flatMap(UUID.init(uuidString:)) == context.actorID else {
            throw CloudSyncError.identityChanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(context.orgID.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.httpBody = bytes
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("k:" + DirectUploader.sha256Hex(method + "\n" + url.path + "\n" + DirectUploader.sha256Hex(bytes)),
                             forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await session.data(for: request)
        guard context.isCurrent else { throw CloudSyncError.identityChanged }
        guard let response = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(response.statusCode) else {
            throw LiveAPIClient.serverError(status: response.statusCode, data: data)
        }
        guard data.count <= 262144 else { throw CloudSyncError.invalidResponse }
        return try JSONDecoder().decode(WebsiteDesignState.self, from: data).checked(for: context)
    }
}

private final class WebsiteDesignRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
