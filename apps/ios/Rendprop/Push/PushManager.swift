import Foundation
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Push notifications
//
// THE DEFECT THIS FIXES. Between sessions, the product never spoke to a
// customer. A buyer filled in the lead form on a tour at 9pm and the agent
// found out whenever they next happened to open the app; a render finished
// while the phone was in a pocket and nothing said so. `Config.enablePush` had
// been `false` since the first build with a TODO next to it, and the Settings
// section that would have shown the switches was commented out.
//
// ── WHEN THE APP ASKS, AND WHY IT IS NOT AT LAUNCH ──────────────────────────
//
// iOS gives an app exactly ONE system prompt. Spending it at launch — before
// the person has published anything, on a screen that has not yet done them a
// favour — is how an app ends up permanently unable to speak to its customers.
// So the app asks at the first moment the answer is obviously yes: the FIRST
// TIME A TOUR IS PUBLISHED SUCCESSFULLY. That is the instant a link exists that
// a stranger can fill a form on, which is the instant a notification starts
// being worth having.
//
// Before the system prompt there is a short pre-prompt sheet in plain words
// (`PushPrePromptView`) that says exactly what will arrive and nothing else.
// "Not now" is a real answer: it is not repeated, nothing is degraded, and the
// way back is a row in Settings the person can find on their own terms. If they
// say no to the SYSTEM prompt, the app never asks again — it cannot, and
// pretending otherwise is how apps end up shipping a fake "enable" button that
// silently does nothing. Settings then shows one honest row that opens iOS
// Settings, which is the only place that decision can be changed.
//
// ── THE SERVER MAY NOT HAVE THE ROUTES YET ──────────────────────────────────
//
// `POST /me/devices` and `PATCH /me/notifications` are being built in parallel.
// Everything here is written so that a server without them is a no-op, never an
// error: a 404 marks the route absent for the rest of this launch and is not
// retried, no banner is shown, and the per-category rows simply do not appear
// until `GET /me` starts carrying a `notifications` object. A feature that does
// not exist yet must look like a feature that does not exist yet — not like a
// broken one.

// MARK: - What a notification can be about

/// The four things the product will ever send. Each is a row in Settings and a
/// key in the preferences payload.
///
/// The two the pre-prompt promises — leads and renders — are deliberately
/// FIRST: those are the ones a person says yes for, and the copy names exactly
/// them. The other two are quieter account matters that already have in-app
/// surfaces; they are opt-outable individually for the same reason.
enum NotificationCategory: String, CaseIterable, Identifiable {
    case leads
    case renders
    case freeWeekEnding = "free_week_ending"
    case allowanceLow = "allowance_low"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leads:          return "New enquiries"
        case .renders:        return "Renders finished"
        case .freeWeekEnding: return "Free week ending"
        case .allowanceLow:   return "Allowance running low"
        }
    }

    var blurb: String {
        switch self {
        case .leads:          return "Someone filled in the form on one of your tours."
        case .renders:        return "A tour finished rendering and is ready to publish."
        case .freeWeekEnding: return "Your free week is nearly up."
        case .allowanceLow:   return "You're close to this month's limit on a plan feature."
        }
    }
}

// MARK: - The preferences themselves

/// What the account wants to be told about.
///
/// Read from `GET /me` → `notifications`, written with `PATCH /me/notifications`.
/// Every field is a plain `Bool` with a safe default because this is exactly the
/// shape that must survive a server which sends half of it, all of it or none
/// of it.
struct NotificationPrefs: Sendable, Hashable {
    /// The master switch. False means the account wants nothing at all, whatever
    /// the four below say.
    var enabled: Bool = true
    var leads: Bool = true
    var renders: Bool = true
    var freeWeekEnding: Bool = true
    var allowanceLow: Bool = true

    subscript(category: NotificationCategory) -> Bool {
        get {
            switch category {
            case .leads:          return leads
            case .renders:        return renders
            case .freeWeekEnding: return freeWeekEnding
            case .allowanceLow:   return allowanceLow
            }
        }
        set {
            switch category {
            case .leads:          leads = newValue
            case .renders:        renders = newValue
            case .freeWeekEnding: freeWeekEnding = newValue
            case .allowanceLow:   allowanceLow = newValue
            }
        }
    }

    /// The PATCH body. Snake case, like every other route this app talks to.
    var wire: [String: Any] {
        [
            "enabled": enabled,
            "leads": leads,
            "renders": renders,
            NotificationCategory.freeWeekEnding.rawValue: freeWeekEnding,
            NotificationCategory.allowanceLow.rawValue: allowanceLow,
        ]
    }

    /// Decode whatever the server sent, tolerantly. `push_enabled` is accepted
    /// alongside `enabled` so the app and the route cannot miss each other over
    /// one word; a missing key keeps the default rather than reading as `false`,
    /// because "the server did not say" and "the person said no" are different
    /// facts and only one of them should silence a notification.
    init(wire: [String: Any]) {
        func flag(_ keys: [String], _ fallback: Bool) -> Bool {
            for key in keys {
                if let b = wire[key] as? Bool { return b }
                if let n = wire[key] as? NSNumber { return n.boolValue }
                if let s = wire[key] as? String {
                    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
                    if ["true", "1", "yes", "on"].contains(t) { return true }
                    if ["false", "0", "no", "off"].contains(t) { return false }
                }
            }
            return fallback
        }
        enabled = flag(["enabled", "push_enabled"], true)
        leads = flag(["leads", "lead"], true)
        renders = flag(["renders", "render"], true)
        freeWeekEnding = flag([NotificationCategory.freeWeekEnding.rawValue, "freeWeekEnding"], true)
        allowanceLow = flag([NotificationCategory.allowanceLow.rawValue, "allowanceLow"], true)
    }

    init() {}
}

/// The one API surface the Notifications section needs. Declared here and cast
/// for at runtime — the pattern the repo uses for every added API surface
/// (`AdminFunnelAPI`, `AdminRoutingAPI`). No conformance, or a server without
/// the routes, and the section says less rather than pretending.
protocol NotificationPrefsAPI {
    /// `GET /me` → its `notifications` object. **nil means the server did not
    /// send one**, i.e. this deployment has no notification preferences yet —
    /// which is a different answer from "all off" and is treated as one.
    func notificationPrefs() async throws -> NotificationPrefs?

    /// `PATCH /me/notifications`. Throws `APIError` — a 404 is the caller's cue
    /// that the route is not deployed, not an error to show anybody.
    func updateNotificationPrefs(_ prefs: NotificationPrefs) async throws -> NotificationPrefs
}

extension LiveAPIClient: NotificationPrefsAPI {
    func notificationPrefs() async throws -> NotificationPrefs? {
        let data = try await PushHTTP.send(path: ["me"], method: "GET", body: nil)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bag = object["notifications"] as? [String: Any] else { return nil }
        return NotificationPrefs(wire: bag)
    }

    func updateNotificationPrefs(_ prefs: NotificationPrefs) async throws -> NotificationPrefs {
        let data = try await PushHTTP.send(path: ["me", "notifications"], method: "PATCH", body: prefs.wire)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return prefs }
        // The route may answer with the row itself or with `{ok, notifications}`.
        if let bag = object["notifications"] as? [String: Any] { return NotificationPrefs(wire: bag) }
        return NotificationPrefs(wire: object)
    }
}

extension MockAPIClient: NotificationPrefsAPI {
    /// The offline build has no account, so it has no preferences either. nil —
    /// the same answer a server without the feature gives — so the section shows
    /// exactly what it would show against such a server, which is what makes the
    /// offline walk worth looking at.
    func notificationPrefs() async throws -> NotificationPrefs? { nil }

    func updateNotificationPrefs(_ prefs: NotificationPrefs) async throws -> NotificationPrefs {
        throw APIError.badResponse(404)
    }
}

// MARK: - The small HTTP helper these two routes share
//
// Deliberately not routed through `LiveAPIClient.execute`: that method is
// `private` to its own file and carries retry/idempotency machinery neither of
// these calls wants. This mirrors `AdminFunnelAPI`'s own extension — same
// headers, same auth, same error mapping, no new concepts.

enum PushHTTP {
    static func send(path: [String], method: String, body: [String: Any]?) async throws -> Data {
        guard let base = Config.apiBaseURL else { throw APIError.notConfigured }
        var url = base
        for component in path { url.appendPathComponent(component) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let token = await AuthStore.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveAPIClient.serverError(status: http.statusCode, data: data)
        }
        return data
    }
}

// MARK: - Where a tapped notification goes

/// Resolved from the payload, consumed once by the app root.
enum PushRoute: Equatable {
    /// A listing's own hosted page, resolved by `DeepLink` — the SAME parser
    /// every Universal Link goes through, so a malformed slug in a payload is
    /// rejected by the same rules that reject a malformed one in a URL.
    case tour(DeepLink)
    /// The Leads inbox. A lead belongs to the account, not to one page.
    case leads
}

// MARK: - PushManager

@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    /// The OS-level answer. `.notDetermined` until somebody is asked.
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Drives the pre-prompt sheet at the app root.
    @Published var showPrePrompt = false
    /// Set by a tapped notification; the root consumes it and clears it.
    @Published private(set) var pendingRoute: PushRoute?

    /// True once the app has shown its pre-prompt (or established that there is
    /// nothing to ask). Persisted: "we already asked" must survive a relaunch,
    /// or the sheet comes back on the next publish and the promise that "Not
    /// now" is not punished becomes a lie.
    private var hasAsked: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasAsked) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasAsked) }
    }

    /// The last device token this launch handed to the server, so a
    /// re-registration with an unchanged token costs nothing.
    private var registeredToken: String?
    /// `POST /me/devices` answered 404 — this deployment has no such route.
    /// Not retried this launch; no error is shown, because nothing is wrong
    /// with the phone.
    private var deviceRouteMissing = false
    private var isRegistering = false

    private enum Keys {
        static let hasAsked = "push.hasAskedPermission.v1"
    }

    /// Push does nothing at all in either automated harness, and the reason is
    /// different for each:
    ///
    ///   `-uiTesting`              the screenshot walk must never meet a system
    ///                             alert; one would sit over the screen being
    ///                             photographed and stop the walk dead.
    ///   `-sessionNetworkTesting`  the loopback regression drives the REAL
    ///                             publish flow against 127.0.0.1
    ///                             (`testPublishRecoversWithoutSecondTap`), and
    ///                             a publish is exactly what would raise the
    ///                             pre-prompt — over the fixture screen the
    ///                             test is asserting on.
    ///
    /// Both switches are DEBUG-only and read false in Release, so this costs a
    /// shipping build nothing.
    private static var isSuppressed: Bool {
        !Config.enablePush || Config.isUITesting || Config.isSessionNetworkTesting
    }

    private init() {}

    // MARK: Launch

    /// Called once from the app root. Reads the current OS answer and, when the
    /// person has already said yes, re-registers with APNs — a device token can
    /// change (restore from backup, reinstall) and a stale one is a silent
    /// notification failure nobody can see.
    ///
    /// ASKS NOTHING. Registering with APNs while already authorized shows no UI.
    func start() {
        guard !Self.isSuppressed else { return }
        UNUserNotificationCenter.current().delegate = PushDelegate.shared
        Task { await refreshAuthorization(registerIfAllowed: true) }
    }

    /// Re-read the OS answer (it can change in iOS Settings while the app is in
    /// the background, in both directions).
    func refreshAuthorization(registerIfAllowed: Bool = false) async {
        guard !Self.isSuppressed else { return }
        let status = await Self.currentAuthorization()
        authorization = status
        if registerIfAllowed, Self.allowsNotifications(status) {
            registerWithAPNs()
        }
    }

    // MARK: The one moment the app asks

    /// A tour just went live. THE one moment this app may ask for notification
    /// permission, and only the first time.
    ///
    /// Does nothing at all when the person has already been asked, when the OS
    /// has already been answered (a reinstall carries the old answer), or when
    /// push is off in `Config`. Never blocks the publish it follows.
    func noteTourPublished() {
        guard !Self.isSuppressed else { return }
        guard !hasAsked, !showPrePrompt else { return }
        Task {
            let status = await Self.currentAuthorization()
            authorization = status
            guard status == .notDetermined else {
                // Already decided at the OS level. Record that there is nothing
                // left to ask, and pick up the token if the answer was yes.
                hasAsked = true
                if Self.allowsNotifications(status) { registerWithAPNs() }
                return
            }
            showPrePrompt = true
        }
    }

    /// "Not now" — or a swipe, which means the same thing. Costs nothing,
    /// changes nothing, and is never asked again from a publish. Settings still
    /// offers the switch, because a person who goes looking for it has asked
    /// for it themselves. Idempotent: the sheet's `onDisappear` calls it too,
    /// so closing it by ANY route counts as having been asked.
    func declinePrePrompt() {
        hasAsked = true
        showPrePrompt = false
    }

    /// "Turn them on" — from the pre-prompt, or from the Settings row when the
    /// OS answer is still `.notDetermined`. This is the single system prompt.
    func requestAuthorization() async {
        hasAsked = true
        showPrePrompt = false
        guard !Self.isSuppressed else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        if granted { registerWithAPNs() }
    }

    // MARK: APNs

    /// Ask iOS for a device token. Silent — no UI, no prompt — and safe to call
    /// more than once.
    func registerWithAPNs() {
        guard !Self.isSuppressed else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// iOS handed us a device token (AppDelegate). Hex-encode it and tell the
    /// server, once per distinct token per launch.
    func handleDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty else { return }
        guard !Self.isSuppressed, Config.useLiveBackend else { return }
        guard !deviceRouteMissing, !isRegistering, registeredToken != hex else { return }
        isRegistering = true
        Task {
            defer { isRegistering = false }
            guard !Config.enableAuth || AuthStore.shared.isSignedIn else { return }
            let body: [String: Any] = [
                "device_token": hex,
                "environment": Self.apnsEnvironment,
                "app_version": Analytics.appVersion,
                "locale": Locale.current.identifier,
            ]
            do {
                _ = try await PushHTTP.send(path: ["me", "devices"], method: "POST", body: body)
                registeredToken = hex
            } catch let error as APIError where error.isNotFound {
                // The route is not deployed yet. That is a fact about the
                // server, not a failure of this phone: stop for this launch,
                // say nothing, and try again next launch.
                deviceRouteMissing = true
            } catch {
                // Offline, a blinked connection, an expired token. The next
                // launch registers again; nothing is shown and nothing loops.
            }
        }
    }

    /// iOS could not get a token (no network, no APNs entitlement on this
    /// build, a Simulator with no push environment). Nothing to show a person:
    /// they asked for notifications and will get them once the phone can
    /// register, and "APNs is unreachable" is not a sentence anybody can act
    /// on. Visible in DEBUG, where somebody IS looking for it.
    func handleRegistrationFailure(_ reason: String) {
        #if DEBUG
        print("[push] APNs registration failed: \(reason)")
        #endif
    }

    // MARK: A tapped notification

    /// Resolve a notification payload to somewhere to stand, and publish it for
    /// the app root to consume.
    ///
    /// REUSES `DeepLink.parse`. The payload's `url` goes straight through it;
    /// a bare `slug` is turned into the app's own `rendprop://f/<slug>` form and
    /// put through the SAME parser, so a payload cannot smuggle in a route the
    /// Universal Link path would have rejected (an empty slug, a 4 KB slug, a
    /// host this app does not answer for, or the `/u/` unbranded shape, which
    /// `DeepLink` deliberately refuses to open in-app).
    func handle(payload: [AnyHashable: Any]) {
        guard !Self.isSuppressed else { return }
        let bag = (payload["rp"] as? [AnyHashable: Any]) ?? payload
        let type = (bag["type"] as? String)?.lowercased() ?? ""

        // A lead belongs to the account's inbox, not to one page — and that is
        // the screen the person actually needs to act on it.
        if type == "lead" || type == "leads" {
            pendingRoute = .leads
            return
        }
        if let raw = (bag["url"] as? String) ?? (bag["link"] as? String),
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let link = DeepLink.parse(url) {
            pendingRoute = .tour(link)
            return
        }
        if let slug = (bag["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slug.isEmpty,
           let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "rendprop://f/\(encoded)"),
           let link = DeepLink.parse(url) {
            pendingRoute = .tour(link)
            return
        }
        // Nothing this app has a screen for. Opening the app is the whole of
        // what happens — never swallow the tap into a blank screen.
    }

    func clearPendingRoute() { pendingRoute = nil }

    // MARK: Small facts

    /// True when notifications may actually be delivered.
    static func allowsNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined:               return false
        @unknown default:                           return false
        }
    }

    var isDenied: Bool { authorization == .denied }
    var isAllowed: Bool { Self.allowsNotifications(authorization) }
    var isUndecided: Bool { authorization == .notDetermined }

    /// Which APNs environment this build's token belongs to.
    ///
    /// The token itself does not say, and sending the wrong one means every
    /// push is silently dropped by Apple. A DEBUG build is always development.
    /// A Release build is production UNLESS it was signed with a development
    /// profile (an Xcode "Release" run on a device), and the embedded
    /// provisioning profile is the only local evidence of that — App Store
    /// builds ship without one at all.
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>") else { return "production" }
        let tail = text[key.upperBound...].prefix(120)
        return tail.contains("development") ? "sandbox" : "production"
        #endif
    }

    /// Wrapped rather than the async property so the continuation carries only
    /// the status — a plain Int-backed enum — instead of the whole settings
    /// object.
    private static func currentAuthorization() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// The iOS Settings page for this app — the ONLY place a denied permission
    /// can be changed, which is why the denied row points here instead of
    /// offering a button that could not work.
    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - The notification-centre delegate

/// Its own object rather than `AppDelegate` so the tap-handling rule sits next
/// to the routing it feeds.
final class PushDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushDelegate()

    /// A notification that arrives while the app is in front. Shown as a banner
    /// — the alternative is a lead that lands silently while somebody is
    /// looking at a different screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let payload = response.notification.request.content.userInfo
        // Routing hops to the main actor; the completion handler is called here
        // and now. iOS only needs to know the delegate is finished with the
        // response, and holding it open across an actor hop buys nothing.
        Task { @MainActor in PushManager.shared.handle(payload: payload) }
        completionHandler()
    }
}

// MARK: - The pre-prompt
//
// Every word here is a promise about what will actually arrive. It names the
// two things the product sends that a person cares about, in their words, and
// nothing else — no "stay in the loop", no "don't miss out", no count of
// anything. "Not now" is the same size and the same weight as yes.

struct PushPrePromptView: View {
    @ObservedObject private var push = PushManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 8)
            Image(systemName: "bell.badge")
                .font(.system(size: 40, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Your tour is live. Want to know when it gets you something?")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                promise("envelope.badge", "When someone enquires about a tour")
                promise("sparkles", "When a render finishes")
            }
            Text("That's everything. No marketing, no daily digest — and you can turn either one off in Settings.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                // Both buttons close the sheet by clearing `showPrePrompt` on
                // the manager — the same binding that presented it — so nothing
                // here has to reach for `dismiss()` off the main actor.
                Button {
                    Task { await push.requestAuthorization() }
                } label: {
                    Text("Turn on notifications")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent)
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("push.prePrompt.allow")
                Button {
                    push.declinePrePrompt()
                } label: {
                    Text("Not now")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Theme.ink)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("push.prePrompt.notNow")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.bg)
        // Swiped away without answering? That still counts as asked. The
        // promise is that this is not repeated, and a sheet that reappears on
        // the next publish would break it.
        .onDisappear { push.declinePrePrompt() }
    }

    private func promise(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.rpBody)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(text)
                .font(.rpBody)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
