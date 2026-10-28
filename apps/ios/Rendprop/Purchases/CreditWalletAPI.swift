import Foundation

protocol CreditWalletAPI {
    func creditWallet(context: CreditWalletContext, environment: String) async throws -> CreditWalletSnapshot
    func openCreditPurchaseIntents(context: CreditWalletContext) async throws -> CreditOpenIntents
    func prepareCreditPurchase(productID: String, environment: String,
                               context: CreditWalletContext) async throws -> CreditPurchasePreparation
    func abandonCreditPurchase(intent: CreditPurchaseIntent, context: CreditWalletContext) async throws
    func settleCreditPurchase(signedTransaction: String, intentID: UUID?, expectedOrgID: UUID?,
                              context: CreditWalletContext) async throws -> CreditPurchaseReceipt
}

extension LiveAPIClient: CreditWalletAPI {
    func creditWallet(context: CreditWalletContext, environment: String) async throws -> CreditWalletSnapshot {
        guard ["Production", "Sandbox"].contains(environment) else { throw CloudSyncError.invalidResponse }
        let data = try await CreditWalletRequest.perform("GET", context: context, environment: environment)
        do { return try JSONDecoder().decode(CreditWalletSnapshot.self, from: data).checked(for: context, environment: environment) }
        catch { throw CloudSyncError.invalidResponse }
    }

    func openCreditPurchaseIntents(context: CreditWalletContext) async throws -> CreditOpenIntents {
        let data = try await CreditWalletRequest.perform("GET", action: "purchase-intents", context: context)
        do { return try JSONDecoder().decode(CreditOpenIntents.self, from: data).checked() }
        catch { throw CloudSyncError.invalidResponse }
    }

    func prepareCreditPurchase(productID: String, environment: String,
                               context: CreditWalletContext) async throws -> CreditPurchasePreparation {
        guard RendpropCreditProduct.quantities[productID] != nil,
              ["Production", "Sandbox"].contains(environment) else { throw CloudSyncError.invalidResponse }
        let data = try await CreditWalletRequest.perform("POST", action: "purchase-intent", context: context,
            body: ["expected_org_id": context.servingOrgID.uuidString.lowercased(),
                   "product_id": productID, "environment": environment])
        do { return try JSONDecoder().decode(CreditPurchasePreparation.self, from: data).checked(for: context, product: productID) }
        catch { throw CloudSyncError.invalidResponse }
    }

    func abandonCreditPurchase(intent: CreditPurchaseIntent, context: CreditWalletContext) async throws {
        guard intent.actorID == context.actorID else { throw CloudSyncError.identityChanged }
        let data = try await CreditWalletRequest.perform("POST", action: "purchase-intent/abandon", context: context,
            body: ["intent_id": intent.intentID.uuidString.lowercased(),
                   "expected_org_id": intent.orgID.uuidString.lowercased()])
        let result = try JSONDecoder().decode(CreditAbandonedIntent.self, from: data)
        guard result.intentID == intent.intentID, result.orgID == intent.orgID,
              result.state == "abandoned" else { throw CloudSyncError.invalidResponse }
    }

    func settleCreditPurchase(signedTransaction: String, intentID: UUID?, expectedOrgID: UUID?,
                              context: CreditWalletContext) async throws -> CreditPurchaseReceipt {
        guard !signedTransaction.isEmpty, signedTransaction.utf8.count <= 65_536 else {
            throw CloudSyncError.invalidResponse
        }
        var body: [String: Any] = ["signed_transaction": signedTransaction]
        if let intentID { body["intent_id"] = intentID.uuidString.lowercased() }
        if let expectedOrgID { body["expected_org_id"] = expectedOrgID.uuidString.lowercased() }
        let data = try await CreditWalletRequest.perform("POST", action: "purchase", context: context, body: body)
        do { return try JSONDecoder().decode(CreditPurchaseReceipt.self, from: data) }
        catch { throw CloudSyncError.invalidResponse }
    }
}

/// A bounded owner request. A paid receipt never follows a redirect, and
/// `Idempotency-Key` is stable for the exact signed transaction body.
@MainActor private enum CreditWalletRequest {
    private static let session = URLSession(configuration: .ephemeral,
        delegate: CreditWalletNoRedirect(), delegateQueue: nil)

    static func perform(_ method: String, action: String? = nil, context: CreditWalletContext,
                        environment: String? = nil,
                        body: [String: Any]? = nil) async throws -> Data {
        guard context.isCurrent, var url = Config.apiBaseURL else { throw CloudSyncError.identityChanged }
        url.appendPathComponent("me"); url.appendPathComponent("credits")
        if let action { url.appendPathComponent(action) }
        if method == "GET", action == nil {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "org_id", value: context.servingOrgID.uuidString.lowercased()),
                                       URLQueryItem(name: "environment", value: environment)]
            guard let queryURL = components?.url else { throw APIError.invalidURL }
            url = queryURL
        }
        guard let token = await AuthStore.validAccessToken(), context.isCurrent,
              AuthStore.jwtSubject(token).flatMap(UUID.init(uuidString:)) == context.actorID else {
            throw CloudSyncError.identityChanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(context.servingOrgID.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            guard bytes.count <= 70_000 else { throw CloudSyncError.invalidResponse }
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
        guard data.count <= 262_144 else { throw CloudSyncError.invalidResponse }
        return data
    }
}

private final class CreditWalletNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
