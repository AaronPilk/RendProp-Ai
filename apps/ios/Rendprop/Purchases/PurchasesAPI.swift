import Foundation

// MARK: - Entitlement sync (docs/LAUNCH-CONTRACT.md § Entitlement sync)
//
// The client NEVER decides what plan someone is on. It hands Apple's signed
// transaction to the server; the server verifies the JWS chain against Apple's
// root CA, checks the bundle id, maps `productId` → plan, and writes
// `orgs.plan`. What comes back is display-only.
//
//   POST /me/entitlement            (owner JWT)
//   { "signed_transaction": "<JWS>", "signed_renewal_info": "<JWS, optional>" }
//   → 200 { plan, source, expires_at, product_id, original_transaction_id, environment }
//
// Added as a NEW protocol + extensions rather than a method on `APIClient`, so
// `Networking/APIClient.swift` stays untouched (see `AdminRoutingAPI` in
// SettingsView.swift for the same pattern). Call sites use
// `something as? PurchasesAPI`.

/// What `POST /me/entitlement` answers. Wire keys are snake_case.
struct EntitlementSync: Codable, Hashable, Sendable {
    /// Effective plan the server just wrote: free | trial | starter | pro | team.
    let plan: String
    /// Where the plan came from: "apple" | "manual" | "trial".
    let source: String?
    /// When the current period ends (nil for a non-expiring/manual plan).
    let expiresAt: Date?
    /// The App Store product id the server matched.
    let productId: String?
    /// Apple's stable subscription id across renewals.
    let originalTransactionId: String?
    /// "Sandbox" | "Production" — as Apple spells it.
    let environment: String?
    let servingActivation: ServingActivationSummary?

    enum CodingKeys: String, CodingKey {
        case plan
        case source
        case expiresAt = "expires_at"
        case productId = "product_id"
        case originalTransactionId = "original_transaction_id"
        case environment
        case servingActivation = "serving_activation"
    }

    /// Tolerant decoding: `expires_at` arrives as an ISO-8601 string (with or
    /// without fractional seconds), and every field but `plan` may be absent on
    /// an older/leaner server response.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = (try? c.decode(String.self, forKey: .plan)) ?? "free"
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        productId = try? c.decodeIfPresent(String.self, forKey: .productId)
        originalTransactionId = try? c.decodeIfPresent(String.self, forKey: .originalTransactionId)
        environment = try? c.decodeIfPresent(String.self, forKey: .environment)
        servingActivation = try c.decodeIfPresent(ServingActivationSummary.self, forKey: .servingActivation)
        if let activation = servingActivation, activation.checked(org: activation.orgId) == nil {
            throw SubscriptionBillingContext.TrialPresentationError.invalidResponse
        }
        let raw = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
        expiresAt = EntitlementSync.parseDate(raw)
    }

    init(plan: String, source: String?, expiresAt: Date?, productId: String?,
         originalTransactionId: String?, environment: String?, servingActivation: ServingActivationSummary? = nil) {
        self.plan = plan
        self.source = source
        self.expiresAt = expiresAt
        self.productId = productId
        self.originalTransactionId = originalTransactionId
        self.environment = environment
        self.servingActivation = servingActivation
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(plan, forKey: .plan)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(productId, forKey: .productId)
        try c.encodeIfPresent(originalTransactionId, forKey: .originalTransactionId)
        try c.encodeIfPresent(environment, forKey: .environment)
        try c.encodeIfPresent(servingActivation, forKey: .servingActivation)
        if let expiresAt {
            try c.encode(EntitlementSync.isoFormatter.string(from: expiresAt), forKey: .expiresAt)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Supabase timestamps sometimes carry fractional seconds and sometimes don't.
    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

/// The one call the purchase flow makes. `PurchaseManager` holds the client as
/// this protocol so the offline (Mock) build walks the whole paywall.
protocol PurchasesAPI {
    func billingContext() async throws -> SubscriptionBillingContext
    func prepareTrialPurchase(orgID: UUID, productID: String, appAccountToken: UUID) async throws -> TrialPurchaseReservation
    /// POST /me/entitlement — hand Apple's signed transaction to the server and
    /// get back the plan it wrote. Throws `APIError` on a non-2xx.
    func syncEntitlement(signedTransaction: String, signedRenewalInfo: String?, expectedOrgID: UUID?) async throws -> EntitlementSync
}

// MARK: - Live

extension LiveAPIClient: PurchasesAPI {
    func prepareTrialPurchase(orgID: UUID, productID: String, appAccountToken: UUID) async throws -> TrialPurchaseReservation {
        guard AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == appAccountToken,
              WorkspaceContext.billingOrgID == orgID else { throw CloudSyncError.identityChanged }
        let data = try await PurchasesRequest.post(path: ["me", "trial", "prepare"], json: [
            "org_id": orgID.uuidString.lowercased(),
            "actor_id": appAccountToken.uuidString.lowercased(), "app_account_token": appAccountToken.uuidString.lowercased(),
            "product_id": productID
        ], retriesUnauthorized: false, requiredCurrentOrg: orgID)
        return try TrialPurchaseReservation.decode(data, actor: appAccountToken, org: orgID, product: productID)
    }
    func billingContext() async throws -> SubscriptionBillingContext {
        let data = try await PurchasesRequest.getBilling()
        return try SubscriptionBillingContext.fromMe(data, selectedOrg: WorkspaceContext.selectedOrgID, billingOrg: WorkspaceContext.billingOrgID, servingOrg: WorkspaceContext.servingOrgID)
    }
    func syncEntitlement(signedTransaction: String, signedRenewalInfo: String?, expectedOrgID: UUID?) async throws -> EntitlementSync {
        var body: [String: Any] = ["signed_transaction": signedTransaction]
        if let expectedOrgID { body["expected_org_id"] = expectedOrgID.uuidString.lowercased() }
        if let signedRenewalInfo, !signedRenewalInfo.isEmpty {
            body["signed_renewal_info"] = signedRenewalInfo
        }
        let data = try await PurchasesRequest.post(path: ["me", "entitlement"], json: body, requiredCurrentOrg: expectedOrgID)
        let decoder = JSONDecoder()   // EntitlementSync decodes its own snake_case keys
        do {
            let result = try decoder.decode(EntitlementSync.self, from: data)
            if let activation = result.servingActivation {
                guard let expectedOrgID, activation.checked(org: expectedOrgID) != nil else { throw CloudSyncError.invalidResponse }
            }
            return result
        } catch {
            throw APIError.decoding
        }
    }
}

/// Minimal request plumbing for `/me/entitlement`.
///
/// `LiveAPIClient`'s own `url`/`makeRequest`/`execute` helpers are `private`, so
/// an extension in another file cannot call them. This mirrors them exactly —
/// same `apikey` header, same freshly-refreshed bearer, same
/// `Idempotency-Key`-on-every-write rule, same `{error, code}` → `APIError`
/// mapping (via `LiveAPIClient.serverError`, which is internal) — and nothing
/// else. If `Networking/APIClient.swift` ever gains `syncEntitlement` on the
/// `APIClient` protocol, delete this and the body above becomes one line.
@MainActor private enum PurchasesRequest {
    private static let reservationSession = URLSession(configuration: .ephemeral,
        delegate: TrialPurchaseRedirectPolicy(), delegateQueue: nil)
    static func getBilling() async throws -> Data {
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        guard let org = WorkspaceContext.selectedOrgID else { throw CloudSyncError.identityChanged }
        guard let base = Config.apiBaseURL, let token = await AuthStore.validAccessToken() else { throw APIError.notConfigured }
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
              WorkspaceContext.selectedOrgID == org, AuthStore.jwtSubject(token) == actor else { throw CloudSyncError.identityChanged }
        var request = URLRequest(url: base.appendingPathComponent("me"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(org.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw LiveAPIClient.serverError(status: http.statusCode, data: data) }
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
              WorkspaceContext.selectedOrgID == org else { throw CloudSyncError.identityChanged }
        return data
    }
    static func post(path: [String], json: [String: Any], retriesUnauthorized: Bool = true, requiredCurrentOrg: UUID? = nil) async throws -> Data {
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        let viewedOrg = WorkspaceContext.selectedOrgID
        guard var url = Config.apiBaseURL else { throw APIError.notConfigured }
        for segment in path { url.appendPathComponent(segment) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        if let org = json["expected_org_id"] as? String { req.setValue(org, forHTTPHeaderField: "X-Org-Id") }
        if let requiredCurrentOrg { req.setValue(requiredCurrentOrg.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        guard let bodyData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            throw APIError.invalidURL
        }
        req.httpBody = bodyData

        // A retry of the SAME signed transaction must replay server-side rather
        // than write a second entitlement row — the whole reason the header
        // exists (LiveAPIClient.Idempotency.derived). Derived from the payload,
        // so it is stable across attempts and different for a different
        // transaction. 66 chars → inside the server's 8…128 bound.
        let material = "POST\n" + url.path + "\n" + DirectUploader.sha256Hex(bodyData)
        req.setValue("k:" + DirectUploader.sha256Hex(material), forHTTPHeaderField: "Idempotency-Key")

        // Owner route: refresh the JWT right before sending, never send one we
        // know is stale.
        if Config.enableAuth, let token = await AuthStore.validAccessToken() {
            guard AuthStore.jwtSubject(token) == actor else { throw CloudSyncError.identityChanged }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if requiredCurrentOrg != nil, req.value(forHTTPHeaderField: "Authorization") == nil {
            throw APIError.notConfigured
        }

        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
              WorkspaceContext.selectedOrgID == viewedOrg,
              requiredCurrentOrg.map({ WorkspaceContext.billingOrgID == $0 }) ?? true else { throw CloudSyncError.identityChanged }
        let session = retriesUnauthorized ? URLSession.shared : reservationSession
        let (data, resp) = try await session.data(for: req)
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
              WorkspaceContext.selectedOrgID == viewedOrg,
              requiredCurrentOrg.map({ WorkspaceContext.billingOrgID == $0 }) ?? true else { throw CloudSyncError.identityChanged }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        if (200..<300).contains(http.statusCode) { return data }

        // Mirrors LiveAPIClient.execute's retry-once-on-401 (audit finding 8):
        // the pre-flight refresh above can still leave a stale token (a race,
        // or a refresh that silently no-oped), and this POST carries a
        // signed Apple transaction — worth one retry with a forced-fresh
        // token before giving up. The Idempotency-Key was derived from the
        // body alone, so the retry replays server-side rather than risking a
        // second entitlement write.
        if retriesUnauthorized, http.statusCode == 401, Config.enableAuth, AuthStore.shared.isSignedIn {
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { throw CloudSyncError.identityChanged }
            let refreshed = await AuthStore.shared.forceRefresh()
            if refreshed, let fresh = AuthStore.storedAccessToken() {
                guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
                      AuthStore.jwtSubject(fresh) == actor,
                      WorkspaceContext.selectedOrgID == viewedOrg,
                      requiredCurrentOrg.map({ WorkspaceContext.billingOrgID == $0 }) ?? true else { throw CloudSyncError.identityChanged }
                req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                let (data2, resp2) = try await URLSession.shared.data(for: req)
                guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
                      WorkspaceContext.selectedOrgID == viewedOrg,
                      requiredCurrentOrg.map({ WorkspaceContext.billingOrgID == $0 }) ?? true else { throw CloudSyncError.identityChanged }
                guard let http2 = resp2 as? HTTPURLResponse else { throw APIError.badResponse(-1) }
                if (200..<300).contains(http2.statusCode) { return data2 }
                throw LiveAPIClient.serverError(status: http2.statusCode, data: data2)
            }
        }
        throw LiveAPIClient.serverError(status: http.statusCode, data: data)
    }
}

/// A cash reservation POST cannot be redirected to another route or host.
/// A redirect/error is retained as an unresolved outcome, without a new POST.
private final class TrialPurchaseRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Mock (offline dev + the UI walk)

extension MockAPIClient: PurchasesAPI {
    func prepareTrialPurchase(orgID: UUID, productID: String, appAccountToken: UUID) async throws -> TrialPurchaseReservation {
        // Offline preview must not manufacture a funded trial promise.
        throw SubscriptionBillingContext.TrialPresentationError.invalidResponse
    }
    func billingContext() async throws -> SubscriptionBillingContext {
        .init(orgID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, orgName: "Preview workspace",
              role: "owner", canManageSubscription: true, source: nil)
    }
    /// Offline: trust the product id in the JWS payload the caller built. There
    /// is no server to verify anything, and the mock's job is to make every
    /// screen exercisable — never to imply a real entitlement.
    func syncEntitlement(signedTransaction: String, signedRenewalInfo: String?, expectedOrgID: UUID?) async throws -> EntitlementSync {
        _ = signedRenewalInfo; _ = expectedOrgID
        try? await Task.sleep(nanoseconds: 300_000_000)
        let productID = MockAPIClient.productID(inJWS: signedTransaction)
        let plan = productID.flatMap(RendpropProducts.planName(for:)) ?? "pro"
        return EntitlementSync(
            plan: plan,
            source: "apple",
            expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60),
            productId: productID,
            originalTransactionId: "mock-original-transaction",
            environment: "Sandbox")
    }

    /// Best-effort read of `productId` out of a JWS payload (middle segment,
    /// base64url, no signature check — offline only, never a trust decision).
    fileprivate static func productID(inJWS jws: String) -> String? {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["productId"] as? String
    }
}
