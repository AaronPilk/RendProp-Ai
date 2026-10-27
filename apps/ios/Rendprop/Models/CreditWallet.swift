import Foundation

/// Retail credits are a customer entitlement. Internal supplier-cost holds are
/// deliberately not represented here or converted into a displayed dollar cost.
enum RendpropCreditProduct {
    static let hundred = "com.rendprop.app.credits.100"
    static let quantities: [String: Int] = [hundred: 100]
}

struct CreditWalletContext: Hashable, Sendable {
    let actorID: UUID
    let sessionRevision: UInt64
    let selectedOrgID: UUID
    let servingOrgID: UUID

    @MainActor static func capture() throws -> Self {
        guard AuthStore.shared.isSignedIn,
              let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)),
              let selected = WorkspaceContext.selectedOrgID,
              let serving = WorkspaceContext.servingOrgID else {
            throw CloudSyncError.identityChanged
        }
        return Self(actorID: actor, sessionRevision: AuthStore.shared.syncSessionRevision,
                    selectedOrgID: selected, servingOrgID: serving)
    }

    @MainActor var isCurrent: Bool {
        AuthStore.shared.isSignedIn &&
        AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == actorID &&
        AuthStore.shared.syncSessionRevision == sessionRevision &&
        WorkspaceContext.selectedOrgID == selectedOrgID &&
        WorkspaceContext.servingOrgID == servingOrgID
    }
}

struct CreditWalletSnapshot: Decodable, Equatable {
    enum FundingMode: String, Decodable {
        case creditPrimary = "credit_primary"
        case topupOnly = "topup_only"
        case included
    }
    struct Quote: Decodable, Equatable {
        let operation: String
        let credits: Int
        let tariffVersion: String
        enum CodingKeys: String, CodingKey {
            case operation, credits, tariffVersion = "tariff_version"
        }
    }
    struct Balance: Decodable, Equatable {
        let monthlyAvailable: Int
        let topupAvailable: Int
        let totalAvailable: Int
        let held: Int
        enum CodingKeys: String, CodingKey {
            case monthlyAvailable = "monthly_available", topupAvailable = "topup_available"
            case totalAvailable = "total_available", held
        }
    }
    struct Product: Decodable, Equatable, Identifiable {
        let productID: String
        let credits: Int
        var id: String { productID }
        enum CodingKeys: String, CodingKey { case productID = "product_id", credits }
    }
    let orgID: UUID
    let environment: String
    let fundingMode: FundingMode
    let canPurchase: Bool
    let balance: Balance
    let products: [Product]
    let quotes: [Quote]
    enum CodingKeys: String, CodingKey {
        case orgID = "org_id", environment, fundingMode = "funding_mode",
             canPurchase = "can_purchase", balance, products, quotes
    }

    var declutterQuote: Quote? { quotes.first { $0.operation == "photo.declutter" } }
    var stageQuote: Quote? { quotes.first { $0.operation == "photo.stage" } }

    func checked(for context: CreditWalletContext, environment expectedEnvironment: String) throws -> Self {
        guard orgID == context.servingOrgID, environment == expectedEnvironment,
              balance.monthlyAvailable >= 0, balance.topupAvailable >= 0,
              balance.totalAvailable == balance.monthlyAvailable + balance.topupAvailable,
              balance.held >= 0,
              products.allSatisfy({ RendpropCreditProduct.quantities[$0.productID] == $0.credits }),
              Set(products.map(\.productID)).count == products.count,
              quotes.count <= 10,
              quotes.allSatisfy({ $0.credits > 0 && $0.credits <= 1_000 &&
                  (($0.operation == "photo.declutter" && $0.tariffVersion == "photo-declutter-v1") ||
                   ($0.operation == "photo.stage" && $0.tariffVersion == "photo-stage-v1")) }),
              Set(quotes.map(\.operation)).count == quotes.count,
              fundingMode == .included || declutterQuote != nil else {
            throw CloudSyncError.invalidResponse
        }
        return self
    }
}

struct StageCreditAuthorization: Hashable, Sendable {
    let tariffVersion: String
    let environment: String
    init(quote: CreditWalletSnapshot.Quote, environment: String) throws {
        guard quote.operation == "photo.stage", quote.tariffVersion == "photo-stage-v1",
              quote.credits > 0, ["Production", "Sandbox"].contains(environment) else {
            throw CloudSyncError.invalidResponse
        }
        tariffVersion = quote.tariffVersion
        self.environment = environment
    }
}

struct DeclutterCreditAuthorization: Hashable, Sendable {
    let tariffVersion: String
    let environment: String
    init(quote: CreditWalletSnapshot.Quote, environment: String) throws {
        guard quote.operation == "photo.declutter", quote.tariffVersion == "photo-declutter-v1",
              quote.credits > 0, ["Production", "Sandbox"].contains(environment) else {
            throw CloudSyncError.invalidResponse
        }
        tariffVersion = quote.tariffVersion
        self.environment = environment
    }
}

struct CreditPurchasePreparation: Decodable {
    let intentID: UUID
    let orgID: UUID
    let productID: String
    let appAccountToken: UUID
    // Pending Ask-to-Buy can complete much later. The server keeps the
    // original workspace pin without assigning a client-side expiry.
    let expiresAt: String?
    let replay: Bool?
    enum CodingKeys: String, CodingKey {
        case intentID = "intent_id", orgID = "org_id", productID = "product_id"
        case appAccountToken = "app_account_token", expiresAt = "expires_at", replay
    }
    func checked(for context: CreditWalletContext, product: String) throws -> Self {
        guard orgID == context.servingOrgID, productID == product,
              appAccountToken != context.actorID,
              expiresAt == nil || CreditWalletTimestamp.parse(expiresAt!) != nil else {
            throw CloudSyncError.invalidResponse
        }
        return self
    }
}

struct CreditOpenIntents: Decodable {
    struct Item: Decodable {
        let intentID: UUID
        let orgID: UUID
        let productID: String
        let appAccountToken: UUID
        let state: String
        enum CodingKeys: String, CodingKey {
            case intentID = "intent_id", orgID = "org_id", productID = "product_id"
            case appAccountToken = "app_account_token", state
        }
    }
    let intents: [Item]
    func checked() throws -> Self {
        guard intents.count <= 20,
              intents.allSatisfy({ $0.state == "open" &&
                  RendpropCreditProduct.quantities[$0.productID] != nil }),
              Set(intents.map(\.appAccountToken)).count == intents.count else {
            throw CloudSyncError.invalidResponse
        }
        return self
    }
}

struct CreditAbandonedIntent: Decodable {
    let intentID: UUID
    let orgID: UUID
    let state: String
    enum CodingKeys: String, CodingKey {
        case intentID = "intent_id", orgID = "org_id", state
    }
}

struct CreditPurchaseReceipt: Decodable {
    let transactionID: String
    let orgID: UUID
    let environment: String
    let creditsGranted: Int
    let refunded: Bool?
    let balance: CreditWalletSnapshot.Balance
    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id", orgID = "org_id", environment
        case creditsGranted = "credits_granted", refunded, balance
    }
    func checked(transactionID expected: UInt64, productID: String, boundOrgID: UUID?) throws -> Self {
        guard transactionID == String(expected),
              boundOrgID.map({ orgID == $0 }) ?? true,
              ["Production", "Sandbox"].contains(environment),
              (creditsGranted == RendpropCreditProduct.quantities[productID] && refunded != true) ||
                  (creditsGranted == 0 && refunded == true),
              balance.monthlyAvailable >= 0, balance.topupAvailable >= 0,
              balance.totalAvailable == balance.monthlyAvailable + balance.topupAvailable,
              balance.held >= 0 else { throw CloudSyncError.invalidResponse }
        return self
    }
}

enum CreditWalletTimestamp {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

/// A purchase is pinned to the original actor and billing workspace before
/// StoreKit opens. Apple may complete it after the person navigates away.
struct CreditPurchaseIntent: Codable, Equatable {
    let intentID: UUID
    let actorID: UUID
    let orgID: UUID
    let productID: String
    let appAccountToken: UUID
    let createdAt: Date
    var transactionID: String?
    var signedTransaction: String?
    /// Only a definite Apple no-charge result can set this. If the network
    /// fails while releasing its server intent, recovery retries that release.
    var knownNoCharge: Bool? = nil

    func matches(_ context: CreditWalletContext) -> Bool {
        actorID == context.actorID && orgID == context.servingOrgID &&
        RendpropCreditProduct.quantities[productID] != nil
    }
}

enum CreditPurchaseIntentStore {
    static func file(for actor: UUID) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("RendpropCreditPurchases", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(actor.uuidString.lowercased() + ".json")
    }
    static func load(actor: UUID) throws -> CreditPurchaseIntent? {
        let url = try file(for: actor)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 && size <= 131_072 else { throw CloudSyncError.invalidResponse }
        let result = try JSONDecoder().decode(CreditPurchaseIntent.self, from: Data(contentsOf: url))
        guard result.actorID == actor,
              RendpropCreditProduct.quantities[result.productID] != nil,
              result.appAccountToken != actor else {
            throw CloudSyncError.invalidResponse
        }
        return result
    }
    static func save(_ intent: CreditPurchaseIntent) throws {
        guard RendpropCreditProduct.quantities[intent.productID] != nil,
              intent.appAccountToken != intent.actorID,
              (intent.signedTransaction?.utf8.count ?? 0) <= 98_304 else {
            throw CloudSyncError.invalidResponse
        }
        if let old = try load(actor: intent.actorID) {
            guard old.intentID == intent.intentID, old.actorID == intent.actorID,
                  old.orgID == intent.orgID, old.productID == intent.productID,
                  old.appAccountToken == intent.appAccountToken,
                  (old.transactionID == nil || old.transactionID == intent.transactionID),
                  old.knownNoCharge != true || intent.knownNoCharge == true else {
                throw CloudSyncError.invalidResponse
            }
        }
        let bytes = try JSONEncoder().encode(intent)
        guard bytes.count <= 131_072 else { throw CloudSyncError.invalidResponse }
        let url = try file(for: intent.actorID)
        try bytes.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        guard try Data(contentsOf: url) == bytes else { throw CloudSyncError.invalidResponse }
    }
    static func clear(_ intent: CreditPurchaseIntent) throws {
        guard try load(actor: intent.actorID)?.intentID == intent.intentID else {
            throw CloudSyncError.invalidResponse
        }
        try FileManager.default.removeItem(at: file(for: intent.actorID))
    }
}
