# iOS privacy/hygiene audit fixes — 2026-09-07

Branch `fix/ios-privacy` off `integrate/1.0.1`, worktree only (no push). Build 5
is already in App Review; nothing here assumes build 5 contains any of this —
these fixes ship in 1.0.1 on top of it. **No Swift compiler was available in
this environment.** Every file below was fixed by reading the surrounding
code closely and mirroring its existing patterns exactly (types, access
levels, actor isolation, error handling) rather than guessing at syntax. Each
section says explicitly what is and is not verified beyond that.

---

## 1. Exact coordinates leaving the device (audit P0-6)

**(a) `geocodeIfNeeded()` now stores the same precision the API uses.**
- `apps/ios/Rendprop/Screens/FlythroughDetailView.swift:1340-1344` — the
  forward-geocode result is now rounded with `coarseCoordinate()` before
  `model.setCoordinate(...)` is called, so full precision never reaches the
  model. (Previously: `model.setCoordinate(lat: c.latitude, lon:
  c.longitude, for: id)` — the exact geocoded fix, unrounded.)
- `coarseCoordinate` is a top-level `internal` function in
  `Networking/LiveAPIClient.swift:19` (no access modifier), and
  `Screens/NewListingView.swift:272-273` already calls it directly with no
  import — confirms it's visible from `Screens/` without any new import.
  Not independently verifiable without a compiler, but this is an existing,
  already-working call pattern in the same target (see `apps/ios/project.yml`
  — one `Rendprop` app target, no submodules), not something new.

**(b) "Open in Maps" now opens by address, not precise `ll=`.**
- `apps/ios/Rendprop/Screens/FlythroughDetailView.swift:1044-1064` (doc
  comment + `mapsURL(_:)`). Verified against Apple's Maps URL Scheme
  reference: `address` is a standalone parameter ("displays a specified
  location without performing a search", does not require `q`), and `ll`
  takes precedence over `address` if both are present — so the fix sends
  **only** `address=<the listing's typed address>` when there is one, and
  falls back to `ll=<coarseCoordinate(lat)>,<coarseCoordinate(lng)>` (never
  the raw on-device coordinate) only when the address is blank. Example:
  `https://maps.apple.com/?address=1%2C%20Infinite%20Loop%2C%20Cupertino`.
  Built with `URLComponents`/`URLQueryItem` exactly as the code already did
  (same percent-encoding mechanism as before, just a different parameter) —
  the lowest-risk way to change this that I could find.

**(c) Comments and docs corrected to say what the app actually does — and
one thing I want to flag clearly:**

Rounding to 3 decimal places (~110 m) does **not** make this "Coarse
Location" under Apple's own privacy-label rules. I found this out by reading
`apps/ios/Rendprop/PrivacyInfo.xcprivacy` itself, which already declares
`NSPrivacyCollectedDataTypePreciseLocation` (not Coarse) with a comment
quoting Apple's definition verbatim: "Precise Location [is] the same or
greater resolution as a latitude and longitude with three or more decimal
places." Three decimals is exactly what both coordinate sources produce. So:
- The `coarseCoordinate` doc comment in `Networking/LiveAPIClient.swift:1-15`
  used to say "the privacy manifest declares CoarseLocation, not precise" —
  this was backwards from the actual manifest and from Apple's own
  threshold, so I rewrote it to say the opposite, explicitly: rounding is
  data minimization, not a reclassification, and the manifest correctly
  stays Precise either way.
- `apps/ios/Rendprop/PrivacyInfo.xcprivacy:90-96` — updated the Location
  entry's comment to say **both** sources (Core Location fix, forward
  geocode) are now rounded to 3 decimals before storage, not just the first
  one. The declared type (`NSPrivacyCollectedDataTypePreciseLocation`) is
  unchanged — that was already correct and still is.
- `docs/appstore/privacy-labels.md` — updated the Precise Location row (§1)
  to match, and added a note that "Open in Maps" now uses the address with a
  rounded fallback, never a raw coordinate.
- **`services/edge/tour-host/src/legal.ts`** (the actual privacy-policy page
  — `grep -rl privacy services/edge/tour-host/public` turns up only pages
  that *link* to `/privacy`; the content itself is server-rendered from this
  file, not a static file under `public/`) — I read `privacyPage()` in full.
  It already says "an approximate (rounded) map coordinate" in plain
  consumer language, which stays true after this fix and doesn't use Apple's
  Precise/Coarse taxonomy at all. **I made no changes here** — nothing in it
  became wrong.

Not verified without a compiler: that `coarseCoordinate(_:)` resolves from
`Screens/FlythroughDetailView.swift` and `Screens/NewListingView.swift`
without an import (argued above from existing usage, not compiled).

---

## 2. Audio collected but not declared (Speech recognition)

**The truth, established by reading the code (not assumed):**
`Voice/SpeechTranscriber.swift:142` sets
`request.requiresOnDeviceRecognition = onDevice` where `onDevice =
recognizer.supportsOnDeviceRecognition` — recognition is **not** forced
on-device. A device/locale without an on-device model gets `false`
immediately (`SpeechTranscriber.swift:106-159`), and even a device that
supports on-device recognition retries once with `false` if the on-device
attempt fails (`SpeechTranscriber.swift:149-153`). Apple's own docs for
`requiresOnDeviceRecognition` say `true` is what "prevent[s] ... sending
audio over the network" — so `false` sends it. `Info.plist:63`'s own
`NSSpeechRecognitionUsageDescription` already tells the user this: "otherwise
the recording is sent to Apple's speech recognition service." Rendprop's own
backend is not part of this path — `SpeechTranscriber` only calls Apple's
`Speech` framework; only the transcript text comes back into the app.

Conclusion: audio **is** collected as Apple defines it (it leaves the device
to a third party under real conditions), so I added the declaration rather
than only touching docs.

**Edits:**
- `apps/ios/Rendprop/PrivacyInfo.xcprivacy:61-83` — new
  `NSPrivacyCollectedDataTypeAudioData` entry: Linked=true, Tracking=false,
  Purpose=AppFunctionality, with a comment laying out the evidence above and
  explaining why the video-embedded copy of the same recording (once a reel
  is published) is *not* double-declared — that's already covered by
  `NSPrivacyCollectedDataTypePhotosorVideos`.
- `docs/appstore/privacy-labels.md` — moved Audio Data from the "No" table
  (§2) to the "Collected" table (§1), left a breadcrumb in the old row, and
  added a new §6 with the full reasoning and evidence chain so the App Store
  Connect answer and the manifest agree.

**One judgment call, flagged for the app owner rather than silently
decided:** I declared this entry `Linked: true`, matching every other row in
this manifest (there is currently no `Linked: false` row anywhere in it) and
on the reasoning that it's a specific signed-in user's own voice against
their own listing. Whether Apple's Speech framework itself ties the
recognition request to the user's Apple ID is Apple's practice, not
something this app's code controls — if the owner's own read of Apple's
guidance differs, this is the field to revisit, not whether to declare Audio
Data at all (the evidence for "collected: yes" is solid independent of the
Linked question).

Not verified without a compiler: nothing new was added to Swift code for
this item — only the `.xcprivacy` (XML, validated well-formed with Python's
`xml.dom.minidom` — see below) and a doc.

---

## 3. Internal COGS strings compiled into the shipped binary (P0-5 residual)

Chose **plain string-content replacement** over the two options the brief
offered (non-numeric placeholders, or compiling the file only into test
configurations). Reasoning: `Config.swift:92-98`
(`Config.makeAPIClient()`) references `MockAPIClient()` **unconditionally**
from the main app target (used both for `-uiTesting` and as the
live-client-construction-failure fallback) — moving `MockAPIClient.swift`'s
compilation to test-only would leave that reference dangling in a Release
build (the archive/App-Store configuration — `apps/ios/project.yml`'s
`archive: config: Release`) unless `Config.swift` were also rewritten with a
different Release-time fallback, which is a bigger and riskier change than
asked for here. Plain string replacement carries no such risk: it's a
content-only change, no new build-configuration logic, and
`test: config: Debug` in `project.yml` is untouched either way, so UI-test
behavior cannot change.

Went beyond the two line numbers named in the brief (`~239`, `~268`) because
`grep` for `\$[0-9]` across the whole file surfaced a few more instances of
the exact same pattern — this is called a "P0-5 **residual**", so I treated
that as a signal to actually clear the pattern rather than patch only the
literally-cited lines and leave siblings behind again.

**Edits (all string-literal content only — no structural changes):**
- `Networking/MockAPIClient.swift:248` — `"docs/AI-COST-MODEL.md §1 — ~$0.24
  / 5s clip"` → `"docs/AI-COST-MODEL.md §1"`
- `Networking/MockAPIClient.swift:254` — `"...— ~$0.04/img"` → `"...§1"`
- `Networking/MockAPIClient.swift:266` — `"...§3 — $1/$5 per 1M tokens,
  cached"` → `"...§3"`
- `Networking/MockAPIClient.swift:278` — `"...— ~$0.09/img via KIE"` →
  `"...§1 — via KIE"` (kept the routing note, dropped the figure)
- `Networking/MockAPIClient.swift:291` — `"...§3 — $0.001/min watched"` →
  `"...§3"`
- `Networking/MockAPIClient.swift:651` — `"4.1c is the medium-quality 1024
  floor — higher quality costs more"` → `"This is the medium-quality..."`
- `Networking/MockAPIClient.swift:768` — `"$1.20 a world is a COGS hole..."`
  → `"This is a COGS hole..."`

**Left untouched, deliberately:**
- Every `unitCostCents`/`unitCents`/`spendCents` numeric (`Double`) literal
  in the same file (e.g. `unitCostCents: 3.9`, `unitCents: 4.8`). The audit
  finding is specifically about `strings`-the-binary exposure, and a
  `Double` constant is an 8-byte binary float, not an extractable ASCII
  string — `strings` won't surface "$0.24" from it the way it does from a
  `String` literal. These numbers also drive the mock's own screenshot/UI
  behavior (budget bars, spend totals) more directly than the citation
  strings did, so leaving them alone is also the lower-risk choice for "does
  not change UI-test behaviour."
- `Networking/MockAPIClient.swift:432` ("...to the per-org monthly **COGS
  ceiling**. Real spend is HIGHER...") — describes a tracking *gap*, not a
  cost figure; no dollar amount to redact.
- `Networking/MockAPIClient.swift:303` ("No committed price in the repo for
  this SKU.") — already says the opposite of a leak.

**Verified by grepping every string I touched** (per the brief's own
instruction) — none of the seven original strings appear anywhere else in
`apps/ios` (app code or `RendpropUITests`), so no test asserts on their
exact text and nothing else references them:
```
grep -rn '\$0\.24 / 5s clip|\$0\.04/img|\$0\.09/img via KIE|4\.1c is the medium|\$1\.20 a world|\$1/\$5 per 1M tokens|\$0\.001/min watched' apps/ios
→ only apps/ios/Rendprop/Networking/MockAPIClient.swift (before this fix)
```

Not verified without a compiler: nothing structural changed, so there is
very little to be unsure of here — the diff is seven string literals with
identical surrounding syntax.

---

## 4. Deletion UI fail-open + analytics device id surviving a wipe (P0-4)

**(a) `cleanup_complete` now defaults to false.**
- `apps/ios/Rendprop/Screens/SettingsView.swift:728` —
  `return decoded.cleanupComplete ?? false` (was `?? true`). A server
  response that omits the field is now read as "cleanup still pending" (the
  UI shows the honest background-cleanup message,
  `SettingsView.swift:423-425`), never as silent full success. I deliberately
  did **not** make `cleanupComplete` a non-optional/required field in
  `ServerDeleteResponse` (`SettingsView.swift:690-697`) — that would fail the
  *entire* decode (and therefore report the account deletion itself as
  failed) on a response that omitted only this advisory flag, which is a
  worse and different failure mode than what was asked. `ok` (already
  required) continues to gate whether the deletion itself succeeded;
  `cleanup_complete` only ever governed which success message to show.

**(b) Analytics device id is cleared and regenerated on every wipe.**
- `apps/ios/Rendprop/Analytics/Analytics.swift:263-278` — new
  `Analytics.resetDeviceIdentity()`, which reassigns the in-memory `deviceID`
  cache, not just the on-disk stores. This matters because `Analytics.start`
  only loads `deviceID` once per process (idempotent past the first call,
  `Analytics.swift:133-148`) — clearing only the Keychain/UserDefaults
  without also updating the cached value would still leak the old id into
  every event tracked later in the *same* process (e.g. delete account A,
  sign in as B, all without an app relaunch — exactly the scenario the audit
  describes).
- `apps/ios/Rendprop/Analytics/Analytics.swift:399-406` — new
  `DeviceIdentity.reset() -> String`: deletes the Keychain item and the
  UserDefaults fallback, then calls the existing `load()` (unmodified),
  which mints and persists a fresh UUID via the exact same code path a
  genuine first launch uses.
- `apps/ios/Rendprop/Analytics/Analytics.swift:460-463` — new private
  `keychainDelete()` (`SecItemDelete`), mirroring `keychainWrite`'s existing
  style in the same nested type.
- `apps/ios/Rendprop/Screens/SettingsView.swift:819-823` (write-location
  checklist) and `:903-908` (the wipe itself, new step 6) — calls
  `Analytics.resetDeviceIdentity()` as part of `wipeLocalData()`, which both
  `deleteAccount()` and `clearLocalDataTapped()` already call. The checklist
  comment at the top of `wipeLocalData()` explicitly says "keep in sync; add
  a line when you add a writer" — updated it accordingly.

**Minor residual I noticed but did not fix** (out of scope for what was
asked, flagging for the owner): `Analytics.queue` — the in-memory array, as
opposed to its on-disk mirror — is not cleared by the wipe (the on-disk
`Application Support/Analytics/queue.json` *is* wiped wholesale by the
existing step 3). Any events queued in memory but not yet flushed before a
wipe would still be sent after it, now tagged with the *new* device id. This
is low-severity: those events carry no PII by this file's own architecture
(`Analytics.swift:13-23`), the account is signed out before any such flush
could run (so nothing ties them to an account server-side), and clearing
`Analytics.queue` too wasn't part of what was asked — but it's a one-line
follow-up if the owner wants belt-and-suspenders here (`queue.removeAll()`
inside `resetDeviceIdentity()`).

Not verified without a compiler: that a `private enum DeviceIdentity` nested
inside `@MainActor enum Analytics` behaves the same way for my new `reset()`
method as it already does for the existing `load()` method it sits beside
(same file, same nesting, same non-actor-touching implementation — I did not
invent a new isolation pattern, I mirrored the existing one exactly).

---

## 5. Direct API paths don't retry a 401 (finding 8)

**Mandatory: the Apple auth-code path.**
- `apps/ios/Rendprop/Auth/AuthStore.swift:65-69` — new
  `Keys.pendingAppleAuthCode` constant.
- `apps/ios/Rendprop/Auth/AuthStore.swift:502-524` —
  `submitAppleAuthorizationCode(_:isRetry:)` now persists the code to the
  Keychain (via the file's existing `SecureStore` — same primitive
  `storedAccessToken`/`storedRefreshToken` already use) **before** the
  network call, and only clears it once the server confirms a 2xx. A crash
  mid-flight, not just a thrown error, is now covered, since the code is
  durable before the request ever goes out.
- `apps/ios/Rendprop/Auth/AuthStore.swift:526-533` — new
  `retryPendingAppleAuthorizationCodeIfNeeded()`, a no-op when nothing is
  pending. Retries **exactly once**: the retry attempt clears the pending
  record regardless of outcome, because Apple's authorization code is
  single-use and short-lived — holding it for a third attempt on some later
  launch would just keep re-submitting an already-expired code forever
  rather than buying a real second chance.
- `apps/ios/Rendprop/RendpropApp.swift:1474-1478` — wired the retry into app
  launch as a second `.task {}` alongside the existing
  `.task { Analytics.start(...) }`. Existing call site
  (`Screens/RenderStatusView.swift:652`) is untouched — the new `isRetry`
  parameter defaults to `false`.

**Also fixed, judged small and safe** (mirrors the *already-existing*
`LiveAPIClient.execute()` pattern at `Networking/LiveAPIClient.swift:196-211`
almost verbatim, using only symbols each file already referenced):
- `apps/ios/Rendprop/Purchases/PurchasesAPI.swift:162-183`
  (`PurchasesRequest.post`, the `/me/entitlement` StoreKit-sync call) — retry
  once on 401 with a forced-fresh token. Safe to retry: the Idempotency-Key
  (`PurchasesAPI.swift:153-154`) is derived from the request body alone, so
  a retry replays server-side rather than risking a second entitlement
  write — the file's own comment already says this is the intended behavior
  for retries.
- `apps/ios/Rendprop/Screens/AdminFunnelView.swift:187-206`
  (`adminFunnel`, `GET /admin/funnel`) — same retry-once-on-401. Lower risk
  still, since a GET has no side effects to worry about replaying.

**Deliberately not touched, with reasons:**
- `Auth/AuthStore.swift` `performRefresh()` (the refresh-token POST itself)
  and `exchangeAppleIdentityToken()` (the initial sign-in exchange) — a 401
  from either of these *is* the definitive rejection (dead refresh token, or
  a bad sign-in credential); there is no "further" token to refresh with
  before retrying, so the retry-once pattern doesn't apply. Both already
  handle their failure explicitly (`performRefresh` signs out on
  400/401/403; `exchangeAppleIdentityToken` throws a decoded GoTrue error).
- `Screens/SettingsView.swift:715` (`requestServerAccountDeletion`, `DELETE
  /me`) — also a direct call with no auto-retry, but out of the three
  categories named ("purchase/admin/Apple-code"). Structurally identical fix
  would apply here too if wanted later: it already has a user-facing manual
  "Retry" button on failure (`SettingsView.swift:415`), which is a real
  (if not automatic) recovery path the Apple-code and admin/purchase routes
  didn't have — so leaving it as-is is a materially smaller gap than the
  ones fixed above.
- `Analytics/AnalyticsAPI.swift:108` and `Gear/GearStore.swift:232` — neither
  is a purchase/admin/auth route; analytics is explicitly designed to fail
  silently and never cost the user anything (`Analytics.swift:42-47`), and
  the gear catalog is a public, unauthenticated JSON fetch with no JWT
  involved at all.

Not verified without a compiler: `AuthStore.shared.isSignedIn` and
`AuthStore.shared.forceRefresh()` are used inside `PurchasesAPI.swift` and
`AdminFunnelView.swift`, neither of which is `@MainActor`-isolated, calling
into `AuthStore` (a plain `final class`, not globally `@MainActor` — only
specific methods on it are annotated `@MainActor` individually). This is the
*exact same expression*, copied verbatim, as the one already sitting in
`LiveAPIClient.swift:196-197`, in a file with the same `SWIFT_VERSION: "5.9"`
setting (`apps/ios/project.yml`) — Swift 5 language mode, not Swift 6 strict
concurrency — so if the original compiles clean today, the copy should too.
I did not invent a new concurrency pattern here, only reused the one already
shipping.

---

## Mechanical checks actually run (no compiler, but not nothing)

- Brace/paren counts before vs. after on every touched Swift file — all
  balanced except `FlythroughDetailView.swift`, which has a pre-existing
  off-by-one paren count (confirmed present in the `git show HEAD` version
  *before* any of my edits, from a comment or string elsewhere in this
  7000-line file) that my edits carried through unchanged (+8/+8, not +8/+9).
- `PrivacyInfo.xcprivacy` parsed successfully with Python's
  `xml.dom.minidom`, and a structural check confirms exactly 14
  `NSPrivacyCollectedDataType` entries (13 before this branch + the new
  Audio Data one), all as `<dict>`/`<key>`/`<string>`/`<array>` shapes
  matching the existing entries.
- Grepped every string literal I edited or removed across all of `apps/ios`
  to confirm no other file (including `RendpropUITests`) references the
  exact old text.

**What no amount of grepping substitutes for:** actual compilation and the
UI-test run itself. Everything above is written to match this codebase's
existing idioms as closely as possible, but the owner should do one
`xcodebuild build` and one `xcodebuild test -only-testing:RendpropUITests`
(or the bridge command this repo already uses for that) before merging.
