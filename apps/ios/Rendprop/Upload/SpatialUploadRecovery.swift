import Foundation

/// A retry may renew one existing physical-write authority, not buy a new
/// upload. The transport service itself decides whether that authority is still
/// planned or has a recoverable stored receipt. Unknown dispatches fail closed.
enum SpatialUploadRecovery {
    enum Probe { case complete, needsReconciliation }
    struct Renewal { let ticketID: String; let putURL: URL }
    enum Result { case complete, renew(URL) }

    static func reconcile(ticketID: String,
                          probe: () async throws -> Probe,
                          renew: () async throws -> Renewal) async throws -> Result {
        if case .complete = try await probe() { return .complete }
        let receipt = try await renew()
        guard receipt.ticketID == ticketID, receipt.putURL.scheme == "https",
              receipt.putURL.host != nil, receipt.putURL.user == nil, receipt.putURL.password == nil else {
            throw SpatialClientError.invalidResponse
        }
        return .renew(receipt.putURL)
    }
}
