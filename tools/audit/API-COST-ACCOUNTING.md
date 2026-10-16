# Private owner API-cost accounting

The owner requires a record of all API costs. Functional correctness, quality and logical UX come first; prices may change. The final price audit follows functional testing and precedes Apple submission. A 75% margin is **not** an acceptance gate. This report changes no funding, security, abuse or rate limit.

`api_cost_snapshot.sql` exports existing accounting records with one SELECT. `api_cost_report.py` produces a private JSON report, a CSV of retained ledger rows and a source/snapshot hash manifest. It never calls an inference provider, retries a generation, flushes a spool, changes a budget or deploys anything. Source snapshots and outputs use new private directories and0600 files. Reports pseudonymize account/library/listing/job identifiers, exclude customer prose/media URLs/credentials and escape CSV formulas. Private source snapshots retain the UUIDs needed for owner reconciliation; do not publish them.

## Run

Execute the SQL through the authenticated Supabase MCP `execute_sql` against the intended project and save the returned `snapshot` object privately. Then:

```sh
python3 tools/audit/api_cost_report.py --snapshot /private/snapshot.json --events /private/owner-events.json --out /private/new-cost-report
python3 -m unittest discover -s tools/audit -p "test_api_cost_*.py"
# Disposable real-PostgreSQL proof of the export path (owned cluster, every migration, no network):
python3 tools/audit/api_cost_report_pg.py --evidence-dir "/Volumes/Rendprop Files/Builds/Active/<build>-api-cost-report-pg"
```

Snapshot **schema 2** (2026-10-16) adds the service-only `provider_attempt_receipts`
journal (migration `20261016192846`, live as history `20261016202008`). The report
still accepts schema-1 snapshots and reports that journal as *not exported*,
never as zero attempts. Schema 2 also carries the ledger meta keys
`provider_attempt_id`, `result`, `price_basis`, `billing_reconciled` and `erase_job_id`.

Alternatively, `--collect-project <20-letter-project-ref>` performs one call to Supabase's [read-only query endpoint](https://supabase.com/docs/reference/api/v1-read-only-query). It reads a Management API credential from the environment-variable NAME selected by `--token-env` (default `SUPABASE_ACCESS_TOKEN`). No credential is accepted in argv. The read-only endpoint is experimental and requires database-read permission; missing permissions fail without retry or a write-endpoint fallback. The live audit used MCP; this collector has closed transport tests, not a claimed live transport acceptance. Local CLI `db query --linked` was unsuitable on this machine (missing link, then IPv6 unavailable); those first-red diagnostics are retained privately.

Every array has a matching database count and a50,000-row bound. An incomplete snapshot refuses to produce totals. The SQL records its database role's RLS-bypass authority; a member-filtered or unverified export refuses to masquerade as whole-app accounting. A Management read-only role without this authority must use an authorized owner export instead; the tool never escalates its permissions. No silently truncated total is accepted. The report preserves each distinct ledger row, flags repeated supplier IDs for investigation and never discounts a possible duplicate charge automatically. Repeated identical exported IDs are idempotent; conflicting immutable IDs refuse. A supplied local `--spool` is read only, matched by immutable idempotency key and kept separate from persisted consumption.

## What the amounts mean

| Amount | Meaning | Add to ledger total? |
| --- | --- | --- |
| Recorded ledger | Stored `cost_ledger.total_cents`; exact decimal sum, not repriced today | Already included once |
| Published bound | A recorded complete-input/output or geometry bound | Already included; not an invoice |
| Usage-priced estimate | Observed usage multiplied by a stored/configured tariff | Already included; not an invoice |
| Catalog/unclassified cost | Stored amount without complete billing evidence | Already included; uncertainty visible |
| Unledgered hold | Reserved/succeeded/uncertain attempt with no unique matching ledger row | Separate potential liability |
| Released/rejected attempt | Journal says no current held liability | No fabricated usage or supplier refund |
| Failed/refused result | A failed job, QC refusal or failed delivery can retain real provider liability | Its recorded costs remain included |
| Credit funding/top-up | Cash or credits added to the supplier account | **Never** consumption |
| Supplier invoice | Separately supplied invoice evidence | Comparison only; never added again to ledger |
| Fixed infrastructure invoice | Separate platform/hosting/storage/compute bill | Separate infrastructure section |
| Spatial/presenter/erase rollup | Other authoritative product journals, potentially overlapping ledger/holds | Reported separately; not blindly added |
| Provider attempt — `intent` / `transport_unknown` | A durable pre-dispatch intent without a confirmed terminal outcome (not proof of supplier dispatch), or a lost reply | **Unknown amount; never zero, never priced.** Listed under `provider_attempt_journal.unknown_outcome_attempts` |
| Provider attempt — `hit` / `no_record` estimate | Configured catalog amount recorded by `provider_attempt_finish` | Never added; the ledger row carrying `meta.provider_attempt_id` is the consumption record. A priced attempt with no retained ledger row matching its organization/provider/model, effective paying account (each row uses its own stored billing_org_id or legacy org_id), and declared stage when present is listed as a reconciliation item; mismatched IDs remain in `mismatched_ledger_ids` |
| Provider attempt — `http_error` / `invalid_response` | Answered refusal or unusable reply | No recorded charge; a supplier may still bill an answered call. Listed, not priced |
| Ledger row with `meta.outcome = uncertain` | A writer that books in `finally` (Studio edit-plan/captions) recorded the attempt after a lost reply — or after a funding refusal before any dispatch | Stays in the total (never discounted); disclosed as `uncertain_dispatch_context`. With no matching serving hold it is also `recorded_without_matching_attempt_hold` (possibly never dispatched) |
| Two ledger rows with one attempt identity | Same org/request_key/stage/provider/model (edge receipts carry no idempotency key) | Both stay in the total; listed under `possible_duplicate_attempt_rows` for investigation |

Serving rows reconcile by immutable ledger ID, or one exact org/request-key/stage/provider/model match. A null `ledger_id` alone does not imply missing spend. Matching app-video/serving holds are not added twice; a larger unmatched reserve retains its excess. Account-deletion video receipt tombstones with missing ledger rows are disclosed separately. No supplier refund, discount, failed-call cost or actual invoice amount is invented. `price_recorded_at` is the recorded row time; the report leaves the tariff's effective date unknown rather than mislabeling that timestamp as a verified price date.

## Coverage map and concrete gaps

| Surface/provider | Existing record/source | Coverage limit |
| --- | --- | --- |
| Photo generation/helpers: Gemini; routed FAL/OpenAI alternatives | `functions/ai-photo/index.ts`, `_shared/ledger.ts`, `_shared/funded-serving.ts`; `cost_ledger`, serving reservations | Modern Pro/Flash4K records use complete bounds, not supplier invoices. Helpers record catalog/quote costs. Most historical rows lack provider IDs; generation image token usage is not consistently retained. |
| Video: FAL Kling4K, Seedance, Veo, Flux/Topaz; KIE alternatives | `ai-video/cost-reservation.ts`; `app_video_cost_reservations`, ledger, serving holds | Accepted request IDs and settlement retained; a later failure does not erase paid cost. An uncertain POST retains liability. Supplier credits/actual refunds and invoices need external reconciliation. |
| Direct Bria erase/reflections | `video_erase_jobs`, `video_erase_stages`, ledger; migrations `0055`, `20261002225458` | Separate stage/job financial journals are exported without URLs. Their rollups can overlap; not blindly summed twice. |
| Ask AI: Anthropic/OpenAI | `coach/index.ts`, ledger | Provider usage evidence can exist, while recorded charge is explicitly route-catalog estimate. No automatic supplier-invoice evidence. |
| Copy, fairness, planning, room vision, QC | `ai-copy`, `property-video-plan`, `ai-video` QC, `ai-photo/photo-qc-runner`, Studio edit-plan production | Copy retries and each answered judge have separate stages. Photo judge records a complete token bound and usage metadata; strict parse/refusal remains paid. Legacy pipeline uses usage-derived rates. Price versions/IDs are incomplete historically. |
| Studio captions: OpenAI; speech: ElevenLabs/OpenAI routes | `studio/media-analysis-production.ts`, `ai-voice/index.ts`, providers | Metered duration/characters and configured rate estimates; request IDs and supplier tier/discounts not universal. On-device Apple speech is distinct and has no app-provider ledger charge. |
| Studio presenter/Higgsfield | `studio/presenter-execution.ts`, `studio_presenter_jobs` | Independent immutable quote/held/charged/billing-reference journal, exported separately. Not central-ledger coverage merely because a provider appears in the catalog. The retained historical audit had zero presenter jobs; that is not a current live observation. |
| Higgsfield routed generation | `_shared/providers/higgsfield.ts`, funded route contract | Adapter exists; eligibility/consent/pricing still required. Enabled catalog entries are not evidence that a call occurred. No live spending probe made by this audit. |
| WorldLabs | Catalog seed/probe; absent from `_shared/providers/index.ts` registry | A configured route is not an implemented generation adapter. Do not report invented usage/zero-price success. |
| Property records: RentCast | `property/index.ts` (property28), `_shared/property/rentcast.ts`; `provider_attempt_receipts` via `provider_attempt_begin/finish` | Cache hits do not rebuy. Since property28 every dispatch has a durable intent and a typed terminal outcome (hit/no_record priced at the configured 7¢ estimate; http_error/invalid_response/transport_unknown unpriced). The `x-request-id` lives only on the receipt, not the ledger row. The ledger row's `billing_org_id` comes from `library_billing_org(org_id)` while the receipt's comes from `library_access(actor, org)`; their effective billing identity still needs a complete team-member RPC/trigger comparison; this audit has not proved a live mismatch. No invoice integration. |
| Nearby/location/maps | Native MapKit/CLGeocoder; `tour-host/src/nearby-places.ts` OpenStreetMap/Overpass | No app cost ledger or provider invoice import. Do not infer an actual invoice of zero. No paid Google Places request was found in these routes. |
| Music | Native bundled catalog; Studio uploaded/licensed assets; CPU `music_catalog.py` | No per-use generative-music provider call found on these paths. Licensing/fixed acquisition costs are external infrastructure/content expenses, not fabricated API consumption. |
| Python render/enhance | `pipeline/cost_ledger.py`, `cost_spool.py`, `worker/db.py` | Stable keys, bounded retries, persistent spool and degraded stop preserve failed ledger writes. Only supplied local spool is visible here; other running hosts' spools are unknown. |
| Render/CPU/containers/Modal spatial | `worker/infra_costs.py`, `spatial-worker/modal_provider.py`, `spatial_jobs` | Old worker encode cost is an explicit configured estimate. Spatial reserves full compute bounds. New Cloudflare composition/photo-QC CPU actual duration/bills are not centralized in ledger. Do not call a max-cost rollup an invoice. |
| R2, uploads, storage, egress, Stream, Images, Workers/DO, public hosting | R2 helpers, media budgets, `metering`, worker Stream storage estimate | Financial budgets plus `owner_testing_media_usage` and `media_serving_usage` count conservative authority requests/admitted bytes, not supplier dollars. The owner and general-product counters are exported separately under `unpriced_usage`; no tariff is invented and they never increase ledger totals. Stream storage is estimated once despite recurring cost; delivery watch metrics are not actual billed egress. Images transforms, request/storage tiers, CPU, fixed plans, bandwidth and domain bills require external account-level invoice/usage import. |
| Supabase DB/Auth/Edge/backups; Resend email; Apple membership/commissions | Supabase platform; `notify/email.ts`; external supplier statements | No all-app dollar journal or fixed-cost invoice import. Provider API health does not establish billing completeness. |

The existing admin provider inventory contains legacy example models/prices and presence-based coverage claims. It is not the price source for this report. Actual selected ledger models, persisted route/tariff versions and explicit unknowns are authoritative for this export. This candidate additively changes the admin spend response; no hosted deployment is claimed by the source patch or this offline verification.

## Functional test blockers versus accounting

| Boundary | Classification and action |
| --- | --- |
| FAL out-of-credit refusal | Actual supplier funding blocker, owner confirmed; owner added$25. Record separately from usage. A generic403 alone is not proof of balance/safety. No supplier call/credit purchase by this report. |
| Retail/trial/shared allowance, quote ceiling and complete-bound reservations | Product financial policy, not proof of supplier cost or a75% requirement. `funded-serving.ts`, `paid_quality_processing_budget`, entitlement/serving-ceiling wrappers can refuse before dispatch. Root owns deliberate testing-funding/policy changes; this tool changes none. |
| Presenter explicit max-cost consent/workspace budget; spatial max-cost reservation | Separate product financial activation. No silent extension or reinterpretation as supplier invoice. |
| Missing ordinary media-budget provisioning | General-product media metering replaces the financial activation dependency for already-authorized media. It does not grant publication/hosting, AI funding or client access; historical budgets/reserves remain unchanged. Apply the product-media migration before collecting its new table. |
| Photo QC enabled/policy/judge route; Pro-stage/declutter task selection; video quality profile/route health | Operational activation, consent and quality dependencies, not a price-margin gate. No flag changes in this audit. |
| Current actor/library/source ownership, consent, signed paid receipt, uncertain-operation fence, request/byte/concurrency/rate guards | Security, abuse and duplicate-spend protections. Preserve them. Existing paid operations cannot be rebought to get around a financial or recovery error. |

## Remaining record-keeping work requiring review

1. Import periodic supplier usage/billing and fixed infrastructure statements; retain original evidence privately. Reconcile per-request charges, credits, duplicate charges and actual refunds without adding invoices/top-ups to consumption again.
2. Retain provider request IDs, listing/job scope and exact effective tariff version/date on every future answered/uncertain paid call. Existing app Edge writes are best effort; reconcile insert failures with retained holds rather than treating a successful user result as a free call.
3. Decide a privacy-reviewed durable accounting tombstone policy: `0039_account_deletion_intent.sql` deletes ledger rows. Historical completeness cannot be claimed from today's ledger alone. Do not silently change deletion/retention behavior in a report tool.
4. Add authoritative invoice/usage collection for Cloudflare CPU/Images/R2/DO/hosting, Supabase and email. Byte/watch/request quotas do not constitute invoices, and missing rows do not mean no cost.

The audit is a bounded source/accounting review, not a promise that every future code path is instrumented. Its export reports known journals and missing coverage instead of fabricating a full bill.
