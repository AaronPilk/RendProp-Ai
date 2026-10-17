-- New strict-client preservation profile only. Legacy photo.stage/declutter
-- rows, old clients, prices/credits/funding and existing paid work are unchanged.
begin;
insert into public.app_config(key,value)
values('photo_preservation_quality','{"enabled":false,"profile":"gemini-pro-4k-preservation-v1","tasks":[]}'::jsonb)
on conflict(key)do nothing;
-- Activation selects only reviewed tasks, e.g. tasks:["photo.stage"].
-- Declutter need not be activated with Stage.
-- Disabled independently of the policy flag. Activation requires both explicit
-- policy approval and enabled eligible isolated rows; no Flash fallback.
insert into public.ai_routes(id,task,position,provider,model,unit,unit_cents,capabilities,max_latency_s,min_plan,same_model_as,privacy_tier,enabled,note,params)
values
 ('c43f188c-faf0-46c8-a646-ea71b8481201','photo.quality_stage',1,'gemini','gemini-3-pro-image','image',30.5536,array['prompt-edit','fidelity','4K'],120,'free','gemini_3_pro_image','retained_30d',false,'legacy','{"image_size":"4K"}'::jsonb),
 ('c43f188c-faf0-46c8-a646-ea71b8481202','photo.quality_declutter',1,'gemini','gemini-3-pro-image','image',30.5536,array['prompt-edit','fidelity','4K'],120,'free','gemini_3_pro_image','retained_30d',false,'legacy','{"image_size":"4K"}'::jsonb)
on conflict(id)do nothing;
--30.5536c is the complete minimum8192-input/4096-text/2000-image bound.
-- The handler reprices the actual verified8192/16384/24576 input tier before
-- normal reservation; the separate paid quality check is never folded into it.
commit;
