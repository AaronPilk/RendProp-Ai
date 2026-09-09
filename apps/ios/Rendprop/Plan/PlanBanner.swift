import SwiftUI

// The one line on Home that says which plan you are on.
//
// WHY IT EXISTS. Two complaints, one cause. "Most people would not know they
// are on a free trial" — nothing in the app said so; the only mention of it was
// a Settings row four taps away. And a paying agent had no way to tell at a
// glance that they were paying. A plan is state, and state the user cannot see
// is state they do not believe in.
//
// WHEN IT ASKS FOR MONEY, which is the part that has to be got right:
//   * On the free week — never. It says what they have and how long is left.
//     Nagging someone on day one of a trial is how you lose day two.
//   * On the last two days, and after the week ends — yes, once, quietly, in
//     the banner they are already looking at. No modal, no interruption.
//   * On a paid plan — never again. It becomes a badge and nothing else.
//
// It routes to the StoreKit paywall and NOWHERE else (App Store 3.1.1). There
// is no web page to send anyone to and there must never be one.
//
// It renders NOTHING until it knows, and nothing at all if the call fails: an
// empty space is better than a wrong claim about somebody's money.

struct PlanBanner: View {
    @StateObject private var loader = Loader()
    @State private var showPaywall = false

    var body: some View {
        // Group, so the hidden case is a true EmptyView: Home stacks its
        // sections with spacing 26, and any real view here — even zero-height —
        // would leave a 26pt hole when there is nothing to say.
        Group {
            if let state = loader.state {
                Button {
                    if state.offersUpgrade { showPaywall = true }
                } label: {
                    banner(state)
                }
                .buttonStyle(.plain)
                .disabled(!state.offersUpgrade)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: loader.state?.kind)
        .sheet(isPresented: $showPaywall) {
            PaywallView(reason: loader.state?.kind == .ended ? .trialEnded : .upgrade)
        }
    }

    /// Holds the fetch, because the view's own body cannot.
    ///
    /// A @StateObject is constructed the first time SwiftUI renders the view,
    /// whether or not that render produces any views at all — which is the
    /// whole point here. `.task` on the Group above did NOT run, because the
    /// Group was an EmptyView until the state it was waiting for arrived.
    @MainActor
    final class Loader: ObservableObject {
        @Published var state: PlanState?
        private var started = false

        init() { start() }

        func start() {
            guard !started else { return }
            started = true
            Task { [weak self] in await self?.load() }
        }

        private func load() async {
            // A launch argument can only come from Xcode or `xcodebuild test`,
            // and Config.uiTestPlanBanner is nil unless -uiTesting is present
            // too — the same fence every other override in Config.swift uses.
            //
            // NOT behind `#if DEBUG`: this project defines
            // SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG in exactly one build
            // configuration, so a #if DEBUG block here compiled out of the very
            // build the UI walk runs.
            if let forced = Config.uiTestPlanBanner {
                let day: TimeInterval = 86_400
                let iso = ISO8601DateFormatter()
                switch forced {
                case "trial":  state = PlanBanner.state(plan: "trial", trialEndsAt: iso.string(from: Date().addingTimeInterval(5 * day)), now: Date())
                case "ending": state = PlanBanner.state(plan: "trial", trialEndsAt: iso.string(from: Date().addingTimeInterval(1.5 * day)), now: Date())
                case "ended":  state = PlanBanner.state(plan: "free", trialEndsAt: nil, now: Date())
                case "paid":   state = PlanBanner.state(plan: "pro", trialEndsAt: nil, now: Date())
                default:       state = nil
                }
                return
            }

            guard Config.useLiveBackend, let base = Config.apiBaseURL,
                  let token = await AuthStore.validAccessToken() else { return }
            var req = URLRequest(url: base.appendingPathComponent("me"))
            req.timeoutInterval = 20
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return }                      // stay silent rather than guess
            let d = JSONDecoder()
            // convertFromSnakeCase and explicit CodingKeys are mutually
            // exclusive — MeSlice declares none, so `trial_ends_at` maps.
            d.keyDecodingStrategy = .convertFromSnakeCase
            guard let me = try? d.decode(MeSlice.self, from: data) else { return }
            state = PlanBanner.state(plan: me.plan, trialEndsAt: me.trialEndsAt, now: Date())
        }
    }

    /// Only the two fields this banner needs. A narrow shape cannot break when
    /// /me grows a field.
    private struct MeSlice: Decodable {
        let plan: String?
        let trialEndsAt: String?
    }

    @ViewBuilder
    private func banner(_ s: PlanState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(s.tint)
                .frame(width: 30, height: 30)
                .background(s.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(s.title)
                    .font(.rpHeadline)
                    .foregroundStyle(Theme.ink)
                Text(s.detail)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            if s.offersUpgrade {
                Text("See plans")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(s.offersUpgrade ? s.tint.opacity(0.45) : Theme.border))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.planBanner")
        .accessibilityLabel("\(s.title). \(s.detail)")
        .accessibilityAddTraits(s.offersUpgrade ? .isButton : [])
    }

    // MARK: - State

    enum Kind: Equatable { case trial, endingSoon, ended, paid }

    struct PlanState: Equatable {
        let kind: Kind
        let title: String
        let detail: String

        var isWorthShowing: Bool { true }
        /// Only the two ends of the funnel ask. The middle of a good trial does
        /// not, and a paying customer never does.
        var offersUpgrade: Bool { kind == .endingSoon || kind == .ended }

        var icon: String {
            switch kind {
            case .trial, .endingSoon: return "gift"
            case .ended:              return "clock.badge.exclamationmark"
            case .paid:               return "checkmark.seal.fill"
            }
        }
        var tint: Color {
            switch kind {
            case .trial:      return Theme.accent
            case .endingSoon: return Theme.warn
            case .ended:      return Theme.warn
            case .paid:       return Theme.accent
            }
        }
    }

    /// Pure, so the copy can be tested without a network.
    static func state(plan: String?, trialEndsAt: String?, now: Date) -> PlanState? {
        switch (plan ?? "").lowercased() {
        case "pro":              return PlanState(kind: .paid, title: "Pro", detail: "25 tours a month, 300 photo edits, 20 reel clips.")
        case "team":             return PlanState(kind: .paid, title: "Team", detail: "Your whole workspace, on the Team plan.")
        case "starter", "solo":  return PlanState(kind: .paid, title: "Starter", detail: "8 tours a month, 150 photo edits, 8 reel clips.")
        case "free":
            return PlanState(kind: .ended,
                             title: "Your free week has ended",
                             detail: "You're on the free plan — one tour a month. Your homes and tours are all still here.")
        case "trial":
            let days = daysLeft(trialEndsAt, now: now)
            guard let days else {
                return PlanState(kind: .trial, title: "Your first week is on us",
                                 detail: "3 tours, 60 photo edits and 4 reel clips, free.")
            }
            if days <= 0 {
                return PlanState(kind: .ended, title: "Your free week has ended",
                                 detail: "You're on the free plan — one tour a month. Your homes and tours are all still here.")
            }
            if days <= 2 {
                return PlanState(kind: .endingSoon,
                                 title: days == 1 ? "Last day of your free week" : "\(days) days left of your free week",
                                 detail: "After that it's the free plan — one tour a month.")
            }
            return PlanState(kind: .trial,
                             title: "Your first week is on us",
                             detail: "3 tours, 60 photo edits and 4 reel clips — \(days) days left.")
        default:
            return nil          // unknown plan: say nothing at all
        }
    }

    static func daysLeft(_ raw: String?, now: Date) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let end = withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let end else { return nil }
        // Round UP: with 18 hours to go a person has "1 day left", not zero.
        let seconds = end.timeIntervalSince(now)
        if seconds <= 0 { return 0 }
        return max(1, Int(ceil(seconds / 86_400)))
    }
}
