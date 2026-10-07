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
        print("Native photo package: \(checks) checks passed")
    }
}
