import Foundation

@main struct ServingPhotoPackageTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAILED: " + message) }
            checks += 1
        }
        let actor = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let org = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let other = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let clock = Date()
        let iso = ISO8601DateFormatter()
        func reset() {
            AuthStore.shared.userID = actor.uuidString
            AuthStore.shared.syncSessionRevision = 1
            AuthStore.shared.identityWrites = 0
            WorkspaceContext.selectedOrgID = org
        }
        func package(_ cap: Int = 5, used: Int = 2) -> [String: Any] {
            ["org_id": org.uuidString, "starts_at": iso.string(from: clock.addingTimeInterval(-3600)),
             "ends_at": iso.string(from: clock.addingTimeInterval(3600)),
             "policy": "one-gemini-1k-4096-plus-one-kontext-20261007",
             "tariff_version": "published-standard-20261006",
             "photo_admissions": ["cap": cap, "used": used, "remaining": cap - used],
             "photo_hold_cents": 35.1296, "protected_photo_cents": Int(ceil(Double(cap) * 35.1296)),
             "other_ai": ["cap_cents": 38, "used_cents": 3, "remaining_cents": 35]]
        }
        func reply(_ value: Any? = nil, envelope: UUID = org, owner: UUID = actor,
                   activation: Any? = nil, source: String = "apple") throws -> Data {
            var result: [String: Any] = ["user": ["id": owner.uuidString, "name": "Synthetic owner"],
                "org": ["id": envelope.uuidString], "plan": "pro", "plan_source": source,
                "entitlement": ["renders_per_month": 10, "photo_edits_per_month": 200,
                    "reels_per_month": 12, "aerials_per_month": 4, "topaz_per_month": 0]]
            if let value { result["serving_photo_package"] = value }
            if let activation { result["serving_activation"] = activation }
            return try JSONSerialization.data(withJSONObject: result)
        }
        func reject(_ data: Data, expected: String) async {
            do { _ = try await LivePhotoPackageFixture(data: data).me(); fatalError("FAILED: " + expected) }
            catch { checks += 1; check(AuthStore.shared.identityWrites == 0, "Malformed package wrote account identity") }
        }
        reset()
        let legacy = try await LivePhotoPackageFixture(data: reply()).me()
        check(legacy.servingPhotoPackage == nil && legacy.entitlements?.photoEditsPerMonth == 200, "Absent package preserves legacy allowances")
        reset()
        let null = try await LivePhotoPackageFixture(data: reply(NSNull(), source: "manual")).me()
        check(null.servingPhotoPackage == nil && null.entitlements?.planSource == "manual", "Null package preserves private QA")
        for (cap, used) in [(0, 0), (5, 2), (20, 7), (60, 60)] {
            reset()
            let usage = try await LivePhotoPackageFixture(data: reply(package(cap, used: used))).me()
            check(usage.servingPhotoPackage?.photoAdmissions.cap == cap, "Actual me forwards configured package")
            let value = usage.servingPhotoPackage!
            check(value.photoAdmissions.remaining == cap - used, "Actual package uses returned count")
            check(value.rows[0].title == "AI photo edits" && value.rows[0].value == "\(used) of \(cap) used · \(cap - used) remaining", "Package display uses actual remaining")
            check(value.rows[1].title == "Other AI tools" && value.rows[1].value == "92% available", "Other AI balance stays separate")
            check(value.checked(org: other) == nil, "Foreign package workspace accepted")
        }
        reset()
        var noOtherAI = package(); noOtherAI["other_ai"] = ["cap_cents": 0, "used_cents": 0, "remaining_cents": 0]
        let excluded = try await LivePhotoPackageFixture(data: reply(noOtherAI)).me()
        check(excluded.servingPhotoPackage?.rows[1].value == "Not included", "Zero other AI budget does not divide by zero or invent credit")
        var patches: [([String: Any], String)] = [
            (["org_id": other.uuidString], "Foreign package workspace accepted"),
            (["policy": "unpriced"], "Unknown package policy accepted"),
            (["tariff_version": "unpriced"], "Unknown package tariff accepted"),
            (["starts_at": "invalid"], "Invalid package interval accepted"),
            (["starts_at": iso.string(from: clock.addingTimeInterval(600))], "Future package interval accepted"),
            (["ends_at": iso.string(from: clock.addingTimeInterval(-600))], "Expired package interval accepted"),
            (["photo_hold_cents": 0], "Incorrect photo hold accepted"),
            (["protected_photo_cents": 175], "Incorrect protected photo total accepted"),
            (["photo_admissions": ["cap": 5, "used": 2, "remaining": 4]], "Photo count algebra bypassed"),
            (["other_ai": ["cap_cents": 38, "used_cents": 3, "remaining_cents": 38]], "Other AI algebra bypassed")]
        for counter in ["photo_admissions", "other_ai"] {
            let keys = counter == "photo_admissions" ? ["cap", "used", "remaining"] : ["cap_cents", "used_cents", "remaining_cents"]
            for key in keys {
                for bad in [-1, true, "2", 2.5] as [Any] {
                    var nested = package()[counter] as! [String: Any]; nested[key] = bad
                    patches.append(([counter: nested], "Malformed package integer accepted"))
                }
            }
        }
        patches.append((["photo_admissions": ["cap": 10001, "used": 0, "remaining": 10001]], "Unbounded photo count accepted"))
        patches.append((["other_ai": ["cap_cents": 100000001, "used_cents": 0, "remaining_cents": 100000001]], "Unbounded other AI balance accepted"))
        for (patch, expected) in patches {
            reset(); var value = package(); value.merge(patch) { _, newer in newer }
            await reject(try reply(value), expected: expected)
        }
        reset(); await reject(try reply(package(), envelope: other), expected: "Foreign enclosing workspace accepted")
        reset(); await reject(try reply(package(), owner: other), expected: "Foreign package actor accepted")
        reset(); await reject(try reply(package(), activation: ["org_id": org.uuidString, "available": false, "funded": false,
            "authority": "subscription_activation_unavailable"]), expected: "Unavailable activation displayed package")
        for mode in ["actor", "revision", "workspace"] {
            reset()
            let api = LivePhotoPackageFixture(data: try reply(package()))
            api.onRead = {
                if mode == "actor" { AuthStore.shared.userID = other.uuidString }
                if mode == "revision" { AuthStore.shared.syncSessionRevision += 1 }
                if mode == "workspace" { WorkspaceContext.selectedOrgID = other }
            }
            do { _ = try await api.me(); fatalError("FAILED: Late package context accepted") }
            catch { checks += 1 }
            check(AuthStore.shared.identityWrites == 0, "Late package context wrote replacement identity")
        }
        // serving_envelope (ceiling mode): additive, lenient, self-checked.
        func envelope(_ patch: [String: Any] = [:], kind: String = "retail") -> [String: Any] {
            var value: [String: Any] = ["kind": kind, "plan": "pro", "ceiling_cents": 1682, "spent_cents": 120.5, "held_cents": 8.36,
                "available_cents": 1553.14, "period_start": iso.string(from: clock.addingTimeInterval(-86_400)),
                "period_end": iso.string(from: clock.addingTimeInterval(29 * 86_400)), "window": "apple_term", "pool": NSNull()]
            value.merge(patch) { _, newer in newer }
            return value
        }
        func withEnvelope(_ value: Any?, historicalTrial: String? = nil) throws -> Data {
            var result = try JSONSerialization.jsonObject(with: reply()) as! [String: Any]
            if let value { result["serving_envelope"] = value }
            if let status = historicalTrial {
                result["trial_usage"] = ["org_id": org.uuidString, "status": status,
                    "starts_at": iso.string(from: clock.addingTimeInterval(-6 * 86_400)),
                    "ends_at": iso.string(from: clock.addingTimeInterval(86_400)),
                    "walkthroughs": ["used": 0, "cap": 1, "remaining": 1],
                    "photo_edits": ["used": 1, "cap": 5, "remaining": 4],
                    "published_listings": ["used": 0, "cap": 1, "remaining": 1],
                    "upload_budget_bytes": 1_073_741_824, "upload_used_bytes": 0]
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
        reset()
        let retail = try await LivePhotoPackageFixture(data: withEnvelope(envelope())).me()
        check(retail.servingEnvelope?.kind == "retail" && retail.servingEnvelope?.window == "apple_term", "Actual me forwards the serving envelope")
        check(retail.servingEnvelope?.budgetTitle == "AI budget", "Retail envelope title")
        check(retail.servingEnvelope?.budgetValue == "$1.21 used · $15.53 available of $16.82", "Envelope value rounds spend up and what is left down")
        check(retail.servingEnvelope?.resetLine?.hasPrefix("Resets ") == true && retail.servingEnvelope?.resetLine?.contains("subscription period") == true, "Apple term reset line")
        check(retail.servingEnvelope?.heldLine == "$0.09 is reserved for work still running.", "Held liability line")
        check(retail.servingEnvelope?.poolLine == nil, "Retail shows no sponsor pool")
        for status in ["active", "exhausted", "expired"] {
            reset()
            let coexist = try await LivePhotoPackageFixture(data: withEnvelope(envelope(), historicalTrial: status)).me()
            check(coexist.servingEnvelope?.checked() != nil && coexist.trialUsage?.status.rawValue == status,
                  "Current checked allowance remains available alongside historical trial metadata")
        }
        reset()
        let free = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["kind": "free", "ceiling_cents": 300, "spent_cents": 0, "held_cents": 0,
            "available_cents": 300, "period_start": NSNull(), "period_end": NSNull(), "window": "lifetime"]))).me()
        check(free.servingEnvelope?.budgetTitle == "Free AI allowance" && free.servingEnvelope?.resetLine?.contains("does not reset") == true, "Free lifetime wording")
        reset()
        let trial = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["kind": "trial", "ceiling_cents": 500, "available_cents": 371.14, "window": "trial_window",
            "pool": ["cap_cents": 29000, "spent_cents": 1200.25, "starts_at": iso.string(from: clock.addingTimeInterval(-86_400)), "ends_at": iso.string(from: clock.addingTimeInterval(20 * 86_400))]]))).me()
        check(trial.servingEnvelope?.budgetTitle == "Free-trial AI budget" && trial.servingEnvelope?.resetLine?.hasPrefix("Trial budget ends ") == true, "Trial wording")
        check(trial.servingEnvelope?.poolLine?.hasPrefix("Trial AI is available until ") == true
              && trial.servingEnvelope?.poolLine?.hasSuffix(", while trial capacity remains.") == true, "Trial capacity line")
        check(trial.servingEnvelope?.poolLine?.contains("$") == false && trial.servingEnvelope?.poolLine?.contains("sponsor") == false, "Trial capacity hides internal funding")
        check(trial.servingEnvelope?.capacityLine(now: clock)?.hasPrefix("Trial AI is available until ") == true, "Active trial capacity uses a fixed clock")
        reset()
        let intro = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["kind": "trial", "window": "intro_window"]))).me()
        check(intro.servingEnvelope?.resetLine?.hasPrefix("Trial allowance ends ") == true
              && intro.servingEnvelope?.resetLine?.contains("unless canceled") == true
              && intro.servingEnvelope?.resetLine?.contains("Resets") == false, "Intro allowance ends instead of promising another trial reset")
        for pool in [["cap_cents": 29000, "spent_cents": 29000, "starts_at": iso.string(from: clock.addingTimeInterval(-86_400)), "ends_at": iso.string(from: clock.addingTimeInterval(86_400))],
                     ["cap_cents": 29000, "spent_cents": 0, "starts_at": iso.string(from: clock.addingTimeInterval(-2 * 86_400)), "ends_at": iso.string(from: clock.addingTimeInterval(-86_400))],
                     ["cap_cents": 29000, "spent_cents": 0, "starts_at": iso.string(from: clock.addingTimeInterval(86_400)), "ends_at": iso.string(from: clock.addingTimeInterval(2 * 86_400))],
                     ["cap_cents": 29000, "spent_cents": 0, "ends_at": iso.string(from: clock.addingTimeInterval(86_400))],
                     ["cap_cents": 29000, "spent_cents": 0, "starts_at": "bad-date", "ends_at": "bad-date"]] as [[String: Any]] {
            reset()
            let closed = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["window": "trial_window", "pool": pool], kind: "trial"))).me()
            check(closed.servingEnvelope?.capacityLine(now: clock) == "Trial AI capacity is unavailable right now.", "Exhausted, ended, future or invalid trial capacity is clear")
        }
        reset()
        let exhaustedFree = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["kind": "free", "ceiling_cents": 300, "spent_cents": 396,
            "held_cents": 0, "available_cents": 0, "window": "lifetime"]))).me()
        check(exhaustedFree.servingEnvelope?.budgetValue == "$3.96 used · $0 available of $3", "Historical free spend above ceiling remains visible")
        reset()
        let grace = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["kind": "grace", "window": "apple_grace"]))).me()
        check(grace.servingEnvelope?.budgetTitle == "AI budget (billing grace)" && grace.servingEnvelope?.resetLine?.hasPrefix("Billing grace ends ") == true, "Grace wording")
        for (bad, why) in [(envelope(["available_cents": 1700]), "Available above ceiling"),
                           (NSNull(), "Null envelope"), ("ceiling", "String envelope"), (["kind": 7], "Wrong-typed kind"),
                           (["kind": "retail"], "Envelope without money"),
                           (envelope(["available_cents": 1600]), "Available ignores running holds"),
                           (envelope(["spent_cents": -1]), "Negative spend"),
                           (envelope(["spent_cents": 1e20, "available_cents": 0]), "Overflowing spend"),
                           (envelope(["held_cents": 1e20, "available_cents": 0]), "Overflowing hold"),
                           (envelope(["ceiling_cents": 2147483647, "available_cents": 2147483647 - 120.5 - 8.36], kind: "sponsored"), "Sponsored unlimited budget"),
                           (envelope(["spent_cents": "inf"]), "Infinite spend"),
                           (envelope(["ceiling_cents": "abc"]), "Non-numeric ceiling")] as [(Any, String)] {
            reset()
            let usage = try await LivePhotoPackageFixture(data: withEnvelope(bad)).me()
            check(usage.servingEnvelope == nil, why + " was drawn")
            check(usage.entitlements?.photoEditsPerMonth == 200, why + " broke the legacy allowances")
        }
        reset()
        let brokenPool = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["ceiling_cents": 500, "available_cents": 371.14,
            "window": "trial_window", "pool": ["cap_cents": "x"]], kind: "trial"))).me()
        check(brokenPool.servingEnvelope?.budgetTitle == "Free-trial AI budget" && brokenPool.servingEnvelope?.poolLine == "Trial AI capacity is unavailable right now.", "Malformed pool cannot advertise available trial capacity")
        for (pool, why) in [(["cap_cents": 1e20, "spent_cents": 0], "Overflowing pool cap"),
                            (["cap_cents": 29000, "spent_cents": 1e20], "Overflowing pool spend")] as [([String: Any], String)] {
            reset()
            let bad = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["ceiling_cents": 500, "available_cents": 371.14,
                "window": "trial_window", "pool": pool], kind: "trial"))).me()
            check(bad.servingEnvelope?.budgetTitle == "Free-trial AI budget", why + " hid the customer's own budget")
            check(bad.servingEnvelope?.pool == nil && bad.servingEnvelope?.poolLine == "Trial AI capacity is unavailable right now.", why + " advertised trial capacity")
        }
        reset()
        let missingPool = try await LivePhotoPackageFixture(data: withEnvelope(envelope(["window": "trial_window"], kind: "trial"))).me()
        check(missingPool.servingEnvelope?.poolLine == "Trial AI capacity is unavailable right now.", "Missing pool cannot advertise available trial capacity")
        reset()
        let absent = try await LivePhotoPackageFixture(data: withEnvelope(nil)).me()
        check(absent.servingEnvelope == nil, "Funded-mode server invents an envelope")
        print("Native photo package: \(checks) checks passed")
    }
}
