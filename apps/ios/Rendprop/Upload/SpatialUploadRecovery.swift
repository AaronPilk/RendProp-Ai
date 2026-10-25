import Foundation

/// A retry may renew one existing physical-write authority, not buy a new
/// upload. The transport service itself decides whether that authority is still
/// planned or has a recoverable stored receipt. Unknown dispatches fail closed.
///
/// The one exception is a reservation the server has already declared dead
/// (expired after 48 h, aborted, or retired). Renewing it can never succeed, so
/// looping the owner through "Resume upload" is not caution, it is a dead end.
/// That case is reported as `.expired`; the caller may then buy a fresh ticket
/// for the SAME frame under a new idempotency key.
enum SpatialUploadRecovery {
    enum Probe { case complete, needsReconciliation }
    enum Result { case complete, renew(URL), expired }

    /// The v2 PUT capability lasts at most an hour. A capability this close to
    /// its `expires` claim is treated as spent: the transfer could start after
    /// the signature stops verifying, especially when it waits for Wi-Fi.
    static let renewalMargin: TimeInterval = 5 * 60

    /// The `expires` claim (epoch seconds) of a v2 capability URL, if present.
    static func capabilityExpiry(_ url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "expires" })?.value,
              let seconds = Int64(raw), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// True only for a bounded v2 capability whose expiry is comfortably ahead.
    /// A URL with no readable expiry is not trusted: renewing costs one small
    /// request, a PUT with a stale signature costs a failed transfer.
    static func capabilityIsUsable(_ url: URL?, at now: Date = Date()) -> Bool {
        guard let url, UploadRecovery.isBoundedCapability(url), let expiry = capabilityExpiry(url) else { return false }
        return expiry.timeIntervalSince(now) > renewalMargin
    }

    /// The server's verdict that this reservation can never be renewed: its
    /// row is gone (404/410), it was aborted or retired, or one of the exact
    /// server-owned 409 texts for an expired or cancelled reservation. Exact
    /// strings, not substring matching: any other conflict still fails closed.
    /// HTTP status is authoritative even if a gateway recases `code`.
    static func isTerminalReservation(_ error: Error) -> Bool {
        if UploadRecovery.isAborted(error) || UploadRecovery.isLegacyRetired(error) { return true }
        guard let api = error as? APIError, let status = api.status else { return false }
        if status == 404 || status == 410 { return true }
        guard status == 409, case .server(_, _, let text) = api else { return false }
        return ["upload is terminal or expired",
                "recovery is terminal or expired",
                "upload expired or cancelled"].contains(text.lowercased())
    }

    /// `POST /uploads` refused a replayed idempotency key because the asset it
    /// names has expired but not yet been swept. The frame must buy under a
    /// new key; nothing else about the request was wrong.
    static func isReplayConflict(_ error: Error) -> Bool {
        guard let api = error as? APIError, api.status == 409,
              case .server(_, _, let text) = api else { return false }
        return text.lowercased() == "idempotency key conflicts with an existing or expired upload"
    }

    static func reconcile(ticketID: String,
                          probe: () async throws -> Probe,
                          renew: (String) async throws -> UploadTicket) async throws -> Result {
        let probed: Probe
        do { probed = try await probe() } catch {
            // `/complete` itself can report the reservation dead. That is the
            // server's verdict on this exact asset, not permission to guess.
            if isTerminalReservation(error) { return .expired }
            throw error
        }
        if case .complete = probed { return .complete }
        // POST /uploads with the same key can reserve another asset after
        // completion excludes the first from reservation lookup. By-id renewal
        // instead returns that first asset's receipt if completion wins a race.
        let renewed: UploadTicket
        do { renewed = try await renew(ticketID) } catch {
            if isTerminalReservation(error) { return .expired }
            throw error
        }
        let receipt = try UploadRecovery.validatedRenewal(renewed,
            previous: UploadTicket(assetID: ticketID, mode: .single))
        if receipt.uploaded == true { return .complete }
        guard let url = receipt.putURL else { throw SpatialClientError.invalidResponse }
        return .renew(url)
    }
}
