# HANDOFF-V — from the agent that owns `FlythroughDetailView.swift`

Everything below is a change in a file I do not own. Nothing here blocks today's
field test; all of it is copy consistency.

## Done in my file (context)

- The per-listing photo screen is now titled **"AI Photo Studio"** with the
  home's address as a nav-bar subtitle (principal toolbar item — iOS 16 has no
  `navigationSubtitle`). It used to be "Listing photos" / "<Space> photos".
- A **"Make a reel"** card is now always on that screen, from zero photos,
  carrying a **"🎙 Voice + captions"** callout. Disabled with the plain reason
  "Add 2 photos to start" until two photos exist. `intent == .reel` still deep
  links here and now rings that card.
- Reel Studio's setup is a numbered path: **1 Pick photos → 2 Add your voice
  (optional) → 3 Make the reel.**
- Edit-button wording is one verb each: "Make it twilight", "Make the sky blue",
  "Make the lawn green", "Tidy the room", "Add furniture", "Turn it into video",
  "Ask for anything". The COMPLIANCE wording is unchanged — `provenanceLabel`
  still writes "Declutter" / "Virtual staging" to the disclosure, and the
  staging dialog still says "Virtual staging is disclosed on your tour".

## Asks (none urgent)

1. **`RendpropApp.swift` — Home feature tiles** (`ListingFeature.actionTitle` /
   `.promise`, around lines 2523–2542):
   - `.photos` → `actionTitle` reads "Take photos", `promise` reads
     "Twilight · blue sky · staging". The screen it opens is now called
     **AI Photo Studio**. Suggest `actionTitle: "AI Photo Studio"` (or keep the
     verb and change the promise to "Sky · tidy · furniture") so the tile and
     the screen it lands on use the same name.
   - `.reel` → `promise` reads "Photos → one social video". The reel now has a
     voiceover; suggest **"Video + your voice"** (matches the toolbox card I
     already updated on the listing detail screen).

2. **`MockAPIClient.swift:213`** — the audit-trigger fixture string
   `"POST /ai-photo (AI Photo Studio: twilight, sky, lawn, declutter, stage)"`
   is now accurate again (the name refers to the per-listing studio). No action
   needed; noting it so nobody "fixes" it.

3. **Nothing needed in `Info.plist`.** `NSMicrophoneUsageDescription` and
   `NSSpeechRecognitionUsageDescription` are both present and honest, including
   the "otherwise the recording is sent to Apple's speech recognition service"
   sentence — my new record-screen copy ("Apple turns your words into captions")
   was written to match it rather than promise on-device-only.

4. **Nothing needed in `Voice/**` or `Networking/**`.** I used only the exposed
   API: `VoiceRecorder.requestPermissions()` / `.hasMicrophonePermission`,
   `SpeechTranscriber.isAvailable()` / `.canAskForPermission()` / `.transcribe`,
   `Voiceover.persistAudio`, `api.aiVoices()` / `api.aiVoiceTTS(...)`.
   One behaviour note for whoever owns the Voice files: the app now records with
   the **microphone alone**. `requestPermissions()` returning false no longer
   blocks recording — if the mic is granted, the take runs and transcription is
   skipped. Please keep `hasMicrophonePermission` and the two
   `SpeechTranscriber` availability helpers as they are.
