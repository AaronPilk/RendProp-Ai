# Handoff from p12-E (networking / uploads / auth) — 2026-09-04

Everything below needs a file this branch does not own. Nothing here is
blocking for the p12-E merge itself; items 1 and 2 are the money ones.

---

## 1. `ai-photo` / `ai-video`: refund the quota when the provider call fails
Owner: whoever holds `services/supabase/functions/ai-photo/` and `ai-video/`.
Finding: **F-E-16** (residual). The helper-mode half is already fixed
(`guardHelper` has its own burst meter and never touches the monthly one).
What is still open: `guardEdit` / `guardGenerate` bump the monthly meter
immediately *before* the billable call, so a 502 from Gemini or fal leaves the
org one AI photo edit — or one $3.60 Topaz allowance — poorer for a request
that produced nothing.

The primitive now exists on this branch: `refundRateLimit()` in
`services/supabase/functions/_shared/ratelimit.ts`, backed by `refund_rate()`
in `migrations/0014_upload_idempotency_and_quota_refunds.sql`. It subtracts
inside the charge's own window and floors at zero, so it can neither mint free
allowance in a later window nor drive a counter negative, and it never throws.

**ai-photo/index.ts** — the monthly key is `aiphotomo:${orgId}` with
`MONTH_SECONDS`. Wrap the Gemini call:

```ts
import { durableRateLimit, refundRateLimit } from "../_shared/ratelimit.ts";

// guardEdit already ran; orgId is the one it charged.
try {
  const res = await fetch(url, { /* Gemini */ });
  // ...existing 502 throws for !res.ok and for "no image in the response"
} catch (e) {
  // The charge bought nothing: give it back before surfacing the error.
  await refundRateLimit(`aiphotomo:${orgId}`, MONTH_SECONDS);
  throw e;
}
```

`guardEdit` currently returns `void`; have it `return orgId` (as
`guardGenerate` already does) so the handler has the org to refund.

**ai-video/index.ts** — `guardGenerate` returns `orgId`; the monthly key is
`` `${meterKeyFor(kind)}:${orgId}` ``. Refund on any non-2xx from the fal
*submit* only. Do **not** refund once fal has accepted the job: at that point
the money is spent whatever happens next, and refunding would hand out a free
generation for every job that fails downstream.

Do not refund the burst meters (`aiphoto:` / `aivideo:`) — those are abuse
control, not allowance.

## 2. `ai-photo` / `ai-video`: write a `cost_ledger` row after a successful call
Owner: same two functions (plus `_shared/ledger.ts` + a migration if the RPC
signature has to change). Finding: **F-E-15** (residual).

Neither AI route logs cost, so `/me`'s "AI spend this month" is $0 for every
app-driven generation, and — the part that matters more — the per-org monthly
COGS ceiling enforced inside `log_job_cost()` never sees app AI at all. The
monthly feature meters are today the *only* thing standing between a plan and
an unbounded provider bill.

`logCost()` cannot be used as-is: it requires a `job_id` and app AI has no
render job. Either add an org-scoped overload of `log_job_cost` (job null,
org_id required, same cap check) or add a sibling RPC. The measured unit costs
are already in `_shared/entitlements.ts`.

## 3. `/ai-*`: make a repeated Idempotency-Key REPLAY, not 409
Owner: `ai-photo/` + `ai-video/`. Finding: **F-E-06** (residual).

Both routes treat a repeated key as a duplicate to reject
(`durableRateLimit("aipidem:…", 1, 120)` → 409 "Duplicate submission"). That
stops a double-tap from billing twice, which is good, but it does **not**
recover a lost response: the request was charged, the provider ran, and the
client that retries gets a 409 and no result. For `/ai-video` that is a fal
job the app can never poll — `request_id` / `status_url` are gone.

Fix shape: persist the 202 body keyed by `(org_id, idem)` for ~24 h and return
it verbatim on a repeat, instead of 409. `/ai-photo` is harder (the response is
a multi-MB image) — either store it in R2 under a short-lived key or accept
409 there and treat `/ai-video` as the one that must replay, since that is
where a single lost response can cost $3.60.

Until that lands, `LiveAPIClient` deliberately does **not** send a derived key
on the `/ai-*` submit routes (see `Idempotency.perAttempt`): a deterministic
key there would convert a legitimate re-roll into a hard 409 without buying
back a single lost response.

## 4. `SettingsView` AI Photo Studio: pass a per-tap idempotency key
Owner: `Screens/SettingsView.swift` (~line 1287). Finding: **F-E-06**.

Every other AI call site mints one `tapKey` per user tap and passes it
(`FlythroughDetailView` 2162 / 2293 / 3731, `RendpropApp` 986). The loose
"AI Photo Studio" edit does not:

```swift
var request = AIPhotoEditRequest(imageBase64: jpeg.base64EncodedString(),
                                 mime: "image/jpeg",
                                 edit: selectedEdit.rawValue)
request.style  = selectedEdit == .stage ? selectedStyle.rawValue : nil
request.prompt = selectedEdit == .custom ? prompt : nil
request.idempotencyKey = UUID().uuidString   // ← ADD: one key per tap
let result = try await model.api.aiPhotoEdit(request)
```

Mint it where the tap is handled (a `let tapKey = UUID().uuidString` at the top
of the button action), not inside the retry, or it defeats itself.

## 5. `FlythroughDetailView.makeClip` — reel batch keys
Owner: `Screens/FlythroughDetailView.swift:4458`. Finding: **F-E-06**, minor.

`makeClip` passes `idempotencyKey: UUID().uuidString`, which is right for a
batch (each clip is a different logical operation) but means a lost response on
one clip's submit is an orphaned, billed fal job. If the batch ever gains a
retry, key it `"reel:<listing>:<clip index>:<batch id>"` instead.

## 6. `beginPhotoBatch` still has no caller
Owner: the Photo Studio save path (`Screens/`). Finding: **F-E-08** (residual).

`UploadManager.beginPhotoBatch(listingID:fileURLs:)` and
`photosDidCompleteNotification` are implemented, tested against the server
contract and unreferenced. The poster half of F-E-08 is wired
(`uploadPoster` → `publish-app.poster_asset_id`), so hosted tours have a
poster; the listing *photo gallery* still never leaves the device. Wiring is:
`ensureServerListing` → `beginPhotoBatch(listingID: serverID, fileURLs:)` →
observe `photosDidCompleteNotification` → `PATCH /listings/<serverID>
{ main_photo_key: … }`. Note the server still has no endpoint that inserts
`photos` rows — that is a backend item, not an app one.

## 7. `X-Org-Id` is still never sent
Owner: `me/index.ts` (return `memberships[]`) + `Screens/SettingsView.swift`
(workspace picker). Finding: **F-E-23**.

`_shared/supabase.ts` already reads `x-org-id` and verifies membership
(`orgForUser(userId, preferredOrgId)`), and `cors.ts` already allows the
header. What is missing is a way for the user to *choose*: a user in two
workspaces publishes into whichever membership ranks highest. The client half
is a two-line change in `LiveAPIClient.makeRequest` once `/me` returns the
memberships and `AuthStore` persists a chosen org id — deliberately not added
here, because a header with no picker behind it can only be wrong.

## 8. Ops
- Apply `services/supabase/migrations/0014_upload_idempotency_and_quota_refunds.sql`
  **before** deploying the `uploads` function. The function tolerates the
  column being absent only in the sense that the insert would fail — do not
  deploy it against a pre-0014 database.
- If another branch also lands a `0014_*.sql`, renumber this one; nothing in it
  depends on the number, only on running after 0011.
- Re-run `tests/invariants.sql` after 0014 (it touches no entitlement rows, so
  it should be a no-op for that suite).

## 9. Agent-card headshot still never leaves the device
Owner: `me/index.ts` (needs a route) + `Screens/SettingsView.swift`. Finding:
**F-E-09** (residual).

The half that was fixed is the destructive one: `syncToBrandKit` now only
pushes the card whose `SpaceType` is the org's primary, so opening the
Restaurant profile no longer overwrites the real-estate agent card. Still
open: the headshot the editor's footer promises buyers will see
(`AgentCard.headshotURL`) is a local file, `brandFields` never includes
`headshot_url`/`avatar_url`/`title`, and `POST /uploads` requires a
`listing_id`, so there is no org-level image path at all. Hosted tours show
initials.

Needs a `POST /me/avatar` (ticket into the public bucket, then write
`brand_kit.headshot_url`), then a call from `AgentCardEditorView` when the
picker changes.

## 10. Watch out if `/listings` ever starts honouring Idempotency-Key
`POST /listings` ignores the header today, and `LiveAPIClient` now sends a
derived one (route + body digest) on every write. If the backend adds replay
there, two genuinely distinct listings created with an identical body — same
address, no price, e.g. two units in one building entered back to back —
would share a key and the second would replay the first. Either scope the
server's replay window tightly, or have `AppModel` pass the local
`Listing.id` as the key (`"listing:<local uuid>"`), which is the real
per-operation identity.
