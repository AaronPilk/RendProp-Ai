// App source is extracted by run-video-narration-readiness.py. These are closed
// delayed callbacks, not a microphone, SDK, network or provider acceptance test.
@MainActor private var assertions = 0
@MainActor private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !value() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
@MainActor private func until(_ predicate: () -> Bool) async {
    for _ in 0..<200 {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    check(false, "closed callback settled within bounded wait")
}

@main struct VideoNarrationReadinessTests {
    @MainActor static func main() async {
        let states: [(String, (NarrationFixture) -> Void)] = [
            ("Waiting for microphone permission…", { $0.requestingVoicePermission = true }),
            ("Stop recording before creating", { $0.recorder.isRecording = true }),
            ("Finishing your narration…", { $0.isTranscribing = true }),
            ("Writing your script…", { $0.scriptInFlight = true }),
            ("Making your voice…", { $0.ttsInFlight = true }),
        ]
        for (message, activate) in states {
            let f = NarrationFixture(); activate(f)
            check(!f.canGenerate, "busy state blocks readiness")
            check(f.generateTitle == message, "busy title identifies pending work")
            let button = f.button
            check(button.isDisabled && button.identifier == "phase1.reelGenerate" && button.strings == [message], "actual Create control exposes and disables pending work")
            button.tap()
            check(f.snapshotSpy.count == 0, "disabled Create cannot freeze audio")
            VideoPhotoFramingReader.control.reset()
            f.generate()
            await Task.yield()
            check(!f.checkingFraming && VideoPhotoFramingReader.control.reads == 0, "busy tap cannot start framing")
            f.generateWithSession()
            check(f.recorder.cancels == 0, "busy session callback preserves recording")
            check(f.snapshotSpy.count == 0, "busy session callback cannot freeze audio")
        }

        let framing = NarrationFixture()
        VideoPhotoFramingReader.control.reset(block: true)
        framing.generate()
        await until { VideoPhotoFramingReader.control.reads > 0 }
        framing.ttsInFlight = true
        VideoPhotoFramingReader.control.release()
        await until { !framing.checkingFraming }
        check(framing.connection.calls == 0 && framing.snapshotSpy.count == 0, "busy after framing cannot enter session")

        let reconnect = NarrationFixture()
        reconnect.connection.deferred = true
        VideoPhotoFramingReader.control.reset()
        reconnect.generate()
        await until { reconnect.connection.calls == 1 && !reconnect.checkingFraming }
        reconnect.isTranscribing = true
        reconnect.connection.deliver()
        check(reconnect.snapshotSpy.count == 0, "reconnect callback rechecks narration before snapshot")
        reconnect.isTranscribing = false
        reconnect.voiceMode = .myVoice
        reconnect.voiceover = .init(id: "finished-exact-take")
        reconnect.generateWithSession()
        check(reconnect.snapshotSpy.count == 1 && reconnect.snapshotSpy.voice?.id == "finished-exact-take", "settled take freezes exact completed audio")

        let failed = NarrationFixture()
        failed.voiceMode = .aiVoice
        failed.voiceError = "The requested voice failed."
        check(failed.canGenerate && failed.generateTitle == "Make my video", "settled failure does not require a paid voice retry")
        failed.generateWithSession()
        check(failed.snapshotSpy.count == 1 && failed.snapshotSpy.voice == nil && failed.recorder.requests == 0, "settled failure cannot auto-request another take")

        let off = NarrationFixture()
        off.voiceover = .init(id: "cached-unused-take")
        off.wordCaptionsOn = true
        check(off.canGenerate, "default Voice Off remains ready")
        off.generateWithSession()
        check(off.snapshotSpy.voice == nil && off.snapshotSpy.captions == .off, "Voice Off cannot include cached narration")

        let fresh = NarrationFixture()
        fresh.voiceMode = .myVoice
        fresh.recordTapped()
        check(fresh.requestingVoicePermission && !fresh.canGenerate, "permission await blocks creation")
        fresh.recordTapped()
        await until { fresh.recorder.requests == 1 }
        check(fresh.recorder.requests == 1, "repeated Record does not duplicate permission requests")
        fresh.recorder.reply(false)
        await until { fresh.voiceError != nil }
        check(fresh.canGenerate && fresh.recorder.starts == 0 && fresh.voiceError != nil, "denied permission releases readiness")

        let microphoneOnly = NarrationFixture()
        microphoneOnly.voiceMode = .myVoice
        microphoneOnly.recorder.hasMicrophonePermission = true
        microphoneOnly.recordTapped()
        await until { microphoneOnly.recorder.requests == 1 }
        microphoneOnly.recorder.reply(false)
        await until { !microphoneOnly.requestingVoicePermission }
        check(microphoneOnly.recorder.starts == 1 && microphoneOnly.speechDenied && !microphoneOnly.canGenerate, "microphone-only permission records with captions note and busy Create")
        microphoneOnly.recordTapped()
        check(microphoneOnly.isTranscribing && microphoneOnly.recorder.cancels == 0, "Stop still finishes the recording without cancellation")

        for reason in ["departed", "mode", "context", "phase"] {
            let f = NarrationFixture(); f.voiceMode = .myVoice
            f.recordTapped()
            await until { f.recorder.requests == 1 }
            switch reason {
            case "departed": f.work.isPresented = false
            case "mode": f.voiceMode = .off
            case "context": f.work.isContextCurrent = false
            default: f.phase = .generating
            }
            f.recorder.reply(true)
            await until { !f.requestingVoicePermission }
            check(f.recorder.starts == 0, "\(reason == "mode" ? "changed mode" : reason == "context" ? "changed context" : reason) permission callback cannot start microphone")
        }

        let reopened = NarrationFixture()
        reopened.voiceMode = .myVoice; reopened.recordTapped()
        await until { reopened.recorder.requests == 1 }
        reopened.disappear()
        reopened.work.isPresented = true // The queue-owned job is reused by a new presentation.
        reopened.recordTapped()
        await until { reopened.recorder.requests == 2 }
        reopened.recorder.reply(true)
        await until { reopened.recorder.returns == 1 }
        check(reopened.recorder.starts == 0, "reopened job cannot revive old permission intent")
        check(reopened.requestingVoicePermission && !reopened.canGenerate, "old callback cannot retire newer permission intent")
        reopened.recorder.reply(true)
        await until { reopened.recorder.returns == 2 }
        check(reopened.recorder.starts == 1 && !reopened.requestingVoicePermission && reopened.recorder.isRecording, "new presentation retains its own recording intent")

        let modeReentry = NarrationFixture()
        modeReentry.voiceMode = .myVoice; modeReentry.recordTapped()
        await until { modeReentry.recorder.requests == 1 }
        modeReentry.changeVoiceMode(.off)
        check(!modeReentry.requestingVoicePermission && modeReentry.canGenerate, "leaving My voice explicitly retires permission intent")
        modeReentry.changeVoiceMode(.myVoice)
        modeReentry.recorder.reply(true)
        await until { modeReentry.recorder.returns == 1 }
        check(modeReentry.recorder.starts == 0, "mode reentry cannot revive abandoned permission intent")

        let cleanup = NarrationFixture()
        let videoPlayer = ClosedPlayer(), takePlayer = ClosedPlayer()
        cleanup.player = videoPlayer; cleanup.voPlayer = takePlayer
        cleanup.voiceover = .init(id: "retained-finished-take")
        cleanup.voicePermissionID = UUID(); cleanup.requestingVoicePermission = true
        cleanup.recorder.isRecording = true
        cleanup.connection.deferred = true; cleanup.connection.run {}
        cleanup.disappear()
        check(!cleanup.work.isPresented && cleanup.voicePermissionID == nil && !cleanup.requestingVoicePermission, "disappearance retires presentation and permission intent")
        check(cleanup.connection.cancellations == 1 && cleanup.connection.action == nil, "disappearance cancels only its unsent reconnect waiter")
        check(cleanup.player == nil && videoPlayer.pauses == 1 && takePlayer.pauses == 1 && cleanup.musicPreview.pauses == 1, "disappearance releases video playback and pauses narration and music")
        check(cleanup.recorder.cancels == 1 && !cleanup.recorder.isRecording && cleanup.voiceover?.id == "retained-finished-take", "disappearance cancels unfinished microphone take but retains finished audio")

        let modeCleanup = NarrationFixture()
        modeCleanup.voiceMode = .myVoice; modeCleanup.recorder.isRecording = true
        modeCleanup.voiceover = .init(id: "finished-take", transcript: "Saved narration words")
        modeCleanup.changeVoiceMode(.off)
        check(modeCleanup.recorder.cancels == 1 && !modeCleanup.recorder.isRecording && modeCleanup.voiceover?.id == "finished-take", "leaving My voice preserves existing microphone cleanup and finished audio")
        modeCleanup.changeVoiceMode(.aiVoice)
        check(modeCleanup.catalogueLoads == 1 && modeCleanup.aiScript == "Saved narration words", "AI voice mode retains transcript seeding and catalogue loading")

        let copy = NarrationFixture()
        copy.scriptOverrunsReel = true; copy.scriptReadSeconds = 15
        check(copy.scriptNote.contains("Shorten the narration or add photos") && !copy.scriptNote.contains("freeze"), "overlong narration copy makes no last-frame promise")
        copy.aiScript = String(repeating: "x", count: 1001)
        check(copy.scriptNote.contains("Trim it or making the voice will fail"), "existing script character cap guidance remains")
        print("PASSED: \(assertions) actual narration readiness, delayed framing/session/permission, button, snapshot and copy assertions")
    }
}
