-- 0030: ai_routes.params — THE REQUEST SHAPE BECOMES A ROW, AND gpt-6-astra
-- TAKES THE FIRST SEAT ON THE TWO WRITING ROUTES (2026-09-07).
--
-- Two things, and the first is why the second is possible.
--
--   1. `ai_routes.params jsonb` — the per-step vendor knobs the adapters used
--      to hardcode. Defaults to NULL, and NULL means "exactly what this adapter
--      did yesterday", so every one of the ~70 existing rows is untouched.
--   2. openai `gpt-6-astra` at position 1 of `copy.shotlist` and
--      `copy.reel_script`, with the params that make it work.
--
-- ── WHY THE COLUMN HAD TO COME FIRST ────────────────────────────────────────
--
-- 0018's promise is that a model change is a ROW EDIT and not a deploy. That
-- promise was not quite true, and this is the row that proved it:
--
--   _shared/providers/openai.ts sent `reasoning: { effort: "none" }` on EVERY
--   chat call and defaulted the answer to 300 output tokens. The comment above
--   it was honest about why — "the router only ever sends this model one-shot
--   classifier work" — and it was correct when it was written.
--
--   _shared/providers/anthropic.ts did the same thing one layer up: it decided
--   `output_config.effort:"low"` from a REGEX ON THE MODEL NAME (/sonnet-5/i),
--   and capped answers at 400 tokens.
--
-- Both are right for a bounded verdict and wrong for a reasoning model. Astra
-- is sold for hard end-to-end work; called with reasoning off it either refuses
-- the request outright or charges a premium price for a deliberately crippled
-- answer, and a 300-token ceiling truncates a shot list that needs ~1,600. So
-- seeding Astra without this column would have been seeding a row that could
-- not work — a deploy disguised as a migration.
--
-- `params` moves those constants into the row that knows which model it is. The
-- adapters read a WHITELIST of keys (`effort`, `max_output_tokens`) and treat
-- anything else — an unknown key, a misspelling, a value the vendor does not
-- accept — as absent, i.e. as today's behaviour. See
-- services/supabase/functions/_shared/providers/params.ts for the rules and for
-- why the token ceiling is additionally clamped in code: this column is
-- operator-supplied config that reaches a vendor's metered API.
--
-- ── WHY ASTRA GOES HERE AND NOWHERE ELSE ────────────────────────────────────
--
-- ── min_plan = 'starter', NOT 'free' — READ THIS BEFORE CHANGING IT ─────────
--
-- Every sibling row on these two tasks is min_plan 'free', and copying that
-- would have been the consistent-looking choice. It is the wrong one here, for
-- a reason that is not obvious from this file:
--
--   router.ts's defaultPolicyFor() IS DEAD CODE. plan_routing_policy is read,
--   cached, and never applied — resolveRoute never calls it — so every chain
--   sorts "best" regardless of plan. The cheapest-policy protection that free
--   and trial tiers are supposed to get does not exist today.
--
-- min_plan itself IS still enforced (router.ts ~358, `planRank(s.min_plan) >
-- rank` drops the step), so it is the only working lever. Without it, a free
-- signup reaches a 10c model on a route that has NO per-call quota and no
-- request-time spend ceiling — only a 60-per-5-minutes burst key, i.e. up to
-- $6.00 per five minutes per org, on an account paying nothing, right as the
-- product starts buying traffic.
--
-- 'starter' is the lowest plan Rendprop actually sells ($49/mo), so this reads
-- as: everyone who pays gets the best writer, everyone else gets Sonnet at 2.1c
-- — which is exactly today's behaviour, so free and trial see NO regression.
-- To open it to everyone, set min_plan = 'free' on these two rows from the
-- admin console. To restrict it further, 'pro' or 'team'.
--
-- Verified against OpenAI's own model documentation, 2026-09-07:
--
--   model id        gpt-6-astra
--   price           $10.00 / 1M input tokens · $50.00 / 1M output tokens
--   context         1,050,000 tokens        max output   128,000 tokens
--   knowledge cut   30 Apr 2026
--   modalities      TEXT + IMAGE in · TEXT ONLY out
--
-- TEXT ONLY OUT is the whole placement argument. Astra cannot generate a video
-- and it cannot return an edited image, so it is irrelevant to every route in
-- this table that costs real money — `photo.*`, `video.*`, `3d.world`. It can
-- only help where the product is words, and the two places where words are the
-- deliverable and quality is visible to the customer are the reel script and
-- the shot list. That is where it is seeded, and nowhere else.
--
-- ── WHAT THIS DELIBERATELY LEAVES ALONE, AND WHY ────────────────────────────
--
-- `judge.*` — NOT ASTRA, AT ANY POSITION. The fair-housing gate and the QC
-- drift check run on EVERY SINGLE GENERATION; being cheap enough to always run
-- is not a nice property of the judge, it IS the judge. The arithmetic, at
-- Astra's published rates:
--
--   judge.qc_drift   4 images + rubric ≈ 3,500 in, ≈ 200 out
--                    3500/1e6 × $10 + 200/1e6 × $50 = 3.5c + 1.0c = ~4.5c
--                    against claude-haiku-4-5 at 0.66c  →  a 7x tax
--   judge.fair_housing   ≈ 500 in, ≈ 200 out
--                    0.5c + 1.0c = ~1.5c against haiku at 0.045c  →  33x
--
-- A 7x tax on the thing whose entire job is to be cheap enough to always run is
-- how a compliance check quietly becomes optional. Not seeded.
--
-- `copy.photo_prompt` — NOT ASTRA either, and this one is not about price. It
-- is the smallest of the three copy routes: a rough sentence in, a single
-- ≤400-CHARACTER instruction out (MAX_PROMPT_OUTPUT in ai-copy/prompt.ts).
-- Measured, that is ~390 tokens in and ~300 out once reasoning is counted:
--   390/1e6 × $10 + 300/1e6 × $50 = 0.4c + 1.5c ≈ 1.9c
-- against claude-sonnet-5 at 2.1c — a WASH, so cost is not the argument. The
-- argument is that the answer is one bounded sentence with no structure to
-- plan and no ordering to get right. There is nothing here for a reasoning
-- model to be better AT, so the upside is unmeasurable and the change would be
-- churn on a route that already works.
--
-- NO ai_routes SCHEMA CHANGE BEYOND THE ONE COLUMN, and no new task, no
-- plan_entitlements change, no plan_routing_policy row: 0018 already seeded a
-- policy for all six plans and this introduces no new tier. `min_plan` stays
-- `free` on both new rows — it controls ROUTING only, never access, exactly as
-- 0027 and 0028 wrote it.
--
-- NO `note = 'legacy'` ROW. Same argument as 0027, 0028 and 0023: a legacy row
-- carries the provider/model a SHIPPED edge function hardcodes TODAY, and these
-- tasks have never had one. With the master flag OFF — still the default —
-- resolveRoute() returns [] for both tasks and ai-copy/index.ts's own two-step
-- in-code chain (anthropic → openai gpt-5.6-terra) runs, UNCHANGED. Nothing
-- below reaches a customer until somebody turns the router on.
--
-- PRIVACY. `retained_30d`, the same honest tier the sibling openai row carries.
-- `carries_customer_media` is never set for these tasks: no photo, no video and
-- no audio reaches a provider — only ids, room labels and typed facts — and the
-- STREET ADDRESS IS NEVER SENT (there is no address field in either request
-- body; the model writes the literal token `{address}` and the app substitutes
-- it on the device). Astra's image-input modality is therefore unused here.
--
-- Idempotent throughout: `add column if not exists`, a guarded position shift
-- that cannot run twice, and `on conflict (task, position) do nothing` on the
-- seed — so the replay CI performs on every migration from 0009 onward is a
-- no-op, and an operator who has since edited these rows keeps their edit.

-- ── 1. The column ───────────────────────────────────────────────────────────

alter table public.ai_routes
  add column if not exists params jsonb;

comment on column public.ai_routes.params is
  'Per-step vendor knobs for THIS row, or NULL for "whatever the adapter does by default" (the case for almost every row, which is what makes the column additive). Read by services/supabase/functions/_shared/providers/*.ts, which WHITELIST the keys — an unknown key, or a value the vendor does not accept, is treated as absent rather than forwarded. Recognised today: `effort` (openai: none|minimal|low|medium|high, default none; anthropic output_config.effort: low|medium|high, default = the model-name rule) and `max_output_tokens` (a positive integer, additionally clamped in code — see params.ts MAX_PARAM_OUTPUT_TOKENS). This is operator-supplied config that reaches a metered third-party API: it is not a passthrough and must never be treated as one.';

-- A params blob is an OBJECT. jsonb will happily store `[]`, `"low"` or `3`,
-- and every adapter reads those as "no params" — but a row that means nothing
-- is a row somebody will spend an afternoon on, so the database refuses it
-- outright. Guarded so a replay does not try to add the constraint twice.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.ai_routes'::regclass and conname = 'ai_routes_params_object_check'
  ) then
    alter table public.ai_routes add constraint ai_routes_params_object_check
      check (params is null or jsonb_typeof(params) = 'object');
  end if;
end $$;

-- ── 2. The position shift ───────────────────────────────────────────────────
--
-- Astra goes in at position 1, so the three rows 0027 and 0028 seeded
-- (1 = anthropic claude-sonnet-5, 2 = openai gpt-5.6-terra, 3 = gemini
-- gemini-3.8-flash) become 2, 3 and 4. `on conflict (task, position) do
-- nothing` does NOT reorder anything for you — it would simply decline to
-- insert Astra and leave the chain exactly as it was, silently — so the shift
-- is written out, and it has to survive being run twice.
--
-- TWO THINGS MAKE IT SAFE TO REPLAY:
--
--   THE GUARD. The whole block runs only while no astra row exists for the
--   task. Once it does, a replay finds it and does nothing at all, so positions
--   cannot walk 1→2→3 across repeated applications. (If an operator later
--   DELETES the astra row, a replay would legitimately re-do the shift — but a
--   deleted row means the shift has been undone too, and re-doing both is the
--   correct answer, not a bug. Disabling the row, which is what the admin
--   console does, changes nothing here.)
--
--   THE TWO PASSES. `uq_ai_routes_task_position` is a plain UNIQUE INDEX and so
--   can never be deferred; a single `set position = position + 1` would hit a
--   duplicate the moment the row at 1 moved onto the still-live row at 2, and
--   an UPDATE has no guaranteed row order to save it. So the live rows go OUT
--   to a band nothing else uses (+1000) and come back DOWN one place lower.
--   Both statements are collision-free at every intermediate state, and both
--   run inside this migration's single transaction, so no reader ever observes
--   the parked positions.
--
-- ONLY THE LIVE CHAIN MOVES. 0018's position convention is 1..9 live,
-- 90..98 retirement tombstones, 99 the legacy row. Neither task has a tombstone
-- or a legacy row today, but the filter respects the convention anyway so a
-- future tombstone is not silently shuffled into the chain.

do $$
declare
  v_task text;
begin
  foreach v_task in array array['copy.shotlist', 'copy.reel_script'] loop
    if not exists (
      select 1 from public.ai_routes
       where task = v_task and provider = 'openai' and model = 'gpt-6-astra'
    ) then
      -- Pass 1: park the live chain out of the way (1..9 → 1001..1009).
      update public.ai_routes
         set position = position + 1000, updated_at = now()
       where task = v_task and position between 1 and 9;

      -- Pass 2: bring it back one place lower (1001..1009 → 2..10).
      update public.ai_routes
         set position = position - 999, updated_at = now()
       where task = v_task and position >= 1000;
    end if;
  end loop;
end $$;

-- ── 3. The seed ─────────────────────────────────────────────────────────────
--
-- PRICE. `unit = 'call'`, so unit_cents has to be computed from the token shape
-- this route actually sends. Measured against the real prompt builders in
-- services/supabase/functions/ai-copy/ (shotlist.ts, prompt.ts) at their
-- ceilings, not guessed:
--
--   copy.shotlist   instruction + turn at MAX_SHOTS(20) ≈ 7,700 chars ≈ 2,000
--                   tokens in. Answer capped at MAX_SHOTLIST_TOKENS = 1,600.
--                     2000/1e6 × $10  = $0.020 = 2.0c   input
--                     1600/1e6 × $50  = $0.080 = 8.0c   output
--                                                ------
--                                                10.0c  per call
--
--   copy.reel_script  instruction + turn ≈ 2,965 chars ≈ 800 tokens in. Answer
--                   capped at MAX_TOKENS = 700 VISIBLE tokens — but a reasoning
--                   model bills its reasoning tokens at the OUTPUT rate, out of
--                   the same budget, so the honest modelled answer is ~950:
--                      800/1e6 × $10  = $0.008 = 0.8c   input
--                      950/1e6 × $50  = $0.0475 = 4.75c output
--                                                ------
--                                                ~5.5c  per call
--
--   Against the anthropic claude-sonnet-5 row each displaces (2.1c): 4.8x for
--   the shot list, 2.6x for the script. Stated plainly rather than rounded into
--   a comfortable range — the shot list is the expensive one, and it is the one
--   whose answer is a twenty-shot structured plan rather than a paragraph.
--
-- ⚠ THESE ARE MODELLED PRICES, NOT MEASUREMENTS — the same caveat 0028 wrote on
-- the rows it inherited, and it applies harder here because reasoning tokens
-- are billed as output and are not visible in the answer. The `max_output_tokens`
-- params below are the real ceilings, so the WORST CASE per call is:
--   shotlist  2.0c + 2400/1e6 × $50 = 2.0c + 12.0c = 14.0c
--   script    0.8c +  1200/1e6 × $50 = 0.8c +  6.0c =  6.8c
-- Confirm both against the first real OpenAI invoice before either number is
-- used to set a COGS ceiling.
--
-- PARAMS, and why these values:
--
--   effort: "low"   NOT "none" (which is the bug this migration exists to fix)
--                   and not "medium". Both tasks are bounded writing against a
--                   fixed JSON schema, not open-ended research; "low" is the
--                   cheapest setting that still has the model think at all,
--                   which is the entire reason to pay for it. Raising it to
--                   "medium" is now a ROW EDIT — that is the point.
--
--   max_output_tokens   HIGHER than the caller's own cap, deliberately. ai-copy
--                   asks for 1,600 (shot list) and 700 (script) of VISIBLE
--                   answer; on a reasoning model the reasoning tokens come out
--                   of the same max_output_tokens budget, so leaving the
--                   caller's number in place would truncate the answer we are
--                   paying extra for. 2,400 = 1,600 + 800 of thinking room;
--                   1,200 = 700 + 500. Both are far below the code clamp
--                   (MAX_PARAM_OUTPUT_TOKENS = 8,000).
--
-- max_latency_s is 120, not the siblings' 60: a reasoning model producing a
-- twenty-shot plan is slower than a one-shot completion, and this column is the
-- p95 an operator judges the step against. NOTE FOR WHOEVER TURNS THE FLAG ON:
-- the adapter's OWN hard timeout is BUDGETS.submitMs = 30s
-- (_shared/providers/common.ts) and is NOT read from this column. If Astra
-- routinely takes longer than 30s the chain will fail over to Sonnet — a
-- correct, invisible degradation, but one that pays for a discarded Astra call
-- first. Watch p95 on provider_health before deciding it is settled.
--
-- CAPABILITIES ARE `{text,compliant}`, matching the siblings exactly. ai-copy
-- passes `needs: ["text","compliant"]` and the filter is a hard AND, so a row
-- missing either is silently unreachable. `compliant` is not decorative here:
-- the narration and every burned-in caption are published advertising and are
-- re-checked against _shared/fairhousing.ts before the response is built.
--
-- `same_model_as` is NULL: Astra is a different upstream model from
-- gpt-5.6-terra, not the same one bought elsewhere, so a failover between them
-- buys a genuinely different model — which is the whole reason position 2 is
-- worth keeping.

insert into public.ai_routes
  (task, position, provider, model, unit, unit_cents, capabilities,
   max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, note, params)
values
  -- ══ copy.shotlist — the whole reel, planned as one decision ══════════════
  ('copy.shotlist', 1, 'openai', 'gpt-6-astra', 'call', 10.0,
   '{text,compliant}', 120, 'starter', null, 'retained_30d', true, null,
   'reasoning model, first seat. PRICE IS MODELLED, NOT BILLED: ~2,000 tokens in x $10/1M + '
   '~1,600 out x $50/1M = 10.0c; the 2,400-token ceiling in params puts the worst case at 14.0c. '
   '4.8x the claude-sonnet-5 row it displaces (now position 2), which is also its failover. '
   'params.effort:"low" is load-bearing — the adapter default is "none", which this model either '
   'refuses or answers badly at a premium price (see 0030 header). Confirm against real invoices '
   'before this number sets a COGS ceiling.',
   '{"effort": "low", "max_output_tokens": 2400}'::jsonb),

  -- ══ copy.reel_script — the reel voiceover script ═════════════════════════
  ('copy.reel_script', 1, 'openai', 'gpt-6-astra', 'call', 5.5,
   '{text,compliant}', 120, 'starter', null, 'retained_30d', true, null,
   'same model and the same reasoning as copy.shotlist position 1, on a shorter answer. '
   'PRICE IS MODELLED: ~800 tokens in x $10/1M + ~950 out (700 visible + reasoning, billed as '
   'output) x $50/1M = ~5.5c; the 1,200-token ceiling puts the worst case at 6.8c. 2.6x the '
   'claude-sonnet-5 row it displaces (now position 2), which is also its failover. '
   'params.effort:"low" is load-bearing — see the copy.shotlist row and the 0030 header.',
   '{"effort": "low", "max_output_tokens": 1200}'::jsonb)
on conflict (task, position) do nothing;
