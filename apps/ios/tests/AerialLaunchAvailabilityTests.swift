import Foundation
@main struct AerialLaunchAvailabilityTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            guard ok else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            checks += 1
        }
        check(!LaunchFeatureAvailability.canGenerateAerial, "aerial is unavailable in shipping policy")
        for count in [0, 1, 2] {
            let home = HomeFixture()
            home.projects = (0..<count).map { _ in Listing(id: UUID()) }
            home.launch(.aerial)
            check(home.gate == nil && !home.showRoute && home.listingsTrips == 0, "Home aerial cannot open a picker or create a project")
        }
        let home = HomeFixture(), listing = Listing(id: UUID())
        home.direct(listing, .aerial)
        check(home.gate == nil && home.route == nil && !home.showRoute, "stale Home route cannot open aerial sheet")
        home.projects = [listing]
        home.launch(.reel)
        if case .reel(let selected) = home.gate { check(selected.id == listing.id, "reel still opens exact selected listing") }
        else { check(false, "reel remains available") }
        home.gate = nil; home.launch(.photos)
        check(home.route?.feature == .photos && home.route?.listing.id == listing.id && home.showRoute, "Photos navigation remains unchanged")
        let aerial = AerialFixture(); aerial.tap()
        check(aerial.sessionCalls == 0 && aerial.postBoundaryCalls == 0 && aerial.phase == .form, "new aerial tap cannot ask for session or reach dispatch")
        for cap in [2, 4, 8, 2_147_483_647] {
            let allowance = PlanAllowances(renders: 4, photoEdits: 100, reels: 6, aerials: cap, topaz: 0, seats: 1)
            check(allowance.aerials == cap, "internal future and saved-result entitlement is retained")
            check(!allowance.benefitLines.contains { $0.lowercased().contains("aerial") }, "paid plan benefits cannot include aerial generation")
            check(allowance.benefitLines.contains("6 reel clips"), "other paid benefits remain available")
        }
        print("PASS: \(checks) actual shipping Aerial availability assertions; no UI/network/Apple")
    }
}
