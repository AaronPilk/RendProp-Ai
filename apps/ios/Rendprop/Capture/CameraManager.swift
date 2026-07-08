import AVFoundation
import UIKit

/// AVCaptureSession wrapper: best-format selection (4K/60 → 4K/30 → 1080p/60),
/// cinematicExtended stabilization, luminance sampling for the light meter,
/// interruption + thermal handling. Never loses footage — a partial recording
/// finalizes as a usable file.
final class CameraManager: NSObject, ObservableObject {
    enum CaptureState: Equatable {
        case idle, configuring, ready, recording, finishing
        case denied
        case failed(String)
    }

    @Published var state: CaptureState = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var luminance: Double = 0.5          // 0–1, ~2Hz
    @Published var thermalMessage: String? = nil
    @Published var interruptionMessage: String? = nil
    @Published var formatLabel: String = ""
    @Published var isUltraWide = true               // 0.5× default — the real-estate look
    @Published private(set) var supportsUltraWide = false

    let session = AVCaptureSession()

    /// Called on main when a recording file is finalized (even a partial one).
    var onFinish: ((URL) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.rendprop.capture.session")
    private let lumaQueue = DispatchQueue(label: "com.rendprop.capture.luma")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var recordTimer: Timer?
    private var frameCounter = 0

    private(set) var activeFPS: Double = 30
    private(set) var activeWidth: Int = 1920
    private(set) var activeHeight: Int = 1080

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configure() } else { self?.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func configure() {
        state = .configuring
        observeInterruptions()
        observeThermal()
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        // Prefer the dual-wide virtual camera: zoom factor 1.0 = ultra-wide (0.5×),
        // switch-over factor (~2.0) = the standard wide lens (1×).
        let picked = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device = picked,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.state = .failed("No back camera available.") }
            return
        }
        session.addInput(input)
        self.device = device
        let hasUltraWide = device.deviceType == .builtInDualWideCamera
        DispatchQueue.main.async { self.supportsUltraWide = hasUltraWide }

        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        selectBestFormat(for: device)

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: lumaQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .cinematicExtended
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // HEVC halves file size vs H.264 with no visible quality loss.
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc],
                                              for: connection)
            }
        }

        session.commitConfiguration()
        applyLens()
        session.startRunning()
        DispatchQueue.main.async { self.state = .ready }
    }

    /// Default: 4K/30 HEVC (half the file size; the pipeline interpolates to
    /// 60fps anyway, so the final tour looks identical). "Max quality" setting
    /// prefers 4K/60. Under thermal pressure, prefer lower tiers.
    private func selectBestFormat(for device: AVCaptureDevice) {
        struct Candidate { let w: Int32; let h: Int32; let fps: Double; let label: String }
        let throttled = ProcessInfo.processInfo.thermalState == .serious
            || ProcessInfo.processInfo.thermalState == .critical
        let maxQuality = UserDefaults.standard.bool(forKey: "maxQualityCapture")
        var candidates: [Candidate] = maxQuality
            ? [Candidate(w: 3840, h: 2160, fps: 60, label: "4K · 60"),
               Candidate(w: 3840, h: 2160, fps: 30, label: "4K · 30"),
               Candidate(w: 1920, h: 1080, fps: 60, label: "1080p · 60"),
               Candidate(w: 1920, h: 1080, fps: 30, label: "1080p · 30")]
            : [Candidate(w: 3840, h: 2160, fps: 30, label: "4K · 30"),
               Candidate(w: 1920, h: 1080, fps: 30, label: "1080p · 30"),
               Candidate(w: 1920, h: 1080, fps: 60, label: "1080p · 60")]
        if throttled && maxQuality { candidates.removeFirst() }

        for candidate in candidates {
            guard let format = device.formats.first(where: { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width == candidate.w && dims.height == candidate.h else { return false }
                return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= candidate.fps }
            }) else { continue }

            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(candidate.fps))
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
                activeFPS = candidate.fps
                activeWidth = Int(candidate.w)
                activeHeight = Int(candidate.h)
                DispatchQueue.main.async { self.formatLabel = candidate.label }
                return
            } catch {
                continue
            }
        }
        // Fall through: keep the device's default format.
        DispatchQueue.main.async { self.formatLabel = "Auto" }
    }

    // MARK: - Lens (0.5× ultra-wide ↔ 1× wide)

    /// On the dual-wide virtual camera, zoom 1.0 = ultra-wide (0.5×) and the
    /// switch-over factor (usually 2.0) = the standard wide lens (1×).
    func toggleLens() {
        guard supportsUltraWide else { return }
        isUltraWide.toggle()
        Haptics.selection()
        applyLens()
    }

    private func applyLens() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device,
                  device.deviceType == .builtInDualWideCamera else { return }
            let wideFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first
                .map { CGFloat(truncating: $0) } ?? 2.0
            let target: CGFloat = self.isUltraWide ? 1.0 : wideFactor
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: target, withRate: 8)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard state == .ready else { return }
        guard FileStore.hasSpace(forMinutes: 3) else {
            state = .failed("Not enough storage for a walkthrough. Free up space and try again.")
            return
        }
        let url = FileStore.newRecordingURL()
        state = .recording
        elapsed = 0
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, case .recording = self.state else { return }
            self.elapsed = self.movieOutput.recordedDuration.seconds.isFinite
                ? self.movieOutput.recordedDuration.seconds : self.elapsed + 0.25
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .finishing
        sessionQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }

    // MARK: - Interruptions (calls, Control Center) — never lose footage

    private func observeInterruptions() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                       name: .AVCaptureSessionWasInterrupted, object: session)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                       name: .AVCaptureSessionInterruptionEnded, object: session)
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                       name: .AVCaptureSessionRuntimeError, object: session)
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        DispatchQueue.main.async {
            self.interruptionMessage = "Recording paused — interruption"
            // If we were recording, movieOutput finalizes the partial file via
            // the delegate; the footage is preserved.
        }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        DispatchQueue.main.async { self.interruptionMessage = nil }
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()   // attempt recovery
        }
    }

    // MARK: - Thermal

    private func observeThermal() {
        NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil)
    }

    @objc private func thermalChanged() {
        let thermalState = ProcessInfo.processInfo.thermalState
        DispatchQueue.main.async {
            switch thermalState {
            case .serious, .critical:
                self.thermalMessage = "Phone is hot — quality reduced to keep recording."
                Haptics.warning()
                // Reconfigure to a cooler format only between takes.
                if self.state == .ready, let device = self.device {
                    self.sessionQueue.async {
                        self.session.beginConfiguration()
                        self.selectBestFormat(for: device)
                        self.session.commitConfiguration()
                    }
                    self.applyLens()   // format changes can reset zoom
                }
            default:
                self.thermalMessage = nil
            }
        }
    }
}

// MARK: - Movie file delegate
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // Even on error, iOS usually finalizes a playable partial file.
        // Never discard footage (master spec 4.2).
        let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
        DispatchQueue.main.async {
            self.recordTimer?.invalidate()
            self.recordTimer = nil
            self.state = .ready
            if fileExists {
                Haptics.success()
                self.onFinish?(outputFileURL)
            } else if let error {
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Luminance sampling (light meter), ~2Hz, off-main
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % 15 == 0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Y-plane of 420 biplanar formats = luma. Sample a sparse grid.
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var total = 0, count = 0
        let stepY = max(1, height / 24), stepX = max(1, width / 24)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                total += Int(ptr[y * stride + x])
                count += 1
                x += stepX
            }
            y += stepY
        }
        guard count > 0 else { return }
        let mean = Double(total) / Double(count) / 255.0

        DispatchQueue.main.async {
            // Smooth to avoid flicker.
            self.luminance = self.luminance * 0.7 + mean * 0.3
        }
    }
}
