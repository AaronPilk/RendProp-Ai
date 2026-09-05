import SwiftUI
// URLSession / URLComponents / JSONDecoder below: this file has no UIKit
// import, and SwiftUI is not documented to re-export Foundation.
import Foundation

// MARK: - Funnel (owner console)
//
// The screen the owner watches while Meta ads are running. It answers two
// questions and refuses to answer any others:
//
//   WHERE DO PEOPLE STOP?   Eight steps, biggest first, each with a count and a
//                           bar as wide as its share of step one.
//   IS THE APP BREAKING?    Crashes and errors, on their own line, in plain red
//                           when there are any.
//
// Everything comes from `GET /admin/funnel`, which is gated server-side by
// `profiles.is_admin` (migration 0017). Nothing on this phone unlocks it.
//
// UX rule from the owner: "so clean and easy to understand a child could use
// it". So: no percentages of percentages, no jargon, no chart library, no
// legend. One sentence under the numbers says what they mean and where they
// are approximate — a funnel that implies more rigour than it has is how
// people talk themselves into bad ad spend.

// MARK: Wire models
//
// Decoded with `.convertFromSnakeCase`, so `pct_of_previous` → `pctOfPrevious`.
//
// Each `init(from:)` is written out by hand, in an EXTENSION, for two reasons
// that are easy to get wrong:
//
//   • Swift's SYNTHESIZED Decodable does not fall back to a property's default
//     when the key is missing — a non-optional `var count: Int = 0` still
//     throws `keyNotFound`. Every field here is `decodeIfPresent`, so a server
//     that adds or drops a key can never blank this screen.
//   • Putting the initializer in an extension keeps the memberwise `init`,
//     which is what `MockAPIClient` builds its sample report with.

struct AdminFunnelStep: Sendable, Hashable, Identifiable {
    var name: String = ""
    /// The server's own plain-words label ("Added a home"). Rendered verbatim,
    /// so the phone and the console can never disagree about what a step is.
    var label: String? = nil
    var count: Int = 0
    /// Share of the step ABOVE. Null when that step had nobody in it — "nobody
    /// got here" and "nobody converted" are different facts.
    var pctOfPrevious: Double? = nil
    /// Share of step one. This is what the bar width uses.
    var pctOfFirst: Double? = nil

    var id: String { name }
    var title: String { label ?? name.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct AdminFunnelDay: Sendable, Hashable, Identifiable {
    var day: String = ""
    var opens: Int = 0
    var signups: Int = 0
    var purchases: Int = 0
    var crashes: Int = 0

    var id: String { day }
}

struct AdminFunnelReport: Sendable, Hashable {
    var generatedAt: String? = nil
    var window: String? = nil
    var from: String? = nil
    var to: String? = nil
    var steps: [AdminFunnelStep]? = nil
    var crashes: Int? = nil
    var errors: Int? = nil
    var activeDevices: Int? = nil
    var sessions: Int? = nil
    var events: Int? = nil
    var byDay: [AdminFunnelDay]? = nil
    /// The server's own caveat about what the numbers mean. Shown verbatim.
    var note: String? = nil
    /// Subscriptions the server actually verified with Apple in the window —
    /// the one purchase number no phone can fake (migration 0021). nil on a
    /// server that predates it.
    var purchasesVerified: Int? = nil
    /// Verified subscriptions from Sandbox (TestFlight / sandbox testers).
    var purchasesVerifiedSandbox: Int? = nil
    /// Set by MockAPIClient only. Draws the "sample numbers" banner so nobody
    /// mistakes offline dev data for real customers.
    var isSample: Bool? = nil

    var stepList: [AdminFunnelStep] { steps ?? [] }
    var dayList: [AdminFunnelDay] { byDay ?? [] }
    var crashCount: Int { crashes ?? 0 }
    var errorCount: Int { errors ?? 0 }
    var verifiedPurchaseCount: Int { purchasesVerified ?? 0 }
    var sandboxPurchaseCount: Int { purchasesVerifiedSandbox ?? 0 }
    var deviceCount: Int { activeDevices ?? 0 }
    var sessionCount: Int { sessions ?? 0 }
    var isEmpty: Bool { stepList.allSatisfy { $0.count == 0 } }
}

// MARK: Hand-written decoding (see the note above the models)

extension AdminFunnelStep: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name, label, count, pctOfPrevious, pctOfFirst
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
        pctOfPrevious = try? c.decodeIfPresent(Double.self, forKey: .pctOfPrevious)
        pctOfFirst = try? c.decodeIfPresent(Double.self, forKey: .pctOfFirst)
    }
}

extension AdminFunnelDay: Decodable {
    private enum CodingKeys: String, CodingKey {
        case day, opens, signups, purchases, crashes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        opens = (try? c.decodeIfPresent(Int.self, forKey: .opens)) ?? 0
        signups = (try? c.decodeIfPresent(Int.self, forKey: .signups)) ?? 0
        purchases = (try? c.decodeIfPresent(Int.self, forKey: .purchases)) ?? 0
        crashes = (try? c.decodeIfPresent(Int.self, forKey: .crashes)) ?? 0
    }
}

extension AdminFunnelReport: Decodable {
    private enum CodingKeys: String, CodingKey {
        case generatedAt, window, from, to, steps, crashes, errors
        case activeDevices, sessions, events, byDay, note
        case purchasesVerified, purchasesVerifiedSandbox
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
        window = try? c.decodeIfPresent(String.self, forKey: .window)
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        to = try? c.decodeIfPresent(String.self, forKey: .to)
        steps = try? c.decodeIfPresent([AdminFunnelStep].self, forKey: .steps)
        crashes = try? c.decodeIfPresent(Int.self, forKey: .crashes)
        errors = try? c.decodeIfPresent(Int.self, forKey: .errors)
        activeDevices = try? c.decodeIfPresent(Int.self, forKey: .activeDevices)
        sessions = try? c.decodeIfPresent(Int.self, forKey: .sessions)
        events = try? c.decodeIfPresent(Int.self, forKey: .events)
        byDay = try? c.decodeIfPresent([AdminFunnelDay].self, forKey: .byDay)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        purchasesVerified = try? c.decodeIfPresent(Int.self, forKey: .purchasesVerified)
        purchasesVerifiedSandbox = try? c.decodeIfPresent(Int.self, forKey: .purchasesVerifiedSandbox)
        // Never sent by the server — only MockAPIClient sets it.
        isSample = nil
    }
}

/// The one call this screen needs. Declared here and cast for at runtime — the
/// pattern the repo uses for every added API surface (`AdminRoutingAPI` in
/// SettingsView.swift). No conformance → the screen says so plainly instead of
/// pretending.
protocol AdminFunnelAPI {
    /// GET /admin/funnel?window=7d|30d|90d
    func adminFunnel(window: String) async throws -> AdminFunnelReport
}

extension LiveAPIClient: AdminFunnelAPI {
    func adminFunnel(window: String) async throws -> AdminFunnelReport {
        guard let base = Config.apiBaseURL else { throw APIError.notConfigured }
        var components = URLComponents(
            url: base.appendingPathComponent("admin").appendingPathComponent("funnel"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "window", value: window)]
        guard let url = components?.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = await AuthStore.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveAPIClient.serverError(status: http.statusCode, data: data)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(AdminFunnelReport.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }
}

extension MockAPIClient: AdminFunnelAPI {
    /// Plausible offline numbers, clearly flagged as a sample. Shaped like a
    /// real funnel — a big drop at sign-up, a smaller one at the paywall — so
    /// the layout is exercised honestly.
    func adminFunnel(window: String) async throws -> AdminFunnelReport {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let scale: Int = window == "7d" ? 1 : (window == "90d" ? 11 : 4)
        let opens: Int = 212 * scale
        let signups: Int = 84 * scale
        let homes: Int = 61 * scale
        let captures: Int = 44 * scale
        let renders: Int = 39 * scale
        let published: Int = 31 * scale
        let paywall: Int = 22 * scale
        let bought: Int = 7 * scale

        // Every step is its own statement with explicit types. The one-shot
        // array literal of eight nested calls plus closure arithmetic that used
        // to live here is exactly the shape that timed out the type-checker on
        // the Mac (2026-09-05) — keep it flat.
        var steps: [AdminFunnelStep] = []
        steps.append(Self.sampleStep("app_open", "Opened the app", opens, opens, nil))
        steps.append(Self.sampleStep("signup", "Signed up", signups, opens, opens))
        steps.append(Self.sampleStep("home_created", "Added a home", homes, opens, signups))
        steps.append(Self.sampleStep("capture_finished", "Finished a walkthrough", captures, opens, homes))
        steps.append(Self.sampleStep("render_finished", "Tour rendered", renders, opens, captures))
        steps.append(Self.sampleStep("tour_published", "Tour published", published, opens, renders))
        steps.append(Self.sampleStep("paywall_viewed", "Saw plans", paywall, opens, published))
        steps.append(Self.sampleStep("purchase_completed", "Subscribed", bought, opens, paywall))

        var days: [AdminFunnelDay] = []
        let dayCount: Int = min(14, 7 * scale)
        for i in 0..<dayCount {
            let dayNumber: Int = (i % 28) + 1
            let dayOpens: Int = 18 + (i * 7) % 26
            let daySignups: Int = 4 + (i * 3) % 9
            let dayPurchases: Int = (i % 4 == 0) ? 1 : 0
            let dayCrashes: Int = (i % 5 == 0) ? 1 : 0
            days.append(AdminFunnelDay(day: String(format: "2026-09-%02d", dayNumber),
                                       opens: dayOpens, signups: daySignups,
                                       purchases: dayPurchases, crashes: dayCrashes))
        }

        var report = AdminFunnelReport()
        report.window = window
        report.steps = steps
        report.crashes = 2 * scale
        report.errors = 6 * scale
        report.activeDevices = opens
        report.sessions = 390 * scale
        report.events = 4_100 * scale
        report.byDay = days
        report.purchasesVerified = max(0, bought - 1)
        report.purchasesVerifiedSandbox = 1
        report.isSample = true
        return report
    }

    /// One sample funnel step. `pct` values are rounded to one decimal, the
    /// way the server rounds them.
    private static func sampleStep(_ name: String, _ label: String, _ count: Int,
                                   _ first: Int, _ previous: Int?) -> AdminFunnelStep {
        let pctPrev: Double? = Self.samplePct(count, over: previous)
        let pctFirst: Double? = Self.samplePct(count, over: first)
        return AdminFunnelStep(name: name, label: label, count: count,
                               pctOfPrevious: pctPrev, pctOfFirst: pctFirst)
    }

    private static func samplePct(_ count: Int, over base: Int?) -> Double? {
        guard let base, base > 0 else { return nil }
        let ratio: Double = Double(count) / Double(base)
        return (ratio * 1000.0).rounded() / 10.0
    }
}

// MARK: - The screen

struct AdminFunnelView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared

    @State private var window: FunnelWindow = .thirtyDays
    @State private var report: AdminFunnelReport?
    @State private var loadError: String?
    @State private var forbiddenMessage: String?
    @State private var needsSignIn = false
    @State private var isLoading = false
    @State private var hasLoaded = false

    /// nil when this build's API client has no funnel method yet. The screen
    /// then says so instead of showing an empty chart.
    private var funnelAPI: AdminFunnelAPI? { model.api as? AdminFunnelAPI }

    enum FunnelWindow: String, CaseIterable, Identifiable {
        case sevenDays = "7d"
        case thirtyDays = "30d"
        case ninetyDays = "90d"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .sevenDays:  return "7 days"
            case .thirtyDays: return "30 days"
            case .ninetyDays: return "90 days"
            }
        }
        var phrase: String {
            switch self {
            case .sevenDays:  return "the last 7 days"
            case .thirtyDays: return "the last 30 days"
            case .ninetyDays: return "the last 90 days"
            }
        }
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Funnel")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: window) { _ in Task { await load() } }
        .onChange(of: auth.isSignedIn) { _ in Task { await load() } }
    }

    // MARK: State routing

    @ViewBuilder
    private var content: some View {
        if funnelAPI == nil {
            plainSection("Not in this app build yet",
                         "This copy of the app can't ask the server for the funnel. The next build can.")
        } else if needsSignIn {
            plainSection("Sign in first",
                         "The funnel lives on the server, so it needs your account.")
        } else if let forbiddenMessage {
            plainSection("Owner only", forbiddenMessage)
        } else {
            windowSection
            if let report {
                sampleBanner(report)
                stepsSection(report)
                moneySection(report)
                stabilitySection(report)
                reachSection(report)
                trendSection(report)
                noteSection(report)
            } else if let loadError {
                plainSection("Couldn't load it", loadError)
            } else if isLoading || !hasLoaded {
                Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(Theme.inkDim) } }
            } else {
                plainSection("Nothing yet", "No one has used the app in \(window.phrase).")
            }
        }
    }

    private func plainSection(_ title: String, _ body: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.rpHeadline).foregroundStyle(Theme.ink)
                Text(body).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Window

    private var windowSection: some View {
        Section {
            Picker("How far back", selection: $window) {
                ForEach(FunnelWindow.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("Everything below covers \(window.phrase).")
        }
    }

    @ViewBuilder
    private func sampleBanner(_ report: AdminFunnelReport) -> some View {
        if report.isSample == true {
            Section {
                Label("Sample numbers — this build is offline",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    // MARK: The funnel itself

    @ViewBuilder
    private func stepsSection(_ report: AdminFunnelReport) -> some View {
        let steps = report.stepList
        let top = max(steps.first?.count ?? 0, 1)
        Section {
            if report.isEmpty {
                Text("No one has done any of these yet.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            } else {
                ForEach(steps) { step in
                    FunnelStepRow(step: step, top: top)
                }
            }
        } header: {
            Text("What people did")
        } footer: {
            Text("The bar shows how many got this far compared with everyone who opened the app.")
        }
    }

    // MARK: Money — the number Apple confirmed, not the one the phone reported

    private func moneySection(_ report: AdminFunnelReport) -> some View {
        Section {
            countRow("Paid subscriptions", report.verifiedPurchaseCount,
                     tint: report.verifiedPurchaseCount > 0 ? Theme.good : Theme.inkDim,
                     icon: "checkmark.seal.fill")
            if report.sandboxPurchaseCount > 0 {
                countRow("Test purchases (sandbox)", report.sandboxPurchaseCount,
                         tint: Theme.inkDim, icon: "testtube.2")
            }
        } header: {
            Text("Money")
        } footer: {
            Text("Counted from subscriptions Apple verified with this server, so a phone can't inflate it. \"Subscribed\" above is what phones reported.")
        }
    }

    // MARK: Stability

    private func stabilitySection(_ report: AdminFunnelReport) -> some View {
        Section {
            countRow("Crashes", report.crashCount,
                     tint: report.crashCount > 0 ? Theme.bad : Theme.good,
                     icon: "exclamationmark.octagon.fill")
            countRow("Errors", report.errorCount,
                     tint: report.errorCount > 0 ? Theme.warn : Theme.good,
                     icon: "exclamationmark.triangle.fill")
        } header: {
            Text("Is it breaking?")
        } footer: {
            Text("Crashes come from iPhone's own reports and can take a day to arrive. Zero is what you want.")
        }
    }

    private func reachSection(_ report: AdminFunnelReport) -> some View {
        Section {
            countRow("Phones", report.deviceCount, tint: Theme.accent, icon: "iphone")
            countRow("Visits", report.sessionCount, tint: Theme.accent, icon: "clock.arrow.circlepath")
        } header: {
            Text("How many people")
        } footer: {
            Text("A phone is counted once no matter how often it comes back. A visit is one stretch of use.")
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

    // MARK: Day-by-day

    @ViewBuilder
    private func trendSection(_ report: AdminFunnelReport) -> some View {
        let days = report.dayList
        if days.count >= 2 {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Sparkline(values: days.map { Double($0.opens) })
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(height: 44)
                        .accessibilityLabel("Opens per day")
                    HStack {
                        Text(days.first?.day ?? "")
                        Spacer()
                        Text(days.last?.day ?? "")
                    }
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Day by day")
            } footer: {
                Text("How many phones opened the app each day.")
            }
        }
    }

    @ViewBuilder
    private func noteSection(_ report: AdminFunnelReport) -> some View {
        if let note = report.note, !note.isEmpty {
            Section {
                Text(note)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Loading

    private func load() async {
        guard let api = funnelAPI else { hasLoaded = true; return }
        if Config.enableAuth && !auth.isSignedIn {
            needsSignIn = true
            hasLoaded = true
            return
        }
        needsSignIn = false
        isLoading = true
        defer { isLoading = false; hasLoaded = true }

        do {
            let fresh = try await api.adminFunnel(window: window.rawValue)
            report = fresh
            loadError = nil
            forbiddenMessage = nil
        } catch let error as APIError {
            if error.isUnauthorized {
                needsSignIn = true
            } else if error.isForbidden {
                forbiddenMessage = error.errorDescription ?? "This account isn't an owner account."
            } else {
                loadError = error.errorDescription ?? "Pull down to try again."
            }
        } catch {
            loadError = "Pull down to try again."
        }
    }
}

// MARK: One step

private struct FunnelStepRow: View {
    let step: AdminFunnelStep
    /// The first step's count — every bar is drawn against this.
    let top: Int

    private var fraction: CGFloat {
        guard top > 0 else { return 0 }
        return min(1, max(0, CGFloat(step.count) / CGFloat(top)))
    }

    /// "68% of the step above". Blank when the step above had nobody in it —
    /// dividing by nothing is not 0%.
    private var dropCaption: String {
        guard let pct = step.pctOfPrevious else { return "" }
        return "\(Self.percent(pct)) of the step above"
    }

    private static func percent(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))%" : String(format: "%.1f%%", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title).font(.rpBody).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(step.count.formatted()).font(.rpHeadline).foregroundStyle(Theme.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fillSubtle)
                    Capsule().fill(Theme.accent)
                        .frame(width: max(fraction * geo.size.width, step.count > 0 ? 4 : 0))
                }
            }
            .frame(height: 6)
            if !dropCaption.isEmpty {
                Text(dropCaption).font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title): \(step.count)")
    }
}

// MARK: Sparkline
//
// One `Path`, no library. Flat when every value is the same (rather than
// dividing by a zero range and drawing nothing).

private struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }

        let lowest = values.min() ?? 0
        let highest = values.max() ?? 0
        let span = highest - lowest
        let stepX = rect.width / CGFloat(values.count - 1)

        for (index, value) in values.enumerated() {
            let ratio = span > 0 ? (value - lowest) / span : 0.5
            let point = CGPoint(x: rect.minX + CGFloat(index) * stepX,
                                y: rect.maxY - CGFloat(ratio) * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
