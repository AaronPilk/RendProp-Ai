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
| 405    | `validation`    | non-GET method. The ONE exception is a `POST` whose first path segment is `routing` — the dispatcher allows any `POST /admin/routing/**` past the method check, and an unrecognised one then 404s (see below) |
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
* Every route is `GET` **except** the two routing switches
  (`POST /admin/routing/flag`, `POST /admin/routing/step/{id}`), which are the
  only writes this function has: each sets one boolean and records who set it.
  Nothing here creates a route, edits a price or changes a model id — that is
  still a migration.

---

## `GET /admin/routing` — the AI router

**Version:** 1 (2026-09-04). Added by migration `0018_ai_routes.sql`. Source:
`public.ai_routes`, `public.plan_routing_policy`, `public.provider_health`,
`public.app_config` and a 30-day slice of `public.cost_ledger` — all read with
the service role AFTER the admin check.

Every AI task resolves through one chain of provider/model steps
(`_shared/router.ts` `resolveRoute()`), and the chain lives in a table so a
model retirement, a price change or a plan policy is a row edit rather than a
deploy. This route is where a human sees that brain: what each task would pick,
what a step costs, whether its circuit is open, and what it has actually spent.

**`enabled` is the whole story.** While it is `false`, every task resolves to
its `legacy` step and behaviour is exactly what shipped — the flag is what makes
the router deployable during a field test. The top-level `enabled` and
`flag.enabled` are the same boolean read from the same `app_config` row; a
client may read either.

**A `404 not_found` on this route is a STATE, not a failure.** It means the
deployed `admin` function predates migration `0018` and has no `routing` case,
so there is no routing table on that server and every AI feature is still using
today's single provider. Say that; do not show it as an error.

```json
{
  "generated_at": "2026-09-04T23:00:00.000Z",
  "enabled": false,
  "flag": {
    "enabled": false,
    "changed_at": null,
    "changed_by_is_you": false,
    "changed_by_recorded": false
  },
  "spend_window_days": 30,
  "spend_truncated": false,
  "routes_truncated": false,
  "note": "With `enabled` false every task resolves to its `legacy` step and behaviour is exactly what shipped. `spend_30d_cents` is matched on the EXACT (provider, model) pair a cost_ledger row carries, so a zero means no row with that exact pair in the window — not that the step is unused.",
  "policies": [
    { "plan": "free", "policy": "cheapest" },
    { "plan": "pro",  "policy": "best" }
  ],
  "routes": [
    {
      "task": "video.aerial",
      "step_count": 5,
      "live_step_count": 2,
      "legacy": {
        "route_id": "…uuid…",
        "provider": "fal",
        "model": "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video"
      },
      "steps": [
        {
          "route_id": "…uuid…",
          "position": 1,
          "provider": "fal",
          "model": "bytedance/seedance/v1/pro/fast/image-to-video",
          "unit": "second",
          "unit_cents": 4.86,
          "capabilities": ["i2v", "1080p", "6s", "8s", "16:9", "9:16"],
          "max_latency_s": 600,
          "min_plan": "free",
          "same_model_as": "bytedance/seedance-1.0-pro-fast",
          "privacy_tier": "retained_30d",
          "enabled": true,
          "retire_after": null,
          "is_legacy": false,
          "note": null,
          "updated_at": "2026-09-04T22:00:00.000Z",
          "health": {
            "open": false,
            "open_until": null,
            "consecutive_failures": 0,
            "p95_latency_ms": null,
            "last_ok_at": null,
            "last_fail_at": null,
            "last_error_class": null
          },
          "spend_30d_cents": 0,
          "spend_30d_rows": 0
        }
      ]
    }
  ]
}
```

* **The task array is `routes`, not `tasks`.** Each entry is
  `{task, step_count, live_step_count, legacy, steps}` and nothing else. It is
  grouped by `task`, sorted by task name; `steps` is sorted by `position`.
  `steps` carries **every** row for the task — the live chain, the retirement
  tombstones (`enabled:false` + a `retire_after`) and the `legacy` row — so
  nothing about a task is hidden. Use `is_legacy` and `enabled` to tell them
  apart, and `live_step_count` for "how many steps would the flag-ON chain
  actually offer today" (`enabled` **and** not `is_legacy` **and** not past
  `retire_after`, evaluated against today's UTC date).
* `is_legacy` is `note === "legacy"`, matched by exact string equality — the
  same lookup `_shared/router.ts` makes, which is why no other row may ever
  carry that `note` value.
* `legacy` is the flag-OFF answer for the task, or `null` if it has none
  (tasks with no shipped implementation yet, e.g. `3d.world`).
* `privacy_tier` ∈ `no_retention` · `retained_30d` · `trains_by_default`. A
  request carrying customer media never touches `trains_by_default` and prefers
  `no_retention`. Where a vendor's terms are unconfirmed the seed assumes the
  worst, which is why every Kie / Higgsfield row reads `trains_by_default`.
* `same_model_as` is an upstream family key. Two steps sharing it are the SAME
  model bought from different resellers — a failover between them buys a
  different queue, not a different model. `String?`.
* **`retire_after` is a bare `YYYY-MM-DD` day, not a timestamp** — the column is
  a Postgres `date`, so it does NOT follow this document's "timestamps are
  ISO-8601" rule. It is the only such field on this route; every other date-ish
  field here (`generated_at`, `updated_at`, `changed_at`, `health.open_until`,
  `health.last_ok_at`, `health.last_fail_at`) is a full ISO-8601 UTC timestamp.
  A client that parses one format only must handle this field separately.
  `String?`.
* `unit_cents` is never `null` and never a string: a missing price reads as `0`,
  and the value is rounded to 4 decimal places before it is sent. `min_plan` is
  never `null` either — an unset one reads as `"free"`. `max_latency_s` is
  seconds, `Int`, defaulting to `0` when the row has none.
* `health.open` is the circuit breaker: `true` means `open_until` is still in
  the future. An open circuit moves the step to the END of its chain, it is
  never removed — an outage must degrade, not hard-fail.
* `health.p95_latency_ms` is **not a true p95**: it is an asymmetric EWMA (rises
  fast, decays slowly) maintained by `public.report_provider_outcome()`. `Int?`.
* **`spend_30d_cents` is matched on the EXACT `(provider, model)` pair a
  `cost_ledger` row carries.** A `0` means "no ledger row with that exact pair in
  the window", NOT "this step is unused" — the legacy fal rows log `fal-ai/…`
  prefixed model ids while the router rows carry the bare slug, and they are
  deliberately different rows. `spend_30d_rows` is the row count behind the same
  figure (`Int`), and `spend_window_days` (30) is the window both were measured
  over. When `spend_truncated` or `routes_truncated` is `true`, a capped page was
  read and every figure on this payload is a LOWER BOUND — say so rather than
  presenting the totals as complete.
  * **Swift note:** `.convertFromSnakeCase` titlecases every component after the
    first, and `"30d".capitalized` is `"30D"`, so these two keys arrive as
    `spend30DCents` / `spend30DRows` — capital D. That titlecasing is
    ICU-dependent, so declare both spellings and read whichever arrived (the
    same defence `AdminMoney.currencyFormatter` documents).
* **There is no `changed_by`, and no field ever holds another admin's id.** The
  console's rule is that no user id but the caller's own appears in any payload,
  so the flag's audit trail is
  `flag: {enabled, changed_at, changed_by_is_you, changed_by_recorded}` — a
  boolean for "was it you" and a boolean for "was an actor recorded at all".
  The id itself stays in `app_config.ai_router` for anyone reading with the
  service role. A client can therefore say "last changed by you" or "by another
  admin", and must never invent a name.

---

## `POST /admin/routing/flag` — the master switch

Body: `{ "enabled": true|false }`. Anything else is a 400 `validation`.

```json
{
  "ok": true,
  "enabled": true,
  "changed_at": "2026-09-04T23:00:00.000Z",
  "note": "The router is ON. Each task now resolves to its table-driven chain."
}
```

Writes `app_config.ai_router` = `{enabled, changed_by, changed_at}` — a flip is
never anonymous. `_shared/router.ts` caches the flag for 30 s per isolate, so a
change is live within half a minute with no deploy.

**This ack is not a report.** It carries exactly the four keys above and nothing
else — no `routes`, no `flag`, no counts. A client that shows routing state must
re-read `GET /admin/routing` after the write, which is also what makes a UI
switch move only once the server has confirmed it. `note` is the server's own
sentence for the direction just taken and is meant to be shown verbatim; it is
the only `note` either write returns.

---

## `POST /admin/routing/step/{route_id}` — one step on or off

`route_id` is the `route_id` from `GET /admin/routing`; a non-uuid is a 400.
Body: `{ "enabled": true|false }`.

```json
{
  "ok": true,
  "route_id": "…uuid…",
  "task": "video.aerial",
  "position": 2,
  "provider": "higgsfield",
  "model": "bytedance/seedance/v1/pro/fast/image-to-video",
  "enabled": false,
  "changed_at": "2026-09-04T23:00:00.000Z",
  "audit_recorded": true
}
```

| status | `code`       | when |
|--------|--------------|------|
| 400    | `validation` | body is not `{"enabled": bool}`, or `route_id` is not a uuid |
| 404    | `not_found`  | no such route step |
| 404    | `not_found`  | the POST path is neither `flag` nor `step` (`POST /admin/routing`, `POST /admin/routing/anything-else`) |
| 409    | `conflict`   | the target is the task's `legacy` row — see below |

**This ack carries no `note`** — the nine keys in the example above are all of
it. Only the flag write returns a `note`. A client that displays `note` after a
write must have its own sentence ready for this route.

**The legacy row is not a switch.** Enabling it would put today's model into the
flag-ON chain as well and silently change routing; disabling it would delete the
flag-OFF answer for that task. Turn the router itself off with
`POST /admin/routing/flag` instead.

Who flipped what is recorded in `app_config` under the key
`ai_router_last_step_change` (`{route_id, task, position, provider, model,
enabled, changed_by, changed_at}`) — a separate key from the master flag, so a
step toggle can never overwrite the flag's own audit trail. `audit_recorded` is
`false` if that best-effort write failed; the toggle itself still applied.

**What these two routes cannot do:** create a step, delete a step, change a
price, change a model id, or change a capability. Every one of those is a
migration, which is what keeps the chain reviewable.
