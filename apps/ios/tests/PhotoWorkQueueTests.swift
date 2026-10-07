import Foundation
import Combine

@main struct PhotoWorkQueueTests {
    enum SyntheticError: Error { case recoverable, quota }
    @MainActor static func main() async {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); count += 1
        }
        func settle(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<10_000 {
                if condition() { return }
                await Task.yield()
            }
            preconditionFailure("Synthetic queue did not settle")
        }

        let queue = PhotoWorkQueue()
        var emissions: [PhotoWorkQueue.Job] = []
        var finalReadback: Bool?
        // Consume the emitted value as the screen must. @Published sends before
        // storage changes: reading queue.visibleJob in this sink is one event late.
        let subscription = queue.$job.sink { emitted in
            if let emitted, queue.isContextCurrent {
                emissions.append(emitted)
                if !emitted.running { finalReadback = queue.visibleJob?.running }
            }
        }
        var completed: PhotoWorkQueue.Job?
        var calls: [String] = []
        check(queue.start(listingID: UUID(), title: "Synthetic navigation-safe edit", photoIDs: ["one", "two", "three"],
            identityIsCurrent: { true }, stopOnError: { _ in false }, process: { id in
                calls.append(id); await Task.yield()
                if id == "two" { throw SyntheticError.recoverable }
            }, completion: { completed = $0 }), "Start valid work")
        check(!queue.start(listingID: UUID(), title: "Blocked", photoIDs: ["other"], identityIsCurrent: { true },
            stopOnError: { _ in false }, process: { _ in preconditionFailure("Must not start overlapping work") }), "Only one batch can own work")
        queue.dismissResult()
        check(queue.job != nil, "Dismiss cannot drop running work")
        await settle { completed != nil }
        check(calls == ["one", "two", "three"], "Recoverable failure continues sequentially")
        check(completed?.done == 2 && completed?.failures.count == 1 && completed?.attempted == 3, "Count successes and attempted failures honestly")
        check(completed?.percent == 100 && completed?.remaining == 0 && completed?.interrupted == false, "Finished means all photos attempted, not all succeeded")
        check(emissions.last?.running == false && emissions.last?.done == 2 && emissions.last?.failures.count == 1,
              "The actual Combine completion emission must contain completed output for immediate screen refresh")
        check(finalReadback == true, "Regression reproducer: storage readback is stale during the completion emission")
        check(queue.job?.running == false && queue.job?.currentPhotoID == nil, "Clear active thumbnail before finishing")
        queue.dismissResult(); check(queue.job == nil, "Completed status can be dismissed")

        var continuation: CheckedContinuation<Void, Never>?
        var cancelled: PhotoWorkQueue.Job?
        check(queue.start(listingID: UUID(), title: "Synthetic cancellation", photoIDs: ["one", "never-start"],
            identityIsCurrent: { true }, stopOnError: { _ in false }, process: { _ in
                await withCheckedContinuation { continuation = $0 }
            }, completion: { cancelled = $0 }), "Queue reusable after finishing")
        await settle { continuation != nil }
        queue.cancel(); continuation!.resume(); continuation = nil
        await settle { cancelled != nil }
        check(cancelled?.interrupted == true && cancelled?.done == 0 && cancelled?.failures.isEmpty == true,
              "Cancellation never claims a completed output or provider failure")
        check(cancelled?.remaining == 2 && cancelled?.currentPhotoID == nil && cancelled?.running == false,
              "Cancellation clears active state and preserves unattempted count")

        var identityCurrent = true
        var scopeChanged: PhotoWorkQueue.Job?
        calls = []
        check(queue.start(listingID: UUID(), title: "Synthetic account/workspace change", photoIDs: ["one", "private-other"],
            identityIsCurrent: { identityCurrent }, stopOnError: { _ in false }, process: { id in
                calls.append(id); await withCheckedContinuation { continuation = $0 }
            }, completion: { scopeChanged = $0 }), "New scoped work can start")
        await settle { continuation != nil }
        identityCurrent = false
        check(queue.visibleJob == nil && !queue.isContextCurrent, "Hide previous-account status immediately")
        continuation!.resume(); continuation = nil
        await settle { scopeChanged != nil }
        check(calls == ["one"] && scopeChanged?.done == 0 && scopeChanged?.interrupted == true,
              "A changed account/workspace prevents the next photo and discards the late completion")
        check(queue.job == nil, "Clear stale owner result after cleanup callback")

        var quotaResult: PhotoWorkQueue.Job?
        calls = []
        check(queue.start(listingID: UUID(), title: "Synthetic quota", photoIDs: ["one", "two", "three"],
            identityIsCurrent: { true }, stopOnError: { ($0 as? SyntheticError) == .quota }, process: { id in
                calls.append(id); throw SyntheticError.quota
            }, completion: { quotaResult = $0 }), "Queue releases ownership after identity change")
        await settle { quotaResult != nil }
        check(calls == ["one"] && quotaResult?.failures.count == 1 && quotaResult?.interrupted == true,
              "Quota/auth stopping policy cannot start another paid photo")
        check(quotaResult?.percent == 33 && quotaResult?.remaining == 2, "Interrupted progress cannot imply the batch finished")
        check(!queue.start(listingID: UUID(), title: "Empty", photoIDs: [], identityIsCurrent: { true }, stopOnError: { _ in false },
            process: { _ in preconditionFailure("Empty work must not execute") }), "Reject an empty batch")
        check(!queue.start(listingID: UUID(), title: "Wrong scope", photoIDs: ["one"], identityIsCurrent: { false }, stopOnError: { _ in false },
            process: { _ in preconditionFailure("Wrong-scope work must not execute") }), "Reject invalid initial identity")
        withExtendedLifetime(subscription) {}
        print("PASSED: \(count) actual queue/Combine completion, failure, cancellation and identity assertions; no provider/files/camera")
    }
}
