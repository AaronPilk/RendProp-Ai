import Foundation
import Combine

/// Owns photo work independently of a navigation destination. Each batch runs
/// its own photos in order; unrelated families can belong to different batches.
/// Percentages count attempted photos, not provider progress within one photo.
@MainActor
final class PhotoWorkQueue: ObservableObject {
    static let shared = PhotoWorkQueue()
    static let maximumRunningJobs = 4
    /// The request and its final before-send check inherit this exact job ID.
    /// Stopping one batch must never stop another batch's unsent photo.
    @TaskLocal static var executingJobID: UUID?

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
    struct Job: Identifiable {
        let id = UUID()
        let startedAt = Date()
        let listingID: UUID
        let title: String
        let total: Int
        /// Every selected family is reserved until this batch finishes. This
        /// includes later photos, so a second job cannot change a parent while
        /// its first batch is waiting to reach that photo.
        let photoKeys: Set<String>
        var current = 0
        var currentPhotoID: String?
        var phase: Phase? = .preparing
        var done = 0
        var failures: [Failure] = []
        var running = true
        var stopRequested = false
        var interrupted = false
        var attempted: Int { done + failures.count }
        var fraction: Double { total > 0 ? Double(attempted) / Double(total) : 0 }
        var percent: Int { Int((fraction * 100).rounded(.down)) }
        var remaining: Int { max(0, total - attempted) }
    }

    @Published private(set) var jobs: [Job] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var identityChecks: [UUID: () -> Bool] = [:]
    /// The last job is retained for older one-job callers and diagnostics.
    var job: Job? { jobs.last }
    var isContextCurrent: Bool { job.map { identityChecks[$0.id]?() == true } == true }
    var visibleJobs: [Job] { jobs.filter { identityChecks[$0.id]?() == true } }
    var visibleJob: Job? { visibleJobs.first(where: \.running) ?? visibleJobs.last }
    var hasRunningJobs: Bool { jobs.contains { $0.running } }
    func job(id: UUID) -> Job? { visibleJobs.first { $0.id == id } }
    func isPhotoBusy(listingID: UUID, key: String) -> Bool {
        visibleJobs.contains { $0.running && $0.listingID == listingID && $0.photoKeys.contains(key) }
    }
    /// Only the task that owns a batch may dispatch its next paid request.
    var permitsUnsentDispatch: Bool {
        guard let id = Self.executingJobID else { return !hasRunningJobs }
        return identityChecks[id]?() == true && jobs.contains { $0.id == id && $0.running && !$0.stopRequested }
            && tasks[id]?.isCancelled == false
    }

    @discardableResult
    func start(listingID: UUID, title: String, photoIDs: [String], photoKeys: [String]? = nil,
               identityIsCurrent: @escaping () -> Bool,
               stopOnError: @escaping (Error) -> Bool,
               process: @escaping (String) async throws -> Void,
               completion: @escaping (Job) -> Void = { _ in }) -> Bool {
        let keys = photoKeys ?? photoIDs
        guard !photoIDs.isEmpty, keys.count == photoIDs.count,
              Set(keys).count == keys.count, identityIsCurrent(),
              visibleJobs.filter(\.running).count < Self.maximumRunningJobs else { return false }
        let reserved = Set(keys)
        guard !visibleJobs.contains(where: { $0.running && $0.listingID == listingID && !$0.photoKeys.isDisjoint(with: reserved) }) else {
            return false
        }
        let initial = Job(listingID: listingID, title: title, total: photoIDs.count, photoKeys: reserved)
        identityChecks[initial.id] = identityIsCurrent
        jobs.append(initial)
        tasks[initial.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, photoID) in photoIDs.enumerated() {
                guard !Task.isCancelled, self.jobs.first(where: { $0.id == initial.id })?.stopRequested != true,
                      identityIsCurrent() else {
                    self.update(initial.id) { $0.interrupted = true }; break
                }
                self.update(initial.id) { job in
                    job.current = index + 1
                    job.currentPhotoID = photoID
                    job.phase = .preparing
                }
                do {
                    try await Self.$executingJobID.withValue(initial.id) { try await process(photoID) }
                    guard !Task.isCancelled, identityIsCurrent() else {
                        self.update(initial.id) { $0.interrupted = true }; break
                    }
                    self.update(initial.id) { $0.done += 1 }
                } catch {
                    guard !Task.isCancelled, identityIsCurrent(), !(error is CancellationError) else {
                        self.update(initial.id) { $0.interrupted = true }; break
                    }
                    self.update(initial.id) { $0.failures.append(Failure(photoID: photoID, position: index + 1, error: error)) }
                    if stopOnError(error) {
                        self.update(initial.id) { $0.interrupted = true }; break
                    }
                }
            }
            self.update(initial.id) { job in
                job.currentPhotoID = nil
                job.phase = nil
                job.running = false
            }
            self.tasks.removeValue(forKey: initial.id)
            if let result = self.jobs.first(where: { $0.id == initial.id }) { completion(result) }
            // New saved versions may now exist for this house; the app backs
            // them up without waiting for the house to be opened again.
            NotificationCenter.default.post(name: .rendpropPhotoWorkFinished, object: nil)
            if !identityIsCurrent() { self.remove(initial.id) }
        }
        return true
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var value = jobs[index]
        change(&value)
        jobs[index] = value
    }
    private func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        identityChecks.removeValue(forKey: id)
    }

    /// A late callback from another photo/run/account cannot change this job.
    func report(_ phase: Phase, jobID: UUID, photoID: String) {
        guard identityChecks[jobID]?() == true,
              let job = jobs.first(where: { $0.id == jobID }), job.running,
              job.currentPhotoID == photoID, tasks[jobID]?.isCancelled == false,
              phase.rawValue >= (job.phase?.rawValue ?? 0) else { return }
        update(jobID) { $0.phase = phase }
    }

    func cancel() { for task in tasks.values { task.cancel() } }
    func cancel(listingID: UUID) {
        for job in jobs where job.listingID == listingID { tasks[job.id]?.cancel() }
    }
    func cancel(jobID: UUID) { tasks[jobID]?.cancel() }
    func stopRemaining(jobID: UUID) {
        guard identityChecks[jobID]?() == true,
              jobs.first(where: { $0.id == jobID })?.running == true else { return }
        update(jobID) { $0.stopRequested = true; $0.interrupted = true }
    }
    func stopRemaining() { if let id = visibleJob?.id { stopRemaining(jobID: id) } }
    func dismissResult(jobID: UUID) {
        guard jobs.first(where: { $0.id == jobID })?.running == false else { return }
        remove(jobID)
    }
    func dismissResult() { if let id = visibleJob?.id { dismissResult(jobID: id) } }
}

extension Notification.Name {
    /// Posted on the main actor when a batch of photo edits ends, whatever its outcome.
    static let rendpropPhotoWorkFinished = Notification.Name("rendprop.photoWorkFinished")
}
