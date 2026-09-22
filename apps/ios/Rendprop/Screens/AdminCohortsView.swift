import SwiftUI
// URLSession / URLComponents / JSONDecoder below: this file has no UIKit
// import, and SwiftUI is not documented to re-export Foundation.
import Foundation

// MARK: - Cohorts (owner console)
//
// The question `GET /admin/funnel` cannot answer, and says so on every
// response: the funnel counts DISTINCT DEVICES per step inside a window, so a
// person who signed up in July and published in September appears in neither
// number together. A cohort follows the same workspaces forward:
//
//   OF THE WORKSPACES THAT SIGNED UP IN A GIVEN WEEK — how many ever published
//   a tour, how many did it within seven days, how long the median one took,
//   and how many are paying right now.
//
// Everything comes from `GET /admin/cohorts`, gated server-side by
// `profiles.is_admin`. Nothing on this phone unlocks it.
//
// THE `note` IS RENDERED VERBATIM AND IS NOT OPTIONAL CHROME. It states what
// these numbers cannot see: orphan workspaces left behind by the anonymous
// handover, activation backfilled only from tours that are still published, a
// cancellation date that only exists from 2026-09-12. A report that implies
// more rigour than it has is how people talk themselves into bad ad spend.
//
// Same shape as AdminFunnelView by design — wire models with hand-written
// `init(from:)` in an extension (so `decodeIfPresent` everywhere keeps a
// changed server from blanking the screen, and the memberwise init survives for
// the mock), one protocol cast for at runtime, one plain List.

// MARK: Wire models

struct AdminCohortBucket: Sendable, Hashable, Identifiable {
    /// ISO date of the first day in the bucket ("2026-08-31").
    var bucketStart: String = ""
    var bucketEnd: String = ""
    /// The bucket is clipped by the window or still running, so its rates are
    /// not comparable with a whole one. The server decides this, not the app.
    var partial: Bool = false

    var orgs: Int = 0
    var activated: Int = 0
    var activatedWithin24h: Int = 0
    var activatedWithin7d: Int = 0
    /// Median over the workspaces that DID activate. nil when none did — which
    /// is not the same as zero and is never drawn as one.
    var medianHoursToActivate: Double? = nil
    var everPaid: Int = 0
    var everPaidSandbox: Int = 0
    var payingNow: Int = 0
    var churned: Int = 0

    var id: String { bucketStart.isEmpty ? bucketEnd : bucketStart }
}

struct AdminCohortSummary: Sendable, Hashable {
    var orgs: Int = 0
    var activated: Int = 0
    var activatedWithin24h: Int = 0
    var activatedWithin7d: Int = 0
    var medianHoursToActivate: Double? = nil
    var everPaid: Int = 0
    var everPaidSandbox: Int = 0
    var payingNow: Int = 0
    var churned: Int = 0
    /// Workspaces left out of the denominator entirely (an empty second
    /// workspace created by signing in with Apple). Shown, because a number
    /// quietly dropped is a number nobody can check.
    var orphanOrgsExcluded: Int = 0
}

struct AdminCohortReport: Sendable, Hashable {
    var generatedAt: String? = nil
    var window: String? = nil
    var bucket: String? = nil
    var from: String? = nil
    var to: String? = nil
    var buckets: [AdminCohortBucket]? = nil
    var summary: AdminCohortSummary? = nil
    /// The server's own statement of what these numbers cannot see. Verbatim.
    var note: String? = nil
    /// Set by MockAPIClient only.
    var isSample: Bool? = nil

    var bucketList: [AdminCohortBucket] { buckets ?? [] }
    var isEmpty: Bool { bucketList.allSatisfy { $0.orgs == 0 } }
}

// MARK: Hand-written decoding

extension AdminCohortBucket: Decodable {
    private enum CodingKeys: String, CodingKey {
        case bucketStart, bucketEnd, partial, orgs, activated
        case activatedWithin24h, activatedWithin7d, medianHoursToActivate
        case everPaid, everPaidSandbox, payingNow, churned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bucketStart = (try? c.decodeIfPresent(String.self, forKey: .bucketStart)) ?? ""
        bucketEnd = (try? c.decodeIfPresent(String.self, forKey: .bucketEnd)) ?? ""
        partial = (try? c.decodeIfPresent(Bool.self, forKey: .partial)) ?? false
        orgs = (try? c.decodeIfPresent(Int.self, forKey: .orgs)) ?? 0
        activated = (try? c.decodeIfPresent(Int.self, forKey: .activated)) ?? 0
        activatedWithin24h = (try? c.decodeIfPresent(Int.self, forKey: .activatedWithin24h)) ?? 0
        activatedWithin7d = (try? c.decodeIfPresent(Int.self, forKey: .activatedWithin7d)) ?? 0
        medianHoursToActivate = try? c.decodeIfPresent(Double.self, forKey: .medianHoursToActivate)
        everPaid = (try? c.decodeIfPresent(Int.self, forKey: .everPaid)) ?? 0
        everPaidSandbox = (try? c.decodeIfPresent(Int.self, forKey: .everPaidSandbox)) ?? 0
        payingNow = (try? c.decodeIfPresent(Int.self, forKey: .payingNow)) ?? 0
        churned = (try? c.decodeIfPresent(Int.self, forKey: .churned)) ?? 0
    }
}

extension AdminCohortSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case orgs, activated, activatedWithin24h, activatedWithin7d
        case medianHoursToActivate, everPaid, everPaidSandbox, payingNow, churned
        case orphanOrgsExcluded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orgs = (try? c.decodeIfPresent(Int.self, forKey: .orgs)) ?? 0
        activated = (try? c.decodeIfPresent(Int.self, forKey: .activated)) ?? 0
        activatedWithin24h = (try? c.decodeIfPresent(Int.self, forKey: .activatedWithin24h)) ?? 0
        activatedWithin7d = (try? c.decodeIfPresent(Int.self, forKey: .activatedWithin7d)) ?? 0
        medianHoursToActivate = try? c.decodeIfPresent(Double.self, forKey: .medianHoursToActivate)
        everPaid = (try? c.decodeIfPresent(Int.self, forKey: .everPaid)) ?? 0
        everPaidSandbox = (try? c.decodeIfPresent(Int.self, forKey: .everPaidSandbox)) ?? 0
        payingNow = (try? c.decodeIfPresent(Int.self, forKey: .payingNow)) ?? 0
        churned = (try? c.decodeIfPresent(Int.self, forKey: .churned)) ?? 0
        orphanOrgsExcluded = (try? c.decodeIfPresent(Int.self, forKey: .orphanOrgsExcluded)) ?? 0
    }
}

extension AdminCohortReport: Decodable {
    private enum CodingKeys: String, CodingKey {
        case generatedAt, window, bucket, from, to, buckets, summary, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
        window = try? c.decodeIfPresent(String.self, forKey: .window)
        bucket = try? c.decodeIfPresent(String.self, forKey: .bucket)
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        to = try? c.decodeIfPresent(String.self, forKey: .to)
        buckets = try? c.decodeIfPresent([AdminCohortBucket].self, forKey: .buckets)
        summary = try? c.decodeIfPresent(AdminCohortSummary.self, forKey: .summary)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        // Never sent by the server — only MockAPIClient sets it.
        isSample = nil
    }
}

/// The one call this screen needs. Same pattern as `AdminFunnelAPI`.
protocol AdminCohortsAPI {
    /// GET /admin/cohorts?window=30d|90d|180d|365d&bucket=day|week|month
    func adminCohorts(window: String, bucket: String) async throws -> AdminCohortReport
}

extension LiveAPIClient: AdminCohortsAPI {
    func adminCohorts(window: String, bucket: String) async throws -> AdminCohortReport {
        try await AdminReportRequest.get(
            path: ["admin", "cohorts"],
            query: [URLQueryItem(name: "window", value: window),
                    URLQueryItem(name: "bucket", value: bucket)])
    }
}

extension MockAPIClient: AdminCohortsAPI {
    /// Plausible offline numbers, clearly flagged. Shaped like a real cohort
    /// table — a recent week still filling up, older weeks with more paying
    /// workspaces — so the layout is exercised honestly.
    func adminCohorts(window: String, bucket: String) async throws -> AdminCohortReport {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let weeks: Int = window == "30d" ? 4 : (window == "180d" ? 12 : (window == "365d" ? 16 : 8))

        var buckets: [AdminCohortBucket] = []
        for i in 0..<weeks {
            let orgs: Int = 9 + (i * 5) % 17
            let activated: Int = max(0, orgs - 3 - (i % 4))
            let within7: Int = max(0, activated - (i % 3))
            let within24: Int = max(0, within7 - 2)
            let paying: Int = max(0, activated / 4)
            var row = AdminCohortBucket()
            row.bucketStart = String(format: "2026-07-%02d", (i % 28) + 1)
            row.bucketEnd = String(format: "2026-07-%02d", (i % 28) + 7)
            row.partial = (i == weeks - 1)
            row.orgs = orgs
            row.activated = activated
            row.activatedWithin24h = within24
            row.activatedWithin7d = within7
            row.medianHoursToActivate = activated > 0 ? Double(6 + (i * 3) % 40) : nil
            row.everPaid = paying + 1
            row.everPaidSandbox = 1
            row.payingNow = paying
            row.churned = i % 5 == 0 ? 1 : 0
            buckets.append(row)
        }

        var summary = AdminCohortSummary()
        summary.orgs = buckets.reduce(0) { $0 + $1.orgs }
        summary.activated = buckets.reduce(0) { $0 + $1.activated }
        summary.activatedWithin24h = buckets.reduce(0) { $0 + $1.activatedWithin24h }
        summary.activatedWithin7d = buckets.reduce(0) { $0 + $1.activatedWithin7d }
        summary.medianHoursToActivate = 21
        summary.everPaid = buckets.reduce(0) { $0 + $1.everPaid }
        summary.everPaidSandbox = buckets.reduce(0) { $0 + $1.everPaidSandbox }
        summary.payingNow = buckets.reduce(0) { $0 + $1.payingNow }
        summary.churned = buckets.reduce(0) { $0 + $1.churned }
        summary.orphanOrgsExcluded = 6

        var report = AdminCohortReport()
        report.window = window
        report.bucket = bucket
        report.buckets = buckets
        report.summary = summary
        report.note = "Sample numbers from the offline build. The live route sends its own note here, and that one states the real limits of these figures."
        report.isSample = true
        return report
    }
}

// MARK: - Shared request for the admin report routes
//
// `adminFunnel` in AdminFunnelView.swift predates this and keeps its own copy;
// the two routes added in 1.0.2 share one, rather than pasting the same
// retry-once-on-401 dance twice more.

enum AdminReportRequest {
    static func get<T: Decodable>(path: [String], query: [URLQueryItem]) async throws -> T {
        guard let base = Config.apiBaseURL else { throw APIError.notConfigured }
        var url = base
        for component in path { url.appendPathComponent(component) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let target = components?.url else { throw APIError.invalidURL }

        var request = URLRequest(url: target)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = await AuthStore.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        var (data, response) = try await URLSession.shared.data(for: request)
        guard var http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }

        // Mirrors LiveAPIClient.execute's retry-once-on-401 (audit finding 8):
        // the pre-flight refresh can still leave a stale token, and a GET is
        // always safe to repeat.
        if http.statusCode == 401, Config.enableAuth, AuthStore.shared.isSignedIn {
            let refreshed = await AuthStore.shared.forceRefresh()
            if refreshed, let fresh = AuthStore.storedAccessToken() {
                request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                (data, response) = try await URLSession.shared.data(for: request)
                guard let http2 = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
                http = http2
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            throw LiveAPIClient.serverError(status: http.statusCode, data: data)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }
}

/// The five states an admin report can be in that are NOT "here are the
/// numbers". Shared by both 1.0.2 console screens so they answer the same way.
enum AdminReportState: Equatable {
    case unsupportedBuild
    case needsSignIn
    case forbidden(String)
    /// The route is not deployed yet. NOT an error: a parallel deploy has not
    /// landed, the phone is fine, and there is nothing to retry differently.
    case notDeployed
    case failed(String)

    var title: String {
        switch self {
        case .unsupportedBuild: return "Not in this app build yet"
        case .needsSignIn:      return "Sign in first"
        case .forbidden:        return "Owner only"
        case .notDeployed:      return "Not available yet"
        case .failed:           return "Couldn't load it"
        }
    }

    func body(_ what: String) -> String {
        switch self {
        case .unsupportedBuild:
            return "This copy of the app can't ask the server for \(what). The next build can."
        case .needsSignIn:
            return "\(what.prefix(1).uppercased() + what.dropFirst()) lives on the server, so it needs your account."
        case .forbidden(let message):
            return message
        case .notDeployed:
            return "The server this app is talking to doesn't have \(what) yet. It appears here on its own once that ships — nothing to do on this phone."
        case .failed(let message):
            return message
        }
    }

    /// Map an APIError onto one of these. A 404 is "not deployed", never an
    /// error to apologise for.
    static func from(_ error: Error) -> AdminReportState {
        guard let api = error as? APIError else { return .failed("Pull down to try again.") }
        if api.isUnauthorized { return .needsSignIn }
        if api.isForbidden { return .forbidden(api.errorDescription ?? "This account isn't an owner account.") }
        if api.isNotFound { return .notDeployed }
        return .failed(api.errorDescription ?? "Pull down to try again.")
    }
}

// MARK: - The screen

struct AdminCohortsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared

    @State private var window: CohortWindow = .ninetyDays
    @State private var report: AdminCohortReport?
    @State private var state: AdminReportState?
    @State private var isLoading = false
    @State private var hasLoaded = false

    /// nil when this build's API client has no cohorts method yet.
    private var cohortsAPI: AdminCohortsAPI? { model.api as? AdminCohortsAPI }

    /// Weeks, always. The route also does day and month; a console whose rule
    /// is "so clean a child could use it" does not need three ways to slice the
    /// same table, and "signup week" is the unit every other growth
    /// conversation here already uses.
    private static let bucket = "week"

    enum CohortWindow: String, CaseIterable, Identifiable {
        case thirtyDays = "30d"
        case ninetyDays = "90d"
        case oneEightyDays = "180d"
        case oneYear = "365d"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .thirtyDays:    return "30d"
            case .ninetyDays:    return "90d"
            case .oneEightyDays: return "180d"
            case .oneYear:       return "1y"
            }
        }
        var phrase: String {
            switch self {
            case .thirtyDays:    return "the last 30 days"
            case .ninetyDays:    return "the last 90 days"
            case .oneEightyDays: return "the last 180 days"
            case .oneYear:       return "the last year"
            }
        }
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cohorts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: window) { _ in Task { await load() } }
        .onChange(of: auth.isSignedIn) { _ in Task { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if cohortsAPI == nil {
            plainSection(AdminReportState.unsupportedBuild, "cohorts")
        } else if let state {
            plainSection(state, "cohorts")
        } else {
            windowSection
            if let report {
                sampleBanner(report)
                summarySection(report)
                bucketsSection(report)
                noteSection(report)
            } else if isLoading || !hasLoaded {
                Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(Theme.inkDim) } }
            } else {
                Section {
                    Text("Nobody signed up in \(window.phrase).")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
            }
        }
    }

    private func plainSection(_ reportState: AdminReportState, _ what: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(reportState.title).font(.rpHeadline).foregroundStyle(Theme.ink)
                Text(reportState.body(what)).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private var windowSection: some View {
        Section {
            Picker("How far back", selection: $window) {
                ForEach(CohortWindow.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("Every row is one SIGNUP WEEK inside \(window.phrase), followed forward however long those workspaces took to act.")
        }
    }

    @ViewBuilder
    private func sampleBanner(_ report: AdminCohortReport) -> some View {
        if report.isSample == true {
            Section {
                Label("Sample numbers — this build is offline",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ report: AdminCohortReport) -> some View {
        if let s = report.summary {
            Section {
                countRow("Workspaces", s.orgs, tint: Theme.accent, icon: "building.2")
                countRow("Published a tour", s.activated,
                         tint: s.activated > 0 ? Theme.good : Theme.inkDim, icon: "checkmark.seal")
                countRow("Within 7 days", s.activatedWithin7d, tint: Theme.inkDim, icon: "calendar")
                medianRow(s.medianHoursToActivate)
                countRow("Paying now", s.payingNow,
                         tint: s.payingNow > 0 ? Theme.good : Theme.inkDim, icon: "creditcard")
                if s.orphanOrgsExcluded > 0 {
                    countRow("Left out (empty workspaces)", s.orphanOrgsExcluded,
                             tint: Theme.inkDim, icon: "tray")
                }
            } header: {
                Text("Everyone in \(window.phrase)")
            } footer: {
                Text("\"Published a tour\" counts a workspace that ever did, at any time after signing up. Paying now comes from subscriptions Apple verified, so a phone can't inflate it.")
            }
        }
    }

    @ViewBuilder
    private func bucketsSection(_ report: AdminCohortReport) -> some View {
        let rows = report.bucketList
        Section {
            if rows.isEmpty || report.isEmpty {
                Text("No one signed up in \(window.phrase).")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            } else {
                ForEach(rows) { row in
                    CohortBucketRow(bucket: row)
                }
            }
        } header: {
            Text("Week by week")
        } footer: {
            Text("A week marked \"still filling up\" is clipped by the window or hasn't finished, so its shares aren't comparable with a whole one.")
        }
    }

    @ViewBuilder
    private func noteSection(_ report: AdminCohortReport) -> some View {
        if let note = report.note, !note.isEmpty {
            Section {
                Text(note)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What these numbers can't see")
            }
        }
    }

    private func countRow(_ title: String, _ value: Int, tint: Color, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.rpBody).foregroundStyle(tint).frame(width: 24)
            Text(title).font(.rpBody).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Text(value.formatted()).font(.rpHeadline).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private func medianRow(_ hours: Double?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock").font(.rpBody).foregroundStyle(Theme.inkDim).frame(width: 24)
            Text("Typical time to first tour").font(.rpBody).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Text(AdminCohortsView.hoursLabel(hours))
                .font(.rpHeadline)
                .foregroundStyle(hours == nil ? Theme.inkDim : Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    /// "—" when nobody activated. Dividing by nobody is not zero hours, and a
    /// zero here would read as "instantly", which is the opposite of the truth.
    static func hoursLabel(_ hours: Double?) -> String {
        guard let hours, hours.isFinite, hours >= 0 else { return "—" }
        if hours < 1 { return "under an hour" }
        if hours < 48 { return "\(Int(hours.rounded())) h" }
        let days = hours / 24
        return days < 10 ? String(format: "%.1f days", days) : "\(Int(days.rounded())) days"
    }

    private func load() async {
        guard let api = cohortsAPI else { hasLoaded = true; return }
        if Config.enableAuth && !auth.isSignedIn {
            state = .needsSignIn
            hasLoaded = true
            return
        }
        state = nil
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            report = try await api.adminCohorts(window: window.rawValue, bucket: Self.bucket)
            state = nil
        } catch is CancellationError {
            // The screen was left mid-load — coming back re-runs it.
        } catch {
            report = nil
            state = AdminReportState.from(error)
        }
    }
}

// MARK: One signup week

private struct CohortBucketRow: View {
    let bucket: AdminCohortBucket

    /// Share of the week's workspaces that ever published. Blank when the week
    /// had nobody in it — "nobody arrived" and "nobody converted" are different
    /// facts.
    private var activatedShare: String {
        guard bucket.orgs > 0 else { return "" }
        let pct = Double(bucket.activated) / Double(bucket.orgs) * 100
        return pct >= 10 ? "\(Int(pct.rounded()))%" : String(format: "%.1f%%", pct)
    }

    private var fraction: CGFloat {
        guard bucket.orgs > 0 else { return 0 }
        return min(1, max(0, CGFloat(bucket.activated) / CGFloat(bucket.orgs)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.bucketStart.isEmpty ? "—" : bucket.bucketStart)
                    .font(.rpBody).foregroundStyle(Theme.ink)
                if bucket.partial {
                    Text("still filling up")
                        .font(.rpCaption).foregroundStyle(Theme.warn)
                }
                Spacer(minLength: 8)
                Text("\(bucket.orgs.formatted()) signed up")
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fillSubtle)
                    Capsule().fill(Theme.accent)
                        .frame(width: max(fraction * geo.size.width, bucket.activated > 0 ? 4 : 0))
                }
            }
            .frame(height: 6)
            Text(detailLine)
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Week of \(bucket.bucketStart): \(bucket.orgs) signed up, \(bucket.activated) published a tour, \(bucket.payingNow) paying now")
    }

    private var detailLine: String {
        var parts: [String] = []
        if activatedShare.isEmpty {
            parts.append("\(bucket.activated) published a tour")
        } else {
            parts.append("\(bucket.activated) published a tour (\(activatedShare))")
        }
        parts.append("\(bucket.activatedWithin7d) within 7 days")
        parts.append("typically \(AdminCohortsView.hoursLabel(bucket.medianHoursToActivate))")
        parts.append("\(bucket.payingNow) paying now")
        return parts.joined(separator: " · ")
    }
}
