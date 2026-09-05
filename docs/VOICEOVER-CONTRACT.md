# Reel voiceover + captions — interface contract

Frozen 2026-09-04. Three agents build against this in parallel:

- **A** owns `apps/ios/Rendprop/Voice/**` (new files) + `Rendprop/Info.plist`
- **B** owns `services/supabase/functions/ai-voice/**` + `apps/ios/Rendprop/Networking/**`
- **C** owns `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` (ReelStudioView + stitch)

Nobody edits anyone else's files. If you need a change in one, write it to your `HANDOFF-<letter>.md`.

---

## Product shape

In Reel Studio, after the photos are chosen, the agent can add a voiceover. Two modes:

1. **My voice** — tap and hold to record. The recording IS the voiceover. Captions come from
   on-device transcription of that recording (word timings included).
2. **AI voice** — record or type a script, pick a voice, ElevenLabs speaks it. Captions come
   from ElevenLabs' character-level alignment.

Either way the reel exports with the voiceover audio mixed in and captions burned into the
video, styled for social (large, bold, centre-lower, word-by-word highlight).

**Speech-to-text is Apple's `Speech` framework, not Whisper.** It is free, runs on device,
returns per-word timestamps, and adds no provider. Whisper would mean a new OpenAI dependency
and $0.006/min for something iOS already does better here.

---

## Shared types — agent A defines these, in `apps/ios/Rendprop/Voice/VoiceTypes.swift`

```swift
/// One caption word with its place on the timeline, relative to the START of
/// the voiceover audio (not the reel).
struct CaptionWord: Codable, Equatable, Sendable {
    let text: String
    let start: Double      // seconds
    let end: Double        // seconds
}

/// A finished voiceover: an audio file on disk plus its word timings.
struct Voiceover: Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case myVoice, aiVoice }
    let id: UUID
    let audioURL: URL          // Documents/Voiceovers/<listing>-<stamp>.m4a|mp3
    let duration: Double       // seconds
    let transcript: String
    let words: [CaptionWord]   // may be empty — captions then simply don't render
    let source: Source
    let voiceName: String?     // AI voice label, nil for myVoice
}

/// Caption styling. C reads it; A owns the defaults.
struct CaptionStyle: Equatable, Sendable {
    var enabled: Bool
    var maxWordsPerLine: Int   // default 4
    var fontSize: CGFloat      // points at 1080-wide render, default 64
    var highlightActiveWord: Bool
}
```

### Agent A also provides

```swift
@MainActor final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording: Bool
    @Published private(set) var level: Float        // 0…1, for a meter
    @Published private(set) var elapsed: Double
    func requestPermissions() async -> Bool         // mic + speech, both
    func start() throws
    func stop() async throws -> URL                 // m4a in a temp dir
    func cancel()
}

enum SpeechTranscriber {
    /// On-device where the device supports it. Returns transcript + word timings.
    /// Throws a user-readable error; never traps.
    static func transcribe(_ audioURL: URL) async throws -> (text: String, words: [CaptionWord])
    static func isAvailable() -> Bool
}

/// Builds the CALayer that AVVideoCompositionCoreAnimationTool animates.
/// C calls this; A owns the drawing.
enum CaptionRenderer {
    /// - Parameters:
    ///   - words: timings relative to the voiceover start
    ///   - offset: where the voiceover starts inside the reel (usually 0)
    ///   - renderSize: the composition size (1080x1920 or 1920x1080)
    /// - Returns: a layer sized to renderSize with keyframed opacity per line.
    static func layer(words: [CaptionWord], offset: Double,
                      renderSize: CGSize, style: CaptionStyle) -> CALayer
}
```

---

## Backend — agent B

New edge function `ai-voice`, JWT-verified, same envelope and `RPnnn` conventions as `ai-photo`.

### `GET /ai-voice/voices`
```json
{ "voices": [ { "voice_id": "…", "name": "Rachel", "labels": "narration · american" } ] }
```
Cached in the function for 10 minutes. If `ELEVENLABS_API_KEY` is unset, return
**503** with `code: "upstream"` and a message naming the missing configuration — never a
silent empty list, and never the key.

### `POST /ai-voice/tts`
```json
{ "text": "…", "voice_id": "…", "listing_id": "uuid|null", "label": "Reel voiceover" }
```
→ 200
```json
{
  "audio_url": "https://…",     // R2, short-lived signed GET
  "mime": "audio/mpeg",
  "duration_s": 12.4,
  "words": [ { "text": "Welcome", "start": 0.0, "end": 0.42 } ],
  "voice_name": "Rachel",
  "characters": 148
}
```
Derive `words` by grouping ElevenLabs' character alignment
(`/v1/text-to-speech/{id}/with-timestamps` → `alignment.characters` +
`character_start_times_seconds` + `character_end_times_seconds`) on whitespace. If alignment is
absent, return `words: []` rather than guessing — captions degrade off, they never drift.

### Gates — all mandatory

- **Fair housing on `text`.** A voiceover script is property marketing; HUD applies to it exactly
  as it does to a photo. Route it through `_shared/fairhousing.ts` before spending a cent.
  "Great family neighborhood", "safe area", "walk to St. Mary's", "perfect for young
  professionals" must be refused with `code: "unsupported_edit"` and copy that says which phrase
  and why. If the existing checker only covers image prompts, extend it — additively, and never
  weaken an existing rule.
- **Length cap** — 1,000 characters. Longer is a 400.
- **Quota** — meter it. Reuse `reels_per_month`; do not invent a new plan column (that needs a
  migration on every plan row and there is no time). Charge AFTER a successful ElevenLabs
  response, or refund with `refundRateLimit` on failure.
- **Rate limit** — 20 per 5 minutes per org.
- **Provenance** — write a `media_provenance` row: this is AI-generated audio and the tour has to
  be able to disclose it.

### iOS API client (agent B owns these too)

```swift
func aiVoices() async throws -> [AIVoice]
func aiVoiceTTS(text: String, voiceID: String, listingServerID: UUID?,
                label: String, idempotencyKey: String) async throws -> AIVoiceResult
```
`AIVoiceResult` carries `audioURL: URL`, `durationS: Double`, `words: [CaptionWord]`,
`voiceName: String`. Every wire field Optional, decoded leniently, per house style.
MockAPIClient returns a believable fixture.

---

## Reel assembly — agent C

`ReelStudioView.stitch` currently takes `(clips, renderSize, captions: ReelCaptions?, output)`.
Extend it — **additively** — to accept `voiceover: Voiceover?` and `captionStyle: CaptionStyle`.

- Mix the voiceover onto an **audio** track in the same `AVMutableComposition`.
- **Video length wins.** If the voiceover is longer than the stitched clips, hold the last frame
  for the remainder rather than truncating the agent mid-sentence. If it is shorter, the reel just
  ends with silence. Never speed-change either one.
- Captions go through `AVVideoCompositionCoreAnimationTool` alongside the existing title card —
  do not replace that path, add to it.
- The reel must still export correctly with **no** voiceover, and with a voiceover but **no**
  words (captions simply absent). Both are normal states, not errors.

---

## Non-negotiables

- Nothing may spend money before the fair-housing gate passes.
- No credential value is ever read by the app, logged, or returned by any route.
- Swift 5.9, iOS 16.0. No new third-party dependencies. `Speech` and `AVFoundation` are Apple.
- Every new `Info.plist` usage string must be honest about what it is for — App Review reads them.
- Keep SwiftUI view bodies small. A type-checker timeout in this file broke the build once today.
