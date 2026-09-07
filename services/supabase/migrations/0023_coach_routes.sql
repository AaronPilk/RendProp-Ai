-- 0023: coach.chat route — Rendprop's in-app COACH (2026-09-07).
--
-- The coach (services/supabase/functions/coach/) is a chat assistant that (a)
-- walks a user through their first project one step at a time and (b) answers
-- customer-service questions from a fixed knowledge base. It is a NEW task —
-- unlike ai-chapters/ai-photo it has no prior hardcoded behaviour to preserve,
-- so this migration seeds ONLY the live chain and adds no `note = 'legacy'`
-- row: with the router flag off (today's default), `resolveRoute('coach.chat', …)`
-- finds no legacy row and returns `[]`.
--
-- coach/index.ts does NOT use the shared `_shared/providers/chain.ts`
-- `resolveChain()` helper for this (that helper takes a SINGLE `fallback:
-- RouteStep` and falls back to `[fallback]` — the one-provider-fallback
-- pattern ai-chapters/ai-photo use). Instead index.ts's own `chooseChain()`
-- calls `resolveRoute()` directly and, on an empty result, substitutes a
-- hardcoded TWO-step fallback — anthropic then openai, byte-identical to
-- both rows seeded below — so a single vendor outage never takes the coach
-- down precisely while the router flag is off, i.e. during normal, everyday
-- operation for a brand-new task like this one. `runChain()` (the same
-- shared retry/circuit-breaker-reporting loop every other function uses)
-- still drives whichever chain `chooseChain()` returns. See
-- docs/AI-ROUTER-CONTRACT.md §1 and coach/README.md for the full rationale.
-- So this migration is additive-only and changes nothing about what the
-- flag-off app runs today; it only gives the router something real to pick
-- once `ai_router.enabled` is flipped on — at which point the real seeded
-- rows are used exactly as `resolveRoute()` returns them, never re-filtered.
--
-- CHAIN CHOICE. coach.chat is the same shape as text.listing_copy (a bounded,
-- well-written text reply, no image in, no image out) so it reuses that row's
-- exact two vetted providers/models/prices verbatim rather than researching a
-- new pair: anthropic `claude-sonnet-5` (always output_config.effort:"low" —
-- enforced in _shared/providers/anthropic.ts regardless of caller) primary,
-- openai `gpt-5.6-terra` (always reasoning.effort:"none") fallback. No third
-- (gemini) step: the contract only asks for "an Anthropic primary and OpenAI
-- fallback" here, and a customer-service chat that must never be dead is
-- better served by two well-understood steps than a third with an
-- unconfirmed price (0018's gemini-3.8-flash row is noted "price estimated").
--
-- NO PLAN METERING. Coach is free on every plan by product decision — the app
-- never gates it on `plan_entitlements`, only on the durable per-user rate
-- limiter (12 msgs / 5 min, 60 / day — coach/index.ts). `min_plan = 'free'` on
-- both rows only controls ROUTING (a paid-only future step could exist
-- alongside these), never access.
--
-- NO NEW plan_routing_policy ROW. 0018 already seeded a policy for all six
-- plans this app will ever send (free/trial/starter → cheapest,
-- solo/pro/team → best) and coach.chat introduces no new plan tier, so the
-- existing table already covers every `context.plan` the app can send.
--
-- PRIVACY. No image or video is ever part of a coach request (text only, by
-- product rule), so `carries_customer_media` is never set for this task and
-- `retained_30d` (the same tier text.listing_copy's rows carry) is honest
-- rather than a `no_retention` claim this task cannot back up.
--
-- Idempotent: `on conflict (task, position) do nothing`, matching 0018 — a
-- replay on a database where an operator has since edited these rows (price,
-- enabled, position) must not revert their change.

insert into public.ai_routes
  (task, position, provider, model, unit, unit_cents, capabilities,
   max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, note)
values
  ('coach.chat', 1, 'anthropic', 'claude-sonnet-5', 'call', 2.1,
   '{text,chat}', 30, 'free', null, 'retained_30d', true, null,
   'reuses text.listing_copy''s primary verbatim — same shape, one bounded text reply. '
   'always output_config.effort:"low"; never a Covered Model (_shared/providers/anthropic.ts).'),
  ('coach.chat', 2, 'openai', 'gpt-5.6-terra', 'call', 2.0,
   '{text,chat}', 30, 'free', null, 'retained_30d', true, null,
   'reuses text.listing_copy''s fallback verbatim. always reasoning.effort:"none".')
on conflict (task, position) do nothing;
