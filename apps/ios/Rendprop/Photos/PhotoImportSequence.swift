import Foundation

struct PhotoImportContext: Equatable, Sendable {
    let owner: String?
    let revision: UInt64
    let workspace: UUID?

    func matches(owner: String?, revision: UInt64, workspace: UUID?) -> Bool {
        self.owner == owner && self.revision == revision && self.workspace == workspace
    }
}

final class PhotoImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct PhotoImportFailure: Sendable {
    let position: Int // zero-based selection position, never completion order
    let message: String
}

struct PhotoImportItem: Sendable {
    let position: Int
    let url: URL
}

struct PhotoImportBatch: Sendable {
    let id: UUID
    let requestedCount: Int
    let items: [PhotoImportItem]
    let failures: [PhotoImportFailure]
    let directory: URL?
    let context: PhotoImportContext
    let cancellation: PhotoImportCancellation

    func removeTemporaryFiles() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}

struct PhotoImportReport: Sendable {
    let requestedCount: Int
    let savedPositions: [Int]
    let failures: [PhotoImportFailure]

    var message: String? {
        guard !failures.isEmpty else { return nil }
        let positions = failures.sorted { $0.position < $1.position }.map { String($0.position + 1) }
        let shown = positions.prefix(12).joined(separator: ", ")
        let more = positions.count > 12 ? " and \(positions.count - 12) more" : ""
        let first = failures.sorted { $0.position < $1.position }.first!.message
        return "\(savedPositions.count) of \(requestedCount) photos saved. Couldn't import selections \(shown)\(more). \(first) Your saved photos are safe; add only the missing photos again."
    }
}

/// One provider file at a time. Synchronous provider completions are trampolined
/// through the queue, so a large selection cannot recurse or decode in parallel.
final class PhotoImportSerialLoader: @unchecked Sendable {
    typealias Load = (Int, @escaping (Result<URL, Error>) -> Void) -> Void
    private let queue = DispatchQueue(label: "com.rendprop.photo-import-files")
    private let total: Int
    private let cancellation: PhotoImportCancellation
    private let load: Load
    private let progress: (Int) -> Void
    private let completion: ([PhotoImportItem], [PhotoImportFailure]) -> Void
    private var items: [PhotoImportItem] = []
    private var failures: [PhotoImportFailure] = []
    private var next = 0
    private var awaiting: Int?

    private init(count: Int, cancellation: PhotoImportCancellation,
                 load: @escaping Load, progress: @escaping (Int) -> Void,
                 completion: @escaping ([PhotoImportItem], [PhotoImportFailure]) -> Void) {
        total = count; self.cancellation = cancellation; self.load = load
        self.progress = progress; self.completion = completion
    }

    static func start(count: Int, cancellation: PhotoImportCancellation,
                      load: @escaping Load, progress: @escaping (Int) -> Void = { _ in },
                      completion: @escaping ([PhotoImportItem], [PhotoImportFailure]) -> Void) {
        precondition(count >= 0)
        let worker = PhotoImportSerialLoader(count: count, cancellation: cancellation,
                                            load: load, progress: progress, completion: completion)
        worker.queue.async { worker.advance() }
    }

    private func advance() {
        if cancellation.isCancelled {
            for position in next..<total {
                failures.append(PhotoImportFailure(position: position, message: "Import was cancelled before this photo was loaded."))
            }
            next = total
        }
        guard next < total else { completion(items, failures); return }
        let position = next
        awaiting = position
        load(position) { [self] result in
            queue.async {
                // An errant provider callback cannot append twice or admit the
                // next selected photo while this one is still being handled.
                guard self.awaiting == position else { return }
                self.awaiting = nil
                switch result {
                case .success(let url): self.items.append(PhotoImportItem(position: position, url: url))
                case .failure(let error):
                    self.failures.append(PhotoImportFailure(position: position, message: error.localizedDescription))
                    if error is CancellationError { self.cancellation.cancel() }
                }
                self.next = position + 1
                self.progress(self.next)
                self.advance()
            }
        }
    }
}

/// Existing galleries sort descending by capture ID. Allocate a batch in that
/// order so the first selected photo stays first; repeat imports stay ahead of
/// earlier batches even if a large batch previously advanced the timestamp.
enum PhotoImportOrder {
    static func galleryStamp(createdAt: Date, importOrderID: String?) -> Int64 {
        importOrderID.flatMap { Int64($0.prefix(15)) } ?? Int64(createdAt.timeIntervalSince1970 * 1000)
    }

    static func ids(count: Int, existing: [String], now: Date = Date(),
                    uuid: () -> UUID = { UUID() }) -> [String] {
        precondition(count >= 0)
        let prior = existing.compactMap { Int64($0.prefix(15)) }.max() ?? 0
        let clock = Int64(now.timeIntervalSince1970 * 1000)
        let top = max(clock, prior) + Int64(count)
        return (0..<count).map { position in
            String(format: "%015lld", top - Int64(position)) + "-" + uuid().uuidString
        }
    }
}

/// A single decode/enhancement/write is active across import batches. Input
/// files, not an array of full-resolution UIImages, wait for their turn.
enum PhotoImportWriter {
    private static let queue = DispatchQueue(label: "com.rendprop.photo-import-save", qos: .userInitiated)

    static func save(_ batch: PhotoImportBatch, existingIDs: [String],
                     process: @escaping (PhotoImportItem, String) throws -> Void,
                     progress: @escaping (Int) -> Void = { _ in },
                     completion: @escaping (PhotoImportReport) -> Void) {
        queue.async {
            defer { batch.removeTemporaryFiles() }
            let ids = PhotoImportOrder.ids(count: batch.requestedCount, existing: existingIDs)
            var saved: [Int] = []
            var failures = batch.failures
            for item in batch.items {
                guard !batch.cancellation.isCancelled else {
                    failures.append(PhotoImportFailure(position: item.position, message: "Import stopped because the account or workspace changed."))
                    continue
                }
                do {
                    try autoreleasepool { try process(item, ids[item.position]) }
                    saved.append(item.position)
                } catch {
                    failures.append(PhotoImportFailure(position: item.position, message: error.localizedDescription))
                }
                progress(saved.count + failures.count)
            }
            completion(PhotoImportReport(requestedCount: batch.requestedCount, savedPositions: saved, failures: failures))
        }
    }
}
