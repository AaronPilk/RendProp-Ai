import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Full-screen guided capture: camera preview + level bubble + pace ring +
/// light meter + thirds grid + live room tagging. One-thumb reachable controls.
///
/// Flow: record → (finalizing) → "Use this take / Retake" review → onComplete.
/// X while recording stops AND discards the take (after a confirm); a
/// discarded or retaken file (and its motion sidecar) is deleted on the spot,
/// so no orphan captures pile up in Documents (audit F-D-16).
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
    @State private var discardOnFinish = false

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
            camera.start()
            motion.startUpdates()
        }
        .onDisappear {
            IdleTimer.release()
            // Break the CameraManager ↔ closure ↔ view cycle (audit F-D-17).
            camera.onFinish = nil
            camera.onRecordingStarted = nil
            motion.stopUpdates()
            camera.stop()
            stopReviewPlayback()
        }
        .confirmationDialog("Stop and discard this take?", isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Discard take", role: .destructive) {
                discardOnFinish = true
                camera.stopRecording()
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The footage recorded so far will be deleted.")
        }
    }

    private var isRecording: Bool { camera.state == .recording }
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
                    if isRecording {
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
                .accessibilityLabel(Text(isRecording ? "Stop and discard take" : "Close"))

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if isRecording {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.bad).frame(width: 8, height: 8)
                            Text(Formatters.duration(camera.elapsed))
                                .font(.rpMono)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("Recording, \(Formatters.duration(camera.elapsed))"))
                    } else if isFinalizing {
                        HStack(spacing: 6) {
                            ProgressView().tint(.white).scaleEffect(0.8)
                            Text("Saving take…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel(Text("Saving take"))
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

            // Room tags — timestamped from the movie output's own clock.
            RoomTagBar(isRecording: isRecording, tags: $tags,
                       currentTime: { camera.currentRecordedSeconds })
                .padding(.vertical, 10)

            // Record button — big, reachable
            recordButton
                .padding(.bottom, 6)

            Text(isRecording
                 ? "Tap to stop · takes stop on their own at \(Formatters.duration(CameraManager.maxRecordingSeconds))"
                 : "One continuous take, up to \(Formatters.duration(CameraManager.maxRecordingSeconds))")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.6))
                .shadow(radius: 2)
                .padding(.bottom, 18)
        }
    }

    private var recordButton: some View {
        Button {
            if isRecording {
                camera.stopRecording()
            } else {
                tags.removeAll()
                camera.startRecording()   // motion logging starts from the first written frame
                Haptics.heavy()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 32, style: .continuous)
                    .fill(Theme.bad)
                    .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
                    .animation(.spring(response: 0.3), value: isRecording)
            }
        }
        .disabled(camera.state == .configuring || camera.state == .idle || isFinalizing)
        .accessibilityLabel(Text(isRecording ? "Stop recording" : "Start recording"))
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

    /// The movie output handed back a finalized file (full take, an interrupted
    /// partial, or the 10-minute cap). Either discard it (X while recording) or
    /// show the review card.
    private func handleFinished(_ url: URL) {
        if discardOnFinish {
            discardOnFinish = false
            motion.cancelLogging()
            Self.deleteTake(url, sidecar: nil)
            tags.removeAll()
            Haptics.selection()
            return
        }
        let sidecar = motion.endLogging(besideVideoAt: url,
                                        fps: camera.activeFPS,
                                        width: camera.activeWidth,
                                        height: camera.activeHeight)
        Haptics.success()   // the one "clip saved" haptic (CameraManager no longer fires its own)
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
        Self.deleteTake(take.url, sidecar: take.sidecar)
        tags.removeAll()
        reviewError = nil
        review = nil
        Haptics.selection()
    }

    private func stopReviewPlayback() {
        reviewPlayer?.pause()
        reviewLooper?.disableLooping()
        reviewLooper = nil
        reviewPlayer = nil
    }

    /// Delete a take and its motion sidecar (the sidecar path is derived when
    /// the caller doesn't have it, e.g. a discarded take that never wrote one).
    static func deleteTake(_ url: URL, sidecar: URL?) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: sidecar ?? MotionRecorder.sidecarURL(for: url))
    }
}
