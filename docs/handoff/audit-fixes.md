# Audit fixes — the external release audit of 7 Sep 2026

An external audit (Codex, static analysis of `main` at `ef9fc9a`) returned NO-GO
with four blockers and a list of ranked findings. This is the index of what was
fixed, by whom, and where the detail lives. Every fix was written on its own
branch off `integrate/1.0.1` and merged here; each linked file carries the
file:line references and the verification output for its own area.

## What the audit said, and what happened to it

| Audit item | Verdict | Fixed in | Where it landed |
|---|---|---|---|
| P0-4 — deletion can return `ok:true, cleanup_complete:true` while retaining profile/analytics rows | real | [deletion](audit-fixes/deletion.md) | `cleanup_complete` computed after every destructive step; the tombstone only completes when it is genuinely true, and the sweeper gets a payload naming the steps that failed |
| Cross-tenant CRM deletion (ranked "additional finding 1", worse than its rank) | real | [deletion](audit-fixes/deletion.md) | GHL contacts are deleted only when this tenant's tag is the only one on them; shared contacts are untagged, unreadable ones are left as a recorded leftover |
| Signed-out StoreKit purchase claimable by another account | real, narrow | [deletion](audit-fixes/deletion.md) | `0026_apple_transaction_binding.sql` — 0019/0021 already refused a *sequential* re-bind; the concurrent first-bind race did not, and now does |
| P0-3 — monthly org spend ceiling is raceable | real, critical | [spend-and-tokens](audit-fixes/spend-and-tokens.md) | `0024_spend_ceiling_lock.sql` — per-org advisory lock around the read-and-insert. The race was reproduced live (1,200¢ against an 800¢ ceiling) and re-tested closed |
| `refundRateLimit` never called by ai-photo / ai-video | real | [spend-and-tokens](audit-fixes/spend-and-tokens.md) | both functions now refund on provider failure, mirroring ai-chapters |
| Video-declutter route writes no ledger row | real | [spend-and-tokens](audit-fixes/spend-and-tokens.md) | records an explicitly-estimated cost — no vendor price was invented |
| Router job tokens unsigned and unbound | real | [spend-and-tokens](audit-fixes/spend-and-tokens.md) | HMAC-signed, org- and user-bound, 2-hour expiry, verified before any vendor poll |
| P0-2 — content-type smuggling through MIME normalization | real | [uploads-and-turnstile](audit-fixes/uploads-and-turnstile.md) | a declared type carrying a parameter is now a 400; the observed type is parsed but its base must match exactly |
| Upload budget charged before the asset insert | real, minor | [uploads-and-turnstile](audit-fixes/uploads-and-turnstile.md) | refunded on failure |
| Turnstile fails open when unconfigured | real | [uploads-and-turnstile](audit-fixes/uploads-and-turnstile.md) | fails closed; `TURNSTILE_OPTIONAL=1` is the knowing opt-out and still warns |
| Beacon metrics replayable | real, low | [uploads-and-turnstile](audit-fixes/uploads-and-turnstile.md) | per-IP-per-slug dedupe window, plus the honest caveat written into the contract: never billing truth |
| P0-8 — webhook claim not lease-safe; stale workers mutate reclaimed jobs | real | [worker-leases](audit-fixes/worker-leases.md) | `--job-id` now claims through the same CAS-plus-lease path; every mutation filters on `worker_id` and a lost claim aborts instead of overwriting |
| R2/ffmpeg resource controls incomplete | real | [worker-leases](audit-fixes/worker-leases.md) | R2 timeouts, a pixel ceiling before decode, a real output-size cap, and a stall timeout that cannot be disabled by accident |
| Cost spool can lose or duplicate rows | real | [worker-leases](audit-fixes/worker-leases.md) | file-locked atomic rewrite, a durable default path, and `0025_cost_ledger_idempotency.sql` |
| CI red on 0022 (no pg_cron in plain Postgres) | real | [ci](audit-fixes/ci.md) | guarded, with a loud notice; the purge function itself stays unconditional. 0001→0023 replays clean, 181/181 invariants |
| CI runs neither the edge tests nor the worker tests | real | [ci](audit-fixes/ci.md) | both wired in (216 Deno tests, the worker suite), and the HDR skip now shouts which filter is missing |
| Supply chain: old Wrangler, stale compatibility date, mutable action tags and images | real | [ci](audit-fixes/ci.md) | Wrangler 4.26.0 → 4.129.0 (4 high advisories → 0), compat date bumped and diffed live, actions pinned to SHAs, images pinned by digest |
| P0-6 — exact coordinates leave the device | real | [ios-privacy](audit-fixes/ios-privacy.md) | the geocode result is coarsened before it is stored, and Maps opens by address instead of a precise `ll=` |
| Audio recorded but absent from the privacy manifest | real | [ios-privacy](audit-fixes/ios-privacy.md) | `SpeechTranscriber` does not force on-device recognition, so audio can reach Apple's servers: declared, and the labels doc updated to match |
| P0-5 residual — internal COGS strings compiled into the binary | real | [ios-privacy](audit-fixes/ios-privacy.md) | redacted from `MockAPIClient` |
| Deletion UI fails open; analytics device id survives a wipe | real | [ios-privacy](audit-fixes/ios-privacy.md) | `cleanup_complete` defaults to false; the wipe clears the device identity and a fresh one is generated |
| 401 not retried on the direct paths; Apple auth code fire-and-forget | real | [ios-privacy](audit-fixes/ios-privacy.md) | the auth code is persisted until the server confirms it and retried next launch |

## What did NOT change, and why

- **P0-1 (secret rotation, registry history)** is a manual gate and stays one. No
  code change can prove a credential never entered an old Docker layer. The
  rotation list is in the launch runbook; it is the owner's to run.
- **P0-7 (migrations applied in production)** is a manual gate for the same
  reason: the repo can only prove the replay, which it does — 181/181.
- The audit's read of **P0-6 as a manifest mismatch** was not accurate:
  `PrivacyInfo.xcprivacy` already declared *precise* location, so the app was
  consistent with what it shipped. The fix is data minimisation, not a
  compliance correction — see the ios-privacy notes.

## Ordering

The server fixes ship first and independently — they need no app update, and
build 5 is in App Review and cannot change. The iOS fixes ride in 1.0.1.
`docs/LAUNCH-CONTRACT.md` records the one deploy order that actually matters:
`events` before the 1.0.1 binary.
