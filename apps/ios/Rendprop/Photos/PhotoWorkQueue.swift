import Foundation
import Combine

/// Owns photo work independently of a navigation destination. Percentages count
/// attempted photos; the provider does not expose progress within one photo.
@MainActor
final class PhotoWorkQueue: ObservableObject {
    static let shared = PhotoWorkQueue()
    struct Failure {
        let photoID: String
        let position: Int
        let error: Error
    }
    struct Job {
        let id = UUID()
        let listingID: UUID
        let title: String
        let total: Int
        var current = 0
        var currentPhotoID: String?
        var done = 0
        var failures: [Failure] = []
        var running = true
        var interrupted = false
        var attempted: Int { done + failures.count }
        var fraction: Double { total > 0 ? Double(attempted) / Double(total) : 0 }
        var percent: Int { Int((fraction * 100).rounded(.down)) }
        var remaining: Int { max(0, total - attempted) }
    }
    @Published private(set) var job: Job?
    private var task: Task<Void, Never>?
    private var identityCheck: (() -> Bool)?
    var isContextCurrent: Bool { identityCheck?() == true }
    var visibleJob: Job? { isContextCurrent ? job : nil }

    @discardableResult
    func start(listingID: UUID, title: String, photoIDs: [String],
               identityIsCurrent: @escaping () -> Bool,
               stopOnError: @escaping (Error) -> Bool,
               process: @escaping (String) async throws -> Void,
               completion: @escaping (Job) -> Void = { _ in }) -> Bool {
        guard task == nil, !photoIDs.isEmpty, identityIsCurrent() else { return false }
        let initial = Job(listingID: listingID, title: title, total: photoIDs.count)
        identityCheck = identityIsCurrent
        job = initial
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, id) in photoIDs.enumerated() {
                guard !Task.isCancelled, identityIsCurrent() else {
                    self.job?.interrupted = true; break
                }
                self.job?.current = index + 1
                self.job?.currentPhotoID = id
                do {
                    try await process(id)
                    guard !Task.isCancelled, identityIsCurrent() else {
                        self.job?.interrupted = true; break
                    }
                    self.job?.done += 1
                } catch {
                    guard !Task.isCancelled, identityIsCurrent(), !(error is CancellationError) else {
                        self.job?.interrupted = true; break
                    }
                    self.job?.failures.append(Failure(photoID: id, position: index + 1, error: error))
                    if stopOnError(error) { self.job?.interrupted = true; break }
                }
            }
            self.job?.currentPhotoID = nil
            self.job?.running = false
            self.task = nil
            // A changed account/workspace must not receive another owner's result.
            if let result = self.job { completion(result) }
            if !identityIsCurrent() { self.job = nil }
        }
        return true
    }

    func cancel() { task?.cancel() }
    func dismissResult() { if job?.running != true { job = nil } }
}
