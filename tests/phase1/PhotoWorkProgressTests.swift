import Foundation
import Combine

@main struct PhotoWorkProgressTests {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }; assertions += 1
    }
    @MainActor static func settle(_ ready: () -> Bool) async {
        for _ in 0..<2000 { if ready() { return }; await Task.yield() }
        fatalError("Owned progress fixture did not reach its boundary")
    }
    enum Refusal: Error { case expected }
    @MainActor static func main() async {
        let queue = PhotoWorkQueue.shared
        var current = true
        var release: CheckedContinuation<Void, Never>?
        var captured: UUID?
        check(queue.start(listingID: UUID(), title: "Stage", photoIDs: ["one"], identityIsCurrent: { current }, stopOnError: { _ in false }, process: { photo in
            guard let id = queue.visibleJob?.id else { fatalError("Missing own job") }; captured = id
            queue.report(.uploading, jobID: id, photoID: photo)
            check(queue.job?.phase == .uploading, "Only observed source upload advances upload phase")
            queue.report(.generatingAndChecking, jobID: id, photoID: photo)
            check(queue.job?.phase?.title == "Generating and checking", "Synchronous supplier phase must not invent separate QC progress")
            queue.report(.preparing, jobID: id, photoID: photo)
            check(queue.job?.phase == .generatingAndChecking, "Older asynchronous boundary cannot regress a photo phase")
            queue.report(.saving, jobID: UUID(), photoID: photo)
            queue.report(.saving, jobID: id, photoID: "another-photo")
            check(queue.job?.phase == .generatingAndChecking, "Wrong run/photo callbacks cannot publish progress")
            current = false
            queue.report(.saving, jobID: id, photoID: photo)
            check(queue.visibleJob == nil && queue.job?.phase == .generatingAndChecking, "Changed account/library cannot publish or see the old progress")
            current = true
            await withCheckedContinuation { release = $0 }
            queue.report(.checkingReturnedImage, jobID: id, photoID: photo)
            check(queue.job?.phase == .checkingReturnedImage, "Returned bytes have their own observable check boundary")
            queue.report(.saving, jobID: id, photoID: photo)
            check(queue.job?.phase == .saving, "Save phase occurs only after the returned-image boundary")
        }), "Own edit starts")
        await settle { release != nil }
        check(queue.job?.current == 1 && queue.job?.total == 1 && queue.job?.done == 0 && queue.job?.percent == 0,
              "In-flight supplier waits cannot fabricate completion percentages")
        release?.resume(); release = nil
        await settle { queue.job?.running == false }
        check(queue.job?.done == 1 && queue.job?.phase == nil, "Saved count is real and finished work clears its live phase")
        let previous = captured!
        queue.report(.saving, jobID: previous, photoID: "one")
        check(queue.job?.phase == nil, "A finished job cannot receive a late active phase")
        queue.dismissResult()
        check(queue.start(listingID: UUID(), title: "Declutter", photoIDs: ["two"], identityIsCurrent: { current }, stopOnError: { _ in false }, process: { photo in
            let next = queue.visibleJob!.id
            queue.report(.saving, jobID: previous, photoID: photo)
            check(queue.job?.phase == .preparing, "A prior generation cannot write into a newly admitted run")
            queue.report(.generatingAndChecking, jobID: next, photoID: photo)
            await withCheckedContinuation { release = $0 }
            queue.report(.saving, jobID: next, photoID: photo)
            check(queue.job?.phase == .generatingAndChecking, "Cancellation rejects progress from an accepted response finishing late")
        }), "Next independent edit starts")
        await settle { release != nil }
        queue.cancel(); release?.resume(); release = nil
        await settle { queue.job?.running == false }
        check(queue.job?.interrupted == true && queue.job?.attempted == 0 && queue.job?.phase == nil,
              "Cancellation preserves truthful unsaved counts and clears its phase")
        queue.dismissResult()
        check(queue.start(listingID: UUID(), title: "Two", photoIDs: ["bad", "good"], identityIsCurrent: { true }, stopOnError: { _ in false }, process: { photo in
            if photo == "bad" { throw Refusal.expected }
        }), "Partial-failure batch starts")
        await settle { queue.job?.running == false }
        check(queue.job?.done == 1 && queue.job?.failures.count == 1 && queue.job?.attempted == 2 && queue.job?.phase == nil,
              "Partial failure never counts the failed photo as saved")
        queue.dismissResult()
        check(queue.start(listingID: UUID(), title: "Large", photoIDs: (0..<100).map(String.init), identityIsCurrent: { true }, stopOnError: { _ in false }, process: { photo in
            let id = queue.visibleJob!.id
            queue.report(.generatingAndChecking, jobID: id, photoID: photo)
        }), "Large finite batch starts")
        await settle { queue.job?.running == false }
        check(queue.job?.done == 100 && queue.job?.current == 100 && queue.job?.phase == nil,
              "100-photo completion counts every saved item without truncation")
        print("PASS \(assertions) actual photo progress assertions; no network, model, app preference or UI")
    }
}
