# HANDOFF — agent IOS (AI routing wave, 2026-09-04)

Branch `ai-router`. IOS owns `apps/ios/Rendprop/Screens/**` and `Voice/**`.
Two things shipped: the **owner console → AI routing** screen, and **auto room
chapters pre-filling the room tagger**.

Everything below is a request to another agent. Nothing here is a change I can
make myself — `Networking/**` is CHAPTERS's, `/admin/routing` is DB's.

---

## 1. Networking methods I need (CHAPTERS / DB)

### 1a. Three admin routing calls — NOT YET IN THE SWIFT CLIENT

> **DONE (follow-up commit on `ai-router`).** All three landed on the `APIClient`
> protocol with exactly these signatures, implemented in `LiveAPIClient` and
> `MockAPIClient`, and the `#if false` block in §1b is now the two live
> conformance lines. The DTOs were used where they are, not moved or copied.

The server routes exist (`services/supabase/functions/admin/index.ts`,
`handleRouting` / `handleRoutingWrite`) but have no Swift client. Add these
three to the `APIClient` protocol + `LiveAPIClient` + `MockAPIClient`, **with
exactly these signatures** — they match what the function actually answers:

```swift
/// GET /admin/routing
func adminRouting() async throws -> AdminRoutingReport

/// POST /admin/routing/flag   body {"enabled": Bool}
func adminSetRoutingFlag(enabled: Bool) async throws -> AdminRoutingWriteAck

/// POST /admin/routing/step/{routeID}   body {"enabled": Bool}
/// 409 `conflict` when routeID is the task's legacy step.
func adminSetRouteStep(routeID: String, enabled: Bool) async throws -> AdminRoutingWriteAck
```

Note the writes return the function's small ack (`{ok, enabled, changed_at,
note, …}`), **not** a fresh report — that is what the server sends. The screen
shows `ack.note` (the server's own sentence: *"The router is ON. Each task now
resolves to its table-driven chain."*) and then re-reads `GET /admin/routing`,
so a switch still only moves after the server has confirmed it.

> **DO NOT re-declare the DTOs.** `AdminRoutingReport`, `AdminRoutingTask`,
> `AdminRoutingStep`, `AdminRoutingPolicy`, `AdminRoutingHealth`,
> `AdminRoutingFlag`, `AdminRoutingLegacy` and `AdminRoutingWriteAck` already
> exist, in `Screens/SettingsView.swift` (search `MARK: - AI routing brain:
> wire models`). They live there because `Networking/**` was another agent's
> file this cycle and **new `.swift` files are not in the Xcode target** until
> someone runs `xcodegen generate` on a Mac (see
> `Screens/AdminConsoleView.swift` for the full story). Same module — just use
> them. A second declaration of any of those names is a hard build break.
> Moving them into `Networking/APIClient.swift` is welcome; copying is not.

### 1b. How to switch the screen on (one line, twice)

The screen does **not** call `model.api.adminRouting()` directly, so that it
compiles and ships today whether or not the methods exist. It casts:

```swift
private var routingAPI: AdminRoutingAPI? { model.api as? AdminRoutingAPI }
```

`AdminRoutingAPI` is declared next to the DTOs. With no conformance the screen
draws an honest "Not in this app build yet" card and every control is
read-only — nothing breaks, nothing lies.

At the bottom of that block is an **`#if false`** section holding the exact
code to enable it. Once the three methods exist, delete the `#if false` /
`#endif` and keep:

```swift
extension LiveAPIClient: AdminRoutingAPI {}
extension MockAPIClient: AdminRoutingAPI {}
```

### 1c. `aiChapters` — landed, used unmodified

CHAPTERS landed this in `Networking/APIClient.swift` while this branch was
being written, and the tagger calls it **directly**, exactly as published:

```swift
func aiChapters(listingServerID: UUID, assetID: UUID, maxChapters: Int,
                idempotencyKey: String) async throws -> AIChaptersResult
```

reading `AIChaptersResult.chapters / .warnings / .hasSuggestions` and
`AIChapter.roomLabel / .startSeconds / .confidenceScore` — all verified present
in the repo. The call site is `RoomTaggerView.runSuggest(automatic:)` in
`Screens/ReviewSubmitView.swift`.

---

## 2. `GET /admin/routing` — built against the landed function, not the doc

> **DONE (follow-up commit on `ai-router`).** `docs/ADMIN-CONSOLE-CONTRACT.md`
> now has the `§GET /admin/routing` section and it matches the function: all
> three surprises below (`routes`, `changed_by_is_you`, `spend_30d_cents`) are
> stated there, along with the `retire_after` day format and the fact that the
> step-write ack carries no `note`. Every key in the doc's example was diffed
> against the keys `handleRouting` emits; they are the same set.

`docs/ADMIN-CONSOLE-CONTRACT.md` still has no `§Routing` section, so the DTOs
were written by reading `handleRouting()` itself and cross-checked by decoding
its literal payload in a harness. DB should write the doc section to match what
the function emits; three things a reader of the task brief will not expect:

1. **The task array is `routes`, not `tasks`**, and each entry carries
   `step_count`, `live_step_count` and a `legacy: {route_id, provider, model}`
   summary. Both spellings decode (`routes ?? tasks`), so a rename can't blank
   the screen.
2. **There is no `changed_by`.** The audit actor lives under
   `flag: {enabled, changed_at, changed_by_is_you, changed_by_recorded}` — the
   function deliberately never returns another admin's user id. The console
   therefore says *"Last changed by you"* / *"by another admin"* / just the
   time, and never invents a name.
3. **`spend_30d_cents` decodes as `spend30DCents`, capital D.** Foundation's
   `.convertFromSnakeCase` titlecases each component after the first and
   `"30d".capitalized == "30D"` (verified by running it, not guessed). Same for
   `spend_30d_rows`. The struct declares **both** spellings and reads whichever
   arrived, because that titlecasing is ICU-dependent and this repo has already
   been bitten once by a Darwin/corelibs Foundation divergence (see the comment
   on `AdminMoney.currencyFormatter`).

Also handled: `retire_after` parses as a bare `yyyy-MM-dd` day **or** a full ISO
timestamp; `position` orders the chain and steps missing it keep wire order at
the end rather than silently reordering a fallback chain; `spend_truncated` /
`routes_truncated` add a "these figures are a lower bound" line; the server's
top-level `note` is printed **verbatim** in the flag section's footer because it
is the honest caveat on the 30-day spend.

A 404 on `GET /admin/routing` is its own state, in plain words: *"This server
build has no routing table yet … Every AI feature is still using today's single
provider."* Not an error.

---

## 3. What the screen writes, and nothing else

Only two writes exist:

* the master flag (confirmed with an alert on the way **ON**; straight through
  on the way **OFF**, because off is always the safe direction), and
* one step's `enabled`.

Plan policy rows are **read-only display** for now, per the brief.

**The legacy step gets no switch.** `handleRoutingWrite` 409s any attempt to
toggle the row whose `note` is `"legacy"` — enabling it would put it into a
flag-ON chain, disabling it would delete the flag-off answer for that task. The
UI matches: that row is labelled "today's", reads *"This is what runs today,
with the brain off. It has no switch — turn the brain itself off instead."*, and
is excluded from `primaryStep`, from `liveSteps`, and from the "same model as …"
comparison (it is not a fallback). If a build ever slips through anyway, the
409's own message is what the owner sees.

---

## 4. Time base (the thing that had to be right)

`start_s` is seconds from t=0 of the asset we submitted
(`time_base: "asset_seconds"`; the server never rescales —
`docs/AI-CHAPTERS-CONTRACT.md` §3).

The app has two timelines:

| timeline | who lives there |
|---|---|
| capture | `RoomTag.tMs`, the tagger's scrubber, `RoomTaggerView` |
| rendered | the published mp4, `capture_chapters.t_ms`, the hosted player |

`AppModel.chapters(from:speedFactor:)` and `FlythroughDetailView.playbackTags`
both go capture → rendered by **dividing** by `speedFactor`. So:

```
render_s = capture_s / speedFactor      ⇒      capture_s = render_s × speedFactor
```

The only asset the app holds a **server** id for is the **rendered** mp4
(`AppModel.uploadedRenderAssets`, written by `publishTour`). So the suggestions
come back on the rendered timeline and are multiplied by `speedFactor` to reach
the capture timeline `RoomTag.tMs` is written in:

```swift
RoomTaggerView.captureMilliseconds(assetSeconds:scale:)   // scale = speedFactor
```

Worked, at speedFactor 2.0: a room entered at **capture 41.0 s** sits at
**render 20.5 s**; the model returns `start_s = 20.5`; `20.5 × 2.0 × 1000 =
41 000 ms`, so the scrubber lands on 41.0 s; Done → publish divides by 2.0
again → 20 500 ms on the hosted tour. Round-trips exactly.

**If the app ever gains a server id for the raw capture asset** (today it does
not — `UploadManager.State` is transient and `CaptureAsset` has no server id),
send that instead with `isRenderAsset: false`; `RoomTagSuggestSource.effectiveScale`
then forces the factor to 1, so a stale `assetSecondsToCaptureScale` cannot
silently misplace every room. The source is constructed in exactly one place:
`FlythroughDetailView.roomTagSuggestSource`.

That property also refuses to hand over a **stale** asset id: it only returns a
source when `uploadedRenderAssets[listing].relPath` still matches the current
tour's file, the same comparison `AppModel.publishTour` makes before reusing an
asset. Without it a re-render would have the AI watch the previous video and
land every name at the wrong moment.

---

## 5. Additive edits outside Screens/

Both inside `// MARK: - router additions` … `// MARK: - end router additions`:

* `Models/RoomTag.swift` — `isAISuggested: Bool?` and `aiConfidence: Double?`,
  plus `isFromAI` / `isLowConfidence`. Both Optional **and** defaulted, so older
  snapshots decode and the memberwise `RoomTag(name:tMs:)` used by
  `RoomTagBar`, `CaptureView` and `AppModel` still compiles. Neither field
  reaches the wire — `ChapterInput` is still built from `name`/`tMs` only, so
  the published tour's JSON is byte-identical.
* `Screens/FlythroughDetailView.swift` — `roomTagSuggestSource`, and the two-line
  `suggest:` argument on the existing `RoomTaggerView(…)` sheet.
* `Screens/SettingsView.swift` — the "AI routing" `NavigationLink` in the
  existing owner-console section.

`RendpropApp.swift` was **not** touched.

---

## 6. Known gaps / things a reviewer should look at

* **Dismissing the tagger still PATCHes.** `FlythroughDetailView.roomTaggerDismissed`
  is unchanged: closing the tagger after tags changed pushes chapters to the
  hosted tour. That is the existing, user-initiated save path and the brief said
  to keep it as the only write path — but it does mean an auto-filled tagger
  closed without a glance publishes AI names. Mitigations in place: auto-run only
  when the tagger is **empty**, a visible "N names came from the AI" banner with
  a one-tap **Clear these**, and an "AI suggested" chip on every untouched name.
  If that is judged too loose, the fix is a staged accept step, not a change to
  the PATCH.

  > **RESOLVED (follow-up commit on `ai-router`).** It was judged too loose, and
  > the staged accept step is now in: `RoomTaggerView` deletes every tag still
  > marked `isAISuggested == true` on every way out (Done and `onDisappear`), so
  > an untouched suggestion never reaches `model.assets` and therefore neither
  > the chapters PATCH nor a later `publishTour`. Acceptance is a **"Use these
  > names"** button on the banner (the whole set at once), or the existing
  > per-row rename/tick. `roomTaggerDismissed` additionally compares and sends
  > human-confirmed tags only, so the answer does not depend on whether SwiftUI
  > runs the sheet's `onDisappear` before the host's `onDismiss`. The one-tap
  > **Clear these** is unchanged.
* **Consent is not auto-prompted.** The automatic run happens only when
  `AIConsent.shared.isGranted` is already true; it never raises the disclosure
  sheet at someone who opened a screen to type room names. The **button** calls
  `ensureGranted()` properly. Contract §5.5's "failures are silent for the
  automatic path" is honoured — auto failures set no error.
* **Nothing here has been compiled against SwiftUI.** This environment has
  Swift 6.0.3 for Linux and no iOS SDK, so verification was
  `swift-frontend -frontend -parse -swift-version 5` on every changed file plus
  a standalone harness that type-checks and runs the DTO decode, every copy
  helper, and the time-base arithmetic against real Foundation. View bodies are
  parse-checked only.
