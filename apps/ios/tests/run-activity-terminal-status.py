#!/usr/bin/env python3
"""Exercise the production Activity progress model without app or network state."""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
MODEL = (ROOT / "apps/ios/Rendprop/Models/ListingVideo.swift").read_text()
QUEUE = (ROOT / "apps/ios/Rendprop/Render/ReelWorkQueue.swift").read_text()
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
        declaration(QUEUE, "struct NativeActivityScope: Codable, Equatable"),
        declaration(QUEUE, "struct NativeActivityEntry: Codable, Identifiable, Equatable"),
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

with tempfile.TemporaryDirectory(prefix="rendprop-activity-status-") as folder:
    source = Path(folder) / "ActivityStatusRegression.swift"
    binary = Path(folder) / "activity-status-regression"
    source.write_text(swift)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
