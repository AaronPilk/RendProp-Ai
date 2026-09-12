import Foundation

@main enum SpatialCoordinatorRecoveryTests {
    static var assertions = 0
    static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        if !condition { FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8)); exit(1) }
    }
    @MainActor static func main() async throws {
        let api = RecoveryAPI()
        let owner = AuthStore.jwtSubject("offline-fixture-only")!
        let job = UUID()
        var frame = SpatialUploadRecord.Frame(imagePath: "images/000001.jpg", sidecarPath: "frames/000001.json",
            bytes: 100, sha256: String(repeating: "a", count: 64), ticketID: api.oldID, phase: .sending)
        frame.restartRequired = true; frame.restartGeneration = 0
        let record = SpatialUploadRecord(id: UUID(), ownerID: owner, listingLocalID: UUID(), listingID: UUID(),
            captureID: UUID(), roomLabel: "Fixture", allowCellular: false, jobID: job, frames: [frame], failure: "interrupted")
        let session = RecoverySession()
        let running = RecoveryTask(1); running.taskDescription = record.taskPrefix + "0"; running.resume()
        session.fixtureTasks = [running]
        let paused = SpatialCoordinatorRecoveryBoundary(record: record, api: api, session: session)
        try paused.pause(jobID: job)
        try await Task.sleep(nanoseconds: 20_000_000)
        check(running.cancellations == 0 && running.suspensions == 0,
              "Spatial Pause does not interrupt an already dispatched JPEG")
        check(paused.records[0].isUserPaused && paused.records[0].frames[0].ticketID == api.oldID,
              "Spatial Pause preserves exact frame ticket")
        running.fixtureState = .suspended
        paused.reconnect()
        try await Task.sleep(nanoseconds: 20_000_000)
        check(running.starts == 1 && paused.active.isEmpty,
              "Paused suspended spatial task does not resume or consume active slots")
        try paused.resume(jobID: job)
        try await Task.sleep(nanoseconds: 20_000_000)
        check(running.starts == 2 && paused.active.contains(record.taskPrefix + "0"),
              "Explicit spatial Resume reattaches the same suspended OS task")

        let lost = RecoveryAPI(); lost.loseRestartReplyOnce = true
        lost.completionFailure = .server(status: 409, code: "conflict", message: "upload is terminal or expired")
        let manager = SpatialCoordinatorRecoveryBoundary(record: record, api: lost, session: RecoverySession())
        await manager.restartFailedFrame(record.id)
        let intent = manager.records[0].frames[0].restartIntent?.operationID
        check(intent != nil && manager.records[0].frames[0].ticketID == lost.oldID,
              "Spatial lost restart response keeps parent and saved intent")
        await manager.restartFailedFrame(record.id)
        let saved = manager.records[0]
        check(saved.id == record.id && saved.jobID == record.jobID && saved.captureID == record.captureID && saved.listingID == record.listingID,
              "Spatial restart never creates another room job or capture")
        check(saved.frames[0].ticketID == lost.newID && saved.frames[0].restartIntent == nil && saved.frames[0].phase == .ticketed,
              "Spatial restart durably adopts the one linked child before upload")
        check(lost.restartKeys.count == 2 && Set(lost.restartKeys).count == 1 && lost.creates == 0 && lost.replacements == 1,
              "Spatial lost reply uses one persisted restart UUID without fresh reserve")
        check(!manager.writes.drop(while: { $0[0].frames[0].restartIntent == nil }).contains(where: {
            $0[0].frames[0].ticketID == lost.oldID && $0[0].frames[0].restartIntent == nil
        }), "Spatial child and consumed restart intent persist in one journal write")

        let completed = RecoveryAPI(); completed.completed = true
        let winner = SpatialCoordinatorRecoveryBoundary(record: record, api: completed, session: RecoverySession())
        await winner.restartFailedFrame(record.id)
        check(winner.records[0].frames[0].phase == .uploaded && completed.restartKeys.isEmpty,
              "Spatial completion winner skips replacement and preserves receipt")
        let switched = RecoveryAPI(); switched.switchOwnerOnRestart = true
        switched.completionFailure = .server(status: 409, code: "conflict", message: "upload is terminal or expired")
        let fenced = SpatialCoordinatorRecoveryBoundary(record: record, api: switched, session: RecoverySession())
        await fenced.restartFailedFrame(record.id)
        check(fenced.records[0].frames[0].ticketID == switched.oldID && fenced.records[0].frames[0].restartIntent != nil && fenced.pumps == 0,
              "Spatial account switch retains intent without pumping another owner's media")
        AuthStore.currentAccessToken = "offline-fixture-only"
        var exhausted = record; exhausted.frames[0].restartGeneration = 3
        let noMore = RecoveryAPI()
        let ceiling = SpatialCoordinatorRecoveryBoundary(record: exhausted, api: noMore, session: RecoverySession())
        await ceiling.restartFailedFrame(record.id)
        check(noMore.restartKeys.isEmpty && ceiling.records[0].frames[0].ticketID == noMore.oldID,
              "Spatial fourth restart is not silently attempted")
        print("PASS SpatialCoordinatorRecoveryTests \(assertions) assertions")
    }
}
