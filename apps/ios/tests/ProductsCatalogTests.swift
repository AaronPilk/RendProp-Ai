import Foundation

// Products.swift's only app dependency; this fixture compiles the actual
// catalog without StoreKit, a simulator, or an App Store account.
enum SpaceType: Equatable {
    case realEstate, venue
    static let current: SpaceType = .realEstate
    var businessNoun: String { "venue" }
}

@main struct ProductsCatalogTests {
    static func main() {
        precondition(RendpropPlan.allCases.map(\.rawValue) == ["pro", "max", "ultra", "team"])
        precondition(RendpropProducts.all == [
            "com.rendprop.app.pro29.monthly",
            "com.rendprop.app.starter.monthly",
            "com.rendprop.app.pro.monthly",
            "com.rendprop.app.team.monthly",
        ])
        let legacy: [(String, RendpropPlan)] = [
            ("com.rendprop.app.starter.monthly", .max),
            ("com.rendprop.app.starter.annual", .max),
            ("com.rendprop.app.pro.monthly", .ultra),
            ("com.rendprop.app.pro.annual", .ultra),
            ("com.rendprop.app.team.monthly", .team),
            ("com.rendprop.app.team.annual", .team),
        ]
        for (product, plan) in legacy {
            precondition(RendpropProducts.plan(for: product) == plan)
        }
        precondition(RendpropProducts.plan(for: "com.rendprop.app.pro29.monthly") == .pro)
        precondition(RendpropProducts.plan(for: "com.rendprop.app.pro29.annual") == nil)
        precondition(RendpropProducts.plan(for: "com.rendprop.app.unissued.monthly") == nil)
        precondition(RendpropProducts.plan(fromPlanName: "starter") == .max)
        precondition(RendpropProducts.plan(fromPlanName: "solo") == .max)
        precondition(RendpropProducts.plan(fromPlanName: "legacy_pro") == .ultra)
        precondition(RendpropPlan.allCases.map(\.allowances.credits) == [80, 200, 440, 1000])
        for plan in RendpropPlan.allCases {
            precondition(plan.benefits.first == "\(plan.allowances.credits) monthly Declutter credits after the trial")
        }
        precondition(RendpropPlan.team.allowances.seats == 3)
        precondition(RendpropProducts.notSoldAtLaunch.count == 3)
        precondition(!RendpropProducts.sellsAnnual)
        print("PASS: four sellable tiers, legacy renewal/restore mappings, credits and three Team seats")
    }
}
