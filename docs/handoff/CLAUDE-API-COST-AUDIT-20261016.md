# Claude — API cost completeness and billing audit (O09 lane), 2026-10-16

Independent DevOps lane beside Codex. Scope was `services/supabase/functions/admin`,
`tools/audit/api_cost_report*` and directly related tests/docs. Nothing was
deployed, pushed, merged or paid for; property28 / voice54 / admin41 stay live and
untouched; paid generation stays PAUSED; Kie stays OFF; onboarding untouched.

## Result in one paragraph

Every paid dispatch path in source was traced to its durable accounting (matrix
below). The deployed provider-attempt journal is sound, but the owner report and
the admin spend route could not see it, so an unresolved or lost RentCast
dispatch was invisible — exactly the "ambiguous dispatch is not free" gap. The
admin spend route also attributed cost to the workspace, not the paying account,
and summed the ledger alone with no view of held/uncertain liability. Those three
defects are fixed on the isolated branch with failing-then-passing tests,
including a disposable real-PostgreSQL proof over all 179 migrations. On the
reconciliation side, FAL and Kie supplier consoles were read (signed-in,
read-only): **Kie October usage reconciles to the internal ledger to the cent
($5.815)**; FAL October reconciles on Seedance within 1.4% and on Kling 4K
within about one 5-second shot pending the 2026-10-16 snapshot that lives on the
external drive. OpenAI, Anthropic, ElevenLabs, Google and all infrastructure
invoices remain **unknown/pending** — not zero. The whole app and the checklist
are not complete on the basis of this lane.

## Branch, base and commits

| Item | Value |
|---|---|
| Base | `63dbe6822d5654e2a62038c040db227de89b9412` (on `origin/feature/launch-checklist82-20261014`) |
| Branch | `claude/api-cost-audit-20261016` (cloud worktree; never pushed) |
| Code commit | `8bddd1b` — "Cost reporting: export provider attempts, billing attribution and unreconciled liability" |
| Docs commit | this file + the sanitized reconciliation artifact (SHA in the delivery receipt) |
| Delivery | `git format-patch 63dbe68..HEAD` copied to `_bridge/build87-claude-api-cost-audit/` on the Mac with the evidence logs; the Mac shell was unavailable to this session (every `device_bash` call failed), so the branch was built in a cloud clone of the public repo |

Changed files (code commit):

```
docs/ADMIN-CONSOLE-CONTRACT.md                        additive /admin/spend fields documented
services/supabase/functions/admin/index.ts            /admin/spend reads 3 journals; by_billing_org, attribution, unreconciled
services/supabase/functions/admin/spend-summary.ts    NEW pure aggregation (aggregateLedger, summarizeUnreconciled)
services/supabase/functions/admin/spend-summary.test.ts NEW 5 closed tests incl. source binding of the route
tools/audit/API-COST-ACCOUNTING.md                    schema 2, new classifications, PG driver run line
tools/audit/api_cost_snapshot.sql                     schema 2: provider_attempts + extra ledger meta keys
tools/audit/api_cost_report.py                        attempt journal, uncertain context, duplicate attempt identities
tools/audit/api_cost_report_pg.py                     NEW disposable owned-cluster PostgreSQL proof
tools/audit/test_api_cost_attempts.py                 NEW 9 closed tests
```

## Tests actually run (cloud container, Linux x86_64)

| Suite | Environment | Result |
|---|---|---|
| `deno test services/supabase/functions/admin/*.test.ts` | Deno 2.9.6 (npm-installed), no network needed | **41 passed / 0 failed** (36 pre-existing + 5 new) |
| `deno check admin/index.ts admin/spend-summary.ts` | Deno 2.9.6 | clean |
| `python3 -m unittest discover -s tools/audit -p "test_api_cost_*.py"` | Python 3.13.16 | **32 passed** (23 pre-existing + 9 new) |
| `tools/audit/api_cost_report_pg.py` | PostgreSQL 16, owned cluster, `tests/ci-bootstrap.sql` + **179 migrations**, run as a non-root user | **25 assertions passed**; cluster stopped and removed |
| RED control — new admin test file against base `index.ts` | same Deno | fails: `handleSpend does not use aggregateLedger(` |
| RED control — base `api_cost_report.py` against the new evidence | same Python | base refuses a schema-2 snapshot (`Unsupported accounting snapshot`), has no attempt journal, reports an `outcome=uncertain` row as plain consumption, flags no duplicate attempt identity |
| RED control — PG driver against a base-commit worktree | same PostgreSQL | fails at assertion 0: base export is schema 1 with no attempts |
| New report over the retained **real** 2026-10-15 snapshot (297 rows) | Python | identical totals to the retained summary ($91.480052, holds 42.3796c); journal reported "not exported" |

Logs: `evidence/admin-tests-GREEN-after-fix.log`, `admin-spend-RED-base-index-control.log`,
`report-tests-GREEN-after-fix.log`, `report-RED-base-control.log`,
`api-cost-report-pg-run1/receipt.json`, `api-cost-report-pg-RED-base-control/receipt.json`.

Not run: hosted CI, a signed-in `GET /admin/spend` against production (admin42 is a
candidate, not deployed), any provider call, any Supabase production read (the
session's permission layer refused production reads; respected, not retried).

## Defects fixed (in scope)

1. **Provider attempt journal invisible to the owner report.** `api_cost_snapshot.sql`
   and `api_cost_report.py` never exported `provider_attempt_receipts`, so an
   unresolved `intent` or `transport_unknown` RentCast dispatch could not appear
   anywhere. Fixed: schema-2 export + `provider_attempt_journal` section. Unknown
   outcomes carry `estimated_cents: null`; priced hit/no_record estimates are never
   added to consumption; a priced attempt without its ledger row is listed.
2. **Spend attributed to the workspace, not the paying account.** `/admin/spend`
   bucketed `by_org` on `cost_ledger.org_id`; a Team member's library bills to the
   team (`billing_org_id`, trigger-stamped) and anonymised deleted-account rows keep
   only `billing_org_id`. Fixed additively: `by_billing_org` + `attribution`;
   `by_org` unchanged for the native console.
3. **Spend total with no view of held liability.** `/admin/spend` summed the ledger
   alone. Fixed additively: `unreconciled` reports serving holds by
   state/budget_source/linked, unsettled app-video holds and provider-attempt
   outcomes for the same window; never added to `total_cents`, never priced.
4. **Uncertain-dispatch receipts indistinguishable from consumption.** Studio
   edit-plan/captions book a ledger row in `finally` with `outcome: "uncertain"`
   even when funding refused before any dispatch (see out-of-scope item A). The
   report now discloses `uncertain_dispatch_context` and, when no serving hold
   exists for the attempt identity, `recorded_without_matching_attempt_hold`.
   Amounts stay recorded — nothing is discounted.
5. **No duplicate detection without supplier IDs.** 177 of 297 retained rows have
   no supplier request id, so `possible_duplicate_supplier_ids` could not catch a
   retried write after a lost reply. Added `possible_duplicate_attempt_rows`
   (same org/request_key/stage/provider/model). Flagged, never netted.
6. Minor: `/admin/spend` previously coerced an unreadable `total_cents` to `0` via
   `Number(x ?? 0)`; now skipped and counted (`ledger_rows_unreadable_amount`).

## Provider / feature accounting coverage matrix

Legend — **Hold**: durable reservation before the POST. **Ledger**: `cost_ledger`
row and when. **Lost reply**: what survives a timeout/killed isolate. **Refusal**:
whether a definitive 4xx releases the hold. **Req-id**: supplier request id kept
on the ledger row. **Basis**: amount meaning.

| Provider · feature | Dispatch site | Hold | Ledger | Lost reply | Refusal | Req-id | Basis | Gap |
|---|---|---|---|---|---|---|---|---|
| Gemini · photo_edit (4K/2K/Pro/1K, Fill) | `_shared/providers/gemini.ts:166` via `ai-photo/index.ts:968-1013` | `serving_cost_reservations` (`fundedAttempt`) | `recordRoutedAiCost` after success | hold `uncertain`; `failPhotoQuality(provider_cost_incurred:"possible")`; no ledger row | released only via `fetchJson` `dispatch_rejected` | no (synthetic job id) | complete-input bound (4K/2K/Pro), MP bound (Fill), catalog (1K) | chain fallover after an uncertain step dispatches step 2 → two possible charges, one row |
| Gemini · photo_helper (suggest / improve_prompt) | `ai-photo/index.ts:1151` raw fetch, **no timeout** | hold | `recordRoutedAiCost` after success | hold stays `reserved` if isolate dies | **never released** (plain `HttpError`) | no | complete request bound | no timeout; refusal held forever |
| Gemini · copy_assist | `ai-copy/index.ts:324` | hold per call (`task:initial|retry:i`) | one row per answered call | `uncertain` | via fetchJson | no | catalog | — |
| Gemini · chapters | `ai-chapters/gemini.ts:326` raw fetch, **no timeout** | hold | `recordAppAiCost` after success | `uncertain`; next model dispatched | never released | no (tokens kept) | catalog × seconds | second charge possible, one row |
| Gemini / FAL · pipeline restage/declutter | `services/pipeline/providers/{gemini,fal_client}.py` → `base.py:133` | hold `worker:<sha>` | `cost_ledger.py` with spool (`idempotency_key` = uuid) | spool retains; hold `uncertain` | listed 4xx → `rejected` | no | flat `costs.py` | **`base.py:139` finishes the hold `uncertain` even on HTTP 200** and meta carries no request_key/stage → hold never binds → permanent double count in the ceiling sum |
| FAL · reel / aerial / drone_render | `_shared/providers/fal.ts:417` via `ai-video/index.ts` + `property-video-worker` | `app_video_cost_reservations` (`app_video_cost_reserve_v2`) **and** serving hold | `app_video_cost_settle` **at acceptance**, `idempotency_key = app-video:<id>` | hold retained, `VideoDispatchUnconfirmed`; later settle from signed status token | `app_video_cost_release_rejected` for listed statuses | **yes** (`meta.request_id`, `provider_request_id`) | `price_estimated:true`, catalog × s / tier | `meta.billing_org_id = r.org_id` (workspace) — column is trigger-correct; `paidRoutedReceiptMatches` compares the meta value |
| FAL · photo (Kontext fallback, Fill) | `fal.ts:417` via ai-photo chain | hold | as Gemini photo | submit success ⇒ hold `succeeded`; poll failure ⇒ no row, hold unbound | via fetchJson | request id exists but **not written to ledger** | flat / MP bound | unbound succeeded holds (one in the retained snapshot) |
| FAL · Bria erase (video_declutter) | `ai-video/erase.ts:652` | `video_erase_jobs` hold + serving hold | SQL `video_erase_finish` at acceptance | `uncertain` after 120 s | `p_no_charge` on `dispatch_rejected` | yes | `price_estimated:false`, authenticated input-second rate | — |
| Kie · reel (owner-QA routes) | `_shared/providers/kie.ts:188/242` via `submitReservedVideo` | as FAL video | as FAL video | as FAL video | **in-envelope codes (HTTP 200 + `code` 402…) thrown with `dispatch_rejected=false` → held forever** | yes (`taskId`) | catalog | envelope refusals never released; Kie NOT active |
| OpenAI / Anthropic · coach | `coach/index.ts:408/422` | hold | after success, before parse | `uncertain`, no row | via fetchJson | no (usage tokens kept) | `route_catalog_estimate_not_supplier_invoice` | — |
| OpenAI / Anthropic · qc drift judge | `ai-video/index.ts:2474/2485` | hold per call | after whole check | `uncertain`, no row | via fetchJson | no | catalog | — |
| Anthropic · photo qc | `ai-photo/photo-qc-runner.ts:58` | hold (`photo-qc:<check>`) + `photo_quality_*` journal | `recordAppAiCost` after success | `uncertain` + `provider_cost_incurred:"possible"`, no row | via fetchJson | no | published complete I/O bound + usage | — |
| OpenAI · video_plan | `property-video-plan/index.ts:52` | hold | in `finally` when dispatched && (measured \|\| answered) | row written, hold `uncertain` → **counted twice in ceiling sum** | via fetchJson | no | provider-reported tokens × rate / bounded estimate | double count on incomplete reply |
| OpenAI/Anthropic · Studio edit_plan / prompt_enhancement | `studio/edit-plan-production.ts:41` raw fetch 30 s | hold (inside `generate`) | `record()` in **`finally`** (`edit-plan.ts:178`) | row with `outcome:"uncertain"`; hold `uncertain` → double count | never released (plain `HttpError`) | no | `price_estimated:true` catalog | **row written even when funding refused before any dispatch** (A) |
| OpenAI · Studio speech_captions (whisper) | `studio/media-analysis-production.ts:115` raw fetch 90 s | hold | `record()` in `finally` (`media-analysis.ts:137`) | as above | never released | no | catalog per second/minute | same as A |
| ElevenLabs · voiceover (voice54) | `ai-voice/index.ts:686` raw fetch, **no timeout** | meter + storage reservation + hold | `recordRoutedAiCost` after validated audio, **before** R2 store (the voice54 fix) | hold stays `reserved` if isolate dies | `rejected` only with `definitiveSubmitRejection` and no audio | no (`request-id` header dropped) | catalog, character floor | no timeout |
| Higgsfield · Studio presenter | `_shared/providers/higgsfield.ts:311` via `presenter-execution.ts:90` | `studio_presenter_jobs` + serving hold with quote=null (private sponsorship only) | **none** (`cost_ledger` never written) | job failed, charge 0; serving hold `uncertain` | `motionRequest` 4xx lacks `dispatch_rejected` | in presenter journal | quote/held/charged | `'settle'` has no caller → completed jobs keep `held_cents`, `charged_cents` NULL |
| Bria direct · erase stages | `ai-video/bria.ts:423/436` via `erase.ts:353` | `video_erase_stages` + serving hold (quote=null) | SQL `video_erase_finish_stage` at acceptance | `uncertain` after 120 s | `p_no_charge` for BriaError rejected/configuration/invalid | yes | confirmed account input-second rate, `price_version` | — |
| RentCast · property.lookup (property28) | `_shared/property/rentcast.ts:43` (12 s abort) via `property/index.ts:106-139` | **no financial hold**; `provider_attempt_begin` intent before POST | `recordAppAiCost` after 2xx/404 with `meta.provider_attempt_id`; `provider_attempt_finish` | `transport_unknown` receipt (unpriced) | `http_error` / `invalid_response` receipts (unpriced) | **only on the receipt** (`provider_request_id`), not the ledger | `configured_per_call_estimate` 7¢ | ledger `billing_org_id` from `library_billing_org(org)` vs receipt from `library_access(actor,org)` — can differ for Team members (code read) |
| Modal · spatial | `services/spatial-worker/modal_provider.py:117` | `spatial_jobs.max_cost_cents` + `spatial_provider_attempts` | **none** | `allocation_unknown` | — | in journal | compute bound; `cost_cents = max` on complete and fail | not in ledger; exported as rollup only |
| Cloudflare Stream store / encode | `services/worker/stream.py:85`, `worker.py:401-487` | — | `stream_store`, `render` estimate rows, random idempotency key | — | — | — | configured estimates | first month only; recurring storage not recorded |
| Cloudflare Stream delivery, Images, Containers CPU, R2 ops | `tour-host/src/media-delivery.ts:111`, `media-thumbnails.ts`, `property-video-render/src/index.ts:151` | byte/request admission counters | **no writer of `stream_deliver` exists** (admin only reads it) | — | — | — | — | usage counters only; no dollars |
| Resend email | `notify/email.ts:71` | — | none | — | — | Idempotency-Key header | — | unmetered |
| WorldLabs | admin probe GET only | — | none | — | — | — | — | no adapter; catalog presence ≠ usage |
| iOS native | `Secrets.example.plist` keys | — | — | — | — | — | — | no runtime paid call found |

Schema facts verified on the disposable cluster: `cost_ledger.billing_org_id`
exists (20261009192550), stamped by `z_team_billing_liability`; `idempotency_key`
partial-unique; edge `recordAppAiCost`/`recordRoutedAiCost` write **no**
idempotency key; account deletion now **anonymises** ledger rows (org/job/meta
nulled, amounts and `billing_org_id` kept — 20261010000032) rather than deleting
them; `provider_attempt_receipts` cascade-deletes with the actor/org.

## Reconciliation (sanitized artifact: `CLAUDE-API-COST-RECONCILIATION-20261016.sanitized.json`)

Billing period and currency: **USD; supplier figures are October 2026 cycle
(UTC) unless stated; internal figures are the retained 2026-10-15T20:46:56Z
snapshot (297 rows, $91.480052).** Production could not be read from this session.

| Provider | Supplier evidence | Internal | Verdict |
|---|---|---|---|
| **Kie** | Usage Oct 3–16: $5.815 (kling3 $3.475, seedance-1-pro-fast $2.34); 3 × $5 credit packs (Aug 25, Sep 4, Oct 16) | 18 rows / 581.5¢ = $5.815 (kling-3.0 347.5¢, seedance 234¢) | **Exact match.** Open: two balance readings minutes apart (709 vs 1,909 credits) and the bought-minus-balance arithmetic (≈$5.455) do not agree with the usage view; owner to check, not resolved here |
| **FAL** | Oct cycle $62.79 = Kling v3 4K 140.00 s × $0.42 + Seedance 3.99 M tokens × $1.00; period credits −$60; balance −$2.79; invoices Aug 24 $10, Sep 3 $10, Sep 30 $3.38, Oct 2 $25, Oct 14 $25, Oct 14 $10 | Oct through snapshot: Kling 23 shots / 115 s / $48.30 (same 42¢/s rate); Seedance 16 rows / 81 s / $3.9366; known later: 4K canary 2 shots $4.20; ≈$8.40 unitemised inside the Oct-16 15:33Z aggregate delta | Seedance within **1.4%** ($0.055). Kling within **≤1 shot ($2.10)**, estimate — exact needs the Oct-16 snapshot (external drive). Credits: $60 − $62.79 = −$2.79 ✓. The retained OWNER-EVENTS file lists one $25 funding event; the console shows three October purchases ($60) — update it before the next run |
| OpenAI, Anthropic, ElevenLabs | consoles require sign-in; not authenticated by this lane | $1.27 / $3.36 / $0.014 internal | **unknown/pending** |
| Google / Gemini | not attempted (shared-browser account risk) | $9.16 internal | **unknown/pending** |
| RentCast, Bria direct, Higgsfield, WorldLabs, Modal | no rows / no console | — | **unknown/pending** |
| Cloudflare (R2, Stream, Workers, Images, Containers), Supabase (Pro tier, org shared with three other projects), Apple, Resend | no invoice access in this session | counters only: product serving 238 req / 57.6 MB, owner testing 28 req / 10.9 MB, watch 1,527 s | **unknown/pending**, not zero |

Top-ups are recorded as funding events, never consumption. No invoice total is
invented; no consumption is inferred from credits purchased.

## Remaining evidence gaps (honest list)

- The Oct-16 15:33Z ledger aggregate (306 rows, $104.712124) and later rows were
  not re-verified; a schema-2 production export has not been run anywhere yet.
- No signed-in `GET /admin/spend` response (admin42 not deployed).
- Supplier statements for Google, OpenAI, Anthropic, ElevenLabs; all
  infrastructure/fixed invoices; Supabase org split.
- 187 of 297 retained rows carry no cost-basis flag (`unclassified_recorded_cost`),
  177 no supplier request id, 247 no listing, 8 rows ($0.577) no attributable account.
- Historical rows deleted before anonymisation landed cannot be reconstructed.

## Codex integration steps (do not deploy from this lane)

1. `git am` the patch series from `_bridge/build87-claude-api-cost-audit/patches/`
   onto the integration branch (or fetch the branch once pushed by the owner).
2. Re-run the three suites in the table above on the Mac; the PG driver needs
   the external volume mounted (`--evidence-dir` under `/Volumes/Rendprop Files`).
3. **Owner report first** (no deploy involved): run `api_cost_snapshot.sql` via the
   authorised read-only path, confirm `schema: 2` and a `provider_attempts` count,
   run the report, and update `OWNER-EVENTS` with the three October FAL purchases.
4. **admin42 candidate**: deploy only the `admin` function with the repo's own
   `deploy-backend.mjs --functions admin --run`; the response is additive, the
   native client needs no change. Verify a signed-in response carries
   `by_billing_org`, `attribution`, `unreconciled` and that `total_cents` equals
   the admin41 value for the same window (no total changed).
5. **No database change is required** by this lane. `provider_attempt_receipts`
   already grants `select` to `service_role`, which is what `/admin/spend` uses.

## Proposed changes outside this lane (describe, not edit)

A. **Studio `edit-plan.ts:178` / `media-analysis.ts:137`** — `record()` runs in
   `finally` even when `beginFundingOperation`/`fundedAttempt` refused before the
   POST. Proposed: track `dispatched` (set true only once the funded attempt's
   callback starts the fetch) and record `uncertain` only when `dispatched && !returned`;
   skip the row when nothing was sent. Tests: refusal-before-dispatch writes no
   ledger row; lost reply still writes `uncertain`.
B. **`services/pipeline/providers/base.py:139`** — finish the hold `succeeded` on a
   2xx and include `request_key`/`stage` (= the `worker:<sha>` stage) in the ledger
   meta so the settlement trigger can bind it. Until then, every pipeline charge
   is counted twice in `serving_ceiling_spent_cents`.
C. **Definitive-refusal signal for hand-rolled fetches** (`ai-photo` `geminiText`,
   `ai-chapters`, Higgsfield `motionRequest`, Kie envelope codes): throw
   `ProviderError` with `dispatch_rejected: true` for the listed statuses so the
   hold is released instead of held forever.
D. **Timeouts** on ElevenLabs `ai-voice:686`, `ai-photo:1153`, `ai-chapters:326`
   (AbortSignal, as RentCast does), so a killed isolate leaves `uncertain`, not
   `reserved`.
E. **Retain supplier request ids on the ledger row** for Gemini (`responseId`),
   OpenAI/Anthropic (`id`), ElevenLabs (`request-id` header), fal photo
   (`request_id`) — `meta.provider_request_id`. This is what turns "177 rows
   without supplier id" into a reconcilable set.
F. **RentCast billing-org consistency**: compute the ledger row's `billing_org_id`
   from the same `library_access(actor, org)` answer the receipt uses, or record
   the receipt's value in `meta` so the report can compare.
G. **Presenter settle** has no caller; decide whether completed Higgsfield jobs
   settle `charged_cents` or the journal is documented as hold-only.

## What this lane does not claim

Not a complete bill, not a margin verdict, not a statement about retail prices,
not App Store readiness, not a whole-checklist closure. O09 moves from
"signed-in admin response, supplier invoices/refunds and infrastructure
reconciliation incomplete" to: report path now covers the attempt journal and
held liability (candidate, tested, undeployed); Kie reconciled; FAL reconciled
within one shot pending the newest snapshot; everything else still pending.
