-- Prospective, explicit deterministic Photo Motion. No existing job/AI identity,
-- supplier route/grant, fallback guard, entitlement or pricing row is rewritten.
begin;
do $predecessors$begin
 if(select md5(prosrc)from pg_proc where oid='property_video_quality_freeze()'::regprocedure)is distinct from'6eb44abb9f8f954094bcb6777e66d9ca'then raise exception'Review changed Photo Motion predecessor: property_video_quality_freeze()';end if;
 if(select md5(prosrc)from pg_proc where oid='property_video_job_claim(uuid,text)'::regprocedure)is distinct from'59756aa060288e811be3dcddb1625349'then raise exception'Review changed Photo Motion predecessor: property_video_job_claim(uuid,text)';end if;
 if(select md5(prosrc)from pg_proc where oid='property_video_job_finish(uuid,uuid,jsonb)'::regprocedure)is distinct from'0cabbfea06fee69464e4719c16e326cd'then raise exception'Review changed Photo Motion predecessor: property_video_job_finish(uuid,uuid,jsonb)';end if;
 if(select md5(prosrc)from pg_proc where oid='property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)'::regprocedure)is distinct from'e9f7f8c6bb71722f219199612684a902'then raise exception'Review changed Photo Motion predecessor: property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)';end if;
 if(select md5(prosrc)from pg_proc where oid='publish_property_video(uuid,uuid,jsonb,uuid,text)'::regprocedure)is distinct from'79ab3b45c7c2932a4f65e42b5a95086a'then raise exception'Review changed Photo Motion predecessor: publish_property_video(uuid,uuid,jsonb,uuid,text)';end if;
 if(select md5(prosrc)from pg_proc where oid='property_video_job_resume(uuid,uuid,numeric)'::regprocedure)is distinct from'121a22da639a891d762964ae72efb00b'then raise exception'Review changed Photo Motion resume predecessor';end if;
 if(select md5(prosrc)from pg_proc where oid='property_video_job_enqueue(uuid,jsonb)'::regprocedure)is distinct from'27d8811249c2658310c9ea65fce6448b'then raise exception'Review changed Photo Motion enqueue predecessor';end if;
 if(select md5(prosrc)from pg_proc where oid='property_video_job_failure(uuid,uuid,uuid,text,boolean)'::regprocedure)is distinct from'418314743fbe80c6ec6a5ef29b95c0e6'then raise exception'Review changed Photo Motion failure predecessor';end if;
end$predecessors$;
-- A new actual producer is registered by the normal service-owned config path
-- only after its real image/source/controller have been qualified. No placeholder
-- row is seeded. v1 registration is a fixed identity, not a task-selected image.
create or replace function public.property_video_photo_motion_identity()returns jsonb language plpgsql stable security definer set search_path=''as $$
declare c jsonb;p jsonb;begin
 select value into c from public.app_config where key='photo_motion_renderer_v1';p:=c->'producer_identity';
 if jsonb_typeof(c)is distinct from'object'or c->'enabled'is distinct from'true'::jsonb
  or c->>'composition_profile'is distinct from'photo-motion-v1-cfr24'
  or jsonb_typeof(p)is distinct from'object'or (select count(*)from jsonb_object_keys(p))<>3
  or exists(select 1 from jsonb_object_keys(p)k where k not in('image_uri','controller_sha256','renderer_source_sha256'))
  or coalesce(p->>'image_uri','')!~'^registry\.cloudflare\.com/[a-f0-9]{32}/[a-z0-9][a-z0-9._/-]{0,180}@sha256:[a-f0-9]{64}$'
  or coalesce(p->>'controller_sha256','')!~'^[a-f0-9]{64}$'or coalesce(p->>'renderer_source_sha256','')!~'^[a-f0-9]{64}$'
 then raise exception'RP503: Photo Motion is waiting for its verified renderer release';end if;
 return '{"source_mode":"photo_motion_v1","composition_profile":"photo-motion-v1-cfr24","fps":24,"algorithm":"centered-fractional-bicubic-cosine-zoom-1-to-1.02","visible_frames":[48,72,96,120],"transition":"cut","max_audio_attempts":3,"max_compose_attempts":3,"max_processing_wall_ms":1260000,"rate_evidence_sha256":"8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a"}'::jsonb||jsonb_build_object('producer_identity',p);
end$$;
-- This private journal records actual controller lifetime observations. A null
-- clock/producer is uncertainty, never zero. It does not change media/QC state.
create table public.property_video_photo_motion_observations(
 job_id uuid not null references public.property_video_jobs(id)on delete cascade,
 lease_token uuid not null,phase text not null check(phase in('inspect_audio','compose')),
 manifest_sha256 text not null check(manifest_sha256~'^[a-f0-9]{64}$'),
 outcome text not null check(outcome in('completed','failed')),producer_identity jsonb,
 processing_wall_ms bigint check(processing_wall_ms between 0 and 1260000 and processing_wall_ms%10=0),
 estimated_cpu_cents numeric check(estimated_cpu_cents>=0),
 observed_at timestamptz not null default clock_timestamp(),primary key(job_id,phase,lease_token),
 check((processing_wall_ms is null)=(estimated_cpu_cents is null)),
 check(producer_identity is not null or(outcome='failed'and processing_wall_ms is null))
);
alter table public.property_video_photo_motion_observations enable row level security;
revoke all on public.property_video_photo_motion_observations from public,anon,authenticated,service_role;
create or replace function public.property_video_photo_motion_observe(p_job uuid,p_lease uuid,p_manifest text,p_phase text,p_outcome text,p_wall_ms bigint,p_producer jsonb)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.property_video_jobs;o public.property_video_photo_motion_observations;wall bigint:=p_wall_ms;hold public.serving_cost_reservations;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_jobs where id=p_job;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||public.library_actor_billing_org(j.actor_id,j.org_id),72452));
 -- Existing generic serving_cost_finish uses the content-org key. Take it
 -- before any job/reservation row so private-library billing cannot invert locks.
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_jobs where id=p_job for update;
 if j.id is null or j.manifest->>'source_mode'is distinct from'photo_motion_v1'or j.quality_profile is distinct from'photo-motion-v1-cfr24'
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
end$$;
create or replace function public.property_video_photo_motion_manifest(p_actor uuid,p_manifest jsonb)returns jsonb language plpgsql security definer set search_path=''as $$
declare s jsonb;ctx jsonb;refs jsonb:='[]';frames jsonb:='[]';hashes jsonb:='[]';total integer:=0;n integer;org uuid;proof public.media_provenance;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if jsonb_typeof(p_manifest)is distinct from'object'or p_manifest->>'source_mode'is distinct from'photo_motion_v1'
  or exists(select 1 from jsonb_object_keys(p_manifest)k where k not in('source_mode','operation_id','listing_id','expected_org_id','purpose','aspect','sources','narration_result_id','narration_asset_id','narration_words','music','presentation','allow_original_photo_fallback'))
  or p_manifest->'allow_original_photo_fallback'is distinct from'false'::jsonb
  or p_manifest->>'purpose'not in('listing','social')or p_manifest->>'aspect'is distinct from(case when p_manifest->>'purpose'='listing'then'16:9'else'9:16'end)
  or jsonb_typeof(p_manifest->'sources')is distinct from'array'then raise exception'RP400: Use an explicit bounded Photo Motion recipe';end if;
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
   or coalesce(length(s->>'photo_id'),0)not between 1 and 200 or s->>'photo_version_id'is distinct from'asset:'||(s->>'photo_asset_id')or s->>'motion'is distinct from'push_in'
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
  refs:=refs||jsonb_build_array(ctx);frames:=frames||jsonb_build_array((s->>'visible_frames')::integer);hashes:=hashes||jsonb_build_array(ctx->>'sha256');total:=total+(s->>'visible_frames')::integer;
 end loop;
 if exists(select 1 from jsonb_array_elements(coalesce(p_manifest->'narration_words','[]'::jsonb))w where(w->>'end')::numeric>total::numeric/24)then raise exception'RP400: Spoken captions must fit the exact Photo Motion timeline';end if;
 return jsonb_build_object('org_id',org,'sources',refs,'source_frames',frames,'source_sha256s',hashes,'total_frames',total,'fps',24);
end$$;
create or replace function public.property_video_photo_motion_quote(p_actor uuid,p_manifest jsonb)returns jsonb language plpgsql security definer set search_path=''as $$
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
 return jsonb_build_object('quality_profile','photo-motion-v1-cfr24','composition_profile','photo-motion-v1-cfr24','source_mode','photo_motion_v1','estimated_cents',hold,'basis','published-container-upper-bound-20261021','tariff_version','container-standard3-20261021','rate_evidence_sha256','8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a','identity',public.property_video_photo_motion_identity(),'source_count',jsonb_array_length(p_manifest->'sources'),'total_frames',checked->'total_frames','max_task_attempts',attempts,'max_processing_wall_ms',1260000,'source_bytes',bytes_,'generation_cents',0,'supplier_calls',0,'excludes',jsonb_build_array('retail_price','Worker_DO_logs_invoices','separately_reserved_storage'));
end$$;
-- Explicit new state/profile; none of the original fallback authority changes.
alter table public.property_video_job_sources drop constraint property_video_job_sources_state_check;
alter table public.property_video_job_sources add constraint property_video_job_sources_state_check check(state in('pending','dispatching','processing','quality_review','ready','original_photo','failed','ambiguous','photo_motion'));
alter table public.property_video_jobs drop constraint property_video_quality_profile_check;
alter table public.property_video_jobs add constraint property_video_quality_profile_check check(quality_profile in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1','photo-motion-v1-cfr24'));
alter table public.property_video_jobs drop constraint property_video_jobs_consent_revision_check;
alter table public.property_video_jobs add constraint property_video_jobs_consent_revision_check check(consent_revision in('property-video-jobs-v1','property-video-jobs-v2','photo-motion-v1'));
alter table public.property_video_jobs drop constraint property_video_jobs_processor_consent_check;
alter table public.property_video_jobs add constraint property_video_jobs_processor_consent_check check((consent_revision='property-video-jobs-v1'and processor_consent is null)or(consent_revision='property-video-jobs-v2'and jsonb_typeof(processor_consent)='object')or(consent_revision='photo-motion-v1'and processor_consent is null and quality_profile='photo-motion-v1-cfr24'));
CREATE OR REPLACE FUNCTION public.property_video_job_enqueue(p_actor uuid, p_manifest jsonb)
 RETURNS property_video_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;ctx jsonb;s jsonb;i integer:=0;n integer;org uuid;lib uuid;h text;m jsonb:=p_manifest;music public.property_video_music_catalog;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if not exists(select 1 from auth.users where id=p_actor and is_anonymous=false)then raise exception'RP403: A named account is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||(m->>'operation_id'),79));
 select * into j from public.property_video_jobs where actor_id=p_actor and operation_id=(m->>'operation_id')::uuid;
 h:=encode(pg_catalog.sha256(pg_catalog.convert_to(m::text,'UTF8')),'hex');
 if j.id is not null then if j.manifest_sha256<>h then raise exception'RP409: This video operation has different saved inputs';end if;return public.property_video_job_scope(j.id,p_actor,false);end if;
 if exists(select 1 from public.property_video_refused_operations where actor_id=p_actor and operation_id=(m->>'operation_id')::uuid)then raise exception'RP409: This refused operation is permanently closed; use a new operation after reviewing the recipe';end if;
 if not exists(select 1 from public.app_config where key='property_video_jobs'and value->'enabled'='true'::jsonb)then raise exception'RP503: Background video processing is not active yet';end if;
 n:=jsonb_array_length(m->'sources');if n not between 1 and 100 or jsonb_typeof(m->'sources')<>'array'or(m->>'purpose')not in('listing','social')or(m->>'aspect')<>(case when m->>'purpose'='listing'then'16:9'else'9:16'end)then raise exception'RP400: Choose one to100 photos and a supported video purpose';end if;
 org:=public.property_video_actor_org(p_actor,(m->>'expected_org_id')::uuid,(m->>'listing_id')::uuid);
 lib:=public.listing_owner_library((m->>'listing_id')::uuid);
 if exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP409: Account deletion is pending';end if;
 if m->'music'not in('null'::jsonb)and m?'music'then
  select * into music from public.property_video_music_catalog where track_id=m#>>'{music,track_id}'and enabled;
  if music.track_id is null or m#>>'{music,asset_sha256}'<>music.sha256 or m#>>'{music,license_id}'<>music.license_id or m#>>'{music,license_evidence_sha256}'<>music.license_evidence_sha256 then raise exception'RP409: This licensed music track is unavailable';end if;
 end if;
 if m->>'narration_asset_id'is not null and not exists(select 1 from public.property_video_audio_assets where id=(m->>'narration_asset_id')::uuid and actor_id=p_actor and listing_id=(m->>'listing_id')::uuid and state='ready')then raise exception'RP404: Saved narration is unavailable';end if;
 if m->>'narration_result_id'is not null and not exists(select 1 from public.studio_creative_results where id=(m->>'narration_result_id')::uuid and user_id=p_actor and listing_id=(m->>'listing_id')::uuid and kind='voice'and storage_key is not null)then raise exception'RP404: Saved AI narration is unavailable';end if;
 insert into public.property_video_jobs(operation_id,actor_id,listing_id,org_id,library_org_id,manifest,manifest_sha256,source_count,consent_revision)
 values((m->>'operation_id')::uuid,p_actor,(m->>'listing_id')::uuid,org,lib,m,h,n,'property-video-jobs-v1')returning * into j;
 for s in select value from jsonb_array_elements(m->'sources')loop
  ctx:=public.property_photo_reference(p_actor,j.listing_id,(s->>'photo_asset_id')::uuid,(s->>'photo_provenance_id')::uuid);
  if coalesce(ctx->>'content_type','')not in('image/jpeg','image/png','image/webp')or(ctx->>'bytes')::bigint>(case when m->>'source_mode'='photo_motion_v1'then 52428800 else 8388608 end) or coalesce(ctx->>'sha256','')!~'^[a-f0-9]{64}$'then raise exception'RP409: Use complete exact prepared JPEG photo sources';end if;
  insert into public.property_video_job_sources(job_id,position,photo_id,asset_id,version_id,photo_provenance_id,source,motion)
  values(j.id,i,s->>'photo_id',(s->>'photo_asset_id')::uuid,s->>'photo_version_id',(s->>'photo_provenance_id')::uuid,ctx,s->>'motion');i:=i+1;
 end loop;return j;end$function$
;
create or replace function public.property_video_job_admit_photo_motion(p_actor uuid,p_manifest jsonb)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.property_video_jobs;q jsonb;checked jsonb;h text;org uuid;billing uuid;prior text;meter jsonb;ent public.plan_entitlements;refused public.property_video_refused_operations;reason text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||(p_manifest->>'operation_id'),79));h:=encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex');
 select*into j from public.property_video_jobs where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if j.id is not null then if j.manifest_sha256<>h or j.manifest->>'source_mode'is distinct from'photo_motion_v1'or j.quality_identity is distinct from public.property_video_photo_motion_identity()then raise exception'RP409: This video operation has different saved inputs';end if;return jsonb_build_object('accepted',true,'job',to_jsonb(public.property_video_job_scope(j.id,p_actor,false)));end if;
 select*into refused from public.property_video_refused_operations where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if refused.operation_id is not null then if refused.manifest_sha256 is distinct from h then raise exception'RP409: This refused video operation has different saved inputs';end if;return jsonb_build_object('accepted',false,'operation_closed',true,'message',refused.message,'operation_id',refused.operation_id);end if;
 begin
 perform 1 from auth.users where id=p_actor and is_anonymous is false for share;if not found then raise exception'RP404: Photo Motion account is unavailable';end if;
 perform 1 from public.profiles where id=p_actor for share;if not found then raise exception'RP404: Photo Motion account is unavailable';end if;
 org:=public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);
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
end$$;

CREATE OR REPLACE FUNCTION public.property_video_quality_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare expected text;quoted text;consent jsonb;begin
 if TG_OP='INSERT'and new.manifest->>'source_mode'='photo_motion_v1'then
  if current_setting('role',true)is distinct from'service_role'or current_setting('rendprop.photo_motion_admission',true)is distinct from new.manifest_sha256
   or new.kie_test_grant_id is not null then raise exception'RP409: Photo Motion requires its exact normal admission';end if;
  perform public.property_video_photo_motion_manifest(new.actor_id,new.manifest);
  new.quality_profile:='photo-motion-v1-cfr24';new.quality_identity:=public.property_video_photo_motion_identity();new.consent_revision:='photo-motion-v1';new.processor_consent:=null;return new;
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
CREATE OR REPLACE FUNCTION public.property_video_job_claim_before_photo_motion_20261021(p_job uuid, p_worker text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;s public.property_video_job_sources;token uuid;active integer;begin
 if current_setting('role',true)is distinct from'service_role'or p_worker not in('slot-0','slot-1')then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-global-slots',79));j:=public.property_video_job_scope(p_job,null,true);
 perform 1 from public.property_video_jobs where id=p_job for update;
 -- Recheck afterlocking: cancellation cancommitwhilewaiting for this row.
 j:=public.property_video_job_scope(p_job,null,true);
 if(j.manifest->>'narration_asset_id'is not null or j.manifest->>'narration_result_id'is not null)and j.audio_preflight is null then
  if j.audio_until>now()then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
  if j.audio_attempts>=3 then update public.property_video_jobs set state='failed',message='The saved narration could not be decoded. Record or upload a valid audio take before creating a new video.'where id=p_job;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  token:=gen_random_uuid();update public.property_video_jobs set state='queued',audio_lease=token,audio_until=now()+interval'5 minutes',audio_attempts=audio_attempts+1 where id=p_job returning * into j;return jsonb_build_object('action','inspect_audio','job',to_jsonb(j));end if;
 select * into s from public.property_video_job_sources where job_id=p_job and state='processing'and clip is not null and(cpu_attempts<3)and(lease_until is null or lease_until<=now())order by position for update skip locked limit 1;
 if s.job_id is not null then token:=gen_random_uuid();update public.property_video_job_sources set state='quality_review',lease_token=token,lease_until=now()+interval'5 minutes',cpu_attempts=cpu_attempts+1 where job_id=p_job and position=s.position returning * into s;
  return jsonb_build_object('action','extract_frames','job',to_jsonb(j),'source',to_jsonb(s));end if;
 if not exists(select 1 from public.property_video_job_sources where job_id=p_job and state not in('ready','original_photo'))then
  if j.compose_until>now()then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
  if j.compose_attempts>=3 then update public.property_video_jobs set state='failed',message='The video could not be assembled. Your saved photos are safe.'where id=p_job;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  -- Recovered assembly cannot cross an uncertain output or changed source snapshot.
  if j.compose_recoveries=2 and public.property_video_static_repair_release()is distinct from(j.compose_recovery_history->1)-array['operation_id','manifest_sha256','quality_profile','deadline','output_asset_id','poster_asset_id','sources_sha256','prior_compose_lease','prior_compose_attempts','recovered_at','repair_operation']then
   update public.property_video_jobs set state='needs_reconciliation',message='The fixed renderer release needs review. Your finished clips are retained.'where id=p_job returning *into j;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  if j.compose_recoveries>=1 and (public.property_video_compose_snapshot(p_job)is null or public.property_video_compose_snapshot(p_job)is distinct from(j.compose_recovery_history->(j.compose_recoveries-1))-array['prior_compose_lease','prior_compose_attempts','recovered_at','repair_operation','policy','renderer_runtime_sha256','renderer_image_sha256'])then
   update public.property_video_jobs set state='needs_reconciliation',message='Saved assembly inputs or an output reservation need review. Your finished clips are retained.'where id=p_job returning *into j;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  token:=gen_random_uuid();update public.property_video_jobs set state='composing',compose_lease=token,compose_until=now()+interval'10 minutes',compose_attempts=compose_attempts+1,output_asset_id=case when j.compose_recoveries>=1 then j.output_asset_id else gen_random_uuid()end,poster_asset_id=case when j.compose_recoveries>=1 then j.poster_asset_id else gen_random_uuid()end,updated_at=now()where id=p_job returning * into j;
  return jsonb_build_object('action','compose','job',to_jsonb(j),'sources',(select jsonb_agg(to_jsonb(x)order by position)from public.property_video_job_sources x where job_id=p_job));end if;
 select count(*)into active from public.property_video_job_sources src join public.property_video_jobs vj on vj.id=src.job_id where src.state in('dispatching','processing','quality_review','ambiguous')and src.provider_terminal_at is null and vj.deadline>now()and(vj.state<>'cancelled'or src.receipt is not null or exists(select 1 from public.app_video_cost_reservations r where r.actor_id=vj.actor_id and r.org_id=vj.org_id and r.idempotency_key=src.request_key and r.released_at is null));
 if active>=4 or(select count(*)from public.property_video_job_sources where job_id=p_job and state in('dispatching','processing','quality_review','ambiguous'))>=2 then
  null; -- Full supplier capacity must not prevent polling accepted receipts.
 elsif
 coalesce((select count from public.rate_limits where key='aivideo:'||public.library_actor_billing_org(j.actor_id,j.org_id)and window_start+window_seconds*interval'1 second'>now()),0)>=20 then
  null; -- Polling is free; the paid helper still charges the same burst gate.
 else
 select * into s from public.property_video_job_sources where job_id=p_job and state='pending'order by position for update skip locked limit 1;
 if s.job_id is not null then
 token:=gen_random_uuid();update public.property_video_job_sources set state='dispatching',attempt_id=gen_random_uuid(),lease_token=token,lease_until=now()+interval'5 minutes'where job_id=p_job and position=s.position returning * into s;
 update public.property_video_job_sources set request_key='bgvideo:'||attempt_id where job_id=p_job and position=s.position returning * into s;
 update public.property_video_jobs set state='generating',updated_at=now()where id=p_job;
 return jsonb_build_object('action','dispatch','job',to_jsonb(j),'source',to_jsonb(s));
 end if;
 end if;
 -- Give every accepted nonterminal receipt a turn. Record the claim time,
 -- including unsuccessful status attempts, so a slow first source cannot
 -- indefinitely starve a second accepted source. The current lease still
 -- prevents overlapping status calls for one attempt.
 select * into s from public.property_video_job_sources where job_id=p_job and state='processing'and clip is null and(lease_until is null or lease_until<=now())order by provider_status_checked_at nulls first,position for update skip locked limit 1;
 if s.job_id is not null then token:=gen_random_uuid();update public.property_video_job_sources set lease_token=token,lease_until=now()+interval'5 minutes',provider_status_checked_at=clock_timestamp()where job_id=p_job and position=s.position returning * into s;return jsonb_build_object('action','poll','job',to_jsonb(j),'source',to_jsonb(s));end if;
 return jsonb_build_object('action','wait','job',to_jsonb(j));end$function$
;

create or replace function public.property_video_job_claim_photo_motion(p_job uuid,p_worker text)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;token uuid;checked jsonb;begin
 if current_setting('role',true)is distinct from'service_role'or p_worker is distinct from'slot-0'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-photo-motion-slot-0',79));
 j:=public.property_video_job_scope(p_job,null,true);perform 1 from public.property_video_jobs where id=p_job for update;j:=public.property_video_job_scope(p_job,null,true);
 if j.quality_profile is distinct from'photo-motion-v1-cfr24'or j.quality_identity is distinct from public.property_video_photo_motion_identity()or j.manifest->>'source_mode'is distinct from'photo_motion_v1'then raise exception'RP409: This is not an admitted Photo Motion job';end if;
 checked:=public.property_video_photo_motion_manifest(j.actor_id,j.manifest);
 if exists(select 1 from public.property_video_job_sources where job_id=p_job and(state<>'photo_motion'or attempt_id is not null or request_key is not null or receipt is not null or generation_provenance_id is not null or clip is not null))then raise exception'RP409: Photo Motion cannot use supplier work or fallback state';end if;
 if not exists(select 1 from public.serving_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and request_key='photomotion:'||j.operation_id and stage='photo_motion'and input_sha256=j.manifest_sha256 and state<>'rejected')then raise exception'RP409: Photo Motion processing liability is unavailable';end if;
 -- Root selected one NEW PhotoMotionCPU instance/slot0, oldAI2 unchanged.
 if exists(select 1 from public.property_video_jobs other where other.id<>p_job and other.quality_profile='photo-motion-v1-cfr24'and other.cancelled_at is null and other.deadline>now()and((other.state='composing'and other.compose_until>now())or(other.audio_preflight is null and other.audio_until>now())))then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
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
end$$;
create or replace function public.property_video_job_claim(p_job uuid,p_worker text)returns jsonb language plpgsql security definer set search_path=''as $$begin
 if exists(select 1 from public.property_video_jobs where id=p_job and manifest->>'source_mode'='photo_motion_v1')then return public.property_video_job_claim_photo_motion(p_job,p_worker);end if;
 return public.property_video_job_claim_before_photo_motion_20261021(p_job,p_worker);end$$;

CREATE OR REPLACE FUNCTION public.property_video_job_audio_preflight(p_job uuid, p_lease uuid, p_manifest text, p_source_sha text, p_duration numeric, p_streams integer)
 RETURNS property_video_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;max_duration numeric;join_frames integer;output_fps integer;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job for update;
 if j.audio_preflight is not null then if j.audio_lease=p_lease and j.manifest_sha256=p_manifest and j.audio_preflight->>'sha256'=p_source_sha and(j.audio_preflight->>'duration_s')::numeric=p_duration and(j.audio_preflight->>'audio_streams')::integer=p_streams then return j;else raise exception'RP409: Measured narration replay changed';end if;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,null);
 if j.audio_lease is distinct from p_lease or j.manifest_sha256 is distinct from p_manifest or j.audio_source->>'sha256'is distinct from p_source_sha or p_duration is null or p_duration<=0 or p_duration>7200 or p_streams<>1 then raise exception'RP409: Use actual measured frozen narration facts';end if;
 output_fps:=case when j.quality_profile='fal-kling3-4k-steady-v2'then 24 else 30 end;
 if j.quality_profile='kie-kling3-4k-steady-v1'then output_fps:=24;end if;
 join_frames:=case j.manifest#>>'{presentation,transition}'when'dissolve'then case when output_fps=24 then 6 else 8 end when'whip'then case when output_fps=24 then 4 else 5 end else 0 end;max_duration:=j.source_count*5-(j.source_count-1)*join_frames/output_fps::numeric;
 if j.manifest->>'source_mode'='photo_motion_v1'then if not exists(select 1 from public.property_video_photo_motion_observations where job_id=p_job and lease_token=p_lease and phase='inspect_audio'and outcome='completed'and producer_identity=j.quality_identity->'producer_identity')then raise exception'RP409: Measured Photo Motion audio processing receipt is required';end if;output_fps:=24;max_duration:=(public.property_video_photo_motion_manifest(j.actor_id,j.manifest)->>'total_frames')::numeric/24;end if;
 if p_duration>max_duration+(case when j.manifest->>'source_mode'='photo_motion_v1'then 0 else .1 end)then update public.property_video_jobs set state='failed',message=format('Your narration is %s seconds; this video is %s seconds. Record a shorter take or choose more photos. No AI clip was started.',round(p_duration,1),round(max_duration,1)),audio_preflight=jsonb_build_object('sha256',p_source_sha,'duration_s',p_duration,'audio_streams',p_streams,'max_duration_s',max_duration,'within_limit',false),audio_until=null where id=p_job returning * into j;return j;end if;
 update public.property_video_jobs set audio_preflight=jsonb_build_object('within_limit',true,'sha256',p_source_sha,'duration_s',p_duration,'audio_streams',p_streams,'max_duration_s',max_duration),audio_until=null where id=p_job returning * into j;return j;end$function$
;
CREATE OR REPLACE FUNCTION public.property_video_job_finish_before_photo_motion_20261021(p_job uuid, p_lease uuid, p_facts jsonb)
 RETURNS property_video_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;o public.property_video_job_outputs;s public.property_video_job_sources;sources jsonb;note uuid;begin
 j:=public.property_video_job_scope(p_job,null,false);select * into j from public.property_video_jobs where id=p_job for update;
 if j.state='ready'then if j.compose_lease is distinct from p_lease or p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or p_facts->>'asset_id'is distinct from j.output_asset_id::text or p_facts->>'poster_asset_id'is distinct from j.poster_asset_id::text or p_facts->>'sha256'is distinct from j.result->>'sha256'or p_facts->>'poster_sha256'is distinct from j.result->>'poster_sha256'then raise exception'RP409: Finished video receipt changed';end if;return j;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,null);
 if p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or(p_facts->>'asset_id')::uuid is distinct from j.output_asset_id or(p_facts->>'poster_asset_id')::uuid is distinct from j.poster_asset_id then raise exception'RP409: Composition source identity changed';end if;
 if p_facts->>'width'is null or p_facts->>'height'is null or p_facts->>'duration_s'is null or(j.manifest->>'aspect'='16:9'and((p_facts->>'width')::int<1920 or(p_facts->>'height')::int<1080 or(p_facts->>'width')::bigint*9<>(p_facts->>'height')::bigint*16))
  or(j.manifest->>'aspect'='9:16'and((p_facts->>'width')::int<1080 or(p_facts->>'height')::int<1920 or(p_facts->>'width')::bigint*16<>(p_facts->>'height')::bigint*9))
  or(p_facts->>'duration_s')::numeric<=0 or(p_facts->>'duration_s')::numeric>j.source_count*5+.1 or(p_facts->>'width')::int>7680 or(p_facts->>'height')::int>7680 then raise exception'RP400: Actual1080 video geometry/duration is required';end if;
 if exists(select 1 from public.property_video_job_sources where job_id=p_job and state not in('ready','original_photo'))or(select count(*)from public.property_video_job_sources where job_id=p_job)<>j.source_count then raise exception'RP409: Every selected photo must finish';end if;
 for o in select * from public.property_video_job_outputs where job_id=p_job and lease_token=p_lease loop
  if o.bytes<>(case when o.kind='video'then(p_facts->>'bytes')::bigint else(p_facts->>'poster_bytes')::bigint end)or o.sha256<>(case when o.kind='video'then p_facts->>'sha256'else p_facts->>'poster_sha256'end)then raise exception'RP409: Retained output identities changed';end if;
  update public.property_video_job_outputs set state='ready',etag=case when o.kind='video'then p_facts->>'etag'else p_facts->>'poster_etag'end where asset_id=o.asset_id;
  update public.capture_assets set uploaded=true where id=o.asset_id;
 end loop;
 if(select count(*)from public.property_video_job_outputs where job_id=p_job and lease_token=p_lease and state='ready'and etag is not null)<>2 then raise exception'RP409: Both measured output receipts are required';end if;
 select jsonb_agg(jsonb_build_object('photo_asset_id',asset_id,'photo_version_id',version_id,'photo_provenance_id',photo_provenance_id,'generation_request_id',case when state='ready'then receipt->>'request_id'else null end,'generation_provenance_id',case when state='ready'then generation_provenance_id else null end,'motion_kind',case when state='ready'then'ai'else'original_photo'end,'source_bound',state='ready')order by position)into sources from public.property_video_job_sources where job_id=p_job;
 update public.property_video_jobs set state='ready',updated_at=now(),result=p_facts||jsonb_build_object('sources',sources,'branding_policy',case when manifest->>'purpose'='listing'then'unbranded'else'social'end,'original_photo_count',(select count(*)from public.property_video_job_sources where job_id=p_job and state='original_photo'),'music',manifest->'music')where id=p_job returning * into j;
 if j.manifest->>'purpose'='listing'then perform public.record_property_video_attestation(j.actor_id,j.listing_id,j.output_asset_id,p_facts->>'etag',(p_facts->>'bytes')::bigint,(p_facts->>'width')::int,(p_facts->>'height')::int,(p_facts->>'duration_s')::numeric);end if;
 perform public.notification_enqueue(j.org_id,j.actor_id,'render_ready',jsonb_build_object('data',jsonb_build_object('listing_id',j.listing_id,'property_video_job_id',j.id,'reel_job_id',j.id)), 'property_video_ready:'||j.id||':'||j.actor_id,null);
 return j;end$function$
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

 if j.state='ready'and exists(select 1 from unnest(array['source_mode','composition_profile','fps','total_frames','source_frames','source_sha256s'])k where p_facts->k is distinct from j.result->k)then raise exception'RP409: Finished Photo Motion timeline receipt changed';end if;
 if j.state='ready'then if j.compose_lease is distinct from p_lease or p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or p_facts->>'asset_id'is distinct from j.output_asset_id::text or p_facts->>'poster_asset_id'is distinct from j.poster_asset_id::text or p_facts->>'sha256'is distinct from j.result->>'sha256'or p_facts->>'poster_sha256'is distinct from j.result->>'poster_sha256'then raise exception'RP409: Finished video receipt changed';end if;return j;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,null);
 checked:=public.property_video_photo_motion_manifest(j.actor_id,j.manifest);
 if j.quality_profile is distinct from'photo-motion-v1-cfr24'or j.quality_identity is distinct from public.property_video_photo_motion_identity()
  or p_facts->>'source_mode'is distinct from'photo_motion_v1'or p_facts->>'composition_profile'is distinct from'photo-motion-v1-cfr24'
  or p_facts->'fps'is distinct from'24'::jsonb or p_facts->'total_frames'is distinct from checked->'total_frames'
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
 select jsonb_agg(jsonb_build_object('photo_asset_id',asset_id,'photo_version_id',version_id,'photo_provenance_id',photo_provenance_id,'generation_request_id',null,'generation_provenance_id',null,'motion_kind','photo_motion','source_bound',true,'source_sha256',source->>'sha256','source_bytes',(source->>'bytes')::bigint,'visible_frames',(j.manifest->'sources'->position->>'visible_frames')::integer)order by position)into sources from public.property_video_job_sources where job_id=p_job;
 update public.property_video_jobs set state='ready',updated_at=now(),result=p_facts||jsonb_build_object('sources',sources,'branding_policy',case when manifest->>'purpose'='listing'then'unbranded'else'social'end,'original_photo_count',(select count(*)from public.property_video_job_sources where job_id=p_job and state='original_photo'),'music',manifest->'music')where id=p_job returning * into j;
 if j.manifest->>'purpose'='listing'then perform public.record_property_video_attestation(j.actor_id,j.listing_id,j.output_asset_id,p_facts->>'etag',(p_facts->>'bytes')::bigint,(p_facts->>'width')::int,(p_facts->>'height')::int,(p_facts->>'duration_s')::numeric);end if;
 perform public.notification_enqueue(j.org_id,j.actor_id,'render_ready',jsonb_build_object('data',jsonb_build_object('listing_id',j.listing_id,'property_video_job_id',j.id,'reel_job_id',j.id)), 'property_video_ready:'||j.id||':'||j.actor_id,null);
 if exists(select 1 from public.serving_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and request_key='photomotion:'||j.operation_id and stage='photo_motion'and state='reserved')then perform public.serving_cost_finish(j.actor_id,j.org_id,'photomotion:'||j.operation_id,'photo_motion','succeeded',null);end if;
 return j;end$function$
;

create or replace function public.property_video_job_finish(p_job uuid,p_lease uuid,p_facts jsonb)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$begin
 if exists(select 1 from public.property_video_jobs where id=p_job and manifest->>'source_mode'='photo_motion_v1')then return public.property_video_job_finish_photo_motion(p_job,p_lease,p_facts);end if;
 return public.property_video_job_finish_before_photo_motion_20261021(p_job,p_lease,p_facts);end$$;

create or replace function public.property_video_photo_motion_publication(p_actor uuid,p_listing uuid,p_asset uuid,p_poster uuid,p_manifest jsonb)returns boolean language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;normalized jsonb;begin
 if p_actor is distinct from auth.uid()and current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_manifest->>'source_mode'is distinct from'photo_motion_v1'or p_manifest->>'composition_profile'is distinct from'photo-motion-v1-cfr24'or p_manifest->'fps'is distinct from'24'::jsonb then return false;end if;
 select*into j from public.property_video_jobs where actor_id=p_actor and listing_id=p_listing and manifest->>'purpose'=p_manifest->>'purpose'and manifest->>'aspect'=p_manifest->>'aspect'and result->>'branding_policy'=p_manifest->>'branding_policy'and output_asset_id=p_asset and poster_asset_id=p_poster and state='ready'and manifest->>'source_mode'='photo_motion_v1'and quality_profile='photo-motion-v1-cfr24'and quality_identity=public.property_video_photo_motion_identity();
 if j.id is null or j.result->'producer_identity'is distinct from j.quality_identity->'producer_identity' or j.result->'total_frames'is distinct from p_manifest->'total_frames'or jsonb_typeof(p_manifest->'sources')is distinct from'array'or jsonb_array_length(p_manifest->'sources')<>j.source_count then return false;end if;
 if exists(select 1 from jsonb_array_elements(j.result->'sources')s left join public.capture_assets a on a.id=(s->>'photo_asset_id')::uuid where a.id is null or a.listing_id<>p_listing or not a.uploaded or a.upload_aborted or a.sha256 is distinct from s->>'source_sha256'or a.bytes is distinct from(s->>'source_bytes')::bigint
  or exists(select 1 from public.media_provenance p where p.org_id=j.org_id and p.listing_id=p_listing and p.altered_key=a.storage_key and p.kind in('photo_edit','virtual_stage','declutter')and p.id is distinct from(s->>'photo_provenance_id')::uuid)
  or(s->>'photo_provenance_id'is not null and not exists(select 1 from public.media_provenance p where p.id=(s->>'photo_provenance_id')::uuid and p.org_id=j.org_id and p.listing_id=p_listing and p.qc->'publishable'='true'::jsonb and p.qc->>'action'in('accept','pass')and p.qc->>'output_sha256'=a.sha256 and(not(p.qc?'verdict')or p.qc->>'verdict'='pass'))))then return false;end if;
 if exists(select 1 from jsonb_array_elements(p_manifest->'sources')s where s->>'motion_kind'is distinct from'photo_motion'or s->'source_bound'is distinct from'true'::jsonb or s->>'generation_request_id'is not null or s->>'generation_provenance_id'is not null)then return false;end if;
 select jsonb_agg(jsonb_build_object('photo_asset_id',s->>'photo_asset_id','photo_version_id',s->>'photo_version_id','photo_provenance_id',s->>'photo_provenance_id','generation_request_id',null,'generation_provenance_id',null,'motion_kind','photo_motion','source_bound',true,'source_sha256',s->>'source_sha256','source_bytes',(s->>'source_bytes')::bigint,'visible_frames',(s->>'visible_frames')::integer)order by n)into normalized from jsonb_array_elements(p_manifest->'sources')with ordinality a(s,n);
 return normalized=j.result->'sources';end$$;

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
 disclosure:=case when ai then 'This property video includes AI-generated movement from still photographs. The movement is simulated; no walkthrough footage of these views was captured.'
  else 'This property video uses movement applied to still photographs; it is not recorded walkthrough footage.'end;
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

CREATE OR REPLACE FUNCTION public.property_video_job_resume_before_photo_motion_20261021(p_actor uuid, p_job uuid, p_quote numeric)
 RETURNS property_video_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;v jsonb;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select *into j from public.property_video_jobs where id=p_job for update;
 if public.property_video_compose_resume_available(p_job)then
  if p_quote is distinct from 0::numeric then raise exception'RP409: Assembly recovery does not require a new supplier quote';end if;
  perform 1 from public.property_video_job_sources where job_id=p_job order by position for update;
  -- Lock current source assets before the final authority snapshot.
  perform 1 from public.capture_assets where id in(select asset_id from public.property_video_job_sources where job_id=p_job)order by id for share;
  v:=public.property_video_compose_snapshot(p_job);if v is null then raise exception'RP409: Saved assembly inputs or output admission changed';end if;
  update public.property_video_jobs set compose_recoveries=1,compose_recovery_history=jsonb_build_array(v||jsonb_build_object('prior_compose_lease',j.compose_lease,'prior_compose_attempts',j.compose_attempts,'recovered_at',now())),compose_attempts=0,state='generating',message='Resuming video assembly using your finished clips. No clips or quality checks are being regenerated.',updated_at=now()where id=p_job;
  return public.property_video_job_scope(p_job,p_actor,false);
 end if;
 if j.compose_recoveries>=1 and j.state in('generating','composing','ready')then
  if j.state<>'ready'then perform public.property_video_job_scope(p_job,p_actor,true);end if;return j;end if;
 if j.compose_recoveries>=1 and j.state='failed'and not exists(select 1 from public.property_video_job_sources where job_id=p_job and state not in('ready','original_photo'))then
  raise exception'RP409: The explicit assembly recovery is exhausted. Finished clips and receipts are retained for support.';end if;
 return public.property_video_job_resume_before_compose_20261015(p_actor,p_job,p_quote);end$function$
;
create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$begin
 if exists(select 1 from public.property_video_jobs where id=p_job and manifest->>'source_mode'='photo_motion_v1')then raise exception'RP409: Photo Motion has no additional recovery windows; review a new operation after the stopped request';end if;
 return public.property_video_job_resume_before_photo_motion_20261021(p_actor,p_job,p_quote);end$$;
revoke all on function public.property_video_job_resume_before_photo_motion_20261021(uuid,uuid,numeric)from public,anon,authenticated;
grant execute on function public.property_video_job_resume_before_photo_motion_20261021(uuid,uuid,numeric)to service_role;
CREATE OR REPLACE FUNCTION public.property_video_job_failure(p_job uuid, p_lease uuid, p_attempt uuid, p_code text, p_ambiguous boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job for update;if j.id is null then return false;end if;
 if j.cancelled_at is not null or j.deadline<=now()or j.state in('ready','cancelled')then raise exception'RP409: Stopped work cannot accept a failure callback';end if;
 if j.manifest->>'source_mode'='photo_motion_v1'then
  if p_attempt is not null or p_ambiguous is distinct from false or p_code not in('cpu_audio_failed','cpu_compose_failed')or p_code is null
   or not exists(select 1 from public.property_video_photo_motion_observations where job_id=p_job and lease_token=p_lease and phase=case when p_code='cpu_audio_failed'then'inspect_audio'else'compose'end and outcome='failed')
  then raise exception'RP409: Photo Motion requires its closed current CPU failure observation';end if;
  if p_code='cpu_audio_failed'then
   if j.audio_lease is distinct from p_lease or j.audio_preflight is not null or j.audio_attempts not between 1 and 3 then raise exception'RP409: Current Photo Motion audio lease is required';end if;
   update public.property_video_jobs set state=case when audio_attempts>=3 then'failed'else'queued'end,audio_until=now(),message='The saved narration could not be decoded. Your photos and any saved files are kept.'where id=p_job;
  else
   if j.compose_lease is distinct from p_lease or j.compose_attempts not between 1 and 3 or j.state not in('composing','generating','failed')then raise exception'RP409: Current Photo Motion composition lease is required';end if;
   update public.property_video_jobs set state=case when compose_attempts>=3 then'failed'else'generating'end,compose_until=now(),message='Photo Motion could not finish. Your photos and any saved files are kept.'where id=p_job;
  end if;return true;
 end if;

 if p_attempt is null and j.audio_lease=p_lease and j.audio_preflight is null then update public.property_video_jobs set state=case when audio_attempts>=3 then'failed'else'queued'end,audio_until=now(),message='The saved narration could not be decoded. Re-record or upload a valid audio take.'where id=p_job;return true;end if;
 if p_attempt is null then if j.compose_lease is distinct from p_lease or j.state<>'composing'then raise exception'RP409: A current composition lease is required';end if;
  update public.property_video_jobs set state=case when compose_attempts>=3 then'failed'else'generating'end,compose_until=now(),message='Video assembly could not finish. Your finished clips are saved.'where id=p_job;return true;end if;
 select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt and lease_token=p_lease for update;
 if s.job_id is null then raise exception'RP409: A current shot lease is required';end if;
 if p_code='capacity_before_dispatch'and not p_ambiguous then
  if s.receipt is not null or exists(select 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and released_at is null)then raise exception'RP409: Accepted or uncertain supplier work cannot be reset';end if;
  update public.property_video_job_sources set state='failed',last_error=p_code,lease_until=null where job_id=p_job and attempt_id=p_attempt;
  update public.property_video_jobs set state='failed',message='Video paused before the next unpaid clip. Completed clips are retained; resume after processing capacity is available.'where id=p_job;return true;end if;
 if p_code='cpu_extract_failed'and s.state='quality_review'and s.cpu_attempts<3 then update public.property_video_job_sources set state='processing',lease_until=null,last_error=p_code where job_id=p_job and attempt_id=p_attempt;return true;end if;
 -- Only the persisted terminal QC verdict can authorize this substitution.
 if not p_ambiguous and p_code='quality_check_refused'and public.property_video_structural_rejection(p_job,p_attempt)is not null then
  update public.property_video_job_sources set state='original_photo',last_error=p_code,lease_until=null where job_id=p_job and attempt_id=p_attempt;return true;end if;
 -- A known paid clip with an unknown QC result is a quality pause, not an
 -- ambiguous new provider POST. Never erase its immutable receipt or clip.
 update public.property_video_job_sources set state=case when p_ambiguous and s.clip is null then'ambiguous'else'failed'end,last_error=left(p_code,80),lease_until=null where job_id=p_job and attempt_id=p_attempt;
 update public.property_video_jobs set state=case when p_ambiguous and s.clip is null then'needs_reconciliation'else'failed'end,
  message=case when p_ambiguous and s.clip is null then'The provider receipt could not be confirmed. No duplicate generation will be started.'when s.clip is not null then'Video quality review paused. Your paid clip is saved; resume the check after processing is available.'else'A selected photo could not be generated or approved. Your photos and payment receipts are retained.'end,updated_at=now()where id=p_job;return true;end$function$
;
revoke all on function public.property_video_photo_motion_observe(uuid,uuid,text,text,text,bigint,jsonb)from public,anon,authenticated;
grant execute on function public.property_video_photo_motion_observe(uuid,uuid,text,text,text,bigint,jsonb)to service_role;
revoke all on function public.property_video_photo_motion_identity(),public.property_video_photo_motion_manifest(uuid,jsonb),public.property_video_photo_motion_quote(uuid,jsonb),public.property_video_job_admit_photo_motion(uuid,jsonb),public.property_video_job_claim_before_photo_motion_20261021(uuid,text),public.property_video_job_claim_photo_motion(uuid,text),public.property_video_job_finish_before_photo_motion_20261021(uuid,uuid,jsonb),public.property_video_job_finish_photo_motion(uuid,uuid,jsonb),public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.property_video_photo_motion_identity(),public.property_video_photo_motion_manifest(uuid,jsonb),public.property_video_photo_motion_quote(uuid,jsonb),public.property_video_job_admit_photo_motion(uuid,jsonb),public.property_video_job_claim_before_photo_motion_20261021(uuid,text),public.property_video_job_claim_photo_motion(uuid,text),public.property_video_job_finish_before_photo_motion_20261021(uuid,uuid,jsonb),public.property_video_job_finish_photo_motion(uuid,uuid,jsonb),public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb) to service_role;
commit;
