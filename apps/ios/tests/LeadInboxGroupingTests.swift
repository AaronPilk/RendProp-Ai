import Foundation

@main struct LeadInboxGroupingTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !value() { fatalError("FAILED: \(name)") }
        }
        UserDefaults.standard.set(SpaceType.realEstate.rawValue, forKey: "space.type")
        let tabs = RootTabFixture()
        let rendered = tabs.tabs as! TabView
        expect(rendered.entries.map(\.label) == ["Home", "Listings", "Activity", "Leads", "Account"], "five tabs in intended order")
        expect(rendered.entries.map(\.tag) == [0, 1, 5, 4, 6], "visible activity, leads and account routes retain stable tags")
        rendered.entries[0].action?()
        expect(tabs.tab == 1, "Home listing action retains listing tag")
        expect(NativeRootTab.destination(for: .planUsage)?.rawValue == 3, "stable tags preserve existing profile and settings routes")
        var account = NativeAccountNavigation()
        expect(account.open(.settings) && account.presentsSettings, "legacy settings route opens the Account settings destination")
        account.close(.settings)
        expect(!account.presentsSettings, "closing Account settings clears its route")
        expect(account.open(.profile) && account.presentsProfile, "legacy profile route opens the Account profile destination")
        expect(NativeRootTab.destination(for: .home)?.rawValue == 0, "coach home route remains home")
        expect(NativeRootTab.destination(for: .startProject)?.rawValue == 0, "coach start route remains home")
        expect(NativeRootTab.destination(for: .project(listingID: UUID(), feature: .spatial))?.rawValue == 0, "coach project route stays on Home resolver")
        expect(NativeRootTab.destination(for: .listingDetails(listingID: UUID()))?.rawValue == 0, "photo-only Share route uses Home listing resolver")
        expect(NativeRootTab.destination(for: .support) == nil, "support does not select a different tab")
        UserDefaults.standard.set(SpaceType.venue.rawValue, forKey: "space.type")
        expect((RootTabFixture().tabs as! TabView).entries[1].label == "Venues", "listing tab retains industry noun")

        let owner = UUID(), otherOwner = UUID(), org = UUID(), otherOrg = UUID()
        let a = UUID(), b = UUID(), hidden = UUID(), unknown = UUID()
        func listing(_ id: UUID, _ title: String, ownerID: UUID = owner, orgID: UUID = org, sample: Bool = false) -> Listing {
            var value = Listing(address: title, beds: 0, baths: 0, sqft: 0, price: Money(cents: 0))
            value.serverID = id; value.cloudSyncOwnerID = ownerID; value.serverOrgID = orgID; value.isSample = sample
            return value
        }
        let catalog = [listing(a, "10 First Street"), listing(b, "20 Second Street"),
                       listing(hidden, "PRIVATE OTHER LIBRARY", ownerID: otherOwner),
                       listing(UUID(), "PRIVATE OTHER ORG", orgID: otherOrg), listing(UUID(), "Sample", sample: true)]
        let visible = LeadInboxGrouping.visibleListings(catalog) { $0.cloudSyncOwnerID == owner && $0.serverOrgID == org }
        expect(visible.count == 2, "sample and foreign context labels stay unavailable")
        let now = Date(timeIntervalSince1970: 1_000)
        let delivery = ClientLeadDelivery(state: "email_sent", recipientEmail: "client@example.invalid", clientName: "Client",
                                          lastAttemptAt: nil, sentAt: "2026-10-14T10:00:00Z", canResend: true, reason: nil)
        let rows = [Lead(id: UUID(), listingID: a, name: "Earlier", createdAt: now, listingAddress: "Recorded First"),
                    Lead(id: UUID(), listingID: a, name: "Latest", email: "buyer@example.invalid", createdAt: now.addingTimeInterval(3), clientDelivery: delivery),
                    Lead(id: UUID(), listingID: b, name: "Other property", createdAt: now.addingTimeInterval(2)),
                    Lead(id: UUID(), listingID: unknown, name: "Unknown local listing", createdAt: now.addingTimeInterval(1), listingAddress: "30 Recorded Street"),
                    Lead(id: UUID(), listingID: hidden, name: "Server scoped record", createdAt: now, listingAddress: "Recorded address"),
                    Lead(id: UUID(), name: "No listing", createdAt: now)]
        let groups = LeadInboxGrouping.sections(rows, listings: visible)
        expect(groups.count == 5 && groups[0].listingID == a, "multiple listings group by exact server identity and latest inquiry")
        expect(groups[0].title == "10 First Street", "visible exact listing supplies property label")
        expect(groups[0].leads.map(\.name) == ["Latest", "Earlier"], "newest inquiries lead each property group")
        expect(groups[0].leads[0].clientDelivery == delivery && groups[0].leads[0].email == "buyer@example.invalid", "grouping preserves reply and delivery state")
        expect(groups.first { $0.listingID == hidden }?.title == "Recorded address", "unknown local listing never borrows a foreign private address")
        expect(groups.first { $0.listingID == unknown }?.title == "30 Recorded Street", "unknown listing retains server supplied address")
        expect(groups.first { $0.listingID == nil }?.title == "Other inquiries", "unassigned inquiry has explicit group")
        expect(rows.filter { LeadInboxFilter.listing(a).includes($0) }.count == 2, "listing filter cannot mix another property inquiry")
        expect(rows.filter { LeadInboxFilter.unassigned.includes($0) }.count == 1, "unassigned filter is distinct from all listings")
        expect(rows.filter { LeadInboxFilter.all.includes($0) } == rows, "all filter retains scoped server records")
        expect(LeadInboxGrouping.sections([], listings: visible).isEmpty, "empty inbox has no fabricated inquiry")
        let emptyOptions = LeadInboxGrouping.sections([], listings: visible, includeEmpty: true)
        expect(emptyOptions.count == 2 && emptyOptions.allSatisfy { $0.leads.isEmpty }, "own listings without inquiries remain filter choices")
        let missing = Lead(id: UUID(), listingID: UUID(), name: "Unknown", createdAt: now)
        expect(LeadInboxGrouping.sections([missing], listings: visible)[0].title == "Listing unavailable", "missing property label stays honest")

        let current = DeletionContext(owner: owner.uuidString, revision: 7, org: org)
        expect(LeadInboxGrouping.current(rows, responseContext: current, currentContext: current) == rows, "current response can populate inbox")
        expect(LeadInboxGrouping.current(rows, responseContext: Optional<DeletionContext>.none, currentContext: current).isEmpty, "unbound response stays hidden")
        expect(LeadInboxGrouping.current(rows, responseContext: current, currentContext: DeletionContext(owner: otherOwner.uuidString, revision: 7, org: org)).isEmpty, "account change hides prior inquiries")
        expect(LeadInboxGrouping.current(rows, responseContext: current, currentContext: DeletionContext(owner: owner.uuidString, revision: 8, org: org)).isEmpty, "same account reauthentication hides stale response")
        expect(LeadInboxGrouping.current(rows, responseContext: current, currentContext: DeletionContext(owner: owner.uuidString, revision: 7, org: otherOrg)).isEmpty, "workspace change hides prior inquiries")
        print("Lead inbox grouping, scoped response and tab routing: \(checks) checks passed")
    }
}
