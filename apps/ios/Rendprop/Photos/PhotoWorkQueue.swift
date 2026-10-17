import Foundation
import Combine

/// Owns photo work independently of a navigation destination. Percentages count
/// attempted photos; the provider does not expose progress within one photo.
@MainActor
final class PhotoWorkQueue: ObservableObject {
    static let shared = PhotoWorkQueue()
    /// The synchronous photo endpoint supplies no provider percentage or
    /// intermediate queue/QC receipt. These are observable native boundaries.
    enum Phase: Int, Sendable {
        case preparing, uploading, generatingAndChecking, checkingReturnedImage, saving
        var title: String {
            switch self {
            case .preparing: return "Preparing photo"
            case .uploading: return "Uploading source"
            case .generatingAndChecking: return "Generating and checking"
            case .checkingReturnedImage: return "Checking returned image"
            case .saving: return "Saving version"
            }
        }
        var detail: String {
            switch self {
            case .preparing: return "Your original and earlier edits stay unchanged."
            case .uploading: return "Saving the retained source for this listing."
            case .generatingAndChecking: return "The service does not report a percentage. Your saved versions are safe."
            case .checkingReturnedImage: return "Reading the returned image before saving it."
            case .saving: return "Keeping the new version and its disclosure together."
            }
        }
    }
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
        var phase: Phase? = .preparing
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
                self.job?.phase = .preparing
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
            self.job?.phase = nil
            self.job?.running = false
            self.task = nil
            // A changed account/workspace must not receive another owner's result.
            if let result = self.job { completion(result) }
            if !identityIsCurrent() { self.job = nil }
        }
        return true
    }

    /// A late callback from another photo/run/account cannot change current UI.
    /// No timer advances a phase; only the work which observed its boundary does.
    func report(_ phase: Phase, jobID: UUID, photoID: String) {
        guard isContextCurrent, job?.id == jobID, job?.running == true,
              job?.currentPhotoID == photoID, task?.isCancelled == false,
              phase.rawValue >= (job?.phase?.rawValue ?? 0) else { return }
        job?.phase = phase
    }

    func cancel() { task?.cancel() }
    func dismissResult() { if job?.running != true { job = nil } }
}
