import Foundation

/// A removal reserves the listing before waiting for its older append to
/// finish. New append passes cannot overtake the acknowledged subtraction.
@MainActor final class PhotoGalleryMutationFence {
    private var syncing: Set<UUID> = []
    private var removing: Set<UUID> = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    func blocksSync(_ listingID: UUID) -> Bool { removing.contains(listingID) }
    func syncDidStart(_ listingID: UUID) { syncing.insert(listingID) }
    func syncDidFinish(_ listingID: UUID) {
        syncing.remove(listingID)
        waiting.removeValue(forKey: listingID)?.resume()
    }
    func acquireRemoval(_ listingID: UUID) async throws {
        guard removing.insert(listingID).inserted else { throw PhotoListingRemovalJournal.Failure.pendingOperation }
        if syncing.contains(listingID) {
            await withCheckedContinuation { waiting[listingID] = $0 }
        }
    }
    func releaseRemoval(_ listingID: UUID) { removing.remove(listingID) }
}
