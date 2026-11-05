# Photo Studio production incident — 5 November 2026

Current integration branch: `codex/photo-batch-output-hotfix-20261105` ([PR #47](https://github.com/AaronPilk/RendProp-Ai/pull/47)). This note distinguishes live server behavior from native source awaiting TestFlight/device acceptance.

## Observed incident

- A customer bulk declutter previously failed on a large 4K image because the output crossed the 35 MB response limit. The photo route now requests 2K and keeps the original photo unchanged. The production `ai-photo` and `ai-photo-v2` routes were deployed as versions 94/18, then 95/19 with a narrower QC wording update; those deployments were read back. Build 137 is internal TestFlight, not the public App Store build.
- Four newer QA declutter requests on 5 November yielded two accepted results and two held results. Read-only evidence in `public.photo_edit_evidence` showed no size or credit failure for these four. One held result had an overstrict window-visibility finding; the prospective QC rubric now permits more of the same partly visible window after clutter removal. The other held result may contain a new window and remains private. Existing held results were not silently released or retried.
- In the QA listing, 32 saved versions across 15 photo families were present in cloud backup, but one older selected gallery asset was absent from the phone's local version catalog. The native selection projection treated this unrelated asset as a global reason to block every family, so even accepted decluttered versions showed “Check selection.”
- The native Photo Studio also had a single global job gate: an active Declutter batch prevented independent lawn, sky, and staging jobs. The AI edit source defaulted to the retained pre-enhancement original instead of the verified enhanced capture.

## Native source repairs

- `50d1f4ab`: up to four independent photo batches can run across disjoint photo families, with individual progress, stop controls, and paid-dispatch fences. A family already reserved by a batch cannot be edited again concurrently.
- `277d2f2d`, `eccea326`: default edits and declutter assessment use the verified enhanced capture. The retained original remains for comparison/disclosure; no-enhancement legacy fallback is limited to unaltered base images.
- `83c02a71`: a known family's edited version can be added to the listing while an unrelated older cloud asset remains selected. The older asset and cover are preserved through the server's compare-and-swap request. Unknown states now say “Refresh selection.” Missing server metadata, ambiguous bytes, and incomplete local history still block mutation.
- `c2dbbf84`: updates focused source-contract test fixtures for the multi-job queue.

## Verification and remaining work

Combined integration checks: cloud selection 91 core + 28 wire assertions; photo history/export 684 checks before the final legacy guard (685 after it); queue 39 assertions; edit lifecycle 111 assertions; photo review routing actual + 11 negative controls; family pager actual + 6 negative controls. A combined iOS Simulator build passed before the final one-line legacy guard; a new signed TestFlight build and physical-phone check are pending. The user is using the phone and requested that testing continue without touching it.

Do not call the native repairs live until the new build is uploaded, installed, and checked on-device. Do not retry or release the two held QA results automatically. The focused phone acceptance is: run Declutter on one photo, start lawn/sky/stage on different photos while it runs, confirm separate Activity progress, then choose an accepted decluttered version as “Use on listing” and verify the existing cover/other selected photo remain intact.
