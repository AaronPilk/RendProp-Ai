import Foundation

@main struct PrivateLibraryContextTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { guard condition else { fatalError(message) }; checks += 1 }
        let actor = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let agent = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let own = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let other = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let oldShared = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
        let qa = UUID(uuidString: "20000000-0000-4000-8000-000000000004")!
        let ownRow = WorkspaceMembership(id: own, name: "My listings", role: "owner", accessMode: "own", libraryOwnerUserID: actor, billingOrgID: own, canRead: true, canWrite: true, canManageSubscription: true)
        let agentRow = WorkspaceMembership(id: other, name: "Agent", role: "team_owner", accessMode: "team_owner", libraryOwnerUserID: agent, billingOrgID: qa, canRead: true, canWrite: true, canManageSubscription: false)
        let preferences = UserDefaults()
        preferences.set("restaurant", forKey: "space.type")
        AccountLocalPreferences.activate(previous: actor, next: agent, defaults: preferences)
        check(preferences.string(forKey: "space.type") == "real_estate", "Other account inherited business type")
        preferences.set("venue", forKey: "space.type")
        AccountLocalPreferences.activate(previous: agent, next: actor, defaults: preferences)
        check(preferences.string(forKey: "space.type") == "restaurant", "Returning account lost own business type")
        preferences.set("saved-intent", forKey: "purchase-workspace.v1.fixture")
        preferences.set("saved-workspace", forKey: "workspace.selection.v1.fixture")
        preferences.set("saved-brand", forKey: "workspace.fixture.brand")
        AccountLocalPreferences.eraseDeviceCache(defaults: preferences)
        check(preferences.string(forKey: "workspace.selection.v1.fixture") == nil && preferences.string(forKey: "workspace.fixture.brand") == nil,
              "Explicit device wipe retained account display cache")
        check(preferences.string(forKey: "space.type") == nil && preferences.string(forKey: "account.space.type.v1." + actor.uuidString.lowercased()) == nil,
              "Explicit device wipe retained account business type")
        check(preferences.string(forKey: "purchase-workspace.v1.fixture") == "saved-intent",
              "Display cleanup discarded an unfinished purchase recovery binding")
        let ownerDirectory = WorkspaceDirectory(actorID: actor, ownOrgID: own, billingOrgID: own, canSwitchAgentLibraries: true, activeOrgID: own, workspaces: [ownRow, agentRow])
        let privateDirectory = WorkspaceDirectory(actorID: actor, ownOrgID: own, billingOrgID: own, canSwitchAgentLibraries: false, activeOrgID: own, workspaces: [ownRow])
        check(ownerDirectory.checked(actor: actor) != nil, "Valid owner directory rejected")
        check(ownerDirectory.checked(actor: agent) == nil, "Foreign directory actor accepted")
        var forgedOwnRow = ownRow; forgedOwnRow.libraryOwnerUserID = agent
        var forgedOtherRow = agentRow; forgedOtherRow.libraryOwnerUserID = actor
        let actorForgery = WorkspaceDirectory(actorID: actor, ownOrgID: own, billingOrgID: own, canSwitchAgentLibraries: true, activeOrgID: own, workspaces: [forgedOwnRow, forgedOtherRow])
        check(actorForgery.checked(actor: agent) == nil, "Foreign directory actor accepted")
        check(WorkspaceEntryPresentation.mode(canSwitch: false, choices: 2, selected: false, showsRecovery: true) == .reconnect, "Ordinary recovery opened agent switcher")
        check(WorkspaceEntryPresentation.mode(canSwitch: true, choices: 2, selected: true, showsRecovery: true) == .switchAgent, "Authorized owner switcher hidden")
        check(WorkspaceEntryPresentation.mode(canSwitch: false, choices: 1, selected: true, showsRecovery: true) == .hidden, "Private account displayed selector")

        check(privateDirectory.selectionChoices.count == 1, "Private owner role inferred sibling access")
        check(privateDirectory.refreshedSelection(previous: oldShared) == own, "Old shared Team selection did not recover private account")
        check(ownerDirectory.refreshedSelection(previous: other) == other, "Authorized local selection was silently reset")
        let forged = WorkspaceDirectory(actorID: actor, ownOrgID: own, billingOrgID: own, canSwitchAgentLibraries: false, activeOrgID: own, workspaces: [ownRow, agentRow])
        check(forged.checked(actor: actor) == nil, "Sibling access accepted without capability")
        let wrongActive = WorkspaceDirectory(actorID: actor, ownOrgID: own, billingOrgID: own, canSwitchAgentLibraries: true, activeOrgID: oldShared, workspaces: [ownRow, agentRow])
        check(wrongActive.checked(actor: actor) == nil, "Unknown active library accepted")
        UserDefaults.standard.set(actor.uuidString, forKey: "auth.supabase.userID")
        AuthStore.shared.userID = actor.uuidString
        let invalidSnapshot = WorkspaceContext.Snapshot(selectedOrgID: other, workspaces: ownerDirectory.workspaces, directory: ownerDirectory)
        check(!WorkspaceContext.save(invalidSnapshot, owner: actor), "Snapshot and active directory disagreement accepted")
        let delegated = ownerDirectory.selecting(other)!
        check(WorkspaceContext.save(.init(selectedOrgID: other, workspaces: delegated.workspaces, directory: delegated), owner: actor), "Valid scoped cache rejected")
        let store = WorkspaceStore()
        check(store.selected == nil && store.selectionChoices.isEmpty && !store.canSwitchAgentLibraries && !store.canViewLibrary(other), "Cached delegation reopened another agent before fresh authority")
        check(WorkspaceContext.billingOrgID == own && WorkspaceContext.servingOrgID == qa, "Purchase and serving roots conflated")
        URLSession.fixture = try JSONEncoder().encode(ownerDirectory)
        await store.refresh()
        check(store.canSwitchAgentLibraries && store.selected?.id == other, "Fresh owner directory lost valid selection")
        check(URLSession.requests.last?.value(forHTTPHeaderField: "X-Org-Id") == nil, "Fresh directory carried removed Team preference")
        let reads = URLSession.requests.count
        check(!(await store.select(.init(id: oldShared, name: nil, role: "owner"))), "Unrelated explicit library switch accepted")
        check(URLSession.requests.count == reads, "Unrelated switch dispatched")
        URLSession.status = 503
        await store.refresh()
        check(store.canViewLibrary(other), "Transient transport failure erased verified selection")
        URLSession.status = 403
        let refusalRevision = AuthStore.shared.syncSessionRevision
        await store.refresh()
        check(!store.canSwitchAgentLibraries && !store.canViewLibrary(other) && store.selected == nil, "Authority refusal retained delegation")
        check(AuthStore.shared.syncSessionRevision > refusalRevision && store.snapshot?.workspaces == [ownRow], "Authority refusal lost own content or stale request guard")
        URLSession.status = 200
        URLSession.fixture = try JSONEncoder().encode(ownerDirectory)
        await store.refresh()
        URLSession.fixture = Data("{}".utf8)
        await store.refresh()
        check(!store.canSwitchAgentLibraries && store.selected == nil, "Malformed authority retained delegation")
        URLSession.fixture = try JSONEncoder().encode(privateDirectory)
        let revision = AuthStore.shared.syncSessionRevision
        await store.refresh()
        check(store.selected?.id == own && !store.canSwitchAgentLibraries && !store.canViewLibrary(other), "Revoked owner permission remained visible")
        check(AuthStore.shared.syncSessionRevision > revision, "Permission removal did not invalidate in-flight scope")
        check(WorkspaceContext.current?.directory?.activeOrgID == WorkspaceContext.selectedOrgID, "Recovered selection and active directory disagree")
        URLSession.fixture = try JSONEncoder().encode(ownerDirectory)
        await store.refresh()
        URLSession.fixture = Data("{\"org_id\":\"\(other.uuidString)\"}".utf8)
        URLSession.onResponse = { AuthStore.shared.syncSessionRevision += 1 }
        check(!(await store.select(agentRow)) && WorkspaceContext.selectedOrgID == own, "Late switch response retargeted changed session")
        URLSession.onResponse = nil
        check(!store.canSwitchAgentLibraries, "Old verified revision retained delegation")

        check(WorkspaceContext.save(.init(selectedOrgID: other, workspaces: delegated.workspaces, directory: delegated), owner: actor), "Team scoped fixture failed")
        var teamWire: [String: Any] = ["org_id": own.uuidString, "actor_id": actor.uuidString, "content_org_id": other.uuidString,
            "can_manage": true, "seats": ["used": 1, "allowed": 6], "members": [], "invites": []]
        URLSession.fixture = try JSONSerialization.data(withJSONObject: teamWire)
        check(try await TeamAPI.summary().canManage, "Owner viewing agent cannot load own parent Team")
        check(URLSession.requests.last?.value(forHTTPHeaderField: "X-Org-Id") == other.uuidString.lowercased(), "Team request aliased to parent content")
        for field in ["actor_id", "org_id", "content_org_id"] {
            var wrong = teamWire; wrong[field] = oldShared.uuidString
            URLSession.fixture = try JSONSerialization.data(withJSONObject: wrong)
            do { _ = try await TeamAPI.summary(); fatalError("Foreign Team summary accepted") } catch { checks += 1 }
        }
        teamWire["can_manage"] = false
        URLSession.fixture = try JSONSerialization.data(withJSONObject: teamWire)
        check(!(try await TeamAPI.summary()).canManage, "Agent Team summary inferred management")

        func billing(content: UUID = other, serving: UUID = qa, purchase: UUID = own, manage: Bool = true) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["org": ["id": other.uuidString], "plan": "team", "serving_mode": "ceiling", "billing": ["org_id": purchase.uuidString, "content_org_id": content.uuidString, "serving_org_id": serving.uuidString, "role": "owner", "can_manage_subscription": manage], "serving_activation": ["org_id": serving.uuidString, "available": true, "funded": false, "authority": "private_sponsorship"]])
        }
        let verified = try SubscriptionBillingContext.fromMe(billing(), selectedOrg: other, billingOrg: own, servingOrg: qa)
        check(verified.orgID == own && verified.contentOrgID == other && verified.servingActivation?.orgId == qa, "Three independent scope bindings lost")
        for value in [try billing(content: oldShared), try billing(serving: oldShared), try billing(purchase: oldShared)] {
            do { _ = try SubscriptionBillingContext.fromMe(value, selectedOrg: other, billingOrg: own, servingOrg: qa); fatalError("Foreign financial binding accepted") } catch { checks += 1 }
        }
        let before = TrialPurchaseSnapshot(actor: actor.uuidString, revision: 4, org: other, billingOrg: own)
        check(PurchaseDispatchAdmission.allows(liveBackend: true, uiTesting: false, ceilingMode: true, verifiedHeldTrial: false, captured: before, current: before), "Bound ceiling purchase rejected")
        for changed in [TrialPurchaseSnapshot(actor: actor.uuidString, revision: 4, org: own, billingOrg: own), TrialPurchaseSnapshot(actor: agent.uuidString, revision: 4, org: other, billingOrg: own), TrialPurchaseSnapshot(actor: actor.uuidString, revision: 5, org: other, billingOrg: own), TrialPurchaseSnapshot(actor: actor.uuidString, revision: 4, org: other, billingOrg: oldShared)] {
            check(!PurchaseDispatchAdmission.allows(liveBackend: true, uiTesting: false, ceilingMode: true, verifiedHeldTrial: false, captured: before, current: changed), "Changed purchase scope accepted")
        }
        let memberBilling = try SubscriptionBillingContext.fromMe(billing(manage: false), selectedOrg: other, billingOrg: own, servingOrg: qa)
        check(!TrialPurchaseAdmission.allows(eligibleIntro: false, billing: memberBilling, captured: before, current: before), "Sponsored agent initiated parent purchase")
        print("Private library context: \(checks) checks passed; synthetic auth/HTTP only")
    }
}
