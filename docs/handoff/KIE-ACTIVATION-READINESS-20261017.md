# Kie activation readiness (offline), 2026-10-17

Branch `claude/kie-readiness-20261017`, base `9670ddd`. Nothing here is deployed, and nothing called Kie, FAL or any paid provider. Kie activation and all paid generation stay paused until the owner lifts the hold. This note says how to switch Kie on when that happens, what the offline work proves, and what only a paid run can prove.

## What keeps Kie unreachable today

1. The pinned route row `7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21` (task `video.property_reel_clip_kie`) is seeded `enabled=false` by migration `20261016100000`. `kiePropertyRouteStep` returns nothing unless the row is `enabled=true` and matches the frozen identity, so dispatch answers 503 before any hold or request. The reserved dispatch reads the row again just before the POST.
2. The global selector `app_config.property_video_quality` is the migration default `{"enabled":false,"profile":"fal-kling3-4k-v1"}`. No job can be admitted on `kie-kling3-4k-steady-v1` until `KIE-ACTIVATION.sql` runs or an owner test grant exists (`KIE-OWNER-TEST-GRANT.sql`, which refuses until the processor contract is published). Before any Kie POST, `property_video_kie_dispatch_authority` must return `activated_profile` or `owner_quality_test`.
3. The three older Kie rows (`video.reel_clip` #2, `video.aerial_no_photo` #2, `video.upscale_4k` #1) are seeded `enabled=false`. The CI invariant in `services/supabase/tests/invariants.sql` ("every kie / higgsfield row is disabled ...") checks this. It runs in CI and regression, not as a runtime constraint.
4. The one other path to Kie is the owner reel comparison grant `app_config.owner_reel_provider_qa`. It needs an explicit admin-only write with consent `owner-authorized-kie-media-qa-2026-10-12`, the owner's own listing and a window of 24 h or less. Read it before activation; none should exist.
5. If `KIE_API_KEY` is unset, every Kie adapter call refuses before a request exists (`kieKey()` in `_shared/providers/kie.ts`).
6. This branch adds no route, selector, grant, secret or migration. K1 (the diagnostic) and K3 (terminal handling) act only on an existing Kie receipt, and 1-4 prevent one from being created.

## Activation steps (owner-approved only)

Preconditions: the owner lifts the paid-generation and Kie holds; the disclosure naming Kie is published (its identifier goes in `processor_disclosure`); and the processor-permission contract is published in `app_config.property_video_processor_consent`. Activation refuses without the contract, as K4 proves.

1. Deploy the edge functions from this branch (order and rollback below). They stay inert while the row is OFF.
2. Set the function secret `KIE_API_KEY`. The owner enters the value; it is never printed or logged.
3. Optional live key test, which generates nothing: `GET /admin/providers/probe`. Its Kie row reads remaining credits from `api.kie.ai/api/v1/chat/credit`.
4. Read the three baselines and confirm every migration check is true:
   `psql "<db-url>" -X -v ON_ERROR_STOP=1 -f docs/handoff/KIE-READONLY-VERIFY.sql`
   The values are `property_video_quality_sha256`, `kie_route_enabled` and `kie_activation_record_sha256`.
5. Activate, as the role that applies migrations:
   `psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v processor_disclosure='<identifier>' -v expected_selector_sha256='<sha256-or-absent>' -v expected_route_enabled='false' -v expected_record_sha256='<sha256-or-absent>' -f docs/handoff/KIE-ACTIVATION.sql`
   It enables only the pinned row, sets the selector to `{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}`, writes the activation record and prints the new baselines. Keep that NOTICE line, because rollback needs it.
6. Health check: `GET /admin/health`. Expect `kie_property_route_enabled: true` and the `kie` row with `optional: false`. `unconfigured` means the secret is missing, so roll back. `idle` (no Kie ledger rows in 7 days) is expected until the first clip, and `ok` follows delivery. Re-run `KIE-READONLY-VERIFY.sql`.

## Rollback

- Stop new Kie admissions and restore the recorded selector: `KIE-ROLLBACK.sql` with the three baselines printed by step 5. Jobs already admitted on Kie can finish within their 24 h deadline.
- Stop unsent Kie clips as well: the same script with `-v emergency_stop=on` (selector restored and row OFF together). After a default rollback and a finished drain, use `KIE-ROUTE-OFF.sql`.
- Stop every new paid property video without switching back to FAL: `KIE-HOLD-NEW-ADMISSIONS.sql`.
- Keep `KIE_API_KEY` set while any accepted Kie task may still be polled. Without it, finished results cannot be fetched.
- Exact invocations and refusal rules are in each script's header.

## Edge functions that change (deploy order, rollback)

No SQL in this branch. Behaviour changes only in:

1. `admin`: `/admin/health` reads the pinned row by id, adds `kie_property_route_enabled`, and makes the KIE row required only when the row is ON. While it is OFF, the body matches today's apart from the new field. A failed route read is a 500, like the other health reads.
2. `ai-video`: a Kie routed status whose finished result can never be stored (an image extension, or over the 100 MiB persist limit) answers a terminal `failed` with `result_unretainable`. It does so only once that receipt's payment is booked (see the fix below); otherwise it keeps the old retryable 503. Every other provider is unchanged.
3. `property-video-worker`: it bundles its own copy of `ai-video` and polls in process, so it needs its own deploy to get item 2. Its poll maps that terminal answer to `source_video_unverifiable` for the Kie profile only. The operator diagnostic gains a read-only Kie branch: one `recordInfo` read reporting state, credits and the result host.

Use `services/supabase/deploy-functions.sh --functions admin,ai-video,property-video-worker`. It is a dry run that stages and hashes; add `--run` to deploy. Any order is safe, since there is no cross-function wire change. Rollback is redeploying the same three from `9670ddd`. `property-video-jobs` bundles `ai-video/index.ts` for the recipe quote only, and functions importing `_shared/providers/common.ts` pick up an inert flag on their next deploy.

**Fix made in this review (`6620fde1`).** As first written, K3 answered terminal on the first finished poll even when the accepted payment had not been settled (`app_video_cost_settle` failed after acceptance, so the priced hold was kept). The worker then failed the attempt and stopped polling. The only repair for a held acceptance, the post-expiry status poll (`paidRoutedReceiptMatches(routed,true)`, token TTL 2 h), would never run, and the hold would stay neither booked nor released. The terminal answer now needs one settled, unreleased reservation for that exact receipt, matching the order the existing Kie stored-object gate already uses. The customer allowance itself is unchanged: by design, an async failure after acceptance never refunds it, the same as `provider_terminal_failed`. Both codes are plain terminal failures in `property_video_job_failure` and resume none.

## What the offline work proves

| | Proof | Result (2026-10-17, this branch) |
|---|---|---|
| K1 | `property-video-worker/provider-diagnostic.test.ts`: Kie branch against closed doubles and the real adapter poll; identity tampering and cross-provider receipts refused before any read; FAL branch byte-identical | 15 passed |
| K2 | `property-video-worker/kie-uhd-rehearsal.test.ts`: real adapter, `routedStatus`, journal, `persistResult`, R2 signers, worker poll/quality/action and MP4 probe, with ffmpeg-made 3840x2160 and 2160x3840 CFR24 120-frame clips through to the exact `ComposeAction`; negatives: 1080p "Pro" substitute, 23.976 fps, `.mov`, 64 MiB + 1 | 8 passed, 0 ignored |
| K2 | `test_cpu.SteadyCadence.test_native_uhd_sources_scale_down_centre_crop_and_keep_every_frame` (run alone): scale-down, centre crop, every frame once, sources unchanged, 23.976 fps refused | 1 test OK (6 composes, 31 s) |
| K3 | `property-video-worker/kie-unretainable-result.test.ts`: terminal only for Kie and only with a settled payment; held, released or foreign payment, and read failures keep the 503; FAL unchanged; 4 compiled controls | 10 passed |
| K3 | `admin/health-kie-required.test.ts`: row OFF matches the forced-off reference; row ON makes only KIE required; 2 compiled controls | 4 passed |
| K4 | `services/supabase/tests/property_video_kie_consent_seed_pg.py`: actual `KIE-ACTIVATION.sql` and `KIE-ROLLBACK.sql` on a disposable PG with a synthetic contract; exact record shape; v2 admits, v1/missing/stale refuse; 6 refused runs change nothing | 183 migrations, 15 checks, 6 refusals, 36 assertions |
| All | Every test file in `property-video-worker`, `ai-video` and `admin`, plus the 3 `_shared/providers` files that use `persistResult`/`ProviderError`, run one file at a time | 52 files, 810 passed, 0 failed |

CI: the edge job already collects the Deno files, but it has no ffmpeg, so there the K2 media cases report as ignored. The renderer job now runs K2 with ffmpeg required and refuses any ignored case. It also runs K4 next to the Kie scope-consent harness (`9ca7c390`).

## What only a paid run can prove

- That Kie accepts our exact `createTask` body and presigned R2 image URL, and returns real `recordInfo` success, failure and error shapes. Kie reports errors as HTTP 200 with a body code.
- The real 4K output for 16:9 and 9:16 sources: actual pixels, CFR 24/1, 120 or 121 frames, H.264 MP4, file size within the 64 MiB read and 100 MiB persist limits, and the CDN content type.
- Credits actually charged against the 33.5 ¢/s catalog estimate (167.5 ¢ per clip) and the booked ledger row.
- Queue and latency against the 1800 s route latency and the 24 h job deadline.
- Motion quality: whether Kling 3.0 4K on Kie passes `motion_qc.FINISHED_LIMITS` and the owner's eye. The walking and bob problem is not touched by any offline proof.

## Prepared priced quality test (not run)

This is a FAL test, not Kie, and it is separate from activation. It is written up as "Prepared priced quality test (DO NOT RUN)" in `/home/claude/product-scope/PRODUCT-WORK-PLAN.md` §1(d), which is not in git:

- 6 landscape photos from the new apartment, as one Listing 16:9 job.
- `fal-ai/kling-video/v3/4k/image-to-video` through profile `fal-kling3-4k-steady-v2`, at 42 ¢/s × 5 s = 210 ¢ per clip: $12.60 expected, $25.20 cap with the one paid QC retry per source.
- The oracle is `motion_qc.FINISHED_LIMITS` (`services/edge/property-video-render/container/motion_qc.py`), plus the plan's sequence and CFR24 checks.
- Admission is a short compare-and-set of the global selector during a quiet window. It runs only when the owner lifts the paid-generation hold.
