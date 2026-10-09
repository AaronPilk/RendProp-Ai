import Foundation

/// Actual /me decoding and Settings/Team consumer bodies, compiled by the runner.
/// Isolated network/presentation interfaces do not perform provider or Apple work.
@main struct WorkspaceAllowanceDisplayTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }
            checks += 1
        }
        let unlimited = 2_147_483_647
        let settings = SettingsPolicyFixture()
        let teamView = TeamPolicyFixture()
        func reply(plan: String = "team", source: String? = "manual", cap: Any = unlimited) throws -> Data {
            var data: [String: Any] = [
                "plan": plan, "plan_raw": plan,
                "entitlement": ["renders_per_month": cap, "photo_edits_per_month": cap,
                    "reels_per_month": cap, "aerials_per_month": cap, "topaz_per_month": cap],
                "usage": ["by_feature": ["renders": 3, "photo_edits": 5, "reels": 2, "aerials": 1, "drone": 0], "leads": 4]
            ]
            if let source { data["plan_source"] = source }
            return try JSONSerialization.data(withJSONObject: data)
        }
        func summary(plan: String? = "team", source: String? = nil, cap: Int = unlimited,
                     used: Int = 2, manager: Bool = true, mode: String? = nil) throws -> TeamSummary {
            var data: [String: Any] = ["org_id": "synthetic-owner-testing", "org_name": "Synthetic testing team",
                "can_manage": manager, "seats": ["used": used, "allowed": cap], "members": [], "invites": []]
            if let plan { data["plan"] = plan }
            if let source { data["plan_source"] = source }
            if let mode { data["access_mode"] = mode }
            return try TeamAPI.fixtureDecode(TeamSummary.self, data: JSONSerialization.data(withJSONObject: data))
        }

        let live = LivePolicyFixture(data: try reply())
        let usage = try await live.me()
        let e = usage.entitlements!
        check(e.planSource == "manual", "actual me forwards authoritative manual source")
        let rows = settings.rows(e)
        check(rows.count == 5, "all five actual Settings usage consumers remain covered")
        for (row, expected) in zip(rows, ["3 used · Unlimited", "5 used · Unlimited", "2 used · Unlimited", "1 used · Unlimited", "0 used · Unlimited"]) {
            check(row.value == expected, "actual Settings testing row shows used count and Unlimited")
        }
        check(rows.map(\.title) == ["Cloud tour renders", "Photo edits", "Reel clips", "Aerial intros", "Video quality upgrades"], "actual Settings row titles are unchanged")
        check(e.remaining("renders") == unlimited - 3 && e.canUseTopaz && e.canUseAerial,
              "display labels do not alter positive numeric native access compatibility")
        check(live.requestCount == 1, "actual me reads one held fixture without a mutation")

        for source in ["apple", "trial", "brokerage", ""] {
            let api = LivePolicyFixture(data: try reply(source: source))
            let finite = try await api.me().entitlements!
            check(finite.planSource == source, "actual me retains every nonmanual source")
            check(settings.rows(finite).allSatisfy { !$0.value.contains("Unlimited") }, "nonmanual source cannot claim testing Unlimited")
        }
        for plan in ["free", "trial", "starter", "pro", "brokerage", ""] {
            let api = LivePolicyFixture(data: try reply(plan: plan))
            let finite = try await api.me().entitlements!
            check(settings.rows(finite).allSatisfy { !$0.value.contains("Unlimited") }, "nonTeam cap cannot claim testing Unlimited")
        }
        for cap in [0, -1, unlimited - 1, unlimited + 1, 1_000_000, 400] {
            let api = LivePolicyFixture(data: try reply(cap: cap))
            let finite = try await api.me().entitlements!
            let ordinary = settings.rows(finite)
            check(ordinary.allSatisfy { !$0.value.contains("Unlimited") }, "only exact marker is testing Unlimited")
            check(ordinary[1].value == (cap > 0 ? "5 of \(cap)" : "Not included"), "ordinary usage labels remain unchanged")
        }
        let legacy = LivePolicyFixture(data: try reply(source: nil, cap: "2147483647"))
        let legacyEntitlement = try await legacy.me().entitlements!
        check(legacyEntitlement.planSource == nil, "old me response can omit source")
        check(settings.rows(legacyEntitlement).allSatisfy { $0.value.contains("Unlimited") }, "legacy exact Team marker stays compatible")

        let testingSeats = try summary()
        check(teamView.row(testingSeats).value == "2 used · Unlimited", "actual Team seat consumer displays Unlimited")
        check(teamView.footer(testingSeats) == "Each agent keeps their own listings, tours and leads. The Team owner can switch between authorized agents’ listings; invited agents see only their own. Unlimited seats are available for testing. You can invite more people.", "actual Team footer does not show sentinel seats remaining")
        check(!testingSeats.seats.isFull && testingSeats.seats.remaining == unlimited - 2, "seat display never changes server numeric full-seat behavior")
        let manualSeats = try summary(source: "manual")
        check(manualSeats.hasUnlimitedTestingSeats, "optional team manual source confirms exact marker")
        for source in ["apple", "trial", "brokerage", ""] {
            let finite = try summary(source: source)
            check(teamView.row(finite).value == "2 of 2147483647", "team nonmanual source stays finite")
            check(!teamView.footer(finite).contains("unlimited"), "team nonmanual footer stays finite")
        }
        for plan: String? in [nil, "free", "starter", "pro", "brokerage"] {
            let finite = try summary(plan: plan)
            check(!finite.hasUnlimitedTestingSeats, "team source requires a Team plan")
            check(teamView.row(finite).value == "2 of 2147483647", "team nonTeam row stays finite")
        }
        for cap in [0, -1, unlimited - 1, unlimited + 1, 2, 100_000] {
            let finite = try summary(cap: cap)
            check(teamView.row(finite).value == "2 of \(cap)", "ordinary seat labels remain unchanged")
            check(!finite.hasUnlimitedTestingSeats, "ordinary high seat cap is not Unlimited")
        }
        let full = try summary(cap: 2)
        check(teamView.footer(full).hasSuffix("Every seat on your plan is taken. A pending invite holds a seat until it's accepted or revoked."), "ordinary full-team capacity footer remains unchanged")
        let oneLeft = try summary(cap: 3)
        check(teamView.footer(oneLeft).hasSuffix("1 seat left. A pending invite holds one until it's accepted or revoked."), "ordinary remaining-seat capacity footer remains unchanged")
        let member = try summary(manager: false)
        check(teamView.row(member).value == "2 used · Unlimited", "agent receives testing seat label too")
        check(teamView.footer(member).hasSuffix("The owner manages who else is on it."), "testing display does not grant agent management authority")

        let privateTeam = try summary(mode: "private_testing")
        check(teamView.access(privateTeam).value == "Private testing accounts", "actual Team access row identifies private testing")
        check(teamView.footer(privateTeam).contains("keeps their own homes, tours and leads private"), "actual private Team footer explains separate content")
        check(!teamView.footer(privateTeam).contains("shared workspace"), "private Team is not presented as shared content")
        check(teamView.row(privateTeam).value == "2 used · Unlimited", "private owner testing seat grant remains unlimited")
        let privateBeneficiary = try summary(cap: 1, used: 1, manager: false, mode: "private_testing")
        check(teamView.row(privateBeneficiary).value == "1 of 1", "private beneficiary retains one private content seat")
        check(teamView.footer(privateBeneficiary).contains("private from other testers") && teamView.footer(privateBeneficiary).contains("Team owner"), "private beneficiary footer does not suggest team content access")
        check(teamView.access(testingSeats).value == "Private agent accounts", "missing legacy mode retains explicit shared workspace label")
        for mode in ["shared", "unknown", "Private_testing", ""] {
            check(teamView.access(try summary(mode: mode)).value == "Private agent accounts", "only exact server private mode changes account-access label")
        }

        func memberRecord(mode: String? = nil, role: String = "agent") throws -> TeamSummary.Member {
            var row: [String: Any] = ["user_id": "synthetic-private-member", "role": role,
                "name": "Synthetic Person", "is_you": false]
            if let mode { row["access_mode"] = mode }
            return try TeamAPI.fixtureDecode(TeamSummary.Member.self, data: JSONSerialization.data(withJSONObject: row))
        }
        let privateMember = try memberRecord(mode: "private_testing")
        check(privateMember.roleLabel == "Private testing account", "sponsored roster badges do not imply shared content membership")
        check(teamView.removal(privateMember) == "Their testing access ends. Their private homes, tours and leads stay in their own account.", "actual private removal message preserves ownership")
        check(try memberRecord(role: "owner").roleLabel == "Owner", "actual master owner retains Owner label")
        let sharedMember = try memberRecord()
        check(sharedMember.roleLabel == "Agent", "ordinary member role remains unchanged")
        check(teamView.removal(sharedMember).contains("private listings") && !teamView.removal(sharedMember).contains("shared workspace"), "actual ordinary removal preserves private content ownership")

        func joinedRecord(mode: String? = nil) throws -> TeamJoined {
            var row: [String: Any] = ["ok": true, "org_id": "owned-private-org", "org_name": "My private workspace", "role": "owner"]
            if let mode { row["access_mode"] = mode; row["team_name"] = "Synthetic Sponsor Team" }
            return try TeamAPI.fixtureDecode(TeamJoined.self, data: JSONSerialization.data(withJSONObject: row))
        }
        let privateJoin = try joinedRecord(mode: "private_testing")
        check(privateJoin.orgId == "owned-private-org", "private join preserves existing actual beneficiary selection contract")
        check(teamView.join(privateJoin).contains("stay private in your own workspace") && !teamView.join(privateJoin).contains("shared workspace"), "actual join confirmation does not promise shared houses")
        check(teamView.join(privateJoin).hasPrefix("Synthetic Sponsor Team provides"), "private join names the verified sponsor without changing private workspace name")
        let sharedJoin = try joinedRecord()
        check(!teamView.join(sharedJoin).contains("shared workspace") && teamView.join(sharedJoin).contains("Only the Team owner"), "actual ordinary join explains owner-only library access")
        check(teamView.join(sharedJoin).contains("keeping your own listings"), "ordinary join retains personal work explanation")

        var sentInvites: [(String?, String)] = []
        let privateInvite = InvitePolicyFixture(privateTesting: true,
            send: { email, role in sentInvites.append((email, role)) }, email: "tester@example.invalid", role: "admin")
        check(!privateInvite.showsRoles, "private invites hide shared-team role selection")
        check(privateInvite.accessRow.value == "Private testing account", "actual private invite access row names private account access")
        check(privateInvite.explanation.contains("own private account") && !privateInvite.explanation.contains("An admin"), "private invite explains separate content without shared authority claims")
        await privateInvite.dispatch()
        check(sentInvites.last?.1 == "agent", "actual private invite dispatch always requests agent allocation")
        check(sentInvites.last?.0 == "tester@example.invalid", "private invite keeps the user's deliberately supplied recipient")
        for role in ["agent", "admin", "marketing"] {
            let sharedInvite = InvitePolicyFixture(privateTesting: false,
                send: { email, chosen in sentInvites.append((email, chosen)) }, email: "", role: role)
            check(sharedInvite.showsRoles, "ordinary shared invites retain role selection")
            check(sharedInvite.explanation.contains("Each agent keeps their own listings") && !sharedInvite.explanation.contains("shared workspace"), "ordinary invite explains shared content access")
            await sharedInvite.dispatch()
            check(sentInvites.last?.1 == role && sentInvites.last?.0 == nil, "actual ordinary invite preserves chosen role and code-only invitation")
        }

        let privateOrg = UUID(uuidString: "bfaf0000-0000-4000-8000-000000000001")!
        let hostOrg = UUID(uuidString: "bfaf0000-0000-4000-8000-000000000002")!
        let privateID = UUID(), hostID = UUID(), draftID = UUID()
        let inventory = InventoryPolicyFixture()
        inventory.listings = [Listing(id: privateID, serverOrgID: privateOrg),
            Listing(id: hostID, serverOrgID: hostOrg, cloudUnavailable: true),
            Listing(id: draftID, cloudDraftOrgID: privateOrg)]
        let savedIDs = inventory.listings.map(\.id)
        Config.useLiveBackend = true; WorkspaceContext.selectedOrgID = privateOrg
        let selectedPrivate = HomePolicyFixture(model: inventory)
        check(selectedPrivate.visibleIDs == [privateID, draftID], "actual Home hides old host inventory after private selection")
        check(!selectedPrivate.needsSelection, "selected private workspace needs no redundant selector prompt")
        check(inventory.listings.map(\.id) == savedIDs && inventory.listings[1].cloudUnavailable, "filtering leaves cached rows and recovery state intact")
        let legacyID = UUID()
        inventory.listings = [Listing(id: legacyID, serverOrgID: hostOrg, serverLibraryOrgID: privateOrg)]
        check(HomePolicyFixture(model: inventory).visibleIDs == [legacyID], "own legacy Team row hidden by physical storage org")
        inventory.listings[0].cloudUnavailable = true
        check(HomePolicyFixture(model: inventory).visibleIDs.isEmpty, "revoked cached library alias exposed old Team row")
        inventory.listings[0].cloudUnavailable = false
        WorkspaceStore.hasAuthority = false
        check(HomePolicyFixture(model: inventory).visibleIDs.isEmpty, "revoked directory delegation exposed cached cards")
        WorkspaceStore.hasAuthority = true
        inventory.listings = [Listing(id: privateID, serverOrgID: privateOrg), Listing(id: hostID, serverOrgID: hostOrg, cloudUnavailable: true), Listing(id: draftID, cloudDraftOrgID: privateOrg)]
        WorkspaceContext.selectedOrgID = nil
        let noSelection = HomePolicyFixture(model: inventory)
        check(noSelection.visibleIDs.isEmpty, "nil live workspace cannot expose cached host houses")
        check(noSelection.needsSelection, "nil live workspace offers explicit selection")
        check(noSelection.prompt.title == "Reconnect to your listings" && noSelection.prompt.identifier == "homes.chooseWorkspace", "actual Home selection prompt is named and identifiable")
        WorkspaceContext.selectedOrgID = hostOrg
        check(HomePolicyFixture(model: inventory).visibleIDs == [hostID], "an explicitly chosen still-authorized workspace keeps its existing scope")
        WorkspaceContext.selectedOrgID = nil; Config.useLiveBackend = false
        check(HomePolicyFixture(model: inventory).visibleIDs == savedIDs, "local mock mode remains unchanged")
        check(!HomePolicyFixture(model: inventory).needsSelection, "offline mock does not request server workspace selection")
        Config.useLiveBackend = true
        print("Workspace testing allowance display: \(checks) passed")
    }
}
