import Foundation
import Security
import SwiftUI

// MARK: - Analytics
//
// First-party product analytics. The whole thing is this file, AnalyticsAPI.swift,
// CrashReporter.swift and Attribution.swift — there is NO third-party SDK in the
// app: no Firebase, no Mixpanel, no ad network. Events go to our own
// `POST /events`, land in our own Postgres table, and are read by the owner in
// the app's own console (docs/LAUNCH-CONTRACT.md §Events).
//
// ── WHAT MAY BE IN AN EVENT ──────────────────────────────────────────────────
//
// A name from the contract vocabulary, a timestamp, and a handful of SHORT
// STRING props that are enums, counts or product ids. That is all.
//
// NEVER, under any circumstance: an e-mail address, a person's name, a street
// address, a phone number, a photo, a file path, a listing id, a URL, a
// coordinate. `props` is `[String: String]` precisely so a call site cannot
// casually hand over a model object and let something slip. The server whitelists
// the keys per event and scrubs every value on top of that — but the honest
// place to stop PII is here, at the call site, and the type is the reminder.
//
// ── IDENTITY ─────────────────────────────────────────────────────────────────
//
// `device_id` is a UUID this app generates on first launch and stores in its own
// Keychain item. It is NOT the IDFA (the app never asks for App Tracking
// Transparency because it does not track across apps), not the IDFV, and not
// derivable from either. `session_id` is fresh per launch, and again after 30
// minutes in the background. The user id is never sent — the server resolves it
// from the JWT, so the app cannot get it wrong or lie about it.
//
// ── DURABILITY ───────────────────────────────────────────────────────────────
//
// `track` appends to an in-memory queue that is mirrored to a JSON file in
// Application Support, so events survive a kill or a crash (which is the whole
// point for the `crash` event). `flush` posts batches of up to 100 and puts
// anything that failed back at the FRONT of the queue. Events older than 7 days
// are dropped: analytics that arrives a week late is not worth the bytes.
//
// ── IT MUST NEVER COST THE USER ANYTHING ─────────────────────────────────────
//
// Nothing here blocks a screen, retries in a loop, or throws into a caller.
// `track` is main-actor and returns immediately. A flush that fails is retried
// later with backoff and is silent — a person capturing a walkthrough must never
// find out that analytics had a bad day.
@MainActor
enum Analytics {

    // MARK: Configuration

    /// The contract vocabulary. A name outside this set is a 400 from the
    /// server, so it is refused here too rather than shipped and lost — a typo
    /// at a call site shows up in DEBUG instead of quietly draining the queue.
    static let vocabulary: Set<String> = [
        "app_open", "signup", "signin", "home_created", "capture_started",
        "capture_finished", "render_finished", "tour_published", "ai_photo_edit",
        "reel_made", "voiceover_added", "aerial_made", "paywall_viewed",
        "purchase_started", "purchase_completed", "purchase_failed", "restore",
        "crash", "error",
    ]

    /// Most events the app can generate in one flush.
    private static let maxBatch = 100
    /// Hard ceiling on the on-disk queue. Past it the OLDEST events go: a device
    /// that has been offline for a month must not grow a file without bound.
    private static let maxQueued = 2_000
    /// An event older than this is dropped unsent.
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// While the app is in front, flush this often.
    private static let flushInterval: TimeInterval = 60
    /// A new launch after this long in the background starts a new session.
    private static let sessionGap: TimeInterval = 30 * 60

    // MARK: State

    private static var api: AnalyticsAPI?
    private static var queue: [QueuedEvent] = []
    private static var started = false
    private static var isFlushing = false
    private static var flushTimer: Task<Void, Never>?
    /// Consecutive failed flushes — drives the backoff, reset by a success.
    private static var failures = 0
    private static var backoffUntil: Date?

    private static var deviceID = ""
    private static var sessionID = UUID().uuidString
    private static var lastBackgrounded: Date?

    // MARK: - Public surface

    /// Record one event. Safe to call from anywhere on the main actor; returns
    /// immediately and never throws.
    ///
    /// `props` values must be short, non-identifying strings — see the file
    /// header. Keys the server does not whitelist for this event are dropped
    /// server-side, so an extra key is harmless but pointless.
    static func track(_ name: String, _ props: [String: String] = [:]) {
        guard vocabulary.contains(name) else {
            #if DEBUG
            assertionFailure("Analytics.track: \"\(name)\" is not in the contract vocabulary")
            #endif
            return
        }

        // Conversion value FIRST, so an install that is killed before its first
        // flush still tells Meta the person got this far. SKAdNetwork postbacks
        // do not depend on our own network call succeeding.
        Attribution.reachedStep(for: name)

        queue.append(QueuedEvent(name: name, t: Date(), props: Self.bounded(props)))
        if queue.count > maxQueued { queue.removeFirst(queue.count - maxQueued) }
        persist()

        #if DEBUG
        print("[analytics] \(name) \(props.isEmpty ? "" : String(describing: props))")
        #endif
    }

    /// Start the pipeline: device id, session id, `app_open`, the crash
    /// subscriber, the SKAdNetwork install postback, and the periodic flush.
    ///
    /// Idempotent for the pipeline itself; calling it again with a different
    /// client (sign-in swaps nothing today — `AppModel.api` is a `let` — but a
    /// future build might) just re-points the sender.
    static func start(api: AnalyticsAPI?) {
        Self.api = api
        guard !started else { return }
        started = true

        deviceID = DeviceIdentity.load()
        queue = Store.load()
        prune()

        CrashReporter.shared.begin()
        Attribution.registerInstall()

        track("app_open", ["cold": "true"])
        scheduleFlushLoop()
        Task { await flush() }
    }

    /// Send what is queued. Batches of ≤ 100, oldest first. Never throws; a
    /// failed batch goes back to the FRONT of the queue so ordering survives.
    static func flush() async {
        guard let api, !isFlushing else { return }
        if let until = backoffUntil, until > Date() { return }
        prune()
        guard !queue.isEmpty else { return }

        isFlushing = true
        defer { isFlushing = false }

        let batch = Array(queue.prefix(maxBatch))
        queue.removeFirst(batch.count)
        persist()

        let payload = EventBatch(
            deviceID: deviceID,
            sessionID: sessionID,
            appVersion: Self.appVersion,
            os: Self.osVersion,
            events: batch.map { $0.wire }
        )

        do {
            _ = try await api.sendEvents(payload)
            failures = 0
            backoffUntil = nil
        } catch {
            // Put them back at the front — an event dropped because the network
            // blinked is a hole in the funnel nobody can see afterwards.
            queue.insert(contentsOf: batch, at: 0)
            if queue.count > maxQueued { queue.removeFirst(queue.count - maxQueued) }
            persist()
            failures += 1
            // 1, 2, 4, 8 … capped at 10 minutes.
            let delay = min(pow(2.0, Double(failures)) * 30, 600)
            backoffUntil = Date().addingTimeInterval(delay)
        }
    }

    /// Wire this to the app's `scenePhase`. Backgrounding is the one moment we
    /// KNOW the user is done for now, so it is the most valuable flush there is.
    static func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            lastBackgrounded = Date()
            flushTimer?.cancel()
            flushTimer = nil
            Task { await flush() }
        case .active:
            rollSessionIfStale()
            scheduleFlushLoop()
            Task { await flush() }
        @unknown default:
            break
        }
    }

    /// Sign-in state changed. Wired to `AuthStore.isSignedIn` from the app root.
    ///
    /// HOW SIGNUP IS TOLD FROM SIGNIN, and the honest limit of it: the FIRST
    /// time this install ever becomes signed in is recorded as `signup`; every
    /// later sign-in is `signin`. That matches the rest of the pipeline, which
    /// counts DEVICES — and it matches SKAdNetwork, where conversion value 1 is
    /// a per-install rung that only ever goes up.
    ///
    /// It is an approximation in exactly one case: a returning customer who
    /// signs in on a brand-new phone is counted as a signup. The server knows
    /// the truth (Supabase says whether the user row was created), so if that
    /// case ever matters the fix is a flag from AuthStore — see HANDOFF-P3.md.
    static func authChanged(_ isSignedIn: Bool) {
        guard isSignedIn else { return }
        let key = "analytics.hasEverSignedIn"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: key) {
            track("signin", ["method": "apple"])
        } else {
            defaults.set(true, forKey: key)
            track("signup", ["method": "apple"])
        }
    }

    /// A closure other modules can be handed so they can emit events without
    /// knowing anything about this type — agent P1's paywall, for instance.
    /// One line at merge time:
    ///
    ///     PaywallEvents.sink = Analytics.externalSink
    ///
    /// `nonisolated` and it hops to the main actor itself, so a caller on any
    /// queue can use it without ceremony.
    nonisolated static var externalSink: (String, [String: String]) -> Void {
        { name, props in
            Task { @MainActor in Analytics.track(name, props) }
        }
    }

    /// The current session id — CrashReporter stamps late-delivered diagnostics
    /// with it, since MetricKit hands them over a launch or more after the fact.
    static var currentSessionID: String { sessionID }

    /// "1.0 (1)" — marketing version + build, exactly what the contract's
    /// `app_version` field expects.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// "iOS 26.4". `ProcessInfo` rather than UIDevice so this stays usable off
    /// the main thread if it ever needs to be.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let patch = v.patchVersion > 0 ? ".\(v.patchVersion)" : ""
        return "iOS \(v.majorVersion).\(v.minorVersion)\(patch)"
    }

    // MARK: - Internals

    /// Clip every prop to something that cannot hide a paragraph, and drop
    /// empties. The server clips again at 200 — this is the polite version.
    private static func bounded(_ props: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in props {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            out[String(key.prefix(40))] = String(v.prefix(120))
        }
        return out
    }

    /// A launch after a long background is a NEW session, so "sessions" means
    /// something closer to "visits" than "process starts".
    private static func rollSessionIfStale() {
        guard let last = lastBackgrounded else { return }
        if Date().timeIntervalSince(last) >= sessionGap {
            sessionID = UUID().uuidString
            track("app_open", ["cold": "false"])
        }
        lastBackgrounded = nil
    }

    private static func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let before = queue.count
        queue.removeAll { $0.t < cutoff }
        if queue.count != before { persist() }
    }

    private static func scheduleFlushLoop() {
        flushTimer?.cancel()
        flushTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await flush()
            }
        }
    }

    private static func persist() { Store.save(queue) }

    // MARK: One queued event

    private struct QueuedEvent: Codable {
        let name: String
        let t: Date
        let props: [String: String]

        var wire: EventBatch.Event {
            EventBatch.Event(name: name, t: Self.iso.string(from: t), props: props)
        }

        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
    }

    // MARK: The on-disk queue
    //
    // Application Support, not Documents: this is app data, not something the
    // user made, and it must not appear in Files. Excluded from iCloud/iTunes
    // backup — an analytics queue is worthless on a restored device and copying
    // it around is the opposite of minimising what we hold.

    private enum Store {
        private static var url: URL? {
            guard let dir = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ) else { return nil }
            let folder = dir.appendingPathComponent("Analytics", isDirectory: true)
            if !FileManager.default.fileExists(atPath: folder.path) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            return folder.appendingPathComponent("queue.json")
        }

        static func load() -> [QueuedEvent] {
            guard let url, let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([QueuedEvent].self, from: data)) ?? []
        }

        static func save(_ events: [QueuedEvent]) {
            guard var url else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(events) else { return }
            // .noFileProtection would be wrong (this can wait for first unlock);
            // .completeFileProtectionUntilFirstUserAuthentication lets a
            // background flush after a reboot still read it.
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    // MARK: The device id
    //
    // Keychain first so it survives a reinstall on the same device (which keeps
    // the funnel honest about repeat installs), UserDefaults as the fallback for
    // the case where the Keychain is unavailable — e.g. before first unlock.
    // `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never synced to
    // iCloud, never restored onto a different phone.

    enum DeviceIdentity {
        private static let service = "com.rendprop.app.analytics"
        private static let account = "device_id"
        private static let defaultsKey = "analytics.deviceID"

        static func load() -> String {
            if let existing = keychainRead(), UUID(uuidString: existing) != nil { return existing }
            if let fallback = UserDefaults.standard.string(forKey: defaultsKey),
               UUID(uuidString: fallback) != nil {
                keychainWrite(fallback)          // promote it now that we can
                return fallback
            }
            let fresh = UUID().uuidString.lowercased()
            keychainWrite(fresh)
            UserDefaults.standard.set(fresh, forKey: defaultsKey)
            return fresh
        }

        private static func query() -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
        }

        private static func keychainRead() -> String? {
            var q = query()
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data,
                  let value = String(data: data, encoding: .utf8) else { return nil }
            return value
        }

        @discardableResult
        private static func keychainWrite(_ value: String) -> Bool {
            guard let data = value.data(using: .utf8) else { return false }
            let update: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(query() as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query()
                insert[kSecValueData as String] = data
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(insert as CFDictionary, nil)
            }
            return status == errSecSuccess
        }
    }
}
