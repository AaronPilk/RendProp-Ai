# Build 58 integration — 2026-10-11

Release receipt: `docs/releases/BUILD58-CODEX-INTEGRATION-20261011.json`.
The archive source is `fe25aea697ceb98e6dbdea7ac75877db154819db`, a descendant
of Claude's `f3a9190`. Use the receipt for current CI and TestFlight status.
CI commit `6ddc21d` changes only the reel batch test fixture; the three native
app/project trees are identical to the archive, recorded in the receipt.
Apple has processed build 58 as VALID and automatically added it to the existing
internal group, Rendprop team; testing notes were written and read back.
Do not attach this build to the submitted App Store version without Aaron's
decision. Build 57 remains WAITING_FOR_REVIEW, release type MANUAL, with its
original build association; no withdrawal, replacement, release or John Apple
changes were made.

## Integrated changes

Claude's photo ZIP, same-link Republish, 30-day Recently deleted, UUID
normalization and Worker subrequest fixes were reviewed and retained. The
Mac worktree is `~/Rendprop AI/build58-integration`, branch
`fix/build58-reel-integration-20261011`; the sandbox checkout was left intact.
Its nonportable Git metadata was bypassed by importing its objects into the
existing Mac repository and creating a proper attached worktree.

Additional corrections:

- Republish now refuses success while facts, measurements, conflicts, contact
  or gallery changes remain unsynced, and fences results after account/library
  changes. The mock details-only path reports completion with the same link.
- Recently deleted discards late list/restore responses after account or
  workspace changes. Restore and the expiry sweep now serialize on the listing
  row; the sweep skips rows already locked by another operation.
- Reel Studio has four closed presets, default Fly-through, then Slow push-in,
  Side glide and Pull-back. The server owns version-one prompts for the actual
  Seedance 1.0 Pro Fast endpoint. Arbitrary text cannot overwrite these presets.
  Source images are cropped to the chosen output ratio rather than stretched;
  the API receives that same ratio. Saved setups preserve the selection and
  remain readable by Studio.
- Recovered paid reel clips now use first/middle/last decoded frames and the
  stored prepared source in the existing drift-check endpoint before entering
  an edit. A missing source, failed check, changed-property verdict or revoked
  consent preserves the receipt and refuses output. There is no automatic paid
  generation retry. Old receipts without the source require manual recovery.
- Hailuo rejects unsupported five-second requests before dispatch instead of
  quietly billing six seconds, and its prompt optimizer is disabled. The
  current 1080p route does not enable its lower-resolution fallback.
- The shot-planner vocabulary/families, style combination inventory, web API
  inventory and mocked SQL-runner inventory include the added capabilities.
  Legacy motion text remains checked against its unchanged digest.
- Photo export presentation is attached at the screen level. The simulator
  test scrolls the lazy export form before querying its ZIP/separate selector.
  An early test incorrectly expected that below-screen selector to exist.

Prompt sources and limitations are documented in
`docs/reels/SEEDANCE-PRESETS-20261011.md`. These changes do not redesign Home,
Listings or their toolbox.

## Deployment boundary

The website's four status probes now return 200/200/404/404. Studio's connected
build passed exact-file and response-policy readback (35 GETs). Its compressed
asset total is 349,807 bytes against the unchanged 350,000-byte ceiling.

Only new fixes were released to the backend: ai-video 65, ai-copy 38 and
`build58_trash_sweep_lock`, recorded live as `20261011164805`. Their entire
runtime source closures were downloaded and hash-compared (46 and 25 files);
JWT verification remains enabled. The sweep is not client-executable. Claude's
already-live original migration and other functions were not redeployed.
Credentials, funding, prices, allowances and repository visibility were not
changed.

## Verification and its limits

The Release simulator build and signed device archive compile. Both new
XCUITests pass: four preset selections and ZIP delivery choices; same-link
mock republish and Recently deleted navigation/empty state. Restoration itself
is covered by the actual SQL and route fixtures, not claimed as a phone test.
The UIKit export runner passes 87 assertions plus ten compiled negative
controls. Native paid-reel recovery passes 94 assertions, a separate live
dispatch-double check, and fourteen compiled guard-removal controls. Its receipt
is authoritative; an older stdout summary still says thirteen controls.
The serving-photo package passes 160 checks with twelve controls. ASC tooling
passes 213 tests. Deno passes 1,907 tests, zero failures, one intentional skip.
The fresh/replayed database has 135 migrations, 270 invariants on each schema,
and the 42 build-58 assertions on each schema. Final hosted CI is recorded in
the receipt, including any failures and their disposition; no audio oracle
was weakened. The earlier hosted failure was a stale reel batch double
missing the new preset/aspect/space arguments. The corrected actual-loop harness
passes 119 assertions and still rejects swallowed errors. No app binary changed.

No paid four-preset output benchmark or physical-phone acceptance is certified.
Good prompts and a sampled drift detector cannot guarantee perfect geometry,
camera motion or unseen rooms. Fly-through is a short glide within each image;
unrelated photos do not establish continuous whole-house geometry. The
2026-10-22 retirement of Veo 3.1 Fast image-to-video remains a separately tested
cost/privacy/quality cutover before that date.

## Aaron's TestFlight 58 phone checklist

1. Edit and save 855 Central Ave. Confirm the identity/Needs-attention error is
   gone and the saved change survives reopening.
2. Republish an already published test listing. Confirm “Live page updated”
   and verify that the original URL still works and shows the change.
3. Share all photos as one ZIP, including originals from the listing's Files
   action. Open it on a computer: README, JPEGs, disclosure notes and retained
   originals must be present. Try Separate files too.
4. Delete a disposable published listing, open Settings → Recently deleted,
   restore it, and check the same tour URL. Do not delete a customer's listing
   merely to test restoration.
5. Try each reel camera preset on representative approved interior/exterior
   photos. Inspect walls, trim, garage-door colors, windows, furniture and
   movement before approving output. Confirm a rejected/unavailable quality
   check does not silently insert the clip or generate another paid attempt.

TestFlight delivery does not constitute App Store release approval or complete
these phone checks. Keep the manual release hold on build 57.

## Current release decision

Build 58 is available for internal TestFlight testing. It is not an App Store
release candidate cleared for manual release: physical acceptance and the real
four-preset output comparison remain pending. The final hosted CI also remains
in progress at the time of this record.

The first tour-host attempt refused a narrated cadence-control output after
measured media playback lag. No corrupt file was downloaded. This is retained
at `~/Rendprop AI/_bridge/build58-hosted-tour-first-attempt/`, alongside the
passing local 7-check/12-run result on identical exporter/test source. No stall,
RMS, pitch or duration oracle was relaxed. GitHub does not accept the isolated
job retry while the native job remains in progress; no retry has started.
A passing retry must not be described as a code fix or erase the first result.
