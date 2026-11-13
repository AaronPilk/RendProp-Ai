import Foundation
@main struct AerialLaunchAvailabilityTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            guard ok else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            checks += 1
        }
        check(!LaunchFeatureAvailability.canGenerateAerial, "legacy aerial generator remains unavailable")
        check(LaunchFeatureAvailability.canCreateOpening, "scoped Aerial intro opening is available")
        let home = HomeFixture(), listing = Listing(id: UUID())
        home.direct(listing, .aerial)
        if case .aerial(let selected) = home.gate { check(selected.id == listing.id, "direct opening route keeps its exact listing") }
        else { check(false, "direct opening route keeps its exact listing") }
        check(home.route == nil && !home.showRoute, "direct opening stays in its scoped sheet")
        home.gate = nil
        for count in [0, 1, 2] {
            let home = HomeFixture()
            home.projects = (0..<count).map { _ in Listing(id: UUID()) }
            home.launch(.aerial)
            if count == 0 {
                if case .start(.aerial) = home.gate {} else { check(false, "Home opening starts a listing when none exists") }
            } else if count == 1 {
                if case .aerial(let selected) = home.gate { check(selected.id == home.projects[0].id, "Home opening keeps the sole selected listing") }
                else { check(false, "Home opening keeps the sole selected listing") }
            } else {
                if case .pick(.aerial) = home.gate {} else { check(false, "Home opening asks which existing listing to use") }
            }
            check(!home.showRoute && home.listingsTrips == 0, "Home opening remains a scoped sheet or listing choice")
        }
        home.projects = [listing]
        home.launch(.reel)
        if case .reel(let selected) = home.gate { check(selected.id == listing.id, "reel still opens exact selected listing") }
        else { check(false, "reel remains available") }
        home.gate = nil; home.launch(.photos)
        check(home.route?.feature == .photos && home.route?.listing.id == listing.id && home.showRoute, "Photos navigation remains unchanged")
        let aerial = AerialFixture(); aerial.tap()
        check(aerial.sessionCalls == 0 && aerial.postBoundaryCalls == 0 && aerial.phase == .form, "legacy aerial tap cannot ask for session or reach dispatch")
        for cap in [2, 4, 8, 2_147_483_647] {
            for shots in [30, 60, 150] {
                let allowance = PlanAllowances(credits: 100, renders: 4, photoEdits: 100, reels: shots, aerials: cap, topaz: 0, seats: 1)
                check(allowance.aerials == cap, "internal future and saved-result entitlement is retained")
                check(!allowance.benefitLines.contains { $0.lowercased().contains("aerial") }, "paid plan benefits cannot include aerial generation")
                check(allowance.benefitLines.first == "AI photo editing with your plan after the trial", "paid benefits describe available photo editing without a dormant credit grant")
                check(!allowance.benefitLines.contains { $0.contains("\(shots) AI video shots") }, "anti-abuse shot cap is not marketed as a separate allowance")
            }
        }
        print("PASS: \(checks) actual scoped opening and disabled legacy Aerial assertions; no UI/network/Apple")
    }
}
