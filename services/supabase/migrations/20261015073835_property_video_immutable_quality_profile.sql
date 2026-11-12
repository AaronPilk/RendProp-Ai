-- New ordinary property-video quality is opt-in. Historical manifests, paid
-- receipts, allowance/funding/global4/job2 and direct legacy routing stay intact.
begin;
insert into public.app_config(key,value)values('property_video_quality','{"enabled":false,"profile":"fal-kling3-4k-v1"}')on conflict(key)do nothing;
insert into public.ai_routes(id,task,position,provider,model,unit,unit_cents,capabilities,max_latency_s,min_plan,same_model_as,privacy_tier,enabled,note)
values('b04b57c1-12c8-44f9-9c64-e06561358f01','video.property_reel_clip',1,'fal','fal-ai/kling-video/v3/4k/image-to-video','second',42,array['i2v','1080p','5s','native4k','preserve_photo'],900,'free','kling_3_pro','retained_30d',true,'Only new saved fal-kling3-4k-v1 property jobs. Native4K source aspect; measured1080 delivery. Profile flag starts OFF.')
on conflict(id)do nothing;

alter table public.property_video_jobs add column if not exists quality_profile text not null default'legacy';
do $$begin if not exists(select 1 from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_quality_profile_check')then
 alter table public.property_video_jobs add constraint property_video_quality_profile_check check(quality_profile in('legacy','fal-kling3-4k-v1'));end if;end$$;

-- SHARE lock lasts through admission: a concurrent profile cutover cannot
-- invalidate a checked quote between this read and the new job insert.
create or replace function public.property_video_quality_profile()returns text language plpgsql security definer set search_path=''as $$declare c jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select value into c from public.app_config where key='property_video_quality'for share;
 if c is null or c->'enabled'='false'::jsonb then return'legacy';end if;
 if c->'enabled'='true'::jsonb and c->>'profile'='fal-kling3-4k-v1'then return'fal-kling3-4k-v1';end if;
 raise exception'RP503: Property-video quality configuration is unavailable';
end$$;
create or replace function public.property_video_quality_freeze()returns trigger language plpgsql security definer set search_path=''as $$declare expected text;quoted text;begin
 if TG_OP='UPDATE'then
  if new.quality_profile is distinct from old.quality_profile then raise exception'RP409: A saved video quality profile is immutable';end if;return new;
 end if;
 expected:=public.property_video_quality_profile();quoted:=nullif(current_setting('rendprop.property_video_quality_profile',true),'');
 if quoted is null then
  if expected<>'legacy'then raise exception'RP409: A new video requires its current quoted quality profile';end if;
  quoted:='legacy';
 end if;
 if quoted not in('legacy','fal-kling3-4k-v1')or quoted<>expected then raise exception'RP409: The video quality quote changed before admission';end if;
 new.quality_profile:=quoted;
 if quoted='fal-kling3-4k-v1'then new.deadline:=new.created_at+interval'24 hours';end if;
 return new;
end$$;
drop trigger if exists property_video_quality_freeze on public.property_video_jobs;
create trigger property_video_quality_freeze before insert or update on public.property_video_jobs for each row execute function public.property_video_quality_freeze();

-- The fourth argument is server-only quote metadata. Existing native/public
-- bodies and manifest SHA do not change. Existing-operation replay comes first.
create or replace function public.property_video_job_admit(p_actor uuid,p_manifest jsonb,p_quote numeric,p_quality_profile text)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;r public.property_video_refused_operations;h text;message text;prior text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||(p_manifest->>'operation_id'),79));
 h:=encode(pg_catalog.sha256(pg_catalog.convert_to(p_manifest::text,'UTF8')),'hex');
 select *into j from public.property_video_jobs where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if j.id is not null then j:=public.property_video_job_enqueue(p_actor,p_manifest);return jsonb_build_object('accepted',true,'job',to_jsonb(j));end if;
 select *into r from public.property_video_refused_operations where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if r.operation_id is not null then if r.manifest_sha256<>h then raise exception'RP409: The refused operation has different saved inputs';end if;return jsonb_build_object('accepted',false,'message',r.message,'operation_closed',true);end if;
 if p_quality_profile is null or p_quality_profile not in('legacy','fal-kling3-4k-v1')or p_quality_profile<>public.property_video_quality_profile()then raise exception'RP409: The video quality quote changed before admission';end if;
 -- These are generation-only minima, not permission to bypass the complete
 -- normal quote/capacity checks or automatic retry funding.
 if p_quality_profile='fal-kling3-4k-v1'and(p_quote is null or p_quote<210*jsonb_array_length(p_manifest->'sources'))then raise exception'RP400: The property-video quality quote is incomplete';end if;
 begin perform public.property_video_recipe_capacity(p_actor,(p_manifest->>'listing_id')::uuid,jsonb_array_length(p_manifest->'sources'),p_quote);
 exception when others then get stacked diagnostics message=message_text;if position('RP402:'in message)<>1 then raise;end if;
 insert into public.property_video_refused_operations(actor_id,operation_id,listing_id,library_org_id,manifest_sha256,message)values(p_actor,(p_manifest->>'operation_id')::uuid,(p_manifest->>'listing_id')::uuid,public.listing_owner_library((p_manifest->>'listing_id')::uuid),h,substr(message,8,1000));return jsonb_build_object('accepted',false,'message',substr(message,8,1000),'operation_closed',true);end;
 prior:=current_setting('rendprop.property_video_quality_profile',true);
 perform set_config('rendprop.property_video_quality_profile',p_quality_profile,true);
 j:=public.property_video_job_enqueue(p_actor,p_manifest);
 perform set_config('rendprop.property_video_quality_profile',coalesce(prior,''),true);
 return jsonb_build_object('accepted',true,'job',to_jsonb(j));
end$$;
-- Old deployed closures can replay accepted jobs, but cannot slip a newly
-- quoted legacy operation through an active high-quality profile cutover.
create or replace function public.property_video_job_admit(p_actor uuid,p_manifest jsonb,p_quote numeric)returns jsonb language sql security definer set search_path=''as $$
 select public.property_video_job_admit(p_actor,p_manifest,p_quote,'legacy');
$$;
revoke all on function public.property_video_quality_profile(),public.property_video_quality_freeze(),public.property_video_job_admit(uuid,jsonb,numeric,text),public.property_video_job_admit(uuid,jsonb,numeric)from public,anon,authenticated;
grant execute on function public.property_video_quality_profile(),public.property_video_job_admit(uuid,jsonb,numeric,text),public.property_video_job_admit(uuid,jsonb,numeric)to service_role;
commit;
