-- 0027: copy.reel_script + copy.photo_prompt — AI PROMPTING FOR PEOPLE WHO ARE
-- NOT PROMPT ENGINEERS (2026-09-07).
--
-- The app's owner asked for "AI prompting installed for like describing how to
-- change an image, describing a script for the reel so that way prompting is
-- perfect." Two routes on one new edge function
-- (services/supabase/functions/ai-copy/) answer that:
--
--   POST /ai-copy/script        `copy.reel_script`  — the reel voiceover script
--   POST /ai-copy/edit-prompt   `copy.photo_prompt` — a rough photo-edit idea,
--                                                     turned into a real
--                                                     instruction
--
-- Full contract: docs/COPY-ASSIST-CONTRACT.md.
--
-- ── WHY THIS FILE LOOKS LIKE 0023 AND NOT LIKE 0018's photo.* ROWS ──────────
--
-- NO `note = 'legacy'` ROW, for either task. 0018 §2's rule is that a legacy row
-- exists to carry the provider/model a SHIPPED edge function hardcodes TODAY, so
-- that flag-off behaviour is byte-identical. These are BRAND NEW tasks with no
-- prior behaviour to preserve — exactly coach.chat's situation in 0023 — so
-- there is nothing for a legacy row to describe, and inventing one would be
-- asserting a "what runs today" that does not exist.
--
-- With the flag off (today's default) `resolveRoute()` therefore finds no legacy
-- row and returns `[]`. ai-copy/index.ts's own `chooseChain()` substitutes a
-- hardcoded TWO-step fallback — anthropic then openai, byte-identical to
-- positions 1 and 2 below — rather than the single-step `resolveChain()`
-- fallback ai-photo/ai-chapters use, so a single vendor outage cannot take a
-- brand-new feature down precisely while the master flag is off, i.e. during
-- normal everyday operation. `runChain()` still drives it and still reports
-- every attempt to the circuit breaker. Once the flag is on, these rows are used
-- exactly as `resolveRoute()` returns them and are never re-filtered
-- (docs/AI-ROUTER-CONTRACT.md §4, rule 2).
--
-- ── CHAIN CHOICE: SIBLINGS OF text.listing_copy ─────────────────────────────
--
-- Both tasks are the same shape as `text.listing_copy` (0018, ~line 405): one
-- bounded, well-written text answer, no image in and no image out. So they reuse
-- that task's three vetted providers/models/prices VERBATIM rather than
-- researching a new set — anthropic `claude-sonnet-5` 2.1¢, openai
-- `gpt-5.6-terra` 2.0¢, gemini `gemini-3.8-flash` 0.9¢ — the same reuse 0023
-- made for coach.chat, and for the same reason: three well-understood rows beat
-- three freshly-guessed ones.
--
-- text.listing_copy itself still has ZERO callers; it was seeded as a slot. These
-- two tasks are its first real users, in everything but the task name.
--
-- CAPABILITIES ARE `{text,compliant}` — text.listing_copy's set MINUS `vision`.
-- `ctx.needs` is a hard AND, so a capability is a promise the caller can be held
-- to: neither of these routes ever sends an image (the script route is told only
-- facts the owner typed; the prompt route is told only their sentence), so
-- claiming `vision` would filter out any future text-only step for a capability
-- nothing here uses. `compliant` is kept and is not decorative: both routes
-- produce copy that is published as advertising and is re-checked against
-- _shared/fairhousing.ts before it is returned.
--
-- NO gemini step is dropped, unlike 0023 — the coach could not be dead, so it
-- took only the two rows with confirmed prices. These routes are assistive
-- (a bad or missing suggestion costs a user one tap, not a broken product), so
-- the cheap third step earns its place as a last resort. Its price carries the
-- same "estimated" warning 0018 wrote on the row it is copied from.
--
-- ── WHAT THIS MIGRATION DELIBERATELY DOES NOT DO ───────────────────────────
--
-- NO plan_entitlements CHANGE, and no new column. Copy assist is metered by a
-- per-org burst limiter only (`aicopy:<org>`, 60 / 5 min) — the shape ai-photo's
-- `suggest` / `improve_prompt` helpers already use for a sub-2¢ text call that
-- generates no image and no video. `min_plan = 'free'` on every row below
-- controls ROUTING only (a paid-only future step could sit alongside these); it
-- never controls access.
--
-- NO plan_routing_policy ROW. 0018 already seeded a policy for all six plans the
-- app can send (free/trial/starter → cheapest, solo/pro/team → best) and these
-- tasks introduce no new tier.
--
-- PRIVACY. Neither task carries customer media, so `carries_customer_media` is
-- never set for them and `retained_30d` (the tier the text.listing_copy rows
-- these are copied from already carry) is honest rather than a `no_retention`
-- claim these tasks cannot back up. What is NOT sent is the point: the STREET
-- ADDRESS never reaches copy.reel_script. There is no address field in the
-- request body — the client sends a city/state `region` at most, the same line
-- ai-video's aerial route holds — and the model is told to write the literal
-- token `{address}`, which the app substitutes on the device. A vendor gets the
-- narration and never the address of somebody's home.
--
-- Idempotent: `on conflict (task, position) do nothing`, matching 0018 and 0023
-- — a replay on a database where an operator has since edited these rows (price,
-- enabled, position) must not revert their change.

insert into public.ai_routes
  (task, position, provider, model, unit, unit_cents, capabilities,
   max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, note)
values
  -- ══ copy.reel_script — the reel voiceover script ═════════════════════════
  ('copy.reel_script', 1, 'anthropic', 'claude-sonnet-5', 'call', 2.1,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'reuses text.listing_copy''s primary verbatim — same shape, one bounded text answer. '
   'always output_config.effort:"low"; never a Covered Model (_shared/providers/anthropic.ts).'),
  ('copy.reel_script', 2, 'openai', 'gpt-5.6-terra', 'call', 2.0,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'reuses text.listing_copy''s fallback verbatim. always reasoning.effort:"none".'),
  ('copy.reel_script', 3, 'gemini', 'gemini-3.8-flash', 'call', 0.9,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'price estimated (flash tier), inherited from 0018''s text.listing_copy row — the contract '
   'states no number; confirm before this becomes the cheapest-policy default.'),

  -- ══ copy.photo_prompt — a rough edit idea → a real instruction ═══════════
  ('copy.photo_prompt', 1, 'anthropic', 'claude-sonnet-5', 'call', 2.1,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'same three steps as copy.reel_script: one bounded text answer, no image either way.'),
  ('copy.photo_prompt', 2, 'openai', 'gpt-5.6-terra', 'call', 2.0,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'always reasoning.effort:"none".'),
  ('copy.photo_prompt', 3, 'gemini', 'gemini-3.8-flash', 'call', 0.9,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null,
   'price estimated (flash tier) — same caveat as the copy.reel_script row above.')
on conflict (task, position) do nothing;
