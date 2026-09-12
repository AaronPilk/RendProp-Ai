# Studio recovery and portable-plans iteration — Claude handoff

Branch: `feat/web-studio-recovery-20260912`, based on `0eec832`.
Worktree: `/Users/pilksclaes/Rendprop AI/web-studio-20260912`.
Scope: web Studio only; no iOS/Apple, production database, paid provider, public
tour-host or upload gateway changes. Three parallel implementation agents plus
root integration; editor and refresh changes received independent cross-review.

## Changes implemented

1. **Undo/Redo:** trim, caption/title, clip order, aspect ratio, audio, framing,
   import/removal edits now have grouped, bounded history. Maximum 20 combined
   steps and 64 KiB metadata. Travel always creates a new revision, aborts active
   recording and invalidates old exports. Removing media releases its File/URL;
   Undo restores exact settings and asks for hash-verified original reselection.
   No hidden large-file retention. Generic copy covers every supported industry.
2. **Portable content plans:** actual JSON download containing the complete queue,
   format `rendprop-content-plans`, version 1; UTF-8 <=2 MiB, <=100 plans. Import
   previews before explicit Merge/Replace. Duplicate IDs, unsupported fields,
   malformed/oversized files and stale previews reject without mutation. Storage
   is written before React state changes. Quota failure preserves both queue and
   preview. Cancellation preserves originals. Timezones/UTC instants survive.
   A serialized-size guard prevents writing an escape-heavy draft the existing
   500,000-character reader could never reopen.
3. **Connected refresh:** refreshing a verified same-account workspace no longer
   unmounts its editor and discards in-memory sources. Only typed network/timeouts,
   HTTP 429 and 5xx may retain the snapshot; errors that imply access loss or invalid
   responses clear it. Identity/org render-time fences remain. Retry remounts the
   planner as well as editor under the restore-attempt scope. Duplicate global
   editor completion announcements removed.
4. **Media bridge:** extracted the real RLS query adapter into `studio/repository.ts`
   so tests cover its Auth/deletion/membership/org/listing order and actual scoped
   query construction. Null database bodies cannot look like empty success.
   Oversized/foreign lookahead rows fail before signing. Live authorization is
   rechecked before signed URLs are returned. Browser validation requires canonical
   R2 tenant/listing paths, literal SigV4 fields and unexpired actual signature time.
   No global signer changes, new writes or credentials in browser code.
5. **Verification:** production-asset gate excludes fixture account code/entrypoints.
   Workspace browser runner no longer silently rebuilds dist during other tests.
   New separately compiled App fixture exercises real services with offline Auth
   and fetch dependencies. Its negative-control wrapper accepts failure only at
   the intended browser regression assertion. CI includes both and repository tests.

## Independently executed integrated checks

Code anchors at runtime commit `d87e60c`:

| Change | Source |
| --- | --- |
| Fresh-revision Undo/Redo and grouped edits | `apps/studio/src/editor/history.ts:44`, `:54` |
| Validated backup parsing and confirmed import | `apps/studio/src/workspace.ts:234`; `apps/studio/src/Planner.tsx:232`, `:249` |
| Same-scope refresh retention and transient-only policy | `apps/studio/src/App.tsx:212`; `apps/studio/src/workspace-refresh.ts:7` |
| Initial and pre-return authorization | `services/supabase/functions/studio/handler.ts:121`, `:249` |
| Real scoped query adapter | `services/supabase/functions/studio/repository.ts:20` |

Reproduce from the worktree (build once before browser gates):

```sh
cd apps/studio
npm run verify
node tests/browser-workspace.mjs --start-preview --base-url=http://127.0.0.1:4181
node tests/browser-editor.mjs --start-preview --base-url=http://127.0.0.1:4182
node tests/browser-connected.mjs
node tests/browser-connected-control.mjs
node node_modules/wrangler/bin/wrangler.js deploy --dry-run
```

On this Mac the browser commands used
`STUDIO_BROWSER_EXECUTABLE=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
(quote the value when entering a shell command). Deno commands from repo root:

```sh
deno test --deny-net --deny-run --deny-write services/supabase/functions/studio/handler.test.ts services/supabase/functions/studio/repository.test.ts
deno check --deny-import --frozen services/supabase/functions/studio/index.ts
```

Actual pinned runtime used here: `/tmp/rendprop-deno296.EyhIbB/deno` (2.9.6).
Run `deno check` with normal import access on a clean machine to prime the pinned
imports before the fully offline check. Do not treat a cold-cache refusal as a pass.
The live suites add `--deployed-preview --base-url=https://studio.rendprop.com`;
they use isolated local browser storage and forbid provider/write requests.
All reported test commands exited0 except the deliberately mutated child, which
exited1 at its expected assertion and was verified by the control wrapper.

- `npm run verify`: **154 tests passed**, zero failed/cancelled/skipped; TS and Vite
  production build passed. Built gate: **165,228 gzip bytes**, original mark identical.
  Vite still warns about the 509,095-byte minified entry (147 kB gzip); not hidden by
  raising a warning threshold. Further code splitting is a performance follow-up.
- Deno `handler.test.ts repository.test.ts`: **29 passed**, zero failed; frozen
  offline `deno check` for `studio/index.ts` passed.
- Built workspace browser: **17 grouped checks**, all five pages at desktop and
 375px. Actual JSON/ICS downloads, merge/replace/cancel/invalid/quota paths, storage
 recovery, file-hash rejection, focus trap and responsive layout. No external
 requests or console errors.
- Built editor browser: **18 grouped checks**, **seven real video downloads**.
 MP4 H.264/AAC and WebM VP8/Opus decoded with ffprobe/ffmpeg; actual 440 Hz audio,
 trims, captions, ordered photo/video cuts, silent/muted tracks and cancellation.
 Undo/Redo tested around edits, completed outputs, removal/reselection and active
 recording. Exactly one completion announcement per output. Zero skips/errors.
- Separately built connected fixture: **six grouped browser checks**, including
 in-flight refresh, 503 preservation, 403 clearing/recovery, and org/account switches.
 The deliberate `setWorkspace(null)` mutant failed at `REFRESH_BINDING_REGRESSION`.
 Initial harness selector/mutation-hook errors were fixed; those unrelated failures
 were not counted as successful negative controls.
- `wrangler deploy --dry-run`: passed, dedicated static Studio only, no bindings.

These counts are not additive coverage percentages or proof every application
path is correct. The media fixtures do not use customer files, and the connected
fixture is NOT live Apple OAuth/private R2 proof. Source tests include 12 planner
source mutants and 20-step history coverage; zero ignored tests.

## Deployment and evidence

**Deployed and verified:** source `d87e60c8abea65f2b2b54731e095e8217ac82dea`, Worker
version `1ad1d0ab-b1a1-49ba-a9e1-4ccbeead04a1`, 100% at 18:12:58 UTC. Actual HTTPS
editor and workspace suites passed again: 18 + 17 grouped checks, seven real video
downloads, zero skips/errors/forbidden requests. JSON/ICS downloads, plan restore,
quota recovery and mobile navigation ran against the actual deployed application.
The separate asset/header gate passed; known managed-robots exception remains.
Dedicated `evidence/2026-09-12/recovery/` receipts bind the source and tested bytes.
Historical initial-release receipts are retained unchanged.

Before deployment, GET read-back still showed Studio version
`2df1ea6d-b3a1-44ff-bc02-9ef66887dacb` at 100%, no bindings. Thus no concurrent Studio
deployment had been overwritten at that check. Existing main-domain workers are
outside this deployment lane.

## Still needed for the requested connected business platform

- Owner/Claude-coordinated Apple web Services ID/callback, preserved native IDs,
  exact Supabase redirect and real same-phone-user sign-in proof. Do not infer
  this authorization from requests to continue local web work.
- Deploy additive Studio function; controlled real R2 CORS/cache/expiry/download
  proof; only then configure public browser project values. No service-role value.
- Cloud edit persistence/version conflicts, resumable larger uploads, canonical
  render jobs, teams approvals and approved social-account publishing integrations.
- Live R2 cache headers are not controlled by Studio's own `no-store`. Signed
  URLs remain usable until expiry; offset pagination is not a snapshot under
  concurrent inserts/deletes. See STUDIO-AUTH for those explicit limitations.
- GitHub write integration previously returned 403. No alternate credentials or
  tool route used to bypass it. Commits remain local until write access is resolved;
  no claim that remote CI ran. Claude can inspect this worktree/branch now.
- Safari/Firefox, real phone encoding/HEVC, limit-length media, full accessibility
  compliance and production account integration are not claimed by Chrome fixtures.

No new subscription or public pricing change. Local drafts and exported backup
files are not cloud sync. Content planning/reminders are not social auto-posting.
