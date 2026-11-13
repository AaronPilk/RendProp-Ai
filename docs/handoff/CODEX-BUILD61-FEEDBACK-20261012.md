# Build 61 — reel downloads, complete photo history and Home address entry

Claude's `claude/build61-feedback-20261012` (`329c617`, code `ac8d882`) was
merged into `fix/build58-reel-integration-20261011`. It could not fast-forward
because the completed build-60 review/CI records had advanced independently;
those records were preserved. Code/archive checkpoint: `fbcecde`. The later
`5613859` changes only the export UI test's switch target. Shipped app, project
and project.yml trees are identical between those checkpoints.

This delivery is **iOS 1.0.4 (61), internal TestFlight only**. Nothing in the
backend, migrations, website, Studio, provider credentials, funding or pricing
was changed or redeployed. App Store 1.0.4 (57) stays in review with manual
release; no release, withdrawal, resubmission or John Apple change is authorized.

Apple processed build `ab02d80e-f2b4-4133-b8b6-cc58dfa4ee57` as **VALID** and
**IN_BETA_TESTING**. The existing **Rendprop team** internal group contains 61;
the English testing notes were saved and read back exactly. The signed IPA is
24,122,669 bytes. App Store build 57's association, WAITING_FOR_REVIEW state and
MANUAL release setting were read back unchanged after this delivery.

## Resulting behavior

- Reel downloads get a unique `.mp4` path before AVFoundation reads them.
  Existing sibling files are never deleted to make room. An actual simulator
  test used identical 10,369-byte H.264 MP4 data: `.tmp` yielded no frames and
  unavailable duration; `.mp4` and the real normalization helper yielded three
  frames with unchanged bytes. An unreadable clip does not send an empty drift
  request; Reel Studio preserves its accepted request for recovery.
- Status polling retries eligible transport/timeout/gateway errors, up to six
  consecutive misses. Cancellation, identity changes and definitive refusals
  still stop. Identity and the five-minute polling deadline are rechecked
  after sleeps and replies; recovery does not submit a second paid generation.
- Reel work uses a finite OS background grant. Expiry ends the correct grant
  synchronously; an old expiry callback cannot end a later grant. Completion
  notices appear only while the app is backgrounded, with notification
  permission already granted, and only for the captured account/session.
  Account changes during the settings lookup cannot enqueue an earlier notice.
- Home's new-home sheet now offers MapKit address suggestions and Use current
  location. Both Home and Listings forms cancel/fence late location/geocoder
  responses so they cannot overwrite newer typing or a changed account/library.
  MapKit suggestions can require Apple's network service; they are not certified
  as an offline lookup. The simulator current-location fixture is absent from
  the signed physical app.
- Restore confirms after the server reply, without waiting for the full library
  refresh. The refresh waits out an older in-flight snapshot, then requests a
  fresh one. Captured account/revision/library checks protect dispatch, replies
  and confirmation; delegated storage-org behavior remains supported.
- Share everything includes the verified retained original and **every saved
  version permitted for download**, including the exact stored current output,
  alongside the
  rendered `-edited.jpg` delivery copy. Content-derived PNG/HEIC/JPEG suffixes
  avoid mislabeled bytes. Version filenames sort chronologically, each carries
  a disclosure note, and the README explains the copies. Unreviewed custom
  versions/descendants are withheld and counted. Missing permitted files or a
  changed history refuse the export rather than producing a silently partial
  package. ZIP creation streams 1 MiB chunks and checks size/CRC during copying.
- The single-photo animation path, which shares download normalization, now
  checks its captured account/revision/library/consent before paid dispatch,
  after asynchronous work and before output display/save.

## Verification

| Check | Passed |
| --- | --- |
| Reel request/recovery | 157 assertions + 14 LAB dispatch assertions; 24 compiled negative controls |
| Reel lifecycle/notifications | 34 assertions; 6 negative controls, including actual disappearance cleanup |
| Actual AVFoundation simulator | 16 assertions; 2 negative controls |
| Moving-photo context | 22 assertions; 6 negative controls |
| Actual UIKit photo/version export | 244 assertions; 20 negative controls |
| Whole-listing package assembly | 44 assertions; 4 negative controls |
| Photo history/export geometry | 536 assertions |
| Home/location/restore boundaries | 48 assertions; 11 runtime controls and 2 compile-failure actor-isolation controls |
| Listing facts | 109 assertions; 9 negative controls |
| Presentation privacy | 36 assertions; 11 negative controls |
| Republish source controls | 5 tests |
| Unchanged Deno functions | 1,907 passed / 0 failed / 1 ignored |
| Release simulator UI | 14 distinct passing cases: 13 in the first run and the corrected export-switch case in a focused rerun |
| Shipping boundary checks | Ordinary/lab compile controls pass; 12 fixture markers absent from the signed physical binary |
| Signed archive | Signature verifies; executable and dSYM UUID `80A70D12-F559-3111-811A-4C1D6F218877` match |

The first real app compile caught two main-actor-isolated revision reads in the
new restore guard. They were fixed with `MainActor.run`; the closed harness's
isolation was corrected to match production, and compile-failure controls now
reject the original mistake. The full app then compiled successfully.

The initial UI run failed only the new toggle interaction: SwiftUI exposes a
labeled Switch row containing a smaller actual UISwitch. The screenshot and
accessibility tree show the test tapped the label. `5613859` targets the actual
control and waits for both off/on values, preserving the same assertions. The
first failed result and the passing focused result are retained. The Home
address/current-location test does not skip its deterministic location checks
when the optional MapKit suggestion observation is unavailable. In this run,
the captured observation explicitly confirmed MapKit suggestions appeared for
`855 Cen`; current-location filling, cancellation and the unchanged listing
count also passed.

CI was dispatched once on the archive/code checkpoint: run `38267819835`.
The final GitHub readback is **completed / success: all 12 jobs passed**.
No retries were requested. The receipt preserves the earlier 11/12 snapshot
and the later completed state on the same archive commit. Its timestamped status,
Apple processing/group readbacks, source trees,
IPA digest, gate receipts and initial failed controls belong in
`docs/releases/BUILD61-FEEDBACK-20261012.json`. Upload success alone does not
establish TestFlight availability.

## Limits and phone checks

OS background execution is finite and variable, not a guaranteed 30 seconds or
continuous service while the app is closed. Longer reels can pause and require
returning to the app or Recover saved request. Local completion notices cannot
run after the process is killed. A durable server job plus APNs completion
pipeline is **not included** in 61. Single-photo animation still lacks durable
accepted-job recovery; Reel Studio's receipt retention is the tested recovery
path. Unreadable downloaded temporary bytes may be cleaned; a retained receipt
does not certify that an unchecked movie is permanently saved locally.

No new real-provider generation or phone-lock/APNs acceptance is claimed by
the closed harnesses. The earlier Studio export timing discrepancy remains in
the build-60 evidence; a passing later encode is not a repair of that finding.

On 61, use the actual **2320 Chantilly Ct** listing to recover the saved paid
reel request, then generate a reel and inspect a portrait Fly-through from a
landscape photo. Lock/switch apps briefly during generation and check recovery;
if notifications are already allowed, check a completion banner. Home → Get
started → Start a new home should offer typed address suggestions and current
location. Delete/restore a disposable listing. Finally save/unzip Share
everything and check originals, every version, disclosure notes, the tour,
listing details and README, then try Separate files. The new-home picker applies
when there are two or more existing homes.

Claude reported that the earlier **Chantilly Cy** package held imported app
screenshots rather than the real listing photos. That source explanation is
not independently certified here: the current App Store Connect app-scoped
feedback read returned 63 older submissions and no build-60 submission; the
collection-wide build filter was refused (403). All five scenarios supplied in
the handoff were reviewed and exercised with the actual code/closed fixtures.
Raw feedback and signed attachment URLs remain outside Git.
