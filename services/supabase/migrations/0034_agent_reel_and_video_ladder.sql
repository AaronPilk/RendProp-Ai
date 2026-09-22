-- 0034 — the agent-on-camera reel route, and the Seedance 2.x ladder as FACT.
--
-- ══ PART ONE: copy.agent_reel ═══════════════════════════════════════════════
--
-- The route behind POST /ai-copy/agent-reel. An agent films themselves talking;
-- this decides which listing photograph covers which sentence and what few words
-- burn on it. NOTHING IS GENERATED — the phone composites the edit it is given.
--
-- IT IS THE CHEAPEST MODEL CALL IN THE APP AND IT SHOULD STAY THAT WAY. The
-- reason is structural: this model writes no narration, because the agent
-- already spoke. Its whole answer is at most twelve objects of {window_id,
-- photo_id, five upper-case words}, so the output ceiling is 700 tokens against
-- the shot list's 2,400.
--
-- WHY ASTRA IS GATED TO 'pro' HERE AND 'starter' ON copy.shotlist. The value a
-- reasoning model adds is proportional to how much it is being asked to decide.
-- On a shot list it writes the entire narration; here it matches pictures to
-- sentences the agent already said, which sonnet-5 does well. So the better
-- model is worth having, and worth having ONE TIER FURTHER UP — a Starter agent
-- gets a good edit at 1.5c and a Pro brokerage gets a better one at 3.7c.
--
-- ══ PART TWO: the Seedance 2.x rows, seeded DISABLED ════════════════════════
--
-- video.reel_clip and video.aerial run bytedance/seedance/v1/pro/fast at
-- 4.86c/second, 1080p. Seedance 2.0 and 2.5 exist and are better, and they are
-- 5x and 10x the price AT LOWER RESOLUTION (720p is their ceiling). Verified on
-- fal 2026-09-10:
--
--   seedance/v1/pro/fast/image-to-video     4.86 c/s   1080p   <=6s    (live)
--   seedance-2.0/fast/image-to-video       24.19 c/s    720p   4-15s
--   seedance-2.0/fast/reference-to-video   24.19 c/s    720p   4-15s   9 img + 3 vid + 3 audio
--   seedance-2.5/image-to-video            47.30 c/s    720p   4-30s
--   seedance-2.5/reference-to-video        47.30 c/s    720p   4-30s   50 refs
--   (a video reference multiplies by 0.6 on both reference endpoints)
--
-- A six-clip five-second reel is $1.46 today, $7.26 on 2.0 Fast and $14.19 on
-- 2.5. Against a $49 Starter plan the last of those is 29% of a month's revenue
-- for ONE reel. So these rows are seeded `enabled = false` and exist to make the
-- ladder a fact in the table rather than a thing someone has to re-derive from a
-- vendor page at the moment they are tempted. NOTHING ROUTES DIFFERENTLY TODAY.
--
-- The two NEW tasks are where 2.x actually earns its multiple, and neither is a
-- bundled allowance item:
--
--   video.transition — `end_image_url`. One clip that STARTS on the kitchen
--     photograph and ENDS on the living-room photograph, so the join between two
--     rooms is a move instead of a cut. ~97c for four seconds. One or two per
--     reel, on a paid plan, or not at all.
--   video.walkthrough — reference-to-video with up to nine of the listing's own
--     photographs, producing one continuous shot that travels through rooms that
--     were only ever stills. ~$3.63 for fifteen seconds. An add-on someone buys
--     deliberately, never something a plan quietly includes.
--
-- Both are DISABLED and neither has a caller. Enabling either is a product and
-- pricing decision with a per-generation ceiling attached, exactly like
-- /ai-video/drone's $48 submission ceiling — and the same rule applies: the
-- repo's per-generation cap lives in log_job_cost(), which the in-app AI routes
-- do not reach, so a caller must bring its own.
--
-- Idempotent: `on conflict (task, position) do nothing`, matching 0018/0023/0027
-- — a replay on a database where an operator has since edited these rows (price,
-- enabled, position) must not revert their change.

insert into public.ai_routes
  (task, position, provider, model, unit, unit_cents, capabilities,
   max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, params, note)
values
  -- ══ copy.agent_reel — the edit-decision list for an agent-on-camera reel ══
  ('copy.agent_reel', 1, 'openai', 'gpt-6-astra', 'call', 3.7,
   '{text,compliant}', 60, 'pro', null, 'retained_30d', true, null,
   '{"effort":"low","max_output_tokens":700}'::jsonb,
   'reasoning model, first seat, gated one tier ABOVE copy.shotlist''s astra row — see the '
   'header. PRICE IS MODELLED, NOT BILLED: ~1,200 tokens in x $10/1M + ~500 out (visible + '
   'reasoning, billed as output) x $50/1M = ~3.7c; the 700-token ceiling puts the worst case '
   'at 4.7c. params.effort:"low" is load-bearing — the adapter default is "none", which this '
   'model either refuses or answers badly at a premium price (0030 header).'),
  ('copy.agent_reel', 2, 'anthropic', 'claude-sonnet-5', 'call', 1.5,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null, null,
   'the working default for everyone below Pro, and astra''s failover. CHEAPER THAN THE '
   'copy.shotlist row that uses the same model (2.1c) because the answer is a fraction of the '
   'size: no narration is written here, only picture assignments and captions. '
   'always output_config.effort:"low"; never a Covered Model (_shared/providers/anthropic.ts).'),
  ('copy.agent_reel', 3, 'openai', 'gpt-5.6-terra', 'call', 1.4,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null, null,
   'sibling of copy.shotlist position 3. always reasoning.effort:"none".'),
  ('copy.agent_reel', 4, 'gemini', 'gemini-3.8-flash', 'call', 0.7,
   '{text,compliant}', 60, 'free', null, 'retained_30d', true, null, null,
   'price estimated (flash tier), scaled from the copy.shotlist row by output size. Confirm '
   'before this becomes the cheapest-policy default.'),

  -- ══ video.reel_clip — the 2.x rungs, DISABLED ════════════════════════════
  ('video.reel_clip', 10, 'fal', 'bytedance/seedance-2.0/fast/image-to-video', 'second', 24.19,
   '{i2v,720p,end_frame,audio,4s,6s,8s,15s,16:9,9:16}', 300, 'free', null, 'retained_30d', false, null, null,
   'DISABLED, NOT A FAILOVER: 5x position 1 and a RESOLUTION DOWNGRADE (720p ceiling against '
   '1080p today). Seeded so the ladder is a fact in the table. Adds end_image_url and native '
   'audio, which is what video.transition below is actually for.'),
  ('video.reel_clip', 11, 'fal', 'bytedance/seedance-2.5/image-to-video', 'second', 47.30,
   '{i2v,720p,end_frame,audio,4s,6s,8s,15s,30s,16:9,9:16}', 300, 'free', null, 'retained_30d', false, null, null,
   'DISABLED: 10x position 1, also 720p. 30-second clips and ~20% better prompt adherence do '
   'not pay for themselves on a five-second room clip. A six-clip reel would cost $14.19.'),

  -- ══ video.transition — the room-to-room join, DISABLED, no caller ════════
  ('video.transition', 1, 'fal', 'bytedance/seedance-2.0/fast/image-to-video', 'second', 24.19,
   '{i2v,720p,end_frame,4s,6s,16:9,9:16}', 300, 'pro', null, 'retained_30d', false, null, null,
   'DISABLED, NO CALLER. Starts on one listing photo and ends on another via end_image_url, so '
   'two rooms JOIN instead of cutting. ~97c for four seconds — one or two per reel on a paid '
   'plan, never bundled. A caller must bring its own per-generation ceiling: the repo''s cap is '
   'in log_job_cost(), which the in-app AI routes never reach.'),
  ('video.transition', 2, 'fal', 'bytedance/seedance-2.5/image-to-video', 'second', 47.30,
   '{i2v,720p,end_frame,4s,6s,8s,16:9,9:16}', 300, 'pro', null, 'retained_30d', false, null, null,
   'DISABLED. Different tier, not a queue failover — 2x position 1 for better adherence on the '
   'hardest thing in this set, which is landing exactly on a given last frame.'),

  -- ══ video.walkthrough — many stills, one continuous shot, DISABLED ═══════
  ('video.walkthrough', 1, 'fal', 'bytedance/seedance-2.0/fast/reference-to-video', 'second', 24.19,
   '{ref2v,720p,audio,9_images,4s,6s,8s,15s,16:9,9:16}', 600, 'pro', null, 'retained_30d', false, null, null,
   'DISABLED, NO CALLER. Up to 9 of the listing''s own photographs become ONE continuous shot '
   'travelling through rooms that were only ever stills. ~$3.63 for fifteen seconds, so it is '
   'an add-on somebody buys deliberately, never a plan inclusion. Prompt addresses references '
   'as [Image1]..[Image9]. A video reference would multiply the rate by 0.6.'),
  ('video.walkthrough', 2, 'fal', 'bytedance/seedance-2.5/reference-to-video', 'second', 47.30,
   '{ref2v,720p,audio,50_refs,4s,6s,8s,15s,30s,16:9,9:16}', 900, 'pro', null, 'retained_30d', false, null, null,
   'DISABLED. 50 references and 30 seconds — the only rung that could cover a whole listing in '
   'one take, at $14.19 for thirty seconds. Priced as a premium one-off or not at all.')
on conflict (task, position) do nothing;
