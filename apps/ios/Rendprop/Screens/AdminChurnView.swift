import SwiftUI
// URLSession / URLComponents / JSONDecoder are reached through
// `AdminReportRequest` (Screens/AdminCohortsView.swift); Foundation is still
// needed here for URLQueryItem and the decoders below.
import Foundation

// MARK: - Churn (owner console)
//
// Who cancelled, at which plan, and for which reason — against the same window
// immediately before, so the number means something on its own.
//
// Everything comes from `GET /admin/churn`, gated server-side by
// `profiles.is_admin`.
//
// THE `note` IS RENDERED VERBATIM. It carries two things that change what the
// total means: switching auto-renew OFF is counted as a cancellation even
// though that subscriber is still entitled until expiry, and the cancellation
// date only exists from 2026-09-12 onward, so a long window under-reports
// rather than reading zero. Hiding either would turn this screen into a reason
// to panic (or not to) about a number that does not say what it looks like.

// MARK: Wire models

struct AdminChurnCount: Sendable, Hashable, Identifiable {
    /// Plan slug or reason slug, exactly as the server sent it. Never invented
    /// here — "(unknown)" is the server's own word for a row it cannot label.
    var label: String = ""
    var count: Int = 0

    var id: String { label }

    /// "solo" → "Solo", "auto_renew_off" → "Auto renew off".
    var title: String {
        guard !label.isEmpty else { return "(unknown)" }
        let spaced = label.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

struct AdminChurnPrevious: Sendable, Hashable {
    var from: String? = nil
    var to: String? = nil
    var cancellations: Int = 0
    var byPlan: [AdminChurnCount] = []
    var byReason: [AdminChurnCount] = []
}

struct AdminChurnReport: Sendable, Hashable {
    var generatedAt: String? = nil
    var window: String? = nil
    var from: String? = nil
    var to: String? = nil
    var cancellations: Int = 0
    var byPlan: [AdminChurnCount] = []
    var byReason: [AdminChurnCount] = []
    /// Cancelled but still inside Apple's billing-grace period — not lost yet.
    var inGrace: Int = 0
    /// TestFlight / App Review testers. Counted apart, because a tester is not
    /// revenue and never was.
    var sandboxCancellations: Int = 0
    var previous: AdminChurnPrevious? = nil
    /// This window minus the one before it. Negative is good news.
    var deltaTotal: Int = 0
    /// The server's own caveat. Shown verbatim.
    var note: String? = nil
    /// Set by MockAPIClient only.
    var isSample: Bool? = nil

    var isEmpty: Bool { cancellations == 0 && sandboxCancellations == 0 }
}

// MARK: Hand-written decoding
//
// `by_plan` and `by_reason` are arrays of {plan|reason, count} — two different
// key names for one shape, so the row decodes both and keeps whichever is
// there. Everything is `decodeIfPresent` for the same reason as the funnel: a
// server that adds or drops a key must never blank this screen.

extension AdminChurnCount: Decodable {
    private enum CodingKeys: String, CodingKey {
        case plan, reason, count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let plan: String? = try? c.decodeIfPresent(String.self, forKey: .plan)
        let reason: String? = try? c.decodeIfPresent(String.self, forKey: .reason)
        label = plan ?? reason ?? ""
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
    }
}

extension AdminChurnPrevious: Decodable {
    private enum CodingKeys: String, CodingKey {
        case from, to, cancellations, byPlan, byReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        to = try? c.decodeIfPresent(String.self, forKey: .to)
        cancellations = (try? c.decodeIfPresent(Int.self, forKey: .cancellations)) ?? 0
        byPlan = (try? c.decodeIfPresent([AdminChurnCount].self, forKey: .byPlan)) ?? []
        byReason = (try? c.decodeIfPresent([AdminChurnCount].self, forKey: .byReason)) ?? []
    }
}

extension AdminChurnReport: Decodable {
    private enum CodingKeys: String, CodingKey {
        case generatedAt, window, from, to, cancellations, byPlan, byReason
        case inGrace, sandboxCancellations, previous, deltaTotal, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
        window = try? c.decodeIfPresent(String.self, forKey: .window)
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        to = try? c.decodeIfPresent(String.self, forKey: .to)
        cancellations = (try? c.decodeIfPresent(Int.self, forKey: .cancellations)) ?? 0
        byPlan = (try? c.decodeIfPresent([AdminChurnCount].self, forKey: .byPlan)) ?? []
        byReason = (try? c.decodeIfPresent([AdminChurnCount].self, forKey: .byReason)) ?? []
        inGrace = (try? c.decodeIfPresent(Int.self, forKey: .inGrace)) ?? 0
        sandboxCancellations = (try? c.decodeIfPresent(Int.self, forKey: .sandboxCancellations)) ?? 0
        previous = try? c.decodeIfPresent(AdminChurnPrevious.self, forKey: .previous)
        deltaTotal = (try? c.decodeIfPresent(Int.self, forKey: .deltaTotal)) ?? 0
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        // Never sent by the server — only MockAPIClient sets it.
        isSample = nil
    }
}

/// The one call this screen needs. Same pattern as `AdminFunnelAPI`.
protocol AdminChurnAPI {
    /// GET /admin/churn?window=7d|30d|90d
    func adminChurn(window: String) async throws -> AdminChurnReport
}

extension LiveAPIClient: AdminChurnAPI {
    func adminChurn(window: String) async throws -> AdminChurnReport {
        try await AdminReportRequest.get(
            path: ["admin", "churn"],
            query: [URLQueryItem(name: "window", value: window)])
    }
}

extension MockAPIClient: AdminChurnAPI {
    func adminChurn(window: String) async throws -> AdminChurnReport {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let scale: Int = window == "7d" ? 1 : (window == "90d" ? 9 : 3)

        var report = AdminChurnReport()
        report.window = window
        report.cancellations = 2 * scale
        report.byPlan = [
            AdminChurnCount(label: "solo", count: 1 * scale),
            AdminChurnCount(label: "pro", count: 1 * scale),
        ]
        report.byReason = [
            AdminChurnCount(label: "auto_renew_off", count: 1 * scale),
            AdminChurnCount(label: "expired", count: 1 * scale),
        ]
        report.inGrace = scale
        report.sandboxCancellations = 1
        var previous = AdminChurnPrevious()
        previous.cancellations = 3 * scale
        previous.byPlan = [AdminChurnCount(label: "solo", count: 3 * scale)]
        previous.byReason = [AdminChurnCount(label: "expired", count: 3 * scale)]
        report.previous = previous
        report.deltaTotal = report.cancellations - previous.cancellations
        report.note = "Sample numbers from the offline build. The live route sends its own note here, and that one states the real limits of these figures."
        report.isSample = true
        return report
    }
}

// MARK: - The screen

struct AdminChurnView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared

    @State private var window: ChurnWindow = .thirtyDays
    @State private var report: AdminChurnReport?
    @State private var state: AdminReportState?
    @State private var isLoading = false
    @State private var hasLoaded = false

    /// nil when this build's API client has no churn method yet.
    private var churnAPI: AdminChurnAPI? { model.api as? AdminChurnAPI }

    enum ChurnWindow: String, CaseIterable, Identifiable {
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
        var previousPhrase: String {
            switch self {
            case .sevenDays:  return "the 7 days before that"
            case .thirtyDays: return "the 30 days before that"
            case .ninetyDays: return "the 90 days before that"
            }
        }
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Churn")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: window) { _ in Task { await load() } }
        .onChange(of: auth.isSignedIn) { _ in Task { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if churnAPI == nil {
            plainSection(AdminReportState.unsupportedBuild, "churn")
        } else if let state {
            plainSection(state, "churn")
        } else {
            windowSection
            if let report {
                sampleBanner(report)
                headlineSection(report)
                breakdownSection("By plan", report.byPlan, empty: "No cancellations to break down.")
                breakdownSection("Why", report.byReason, empty: "No reasons to break down.")
                previousSection(report)
                noteSection(report)
            } else if isLoading || !hasLoaded {
                Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(Theme.inkDim) } }
            } else {
                Section {
                    Text("Nobody cancelled in \(window.phrase).")
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
                ForEach(ChurnWindow.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("Everything below covers \(window.phrase), compared with \(window.previousPhrase).")
        }
    }

    @ViewBuilder
    private func sampleBanner(_ report: AdminChurnReport) -> some View {
        if report.isSample == true {
            Section {
                Label("Sample numbers — this build is offline",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    private func headlineSection(_ report: AdminChurnReport) -> some View {
        Section {
            countRow("Cancellations", report.cancellations,
                     tint: report.cancellations > 0 ? Theme.warn : Theme.good,
                     icon: "person.crop.circle.badge.xmark")
            deltaRow(report)
            if report.inGrace > 0 {
                countRow("Still in billing grace", report.inGrace, tint: Theme.inkDim, icon: "clock.badge")
            }
            if report.sandboxCancellations > 0 {
                countRow("Test cancellations (sandbox)", report.sandboxCancellations,
                         tint: Theme.inkDim, icon: "testtube.2")
            }
        } header: {
            Text(window.phrase.prefix(1).uppercased() + window.phrase.dropFirst())
        } footer: {
            Text("A subscriber who cancelled and came back inside the window isn't counted — a win-back clears the cancellation. Sandbox testers are never in the main figure.")
        }
    }

    /// Fewer than last period is good news, and the row says so in words rather
    /// than leaving a reader to work out which direction a minus sign points.
    private func deltaRow(_ report: AdminChurnReport) -> some View {
        let delta = report.deltaTotal
        let previous = report.previous?.cancellations ?? 0
        let tint: Color = delta < 0 ? Theme.good : (delta > 0 ? Theme.warn : Theme.inkDim)
        let text: String
        if delta == 0 {
            text = "Same as \(window.previousPhrase) (\(previous.formatted()))"
        } else if delta < 0 {
            text = "\(abs(delta).formatted()) fewer than \(window.previousPhrase) (\(previous.formatted()))"
        } else {
            text = "\(delta.formatted()) more than \(window.previousPhrase) (\(previous.formatted()))"
        }
        return HStack(spacing: 12) {
            Image(systemName: delta < 0 ? "arrow.down.right" : (delta > 0 ? "arrow.up.right" : "equal"))
                .font(.rpBody).foregroundStyle(tint).frame(width: 24)
            Text(text).font(.rpBody).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func breakdownSection(_ title: String, _ rows: [AdminChurnCount], empty: String) -> some View {
        Section {
            if rows.isEmpty {
                Text(empty).font(.rpCaption).foregroundStyle(Theme.inkDim)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Text(row.title).font(.rpBody).foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Text(row.count.formatted()).font(.rpHeadline).foregroundStyle(Theme.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text(title)
        }
    }

    @ViewBuilder
    private func previousSection(_ report: AdminChurnReport) -> some View {
        if let previous = report.previous, previous.cancellations > 0 || !previous.byPlan.isEmpty {
            Section {
                countRow("Cancellations", previous.cancellations, tint: Theme.inkDim,
                         icon: "person.crop.circle.badge.xmark")
                ForEach(previous.byPlan) { row in
                    HStack(spacing: 12) {
                        Text(row.title).font(.rpBody).foregroundStyle(Theme.inkDim)
                        Spacer(minLength: 8)
                        Text(row.count.formatted()).font(.rpBody).foregroundStyle(Theme.inkDim)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(window.previousPhrase.prefix(1).uppercased() + window.previousPhrase.dropFirst())
            } footer: {
                Text("The same length of time, immediately before — so the comparison above is like for like.")
            }
        }
    }

    @ViewBuilder
    private func noteSection(_ report: AdminChurnReport) -> some View {
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

    private func load() async {
        guard let api = churnAPI else { hasLoaded = true; return }
        if Config.enableAuth && !auth.isSignedIn {
            state = .needsSignIn
            hasLoaded = true
            return
        }
        state = nil
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            report = try await api.adminChurn(window: window.rawValue)
            state = nil
        } catch is CancellationError {
            // The screen was left mid-load — coming back re-runs it.
        } catch {
            report = nil
            state = AdminReportState.from(error)
        }
    }
}
