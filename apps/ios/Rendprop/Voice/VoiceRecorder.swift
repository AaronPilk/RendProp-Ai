import AVFoundation
import Foundation
import Speech

/// Tap-and-hold voice capture for a reel voiceover.
///
/// Records AAC/m4a (44.1 kHz **mono**, 64 kbps — speech, not music: about
/// 0.5 MB a minute) into the temp directory and publishes what a record UI
/// needs: `isRecording`, a 0…1 `level` for a meter, and `elapsed`.
///
/// Audio-session policy, which reviewers do notice:
///   • `.playAndRecord` + `.defaultToSpeaker` + `.allowBluetooth` so the agent
///     can record and then hear the playback out of the loud speaker.
///   • The session is **deactivated** (`.notifyOthersOnDeactivation`) the moment
///     recording ends, is cancelled, is interrupted, or this object dies — an
///     app that leaves a `.playAndRecord` session active permanently ducks or
///     kills the user's music. iOS re-activates it implicitly for playback, so
///     playing the file back afterwards still works.
///
/// Interruptions (a phone call, Siri, another app taking the mic, the headset
/// being unplugged, a media-services reset) finalise the partial file and drop
/// `isRecording` to false — it can never latch true.
@MainActor
final class VoiceRecorder: ObservableObject {

    // MARK: Published state (contract)

    @Published private(set) var isRecording: Bool = false
    /// 0…1, smoothed, meant to drive a meter. NOT raw dB — `averagePower` is
    /// −160…0 dB and a linear map of that reads dead for normal speech.
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: Double = 0

    /// Additive (not in the contract): true when the last take was cut short by
    /// the system — a call, Siri, a route change. The partial recording is kept,
    /// so `stop()` still returns it.
    @Published private(set) var wasInterrupted: Bool = false

    // MARK: Errors

    enum RecorderError: LocalizedError {
        case alreadyRecording
        case notRecording
        case microphoneDenied
        case noInput
        case sessionFailed(String)
        case startFailed
        case tooShort
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already running."
            case .notRecording:
                return "There's no recording to stop."
            case .microphoneDenied:
                return "Rendprop needs microphone access to record a voiceover. Turn it on in Settings → Rendprop → Microphone."
            case .noInput:
                return "No microphone is available right now. Disconnect any headset or accessory and try again."
            case .sessionFailed(let why):
                return "Couldn't get the audio system ready — \(why)"
            case .startFailed:
                return "Couldn't start recording. Close anything else using the microphone and try again."
            case .tooShort:
                return "That recording was too short to use — hold the button and speak for a second or two."
            case .encodingFailed(let why):
                return "The recording couldn't be saved — \(why)"
            }
        }
    }

    // MARK: Private state

    private var recorder: AVAudioRecorder?
    /// `AVAudioRecorder.delegate` is a WEAK reference. The delegate must be held
    /// here or it deallocates mid-record and the finish/encode-error callbacks
    /// silently never arrive.
    private var delegateShim: RecorderDelegate?
    private var currentURL: URL?
    private var meterTask: Task<Void, Never>?
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var encodeError: RecorderError?
    private var isStopping = false
    /// Holds the two things that MUST be undone even if this object is
    /// deallocated mid-record — the notification observers and an active audio
    /// session. It is a plain (non-isolated) class, so its own `deinit` does the
    /// cleanup wherever the last reference happens to be released, and
    /// `VoiceRecorder` needs no `deinit` of its own.
    private let keeper = AudioSessionKeeper()

    /// Meter/elapsed refresh. 20 Hz is smooth to the eye and cheap.
    private static let tickNanos: UInt64 = 50_000_000
    /// How long `stop()` waits for the encoder's finish callback before it goes
    /// ahead and inspects the file anyway. `AVAudioRecorder.stop()` finalises
    /// synchronously in practice; this only stops a missing callback hanging the
    /// UI forever.
    private static let finishTimeoutNanos: UInt64 = 2_000_000_000

    // MARK: Permissions

    /// Asks for BOTH microphone and speech recognition. False if either is
    /// denied, restricted (Screen Time can restrict speech recognition outright)
    /// or otherwise unavailable. Never traps, whatever the user answers.
    func requestPermissions() async -> Bool {
        let mic = await Self.requestMicrophoneAccess()
        let speech = await Self.requestSpeechAccess()
        return mic && speech
    }

    /// True when the mic alone is granted — recording works without speech
    /// recognition, it just means no caption timings.
    var hasMicrophonePermission: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    // `recordPermission` / `requestRecordPermission` are deprecated in iOS 17 in
    // favour of `AVAudioApplication`, which does not exist below iOS 17. The
    // deployment target is iOS 16, so the deprecated pair is the one call that
    // compiles and works on every supported OS. Deprecation warning: accepted,
    // deliberate.
    private static func requestMicrophoneAccess() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                session.requestRecordPermission { granted in cont.resume(returning: granted) }
            }
        @unknown default:
            return false
        }
    }

    private static func requestSpeechAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: Record

    /// Configure the session and start recording into a fresh temp file.
    /// Throws (never traps) when permission is denied, no input route exists, or
    /// the encoder refuses to start.
    func start() throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        guard hasMicrophonePermission else { throw RecorderError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            keeper.setActive(true)
        } catch {
            deactivateSession()
            throw RecorderError.sessionFailed(error.localizedDescription)
        }
        // A device with no usable input (all routes gone) must fail cleanly.
        guard session.isInputAvailable else {
            deactivateSession()
            throw RecorderError.noInput
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceover-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let shim = RecorderDelegate(
            onFinish: { [weak self] ok in
                Task { @MainActor in self?.handleFinish(success: ok) }
            },
            onEncodeError: { [weak self] message in
                Task { @MainActor in self?.handleEncodeError(message) }
            })

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = shim
            rec.isMeteringEnabled = true
            guard rec.prepareToRecord(), rec.record() else {
                deactivateSession()
                throw RecorderError.startFailed
            }
            recorder = rec
        } catch let error as RecorderError {
            deactivateSession()
            throw error
        } catch {
            deactivateSession()
            throw RecorderError.startFailed
        }

        delegateShim = shim
        currentURL = url
        encodeError = nil
        wasInterrupted = false
        elapsed = 0
        level = 0
        isRecording = true
        installObservers()
        startMeterLoop()
    }

    /// Finish the take and hand back the m4a in the temp directory.
    /// Also returns the (finalised) partial file when an interruption already
    /// ended the recording — a cut-off take is still the agent's take.
    func stop() async throws -> URL {
        guard let url = currentURL, !isStopping else { throw RecorderError.notRecording }
        isStopping = true
        defer { isStopping = false }

        meterTask?.cancel()
        meterTask = nil

        if let recorder, recorder.isRecording {
            elapsed = recorder.currentTime
            recorder.stop()                     // finalises the file, fires the delegate
            _ = await waitForFinish()
        }
        isRecording = false
        level = 0

        let failure = encodeError
        teardown()

        if let failure {
            removeFile(url)
            currentURL = nil
            throw failure
        }
        // An empty/near-empty file means the encoder produced nothing usable —
        // a bare AAC header is a few hundred bytes.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard FileManager.default.fileExists(atPath: url.path), size > 2_048 else {
            removeFile(url)
            currentURL = nil
            throw RecorderError.tooShort
        }
        currentURL = nil
        return url
    }

    /// Throw the take away: stop, delete the file, release the session.
    /// Safe to call at any time, including when nothing is recording.
    func cancel() {
        meterTask?.cancel()
        meterTask = nil
        if let recorder {
            if recorder.isRecording { recorder.stop() }
            recorder.deleteRecording()          // only legal once stopped
        }
        resumeFinish(false)                     // never strand an in-flight stop()
        let url = currentURL
        teardown()
        if let url { removeFile(url) }
        currentURL = nil
        encodeError = nil
        isRecording = false
        level = 0
        elapsed = 0
    }

    // MARK: Meter

    private func startMeterLoop() {
        meterTask?.cancel()
        // Created inside a @MainActor method, so the body runs on the main actor.
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: VoiceRecorder.tickNanos)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let target = Self.normalizedLevel(recorder.averagePower(forChannel: 0))
        level = Self.smoothed(previous: level, target: target)
        elapsed = recorder.currentTime
    }

    /// dB (−160…0) → 0…1 that actually moves while someone talks.
    /// −50 dB is treated as silence; the dB value becomes linear amplitude,
    /// is renormalised so the floor is a true 0, then gamma-curved so quiet
    /// speech is visible instead of hugging the bottom of the meter.
    static func normalizedLevel(_ decibels: Float) -> Float {
        let floorDb: Float = -50
        guard decibels.isFinite else { return 0 }
        if decibels <= floorDb { return 0 }
        let amplitude = powf(10, min(decibels, 0) / 20)
        let floorAmplitude = powf(10, floorDb / 20)
        let normalized = (amplitude - floorAmplitude) / (1 - floorAmplitude)
        return min(1, max(0, powf(normalized, 0.6)))
    }

    /// Fast attack, slow release — a meter that snaps up and eases down.
    static func smoothed(previous: Float, target: Float) -> Float {
        let factor: Float = target > previous ? 0.5 : 0.15
        return previous + (target - previous) * factor
    }

    // MARK: Delegate plumbing

    private func handleFinish(success: Bool) {
        if !success, encodeError == nil {
            encodeError = .encodingFailed("the recording didn't finish cleanly. Try again.")
        }
        resumeFinish(success)
    }

    private func handleEncodeError(_ message: String) {
        encodeError = .encodingFailed(message)
        isRecording = false
        meterTask?.cancel()
        meterTask = nil
        resumeFinish(false)
    }

    private func waitForFinish() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            finishContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: VoiceRecorder.finishTimeoutNanos)
                self?.resumeFinish(false)       // no-op if the delegate already answered
            }
        }
    }

    /// Resume exactly once. Both callers are main-actor, so this is race-free.
    private func resumeFinish(_ success: Bool) {
        guard let cont = finishContinuation else { return }
        finishContinuation = nil
        cont.resume(returning: success)
    }

    // MARK: Interruptions

    private func installObservers() {
        guard !keeper.hasObservers else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        keeper.add(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main) { [weak self] note in
                // Pull the primitive out here; only it crosses to the actor.
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.endTakeFromSystem() }
            })

        keeper.add(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                // The mic we were recording with disappeared (headset unplugged,
                // Bluetooth walked away). Anything else is fine to keep going on.
                guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                Task { @MainActor in self?.endTakeFromSystem() }
            })

        keeper.add(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleMediaServicesReset() }
            })
    }

    /// A call/Siri/route loss ended the take. Finalise what we have, stop
    /// publishing "recording", and hand the session back so music can resume.
    private func endTakeFromSystem() {
        guard isRecording || recorder?.isRecording == true else { return }
        wasInterrupted = true
        meterTask?.cancel()
        meterTask = nil
        if let recorder, recorder.isRecording {
            elapsed = recorder.currentTime
            recorder.stop()
        }
        isRecording = false
        level = 0
        deactivateSession()
        // `recorder` and `currentURL` stay put: stop() can still return the
        // partial take.
    }

    /// The audio server restarted — every AVAudioRecorder is dead. Keep the
    /// bytes already on disk, drop the objects, and let stop() validate the file.
    private func handleMediaServicesReset() {
        wasInterrupted = true
        meterTask?.cancel()
        meterTask = nil
        recorder = nil
        delegateShim = nil
        keeper.setActive(false)
        isRecording = false
        level = 0
        resumeFinish(false)
    }

    // MARK: Teardown

    private func teardown() {
        recorder = nil
        delegateShim = nil
        deactivateSession()
    }

    private func deactivateSession() {
        keeper.deactivate()
    }

    private func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Delegate shim

/// A tiny NSObject that owns the AVAudioRecorder callbacks so `VoiceRecorder`
/// does not have to be an NSObject, and so nothing main-actor-isolated is
/// touched on the audio thread. Held strongly by VoiceRecorder (the recorder's
/// own `delegate` is weak); the callbacks capture `self` weakly, so there is no
/// retain cycle in either direction.
private final class RecorderDelegate: NSObject, AVAudioRecorderDelegate {
    private let onFinish: @Sendable (Bool) -> Void
    private let onEncodeError: @Sendable (String) -> Void

    init(onFinish: @escaping @Sendable (Bool) -> Void,
         onEncodeError: @escaping @Sendable (String) -> Void) {
        self.onFinish = onFinish
        self.onEncodeError = onEncodeError
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        onFinish(flag)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        onEncodeError(error?.localizedDescription ?? "the audio encoder failed.")
    }
}

// MARK: - Audio session keeper

/// Deliberately NOT main-actor isolated: its `deinit` has to be able to run on
/// whichever thread drops the last reference, and it must never touch isolated
/// state. Removing the observers and releasing the audio session here means a
/// `VoiceRecorder` that is torn down mid-record (view dismissed, app state
/// churn) still hands the user's music back.
private final class AudioSessionKeeper {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var active = false

    var hasObservers: Bool {
        lock.lock(); defer { lock.unlock() }
        return !tokens.isEmpty
    }

    func add(_ token: NSObjectProtocol) {
        lock.lock(); defer { lock.unlock() }
        tokens.append(token)
    }

    func setActive(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        active = value
    }

    /// Idempotent: the second call is a no-op, so stop() → teardown() →
    /// an interruption that already deactivated cannot fight over the session.
    func deactivate() {
        lock.lock()
        let wasActive = active
        active = false
        lock.unlock()
        guard wasActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    deinit {
        // Sole owner at this point — no lock needed, and none may be taken:
        // deinit can run on any thread.
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        guard active else { return }
        let session = AVAudioSession.sharedInstance()
        DispatchQueue.global(qos: .utility).async {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
