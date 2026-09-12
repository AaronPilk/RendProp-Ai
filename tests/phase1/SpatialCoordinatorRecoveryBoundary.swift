import Foundation

/// Only app/OS boundaries are substituted. The runner inserts the coordinator's
/// actual restart, pause, resume, reconnect, owner, failure and parser methods.
/// pump() is a spy, not a claim to execute camera capture or the background daemon.
@MainActor final class SpatialCoordinatorRecoveryBoundary {
    var records: [SpatialUploadRecord]
    let api: APIClient
    let session: URLSession
    var recoveryError: String?
    var restartingFrame = false
    var reconnecting = false
    var active = Set<String>()
    var writes: [[SpatialUploadRecord]] = []
    var pumps = 0
    var ownerID: String? { AuthStore.currentAccessToken.flatMap(AuthStore.jwtSubject) }
    init(record: SpatialUploadRecord, api: APIClient, session: URLSession) {
        records = [record]; self.api = api; self.session = session
    }
    private func persist() throws { writes.append(records) }
    private func pump() { pumps += 1 }
    // ACTUAL_METHODS
}
