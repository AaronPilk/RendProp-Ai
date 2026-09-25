begin;
-- Text-only Studio routes. This migration does not set edge-function secrets,
-- ai_router flags, presenter flags or any existing task's configuration.
-- Endpoints remain unavailable until their separate bounded environment gate
-- is enabled. Preserve ALL existing choices for either task, including disabled
-- rows or nonstandard positions; the operator, not a replay, owns those choices.
--
-- PRICE ESTIMATE, checked 2026-09-24:
-- https://platform.claude.com/docs/en/about-claude/pricing
-- Sonnet 5: $2/1M input and $10/1M output tokens.
-- Studio caps user JSON at 24,576 UTF-8 bytes; larger system prompt is 4,039
-- bytes. Conservative byte-as-token allowance: 28,615 * $2/1M = $0.05723;
-- 1,600 output tokens * $10/1M = $0.016; combined $0.07323 < $0.08.
-- The additional margin covers message framing. These are estimates, not
-- token-metered invoice amounts. New code records price_estimated=true.
-- Both text tasks share a 100/day global request cap; estimated maximum $8/day.
-- output_config.effort=low is already supported by the Anthropic adapter;
-- the Studio transport independently enforces max_tokens=1600 and 30 seconds.
insert into public.ai_routes
 (task,position,provider,model,unit,unit_cents,capabilities,max_latency_s,
  min_plan,same_model_as,privacy_tier,enabled,retire_after,note,params)
select task,1,'anthropic','claude-sonnet-5','call',8.0000,
 array['text','compliant'],30,'free',null,'retained_30d',true,null,
 'PRICE ESTIMATED: text only, <=24576 user UTF-8 bytes + <=4039 system bytes, <=1600 output tokens; conservative 8c/call at Sonnet 5 $2/M input + $10/M output. https://platform.claude.com/docs/en/about-claude/pricing checked 2026-09-24. Requires separate STUDIO_EDIT_PLANNER_ENABLED and bounded price environment gates. No automatic paid retries.',
 '{"effort":"low","max_output_tokens":1600}'::jsonb
from (values('copy.edit_plan'),('copy.prompt_enhancement')) seed(task)
where not exists(select 1 from public.ai_routes existing where existing.task=seed.task)
on conflict(task,position) do nothing;
commit;
