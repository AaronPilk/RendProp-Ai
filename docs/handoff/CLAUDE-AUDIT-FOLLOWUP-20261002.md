# Claude audit follow-up — 2 October 2026

The supplied audit was reviewed as evidence, then checked against runtime
`8de8fd0` / documentation HEAD `5551a83` and live Supabase metadata. Its target
`fix/listing-first-tour-20261001` is older. Work is isolated on
`fix/audit-cost-guards-20261002`; no shared branch, native capture code, Apple
submission or provider generation was changed during this audit.

## Findings and disposition

| Finding | Current evidence and action |
| --- | --- |
| Anonymous signup automatically grants the expanded seven-day trial | Stale in production. `handle_new_user` creates `free`, with no trial expiry or plan source. Migration `subscription_confirmed_trial_start` is applied as `20261001152146`. A fresh free workspace has 1 render, 5 photo edits and zero reels/aerials/Topaz. The advertised trial requires a verified Apple subscription offer. |
| Anonymous accounts can repeatedly claim free AI | Confirmed residual. Paid AI guards now use Auth's server-validated identity. Named users retain free allowances. A guest who actually subscribed retains access only through an exact server-bound active/grace Apple subscription for that actor and workspace. Unknown identity flags, mismatched subscriptions and failed lookups do not grant AI access. Anonymous capture, adoption and ordinary account APIs remain compatible. |
| Legacy `ai-enhance` lacks role, plan, queue and concurrency guards | Confirmed but unused: no native/Studio/worker caller or `_requests` consumer exists. POST now authenticates, then returns 503 without reading a job or changing its queue. `created` → `queued` never expanded the existing worker claim set, which already included both states. |
| Database failure resets paid monthly limits per isolate | Confirmed. `durableRateLimit` now refuses admission with 503 on RPC failure or malformed results. Only unbilled public leads, beacon and events explicitly use the quarter-cap memory fallback. Private writes and deduplication use the durable counter. |
| Paid requests may omit/oversize their deduplication key | Confirmed. Ordinary photo, video, chapters and voice require an 8–128 character printable key. Shipped builds 42/43 and current Studio already send compatible keys. Photo/chapter/voice still have a **two-minute** deduplication window; this does not provide durable output recovery. Ordinary video adds persistent admission below. |
| Coach can bill before finding the caller's workspace | Confirmed by an offline actual-source reproducer. Membership now resolves before generation; routing uses the server plan rather than client context. Existing per-user limits remain, plus a 600-call daily workspace abuse limit. Customer service is still independent of paid plan allowances. |
| Current native toolbox/share/launch still have the reported crash shape | Stale or unproven. Named toolbox/launch boundaries already shipped in 40 and are present in signed 43. Current share section has four direct children. The installed SwiftUI SDK uses a flat variadic `buildBlock`, so the audit's per-sibling `buildPartialBlock` calculation does not describe this toolchain. No `IdentityGate` exists in this branch. Physical arm64e behavior still requires phone evidence. |
| Upload MIME comparison differs for single/multipart | Confirmed difference with a transport rationale: multipart MIME is fixed at initialization; an undeclared single-upload MIME may use an allowlisted observed value. No demonstrated bypass; no transport rewrite. |
| `pg_net` extension is in public | Existing advisor warning, not a demonstrated new exploit. This patch does not relocate a live extension or change its dependencies. |

## Additional reproduced video cost race

Two distinct 4K drone submissions can both pass the old read-only precheck:
each projects 4,800 cents against 6,000 cents of monthly headroom, so together
they admit 9,600 cents. The healthy monthly Topaz allowance still limits this
to the plan's included count; the audit's twelve-job burst example omitted
that independent meter.

Ordinary drone/reel/aerial submissions now commit an immutable priced hold
before one eligible provider POST. The new service-only journal and reserve /
settle RPCs use the same `org_month_spend:` advisory lock (seed 42) as reflection
reservations and render accounting. Accepted receipts replace their hold with
one estimated ledger row in the same transaction. A lost POST response retains
the hold and allowance. There is no automatic TTL, release, retry permission
or failover after an uncertain submission. Failed ledger settlement preserves
the accepted output receipt while keeping the hold. Persistent same-key
replays never authorize another dispatch.

Topaz estimated accounting keeps the same frame-rate multiplier as admission;
base tier prices are unchanged. Estimates are marked `price_estimated`, with
invoice reconciliation outstanding. The journal stores only input SHA-256 and
bounded accounting facts, never customer media, URLs, prompts or room labels.
Cost-only identifiers/receipts survive account deletion; original media and
account purge still run. This retention supports outstanding expense accounting,
not access to the deleted customer's assets.

This is **not a universal pre-dispatch COGS hold**: photo, voice, chapters,
Coach and other direct app-AI ledger writes still use their feature meters /
best-effort cost rows. Their two-minute key guard also does not replay output.
Do not advertise global reservation coverage, invoice-exact spend, camera
quality or a fully certified team launch from these tests.

## Verification and delivery

Implementation passes **1,297 offline edge tests** (one dedicated PostgreSQL
fixture is ignored without its database harness) and **25/25 function
typechecks**. The local PostgreSQL 17.11 runner passes 101 assertions on a fresh
replay and 101 on migration replay, preserves legacy/direct reflection 51/37,
and tests real concurrent admission, eight settlements, direct-reflection
overlap, client grants/RLS, actual account purge and a deliberately removed-lock
mutation. The mutation admits 9,600 cents against 6,000 and is caught.

Independent source review and actual-source handler tests verify all three
video routes, unchanged 202 receipts, privacy, persistent duplicate refusal,
uncertain submission behavior and frame-scaled pricing. A reserve-after-POST
mutation fails the same ordering check.

Status: local verification complete; full CI and deployment pending. Final
source/check and rollout receipts will be recorded here after completion. No
paid provider calls or physical camera tests were performed.

Private original reports, customer identifiers and raw receipts stay outside
Git in `LocalRendpropAudits`. The new migration was generated by Supabase CLI:
`20261003020955_app_video_cost_reservations.sql`. Do not apply it twice under
a different ledger timestamp after production delivery.
