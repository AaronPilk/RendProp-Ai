# Claude handoff — C2 discard and Studio photo order (October 15, 2026)

## Integrated source checkpoint

The reviewed C2 backend is integrated in `6849c3e` on top of `a0b6d57`.
The integration preserves the current `composeResumeAvailable` import and
resume branch byte for byte; `property-video-jobs/runtime.ts` is unchanged.
The older `d1b3ad6` branch and its CI edit were not integrated.

Current integrated local proof (no hosted deployment or provider call):
`build84-c2-integration/` on the external Builds volume contains actual
PostgreSQL discard 39 assertions / 9 race groups / 6 compiled controls,
gallery order 19 assertions / 3 races / 4 compiled controls, targeted
Deno 238 passed / 0 failed / 1 ignored, and Studio 575 unit tests plus
build and bundle budgets. Browser receipts separately bind the integrated
Studio runtime. The CI extension retains all 16 jobs and all previous
steps/settings, adding the two PG drivers and two browser flows with four
compiled browser fault controls.

The original report below describes the isolated branch and its historical
failures. Its replay-harness failures were subsequently addressed by the
integrated `fdad4f8` checkpoint; they are not new runtime failures. Native
83/84 upload order, manual tap order and two-batch behavior were delivered
and have separate Simulator proof. The remaining cross-client ordering
question concerns backend metadata/projection, not a reproduced regression
in that native behavior. Root owns the separate legacy NEW-video projection
follow-up; explicit gallery selection and admitted recipes remain authority.

Branch `claude/c2-abandon-order-20261015`, worktree
`Rendprop Workspace/Worktrees/Active/claude-c2-abandon-order`, based on the
committed integrated tip `2d98e60` (local `feature/launch-checklist82-20261014`).
Not pushed or deployed. Evidence: `_bridge/build84-c2-order-claude/`
(`before/` = failures on 2d98e60, `after/` = receipts, `preexisting/`).

| Commit | Scope |
|---|---|
| `9bcc4c1` | C2 server: discard route, RPC, tombstone, insert fence, lookup reason |
| `f6e1c8e` | C2 Studio: "Discard saved request", recovery paths, tests |
| `57ed810` | Studio gallery upload order (attach append, ordering, reorder check) |

An earlier draft branch `claude/c2-video-abandon-20261015` (based on d643afe,
with a CI edit) is superseded; do not integrate it.

## 1. C2 — discard a request the server never accepted

**Reproduced (before/).** A pending request whose photo preparation keeps
failing, or whose photo versions changed, could only Resume (refused: "earlier
photo versions") or Recover (not found). No discard route existed (deno 5/6
fail), and Studio never offered a way out (browser fails at "Discard saved request").

**Contract.** `POST /property-video-jobs/operations/:operation_id/abandon`,
body `{listing_id, expected_org_id}`, `Idempotency-Key:
property-video-abandon:<operation_id>`, no AI consent. Reply 200 with the
lookup shape plus `closed_reason`:
- accepted operation → its existing `job`, `operation_closed:false`; never
  cancelled (normal Cancel/recovery applies);
- capacity refusal → `closed_reason:"capacity_refused"`, unchanged;
- unseen operation → permanent per-actor tombstone, `closed_reason:"abandoned"`.

`property_video_operation_abandon` takes the same per-actor operation lock as
admission/lookup. A BEFORE INSERT/UPDATE trigger on `property_video_jobs` and
`property_video_refused_operations` re-takes it and refuses a tombstoned
operation, so enqueue/admission racing a discard has exactly one winner; other
isolation levels fail closed. Jobs, receipts, cost rows, preparations and
source media are never touched. A late `POST /property-video-jobs` gets 409
`operation_abandoned`; a discard landing after that route's pre-check is
refused by the fence as 409. Lookup reports `closed_reason`; a reasonless
closure from an older server still means capacity refusal.

**Studio.** "Discard saved request" (confirmation) appears only for a pending
request. Photos/options unlock only after the server confirms; a lost reply,
timeout or "not found" keeps it pending; a duplicate tap sends one request. An
accepted-before-discard job is adopted with the normal Cancel video. Load,
Recover and a 402/409 from Resume resolve the same operation (stale tab /
other device). The recipe is archived under `:abandoned:<operation>`.

## 2. Studio photo order

**Reproduced (before/).** Every Studio attach wrote `photos.sort=0`; Studio,
`studio/media` and the reorder check broke ties by UUID, so uploads appeared in
random order and a new batch jumped to the front after any reorder. Source
photos in `studio/media` were UUID-ordered too. PG: "two uploads with repeated
filenames and tied attach times keep upload order" fails; deno 2/3 fail;
browser shows `Garden, Front door, Kitchen` for `Front door, Kitchen, Garden`.

**Fix.** `studio_attach_photo` assigns the next position (later batches append
whatever their names, UUIDs or clock ties; attach and reorder already serialize
on the listing row lock in `studio_photo_authority`). `studio_gallery_update_v2`
compares (sort, created_at, id) and still accepts the same unchanged snapshot
named by a pre-fix client as (sort, id). `studio/media` orders gallery rows by
(sort, created_at, id) and source photos by (created_at, id); `orderedGallery`
matches. Existing rows are not rewritten. The reorder notice no longer claims
the website/tour order changed.

Verified without change: Make a video keeps tap order (B2 before A1 style, e.g.
photo 4 → 2 → 1); the planner only sets motion; admitted manifests are immutable
(RP409); AI Photo Studio and its controls are untouched.

## 3. Rollout order

1. Migrations `20261015174300_property_video_operation_abandon.sql` and
   `20261015180500_studio_gallery_upload_order.sql` (both after 171923; rename
   the timestamps if a newer migration is recorded first — neither redefines a
   function from Codex's in-flight migrations).
2. Edge `property-video-jobs` (index.ts, selected.ts) and `studio`
   (repository.ts). Old Studio clients keep working against the new SQL/edge.
3. Studio frontend.

## 4. Tests (LOCAL only: owned socket-only PostgreSQL, Deno closed transports, headless Chromium)

| Command | Result |
|---|---|
| `python3 services/supabase/tests/property_video_abandon_pg.py` | pass: 39 assertions, 9 races (both winner orders), 6 compiled controls |
| `python3 services/supabase/tests/studio_gallery_order_pg.py` | pass: 19 assertions, 3 races, 4 compiled controls |
| `deno test --allow-env --allow-read --allow-net studio/ property-video-jobs/` | 235 pass |
| Studio `npm test` / `npm run build` + `check-dist` | 575 pass / pass |
| `node tests/make-video-discard-browser.mjs` (+3 `--fault=` controls fail as intended) | pass, 8 checks |
| `node tests/listing-upload-order-browser.mjs` (+`--fault=uuid-tie-break` fails) | pass, 4 checks |
| `make-video-browser`, `make-video-status-browser`, `listing-workflow-browser` (5/5), `listing-kit-browser`, `creative-photo-pages-browser` | pass |
| PG regressions: property_video_jobs, submit_recovery, quality_profile, failed_terminal, paid_quality_processing, product_media_serving, owner_testing_media_delivery, studio_recorded_source, studio_photo_history, listing_gallery_remove, `run_photo_authority.py`, `run_listing_gallery_selection.py` | pass |

**Pre-existing at 2d98e60 without these commits (preexisting/):**
`property_video_derived_retry_pg.py` and `property_video_result_delivery_pg.py`
fail their replay stage because later migrations redefine
`property_video_job_resume`, tripping md5 guards in 151716/160252 (CI steps at
ci.yml ~1487/1494). `make-video-browser.mjs` timed out once in 4 runs at the
account-switch step (passed 3/3 reruns).

Shared test files touched minimally: `studio/repository.test.ts` (one order
assertion) and `listing-workflow-browser.mjs` (oracle used UUID order).

## 5. CI lines for Codex (not edited here)

- property-video job, after `property_video_jobs_pg.py`:
  `property_video_abandon_pg.py` and `studio_gallery_order_pg.py`.
- Studio browser list: `make-video-discard-browser.mjs`,
  `listing-upload-order-browser.mjs`; controls must fail with
  `the server recorded the discard` (client-only-discard), `lost discard
  response` (forget-after-lost-reply), `already accepted this request`
  (discard-hides-accepted-job), `earlier photos keep their upload order`
  (uuid-tie-break).

## 6. Codex must verify (hosted / real phone; not done here)

- Deploy readback of both migrations and both functions; authenticated
  Studio: stuck request → Discard → new recipe; accepted race shows the job.
- Real upload of two batches with restarting names in Studio and the phone's
  cloud media view; existing listings' order after deploy.

## 7. Documented, not changed (outside a minimal fix)

- Studio reorder does not drive the published gallery or Make a video:
  tours/selected.ts use `gallery_asset_ids` or capture `created_at`. Needs a
  product decision on one gallery-order authority.
- Once the phone sets `gallery_asset_ids`, Studio uploads/edits are not in it
  (website and Make a video omit them); `append_listing_gallery` caps at 40
  while the validator allows 100.
- Backend native-upload batch reservations can share one `created_at`; with no
  server ordinal, the cross-client source projection resolves ties by UUID.
  This is separate from the delivered native local upload-order fixes and is
  not evidence of a new phone UI regression. A server ordinal would be a
  separate schema/protocol change, not part of C2 abandonment.
- Studio has no photo-version family: a saved edit is a new gallery photo, now
  appended (existing order unchanged). Placing it next to its source needs a
  source-photo id on attach.
- `studio/media` pages interleave gallery and source photos beyond 50 when a
  listing has both; Make a video offers the oldest 100 gallery photos only.
- Job `c40f4860` was not inspected; Codex's `887cbea` covers the unaccepted
  FAL 403 path.
