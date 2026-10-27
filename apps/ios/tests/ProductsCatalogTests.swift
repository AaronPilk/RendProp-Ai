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
        precondition(RendpropPlan.allCases.map(\.allowances.credits) == [60, 120, 250, 600])
        for plan in RendpropPlan.allCases {
            precondition(plan.benefits.first == "AI photo editing with your plan after the trial")
            precondition(plan.benefits.allSatisfy { !$0.localizedCaseInsensitiveContains("credit") })
        }
        precondition(RendpropPlan.team.allowances.customerBenefitLines(seats: 9).last ==
                     "9 seats in one workspace")
        precondition(RendpropPlan.team.allowances.seats == 3)
        precondition(RendpropProducts.notSoldAtLaunch.count == 9)
        precondition(TeamSeatVariant.all.map(\.seats) == [4, 5, 6, 7, 8, 9])
        precondition(TeamSeatVariant.all.map(\.monthlyCredits) == [700, 800, 900, 1000, 1100, 1200])
        for variant in TeamSeatVariant.all {
            precondition(RendpropProducts.plan(for: variant.productID) == .team)
            precondition(RendpropProducts.period(for: variant.productID) == .monthly)
            precondition(RendpropProducts.notSoldAtLaunch.contains(variant.productID))
            precondition(!RendpropProducts.all.contains(variant.productID))
        }
        precondition(RendpropProducts.plan(for: "com.rendprop.app.team10.monthly") == nil)
        precondition(!RendpropProducts.sellsAnnual)
        print("PASS: four sellable tiers, legacy renewal/restore mappings, internal credit targets and honest retail benefits")
    }
}
