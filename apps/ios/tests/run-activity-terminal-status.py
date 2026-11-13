#!/usr/bin/env python3
"""Exercise the production Activity progress model without app or network state."""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
MODEL = (ROOT / "apps/ios/Rendprop/Models/ListingVideo.swift").read_text()
QUEUE = (ROOT / "apps/ios/Rendprop/Render/ReelWorkQueue.swift").read_text()
SERVICE = (ROOT / "apps/ios/Rendprop/Networking/AerialOpeningService.swift").read_text()
VIEW = (ROOT / "apps/ios/Rendprop/Render/ReelWorkBanner.swift").read_text()


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"Unclosed declaration: {marker}")


# The harness compiles the exact model declarations used by Activity. A cold
# restore has a durable ready receipt but no in-memory check/progress clocks.
swift = "\n\n".join(
    [
        "import Foundation",
        declaration(MODEL, "struct NativeGenerationProgress: Equatable"),
        """
struct PropertyVideoJobContext: Codable, Equatable {}
struct AerialOpeningManifest: Codable, Equatable {}
struct AerialOpeningQuote: Codable, Equatable {}
struct AerialOpeningStatus: Codable, Equatable {
    let state: String
    var isTerminal: Bool { ["accepted", "failed", "ineligible", "cancelled"].contains(state) }
}
""",
        declaration(SERVICE, "struct AerialOpeningJournal: Codable, Equatable"),
        declaration(QUEUE, "struct NativeActivityScope: Codable, Equatable"),
        declaration(QUEUE, "struct NativeActivityEntry: Codable, Identifiable, Equatable"),
        declaration(QUEUE, "struct NativeActivityHistory: Codable"),
        """
@main struct ActivityStatusRegression {
    static func main() {
        let scope = NativeActivityScope(actor: UUID(), library: UUID())
        var entry = NativeActivityEntry(
            id: "reel:restored", scope: scope, listingID: UUID(), listingTitle: "855 Central",
            kind: .video, state: .ready, stage: "Video saved. Ready to review.",
            completed: 0, total: 0, startedAt: nil, firstObservedAt: Date(),
            progressToken: "ready", lastProgressAt: nil, lastCheckedAt: nil,
            milestoneCompleted: 5, checkFailed: nil, expectsStatusChecks: true,
            countUnit: nil, progressKind: "video")
        let restored = entry.generationProgress
        assert(restored.percent == 100 && restored.completed == 5 && restored.total == 5)
        assert(!restored.checksExpected && restored.lastProgressAt == nil)

        entry.state = .working
        entry.progressToken = "generating"
        entry.milestoneCompleted = 2
        let active = entry.generationProgress
        assert(active.checksExpected && active.checkIsStale(at: Date()))
        assert(!active.canIndicateLive(at: Date()))

        entry.lastCheckedAt = Date()
        assert(entry.generationProgress.canIndicateLive(at: Date()))

        entry.state = .attention
        entry.checkFailed = true
        let attention = entry.generationProgress
        assert(attention.checksExpected && attention.checkFailed)

        entry.state = .failed
        entry.progressToken = "ready"
        entry.milestoneCompleted = 5
        let failed = entry.generationProgress
        assert(!failed.checksExpected && failed.percent == nil)

        // Local photo/video phases must move the observation clock forward on
        // every confirmed change, while a failure alone is not progress.
        var local = entry
        local.state = .working
        local.progressToken = "queued"
        local.milestoneCompleted = 1
        local.lastProgressAt = nil
        var phaseHistory = NativeActivityHistory(entries: [local])
        local.progressToken = "generating"
        local.milestoneCompleted = 2
        phaseHistory.observe(local, now: Date(timeIntervalSince1970: 10))
        assert(phaseHistory.entries[0].lastProgressAt == Date(timeIntervalSince1970: 10))
        local.progressToken = "quality_review"
        local.milestoneCompleted = 3
        phaseHistory.observe(local, now: Date(timeIntervalSince1970: 20))
        assert(phaseHistory.entries[0].lastProgressAt == Date(timeIntervalSince1970: 20))
        local.state = .failed
        local.progressToken = "failed"
        local.milestoneCompleted = nil
        phaseHistory.observe(local, now: Date(timeIntervalSince1970: 30))
        assert(phaseHistory.entries[0].lastProgressAt == Date(timeIntervalSince1970: 20))
        local.state = .stopped
        phaseHistory.observe(local, now: Date(timeIntervalSince1970: 40))
        assert(phaseHistory.entries[0].lastProgressAt == Date(timeIntervalSince1970: 20))

        let aerialPhases: [(String, Int)] = [
            ("queued_input", 0), ("preparing_input", 0),
            ("queued_assessment", 1), ("checking_source", 1),
            ("queued_generation", 2), ("processing", 2),
            ("queued_qualification", 3), ("qualifying", 3),
            ("queued_quality", 4), ("checking_quality", 4),
            ("ready_for_acceptance", 5), ("accepted", 5)
        ]
        var aerial = NativeActivityEntry(
            id: "aerial:restored", scope: scope, listingID: UUID(), listingTitle: "QA Exterior",
            kind: .aerial, state: .working, stage: "Making opening",
            completed: nil, total: nil, startedAt: nil, firstObservedAt: Date(),
            progressToken: "queued_input", lastProgressAt: nil, lastCheckedAt: nil,
            milestoneCompleted: nil, aerialProgressVersion: 2,
            checkFailed: nil, expectsStatusChecks: true,
            countUnit: nil, progressKind: nil)
        for (phase, completed) in aerialPhases {
            assert(NativeGenerationProgress.steps(kind: "aerial", phase: phase) == completed)
            aerial.state = phase == "accepted" ? .ready : phase == "ready_for_acceptance" ? .attention : .working
            aerial.progressToken = phase
            let progress = aerial.generationProgress
            assert(progress.completed == completed && progress.total == 5,
                   "Incorrect completed stages for \\(phase)")
            assert(progress.percent == completed * 20, "Incorrect percent for \\(phase)")
            if phase == "ready_for_acceptance" {
                assert(aerial.isAerialAwaitingReview && !progress.active && !progress.checksExpected)
            }
        }
        assert(NativeGenerationProgress.stepTotal(kind: "aerial") == 5)
        let operationID = UUID()
        aerial = NativeActivityEntry(
            id: "aerial:\\(operationID)", scope: scope, listingID: aerial.listingID,
            listingTitle: aerial.listingTitle, kind: .aerial, state: .working,
            stage: "Making opening", completed: nil, total: nil, startedAt: nil,
            firstObservedAt: Date())
        for state in [NativeActivityEntry.State.working, .waiting, .attention, .ready, .failed, .stopped] {
            aerial.state = state
            assert(aerial.matchesAerialOperation(operationID, scope: scope), "Exact aerial route lost in \\(state)")
        }
        assert(!aerial.matchesAerialOperation(UUID(), scope: scope))
        assert(!aerial.matchesAerialOperation(operationID, scope: .init(actor: UUID(), library: scope.library)))

        var oldAerial = aerial
        oldAerial.state = .attention
        oldAerial.progressToken = "ready_for_acceptance"
        oldAerial.milestoneCompleted = 6
        oldAerial.aerialProgressVersion = nil // A Build 119 Activity receipt.
        assert(oldAerial.generationProgress.percent == 100)
        var newAerial = oldAerial
        newAerial.milestoneCompleted = 5
        newAerial.aerialProgressVersion = 2
        var history = NativeActivityHistory(entries: [oldAerial])
        history.observe(newAerial, now: Date())
        assert(history.entries.first?.milestoneCompleted == 5)

        var fourthStage = aerial
        fourthStage.progressToken = "queued_quality"
        fourthStage.milestoneCompleted = 4
        fourthStage.lastProgressAt = Date(timeIntervalSince1970: 10)
        var stale = fourthStage
        stale.progressToken = "queued_assessment"
        stale.milestoneCompleted = 1
        stale.lastProgressAt = Date(timeIntervalSince1970: 20)
        history = NativeActivityHistory(entries: [fourthStage])
        history.observe(stale, now: Date(timeIntervalSince1970: 20))
        assert(history.entries.first?.generationProgress.completed == 4)
        assert(history.entries.first?.generationProgress.percent == 80)
        assert(history.entries.first?.lastProgressAt == fourthStage.lastProgressAt)

        stale.state = .failed
        stale.progressToken = "failed"
        stale.milestoneCompleted = nil
        history.observe(stale, now: Date(timeIntervalSince1970: 30))
        assert(history.entries.first?.generationProgress.completed == 4)
        assert(history.entries.first?.generationProgress.percent == 80)

        var allStages = fourthStage
        allStages.milestoneCompleted = 5
        allStages.progressToken = "ready_for_acceptance"
        history = NativeActivityHistory(entries: [allStages])
        history.observe(stale, now: Date(timeIntervalSince1970: 30))
        assert(history.entries.first?.generationProgress.percent == nil)

        let legacyJournalJSON = #"{"context":{},"physicalOrgID":"00000000-0000-0000-0000-000000000001","manifest":{},"quote":{},"disclosure":"","sourcePhotoID":"photo-1","dispatched":true,"stopRequested":false,"status":{"state":"queued_quality"},"completedMilestones":5}"#
        var journal = try! JSONDecoder().decode(AerialOpeningJournal.self, from: Data(legacyJournalJSON.utf8))
        assert(journal.progressVersion == nil)
        assert(journal.generationProgress().completed == 4)
        assert(journal.canStopUnfinishedRequest)
        let previousChange = Date(timeIntervalSince1970: 10)
        journal.lastPhaseChangedAt = previousChange
        journal.recordConfirmedStatus(.init(state: "queued_assessment"), at: Date(timeIntervalSince1970: 20))
        assert(journal.progressVersion == 2 && journal.completedMilestones == 4)
        assert(journal.generationProgress().completed == 4 && journal.generationProgress().percent == 80)
        assert(journal.lastPhaseChangedAt == previousChange)
        journal.recordConfirmedStatus(.init(state: "failed"), at: Date(timeIntervalSince1970: 30))
        assert(journal.generationProgress().completed == 4)
        assert(journal.lastPhaseChangedAt == previousChange)
        journal.recordConfirmedStatus(.init(state: "ready_for_acceptance"), at: Date(timeIntervalSince1970: 40))
        assert(journal.generationProgress().completed == 5)
        assert(journal.lastPhaseChangedAt == Date(timeIntervalSince1970: 40))
        assert(!journal.canStopUnfinishedRequest)
        journal.recordConfirmedStatus(.init(state: "cancelled"), at: Date(timeIntervalSince1970: 50))
        assert(journal.generationProgress().percent == nil)
        assert(journal.lastPhaseChangedAt == Date(timeIntervalSince1970: 40))
        assert(!journal.canStopUnfinishedRequest)
        print("Activity terminal/active status model: passed")
    }
}
""",
    ]
)

# The view hides unknown times for terminal entries, while the active branch
# retains its status-check and unknown-progress diagnostics.
stage = QUEUE[QUEUE.index("for job in ReelWorkQueue.shared.reviewableJobs {") :]
assert stage.index('case .done: stage = "Video saved. Ready to review."') < stage.index("default: stage = job.serverJob?.reply.map")
assert stage.index('case .failed: stage = "Video needs attention"') < stage.index("default: stage = job.serverJob?.reply.map")
progress_view = declaration(VIEW, "struct NativeGenerationProgressView: View")
assert "if progress.checksExpected {" in progress_view
assert "if let lastProgressAt = progress.lastProgressAt {" in progress_view
assert "else if progress.active || progress.checksExpected {" in progress_view
activity_view = declaration(VIEW, "struct NativeActivityView: View")
activity_card = declaration(VIEW, "struct NativeActivityCard: View")
exact_aerial = declaration(VIEW, "private func exactAerialJournal(_ entry: NativeActivityEntry)")
review = declaration(VIEW, "@ViewBuilder private func review(_ entry: NativeActivityEntry")
assert "entry.state.isActive" not in exact_aerial
assert "entry.matchesAerialOperation(saved.manifest.operationID, scope: NativeActivityStore.currentScope)" in exact_aerial
assert "if entry.kind == .aerial && exactAerial(entry)" in review
assert "expectedOperationID: UUID(uuidString:" in review
assert "lastProgressAt: confirmedProgressAt," in QUEUE
assert "exactAerialJournal(entry)?.canStopUnfinishedRequest == true" in activity_view
assert "entry.state.isActive && !entry.isAerialAwaitingReview" in activity_card
assert "saved.canStopUnfinishedRequest else { return }" in QUEUE
assert SERVICE.count("total: NativeGenerationProgress.aerialTotal") >= 2
assert "incoming: NativeGenerationProgress.steps(kind: \"aerial\", phase: status?.state)" in SERVICE

with tempfile.TemporaryDirectory(prefix="rendprop-activity-status-") as folder:
    source = Path(folder) / "ActivityStatusRegression.swift"
    binary = Path(folder) / "activity-status-regression"
    source.write_text(swift)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
