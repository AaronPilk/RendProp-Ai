import Foundation

struct EnhancedPhoto { let id: String }
struct AIShot {}
@MainActor final class ClipAPI {
    var calls: [Int] = []
    let errors: [Int: Error]
    init(errors: [Int: Error]) { self.errors = errors }
}
enum FileStore {
    static var documents = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reel-failure-\(UUID())")
    static func url(fromRelativePath path: String) -> URL { documents.appendingPathComponent(path) }
    static func relativePath(for url: URL) -> String { String(url.path.dropFirst(documents.path.count + 1)) }
}

@main struct ReelClipFailureTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) {
            precondition(value(), reason); assertions += 1
        }
        defer { try? FileManager.default.removeItem(at: FileStore.documents) }
        for (status, code, message) in [
            (502, "upstream", "fal HTTP 403: {\"detail\":\"private provider payload\"}"),
            (503, "upstream", "All providers unavailable"),
            (500, "internal", "Internal provider problem"),
            (402, "quota_exceeded", "Your clip allowance is used up."),
            (401, "unauthorized", "Expired session"),
            (429, "rate_limited", "Too many requests"),
            (400, "validation", "Choose a supported camera move."),
        ] {
            let error=APIError.server(status: status,code: code,message: message)
            let api=ClipAPI(errors: [0:error]);let run=ReelBatchHarness(api:api)
            let id=UUID();let dir=FileManager.default.temporaryDirectory.appendingPathComponent("clip-test-\(id)")
            try await run.run(count:8,listingID:id,tmpDir:dir)
            check(api.calls == [0], "A first-photo failure must stop without sending the remaining seven photos")
            check(!run.stitched && run.receivedError != nil, "A failed batch must not silently become a partial-success reel")
            check(run.clipIssues.count==1 && run.clipIssues[0].photoNumber==1, "Keep the exact failed-photo position")
            check(run.completedClips==1, "Completed attempts includes the failed photo")
            let visible=run.clipIssues[0].failure
            check(visible.isQuota==(status==402), "Preserve quota recovery action")
            check(visible.isUnauthorized==(status==401), "Preserve workspace recovery action")
            check(visible.isRateLimited==(status==429), "Preserve wait recovery action")
            check(!visible.message.contains("private provider payload") && !visible.message.contains("Nothing was charged"), "No raw payload or unsupported billing claim")
            if status>=500 { check(visible.message.contains("unavailable"), "Make upstream outage actionable") }
            if status==400 { check(visible.message==message, "Keep a readable per-photo validation reason") }
            check(!FileManager.default.fileExists(atPath:dir.path), "Clean the empty failed-run temporary directory")
        }
        let raw=NSError(domain:"offline-test",code:1,userInfo:[NSLocalizedDescriptionKey:"fal HTTP 422: {\"detail\":\"private image bytes\"}"])
        let issue=ReelClipIssue(photoNumber:3,error:raw)
        check(issue.failure.message.contains("Review the photo"), "Safe next step for an unclassified provider rejection")
        check(!issue.failure.message.contains("private image") && !issue.failure.message.contains("charged"), "Do not echo raw input or infer a refund")
        let offline=ReelClipIssue(photoNumber:2,error:URLError(.networkConnectionLost))
        check(offline.failure.message.contains("connection"), "Readable network reason")
        let lateAPI=ClipAPI(errors:[2:APIError.server(status:502,code:"upstream",message:"Unavailable")])
        let late=ReelBatchHarness(api:lateAPI);let lateID=UUID()
        let lateDir=FileManager.default.temporaryDirectory.appendingPathComponent("clip-test-\(lateID)")
        try await late.run(count:8,listingID:lateID,tmpDir:lateDir)
        check(lateAPI.calls == [0,1,2], "Stop on photo three without four-through-eight submissions")
        check(late.clipIssues.first?.photoNumber==3, "Visible failed photo is three")
        check(!late.stitched, "Saved earlier clips require an explicit choice before partial composition")
        let saved=PendingReelClips.load(for:lateID)
        check(saved?.clipURLs.count==2, "Both earlier completed clips are durably parked")
        let text=try saved!.clipURLs.map { try String(contentsOf:$0,encoding:.utf8) }
        check(text==["synthetic completed clip 0","synthetic completed clip 1"], "Park source bytes in order without regenerating")
        check(!FileManager.default.fileExists(atPath:lateDir.path), "Remove temporary directory only after parking completed files")
        PendingReelClips.clear(for:lateID)
        let goodAPI=ClipAPI(errors:[:]);let good=ReelBatchHarness(api:goodAPI);let goodID=UUID()
        try await good.run(count:3,listingID:goodID,tmpDir:FileManager.default.temporaryDirectory.appendingPathComponent("clip-test-\(goodID)"))
        check(goodAPI.calls == [0,1,2] && good.stitched, "A full successful batch still reaches composition")
        check(good.clipIssues.isEmpty && good.receivedError==nil, "Successful batch has no invented error")
        let cancelAPI=ClipAPI(errors:[1:CancellationError()]);let cancel=ReelBatchHarness(api:cancelAPI);let cancelID=UUID()
        try await cancel.run(count:3,listingID:cancelID,tmpDir:FileManager.default.temporaryDirectory.appendingPathComponent("clip-test-\(cancelID)"))
        check(cancelAPI.calls == [0,1] && cancel.clipIssues.isEmpty, "Cancellation stops generation without displaying it as a photo defect")
        check(PendingReelClips.load(for:cancelID)?.clipURLs.count==1, "Cancellation preserves completed clip")
        PendingReelClips.clear(for:cancelID)
        print("PASSED: \(assertions) reel failure, recovery, retained-file and batch-stop assertions; no network/provider calls")
    }
}
