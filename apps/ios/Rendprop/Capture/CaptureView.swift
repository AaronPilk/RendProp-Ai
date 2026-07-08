import SwiftUI
import AVFoundation
import UIKit

/// Full-screen guided capture: camera preview + level bubble + pace ring +
/// light meter + thirds grid + live room tagging. One-thumb reachable controls.
struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraManager()
    @StateObject private var motion = MotionRecorder()
    @State private var tags: [RoomTag] = []
    @State private var metronome: Timer? = nil

    let onComplete: (CaptureAsset) -> Void

    var body: some View {
        ZStack {
            // Camera chrome stays dark (it sits over live video); the
            // permission/error states use the app's light background.
            (isInfoState ? Theme.bg : Color.black).ignoresSafeArea()

            switch camera.state {
            case .denied:
                permissionDenied
            case .failed(let message):
                failure(message)
            default:
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                ThirdsGrid().ignoresSafeArea()
                overlays
            }
        }
        .statusBarHidden()
        .onAppear {
            camera.start()
            motion.startUpdates()
            camera.onFinish = handleFinished
        }
        .onDisappear {
            metronome?.invalidate()
            motion.stopUpdates()
            camera.stop()
        }
    }

    private var isRecording: Bool { camera.state == .recording }

    private var isInfoState: Bool {
        if camera.state == .denied { return true }
        if case .failed = camera.state { return true }
        return false
    }

    // MARK: - Overlay chrome

    private var overlays: some View {
        VStack {
            // Top bar
            HStack(alignment: .top) {
                Button {
                    if isRecording { camera.stopRecording() } else { dismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(Text(isRecording ? "Stop and close" : "Close"))

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if isRecording {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.bad).frame(width: 8, height: 8)
                            Text(Formatters.duration(camera.elapsed))
                                .font(.rpMono)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    Text(camera.formatLabel)
                        .font(.caption2)
                        .foregroundStyle(Theme.inkDim)
                        .shadow(radius: 2)
                }
            }
            .padding(.horizontal)

            // Banners
            VStack(spacing: 8) {
                if let message = camera.thermalMessage { banner(message, color: Theme.warn) }
                if let message = camera.interruptionMessage { banner(message, color: Theme.bad) }
                LightWarning(luminance: camera.luminance)
            }
            .animation(.easeInOut(duration: 0.25), value: camera.luminance < 0.18)

            Spacer()

            // Guidance instruments
            HStack {
                LevelBubble(roll: motion.roll, pitch: motion.pitch)
                Spacer()
                PaceRing(pace: motion.pace, isRecording: isRecording)
            }
            .padding(.horizontal, 28)

            // Room tags
            RoomTagBar(elapsed: camera.elapsed, isRecording: isRecording, tags: $tags)
                .padding(.vertical, 10)

            // Record button — big, reachable
            recordButton
                .padding(.bottom, 26)
        }
    }

    private var recordButton: some View {
        Button {
            if isRecording {
                camera.stopRecording()
            } else {
                tags.removeAll()
                motion.beginLogging()
                camera.startRecording()
                startMetronome()
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
        .disabled(camera.state == .configuring || camera.state == .finishing)
        .accessibilityLabel(Text(isRecording ? "Stop recording" : "Start recording"))
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(0.9), in: Capsule())
            .foregroundStyle(.black)
    }

    private var permissionDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash")
                .font(.system(size: 40))
                .foregroundStyle(Theme.inkDim)
            Text("Camera access is off")
                .font(.rpTitle)
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

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(.rpBody)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    // MARK: - Pace metronome (subtle haptic rhythm while recording)

    private func startMetronome() {
        metronome?.invalidate()
        metronome = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard isRecording else { return }
            if motion.pace > 0.7 {
                Haptics.warning()      // too fast — slow down
            } else {
                Haptics.tick()         // match this rhythm
            }
        }
    }

    // MARK: - Finalize

    private func handleFinished(_ url: URL) {
        metronome?.invalidate()
        let sidecar = motion.endLogging(besideVideoAt: url,
                                        fps: camera.activeFPS,
                                        width: camera.activeWidth,
                                        height: camera.activeHeight)
        let capturedTags = tags
        Task {
            let probe = await MediaImporter.probe(url: url)
            let asset = CaptureAsset(localURL: url,
                                     motionSidecarURL: sidecar,
                                     durationS: probe.duration,
                                     fps: probe.fps > 0 ? probe.fps : camera.activeFPS,
                                     width: probe.width > 0 ? probe.width : camera.activeWidth,
                                     height: probe.height > 0 ? probe.height : camera.activeHeight,
                                     bytes: FileStore.fileSize(url),
                                     isDrone: false,
                                     roomTags: capturedTags)
            await MainActor.run {
                onComplete(asset)
                dismiss()
            }
        }
    }
}
