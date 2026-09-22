// Test storage substitution only: the production AIConsent body is extracted
// byte-for-byte by consent-disclosure.test.mjs. Foundation + Combine are real.
// No app defaults, media, API client, SwiftUI or provider call is instantiated.
import Foundation
import Combine

enum UserDefaults {
    static let suiteName = CommandLine.arguments[2]
    static let standard = Foundation.UserDefaults(suiteName: suiteName)!
}

@main
struct ConsentPersistenceTests {
    @MainActor static var checks = 0

    @MainActor static func check(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    @MainActor static func pending(_ consent: AIConsent) async -> Task<Bool, Never> {
        let task = Task { @MainActor in await consent.ensureGranted() }
        for _ in 0..<1000 {
            if consent.isAsking { break }
            await Task.yield()
        }
        check(consent.isAsking, "ungranted request must ask before returning")
        return task
    }

    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3,
              CommandLine.arguments[2].hasPrefix("com.rendprop.offline-consent-tests.") else {
            print("FAIL: requires a unique test-only preferences suite")
            exit(1)
        }
        let old = "ai.thirdPartyProcessing.consent.v1"
        let current = "ai.thirdPartyProcessing.consent.v2"
        let defaults = UserDefaults.standard
        switch CommandLine.arguments[1] {
        case "v1-only-then-grant":
            check(defaults.object(forKey: old) == nil && defaults.object(forKey: current) == nil,
                  "test suite must start unused")
            defaults.set(true, forKey: old)
            let consent = AIConsent.shared
            check(!consent.isGranted, "a persisted v1 YES must not grant v2")
            check(!consent.isAsking, "loading ungranted defaults must not open a tool")
            let first = await pending(consent)
            let second = Task { @MainActor in await consent.ensureGranted() }
            await Task.yield()
            consent.grant()
            let a = await first.value
            let b = await second.value
            check(a && b, "grant must return true to both requesting callers")
            check(consent.isGranted && !consent.isAsking, "grant must close disclosure")
            check(defaults.bool(forKey: current), "grant must persist v2")
            check(defaults.bool(forKey: old), "grant must not rewrite the historical v1 key")
            check(defaults.synchronize(), "test preferences must flush before next process")
        case "relaunch-then-revoke":
            check(defaults.bool(forKey: current), "previous process must have persisted v2 grant")
            let consent = AIConsent.shared
            check(consent.isGranted, "relaunch must load the v2 grant")
            let granted = await consent.ensureGranted()
            check(granted && !consent.isAsking, "v2 grant skips asking")
            consent.revoke()
            check(!consent.isGranted && !defaults.bool(forKey: current), "revoke persists false")
            check(defaults.bool(forKey: old), "stale v1 YES remains irrelevant")
            check(defaults.synchronize(), "revocation must flush before next process")
        case "relaunch-then-decline":
            let consent = AIConsent.shared
            check(defaults.bool(forKey: old), "fixture retains old v1 grant")
            check(!consent.isGranted, "persisted v2 false must require a fresh decision")
            let declined = await pending(consent)
            consent.decline()
            let answer = await declined.value
            check(!answer && !consent.isGranted && !consent.isAsking,
                  "decline resumes false and closes without granting")
            check(!defaults.bool(forKey: current), "decline must not persist a grant")
            let cancelled = await pending(consent)
            consent.cancelIfStillWaiting()
            let cancellation = await cancelled.value
            check(!cancellation && !consent.isAsking, "leaving resumes false and closes")
            check(!defaults.bool(forKey: current), "leaving must not persist a grant")
            consent.cancelIfStillWaiting()
            check(!consent.isGranted, "repeated cancellation is inert")
        default:
            check(false, "unknown scenario is not a pass")
        }
        print("PASS \(checks) assertions: \(CommandLine.arguments[1])")
    }
}
