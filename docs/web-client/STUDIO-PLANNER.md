# Studio planner and draft recovery

Date: 2026-09-12

Worktree: `web-studio-20260912`
Current branch: `feat/web-studio-recovery-20260912`

Portable-backup unit baseline: `0eec832` (the original Studio work remains in
this worktree; this iteration does not change the deployed iOS app).

This document records implemented functionality, executed tests, and independent
source review. It does not claim that Studio, account connection, or any social
integration is deployed.

## Implemented planner

`apps/studio/src/Planner.tsx` preserves the `items`, `onSave`, and `onNotice`
interface and supports:

- Create plans with title, caption, channel, date/time, and timezone.
- Edit existing plans without changing their identity or creation timestamp.
- Cancel editing without modifying the saved plan.
- Confirm before replacing unsaved form changes with another plan.
- Confirm before removing a single browser-local plan.
- Filter by Instagram, Facebook, TikTok, YouTube, or LinkedIn.
- Show all plans, upcoming plans, or a Monday–Sunday calendar week, with
  previous/next/this-week navigation.
- Copy captions and download 15-minute ICS reminders.
- Store up to 100 plans per browser workspace. Editing and removal remain
  available at capacity.
- Export the entire saved queue as a portable versioned JSON backup, independent
  of the selected channel/week filter.
- Import a backup into an explicit preview, then choose Merge or Replace and
  confirm. Cancelling, an invalid file, or a failed save leaves existing plans
  unchanged.

The UI explicitly states that social accounts are not connected and plans are
not automatically published. Removal does not change listing media, imported
calendar events, or social posts.

Scoped `planner.css` retains Studio's violet/lavender/dark palette and responsive
layout. Filtered results are derived from saved plans, not maintained as a second
mutable queue. The form resets only after the parent save succeeds; persistence
failures do not report success.

## Storage and scheduling contract

`apps/studio/src/workspace.ts` defines and validates:

```ts
type PlanItem = {
  id: string;
  title: string;
  caption: string;
  channel: "Instagram" | "Facebook" | "TikTok" | "YouTube" | "LinkedIn";
  date: string;
  createdAt: string;
  timeZone?: string;
  scheduledAt?: string;
};
```

New and edited plans save the optional fields together. For example,
`2026-09-15T12:30` in `America/New_York` binds to
`2026-09-15T16:30:00.000Z`.

Validation rejects impossible dates, duplicate IDs, unsupported channels,
oversized fields, incomplete timezone pairs, and UTC instants inconsistent with
their wall-clock time. Unknown fields are not persisted.

Storage uses separate local and user/organization keys:

```text
rendprop-studio:v1:local:planner
rendprop-studio:v1:<encoded-user-id>:<encoded-org-id>:planner
```

This is browser-local persistence, not server authorization or cross-device
synchronization. Host identity/workspace rendering and write fences remain in
`App.tsx`.

### Dates and daylight saving

`wallDate`, `planDateChoices`, and `bindPlanDate` prevent silent normalization:

- February 30, non-leap February 29, and 24:00 are rejected.
- Nonexistent daylight-saving times are rejected rather than shifted.
- Repeated clock times require an explicit first/second occurrence.
- Tests cover half-hour transitions, quarter-hour zones, and a skipped calendar
  day.
- Bound reminders retain their UTC instant after a browser timezone change.

Legacy unbound drafts remain readable and visibly labeled. Normal legacy exports
use the current browser timezone and say so. Ambiguous or nonexistent legacy
times require editing instead of silently selecting an instant.

Timezone rules depend on the browser's `Intl` database; tests do not guarantee
that an outdated browser knows future government rule changes.

### Calendar export

`calendarFile` escapes backslashes, commas, semicolons, LF, CRLF, and lone CR.
IDs use a bounded ASCII identifier pattern, permitting UUIDs and legacy
`test-post` without permitting injected calendar properties. Line folding
preserves UTF-8 characters.

ICS files contain a stable UID and UTC start/end times. Changing a Studio plan
does not automatically update or delete an event already imported into another
calendar.

## Portable content-plan backups

The download has a descriptive UTC timestamp and plan count, for example:
`rendprop-content-plans-2026-09-12T18-15-30-123Z-2-plans.json`.

```json
{
  "format": "rendprop-content-plans",
  "version": 1,
  "exportedAt": "2026-09-12T18:15:30.123Z",
  "plans": []
}
```

`planBackupFile` validates every saved record before exporting; nothing is
silently sliced. `readPlanBackupFile` checks the file's byte size **before**
reading, rechecks actual bytes/declared size afterward, and uses fatal UTF-8
decoding. `parsePlanBackup` validates the envelope, supported version, UTC export
timestamp, every plan, unique IDs, and the 100-plan limit. Unknown envelope/item
fields are rejected rather than silently losing data from a future format.
The limit is **2 MiB**; the tests cover the exact boundary and one byte beyond.
MIME type/filename are picker hints, never substitutes for content validation.

Backups retain IDs, captions, creation timestamps, channel, wall-clock date,
timezone, and exact scheduled UTC instant—including a selected repeated DST
hour. Legacy records retain their absent timezone and are explicitly labeled;
import never guesses one. Files contain no media, credentials, workspace IDs, or
social connections. The UI warns that captions can contain business details and
backups should be stored privately. This is a user-managed file transfer, not
cloud synchronization, a scheduler, or automatic social publishing.

### Preview, merge, replacement, and failure behavior

- The preview displays the filename/export date, counts, each incoming title,
  channel, reminder time, and caption. No save occurs while choosing/reading a
  file, previewing, changing mode, or cancelling.
- Merge keeps existing plans and appends the validated backup **only when IDs
  are disjoint and the combined total is at most 100**. Even an identical
  overlapping ID is rejected; the app does not invent IDs, silently deduplicate,
  or overwrite a changed plan from another browser.
- Replace requires its own mode selection and `Confirm replace import` action.
  It explicitly warns that the current browser-local queue and unsaved planner
  form will be replaced. Empty backups are valid, and their preview clearly
  warns that replacement leaves zero plans. Existing calendar events, listing
  media, and social posts are untouched.
- A canonical current-queue snapshot is bound to the preview. Both rendering
  and `confirmPlanImport` reject confirmation if the saved queue changes before
  the click. Reopen the backup to review the new state.
- Confirmation invokes the existing synchronous parent `onSave` once with the
  complete validated result. The parent must write browser storage before
  updating React state and throw on failure. Queue/form/preview reset occurs
  only after success; a quota failure keeps the preview for an explicit retry.
- `writePlans` now refuses serialized drafts over **500,000 characters** before
  writing, matching the existing `readPlans` limit. Otherwise escape-heavy but
  structurally valid JSON could save successfully and fail to reopen. The
  2-MiB transport limit does not promise every imported queue fits browser
  storage; that distinct failure preserves the old queue.
- Selecting another file, cancelling a pending read, or unmounting invalidates
  its generation. A late read cannot install a preview or notice afterward.
  The host must retain its keyed workspace/restore-scope boundary; no new props
  are required (`items`, synchronous `onSave`, `onNotice`).
- Download anchors are temporarily attached then removed. Blob URLs are
  revoked after 30 seconds even if the browser click throws. The UI says
  "download requested," not that the browser has durably saved a file.

These are code/unit guarantees. Actual React file-picker cancellation,
workspace switching, confirmation UX, and browser storage quota integration are
covered by the root-owned browser-workspace verification, not inferred from
the pure helper tests.

## Four integration defects found and corrected

These fixes belong to root/shared host and editor code. Independent review
confirms **static closure**; browser execution evidence belongs to the integration
reports.

1. **Failed restore could overwrite saved work.** A malformed planner prevented
   reading a valid video edit; opening the editor could then autosave an empty
   draft over it. `src/drafts.ts:13` now reads each document independently.
   Per-document failure flags prevent writes to the failed document (`App.tsx`,
   `saveDraft`/`savePlans`). Existing empty strings are invalid, not missing.
   Temporary editing remains available with explicit no-autosave messaging.

2. **Ordinary navigation discarded imported media.** Switching from Editor to
   Planner and back previously unmounted the editor and revoked its file URLs.
   The host now retains the editor hidden within the same edit scope. Its
   `active` prop pauses playback and cancels export while inactive.
   Account/workspace changes still trigger cleanup.

3. **Connection failure silently disabled local autosave.** A signed-in account
   without a loaded workspace previously saw an apparently usable local editor
   while saves were rejected. `workspaceDraftReady` now gates the editor/planner.
   Connection errors offer an explicit switch to local mode through
   browser-local sign-out.

4. **Retry remounted stale temporary data before recovery finished.**
   `restoreScope` now includes the retry attempt. Readiness becomes false
   immediately and is restored only after both document reads finish. The editor
   then mounts from recovered data. Retry confirmation warns about discarding
   temporary edits/form changes and reselecting imported files.

Persistent invalid documents remain intact; recovery does not automatically
delete/reset them.

**Refresh recovery, updated 18:08 UTC:** Same-account library refresh now retains
the verified workspace and in-memory editor files. A known transient outage
shows a stale-data notice instead of resetting the draft. Access loss, malformed
responses, account/org changes, reload and explicit recovery still clear or
remount the affected scope; original-file reselection is then required.
The separately bundled App/services fixture passed hold/503/403/recovery/org/user
checks. Its deliberate old-behavior mutant failed at the exact refresh assertion.
This is offline identity-lifecycle proof, not live OAuth or private-media proof.

## Initial planner verification (before portable backups)

Working directory: `apps/studio`; Node `v25.9.0`.

```sh
node_modules/.bin/tsx --test \
  tests/drafts.test.ts \
  tests/planner.test.ts \
  tests/planner-mutants.test.ts \
  tests/workspace.test.ts
```

Actual result: **67 passed, 0 failed, 0 skipped; exit 0**.

- **19 recovery tests:** independent malformed documents, throwing reads/storage
  access, missing versus empty values, size limits, original-byte preservation,
  zero writes, and scoped keys.
- **48 planner/workspace tests:** dates, editing/removal, capacity, persistence,
  ICS, and mutation coverage.
- **Six actual-source mutants caught:** missing real-date guard, implicit
  repeated-hour selection, entry 101 permitted, append-on-edit, lone-CR escaping
  regression, and ignored UTC binding.

Each mutant must match exactly one source location and make the same passing
production probe fail. Missing anchors fail rather than skip.
Formatting-tolerant anchors preserve these controls.

Historical source hashes for that initial run:

```text
workspace.ts 45655c829a9b121cfec001b5c2e2b634d46d9efe1ca28ddc24968913c6a84c0f
drafts.ts    fb2dee5788bc09a91794acad273d604bc459d0b1adcc4a5cfd843556acdec55f
```

These unit tests do not establish React remount ordering, deployed OAuth, R2
CORS, browser export behavior, or release deployment. Consult the
root/identity/editor browser and deployment receipts for those claims. No
planner-unit work submitted an Apple build, connected social accounts, or changed
original customer media.

## Portable-backup verification

Working directory: `apps/studio`. Node `v25.9.0`. No new project dependencies,
server writes, social-provider calls, distribution build, or deployment.

```sh
node_modules/.bin/tsx --test \
  tests/planner-backup.test.ts tests/planner-backup-mutants.test.ts \
  tests/planner.test.ts tests/planner-mutants.test.ts tests/workspace.test.ts
npm run typecheck
```

Actual result: **90 passed, 0 failed, 0 skipped; exit 0**. Typecheck: **exit 0**.
The 42 new tests comprise 35 backup tests and seven mutation/receipt tests.
Seventeen deliberately invalid document fixtures refuse malformed JSON,
wrong/future formats, missing/unknown fields, inconsistent dates/timezones,
duplicate IDs, count 101, and injected identities. Additional tests cover UTF-8,
byte limits, complete maximum-field exports, merge/replace, stale snapshots,
single-save semantics, retained bytes after quota failure, explicit retry,
unreadable-draft prevention, and download URL cleanup on success/failure.

Six new actual-source mutants are caught: accepting an unsupported version,
duplicate merge IDs, merged count 101, stale replacement, nonfatal UTF-8 data
replacement, and a write that cannot reopen. Each transforms exactly one source
location and requires the identical positive probe to fail. The existing six
planner mutants still run. Both suites print the actual workspace source
SHA-256; missing anchors fail instead of skipping.

The first combined run passed all 83 then-present tests but typecheck failed on
two concurrent editor call signatures. After the editor owner corrected them,
the above expanded 90-test run and typecheck passed. No unrelated editor source
was changed by the planner unit. Formatting/final integration and real browser
evidence are tracked by the parent release report.
