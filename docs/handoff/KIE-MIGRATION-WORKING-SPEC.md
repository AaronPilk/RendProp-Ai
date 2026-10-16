# Kie property-video migration — working spec for parallel lanes (Oct 16, 2026)

Worktree (Mac): `/Users/pilksclaes/Rendprop AI/Rendprop Workspace/Worktrees/Active/claude-kie-video-migration`
Same path in the Linux shell: `/sessions/dreamy-confident-ritchie/mnt/Rendprop AI/Rendprop Workspace/Worktrees/Active/claude-kie-video-migration`
Branch `claude/kie-video-migration-20261016`, base `462e4c8`. Do not commit (the coordinator commits). Never touch
`Worktrees/Active/build82-launch-checklist` (Codex's shared checkout) except read-only.

Hard boundaries: no live provider/API calls, no paid generation, no credentials, no deploy, no applying migrations
to any real database, no config changes outside disposable local Postgres. Offline tests only.

Tools in the Linux shell: PostgreSQL 18.6 binaries at `/tmp/ep/site/embedded_postgres/pginstall/bin` (initdb, pg_ctl,
psql, createdb); Deno at `~/.deno/bin/deno` (std/npm deps cached). Background processes die when a shell call ends,
so start/stop Postgres inside one call. Each call has a ~170 s limit. `/tmp/kie/pgdev.sh <worktree> <sql...>` starts a
throwaway PG, applies `tests/ci-bootstrap.sql` + all migrations, runs extra SQL, stops (port 55700 — use your own port
in your own scripts).

## The profile (canonical identity)

`services/supabase/functions/_shared/property-video-kie-identity.json` is the single source of truth. The runtime
imports its TS copy `_shared/property-video-kie-identity.ts` (`_shared/property-video-kie.ts:23`), so no deployed
graph imports a JSON module; a Deno test keeps the two equal (`_shared/property-video-kie_test.ts:15`).

- profile `kie-kling3-4k-steady-v1`; provider `kie`; model `kling-3.0/video`; mode `4K`; sound false; multi_shots false;
  5 s; unit `second`; unit_cents 33.5; attempt_cents 167.5 (67 credits/s × $0.005); bonus credits excluded;
  max 2 paid attempts per source (1 + the existing single drift-QC retry); prompt profile `steady-property-v1`
  (= existing `buildSteadyPropertyReelPrompt`), pinned exactly by `prompt_template_token` `{scene_noun}`,
  `prompt_scene_nouns` (home, event venue, restaurant, store, fitness studio, space) and one
  `prompt_template_sha256` per movement (fly_through, push_in, side_glide, pull_back); composition `steady-v2-cfr24`
  (native 24 fps CFR); output 24 fps, 120/121 frames; actual clip short side ≥ `min_short_side_px` 2160 and
  ≥ `min_pixels` 8,000,000 px (the owner/Codex2160 decision is implemented in this private candidate; the 2492×3324 @24
  geometry used in tests is FAL Kling 3 4K output, not Kie evidence); aspect_ratio omitted on the wire
  (official auto-adaptation); privacy tier `trains_by_default` (Kie Terms §3); activation acknowledgement
  `kie-terms-2025-08-01-section-3-owner-accepted` (an operator record, not any user's permission; user permission is
  the separate v2 processor record, see `KIE-CONSENT-CLIENT-PROPOSALS.md`).
- The same JSON, byte-for-byte as jsonb, is returned by SQL `public.property_video_quality_identity('kie-kling3-4k-steady-v1')`
  (migration 20261016100000) and embedded as the expected value in `docs/handoff/KIE-ACTIVATION.sql` (activation
  refuses on any difference) and `docs/handoff/KIE-READONLY-VERIFY.sql`. `property_video_kie_profile_pg.py` reads the
  JSON file and fails if any of the three differs from it. Changing the identity means changing five copies together
  (JSON, TS copy, migration literal, both operator-script literals) and regenerating the PG fixture (next section).
- Route row: `ai_routes.id = 7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21`, task `video.property_reel_clip_kie` (dedicated task
  so the FAL task `video.property_reel_clip` still resolves exactly one row), position 1, provider kie, model
  kling-3.0/video, unit second, unit_cents 33.5, capabilities `{i2v,1080p,5s,native4k,preserve_photo}`,
  max_latency_s 1800, min_plan free, same_model_as `kling_3_pro`, privacy_tier `trains_by_default`,
  params `{"kie_mode":"4K","sound":false}`, note mentions the profile. Seeded `enabled false` (AI-router contract
  §3: a reseller row stays OFF until its terms are owner-approved); only `docs/handoff/KIE-ACTIVATION.sql` enables it.
- Activation (NOT in the migration; owner-approved operator step after deploy):
  `psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v processor_disclosure='<identifier>' -f docs/handoff/KIE-ACTIVATION.sql`.
  `processor_disclosure` is required: the identifier (document version or URL) of the published privacy/consent
  disclosure that names Kie, 1-200 visible ASCII characters (no whitespace, control or non-ASCII characters).
  In one transaction it refuses unless the deployed identity equals the reviewed canonical JSON, takes the
  operator-scripts advisory lock, locks the selector row (then the route row, admission's order), prints the
  previous selector (`absent` if the key does not exist), refuses if it already names Kie or is not a working pre-Kie
  selector (`enabled` false, or true with fal-kling3-4k-v1 / fal-kling3-4k-steady-v2), verifies the pinned row in
  every field but `enabled`, enables only that row and sets (inserting the key if absent)
  `app_config.property_video_quality = {"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}`.
  `property_video_quality_profile()` returns the Kie profile only with that exact acknowledgement; otherwise RP503.
  Existing FAL selector values keep working exactly as today.
- Activation record: the same transaction saves (replacing any earlier one) the separate key
  `app_config.property_video_quality_kie_activation` = `{"profile","route_id","previous_selector":{"present":true,"value":<exact previous>}`
  or `{"present":false}`, `"route_enabled_before","processor_disclosure","vendor_content_license","activated_at":now(),
  "rolled_back_at":null,"rollback_mode":null,"route_disabled_at":null}`. Why this storage: `app_config` has only its
  primary key and NOT NULL constraints, no trigger, admin-only RLS (`is_admin()` SELECT policy; tenants read zero
  rows), no tenant write grant, no invariant that inventories its keys, and the admin edge function already keeps
  audit records under separate keys (`ai_router_last_step_change`, `admin_last_probe`); the migration seeds no record.
  Re-activation after a rollback replaces the record with the then-current previous value.
- Rollback: `docs/handoff/KIE-ROLLBACK.sql` restores EXACTLY the recorded `previous_selector` (deleting the key when it
  was absent) and never a default. DEFAULT keeps the pinned row ON so admitted Kie jobs (frozen identity) can finish;
  `-v emergency_stop=on` also switches the row OFF (unsent Kie clips refuse before any POST). Optional
  `-v previous='<printed value>'` (or `absent`) must equal the record, otherwise refused as ambiguous; with no current
  record (missing, or one that already shows a rollback while the selector names Kie again) `-v previous` is
  required, otherwise refused. When the selector no longer names Kie (after a default rollback) the only allowed run
  is EMERGENCY with the row ON: it switches the row OFF and leaves the selector exactly as it is; anything else is
  refused as nothing to roll back. The record is kept as the audit trail: `rolled_back_at` + `rollback_mode`
  (`default`/`emergency`) when the selector is restored, `route_disabled_at` when the row goes OFF. The restore target
  comes from that durable record (`KIE-ROLLBACK.sql:4-8`, `:152-160`); remaining K10 gaps are listed under
  "Not implemented / unproven".
- Read-only verification: `psql "<db-url>" -X -v ON_ERROR_STOP=1 -f docs/handoff/KIE-READONLY-VERIFY.sql` (its own
  `BEGIN ... READ ONLY` / `ROLLBACK`): 18 boolean checks plus `all checks` — identity equals the embedded canonical
  JSON, NULL for legacy/FAL, `quality_identity` column, freeze trigger, profile constraint, the six post-patch md5 pins,
  pinned Kie row, one Kie task row, FAL row `b04b57c1-12c8-44f9-9c64-e06561358f01` unchanged, one FAL property task
  row, selector, activation record, phase (`not activated` / `activated` / `draining` / `Kie off`; `drain over` and
  hand-made states are false) — then the stored selector, row state, record and Kie job counts/latest deadline.
- Invariant `every kie / higgsfield row is disabled and assumes trains_by_default` (#144, still 270 in total) accepts
  the ON pinned row only (a) under that exact selector AND a current activation record (not rolled back) that
  attests a valid `processor_disclosure` with the same acknowledgement, or (b) after a rollback, while the selector no
  longer selects Kie (the rule `property_video_quality_profile()` applies, extra keys included) and an admitted Kie
  job is draining. Draining (the same test in the invariant, `KIE-ROLLBACK.sql` and `KIE-READONLY-VERIFY.sql`):
  `quality_profile='kie-kling3-4k-steady-v1' and state in('queued','generating','quality_review','composing','failed')
  and cancelled_at is null and deadline>now()`. The four active states are the worker-scope test; `failed` is a pause
  the owner can still resume before the deadline (capacity, quality or CPU recovery), and its resume quote and unsent
  clips read the pinned row, so it must keep the row ON. `ready`, `cancelled` and `needs_reconciliation` are final: no
  SQL function moves a job out of them (an uncertain dispatch is only reconciled through the metadata-only cron, which
  never reads the pinned row). The deadline is set once at admission and never extended, so the drain still ends by
  the last Kie job's 24 h deadline. Selector + row set by hand, the record removed, or a hand-edited Kie selector with
  an extra key while a Kie job drains, are red.
- Post-patch body md5 pins (unchanged by the identity update; anchors verified first): quality_profile `9671b48a…`,
  quality_freeze `8690864e…`, job_admit `27144ffa…`, paid_quality_processing_budget `a28d26cf…`, audio_preflight
  `e9f7f8c6…`, background_video_delivery `7c8f938e…` (full values in the migration and the verify file).

## SQL ↔ Deno identity fixture (G1: harness code added, first run pending)

- `services/supabase/functions/ai-video/fixtures/kie-property-identity-pg.json` (read by the Deno identity test) is the
  exact `psql -At` text of `select json_build_object('quality_identity', public.property_video_quality_identity('kie-kling3-4k-steady-v1'), 'pinned_route', (select to_jsonb(r) from public.ai_routes r where r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'))::text;`
  on the migrated schema (row seeded OFF), with `"(created_at|updated_at)": "[^"]*"` replaced by `2026-10-16T00:00:00+00:00`.
  `property_video_kie_profile_pg.py` asserts byte equality (fresh, replay, later schema), the SQL fixture asserts the
  same text and that an admitted Kie job's `to_jsonb(job)->'quality_identity'` text equals the identity part; controls:
  one changed identity value in the file, in the expected job identity, or in the installed function fails it.
  Changing the identity or the pinned row's columns means regenerating this file too.

## Kie capacity pause → resume (no SQL function change; G1 fixture added, first run pending)

- The worker files a Kie vendor-account refusal (definite 401/402/403 with the hold released by
  `app_video_cost_release_rejected(...,<status>,'upstream')`, or a missing `KIE_API_KEY` before any hold) as
  `property_video_job_failure(...,'capacity_before_dispatch',false)`. The existing generic
  `property_video_job_resume(actor, job, quote)` then resumes it (quote = 167.5 × pending+failed shots; the capacity
  resume checks capacity only, each attempt still reserves its exact 167.5 before dispatch): sources `pending`, new
  request key at the next claim, `admission_retries`+1, frozen profile/identity unchanged, refused after 3 resumes. An
  unreleased Kie hold cannot be filed as a capacity pause (RP409) and, filed ambiguous, is `needs_reconciliation`
  (not resumable). `property_video_submit_refusal` stays FAL-only (null for every Kie attempt; body md5
  `86d81ed9057049780f6fb2d53618304a` unchanged by the Kie migration).

## Open: paid-quality floor during a drain (G1 finding from code reading; not yet proven in the harness or fixed)

- `paid_quality_processing_budget` grants the bounded paid-quality floor (Starter/Solo 6500, Pro 12000, Team 30000)
  only while the CURRENT selector is a quality profile. A default rollback that restores a non-quality selector (the
  migration default `{"enabled":false,"profile":"fal-kling3-4k-v1"}`, or absent) drops it for every org at once:
  `org_entitlement` falls back to the base ceiling (Starter/Solo 2032, Pro 4157, Team 10532), `plan_serving_ceiling` to
  the receipt envelope and `org_month_spend_cents` to the calendar month. An admitted Kie job of an org whose spend is
  above base ceiling − 167.5 is then refused RP402 at its next reservation (first dispatch of a remaining shot, the
  single quality retry) and at a capacity resume (`property_video_recipe_capacity`). Restoring a FAL quality selector
  keeps the floor. Proposed md5-anchored fix: the floor also applies while the billing org has a draining Kie job
  with the canonical frozen identity (same state set as above); FAL selectors return before the new branch.
- Status 2026-10-16: that branch is now in source in migration
  `20261016110000_property_video_kie_scope_consent_drain.sql` (`:6-12`, `:246-252`), not yet executed or proven.

## Frozen identity at admission

- New nullable column `property_video_jobs.quality_identity jsonb`. The freeze trigger sets it at INSERT for the Kie
  profile from `public.property_video_quality_identity('kie-kling3-4k-steady-v1')` (returns exactly the canonical
  JSON) and leaves it NULL for legacy/FAL profiles (their behaviour is unchanged). It is immutable on UPDATE, like
  `quality_profile`.
- Admission (`property_video_job_admit(...,'kie-kling3-4k-steady-v1')`) also verifies the live route row equals the
  identity (id, task, provider, model, unit, unit_cents, params, enabled, privacy tier) or refuses RP409, and requires
  `p_quote >= 167.5 * source_count` (generation-only minimum, like FAL's 210). 24 h deadline like the FAL profiles.

## Runtime contract (TypeScript)

- Quote and dispatch read the pinned route row by id (NOT `resolveRoute`, whose privacy rule drops
  trains_by_default for customer media; the gate above is the explicit, recorded decision) and assert every field
  equals the identity. No FAL step is ever returned for this profile; mismatch = 503/RP409, no generation.
- Worker → ai-video scope carries `qualityProfile` and `qualityIdentity` (from the job row); dispatch refuses before
  any POST unless `sameKiePropertyIdentity(job.quality_identity)` and the live row matches.
- GenerateInput for this profile: `{task:'video.reel_clip', prompt:<steady prompt>, image_url:<https presigned GET of
  the exact verified owned source object, 7200 s>, seconds:5, resolution:'1080p', aspect, framing:'preserve_photo',
  extra:{kie_mode:'4K', sound:false, property_video_target_aspect:aspect, property_video_quality_profile:'kie-kling3-4k-steady-v1'}}`.
- Kie wire for that profile (exact): `POST https://api.kie.ai/api/v1/jobs/createTask`
  `{"model":"kling-3.0/video","input":{"prompt":…,"image_urls":[<url>],"sound":false,"duration":"5","mode":"4K","multi_shots":false}}`
  — no aspect_ratio, no callBackUrl, no kling_elements. Other Kie paths (owner QA, Seedance) keep their exact wire.
- Definite refusal = Kie envelope (HTTP 200 or 4xx) with code in {400,401,402,403,404,422,429} and no taskId →
  `dispatch_rejected=true` (hold released). Everything else (timeouts, 5xx, 455/500/501/505, code 200 without
  taskId, malformed JSON) is ambiguous: hold retained, no second POST.
- Poll never trusts Kie's echo. The worker accepts a retained clip only if actual MP4 facts satisfy
  `kieProperty4KFacts` (24 fps, 120/121 frames, short side ≥ identity `min_short_side_px` = 2160, ≥ `min_pixels` =
  8 MP, 5±0.1 s; thresholds read from the identity); otherwise
  `source_video_unverifiable` (no extra paid attempt beyond the existing single drift retry policy).
- Retention (G2, source-present, not executed): `persistResult` stores a Kie MP4 whose download header is missing,
  `application/octet-stream`, `binary/octet-stream` or a case variant of `video/mp4` as `video/mp4`
  (`_shared/providers/common.ts:496-504`). The worker then ends a Kie clip as terminal `source_video_unverifiable`,
  before reading any byte, when the retained object is unchanged (same bytes, an ETag) but stored with another type or
  larger than 64 MiB (`property-video-worker/engine.ts:53-63`). These two cases no longer loop to the deadline.
  Still re-polled until the deadline: transport errors, a missing or changed retained object, and results the
  persistence step refuses (over 100 MiB, image extension) (`engine.ts:44-46`, `:59`; `ai-video/index.ts:2288-2293`).
  FAL and legacy keep the old loop.
- Composition: the worker sends `composition_profile:'steady-v2-cfr24'` for both steady profiles; finish/attest/
  delivery/audio-preflight treat `kie-kling3-4k-steady-v1` as a 24 fps profile exactly like `fal-kling3-4k-steady-v2`.
- Historical FAL jobs (`legacy`, `fal-kling3-4k-v1`, `fal-kling3-4k-steady-v2`) keep their exact routes, prompts,
  receipts, polls and recovery functions.

## Native-pixel policy — owner/Codex2160 decision implemented privately

- The current candidate requires a retained Kie clip's actual short side to be at least2160 AND width × height
  to be at least8,000,000pixels. The helper also requires finite measured facts, native24fps CFR,120/121frames
  and5±0.1seconds; the worker separately requires coverage of the1920×1080 or1080×1920 job canvas. Source-auto
  aspect, faithful crop and no upscale remain unchanged. Provider `4K` labels are not actual pixel evidence.
- The canonicalJSON, TS mirror, SQL identity and the reviewed Activation/Verify/OwnerGrant identity copies
  all use `min_short_side_px:2160`. Other identity keys, prices, prompt digests, generic1080p delivery wire,
  six first-migration body rewrites and the second migration's three rewrites/eight replay pins are unchanged.
- Actual helper/poller tests accept3840×2160 and2160×3840; they refuse8192×1080,1080×8192,4068×2032,
  1952×4236 and2159×4000.2160×3600 fails the8MP area floor;2160×3704 passes geometry alone. Thus this is
  an8MP-plus-short-side rule, not a requirement for an exact3840×2160 canvas. No paid output quality is implied.
- The earlier1080-plus8MP candidate and its under2160 synthetic passing fixtures are historical. Original
  snapshots, fixtures and receipts remain unchanged. The actual8192×1080 causal test fails under that old
  identity and passes under the prospective2160 identity. The regenerated golden comes from the actual
  isolated181-migration PostgreSQL query, with only the two route timestamps normalized.
- Root's read-only live precheck at2026-10-16T21:31:36Z found no deployed Kie identity/grant table, no Kie route
  or admitted Kie jobs and neither candidate migration in history. That evidence permits this prospective
  same-named identity change; it does not permit rewriting any accepted historical identity. A later change
  after admission requires a separately versioned identity. FAL jobs keep their original frozen contracts.
- Exact source and retained offline proofs are under
  `/Volumes/Rendprop Files/Builds/Active/build87-kie-2160-harmonization/implementation`;
  `CORE-STATIC-CONTRACT.json` binds the three single-literal production changes and unchanged hardening pins.
  This is private/offline work. Kie remains unactivated; no real Kie4K output has been accepted or measured
  by this server path, and motion/fidelity parity remains unproven.

## Not implemented / unproven (2026-10-16)

The candidate claims none of these. Each needs its own implementation or proof before a quality claim or activation
(review packet `:14`, `:18-19`).

- Durable per-shot temporal HOLD and finish/publication gate (Codex K06/K07,
  `READONLY-ACTIVATION-GATES.json:158-185`): not implemented. The worker's quality step sends three frames to the drift
  check and calls `property_video_job_qc` (`property-video-worker/engine.ts:88-94`), which checks the paid drift receipt
  and marks the source ready (`migrations/20261014183851_background_property_videos.sql:183-190`). No temporal
  measurement is requested or stored: nothing under `functions/property-video-worker` mentions `temporal`.
- Temporal diagnostics and stabiliser: inactive. `motion_qc.py` (`temporal-motion-v2`) is diagnostic-only with
  provisional thresholds; `smooth_finish.py` is not wired into compose or publication
  (`services/edge/property-video-render/README.md:40-56`).
- No paid frozen or no-motion shot accepted as generated motion (K08, `READONLY-ACTIVATION-GATES.json:186-197`): no
  policy implemented.
- 100-shot workload and watchdog (K09, `:198-211`): unproven. The renderer controller keeps a 20-minute CPU timeout
  (`services/edge/property-video-render/src/index.ts:19`, `:195`), not changed for a stabilised profile
  (`services/edge/property-video-render/README.md:55-56`); hosted 100-shot throughput is a release acceptance item
  (`services/supabase/functions/property-video-jobs/README.md:140-143`).
- Capability expiry at scale: unproven. Worker media capabilities default to 600 s and 1800 s for compose narration
  (`property-video-worker/engine.ts:95`, `:103-104`); nothing shows they hold across a full 100-shot job.
- A real Kie MP4 through the server path: none. No Kie 4K MP4 has been accepted by this poll/compose path, and the repo
  records no retained Kie 4K clip. The 2492×3324 @24 geometry used in tests is FAL Kling 3 4K output
  (`docs/handoff/OWNER-CONTEXT-20261014.md:456`, `:489-491`); the current helper/poller labels explicitly
  identify that geometry as FAL-derived synthetic input, not retained Kie output. Files under `/Volumes/Rendprop Files/Builds/Active/build82-kie-*` exist; this lane could not probe or
  attribute them, so they are not cited as evidence.
- Walking/bob motion: not fixed. The owner rejected the 14-photo video's motion (`OWNER-CONTEXT-20261014.md:69`). This
  profile sends the same `steady-property-v1` prompts (identity `:20-35`) to the same Kling 3.0 family as FAL steady-v2
  (`same_model_as` `kling_3_pro`, `20261016100000…sql:21`). Moving that model family to Kie does not change its
  motion, and the 24 fps cadence does not remove generated camera bob (`services/edge/property-video-render/README.md:37-39`).
- Final verification: the G-wave and `20261016110000` edits have never been run; earlier F-wave counts are not evidence
  for this tree; the Kie PG driver is not in CI.
- Operator controls (K10): activation takes no exact expected baseline (`docs/handoff/KIE-ACTIVATION.sql:101-111`);
  rollback accepts `-v previous` when the record is missing and checks only that the current selector names Kie
  (`docs/handoff/KIE-ROLLBACK.sql:152-167`); no concurrent or lost-reply operator proof. Rollback-to-FAL is not a
  no-new-paid-video hold; the hold script `docs/handoff/KIE-HOLD-NEW-ADMISSIONS.sql` named by
  `20261016110000…sql:34-37` is not in the worktree.
- Owner-only test grant and processor permission: SQL only (`20261016110000…sql:13-33`). No grant operator script
  (`docs/handoff/KIE-OWNER-TEST-GRANT.sql`, named at `:32`, absent); no edge wiring (`property-video-jobs/index.ts:18`,
  `:21` still require v1; nothing calls `property_video_kie_dispatch_authority`); no published disclosure; no client
  change. Contract and proposals: `docs/handoff/KIE-CONSENT-CLIENT-PROPOSALS.md`.
