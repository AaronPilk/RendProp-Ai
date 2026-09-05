# Rendprop AUTO ROOM CHAPTERS — contract v1 (2026-09-04)

**Owner:** agent CHAPTERS · `services/supabase/functions/ai-chapters/**` + `apps/ios/Rendprop/Networking/**`
**Consumer:** agent IOS (`Screens/**`) builds the tagger UI against §3–§5 of this file.
**Router:** consumes `resolveRoute("video.chapters", …)` per `docs/AI-ROUTER-CONTRACT.md` §1/§3.

The agent never types a room name again. After a walkthrough is captured (or
rendered), the app sends the video's `asset_id` to `POST /ai-chapters`; Gemini
watches it at 1 fps / low media resolution and returns the rooms with entry
timestamps; the app **pre-fills the room tagger** with editable suggestions.

Target cost: **~1–3¢ per house** (0.0117¢/s of video → 1.05¢ for a 90 s clip).

---

## 1. Endpoint

```
POST /functions/v1/ai-chapters
Authorization: Bearer <owner JWT>      (required — role `marketing` is refused)
apikey: <supabase anon key>
X-Org-Id: <org uuid>                   (optional; must match the asset's org)
Idempotency-Key: <8…128 chars>         (one UUID per user TAP — a repeat inside
                                        2 min is a 409, never a second bill)
Content-Type: application/json
```

### Request

```jsonc
{
  "listing_id": "0f0f…",     // uuid, REQUIRED — anchors provenance + the label vocabulary
  "asset_id":   "9a9a…",     // uuid, REQUIRED — capture_assets.id, kind "video", uploaded
  "max_chapters": 12,        // optional, 1…24, default 12
  "language": "en"           // optional, BCP-47-ish, default "en"
}
```

### Response `200`

```jsonc
{
  "chapters": [
    {
      "label": "Entry",              // from the allowed vocabulary (§4) or "Other"
      "start_s": 0,                  // seconds into THE SUBMITTED ASSET (§3)
      "end_s": 6.5,                  // seconds; >= start_s, <= video_seconds
      "confidence": 0.91,            // 0…1, model's own; may be null
      "description": "Tiled entry with a coat closet and a view down the hall."
                                     // property-only; null when the model gave
                                     // none OR when it failed the fair-housing
                                     // gate (the chapter itself is KEPT)
    }
  ],
  "summary": "A single-level three-bedroom walkthrough…",  // may be null
  "model": "gemini-3.6-flash",
  "provider": "gemini",
  "route": { "task": "video.chapters", "route_id": null, "source": "legacy" },
  "cost_cents_estimate": 1.05,
  "video_seconds": 90,               // duration the timestamps are measured against
  "time_base": "asset_seconds",      // ALWAYS this value in v1 — see §3
  "asset_id": "9a9a…",
  "warnings": ["3 suggestions were merged (under 3s)"],   // may be []
  "disclosure": "This media was digitally altered or generated with AI.",
  "provenance": { "id": "…", "recorded": true }
}
```

### Errors (standard `{ error, code }` envelope)

| status | code | when |
|---|---|---|
| 400 | `validation` | missing/!uuid `listing_id`/`asset_id`, asset is a photo, `asset_id` not on `listing_id` |
| 402 | `plan_required` | the plan includes 0 renders/month |
| 403 | `forbidden` | role `marketing`, or the asset belongs to another org than `X-Org-Id` |
| 404 | `not_found` | asset (or its listing) not visible to the caller |
| 409 | `conflict` | duplicate `Idempotency-Key` inside 2 min; upload not complete; no probed `duration_s` |
| 413 | `payload_too_large` | video over the size/length ceiling (§6) |
| 429 | `rate_limited` / `quota_exceeded` | 10 per 5 min per org, or the monthly meter |
| 502/503/504 | `upstream` | `GEMINI_API_KEY` unset, plan lookup degraded, Gemini unreachable or still transcoding |

**The server never writes `capture_chapters`.** Suggestions are suggestions. The
app confirms/edits, then calls the EXISTING
`PATCH /renders/:render_id/chapters { chapters:[{label,t_ms,sort}] }`.

---

## 2. Swift API (`apps/ios/Rendprop/Networking/`, additive)

```swift
/// One AI-suggested room chapter. Every wire field is Optional and decoded
/// leniently (house style): a new field, a null, or one malformed entry must
/// never fail the whole suggestion set. Read through the non-optional accessors.
struct AIChapter: Codable, Sendable, Hashable, Identifiable {
    // Wire (snake_case → camelCase via .convertFromSnakeCase)
    let label: String?
    let startS: Double?
    let endS: Double?
    let confidence: Double?
    let description: String?

    var id: String { "\(roomLabel)@\(Int((startS ?? 0) * 1000))" }

    /// Never empty — an unlabeled suggestion reads "Other".
    var roomLabel: String { … }
    /// Seconds into the SUBMITTED asset. Never negative / NaN.
    var startSeconds: Double { … }
    /// Milliseconds into the SUBMITTED asset — what `RoomTag.tMs` wants.
    var startMilliseconds: Int { … }
    /// nil when the model gave none or it failed the fair-housing gate.
    var blurb: String? { … }
    /// nil when the model sent no confidence. 0…1 when it did.
    var confidenceScore: Double? { … }
}

/// The result of one `POST /ai-chapters`.
struct AIChaptersResult: Sendable, Hashable {
    let chapters: [AIChapter]
    let summary: String?
    let videoSeconds: Double?
    let model: String?
    let costCentsEstimate: Double?
    /// Verbatim server strings — show them, don't re-word them.
    let warnings: [String]
    let disclosure: String?
    let provenanceID: String?
    let provenanceRecorded: Bool

    /// True when there is at least one usable suggestion.
    var hasSuggestions: Bool { !chapters.isEmpty }
}

protocol APIClient {
    /// Ask Gemini to watch `assetID` and suggest room chapters.
    /// `idempotencyKey`: ONE UUID PER USER TAP — a retry of the same tap is
    /// 409'd server-side rather than billed twice.
    func aiChapters(listingServerID: UUID,
                    assetID: UUID,
                    maxChapters: Int,
                    idempotencyKey: String) async throws -> AIChaptersResult
}
```

`MockAPIClient` returns **6 believable chapters for a 90 s clip** (Entry 0 s,
Living Room 9 s, Kitchen 24 s, Dining 41 s, Primary 55 s, Backyard 74 s) after a
~1.2 s simulated think, so the whole flow runs offline.

---

## 3. TIME BASE — read this before wiring the tagger

> **`start_s` / `end_s` are seconds from t=0 of the EXACT asset you submitted.**
> The server never rescales anything. `time_base` is always `"asset_seconds"`.

Rendprop has two timelines for the same walk:

| timeline | what it is | who uses it |
|---|---|---|
| **capture** | the raw walkthrough off the camera | `RoomTag.tMs`, `RoomTaggerView` |
| **rendered** | the on-device render, retimed by `speedFactor` (a 2× glide halves every timestamp) | `capture_chapters.t_ms`, the hosted player |

`AppModel.chapters(from:speedFactor:)` and `FlythroughDetailView.playbackTags`
both convert capture → rendered by **dividing by `speedFactor`**.

**So: send the ORIGINAL CAPTURE asset.** It is the timeline the tagger is
written in, and no conversion is needed:

```swift
tag.tMs = chapter.startMilliseconds          // capture asset → direct
```

The capture asset lives in the private `uploads` bucket; that is fine — this
function presigns a short-lived GET, it does not need a public URL (which is why
it does not reuse `ai-video`'s public-bucket-only asset resolver).

If you only have the RENDER asset (published tour, capture already purged),
you MUST convert back to capture time before writing a `RoomTag`:

```swift
tag.tMs = Int((chapter.startSeconds * speedFactor * 1000).rounded())
```

…and if you are writing straight to `capture_chapters` via
`PATCH /renders/:id/chapters` (skipping `RoomTag`), a render-asset suggestion
needs **no** conversion at all — it is already on the rendered timeline.

Why the server refuses to guess: `capture_assets` records `bucket` and
`duration_s`, but nothing on the row says "this file was retimed by 2×" — the
speed factor lives only in the app's `RenderedTour`. A server that guessed would
be silently wrong for every hand-imported render. One rule, stated once, in the
caller's hands.

---

## 4. Room label vocabulary

The server passes the app's OWN quick-tag list for the listing's `space_type` as
the allowed set (mirrors `SpaceType.quickTags` in `Models/Listing.swift`), plus
`"Other"`:

| space_type | labels |
|---|---|
| `real_estate` | Exterior, Entry, Living Room, Kitchen, Dining, Primary, Bedroom, Bath, Office, Garage, Backyard |
| `venue` | Entrance, Main Hall, Stage, Bar, Lounge, Patio, Garden, Kitchen, Restrooms, Green Room |
| `restaurant` | Entrance, Dining, Bar, Patio, Private Room, Kitchen, Restrooms |
| `retail` | Entrance, Front, Aisles, Produce, Deli, Checkout, Backroom |
| `fitness` | Entrance, Reception, Main Floor, Weights, Studio, Cardio, Locker Room, Showers |
| `other` | Entrance, Main Area, Front, Back, Outside, Restrooms |

A returned label that matches the set (case/space-insensitive) is snapped to the
canonical spelling. A label OUTSIDE the set is kept only if it clears the
fair-housing gate and is ≤ 32 chars (and a warning is added); otherwise it
becomes `"Other"`. **A room label is never invented from a person, a religion,
or a neighborhood** — that is what the gate is for.

---

## 5. What agent IOS must build

1. **Two entry points, one call.**
   - a visible **"Suggest room names"** button on the tagger, and
   - an **automatic** call when the tagger opens with **zero** tags.
   Call it **once per asset** — remember the result (or the refusal) for the
   session; do not re-fire on every sheet presentation.
2. **Pre-filled, editable.** Every suggestion lands as a normal editable
   `RoomTag` chip. The agent can rename, move, or delete any of them exactly as
   if they had typed it. Show `confidenceScore` only as a soft cue (dim the
   chip under 0.5); never block on it.
3. **Never auto-publish.** A suggestion set must never trigger a publish, and
   must never reach `PATCH /renders/:id/chapters` without the agent having seen
   the tagger. Suggestions are a draft, always.
4. **Show `warnings` verbatim** in a small footnote when non-empty ("3
   suggestions were merged").
5. **Failures are silent for the automatic path.** A 402/429/503 on the
   auto-call must not throw a modal at someone who never asked for AI — degrade
   to the empty tagger and leave the button. The BUTTON path shows the server's
   message (it is written for the agent).
6. **`description`** is a room blurb the agent can paste into a caption; it is
   NOT a disclosure. Show `disclosure` only where the media itself is disclosed.
7. **Quota:** this bills the same `renders_per_month` meter as a render. Show it
   as a render in the usage row; do not invent a new counter.

---

## 6. Server behaviour (for reviewers)

- **Auth/quota/provenance** exactly mirror `ai-video`: owner JWT, role gate
  (`marketing` refused), `entitlementForCharge`, burst limiter
  `aichapters:<org>` 10 / 5 min, monthly meter `chaptersmo:<org>` against
  `renders_per_month`, `Idempotency-Key` dedupe `aichidem:<org>:<key>` 2 min.
  Quota is charged **after** the body and the asset validate, immediately before
  the billable Gemini call, and **refunded** (`refundRateLimit`) when Gemini fails.
- **Asset** must be `kind = "video"`, `uploaded = true`, belong to the caller's
  org's listing, and carry a probed `duration_s`. Ceilings: **≤ 20 min** and
  **≤ 300 MB** (the Files API takes 2 GB, but an edge function has to stream it
  and has a wall clock).
- **Media path:** R2 presigned GET (900 s) → Gemini **Files API** resumable
  upload (streamed, never buffered) → poll `state=ACTIVE` → `generateContent` →
  **`DELETE /v1beta/files/<name>`** immediately (customer media; the 48 h
  auto-expiry is a backstop, not the plan).
- **Model** from `resolveRoute("video.chapters", { plan, needs:["video_understanding","timestamps"], carries_customer_media:true })`.
  Those capability tokens match migration 0018's seed EXACTLY — `ctx.needs` is a
  hard AND, so one hyphen would filter every step out and silently pin the
  feature to the legacy model forever. The chain is used as returned, never
  re-filtered (HANDOFF-DB.md §2); the Files upload happens ONCE and the first
  two steps are tried against it, so a fallback costs only another
  `generateContent`. The router is loaded at RUNTIME (`_shared/router.ts` is
  another agent's file and may churn); absent, empty, or flag-off ⇒ the legacy
  default `gemini-3.6-flash` at 0.0117¢/s. `video.chapters` has no prior
  behaviour to preserve, so an empty chain degrades rather than 503ing — the
  plan boundary is still enforced by the quota gate, which runs either way.
- **Pricing follows the chosen route's own `unit`.** 0018 prices
  `video.chapters` PER CALL (1.4¢ a tour); the legacy step is per SECOND
  (0.0117¢/s). Using one for the other is the difference between a 1¢ ledger row
  and a 126¢ one, so `units` is `video_seconds` for a per-second row and `1` for
  a per-call row. `video_seconds` is recorded in the ledger `meta` either way.
- **Post-processing, in order:** parse → per-chapter fair-housing gate on
  `description` (drop the description, keep the chapter) → label snap → clamp to
  `[0, video_seconds]` → sort by `start_s` → merge adjacent same-label → merge
  anything under **3 s** into its neighbour → cap at `max_chapters` (keep the
  longest, re-sort) → close `end_s` gaps.
- **Ledger:** `recordAppAiCost({ feature:"chapters", provider: <route>, model: <route>, units: <per the route's unit>, unitCents: <the route's> })`.
- **Provenance:** one `media_provenance` row, `kind:"other"`, `edit:"chapters"`,
  label `"AI-suggested room labels"`. Best effort, never fatal.

### The exact Gemini request

```jsonc
POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent
x-goog-api-key: <GEMINI_API_KEY>
content-type: application/json

{
  "system_instruction": { "parts": [ { "text": "<FAIR_HOUSING_LOCK + PERMANENCE_LOCK + the never-describe rules>" } ] },
  "contents": [ { "role": "user", "parts": [
      { "file_data":      { "mime_type": "video/mp4", "file_uri": "https://generativelanguage.googleapis.com/v1beta/files/<id>" },
        "video_metadata": { "fps": 1 } },
      { "text": "<task prompt + allowed label vocabulary>" }
  ] } ],
  "generation_config": {
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "response_mime_type": "application/json",
    "response_schema": { "type": "OBJECT", "properties": { "chapters": { … }, "summary": { … }, "warnings": { … } }, "required": ["chapters"] },
    "temperature": 0.2,
    "max_output_tokens": 4096,
    "candidate_count": 1
  }
}
```

Verified 2026-09-04 against
<https://ai.google.dev/gemini-api/docs/generate-content/video-understanding>,
`…/generate-content/media-resolution` and `…/docs/files`. Two notes:

- Google is rolling out a **beta `POST /v1beta/interactions`** API (typed `input`
  blocks, `response_format`, per-item `"resolution": "low"`). Its own docs say
  *"For stable production deployments, we recommend you continue to use the
  `generateContent` API."* We use `generateContent`, which is also what
  `ai-photo` already speaks.
- `file_uri` accepts **Files API URIs and YouTube URLs only** — an arbitrary
  public HTTPS URL is not documented as supported, which is why the R2 object is
  uploaded to the Files API rather than linked. Video at
  `MEDIA_RESOLUTION_LOW` = 70 tokens/frame; at 1 fps that is 70 tokens per
  second of walkthrough.

**Unexercised:** there is no `GEMINI_API_KEY` in this environment, so the live
Gemini round-trip (Files upload → ACTIVE → generateContent) has never been run.
Everything downstream of the parse is covered by `postprocess_test.ts`.
