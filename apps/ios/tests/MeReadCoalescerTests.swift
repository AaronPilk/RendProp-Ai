import Foundation

enum CloudSyncError: Error { case identityChanged }

@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "account-A"
    var syncSessionRevision: UInt64 = 1
}

@MainActor enum WorkspaceContext {
    static var selectedOrgID: UUID? = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
}

extension Notification.Name {
    static let rendpropPlanChanged = Notification.Name("closed-plan-change")
    static let rendpropWorkspaceChanged = Notification.Name("closed-workspace-change")
}

@MainActor final class ReadGate {
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            waiting = true
            self.continuation = continuation
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor final class LiveAPIClient {
    var beforeSendGate: ReadGate?
    var responseGate: ReadGate?
    var preparedOrg: String?
    var sends = 0

    func url(_ parts: [String]) -> URL { URL(string: "https://example.invalid/" + parts.joined(separator: "/"))! }
    func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let org = WorkspaceContext.selectedOrgID {
            request.setValue(org.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id")
        }
        return request
    }
    func execute(_ request: URLRequest, beforeSend: (@MainActor () throws -> Void)? = nil) async throws -> Data {
        preparedOrg = request.value(forHTTPHeaderField: "X-Org-Id")
        if let beforeSendGate { await beforeSendGate.hold() }
        try beforeSend?()
        sends += 1
        if let responseGate { await responseGate.hold() }
        return Data((preparedOrg ?? "missing-org").utf8)
    }

    // EXTRACTED_SHARED_READ
    func read() async throws -> Data { try await sharedMeRead() }
}

// EXTRACTED_COALESCER

@main struct MeReadCoalescerTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        func waitFor(_ predicate: @MainActor () -> Bool) async {
            for _ in 0..<10_000 {
                if predicate() { return }
                await Task.yield()
            }
            preconditionFailure("closed continuation was not reached")
        }
        let orgA = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let orgB = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        func reset() {
            AuthStore.shared.userID = "account-A"
            AuthStore.shared.syncSessionRevision = 1
            WorkspaceContext.selectedOrgID = orgA
            MeReadCoalescer.shared.invalidate()
        }
        func rejectedIdentity(_ task: Task<Data, Error>) async -> Bool {
            do { _ = try await task.value; return false }
            catch CloudSyncError.identityChanged { return true }
            catch { return false }
        }

        reset()
        let keyA = MeReadCoalescer.currentKey()!
        let cached = try await MeReadCoalescer.shared.data(key: keyA, reuseWithin: 3) { Data("A".utf8) }
        check(cached == Data("A".utf8), "same-context /me answer is cached")
        WorkspaceContext.selectedOrgID = orgB
        var wrongCacheFetches = 0
        do {
            _ = try await MeReadCoalescer.shared.data(key: keyA, reuseWithin: 3) {
                wrongCacheFetches += 1; return Data("wrong".utf8)
            }
            check(false, "cached /me answer cannot cross library")
        } catch CloudSyncError.identityChanged {
            check(wrongCacheFetches == 0, "changed library refuses cache before any fetch")
        }
        var deferredFetches = 0
        do {
            _ = try await MeReadCoalescer.shared.data(key: keyA, reuseWithin: 0) {
                deferredFetches += 1; return Data("wrong".utf8)
            }
            check(false, "captured /me key cannot start a fetch in a different library")
        } catch CloudSyncError.identityChanged {
            check(deferredFetches == 0, "deferred fetch is fenced before request creation")
        }

        reset()
        let pendingGate = ReadGate()
        let pendingKey = MeReadCoalescer.currentKey()!
        let pending = Task { @MainActor in
            try await MeReadCoalescer.shared.data(key: pendingKey, reuseWithin: 0) {
                await pendingGate.hold(); return Data("A".utf8)
            }
        }
        await waitFor { pendingGate.waiting }
        WorkspaceContext.selectedOrgID = orgB
        pendingGate.release()
        check(await rejectedIdentity(pending), "completed /me answer cannot cross library")

        reset()
        let joinedGate = ReadGate()
        let joiningKey = MeReadCoalescer.currentKey()!
        let owner = Task { @MainActor in
            try await MeReadCoalescer.shared.data(key: joiningKey, reuseWithin: 0) {
                await joinedGate.hold(); return Data("A".utf8)
            }
        }
        await waitFor { joinedGate.waiting }
        var joinerEntered = false
        let joiner = Task { @MainActor in
            joinerEntered = true
            return try await MeReadCoalescer.shared.data(key: joiningKey, reuseWithin: 0) {
                preconditionFailure("joined caller must not start another fetch")
            }
        }
        await waitFor { joinerEntered }
        WorkspaceContext.selectedOrgID = orgB
        joinedGate.release()
        let ownerRejected = await rejectedIdentity(owner)
        let joinerRejected = await rejectedIdentity(joiner)
        check(ownerRejected && joinerRejected,
              "joined /me readers cannot receive an answer after a library switch")

        reset()
        let beforeGate = ReadGate()
        let beforeClient = LiveAPIClient(); beforeClient.beforeSendGate = beforeGate
        let before = Task { @MainActor in try await beforeClient.read() }
        await waitFor { beforeGate.waiting }
        check(beforeClient.preparedOrg == orgA.uuidString.lowercased(), "request binds its captured library")
        WorkspaceContext.selectedOrgID = orgB
        beforeGate.release()
        check(await rejectedIdentity(before) && beforeClient.sends == 0,
              "library switch during token wait cannot dispatch an old /me read")

        reset()
        let responseGate = ReadGate()
        let responseClient = LiveAPIClient(); responseClient.responseGate = responseGate
        let response = Task { @MainActor in try await responseClient.read() }
        await waitFor { responseGate.waiting }
        AuthStore.shared.syncSessionRevision = 2
        responseGate.release()
        check(await rejectedIdentity(response) && responseClient.sends == 1,
              "session switch after response dispatch cannot return or cache that answer")

        reset()
        let actorKey = MeReadCoalescer.currentKey()!
        AuthStore.shared.userID = "account-B"
        check(MeReadCoalescer.currentKey() != actorKey, "account is part of the cache key")
        let absent = LiveAPIClient(); AuthStore.shared.userID = nil
        let noAccount = Task { @MainActor in try await absent.read() }
        check(await rejectedIdentity(noAccount) && absent.sends == 0,
              "signed-out /me does not dispatch an unbound request")

        reset()
        let sharedGate = ReadGate()
        let shared = LiveAPIClient(); shared.responseGate = sharedGate
        let first = Task { @MainActor in try await shared.read() }
        await waitFor { sharedGate.waiting }
        let second = Task { @MainActor in try await shared.read() }
        sharedGate.release()
        let firstData = try await first.value
        let secondData = try await second.value
        check(firstData == secondData && shared.sends == 1,
              "same-context readers share a request or its three-second answer")
        print("PASSED: \(checks) actual /me coalescer context, cache and dispatch assertions")
    }
}
