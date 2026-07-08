import Foundation

/// Real client against services/api (master spec Part 8.3). Endpoint shapes are
/// in place; flesh out bodies when the backend exists. All POSTs that create or
/// charge must send an Idempotency-Key.
final class LiveAPIClient: APIClient {
    private let base: URL
    private let session: URLSession

    init?(baseURL: URL? = Config.apiBaseURL) {
        guard let baseURL else { return nil }
        self.base = baseURL
        self.session = URLSession(configuration: .default)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" {
            req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        // TODO Phase 2: attach JWT from AuthStore (master spec Part 4.5)
        req.httpBody = body
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func listings() async throws -> [Listing] {
        try await send(request("v1/listings"))
    }

    func createListing(_ listing: Listing) async throws -> Listing {
        try await send(request("v1/listings", method: "POST",
                               body: try JSONEncoder().encode(listing)))
    }

    func requestUpload(filename: String, bytes: Int64) async throws -> UploadTicket {
        struct Body: Codable { let filename: String; let bytes: Int64 }
        return try await send(request("v1/uploads/session", method: "POST",
                                      body: try JSONEncoder().encode(Body(filename: filename, bytes: bytes))))
    }

    func completeUpload(id: String, sha256: String?) async throws {
        struct Body: Codable { let sha256: String? }
        struct Empty: Codable {}
        let _: Empty = try await send(request("v1/uploads/\(id)/complete", method: "POST",
                                              body: try JSONEncoder().encode(Body(sha256: sha256))))
    }

    func createRender(listingID: UUID, tier: Render.Tier, durationS: Double) async throws -> Render {
        struct Body: Codable { let listingId: UUID; let tier: String; let durationS: Double }
        return try await send(request("v1/renders", method: "POST",
                                      body: try JSONEncoder().encode(Body(listingId: listingID, tier: tier.rawValue, durationS: durationS))))
    }

    func renderStatus(id: UUID) async throws -> Render {
        try await send(request("v1/renders/\(id.uuidString)"))
    }
}
