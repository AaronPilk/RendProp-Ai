import Foundation

/// A retry may renew one existing physical-write authority, not buy a new
/// upload. The transport service itself decides whether that authority is still
/// planned or has a recoverable stored receipt. Unknown dispatches fail closed.
enum SpatialUploadRecovery {
    enum Probe { case complete, needsReconciliation }
    enum Result { case complete, renew(URL) }

    static func reconcile(ticketID: String,
                          probe: () async throws -> Probe,
                          renew: (String) async throws -> UploadTicket) async throws -> Result {
        if case .complete = try await probe() { return .complete }
        // POST /uploads with the same key can reserve another asset after
        // completion excludes the first from reservation lookup. By-id renewal
        // instead returns that first asset's receipt if completion wins a race.
        let receipt = try UploadRecovery.validatedRenewal(try await renew(ticketID),
            previous: UploadTicket(assetID: ticketID, mode: .single))
        if receipt.uploaded == true { return .complete }
        guard let url = receipt.putURL else { throw SpatialClientError.invalidResponse }
        return .renew(url)
    }
}
