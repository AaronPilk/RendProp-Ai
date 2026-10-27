-- SOURCE ONLY. Apply after the separately qualified aerial generation schema.
-- No config producer is seeded, no existing cost settlement function is changed.
begin;
set local lock_timeout='5s';
lock table public.property_video_jobs in access exclusive mode;
do $baseline$begin
 if(select md5(prosrc)from pg_proc where oid='public.property_video_photo_motion_profile(jsonb)'::regprocedure)is distinct from'552c7588850bafe94517f75d5c873657'then raise exception'Aerial composition predecessor changed: public.property_video_photo_motion_profile(jsonb)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_photo_motion_identity_for(text)'::regprocedure)is distinct from'f2c8a9922c70864b427cf64f0a9b9f36'then raise exception'Aerial composition predecessor changed: public.property_video_photo_motion_identity_for(text)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_photo_motion_saved_identity(text,jsonb)'::regprocedure)is distinct from'28867ce20c2e3d208c78083f4a232376'then raise exception'Aerial composition predecessor changed: public.property_video_photo_motion_saved_identity(text,jsonb)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_photo_motion_manifest(uuid,jsonb)'::regprocedure)is distinct from'2059470d9f9f5332cfb9db0b2df67ddd'then raise exception'Aerial composition predecessor changed: public.property_video_photo_motion_manifest(uuid,jsonb)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_photo_motion_quote(uuid,jsonb)'::regprocedure)is distinct from'bf3e145ba3cf114bee73cb584a859bdb'then raise exception'Aerial composition predecessor changed: public.property_video_photo_motion_quote(uuid,jsonb)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_job_admit_photo_motion(uuid,jsonb)'::regprocedure)is distinct from'208841bb1ad938ce350f523db1287e3b'then raise exception'Aerial composition predecessor changed: public.property_video_job_admit_photo_motion(uuid,jsonb)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_quality_freeze()'::regprocedure)is distinct from'14341b1138c30711190930517c475961'then raise exception'Aerial composition predecessor changed: public.property_video_quality_freeze()';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_job_claim_photo_motion(uuid,text)'::regprocedure)is distinct from'b5155260c61b883086684e414b3ab8f8'then raise exception'Aerial composition predecessor changed: public.property_video_job_claim_photo_motion(uuid,text)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_job_finish_photo_motion(uuid,uuid,jsonb)'::regprocedure)is distinct from'dc51cc3e8fcdee2e230b6c89e58dfe07'then raise exception'Aerial composition predecessor changed: public.property_video_job_finish_photo_motion(uuid,uuid,jsonb)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure)is distinct from'56b0bd247ea9461c5a71ce5a3cab46cf'then raise exception'Aerial composition predecessor changed: public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)';end if;
 if(select md5(prosrc)from pg_proc where oid='public.publish_property_video(uuid,uuid,jsonb,uuid,text)'::regprocedure)is distinct from'ccf5e5f340b045e8f507cbb87032ae46'then raise exception'Aerial composition predecessor changed: public.publish_property_video(uuid,uuid,jsonb,uuid,text)';end if;
end$baseline$;

alter function public.property_video_photo_motion_manifest(uuid,jsonb) rename to property_video_photo_motion_manifest_before_opening_20261022;
alter function public.property_video_photo_motion_identity_for(text) rename to property_video_photo_motion_identity_before_opening_20261022;
alter function public.property_video_photo_motion_profile(jsonb) rename to property_video_photo_motion_profile_before_opening_20261022;
alter function public.property_video_photo_motion_saved_identity(text,jsonb) rename to property_video_photo_motion_saved_identity_before_opening_20261022;
create function public.property_video_photo_motion_profile(p_manifest jsonb)returns text language plpgsql immutable set search_path=''as $$begin
 if p_manifest->>'composition_profile'='photo-motion-v2-opening-cfr24'then
  if p_manifest->>'source_mode'is distinct from'photo_motion_v1'or jsonb_typeof(p_manifest->'opening')is distinct from'object'then raise exception'RP400: Freeze one accepted aerial opening with this profile';end if;
  return 'photo-motion-v2-opening-cfr24';
 end if;
 if p_manifest?'opening'then raise exception'RP400: An aerial opening requires its explicit composition profile';end if;
 return public.property_video_photo_motion_profile_before_opening_20261022(p_manifest);end$$;
create function public.property_video_photo_motion_identity_for(p_profile text)returns jsonb language plpgsql stable security definer set search_path=''as $$declare c jsonb;p jsonb;begin
 if p_profile is distinct from'photo-motion-v2-opening-cfr24'then return public.property_video_photo_motion_identity_before_opening_20261022(p_profile);end if;
 select value into c from public.app_config where key='photo_motion_renderer_v2_opening';p:=c->'producer_identity';
 if jsonb_typeof(c)is distinct from'object'or c->'enabled'is distinct from'true'::jsonb or c->>'composition_profile'is distinct from'photo-motion-v2-opening-cfr24'
 or jsonb_typeof(p)is distinct from'object'or(select count(*)from jsonb_object_keys(p))<>3 or exists(select 1 from jsonb_object_keys(p)k where k not in('image_uri','controller_sha256','renderer_source_sha256'))
 or coalesce(p->>'image_uri','')!~'^registry\.cloudflare\.com/[a-f0-9]{32}/[a-z0-9][a-z0-9._/-]{0,180}@sha256:[a-f0-9]{64}$'
 or coalesce(p->>'controller_sha256','')!~'^[a-f0-9]{64}$'or coalesce(p->>'renderer_source_sha256','')!~'^[a-f0-9]{64}$'
 then raise exception'RP503: Aerial composition is waiting for its verified renderer release';end if;
 return '{"source_mode":"photo_motion_v1","composition_profile":"photo-motion-v2-opening-cfr24","fps":24,"algorithm":"fractional-bicubic-cosine-12pct-four-directions","visible_frames":[48,72,96,120],"transition":"cut","opening":"accepted-full-clip-first","max_opening_frames":192,"max_audio_attempts":3,"max_compose_attempts":3,"max_processing_wall_ms":1260000,"rate_evidence_sha256":"8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a"}'::jsonb||jsonb_build_object('producer_identity',p);
end$$;
create function public.property_video_photo_motion_saved_identity(p_profile text,p_identity jsonb)returns boolean language plpgsql stable security definer set search_path=''as $$begin
 if p_profile='photo-motion-v2-opening-cfr24'then return p_identity is not distinct from public.property_video_photo_motion_identity_for(p_profile);end if;
 return public.property_video_photo_motion_saved_identity_before_opening_20261022(p_profile,p_identity);end$$;
create function public.property_video_photo_motion_manifest(p_actor uuid,p_manifest jsonb)returns jsonb language plpgsql security definer set search_path=''as $$declare base jsonb;checked jsonb;opening jsonb;total integer;org uuid;begin
 if p_manifest->>'composition_profile'is distinct from'photo-motion-v2-opening-cfr24'then return public.property_video_photo_motion_manifest_before_opening_20261022(p_actor,p_manifest);end if;
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_photo_motion_profile(p_manifest);
 base:=jsonb_set(p_manifest-'opening','{composition_profile}','"photo-motion-v2-cfr24"'::jsonb);
 -- Photo validation stays in the exact predecessor. Caption timing uses the
 -- complete timeline below, rather than silently extending its final shot.
 checked:=public.property_video_photo_motion_manifest_before_opening_20261022(p_actor,jsonb_set(base,'{narration_words}','[]'::jsonb));
 org:=(checked->>'org_id')::uuid;
 opening:=public.property_video_aerial_opening_scope(p_manifest->'opening',p_actor,org,public.listing_owner_library((p_manifest->>'listing_id')::uuid),(p_manifest->>'listing_id')::uuid,p_manifest->>'aspect');
 total:=(checked->>'total_frames')::integer+(opening#>>'{opening,visible_frames}')::integer;
 if jsonb_typeof(coalesce(p_manifest->'narration_words','[]'::jsonb))is distinct from'array'or exists(select 1 from jsonb_array_elements(coalesce(p_manifest->'narration_words','[]'::jsonb))w where(w->>'end')::numeric>total::numeric/24)then raise exception'RP400: Spoken captions must fit the exact opening and photo timeline';end if;
 return checked||jsonb_build_object('opening',opening->'opening','total_frames',total);end$$;

CREATE OR REPLACE FUNCTION public.property_video_photo_motion_quote(p_actor uuid, p_manifest jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare checked jsonb;attempts integer;bytes_ numeric;hold numeric;begin
 checked:=public.property_video_photo_motion_manifest(p_actor,p_manifest);
 attempts:=case when p_manifest->>'narration_asset_id'is not null or p_manifest->>'narration_result_id'is not null then 6 else 3 end;
 select coalesce(sum((s->>'source_bytes')::numeric),0)into bytes_ from jsonb_array_elements(p_manifest->'sources')s;
 if p_manifest->>'composition_profile'='photo-motion-v2-opening-cfr24'then bytes_:=bytes_+(checked#>>'{opening,bytes}')::numeric;end if;
 -- Published standard-3 marginal bounds, no included tiers. CPU/RAM/disk
 -- .006112 cents/wall-second; $0.05/GB worst listed container egress.
 -- Up to3compose +3optional audio attempts; 20min watchdog plus60s idle each.
 -- Outputs use the existing1GiB video/10MiB poster caps. Storage/Worker/DO/log
 -- budgets retain their normal separate authorities; this is not a retail price.
 hold:=ceil((attempts*1260*.006112+3*(bytes_+1073741824+10485760)*5/1000000000+case when attempts=6 then 3*20971520*5::numeric/1000000000 else 0 end)*10000)/10000;
 return jsonb_build_object('quality_profile',public.property_video_photo_motion_profile(p_manifest),'composition_profile',public.property_video_photo_motion_profile(p_manifest),'source_mode','photo_motion_v1','estimated_cents',hold,'basis','published-container-upper-bound-20261021','tariff_version','container-standard3-20261021','rate_evidence_sha256','8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a','identity',public.property_video_photo_motion_identity_for(public.property_video_photo_motion_profile(p_manifest)),'source_count',jsonb_array_length(p_manifest->'sources'),'total_frames',checked->'total_frames','max_task_attempts',attempts,'max_processing_wall_ms',1260000,'source_bytes',bytes_,'generation_cents',0,'supplier_calls',0,'excludes',jsonb_build_array('retail_price','Worker_DO_logs_invoices','separately_reserved_storage'));
end$function$
;

CREATE OR REPLACE FUNCTION public.property_video_job_admit_photo_motion(p_actor uuid, p_manifest jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.property_video_jobs;q jsonb;checked jsonb;h text;org uuid;billing uuid;prior text;meter jsonb;ent public.plan_entitlements;refused public.property_video_refused_operations;reason text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||(p_manifest->>'operation_id'),79));h:=encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex');
 select*into j from public.property_video_jobs where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if j.id is not null then if j.manifest_sha256<>h or j.manifest->>'source_mode'is distinct from'photo_motion_v1'or not public.property_video_photo_motion_saved_identity(public.property_video_photo_motion_profile(j.manifest),j.quality_identity)then raise exception'RP409: This video operation has different saved inputs';end if;return jsonb_build_object('accepted',true,'job',to_jsonb(public.property_video_job_scope(j.id,p_actor,false)));end if;
 select*into refused from public.property_video_refused_operations where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if refused.operation_id is not null then if refused.manifest_sha256 is distinct from h then raise exception'RP409: This refused video operation has different saved inputs';end if;return jsonb_build_object('accepted',false,'operation_closed',true,'message',refused.message,'operation_id',refused.operation_id);end if;
 begin
 perform 1 from auth.users where id=p_actor and is_anonymous is false for share;if not found then raise exception'RP404: Photo Motion account is unavailable';end if;
 perform 1 from public.profiles where id=p_actor for share;if not found then raise exception'RP404: Photo Motion account is unavailable';end if;
 org:=public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);
 if public.property_video_photo_motion_profile(p_manifest)not in('photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24') then raise exception'RP402: Update Rendprop to use the current Photo motion profile. Your saved videos remain available.';end if;
 billing:=public.library_actor_billing_org(p_actor,org);
 perform pg_advisory_xact_lock(hashtextextended('serving:'||billing,72452));
 perform pg_advisory_xact_lock(hashtextextended('serving:'||org,72452));
 perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||billing,42));
 perform 1 from public.orgs where id=billing and deleted_at is null for update;if not found then raise exception'RP404: Photo Motion billing library is unavailable';end if;
 perform 1 from public.orgs where id=org and deleted_at is null for update;if not found then raise exception'RP404: Photo Motion library is unavailable';end if;
 perform 1 from public.listings where id=(p_manifest->>'listing_id')::uuid and deleted_at is null for share;if not found then raise exception'RP404: Photo Motion property is unavailable';end if;
 perform 1 from public.capture_assets where id in(select(value->>'photo_asset_id')::uuid from jsonb_array_elements(p_manifest->'sources'))order by id for share;
 perform 1 from public.media_provenance where id in(select(value->>'photo_provenance_id')::uuid from jsonb_array_elements(p_manifest->'sources'))order by id for share;
 if p_manifest->>'composition_profile'='photo-motion-v2-opening-cfr24'then perform 1 from public.property_video_aerial_openings where id=(p_manifest#>>'{opening,aerial_job_id}')::uuid for share;if not found then raise exception'RP404: Accepted aerial opening unavailable';end if;end if;
 checked:=public.property_video_photo_motion_manifest(p_actor,p_manifest);q:=public.property_video_photo_motion_quote(p_actor,p_manifest);org:=(checked->>'org_id')::uuid;
 -- Normal exact existing plan/ceiling or funded authority. No new funding gate.
 perform public.property_video_recipe_capacity(p_actor,(p_manifest->>'listing_id')::uuid,jsonb_array_length(p_manifest->'sources'),(q->>'estimated_cents')::numeric);
 perform public.serving_cost_reserve(p_actor,org,'photomotion:'||(p_manifest->>'operation_id'),'photo_motion','cloudflare','container-standard-3',h,(q->>'estimated_cents')::numeric,'container-standard3-20261021');
 select*into ent from public.org_entitlement(public.library_actor_billing_org(p_actor,org));meter:=public.bump_rate_receipt('reelmo:'||public.library_actor_billing_org(p_actor,org),2592000,ent.reels_per_month,jsonb_array_length(p_manifest->'sources'));if meter->'accepted'is distinct from'true'::jsonb then raise exception'RP402: This video exceeds the current plan photo-clip allowance';end if;
 perform 1 from public.listings where id=(p_manifest->>'listing_id')::uuid and deleted_at is null for share;if not found then raise exception'RP404: Property video library is unavailable';end if;
 checked:=public.property_video_photo_motion_manifest(p_actor,p_manifest);prior:=current_setting('rendprop.photo_motion_admission',true);perform set_config('rendprop.photo_motion_admission',h,true);
 j:=public.property_video_job_enqueue(p_actor,p_manifest);perform set_config('rendprop.photo_motion_admission',coalesce(prior,''),true);
 update public.property_video_job_sources set state='photo_motion'where job_id=j.id and state='pending'and attempt_id is null and request_key is null and receipt is null and clip is null and generation_provenance_id is null;
 if(select count(*)from public.property_video_job_sources where job_id=j.id and state='photo_motion')<>j.source_count then raise exception'RP409: Explicit Photo Motion source admission changed';end if;
 return jsonb_build_object('accepted',true,'job',to_jsonb(j),'processing_quote',q);
 exception when others then
  if sqlerrm not like'RP402:%'then raise;end if;reason:=left(sqlerrm,500);
  insert into public.property_video_refused_operations(actor_id,operation_id,listing_id,library_org_id,manifest_sha256,message)
   values(p_actor,(p_manifest->>'operation_id')::uuid,(p_manifest->>'listing_id')::uuid,public.listing_owner_library((p_manifest->>'listing_id')::uuid),h,reason);
  return jsonb_build_object('accepted',false,'operation_closed',true,'operation_id',p_manifest->>'operation_id','message',reason);
 end;
end$function$
;

CREATE OR REPLACE FUNCTION public.property_video_quality_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare expected text;quoted text;consent jsonb;begin
 if TG_OP='INSERT'and new.manifest->>'source_mode'='photo_motion_v1'then
  if current_setting('role',true)is distinct from'service_role'or current_setting('rendprop.photo_motion_admission',true)is distinct from new.manifest_sha256
   or new.kie_test_grant_id is not null then raise exception'RP409: Photo Motion requires its exact normal admission';end if;
  if public.property_video_photo_motion_profile(new.manifest)not in('photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24')then raise exception'RP402: Update Rendprop to use the current Photo motion profile. Your saved videos remain available.';end if;
  perform public.property_video_photo_motion_manifest(new.actor_id,new.manifest);
  new.quality_profile:=public.property_video_photo_motion_profile(new.manifest);new.quality_identity:=public.property_video_photo_motion_identity_for(public.property_video_photo_motion_profile(new.manifest));new.consent_revision:='photo-motion-v1';new.processor_consent:=null;return new;
 end if;
 if TG_OP='UPDATE'then
  if new.quality_profile is distinct from old.quality_profile then raise exception'RP409: A saved video quality profile is immutable';end if;
  if new.quality_identity::text is distinct from old.quality_identity::text then raise exception'RP409: A saved video quality identity is immutable';end if;
  if new.kie_test_grant_id is distinct from old.kie_test_grant_id or new.processor_consent::text is distinct from old.processor_consent::text
   or new.consent_revision is distinct from old.consent_revision then raise exception'RP409: A saved video permission or test scope is immutable';end if;return new;
 end if;
 expected:=public.property_video_quality_profile_for(new.actor_id,new.manifest,nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid);quoted:=nullif(current_setting('rendprop.property_video_quality_profile',true),'');
 if quoted is null then
  if expected<>'legacy'then raise exception'RP409: A new video requires its current quoted quality profile';end if;
  quoted:='legacy';
 end if;
 if quoted not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1')or quoted<>expected then raise exception'RP409: The video quality quote changed before admission';end if;
 new.quality_profile:=quoted;new.quality_identity:=case when quoted='kie-kling3-4k-steady-v1'then public.property_video_prompt_identity(coalesce(nullif(current_setting('rendprop.property_video_prompt_revision',true),''),'v1'))else public.property_video_quality_identity(quoted)end;
 -- Fresh processor permission (required for Kie, persisted, immutable) and the exact
 -- owner quality-test scope that property_video_quality_profile_for just validated.
 consent:=public.property_video_processor_consent_record(quoted,nullif(current_setting('rendprop.property_video_consent',true),'')::jsonb);
 new.consent_revision:=coalesce(consent->>'token',new.consent_revision);new.processor_consent:=consent;
 new.kie_test_grant_id:=case when quoted='kie-kling3-4k-steady-v1'then nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid end;
 if quoted in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then new.deadline:=new.created_at+interval'24 hours';end if;
 if quoted='kie-kling3-4k-steady-v1'then new.deadline:=new.created_at+interval'24 hours';end if;
 return new;
end$function$
;

CREATE OR REPLACE FUNCTION public.property_video_job_claim_photo_motion(p_job uuid, p_worker text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;token uuid;checked jsonb;begin
 if current_setting('role',true)is distinct from'service_role'or p_worker is distinct from'slot-0'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-photo-motion-slot-0',79));
 j:=public.property_video_job_scope(p_job,null,true);perform 1 from public.property_video_jobs where id=p_job for update;j:=public.property_video_job_scope(p_job,null,true);
 if j.quality_profile is distinct from public.property_video_photo_motion_profile(j.manifest)or j.quality_identity is distinct from public.property_video_photo_motion_identity_for(public.property_video_photo_motion_profile(j.manifest))or j.manifest->>'source_mode'is distinct from'photo_motion_v1'then raise exception'RP409: This is not an admitted Photo Motion job';end if;
 checked:=public.property_video_photo_motion_manifest(j.actor_id,j.manifest);
 if exists(select 1 from public.property_video_job_sources where job_id=p_job and(state<>'photo_motion'or attempt_id is not null or request_key is not null or receipt is not null or generation_provenance_id is not null or clip is not null))then raise exception'RP409: Photo Motion cannot use supplier work or fallback state';end if;
 if not exists(select 1 from public.serving_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and request_key='photomotion:'||j.operation_id and stage='photo_motion'and input_sha256=j.manifest_sha256 and state<>'rejected')then raise exception'RP409: Photo Motion processing liability is unavailable';end if;
 -- Root selected one NEW PhotoMotionCPU instance/slot0, oldAI2 unchanged.
 if exists(select 1 from public.property_video_jobs other where other.id<>p_job and other.quality_profile in('photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24')and other.cancelled_at is null and other.deadline>now()and((other.state='composing'and other.compose_until>now())or(other.audio_preflight is null and other.audio_until>now())))then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
 if exists(select 1 from public.property_video_aerial_openings aerial where(aerial.state='preparing_input'and aerial.input_lease_until>now())or(aerial.state='qualifying'and aerial.qualification_lease_until>now()))then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
 if(j.manifest->>'narration_asset_id'is not null or j.manifest->>'narration_result_id'is not null)and j.audio_preflight is null then
  if j.audio_until>now()then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
  if j.audio_attempts>=3 then update public.property_video_jobs set state='failed',message='The saved narration could not be decoded. Your photos are kept.'where id=p_job returning*into j;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  token:=gen_random_uuid();update public.property_video_jobs set state='queued',audio_lease=token,audio_until=now()+interval'5 minutes',audio_attempts=audio_attempts+1 where id=p_job returning*into j;return jsonb_build_object('action','inspect_audio','job',to_jsonb(j));end if;
 if j.compose_until>now()then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
 if j.compose_attempts>=3 then update public.property_video_jobs set state='failed',message='Photo Motion could not be assembled. Your photos are kept.'where id=p_job returning*into j;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
 -- Existing uncertain output bytes cannot be silently abandoned/replaced.
 if exists(select 1 from public.property_video_job_outputs where job_id=p_job)then update public.property_video_jobs set state='needs_reconciliation',message='Saved Photo Motion output needs review. Your photos and files are kept.'where id=p_job returning*into j;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
 token:=gen_random_uuid();update public.property_video_jobs set state='composing',compose_lease=token,compose_until=now()+interval'10 minutes',compose_attempts=compose_attempts+1,output_asset_id=gen_random_uuid(),poster_asset_id=gen_random_uuid(),updated_at=now()where id=p_job returning*into j;
 return jsonb_build_object('action','compose','job',to_jsonb(j),'sources',(select jsonb_agg(to_jsonb(s)order by position)from public.property_video_job_sources s where job_id=p_job));
end$function$
;

CREATE OR REPLACE FUNCTION public.property_video_job_finish_photo_motion(p_job uuid, p_lease uuid, p_facts jsonb)
 RETURNS property_video_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;o public.property_video_job_outputs;s public.property_video_job_sources;sources jsonb;note uuid;checked jsonb;begin
 j:=public.property_video_job_scope(p_job,null,false);
 perform pg_advisory_xact_lock(hashtextextended('serving:'||public.library_actor_billing_org(j.actor_id,j.org_id),72452));
 -- Existing generic serving_cost_finish uses the content-org key. Take it
 -- before any job/reservation row so private-library billing cannot invert locks.
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select * into j from public.property_video_jobs where id=p_job for update;
 if p_facts->'producer_identity'is distinct from j.quality_identity->'producer_identity'
  or not exists(select 1 from public.property_video_photo_motion_observations where job_id=p_job and lease_token=p_lease and phase='compose'and outcome='completed'and producer_identity=j.quality_identity->'producer_identity'and coalesce(to_jsonb(processing_wall_ms),'null'::jsonb)is not distinct from coalesce(p_facts->'processing_wall_ms','null'::jsonb))
 then raise exception'RP409: The actual Photo Motion producer and processing receipt are required';end if;

 if j.state='ready'and exists(select 1 from unnest(array['source_mode','composition_profile','fps','total_frames','source_frames','source_sha256s','source_motions','opening'])k where p_facts->k is distinct from j.result->k)then raise exception'RP409: Finished Photo Motion timeline receipt changed';end if;
 if j.state='ready'then if j.compose_lease is distinct from p_lease or p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or p_facts->>'asset_id'is distinct from j.output_asset_id::text or p_facts->>'poster_asset_id'is distinct from j.poster_asset_id::text or p_facts->>'sha256'is distinct from j.result->>'sha256'or p_facts->>'poster_sha256'is distinct from j.result->>'poster_sha256'then raise exception'RP409: Finished video receipt changed';end if;return j;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,null);
 checked:=public.property_video_photo_motion_manifest(j.actor_id,j.manifest);
 if j.quality_profile is distinct from public.property_video_photo_motion_profile(j.manifest)or j.quality_identity is distinct from public.property_video_photo_motion_identity_for(public.property_video_photo_motion_profile(j.manifest))
  or p_facts->>'source_mode'is distinct from'photo_motion_v1'or p_facts->>'composition_profile'is distinct from j.quality_profile
  or p_facts->'fps'is distinct from'24'::jsonb or p_facts->'total_frames'is distinct from checked->'total_frames'
  or(public.property_video_photo_motion_profile(j.manifest)in('photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24')and p_facts->'source_motions'is distinct from checked->'source_motions')
  or p_facts->'opening'is distinct from checked->'opening'
  or p_facts->'source_frames'is distinct from checked->'source_frames'or p_facts->'source_sha256s'is distinct from checked->'source_sha256s'
  or abs((p_facts->>'duration_s')::numeric-(checked->>'total_frames')::numeric/24)>.001
  or exists(select 1 from public.property_video_job_sources where job_id=p_job and(state<>'photo_motion'or attempt_id is not null or request_key is not null or receipt is not null or clip is not null or generation_provenance_id is not null))then raise exception'RP409: The measured Photo Motion timeline or source identity changed';end if;

 if p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or(p_facts->>'asset_id')::uuid is distinct from j.output_asset_id or(p_facts->>'poster_asset_id')::uuid is distinct from j.poster_asset_id then raise exception'RP409: Composition source identity changed';end if;
 if p_facts->>'width'is null or p_facts->>'height'is null or p_facts->>'duration_s'is null or(j.manifest->>'aspect'='16:9'and((p_facts->>'width')::int<1920 or(p_facts->>'height')::int<1080 or(p_facts->>'width')::bigint*9<>(p_facts->>'height')::bigint*16))
  or(j.manifest->>'aspect'='9:16'and((p_facts->>'width')::int<1080 or(p_facts->>'height')::int<1920 or(p_facts->>'width')::bigint*16<>(p_facts->>'height')::bigint*9))
  or(p_facts->>'duration_s')::numeric<=0 or(p_facts->>'duration_s')::numeric>j.source_count*5+(case when j.quality_profile='photo-motion-v2-opening-cfr24' then (checked#>>'{opening,visible_frames}')::numeric/24 else 0 end)+.1 or(p_facts->>'width')::int>7680 or(p_facts->>'height')::int>7680 then raise exception'RP400: Actual1080 video geometry/duration is required';end if;
 if exists(select 1 from public.property_video_job_sources where job_id=p_job and state<>'photo_motion')or(select count(*)from public.property_video_job_sources where job_id=p_job)<>j.source_count then raise exception'RP409: Every selected photo must finish';end if;
 for o in select * from public.property_video_job_outputs where job_id=p_job and lease_token=p_lease loop
  if o.bytes<>(case when o.kind='video'then(p_facts->>'bytes')::bigint else(p_facts->>'poster_bytes')::bigint end)or o.sha256<>(case when o.kind='video'then p_facts->>'sha256'else p_facts->>'poster_sha256'end)then raise exception'RP409: Retained output identities changed';end if;
  update public.property_video_job_outputs set state='ready',etag=case when o.kind='video'then p_facts->>'etag'else p_facts->>'poster_etag'end where asset_id=o.asset_id;
  update public.capture_assets set uploaded=true where id=o.asset_id;
 end loop;
 if(select count(*)from public.property_video_job_outputs where job_id=p_job and lease_token=p_lease and state='ready'and etag is not null)<>2 then raise exception'RP409: Both measured output receipts are required';end if;
 select jsonb_agg(jsonb_build_object('photo_asset_id',asset_id,'photo_version_id',version_id,'photo_provenance_id',photo_provenance_id,'generation_request_id',null,'generation_provenance_id',null,'motion_kind','photo_motion','source_bound',true,'source_sha256',source->>'sha256','source_bytes',(source->>'bytes')::bigint,'visible_frames',(j.manifest->'sources'->position->>'visible_frames')::integer)||case when j.quality_profile in('photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24')then jsonb_build_object('motion',j.manifest->'sources'->position->>'motion')else'{}'::jsonb end order by position)into sources from public.property_video_job_sources where job_id=p_job;
 update public.property_video_jobs set state='ready',updated_at=now(),result=p_facts||jsonb_build_object('sources',sources,'branding_policy',case when manifest->>'purpose'='listing'then'unbranded'else'social'end,'original_photo_count',(select count(*)from public.property_video_job_sources where job_id=p_job and state='original_photo'),'music',manifest->'music')where id=p_job returning * into j;
 if j.manifest->>'purpose'='listing'then perform public.record_property_video_attestation(j.actor_id,j.listing_id,j.output_asset_id,p_facts->>'etag',(p_facts->>'bytes')::bigint,(p_facts->>'width')::int,(p_facts->>'height')::int,(p_facts->>'duration_s')::numeric);end if;
 perform public.notification_enqueue(j.org_id,j.actor_id,'render_ready',jsonb_build_object('data',jsonb_build_object('listing_id',j.listing_id,'property_video_job_id',j.id,'reel_job_id',j.id)), 'property_video_ready:'||j.id||':'||j.actor_id,null);
 if exists(select 1 from public.serving_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and request_key='photomotion:'||j.operation_id and stage='photo_motion'and state='reserved')then perform public.serving_cost_finish(j.actor_id,j.org_id,'photomotion:'||j.operation_id,'photo_motion','succeeded',null);end if;
 return j;end$function$
;

CREATE OR REPLACE FUNCTION public.property_video_photo_motion_publication(p_actor uuid, p_listing uuid, p_asset uuid, p_poster uuid, p_manifest jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;normalized jsonb;begin
 if p_actor is distinct from auth.uid()and current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_manifest->>'source_mode'is distinct from'photo_motion_v1'or not coalesce(p_manifest->>'composition_profile'in('photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24'),false)or p_manifest->'fps'is distinct from'24'::jsonb then return false;end if;
 select*into j from public.property_video_jobs where actor_id=p_actor and listing_id=p_listing and manifest->>'purpose'=p_manifest->>'purpose'and manifest->>'aspect'=p_manifest->>'aspect'and result->>'branding_policy'=p_manifest->>'branding_policy'and output_asset_id=p_asset and poster_asset_id=p_poster and state='ready'and manifest->>'source_mode'='photo_motion_v1'and quality_profile=public.property_video_photo_motion_profile(p_manifest)and public.property_video_photo_motion_saved_identity(public.property_video_photo_motion_profile(p_manifest),quality_identity);
 if j.id is null or j.result->'producer_identity'is distinct from j.quality_identity->'producer_identity' or j.result->'total_frames'is distinct from p_manifest->'total_frames'or jsonb_typeof(p_manifest->'sources')is distinct from'array'or jsonb_array_length(p_manifest->'sources')<>j.source_count then return false;end if;
 if j.quality_profile='photo-motion-v2-opening-cfr24'theN
  if p_manifest->'opening'is distinct from j.result->'opening'or(public.property_video_aerial_opening_scope(j.manifest->'opening',p_actor,j.org_id,j.library_org_id,p_listing,j.manifest->>'aspect'))->'opening'is distinct from j.result->'opening'then return false;end if;
 elsif p_manifest?'opening'then return false;end if;
 if exists(select 1 from jsonb_array_elements(j.result->'sources')s left join public.capture_assets a on a.id=(s->>'photo_asset_id')::uuid where a.id is null or a.listing_id<>p_listing or not a.uploaded or a.upload_aborted or a.sha256 is distinct from s->>'source_sha256'or a.bytes is distinct from(s->>'source_bytes')::bigint
  or exists(select 1 from public.media_provenance p where p.org_id=j.org_id and p.listing_id=p_listing and p.altered_key=a.storage_key and p.kind in('photo_edit','virtual_stage','declutter')and p.id is distinct from(s->>'photo_provenance_id')::uuid)
  or(s->>'photo_provenance_id'is not null and not exists(select 1 from public.media_provenance p where p.id=(s->>'photo_provenance_id')::uuid and p.org_id=j.org_id and p.listing_id=p_listing and p.qc->'publishable'='true'::jsonb and p.qc->>'action'in('accept','pass')and p.qc->>'output_sha256'=a.sha256 and(not(p.qc?'verdict')or p.qc->>'verdict'='pass'))))then return false;end if;
 if exists(select 1 from jsonb_array_elements(p_manifest->'sources')s where s->>'motion_kind'is distinct from'photo_motion'or s->'source_bound'is distinct from'true'::jsonb or s->>'generation_request_id'is not null or s->>'generation_provenance_id'is not null)then return false;end if;
 select jsonb_agg(jsonb_build_object('photo_asset_id',s->>'photo_asset_id','photo_version_id',s->>'photo_version_id','photo_provenance_id',s->>'photo_provenance_id','generation_request_id',null,'generation_provenance_id',null,'motion_kind','photo_motion','source_bound',true,'source_sha256',s->>'source_sha256','source_bytes',(s->>'source_bytes')::bigint,'visible_frames',(s->>'visible_frames')::integer)||case when j.quality_profile in('photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24')then jsonb_build_object('motion',s->>'motion')else'{}'::jsonb end order by n)into normalized from jsonb_array_elements(p_manifest->'sources')with ordinality a(s,n);
 return normalized=j.result->'sources';end$function$
;

CREATE OR REPLACE FUNCTION public.publish_property_video(p_listing uuid, p_asset uuid, p_manifest jsonb, p_poster uuid, p_key text)
 RETURNS renders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid();ctx jsonb;o uuid;r public.renders;a public.property_video_attestations;c public.property_video_compositions;
 s jsonb;source public.property_video_sources;p public.media_provenance;g public.media_provenance;
 job public.render_jobs;poster jsonb;op public.property_video_publication_ops;revision bigint;ai boolean:=false;staged boolean:=false;edited boolean:=false;disclosure text;
begin
 if actor is null or p_key is null or p_key!~'^photo-video:[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then raise exception 'RP400: A durable publication identity is required';end if;
 ctx:=public.property_owned_upload(actor,p_listing,p_asset,'video');o:=(ctx->>'org_id')::uuid;
 if ctx->>'bucket'<>'renders'then raise exception 'RP400: A property video render upload is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('property_video:'||p_listing::text,42));
 poster:=public.property_owned_upload(actor,p_listing,p_poster,'photo');
 if poster->>'bucket'<>'renders'or lower(split_part(poster->>'content_type',';',1))not in('image/jpeg','image/png','image/webp')then raise exception 'RP400: Upload the saved video first-clip poster';end if;
 select * into a from public.property_video_attestations where asset_id=p_asset and actor_id=actor and listing_id=p_listing
  and etag=ctx->>'etag'and bytes=(ctx->>'bytes')::bigint;
 if a.asset_id is null then raise exception 'RP409: Verify the finished property video before publishing';end if;
 if p_manifest->>'schema'is distinct from '1'or p_manifest->>'purpose'is distinct from 'listing'or p_manifest->>'aspect'is distinct from '16:9'or p_manifest->>'branding_policy'is distinct from 'unbranded'
  or jsonb_typeof(p_manifest->'sources')is distinct from 'array'or jsonb_array_length(p_manifest->'sources')not between 1 and 100
  or octet_length(p_manifest::text)>100000 then raise exception 'RP400: A bounded listing-video source manifest is required';end if;
 if p_manifest?'source_mode'or exists(select 1 from jsonb_array_elements(p_manifest->'sources')pm_source(value)where pm_source.value->>'motion_kind'='photo_motion')then
  if not public.property_video_photo_motion_publication(actor,p_listing,p_asset,p_poster,p_manifest)then raise exception'RP409: Photo Motion publication has no exact finished source/timeline authority';end if;
 end if;
 for s in select value from jsonb_array_elements(p_manifest->'sources')loop
  perform public.property_owned_upload(actor,p_listing,(s->>'photo_asset_id')::uuid,'photo');
  if coalesce(length(s->>'photo_version_id'),0)not between 1 and 200 or coalesce(s->>'motion_kind','')not in('ai','original_photo','photo_motion')then raise exception 'RP400: Invalid video source';end if;
  p:=null;
  if s->>'photo_provenance_id'is not null then
   select * into p from public.media_provenance where id=(s->>'photo_provenance_id')::uuid and org_id=o and listing_id=p_listing
    and kind in('photo_edit','virtual_stage','declutter');
    if p.id is null then raise exception 'RP404: Photo provenance belongs to another property';end if;
    if p.qc->>'publishable'='false'or(p.original_key is not null and not public.studio_presenter_key_access(p_listing,p.original_key))
   or(p.altered_key is not null and not public.studio_presenter_key_access(p_listing,p.altered_key))then raise exception 'RP409: This source photo has not passed its property quality check or was withdrawn';end if;
   perform public.assert_studio_asset_quality((s->>'photo_asset_id')::uuid);
   edited:=true;staged:=staged or p.kind='virtual_stage'or p.edit='stage';
  end if;
  if s->>'motion_kind'='ai'or s->>'generation_request_id'is not null or s->>'generation_provenance_id'is not null then
   select * into source from public.property_video_sources where request_id=s->>'generation_request_id'and actor_id=actor and org_id=o and listing_id=p_listing
    and source_asset_id=(s->>'photo_asset_id')::uuid and generation_provenance_id=(s->>'generation_provenance_id')::uuid
    and source_provenance_id is not distinct from p.id;
   if source.request_id is null then raise exception 'RP409: This clip has no verified property/source identity';end if;
   if s->>'motion_kind'='ai'then
    select * into g from public.media_provenance where id=source.generation_provenance_id and listing_id=p_listing and org_id=o;
    if not exists(select 1 from public.cost_ledger q where q.org_id=o and q.feature='qc'and q.meta->>'kind'='video_drift'
     and q.meta->>'request_id'=source.request_id and q.meta->>'provenance_id'=source.generation_provenance_id::text
     and q.meta->>'source_asset_id'=source.source_asset_id::text and q.meta->>'source_sha256'=source.qc_source_hash
     and q.meta->>'publishable'='true'and q.meta->>'action'='accept')then
     raise exception 'RP409: This AI clip has not passed its property quality check';end if;
    if not exists(select 1 from public.app_video_drift_checks dc join public.app_video_cost_reservations vr on vr.id=dc.reservation_id
     where vr.provider_request_id=source.request_id and dc.actor_id=actor and dc.org_id=o and dc.listing_id=p_listing
      and dc.source_sha256=source.qc_source_hash and dc.state='accept'and dc.result#>>'{drift,action}'='accept'and dc.result#>>'{drift,publishable}'='true')then
     raise exception 'RP409: The clip quality-check journal does not authorize publication';end if;
    ai:=true;
   end if;
  end if;
 end loop;
 if p_manifest->>'composition_profile'='photo-motion-v2-opening-cfr24'theN ai:=true;end if;
 disclosure:=case when ai then 'This property video includes AI-generated movement from still photographs. The movement is simulated; no walkthrough footage of these views was captured.'
  else 'This property video uses movement applied to still photographs; it is not recorded walkthrough footage.'end;
 if p_manifest->>'composition_profile'='photo-motion-v2-opening-cfr24'theN disclosure:=disclosure||' '||(p_manifest#>>'{opening,disclosure}');end if;
 if staged then disclosure:=disclosure||' Some source photos were virtually staged with AI.';
 elsif edited then disclosure:=disclosure||' Some source photos were digitally edited with AI.';end if;
 -- Selection intent is distinct from immutable output identity. A lost reply
 -- retries its operation; a new explicit selection gets a new operation.
 select * into op from public.property_video_publication_ops where operation_key=p_key;
 if op.operation_key is not null then
  select * into c from public.property_video_compositions where id=op.composition_id;
  if row(op.actor_id,op.listing_id,c.asset_id,c.poster_asset_id,c.manifest)is distinct from row(actor,p_listing,p_asset,p_poster,p_manifest)then
   raise exception 'RP409: Publication identity cannot change its video, poster or sources';end if;
  if op.selection_revision is distinct from(select max(selection_revision)from public.property_video_publication_ops where listing_id=p_listing)or not c.selected then
   raise exception 'RP409: publication_superseded: A newer property-video selection has replaced this saved request';end if;
  select * into r from public.renders where listing_id=p_listing and published_at is not null order by published_at desc,created_at desc limit 1;
  if r.id is null then raise exception 'RP409: This publication is no longer live';end if;return r;
 end if;
 select * into c from public.property_video_compositions where asset_id=p_asset;
 if c.id is not null and row(c.actor_id,c.listing_id,c.poster_asset_id,c.manifest)is distinct from row(actor,p_listing,p_poster,p_manifest)then
  raise exception 'RP409: The saved video composition is immutable';end if;
 select * into r from public.renders where listing_id=p_listing and published_at is not null order by published_at desc,created_at desc limit 1;
 if r.id is null then
  job:=public.create_render_job(p_listing,p_asset,'smooth','{}'::jsonb,p_key,'app');
  r:=public.publish_render(job.id,a.duration_s,1.0,'[]'::jsonb,p_poster);
  update public.renders set presentation_kind='photo_video'where id=r.id returning * into r;
 end if;
 -- Existing recorded video, chapters, slug and capture timestamps stay intact.
 update public.property_video_compositions set selected=false where listing_id=p_listing and selected;
 if c.id is null then
  insert into public.property_video_compositions(listing_id,org_id,actor_id,asset_id,poster_asset_id,manifest,disclosure,selected,publication_key)
   values(p_listing,o,actor,p_asset,p_poster,p_manifest,disclosure,true,p_key)returning * into c;
 else update public.property_video_compositions set selected=true where id=c.id;end if;
 select coalesce(max(selection_revision),0)+1 into revision from public.property_video_publication_ops where listing_id=p_listing;
 insert into public.property_video_publication_ops(operation_key,actor_id,listing_id,composition_id,selection_revision)values(p_key,actor,p_listing,c.id,revision);
 return r;
end$function$
;

alter table public.property_video_jobs drop constraint property_video_quality_profile_check;
alter table public.property_video_jobs add constraint property_video_quality_profile_check check(quality_profile in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1','photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24'));
alter table public.property_video_jobs drop constraint property_video_jobs_processor_consent_check;
alter table public.property_video_jobs add constraint property_video_jobs_processor_consent_check check((consent_revision='property-video-jobs-v1'and processor_consent is null)or(consent_revision='property-video-jobs-v2'and jsonb_typeof(processor_consent)='object')or(consent_revision='photo-motion-v1'and processor_consent is null and quality_profile in('photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24')));
revoke all on function public.property_video_photo_motion_profile(jsonb),public.property_video_photo_motion_identity_for(text),public.property_video_photo_motion_saved_identity(text,jsonb)from public,anon,authenticated,service_role;
revoke all on function public.property_video_photo_motion_manifest(uuid,jsonb)from public,anon,authenticated,service_role;
grant execute on function public.property_video_photo_motion_manifest(uuid,jsonb)to service_role;
-- Root activation must append the exact qualified new ordinary-V2 producer to
-- curated historical identity acceptance before enabling the replacement image.
commit;
