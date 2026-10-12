# Build 60 — TestFlight beta feedback fixes

Claude's `claude/build60-feedback-20261011` commits `7d0533a` and `bda5f5d`
were fast-forwarded into `fix/build58-reel-integration-20261011`. All nine Aaron
build-59 submissions and Stephenie's build-56 submission were reviewed.
`docs/releases/BUILD60-FEEDBACK-20261011.json` records the delivery and CI snapshot.

## Changes delivered

- **Share everything** opens a full listing package, with One ZIP file selected
  by default. It includes available local walkthroughs, photos, retained
  verified retained originals when available and enabled, disclosure notes,
  reels, aerial and moving-photo clips, a local 3D scan when present, listing
  details and a README. Separate files offers the media, original/disclosure
  files and listing-details note; the README is included in the ZIP. Missing
  cached media at initial admission or a failed details-file write refuses the
  package with an error instead of sharing an incomplete package.
  The export copy now describes the listing package rather than just photos.
- **Get started** offers Start a new home before the existing homes when there
  are multiple listings. Cancellation clears the pending feature intent.
- A definitive reel refusal clears its saved request so Generate can be used
  again. **408, 409, transport loss and 5xx retain the marker**: 409 can mean a
  request was already admitted, so clearing it could submit another paid job.
- Sold timestamp acknowledgements compare instants within one millisecond;
  the exact server baseline remains available for compare-and-set. This clears
  the Z-versus-+00:00 sync loop without discarding a newer local edit.
- Aerial intro sits beside Re-render fly-through. Share everything and Listing
  contact precede the Coming soon cards. Measurements and 3D availability is
  unchanged. Aaron already confirmed republish and reconnect recovery on 59.

Claude's server fixes were **already deployed**: migration live version
`20261011230539`, listings 52 and ai-video 66. The tree includes the migration
and `BUILD59-FEEDBACK-BACKEND-20261011.json`; its 53 source hashes match. This
delivery did not redeploy, reapply migrations, rotate credentials, change
funding, or alter pricing.

## Verification

| Check | Result |
| --- | --- |
| Deno functions | 1,907 passed, 0 failed, 1 ignored |
| Standalone route/upload tests | 76 passed across six isolated suites |
| Database runner controls | 37 passed |
| Disposable PostgreSQL | 270 invariants and 52 build controls on fresh and historical replay; 424 commands, race and negative controls passed |
| Reel recovery | 125 actual assertions plus 14 dispatch assertions; 16 compiled negative controls |
| Actual photo/package renderer | 148 assertions; 12 negative controls, including videos-only ZIPs and exact media bytes |
| Actual listing package assembly | 44 assertions; 4 negative controls for missing media, failed notes, refused admission and modified originals |
| Listing facts synchronization | 109 assertions; 9 negative controls, including equivalent timestamps and newer local edits |
| Presentation privacy | 36 assertions; 11 negative controls, including clearing package extras and errors after account/workspace changes |
| Release simulator UI | All 13 cases covered: 12 passed in the full run, then the corrected venue case passed separately |
| Shipping boundaries | Ordinary/lab compile controls passed; ten simulator-only fixture markers absent from the signed physical app |
| Archive/export | 1.0.4 (60), signature verified, executable/dSYM UUID match; IPA exported and uploaded without build-number renumbering |

The first UI run's venue assertion read a lazily mounted card after it was
offscreen. `1a090bb` scrolls that card into view before checking the same label.
The original failed result and the passing focused rerun are retained. The
new whole-package and two Home tests passed in the full run.

First CI run `38184964038` had two fixture/scan problems corrected in
`adc3619`: the privacy harness's closed template lacked the new package state,
and four exact deployment-manifest source checksums triggered the secret
scanner. Those checksums were recomputed from source; only their exact
historical fingerprints were excluded. No credential or broad path/rule
exclusion was added. The new full run is `38185550169` on `1a090bb`; its
privacy step and secret-scan job pass. Its final status belongs in the receipt.

The first CI run also failed the unchanged Studio finishing export's duration
oracle. Planned duration was 8 seconds; the artifact contains 8.539800 seconds
of video and 7.912917 seconds of AAC, a 626.883 ms mismatch. This is a real
encoded duration discrepancy, not a missing dependency or a false assertion.
The prior build-59 hosted discrepancy remains recorded separately. No export
code or timing/audio oracle was weakened; a later passing run does not erase
this failure or constitute an exporter fix. The investigation evidence is in
`~/Rendprop AI/_bridge/build60-ci-export-review/`.

These checks use synthetic transports, disposable databases, actual local
file/rendering code and simulator UI. They do not certify phone acceptance,
provider generation quality, or a new live-provider run.
ZIP preparation also rechecks media readability. Separate files does not
recheck extra-file readability after the export sheet opens; a file disappearing
during that interval remains an untested delivery race.

## Source and Apple boundaries

Archive source is `17808cc4c14e23a132d028141608325d41f7c7e0`. The current code/test
tip `1a090bb484e839868b8950f2b6d8253052215599` has identical shipped app, project
configuration and Xcode-project trees; later commits only update tests and
their scan configuration. UUID: `1B02EF8B-FBE1-30EE-A0C5-61491DF38AED`.
The receipt distinguishes archive source from test/documentation commits.

Delivery is **internal TestFlight only**. App Store 1.0.4 (57) remains associated
with build `46e2df20-e688-4e14-afa7-88655f28e8ba`, WAITING_FOR_REVIEW and MANUAL.
No release, withdrawal, resubmission, version attachment, or John Apple change
was made. Upload success alone is not counted as TestFlight availability:
the receipt records Apple's processing and group relationship readbacks.

Apple completed processing: build `4d353aef-a30b-4c73-86d4-b12ac7f6268e` is
**VALID / IN_BETA_TESTING**, included in the existing internal Rendprop team
group. Testing notes were written and read back exactly; non-exempt encryption
is false. The App Store 57 association and manual release state remain unchanged.

At the delivery snapshot, CI `38185550169` has **11 successful jobs and one
still running** (the hosted native audit). The complete unchanged tour-host
audio/export suite passed on this run. This is a passing verification, not a
code repair of the earlier retained export discrepancy. The receipt is a
timestamped snapshot, not a claim that all twelve jobs have completed.

## Phone acceptance on 60

1. Open 855 Central Ave and refresh; the sold facts should stop waiting to sync.
2. With two or more existing homes, tap Get started, choose Start a new home, and name it.
   Cancel once and verify an old queued feature does not reopen.
3. Open Share everything on a listing with photos and video. Save the ZIP to
   Files, unzip it, open the tour and photos, and verify disclosure/original
   files and listing-details.txt. Check Separate files too.
4. Generate a reel with the chosen photos. A validation/allowance refusal
   should allow correction and retry; a timeout or already-started response
   should offer saved-request recovery rather than a second paid submission.
5. Delete a disposable listing, find it in Settings → Recently deleted, and
   restore it with its original URL.

Public/manual release remains held for phone acceptance and the tracked export
discrepancy. Build 60 is an internal acceptance build, not a replacement for
the App Store submission.

## Claude's independent review — 2026-10-12 UTC

Claude checked ancestry, shipped tree equivalence, the three product corrections,
exact checksum exclusions, the previously deployed backend, TestFlight validity
and the retained export discrepancy. His verdict agrees with this delivery:
GO for internal acceptance of 60; hold public/manual release until the phone
checklist passes. Mac harness/UI, archive and internal-group proof remain
Codex-verified rather than independently re-executed by Claude.

Two claims in his section 4 require correction. The hosted native audit uses
`macos-latest`, not Linux (workflow and live job labels agree). It executes
production Swift bodies and listing models as well as actual UIKit/JPEG/ZIP
code in an iOS simulator. A late failure could identify app behavior, fixture
issues or infrastructure; the failed step and receipt determine its class.
Running offline or extracting source does not establish that a failure is
harmless. The job remains pending at this review snapshot; no ad-hoc rerun,
product change or deployment was made to obtain a green result.

After phone acceptance, the choice between keeping 57 as submitted or replacing
it with 60 remains a separate submission decision. Neither review authorizes
automatic Release or withdrawal of the existing submission.
