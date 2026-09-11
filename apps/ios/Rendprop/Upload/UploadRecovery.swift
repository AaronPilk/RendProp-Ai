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

    static func reconcile(journal: Journal, allowLegacyCancellation: Bool,
                          incompleteMultipart: Bool = false,
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
            guard mayReconcile(error, incompleteMultipart: incompleteMultipart) else { throw error }
        }
        let renewed = try validatedRenewal(try await renew(existing.assetID), previous: existing)
        return renewed.uploaded == true ? .complete(renewed.assetID) : .ticket(renewed)
    }
}
