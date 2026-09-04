# HANDOFF — area G (render worker + AI pipeline) → Supabase / edge / iOS owners

Everything in this file is a change area G **cannot make itself**: this worktree owns
`services/worker/`, `services/pipeline/` and `services/marketing-video/` only. The worker
code that depends on each item already ships, degrades cleanly without it, and says so at
startup — so nothing here is blocking, but each one closes a real failure mode.

Contains **no credential values.**

---

## 1. REQUIRED — migration `0015_job_lease.sql` (audit F-G-05)

Without this, a worker that dies mid-render leaves its job at `status='processing'`
**forever**. Nothing re-queues it, the app polls a job that never finishes, and after three
such orphans `create_render_job` raises `RP429` for **every** subsequent publish in that org
(including free app-published base tours) — permanently, until someone edits rows by hand.

The worker already detects whether these columns exist (one probe at first claim) and, when
they are absent, runs exactly as before while printing:

> `⚠ render_jobs has no lease_expires_at/attempts/worker_id (migration 0015 not applied) — NO stuck-job recovery`

```sql
-- 0015_job_lease.sql — worker job leases, attempt counting and stuck-job recovery.
-- Audit F-G-05. Safe to run more than once.

-- ── 1. lease columns ─────────────────────────────────────────────────────────
alter table public.render_jobs
  add column if not exists lease_expires_at timestamptz,
  add column if not exists attempts         integer not null default 0,
  add column if not exists worker_id        text;

comment on column public.render_jobs.lease_expires_at is
  'Wall-clock deadline on the current claim. The owning worker refreshes it every '
  'WORKER_HEARTBEAT_S (default 60s). Past this instant with status=processing the '
  'job is orphaned and reclaimable.';
comment on column public.render_jobs.attempts is
  'Times this job has been claimed. At WORKER_MAX_ATTEMPTS (default 3) the reaper '
  'marks it failed with error->>type = ''poison'' instead of looping forever.';
comment on column public.render_jobs.worker_id is
  'Host:pid (or WORKER_ID) of the worker holding the lease. The heartbeat filters on '
  'it so a worker that lost the race can never extend someone else''s lease.';

-- The claim/reclaim/reaper queries all filter on (status, lease_expires_at).
create index if not exists idx_jobs_lease
  on public.render_jobs (status, lease_expires_at)
  where status = 'processing';

-- ── 2. stop orphans from consuming the 3-in-flight cap ───────────────────────
-- 0008_audit_round4.sql:129-134 counts every source='worker' job in
-- (created, queued, processing) toward the cap used by BOTH POST /renders and
-- publish-app. An orphan is not in flight; it is dead. Exclude jobs whose lease
-- has expired, so a stuck row can never lock an org out of publishing.
--
-- Apply this as an edit to the in-flight count inside create_render_job():
--
--     and (
--       rj.status in ('created','queued')
--       or (rj.status = 'processing'
--           and (rj.lease_expires_at is null or rj.lease_expires_at > now()))
--     )
--
-- (`lease_expires_at is null` keeps pre-0014 rows counted, which is the safe
--  direction: they are never silently uncapped.)

-- ── 3. one-off: release orphans that already exist ───────────────────────────
update public.render_jobs
   set status = 'queued', started_at = null, progress = 0,
       current_step = 'requeued: orphaned before 0014', error = null
 where status = 'processing'
   and source = 'worker'
   and started_at < now() - interval '2 hours';
```

**Deploy order:** apply the migration first, then restart the workers. A worker started
before the migration latches "no lease support" for the life of its process.

Worker knobs that go with it (all optional, all in `services/worker/.env.example`):
`WORKER_LEASE_S` (600), `WORKER_HEARTBEAT_S` (60), `WORKER_MAX_ATTEMPTS` (3),
`REAP_INTERVAL_S` (120), `WORKER_ID`.

---

## 2. RECOMMENDED — migration `0016_enhancement_outcome.sql` (audit F-G-01 #2, F-G-09)

Today `publish_render` derives `renders.staged` from the *toggles the user picked*
(`0008_audit_round4.sql:220-222`), so a tour is stamped "✦ Virtually staged" plus the MLS
disclosure even when no pixel was altered — which is the compliance failure in reverse, and
false advertising of a feature that did not run. And when enhancement is skipped or partly
fails, the reason is only printed to the worker's stdout: ops cannot tell from the database
whether a paid add-on ran.

The worker writes `enhancement_result` best-effort **already** (missing column → one warning,
job still publishes), so applying this migration is all that is needed to light it up.

```sql
-- 0016_enhancement_outcome.sql — record what the AI pipeline actually DID.
alter table public.render_jobs
  add column if not exists enhancement_result jsonb;

comment on column public.render_jobs.enhancement_result is
  'Written ONLY by the render worker: {ran, staged, reason, spent_cents, segments, '
  'errors}. `staged` is an OUTCOME (a segment passed QC and shipped an edit), never '
  'an intent derived from the request toggles.';

alter table public.renders
  add column if not exists hero_key text;

comment on column public.renders.hero_key is
  'R2 key of the optional Seedance hero clip (renders/{listing}/{render}-hero.mp4). '
  'Until this existed the worker uploaded the clip and had nowhere to reference it.';
```

Then, in `publish_render` (0008:220-222), replace the toggle-derived flag:

```sql
-- was: v_staged := (v_enh->>'declutter')::bool
--                  or coalesce(v_enh->>'style','') not in ('as_is','as-is','asis','none','');
-- now: outcome, not intent. An app-published tour (no worker) has no
--      enhancement_result, so it is correctly NOT staged.
v_staged := coalesce((v_job.enhancement_result->>'staged')::bool, false);
```

And have `GET /renders/:id` + `functions/tours/index.ts` return `enhancement_result` and
`hero_key` so `RenderStatusView` can say *why* an add-on did not run.

---

## 3. FYI — items area G verified but cannot fix

| audit id | what | who owns it |
|---|---|---|
| F-G-01 | Nothing creates worker jobs in live mode (`ReviewSubmitView.start()` skips `POST /renders`; `publish-app` goes straight to `ready`; `/ai-enhance` enqueues into `enhancements._requests`, which no code reads). The worker is correct and unreachable. | iOS + `services/supabase/functions` |
| F-G-10 | `POST /renders` accepts no `chapters`, and `/uploads/:id/complete` has no `chapters` field, so `capture_chapters` is always empty for worker jobs → the pipeline falls back to blind time slices and the tour's tap-to-jump dots are empty. Also undecided: source time vs rendered time. The worker README no longer claims otherwise. | edge + iOS |
| F-G-13 | The claim filter (`source=eq.worker` + `capture_assets.bucket=eq.uploads`) depends on `render_jobs.source` from `0011_app_publish_and_lifecycle.sql` — **verified present**. No action. | — |
| F-G-18 | `uploads/index.ts:158` and `0006_p0_rpcs.sql:208` accept **7200 s** sources; the worker's `MAX_SOURCE_SECONDS` is now aligned to 7200 so a 61–120 min upload no longer consumes entitlement and then fails. If you would rather cap at 3600, enforce it in `create_render_job` so the customer is told **before** they upload 12 GB. | Supabase (optional) |
| — | `apps/ios/Rendprop/Config.swift:31` has a committed Supabase JWT. Decoded claims: `role=anon` — public by design, not a leak. It stops working if the project's JWT secret is rotated (see `services/pipeline/SECRETS-ROTATION.md`). | iOS |
| F-G-23 | `docs/AI-ENHANCEMENTS-SPEC.md:12` ("Both are wired end-to-end … → render job → status steps") and `:51` ("Now (done)") are not true in live mode — see F-G-01. Its provider table (Higgsfield / SAM-2 / ProPainter) also differs from the code (Gemini / Flux / Seedance). | docs |
| F-G-19 | `docs/AI-COST-MODEL.md:30` claims a −90% prompt-cache discount on the QC rubric. The rubric is ~540 tokens and Haiku's minimum cacheable prefix is ~4096, so it never cached. The inert `cache_control` marker has been removed from the code; the doc line should go or become aspirational. | docs |

---

## 4. Operational notes for whoever deploys the worker

- **Cost-spool durability.** Cost rows that cannot reach Supabase are spooled to disk and
  replayed. The default path is under the system temp dir, which on Cloud Run and Modal is
  tmpfs and is **lost on restart**. Set `COST_LEDGER_SPOOL` to a path on a persistent volume
  (and `COST_LEDGER_SPOOL_DURABLE=1`). The worker prints which of the two it has at startup.
- **Deploy timeout ≥ ffmpeg ceiling.** `FFMPEG_TIMEOUT_S` defaults to 5400 s. A platform
  timeout below that SIGKILLs mid-encode; with §1 applied the job is reclaimed, without it
  the job is orphaned. The README's Modal example says the same.
- **Disk, not RAM.** The worker now refuses a job when free space is under ~2.5× the source
  (`shutil.disk_usage`), which turns a silent OOM into a clear, retryable failure. Cloud Run's
  filesystem is in-memory and counts against the instance's RAM — give the worker a
  disk-backed volume, or size the instance for 12 GB captures.
