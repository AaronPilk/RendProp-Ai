import Foundation

// The runner inserts exact Settings deletion methods and AuthStore's existing
// JWT subject decoder. These doubles suspend at the same two async boundaries;
// they never sign in, delete files, or send an HTTP request.
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "account-a"
    var syncSessionRevision: UInt64 = 1
    var isSignedIn = true
    var signOutCalls = 0
    static var suspendToken = false
    static var tokenOverride: String?
    static var pendingToken: CheckedContinuation<Void, Never>?
    static func token(_ owner: String) -> String {
        let payload = Data(#"{"sub":"\#(owner)"}"#.utf8).base64EncodedString()
        return "synthetic.\(payload).synthetic"
    }
    static func validAccessToken() async -> String? {
        if suspendToken { await withCheckedContinuation { pendingToken = $0 } }
        return tokenOverride ?? shared.userID.map(token)
    }
    func signOut() { signOutCalls += 1; isSignedIn = false; syncSessionRevision += 1 }
    static func reset() {
        shared.userID = "account-a"; shared.syncSessionRevision = 1
        shared.isSignedIn = true; shared.signOutCalls = 0
        suspendToken = false; tokenOverride = nil; pendingToken = nil
    }
    __JWT_SUBJECT__
}

enum Config {
    static let apiBaseURL = URL(string: "https://account-deletion.fixture.invalid")
    static let supabaseAnonKey = "synthetic-public"
}
@MainActor final class URLSession {
    static let shared = URLSession()
    var requests: [URLRequest] = []
    var pending: CheckedContinuation<(Data, URLResponse), Error>?
    var serverDeletedOwners: [String] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(status: Int = 200, body: String = #"{"ok":true,"cleanup_complete":true}"#) {
        let request = requests.last!, data = Data(body.utf8)
        if (200..<300).contains(status),
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool == true,
           let bearer = request.value(forHTTPHeaderField: "Authorization"),
           let owner = AuthStore.jwtSubject(String(bearer.dropFirst(7))) { serverDeletedOwners.append(owner) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let waiter = pending!; pending = nil; waiter.resume(returning: (data, response))
    }
    func reset() { requests = []; pending = nil; serverDeletedOwners = [] }
}
enum UserFacingError { static func message(_ error: Error) -> String { error.localizedDescription } }
enum Haptics { static func success() {} }
@MainActor final class UploadSpy { var state: Int? = 1; var cancelCalls = 0; func cancel() { state = nil; cancelCalls += 1 } }
@MainActor final class DeletionHarness {
    let auth = AuthStore.shared, uploads = UploadSpy()
    var serverAccountsEnabled = true, isDeletingAccount = false, deletionPendingCleanup = false
    var showDeleteNeedsSignIn = false, showDeleteConfirm = false, showDeleteError = false, showAccountDeleted = false
    var deleteErrorMessage: String?
    var files = ["saved-account-a-media"], wipeCalls = 0, wipedOwner: String?
    var accountDeletionContext: AccountDeletionContext?
    func wipeLocalData() { wipedOwner = auth.userID; wipeCalls += 1; files = [] }
    __ERROR__
    __CONTEXT__
    __CONTEXT_ERROR__
    __RESPONSE__
    __REQUEST__
    __TAPPED__
    __SCHEDULE__
    __DELETE__
}

@main struct AccountDeletionContextTests {
    struct Failure: Error { let message: String }
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) throws {
        checks += 1; if !value { throw Failure(message: message) }
    }
    @MainActor static func wait(_ label: String, until condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= end { throw Failure(message: "Fixture wait timed out: " + label) }
            await Task.yield()
        }
    }
    @MainActor static func host() -> DeletionHarness {
        AuthStore.reset(); URLSession.shared.reset(); return DeletionHarness()
    }
    @MainActor static func switchSession(_ h: DeletionHarness, mode: String) {
        if mode == "actor-without-revision" { h.auth.userID = "account-b" }
        else if mode == "aba" { h.auth.userID = "account-b"; h.auth.syncSessionRevision += 1; h.auth.userID = "account-a"; h.auth.syncSessionRevision += 1 }
        else if mode == "workspace" || mode == "reauth" { h.auth.syncSessionRevision += 1 }
        else if mode == "signed-out" { h.auth.isSignedIn = false }
        else { h.auth.userID = "account-b"; h.auth.syncSessionRevision += 1 }
        h.files = ["replacement-session-media"]
    }
    @MainActor static func retained(_ h: DeletionHarness, _ label: String) throws {
        try check(h.wipeCalls == 0 && h.files == ["replacement-session-media"], label + " preserves replacement files")
        try check(h.auth.signOutCalls == 0 && h.uploads.cancelCalls == 0, label + " preserves replacement session and upload")
        try check(!h.showAccountDeleted && !h.deletionPendingCleanup, label + " cannot publish old deletion success")
    }
    @MainActor static func run() async throws {
        let context = DeletionHarness.AccountDeletionContext(owner: "account-a", revision: 7)
        try check(context.matches(owner: "account-a", revision: 7, signedIn: true), "Current deletion context matches")
        try check(!context.matches(owner: "account-b", revision: 7, signedIn: true), "Deletion context requires original actor")
        try check(!context.matches(owner: "account-a", revision: 8, signedIn: true), "Deletion context requires original revision")
        try check(!context.matches(owner: "account-a", revision: 7, signedIn: false), "Deletion context requires signed-in session")

        for body in [#"{"ok":true,"cleanup_complete":true}"#, #"{"ok":true,"cleanup_complete":false}"#, #"{"ok":true}"#] {
            let h = host(); h.deleteTapped()
            try check(h.showDeleteConfirm && h.accountDeletionContext?.owner == "account-a", "Confirmation captures its original actor")
            let task = h.scheduleAccountDeletion(context: h.accountDeletionContext)
            try await wait("current dispatch", until: { URLSession.shared.pending != nil })
            let request = URLSession.shared.requests[0]
            try check(request.httpMethod == "DELETE" && request.url?.path == "/me", "Current deletion uses exact DELETE /me")
            try check(AuthStore.jwtSubject(String(request.value(forHTTPHeaderField: "Authorization")!.dropFirst(7))) == "account-a", "Current deletion bearer belongs to original actor")
            URLSession.shared.finish(body: body); await task.value
            try check(h.wipeCalls == 1 && h.wipedOwner == "account-a" && h.auth.signOutCalls == 1, "Current success wipes only its original session")
            try check(h.showAccountDeleted && h.uploads.cancelCalls == 1, "Current success retains original deletion completion flow")
            try check(h.deletionPendingCleanup == !body.contains("\"cleanup_complete\":true"), "Queued or missing cleanup stays honestly pending")
        }
        for (status, body) in [(409, #"{"error":"synthetic custody refusal"}"#), (200, #"{"ok":false}"#), (200, "malformed")] {
            let h = host(); h.deleteTapped(); let task = h.scheduleAccountDeletion(context: h.accountDeletionContext)
            try await wait("refusal dispatch", until: { URLSession.shared.pending != nil })
            URLSession.shared.finish(status: status, body: body); await task.value
            try check(h.wipeCalls == 0 && h.auth.signOutCalls == 0 && h.uploads.cancelCalls == 0, "Refused or unverified deletion preserves local data")
            try check(h.showDeleteError && !h.showAccountDeleted, "Current refusal retains actionable retry UI")
        }
        for mode in ["actor", "actor-without-revision", "aba", "workspace", "reauth", "signed-out"] {
            let h = host(); h.deleteTapped(); switchSession(h, mode: mode)
            let captured = h.accountDeletionContext
            var done = false; let task = Task { await h.deleteAccount(context: captured); done = true }
            try await wait("stale confirmation", until: { done || URLSession.shared.pending != nil })
            if URLSession.shared.pending != nil { URLSession.shared.finish() }
            await task.value
            try check(URLSession.shared.requests.isEmpty, "Stale confirmation cannot retarget deletion")
            try retained(h, "Stale confirmation")
            try check(!h.showDeleteError && h.deleteErrorMessage == nil, "Stale confirmation cannot prepare a replacement-account Retry")
        }
        for mode in ["actor", "aba", "workspace", "reauth", "signed-out"] {
            let h = host(); h.deleteTapped(); AuthStore.suspendToken = true
            let captured = h.accountDeletionContext
            var done = false; let task = Task { await h.deleteAccount(context: captured); done = true }
            try await wait("token suspension", until: { AuthStore.pendingToken != nil })
            switchSession(h, mode: mode); let waiter = AuthStore.pendingToken!; AuthStore.pendingToken = nil; waiter.resume()
            try await wait("post token", until: { done || URLSession.shared.pending != nil })
            if URLSession.shared.pending != nil { URLSession.shared.finish() }
            await task.value
            try check(URLSession.shared.requests.isEmpty, "Changed token session cannot dispatch deletion")
            try retained(h, "Changed token session")
        }
        for token in [AuthStore.token("account-b"), "malformed-token", "synthetic.e30=.synthetic"] {
            let h = host(); h.deleteTapped(); AuthStore.tokenOverride = token
            let captured = h.accountDeletionContext
            var done = false; let task = Task { await h.deleteAccount(context: captured); done = true }
            try await wait("token identity refusal", until: { done || URLSession.shared.pending != nil })
            if URLSession.shared.pending != nil { URLSession.shared.finish() }
            await task.value
            try check(URLSession.shared.requests.isEmpty, "Wrong or unverified JWT subject cannot dispatch deletion")
            try check(h.wipeCalls == 0 && h.auth.signOutCalls == 0, "JWT refusal preserves current session")
        }
        for mode in ["actor", "aba", "workspace", "reauth", "signed-out"] {
            let h = host(); h.deleteTapped(); let task = h.scheduleAccountDeletion(context: h.accountDeletionContext)
            try await wait("late response dispatch", until: { URLSession.shared.pending != nil })
            switchSession(h, mode: mode)
            h.accountDeletionContext = .init(owner: h.auth.userID ?? "", revision: h.auth.syncSessionRevision)
            URLSession.shared.finish(); await task.value
            try check(URLSession.shared.serverDeletedOwners == ["account-a"], "Late response retains original server deletion identity")
            try retained(h, "Late deletion response")
            try check(!h.showDeleteError && h.deleteErrorMessage == nil, "Late response cannot show misleading replacement-account retry")
        }
        for mode in ["actor", "aba", "workspace"] {
            let h = host(); h.deleteTapped(); let captured = h.accountDeletionContext
            // The real synchronous button scheduler must capture before its
            // new Task gets an opportunity to execute on the main actor.
            let task = h.scheduleAccountDeletion(context: captured)
            switchSession(h, mode: mode); h.deleteTapped()
            var done = false; let observer = Task { await task.value; done = true }
            try await wait("queued confirmation", until: { done || URLSession.shared.pending != nil })
            if URLSession.shared.pending != nil { URLSession.shared.finish() }
            await observer.value
            try check(URLSession.shared.requests.isEmpty, "Queued confirmation cannot retarget deletion")
            try retained(h, "Queued confirmation")
            try check(!h.showDeleteError && h.deleteErrorMessage == nil, "Queued confirmation cannot prepare a replacement-account Retry")
        }
        let retry = host(); retry.deleteTapped(); let refused = retry.scheduleAccountDeletion(context: retry.accountDeletionContext)
        try await wait("original retry refusal", until: { URLSession.shared.pending != nil })
        URLSession.shared.finish(status: 409, body: #"{"error":"synthetic refusal"}"#); await refused.value
        let oldRetry = retry.scheduleAccountDeletion(context: retry.accountDeletionContext)
        switchSession(retry, mode: "actor"); retry.deleteTapped()
        var retryDone = false; let retryObserver = Task { await oldRetry.value; retryDone = true }
        try await wait("old Retry", until: { retryDone || URLSession.shared.pending != nil })
        if URLSession.shared.pending != nil { URLSession.shared.finish() }
        await retryObserver.value
        try check(URLSession.shared.requests.count == 1, "Old Retry cannot authenticate replacement account")
        try retained(retry, "Old Retry")

        let signedOut = host(); signedOut.auth.isSignedIn = false; signedOut.deleteTapped()
        try check(signedOut.showDeleteNeedsSignIn && !signedOut.showDeleteConfirm && signedOut.accountDeletionContext == nil, "Signed-out deletion cannot create confirmation authority")
        let offline = host(); offline.serverAccountsEnabled = false; offline.auth.isSignedIn = false
        offline.deleteTapped(); await offline.scheduleAccountDeletion(context: offline.accountDeletionContext).value
        try check(URLSession.shared.requests.isEmpty && offline.wipeCalls == 1 && offline.showAccountDeleted, "Offline local-only wipe remains available without cloud request")

        let confirmed = host(); confirmed.deleteTapped(); let captured = confirmed.accountDeletionContext!
        var result: Error?; let request = Task { do { _ = try await confirmed.requestServerAccountDeletion(context: captured) } catch { result = error } }
        try await wait("direct late receipt", until: { URLSession.shared.pending != nil })
        switchSession(confirmed, mode: "actor"); URLSession.shared.finish(); await request.value
        if case DeletionHarness.AccountDeletionContextError.changedAfterDispatch(let accepted)? = result {
            try check(accepted, "Stale response preserves confirmed prior-account deletion fact")
        } else { try check(false, "Stale response preserves confirmed prior-account deletion fact") }
        try check(result?.localizedDescription.contains("earlier account") == true && result?.localizedDescription.contains("were kept") == true, "Stale response recovery does not falsely claim prior account was not deleted")
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS AccountDeletionContextTests \(checks) checks") }
        catch let failure as Failure { print("FAIL " + failure.message); exit(1) }
        catch { print("FAIL unexpected synthetic fixture error: \(error)"); exit(1) }
    }
}
