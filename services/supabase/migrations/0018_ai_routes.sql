-- 0018: the AI ROUTER — routes live in a table, not in code (2026-09-04).
--
-- Every AI task in the product resolves through ONE resolver
-- (functions/_shared/router.ts) that returns an ORDERED CHAIN of provider/model
-- steps. Callers try the chain in order and report every outcome back, so the
-- router can open a circuit and the ledger can attribute spend to the step that
-- actually ran. The whole point of this migration is that a model retirement, a
-- price change, or a plan-tier policy becomes a ROW EDIT rather than a deploy.
--
-- The frozen interface three other agents are building against right now is
-- docs/AI-ROUTER-CONTRACT.md. This file is §3 of that contract, materialised.
--
-- ── FOUR THINGS THIS FILE IS CAREFUL ABOUT ───────────────────────────────────
--
-- 1. THE FLAG IS OFF AND A REPLAY NEVER TURNS IT BACK ON (or off).
--    `app_config('ai_router')` seeds `{"enabled": false}` and EVERY seed in this
--    file is `on conflict ... do nothing`. A field test is live on the current
--    functions; re-applying 0018 on a database where the owner has already
--    flipped the flag — or disabled a step from the admin console — must not
--    revert their decision. That also means a price correction is made in the
--    TABLE (or through the console), never by editing and re-running this file:
--    exactly the property the contract asks for.
--
-- 2. FLAG OFF = BYTE-IDENTICAL LEGACY BEHAVIOUR. Every task the app runs today
--    also gets a row tagged `note = 'legacy'` carrying the provider/model that
--    is hardcoded in the shipped edge functions RIGHT NOW. With the flag off,
--    resolveRoute() returns that one row and nothing else, so the deploy is a
--    no-op in production. The legacy rows are `enabled = false` so they can
--    never leak into a flag-ON chain (that lookup is by `note`, not `enabled`).
--
-- 3. AN OUTAGE DEGRADES, IT DOES NOT HARD-FAIL. `provider_health` is a circuit
--    breaker, and an open circuit moves a step to the END of the chain — it is
--    never removed. report_provider_outcome() is the only thing that writes it.
--
-- 4. NOTHING HERE IS A CREDENTIAL. `ai_routes` holds model ids and prices, which
--    are not secret, so `authenticated` may READ it (the app can show which
--    model produced a result). `provider_health` and `app_config` are
--    admin-only: an outage map and an operational flag are not tenant business.
--
-- Idempotent: `create table if not exists` / guarded constraints / `drop policy
-- if exists` before `create policy` / `create or replace function` /
-- `on conflict do nothing` seeds. Safe to re-apply on a migrated database.

-- ── 1. app_config — the master flag ─────────────────────────────────────────
-- A tiny key/value table. Today it holds exactly one key; it exists as a table
-- rather than an env var because flipping the router must NOT require a deploy
-- (the whole reason the field test can stay up while this lands).

create table if not exists public.app_config (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

comment on table public.app_config is
  'Operational key/value flags read by the edge functions. Admin/service-role '
  'only. `ai_router` = {enabled, changed_by, changed_at} — the AI router master '
  'switch (functions/_shared/router.ts routerEnabled()).';

-- The master switch, OFF. `do nothing` so a replay never reverts an owner who
-- has already turned it on from GET/POST /admin/routing.
insert into public.app_config (key, value)
values ('ai_router', '{"enabled": false}'::jsonb)
on conflict (key) do nothing;

-- ── 2. ai_routes — the chain ────────────────────────────────────────────────
--
-- One row = one STEP of one task's chain. `position` is the "best" order (the
-- seed order of docs/AI-ROUTER-CONTRACT.md §3); the `cheapest` policy re-sorts
-- the same valid steps by `unit_cents`.
--
-- Column notes that carry real meaning:
--   • unit_cents      researched price 2026-09-04, CENTS per `unit`. Estimated
--                     rows are called out in the seed comments below.
--   • capabilities    what this step can ACTUALLY do. A caller passes the
--                     capabilities it REQUIRES in RouteContext.needs and any
--                     step lacking one is filtered out. These are honest, not
--                     aspirational: the 768p Hailuo fallback does not claim
--                     "1080p", which is why a caller that hard-requires 1080p
--                     will not be offered it.
--   • same_model_as   upstream family key. Two steps sharing it are the SAME
--                     upstream model bought from different resellers, so they
--                     are NOT availability-independent — a failover between
--                     them buys you a different queue, not a different model.
--   • privacy_tier    the vendor's data posture. `carries_customer_media`
--                     callers never touch `trains_by_default` and prefer
--                     `no_retention`. Where a vendor's commercial terms are
--                     unconfirmed we assume the WORST (`trains_by_default`),
--                     which is what makes the Kie/Higgsfield rows safe to have
--                     in the table at all while their terms are being checked.
--   • retire_after    the date after which the router must stop choosing this
--                     row. resolveRoute() drops `retire_after < today`, so an
--                     announced sunset is a date in a row, not a calendar
--                     reminder. Deliberately NULL on `note='legacy'` rows —
--                     those describe what the app runs today, not what the
--                     router may choose.
--   • note            free text for operators, with ONE reserved value:
--                     exactly 'legacy' marks the flag-off row for a task.
--                     Nothing else may use that exact string.

create table if not exists public.ai_routes (
  id            uuid primary key default gen_random_uuid(),
  task          text not null,
  position      integer not null,
  provider      text not null,
  model         text not null,
  unit          text not null,
  unit_cents    numeric(10,4) not null default 0,
  capabilities  text[] not null default '{}',
  max_latency_s integer not null default 120,
  min_plan      text not null default 'free',
  same_model_as text,
  privacy_tier  text not null default 'retained_30d',
  enabled       boolean not null default true,
  retire_after  date,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.ai_routes'::regclass and conname = 'ai_routes_privacy_tier_check'
  ) then
    alter table public.ai_routes add constraint ai_routes_privacy_tier_check
      check (privacy_tier in ('no_retention','retained_30d','trains_by_default'));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.ai_routes'::regclass and conname = 'ai_routes_min_plan_check'
  ) then
    -- The same six plans plan_entitlements carries (0010 §1). A typo here would
    -- otherwise silently make a step unreachable for everyone.
    alter table public.ai_routes add constraint ai_routes_min_plan_check
      check (min_plan in ('free','trial','starter','solo','pro','team'));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.ai_routes'::regclass and conname = 'ai_routes_position_check'
  ) then
    alter table public.ai_routes add constraint ai_routes_position_check
      check (position >= 0);
  end if;
end $$;

-- (task, position) is the chain's identity, and it is what every seed below
-- keys its `on conflict do nothing` on — so a replay recognises a row it
-- already inserted even though `id` is a fresh uuid each time.
create unique index if not exists uq_ai_routes_task_position
  on public.ai_routes (task, position);

create index if not exists idx_ai_routes_task_enabled
  on public.ai_routes (task, enabled);

-- One 'legacy' row per task, enforced rather than assumed: the flag-off path
-- reads it with LIMIT 1 and an accidental second row would make which model
-- runs today depend on a sort.
create unique index if not exists uq_ai_routes_legacy_per_task
  on public.ai_routes (task) where note = 'legacy';

comment on table public.ai_routes is
  'The AI router chain: one row per (task, position) step. Read by '
  'functions/_shared/router.ts resolveRoute(). `note = ''legacy''` marks the '
  'single flag-off step for a task (today''s hardcoded provider/model) and is '
  'the ONLY reserved value of that column.';

comment on column public.ai_routes.same_model_as is
  'Upstream model family key. Steps sharing it are the SAME upstream model via '
  'different resellers and are therefore NOT availability-independent.';

comment on column public.ai_routes.retire_after is
  'Date after which resolveRoute() must not choose this row. NULL on legacy '
  'rows — they describe what ships today, not what the router may pick.';

-- ── 3. plan_routing_policy — best vs cheapest, per plan ─────────────────────

create table if not exists public.plan_routing_policy (
  plan   text primary key,
  policy text not null
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.plan_routing_policy'::regclass
       and conname = 'plan_routing_policy_policy_check'
  ) then
    alter table public.plan_routing_policy add constraint plan_routing_policy_policy_check
      check (policy in ('best','cheapest'));
  end if;
end $$;

comment on table public.plan_routing_policy is
  'Default RouteContext.policy per plan (contract §3): the plans that pay '
  'nothing or little route CHEAPEST, the paid tiers route BEST. A caller may '
  'still override it explicitly.';

insert into public.plan_routing_policy (plan, policy) values
  ('free',    'cheapest'),
  ('trial',   'cheapest'),
  ('starter', 'cheapest'),
  ('solo',    'best'),
  ('pro',     'best'),
  ('team',    'best')
on conflict (plan) do nothing;

-- ── 4. provider_health — the circuit breaker ────────────────────────────────
-- Written ONLY by report_provider_outcome() below. Read by resolveRoute() to
-- move an open-circuit step to the END of the chain.

create table if not exists public.provider_health (
  provider             text not null,
  model                text not null,
  consecutive_failures integer not null default 0,
  open_until           timestamptz,
  p95_latency_ms       integer,
  last_ok_at           timestamptz,
  last_fail_at         timestamptz,
  last_error_class     text,
  primary key (provider, model)
);

comment on table public.provider_health is
  'Circuit breaker state per (provider, model). An OPEN circuit '
  '(open_until > now()) demotes a step to the end of its chain — it is never '
  'removed, because an outage must degrade and not hard-fail.';

comment on column public.provider_health.p95_latency_ms is
  'NOT a true p95: an asymmetric EWMA (rises fast, decays slowly) maintained by '
  'report_provider_outcome(). It tracks the upper tail closely enough to compare '
  'against ai_routes.max_latency_s without storing a latency histogram. The '
  'column keeps the contract''s name so callers need not learn a second one.';

-- ── 5. SEED: docs/AI-ROUTER-CONTRACT.md §3, in full ─────────────────────────
--
-- POSITION CONVENTION
--   1..9   the live chain, in "best" order (the contract's own order)
--   90..98 retirement tombstones: enabled = false + retire_after. These models
--          are NOT in any chain; the row exists so the retirement is a fact in
--          the database instead of a line in a doc, and so an operator sees the
--          lineage next to the successor that replaced it.
--   99     the single `note = 'legacy'` row — what the shipped functions run
--          TODAY, returned verbatim while the flag is off.
--
-- PRICES are cents per `unit`, researched 2026-09-04 as recorded in the
-- contract. Rows whose price the contract did not state are marked
-- "price estimated" in their note and are listed in HANDOFF-DB.md; nothing
-- charges off these numbers (the ledger records real spend), they only order
-- the `cheapest` policy.
--
-- DISABLED-ON-PURPOSE rows carry the reason in `note`, per the contract:
--   • every Kie row      — commercial/redistribution rights unconfirmed
--   • every Higgsfield row — enterprise / no-training terms not signed
--   • higgsfield dop/turbo — experimental, A/B only, 5s/720p ceiling

insert into public.ai_routes
  (task, position, provider, model, unit, unit_cents, capabilities,
   max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, note)
values

-- ══ photo.sky / photo.twilight / photo.lawn — prompt-edit ═══════════════════
  ('photo.sky', 1, 'gemini', 'gemini-3.1-flash-lite-image', 'image', 3.36,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', true, null, null),
  ('photo.sky', 2, 'gemini', 'gemini-3.1-flash-image', 'image', 6.7,
   '{prompt-edit,fidelity}', 60, 'free', null, 'retained_30d', true, null, null),
  ('photo.sky', 3, 'fal', 'flux-pro/kontext', 'image', 4.0,
   '{prompt-edit,fidelity}', 90, 'free', null, 'retained_30d', true, null, null),

  ('photo.twilight', 1, 'gemini', 'gemini-3.1-flash-lite-image', 'image', 3.36,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', true, null, null),
  ('photo.twilight', 2, 'gemini', 'gemini-3.1-flash-image', 'image', 6.7,
   '{prompt-edit,fidelity}', 60, 'free', null, 'retained_30d', true, null, null),
  ('photo.twilight', 3, 'fal', 'flux-pro/kontext', 'image', 4.0,
   '{prompt-edit,fidelity}', 90, 'free', null, 'retained_30d', true, null, null),

  ('photo.lawn', 1, 'gemini', 'gemini-3.1-flash-lite-image', 'image', 3.36,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', true, null, null),
  ('photo.lawn', 2, 'gemini', 'gemini-3.1-flash-image', 'image', 6.7,
   '{prompt-edit,fidelity}', 60, 'free', null, 'retained_30d', true, null, null),
  ('photo.lawn', 3, 'fal', 'flux-pro/kontext', 'image', 4.0,
   '{prompt-edit,fidelity}', 90, 'free', null, 'retained_30d', true, null, null),

-- ══ photo.declutter — needs a real MASK ═════════════════════════════════════
-- Only steps 1 and 3 advertise `mask`. The Gemini middle step is a PROMPT edit,
-- so a caller that hard-requires `mask` correctly never sees it — that is the
-- capability filter doing its job, not a gap in the seed.
  ('photo.declutter', 1, 'fal', 'flux-pro/v1/fill', 'image', 5.0,
   '{mask,prompt-edit}', 90, 'free', null, 'retained_30d', true, null,
   'true masked inpaint; fal prices per megapixel ($0.05/MP) — 5c is a ~1 MP edit, verify at full res before routing cheapest at scale'),
  ('photo.declutter', 2, 'gemini', 'gemini-3.1-flash-image', 'image', 6.7,
   '{prompt-edit,fidelity}', 60, 'free', null, 'retained_30d', true, null,
   'prompt-only declutter — no mask capability, so a mask-requiring caller skips it'),
  ('photo.declutter', 3, 'openai', 'gpt-image-2', 'image', 4.1,
   '{mask,prompt-edit,fidelity}', 120, 'free', null, 'retained_30d', true, null,
   'mask-guided edit; 4.1c is the medium-quality 1024 floor — higher quality costs more'),

-- ══ photo.stage / photo.custom — prompt-edit + fidelity ═════════════════════
  ('photo.stage', 1, 'gemini', 'gemini-3.1-flash-image', 'image', 6.7,
   '{prompt-edit,fidelity}', 60, 'free', null, 'retained_30d', true, null, null),
  ('photo.stage', 2, 'openai', 'gpt-image-2', 'image', 4.1,
   '{prompt-edit,fidelity,mask}', 120, 'free', null, 'retained_30d', true, null,
   '4.1c is the medium-quality 1024 floor — higher quality costs more'),
  ('photo.stage', 3, 'fal', 'flux-pro/kontext', 'image', 4.0,
   '{prompt-edit,fidelity}', 90, 'free', null, 'retained_30d', true, null, null),

  ('photo.custom', 1, 'gemini', 'gemini-3.1-flash-image', 'image', 6.7,
   '{prompt-edit,fidelity}', 60, 'free', null, 'retained_30d', true, null, null),
  ('photo.custom', 2, 'openai', 'gpt-image-2', 'image', 4.1,
   '{prompt-edit,fidelity,mask}', 120, 'free', null, 'retained_30d', true, null,
   '4.1c is the medium-quality 1024 floor — higher quality costs more'),
  ('photo.custom', 3, 'fal', 'flux-pro/kontext', 'image', 4.0,
   '{prompt-edit,fidelity}', 90, 'free', null, 'retained_30d', true, null, null),

-- ══ video.reel_clip — i2v, 1080p, 5s, 16:9 & 9:16 ═══════════════════════════
-- Step 2 is the SAME upstream model resold by Kie: cheaper, but a failover to
-- it buys a different queue, not a different model. Step 3 is a genuinely
-- different model and is the only availability-independent fallback — and it
-- is honest about being 768p / 6s, so a 1080p-requiring caller will not get it.
  ('video.reel_clip', 1, 'fal', 'bytedance/seedance/v1/pro/fast/image-to-video', 'second', 4.86,
   '{i2v,1080p,5s,6s,16:9,9:16}', 600, 'free', 'bytedance/seedance-1.0-pro-fast',
   'retained_30d', true, null, null),
  ('video.reel_clip', 2, 'kie', 'bytedance/v1-pro-fast-image-to-video', 'second', 3.6,
   '{i2v,1080p,5s,6s,16:9,9:16}', 600, 'free', 'bytedance/seedance-1.0-pro-fast',
   'trains_by_default', false, null,
   'DISABLED: commercial/redistribution rights unconfirmed. privacy_tier is the conservative assumption until Kie terms are read — it also keeps customer media off this step if someone enables it early.'),
  ('video.reel_clip', 3, 'fal', 'minimax/hailuo-02/standard/image-to-video', 'second', 4.5,
   '{i2v,768p,6s,16:9,9:16}', 600, 'free', null, 'retained_30d', true, null,
   'different model = the only availability-independent fallback; 768p and 6s max, so it is dropped for a caller that hard-requires 1080p'),
  ('video.reel_clip', 90, 'openai', 'sora-2', 'second', 0,
   '{i2v}', 600, 'free', null, 'retained_30d', false, date '2026-09-24',
   'RETIRED 2026-09-24 (contract §3). Tombstone: never routed, kept so the retirement is a fact in the table.'),

-- ══ video.aerial — i2v, 6-8s, 1080p, 16:9 & 9:16 ═══════════════════════════
  ('video.aerial', 1, 'fal', 'bytedance/seedance/v1/pro/fast/image-to-video', 'second', 4.86,
   '{i2v,1080p,6s,8s,16:9,9:16}', 600, 'free', 'bytedance/seedance-1.0-pro-fast',
   'retained_30d', true, null, null),
  ('video.aerial', 2, 'higgsfield', 'bytedance/seedance/v1/pro/fast/image-to-video', 'second', 4.86,
   '{i2v,1080p,6s,8s,16:9,9:16}', 600, 'free', 'bytedance/seedance-1.0-pro-fast',
   'trains_by_default', false, null,
   'DISABLED: enterprise / no-training terms not signed. Same upstream model as step 1, so it is a queue failover, not a model failover.'),
  ('video.aerial', 3, 'fal', 'veo3.1/fast/image-to-video', 'second', 10.0,
   '{i2v,1080p,6s,8s,16:9,9:16}', 900, 'free', 'google/veo-3.1-fast',
   'retained_30d', true, null,
   'different model — the availability-independent fallback, at ~2x the price'),
  ('video.aerial', 4, 'higgsfield', 'dop/turbo', 'second', 8.3,
   '{i2v,720p,5s,16:9,9:16}', 600, 'free', null, 'trains_by_default', false, null,
   'DISABLED, EXPERIMENTAL: A/B only. 5s / 720p ceiling, so a 6s-requiring caller drops it on capabilities alone. Adapter must always send enhance_prompt:false and treat nsfw as its own terminal state.'),

-- ══ video.aerial_no_photo — t2v ════════════════════════════════════════════
  ('video.aerial_no_photo', 1, 'fal', 'veo3.1/fast', 'second', 10.0,
   '{t2v,1080p,4s,6s,8s,16:9,9:16}', 900, 'free', 'google/veo-3.1-fast',
   'retained_30d', true, null, null),
  ('video.aerial_no_photo', 2, 'kie', 'veo3_fast', 'call', 4.1,
   '{t2v,1080p,8s,16:9,9:16}', 900, 'free', 'google/veo-3.1-fast',
   'trains_by_default', false, null,
   'DISABLED: price unverified AND commercial rights unconfirmed. Legacy /api/v1/veo/generate code path, priced per CLIP not per second.'),

-- ══ video.upscale_4k — v2v ═════════════════════════════════════════════════
  ('video.upscale_4k', 1, 'kie', 'topaz/video-upscale', 'second', 4.0,
   '{v2v,4k,2x}', 1800, 'free', 'topaz/video-ai', 'trains_by_default', false, null,
   'DISABLED: rights unconfirmed. 2x only and the input must be <= 50 MB, which is a hard ceiling the adapter has to pre-check.'),
  ('video.upscale_4k', 2, 'fal', 'topaz/upscale/video', 'second', 8.0,
   '{v2v,4k,2x,4x,60fps}', 1800, 'free', 'topaz/video-ai', 'retained_30d', true, null, null),

-- ══ video.upscale_1080p60 — v2v ════════════════════════════════════════════
  ('video.upscale_1080p60', 1, 'fal', 'topaz/upscale/video', 'second', 4.0,
   '{v2v,1080p,60fps,2x}', 1800, 'free', 'topaz/video-ai', 'retained_30d', true, null,
   'contract quotes 2-4c/s; 4.0 is the 1080p60 number the repo already bills (ledger.ts APP_AI_UNIT_CENTS.topaz_1080p60_per_s)'),

-- ══ tts.captioned — per-character alignment, single vendor ═════════════════
  ('tts.captioned', 1, 'elevenlabs', 'with-timestamps', '1k_chars', 22.0,
   '{tts,timestamps,char_alignment}', 120, 'free', null, 'retained_30d', true, null,
   'ONLY vendor with per-character alignment — no fallback exists, so a caller must surface the outage rather than silently degrade. price estimated (Creator-tier credit rate); confirm against the live plan.'),

-- ══ tts.plain ══════════════════════════════════════════════════════════════
  ('tts.plain', 1, 'openai', 'tts-1', '1k_chars', 1.5,
   '{tts}', 120, 'free', null, 'retained_30d', true, null, null),
  ('tts.plain', 2, 'elevenlabs', 'with-timestamps', '1k_chars', 22.0,
   '{tts,timestamps,char_alignment}', 120, 'free', null, 'retained_30d', true, null,
   'price estimated (Creator-tier credit rate)'),

-- ══ stt.captions — word timestamps ═════════════════════════════════════════
-- Apple's on-device recogniser is free AND no_retention (nothing leaves the
-- phone), so it is first on both the `best` and `cheapest` policies.
  ('stt.captions', 1, 'apple', 'on-device-speech', 'minute', 0,
   '{stt,word_timestamps,on_device}', 120, 'free', null, 'no_retention', true, null,
   'runs on the device; nothing is uploaded, nothing is billed'),
  ('stt.captions', 2, 'openai', 'whisper-1', 'minute', 0.6,
   '{stt,word_timestamps}', 300, 'free', null, 'retained_30d', true, date '2027-02-26',
   'sunsets 2027-02-26 — resolveRoute() stops choosing it that day on its own; needs timestamp_granularities[]=word'),

-- ══ stt.plain ══════════════════════════════════════════════════════════════
  ('stt.plain', 1, 'apple', 'on-device-speech', 'minute', 0,
   '{stt,on_device}', 120, 'free', null, 'no_retention', true, null,
   'runs on the device; nothing is uploaded, nothing is billed'),
  ('stt.plain', 2, 'openai', 'gpt-transcribe', 'minute', 0.45,
   '{stt}', 300, 'free', null, 'retained_30d', true, null, null),

-- ══ text.listing_copy — vision + fair-housing-compliant copy ═══════════════
  ('text.listing_copy', 1, 'anthropic', 'claude-sonnet-5', 'call', 2.1,
   '{text,vision,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'always send output_config.effort:"low"; never a Covered Model'),
  ('text.listing_copy', 2, 'openai', 'gpt-5.6-terra', 'call', 2.0,
   '{text,vision,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'always send reasoning.effort:"none"'),
  ('text.listing_copy', 3, 'gemini', 'gemini-3.8-flash', 'call', 0.9,
   '{text,vision,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'price estimated (flash tier) — the contract states no number; confirm before this becomes the cheapest-policy default'),

-- ══ judge.fair_housing — NOT a failover chain ══════════════════════════════
-- The regex is unbypassable and ALWAYS runs first (it is our own code, offline,
-- free). Steps 2 and 3 are an OR, not a fallback: the caller flags the copy if
-- EITHER model flags it. resolveRoute() still returns them in order; the caller
-- decides to fan out rather than fail over.
  ('judge.fair_housing', 1, 'rendprop', 'fairhousing-regex', 'call', 0,
   '{classifier,deterministic,offline}', 1, 'free', null, 'no_retention', true, null,
   'our own code (_shared/fairhousing.ts). Runs BEFORE resolveRoute on every free-text task and cannot be bypassed.'),
  ('judge.fair_housing', 2, 'anthropic', 'claude-haiku-4-5', 'call', 0.045,
   '{classifier,text}', 30, 'free', null, 'retained_30d', true, null,
   'OR with step 3, not a failover: flag if EITHER flags. watch >= 2026-10-15 for a successor — claude-sonnet-5 effort:low is already seeded on judge.qc_drift.'),
  ('judge.fair_housing', 3, 'openai', 'gpt-5.6-luna', 'call', 0.01,
   '{classifier,text}', 30, 'free', null, 'retained_30d', true, null,
   'OR with step 2, not a failover: flag if EITHER flags'),

-- ══ judge.qc_drift — 4-image verdict ═══════════════════════════════════════
  ('judge.qc_drift', 1, 'anthropic', 'claude-haiku-4-5', 'call', 0.66,
   '{classifier,vision,multi_image}', 60, 'free', null, 'retained_30d', true, null,
   'watch >= 2026-10-15 for a successor; the escalation row below is that successor'),
  ('judge.qc_drift', 2, 'anthropic', 'claude-sonnet-5', 'call', 1.3,
   '{classifier,vision,multi_image}', 60, 'free', null, 'retained_30d', true, null,
   'escalation, and the standing successor to claude-haiku-4-5. always output_config.effort:"low"'),
  ('judge.qc_drift', 3, 'openai', 'gpt-5.6-luna', 'call', 0.12,
   '{classifier,vision,multi_image}', 60, 'free', null, 'retained_30d', true, null,
   'A/B candidate, and a genuinely independent third opinion if both Anthropic steps are down'),

-- ══ video.chapters — video understanding ═══════════════════════════════════
  ('video.chapters', 1, 'gemini', 'gemini-3.6-flash', 'call', 1.4,
   '{video_understanding,timestamps}', 300, 'free', null, 'retained_30d', true, null,
   'low-res, 1 fps; ~1.4c per 2-minute tour — unit is per CALL, not per minute'),
  ('video.chapters', 2, 'gemini', 'gemini-3.1-flash-lite', 'call', 0.6,
   '{video_understanding,timestamps}', 300, 'free', null, 'retained_30d', true, null,
   '~0.6c per 2-minute tour — unit is per CALL, not per minute'),

-- ══ vision.room_label — one frame ══════════════════════════════════════════
  ('vision.room_label', 1, 'openai', 'gpt-5.6-luna', 'image', 0.012,
   '{vision,single_frame}', 30, 'free', null, 'retained_30d', true, null, 'send detail:low'),
  ('vision.room_label', 2, 'anthropic', 'claude-haiku-4-5', 'image', 0.06,
   '{vision,single_frame}', 30, 'free', null, 'retained_30d', true, null, null),

-- ══ 3d.world ═══════════════════════════════════════════════════════════════
  ('3d.world', 1, 'worldlabs', 'marble-1.1', 'world', 120.0,
   '{3d,world,image_to_world}', 1800, 'pro', null, 'retained_30d', true, null,
   'THE only min_plan above free in this seed: $1.20 a world is a COGS hole on an unpaid tier. No adapter exists yet, and WorldLabs retention/training terms are UNVERIFIED — confirm them before this carries customer media.'),

-- ══ floorplan ══════════════════════════════════════════════════════════════
  ('floorplan', 1, 'apple', 'roomplan', 'call', 0,
   '{floorplan,on_device,lidar}', 300, 'free', null, 'no_retention', true, null,
   'runs on the device; nothing is uploaded, nothing is billed'),

-- ══ RETIREMENT TOMBSTONES (enabled = false + retire_after) ═════════════════
-- Not part of any chain. They sit next to the successor that replaced them so
-- the lineage is visible in the table, and they make the retirement a row
-- rather than a sentence in a document.
  ('photo.stage', 90, 'gemini', 'gemini-2.5-flash-image', 'image', 3.9,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', false, date '2026-10-02',
   'RETIRED 2026-10-02. Superseded by gemini-3.1-flash-image (step 1). This model is still what the LEGACY rows run while the router flag is off — see the note on those rows.'),
  ('photo.stage', 91, 'openai', 'gpt-image-1', 'image', 4.1,
   '{prompt-edit,mask}', 120, 'free', null, 'retained_30d', false, date '2026-10-23',
   'RETIRED 2026-10-23. Superseded by gpt-image-2 (step 2).'),

-- ══ LEGACY: what the SHIPPED functions run TODAY (flag OFF) ════════════════
-- `note = 'legacy'` exactly — router.ts looks these up by string equality, so
-- nothing else may ever use that value. They are enabled = false so they can
-- never be picked by a flag-ON chain, and retire_after is NULL because they
-- describe today's deployed behaviour, not a routing choice.
--
--   photo.*             functions/ai-photo/index.ts  MODEL default
--                       ("gemini-2.5-flash-image"), 3.9c/image
--                       (_shared/ledger.ts APP_AI_UNIT_CENTS.gemini_image)
--   video.reel_clip     functions/ai-video/index.ts  MODEL_I2V, 4.8c/s
--   video.aerial        functions/ai-video/index.ts  MODEL_I2V (grounded), 4.8c/s
--   video.aerial_no_photo  MODEL_AERIAL_T2V, billed FLAT per clip (80c)
--   video.upscale_*     MODEL_DRONE, 8.0c/s (4k30) and 4.0c/s (1080p60)
--   tts.*               functions/ai-voice/index.ts  /with-timestamps
--
-- NOT covered, deliberately: ai-video's `bria/video/erase/prompt` declutter
-- path. §3 defines no video-declutter task and the repo has NO committed price
-- for Bria (admin/index.ts lists unit_cost_cents: null and /ai-video writes no
-- ledger row for it), so inventing a route row would invent a price. That path
-- must keep its hardcoded model until a price lands. Recorded in HANDOFF-DB.md.
  ('photo.sky', 99, 'gemini', 'gemini-2.5-flash-image', 'image', 3.9,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', false, null, 'legacy'),
  ('photo.twilight', 99, 'gemini', 'gemini-2.5-flash-image', 'image', 3.9,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', false, null, 'legacy'),
  ('photo.lawn', 99, 'gemini', 'gemini-2.5-flash-image', 'image', 3.9,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', false, null, 'legacy'),
  ('photo.declutter', 99, 'gemini', 'gemini-2.5-flash-image', 'image', 3.9,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', false, null, 'legacy'),
  ('photo.stage', 99, 'gemini', 'gemini-2.5-flash-image', 'image', 3.9,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', false, null, 'legacy'),
  ('photo.custom', 99, 'gemini', 'gemini-2.5-flash-image', 'image', 3.9,
   '{prompt-edit}', 60, 'free', null, 'retained_30d', false, null, 'legacy'),
  ('video.reel_clip', 99, 'fal', 'fal-ai/bytedance/seedance/v1/pro/fast/image-to-video', 'second', 4.8,
   '{i2v,1080p,5s,16:9,9:16}', 600, 'free', 'bytedance/seedance-1.0-pro-fast',
   'retained_30d', false, null, 'legacy'),
  ('video.aerial', 99, 'fal', 'fal-ai/bytedance/seedance/v1/pro/fast/image-to-video', 'second', 4.8,
   '{i2v,1080p,6s,8s,16:9,9:16}', 600, 'free', 'bytedance/seedance-1.0-pro-fast',
   'retained_30d', false, null, 'legacy'),
  ('video.aerial_no_photo', 99, 'fal', 'fal-ai/veo3.1/fast', 'call', 80.0,
   '{t2v,1080p,4s,6s,8s,16:9,9:16}', 900, 'free', 'google/veo-3.1-fast',
   'retained_30d', false, null, 'legacy'),
  ('video.upscale_4k', 99, 'fal', 'fal-ai/topaz/upscale/video', 'second', 8.0,
   '{v2v,4k,2x,4x,60fps}', 1800, 'free', 'topaz/video-ai', 'retained_30d', false, null, 'legacy'),
  ('video.upscale_1080p60', 99, 'fal', 'fal-ai/topaz/upscale/video', 'second', 4.0,
   '{v2v,1080p,60fps,2x}', 1800, 'free', 'topaz/video-ai', 'retained_30d', false, null, 'legacy'),
  ('tts.captioned', 99, 'elevenlabs', 'with-timestamps', '1k_chars', 22.0,
   '{tts,timestamps,char_alignment}', 120, 'free', null, 'retained_30d', false, null, 'legacy'),
  ('tts.plain', 99, 'elevenlabs', 'with-timestamps', '1k_chars', 22.0,
   '{tts,timestamps,char_alignment}', 120, 'free', null, 'retained_30d', false, null, 'legacy')

on conflict (task, position) do nothing;

-- ── 6. report_provider_outcome() — the only writer of provider_health ───────
--
-- SECURITY DEFINER with `set search_path = public`, the convention every definer
-- in this repo follows (is_admin 0017, org_role 0006, effective_plan/log_job_cost
-- 0010, create_render_job/publish_render 0011). service_role EXECUTE only: the
-- circuit breaker is written from the edge functions with the service-role
-- client, never by a client, or a tenant could open a competitor's circuit.
--
-- CIRCUIT RULE (contract): 3 consecutive failures opens it for 10 minutes, and
-- a rate_limit opens it IMMEDIATELY — being throttled is not something more
-- attempts fix, and the retry storm is what keeps you throttled.
--
-- LATENCY: an asymmetric EWMA, not a real p95 (see the column comment). It
-- rises fast (alpha 0.3) and decays slowly (alpha 0.05) so a genuine slowdown
-- shows up within a few calls while one fast response cannot erase it. Latency
-- is only folded in when the caller measured something (> 0).

create or replace function public.report_provider_outcome(
  p_provider    text,
  p_model       text,
  p_ok          boolean,
  p_latency_ms  integer default null,
  p_error_class text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider text := btrim(coalesce(p_provider, ''));
  v_model    text := btrim(coalesce(p_model, ''));
  v_ok       boolean := coalesce(p_ok, false);
  v_lat      integer := case when coalesce(p_latency_ms, 0) > 0 then p_latency_ms else null end;
  v_class    text := nullif(btrim(coalesce(p_error_class, '')), '');
  v_prev     integer;
  v_fails    integer;
begin
  -- A blank provider/model would create a junk primary key that no route ever
  -- matches, silently disabling the breaker for the step that actually failed.
  if v_provider = '' or v_model = '' then
    return;
  end if;

  insert into provider_health (provider, model) values (v_provider, v_model)
  on conflict (provider, model) do nothing;

  select consecutive_failures, p95_latency_ms
    into v_fails, v_prev
    from provider_health
   where provider = v_provider and model = v_model
   for update;

  if v_ok then
    update provider_health
       set consecutive_failures = 0,
           open_until           = null,   -- a success CLOSES the circuit immediately
           last_ok_at           = now(),
           p95_latency_ms       = case
                                    when v_lat is null then p95_latency_ms
                                    when v_prev is null then v_lat
                                    when v_lat > v_prev then round(v_prev * 0.7 + v_lat * 0.3)::integer
                                    else round(v_prev * 0.95 + v_lat * 0.05)::integer
                                  end
     where provider = v_provider and model = v_model;
  else
    v_fails := coalesce(v_fails, 0) + 1;
    update provider_health
       set consecutive_failures = v_fails,
           last_fail_at         = now(),
           last_error_class     = v_class,
           open_until           = case
                                    when v_class = 'rate_limit' or v_fails >= 3
                                      then now() + interval '10 minutes'
                                    else open_until
                                  end,
           p95_latency_ms       = case
                                    when v_lat is null then p95_latency_ms
                                    when v_prev is null then v_lat
                                    when v_lat > v_prev then round(v_prev * 0.7 + v_lat * 0.3)::integer
                                    else round(v_prev * 0.95 + v_lat * 0.05)::integer
                                  end
     where provider = v_provider and model = v_model;
  end if;
end;
$$;

revoke execute on function public.report_provider_outcome(text, text, boolean, integer, text)
  from public, anon, authenticated;
grant execute on function public.report_provider_outcome(text, text, boolean, integer, text)
  to service_role;

comment on function public.report_provider_outcome(text, text, boolean, integer, text) is
  'Records ONE provider attempt into provider_health. 3 consecutive failures — '
  'or any rate_limit — opens the circuit for 10 minutes; a success closes it and '
  'resets the counter. p95_latency_ms is an asymmetric EWMA, not a true p95. '
  'service_role only.';

-- ── 7. RLS + grants ─────────────────────────────────────────────────────────
--
-- ci-bootstrap.sql mirrors Supabase's default privileges (ALL on every new
-- table to anon/authenticated/service_role), so every REVOKE below is
-- load-bearing, not decoration.
--
-- ai_routes / plan_routing_policy — READ-ONLY and NON-SECRET.
--   Model ids and list prices are not credentials, and the app has a legitimate
--   reason to know which model produced a result. `authenticated` therefore gets
--   SELECT with a `using (true)` policy, exactly like plan_entitlements (0010
--   §2). Writes stay service-role.
--
--   The admin-read policies on these two are REDUNDANT today (the tenant policy
--   already returns every row) and are added deliberately rather than by
--   accident: they are what keeps the admin console working if the tenant read
--   is ever narrowed. 0017 declined to add one to plan_entitlements for the
--   same reason it is defensible here — that table is world-readable by design
--   and will stay that way; these two are operational and may not.
--
-- provider_health / app_config — ADMIN-ONLY.
--   An outage map and an operational flag are not tenant business. The pattern
--   is 0017 §7's rate_limits, verbatim: an RLS policy only takes effect for a
--   role that also holds the table grant, so SELECT is granted to
--   `authenticated` and the ONLY policy restricts it to is_admin(). Net effect
--   for a non-admin: ZERO ROWS. INSERT/UPDATE/DELETE stay revoked, so the
--   service role (and report_provider_outcome, a definer) are the only writers.

alter table public.ai_routes            enable row level security;
alter table public.plan_routing_policy  enable row level security;
alter table public.provider_health      enable row level security;
alter table public.app_config           enable row level security;

grant select on public.ai_routes           to authenticated;
grant select on public.plan_routing_policy to authenticated;
grant select on public.provider_health     to authenticated;
grant select on public.app_config          to authenticated;

revoke insert, update, delete on public.ai_routes           from authenticated, anon;
revoke insert, update, delete on public.plan_routing_policy from authenticated, anon;
revoke insert, update, delete on public.provider_health     from authenticated, anon;
revoke insert, update, delete on public.app_config          from authenticated, anon;

revoke all on public.ai_routes           from anon;
revoke all on public.plan_routing_policy from anon;
revoke all on public.provider_health     from anon;
revoke all on public.app_config          from anon;

drop policy if exists "routes readable" on public.ai_routes;
create policy "routes readable" on public.ai_routes
  for select to authenticated using (true);

drop policy if exists "admin routes read" on public.ai_routes;
create policy "admin routes read" on public.ai_routes
  for select using (public.is_admin());

drop policy if exists "routing policy readable" on public.plan_routing_policy;
create policy "routing policy readable" on public.plan_routing_policy
  for select to authenticated using (true);

drop policy if exists "admin routing policy read" on public.plan_routing_policy;
create policy "admin routing policy read" on public.plan_routing_policy
  for select using (public.is_admin());

drop policy if exists "admin provider health read" on public.provider_health;
create policy "admin provider health read" on public.provider_health
  for select using (public.is_admin());

drop policy if exists "admin app config read" on public.app_config;
create policy "admin app config read" on public.app_config
  for select using (public.is_admin());
