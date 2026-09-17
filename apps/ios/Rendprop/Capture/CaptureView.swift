import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Full-screen guided capture: camera preview + level bubble + pace ring +
/// light meter + thirds grid + live room tagging. One-thumb reachable controls.
///
/// Flow: record → (pause/resume, any number of times) → (finalizing) →
/// "Use this take / Retake" review → onComplete.
/// X while recording stops AND discards the take (after a confirm); a
/// discarded or retaken file (and its motion sidecar) is deleted on the spot,
/// so no orphan captures pile up in Documents (audit F-D-16).
///
/// PAUSE exists because a real walkthrough is not a clean run: a client walks
/// into frame, a door sticks, someone says something. iOS has no pause on
/// `AVCaptureMovieFileOutput`, so `CameraManager` records a piece per stretch
/// and hands back the list; this screen joins them into one file before the
/// review card, passthrough, no re-encode.
struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraManager()
    @StateObject private var motion = MotionRecorder()
    @State private var tags: [RoomTag] = []

    // Take review ("Use this take / Retake")
    @State private var review: TakeReview?
    @State private var reviewPlayer: AVQueuePlayer?
    @State private var reviewLooper: AVPlayerLooper?
    @State private var isSavingTake = false
    @State private var reviewError: String?

    // X while recording → stop & discard (after confirming)
    @State private var showDiscardConfirm = false
    /// Joining the pieces of a paused take back into one file.
    @State private var isJoining = false
    /// Set only when the join failed and the review card is showing one piece
    /// instead of the whole take. Never silently swallowed — footage is the one
    /// thing this screen must not lose quietly.
    @State private var joinWarning: String?

    let onComplete: (CaptureAsset) -> Void

    struct TakeReview {
        let url: URL
        let sidecar: URL?
        let tags: [RoomTag]
        let seconds: Double
    }

    var body: some View {
        ZStack {
            // Camera chrome stays dark (it sits over live video); the
            // permission/error states use the app's light background.
            (isInfoState ? Theme.bg : Color.black).ignoresSafeArea()

            switch camera.state {
            case .denied:
                permissionDenied
            case .restricted:
                permissionRestricted
            case .failed(let message):
                failure(message)
            default:
                // Camera chrome is ALWAYS dark, regardless of the app's
                // appearance: forcing the dark trait here makes materials
                // render as dark smoke and every adaptive Theme token resolve
                // to its bright dark-mode variant — correct over live video
                // in both app modes.
                Group {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea()
                    ThirdsGrid().ignoresSafeArea()
                    if let review {
                        reviewOverlay(review)
                    } else {
                        overlays
                    }
                }
                .environment(\.colorScheme, .dark)
            }
        }
        .statusBarHidden()
        .onAppear {
            IdleTimer.hold()                       // the screen must not sleep mid-take
            camera.onFinish = handleFinished
            camera.onRecordingStarted = { motion.beginLogging() }   // sidecar t=0 = first frame
            camera.onRecordingResumed = { motion.resumeLogging() }  // same clock, pause skipped
            camera.onDiscarded = {
                motion.cancelLogging()
                tags.removeAll()
                Haptics.selection()
            }
            camera.start()
            motion.startUpdates()
        }
        .onDisappear {
            IdleTimer.release()
            // Break the CameraManager ↔ closure ↔ view cycle (audit F-D-17).
            camera.onFinish = nil
            camera.onRecordingStarted = nil
            camera.onRecordingResumed = nil
            camera.onDiscarded = nil
            motion.stopUpdates()
            camera.stop()
            stopReviewPlayback()
        }
        .confirmationDialog("Stop and discard this take?", isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Discard take", role: .destructive) {
                camera.cancelTake()
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The footage recorded so far will be deleted.")
        }
    }

    private var isRecording: Bool { camera.state == .recording }
    private var isPaused: Bool { camera.state == .paused }
    /// A take exists — recording or held. Stop always applies; so does tagging.
    private var takeInProgress: Bool { isRecording || isPaused }
    private var isFinalizing: Bool { camera.state == .finalizing }

    private var isInfoState: Bool {
        switch camera.state {
        case .denied, .restricted, .failed: return true
        default: return false
        }
    }

    /// Landscape (or nearly) — the tour records upright; say so instead of
    /// silently saving a sideways video (audit F-D-18).
    private var isSideways: Bool { abs(motion.roll) > 1.05 }   // > ~60°

    // MARK: - Overlay chrome

    private var overlays: some View {
        VStack {
            // Top bar
            HStack(alignment: .top) {
                Button {
                    if takeInProgress {
                        showDiscardConfirm = true
                    } else if !isFinalizing {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(isFinalizing)
                .accessibilityLabel(Text(takeInProgress ? "Stop and discard take" : "Close"))

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if isRecording || isPaused {
                        HStack(spacing: 6) {
                            // Solid red while writing, hollow amber while held —
                            // the dot alone says which one you are in, from
                            // across a room, without reading the word.
                            Group {
                                if isPaused {
                                    Circle().strokeBorder(Theme.warn, lineWidth: 2)
                                } else {
                                    Circle().fill(Theme.bad)
                                }
                            }
                            .frame(width: 8, height: 8)
                            Text(isPaused
                                 ? "Paused · \(Formatters.duration(camera.elapsed))"
                                 : Formatters.duration(camera.elapsed))
                                .font(.rpMono)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(isPaused
                                                 ? "Paused at \(Formatters.duration(camera.elapsed))"
                                                 : "Recording, \(Formatters.duration(camera.elapsed))"))
                    } else if isFinalizing {
                        HStack(spacing: 6) {
                            ProgressView().tint(.white).scaleEffect(0.8)
                            Text(isJoining ? "Joining your take…" : "Saving take…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel(Text(isJoining ? "Joining your take" : "Saving take"))
                    }
                    // Explicit white (never adaptive ink) — this text sits
                    // directly on the video feed.
                    Text(camera.formatLabel)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .shadow(radius: 2)
                    if !camera.stabilizationLabel.isEmpty {
                        Text(camera.stabilizationLabel)
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .shadow(radius: 2)
                    }
                }
            }
            .padding(.horizontal)

            // Banners
            VStack(spacing: 8) {
                if let message = camera.thermalMessage { banner(message, color: Theme.warn) }
                if let message = camera.interruptionMessage { banner(message, color: Theme.bad) }
                if let message = camera.storageMessage { banner(message, color: Theme.bad) }
                if isSideways { banner("Hold your phone upright — tours record in portrait", color: Theme.warn) }
                LightWarning(luminance: camera.luminance)
            }
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.25), value: camera.luminance < 0.18)
            .animation(.easeInOut(duration: 0.25), value: isSideways)

            Spacer()

            // Guidance instruments + lens toggle
            HStack {
                LevelBubble(roll: motion.roll, pitch: motion.pitch)
                Spacer()
                if camera.supportsUltraWide {
                    Button {
                        camera.toggleLens()   // haptic fires inside (once)
                    } label: {
                        Text(camera.isUltraWide ? "0.5×" : "1×")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(camera.isUltraWide ? Theme.accent : .white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(camera.isUltraWide ? Theme.accent : .white.opacity(0.25),
                                                           lineWidth: 1))
                    }
                    .accessibilityLabel(Text(camera.isUltraWide ? "Ultra-wide lens on" : "Standard lens"))
                    Spacer()
                }
                PaceRing(pace: motion.pace, isRecording: isRecording)
            }
            .padding(.horizontal, 28)

            // Room tags — timestamped from the take's own clock. Tagging works
            // while held too: pausing to say "this is the primary bedroom" is
            // exactly when someone reaches for it.
            RoomTagBar(isRecording: takeInProgress, tags: $tags,
                       currentTime: { camera.currentRecordedSeconds })
                .padding(.vertical, 10)

            // Record button — big, reachable, dead centre. Pause sits beside it
            // in a fixed-width slot so the record button does not shift when it
            // appears mid-take.
            HStack(spacing: 0) {
                Group {
                    if takeInProgress { pauseButton }
                }
                .frame(width: 92)
                recordButton
                Color.clear.frame(width: 92, height: 1)
            }
            .padding(.bottom, 6)

            Text(captionText)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.6))
                .shadow(radius: 2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
    }

    private var captionText: String {
        if isPaused {
            return "Held — nothing is being recorded. Resume and it carries on in the same take."
        }
        if isRecording {
            return "Tap to stop · pause any time · takes stop on their own at \(Formatters.duration(CameraManager.maxRecordingSeconds))"
        }
        return "One take, up to \(Formatters.duration(CameraManager.maxRecordingSeconds)) — pause whenever you need to"
    }

    /// Pause / Resume. Deliberately NOT a second red circle: two identical
    /// buttons beside each other is how someone taps the wrong one and loses a
    /// walkthrough.
    private var pauseButton: some View {
        Button {
            if isPaused {
                camera.resumeRecording()
                Haptics.selection()
            } else {
                motion.pauseLogging()
                camera.pauseRecording()
                Haptics.selection()
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isPaused ? Theme.warn : .white)
                Text(isPaused ? "Resume" : "Pause")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .frame(width: 62, height: 62)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(isPaused ? Theme.warn : Color.white.opacity(0.35),
                                           lineWidth: isPaused ? 2 : 1))
        }
        .disabled(isFinalizing)
        .accessibilityLabel(Text(isPaused ? "Resume recording" : "Pause recording"))
        .accessibilityIdentifier("capture.pause")
    }

    private var recordButton: some View {
        Button {
            if takeInProgress {
                camera.stopRecording()
            } else {
                tags.removeAll()
                camera.startRecording()   // motion logging starts from the first written frame
                Analytics.track("capture_started", ["space_type": SpaceType.current.rawValue])
                Haptics.heavy()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: takeInProgress ? 6 : 32, style: .continuous)
                    .fill(Theme.bad)
                    .frame(width: takeInProgress ? 30 : 62, height: takeInProgress ? 30 : 62)
                    .animation(.spring(response: 0.3), value: takeInProgress)
            }
        }
        // Starting a take while the session is interrupted (a call, Control
        // Center, another app on screen) fails in the movie output and dropped
        // the whole screen into the ".failed" dead-end. The banner already says
        // what is happening — keep the button out of reach until it clears.
        // Stopping a take that already exists is ALWAYS allowed, interrupted or
        // not — the alternative is footage stranded behind a banner.
        .disabled(camera.state == .configuring || camera.state == .idle || isFinalizing
                  || (!takeInProgress && camera.interruptionMessage != nil))
        .accessibilityLabel(Text(takeInProgress ? "Stop recording" : "Start recording"))
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(0.9), in: Capsule())
            .foregroundStyle(.black)
    }

    // MARK: - Take review ("Use this take / Retake")

    private func reviewOverlay(_ take: TakeReview) -> some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("YOUR TAKE")
                    .font(.rpKicker)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .padding(.top, 8)

                if let reviewPlayer {
                    VideoPlayer(player: reviewPlayer)
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .frame(maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel(Text("Preview of your take"))
                }

                HStack(spacing: 18) {
                    Label(Formatters.duration(take.seconds), systemImage: "timer")
                    Label("\(take.tags.count) \(take.tags.count == 1 ? "tag" : "tags")", systemImage: "tag")
                    if !camera.formatLabel.isEmpty {
                        Label(camera.formatLabel, systemImage: "video")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.85))

                if let joinWarning {
                    Label(joinWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal)
                }

                if let reviewError {
                    Text(reviewError)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 10) {
                    Button {
                        useTake(take)
                    } label: {
                        HStack(spacing: 8) {
                            if isSavingTake { ProgressView().tint(.white) }
                            Text(isSavingTake ? "Checking take…" : "Use this take")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.accent)
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isSavingTake)

                    Button {
                        retake(take)
                    } label: {
                        Text("Retake")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.12))
                            .foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isSavingTake)
                }

                Text("Retake deletes this file. Tags are re-recorded on the next take.")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    // MARK: - Permission / failure states

    private var permissionDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash")
                .font(.system(size: 40))
                .foregroundStyle(Theme.inkDim)
            Text("Camera access is off")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text("Rendprop needs the camera to record a walkthrough. Enable it in Settings.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Close") { dismiss() }
                .foregroundStyle(Theme.inkDim)
        }
        .padding(32)
    }

    /// Screen Time / MDM restriction — the app's Settings page can't lift it,
    /// so no "Open Settings" button that leads nowhere (audit F-D-22).
    private var permissionRestricted: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(Theme.inkDim)
            Text("Camera access is restricted")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text("Screen Time or a device management profile is blocking the camera on this iPhone, so Rendprop can't turn it on. Ask whoever manages this device to allow the camera — or import a video instead.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(.rpBody)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    // MARK: - Finalize

    /// The camera handed back the finished take as its pieces, in order (one
    /// piece if it was never paused, an interrupted partial, or the 10-minute
    /// cap). Join them if there is more than one, then show the review card.
    private func handleFinished(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pauses = urls.count - 1
        if pauses == 0 {
            present(take: urls[0], pauses: 0)
            return
        }
        isJoining = true
        Task {
            let joined = await TakeJoiner.join(urls)
            await MainActor.run {
                isJoining = false
                if let joined {
                    // The pieces have been copied into the joined file; keeping
                    // them would double the storage of every paused take.
                    for piece in urls { Self.deleteTake(piece) }
                    present(take: joined, pauses: pauses)
                } else {
                    // NEVER LOSE FOOTAGE (master spec 4.2). The join failed, so
                    // hand back the first piece — the start of the walkthrough —
                    // and say plainly that the rest is still on the phone rather
                    // than pretending this is the whole take.
                    joinWarning = "The \(pauses == 1 ? "pause" : "pauses") couldn\u{2019}t be joined, so this is the first part of your take. Nothing was deleted — record again if you need it in one piece."
                    present(take: urls[0], pauses: pauses)
                }
            }
        }
    }

    /// Write the sidecar beside the final file and put the review card up.
    private func present(take url: URL, pauses: Int) {
        let sidecar = motion.endLogging(besideVideoAt: url,
                                        fps: camera.activeFPS,
                                        width: camera.activeWidth,
                                        height: camera.activeHeight)
        Haptics.success()   // the one "clip saved" haptic (CameraManager no longer fires its own)
        Analytics.track("capture_finished", ["space_type": SpaceType.current.rawValue,
                                             "duration_s": String(Int(camera.elapsed)),
                                             "pauses": String(pauses)])
        let take = TakeReview(url: url, sidecar: sidecar, tags: tags, seconds: camera.elapsed)

        // Muted looping preview of the take behind the buttons.
        let player = AVQueuePlayer()
        player.isMuted = true
        reviewLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        reviewPlayer = player
        player.play()

        reviewError = nil
        review = take
    }

    private func useTake(_ take: TakeReview) {
        guard !isSavingTake else { return }
        isSavingTake = true
        reviewError = nil
        let fallbackFPS = camera.activeFPS
        Task {
            do {
                // Validates the file (duration, video track, dimensions,
                // playable) — a broken partial never reaches Review & Submit.
                var asset = try await MediaImporter.makeAsset(from: take.url, isDrone: false,
                                                              deleteOnFailure: false)
                asset.motionSidecarURL = take.sidecar
                asset.roomTags = take.tags
                if asset.fps <= 0 { asset.fps = fallbackFPS }
                await MainActor.run {
                    stopReviewPlayback()
                    onComplete(asset)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSavingTake = false
                    reviewError = "This take can't be used — \(error.localizedDescription) Try recording again."
                }
            }
        }
    }

    private func retake(_ take: TakeReview) {
        stopReviewPlayback()
        Self.deleteTake(take.url)
        tags.removeAll()
        reviewError = nil
        joinWarning = nil
        review = nil
        Haptics.selection()
    }

    private func stopReviewPlayback() {
        reviewPlayer?.pause()
        reviewLooper?.disableLooping()
        reviewLooper = nil
        reviewPlayer = nil
    }

    /// Delete a take and its motion sidecar. The sidecar goes through
    /// `MotionRecorder.deleteSidecar` so the removal is ordered behind a write
    /// that may still be encoding on the sidecar queue — otherwise a fast
    /// Retake could delete first and have the pending write recreate the file.
    static func deleteTake(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        MotionRecorder.deleteSidecar(for: url)
    }
}

// MARK: - Joining a paused take

/// Joins the pieces of a paused take into one file.
///
/// PASSTHROUGH, not a re-encode. Every piece came out of the same capture
/// session with the same format, codec and dimensions, so the frames can be
/// copied into one container — a 4K 10-minute take re-encodes for minutes and
/// loses quality doing it, and neither is acceptable at the moment somebody
/// taps Stop.
enum TakeJoiner {
    /// Returns the joined file, or nil if anything about the join failed — the
    /// caller keeps the pieces in that case and says so.
    static func join(_ urls: [URL]) async -> URL? {
        guard urls.count > 1 else { return urls.first }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        var cursor = CMTime.zero
        var orientation: CGAffineTransform?
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration),
                  duration.isValid, duration.seconds.isFinite, duration.seconds > 0
            else { continue }
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                          of: source, at: cursor)
            } catch {
                continue
            }
            // Portrait capture writes its rotation as a track transform. Taking
            // it from the first piece keeps the joined file upright; without it
            // the whole take plays on its side.
            if orientation == nil { orientation = try? await source.load(.preferredTransform) }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard cursor.seconds > 0 else { return nil }
        if let orientation { track.preferredTransform = orientation }

        let out = FileStore.newRecordingURL()
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        export.outputURL = out
        export.outputFileType = .mov
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed,
              FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        MediaImporter.excludeFromBackup(FileStore.recordingsDir)
        return out
    }
}
