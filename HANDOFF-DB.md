# HANDOFF-DB — the AI router core (agent DB)

Shipped on `ai-router`:

| file | what |
|---|---|
| `services/supabase/migrations/0018_ai_routes.sql` | `app_config`, `ai_routes` (68 seeded rows), `plan_routing_policy`, `provider_health`, `report_provider_outcome()`, RLS + grants |
| `services/supabase/functions/_shared/router.ts` | contract §1: `resolveRoute` · `reportOutcome` · `routerEnabled` · `orderSteps` · `pickLedgerProvider` |
| `services/supabase/functions/_shared/router.test.ts` | 13 deno tests for `orderSteps` + the flag-off path |
| `services/supabase/functions/admin/index.ts` | ADDITIVE: `GET /admin/routing`, `POST /admin/routing/flag`, `POST /admin/routing/step/{id}` |
| `services/supabase/tests/invariants.sql` | +30 assertions (130 → 160) |
| `docs/ADMIN-CONSOLE-CONTRACT.md` | Routing section |

**Nothing is deployed.** The flag ships OFF, so applying 0018 and deploying
`admin` changes no behaviour.

---

## 1. Deviations from the frozen contract

**`RouteStep` is byte-identical to §1.** Two extra columns the ORDERING needs
(`position` for the "best" order, `retire_after` for the retirement filter) live
on a strict superset:

```ts
export interface ChainStep extends RouteStep { position: number; retire_after: string | null }
```

`orderSteps()` takes and returns `ChainStep[]`; `resolveRoute()` still declares
`Promise<RouteStep[]>`. A `ChainStep` IS a `RouteStep`, so nothing you write
against §1 changes. Consume `RouteStep` and ignore the extras.

**`orderSteps` takes an optional 4th argument.** `orderSteps(steps, ctx,
healthMap, now = new Date())`. The 3-arg call the brief specified is unchanged;
the 4th exists only so a test can assert an exact chain at an exact moment.

**Two providers outside §1's list.** `apple` is in the list; `rendprop` is not —
it is the fair-housing regex, our own offline code, seeded at 0¢ as step 1 of
`judge.fair_housing` so "the regex always runs first" is a row, not a convention.

**`privacy_tier` outranks cost, it does not merely break ties.** The brief reads
"…sort `no_retention` first, apply policy…"; a later stable sort by policy would
let 3¢ outrank a customer's property photo staying off a 30-day-retention
vendor. Privacy is the DOMINANT key when `carries_customer_media` is set, then
policy, then `position`. On the current seed the two readings give identical
answers (the only `no_retention` steps are the free on-device ones, already
first under both policies), so this is cheap insurance rather than a live
behaviour change.

**`claude-haiku-4-5` carries no `retire_after`.** §3 calls it a *watch*
(">= 2026-10-15"), not a retirement. `retire_after` is a hard auto-expiry —
`resolveRoute()` drops the row on that date with no announcement — so setting it
would silently remove Haiku from `judge.qc_drift` and `judge.fair_housing` in
October. The watch date is in the row's `note`; the successor
(`claude-sonnet-5 effort:low`) is already seeded as `judge.qc_drift` step 2.

**`whisper-1` is ENABLED with `retire_after = 2027-02-26`.** §3 lists it as a
live step with a sunset; the retirement paragraph lists it under "enabled=false
+ retire_after". Disabling it today would leave `stt.captions` with no cloud
fallback for 17 months. Encoded the way the column is designed to work: enabled
now, dropped automatically on the sunset date.

> ⚠️ The invariant *"no ENABLED step is past its retire_after"* therefore fires
> in CI on **2027-02-27** unless someone disables or replaces that row. That is
> the intended alarm, and the failure note names the offending row.

**Retirement tombstones are separate rows, not the legacy rows.** `retire_after`
is only ever set on `enabled = false` rows plus the whisper row above, so today
nothing can trip that invariant by accident. Tombstones: `gemini-2.5-flash-image`
(2026-10-02) and `gpt-image-1` (2026-10-23) on `photo.stage`, `sora-2`
(2026-09-24) on `video.reel_clip`.

**`min_plan` is `free` everywhere except `3d.world` (`pro`).** Plan gating is
already enforced upstream by `plan_entitlements`, and a second, different plan
gate inside the router would be a silent way to break a paying customer. The one
exception is WorldLabs Marble at **120¢ a world** — a COGS hole on an unpaid
tier. The column exists so a future premium-only step is a row edit.

---

## 2. Things ADAPT / CHAPTERS need to know

**Do not re-filter the chain.** Everything `resolveRoute()` returns is a step you
may run right now. In particular do NOT `.filter(s => s.enabled)` — the flag-off
legacy step is reported `enabled: true` for exactly this reason (its DB row is
`enabled = false` so it can never leak into a flag-ON chain).

**Pass only the capabilities you genuinely require.** The filter is a hard AND
over `ctx.needs`, and the seed is honest: the Hailuo reel fallback advertises
`768p`/`6s`, not `1080p`/`5s`. Asking for `1080p` correctly removes your only
availability-independent fallback. Ask for the least you can accept.

**An empty array is not only "no such task".** It also means every step was
filtered out (plan too low, a capability nothing provides, everything retired).
Both deserve a clear 503.

**The ledger records the RESELLER.** `pickLedgerProvider(step)` returns
`{provider: step.provider, model: step.model}`. `same_model_as` describes
availability, never billing.

**Legacy model strings are byte-identical to what you hardcode today**, prefixes
included (`fal-ai/bytedance/…`, `fal-ai/veo3.1/fast`, `fal-ai/topaz/upscale/video`,
`gemini-2.5-flash-image`, `with-timestamps`). The flag-ON rows carry the bare
slug. That is deliberate, and it is why `spend_30d_cents` in `/admin/routing`
matches on the exact pair.

**`video.aerial_no_photo`'s legacy row is priced per CALL (80¢), not per second**
— it mirrors `APP_AI_UNIT_CENTS.veo_aerial_clip`, which is how `/ai-video` bills
it today. The flag-ON Veo row is 10¢ per second.

### Known gap: `bria/video/erase/prompt`

`/ai-video`'s video-declutter path has **no route row**. §3 defines no
video-declutter task, and the repo has no committed price for Bria
(`admin/index.ts` lists `unit_cost_cents: null`; `/ai-video` writes no ledger row
for it). Seeding a row would have meant inventing a price. **That path must keep
its hardcoded model** until a price lands — then add a `video.declutter` task
(chain row + `note='legacy'` row) in a follow-up migration.

---

## 3. Prices that are ESTIMATED (not from the contract)

Nothing charges off these; they only order the `cheapest` policy. Each row says
so in its `note`.

| task / step | value | basis |
|---|---|---|
| `tts.captioned` / `tts.plain` — elevenlabs `with-timestamps` | 22¢ / 1k chars | Creator-tier credit rate; the repo has no ElevenLabs price and `/ai-voice` writes no ledger row today |
| `text.listing_copy` step 3 — gemini `gemini-3.8-flash` | 0.9¢ / call | flash-tier estimate; §3 states no number |
| `photo.declutter` step 1 — fal `flux-pro/v1/fill` | 5¢ / image | §3 quotes 5¢/**megapixel**; recorded per image because `cheapest` must compare like with like. A full-res edit costs more — verify before routing cheapest at scale |
| `photo.*` — openai `gpt-image-2` | 4.1¢ / image | §3's "4.1+" floor (medium quality, 1024²) |

**Unverified terms:** `worldlabs` (`3d.world`) is seeded `retained_30d` with no
adapter yet — confirm WorldLabs' retention/training terms **before** that step
ever carries customer media. Kie and Higgsfield are seeded `trains_by_default`
(the conservative assumption) and are disabled; that tier is also what keeps
customer media off them if somebody enables one early.

---

## 4. Operator behaviour worth knowing

* **Every seed is `on conflict … do nothing`.** Re-applying 0018 never reverts a
  flag flip or a step toggle made from the console. Verified: flag ON + one step
  disabled both survived a replay. The corollary is that a price correction is a
  ROW edit (or a new migration), never a re-run of this file.
* **The flag caches for 30 s per isolate** (`routerEnabled()`), as does the
  six-row policy table. Route rows and `provider_health` are never cached — a
  price edit and an outage both take effect on the very next request.
* **Everything fails safe to legacy.** An unreadable flag, an unreadable route
  table or a task with no enabled rows all fall back to the legacy step rather
  than onto an unproven chain.

## 5. Not done here

* `router.test.ts` is **not wired into CI** — `.github/workflows/ci.yml` is not a
  DB-owned file and its `edge-functions` job only loops `*/index.ts`. Add
  `deno test --allow-env --allow-net _shared/router.test.ts` to that job.
* No adapter calls `resolveRoute()` yet; nothing writes `provider_health` in
  production, so `p95_latency_ms` will read `null` until ADAPT lands.
