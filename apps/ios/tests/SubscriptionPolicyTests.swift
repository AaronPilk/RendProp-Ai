import Foundation

@main enum SubscriptionPolicyTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            checks += 1
            guard condition else { throw NSError(domain: name, code: 1) }
        }
        for eligible in [false, true] {
            for free in [false, true] {
                for count in [0, 1, 2] {
                    for unit in [SubscriptionOfferPolicy.PeriodUnit.day, .week, .month, .year, .unknown] {
                        for value in [0, 1, 3, 7, 14] {
                            let expected = eligible && free && count == 1 && ((unit == .day && value == 7) || (unit == .week && value == 1))
                            try check(SubscriptionOfferPolicy.isSevenDayFreeTrial(eligible: eligible, free: free, value: value, unit: unit, count: count) == expected,
                                      "Only an eligible exact seven-day free offer may be advertised")
                        }
                    }
                }
            }
        }
        let disclosure = SubscriptionOfferPolicy.disclosure(sevenDayTrial: true, price: "€99,99", period: "/month")
        try check(disclosure.contains("Confirm your subscription with Apple") && disclosure.contains("€99,99/month") && disclosure.contains("24 hours"), "Trial confirmation, localized recurring charge and cancellation are explicit")
        try check(!SubscriptionOfferPolicy.disclosure(sevenDayTrial: false, price: "£49.00", period: "/year").contains("7 days"), "Ineligible customers receive no invented trial")

        let suite = "RendpropBillingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID(), org = UUID(), otherOrg = UUID(), product = "com.rendprop.app.pro.monthly"
        try check(try PurchaseWorkspaceBindingStore.prepare(owner: owner, productID: product, orgID: org, defaults: defaults), "Intent is durably written before purchase")
        let reopened = UserDefaults(suiteName: suite)!
        try check(try PurchaseWorkspaceBindingStore.load(owner: owner, productID: product, defaults: reopened)?.orgID == org, "Relaunch retains the selected billing workspace")
        try check(!(try PurchaseWorkspaceBindingStore.prepare(owner: owner, productID: product, orgID: org, defaults: defaults)), "Same workspace retry preserves intent")
        do {
            _ = try PurchaseWorkspaceBindingStore.prepare(owner: owner, productID: product, orgID: otherOrg, defaults: defaults)
            throw NSError(domain: "Cross-workspace purchase intent was overwritten", code: 1)
        } catch PurchaseWorkspaceBindingStore.Failure.conflict { checks += 1 }
        try check(try PurchaseWorkspaceBindingStore.load(owner: UUID(), productID: product, defaults: defaults) == nil, "Another app account cannot inherit the purchase binding")
        PurchaseWorkspaceBindingStore.discardUnpurchased(owner: owner, productID: product, orgID: otherOrg, defaults: defaults)
        try check(try PurchaseWorkspaceBindingStore.load(owner: owner, productID: product, defaults: defaults)?.orgID == org, "Wrong-workspace cancellation cannot erase the original intent")
        PurchaseWorkspaceBindingStore.discardUnpurchased(owner: owner, productID: product, orgID: org, defaults: defaults)
        try check(try PurchaseWorkspaceBindingStore.load(owner: owner, productID: product, defaults: defaults) == nil, "Cancelled unpurchased intent can be removed")
        defaults.set(Data("corrupt".utf8), forKey: PurchaseWorkspaceBindingStore.key(owner: owner, productID: product))
        do {
            _ = try PurchaseWorkspaceBindingStore.load(owner: owner, productID: product, defaults: defaults)
            throw NSError(domain: "Corrupt binding treated as missing", code: 1)
        } catch PurchaseWorkspaceBindingStore.Failure.unreadable { checks += 1 }
        let guest = UUID(), named = UUID(), nextProduct = "com.rendprop.app.team.monthly"
        _ = try PurchaseWorkspaceBindingStore.prepare(owner: named, productID: nextProduct, orgID: org, defaults: defaults)
        try check(try PurchaseWorkspaceBindingStore.resolve(tokenOwner: guest, currentOwner: named, productID: nextProduct, defaults: defaults)?.orgID == org, "Adopted subscription plan change recovers named-account intent under original guest appAccountToken")
        _ = try PurchaseWorkspaceBindingStore.prepare(owner: guest, productID: nextProduct, orgID: otherOrg, defaults: defaults)
        do {
            _ = try PurchaseWorkspaceBindingStore.resolve(tokenOwner: guest, currentOwner: named, productID: nextProduct, defaults: defaults)
            throw NSError(domain: "Conflicting adopted purchase bindings were ignored", code: 1)
        } catch PurchaseWorkspaceBindingStore.Failure.conflict { checks += 1 }
        print("PASS: \(checks) trial-offer, disclosure and durable purchase-workspace checks")
    }
}
