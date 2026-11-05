# Photo Studio production incident — 5 November 2026

Current integration branch: `codex/photo-batch-output-hotfix-20261105` ([PR #47](https://github.com/AaronPilk/RendProp-Ai/pull/47)). This note distinguishes live server behavior from native source awaiting TestFlight/device acceptance.

## Latest device checkpoint (5 November, 5:49 p.m. Eastern)

- Build **1.0.6 (139)** is installed in internal TestFlight on the owner's physical iPhone. The accepted Declutter versions for photo families 11 and 13 both show **Selected for listing** after the phone's actions. The filtered Photos gallery shows both selected badges.
- Live `me` Edge Function v80 removed a false “Disclosure record not found” response for those older accepted, listing-linked edits. Focused tests and downloaded-function readback passed.
- Both saved versions initially failed at the subsequent publication gate with “This saved photo is unavailable for publication.” The current publication contract expected an unbound source, while these valid older accepted edits have a listing ID and a retained original asset. Guarded production migrations **20261105223709** and **20261105224531** now admit only exact same-listing accepted sources with a completed original upload, current source availability, matching private output row, and exact byte proof; the latter migration fixed a missed output-ledger substitution found by the first phone retry. Live `me` v81, `listings` v64, and `property-video-jobs` v38 contain the aligned Edge check, with authentication settings preserved and deployed sources downloaded for readback. Focused integration checks: 36 passed, 0 failed.
- The two final phone choices created accepted `native_gallery_selection_operations` at 22:47 and 22:48 UTC. Read-only production readback confirms both target assets remain in the current gallery (three selected assets total), and both operations preserved the original cover. No earlier failed attempt changed the selection.
- A successful physical-phone overlapping-generation test is still unverified. One-photo lawn and sky jobs both completed, but the first finished before the second was submitted.

## Observed incident

- A customer bulk declutter previously failed on a large 4K image because the output crossed the 35 MB response limit. The photo route now requests 2K and keeps the original photo unchanged. The production `ai-photo` and `ai-photo-v2` routes were deployed as versions 94/18, then 95/19 with a narrower QC wording update; those deployments were read back. Build 137 contained the first native batch/output repair; Build 138 contains the later photo workflow repairs in internal TestFlight. Neither is the public App Store build.
- Four newer QA declutter requests on 5 November yielded two accepted results and two held results. Read-only evidence in `public.photo_edit_evidence` showed no size or credit failure for these four. One held result had an overstrict window-visibility finding; the prospective QC rubric now permits more of the same partly visible window after clutter removal. The other held result may contain a new window and remains private. Existing held results were not silently released or retried.
- In the QA listing, 32 saved versions across 15 photo families were present in cloud backup, but one older selected gallery asset was absent from the phone's local version catalog. The native selection projection treated this unrelated asset as a global reason to block every family, so even accepted decluttered versions showed “Check selection.”
- The native Photo Studio also had a single global job gate: an active Declutter batch prevented independent lawn, sky, and staging jobs. The AI edit source defaulted to the retained pre-enhancement original instead of the verified enhanced capture.

## Native source repairs

- `50d1f4ab`: up to four independent photo batches can run across disjoint photo families, with individual progress, stop controls, and paid-dispatch fences. A family already reserved by a batch cannot be edited again concurrently.
- `277d2f2d`, `eccea326`: default edits and declutter assessment use the verified enhanced capture. The retained original remains for comparison/disclosure; no-enhancement legacy fallback is limited to unaltered base images.
- `83c02a71`: a known family's edited version can be added to the listing while an unrelated older cloud asset remains selected. The older asset and cover are preserved through the server's compare-and-swap request. Unknown states now say “Refresh selection.” Missing server metadata, ambiguous bytes, and incomplete local history still block mutation.
- `c2dbbf84`: updates focused source-contract test fixtures for the multi-job queue.

## Verification and remaining work

Combined integration checks: cloud selection 91 core + 28 wire assertions; photo history/export 685 checks; queue 39 assertions; edit lifecycle 111 assertions; photo review routing actual + 11 negative controls; family pager actual + 6 negative controls. The CI consent/batch fixture was aligned with the enhanced-capture source and its 48 focused assertions pass. A combined iOS Simulator build passed, and the signed Release archive and internal-only IPA for **1.0.6 (138)** passed signature/UUID checks. Apple build ID `7c9f621d-d47c-45f0-baef-8a57a8304784` is **VALID / INTERNAL_ONLY / IN_BETA_TESTING** and belongs to the existing Rendprop team internal group. The single-upload receipt is stored outside Git at `/Volumes/Rendprop Files/Builds/Active/photo-testflight-138-20261105/HOTFIX-138-RECEIPT.json`. **Build 139** is the phone-tested native version for selecting the two accepted declutters.

Do not call the native repairs public until an App Store update is submitted and released; TestFlight availability is not public release. Do not retry or release the two held QA results automatically. The remaining phone acceptance is a true overlapping run: start Declutter on one photo, start lawn/sky/stage on a different photo before Declutter completes, and confirm separate Activity progress. Previously run one-photo lawn and sky jobs completed sequentially, so concurrency remains unverified on the phone.

At the next device session, resume iPhone Mirroring after the Mac is manually unlocked. Computer use returned “The Mac is locked and automatic unlock could not unlock it” just as the overlapping-job check began; do not infer a concurrency result from the finished listing-selection check.
