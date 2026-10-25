import AVFoundation
import Foundation
import Speech

/// Turns a recorded voiceover into a transcript plus per-word timings, using
/// Apple's `Speech` framework — free, no new provider, and (on every device
/// that supports it) entirely on-device.
///
/// Word timings come from `SFTranscriptionSegment.timestamp` / `.duration` on
/// the **final** result only; partial results carry timings that move.
///
/// Never traps. Every failure is a `TranscribeError` whose `errorDescription`
/// is written to be shown to an agent, not logged.
enum SpeechTranscriber {

    // MARK: Errors

    enum TranscribeError: LocalizedError {
        case noPermission
        case restricted
        case noRecognizer(String)
        case unavailable
        case emptyAudio
        case nothingRecognized
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "Rendprop needs speech recognition access to write captions. Turn it on in Settings → Rendprop → Speech Recognition."
            case .restricted:
                return "Speech recognition is turned off for this device (Screen Time restrictions). The voiceover still records — captions just won't be written."
            case .noRecognizer(let locale):
                return "Speech recognition isn't available for \(locale) on this device. The voiceover still records without captions."
            case .unavailable:
                return "Speech recognition is unavailable right now. Try again in a moment, or keep the voiceover without captions."
            case .emptyAudio:
                return "That recording has no audio in it."
            case .nothingRecognized:
                return "Nothing recognisable was said in that recording — try again somewhere quieter."
            case .timedOut:
                return "Transcribing took too long and was stopped. The voiceover is fine; captions weren't written."
            case .failed(let why):
                return "Couldn't transcribe the voiceover — \(why)"
            }
        }

        /// Only a recogniser-side failure is worth a second attempt; a denial,
        /// a timeout or "nothing was said" would fail exactly the same way twice.
        var isRecogniserFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// Speech errors surface as `kAFAssistantErrorDomain` numbers whose
    /// `localizedDescription` reads like a crash log. Map the ones that mean
    /// something to the agent and keep the rest generic.
    private static func translate(_ error: Error) -> TranscribeError {
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case ("kAFAssistantErrorDomain", 1110),      // no speech detected
             ("kAFAssistantErrorDomain", 1700):
            return .nothingRecognized
        case ("kAFAssistantErrorDomain", 203),       // service unreachable / retry
             ("kAFAssistantErrorDomain", 1101):      // on-device asset missing
            return .failed("the speech service couldn't process that recording.")
        default:
            let message = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let opaque = message.isEmpty || message.contains("ErrorDomain")
            return .failed(opaque ? "the speech service couldn't process that recording." : message)
        }
    }

    // MARK: Availability

    /// Honest answer to "can this device transcribe right now?": speech
    /// recognition is **authorised**, a recogniser exists for the current
    /// locale, and that recogniser reports itself available. It deliberately
    /// returns false while authorisation is still `.notDetermined` — use
    /// `canAskForPermission()` to decide whether it is worth asking.
    static func isAvailable() -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = makeRecognizer() else { return false }
        return recognizer.isAvailable
    }

    /// True when the user has not been asked yet (so the feature can still be
    /// offered — `VoiceRecorder.requestPermissions()` does the asking).
    static func canAskForPermission() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    /// True when transcription will run on-device (offline, nothing leaves the
    /// phone). Fine to call for UI copy; false just means server recognition.
    static func supportsOnDevice() -> Bool {
        makeRecognizer()?.supportsOnDeviceRecognition ?? false
    }

    // MARK: Transcribe

    /// On-device where the device supports it. Returns transcript + word timings.
    /// `words` comes back empty when the recogniser gives no usable timings —
    /// captions then simply don't render, which is a normal state.
    static func transcribe(_ audioURL: URL) async throws -> (text: String, words: [CaptionWord]) {
        // 1. Is there any audio at all? (A bare AAC header is a few hundred bytes.)
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard FileManager.default.fileExists(atPath: audioURL.path), bytes > 1_024 else {
            throw TranscribeError.emptyAudio
        }
        let duration = await audioDuration(audioURL)
        if duration > 0, duration < 0.2 { throw TranscribeError.emptyAudio }

        // 2. Permission — ask if we never have; never prompt twice, never trap.
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .restricted:
            throw TranscribeError.restricted
        case .denied:
            throw TranscribeError.noPermission
        case .notDetermined:
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
            guard granted else { throw TranscribeError.noPermission }
        @unknown default:
            throw TranscribeError.noPermission
        }

        // 3. A recogniser for this locale, and one that is actually up.
        guard let recognizer = makeRecognizer() else {
            throw TranscribeError.noRecognizer(Locale.current.identifier)
        }
        guard recognizer.isAvailable else { throw TranscribeError.unavailable }

        // 4. Recognise. On-device when the model is present (privacy + offline);
        //    server otherwise. If an on-device pass fails outright, retry once
        //    against the server rather than losing the captions.
        let onDevice = recognizer.supportsOnDeviceRecognition
        let budget = max(45, duration * 4 + 20)
        var outcome: (text: String, words: [CaptionWord])
        do {
            outcome = try await run(recognizer: recognizer,
                                    request: request(for: audioURL, onDevice: onDevice),
                                    timeout: budget)
        } catch let error as TranscribeError {
            guard onDevice, error.isRecogniserFailure, recognizer.isAvailable else { throw error }
            outcome = try await run(recognizer: recognizer,
                                    request: request(for: audioURL, onDevice: false),
                                    timeout: budget)
        }

        let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscribeError.nothingRecognized }
        return (text, outcome.words)
    }

    // MARK: Plumbing

    private static func makeRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer()
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    private static func request(for url: URL, onDevice: Bool) -> SFSpeechURLRecognitionRequest {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false   // timings are only stable on the final result
        request.taskHint = .dictation
        request.addsPunctuation = true               // iOS 16+; captions read as sentences
        request.requiresOnDeviceRecognition = onDevice
        return request
    }

    /// Duration in seconds, 0 when it can't be read (never throws — an
    /// unreadable duration is not a reason to refuse to transcribe).
    private static func audioDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// One recognition pass. The result box guarantees the continuation resumes
    /// exactly once, whichever of the four paths gets there first: the final
    /// result, a recogniser error, the watchdog, or task cancellation.
    private static func run(recognizer: SFSpeechRecognizer,
                            request: SFSpeechURLRecognitionRequest,
                            timeout: Double) async throws -> (text: String, words: [CaptionWord]) {
        let box = ResultBox()
        let handle = TaskHandleBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.attach(cont)

                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    handle.cancel()
                    box.finish(.failure(TranscribeError.timedOut))
                }

                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        watchdog.cancel()
                        box.finish(.failure(translate(error)))
                        return
                    }
                    // FINAL result only — partial segments have provisional timings.
                    guard let result, result.isFinal else { return }
                    watchdog.cancel()
                    box.finish(.success((text: result.bestTranscription.formattedString,
                                         words: captionWords(from: result.bestTranscription))))
                }
                handle.set(task)
            }
        } onCancel: {
            handle.cancel()
            box.finish(.failure(CancellationError()))
        }
    }

    /// `SFTranscriptionSegment` → `CaptionWord`, with the timings sanitised.
    /// Server recognition sometimes returns every segment at timestamp 0 with a
    /// 0 duration; that would stack every caption at t=0, so it is treated as
    /// "no timings" and the captions are dropped rather than rendered wrong.
    static func captionWords(from transcription: SFTranscription) -> [CaptionWord] {
        var words: [CaptionWord] = []
        words.reserveCapacity(transcription.segments.count)
        var sawRealTiming = false
        var cursor: Double = 0

        for segment in transcription.segments {
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let rawStart = segment.timestamp.isFinite ? max(0, segment.timestamp) : 0
            let rawDuration = segment.duration.isFinite ? max(0, segment.duration) : 0
            if rawDuration > 0.001 || rawStart > 0.001 { sawRealTiming = true }
            // Keep starts non-decreasing and give every word a visible span.
            let start = max(rawStart, cursor)
            let end = start + max(rawDuration, 0.12)
            cursor = start
            words.append(CaptionWord(text: text, start: start, end: end))
        }
        return sawRealTiming ? words : []
    }
}

// MARK: - Small thread-safe boxes
//
// The Speech callbacks arrive on an arbitrary queue and can fire more than
// once; these two carry the continuation and the task across that boundary
// without a race and without a leaked continuation.

private final class ResultBox: @unchecked Sendable {
    typealias Value = (text: String, words: [CaptionWord])

    private let lock = NSLock()
    private var cont: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var finished = false

    /// Hand the continuation over. If a result already landed (cancellation can
    /// beat the operation body), deliver it immediately.
    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if finished, let pending {
            self.pending = nil
            lock.unlock()
            ResultBox.deliver(continuation, pending)
            return
        }
        cont = continuation
        lock.unlock()
    }

    /// First caller wins; every later caller is a no-op.
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        if let continuation = cont {
            cont = nil
            lock.unlock()
            ResultBox.deliver(continuation, result)
            return
        }
        pending = result
        lock.unlock()
    }

    private static func deliver(_ continuation: CheckedContinuation<Value, Error>,
                                _ result: Result<Value, Error>) {
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

private final class TaskHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    func set(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        if cancelled { lock.unlock(); task.cancel(); return }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
