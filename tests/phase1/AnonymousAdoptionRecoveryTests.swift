import Foundation

@main @MainActor
struct AnonymousAdoptionRecoveryTests {
    static var assertions = 0
    static var failed = 0
    static let source = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let destination = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let other = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    static func check(_ ok: Bool, _ message: String) {
        assertions += 1
        if !ok { failed += 1; print("FAIL: \(message)") }
    }
    static func token(_ id: UUID, anonymous: Bool, expired: Bool = false) -> String {
        let bytes = try! JSONSerialization.data(withJSONObject: ["sub": id.uuidString.lowercased(), "is_anonymous": anonymous, "exp": expired ? 1 : 9999999999])
        let payload = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "synthetic.\(payload).unsigned"
    }
    final class Store {
        var raw: String?; var failRead = false; var failWrite = false; var failRemove = false
        var writes = 0; var removals = 0; var messages: [String?] = []
    }
    static func make(_ store: Store, send: @escaping AnonymousAdoptionRecovery.Transport) -> AnonymousAdoptionRecovery {
        AnonymousAdoptionRecovery(apiBase: URL(string: "https://fixture.invalid/functions/v1")!,
            authBase: URL(string: "https://fixture.invalid/auth/v1")!, anonKey: "synthetic-anon",
            read: { if store.failRead { throw AnonymousAdoptionRecovery.RecoveryError.storage }; return store.raw },
            write: { store.writes += 1; if store.failWrite { return false }; store.raw = $0; return true },
            remove: { store.removals += 1; if store.failRemove { return false }; store.raw = nil; return true },
            send: send, changed: { store.messages.append($0) })
    }
    static func prepared(_ value: AnonymousAdoptionRecovery, expired: Bool = false) throws {
        try value.prepare(sourceAccess: token(source, anonymous: true, expired: expired), sourceRefresh: "synthetic-source-refresh",
                          destinationAccess: token(destination, anonymous: false))
    }
    static func response(_ req: URLRequest, _ body: [String: Any], status: Int = 200) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    static func success(_ req: URLRequest, patch: [String: Any] = [:]) -> (Data, HTTPURLResponse) {
        var body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        body.removeValue(forKey: "anonymous_token")
        body["ok"] = true; body["adopted"] = true; body["org_id"] = other.uuidString
        body.merge(patch) { _, replacement in replacement }
        return response(req, body)
    }
    static let noNetwork: AnonymousAdoptionRecovery.Transport = { _ in throw URLError(.notConnectedToInternet) }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); check(false, label) } catch { check(true, label) }
    }
    static func main() async {
        do { try await run() } catch { check(false, "unexpected fixture exception") }
        if CommandLine.arguments.contains("--force-failure") { check(false, "deliberate negative control") }
        if failed > 0 { print("FAIL: \(failed) / \(assertions) assertions"); exit(1) }
        print("PASS: \(assertions) assertions; production Foundation recovery; no real network/Keychain")
    }
    static func run() async throws {
        let store = Store(), core = make(Store(), send: noNetwork)
        let recovery = make(store, send: noNetwork)
        try prepared(recovery)
        let first = try recovery.pending()!
        check(first.sourceUserID == source && first.destinationUserID == destination, "source and destination persisted")
        check(first.sourceRefreshToken == "synthetic-source-refresh", "refresh survives active-session overwrite")
        check(first.version == 1 && store.writes == 1, "one atomic versioned envelope")
        let restarted = make(store, send: noNetwork)
        check(try restarted.pending() == first, "restart restores exact operation and source credentials")
        try prepared(restarted)
        check(store.writes == 1, "same handoff reuses operation")
        rejects("different destination cannot overwrite pending") {
            try recovery.prepare(sourceAccess: token(source, anonymous: true), sourceRefresh: "new", destinationAccess: token(other, anonymous: false))
        }
        rejects("different source cannot evict pending") {
            try recovery.prepare(sourceAccess: token(other, anonymous: true), sourceRefresh: "new", destinationAccess: token(destination, anonymous: false))
        }
        check(try recovery.pending() == first, "conflicts preserve bytes")
        try recovery.prepare(sourceAccess: token(source, anonymous: true), sourceRefresh: "source-rotated-while-still-active", destinationAccess: token(destination, anonymous: false))
        check(try recovery.pending()?.operationID == first.operationID, "pre-activation retry preserves operation identity")
        check(try recovery.pending()?.sourceRefreshToken == "source-rotated-while-still-active", "pre-activation retry captures current rotated source credentials")
        for invalid in ["bad", token(source, anonymous: false), token(destination, anonymous: true)] {
            rejects("invalid identity refuses prepare") { try core.prepare(sourceAccess: invalid, sourceRefresh: nil, destinationAccess: token(destination, anonymous: false)) }
        }
        for failure in ["read", "write", "malformed", "version"] {
            let cell = Store(); cell.failRead = failure == "read"; cell.failWrite = failure == "write"
            if failure == "malformed" { cell.raw = "not-json" }
            if failure == "version" { cell.raw = store.raw!.replacingOccurrences(of: "\"version\":1", with: "\"version\":2") }
            let value = make(cell, send: noNetwork)
            rejects("\(failure) refuses session replacement") { try prepared(value) }
            check(cell.removals == 0, "\(failure) never clears recovery")
        }
        await recovery.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { true })
        check(store.raw != nil && store.removals == 0, "offline retains recovery")
        for patch: [String: Any] in [["ok": false], ["adopted": false], ["operation_id": other.uuidString],
                                    ["source_user_id": other.uuidString], ["destination_user_id": other.uuidString], ["org_id": "invalid"]] {
            let cell = Store()
            let target = make(cell) { success($0, patch: patch) }
            try prepared(target)
            await target.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { true })
            check(cell.raw != nil && cell.removals == 0, "unbound/no-op receipt retains recovery")
        }
        var sends = 0
        let wrong = make(store) { req in sends += 1; return success(req) }
        await wrong.retry(destinationAccess: token(other, anonymous: false), isCurrent: { true })
        await wrong.retry(destinationAccess: token(source, anonymous: true), isCurrent: { true })
        await wrong.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { false })
        check(sends == 0 && store.raw != nil, "other account/guest/logout cannot submit")
        for stage in ["adopt", "refresh"] {
            let cell = Store(); var current = true; var calls = 0
            let target = make(cell) { req in
                calls += 1
                if stage == "adopt" { current = false; return success(req) }
                if calls == 1 { return response(req, ["adoption_state": "source_session_expired"], status: 409) }
                current = false
                return response(req, ["access_token": token(source, anonymous: true), "refresh_token": "synthetic-rotated-refresh"])
            }
            try prepared(target)
            await target.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { current })
            check(cell.raw != nil && cell.removals == 0, "logout during \(stage) cannot clear receipt")
            check(calls == (stage == "adopt" ? 1 : 2), "logout fences later \(stage) requests")
            if stage == "refresh" { check(try target.pending()?.sourceRefreshToken == "synthetic-rotated-refresh", "rotation durable despite logout, without active session overwrite") }
        }
        for refreshStatus in [200, 401, 503] {
            let cell = Store(); var calls = 0
            let target = make(cell) { req in
                calls += 1
                check(req.timeoutInterval == 20, "request timeout retained")
                if calls == 1 { return response(req, ["adoption_state": "source_session_expired"], status: 409) }
                if calls == 2 {
                    check(req.url?.query == "grant_type=refresh_token", "source refresh endpoint")
                    check(req.value(forHTTPHeaderField: "Authorization") == nil, "identified bearer never used as source refresh credential")
                    return response(req, ["access_token": token(source, anonymous: true), "refresh_token": "synthetic-rotated-refresh"], status: refreshStatus)
                }
                check(cell.raw?.contains("synthetic-rotated-refresh") == true, "rotate persisted before second adoption POST")
                return success(req)
            }
            try prepared(target, expired: true)
            await target.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { true })
            check(calls == (refreshStatus == 200 ? 3 : 2), "bounded refresh attempt")
            check((cell.raw == nil) == (refreshStatus == 200), "only verified receipt clears recovery")
        }
        for badSource in [token(other, anonymous: true), token(source, anonymous: false)] {
            let cell = Store(); var calls = 0
            let target = make(cell) { req in
                calls += 1
                return calls == 1 ? response(req, ["adoption_state": "source_session_expired"], status: 409)
                    : response(req, ["access_token": badSource, "refresh_token": "wrong-binding"])
            }
            try prepared(target)
            await target.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { true })
            check(calls == 2 && cell.writes == 1 && cell.raw != nil, "wrong refreshed identity never saved")
        }
        let replayStore = Store(); var replayCalls = 0
        let replay = make(replayStore) { req in replayCalls += 1; return success(req) }
        try prepared(replay, expired: true)
        await replay.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { true })
        check(replayCalls == 1 && replayStore.raw == nil, "receipt clears expired source without refresh")
        let failedRemoval = Store(); failedRemoval.failRemove = true
        let removal = make(failedRemoval) { success($0) }; try prepared(removal)
        await removal.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { true })
        check(failedRemoval.raw != nil, "failed Keychain removal retains operation")
        let reentrantStore = Store(); var reentrant: AnonymousAdoptionRecovery!; var reentrantCalls = 0
        reentrant = make(reentrantStore) { req in
            reentrantCalls += 1
            await reentrant.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { true })
            return success(req)
        }
        try prepared(reentrant)
        await reentrant.retry(destinationAccess: token(destination, anonymous: false), isCurrent: { true })
        check(reentrantCalls == 1 && reentrantStore.raw == nil, "reentrant client shares one attempt")
    }
}
