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
        /// Mid-take, nothing being written, everything recorded so far kept.
        ///
        /// WHY THIS EXISTS: a working agent filming a walkthrough had her client
        /// walk into frame and had no way to hold the take — her only options
        /// were to keep filming the client or start the whole house again. Her
        /// words: "a good feature would be to be able to pause the video and
        /// then restart it in case you have run into a person."
        ///
        /// `AVCaptureMovieFileOutput` has no pause on iOS, so a pause ENDS the
        /// current file and a resume starts another; the pieces are joined back
        /// into one take when the recording stops. Room tags and the motion
        /// sidecar are kept on the JOINED clock, not on wall time.
        case paused
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

    /// Called on main when a take is finalized (even a partial one), with its
    /// pieces IN ORDER. A take with no pauses has exactly one; joining them is
    /// the caller's job, because "what counts as a take" is a capture-screen
    /// question and this class only knows about files.
    var onFinish: (([URL]) -> Void)?
    /// Called on main the moment the FIRST frame of a take is written — the
    /// motion sidecar clock starts here so gyro samples line up with frame 0.
    /// Does not fire again when a paused take resumes.
    var onRecordingStarted: (() -> Void)?
    /// Called on main when a paused take starts writing again.
    var onRecordingResumed: (() -> Void)?
    /// Called on main when a take was thrown away — no file is handed back.
    var onDiscarded: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.rendprop.capture.session")
    private let lumaQueue = DispatchQueue(label: "com.rendprop.capture.luma")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var recordTimer: Timer?
    private var frameCounter = 0
    private var usesHEVC = false

    /// What the delegate should do with the file it is about to hand back.
    private enum SegmentEnd { case pause, finish, discard }
    private var pendingEnd: SegmentEnd = .finish
    /// The pieces of the take in progress, oldest first.
    private var segments: [URL] = []
    /// Seconds already banked in completed pieces — the take's clock is this
    /// plus whatever the movie output has written since the last resume.
    private var bankedSeconds: TimeInterval = 0
    /// False until the first frame of THIS take is written, so a resume does
    /// not restart the motion sidecar at zero.
    private var takeStarted = false

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
        // Paused counts: a room tag tapped while held still belongs at the
        // point the take had reached.
        guard state == .recording || state == .paused || state == .finalizing else { return 0 }
        guard state == .recording else { return bankedSeconds }
        let t = movieOutput.recordedDuration
        guard t.isValid, t.seconds.isFinite, t.seconds >= 0 else { return elapsed }
        return bankedSeconds + t.seconds
    }

    /// True while a take is in progress, recording or held.
    var hasTakeInProgress: Bool { state == .recording || state == .paused }

    /// Seconds of headroom left in this take, across all its pieces.
    private var remainingSeconds: TimeInterval {
        max(1, Self.maxRecordingSeconds - bankedSeconds)
    }

    func startRecording() {
        guard state == .ready else { return }
        // A session interrupted by a call / Control Center / another foreground
        // app is still `.ready` here. Asking the movie output to record on it
        // fails in the delegate with no file, which used to flip the whole
        // screen to `.failed` — a dead end with only "Close". The interruption
        // banner already explains the wait; just don't start (audit F-D-20).
        guard session.isRunning else { return }
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
        // Fresh take: nothing banked, nothing started, no leftovers.
        segments.removeAll()
        bankedSeconds = 0
        takeStarted = false
        elapsed = 0
        beginSegment()
    }

    /// Hold the take. The current file is closed (iOS has no real pause on
    /// `AVCaptureMovieFileOutput`) but nothing is thrown away and nothing is
    /// joined yet — `resumeRecording()` simply opens the next piece.
    func pauseRecording() {
        guard state == .recording else { return }
        pendingEnd = .pause
        state = .finalizing
        sessionQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }

    /// Carry on into the same take.
    func resumeRecording() {
        guard state == .paused else { return }
        guard session.isRunning else { return }
        // Storage is re-checked here for the same reason it is checked at the
        // start: a long hold is exactly when a phone fills up.
        let free = FileStore.freeSpaceBytes()
        guard free > 300_000_000 else {
            storageMessage = "Not enough storage left to keep recording — only \(Formatters.bytes(free)) free. Stop here to keep what you have."
            Haptics.warning()
            return
        }
        storageMessage = nil
        beginSegment()
    }

    /// Open the next piece of the current take.
    private func beginSegment() {
        guard session.isRunning else { return }
        let url = FileStore.newRecordingURL()
        pendingEnd = .finish
        state = .recording
        let banked = bankedSeconds
        // The 10-minute ceiling is on the TAKE, not on each piece — a paused
        // take must not get a fresh ten minutes every time it resumes.
        let cap = remainingSeconds
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, case .recording = self.state else { return }
            let t = self.movieOutput.recordedDuration
            self.elapsed = (t.isValid && t.seconds.isFinite) ? banked + t.seconds : self.elapsed + 0.25
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieOutput.maxRecordedDuration = CMTime(seconds: cap, preferredTimescale: 600)
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        // Stopping while held: there is no file in flight, so finish with the
        // pieces already banked instead of waiting for a delegate callback that
        // will never come.
        if state == .paused {
            recordTimer?.invalidate(); recordTimer = nil
            deliverTake()
            return
        }
        guard state == .recording else { return }
        pendingEnd = .finish
        state = .finalizing
        sessionQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }

    /// Throw the whole take away — every piece of it — and go back to ready.
    func cancelTake() {
        if state == .paused {
            recordTimer?.invalidate(); recordTimer = nil
            discardTake()
            state = .ready
            onDiscarded?()
            return
        }
        guard state == .recording else { return }
        pendingEnd = .discard
        state = .finalizing
        sessionQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }

    /// Hand the finished take back, then reset.
    private func deliverTake() {
        let pieces = segments
        segments.removeAll()
        bankedSeconds = 0
        takeStarted = false
        state = .ready
        if pieces.isEmpty {
            onDiscarded?()
        } else {
            onFinish?(pieces)
        }
    }

    /// Delete every piece of the take in progress.
    private func discardTake() {
        for url in segments {
            try? FileManager.default.removeItem(at: url)
            MotionRecorder.deleteSidecar(for: url)
        }
        segments.removeAll()
        bankedSeconds = 0
        takeStarted = false
        elapsed = 0
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
        DispatchQueue.main.async {
            // The sidecar clock starts at the first frame of the TAKE. A resume
            // continues that clock (`resumeLogging`), it does not restart it —
            // restarting would put every later sample at the wrong frame.
            if self.takeStarted {
                self.onRecordingResumed?()
            } else {
                self.takeStarted = true
                self.onRecordingStarted?()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // Even on error (interruption, the 10-minute cap), iOS finalizes a
        // playable partial file. Never discard footage here (master spec 4.2) —
        // the capture screen lets the user keep or retake it.
        let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
        let written = fileExists ? Self.durationSeconds(of: outputFileURL) : 0
        DispatchQueue.main.async {
            self.recordTimer?.invalidate()
            self.recordTimer = nil
            // A piece with no frames in it is not footage — it is what a pause
            // tapped a fraction of a second after resume produces. Banking it
            // would put a zero-length segment in the join.
            if fileExists && written > 0.05 {
                self.segments.append(outputFileURL)
                self.bankedSeconds += written
                self.elapsed = self.bankedSeconds
            } else if fileExists {
                try? FileManager.default.removeItem(at: outputFileURL)
            }
            switch self.pendingEnd {
            case .pause:
                self.pendingEnd = .finish
                self.state = .paused
            case .discard:
                self.pendingEnd = .finish
                self.discardTake()
                self.state = .ready
                self.onDiscarded?()
            case .finish:
                if self.segments.isEmpty, let error {
                    self.state = .failed(error.localizedDescription)
                    self.takeStarted = false
                    return
                }
                self.deliverTake()
            }
        }
    }

    /// The real written length of a finished piece. `movieOutput.recordedDuration`
    /// has already been reset by the time this runs, so it is read off the file.
    private static func durationSeconds(of url: URL) -> TimeInterval {
        let t = AVURLAsset(url: url).duration
        guard t.isValid, t.seconds.isFinite, t.seconds > 0 else { return 0 }
        return t.seconds
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
