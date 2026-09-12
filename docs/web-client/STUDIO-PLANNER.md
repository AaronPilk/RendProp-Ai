# Studio planner and draft recovery

Date: 2026-09-12

Worktree: `web-studio-20260912`
Branch: `feat/web-studio-20260912`

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

**Remaining lifecycle limitation:** Refresh library clears the loaded workspace
while revalidating it, changing the connected editor scope. Media may require
reselection afterward. Ordinary page navigation retains media; refresh,
account/workspace changes, reload, and explicit recovery are not promised to do
so.

## Executed verification

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

Final tested source hashes:

```text
workspace.ts 45655c829a9b121cfec001b5c2e2b634d46d9efe1ca28ddc24968913c6a84c0f
drafts.ts    fb2dee5788bc09a91794acad273d604bc459d0b1adcc4a5cfd843556acdec55f
```

These unit tests do not establish React remount ordering, deployed OAuth, R2
CORS, browser export behavior, or release deployment. Consult the
root/identity/editor browser and deployment receipts for those claims. No
planner-unit work submitted an Apple build, connected social accounts, or changed
original customer media.
