import Foundation

@main
struct SessionConnectionTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    @MainActor
    static func main() async throws {
        // A broken continuation must fail this verification, not hang forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("FAIL: session tests exceeded their deadline\n", stderr)
            exit(1)
        }
        var ready = false
        var attempts = 0
        var concurrent = 0
        var maximum = 0
        var states: [SessionConnection.State] = []
        let connection = SessionConnection(retryDelay: 1_000_000, attempt: {
            attempts += 1
            concurrent += 1
            maximum = max(maximum, concurrent)
            try? await Task.sleep(nanoseconds: 2_000_000)
            concurrent -= 1
            return ready
        }, stateChanged: { states.append($0) })
        let callers = (0..<4).map { _ in Task { await connection.connect() } }
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(states.contains(.retrying), "failure must expose retry state")
        try check(attempts > 1, "failed original attempts must automatically retry")
        ready = true
        for caller in callers { try check(await caller.value, "original tap must resume") }
        try check(maximum == 1, "concurrent callers must share exactly one attempt")
        try check(states.last == .idle, "notice must dismiss after recovery")
        print("PASS actual source: four concurrent actions resume after recovery, max one attempt")

        ready = false
        let cancelled = Task { await connection.connect() }
        let survivor = Task { await connection.connect() }
        try await Task.sleep(nanoseconds: 5_000_000)
        cancelled.cancel()
        try check(await cancelled.value == false, "cancelled waiter must return false")
        ready = true
        try check(await survivor.value, "cancelling one action must not cancel another")
        print("PASS actual source: independent waiter cancellation")

        let old = Task { await connection.connect() }
        connection.cancelAll()
        old.cancel()
        try check(await old.value == false, "pre-cancelled action must not restart")
        let next = Task { await connection.connect() }
        try check(await next.value, "next generation must still connect")
        print("PASS actual source: cancellation and subsequent generation")

        var tries = 0
        let manualRetry = SessionConnection(retryDelay: 30_000_000_000, attempt: {
            tries += 1
            return tries > 1
        }, stateChanged: { _ in })
        let retryCaller = Task { await manualRetry.connect() }
        try await Task.sleep(nanoseconds: 5_000_000)
        manualRetry.retryNow()
        try check(await retryCaller.value, "Retry must wake the same long-delay attempt")
        try check(tries == 2, "Retry must not duplicate action")
        print("PASS actual source: Retry wakes backoff without a duplicate signup")
    }
}
