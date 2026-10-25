import Foundation

enum WebsiteDesign: String, Codable, CaseIterable, Identifiable, Sendable {
    case basic
    case signatureEstate = "signature-estate"
    case coastalLuxe = "coastal-luxe"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .basic: return "Classic"
        case .signatureEstate: return "Signature Estate"
        case .coastalLuxe: return "Coastal Luxe"
        }
    }
    var summary: String {
        switch self {
        case .basic: return "Your included property website, with video, gallery, location and contact pages."
        case .signatureEstate: return "An editorial design with cream, charcoal and bronze."
        case .coastalLuxe: return "A spacious design with warm white and deep teal."
        }
    }
    var isPremium: Bool { self != .basic }

    func previewURL(canonical: URL, address: String? = nil) -> URL? {
        guard let buyer = DeepLink.buyerWebsiteURL(from: canonical, address: address),
              var components = URLComponents(url: buyer, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "preview_theme", value: rawValue)]
        components.fragment = nil
        return components.url
    }
}

enum WebsiteUpgradeProduct {
    static let id = "com.rendprop.app.website.premium.property"
}

/// Capture before a request or StoreKit sheet. Never move a paid credit to the
/// newly visible account, library or property when an asynchronous call returns.
struct WebsiteDesignContext: Codable, Hashable, Sendable {
    let actorID: UUID
    let sessionRevision: UInt64
    let orgID: UUID
    let listingID: UUID

    @MainActor static func capture(listingID: UUID) throws -> Self {
        guard AuthStore.shared.isSignedIn,
              let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)),
              let org = WorkspaceContext.selectedOrgID else { throw CloudSyncError.identityChanged }
        return .init(actorID: actor, sessionRevision: AuthStore.shared.syncSessionRevision,
                     orgID: org, listingID: listingID)
    }
    @MainActor var isCurrent: Bool {
        AuthStore.shared.isSignedIn && AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == actorID &&
        AuthStore.shared.syncSessionRevision == sessionRevision && WorkspaceContext.selectedOrgID == orgID
    }
    func matches(actor: UUID?, revision: UInt64, org: UUID?) -> Bool {
        actor == actorID && revision == sessionRevision && org == orgID
    }
}

struct WebsiteDesignState: Codable, Equatable, Sendable {
    struct Premium: Codable, Equatable, Sendable {
        let unlocked: Bool
        let productID: String
        let testOnly: Bool
        let purchaseEnabled: Bool
        let sandboxPurchaseEnabled: Bool
        enum CodingKeys: String, CodingKey {
            case unlocked, productID = "product_id", testOnly = "test_only", purchaseEnabled = "purchase_enabled"
            case sandboxPurchaseEnabled = "sandbox_purchase_enabled"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unlocked = try c.decode(Bool.self, forKey: .unlocked)
            productID = try c.decode(String.self, forKey: .productID)
            testOnly = try c.decode(Bool.self, forKey: .testOnly)
            purchaseEnabled = try c.decodeIfPresent(Bool.self, forKey: .purchaseEnabled) ?? false
            sandboxPurchaseEnabled = try c.decodeIfPresent(Bool.self, forKey: .sandboxPurchaseEnabled) ?? false
        }
        init(unlocked: Bool, productID: String = WebsiteUpgradeProduct.id, testOnly: Bool = false,
             purchaseEnabled: Bool = false, sandboxPurchaseEnabled: Bool = false) {
            self.unlocked = unlocked; self.productID = productID
            self.testOnly = testOnly; self.purchaseEnabled = purchaseEnabled
            self.sandboxPurchaseEnabled = sandboxPurchaseEnabled
        }
        func canPurchase(environment: String?) -> Bool {
            environment == "Production" ? purchaseEnabled : environment == "Sandbox" ? sandboxPurchaseEnabled : false
        }
    }
    let listingID: UUID
    let orgID: UUID
    let theme: WebsiteDesign
    let premium: Premium
    var assigned: Bool? = nil
    var replay: Bool? = nil
    var revoked: Bool? = nil
    var environment: String? = nil
    var transactionID: String? = nil

    enum CodingKeys: String, CodingKey {
        case listingID = "listing_id", orgID = "org_id", theme = "website_theme", premium = "premium_website"
        case assigned, replay, revoked, environment, transactionID = "transaction_id"
    }

    func checked(for context: WebsiteDesignContext) throws -> Self {
        guard listingID == context.listingID, orgID == context.orgID,
              premium.productID == WebsiteUpgradeProduct.id,
              !theme.isPremium || premium.unlocked else { throw CloudSyncError.invalidResponse }
        if let environment, !["Production", "Sandbox"].contains(environment) { throw CloudSyncError.invalidResponse }
        return self
    }
    func acknowledges(transactionID: String, context: WebsiteDesignContext) throws -> Bool {
        _ = try checked(for: context)
        return self.transactionID == transactionID &&
            ((assigned == true && premium.unlocked) || revoked == true) &&
            ["Production", "Sandbox"].contains(environment ?? "")
    }
}

/// One purchase in flight per account. The property selection is written
/// before StoreKit; signed receipts are never exported with listing media.
struct WebsiteUpgradeIntent: Codable, Equatable, Sendable {
    var schema = 1
    let id: UUID
    let actorID: UUID
    let orgID: UUID
    let listingID: UUID
    let productID: String
    let createdAt: Date
    var transactionID: String? = nil
    var signedTransaction: String? = nil

    init(context: WebsiteDesignContext) {
        id = UUID(); actorID = context.actorID; orgID = context.orgID
        listingID = context.listingID; productID = WebsiteUpgradeProduct.id; createdAt = Date()
    }
    func matches(_ context: WebsiteDesignContext) -> Bool {
        schema == 1 && actorID == context.actorID && orgID == context.orgID && listingID == context.listingID &&
        productID == WebsiteUpgradeProduct.id
    }
}

enum WebsiteUpgradeIntentStore {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let result = base.appendingPathComponent("RendpropWebsitePurchases", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    static func file(actor: UUID) throws -> URL { try directory().appendingPathComponent(actor.uuidString.lowercased() + ".json") }
    static func load(actor: UUID) throws -> WebsiteUpgradeIntent? {
        let url = try file(actor: actor)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, count > 0, count <= 131072 else {
            throw CloudSyncError.invalidResponse
        }
        let result = try JSONDecoder().decode(WebsiteUpgradeIntent.self, from: Data(contentsOf: url))
        guard result.schema == 1, result.actorID == actor, result.productID == WebsiteUpgradeProduct.id else {
            throw CloudSyncError.invalidResponse
        }
        return result
    }
    static func save(_ intent: WebsiteUpgradeIntent) throws {
        guard intent.schema == 1, intent.productID == WebsiteUpgradeProduct.id,
              (intent.signedTransaction?.utf8.count ?? 0) <= 98304 else { throw CloudSyncError.invalidResponse }
        if let existing = try load(actor: intent.actorID) {
            guard existing.id == intent.id, existing.actorID == intent.actorID,
                  existing.orgID == intent.orgID, existing.listingID == intent.listingID,
                  existing.transactionID == nil || existing.transactionID == intent.transactionID else {
                throw CloudSyncError.invalidResponse
            }
        }
        let url = try file(actor: intent.actorID), data = try JSONEncoder().encode(intent)
        guard data.count <= 131072 else { throw CloudSyncError.invalidResponse }
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        guard try Data(contentsOf: url) == data else { throw CloudSyncError.invalidResponse }
    }
    static func clear(_ intent: WebsiteUpgradeIntent) throws {
        guard try load(actor: intent.actorID)?.id == intent.id else { throw CloudSyncError.invalidResponse }
        try FileManager.default.removeItem(at: file(actor: intent.actorID))
    }
}
