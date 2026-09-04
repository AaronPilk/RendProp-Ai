# Admin spend console — wire contract

**Function:** `services/supabase/functions/admin/index.ts`
**Base path:** `/functions/v1/admin`
**Auth:** owner JWT (`Authorization: Bearer <access_token>`), same as every other
owner route. **The role is SERVER-ENFORCED.** The client never asserts it and
there is no header, body field or query parameter that can grant it: the
function reads `public.profiles.is_admin` for `auth.uid()` with the service-role
client and 403s otherwise. A hostile client holding a perfectly valid non-admin
JWT gets the same 403 on every route, and — independently — Postgres RLS gives
it nothing extra even on a direct PostgREST call (migration `0017_admin_role.sql`).

**Version:** 1 (2026-09-04). Every field below is ALWAYS present. Optionals are
sent as explicit `null`, arrays are sent as `[]`, never omitted — so a Swift
`Codable` struct with non-optional properties (except where marked `?`) decodes
without a `keyNotFound`. There are no free-form dictionaries anywhere: every
map-shaped thing is an array of fixed-key objects.

**Money:** every `*_cents` field is a `Double` (the ledger stores
`numeric(12,4)`; fractional cents are real — one Gemini image edit is `3.9`).
Counts are `Int`. Timestamps are ISO-8601 UTC strings.

---

## Errors

The standard envelope from `_shared/http.ts` — unchanged:

```json
{ "error": "Admin access is required for this console.", "code": "forbidden", "reason": "not_admin" }
```

| status | `code`          | when |
|--------|-----------------|------|
| 401    | `unauthorized`  | missing / invalid bearer token |
| 403    | `forbidden`     | valid JWT, `profiles.is_admin` is false → `reason: "not_admin"` |
| 403    | `forbidden`     | admin lookup failed (fail closed) → `reason: "admin_check_failed"` |
| 404    | `not_found`     | unknown route |
| 405    | `validation`    | non-GET method |
| 429    | `rate_limited`  | more than 60 admin calls/minute for this user |
| 500    | `internal`      | unexpected |

`reason` is present ONLY on the two 403s above; treat it as `String?`.

---

## `GET /admin/spend?window=today|7d|30d`

Default `window=today`. Anything else is a 400 `validation`.
Source: `public.cost_ledger` (read with the service role AFTER the admin check).

```json
{
  "window": "7d",
  "from": "2026-08-28T00:00:00.000Z",
  "to": "2026-09-04T18:12:03.101Z",
  "generated_at": "2026-09-04T18:12:03.101Z",
  "total_cents": 418.7412,
  "ledger_rows": 96,
  "truncated": false,
  "by_provider": [
    { "key": "fal", "label": "fal.ai", "total_cents": 310.4, "rows": 41, "share": 0.7413 }
  ],
  "by_feature": [
    { "key": "hero", "label": "AI hero clip", "total_cents": 240.0, "rows": 10, "share": 0.5732 }
  ],
  "by_org": [
    { "org_id": "0f1e2d3c-4b5a-4968-8776-655443322110", "org_name": "Fixture Agent",
      "plan": "pro", "total_cents": 118.9, "rows": 22, "share": 0.2839 }
  ],
  "coverage": {
    "complete": false,
    "headline": "Incomplete: 3 spend source(s) never reach the ledger, so real provider spend is HIGHER than the total shown.",
    "represented_count": 2,
    "missing_count": 3,
    "sources": [
      {
        "key": "worker_pipeline",
        "label": "Worker render pipeline — declutter, restage, hero clip, QC",
        "represented": true,
        "detail": "services/pipeline writes one cost_ledger row per metered provider call through log_job_cost(), which also enforces the per-job cap and the per-org monthly COGS ceiling.",
        "reference": "services/pipeline/cost_ledger.py"
      },
      {
        "key": "app_ai_photo",
        "label": "In-app AI photo edits (POST /ai-photo)",
        "represented": false,
        "detail": "The ai-photo edge function never writes a cost_ledger row, so every Photo Studio edit is missing from the total above and from the per-org monthly COGS ceiling. Real provider spend is HIGHER than this number. Size the gap from GET /admin/usage photo_edits_used x 3.9c.",
        "reference": "docs/handoff/E-network.md §2 (finding F-E-15)"
      }
    ]
  }
}
```

* `by_org` may contain one entry with `"org_id": null` and
  `"org_name": "(unattributed)"` — ledger rows whose org could not be resolved
  (`cost_ledger.org_id` is nullable and is `set null` when an org is deleted).
  Decode `org_id` and `plan` as `String?`.
* `share` is this bucket ÷ `total_cents`, rounded to 4 dp; `0` when the total is 0.
* Every array is sorted by `total_cents` descending.
* `truncated` is `true` if the window held more ledger rows than the read cap
  (50 000); the totals are then a lower bound for that window.

### The `coverage` object — read this before believing `total_cents`

`total_cents` is **the ledger's number, not the invoice**. The console must
render `coverage.headline` next to the total whenever `complete` is `false`.

`sources` always has these five entries, in this order:

| `key` | represented today | why |
|---|---|---|
| `worker_pipeline` | yes | `services/pipeline` logs every metered call via `log_job_cost()` |
| `worker_infra` | yes | `services/worker/infra_costs.py` logs `render` + `stream_store` (the render number is a configurable estimate, not a vendor bill) |
| `app_ai_photo` | **no** | `ai-photo/index.ts` makes billable Gemini calls and writes no ledger row |
| `app_ai_video` | **no** | `ai-video/index.ts` makes billable fal calls (aerial $0.80, Topaz up to $14.40) and writes no ledger row |
| `stream_delivery` | **no** | views are metered in `metering` (watched minutes) but never priced into the ledger |

The two app-AI gaps are `docs/handoff/E-network.md` §2, finding **F-E-15**. That
consumption *is* metered — as the monthly feature counters `GET /admin/usage`
reports — but it never becomes money in this ledger, and it never reaches the
per-org monthly COGS ceiling inside `log_job_cost()`. So `total_cents` alone
understates real provider spend, and the size of the gap is exactly
`GET /admin/usage`'s photo-edit / reel / aerial / drone counters × the unit
prices in `GET /admin/providers`.

`represented` is **probed against the data, not asserted in prose**, so coverage
heals itself when those writers land instead of going stale: app AI has no
render job, so an org-scoped `cost_ledger` row with `job_id IS NULL` can only
have come from an app-AI ledger write, and stream delivery would arrive as
`feature = 'stream_deliver'`. `complete` is `true` only when all five are
represented. A failed probe counts as *not* represented — the response never
claims coverage it could not confirm.

---

## `GET /admin/providers`

Static inventory derived from the repo's own cost model, plus a **live boolean**
for whether each credential env var is present in this function's environment.

**Credential rule (enforced, not aspirational): a credential VALUE is never
returned, logged or echoed — not the value, not a prefix, not a suffix, not a
length. Only the env var NAME and a boolean.**

```json
{
  "generated_at": "2026-09-04T18:12:03.101Z",
  "provider_count": 9,
  "configured_count": 6,
  "providers": [
    {
      "key": "fal",
      "name": "fal.ai",
      "kind": "ai",
      "billable": true,
      "credential_env": "FAL_KEY",
      "env_names": ["FAL_KEY"],
      "configured": true,
      "ledger_provider": "fal",
      "models": [
        {
          "sku": "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video",
          "label": "Seedance 1.0 Pro Fast — image-to-video",
          "unit": "second of generated clip",
          "unit_cost_cents": 4.8,
          "trigger": "POST /ai-video/reel-clip (Reel clip in the app); worker hero clip",
          "source": "services/pipeline/providers/costs.py — UNIT_COSTS_CENTS.hero_seedance_per_s"
        }
      ]
    }
  ]
}
```

* `unit_cost_cents` is `Double?` — `null` where the repo has no committed price
  for that SKU (currently only `bria/video/erase/prompt`). The `source` field
  says so in words in that case.
* `kind` ∈ `ai` | `infra` | `integration`.
* `configured` is `true` only when **every** name in `env_names` is set to a
  non-empty (trimmed) value in this function's environment.
* `ledger_provider` is `String?` — the `cost_ledger.provider` value this
  provider's rows carry, or `null` when it never writes ledger rows (which is
  itself part of the coverage story).

---

## `GET /admin/usage`

Per-org plan, this month's counters against `plan_entitlements`, and who is
blocked. **Org-level aggregates only — no member, no email, no name of any
person.** Orgs sorted by month spend descending, then by name.

```json
{
  "generated_at": "2026-09-04T18:12:03.101Z",
  "month": "2026-09",
  "month_start": "2026-09-01T00:00:00.000Z",
  "org_count": 12,
  "blocked_count": 2,
  "truncated": false,
  "orgs": [
    {
      "org_id": "0f1e2d3c-4b5a-4968-8776-655443322110",
      "org_name": "Fixture Agent",
      "plan": "free",
      "plan_raw": "trial",
      "trial_ends_at": "2026-09-01T00:00:00.000Z",
      "spend_cents_month": 118.9,
      "cogs_ceiling_cents": 800,
      "spend_share_of_ceiling": 0.1486,
      "renders_used": 1, "renders_cap": 1,
      "photo_edits_used": 10, "photo_edits_cap": 10,
      "reels_used": 0, "reels_cap": 1,
      "aerials_used": 0, "aerials_cap": 2,
      "drone_used": 0, "drone_cap": 1,
      "jobs_in_flight": 1,
      "jobs_orphaned": 0,
      "blocked": true,
      "blocked_reasons": ["renders_at_cap", "photo_edits_at_cap"]
    }
  ]
}
```

* `plan` is the **effective** plan (`effective_plan()` — an expired trial reads
  `free`, exactly as the charge paths see it). `plan_raw` is `orgs.plan` as
  stored. `trial_ends_at` is `String?`.
* Counters come from the same `rate_limits` rows the AI routes charge
  (`aiphotomo:` / `reelmo:` / `aerialmo:` / `dronemo:` + `<org_id>`), clamped to
  the cap and treated as `0` once their 30-day window has expired — identical
  arithmetic to `GET /me`. `renders_used` counts `source='worker'` render jobs
  this calendar month, which is what `create_render_job` enforces.
* `jobs_orphaned` = `status='processing'` worker jobs with a `lease_expires_at`
  in the past (migration 0015). These are dead but were, before 0015, enough to
  lock a workspace out of publishing — so they are surfaced.
* `blocked_reasons` is a stable slug array, possibly empty. Known values:
  `renders_at_cap`, `photo_edits_at_cap`, `reels_at_cap`, `aerials_at_cap`,
  `drone_at_cap`, `spend_ceiling_reached`, `jobs_in_flight_max`,
  `orphaned_jobs`. `blocked` is `true` iff the array is non-empty.
* `truncated` is `true` when more than 200 orgs exist; the list is the top 200
  by month spend.

---

## `GET /admin/health`

Credential configuration + the most recent success/failure **visible in data we
already hold**. This route makes **no outbound provider calls** — no spend, no
latency, no key exercised.

```json
{
  "generated_at": "2026-09-04T18:12:03.101Z",
  "checked_provider_apis": false,
  "note": "No provider API is called by this route. Success is inferred from cost_ledger rows (a row is only written after a metered call returned); failures are render-job failures, which are NOT attributed to a provider.",
  "window_days": 7,
  "providers": [
    {
      "key": "fal",
      "name": "fal.ai",
      "credential_env": "FAL_KEY",
      "configured": true,
      "status": "ok",
      "ledger_provider": "fal",
      "last_success_at": "2026-09-04T17:40:12.000Z",
      "last_success_detail": "hero / fal-ai/bytedance/seedance/v1/pro/fast/image-to-video",
      "rows_in_window": 41,
      "spend_cents_in_window": 310.4
    }
  ],
  "job_failures": {
    "window_days": 7,
    "failed_jobs": 3,
    "orphaned_jobs": 1,
    "last_failure_at": "2026-09-03T09:11:02.000Z",
    "last_failure_step": "enhance",
    "last_failure_type": "ProviderError",
    "by_step": [ { "key": "enhance", "count": 2 }, { "key": "reaper", "count": 1 } ]
  }
}
```

* `providers` carries **all nine** entries from `GET /admin/providers`, in the
  same order: the six that write ledger rows first, then the three that never do.
* `status` ∈ `ok` (configured + a ledger row inside the window) · `idle`
  (configured, no ledger row in the window) · `unmetered` (configured, but this
  provider never writes ledger rows — nothing here can prove it worked) ·
  `unconfigured` (credential env missing → the feature is off).
* `last_success_at` / `last_success_detail` are `String?`.
* **`job_failures` carries no free text from a provider.** Only
  `error->>'step'` and `error->>'type'` are exposed — `error->>'message'` is
  deliberately withheld because it is an arbitrary upstream string that could
  carry a signed URL or key material.
* Failures are per-job, not per-provider: `render_jobs.error` is
  `{message, step, type, ts}` (`services/worker/worker.py`) and does not record
  which provider failed. The response says so rather than guessing.

---

## What the console must not expect

* No user emails, names, phone numbers, avatars or ids of anybody other than the
  caller. `by_org` / `orgs` identify a workspace by `org_id` + `org_name` only.
* No credential values, prefixes, suffixes or lengths — anywhere, ever.
* No route mutates anything. Every route is `GET`.
