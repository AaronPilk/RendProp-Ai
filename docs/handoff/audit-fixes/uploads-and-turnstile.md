# Audit fixes — content-type smuggling, Turnstile fail-open, beacon replay

Branch `fix/uploads-and-turnstile` off `integrate/1.0.1`. Three defects from an
external release audit, fixed in place. No schema/migration changes — every
fix is application-layer.

Test counts (see §4): **28 new tests, 0 failing · 163/163 total passing** across
`services/supabase/functions` · `deno check` clean on every file touched.

---

## 1. Content-type smuggling through MIME normalization (audit P0-2 residual)

**Where:** `services/supabase/functions/uploads/index.ts`, plus the parsing
logic pulled out to `services/supabase/functions/uploads/content_type.ts`
(new) so it has direct unit tests.

**The defect.** `mediaType()` (old, ~line 195) stripped everything from the
first `;` onward before checking the allowlist, and was used for BOTH the
client's declared `content_type` (ticket creation) and the server-observed R2
Content-Type (at `/complete`). So `{"content_type":"image/jpeg;evil"}`
normalized to `"image/jpeg"`, passed the allowlist, and got stored as a clean
declared type — while the file's own comment claimed `"video/mp4;evil"` "must
not launder into video/mp4." The implementation did exactly that.

**The fix — two parsers for two trust levels, per RFC 9110 §8.3.1** (see
`content_type.ts` header for the full reasoning):

| Function | Used for | Behavior |
|---|---|---|
| `requireBareContentType(raw, field)` (`content_type.ts:78`) | The CLIENT's declared `content_type` — `POST /uploads` (`index.ts:707`) and `POST /uploads/batch` (`index.ts:375`, one call per `files[i]`) | Must be a bare `type/subtype`. A `;`, any whitespace, or a malformed shape is a **400 naming the exact field** (`content_type`, or `files[3].content_type`). Case is folded (`IMAGE/JPEG` → `image/jpeg`), nothing else is forgiven. Never truncates — always rejects outright. |
| `baseMediaType(raw)` (`content_type.ts:102`) | The server-OBSERVED R2 Content-Type at `/complete` (`index.ts:590-591`, `observedType`/`declaredType`) and the stored value re-read in `ticketMatches` (`index.ts:927`) | Strips a parameter (e.g. `; charset=utf-8`), trims, lower-cases. This is legitimate here — and NOT the laundering bug — because the presigned PUT URL never binds Content-Type (`r2.ts` — aws4fetch's `signQuery` signs only `host`), so this header is a FACT about the object the client does not get to shape, and it is compared against a declared type that can no longer itself carry a parameter (closed by `requireBareContentType` above). |
| `isContentTypeDeclared(raw)` (`content_type.ts:65`) | Both entry points | Distinguishes "not declared" (blank/absent → server default) from "declared invalid" (→ 400). Unchanged in effect from before, factored out for reuse. |

The `/complete` comment (`index.ts:558-589`) was rewritten to describe this
honestly instead of repeating the old, false "must not launder" claim without
backing it. The comment in the file's changelog block (`index.ts:70-95`) has
the full before/after.

**Overcharge (the audit's second point on this route).** Budget was charged
(`chargeUploadBudget`) BEFORE the `capture_assets` insert in all three
ticket-creation paths (`POST /uploads` single, `POST /uploads` multipart,
`POST /uploads/batch`), so a later DB or R2 failure burned the org's daily
ticket/byte allowance for an asset that never came to exist. Fixed by
refunding rather than restructuring the charge order (the codebase already has
this exact pattern in `ai-chapters/index.ts` and `ai-voice/index.ts` via
`refundRateLimit` — `_shared/ratelimit.ts:68`):

- `refundUploadBudget(orgId, fileCount, totalBytes)` (`index.ts:248`, new) —
  the inverse of `chargeUploadBudget`, best-effort, never throws.
- `POST /uploads` (single + multipart): everything from right after the charge
  (`index.ts:733`) through the response is now in a `try { … } catch (e) {
  await refundUploadBudget(...); throw e; }` (`index.ts:736-857`). The two
  places that lose an Idempotency-Key race and relay a CONCURRENT ticket
  instead of minting their own (`index.ts:792`, `index.ts:832`) explicitly
  refund before returning 200, since a `return` doesn't hit the `catch`.
- `POST /uploads/batch`: the per-file insert loop is wrapped the same way
  (`index.ts:382-424`) — on any file's failure, the FULL batch charge is
  refunded (matches what the client actually got: an error, not partial
  assets) and the error is rethrown.
- `chargeUploadBudget` itself (`index.ts:214`) now refunds the ticket-count
  charge if the byte-budget charge then fails, so a byte-capped org never
  ALSO loses a ticket for a request that was about to be rejected anyway.

**Left as documented, not restructured:** a batch whose Nth file fails still
leaves files `0..N-1`'s `capture_assets` rows inserted in the database (each
one real and valid) even though the refunded charge and the 400 response
together mean the client is told the whole batch failed and gets no asset
ids back. Those rows cost no R2 storage (a row alone doesn't stage bytes) and
are the same shape as any other abandoned `uploaded=false` ticket already
tolerated elsewhere in this file — reconciling that would mean either
per-file transactions or an explicit cleanup pass, which is a batch-route
restructuring beyond this fix's scope. Documented here rather than silently
left as a surprise.

### Verification

- `deno check services/supabase/functions/uploads/index.ts
  services/supabase/functions/uploads/content_type.ts` — clean.
- `deno test services/supabase/functions/uploads/content_type.test.ts` — 16/16
  passing, covering exactly the cases asked for: a bare allowed type; an
  allowed type with a parameter (rejected, field named in the message); a
  disallowed-but-well-formed type (parses at this layer — the allowlist is a
  separate check in `validateFileMeta`); an observed type with `charset=` at
  completion (`baseMediaType`, accepted after parsing); case differences
  (`IMAGE/JPEG` → `image/jpeg`); and leading/trailing whitespace (rejected,
  not trimmed) — plus a no-slash value, internal whitespace, and an
  end-to-end round-trip proving a clean declared type is never re-laundered.
- The overcharge/refund wiring was verified by `deno check` (type-correctness
  of every new call site) and by tracing each failure path by hand (listed
  above); it is **not** covered by an automated test. Exercising it for real
  needs a live `bump_rate`/`refund_rate` Postgres RPC plus R2 HTTP calls
  (`createMultipartUpload`, `presignPut`) — this repo's existing test pattern
  for a `Deno.serve` route (`admin/funnel.test.ts`) stubs `globalThis.fetch`
  for a single RPC call; extending that to uploads' full ticket-creation flow
  across R2 + Supabase together would be a materially larger effort than this
  fix, so it was left as a documented gap rather than rushed.

---

## 2. Turnstile fails open when unconfigured

**Where:** `services/supabase/functions/leads/index.ts`, verification logic
moved to `services/supabase/functions/leads/turnstile.ts` (new).

**The defect.** `verifyTurnstile()` (old, ~line 44) returned `true` when
`TURNSTILE_SECRET_KEY` was unset — "not configured yet, don't block." The
public lead form (`POST /leads`) therefore had no bot protection beyond the
honeypot until someone remembered to set the secret, and nothing said so at
runtime.

**Environment check (as asked).** Grepping `_shared/` for how this codebase
distinguishes environments turned up no `NODE_ENV`/`DENO_ENV`-style switch at
all — the actual convention for a required secret is "the secret's absence
IS the signal, and the code names it": `_shared/r2.ts`'s `endpoint()` throws
`"Missing env var: CLOUDFLARE_ACCOUNT_ID"`, `_shared/providers/gemini.ts`'s
`geminiKey()` throws `"GEMINI_API_KEY function secret is not set"`, etc. The
fix follows that same convention rather than inventing a new one.

**The fix** (`turnstile.ts:44-73`, `verifyTurnstile`):

- Secret set + valid token → `true` (unchanged).
- Secret set + bad token, or the verify call itself errors → `false`
  (unchanged).
- **Secret missing → `false` (fails CLOSED)** — the submission is rejected
  with `403 "Bot check failed — please retry the form."`
  (`leads/index.ts:199-201`, unchanged wording — deliberately generic to a
  public caller; the diagnostic detail goes to the log, not the response).
- **Escape hatch:** `TURNSTILE_OPTIONAL=1` (exact literal `"1"` — nothing else
  opts out) makes a missing secret answer `true` instead — what a local dev
  box with no Cloudflare account, or a production deploy that has knowingly
  chosen to launch without Turnstile, sets on purpose.
- **Either way, one unmistakable `console.error` naming
  `TURNSTILE_SECRET_KEY`** is logged on every request while the secret is
  missing — not once at deploy time, and not only on the rejected path: the
  opt-out is logged too, so an operator who left it unset cannot miss it in
  the function logs regardless of which behavior resulted.

**Docs updated** (as asked — "document the new env var… add it to whatever
launch checklist lists required secrets"):

- `services/supabase/functions/leads/README.md` (new) — full explanation,
  the exact log lines, and the deploy command.
- `services/supabase/functions/README.md` — the `TURNSTILE_SECRET_KEY` secrets
  table row rewritten from "optional" to "required (fails closed)"; new
  `TURNSTILE_OPTIONAL` row added.
- `services/supabase/DEPLOYMENT.md` — secrets reference line + a called-out
  paragraph on the behavior change.
- `services/supabase/set-secrets.sh` — `TURNSTILE_SECRET_KEY` changed from an
  `OPTIONAL_BLANK` placeholder to a `PASTE_...` one (matching every other
  required secret in that script), `TURNSTILE_OPTIONAL` added, and the
  top-of-file + inline comments updated (this script previously called
  Turnstile "a no-op" when blank — no longer true).
- `docs/LAUNCH-CHECKLIST.md` — item 12 marked fixed with the new behavior
  explained; "The only genuine open item" section rewritten from "add
  Turnstile" to "set the secret before launch, since the code now fails
  closed instead of failing open."

### Verification

- `deno check services/supabase/functions/leads/index.ts
  services/supabase/functions/leads/turnstile.ts` — clean.
- `deno test services/supabase/functions/leads/turnstile.test.ts` — 7/7
  passing, covering exactly what was asked (secret set + valid token, secret
  set + bad token, secret missing → rejected, secret missing + opt-out →
  allowed with a warning logged) plus three extras worth locking down: no
  token at all short-circuits before calling Cloudflare, an
  `TURNSTILE_OPTIONAL` value other than the literal `"1"` does NOT opt out,
  and a network error talking to Cloudflare fails closed.

---

## 3. Public beacon metrics are replayable

**Where:** `services/supabase/functions/beacon/index.ts`, the decision pulled
out to `services/supabase/functions/beacon/logic.ts` (new) for a direct test.

**The defect.** `bump_metering()` clamps `p_views` to `[0,1]` per call, but
nothing stopped a caller from POSTing `view_start:true` for the same tour
repeatedly — the existing per-IP rate limit (120 req/60s, `index.ts:71`)
bounds request VOLUME, not how many of those requests get to count as a NEW
view.

**(a) Cheap replay resistance — added.** A per-(IP, slug) dedupe using the
existing `durableRateLimit` helper (`_shared/ratelimit.ts`, already imported
in this file), exactly as the task suggested: `durableRateLimit(key, 1,
window)` is a one-shot-per-window gate (`bump_rate`'s own semantics — first
call in a window returns `count(1) <= max(1)` → true, every subsequent call in
the same window returns `count(2+) <= 1` → false; see migration
`0006_p0_rpcs.sql`). Wired in at `beacon/index.ts:103-106`:

```ts
const countView = await shouldCountView(
  body.view_start,
  () => durableRateLimit(`beaconview:${clientIp(req)}:${render.id}`, 1, VIEW_DEDUPE_WINDOW_SECONDS),
);
```

`shouldCountView` (`logic.ts:36`) is the pure decision — `view_start !== true`
never even calls the gate, so ordinary watch/scroll beacons (the vast
majority of traffic) do zero extra rate-limit work. `VIEW_DEDUPE_WINDOW_SECONDS
= 5 * 60` (`index.ts:62`): long enough to absorb a genuine same-session
duplicate (a reload right after load), short enough that a real return visit
later the same day still counts as a new view. This is explicitly a cheap
mitigation, not a strong one — it does not survive IP rotation or simply
waiting out the window, and it undercounts several genuine viewers behind one
IP (an office, a NAT) inside the window to one. Both limits are stated, not
hidden — see (b).

**(b) The honest caveat — written into:**

- `beacon/index.ts:12-29` — a new header section, "Honest caveat," spelling
  out exactly what the mitigation does and does not defend against.
- `docs/ADMIN-CONSOLE-CONTRACT.md` (new paragraph right after the `metering`
  row in the ledger-coverage table, the only place in that doc where view
  counts are described) — states plainly that `metering` is public,
  unauthenticated telemetry, never billing truth, and that any future console
  screen surfacing it must present it as a best-effort figure, the same way
  `total_cents`'s `coverage` object already is.
- `beacon` has no `README.md` (confirmed — the function's directory holds only
  `index.ts`), so per the task's own conditional wording ("its README if it
  has one") none was created; the header comment and the contract doc are
  the two places this lives.

### Verification

- `deno check services/supabase/functions/beacon/index.ts
  services/supabase/functions/beacon/logic.ts` — clean.
- `deno test services/supabase/functions/beacon/logic.test.ts` — 5/5 passing:
  a plain beacon (`view_start` false/absent) never counts and never calls the
  dedupe gate; `view_start:true` counts only when the gate allows it; a
  simulated replay (the gate answering true once, then false) is counted
  exactly once across three attempts; two independent gates (different
  IP/slug keys) don't interfere with each other.
- The `durableRateLimit` wiring itself (the actual Postgres-backed gate) is
  exercised by the SAME reasoning as §1's charge/refund wiring — verified by
  `deno check` and by the fact that `bump_rate`'s semantics (migration 0006)
  are unit-testable in principle but require a live Postgres instance this
  sandbox does not have; `shouldCountView`'s test simulates that RPC's
  documented behavior instead of calling it for real.

---

## 4. Test counts

```
deno test --allow-env --allow-net --allow-read <every *.test.ts under services/supabase/functions>
  ok | 163 passed | 0 failed
```

New this change: **28 tests** (`uploads/content_type.test.ts` 16,
`leads/turnstile.test.ts` 7, `beacon/logic.test.ts` 5). Pre-existing: 135,
all still green (nothing in `_shared/` was touched by this change, so no
regression was expected — confirmed by re-running the full suite, not
assumed).

`deno check` was run on every function's `index.ts` (17 functions, excluding
`_shared/`) plus every new/edited file individually — all clean.

## 5. Not done / deliberately out of scope

- **Batch route's orphaned rows on a partial failure** — see §1, "Left as
  documented, not restructured."
- **No automated test for the upload budget refund wiring** or for
  `durableRateLimit`'s real Postgres RPC in the beacon dedupe — see the
  Verification notes in §1 and §3. Both are type-checked and traced by hand;
  neither is exercised end-to-end because that needs a live Postgres +
  (for §1) R2 credentials this environment doesn't have.
- **`admin/index.ts`'s Turnstile provider-health entry** (the `PROVIDERS` list
  used by `GET /admin/providers`) was left untouched. It already reports
  Turnstile as `"unconfigured"` (not `"optional_off"`) when the secret is
  missing, which was already the honest signal on that surface — nothing
  there needed to change for this fix.
- **Historical/point-in-time docs** (`docs/AUDIT-RESPONSE-2026-08-28.md`,
  `docs/FULL-AUDIT-2026-08-26.md`) were left as-is — they're dated snapshots
  of a past audit response, not living references, so rewriting them to say
  "fixed now" would misrepresent what they are.
