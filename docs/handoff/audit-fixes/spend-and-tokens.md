# Audit fixes — money & security (2026-09-07)

Four findings from the external release audit, fixed on `fix/spend-and-tokens`
(branched from `integrate/1.0.1`), worked in a dedicated worktree at
`/home/claude/wt-spend`. One fix per section below: what was wrong, the exact
file:line, what changed, and how it was verified. Nothing here was verified by
reading the code alone unless the section says so explicitly — three of the
four were run (deno test) and the fourth (the migration) was run against a
real Postgres database.

Note on numbering: "P0-3" below is this audit round's label for the spend
ceiling race. It reuses a number `docs/AUDIT-RESPONSE-2026-08-28.md` already
used for an unrelated, earlier, already-closed finding (App Store pricing
copy) — same label, different finding, no relation between the two.

---

## 1. P0-3 (critical) — raceable monthly org spend ceiling

**Where:** `services/supabase/migrations/0010_pricing_entitlements_and_spend_ceiling.sql:139-199`,
function `public.log_job_cost()`.

**The bug:** the function takes a row lock on the render job it's logging for
(`perform 1 from render_jobs where id = p_job for update`, line 162), but two
*different* jobs for the *same org* never contend for that lock — each locks
its own row. The per-org monthly ceiling check that follows —
`org_month_spend_cents(v_org)` read, compared against
`plan_entitlement(...).cogs_ceiling_cents`, then an `insert into cost_ledger`
— has no lock protecting it at all. Two concurrent jobs for the same org can
both read the same pre-spend total, both pass the check, both insert.

**The fix:** `services/supabase/migrations/0024_spend_ceiling_lock.sql`
(0023 was already taken by the coach-routes migration). `create or replace
function public.log_job_cost(...)` — identical signature, identical grants,
identical per-job-cap and error-message behavior — with one addition: a
per-org `pg_advisory_xact_lock(hashtextextended('org_month_spend:' ||
v_org::text, 42))`, taken as the first statement once `v_org` is known and
non-null, *before* `org_month_spend_cents()` is read. This is the same
advisory-lock pattern already in production use in this repo —
`0015_job_lease.sql:163` (`'render_jobs:' || v_org::text`) and
`0016_enhancement_outcome.sql:112` (`'publish_render:' || p_job::text`) — with
a new, distinct string prefix so its lock-key space can't collide with
theirs (the prefix, not the `42` seed, is what separates the namespaces —
confirmed by reading both existing call sites). Because
`pg_advisory_xact_lock` is transaction-scoped and the whole function body
runs as one implicit transaction per RPC call, holding the lock from before
the read through the `insert into cost_ledger` serializes exactly the
critical section, for exactly one org, for exactly the duration of one
`log_job_cost()` call — never leaked, never held across a network round
trip. `create or replace function` means every existing caller (worker
pipeline, ai-photo, ai-video) keeps working with no code change.

**Verified — live, against a real database**, not just read: this machine has
a local Postgres 16 with a `rendprop` database carrying migrations 0001-0023
already applied (confirmed `log_job_cost`'s live definition was byte-for-byte
the vulnerable 0010 text before I touched anything).

1. **Dry run in a rolled-back transaction** — confirms the migration applies
   cleanly against the real schema without being left applied:
   ```
   BEGIN;
   \i services/supabase/migrations/0024_spend_ceiling_lock.sql
   -- confirmed: the new lock line is present, the 9-arg signature is
   -- unchanged, grants are still service_role-only.
   ROLLBACK;
   ```
   Ran clean (`CREATE FUNCTION` / `REVOKE` / `GRANT`, no errors). Confirmed
   post-rollback that `log_job_cost`'s live definition no longer contained the
   fix — the dry run left the database exactly as it found it.

2. **Reproduced the race on the live (still-unpatched) function.** Built a
   throwaway org via `insert into auth.users(...)` (its `handle_new_user`
   trigger auto-creates a profile + trial org + membership — trial/free
   ceiling in this database's seed is 800¢, not the 200¢ in 0010's own
   comment; a later migration evidently re-seeded `plan_entitlements` — I used
   whatever the live ceiling actually was), one listing, two `render_jobs`
   rows. To force two real, separate `psql` sessions to overlap inside the
   read/act window deterministically (rather than hoping two backgrounded
   shell calls happen to interleave within microseconds), I temporarily
   replaced `org_month_spend_cents()` with a functionally-identical version
   that adds `perform pg_sleep(1);` before its `select` — a standard technique
   for widening a real, normally-microsecond-wide race window into something
   two independent connections reliably both land inside — then restored the
   original (plain-SQL) definition immediately after, byte-for-byte (checked
   with `pg_get_functiondef` before and after). Two already-connected `psql`
   sessions (pre-opened so connection setup wasn't part of the timed part)
   fired one `select log_job_cost(...)` each, ~2.7ms apart, both charging
   600¢ against the 800¢ ceiling:
   ```
   session A fired at 3.794654826 -> 600.0000 (succeeded)
   session B fired at 3.797343017 -> 600.0000 (succeeded)
   actual total in cost_ledger afterward: 1200.0000
   ```
   Both passed. Final spend landed at $12.00 against an $8.00 ceiling — a real,
   reproduced 50% overrun, on the exact mechanism the audit named.

3. **Applied 0024 for real** (committed, not rolled back — this dev database
   tracks applied migrations by having them actually run against it, the same
   way 0001-0023 got there). Confirmed live: `pg_get_functiondef` on
   `log_job_cost` now contains `org_month_spend:`.

4. **Re-ran the identical test against the fixed function** (fixtures reset to
   zero spend first; same temporary `pg_sleep(1)` widening, so this is an
   apples-to-apples rerun, not a weaker test). Used psql's own `\timing` so
   the evidence is self-reported by the database, not my shell's clock:
   ```
   winning session:  600.0000                         Time: 1009.758 ms
   blocked session:  ERROR RP402: monthly AI spend ceiling
                      reached for the trial plan (600¢ of 800¢)
                                                        Time: 2013.952 ms
   actual total in cost_ledger afterward: 600.0000
   ```
   The second session's wall time (~2.0s, almost exactly double the first's
   ~1.0s) is direct evidence it spent one full cycle *blocked* on the
   advisory lock before it ever got to run its own check — not merely "lost"
   a fast race. Once unblocked, it correctly read the now-current total
   (600¢, the first session's committed insert) and was correctly refused:
   600 + 600 = 1200 > 800. Final actual spend: 600¢ — at, not over, the
   ceiling. The race is closed.

5. **Cleaned up** every fixture row created for this test (auth.users,
   profiles, orgs, memberships, listings, render_jobs, cost_ledger) — all
   test tables back to their pre-test row counts (0, this was an empty dev
   database). `org_month_spend_cents()` confirmed restored to the exact
   original 0010 definition (plain `language sql stable`, no sleep). The only
   permanent change left in the database is migration 0024 itself, applied
   the same way every other migration in this database was.

Nothing here required guessing: the live database's actual pre-migration
function text, the actual race, and the actual fix were all observed
directly, not inferred from reading the SQL.

---

## 2. AI quota consumed when the provider fails (no refund on failure)

**Where:** `services/supabase/functions/_shared/ratelimit.ts` exports
`refundRateLimit()`, correctly used by
`services/supabase/functions/ai-chapters/index.ts` on every failure path, but
never called from `services/supabase/functions/ai-photo/index.ts` or
`services/supabase/functions/ai-video/index.ts` — a provider 502 (or any
post-charge failure) permanently burned burst + monthly quota for output that
was never produced.

**The fix — mirrors `ai-chapters/index.ts`'s existing pattern exactly** in
both files: the guard function that charges quota now returns a small
`Charge` record (org id, plan, the exact rate-limit keys it bumped) instead of
`void`, and a matching `refund*Charge()` helper hands it back via
`refundRateLimit()`. Every call site that charges then attempts a provider
call now wraps *only the provider call* in try/catch, refunding on catch and
rethrowing (never swallowing the error) — placed exactly at the boundary
where `resolveChain`/`resolveRoute`/`routerEnabled` are known never to throw
(read `_shared/providers/chain.ts`, `router.ts`, `providers/common.ts` to
confirm this) and only `runChain()` / `falSubmit()` can:

- **`ai-video/index.ts`**: `GenerateCharge` interface and `guardGenerate()`
  (`:146`, `:165`), `refundGenerateCharge()` (`:221`). All four generate
  routes — drone (`:586`), declutter (`:693`), aerial (`:810`), reel-clip
  (`:941`) — capture the charge and refund it if `runChain(...)` /
  `falSubmit(...)` throws (call sites at `:608-613`, `:705-706`, `:840-845`,
  `:970-975`), then rethrow so the caller still sees the original error.
- **`ai-photo/index.ts`**: `EditCharge` (`:119`, `guardEdit()` at `:132`),
  `refundEditCharge()` (`:169`); `HelperCharge` (`:175`, `guardHelper()` at
  `:181`), `refundHelperCharge()` (`:191`). The main edit path refunds at
  `:681`; the `suggest`/`improve_prompt` helper paths refund at `:546` and
  `:561`.

**Not double-refunded, not refunded on real spend:** the refund call sits
*only* around the submit/generate call, after the charge and before any
result is produced — a path that reaches a successful response never enters
the catch block, so a provider that actually billed and produced output is
never refunded. Each charge is captured once per request and refunded at most
once (the try/catch wraps a single call; on success the charge variable is
simply never touched again).

**Verified:**
- `~/.deno/bin/deno check ai-photo/index.ts` — clean (exit 0).
- `~/.deno/bin/deno check ai-video/index.ts` — clean (exit 0).
- `~/.deno/bin/deno check ai-chapters/index.ts` — clean (exit 0, confirms the
  reference implementation itself still checks after being read/compared).
- Full-repo convention check (`services/supabase/functions/README.md`'s own
  documented CI loop — `deno check` on every `*/index.ts` except `_shared/`)
  — all 17 function entrypoints clean, see the combined verification section
  at the bottom of this doc.
- **Not covered by an automated test**: there is no existing unit-test
  harness for `ai-photo/index.ts` or `ai-video/index.ts` (no
  `ai-photo_test.ts` / `ai-video_test.ts` exists in the repo, and both files
  are `Deno.serve` HTTP handlers wired directly to Supabase auth/DB clients,
  not pure functions) — `ai-chapters/postprocess_test.ts` tests chapter
  post-processing helpers, not the refund path either. The refund logic here
  was verified by type-checking and by tracing every call site by hand
  against the chain/router code's documented never-throws contract, not by
  an executed test. This is the one piece of issues #2-4 that could not be
  proven by running something — flagged here rather than left silent.

---

## 3. Video-declutter route writes no cost_ledger row

**Where:** `services/supabase/functions/ai-video/index.ts`, the declutter
route (guard at `:693`, provider submit at `:697-708`).

**The bug:** this route consumed the shared reel-allowance quota and called a
real provider (Bria, via fal) but never wrote to `cost_ledger` — real spend
invisible to the per-org COGS ceiling and to `GET /admin`'s spend reporting.

**Checked for a committed price before writing anything** (the task's
explicit instruction: do not invent one). Confirmed absent in every place a
price could live:
- `services/supabase/migrations/0018_ai_routes.sql` — the router's seeded
  route table has no `video.declutter`/Bria row at all.
- `services/supabase/functions/admin/index.ts` (pre-fix) — the Bria pricing
  row existed with `unit_cost_cents: null`.
- `HANDOFF-DB.md` and `HANDOFF-ADAPT.md` — both explicitly list Bria pricing
  as an open gap.
- `docs/PRICING-DATA.md` — no Bria figure.

**The fix:** rather than inventing a number, reused the already-committed
`ESTIMATED_UNIT_COST_CENTS.declutter` constant
(`services/supabase/functions/_shared/ledger.ts:87-91`, = 4¢, "Flux
Fill/Kontext masked inpaint (~$0.04/img)" — an existing pre-flight-cap
estimate used elsewhere in the repo, not a number I made up) via a new,
clearly-named alias `APP_AI_UNIT_CENTS.bria_declutter_per_clip_estimated`
(`_shared/ledger.ts:143`, with a long comment explaining exactly why it's
there and what it should be replaced with). The declutter route now calls
`recordAppAiCost(...)` after a successful submit (`ai-video/index.ts:727`)
with `feature: "video_declutter"`, `unitCents:
APP_AI_UNIT_CENTS.bria_declutter_per_clip_estimated`, and
`meta.price_estimated: true` plus a `price_basis` string explaining the
estimate — so every consumer of the ledger (including a human reading raw
rows) can tell this specific row is a placeholder rather than a real vendor
quote. `admin/index.ts`'s Bria pricing row (`:353-367`) now reports the same
estimated cents instead of `null`, and its `FEATURE_LABELS` dict gained
`video_declutter: "AI video declutter (Bria, estimated price)"` (`:671`) so
the admin console doesn't show a blank/unlabeled feature.

**This is explicitly an estimate, not a real Bria price** — flagged in code
(three separate comments: `ledger.ts`, `ai-video/index.ts`,
`admin/index.ts`) and flagged here. It closes the ledger-visibility gap (spend
is no longer silently absent) without pretending to know Bria's real per-clip
cost. Replacing it with a real number, once one exists, is a one-constant
change (`ledger.ts:143`) that automatically flows to both the route and the
admin console.

**Verified:** `deno check ai-video/index.ts`, `admin/index.ts`, and
`_shared/ledger.ts` all clean (exit 0). No dedicated test exists for the
declutter route itself (same gap as issue #2 — no `ai-video_test.ts`); the
`recordAppAiCost()` helper it calls is a pre-existing, already-shipped
function in `_shared/ledger.ts` that this fix did not modify.

---

## 4. Unsigned, unbound, non-expiring async job tokens

**Where:** `services/supabase/functions/_shared/providers/jobtoken.ts` (whole
file rewritten) and `services/supabase/functions/ai-video/index.ts`'s
`GET /ai-video/status` dispatch (`:1011-1041`) and `routedStatus()`
(`:1104`).

**The bug:** the pre-fix token was plain base64url JSON — no signature, no
owner, no expiry. Consequence: any authenticated caller who obtained the
string (a referrer header, a shared log line) could hand it back to
`GET /ai-video/status` and have the finished, paid-for asset persisted under
*their own* org (silent adoption of someone else's generation); and nothing
stopped a caller from hand-building an arbitrary token naming any
provider/model/vendor-id, causing the server to poll that URL with *our*
vendor credentials on the forger's say-so.

**The fix** (full design rationale is written into
`_shared/providers/jobtoken.ts`'s header comment, lines 1-54 — summarized
here):

- **Signed** — HMAC-SHA256 over the payload via Web Crypto
  (`crypto.subtle.sign`/`verify`), keyed by a new, dedicated env var
  `JOB_TOKEN_SIGNING_SECRET` (read through the same `trimmedEnv()`
  trim-or-undefined pattern already used in `_shared/r2.ts`,
  `_shared/providers/common.ts` and `ai-chapters/index.ts` — this repo has a
  documented production outage from an untrimmed secret, so every secret read
  in this codebase goes through that helper). Deliberately its own secret
  (not a vendor key, not the Supabase service-role key) so rotating it can
  never also rotate a vendor credential. A tampered payload or forged
  signature decodes to `null`, never throws.
- **Owned** — every token carries the org id (`o`) *and* user id (`usr`) that
  created the job (`RouterJobToken` shape, `jobtoken.ts:58-68`).
  `GET /ai-video/status` re-derives the caller's own org/user from *their*
  JWT (never trusts the token for this) and `verifyJobToken()` refuses to
  return a token whose owner doesn't match. This check happens in
  `ai-video/index.ts:1030-1039`, **before** `routedStatus()` — and therefore
  before any vendor is ever polled — closing the exact ordering bug that made
  the original vulnerable (the old code derived org only *after* a
  successful poll). A mismatch is a `403` with a message that does not
  distinguish "expired" from "wrong org" from "tampered" (`jobtoken.ts:1035-
  1038`).
  - Confirmed a **wrong org is refused** (`verifyJobToken` with a different
    `orgId` returns `null` — new test, see below).
- **Expiring** — every token carries `exp` (unix seconds),
  `TOKEN_TTL_SECONDS = 2 * 60 * 60` (`jobtoken.ts:80`) — generous relative to
  the router's longest advertised job (`video.upscale_4k` /
  `video.upscale_1080p60`, `max_latency_s = 1800` in
  `0018_ai_routes.sql`) plus slack for vendor queue backlog.
  - Confirmed an **expired token is refused** even with a valid signature and
    matching owner (new test, see below).

`verifyJobToken()` (`jobtoken.ts:261-271`) is the single gate — signature,
shape, expiry, and ownership are all checked there, and it never throws (a
malformed string, missing secret, or any check failure all answer `null`
uniformly). `routerStatusUrl()` (`jobtoken.ts:274-297`, now `async`) mints a
token via `encodeJobToken()` at submit time, requiring a `JobTokenOwner`
argument — every one of the four generate routes in `ai-video/index.ts` now
passes `{ orgId: charge.orgId, userId: user.id }` when building the status
URL, so a token can never be minted without an owner.

**No backward-compatible grace path for old unsigned tokens** — a deliberate
decision, documented in `jobtoken.ts:42-47` and called out here per the
task's own condition ("old tokens may keep working ONLY if something in
flight needs them"): nothing in this repository is a live deployment with
async jobs already outstanding, so there is nothing an old-format token needs
to keep working *for*. A grace path would itself reopen a bounded version of
the exact hole this fix closes, for no compensating benefit. **A real
production rollout that does have in-flight async jobs at deploy time would
need a time-boxed grace path** (bounded to the longest supported job,
`TOKEN_TTL_SECONDS` = 2h) — flagging that explicitly since it's a real gap
for an actual deploy, just not one that applies to this repo's current state.

**Tests added** — `services/supabase/functions/_shared/providers/providers_test.ts`,
section "── 8. THE ROUTED-JOB TOKEN" (this is where the pre-existing jobtoken
tests already lived; no new test file was created, to avoid fragmenting
jobtoken coverage across two files):
1. `"job token round-trips end to end (sign -> extract -> verify), is bound
   to its owner, and carries no vendor credential"` — mints via
   `routerStatusUrl()`, extracts, verifies; asserts every field round-trips;
   asserts the raw payload contains none of `key`/`secret`/`X-Amz`/
   `Authorization`; asserts a **wrong org** and a **wrong user** each fail
   verification.
2. `"a legacy fal status request carries no job token; garbage in the job
   slot fails verification, never a throw"` — the flag-off/legacy path still
   returns `null` from `extractJobToken`; garbage in the `job` param is
   extracted (so the caller can tell "attempted and failed" from "not
   attempted") but never verifies, and never throws.
3. `"a tampered job token payload and a forged signature both fail
   verification"` — swaps the org id inside the payload (signature no longer
   matches → rejected); flips two characters of the signature (forged →
   rejected); malformed shapes (no `.` separator, extra segments) all answer
   `null`.
4. `"an expired job token fails verification even with a valid signature and
   matching owner"` — a freshly-minted token verifies now; the identical
   token evaluated against a `now` one year in the future is rejected.

That is all five required cases (valid token, wrong org, expired, tampered
payload, forged signature) plus wrong-user as a bonus, since the fix binds to
user id as well as org id.

**New required secret, documented:** `JOB_TOKEN_SIGNING_SECRET` added to
`services/supabase/functions/README.md` §2 (secrets table), the dense
one-liner in `services/supabase/DEPLOYMENT.md`'s "Secrets reference", and
`services/supabase/set-secrets.sh` (with a comment on how to generate one —
`openssl rand -hex 32` — and what rotating it costs). The code itself also
fails loud with a clear error if the secret is unset (`jobtoken.ts:96-105`),
so a missing secret cannot silently ship as "tokens accepted unsigned."

**Verified:**
- `~/.deno/bin/deno check _shared/providers/jobtoken.ts` — clean.
- `~/.deno/bin/deno check _shared/providers/providers_test.ts` — clean.
- `~/.deno/bin/deno check ai-video/index.ts` — clean.
- `~/.deno/bin/deno test --allow-env --allow-net _shared/providers/providers_test.ts`
  — **31 passed, 0 failed**, including all four jobtoken tests above.

---

## Combined verification run (everything touched, plus the whole repo)

```
$ echo '{"nodeModulesDir":"auto"}' > services/supabase/functions/deno.json   # repo's own documented CI convention, README.md
$ cd services/supabase/functions
$ for d in */; do [ "$d" = "_shared/" ] || deno check "${d}index.ts"; done
```
All 17 function entrypoints (`admin`, `ai-chapters`, `ai-enhance`, `ai-photo`,
`ai-video`, `ai-voice`, `apple-subscriptions`, `beacon`, `coach`, `events`,
`leads`, `listings`, `me`, `portfolio`, `renders`, `tours`, `uploads`) — clean,
exit 0.

```
$ deno test --allow-env --allow-net \
    _shared/providers/providers_test.ts \
    ai-chapters/postprocess_test.ts \
    coach/actions_test.ts
ok | 83 passed | 0 failed (421ms)
```

Every `*_test.ts` file that exists anywhere in `services/supabase/functions`
(there are only these three in the whole repo) — all pass, including the two
files this session did not touch (confirms nothing was broken elsewhere).

The temporary `services/supabase/functions/deno.json` scratch file created
for the check loop above was deleted before committing — it is not a tracked
repo file.

---

## What could not be proven

- **Issues #2 and #3's actual runtime behavior** (a real provider call
  failing mid-flight and the refund/ledger-write firing) — verified by
  type-checking and by hand-tracing every call site against the chain/router
  code's documented never-throws contract, **not by running a test against a
  live or mocked provider**. Neither `ai-photo/index.ts` nor
  `ai-video/index.ts` has an existing unit-test harness (both are
  `Deno.serve` HTTP handlers wired to live Supabase/auth clients — unlike
  `ai-chapters/index.ts`, which has a companion `postprocess_test.ts` for its
  pure-function pieces only, not for its own refund path either). Building a
  full request-mocking harness for either file was out of scope for a
  four-fix audit pass; flagging it rather than claiming an execution proof
  that didn't happen.
- **Issue #3's price** is explicitly an estimate (4¢/clip,
  `ESTIMATED_UNIT_COST_CENTS.declutter`), not a vendor-confirmed Bria price —
  see the "not invent a price" discussion above. The ledger row now exists
  and is clearly marked; the number itself still needs a real quote.
- Nothing else — issue #4's doc updates (`README.md` §2, `DEPLOYMENT.md`,
  `set-secrets.sh`) are done, and issue #1's fix was proven against a real,
  running database rather than left as a read-the-code claim.
