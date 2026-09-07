-- 0028: copy.shotlist — THE REEL, PLANNED AS ONE DECISION (2026-09-07).
--
-- The third route on services/supabase/functions/ai-copy/:
--
--   POST /ai-copy/shotlist   `copy.shotlist`  — the photos in the order they
--                                               should play, the camera move and
--                                               the hold on each one, the caption
--                                               burned into each one, and the
--                                               line of narration that runs
--                                               under it.
--
-- Full contract: docs/COPY-ASSIST-CONTRACT.md §1.3.
--
-- ── WHY A THIRD TASK AND NOT A FLAG ON copy.reel_script ────────────────────
--
-- A route gets its own task when an operator would want to price, cap or fail it
-- over SEPARATELY, and this one qualifies: its answer is one caption plus one
-- narration line per shot (up to twenty shots) rather than one paragraph, so it
-- is the largest reply this function produces and the one whose cost moves first
-- if a model's output pricing changes. Sharing `copy.reel_script`'s task would
-- hide that inside the script's own numbers and leave an operator no way to
-- route the two differently.
--
-- ── THE SAME THREE PROVIDERS AS copy.reel_script, VERBATIM ─────────────────
--
-- This is the same SHAPE of work as its sibling and as `text.listing_copy`
-- before it: one bounded text answer, no image in and no image out. The photos
-- themselves are NEVER sent — the model is given ids, the room label the app
-- already shows, and the photographer's note. So the task reuses the three
-- vetted providers/models/prices rather than researching a new set, exactly as
-- 0027 and 0023 did: anthropic `claude-sonnet-5` 2.1¢, openai `gpt-5.6-terra`
-- 2.0¢, gemini `gemini-3.8-flash` 0.9¢.
--
-- ⚠ PRICE CAVEAT, STATED RATHER THAN BURIED. `unit = 'call'`, and this call's
-- answer is bounded at ~1,600 output tokens against ~700 for a script, so its
-- TRUE cost per call runs above the inherited 2.1¢ / 2.0¢ — inherited numbers
-- priced for a shorter reply. They are kept because a documented, vetted number
-- is worth more than a freshly-guessed one, and because the direction of the
-- error is known and written on the rows below: confirm against the first real
-- provider bills before this task is used to set a COGS ceiling. The same
-- warning 0018 wrote on the gemini row it was copied from applies here twice.
--
-- CAPABILITIES ARE `{text,compliant}` — identical to copy.reel_script, and for
-- the same two reasons. No `vision`: `ctx.needs` is a hard AND, so claiming a
-- capability the route never uses would filter out text-only steps for nothing.
-- `compliant` is not decorative: the narration AND every burned-in caption are
-- published advertising and are re-checked against _shared/fairhousing.ts before
-- the response is built.
--
-- ── NO `note = 'legacy'` ROW ────────────────────────────────────────────────
--
-- Same argument as 0027 and 0023: a legacy row exists to carry the
-- provider/model a SHIPPED edge function hardcodes TODAY (0018 §2), and this is
-- a brand-new task with no prior behaviour to preserve. Inventing one would
-- assert a "what runs today" that does not exist.
--
-- So with the flag off (today's default) `resolveRoute('copy.shotlist')` finds
-- no legacy row and returns `[]`, and ai-copy/index.ts's own `chooseChain()`
-- substitutes its hardcoded TWO-step fallback — anthropic then openai,
-- byte-identical to positions 1 and 2 below — so a single vendor outage cannot
-- take the route down precisely while the master flag is off, i.e. during normal
-- everyday operation. `runChain()` still drives it and still reports every
-- attempt to the circuit breaker. With the flag on, these rows are used exactly
-- as `resolveRoute()` returns them and are never re-filtered
-- (docs/AI-ROUTER-CONTRACT.md §4, rule 2).
--
-- ── WHAT THIS MIGRATION DELIBERATELY DOES NOT DO ───────────────────────────
--
-- NO plan_entitlements CHANGE and no new column. /shotlist shares
-- `aicopy:<org>` (60 / 5 min) with the other two copy routes — one burst key for
-- one function, so a client cannot dodge the limiter by alternating routes.
-- `min_plan = 'free'` controls ROUTING only, never access.
--
-- NO plan_routing_policy ROW: 0018 already seeded a policy for all six plans and
-- this task introduces no new tier.
--
-- NO ai_routes SCHEMA CHANGE. `motion` — the closed set of camera moves this
-- route returns — is application vocabulary shared with
-- services/supabase/functions/ai-video, not routing data, and it is not stored
-- here.
--
-- PRIVACY. `retained_30d`, honestly, and `carries_customer_media` is NOT set:
-- no photo, no video and no audio ever reaches a provider on this task — only
-- ids, room labels and typed facts. THE STREET ADDRESS IS NEVER SENT, the same
-- line copy.reel_script holds: there is no address field in the request body,
-- the client sends a city/state `region` at most, and the model is told to write
-- the literal token `{address}`, which the app substitutes on the device.
--
-- Idempotent: `on conflict (task, position) do nothing`, matching 0018, 0023 and
-- 0027 — a replay on a database where an operator has since edited these rows
-- (price, enabled, position) must not revert their change.

insert into public.ai_routes
  (task, position, provider, model, unit, unit_cents, capabilities,
   max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, note)
values
  -- ══ copy.shotlist — the whole reel: order, motion, pacing, captions, script ═
  ('copy.shotlist', 1, 'anthropic', 'claude-sonnet-5', 'call', 2.1,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'sibling of copy.reel_script (0027), same model verbatim — one bounded text answer, no image '
   'either way. PRICE INHERITED FROM A SHORTER REPLY: this task is capped at ~1,600 output tokens '
   'against ~700 for a script, so 2.1c per call is a floor, not a measurement. Confirm against real '
   'bills before it sets a ceiling. always output_config.effort:"low"; never a Covered Model '
   '(_shared/providers/anthropic.ts).'),
  ('copy.shotlist', 2, 'openai', 'gpt-5.6-terra', 'call', 2.0,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'sibling of copy.reel_script position 2, verbatim. Same inherited-price caveat as position 1. '
   'always reasoning.effort:"none".'),
  ('copy.shotlist', 3, 'gemini', 'gemini-3.8-flash', 'call', 0.9,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'price estimated (flash tier), inherited from 0018''s text.listing_copy row via 0027 — the '
   'contract states no number, and the inherited-price caveat above applies on top of it. Confirm '
   'before this becomes the cheapest-policy default.')
on conflict (task, position) do nothing;
