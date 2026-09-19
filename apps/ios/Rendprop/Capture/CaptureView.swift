import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Full-screen guided capture: camera preview + level bubble + pace ring +
/// light meter + thirds grid + live room tagging. One-thumb reachable controls.
///
/// Flow: record → (pause/resume, any number of times) → (finalizing) →
/// "Use this take / Retake" review → onComplete.
/// X while recording discards only after confirmation. Completed pieces are
/// journaled before joining and remain available in Saved takes after relaunch.
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
    @State private var recordingRecovery: RecoverableTake?
    @State private var recovery: RecoverableTake?
    @State private var recoveryError: String?
    @State private var savedTakes: [RecoverableTake] = []
    @State private var otherRecordings: [TakeRecoveryStore.OtherRecording] = []
    @State private var unreadableRecoveries = 0
    @State private var showSavedTakes = false
    @State private var showRecoveryCloseConfirm = false

    let onComplete: (CaptureAsset) -> Void

    struct TakeReview {
        let url: URL
        let sidecar: URL?
        let tags: [RoomTag]
        let seconds: Double
        let fps: Double
        let formatLabel: String
        let recovery: RecoverableTake
        /// Where somebody was visible, on this take's clock.
        var people: [TimeRange] = []
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
        .interactiveDismissDisabled(isFinalizing || isSavingTake || takeInProgress || (recovery.map { !isDurablySaved($0) } ?? false))
        .overlay {
            if let recovery { recoveryOverlay(recovery) }
        }
        .overlay(alignment: .bottom) {
            if isInfoState, recovery == nil { savedTakesButton.padding(.bottom, 24) }
        }
        .sheet(isPresented: $showSavedTakes) { savedTakesSheet }
        .onChange(of: tags) { updated in
            guard var checkpoint = recordingRecovery else { return }
            checkpoint.tags = updated
            recordingRecovery = checkpoint
            do { try TakeRecoveryStore.save(checkpoint) }
            catch { recoveryError = "The take is on your phone, but its recovery details couldn’t be saved. Stop and export its parts before leaving." }
        }
        .onAppear {
            IdleTimer.hold()                       // the screen must not sleep mid-take
            camera.onFinish = handleFinished
            camera.onRecordingStarted = { motion.beginLogging() }   // sidecar t=0 = first frame
            camera.onSegmentStarted = { motion.beginSegment(atUptime: $0, joinedOffset: $1) }
            camera.onSegmentFinished = { motion.finishSegment(duration: $0) }
            camera.onSegmentsChanged = checkpointTake
            camera.onDiscarded = {
                motion.cancelLogging()
                if let recordingRecovery { TakeRecoveryStore.forgetDiscarded(recordingRecovery.id) }
                recordingRecovery = nil
                tags.removeAll()
                Haptics.selection()
            }
            refreshSavedTakes()
            camera.start()
            motion.startUpdates()
        }
        .onDisappear {
            IdleTimer.release()
            // Break the CameraManager ↔ closure ↔ view cycle (audit F-D-17).
            camera.onFinish = nil
            camera.onRecordingStarted = nil
            camera.onRecordingResumed = nil
            camera.onSegmentStarted = nil
            camera.onSegmentFinished = nil
            camera.onSegmentsChanged = nil
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
        .confirmationDialog("Close without a saved recovery record?", isPresented: $showRecoveryCloseConfirm,
                            titleVisibility: .visible) {
            Button("Close") { dismiss() }
            Button("Stay and save the parts", role: .cancel) {}
        } message: {
            Text("Nothing will be deleted, but these parts may not appear in Saved takes after closing. Save each part to Files first.")
        }
    }

    private var isRecording: Bool { camera.state == .recording }
    private var isPaused: Bool { camera.state == .paused }
    /// A take exists — recording or held. Stop always applies; so does tagging.
    private var takeInProgress: Bool { isRecording || isPaused }
    private var isFinalizing: Bool { camera.state == .finalizing || isJoining }

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

                if !takeInProgress { savedTakesButton.disabled(isFinalizing) }

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
                if let message = camera.personDetectionUnavailableMessage { banner(message, color: Theme.warn) }
                if let message = camera.interruptionMessage { banner(message, color: Theme.bad) }
                if let message = camera.storageMessage { banner(message, color: Theme.bad) }
                if let recoveryError { banner(recoveryError, color: Theme.warn) }
                if isSideways { banner("Hold your phone upright — tours record in portrait", color: Theme.warn) }
                PersonWarning(visible: camera.personInShot)
                LightWarning(luminance: camera.luminance)
            }
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.25), value: camera.luminance < 0.18)
            .animation(.easeInOut(duration: 0.25), value: isSideways)
            .animation(.easeInOut(duration: 0.25), value: camera.personInShot)

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
                    .disabled(takeInProgress || isFinalizing)
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
                    if !take.formatLabel.isEmpty {
                        Label(take.formatLabel, systemImage: "video")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.85))

                // Said here rather than swallowed. Retaking a 90-second
                // walkthrough is cheap; finding yourself in the hallway mirror
                // after the tour is published is not.
                if !take.people.isEmpty {
                    let n = take.people.count
                    let secs = Int(take.people.reduce(0) { $0 + $1.durationS }.rounded())
                    Label("Someone was in shot — \(n) \(n == 1 ? "moment" : "moments"), about \(secs)s. Worth a retake if it was you in a mirror.",
                          systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal)
                        .accessibilityLabel(Text("Someone was visible in \(n) moments, about \(secs) seconds in total."))
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
                        Text("Record another")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.12))
                            .foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isSavingTake)
                }

                Text("Your original parts stay in Saved takes, including after you close the app.")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    // MARK: - Saved takes and failed-join recovery

    @ViewBuilder private var savedTakesButton: some View {
        if !savedTakes.isEmpty || !otherRecordings.isEmpty || unreadableRecoveries > 0 {
            Button { refreshSavedTakes(); showSavedTakes = true } label: {
                Label("Saved takes", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityIdentifier("capture.saved-takes")
        }
    }

    private var savedTakesSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Original recordings are kept here so you can retry a join or save each part to Files.")
                        .font(.subheadline)
                }
                ForEach(savedTakes) { take in
                    Button {
                        showSavedTakes = false
                        stopReviewPlayback()
                        review = nil
                        recoveryError = nil
                        recovery = take
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(take.createdAt, style: .date).font(.headline)
                            Text("\(take.piecePaths.count) \(take.piecePaths.count == 1 ? "part" : "parts") · \(Formatters.duration(take.seconds))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if !otherRecordings.isEmpty {
                    Section {
                        ForEach(otherRecordings) { recording in
                            ShareLink(item: recording.url) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let date = recording.createdAt {
                                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                        } else { Text("Recording") }
                                        Text(Formatters.bytes(Int64(recording.bytes))).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                    } header: {
                        Text("Other recordings on this phone")
                    } footer: {
                        Text("These files have no saved-take record. Some may be parts from an older app version. Save them individually; their order has not been guessed.")
                    }
                }
                if unreadableRecoveries > 0 {
                    Text("\(unreadableRecoveries) saved \(unreadableRecoveries == 1 ? "take needs" : "takes need") help opening. The recovery records and original files have been kept. Contact Aaron@pilk.ai before clearing app data.")
                        .foregroundStyle(Theme.warn)
                }
            }
            .navigationTitle("Saved takes")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSavedTakes = false } } }
        }
    }

    private func recoveryOverlay(_ take: RecoverableTake) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(isDurablySaved(take) ? "Your take is saved" : "Save your video parts", systemImage: "tray.full.fill").font(.rpTitle)
                Text("\(take.piecePaths.count) \(take.piecePaths.count == 1 ? "part" : "parts") · \(Formatters.duration(take.seconds))")
                    .font(.headline)
                Text("Retry joining the parts into one video, or save each part to Files. Your originals will stay on this phone.")
                    .font(.rpBody)
                if let recoveryError { Text(recoveryError).foregroundStyle(Theme.warn) }
                if isJoining {
                    ProgressView("Checking and joining your take…")
                } else {
                    Button(take.piecePaths.count == 1 ? "Review this take" : "Retry join") { joinSavedTake(take) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("capture.retry-join")
                }
                ForEach(Array(take.pieces.enumerated()), id: \.offset) { index, url in
                    if FileManager.default.fileExists(atPath: url.path) {
                        ShareLink(item: url) {
                            Label("Save part \(index + 1)", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isJoining)
                    } else {
                        Label("Part \(index + 1) is missing from this phone", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warn)
                    }
                }
                Button(isDurablySaved(take) ? "Keep for later" : "Close…") {
                    if isDurablySaved(take) {
                        recovery = nil
                        recoveryError = nil
                        refreshSavedTakes()
                        dismiss()
                    } else {
                        showRecoveryCloseConfirm = true
                    }
                }
                .disabled(isJoining)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .interactiveDismissDisabled(isJoining || !isDurablySaved(take))
    }

    private func isDurablySaved(_ take: RecoverableTake) -> Bool {
        savedTakes.contains {
            $0.id == take.id && $0.piecePaths == take.piecePaths &&
            $0.tags == take.tags && $0.people == take.people && $0.seconds == take.seconds
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

    private func refreshSavedTakes() {
        let library = TakeRecoveryStore.load()
        savedTakes = library.takes
        otherRecordings = library.otherRecordings
        unreadableRecoveries = library.unreadableCount
    }

    /// Called after each finalized segment, including Pause. The journal keeps
    /// the ordered parts reachable even if the process exits before Stop.
    private func checkpointTake(_ urls: [URL], seconds: Double) {
        guard let first = urls.first else { return }
        let sidecar = motion.checkpointLogging(besideVideoAt: first, fps: camera.activeFPS,
                                                width: camera.activeWidth, height: camera.activeHeight)
        let checkpoint = makeRecovery(urls, seconds: seconds, sidecar: sidecar)
        recordingRecovery = checkpoint
        do {
            try TakeRecoveryStore.save(checkpoint)
            recoveryError = nil
        } catch {
            recoveryError = "Recovery details couldn’t be saved. Your video parts are still on this phone. Stop and save the parts before leaving."
        }
        refreshSavedTakes()
    }

    private func makeRecovery(_ urls: [URL], seconds: Double, sidecar: URL?) -> RecoverableTake {
        RecoverableTake(id: recordingRecovery?.id ?? UUID(),
                        createdAt: recordingRecovery?.createdAt ?? Date(),
                        piecePaths: urls.map { FileStore.relativePath(for: $0) },
                        sidecarPath: sidecar.map { FileStore.relativePath(for: $0) },
                        tags: tags, people: camera.personVisibleRanges,
                        seconds: seconds, fps: camera.activeFPS,
                        width: camera.activeWidth, height: camera.activeHeight)
    }

    /// Freeze metadata and stop gyro logging BEFORE awaiting export. Joining
    /// never reads another take's mutable CameraManager or room-tag state.
    private func handleFinished(_ urls: [URL]) {
        guard let first = urls.first, !isJoining else { return }
        let sidecar = motion.endLogging(besideVideoAt: first, fps: camera.activeFPS,
                                        width: camera.activeWidth, height: camera.activeHeight)
        let take = makeRecovery(urls, seconds: camera.elapsed, sidecar: sidecar)
        recordingRecovery = nil
        recovery = take
        joinSavedTake(take)
    }

    private func joinSavedTake(_ take: RecoverableTake) {
        guard !isJoining else { return }
        isJoining = true
        recoveryError = nil
        recovery = take
        do {
            // Never allocate a joined replacement until all original paths and
            // metadata have a durable recovery record.
            try TakeRecoveryStore.save(take)
        } catch {
            isJoining = false
            refreshSavedTakes()
            recoveryError = "The recovery record couldn’t be saved. Nothing was deleted. Save each part to Files, then free some storage and retry."
            return
        }
        refreshSavedTakes()
        Task {
            // A single piece still receives the same complete media validation.
            // A prior joined output is retained; retry never overwrites it.
            let joined = await TakeJoiner.join(take.pieces)
            var completed = take
            if let joined, let first = take.pieces.first, joined != first,
               let copiedSidecar = await MotionRecorder.copySidecar(from: first, to: joined) {
                completed.sidecarPath = FileStore.relativePath(for: copiedSidecar)
            }
            let frozenCompleted = completed
            await MainActor.run {
                guard let joined else {
                    isJoining = false
                    recoveryError = "These parts couldn’t be joined safely. Every original has been kept. Retry, or save the parts individually."
                    return
                }
                var saved = frozenCompleted
                if !take.pieces.contains(joined) { saved.joinedPath = FileStore.relativePath(for: joined) }
                do {
                    try TakeRecoveryStore.save(saved)
                } catch {
                    isJoining = false
                    recovery = saved
                    recoveryError = "The video joined, but its recovery details couldn’t be saved. Every original remains available below. Free some storage and retry."
                    return
                }
                // onComplete has no durable-save acknowledgement. Retain all
                // original parts even after Use this take; never optimistically
                // delete the user's only independent copy of a walkthrough.
                isJoining = false
                recovery = nil
                refreshSavedTakes()
                present(take: joined, recovery: saved)
            }
        }
    }

    private func present(take url: URL, recovery saved: RecoverableTake) {
        Haptics.success()
        let label = "\(min(saved.width, saved.height) >= 2160 ? "4K" : "\(min(saved.width, saved.height))p") · \(Int(saved.fps.rounded())) fps"
        let take = TakeReview(url: url, sidecar: saved.sidecar, tags: saved.tags,
                              seconds: saved.seconds, fps: saved.fps, formatLabel: label,
                              recovery: saved, people: saved.people)
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
        let fallbackFPS = take.fps
        Task {
            do {
                // Validates the file (duration, video track, dimensions,
                // playable) — a broken partial never reaches Review & Submit.
                var asset = try await MediaImporter.makeAsset(from: take.url, isDrone: false,
                                                              deleteOnFailure: false)
                asset.motionSidecarURL = take.sidecar
                asset.roomTags = take.tags
                asset.personVisibleRanges = take.people
                if asset.fps <= 0 { asset.fps = fallbackFPS }
                await MainActor.run {
                    stopReviewPlayback()
                    onComplete(asset)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSavingTake = false
                    reviewError = "This take can't be used — \(error.localizedDescription) Your originals remain in Saved takes."
                }
            }
        }
    }

    private func retake(_ take: TakeReview) {
        stopReviewPlayback()
        // Record another keeps this completed take recoverable.
        tags.removeAll()
        reviewError = nil
        recoveryError = nil
        recordingRecovery = nil
        refreshSavedTakes()
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

/// A join is all-or-nothing. Originals remain in TakeRecoveryStore until the
/// user can recover them; this helper never deletes or overwrites an input.
enum TakeJoiner {
    private struct Video {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: CMTime
        let transform: CGAffineTransform
        let width: Int32
        let height: Int32
        let codec: FourCharCode
        let samples: Int64
    }

    private static func inspect(_ url: URL) async throws -> Video? {
        guard FileManager.default.fileExists(atPath: url.path),
              ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else { return nil }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { return nil }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { return nil }
        let duration = try await asset.load(.duration)
        let range = try await track.load(.timeRange)
        let formats = try await track.load(.formatDescriptions)
        guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0,
              range.start.isValid, abs(range.start.seconds) < 0.001,
              range.duration.isValid, abs(range.duration.seconds - duration.seconds) < 0.05,
              let format = formats.first else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let codec = CMFormatDescriptionGetMediaSubType(format)
        guard dimensions.width > 0, dimensions.height > 0,
              formats.allSatisfy({
                  let d = CMVideoFormatDescriptionGetDimensions($0)
                  return d.width == dimensions.width && d.height == dimensions.height &&
                      CMFormatDescriptionGetMediaSubType($0) == codec
              }) else { return nil }
        let transform = try await track.load(.preferredTransform)
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite),
              let samples = try sampleCount(asset: asset, track: track), samples > 0 else { return nil }
        return Video(asset: asset, track: track, duration: duration, transform: transform,
                     width: dimensions.width, height: dimensions.height, codec: codec, samples: samples)
    }

    /// Read compressed sample buffers without decoding 4K frames into memory.
    /// The completed output must contain every sample from every input.
    private static func sampleCount(asset: AVAsset, track: AVAssetTrack) throws -> Int64? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var count: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            let (next, overflow) = count.addingReportingOverflow(Int64(CMSampleBufferGetNumSamples(sample)))
            guard !overflow else { reader.cancelReading(); return nil }
            count = next
        }
        return reader.status == .completed ? count : nil
    }

    /// Returns only a complete, verified output. Missing, damaged or mismatched
    /// pieces fail the whole join and remain available for recovery/export.
    static func join(_ urls: [URL]) async -> URL? {
        guard !urls.isEmpty else { return nil }
        let inputPaths = urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard Set(inputPaths).count == urls.count else { return nil }
        var videos: [Video] = []
        do {
            for url in urls {
                guard !Task.isCancelled, let video = try await inspect(url) else { return nil }
                if let first = videos.first {
                    guard video.width == first.width, video.height == first.height,
                          video.codec == first.codec, video.transform == first.transform else { return nil }
                }
                videos.append(video)
            }
        } catch { return nil }
        guard let first = videos.first else { return nil }
        if videos.count == 1 { return first.duration.seconds <= MediaImporter.maxDurationSeconds ? urls[0] : nil }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        var expectedSamples: Int64 = 0
        do {
            for video in videos {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: video.duration), of: video.track, at: cursor)
                cursor = CMTimeAdd(cursor, video.duration)
                let (next, overflow) = expectedSamples.addingReportingOverflow(video.samples)
                guard !overflow else { return nil }
                expectedSamples = next
            }
        } catch { return nil }
        guard cursor.seconds <= MediaImporter.maxDurationSeconds else { return nil }
        track.preferredTransform = first.transform
        let out = FileStore.newRecordingURL()
        guard !inputPaths.contains(out.resolvingSymlinksInPath().standardizedFileURL.path),
              !FileManager.default.fileExists(atPath: out.path) else { return nil }
        var keepOutput = false
        defer { if !keepOutput { try? FileManager.default.removeItem(at: out) } }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { return nil }
        export.outputURL = out
        export.outputFileType = .mov
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard !Task.isCancelled, export.status == .completed else { return nil }
        do {
            guard let result = try await inspect(out), result.samples == expectedSamples,
                  result.duration.seconds <= MediaImporter.maxDurationSeconds,
                  abs(result.duration.seconds - cursor.seconds) < 0.05,
                  result.width == first.width, result.height == first.height,
                  result.codec == first.codec, result.transform == first.transform else { return nil }
        } catch { return nil }
        MediaImporter.excludeFromBackup(FileStore.recordingsDir)
        keepOutput = true
        return out
    }
}
