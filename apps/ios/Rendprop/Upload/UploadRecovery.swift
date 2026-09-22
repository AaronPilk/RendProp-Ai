import Foundation

/// Reconciliation is metadata-first. A transport timeout says nothing about
/// whether storage committed; replaying its old PUT URL spends bytes twice on
/// v1 and violates the one-dispatch authority on v2. Only a fresh, same-ticket
/// server renewal may authorize the next transfer.
enum UploadRecovery {
    enum Failure: LocalizedError {
        case needsLegacyConfirmation, changedTicket, incompatibleTransport, invalidTicket
        var errorDescription: String? {
            switch self {
            case .needsLegacyConfirmation:
                return "This older upload needs recovery. Your original is safe. Tap Resume to replace its retired upload ticket."
            case .changedTicket:
                return "The upload ticket changed during recovery. Your original is safe; no replacement bytes were sent."
            case .incompatibleTransport:
                return "Upload recovery is temporarily unavailable. Your original and saved progress are safe. Try again after the service update."
            case .invalidTicket:
                return "The server returned an incomplete upload ticket. Your original is safe."
            }
        }
    }

    enum Result { case complete(String), ticket(UploadTicket) }

    /// Kept with either a video record or a foreground photo journal. Persist
    /// before the cancellation call so a killed app can recover a lost abort
    /// acknowledgement without inventing another idempotency key.
    struct Journal: Codable {
        var ticket: UploadTicket?
        var cancellationAuthorizedFor: String?
        var dispatched = false
        var completed = false
        /// A whole call's rounds ran dry on `ticket` (or the server retired it).
        /// `dispatched` stays true — the next attempt still reconciles first —
        /// but that next, explicit attempt may retire and replace the ticket
        /// instead of reconciling a corpse forever. Optional so journals written
        /// before this field existed still decode.
        var recoveryExhausted: Bool? = nil
    }

    static func sameAsset(_ lhs: String, _ rhs: String) -> Bool {
        if let a = UUID(uuidString: lhs), let b = UUID(uuidString: rhs) { return a == b }
        return lhs == rhs
    }

    static func isLegacyRetired(_ error: Error) -> Bool {
        guard let api = error as? APIError, api.status == 409,
              case .server(_, _, let text) = api else { return false }
        // These are exact server-owned messages, not substring matching of any
        // conflict mentioning an upload. HTTP status is authoritative even if
        // a gateway changes the code's case (CONFLICT versus conflict).
        return ["legacy upload must be reticketed after rollout cleanup",
                "legacy upload must be aborted and reticketed"].contains(text.lowercased())
    }

    static func isAborted(_ error: Error) -> Bool {
        guard let api = error as? APIError, api.status == 409,
              case .server(_, _, let text) = api else { return false }
        return text.lowercased() == "this upload was aborted — create a new ticket"
    }

    /// The server retired THIS reservation for good: its row is gone, or it was
    /// aborted without our durable authorization. No renewal can revive it, so
    /// a later, explicit attempt reserves afresh instead of probing it forever.
    static func isRetired(_ error: Error) -> Bool {
        guard let api = error as? APIError, let status = api.status else { return false }
        return status == 404 || status == 410 || isAborted(error)
    }

    /// Renewal answers that justify retiring a reservation ourselves — only on
    /// a later explicit attempt, after an earlier one already ran dry: the
    /// server still cannot plan a transfer (5xx, or the receipt/rejected
    /// conflicts). Sign-in, plan, permission and rate limits are never the
    /// ticket's fault and stay plain retries. Being offline is not an answer.
    static func mayRetire(_ error: Error) -> Bool {
        guard let api = error as? APIError, let status = api.status else { return false }
        if [401, 402, 403, 429].contains(status) { return false }
        return status >= 500 || status == 409
    }

    static func mayReconcile(_ error: Error, incompleteMultipart: Bool) -> Bool {
        guard let api = error as? APIError, let status = api.status else { return false }
        if status == 503 { return true } // renewal can only inspect this same reservation
        guard case .server(_, _, let text) = api else { return false }
        if status == 409 {
            return text.lowercased() == "every transfer needs its durable stored receipt before completion"
        }
        return incompleteMultipart && status == 400 &&
            text.hasPrefix("parts[] must contain each part 1…") && text.hasSuffix(" exactly once")
    }

    static func validatedRenewal(_ ticket: UploadTicket, previous: UploadTicket) throws -> UploadTicket {
        guard sameAsset(ticket.assetID, previous.assetID), ticket.mode == previous.mode else {
            throw Failure.changedTicket
        }
        // Do not relabel a v2 reservation as v1 after an edge-function rollback.
        // Renew is a v2-only endpoint; an absent version is not proof of safety.
        guard ticket.uploaded == true || ticket.transportVersion == 2 else {
            throw Failure.incompatibleTransport
        }
        if ticket.uploaded == true { return ticket }
        switch ticket.mode {
        case .single:
            guard let url = ticket.putURL, isBoundedCapability(url) else { throw Failure.invalidTicket }
        case .multipart:
            guard ticket.uploadID == previous.uploadID, ticket.partSize == previous.partSize,
                  ticket.partCount == previous.partCount, let count = ticket.partCount, count > 0,
                  let size = ticket.partSize, size > 0 else { throw Failure.changedTicket }
            let parts = ticket.confirmedParts ?? []
            guard Set(parts.map(\.number)).count == parts.count,
                  parts.allSatisfy({ (1...count).contains($0.number) && !$0.etag.isEmpty && $0.etag.count <= 256 }) else {
                throw Failure.invalidTicket
            }
        }
        return ticket
    }

    static func isBoundedCapability(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 2,
              items.filter({ $0.name == "expires" }).count == 1,
              items.filter({ $0.name == "signature" }).count == 1,
              let expiry = items.first(where: { $0.name == "expires" })?.value, Int64(expiry) != nil,
              let signature = items.first(where: { $0.name == "signature" })?.value,
              signature.count == 64, signature.allSatisfy({ $0.isHexDigit }) else { return false }
        let pieces = url.path.split(separator: "/")
        return pieces.count == 2 && pieces[0] == "v2" && UUID(uuidString: String(pieces[1])) != nil
    }

    static func validatedReplacement(_ ticket: UploadTicket, retired: UploadTicket) throws -> UploadTicket {
        guard !sameAsset(ticket.assetID, retired.assetID) else { throw Failure.changedTicket }
        if ticket.transportVersion != 2 { throw Failure.incompatibleTransport }
        if ticket.mode == .single {
            guard let url = ticket.putURL, isBoundedCapability(url) else { throw Failure.invalidTicket }
        }
        return ticket
    }

    /// `allowRetiredReplacement` is the second-attempt consent for a v2 ticket
    /// whose earlier call ran every round dry (`Journal.recoveryExhausted`):
    /// this call may then answer a retired or still-unplannable ticket with an
    /// abort (durable intent first) and ONE fresh reservation for the same
    /// file. A first call never replaces a reservation on its own — the
    /// existing tests pin that — so budget is only ever spent on a deliberate
    /// retry, never in a loop.
    static func reconcile(journal: Journal, allowLegacyCancellation: Bool,
                          incompleteMultipart: Bool = false,
                          allowRetiredReplacement: Bool = false,
                          persistCancellation: (String) async throws -> Void,
                          complete: (String) async throws -> Void,
                          renew: (String) async throws -> UploadTicket,
                          cancel: (String) async throws -> Void,
                          create: () async throws -> UploadTicket) async throws -> Result {
        guard let existing = journal.ticket else { throw Failure.invalidTicket }
        do {
            try await complete(existing.assetID)
            return .complete(existing.assetID)
        } catch {
            if let api = error as? APIError, api.isAlreadyComplete { return .complete(existing.assetID) }
            if isLegacyRetired(error) {
                guard allowLegacyCancellation else { throw Failure.needsLegacyConfirmation }
                try await persistCancellation(existing.assetID)
                do { try await cancel(existing.assetID) }
                catch {
                    // Complete may win against the explicit cancellation. Do
                    // not allocate a replacement if this original is publishable.
                    if let api = error as? APIError, api.isAlreadyComplete {
                        try await complete(existing.assetID)
                        return .complete(existing.assetID)
                    }
                    throw error
                }
                let replacement = try await create()
                return .ticket(try validatedReplacement(replacement, retired: existing))
            }
            if isAborted(error), let approved = journal.cancellationAuthorizedFor,
               sameAsset(approved, existing.assetID) {
                // Only our durable, explicitly approved legacy cancellation can
                // take this path; unrelated expired/rejected tickets never do.
                let replacement = try await create()
                return .ticket(try validatedReplacement(replacement, retired: existing))
            }
            if allowRetiredReplacement, isRetired(error) {
                // The row is gone or the server aborted it behind our back, and
                // an earlier attempt already ran dry on it. There is nothing to
                // cancel; the deliberate retry gets a fresh reservation.
                let replacement = try await create()
                return .ticket(try validatedReplacement(replacement, retired: existing))
            }
            guard mayReconcile(error, incompleteMultipart: incompleteMultipart) else { throw error }
        }
        let renewed: UploadTicket
        do {
            renewed = try validatedRenewal(try await renew(existing.assetID), previous: existing)
        } catch {
            // Renewal is what re-plans a rejected transfer. When it still cannot,
            // on a deliberate retry after an exhausted one, retire the ticket
            // ourselves: durable cancellation intent, abort, fresh reservation.
            // A validation failure (rollback, changed ticket) is never a reason
            // to abort — the replacement would fail the same checks.
            guard allowRetiredReplacement, !(error is Failure) else { throw error }
            if isRetired(error) {
                let replacement = try await create()
                return .ticket(try validatedReplacement(replacement, retired: existing))
            }
            guard mayRetire(error) else { throw error }
            try await persistCancellation(existing.assetID)
            do { try await cancel(existing.assetID) }
            catch {
                // Same rule as the legacy path: a completion that won the race
                // is publishable and must not be replaced.
                if let api = error as? APIError, api.isAlreadyComplete {
                    try await complete(existing.assetID)
                    return .complete(existing.assetID)
                }
                throw error
            }
            let replacement = try await create()
            return .ticket(try validatedReplacement(replacement, retired: existing))
        }
        return renewed.uploaded == true ? .complete(renewed.assetID) : .ticket(renewed)
    }
}
