import AVFoundation
import UIKit

/// AVCaptureSession wrapper: best-format selection (4K/60 → 4K/30 → 1080p/60),
/// the best hardware stabilization the chosen format supports, luminance
/// sampling for the light meter, interruption + thermal handling. Never loses
/// footage — a partial recording finalizes as a usable file.
///
/// VIDEO ONLY: the flythrough is muted everywhere (player + hosted page) and the
/// render engine builds a video-only composition, so no microphone input is
/// added. That means no mic permission prompt, no pausing the user's music, and
/// a phone call no longer ends the take (audit F-D-06).
final class CameraManager: NSObject, ObservableObject {
    enum CaptureState: Equatable {
        case idle, configuring, ready, recording
        /// The movie file is being written out after Stop — the button stays
        /// disabled until the delegate hands the file back (audit F-D-21).
        case finalizing
        case denied
        /// Camera blocked by Screen Time / a device profile — Settings can't
        /// help, so the UI shows different copy than `.denied` (audit F-D-22).
        case restricted
        case failed(String)
    }

    /// Takes stop themselves here — the render engine refuses longer sources
    /// (RenderEngine.maxSourceSeconds) and the UI says so up front.
    static let maxRecordingSeconds: Double = 600

    @Published var state: CaptureState = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var luminance: Double = 0.5          // 0–1, ~2Hz
    @Published var thermalMessage: String? = nil
    @Published var interruptionMessage: String? = nil
    /// Pre-flight storage problem (with real numbers) — shown as a banner so the
    /// camera stays open while the user frees space.
    @Published var storageMessage: String? = nil
    @Published var formatLabel: String = ""
    /// "Stabilization: Enhanced / Standard / Off" — the mode the ACTIVE format
    /// really supports, never a silent fallback to off (audit F-D-04).
    @Published var stabilizationLabel: String = ""
    @Published var isUltraWide = true               // 0.5× default — the real-estate look
    @Published private(set) var supportsUltraWide = false

    let session = AVCaptureSession()

    /// Called on main when a recording file is finalized (even a partial one).
    var onFinish: ((URL) -> Void)?
    /// Called on main the moment the first frame is written — the motion
    /// sidecar clock starts here so gyro samples line up with frame 0.
    var onRecordingStarted: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.rendprop.capture.session")
    private let lumaQueue = DispatchQueue(label: "com.rendprop.capture.luma")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var recordTimer: Timer?
    private var frameCounter = 0
    private var usesHEVC = false

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
        case .restricted:
            state = .restricted
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
        recordTimer?.invalidate()
        recordTimer = nil
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

        // No audio input on purpose — see the type comment.

        _ = selectBestFormat(for: device)

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        movieOutput.maxRecordedDuration = CMTime(seconds: Self.maxRecordingSeconds, preferredTimescale: 600)

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: lumaQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            // The light meter reads the Y plane as 8-bit. HDR formats deliver
            // 10-bit (x420) buffers, so ask the data output for an 8-bit 4:2:0
            // conversion; the sampler double-checks the pixel format (F-D-23).
            let wanted = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            if videoDataOutput.availableVideoPixelFormatTypes.contains(wanted) {
                videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: wanted]
            }
        }

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // HEVC halves file size vs H.264 with no visible quality loss.
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc],
                                              for: connection)
                usesHEVC = true
            }
        }

        session.commitConfiguration()
        applyStabilization()
        applyLens()
        session.startRunning()
        publishActiveStabilization()
        DispatchQueue.main.async { self.state = .ready }
    }

    /// Default: 4K/30 HEVC (half the file size; the pipeline interpolates to
    /// 60fps anyway, so the final tour looks identical). "Max quality" setting
    /// prefers 4K/60. Under thermal pressure, prefer lower tiers. Among formats
    /// with the same size/fps, prefer one that supports the best hardware
    /// stabilization. Returns the label of the chosen format. Session queue.
    @discardableResult
    private func selectBestFormat(for device: AVCaptureDevice) -> String {
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
            let matching = device.formats.filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width == candidate.w && dims.height == candidate.h else { return false }
                return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= candidate.fps }
            }
            // Same size + fps can exist as several pixel formats; the one that
            // supports cinematicExtended stabilization wins (audit F-D-04).
            guard let format = matching.first(where: { $0.isVideoStabilizationModeSupported(.cinematicExtended) })
                ?? matching.first(where: { $0.isVideoStabilizationModeSupported(.cinematic) })
                ?? matching.first else { continue }

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
                return candidate.label
            } catch {
                continue
            }
        }
        // Fall through: keep the device's default format.
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        activeWidth = Int(dims.width)
        activeHeight = Int(dims.height)
        DispatchQueue.main.async { self.formatLabel = "Auto" }
        return "Auto"
    }

    // MARK: - Hardware stabilization ladder

    /// Pick the best stabilization the ACTIVE format supports. `preferred…` is
    /// silently ignored by AVFoundation when the format can't do it (that is how
    /// 4K·60 used to end up with stabilization OFF while the code asked for
    /// cinematicExtended). Session queue; call after every format change.
    private func applyStabilization() {
        guard let device, let connection = movieOutput.connection(with: .video) else {
            DispatchQueue.main.async { self.stabilizationLabel = "" }
            return
        }
        guard connection.isVideoStabilizationSupported else {
            DispatchQueue.main.async { self.stabilizationLabel = Self.label(for: .off) }
            return
        }
        let ladder: [AVCaptureVideoStabilizationMode] = [.cinematicExtended, .cinematic, .standard, .auto]
        let format = device.activeFormat
        let chosen = ladder.first { format.isVideoStabilizationModeSupported($0) } ?? .off
        connection.preferredVideoStabilizationMode = chosen
        let label = Self.label(for: chosen)
        DispatchQueue.main.async { self.stabilizationLabel = label }
    }

    /// Once the session runs, the connection reports what it is really doing.
    private func publishActiveStabilization() {
        guard let connection = movieOutput.connection(with: .video),
              connection.isVideoStabilizationSupported else { return }
        let active = connection.activeVideoStabilizationMode
        // `.auto` as the active mode means the system picked one for us; keep
        // the ladder's label in that case rather than printing "Auto".
        guard active != .auto else { return }
        let label = Self.label(for: active)
        DispatchQueue.main.async { self.stabilizationLabel = label }
    }

    private static func label(for mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .cinematicExtended: return "Stabilization: Enhanced"
        case .cinematic:         return "Stabilization: Cinematic"
        case .standard:          return "Stabilization: Standard"
        case .auto:              return "Stabilization: Auto"
        case .off:               return "Stabilization: Off"
        default:                 return "Stabilization: On"   // newer modes (previewOptimized, enhanced…)
        }
    }

    // MARK: - Lens (0.5× ultra-wide ↔ 1× wide)

    /// On the dual-wide virtual camera, zoom 1.0 = ultra-wide (0.5×) and the
    /// switch-over factor (usually 2.0) = the standard wide lens (1×).
    /// Haptic lives here (only here) so the toggle never buzzes twice.
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

    // MARK: - Storage pre-flight

    /// Apple's published capture rates (Settings → Camera → Record Video), HEVC:
    /// 4K·60 ≈ 400 MB/min, 4K·30 ≈ 170, 1080p·60 ≈ 90, 1080p·30 ≈ 60. H.264 is
    /// roughly 1.7× that. Computed from the ACTIVE format, not a flat 400 MB/min
    /// (audit F-D-27).
    var estimatedBytesPerMinute: Int64 {
        let pixels = Double(activeWidth * activeHeight)
        let is4K = pixels >= 3840 * 2160 * 0.9
        let highFPS = activeFPS >= 50
        let base: Double
        if is4K { base = highFPS ? 400_000_000 : 170_000_000 }
        else    { base = highFPS ?  90_000_000 :  60_000_000 }
        return Int64(base * (usesHEVC ? 1.0 : 1.7))
    }

    /// Room for a full-length take at the current format plus headroom for the
    /// rendered tour and the scrub master.
    private var requiredFreeBytes: Int64 {
        estimatedBytesPerMinute * Int64(Self.maxRecordingSeconds / 60) + 500_000_000
    }

    // MARK: - Recording

    /// Seconds of the take written so far — read the movie output's own clock
    /// (not the 250 ms UI timer) so room tags land where the tap happened.
    var currentRecordedSeconds: TimeInterval {
        guard state == .recording || state == .finalizing else { return 0 }
        let t = movieOutput.recordedDuration
        return (t.isValid && t.seconds.isFinite && t.seconds >= 0) ? t.seconds : elapsed
    }

    func startRecording() {
        guard state == .ready else { return }
        let free = FileStore.freeSpaceBytes()
        let needed = requiredFreeBytes
        guard free > needed else {
            let minutes = Int(Self.maxRecordingSeconds / 60)
            storageMessage = "Not enough storage: a \(minutes)-minute take at \(formatLabel.isEmpty ? "this quality" : formatLabel) needs about \(Formatters.bytes(needed)) free, and only \(Formatters.bytes(free)) is left."
            Haptics.warning()
            return
        }
        storageMessage = nil
        MediaImporter.excludeFromBackup(FileStore.recordingsDir)
        let url = FileStore.newRecordingURL()
        state = .recording
        elapsed = 0
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, case .recording = self.state else { return }
            let t = self.movieOutput.recordedDuration
            self.elapsed = (t.isValid && t.seconds.isFinite) ? t.seconds : self.elapsed + 0.25
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .finalizing
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
        let reasonRaw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = reasonRaw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        DispatchQueue.main.async {
            let base: String
            switch reason {
            case .videoDeviceInUseByAnotherClient:
                base = "Another app is using the camera"
            case .videoDeviceNotAvailableInBackground:
                base = "Camera paused while Rendprop is in the background"
            case .videoDeviceNotAvailableWithMultipleForegroundApps:
                base = "Camera unavailable while another app is on screen"
            case .videoDeviceNotAvailableDueToSystemPressure:
                base = "Camera paused — the phone is too hot"
            default:
                base = "Camera paused"
            }
            // While recording, iOS stops the movie output and finalizes the
            // partial file (the delegate hands it back) — say so, honestly.
            let wasRecording = self.state == .recording || self.state == .finalizing
            self.interruptionMessage = wasRecording ? "\(base) — the take so far is being saved" : base
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
            self.session.startRunning()   // attempt recovery (e.g. media services reset)
        }
    }

    // MARK: - Thermal

    private func observeThermal() {
        NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil)
    }

    /// Copy tells the truth about what happens: mid-take nothing changes (a
    /// format switch would end the recording); between takes only the 4K·60
    /// "max quality" tier has a cooler format to fall to (audit F-D-20).
    @objc private func thermalChanged() {
        let thermalState = ProcessInfo.processInfo.thermalState
        DispatchQueue.main.async {
            switch thermalState {
            case .serious, .critical:
                Haptics.warning()
                if self.state == .recording || self.state == .finalizing {
                    self.thermalMessage = "Phone is getting hot — wrap up this take soon"
                } else if self.state == .ready, let device = self.device,
                          UserDefaults.standard.bool(forKey: "maxQualityCapture") {
                    self.thermalMessage = "Phone is hot — switching to a cooler capture format"
                    self.reselectFormat(for: device) { label in
                        self.thermalMessage = "Phone is hot — capturing at \(label) until it cools"
                    }
                } else {
                    self.thermalMessage = "Phone is hot — let it cool for the best quality"
                }
            default:
                self.thermalMessage = nil
                // Cooled down between takes: go back up to the preferred tier.
                if self.state == .ready, let device = self.device,
                   UserDefaults.standard.bool(forKey: "maxQualityCapture") {
                    self.reselectFormat(for: device) { _ in }
                }
            }
        }
    }

    /// Re-run the format ladder (between takes only) and re-apply the
    /// stabilization ladder + lens for the new format. `done` runs on main.
    private func reselectFormat(for device: AVCaptureDevice, done: @escaping (String) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            let label = self.selectBestFormat(for: device)
            self.applyStabilization()
            self.session.commitConfiguration()
            self.applyLens()   // format changes can reset zoom
            self.publishActiveStabilization()
            DispatchQueue.main.async { done(label) }
        }
    }
}

// MARK: - Movie file delegate
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.onRecordingStarted?() }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // Even on error (interruption, the 10-minute cap), iOS finalizes a
        // playable partial file. Never discard footage here (master spec 4.2) —
        // the capture screen lets the user keep or retake it.
        let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
        DispatchQueue.main.async {
            self.recordTimer?.invalidate()
            self.recordTimer = nil
            self.state = .ready
            if fileExists {
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

        // Only the 8-bit bi-planar formats have a one-byte-per-pixel Y plane;
        // a 10-bit (x420) buffer would be read as garbage. Bail instead.
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Y-plane of 420 biplanar formats = luma. Sample a sparse grid.
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, stride >= width else { return }
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

// MARK: - Idle timer holds
/// Reference-counted `isIdleTimerDisabled`, so capture and a render can each
/// keep the screen awake without one releasing the other's hold (audit F-D-05).
@MainActor
enum IdleTimer {
    private static var holds = 0

    static func hold() {
        holds += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        holds = max(0, holds - 1)
        if holds == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
