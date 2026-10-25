import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

@MainActor
protocol VideoMusicPreviewPlayback: AnyObject {
    var isPlaying: Bool { get }
    var onFinish: (() -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    func play() -> Bool
    func pause()
    func stop()
}

/// Preview has its own local player. Selecting music never starts playback or
/// changes the music mixed into a saved video.
@MainActor
final class VideoMusicPreviewController: ObservableObject {
    @Published private(set) var trackID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    private var playback: (any VideoMusicPreviewPlayback)?
    private let makePlayback: (VerifiedMusicTrack) throws -> any VideoMusicPreviewPlayback
    private var observers: [NSObjectProtocol] = []

    init(makePlayback: ((VerifiedMusicTrack) throws -> any VideoMusicPreviewPlayback)? = nil) {
        self.makePlayback = makePlayback ?? { track in
            try LocalVideoMusicPreviewPlayback(url: VideoMusicCatalog.localURL(for: track))
        }
        #if os(iOS)
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     UIApplication.willResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stop() }
            })
        }
        #endif
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func toggle(_ track: VerifiedMusicTrack) {
        errorMessage = nil
        guard track.isEligible else { fail(); return }
        if trackID == track.id, let playback {
            if isPlaying {
                playback.pause()
                isPlaying = false
            } else { start(playback) }
            return
        }
        stop()
        do {
            let next = try makePlayback(track)
            playback = next
            trackID = track.id
            next.onFinish = { [weak self, weak next] in
                guard let self, let next, self.playback === next else { return }
                self.stop()
            }
            next.onFailure = { [weak self, weak next] in
                guard let self, let next, self.playback === next else { return }
                self.fail()
            }
            start(next)
        } catch { fail() }
    }

    func selectionChanged(to selection: VideoMusicSelection?) {
        if selection?.trackID != trackID || selection == nil { stop() }
    }

    func stop() {
        playback?.onFinish = nil
        playback?.onFailure = nil
        playback?.stop()
        playback = nil
        trackID = nil
        isPlaying = false
        errorMessage = nil
    }

    private func start(_ next: any VideoMusicPreviewPlayback) {
        guard next.play(), next.isPlaying else { fail(); return }
        isPlaying = true
    }

    private func fail() {
        stop()
        errorMessage = "This music preview isn't available. Choose Off or another track."
    }
}

@MainActor
private final class LocalVideoMusicPreviewPlayback: NSObject, VideoMusicPreviewPlayback, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?
    var onFailure: (() -> Void)?
    var isPlaying: Bool { player.isPlaying }

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        guard player.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
    }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop(); player.currentTime = 0 }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            if flag { self?.onFinish?() } else { self?.onFailure?() }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFailure?() }
    }
}

struct VideoMusicPicker: View {
    @Binding var selection: VideoMusicSelection?
    var previewedTrackID: String? = nil
    var isPreviewPlaying = false
    var previewError: String? = nil
    var onStop: () -> Void = {}
    var onPreview: (VerifiedMusicTrack) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background music · optional").font(.rpBody.weight(.semibold))
            Button { onStop(); selection = nil } label: {
                Label("Off", systemImage: selection == nil ? "checkmark.circle.fill" : "circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(RendpropPillButtonStyle(selected: selection == nil, compact: true))
            .accessibilityIdentifier("video.music.off")
            ForEach(VideoMusicCatalog.tracks) { track in
                (dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 12))) {
                    Button {
                        onStop()
                        selection = VideoMusicSelection(trackID: track.id, assetSHA256: track.assetSHA256,
                            licenseID: track.licenseID, licenseEvidenceSHA256: track.licenseEvidenceSHA256)
                    } label: {
                        Label(track.title, systemImage: selection?.trackID == track.id ? "checkmark.circle.fill" : "music.note")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(RendpropPillButtonStyle(selected: selection?.trackID == track.id, compact: true))
                    Button { onPreview(track) } label: {
                        Image(systemName: previewedTrackID == track.id && isPreviewPlaying ? "pause.circle" : "play.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(minWidth: 24, minHeight: 24)
                    }
                        .buttonStyle(RendpropPillButtonStyle(compact: true, horizontalPadding: 10))
                        .accessibilityLabel((previewedTrackID == track.id && isPreviewPlaying ? "Pause " : "Play ") + track.title)
                        .accessibilityValue(previewedTrackID == track.id ? (isPreviewPlaying ? "Playing" : "Paused") : "Not playing")
                        .accessibilityIdentifier("video.music.preview.\(track.id)")
                }.accessibilityIdentifier("video.music.\(track.id)")
            }
            if let previewError { Text(previewError).font(.rpCaption).foregroundStyle(Theme.warn) }
            Text("These tracks are offered under CC0. Music stays quieter beneath narration. Your choice is saved with this video.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }.foregroundStyle(Theme.ink)
    }
}
