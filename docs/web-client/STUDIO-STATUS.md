# Rendprop Studio — implementation status and Claude handoff

Working date: 2026-09-12. Current web branch: `feat/web-studio-recovery-20260912`.
It branches from initial Studio branch `feat/web-studio-20260912` at `0eec832`.
Base: `81fa6d21c17b559297fc03e6e548f70d7ce33bad` (Claude's build-20 hardening wave).
Before the web commit, fast-forwarded to Claude's `00b56e3` (1.0.1 build 21).
His intervening change touches only the two iOS project/version files; no web
source or built asset changed. This preserves his current submission source.
Workspace: `/Users/pilksclaes/Rendprop AI/web-studio-20260912`.

## Latest iteration — deployed and verified 18:15 UTC

Implemented Undo/Redo, portable JSON content-plan backup/restore, connected-refresh
file retention, single editor completion notices and stricter scoped media reads.
Integrated verification passed: 154 unit tests, 29 Deno tests, 17 workspace browser
checks, 18 editor browser checks/seven real video downloads, six connected-fixture
checks and a deliberate refresh regression caught at its specific browser assertion.
Type checks, exact built assets and Studio-only deploy dry-run passed.

This iteration is now deployed from `d87e60c8abea65f2b2b54731e095e8217ac82dea`.
Both browser suites passed again against actual HTTPS: 17 workspace checks,
18 editor checks and seven decoded video downloads, zero skips/errors or external
requests. [Full changes, reproduction, limits and Claude handoff](STUDIO-RECOVERY-2026-09-12.md).
[New source-bound receipts](evidence/2026-09-12/recovery/README.md) preserve older evidence separately.
No iOS, Apple, paid-provider or existing production service changes were made.

## Delivered preview — read this first

**https://studio.rendprop.com is live** as a local-editor/content-planner preview.
Cloudflare Worker `rendprop-studio`, version
`1ad1d0ab-b1a1-49ba-a9e1-4ccbeead04a1`, deployed from source
`d87e60c8abea65f2b2b54731e095e8217ac82dea`. Initial implementation commit:
`74153def832b088190390552f950afb8baf2be49`.

Actual HTTPS browser verification passed at 18:13–18:15 UTC: 18 grouped editor
checks plus 17 workspace checks, seven real video downloads, no skips, no
external/disallowed requests or browser errors. The browser-received entry HTML
and four JS/CSS assets matched the local build.
The separate deployed-assets gate also verified the original logo, headers and
SPA deep route. Receipts are linked below; these are not localhost claims.

**Not delivered as live features:** same-account Apple web login and iPhone media
sync, cloud edit revisions, resumable large uploads, canonical cloud renders,
team approvals and automated social publishing. The deployed build intentionally
has no account configuration and says so. No fake listings, fake connection or
simulated server job is substituted for the missing integration.

The public marketing changes are built/tested/committed but **not deployed to the
existing tour-host**. Claude must integrate them with its current production
baseline; do not replace that Worker with a historical branch indiscriminately.
Apple/iOS submission, existing tour-host, upload gateway, database, customer data
and paid provider routes were not changed by this Studio deployment.

All source is committed locally on `feat/web-studio-recovery-20260912`. GitHub write access
returned 403, so this branch is **not pushed**. Claude can inspect the local branch
or worktree immediately; a remote build link is not proof that GitHub has its source.

## Scope and separation

The owner's latest request supersedes the audit as the main work: build Rendprop's
web business and editing product, reuse iPhone accounts/content, preserve branding,
cover every supported industry, and improve public search discoverability. Claude
owns the concurrent iOS submission. This branch does not edit iOS source, Apple
products, App Review state, subscriptions, paid AI routing, or customer records.

This is the **first implemented Studio release**, not a claim that every planned
business feature is complete. The editor is real; automatic social posting, cloud
edit sync and canonical server exports are not implemented by this release.

## Implemented

- `apps/studio/`: React/TypeScript/Vite owner workspace, original Rendprop vector mark,
  violet palette, responsive sidebar/navigation, content library, workspace selector,
  sign-in dialog, local editor and content planner. No third-party analytics/scripts.
- Same Supabase identity and literal existing `/me` and `/listings` contracts.
  Official Apple OAuth/PKCE browser adapter; membership and workspace selection;
  no second billing or identity service. Runtime DTO validation, one-401 retry,
  same-subject refresh, cancellation, account-switch and render-time visibility fences.
  Auth operations have 20-second deadlines; reads have one 30-second total deadline
  including JSON decoding and refresh. Local library downloads have a 120-second cap.
- Additive `services/supabase/functions/studio/`: authenticated, paginated owner-media
  read bridge. RLS-scoped listing/media queries, live membership/deletion checks,
  bounded requests and 10-minute R2 read URLs for canonical listing-linked media.
  No arbitrary key signing, upload, rendering, deletion or publication operation.
- Editor: photo/video import, reorder, trim, framing, three aspect ratios, title and
  clip text, playback/scrub, original video audio or explicit mute, real local export,
  schema-versioned edit plans, full-content-hash media reselection, cancellation.
- Planner: locally saved caption/date/channel drafts, editing, confirmed removal,
  channel/upcoming/week filters and ICS reminders. Timezone-bound instants survive
  travel; nonexistent/repeated daylight-saving times receive explicit handling.
  Platform connections are explicitly not connected. It does not impersonate a scheduler.
- Public website: Studio and Industries pages, all five core industries, crawlable
  content/navigation, canonical/OG metadata, visible-answer-aligned structured data,
  sitemap/robots, corrected account/App Store availability copy. Exact prices unchanged.
- Dedicated static Worker configuration for `studio.rendprop.com`, private noindex,
  CSP/response headers, pinned dependencies/lockfile, offline and browser test runners,
  build-output gates and a separate CI workflow. The isolated local-mode preview
  is now deployed and verified as described above; connected mode is not.

## Important product limits — do not conceal in handoff or marketing

1. Cloud app data and local-only iPhone files are different. Signing in cannot recover
   files that were never uploaded. An anonymous-only phone workspace must be linked
   to the same Apple identity in the existing app before browser account access.
2. This local editor initially accepts 12 clips, 32 MiB per file, 160 MiB total,
   three-minute timelines. Unsupported codecs/pixel counts are rejected. Original
   iPhone MOV/HEVC compatibility depends on the browser; no universal codec claim.
3. Local exports use a real-time browser encoder, not frame-exact server rendering.
   Keep the tab visible; hidden tabs cancel. The observed 2-second test was about
   2.095 seconds. MP4 is H.264/AAC where those capabilities are available; WebM is
   offered when supported. Not canonical publish/export parity with iOS.
4. Edit intent/content plans persist in this browser, scoped to account and org.
   Media is not put in localStorage. Reselect originals after reload. No cloud
   backup, team approvals, automatic posting or cross-device edit sync yet.
5. Media bridge deliberately omits untrusted/unlinked keys and Stream-only outputs;
   the UI reports unavailable counts. Arbitrary `ai-router/` references are not
   signed merely because a client-writable photo record points to them.
6. Existing `/listings` has no paging contract and may hit default Data API limits
   for very large accounts. Enterprise-wide completeness needs a paginated contract.
7. Recovery iteration fixes same-account refresh file retention, including transient
   network/503 failure. Access loss, identity/org changes, reload and explicit draft
   recovery still require original reselection. Offline App/services browser proof
   passed; real same-account integration acceptance is still required.

## Live configuration read-back (GET only)

At 2026-09-12 15:56 UTC, a fresh GET of Supabase Apple config still lists only `com.rendprop.app`.
No web Services ID appears, and `https://studio.rendprop.com/` is not in the
redirect allowlist. This directly prevents the requested same-account browser
login from being a verified production feature. No provider setting was changed.
An empty/missing secret field in a management response is not by itself proof
that a secret was never configured; the Services ID and redirect gaps suffice.

Cloudflare predeploy read-back at 16:19 UTC found no Studio custom domain or DNS
record. This turn then created only `rendprop-studio` and its exact
`studio.rendprop.com` custom domain, with no database/storage/secret bindings.
Domain read-back confirmed that mapping and the actual HTTPS tests verified its
served app. Existing tour/upload hostnames and routes remain untouched.

The initial deployment (`5cf06909-3367-458a-a5c0-0f19f3d76d12`) exposed a real
environment difference: Cloudflare injected a JavaScript Detection snippet into
HTML. Exact-byte verification failed. The scoped `no-transform` header fix in
`98a6da6` resolved it without weakening script CSP or changing zone bot/WAF settings.
All seven app asset files stayed byte-identical across this header-only fix.

**Separate open crawler-policy item:** Cloudflare also prepends its existing
managed policy to `robots.txt`. Its wildcard `Allow: /` can conflict with the
origin's wildcard `Disallow: /`. The file is therefore NOT an exact-byte match,
and crawl blocking is not claimed. The read-back gate verifies the exact origin
tail plus the SHA-pinned known managed prefix, reports that exception and retains
noindex header/meta checks. Noindex is the intended index exclusion; neither it
nor robots.txt is account access control. Resolve the managed policy with a
hostname-scoped design before claiming an all-crawler exclusion; do not disable
or rewrite the entire business domain's crawl settings to silence a test.

## Required integration order

1. Review this branch relative to Claude's latest tip. Do not deploy an older tour
   Worker over his newer changes. Keep this web lane separate from Apple submission.
2. Create/configure a Sign in with Apple **web Services ID** associated with the
   native App ID. Put Services ID first in Supabase's Apple client list and retain
   `com.rendprop.app`; configure the Supabase callback and valid Apple OAuth secret.
   Add exact Studio redirect URL without removing native redirects. Coordinate this
   with the owner/Claude; it is an Apple configuration change, not a browser workaround.
3. Deploy only the additive `studio` Edge Function with JWT verification and its
   internal Auth/membership checks. No migration required. Reuse the existing R2
   server credentials; no credential value belongs in browser config or documentation.
4. Verify R2 GET/HEAD CORS for the Studio origin, exposing content type/length as
   needed; verify cache headers and signed-URL expiry on actual private media.
   Studio's own `no-store` policy does not cover external R2 responses. Do not
   replace existing iPhone/upload/viewer settings blindly.
5. For the connected release, rebuild the existing preview with the project's
   **public** Supabase URL and publishable key; update only its own Worker,
   then verify headers, emitted JS and actual
   browser sign-in into the SAME subject/org as the phone. No service-role key.
6. Verify media paging/expiry/import and account-switch behavior against a controlled
   owner fixture. Then activate public Open Studio/Sign in links. The public pages
   currently avoid claiming a missing destination already works.
7. Run all tests below and inspect actual output. A mock session and a green source
   test are not proof of deployed Apple OAuth, CORS or a real customer round trip.

## Commands and deeper contracts

```bash
cd apps/studio
npm ci --no-audit --no-fund
npm run verify
npx playwright install chromium
node tests/browser-workspace.mjs --start-preview --base-url=http://127.0.0.1:4181
node tests/browser-editor.mjs --start-preview --base-url=http://127.0.0.1:4182
npx wrangler deploy --dry-run
```

The media browser test needs `ffmpeg`/`ffprobe`. On the development Mac, an existing
Chrome binary can be selected with `STUDIO_BROWSER_EXECUTABLE` instead of downloading
another browser. Tests must not use customer capture files or production sessions.

```bash
deno check services/supabase/functions/studio/index.ts
deno test --deny-net --deny-run --deny-write services/supabase/functions/studio/handler.test.ts
cd services/edge/tour-host
npm ci --no-audit --no-fund
npm run predeploy
```

- [Identity contract and runtime gates](STUDIO-AUTH.md)
- [Editing engine, limits and actual media proof](STUDIO-EDITOR.md)
- [Content planner and independent recovery](STUDIO-PLANNER.md)
- [SEO decisions, static checks and browser proof](STUDIO-SEO.md)
- [Existing web architecture decision record](ARCHITECTURE.md)

## Verification completed before publication

All dates below are 2026-09-12. Test counts describe different gates; do not add
assertions, tests and viewport combinations into a fictitious single test total.

| Gate | Actual result |
| --- | --- |
| `npm run verify`, Studio | 104 unit tests, zero skips; TypeScript and Vite build passed; emitted-asset gate passed |
| Built editor browser run, 16:21–16:22 UTC | 13 grouped checks, seven real downloads, zero skips/external requests/browser errors |
| Built workspace browser run, 16:21–16:22 UTC | 14 grouped checks; five pages at desktop and 375px; zero external requests/browser errors |
| Synthetic bad build config | Real Vite CLI rejected ambiguous key fields with exit 1 before emitting files; existing dist hashes unchanged |
| Additive Studio Deno route | Typecheck passed; 18 offline handler tests passed with network/process/write denied |
| Existing tour-host `npm run predeploy`, 16:10 UTC | Typecheck; 557 unbranded + 12 self-tests; 584 route; 707 upstream; 418 lead-form; 57 legal; 103 spatial; 28 emitted-module checks; 2 asset checks; 917 marketing assertions + 12 deliberate negative controls passed |
| Public marketing browser run | 179 assertions over 28 page/viewport combinations, zero browser errors; unchanged source hashes bound in receipt |
| Studio dependency audit | Full and production-only audit reported zero advisories in this installed lockfile at 15:46 UTC |
| Cloudflare static packaging | Pinned Wrangler 4.131.1 dry run passed; this alone is not deployment proof |
| Actual HTTPS editor, 16:31 UTC | 13 grouped checks, seven actual exports; strict served HTML/JS/CSS hashes; zero skips/browser errors/disallowed requests |
| HTTPS app read-back, 16:31–16:32 UTC | Exact HTML/JS/CSS/logo bytes, required headers and SPA route passed; separately pinned managed-robots prefix reported as a warning, not exact robots or crawl-blocking proof |
| Remote CI | Not run: new workflow is local until this branch can be pushed |

The two-second final MP4 measured 2.038267 seconds (H.264/AAC); the WebM measured
2.025 seconds (VP8/Opus). Reordered photo→video exports measured 3.010467 / 2.999
seconds, with decoded leading-photo RMS exactly 0 in both and the original ~440Hz
tone after the cut. These are synthetic fixtures, not customer captures.

Durable JSON evidence is in [evidence/2026-09-12](evidence/2026-09-12/README.md).
Earlier failed runs (Mac ENOSPC, copied-logo final newline mismatch, WebM fixture
timing, and the actual leading-photo audio defect) are not counted as passes.
Disk space later recovered; no source, customer data, release archive, compiler
output or test artifact was deleted by this turn.

GitHub's integration returned HTTP 403 `Resource not accessible by integration`
on the attempted tree write. No remote tree/commit/branch was created by it. Do not
mistake local completion or a later static deployment for a successful Git push.
The local worktree is the handoff source until the owner restores repository write
access or Claude integrates it through an authorized repository connection.

## Bugs found and fixed during this build

- Browser WebM startup deadlock: awaiting the recorder's `start` event before
  delivering another canvas frame could wait forever. Start recording and feed
  frames immediately; test actual offered MP4 and WebM output, not source stubs.
- Leading photos lost their silent audio interval: a Web Audio destination with no
  live source shifted the first video's sound to t=0 in a multi-clip recording.
  A zero-valued source now preserves its audio clock and is stopped/disconnected
  in cleanup. Decoded samples prove silence before and sound after the cut.
- An unused browser key alias could escape validation when a valid preferred key
  was also supplied. Config now rejects simultaneous key fields before bundling;
  synthetic regression tests and the actual Vite CLI reject that configuration.
- Ordinary page navigation discarded imported files. The editor now remains mounted
  within the same workspace; leaving its view pauses preview/cancels export without
  revoking source files. Identity/workspace change still tears down that media session.
- One malformed saved planner could suppress restoration of a valid edit and cause
  initial autosave to overwrite it. Restore both documents independently. Failed reads
  lock writes to that document, preserve the original bytes, and show recovery copy.
- Recovery retry could mount the old temporary edit before restored data arrived.
  The mount-ready fence includes the recovery attempt; confirmation explains the
  loss of temporary edits/file bindings before any remount.
- Signed-in but unavailable workspaces appeared editable while autosave was refused.
  Keep the account workspace visibly loading/failed and offer explicit browser-local
  sign-out to use local files. Never silently save to another account's scope.
- Stalled network/body/auth operations had no total deadline. Added bounded operations
  with controlled-clock tests that deliberately never resolve, plus safe late-settlement handling.
- Mobile navigation had become icons without visible names. Added a labeled bottom
  navigation bar and browser assertions for visible text/no horizontal overflow.
- Planner dates previously allowed JavaScript normalization of impossible dates and
  timezone-dependent reminders. Strict wall-date validation, DST choices, canonical
  UTC timestamps, UID/CR escaping and six actual-source mutation controls now cover them.

These are defects discovered and addressed in this new Studio implementation, not
claims of regressions in the App Store binary. No camera/AR tests were attempted.

## Next product engineering, in order

Small preview UX follow-ups: the embedded editor still says “Make the listing move”
(`apps/studio/src/editor/VideoEditor.tsx:525`) regardless of the selected industry;
make this generic or industry-aware before the all-industry launch. A completed
export is announced both by the host notice (`App.tsx:699,932`) and editor notice
(`VideoEditor.tsx:587`); consolidate the announcement owner to reduce duplicate
visual/live-region messaging. These do not invalidate the actual export proof.

1. Connected account/media acceptance above; paid customers must see the same spaces.
2. Durable browser upload using existing v2 gateway/recovery protocol; no new storage
   pipeline. Add tested resumable large-file import and proxies for phone footage.
3. Immutable cloud edit revisions plus one canonical renderer/artifact identity.
   Extend the existing fenced worker and cost ledger; do not create a parallel queue.
4. Persisted content calendar and approvals tied to organization/asset revisions.
   Owner/admin/agent/marketing roles must be enforced on the server, not just hidden UI.
5. Meta/Instagram business OAuth, expiring token storage, queue/retry/idempotency,
   webhook receipts and revocation. Then add other social providers independently.
   User's existing Claude Instagram posting is not an app-integrated connection.
6. Brokerage brand inheritance, office/team controls, reusable templates, approval
   policies and versioned audit history. Do not advertise SSO/SCIM or enterprise
   governance before those capabilities and tenant tests actually exist.
7. Search Console validation, useful industry case studies, real tutorials and
   measured acquisition/activation/retention. No fake reviews, market statistics,
   ranking promises, or assumption that an `llms.txt` file creates AI visibility.
