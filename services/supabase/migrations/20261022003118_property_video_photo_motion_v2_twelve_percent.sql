-- Future fixed12% Photo motion. Legacy2% rows/identities/results remain immutable.
begin;
lock table public.property_video_jobs in access exclusive mode;
do $baseline$begin

 if(select md5(prosrc)from pg_proc where oid='property_video_job_admit_photo_motion(uuid,jsonb)'::regprocedure)is distinct from'dbf14a95176fe334877cf7f4aaacd3b7'then raise exception'Photo motion V2 predecessor changed: property_video_job_admit_photo_motion(uuid,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)'::regprocedure)is distinct from'2af2e6a298ecfae7c58d6845b94ab509'then raise exception'Photo motion V2 predecessor changed: property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_claim_before_photo_motion_20261021(uuid,text)'::regprocedure)is distinct from'59756aa060288e811be3dcddb1625349'then raise exception'Photo motion V2 predecessor changed: property_video_job_claim_before_photo_motion_20261021(uuid,text)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_claim_photo_motion(uuid,text)'::regprocedure)is distinct from'6af1b01d6f2df7fbe380a9b7473b00f7'then raise exception'Photo motion V2 predecessor changed: property_video_job_claim_photo_motion(uuid,text)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_claim(uuid,text)'::regprocedure)is distinct from'15f15580322eff4727dee295dfdb7d1b'then raise exception'Photo motion V2 predecessor changed: property_video_job_claim(uuid,text)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_enqueue(uuid,jsonb)'::regprocedure)is distinct from'0e3c2110da601c1ffbd0fe8357fa2499'then raise exception'Photo motion V2 predecessor changed: property_video_job_enqueue(uuid,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_failure(uuid,uuid,uuid,text,boolean)'::regprocedure)is distinct from'53a2d40ae0768110a7e1498a0a0e6d0e'then raise exception'Photo motion V2 predecessor changed: property_video_job_failure(uuid,uuid,uuid,text,boolean)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_finish_before_photo_motion_20261021(uuid,uuid,jsonb)'::regprocedure)is distinct from'0cabbfea06fee69464e4719c16e326cd'then raise exception'Photo motion V2 predecessor changed: property_video_job_finish_before_photo_motion_20261021(uuid,uuid,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_finish_photo_motion(uuid,uuid,jsonb)'::regprocedure)is distinct from'647358fc666136498a4d659b8d76c37e'then raise exception'Photo motion V2 predecessor changed: property_video_job_finish_photo_motion(uuid,uuid,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_finish(uuid,uuid,jsonb)'::regprocedure)is distinct from'5980fd3cf7c108e8fde677892af8be31'then raise exception'Photo motion V2 predecessor changed: property_video_job_finish(uuid,uuid,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_resume_before_photo_motion_20261021(uuid,uuid,numeric)'::regprocedure)is distinct from'121a22da639a891d762964ae72efb00b'then raise exception'Photo motion V2 predecessor changed: property_video_job_resume_before_photo_motion_20261021(uuid,uuid,numeric)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_job_resume(uuid,uuid,numeric)'::regprocedure)is distinct from'51b5d28a8c1e6e08452c015b1e18a188'then raise exception'Photo motion V2 predecessor changed: property_video_job_resume(uuid,uuid,numeric)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_photo_motion_identity()'::regprocedure)is distinct from'93aeb88555e7bad61a1ebf3713b99c42'then raise exception'Photo motion V2 predecessor changed: property_video_photo_motion_identity()';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_photo_motion_manifest(uuid,jsonb)'::regprocedure)is distinct from'25c9b7f6a6b9d9d93de06a05ff2f5aea'then raise exception'Photo motion V2 predecessor changed: property_video_photo_motion_manifest(uuid,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_photo_motion_observe(uuid,uuid,text,text,text,bigint,jsonb)'::regprocedure)is distinct from'550f1622527ee034a1abe89ea5189799'then raise exception'Photo motion V2 predecessor changed: property_video_photo_motion_observe(uuid,uuid,text,text,text,bigint,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure)is distinct from'4055cea62be6970b0b47d07a2734203f'then raise exception'Photo motion V2 predecessor changed: property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_photo_motion_quote(uuid,jsonb)'::regprocedure)is distinct from'1474b9c5cb1e7fb44cd1d54e55c30f77'then raise exception'Photo motion V2 predecessor changed: property_video_photo_motion_quote(uuid,jsonb)';end if;

 if(select md5(prosrc)from pg_proc where oid='property_video_quality_freeze()'::regprocedure)is distinct from'a949e307964d15694b15fdef2e9121d3'then raise exception'Photo motion V2 predecessor changed: property_video_quality_freeze()';end if;

 if(select md5(prosrc)from pg_proc where oid='publish_property_video(uuid,uuid,jsonb,uuid,text)'::regprocedure)is distinct from'ccf5e5f340b045e8f507cbb87032ae46'then raise exception'Photo motion V2 predecessor changed: publish_property_video(uuid,uuid,jsonb,uuid,text)';end if;

end$baseline$;

create function public.property_video_photo_motion_profile(p_manifest jsonb)returns text language plpgsql immutable set search_path=''as $$begin
 if jsonb_typeof(p_manifest)is distinct from'object'or p_manifest->>'source_mode'is distinct from'photo_motion_v1'then raise exception'RP400: Use an explicit Photo motion profile';end if;
 if not(p_manifest?'composition_profile')then return'photo-motion-v1-cfr24';end if;
 if jsonb_typeof(p_manifest->'composition_profile')is distinct from'string'or p_manifest->>'composition_profile'not in('photo-motion-v1-cfr24','photo-motion-v2-cfr24')then raise exception'RP400: Use a supported explicit Photo motion profile';end if;
 return p_manifest->>'composition_profile';end$$;
create function public.property_video_photo_motion_identity_for(p_profile text)returns jsonb language plpgsql stable security definer set search_path=''as $$declare c jsonb;p jsonb;begin
 if p_profile='photo-motion-v1-cfr24'then return public.property_video_photo_motion_identity();end if;
 if p_profile is distinct from'photo-motion-v2-cfr24'then raise exception'RP400: Use a supported explicit Photo motion profile';end if;
 select value into c from public.app_config where key='photo_motion_renderer_v2';p:=c->'producer_identity';
 if jsonb_typeof(c)is distinct from'object'or c->'enabled'is distinct from'true'::jsonb or c->>'composition_profile'is distinct from'photo-motion-v2-cfr24'
 or jsonb_typeof(p)is distinct from'object'or(select count(*)from jsonb_object_keys(p))<>3 or exists(select 1 from jsonb_object_keys(p)k where k not in('image_uri','controller_sha256','renderer_source_sha256'))
 or coalesce(p->>'image_uri','')!~'^registry\.cloudflare\.com/[a-f0-9]{32}/[a-z0-9][a-z0-9._/-]{0,180}@sha256:[a-f0-9]{64}$'
 or coalesce(p->>'controller_sha256','')!~'^[a-f0-9]{64}$'or coalesce(p->>'renderer_source_sha256','')!~'^[a-f0-9]{64}$'
 then raise exception'RP503: Photo motion is waiting for its verified12%% renderer release';end if;
 return '{"source_mode":"photo_motion_v1","composition_profile":"photo-motion-v2-cfr24","fps":24,"algorithm":"fractional-bicubic-cosine-12pct-four-directions","visible_frames":[48,72,96,120],"transition":"cut","max_audio_attempts":3,"max_compose_attempts":3,"max_processing_wall_ms":1260000,"rate_evidence_sha256":"8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a"}'::jsonb||jsonb_build_object('producer_identity',p);
end$$;
revoke all on function public.property_video_photo_motion_profile(jsonb),public.property_video_photo_motion_identity_for(text)from public,anon,authenticated,service_role;

-- Recover the applied saved-identity handoff that preceded aerial composition.
-- The body is the exact predecessor pinned by 20261022223138 and 20261022223142.
create function public.property_video_photo_motion_saved_identity(p_profile text,p_identity jsonb)returns boolean language plpgsql stable security definer set search_path=''as $history$
begin
 if p_profile='photo-motion-v1-cfr24' then
  return p_identity is not distinct from public.property_video_photo_motion_identity_for(p_profile);
 end if;
 if p_profile is distinct from 'photo-motion-v2-cfr24' then return false;end if;
 return p_identity is not distinct from '{"algorithm":"fractional-bicubic-cosine-12pct-four-directions","composition_profile":"photo-motion-v2-cfr24","fps":24,"max_audio_attempts":3,"max_compose_attempts":3,"max_processing_wall_ms":1260000,"producer_identity":{"controller_sha256":"604b92b2c8b6a3ccfd49ac6bec6ff81993e52062c71ba6f910f057d1e2cb3db6","image_uri":"registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:f8bf65d52390bdd4470c36638b141251ec9fe924aa30bb7218fdbcba09a809ec","renderer_source_sha256":"a98b48825fbd819dbf49fd4c2cca4b836cdd81d57bedda5bf2de7774a42d98be"},"rate_evidence_sha256":"8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a","source_mode":"photo_motion_v1","transition":"cut","visible_frames":[48,72,96,120]}'::jsonb
     or p_identity is not distinct from '{"algorithm":"fractional-bicubic-cosine-12pct-four-directions","composition_profile":"photo-motion-v2-cfr24","fps":24,"max_audio_attempts":3,"max_compose_attempts":3,"max_processing_wall_ms":1260000,"producer_identity":{"controller_sha256":"c36d9aba8975401865aacb6c58ad4026c9eff810050957435a53e55035705e64","image_uri":"registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:f8bf65d52390bdd4470c36638b141251ec9fe924aa30bb7218fdbcba09a809ec","renderer_source_sha256":"a98b48825fbd819dbf49fd4c2cca4b836cdd81d57bedda5bf2de7774a42d98be"},"rate_evidence_sha256":"8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a","source_mode":"photo_motion_v1","transition":"cut","visible_frames":[48,72,96,120]}'::jsonb;
end$history$;
revoke all on function public.property_video_photo_motion_saved_identity(text,jsonb)from public,anon,authenticated,service_role;



CREATE OR REPLACE FUNCTION public.property_video_photo_motion_manifest(p_actor uuid, p_manifest jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s jsonb;ctx jsonb;refs jsonb:='[]';frames jsonb:='[]';hashes jsonb:='[]';moves jsonb:='[]';total integer:=0;n integer;org uuid;proof public.media_provenance;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if jsonb_typeof(p_manifest)is distinct from'object'or p_manifest->>'source_mode'is distinct from'photo_motion_v1'
  or exists(select 1 from jsonb_object_keys(p_manifest)k where k not in('source_mode','composition_profile','operation_id','listing_id','expected_org_id','purpose','aspect','sources','narration_result_id','narration_asset_id','narration_words','music','presentation','allow_original_photo_fallback'))
  or p_manifest->'allow_original_photo_fallback'is distinct from'false'::jsonb
  or p_manifest->>'purpose'not in('listing','social')or p_manifest->>'aspect'is distinct from(case when p_manifest->>'purpose'='listing'then'16:9'else'9:16'end)
  or jsonb_typeof(p_manifest->'sources')is distinct from'array'then raise exception'RP400: Use an explicit bounded Photo Motion recipe';end if;
 perform public.property_video_photo_motion_profile(p_manifest);
 n:=jsonb_array_length(p_manifest->'sources');if n not between 1 and 100 then raise exception'RP400: Choose one to100 exact saved photos';end if;
 if p_manifest#>>'{presentation,transition}'is distinct from'cut'or p_manifest#>>'{presentation,shot_caption_style}'not in('off','lowerThird','punchCard','highlightBox')
  or jsonb_typeof(p_manifest#>'{presentation,spoken_captions}')is distinct from'boolean'
  or jsonb_typeof(p_manifest#>'{presentation,shot_labels}')is distinct from'array'or jsonb_array_length(p_manifest#>'{presentation,shot_labels}')<>n
  or(p_manifest->>'purpose'='listing'and coalesce(p_manifest#>'{presentation,title_card}','null')<>'null'::jsonb)then raise exception'RP400: Photo Motion uses Cut and an exact bounded presentation';end if;
 if(select count(distinct value->>'photo_id')from jsonb_array_elements(p_manifest->'sources'))<>n
  or(select count(distinct value->>'photo_asset_id')from jsonb_array_elements(p_manifest->'sources'))<>n then raise exception'RP400: Choose each exact Photo Motion master once';end if;
 org:=public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);
 for s in select value from jsonb_array_elements(p_manifest->'sources')loop
  if jsonb_typeof(s)is distinct from'object'or exists(select 1 from jsonb_object_keys(s)k where k not in('photo_id','photo_asset_id','photo_version_id','photo_provenance_id','motion','visible_frames','source_sha256','source_bytes'))
   or coalesce(length(s->>'photo_id'),0)not between 1 and 200 or s->>'photo_version_id'is distinct from'asset:'||(s->>'photo_asset_id')or(case when public.property_video_photo_motion_profile(p_manifest)='photo-motion-v1-cfr24'then s->>'motion'is distinct from'push_in'else not coalesce(s->>'motion'in('push_in','pull_back','slide_left','slide_right'),false)end)
   or jsonb_typeof(s->'visible_frames')is distinct from'number'or s->>'visible_frames'not in('48','72','96','120')
   or coalesce(s->>'source_sha256','')!~'^[a-f0-9]{64}$'or jsonb_typeof(s->'source_bytes')is distinct from'number'
   or(s->>'source_bytes')::numeric<>trunc((s->>'source_bytes')::numeric)or(s->>'source_bytes')::numeric not between 1 and 52428800 then raise exception'RP400: Freeze each full master and2,3,4or5 seconds';end if;
  ctx:=public.property_photo_reference(p_actor,(p_manifest->>'listing_id')::uuid,(s->>'photo_asset_id')::uuid,(s->>'photo_provenance_id')::uuid);
  if ctx->>'asset_id'is distinct from s->>'photo_asset_id'or ctx->>'sha256'is distinct from s->>'source_sha256'or(ctx->>'bytes')::numeric is distinct from(s->>'source_bytes')::numeric
   or ctx->>'content_type'not in('image/jpeg','image/png','image/webp')or coalesce(ctx->>'etag','')=''then raise exception'RP409: The selected full master changed or is unavailable';end if;
  if(select count(*)from public.media_provenance where org_id=org and listing_id=(p_manifest->>'listing_id')::uuid and altered_key=ctx->>'storage_key'and kind in('photo_edit','virtual_stage','declutter'))>1
   or exists(select 1 from public.media_provenance where org_id=org and listing_id=(p_manifest->>'listing_id')::uuid and altered_key=ctx->>'storage_key'and kind in('photo_edit','virtual_stage','declutter')and id is distinct from(s->>'photo_provenance_id')::uuid)
  then raise exception'RP409: Keep this full master exact saved edit provenance';end if;
  if s->>'photo_provenance_id'is not null then
   select*into proof from public.media_provenance where id=(s->>'photo_provenance_id')::uuid and org_id=org and listing_id=(p_manifest->>'listing_id')::uuid and kind in('photo_edit','virtual_stage','declutter');
   if proof.id is null or proof.qc->'publishable'is distinct from'true'::jsonb or coalesce(proof.qc->>'action','')not in('accept','pass')
    or proof.qc->>'output_sha256'is distinct from ctx->>'sha256'or(proof.qc?'verdict'and proof.qc->>'verdict'is distinct from'pass')
   then raise exception'RP409: Keep the exact quality-approved saved edit master';end if;
   perform public.assert_studio_asset_quality((s->>'photo_asset_id')::uuid);
  end if;
  -- A prepared alias cannot masquerade as its full master even if the caller labels it.
  if exists(select 1 from public.property_video_preparations p where p.asset_id=(s->>'photo_asset_id')::uuid and p.original_asset_id<>p.asset_id)then raise exception'RP409: Choose the full saved master, not its prepared video alias';end if;
  moves:=moves||jsonb_build_array(s->>'motion');refs:=refs||jsonb_build_array(ctx);frames:=frames||jsonb_build_array((s->>'visible_frames')::integer);hashes:=hashes||jsonb_build_array(ctx->>'sha256');total:=total+(s->>'visible_frames')::integer;
 end loop;
 if exists(select 1 from jsonb_array_elements(coalesce(p_manifest->'narration_words','[]'::jsonb))w where(w->>'end')::numeric>total::numeric/24)then raise exception'RP400: Spoken captions must fit the exact Photo Motion timeline';end if;
 return jsonb_build_object('org_id',org,'sources',refs,'source_frames',frames,'source_sha256s',hashes,'total_frames',total,'fps',24)||case when public.property_video_photo_motion_profile(p_manifest)='photo-motion-v2-cfr24'theN jsonb_build_object('source_motions',moves)else'{}'::jsonb end;
end$function$
;

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
 if public.property_video_photo_motion_profile(p_manifest)is distinct from'photo-motion-v2-cfr24' then raise exception'RP402: Update Rendprop to use the current Photo motion profile. Your saved videos remain available.';end if;
 billing:=public.library_actor_billing_org(p_actor,org);
 perform pg_advisory_xact_lock(hashtextextended('serving:'||billing,72452));
 perform pg_advisory_xact_lock(hashtextextended('serving:'||org,72452));
 perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||billing,42));
 perform 1 from public.orgs where id=billing and deleted_at is null for update;if not found then raise exception'RP404: Photo Motion billing library is unavailable';end if;
 perform 1 from public.orgs where id=org and deleted_at is null for update;if not found then raise exception'RP404: Photo Motion library is unavailable';end if;
 perform 1 from public.listings where id=(p_manifest->>'listing_id')::uuid and deleted_at is null for share;if not found then raise exception'RP404: Photo Motion property is unavailable';end if;
 perform 1 from public.capture_assets where id in(select(value->>'photo_asset_id')::uuid from jsonb_array_elements(p_manifest->'sources'))order by id for share;
 perform 1 from public.media_provenance where id in(select(value->>'photo_provenance_id')::uuid from jsonb_array_elements(p_manifest->'sources'))order by id for share;
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
  if public.property_video_photo_motion_profile(new.manifest)is distinct from'photo-motion-v2-cfr24'then raise exception'RP402: Update Rendprop to use the current Photo motion profile. Your saved videos remain available.';end if;
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

CREATE OR REPLACE FUNCTION public.property_video_photo_motion_observe(p_job uuid, p_lease uuid, p_manifest text, p_phase text, p_outcome text, p_wall_ms bigint, p_producer jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.property_video_jobs;o public.property_video_photo_motion_observations;wall bigint:=p_wall_ms;hold public.serving_cost_reservations;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_jobs where id=p_job;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||public.library_actor_billing_org(j.actor_id,j.org_id),72452));
 -- Existing generic serving_cost_finish uses the content-org key. Take it
 -- before any job/reservation row so private-library billing cannot invert locks.
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_jobs where id=p_job for update;
 if j.id is null or j.manifest->>'source_mode'is distinct from'photo_motion_v1'or j.quality_profile is distinct from public.property_video_photo_motion_profile(j.manifest)
  or p_manifest is distinct from j.manifest_sha256 or p_phase not in('inspect_audio','compose')or p_outcome not in('completed','failed')
  or p_phase is null or p_outcome is null or p_lease is null
  or(p_phase='inspect_audio'and(p_lease is distinct from j.audio_lease or j.audio_attempts not between 1 and 3))
  or(p_phase='compose'and(p_lease is distinct from j.compose_lease or j.compose_attempts not between 1 and 3))
  or(p_producer is distinct from j.quality_identity->'producer_identity'and not(p_producer is null and p_outcome='failed'and p_wall_ms is null))
 then raise exception'RP409: Use the exact admitted Photo Motion task observation';end if;
 if wall is not null and(wall<0 or wall>1260000 or wall%10<>0)then wall:=null;end if;
 select*into o from public.property_video_photo_motion_observations where job_id=p_job and phase=p_phase and lease_token=p_lease;
 if o.job_id is not null then
  if o.manifest_sha256 is distinct from p_manifest or o.outcome is distinct from p_outcome or o.processing_wall_ms is distinct from wall or o.producer_identity is distinct from p_producer then raise exception'RP409: A measured processing observation is immutable';end if;
  return jsonb_build_object('recorded',true,'replay',true,'processing_wall_ms',o.processing_wall_ms,'estimated_cpu_cents',o.estimated_cpu_cents);
 end if;
 insert into public.property_video_photo_motion_observations(job_id,lease_token,phase,manifest_sha256,outcome,producer_identity,processing_wall_ms,estimated_cpu_cents)
 values(p_job,p_lease,p_phase,p_manifest,p_outcome,p_producer,wall,case when wall is null then null else ceil(wall::numeric/1000*.006112*10000)/10000 end)returning*into o;
 select*into hold from public.serving_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and request_key='photomotion:'||j.operation_id and stage='photo_motion'for update;
 if hold.id is null or hold.input_sha256 is distinct from j.manifest_sha256 or hold.state='rejected'then raise exception'RP409: Photo Motion processing liability is unavailable';end if;
 if (wall is null or p_outcome='failed')and hold.state='reserved'then perform public.serving_cost_finish(j.actor_id,j.org_id,'photomotion:'||j.operation_id,'photo_motion','uncertain',null);end if;
 return jsonb_build_object('recorded',true,'replay',false,'processing_wall_ms',o.processing_wall_ms,'estimated_cpu_cents',o.estimated_cpu_cents,'basis','published-container-marginal-estimate-not-invoice');
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
 if exists(select 1 from public.property_video_jobs other where other.id<>p_job and other.quality_profile in('photo-motion-v1-cfr24','photo-motion-v2-cfr24')and other.cancelled_at is null and other.deadline>now()and((other.state='composing'and other.compose_until>now())or(other.audio_preflight is null and other.audio_until>now())))then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
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

 if j.state='ready'and exists(select 1 from unnest(array['source_mode','composition_profile','fps','total_frames','source_frames','source_sha256s','source_motions'])k where p_facts->k is distinct from j.result->k)then raise exception'RP409: Finished Photo Motion timeline receipt changed';end if;
 if j.state='ready'then if j.compose_lease is distinct from p_lease or p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or p_facts->>'asset_id'is distinct from j.output_asset_id::text or p_facts->>'poster_asset_id'is distinct from j.poster_asset_id::text or p_facts->>'sha256'is distinct from j.result->>'sha256'or p_facts->>'poster_sha256'is distinct from j.result->>'poster_sha256'then raise exception'RP409: Finished video receipt changed';end if;return j;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,null);
 checked:=public.property_video_photo_motion_manifest(j.actor_id,j.manifest);
 if j.quality_profile is distinct from public.property_video_photo_motion_profile(j.manifest)or j.quality_identity is distinct from public.property_video_photo_motion_identity_for(public.property_video_photo_motion_profile(j.manifest))
  or p_facts->>'source_mode'is distinct from'photo_motion_v1'or p_facts->>'composition_profile'is distinct from j.quality_profile
  or p_facts->'fps'is distinct from'24'::jsonb or p_facts->'total_frames'is distinct from checked->'total_frames'
  or(public.property_video_photo_motion_profile(j.manifest)='photo-motion-v2-cfr24'and p_facts->'source_motions'is distinct from checked->'source_motions')
  or p_facts->'source_frames'is distinct from checked->'source_frames'or p_facts->'source_sha256s'is distinct from checked->'source_sha256s'
  or abs((p_facts->>'duration_s')::numeric-(checked->>'total_frames')::numeric/24)>.001
  or exists(select 1 from public.property_video_job_sources where job_id=p_job and(state<>'photo_motion'or attempt_id is not null or request_key is not null or receipt is not null or clip is not null or generation_provenance_id is not null))then raise exception'RP409: The measured Photo Motion timeline or source identity changed';end if;

 if p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or(p_facts->>'asset_id')::uuid is distinct from j.output_asset_id or(p_facts->>'poster_asset_id')::uuid is distinct from j.poster_asset_id then raise exception'RP409: Composition source identity changed';end if;
 if p_facts->>'width'is null or p_facts->>'height'is null or p_facts->>'duration_s'is null or(j.manifest->>'aspect'='16:9'and((p_facts->>'width')::int<1920 or(p_facts->>'height')::int<1080 or(p_facts->>'width')::bigint*9<>(p_facts->>'height')::bigint*16))
  or(j.manifest->>'aspect'='9:16'and((p_facts->>'width')::int<1080 or(p_facts->>'height')::int<1920 or(p_facts->>'width')::bigint*16<>(p_facts->>'height')::bigint*9))
  or(p_facts->>'duration_s')::numeric<=0 or(p_facts->>'duration_s')::numeric>j.source_count*5+.1 or(p_facts->>'width')::int>7680 or(p_facts->>'height')::int>7680 then raise exception'RP400: Actual1080 video geometry/duration is required';end if;
 if exists(select 1 from public.property_video_job_sources where job_id=p_job and state<>'photo_motion')or(select count(*)from public.property_video_job_sources where job_id=p_job)<>j.source_count then raise exception'RP409: Every selected photo must finish';end if;
 for o in select * from public.property_video_job_outputs where job_id=p_job and lease_token=p_lease loop
  if o.bytes<>(case when o.kind='video'then(p_facts->>'bytes')::bigint else(p_facts->>'poster_bytes')::bigint end)or o.sha256<>(case when o.kind='video'then p_facts->>'sha256'else p_facts->>'poster_sha256'end)then raise exception'RP409: Retained output identities changed';end if;
  update public.property_video_job_outputs set state='ready',etag=case when o.kind='video'then p_facts->>'etag'else p_facts->>'poster_etag'end where asset_id=o.asset_id;
  update public.capture_assets set uploaded=true where id=o.asset_id;
 end loop;
 if(select count(*)from public.property_video_job_outputs where job_id=p_job and lease_token=p_lease and state='ready'and etag is not null)<>2 then raise exception'RP409: Both measured output receipts are required';end if;
 select jsonb_agg(jsonb_build_object('photo_asset_id',asset_id,'photo_version_id',version_id,'photo_provenance_id',photo_provenance_id,'generation_request_id',null,'generation_provenance_id',null,'motion_kind','photo_motion','source_bound',true,'source_sha256',source->>'sha256','source_bytes',(source->>'bytes')::bigint,'visible_frames',(j.manifest->'sources'->position->>'visible_frames')::integer)||case when j.quality_profile='photo-motion-v2-cfr24'then jsonb_build_object('motion',j.manifest->'sources'->position->>'motion')else'{}'::jsonb end order by position)into sources from public.property_video_job_sources where job_id=p_job;
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
 if p_manifest->>'source_mode'is distinct from'photo_motion_v1'or not coalesce(p_manifest->>'composition_profile'in('photo-motion-v1-cfr24','photo-motion-v2-cfr24'),false)or p_manifest->'fps'is distinct from'24'::jsonb then return false;end if;
 select*into j from public.property_video_jobs where actor_id=p_actor and listing_id=p_listing and manifest->>'purpose'=p_manifest->>'purpose'and manifest->>'aspect'=p_manifest->>'aspect'and result->>'branding_policy'=p_manifest->>'branding_policy'and output_asset_id=p_asset and poster_asset_id=p_poster and state='ready'and manifest->>'source_mode'='photo_motion_v1'and quality_profile=public.property_video_photo_motion_profile(p_manifest)and public.property_video_photo_motion_saved_identity(public.property_video_photo_motion_profile(p_manifest),quality_identity);
 if j.id is null or j.result->'producer_identity'is distinct from j.quality_identity->'producer_identity' or j.result->'total_frames'is distinct from p_manifest->'total_frames'or jsonb_typeof(p_manifest->'sources')is distinct from'array'or jsonb_array_length(p_manifest->'sources')<>j.source_count then return false;end if;
 if exists(select 1 from jsonb_array_elements(j.result->'sources')s left join public.capture_assets a on a.id=(s->>'photo_asset_id')::uuid where a.id is null or a.listing_id<>p_listing or not a.uploaded or a.upload_aborted or a.sha256 is distinct from s->>'source_sha256'or a.bytes is distinct from(s->>'source_bytes')::bigint
  or exists(select 1 from public.media_provenance p where p.org_id=j.org_id and p.listing_id=p_listing and p.altered_key=a.storage_key and p.kind in('photo_edit','virtual_stage','declutter')and p.id is distinct from(s->>'photo_provenance_id')::uuid)
  or(s->>'photo_provenance_id'is not null and not exists(select 1 from public.media_provenance p where p.id=(s->>'photo_provenance_id')::uuid and p.org_id=j.org_id and p.listing_id=p_listing and p.qc->'publishable'='true'::jsonb and p.qc->>'action'in('accept','pass')and p.qc->>'output_sha256'=a.sha256 and(not(p.qc?'verdict')or p.qc->>'verdict'='pass'))))then return false;end if;
 if exists(select 1 from jsonb_array_elements(p_manifest->'sources')s where s->>'motion_kind'is distinct from'photo_motion'or s->'source_bound'is distinct from'true'::jsonb or s->>'generation_request_id'is not null or s->>'generation_provenance_id'is not null)then return false;end if;
 select jsonb_agg(jsonb_build_object('photo_asset_id',s->>'photo_asset_id','photo_version_id',s->>'photo_version_id','photo_provenance_id',s->>'photo_provenance_id','generation_request_id',null,'generation_provenance_id',null,'motion_kind','photo_motion','source_bound',true,'source_sha256',s->>'source_sha256','source_bytes',(s->>'source_bytes')::bigint,'visible_frames',(s->>'visible_frames')::integer)||case when j.quality_profile='photo-motion-v2-cfr24'then jsonb_build_object('motion',s->>'motion')else'{}'::jsonb end order by n)into normalized from jsonb_array_elements(p_manifest->'sources')with ordinality a(s,n);
 return normalized=j.result->'sources';end$function$
;

alter table public.property_video_jobs drop constraint property_video_quality_profile_check;
alter table public.property_video_jobs add constraint property_video_quality_profile_check check(quality_profile in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1','photo-motion-v1-cfr24','photo-motion-v2-cfr24'));
alter table public.property_video_jobs drop constraint property_video_jobs_processor_consent_check;
alter table public.property_video_jobs add constraint property_video_jobs_processor_consent_check check((consent_revision='property-video-jobs-v1'and processor_consent is null)or(consent_revision='property-video-jobs-v2'and jsonb_typeof(processor_consent)='object')or(consent_revision='photo-motion-v1'and processor_consent is null and quality_profile in('photo-motion-v1-cfr24','photo-motion-v2-cfr24')));
-- No registry row seeded or rewritten. Root registers verifiedV2 only after no-activeV1 cutover.
commit;
