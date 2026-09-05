import Foundation

// MARK: - The wire shape
//
// Mirrors `POST /events` in docs/LAUNCH-CONTRACT.md §Events exactly. Keys are
// snake_case on the wire and camelCase in Swift; the mapping is explicit
// (`CodingKeys`) rather than relying on a global key strategy, because this
// type is encoded by hand and a silent rename would be a silent data loss.
//
// There is deliberately no `user_id` field. The server resolves the account
// from the JWT, so the app cannot attribute an event to the wrong person even
// if it wanted to.
struct EventBatch: Encodable, Sendable {
    struct Event: Encodable, Sendable {
        /// One of the contract's 19 names. Anything else is a 400.
        let name: String
        /// ISO-8601 with fractional seconds, taken on the DEVICE when the event
        /// happened — the app buffers offline and may flush days later.
        let t: String
        /// Short, non-identifying strings only. See Analytics.swift's header.
        let props: [String: String]
    }

    /// App-generated install UUID from the Keychain. Not the IDFA or IDFV.
    let deviceID: String
    /// Fresh per launch, and again after 30 minutes in the background.
    let sessionID: String
    /// "1.0 (1)"
    let appVersion: String
    /// "iOS 26.4"
    let os: String
    let events: [Event]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case sessionID = "session_id"
        case appVersion = "app_version"
        case os
        case events
    }
}

/// What `POST /events` answers (202). Every field optional: an ack the app
/// cannot decode must not turn a successful send into a retry loop.
struct EventAck: Decodable, Sendable {
    var ok: Bool? = nil
    /// How many events actually landed.
    var accepted: Int? = nil
    /// Prop keys the server dropped because they are not whitelisted for that
    /// event. Non-zero means a call site is sending something pointless.
    var droppedProps: Int? = nil
    /// Whole events dropped for being over the 1 KB cap.
    var droppedEvents: Int? = nil

    enum CodingKeys: String, CodingKey {
        case ok
        case accepted
        case droppedProps = "dropped_props"
        case droppedEvents = "dropped_events"
    }
}

/// The one call analytics makes. A separate protocol (not a change to
/// `APIClient`) so nothing that already ships has to move — the repo's rule for
/// adding API surface: `protocol XxxAPI` + an extension per client, and call
/// sites cast with `as? XxxAPI` (see `AdminRoutingAPI` in SettingsView.swift).
protocol AnalyticsAPI: Sendable {
    func sendEvents(_ batch: EventBatch) async throws -> EventAck
}

// MARK: - Live
//
// This is the ONE route in the app that is called while SIGNED OUT, because
// half the funnel (app_open, paywall_viewed) happens before anybody has an
// account. The bearer is therefore the user's JWT when there is one and the
// project's ANON key when there is not — the anon key is itself a
// project-signed JWT, which is what lets `events` deploy with verify_jwt ON
// (the default) instead of being an open write endpoint.
//
// It deliberately does NOT reuse `LiveAPIClient.execute()`: that helper signs
// out the user on a second 401, which is a catastrophic response to a failed
// analytics ping. A failed flush here is retried later with backoff and the
// person never learns it happened.
extension LiveAPIClient: AnalyticsAPI {
    func sendEvents(_ batch: EventBatch) async throws -> EventAck {
        guard let base = Config.apiBaseURL else { throw APIError.badResponse(-1) }

        var request = URLRequest(url: base.appendingPathComponent("events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        // Signed in → the owner JWT, so the server can attribute the events to
        // the account. Signed out → the anon key, which the gateway accepts and
        // the function reads as "no user".
        let signedInToken = Config.enableAuth ? await AuthStore.validAccessToken() : nil
        request.setValue("Bearer \(signedInToken ?? Config.supabaseAnonKey)",
                         forHTTPHeaderField: "Authorization")

        // No Idempotency-Key: this route is an append-only insert of events that
        // each carry their own timestamp, and a replayed batch would be
        // duplicate rows, not a duplicate charge. The queue's "put it back at
        // the front on failure" is what prevents double-sends.
        request.httpBody = try JSONEncoder().encode(batch)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else {
            // Surfaces the server's own `{error, code}` sentence — nothing shows
            // it to the user, but it is what a DEBUG console print reads.
            throw LiveAPIClient.serverError(status: http.statusCode, data: data)
        }
        return (try? JSONDecoder().decode(EventAck.self, from: data))
            ?? EventAck(ok: true, accepted: batch.events.count)
    }
}

// MARK: - Mock
//
// Offline dev accepts everything. It prints in DEBUG only so a release build of
// the mock client (which is what a simulator UI test runs against) is silent.
extension MockAPIClient: AnalyticsAPI {
    func sendEvents(_ batch: EventBatch) async throws -> EventAck {
        #if DEBUG
        let names = batch.events.map(\.name).joined(separator: ", ")
        print("[analytics/mock] \(batch.events.count) event(s) accepted: \(names)")
        #endif
        return EventAck(ok: true, accepted: batch.events.count, droppedProps: 0, droppedEvents: 0)
    }
}
