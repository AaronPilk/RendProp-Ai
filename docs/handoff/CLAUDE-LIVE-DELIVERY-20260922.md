# Rendprop live delivery — September 22, 2026

## What is available

**Internal TestFlight 1.0.3 (31)** is processed and available to the existing
**Rendprop team**. Build ID: `91098553-1499-4579-989b-b19382dd4f42`.
Apple reports `VALID`, `INTERNAL_ONLY`, and `IN_BETA_TESTING`; the build is listed
in that group's relationship. Public App Store versions remain unchanged.

**Studio is live at https://studio.rendprop.com.** Its current deployment is
`39aec793-2c04-4307-a469-d8636334073f`, from application source at `b8b06d3`.
Later changes in this release are test fixtures, CI and documentation, with no
new native, edge-function or deployed Studio application changes.

The native archive is from `337991a05c715893a35aa6c9529c099c8fbe693a`. It combines
TestFlight 30's audited capture release (`0687a0f`) with the native/Studio
continuity branch (`1cac978`). TestFlight 30 had omitted that continuity work
because the branches diverged. This release also fixes three new-listing paths
that saved corrected property facts without marking the draft dirty for sync.

Use `release/complete-product-20260922` and PR
https://github.com/AaronPilk/RendProp-Ai/pull/3 for the integrated source. Claude's
`claude/call-fixes-20260917` at `7bcc624` is an ancestor; its working checkout and
uncommitted files were preserved. No force-push occurred.

## User-visible changes

- The same named account and workspace connect phone listings and uploaded
  media with Studio. Supported native reel setup and saved property documents
  share the existing backend. Local files still need a completed upload before
  another device can use them; full timeline identity across editors is not claimed.
- Studio saves a separate reel under `edit:<property UUID>`. Older workspace
  edits and browser backups remain available through explicit recovery. Pending
  uploads, exports and unsaved work prevent an unsafe property switch.
- A branded “Finish this listing” panel uses the actual saved media, jobs,
  review and publication state to suggest a next step, including photos-only work.
- “Download listing kit” packages selected saved gallery photos, paired originals
  and disclosures, eligible saved videos, property facts and saved script.
  Published links and QR codes are included only when a published tour exists.
  Videos require selection; downloads preserve dirty fields and cancel safely
  on request or account/property changes. Limits: 40 selected items, 128 MiB per
  file, 256 MiB per ZIP. An incomplete download never becomes a partial kit.

## Live backend and deployment facts

Supabase project: `ymgqpbnjpztwjsyvceld`. Only the two missing migrations were applied:

| Migration | Recorded live version |
|---|---|
| 0055_video_reflection_jobs | 20260922203438 |
| 0056_active_photo_fallback | 20260922203448 |

All eight Studio migrations were already live under different timestamp names
and were **not replayed**. Next migrations must be 0057+ after checking inventory.
0056 changes only six already-enabled photo routes' fallback notes. Prices,
models, enabled flags and all disabled route records retain their prior values.

Eleven changed functions were deployed with their existing JWT verification:
admin25, ai-chapters21, ai-copy14, ai-enhance30, ai-photo46, ai-video42,
ai-voice30, coach16, property11, studio7, tours39. Runtime source/dependencies
were read back and matched. The thirteen unchanged packages were also read back
and matched, giving a current comparison of all 24 packages.

Tour-host deployment: `3c9187a5-5390-4838-9143-49e0e0098caf`. Public tour disclosure
keeps reflection work labelled AI video and ordinary Studio output Edited media.

## Evidence and limits

Executed checks include 302 Studio unit tests, 940 edge tests, 24 function
typechecks, 2,745 tour-host assertions, actual browser export checks, disposable
SQL migrations/accounting races, and a native dirty-sync regression with 21
assertions and a fault injection that reproduces the old bug. The kit received
162 independent archive/module assertions and nine independent browser scenarios.
Existing property, branding, theme, refresh/recovery and account isolation browser
fixtures were also run; the refresh fault injection still fails for its intended cause.

All 12 CI jobs passed for `479c943` in
https://github.com/AaronPilk/RendProp-Ai/actions/runs/35784907884. The following
fixture-only commits add the updated connected-browser tests to that same CI
job; consult PR 3 for the final head's check status.

The shared auth test bootstrap now includes Supabase's real `is_anonymous`
column. Eight exact existing Studio migrations run in both fresh database paths
without being incorrectly treated as repeatable CREATE scripts. All other
historically repeatable migrations keep their replay checks. The 266-invariant
inventory is unchanged: 265 pass; existing invariant 155, agent-reel token
headroom, remains visibly red by the prior owner decision. No ceiling was raised.

Production verification includes seven two-session sync groups using a retained
synthetic account, bounded real PNG/MP4 uploads, conflict rejection and exact
shared output bytes. No customer records were used or deleted. An independent
production UI check made 93 GET requests across two sessions with zero page
errors. The latest Studio's 23 served files and SPA entry match the built bytes.
Apple web-auth configuration is enabled and correctly scoped; this does not
establish the owner's interactive Apple sign-in roundtrip.

Full receipts are retained locally under
`/Users/pilksclaes/LocalRendpropAudits/complete-product-20260922` and
`/Users/pilksclaes/LocalRendpropAudits/listing-delivery-kit-20260922`.
These directories include private recovery material: do not commit or publish
their contents wholesale. The historical `call-20260919/web/run-erase-postgres.py`
has an obsolete blanket Studio migration replay; use the current database runner
or `complete-product-20260922/verify_backend.py` instead.

## Remaining work is not marked complete

There is **no camera available to this agent**. Physical recording, focus/exposure,
interruption/thermal recovery, AR tracking and real-room output quality require
the owner's phone. No simulator result certifies those behaviors.

Spatial stays disabled until accepted output exists. Spend remains
**$6.96837765 of the $25 ceiling**. Runtime is unchanged: `enabled=false`,
`singleton=true`, `max_seconds=7200`, `job_cap_cents=600`,
`max_gaussians=500000`, `max_iterations=3000`, `daily_budget_cents=0`,
`max_training_seconds=900`, `org_monthly_budget_cents=0`. This release did not
run another GPU experiment and does not name an ablation winner.

The [18-product competitor review](../research/COMPETITOR-DELIVERY-20260922.md)
informed the property workflow and listing kit. It is not an exhaustive census
or provider-quality comparison. Runway is not newly integrated or benchmarked;
no paid Runway jobs ran. Do not publish an uncommitted Bria price or claim all
competitor features are finished. Browser reflection-batch continuity, shared
agent portraits, richer room-consistent revisions and real-output comparison
remain separate work.

For the owner's phone check: install build 31, use the same named account in
Studio, record/import into one property and let its upload finish, then open
that property at the desk, make a reel and download its kit. Phone recording
interruption and real-room quality are the outstanding physical checks.
