import SwiftUI
import Combine
import UIKit

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
        private var bag = Set<AnyCancellable>()
        private var foreground: NSObjectProtocol?
        private var inFlight = false

        init() {
            // AuthStore's own publisher, which fires IMMEDIATELY with the
            // current value and again every time the session changes — the
            // anonymous bootstrap landing, a Sign in with Apple, a sign-out.
            // That is what the first version got wrong: it loaded once, at the
            // moment Home first rendered, which on a cold launch is before the
            // anonymous session exists. There was no token, it returned, and it
            // never looked again. Settings showed the plan because its `.task`
            // runs later; Home showed nothing, for the rest of the session.
            AuthStore.shared.$isSignedIn
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor in await self?.refresh() } }
                .store(in: &bag)

            // A plan can change while the app is backgrounded — a purchase on
            // another device, a trial expiring overnight.
            foreground = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        }

        deinit {
            if let foreground { NotificationCenter.default.removeObserver(foreground) }
        }

        func refresh() async {
            guard !inFlight else { return }
            inFlight = true
            defer { inFlight = false }
            await load()
        }

        private func load() async {
            if let forced = Config.uiTestPlanBanner {
                let day: TimeInterval = 86_400
                let iso = ISO8601DateFormatter()
                // Fixed numbers, so the screenshot is the same on every run:
                // the real-estate free week for the trial states, and the Pro
                // literals from Products.swift for the paid one.
                let week = Allowances(renders: 3, photoEdits: 60, reels: 4)
                let pro = RendpropPlan.pro.allowances
                let paid = Allowances(renders: pro.renders, photoEdits: pro.photoEdits, reels: pro.reels)
                switch forced {
                case "trial":  state = PlanBanner.state(plan: "trial", trialEndsAt: iso.string(from: Date().addingTimeInterval(5 * day)), allowances: week, now: Date())
                case "ending": state = PlanBanner.state(plan: "trial", trialEndsAt: iso.string(from: Date().addingTimeInterval(1.5 * day)), allowances: week, now: Date())
                case "ended":  state = PlanBanner.state(plan: "free", trialEndsAt: nil, allowances: nil, now: Date())
                case "paid":   state = PlanBanner.state(plan: "pro", trialEndsAt: nil, allowances: paid, now: Date())
                default:       state = nil
                }
                return
            }
            guard Config.useLiveBackend, let base = Config.apiBaseURL else { return }

            // A session can exist a beat before its token is usable, so give it
            // a few tries rather than going quiet for the rest of the launch.
            for delay in [0.0, 0.8, 2.0, 4.0] {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard let token = await AuthStore.validAccessToken() else { continue }
                var req = URLRequest(url: base.appendingPathComponent("me"))
                req.timeoutInterval = 20
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
                else { continue }
                let d = JSONDecoder()
                // convertFromSnakeCase and explicit CodingKeys are mutually
                // exclusive — MeSlice declares none, so `trial_ends_at` maps.
                d.keyDecodingStrategy = .convertFromSnakeCase
                guard let me = try? d.decode(MeSlice.self, from: data) else { return }
                // The server's own numbers for THIS org — the free week is sized
                // per industry from `orgs.space_type`, so these, not a literal
                // in the app, are the promise the server will actually keep.
                state = PlanBanner.state(plan: me.plan, trialEndsAt: me.trialEndsAt,
                                         allowances: me.entitlement?.allowances, now: Date())
                // The server sizing the week for a different industry than the
                // one chosen on this phone means the last sync never landed
                // (or landed on another org). Forget that it did, so the next
                // sync point — a type change, a session change, the next
                // foreground — sends it again. Nothing is shown for it.
                if let serverType = me.org?.spaceType?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !serverType.isEmpty, serverType != SpaceType.current.rawValue {
                    AppModel.markSpaceTypeOutOfSync()
                }
                return
            }
            // Every attempt failed: say nothing rather than guess at somebody's
            // money. The next foreground tries again.
        }
    }

    /// The monthly numbers the banner can quote, as `GET /me` reports them
    /// (`entitlement.*_per_month`). nil = not known (offline, an older server),
    /// in which case the copy falls back to the app's own literals.
    struct Allowances: Equatable {
        let renders: Int
        let photoEdits: Int
        let reels: Int
    }

    /// Only the fields this banner needs. A narrow shape cannot break when
    /// /me grows a field; every field is optional so a missing one cannot
    /// break it either.
    private struct MeSlice: Decodable {
        struct Entitlement: Decodable {
            // `LenientInt` (the same tolerant number LiveAPIClient's own /me
            // decode uses) never throws: a count arriving as `3.0`, `"3"` or
            // null must not silence the whole banner.
            let rendersPerMonth: LiveAPIClient.LenientInt?
            let photoEditsPerMonth: LiveAPIClient.LenientInt?
            let reelsPerMonth: LiveAPIClient.LenientInt?

            /// All three, or nothing — a half-known set of numbers would quote
            /// one server figure next to one literal.
            var allowances: Allowances? {
                guard let r = rendersPerMonth?.value, let e = photoEditsPerMonth?.value,
                      let c = reelsPerMonth?.value else { return nil }
                return Allowances(renders: r, photoEdits: e, reels: c)
            }
        }
        struct Org: Decodable {
            let spaceType: String?
        }
        let plan: String?
        let trialEndsAt: String?
        let entitlement: Entitlement?
        let org: Org?
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
    ///
    /// `allowances` are the server's numbers for this org when `/me` had them;
    /// nil falls back to the app's own: `RendpropPlan.allowances` for a paid
    /// plan (the one copy of those literals, Products.swift) and the industry's
    /// free week (`SpaceType.freeWeekLine`) for the trial. `space` is the
    /// business type the copy addresses — the current one, unless a test says
    /// otherwise.
    static func state(plan: String?, trialEndsAt: String?, allowances: Allowances?, now: Date,
                      space: SpaceType = .current) -> PlanState? {
        // "Your free week has ended" is said in two places below; one string.
        let ended = PlanState(kind: .ended,
                              title: "Your free week has ended",
                              detail: "You're on the free plan — one tour a month. Your \(space.spaceNounPlural) and tours are all still here.")
        switch (plan ?? "").lowercased() {
        case "pro":
            return PlanState(kind: .paid, title: "Pro", detail: paidDetail(allowances, fallback: RendpropPlan.pro))
        case "team":
            return PlanState(kind: .paid, title: "Team", detail: "Your whole workspace, on the Team plan.")
        case "starter", "solo":
            return PlanState(kind: .paid, title: "Starter", detail: paidDetail(allowances, fallback: RendpropPlan.starter))
        case "free":
            return ended
        case "trial":
            // What the week gives, in the server's numbers when it sent them —
            // the week is sized per industry (`orgs.space_type`), and the
            // server's figure is the one it enforces.
            let week = allowances.map {
                SpaceType.makeFreeWeekLine(tours: $0.renders, photoEdits: $0.photoEdits, reelClips: $0.reels)
            } ?? space.freeWeekLine
            let days = daysLeft(trialEndsAt, now: now)
            guard let days else {
                return PlanState(kind: .trial, title: "Your first week is on us",
                                 detail: "\(week), free.")
            }
            if days <= 0 {
                return ended
            }
            if days <= 2 {
                return PlanState(kind: .endingSoon,
                                 title: days == 1 ? "Last day of your free week" : "\(days) days left of your free week",
                                 detail: "After that it's the free plan — one tour a month.")
            }
            return PlanState(kind: .trial,
                             title: "Your first week is on us",
                             detail: "\(week) — \(days) days left.")
        default:
            return nil          // unknown plan: say nothing at all
        }
    }

    /// "10 tours a month, 200 photo edits, 12 reel clips." — from the server's
    /// numbers when known, else the plan's literals in Products.swift.
    static func paidDetail(_ allowances: Allowances?, fallback plan: RendpropPlan) -> String {
        let a = plan.allowances
        let renders = allowances?.renders ?? a.renders
        let edits = allowances?.photoEdits ?? a.photoEdits
        let clips = allowances?.reels ?? a.reels
        let tourNoun = renders == 1 ? "tour" : "tours"
        let editNoun = edits == 1 ? "edit" : "edits"
        let clipNoun = clips == 1 ? "clip" : "clips"
        return "\(renders) \(tourNoun) a month, \(edits) photo \(editNoun), \(clips) reel \(clipNoun)."
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
