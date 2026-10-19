import Foundation

// The runner extracts the actual production models and request decoder body.
// Only the unrelated APIError case needs a stand-in; no network is involved.
enum APIError: Error { case decoding }

@main struct AdminCohortDecodingTests {
    private static var assertions = 0

    private static func check(_ value: Bool, _ message: String) {
        assertions += 1
        guard value else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func decode(_ object: [String: Any]) throws -> AdminCohortReport {
        try AdminCohortTestDecoder.decode(
            AdminCohortReport.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    static func main() throws {
        // Use the server's real snake_case keys, including numeric suffixes.
        let counts: [String: Any] = [
            "orgs": 6, "activated": 5,
            "activated_within_24h": 2, "activated_within_7d": 4,
            "median_hours_to_activate": 5.0,
            "ever_paid": 3, "ever_paid_sandbox": 1,
            "paying_now": 2, "churned": 1,
        ]
        var bucket = counts
        bucket["bucket_start"] = "2026-09-07T00:00:00Z"
        bucket["bucket_end"] = "2026-09-14T00:00:00Z"
        bucket["partial"] = true
        var summary = counts
        summary["orphan_orgs_excluded"] = 31
        let report = try decode([
            "generated_at": "2026-10-04T00:00:00Z",
            "window": "90d", "bucket": "week",
            "buckets": [bucket], "summary": summary,
            "note": "Synthetic report", "future_field": "ignored", "is_sample": true,
        ])
        check(report.buckets?.count == 1, "bucket count")
        check(report.summary != nil, "summary survives decoding")
        let row = report.buckets![0]
        let total = report.summary!
        check(row.activatedWithin24h == 2, "bucket actual 24h count")
        check(row.activatedWithin7d == 4, "bucket actual 7d count")
        check(total.activatedWithin24h == 2, "summary actual 24h count")
        check(total.activatedWithin7d == 4, "summary actual 7d count")
        check(row.orgs == 6 && total.orgs == 6, "workspace counts")
        check(row.activated == 5 && total.activated == 5, "activation counts")
        check(row.medianHoursToActivate == 5 && total.medianHoursToActivate == 5, "median")
        check(row.everPaid == 3 && total.everPaid == 3, "paid counts")
        check(row.everPaidSandbox == 1 && total.everPaidSandbox == 1, "sandbox counts")
        check(row.payingNow == 2 && total.payingNow == 2, "current paid counts")
        check(row.churned == 1 && total.churned == 1, "churn counts")
        check(total.orphanOrgsExcluded == 31, "excluded count stays separate")
        check(row.bucketStart == "2026-09-07T00:00:00Z", "bucket start")
        check(row.bucketEnd == "2026-09-14T00:00:00Z", "bucket end")
        check(row.id == row.bucketStart && row.partial, "bucket identity and partial flag")
        check(!report.isEmpty && report.bucketList.count == 1, "populated report")
        check(report.generatedAt == "2026-10-04T00:00:00Z", "generated time")
        check(report.window == "90d" && report.bucket == "week", "window and bucket")
        check(report.note == "Synthetic report" && report.isSample == nil, "server cannot mark a mock report")

        // Bucket metrics are independent of one another and of summary values.
        var second = bucket
        second["bucket_start"] = "2026-09-14T00:00:00Z"
        second["activated_within_24h"] = 0
        second["activated_within_7d"] = 1
        summary["activated_within_24h"] = 2
        summary["activated_within_7d"] = 5
        let multiple = try decode(["buckets": [bucket, second], "summary": summary])
        check(multiple.buckets?.count == 2, "multiple buckets survive")
        check(multiple.buckets![1].activatedWithin24h == 0, "real zero is preserved")
        check(multiple.buckets![1].activatedWithin7d == 1, "second bucket remains independent")
        check(multiple.summary!.activatedWithin7d == 5, "summary is not copied from a bucket")

        // Tolerance stays per field; one changed server field cannot blank others.
        let missing = try decode(["buckets": [["orgs": 2]], "summary": ["orgs": 2]])
        check(missing.buckets![0].activatedWithin24h == 0, "missing bucket 24h is tolerated")
        check(missing.buckets![0].activatedWithin7d == 0, "missing bucket 7d is tolerated")
        check(missing.summary!.activatedWithin24h == 0, "missing summary 24h is tolerated")
        check(missing.summary!.activatedWithin7d == 0, "missing summary 7d is tolerated")
        check(missing.summary!.medianHoursToActivate == nil, "missing median stays unknown")
        var changed = counts
        changed["activated_within_24h"] = "bad"
        changed["median_hours_to_activate"] = NSNull()
        let tolerant = try decode(["buckets": [changed], "summary": changed])
        check(tolerant.buckets![0].activatedWithin24h == 0, "malformed bucket field is tolerated")
        check(tolerant.summary!.activatedWithin24h == 0, "malformed summary field is tolerated")
        check(tolerant.buckets![0].activatedWithin7d == 4, "valid bucket 7d survives changed 24h")
        check(tolerant.summary!.activatedWithin7d == 4, "valid summary 7d survives changed 24h")
        check(tolerant.buckets![0].medianHoursToActivate == nil, "null bucket median stays unknown")
        check(tolerant.summary!.medianHoursToActivate == nil, "null summary median stays unknown")
        check(tolerant.buckets![0].orgs == 6 && tolerant.summary!.orgs == 6, "other counts survive")

        let empty = try decode(["buckets": [], "summary": ["orgs": 0, "orphan_orgs_excluded": 3]])
        check(empty.isEmpty && empty.bucketList.isEmpty, "empty denominator remains empty")
        check(empty.summary!.orphanOrgsExcluded == 3, "empty denominator does not erase excluded rows")
        do {
            _ = try AdminCohortTestDecoder.decode(AdminCohortReport.self, from: Data("not JSON".utf8))
            check(false, "invalid JSON must fail")
        } catch APIError.decoding {
            check(true, "actual request decoder preserves decoding error")
        }
        print("PASSED: \(assertions) actual cohort wire-decoding assertions; no network or customer data")
    }
}
