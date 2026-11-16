// Boundary doubles only. The runner appends the actual production policy,
// reconnect, drain, parser and pre-network admission method bodies.
import Foundation

final class BoundaryTransfer {
    enum State { case running, suspended, completed, canceling }
    var state: State
    var taskDescription: String?
    var suspends = 0
    var resumes = 0
    init(_ state: State, key: String) { self.state = state; taskDescription = key }
    func suspend() { suspends += 1; state = .suspended }
    func resume() { resumes += 1; state = .running }
    func cancel() { state = .canceling }
}
final class BoundarySession {
    let tasks: [BoundaryTransfer]
    private let repeatedCallbackDelay: UInt64
    private var callbackCalls = 0
    init(_ tasks: [BoundaryTransfer], repeatedCallbackDelay: UInt64) {
        self.tasks = tasks; self.repeatedCallbackDelay = repeatedCallbackDelay
    }
    func getAllTasks(_ completion: @escaping ([BoundaryTransfer]) -> Void) {
        callbackCalls += 1
        guard callbackCalls > 1, repeatedCallbackDelay > 0 else { completion(tasks); return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: repeatedCallbackDelay)
            completion(tasks)
        }
    }
}
struct UIBackgroundTaskIdentifier: Equatable {
    let raw: Int
    static let invalid = Self(raw: -1)
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var begins = 0
    var ends = 0
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        begins += 1; return UIBackgroundTaskIdentifier(raw: begins)
    }
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) { ends += 1 }
}
struct BoundaryRecord {
    let id: UUID
    var isUserPaused = false
    let frames = [0]
}
@MainActor final class SpatialUploadCoordinator {
    let session: BoundarySession
    var reconnecting = false
    var records: [BoundaryRecord]
    var active = Set<String>()
    var preparingTransfers = Set<String>()
    var starting = Set<UUID>()
    var recoveryError: String?
    var backgroundDrain = UIBackgroundTaskIdentifier.invalid
    var drainTask: Task<Void, Never>?
    var finishBackgroundEvents: (() -> Void)?
    var journalFlushes = 0
    var pumpCalls = 0
    var generationCalls = 0
    init(tasks: [BoundaryTransfer], id: UUID, repeatedCallbackDelay: UInt64) {
        session = BoundarySession(tasks, repeatedCallbackDelay: repeatedCallbackDelay)
        records = [BoundaryRecord(id: id)]
    }
    func owns(_ record: BoundaryRecord) -> Bool { true }
    func pruneFinishedRecords() {}
    func flushJournalQuietly() { journalFlushes += 1 }
}
