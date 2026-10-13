import SwiftUI
import AVKit
import AVFAudio

/// The introduction is bundled with the app. Watching it never needs an account,
/// network request or permission for photos, camera, location or AI.
enum QuickStartVideoAsset {
    static func videoURL(in bundle: Bundle = .main) -> URL? {
        guard let url = bundle.url(forResource: "RendpropQuickStart", withExtension: "mp4"),
              url.isFileURL else { return nil }
        return url
    }

    static func transcript(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "RendpropQuickStart", withExtension: "txt"),
              url.isFileURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct QuickStartKnowledgeCheck: Identifiable {
    let id: String
    let question: String
    let answers: [String]
    let correctAnswer: Int
    let explanation: String

    static let questions: [QuickStartKnowledgeCheck] = [
        .init(id: "review", question: "What should you do before using an AI-edited photo?",
              answers: ["Compare it with the retained original and review the changes", "Publish it immediately"],
              correctAnswer: 0,
              explanation: "Compare the edited photo with its retained source. Check fixed features, colors and materials before selecting it for your listing."),
        .init(id: "share", question: "How do you share a property website?",
              answers: ["Publish the property website, then share its link", "Send someone a screenshot of the editor"],
              correctAnswer: 0,
              explanation: "Publish the property website first. Then share the published link so buyers can view it and send an enquiry."),
        .init(id: "help", question: "Where can you get help with the screen you're using?",
              answers: ["Tap Ask AI on that screen", "Start another listing"],
              correctAnswer: 0,
              explanation: "Tap Ask AI for help with the current screen. You can ask what a control does or how to take the next step.")
    ]
}

/// Owns only the introduction's audio configuration. If another feature starts
/// recording or changes the session, cleanup leaves that newer configuration alone.
@MainActor private final class QuickStartPlaybackAudio {
    private struct Previous {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }
    private let session: AVAudioSession
    private var previous: Previous?

    init(session: AVAudioSession = .sharedInstance()) { self.session = session }

    func activate() throws {
        if previous != nil {
            guard ownsConfiguration else {
                previous = nil
                throw NSError(domain: "RendpropQuickStart", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Another audio activity is using the session."])
            }
            return
        }
        let saved = Previous(category: session.category, mode: session.mode, options: session.categoryOptions)
        try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        previous = saved
        do { try session.setActive(true) }
        catch { restore(); throw error }
    }

    func restore() {
        guard let saved = previous else { return }
        previous = nil
        guard ownsConfiguration else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(saved.category, mode: saved.mode, options: saved.options)
    }

    private var ownsConfiguration: Bool {
        session.category == .playback && session.mode == .moviePlayback
            && session.categoryOptions == [.mixWithOthers]
    }
}

@MainActor struct QuickStartVideoView: View {
    var returnLabel = "Skip checks and return to sign-in"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var videoAspect: CGFloat = 16.0 / 9.0
    @State private var answers: [String: Int] = [:]
    @State private var playbackOpen = false
    @State private var playbackAudio = QuickStartPlaybackAudio()
    @State private var audioError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(videoAspect, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("Rendprop introduction video")
                            .accessibilityHint("Use the video controls to play, pause or replay.")
                            .accessibilityIdentifier("quickStart.video")
                            .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                                guard playbackOpen, scenePhase == .active else { stopPlayback(); return }
                                if status == .paused { playbackAudio.restore() }
                                else { enableAudio(for: player) }
                            }
                    } else {
                        ContentUnavailableVideo()
                    }

                    if let audioError {
                        Text(audioError).font(.body).foregroundStyle(Theme.inkDim)
                    }

                    if let transcript = QuickStartVideoAsset.transcript() {
                        DisclosureGroup("Read the video transcript") {
                            Text(transcript)
                                .font(.body).foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                                .padding(.top, 8)
                                .accessibilityIdentifier("quickStart.transcript")
                        }
                        .font(.headline).foregroundStyle(Theme.accent)
                    }

                    DisclosureGroup("Try 3 quick checks (optional)") {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(QuickStartKnowledgeCheck.questions) { check in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(check.question).font(.headline).foregroundStyle(Theme.ink)
                                    ForEach(check.answers.indices, id: \.self) { index in
                                        Button { answers[check.id] = index } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: answers[check.id] == index ? "checkmark.circle.fill" : "circle")
                                                Text(check.answers[index]).multilineTextAlignment(.leading)
                                            }
                                            .font(.body).foregroundStyle(Theme.ink)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(12)
                                            .background(Theme.accent.opacity(answers[check.id] == index ? 0.15 : 0.05),
                                                        in: RoundedRectangle(cornerRadius: 12))
                                        }
                                        .accessibilityIdentifier("quickStart.\(check.id).answer.\(index)")
                                    }
                                    if let answer = answers[check.id] {
                                        Text((answer == check.correctAnswer ? "That's right. " : "Here's the next step. ") + check.explanation)
                                            .font(.body).foregroundStyle(Theme.ink)
                                            .accessibilityIdentifier("quickStart.\(check.id).feedback")
                                    }
                                }
                            }
                        }.padding(.top, 12)
                    }
                    .font(.headline).foregroundStyle(Theme.accent)

                    Button(returnLabel) { stopPlayback(); dismiss() }
                        .font(.body).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("quickStart.skipChecks")
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("See how Rendprop works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { stopPlayback(); dismiss() }
                        .accessibilityIdentifier("quickStart.close")
                }
            }
        }
        .task {
            playbackOpen = true
            guard player == nil, let url = QuickStartVideoAsset.videoURL() else { return }
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                let ratio = abs(rect.width / rect.height)
                if ratio.isFinite, ratio > 0 { videoAspect = ratio }
            }
            guard !Task.isCancelled, playbackOpen else { return }
            let localPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = localPlayer
            // The person explicitly opened the video; this is not autoplay on launch.
            if scenePhase == .active, enableAudio(for: localPlayer) { localPlayer.play() }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { stopPlayback() }
        }
        .onDisappear { playbackOpen = false; stopPlayback(); player = nil }
    }

    @discardableResult private func enableAudio(for player: AVPlayer) -> Bool {
        do { try playbackAudio.activate(); audioError = nil; return true }
        catch {
            player.pause()
            audioError = "Couldn't enable video sound. Read the transcript or try playing again."
            return false
        }
    }

    private func stopPlayback() {
        player?.pause()
        playbackAudio.restore()
    }

    private struct ContentUnavailableVideo: View {
        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "play.rectangle").font(.largeTitle)
                Text("Introduction video unavailable").font(.headline)
                Text("Close this video to continue.")
                    .font(.body).multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.inkDim)
            .frame(maxWidth: .infinity).padding(.vertical, 48)
        }
    }
}
