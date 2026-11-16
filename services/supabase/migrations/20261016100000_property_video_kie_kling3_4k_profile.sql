-- Prospective Kie Kling 3.0 native-4K property-video profile
-- (kie-kling3-4k-steady-v1). One pinned route row, a frozen identity on every
-- newly admitted Kie job, and the same 24 fps steady treatment as
-- fal-kling3-4k-steady-v2. No app_config default, existing route, saved
-- job/manifest/profile, price, allowance, hold or historical output changes.
-- The pinned row is seeded OFF (AI-router contract section 3: every reseller
-- row stays disabled until its terms are owner-approved) and nothing here can
-- turn the profile on. Activation is the separate owner-approved operator step
-- docs/handoff/KIE-ACTIVATION.sql: in one transaction it enables this row,
-- sets the selector with the exact Kie Terms section 3 acknowledgement and
-- records the processor-disclosure attestation with the exact previous selector
-- (app_config.property_video_quality_kie_activation, which this migration never
-- seeds; docs/handoff/KIE-ROLLBACK.sql restores that value). Without the
-- acknowledgement the selector refuses (RP503); without the enabled row,
-- admission refuses (RP409) and the runtime sends no generation.
begin;
-- Dedicated task: the FAL task video.property_reel_clip still resolves exactly
-- one row. Runtime reads this row by id (never resolveRoute, whose customer-
-- media privacy rule drops trains_by_default); admission below re-checks it.
insert into public.ai_routes(id,task,position,provider,model,unit,unit_cents,capabilities,max_latency_s,min_plan,same_model_as,privacy_tier,enabled,params,note)
values('7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21','video.property_reel_clip_kie',1,'kie','kling-3.0/video','second',33.5,array['i2v','1080p','5s','native4k','preserve_photo'],1800,'free','kling_3_pro','trains_by_default',false,'{"kie_mode":"4K","sound":false}','Only new saved kie-kling3-4k-steady-v1 property jobs, read by pinned id (never resolveRoute). Native 4K, silent, 5s, 67 credits/s. Kie Terms section 3 is trains_by_default: the profile needs the explicit owner acknowledgement. Row is OFF until the owner-approved activation (docs/handoff/KIE-ACTIVATION.sql enables it and sets the acknowledged selector).')
on conflict(id)do nothing;
-- Every identity field is exact. enabled may be either value: the owner-approved
-- activation (and its rollback) flips only enabled (and stamps updated_at), so a
-- replay after activation still verifies. note/created_at/updated_at are metadata.
do $route$begin
 if(select count(*)from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'and task='video.property_reel_clip_kie'and position=1 and provider='kie'and model='kling-3.0/video'and unit='second'and unit_cents=33.5
   and capabilities=array['i2v','1080p','5s','native4k','preserve_photo']and max_latency_s=1800 and min_plan='free'and same_model_as='kling_3_pro'and privacy_tier='trains_by_default'and enabled in(false,true)and retire_after is null
   and params='{"kie_mode":"4K","sound":false}'::jsonb)<>1 or(select count(*)from public.ai_routes where task='video.property_reel_clip_kie')<>1 then raise exception'Review changed pinned Kie property-video route';end if;
end$route$;

-- Canonical identity; must equal functions/_shared/property-video-kie-identity.json
-- (the disposable-Postgres proof compares them). NULL for every other profile.
create or replace function public.property_video_quality_identity(p_profile text)returns jsonb language sql immutable set search_path=''as $$
 select case when p_profile='kie-kling3-4k-steady-v1'then'{"profile":"kie-kling3-4k-steady-v1","provider":"kie","model":"kling-3.0/video","route_id":"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21","task":"video.property_reel_clip_kie","mode":"4K","sound":false,"multi_shots":false,"seconds":5,"unit":"second","unit_cents":33.5,"attempt_cents":167.5,"credits_per_second":67,"usd_per_credit":0.005,"price_source":"https://kie.ai/kling-3-0","price_checked":"2026-10-16","bonus_credits_excluded":true,"max_paid_attempts_per_source":2,"prompt_profile":"steady-property-v1","prompt_template_token":"{scene_noun}","prompt_scene_nouns":["home","event venue","restaurant","store","fitness studio","space"],"prompt_template_sha256":{"fly_through":"5a27f080e3affd92fc1f455f09d29df3b9d82c3bb07de6a4fae644ddba95a785","push_in":"275836a1c183898de223d1f576eba246ca4aa635611a0afd410743a264d472f7","side_glide":"cad745c420ac54cd4339a73fde9ad33322949dbbb6764f596c2d1da24d0848a3","pull_back":"e80e5a784366935080e5ab43d2e8ea395859a6993c6c146bfc96c86b138b8aa9"},"composition_profile":"steady-v2-cfr24","output_fps":24,"output_frames":[120,121],"min_short_side_px":2160,"min_pixels":8000000,"aspect_ratio_wire":"omitted_source_auto","privacy_tier":"trains_by_default","content_license_ack":"kie-terms-2025-08-01-section-3-owner-accepted"}'::jsonb end
$$;
revoke all on function public.property_video_quality_identity(text)from public,anon,authenticated;
grant execute on function public.property_video_quality_identity(text)to service_role;
comment on function public.property_video_quality_identity(text)is'Canonical frozen identity of kie-kling3-4k-steady-v1 (equals functions/_shared/property-video-kie-identity.json); NULL for legacy and FAL profiles.';

-- NULL for every historical and FAL job; set only by the freeze trigger.
alter table public.property_video_jobs add column if not exists quality_identity jsonb;
do $column$begin
 if(select format_type(atttypid,atttypmod)||':'||attnotnull||':'||atthasdef from pg_attribute where attrelid='public.property_video_jobs'::regclass and attname='quality_identity'and not attisdropped)is distinct from'jsonb:false:false'then
  raise exception'Review changed saved quality identity column';end if;
end$column$;
comment on column public.property_video_jobs.quality_identity is'Immutable identity frozen at admission: property_video_quality_identity(quality_profile) for kie-kling3-4k-steady-v1, NULL otherwise.';

-- Exact md5-verified anchors in the current (steady-v2) bodies. The steady-v2
-- anchors are kept verbatim so its compiled proofs still address the same text.
do $patch$declare p record;body text;original text;definition text;i integer;begin
 for p in select *from(values
('public.property_video_quality_profile()','ea27e5d9a2848810bbd28ec744819f47','9671b48a46a1e777bc4b968c1a669d44',array[$anchor$if c->'enabled'='true'::jsonb and c->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then return c->>'profile';end if;$anchor$],array[$replacement$if c->'enabled'='true'::jsonb and c->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then return c->>'profile';end if;
 -- Kie Terms section 3 licenses customer content to improve its services; the
 -- profile is active only with the owner's exact recorded acknowledgement.
 if c->'enabled'='true'::jsonb and c->>'profile'='kie-kling3-4k-steady-v1'and c->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack'then return c->>'profile';end if;$replacement$]),
('public.property_video_quality_freeze()','6ae05e2c05a0007cbedeb754437889bd','8690864e9d4e01a5c8fa5d4699bfdc20',array[$anchor$if new.quality_profile is distinct from old.quality_profile then raise exception'RP409: A saved video quality profile is immutable';end if;$anchor$,$anchor$quoted not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2')or quoted<>expected$anchor$,$anchor$new.quality_profile:=quoted;$anchor$,$anchor$if quoted in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then new.deadline:=new.created_at+interval'24 hours';end if;$anchor$],array[$replacement$if new.quality_profile is distinct from old.quality_profile then raise exception'RP409: A saved video quality profile is immutable';end if;
  if new.quality_identity::text is distinct from old.quality_identity::text then raise exception'RP409: A saved video quality identity is immutable';end if;$replacement$,$replacement$quoted not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1')or quoted<>expected$replacement$,$replacement$new.quality_profile:=quoted;new.quality_identity:=public.property_video_quality_identity(quoted);$replacement$,$replacement$if quoted in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then new.deadline:=new.created_at+interval'24 hours';end if;
 if quoted='kie-kling3-4k-steady-v1'then new.deadline:=new.created_at+interval'24 hours';end if;$replacement$]),
('public.property_video_job_admit(uuid,jsonb,numeric,text)','7a2b40f20d4c63c2faf0029e5e1bda94','27144ffabf1bcb6a36ea6023d169cbd8',array[$anchor$p_quality_profile not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2')or$anchor$,$anchor$if p_quality_profile in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')and(p_quote is null or p_quote<210*jsonb_array_length(p_manifest->'sources'))then raise exception'RP400: The property-video quality quote is incomplete';end if;$anchor$],array[$replacement$p_quality_profile not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1')or$replacement$,$replacement$if p_quality_profile in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')and(p_quote is null or p_quote<210*jsonb_array_length(p_manifest->'sources'))then raise exception'RP400: The property-video quality quote is incomplete';end if;
 -- Kie 4K: 67 credits/s x 5 s = 167.5 cents per source, exact numeric.
 if p_quality_profile='kie-kling3-4k-steady-v1'and(p_quote is null or p_quote<167.5*jsonb_array_length(p_manifest->'sources'))then raise exception'RP400: The property-video quality quote is incomplete';end if;
 -- The pinned route row must still equal the frozen identity. FOR SHARE holds
 -- it through the job insert, so a concurrent route edit cannot pass a stale quote.
 if p_quality_profile='kie-kling3-4k-steady-v1'then
  perform 1 from public.ai_routes route,(select public.property_video_quality_identity('kie-kling3-4k-steady-v1')kie)pinned
   where route.id=(pinned.kie->>'route_id')::uuid and route.task=pinned.kie->>'task'and route.provider=pinned.kie->>'provider'and route.model=pinned.kie->>'model'
    and route.unit=pinned.kie->>'unit'and route.unit_cents=(pinned.kie->>'unit_cents')::numeric and route.params=jsonb_build_object('kie_mode',pinned.kie->'mode','sound',pinned.kie->'sound')
    and route.enabled and route.privacy_tier=pinned.kie->>'privacy_tier'and(route.retire_after is null or route.retire_after>(now()at time zone'UTC')::date)for share of route;
  if not found then raise exception'RP409: The Kie property-video route changed before admission';end if;
 end if;$replacement$]),
('public.paid_quality_processing_budget(uuid)','d519be40bb1028a8d014fd1f47d20130','a28d26cfc04c43b1fd12b58cc7d49cb4',array[$anchor$quality:=coalesce(v->'enabled'='true'::jsonb and v->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2'),false);$anchor$],array[$replacement$quality:=coalesce(v->'enabled'='true'::jsonb and(v->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')or(v->>'profile'='kie-kling3-4k-steady-v1'and v->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack')),false);$replacement$]),
('public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)','2b4f442689386f645e9cb89fcfd4be91','e9f7f8c6bb71722f219199612684a902',array[$anchor$output_fps:=case when j.quality_profile='fal-kling3-4k-steady-v2'then 24 else 30 end;$anchor$],array[$replacement$output_fps:=case when j.quality_profile='fal-kling3-4k-steady-v2'then 24 else 30 end;
 if j.quality_profile='kie-kling3-4k-steady-v1'then output_fps:=24;end if;$replacement$]),
('public.background_video_delivery(uuid,uuid,uuid,text,bigint)','67354e0acac516a3c6402903318235ab','7c8f938eb5822ca727d18ebad808db46',array[$anchor$case when j.quality_profile='fal-kling3-4k-steady-v2'then jsonb_build_object('quality_profile',j.quality_profile)else'{}'::jsonb end;$anchor$],array[$replacement$case when j.quality_profile='fal-kling3-4k-steady-v2'then jsonb_build_object('quality_profile',j.quality_profile)else'{}'::jsonb end||case when j.quality_profile='kie-kling3-4k-steady-v1'then jsonb_build_object('quality_profile',j.quality_profile)else'{}'::jsonb end;$replacement$])
 )v(signature,before_md5,after_md5,anchors,replacements)loop
  select prosrc into body from pg_proc where oid=p.signature::regprocedure;
  if md5(body)not in(p.before_md5,p.after_md5)then raise exception'Review changed Kie profile dependency: %',p.signature;end if;
  if md5(body)=p.before_md5 then
   original:=body;
   for i in 1..array_length(p.anchors,1)loop
    if(length(body)-length(replace(body,p.anchors[i],'')))/length(p.anchors[i])<>1 then raise exception'Exact Kie profile anchor changed: %',p.signature;end if;
    body:=replace(body,p.anchors[i],p.replacements[i]);
   end loop;
   if md5(body)<>p.after_md5 then raise exception'Unexpected Kie profile body: %',p.signature;end if;
   definition:=pg_get_functiondef(p.signature::regprocedure);
   if position(original in definition)=0 then raise exception'Kie profile function definition changed: %',p.signature;end if;
   execute replace(definition,original,body);
  end if;
 end loop;
end$patch$;
do $constraint$declare actual text;begin
 select pg_get_constraintdef(oid)into actual from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_quality_profile_check'and contype='c'and convalidated;
 if actual=$old$CHECK ((quality_profile = ANY (ARRAY['legacy'::text, 'fal-kling3-4k-v1'::text, 'fal-kling3-4k-steady-v2'::text])))$old$ then
  alter table public.property_video_jobs drop constraint property_video_quality_profile_check;
  alter table public.property_video_jobs add constraint property_video_quality_profile_check check(quality_profile in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1'));
 elsif actual is distinct from $expected$CHECK ((quality_profile = ANY (ARRAY['legacy'::text, 'fal-kling3-4k-v1'::text, 'fal-kling3-4k-steady-v2'::text, 'kie-kling3-4k-steady-v1'::text])))$expected$ then raise exception'Review changed saved quality profile constraint';end if;
end$constraint$;
commit;
