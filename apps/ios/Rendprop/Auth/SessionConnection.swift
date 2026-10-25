import Foundation

/// One retry loop, any number of independently cancellable feature callers.
/// No UI or Supabase dependency: the same implementation is exercised by the
/// standalone Swift concurrency tests as well as the application.
@MainActor
final class SessionConnection {
    enum State: Equatable { case idle, connecting, retrying }

    private let attempt: @MainActor () async -> Bool
    private let stateChanged: @MainActor (State) -> Void
    private let delay: UInt64
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var worker: Task<Void, Never>?
    private var pause: Task<Void, Never>?
    private var runID: UUID?

    init(retryDelay: UInt64 = 3_000_000_000,
         attempt: @escaping @MainActor () async -> Bool,
         stateChanged: @escaping @MainActor (State) -> Void) {
        self.delay = retryDelay
        self.attempt = attempt
        self.stateChanged = stateChanged
    }

    func connect() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = continuation
                startIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    /// Wake the existing retry loop; never create a competing signup request.
    func retryNow() { pause?.cancel() }

    func cancelAll() {
        worker?.cancel()
        pause?.cancel()
        worker = nil
        pause = nil
        runID = nil
        let pending = waiters.values
        waiters.removeAll()
        stateChanged(.idle)
        for waiter in pending { waiter.resume(returning: false) }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
        if waiters.isEmpty { cancelAll() }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        let id = UUID()
        runID = id
        stateChanged(.connecting)
        worker = Task { [weak self] in
            guard let self else { return }
            var failures: UInt64 = 0
            while !Task.isCancelled, self.runID == id, !self.waiters.isEmpty {
                let connected = await self.attempt()
                guard !Task.isCancelled, self.runID == id else { return }
                if connected {
                    self.worker = nil
                    self.runID = nil
                    let pending = self.waiters.values
                    self.waiters.removeAll()
                    self.stateChanged(.idle)
                    for waiter in pending { waiter.resume(returning: true) }
                    return
                }
                self.stateChanged(.retrying)
                failures = min(failures + 1, 10)
                let seconds = min(self.delay * failures, 30_000_000_000)
                let sleep = Task<Void, Never> { try? await Task.sleep(nanoseconds: seconds) }
                self.pause = sleep
                await sleep.value
                guard !Task.isCancelled, self.runID == id else { return }
                self.pause = nil
            }
        }
    }
}
