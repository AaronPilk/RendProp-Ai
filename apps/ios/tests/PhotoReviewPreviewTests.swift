import Foundation

// Closed decoding and presentation boundaries. The production task/context and
// selection/clearing methods are extracted by the runner; this is not UIKit QA.
struct UIImage { let value: String }
struct EnhancedPhoto {
    let id: String
    let enhancedURL: URL
    let originalURL: URL
}
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "viewer"
    var syncSessionRevision: UInt64 = 1
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
enum PhotoVersionHistory {
    struct StagingReview { var comparedSource = false }
    struct CustomReview { var comparedSource = false }
    struct History { func isSelectedForListing(_ id: String) -> Bool { false } }
    static func load(directory: URL) throws -> History { History() }
}
@MainActor enum AIImagePrep {
    static var count = 0
    static var atDecode: (Int) -> Void = { _ in }
    static func decoded(at url: URL, maxPixel: Int) async -> UIImage? {
        count += 1
        atDecode(count)
        await Task.yield()
        return UIImage(value: url.lastPathComponent)
    }
}
// The resource lookup is closed so hostile remote URLs can be supplied without
// a request. Real Bundle inclusion and video metadata are checked separately.
struct ControlledBundle {
    static let main = ControlledBundle(video: nil, text: nil)
    var video: URL?
    var text: URL?
    func url(forResource name: String?, withExtension ext: String?) -> URL? {
        guard name == "RendpropQuickStart" else { return nil }
        return ext == "mp4" ? video : text
    }
}
// Closed OS audio boundary. Production scoped activation/restoration decisions
// execute unchanged; this does not emulate Silent Mode or AVPlayer UI on a phone.
final class AVAudioSession {
    enum Category { case ambient, playback, playAndRecord }
    enum Mode { case `default`, moviePlayback, voiceChat }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let mixWithOthers = Self(rawValue: 1)
        static let defaultToSpeaker = Self(rawValue: 2)
    }
    struct SetActiveOptions: OptionSet {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Self(rawValue: 1)
    }
    static let shared = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { shared }
    var category: Category = .ambient
    var mode: Mode = .default
    var categoryOptions: CategoryOptions = [.defaultToSpeaker]
    var active = false
    var categoryCalls = 0
    var activationCalls = 0
    var deactivationOptions: SetActiveOptions = []
    var failCategory = false
    var failActivation = false
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws {
        if failCategory { throw NSError(domain: "fixture", code: 1) }
        categoryCalls += 1
        self.category = category; self.mode = mode; self.categoryOptions = options
    }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {
        activationCalls += 1
        if active && failActivation { throw NSError(domain: "fixture", code: 2) }
        self.active = active
        if !active { deactivationOptions = options }
    }
}
@MainActor final class AVPlayer {
    var pauses = 0
    func pause() { pauses += 1 }
}
@MainActor enum Checks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ reason: String) {
        guard value() else { fatalError(reason) }
        count += 1
    }
    static func reset() {
        AuthStore.shared.userID = "viewer"
        AuthStore.shared.syncSessionRevision = 1
        WorkspaceContext.selectedOrgID = UUID()
        AIImagePrep.count = 0
        AIImagePrep.atDecode = { _ in }
    }
}
@main struct Main {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("RendpropQuickStart.mp4")
        let transcript = directory.appendingPathComponent("RendpropQuickStart.txt")
        try Data([0, 1, 2]).write(to: video)
        try "  A readable introduction transcript.\n".write(to: transcript, atomically: true, encoding: .utf8)
        let local = ControlledBundle(video: video, text: transcript)
        Checks.check(QuickStartVideoAsset.videoURL(in: local) == video, "bundled video remains a local file")
        Checks.check(QuickStartVideoAsset.transcript(in: local) == "A readable introduction transcript.", "bundled transcript remains readable")
        Checks.check(QuickStartVideoAsset.videoURL(in: ControlledBundle(video: nil, text: nil)) == nil, "missing video does not invent a fallback")
        Checks.check(QuickStartVideoAsset.videoURL(in: ControlledBundle(video: URL(string: "https://invalid.example/video.mp4"), text: nil)) == nil, "preauth playback cannot accept a remote video URL")
        try "  \n".write(to: transcript, atomically: true, encoding: .utf8)
        Checks.check(QuickStartVideoAsset.transcript(in: local) == nil, "blank transcript is not presented as readable content")

        let checks = QuickStartKnowledgeCheck.questions
        Checks.check(checks.count == 3 && Set(checks.map(\.id)).count == 3, "optional knowledge checks have stable distinct identities")
        Checks.check(checks.allSatisfy { $0.answers.indices.contains($0.correctAnswer) && !$0.explanation.isEmpty }, "every check has a valid answer and corrective explanation")
        Checks.check(checks[0].answers[checks[0].correctAnswer].contains("retained original"), "photo instruction requires comparison before use")
        Checks.check(checks[1].answers[checks[1].correctAnswer].contains("Publish"), "website instruction requires publishing before sharing")
        Checks.check(checks[2].answers[checks[2].correctAnswer].contains("Ask AI"), "screen help instruction uses Ask AI")

        Checks.reset()
        let normal = PhotoReviewHarness()
        await normal.loadImages()
        Checks.check(normal.enhanced?.value == "edited.jpg", "edited image decodes normally")
        Checks.check(normal.original?.value == "original.jpg" && normal.imageLoadComplete, "source decode completes normal review")
        Checks.check(!normal.stagingReview.comparedSource && !normal.customReview.comparedSource, "loading edited image does not approve comparison")
        normal.sourceChanged(true)
        Checks.check(normal.stagingReview.comparedSource && normal.customReview.comparedSource, "opening source records comparison only")

        for boundary in ["owner", "revision", "workspace", "photo"] {
            for decode in [1, 2] {
                Checks.reset()
                let subject = PhotoReviewHarness()
                AIImagePrep.atDecode = { count in
                    if count == decode {
                        switch boundary {
                        case "owner": AuthStore.shared.userID = "someone-else"
                        case "revision": AuthStore.shared.syncSessionRevision += 1
                        case "workspace": WorkspaceContext.selectedOrgID = UUID()
                        default: subject.selectedVersion = EnhancedPhoto(id: "replacement", enhancedURL: video, originalURL: transcript)
                        }
                    }
                }
                await subject.loadImages()
                Checks.check(subject.original == nil && !subject.imageLoadComplete, "\(boundary) change during decode rejects the stale completed preview")
                if decode == 1 { Checks.check(subject.enhanced == nil, "\(boundary) change during first decode rejects stale edited pixels") }
            }
        }

        Checks.reset()
        let erased = PhotoReviewHarness()
        await erased.loadImages()
        erased.showFullComparison = true
        erased.exporting = true
        erased.clearAndDismiss()
        Checks.check(!erased.showFullComparison && erased.exporting == nil && erased.imageContext == nil, "dismissal clears enlarged preview and export context")
        Checks.check(erased.enhanced == nil && erased.original == nil && erased.dismissCount == 1, "dismissal clears both decoded images")

        Checks.reset()
        let changing = PhotoReviewHarness()
        await changing.loadImages()
        changing.showFullComparison = true
        changing.chooseVersion(EnhancedPhoto(id: "new", enhancedURL: video, originalURL: transcript))
        Checks.check(changing.enhanced == nil && changing.original == nil && changing.imageContext == nil, "version switch clears prior preview before the next decode")
        Checks.check(!changing.showFullComparison && !changing.imageLoadComplete && changing.viewed.id == "new", "version switch cannot leave a prior enlarged comparison displayed")
        changing.sourceChanged(true)
        Checks.check(!changing.stagingReview.comparedSource && !changing.customReview.comparedSource, "missing source cannot record a comparison")

        Checks.reset()
        let same = PhotoReviewHarness()
        await same.loadImages()
        same.showOriginal = true
        same.sourceChanged(true)
        same.chooseVersion(same.viewed)
        Checks.check(same.enhanced != nil && same.original != nil && same.imageContext?.isCurrent == true && same.imageLoadComplete,
                     "choosing the current version preserves loaded pixels because the decode task ID is unchanged")
        Checks.check(!same.showOriginal, "choosing the current edited chip switches back from Original without reloading")
        Checks.check(same.stagingReview.comparedSource && same.customReview.comparedSource,
                     "same-version chip preserves existing comparison evidence")

        let session = AVAudioSession()
        let audio = QuickStartPlaybackAudio(session: session)
        Checks.check(session.categoryCalls == 0 && session.activationCalls == 0, "constructing the introduction does not activate audio")
        try audio.activate()
        Checks.check(session.category == .playback && session.mode == .moviePlayback && session.categoryOptions == [.mixWithOthers] && session.active,
                     "explicit introduction playback uses movie audio that is not silenced by the ringer category")
        try audio.activate()
        Checks.check(session.categoryCalls == 1 && session.activationCalls == 1, "repeated playback callbacks keep the original audio snapshot")
        audio.restore()
        Checks.check(session.category == .ambient && session.mode == .default && session.categoryOptions == [.defaultToSpeaker],
                     "audio cleanup restores the exact prior category mode and options")
        Checks.check(!session.active && session.deactivationOptions == .notifyOthersOnDeactivation,
                     "audio cleanup deactivates with notifyOthersOnDeactivation")
        let calls = (session.categoryCalls, session.activationCalls)
        audio.restore()
        Checks.check(session.categoryCalls == calls.0 && session.activationCalls == calls.1, "audio cleanup is idempotent")
        try audio.activate(); audio.restore()
        Checks.check(session.category == .ambient && !session.active, "explicit resume after background reacquires and restores its audio scope")

        let failed = AVAudioSession(); failed.failActivation = true
        let failureAudio = QuickStartPlaybackAudio(session: failed)
        do { try failureAudio.activate(); Checks.check(false, "activation must throw") } catch {}
        Checks.check(failed.category == .ambient && failed.mode == .default && !failed.active,
                     "failed audio activation restores the previous configuration")
        let denied = AVAudioSession(); denied.failCategory = true
        do { try QuickStartPlaybackAudio(session: denied).activate(); Checks.check(false, "configuration must throw") } catch {}
        Checks.check(denied.activationCalls == 0 && denied.category == .ambient, "failed configuration never activates audio")

        for takeover in ["category", "mode", "options"] {
            let external = AVAudioSession(); let scoped = QuickStartPlaybackAudio(session: external)
            try scoped.activate()
            switch takeover {
            case "category": external.category = .playAndRecord
            case "mode": external.mode = .voiceChat
            default: external.categoryOptions = [.defaultToSpeaker]
            }
            let previousCalls = (external.categoryCalls, external.activationCalls)
            scoped.restore()
            Checks.check(external.categoryCalls == previousCalls.0 && external.activationCalls == previousCalls.1,
                         "\(takeover) takeover by another audio activity prevents stale restoration or deactivation")
        }
        let takeover = AVAudioSession(); let takeAudio = QuickStartPlaybackAudio(session: takeover)
        try takeAudio.activate(); takeover.category = .playAndRecord
        let beforeCalls = (takeover.categoryCalls, takeover.activationCalls)
        do { try takeAudio.activate(); Checks.check(false, "changed audio owner must throw") } catch {}
        takeAudio.restore()
        Checks.check(takeover.categoryCalls == beforeCalls.0 && takeover.activationCalls == beforeCalls.1,
                     "a late replay callback cannot overwrite another audio activity")

        let playback = QuickStartPlaybackHarness()
        Checks.check(playback.enableAudio(for: playback.player!), "view playback enables the scoped audio helper")
        playback.stopPlayback()
        Checks.check(playback.player?.pauses == 1 && !AVAudioSession.shared.active,
                     "view background or dismissal pauses playback before releasing its audio scope")
        print("PASS \(Checks.count) actual-body/bundle assertions; closed decoder and presentation boundaries")
    }
}
