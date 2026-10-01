import Foundation

struct SubscriptionBillingContext: Codable, Equatable, Sendable {
    let orgID: UUID
    let orgName: String?
    let role: String
    let canManageSubscription: Bool
    let source: String?
    var originalTransactionIDs: [String]? = nil
    enum CodingKeys: String, CodingKey {
        case orgID = "org_id", orgName = "org_name", role
        case canManageSubscription = "can_manage_subscription", source
        case originalTransactionIDs = "original_transaction_ids"
    }
    var name: String { orgName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Your workspace" }
    var unavailableMessage: String {
        if role != "owner" && role != "admin" { return "Your workspace owner or admin manages this plan. You can still manage your own Apple subscriptions below." }
        return "This workspace’s plan is managed separately. Contact your workspace administrator before buying another subscription. Your existing Apple subscriptions can be managed below."
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

/// Non-secret intent written BEFORE Apple's purchase sheet. StoreKit can
/// redeliver after a restart, so an active-workspace change must not retarget it.
enum PurchaseWorkspaceBindingStore {
    struct Binding: Codable, Equatable {
        let owner: UUID
        let productID: String
        let orgID: UUID
    }
    enum Failure: Error { case unreadable, conflict, storage }
    static func key(owner: UUID, productID: String) -> String {
        "purchase-workspace.v1.\(owner.uuidString.lowercased()).\(productID)"
    }
    static func load(owner: UUID, productID: String, defaults: UserDefaults = .standard) throws -> Binding? {
        guard let data = defaults.data(forKey: key(owner: owner, productID: productID)) else { return nil }
        guard data.count < 4096, let value = try? JSONDecoder().decode(Binding.self, from: data),
              value.owner == owner, value.productID == productID else { throw Failure.unreadable }
        return value
    }
    static func resolve(tokenOwner: UUID?, currentOwner: UUID?, productID: String, defaults: UserDefaults = .standard) throws -> Binding? {
        let original = try tokenOwner.flatMap { try load(owner: $0, productID: productID, defaults: defaults) }
        let current = try currentOwner.flatMap { try load(owner: $0, productID: productID, defaults: defaults) }
        if let original, let current, original.orgID != current.orgID { throw Failure.conflict }
        return original ?? current
    }
    @discardableResult static func prepare(owner: UUID, productID: String, orgID: UUID,
                                          defaults: UserDefaults = .standard) throws -> Bool {
        if let prior = try load(owner: owner, productID: productID, defaults: defaults) {
            guard prior.orgID == orgID else { throw Failure.conflict }
            return false
        }
        let binding = Binding(owner: owner, productID: productID, orgID: orgID)
        defaults.set(try JSONEncoder().encode(binding), forKey: key(owner: owner, productID: productID))
        guard defaults.synchronize(), try load(owner: owner, productID: productID, defaults: defaults) == binding else {
            throw Failure.storage
        }
        return true
    }
    static func discardUnpurchased(owner: UUID, productID: String, orgID: UUID, defaults: UserDefaults = .standard) {
        guard (try? load(owner: owner, productID: productID, defaults: defaults))?.orgID == orgID else { return }
        defaults.removeObject(forKey: key(owner: owner, productID: productID))
    }
}
