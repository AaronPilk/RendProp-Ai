import Foundation

@main struct TrialUsageTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }
            checks += 1
        }
        let org = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        WorkspaceContext.selectedOrgID = org
        func counter(_ used: Int, _ cap: Int) -> [String: Any] {
            ["used": used, "cap": cap, "remaining": cap - used]
        }
        func trial(_ status: String = "active") -> [String: Any] {
            ["org_id": org.uuidString, "status": status,
             "starts_at": "2026-01-01T00:00:00.000Z", "ends_at": "2026-01-08T00:00:00Z",
             "walkthroughs": counter(1, 1), "photo_edits": counter(2, 5),
             "published_listings": counter(0, 1), "upload_budget_bytes": 134_217_728,
             "upload_used_bytes": 1_048_576]
        }
        func offer(_ enabled: Bool = true) -> [String: Any] {
            ["enabled": enabled, "walkthroughs": 1, "photo_edits": 5, "published_listings": 1,
             "max_days": 7, "max_video_seconds": 90, "upload_budget_bytes": 134_217_728]
        }
        func reply(_ usage: Any? = nil, _ proposed: Any? = nil, activation: Any? = nil, envelopeOrg: UUID = org,
                   plan: String = "pro", source: String = "apple") throws -> Data {
            var json: [String: Any] = ["org": ["id": envelopeOrg.uuidString], "plan": plan,
                "plan_source": source,
                "entitlement": ["renders_per_month": 10, "photo_edits_per_month": 200,
                    "reels_per_month": 12, "aerials_per_month": 4, "topaz_per_month": 0],
                "billing": ["org_id": org.uuidString, "role": "owner", "can_manage_subscription": true]]
            if let usage { json["trial_usage"] = usage }
            if let proposed { json["trial_offer"] = proposed }
            if let activation { json["serving_activation"] = activation }
            return try JSONSerialization.data(withJSONObject: json)
        }
        let old = try await LiveTrialFixture(data: reply()).me()
        check(old.trialUsage == nil && old.trialOffer == nil, "No trial inferred from a chosen paid plan")
        check(old.entitlements?.photoEditsPerMonth == 200, "Existing paid allowance remains unchanged")
        let null = try await LiveTrialFixture(data: reply(NSNull(), NSNull())).me()
        check(null.trialUsage == nil && null.trialOffer == nil, "Null additive fields preserve old servers")
        func activation(_ authority: String = "subscription_activation_unavailable", available: Bool = false, funded: Bool = false, id: UUID = org) -> [String: Any] {
            ["org_id": id.uuidString, "available": available, "funded": funded, "authority": authority]
        }
        let pending = try await LiveTrialFixture(data: reply(activation: activation())).me()
        check(pending.planName == "pro" && pending.servingActivation?.available == false, "Pending service preserves recorded subscription identity")
        check(pending.entitlements?.photoEditsPerMonth == 0 && pending.entitlements?.rendersPerMonth == 0,
              "Pending activation exposed usable paid photo allowance")
        let pendingContext = try SubscriptionBillingContext.fromMe(reply(activation: activation()), selectedOrg: org)
        check(pendingContext.servingActivation?.available == false && pendingContext.canManageSubscription,
              "Billing pending status keeps restore and management context")
        check(pendingContext.showsServicePending, "Active recorded Apple plan unavailable shows pending")
        let oldFree = try SubscriptionBillingContext.fromMe(reply(activation: activation(), plan: "free"), selectedOrg: org)
        check(!oldFree.showsServicePending, "Historical free access precedes generic service pending")
        let oldTrial = try SubscriptionBillingContext.fromMe(reply(trial("expired"), activation: activation()), selectedOrg: org)
        check(!oldTrial.showsServicePending && oldTrial.trialUsage?.status == .expired,
              "Recorded expired trial precedes generic service pending")
        check(PlanBanner.pendingActivationState().kind == .activationPending && PlanBanner.pendingActivationState().title == "Service activation pending",
              "Home shows explicit service activation pending")
        let syncPending = try JSONDecoder().decode(EntitlementSync.self, from: reply(activation: activation()))
        check(syncPending.plan == "pro" && syncPending.servingActivation?.available == false,
              "Signed subscription response keeps identity separate from serving activation")
        check(try JSONDecoder().decode(EntitlementSync.self, from: reply()).servingActivation == nil,
              "Legacy signed subscription response stays compatible")
        for (authority, funded) in [("private_sponsorship", false), ("brokerage", false), ("existing_non_apple", false), ("app_review", true), ("verified_retail", true), ("funded_trial", true)] {
            let authorized = try await LiveTrialFixture(data: reply(activation: activation(authority, available: true, funded: funded))).me()
            check(authorized.servingActivation?.available == true && authorized.entitlements?.photoEditsPerMonth == 200,
                  "Verified manual QA and funded serving allowances remain unchanged")
        }
        do { _ = try await LiveTrialFixture(data: reply(activation: activation(id: other))).me(); fatalError("Foreign activation workspace accepted") }
        catch { checks += 1 }
        for bad in [activation(available: true), activation(funded: true), activation("unknown-authority"), activation("private_sponsorship", available: true, funded: true)] {
            do { _ = try await LiveTrialFixture(data: reply(activation: bad)).me(); fatalError("Malformed activation accepted") }
            catch { checks += 1 }
        }
        let disabled = try await LiveTrialFixture(data: reply(nil, ["enabled": false])).me()
        check(disabled.trialOffer?.benefitLines == [], "Disabled offer never promises numeric quantities")
        let disabledNumbers = try await LiveTrialFixture(data: reply(nil, offer(false))).me()
        check(disabledNumbers.trialOffer?.benefitLines == [], "Disabled configured quantities stay hidden")
        let current = try await LiveTrialFixture(data: reply(trial(), offer())).me()
        check(current.trialUsage?.photoEdits.cap == 5, "Actual me forwards recorded trial usage")
        check(current.trialOffer?.benefitLines.first?.contains("1 hosted walkthrough") == true, "Actual me forwards enabled offer")
        let usage = current.trialUsage!
        check(usage.status == .active && usage.walkthroughs.remaining == 0 && usage.photoEdits.remaining == 3 && usage.publishedListings.remaining == 1,
              "Buckets remain independent after the walkthrough is used")
        check(usage.rows.map(\.title) == ["Hosted walkthroughs", "AI photo edit credits", "Published listings", "Trial upload space"], "All trial action and upload counters are labelled")
        check(usage.rows[1].value == "2 of 5 used · 3 remaining", "Recorded used cap and remaining reach presentation")
        check(usage.checked(org: other) == nil, "Recorded trial cannot cross workspaces")
        check(usage.endDate != nil && usage.status == .active, "Server status is authoritative regardless of local elapsed date")
        let home = PlanBanner.boundedTrialState(usage)
        check(home.kind == .trial && home.detail.contains("3 photo edit credits"), "Home banner presents actual remaining photo credits")
        for status in ["exhausted", "expired"] {
            let recorded = try await LiveTrialFixture(data: reply(trial(status), ["enabled": false])).me()
            check(recorded.trialUsage?.rows.count == 4 && recorded.trialUsage?.photoEdits.used == 2,
                  "Recorded trial remains visible when catalog is disabled or access ended")
            check(PlanBanner.boundedTrialState(recorded.trialUsage!).kind == .ended, "Home banner obeys expired server status")
        }
        var different = trial(); different["photo_edits"] = counter(1, 3)
        let recorded = try await LiveTrialFixture(data: reply(different, offer())).me()
        check(recorded.trialUsage?.photoEdits.cap == 3, "Recorded cap is never replaced with offer or hardcoded five")
        let context = try SubscriptionBillingContext.fromMe(reply(trial(), offer()), selectedOrg: org)
        check(context.trialUsage?.photoEdits.used == 2 && context.trialOffer?.benefitLines.count == 4, "Billing consumer receives paired additive presentation")
        let legacyBilling = try SubscriptionBillingContext.fromMe(reply(), selectedOrg: org)
        check(legacyBilling.trialUsage == nil && legacyBilling.trialOffer == nil, "Legacy billing does not invent an offer")
        var fullIngress = trial(); fullIngress["upload_used_bytes"] = 134_217_728
        let full = try await LiveTrialFixture(data: reply(fullIngress)).me()
        check(full.trialUsage?.status == .active && full.trialUsage?.photoEdits.remaining == 3 && full.trialUsage?.publishedListings.remaining == 1,
              "Full ingress does not replace remaining photo and publication counters")
        check(full.trialUsage!.rows[3].value.contains("0 bytes remaining"), "Upload row exposes exhausted ingress separately")
        check(PlanBanner.boundedTrialState(full.trialUsage!).detail.contains("0 bytes remaining"), "Home banner exposes exhausted ingress separately")
        for source in ["manual", "brokerage"] {
            let existing = try await LiveTrialFixture(data: reply(nil, nil, plan: "team", source: source)).me()
            check(existing.trialUsage == nil && existing.entitlements?.planSource == source, "Manual and contract access has no inferred trial overlay")
        }
        var invalid: [[String: Any]] = []
        for key in ["used", "cap", "remaining"] {
            var bad = trial(); var c = counter(2, 5); c[key] = -1; bad["photo_edits"] = c; invalid.append(bad)
        }
        var bad = trial(); bad["photo_edits"] = ["used": 2, "cap": 5, "remaining": 4]; invalid.append(bad)
        bad = trial(); bad["org_id"] = other.uuidString; invalid.append(bad)
        bad = trial(); bad["ends_at"] = "2026-01-09T00:00:00Z"; invalid.append(bad)
        bad = trial(); bad["ends_at"] = "2025-12-31T00:00:00Z"; invalid.append(bad)
        bad = trial(); bad["starts_at"] = "untrusted-clock"; invalid.append(bad)
        bad = trial(); bad["status"] = "paid"; invalid.append(bad)
        bad = trial(); bad["upload_used_bytes"] = 134_217_729; invalid.append(bad)
        bad = trial(); bad["photo_edits"] = ["used": "2", "cap": 5, "remaining": 3]; invalid.append(bad)
        bad = trial(); bad.removeValue(forKey: "published_listings"); invalid.append(bad)
        bad = trial(); bad["photo_edits"] = counter(0, 0); invalid.append(bad)
        bad = trial(); bad["photo_edits"] = counter(0, 6); invalid.append(bad)
        bad = trial(); bad["walkthroughs"] = counter(0, 2); invalid.append(bad)
        bad = trial(); bad["published_listings"] = counter(0, 2); invalid.append(bad)
        bad = trial(); bad["upload_budget_bytes"] = 1_073_741_825; invalid.append(bad)
        for payload in invalid {
            do { _ = try await LiveTrialFixture(data: reply(payload)).me(); fatalError("Malformed trial response accepted") }
            catch { checks += 1 }
        }
        var wrongDays = offer(); wrongDays["max_days"] = 8
        do { _ = try await LiveTrialFixture(data: reply(nil, wrongDays)).me(); fatalError("Non-seven-day enabled offer accepted") }
        catch { checks += 1 }
        for (key, value) in [("walkthroughs", 2), ("photo_edits", 6), ("published_listings", 2), ("max_video_seconds", 91), ("upload_budget_bytes", 1_073_741_825)] {
            var malformed = offer(); malformed[key] = value
            do { _ = try await LiveTrialFixture(data: reply(nil, malformed)).me(); fatalError("Unbounded enabled offer accepted") }
            catch { checks += 1 }
        }
        do { _ = try await LiveTrialFixture(data: reply(trial(), nil, envelopeOrg: other)).me(); fatalError("Foreign enclosing org accepted") }
        catch { checks += 1 }
        do { _ = try SubscriptionBillingContext.fromMe(reply(nil, offer(), envelopeOrg: other), selectedOrg: org); fatalError("Billing offer accepted foreign enclosing org") }
        catch { checks += 1 }
        for kind in ["actor", "revision", "workspace"] {
            AuthStore.shared.userID = "synthetic-owner"; AuthStore.shared.syncSessionRevision = 1; WorkspaceContext.selectedOrgID = org
            let fixture = LiveTrialFixture(data: try reply())
            fixture.onRead = {
                if kind == "actor" { AuthStore.shared.userID = "different-synthetic-owner" }
                if kind == "revision" { AuthStore.shared.syncSessionRevision = 2 }
                if kind == "workspace" { WorkspaceContext.selectedOrgID = other }
            }
            do { _ = try await fixture.me(); fatalError("Changed \(kind) accepted after response") }
            catch { check(fixture.identityWrites == 0, "Stale response cannot apply personal identity") }
        }
        AuthStore.shared.userID = "synthetic-owner"; AuthStore.shared.syncSessionRevision = 1; WorkspaceContext.selectedOrgID = org
        let held = HeldBillingAPI()
        let currentRefresh = BillingRefreshFixture(held)
        let first = Task { await currentRefresh.refreshBillingContext() }
        while held.pending.count < 1 { await Task.yield() }
        let second = Task { await currentRefresh.refreshBillingContext() }
        while held.pending.count < 2 { await Task.yield() }
        held.pending[1].resume(returning: legacyBilling)
        await second.value
        held.pending[0].resume(returning: context)
        await first.value
        check(currentRefresh.billingContext?.trialUsage == nil && currentRefresh.billingContext?.orgID == org,
              "Older same-workspace trial response replaced verified paid state")
        let snapshot = TrialPurchaseSnapshot(actor: "synthetic-owner", revision: 1, org: org)
        check(!TrialPurchaseAdmission.allows(eligibleIntro: true, billing: legacyBilling, captured: snapshot, current: snapshot),
              "Absent offer authorized an introductory purchase")
        let disabledBilling = try SubscriptionBillingContext.fromMe(reply(nil, offer(false)), selectedOrg: org)
        check(!TrialPurchaseAdmission.allows(eligibleIntro: true, billing: disabledBilling, captured: snapshot, current: snapshot),
              "Disabled offer authorized an introductory purchase")
        check(TrialPurchaseAdmission.allows(eligibleIntro: false, billing: legacyBilling, captured: snapshot, current: snapshot),
              "Known noneligible paid purchase should retain existing behavior")
        let deniedBilling = SubscriptionBillingContext(orgID: org, orgName: nil, role: "agent", canManageSubscription: false, source: "apple")
        check(!TrialPurchaseAdmission.allows(eligibleIntro: false, billing: deniedBilling, captured: snapshot, current: snapshot),
              "Denied fresh authority authorized noneligible billing")
        let wrongPaidWorkspace = SubscriptionBillingContext(orgID: other, orgName: nil, role: "owner", canManageSubscription: true, source: "apple")
        check(!TrialPurchaseAdmission.allows(eligibleIntro: false, billing: wrongPaidWorkspace, captured: snapshot, current: snapshot),
              "Foreign workspace authorized noneligible billing")
        check(!TrialPurchaseAdmission.allows(eligibleIntro: nil, billing: context, captured: snapshot, current: snapshot),
              "Unknown eligibility must not begin introductory billing")
        check(TrialPurchaseAdmission.allows(eligibleIntro: true, billing: context, captured: snapshot, current: snapshot),
              "Valid hypothetical server offer with current workspace can pass the necessary gate")
        var malformedBilling = context
        malformedBilling.trialOffer = TrialOfferSummary(enabled: true, walkthroughs: 1, photoEdits: 5,
            publishedListings: 1, maxDays: 8, maxVideoSeconds: 90, uploadBudgetBytes: 134_217_728)
        check(!TrialPurchaseAdmission.allows(eligibleIntro: true, billing: malformedBilling, captured: snapshot, current: snapshot),
              "Malformed offer authorized an introductory purchase")
        var foreignBilling = SubscriptionBillingContext(orgID: other, orgName: nil, role: "owner", canManageSubscription: true, source: "apple")
        foreignBilling.trialOffer = context.trialOffer
        check(!TrialPurchaseAdmission.allows(eligibleIntro: true, billing: foreignBilling, captured: snapshot, current: snapshot),
              "Foreign workspace authorized an introductory purchase")
        for kind in ["actor", "revision", "workspace"] {
            AuthStore.shared.userID = "synthetic-owner"; AuthStore.shared.syncSessionRevision = 1; WorkspaceContext.selectedOrgID = org
            let gate = HeldBillingAPI()
            let freshAdmission = BillingRefreshFixture(gate)
            let attempt = Task { try await freshAdmission.validateTrialPurchase(eligibleIntro: true, captured: snapshot) }
            while gate.pending.count < 1 { await Task.yield() }
            if kind == "actor" { AuthStore.shared.userID = "different-synthetic-owner" }
            if kind == "revision" { AuthStore.shared.syncSessionRevision = 2 }
            if kind == "workspace" { WorkspaceContext.selectedOrgID = other }
            gate.pending[0].resume(returning: context)
            check(try await attempt.value == false, "Late account or workspace response authorized introductory billing")
        }
        print("Native bounded trial: \(checks) checks passed; network, provider, Apple and file deletions 0")
    }
}
