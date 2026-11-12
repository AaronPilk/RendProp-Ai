-- Durable, private photo video work. Service activation stays explicitly off.
create table if not exists public.property_video_jobs(
 id uuid primary key default gen_random_uuid(),operation_id uuid not null,actor_id uuid not null references auth.users(id)on delete cascade,
 listing_id uuid not null references public.listings(id)on delete cascade,org_id uuid not null references public.orgs(id)on delete cascade,library_org_id uuid not null,
 manifest jsonb not null check(jsonb_typeof(manifest)='object'and pg_column_size(manifest)<=524288),manifest_sha256 text not null check(manifest_sha256~'^[a-f0-9]{64}$'),
 source_count integer not null check(source_count between 1 and 100),state text not null default'queued'check(state in('queued','generating','quality_review','composing','ready','cancelled','failed','needs_reconciliation')),
 consent_revision text not null check(consent_revision='property-video-jobs-v1'),cancelled_at timestamptz,deadline timestamptz not null default(now()+interval'4 hours'),
 audio_lease uuid,audio_until timestamptz,audio_attempts integer not null default 0 check(audio_attempts between 0 and 3),audio_source jsonb,audio_preflight jsonb,compose_lease uuid,compose_until timestamptz,compose_attempts integer not null default 0 check(compose_attempts between 0 and 3),output_asset_id uuid,poster_asset_id uuid,
 result jsonb,message text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(actor_id,operation_id));
create table if not exists public.property_video_refused_operations(
 actor_id uuid not null references auth.users(id)on delete cascade,operation_id uuid not null,listing_id uuid not null references public.listings(id)on delete cascade,library_org_id uuid not null,manifest_sha256 text not null check(manifest_sha256~'^[a-f0-9]{64}$'),message text not null,created_at timestamptz not null default now(),primary key(actor_id,operation_id));
create table if not exists public.property_video_stop_operations(
 actor_id uuid not null references auth.users(id)on delete cascade,operation_id uuid not null,reason text not null check(reason in('ai_consent_revoked','local_data_erasure')),cancelled_count integer not null check(cancelled_count>=0),created_at timestamptz not null default now(),primary key(actor_id,operation_id));
create table if not exists public.property_video_job_sources(
 job_id uuid not null references public.property_video_jobs(id)on delete cascade,position integer not null check(position between 0 and 99),photo_id text not null,
 asset_id uuid not null references public.capture_assets(id),version_id text not null,photo_provenance_id uuid references public.media_provenance(id),source jsonb not null,motion text not null,
 state text not null default'pending'check(state in('pending','dispatching','processing','quality_review','ready','original_photo','failed','ambiguous')),
 attempt_id uuid unique,lease_token uuid,lease_until timestamptz,cpu_attempts integer not null default 0 check(cpu_attempts between 0 and 3),
 provider_terminal_at timestamptz,provider_status_checked_at timestamptz,admission_retries integer not null default 0 check(admission_retries between 0 and 3),non_dispatch_history jsonb not null default'[]'::jsonb,request_key text,receipt jsonb,clip jsonb,generation_provenance_id uuid references public.media_provenance(id),last_error text,
 primary key(job_id,position),unique(job_id,photo_id));
create table if not exists public.property_video_job_outputs(
 asset_id uuid primary key references public.capture_assets(id)on delete cascade,job_id uuid not null references public.property_video_jobs(id)on delete cascade,
 lease_token uuid not null,kind text not null check(kind in('video','photo')),storage_key text not null unique,bytes bigint not null check(bytes>0),sha256 text not null check(sha256~'^[a-f0-9]{64}$'),
 content_type text not null,etag text,state text not null default'reserved'check(state in('reserved','ready')),unique(job_id,lease_token,kind));
create table if not exists public.property_video_audio_assets(
 id uuid primary key default gen_random_uuid(),operation_id uuid not null,actor_id uuid not null references auth.users(id)on delete cascade,listing_id uuid not null references public.listings(id)on delete cascade,
 org_id uuid not null references public.orgs(id)on delete cascade,library_org_id uuid not null,storage_key text not null unique,bytes bigint not null check(bytes between 1 and 20971520),
 sha256 text not null check(sha256~'^[a-f0-9]{64}$'),mime text not null check(mime in('audio/mp4','audio/mpeg')),etag text,state text not null default'reserved'check(state in('reserved','ready')),
 upload_until timestamptz not null default(now()+interval'10 minutes'),created_at timestamptz not null default now(),unique(actor_id,operation_id));
create table if not exists public.property_video_music_catalog(
 track_id text primary key check(track_id in('calm','upbeat','cinematic')),storage_key text not null,bytes bigint not null check(bytes>0),sha256 text not null check(sha256~'^[a-f0-9]{64}$'),
 license_id text not null check(license_id='CC0-1.0'),license_evidence_sha256 text not null check(license_evidence_sha256~'^[a-f0-9]{64}$'),credit text not null,enabled boolean not null default false);
insert into public.property_video_music_catalog(track_id,storage_key,bytes,sha256,license_id,license_evidence_sha256,credit)values
 ('calm','licensed-property-video/calm-9503b0d6.m4a',3196552,'9503b0d6d59cdc76f69f786b6f2fd2fb6f39a747e245e8f02dc358b7fd4dbb36','CC0-1.0','8a5d6e54d255e734a434dbb63abb7fbcf759eb619be6735c123f467d444a9074','First Light Particles — Yoiyami; CC0'),
 ('upbeat','licensed-property-video/upbeat-ce553468.m4a',6863940,'ce55346893354d49746c689b3dde135ec1f3d9299d22ef8ec26b27a022020375','CC0-1.0','fa5b82351abf48b8b0877b1c10ed5163f3243a2cd7781c3b02dcb72ae4d26e27','Scaling Up — Ruskerdax; CC0'),
 ('cinematic','licensed-property-video/cinematic-119eaedb.m4a',1809900,'119eaedb3c58948d6f6b346ec61aac58fa28174658714e06a6a5b8d0ec11bdc8','CC0-1.0','5f83d54c6e0d67b855d772f12615fe668c6678dc551cf1a95f382e96d89e3a45','At Home - Orchestral — Wolfgang_; CC0')on conflict do nothing;
insert into public.app_config(key,value)values('property_video_jobs','{"enabled":false,"runtime_revision":"property-video-worker-v1"}')on conflict do nothing;
alter table public.property_website_products add column if not exists intended_usd_cents integer not null default 2500;
update public.property_website_products set intended_usd_cents=2500 where product_id='com.rendprop.app.website.premium.property';
-- Price is planning metadata; verified localized StoreKit receipt remains authority.
create index if not exists property_video_jobs_pending on public.property_video_jobs(state,created_at)where state not in('ready','cancelled','failed');
do $$declare t text;begin foreach t in array array['property_video_jobs','property_video_refused_operations','property_video_stop_operations','property_video_job_sources','property_video_job_outputs','property_video_audio_assets','property_video_music_catalog']loop
 execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated',t);execute format('grant select,insert,update,delete on public.%I to service_role',t);end loop;end$$;

create or replace function public.property_video_actor_org(p_actor uuid,p_expected uuid,p_listing uuid)returns uuid language plpgsql security definer set search_path=''as $$declare c jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 c:=public.listing_library_scope(p_actor,p_listing);
 if c is null or c->>'can_write'<>'true'or p_expected not in((c->>'org_id')::uuid,(c->>'library_org_id')::uuid)then raise exception'RP404: Property library is unavailable';end if;return(c->>'org_id')::uuid;end$$;

create or replace function public.property_video_job_scope(p_job uuid,p_actor uuid default null,p_active boolean default true)returns public.property_video_jobs
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job;
 if j.id is null or(p_actor is not null and p_actor<>j.actor_id)or not public.listing_content_access(j.actor_id,j.listing_id,true)
  or exists(select 1 from public.deletion_requests where user_id=j.actor_id and status in('pending','processing'))then raise exception'RP404: Video job is unavailable';end if;
 if p_active and(j.state in('ready','cancelled','failed','needs_reconciliation')or j.cancelled_at is not null or j.deadline<=now())then raise exception'RP409: Video job no longer accepts work';end if;
 if p_active or j.state='ready'then for s in select * from public.property_video_job_sources where job_id=j.id loop
  if public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source then raise exception'RP409: A selected photo changed or was withdrawn';end if;
 end loop;end if;return j;end$$;
create or replace function public.property_video_job_enqueue(p_actor uuid,p_manifest jsonb)returns public.property_video_jobs
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;ctx jsonb;s jsonb;i integer:=0;n integer;org uuid;lib uuid;h text;m jsonb:=p_manifest;music public.property_video_music_catalog;
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
  if coalesce(ctx->>'content_type','')not in('image/jpeg','image/png','image/webp')or(ctx->>'bytes')::bigint>8388608 or coalesce(ctx->>'sha256','')!~'^[a-f0-9]{64}$'then raise exception'RP409: Use complete exact prepared JPEG photo sources';end if;
  insert into public.property_video_job_sources(job_id,position,photo_id,asset_id,version_id,photo_provenance_id,source,motion)
  values(j.id,i,s->>'photo_id',(s->>'photo_asset_id')::uuid,s->>'photo_version_id',(s->>'photo_provenance_id')::uuid,ctx,s->>'motion');i:=i+1;
 end loop;return j;end$$;
create or replace function public.property_video_job_cancel(p_actor uuid,p_job uuid)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select * into j from public.property_video_jobs where id=p_job for update;
 if j.state<>'ready'then update public.property_video_jobs set state='cancelled',cancelled_at=now(),updated_at=now()where id=p_job;end if;
 return jsonb_build_object('job_id',p_job,'cancelled',j.state<>'ready');end$$;
-- A stopped actor's old lost-reply operation never cancels later new jobs.
create or replace function public.property_video_job_cancel_all(p_actor uuid,p_operation uuid,p_reason text)returns jsonb
language plpgsql security definer set search_path=''as $$declare o public.property_video_stop_operations;n integer;begin
 if current_setting('role',true)is distinct from'service_role'or p_actor is null then raise insufficient_privilege;end if;
 if p_reason not in('ai_consent_revoked','local_data_erasure')or p_operation is null then raise exception'RP400: Use a saved cancellation identity';end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-stop:'||p_actor||':'||p_operation,79));
 select * into o from public.property_video_stop_operations where actor_id=p_actor and operation_id=p_operation;
 if o.operation_id is not null then if o.reason<>p_reason then raise exception'RP409: Saved cancellation reason changed';end if;return jsonb_build_object('cancelled_count',o.cancelled_count);end if;
 update public.property_video_jobs set state='cancelled',cancelled_at=now(),updated_at=now(),message='Video work was cancelled. Completed media remains private.'where actor_id=p_actor and state not in('ready','cancelled','failed');
 get diagnostics n=row_count;
 insert into public.property_video_stop_operations values(p_actor,p_operation,p_reason,n,now());return jsonb_build_object('cancelled_count',n);end$$;
-- Expired CPU leases may retry the local phase. A lost provider submission
-- cannot become another paid POST; its financial reservation remains intact.
create or replace function public.property_video_job_reconcile_stale()returns integer language plpgsql security definer set search_path=''as $$declare n integer;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 update public.property_video_jobs j set state=case when exists(select 1 from public.property_video_job_sources s where s.job_id=j.id and s.state in('dispatching','ambiguous'))then'needs_reconciliation'else'failed'end,updated_at=now(),message='Background video time limit reached. Saved photos and payment receipts are retained; no duplicate generation will start.'where j.deadline<=now()and j.state in('queued','generating','quality_review','composing');get diagnostics n=row_count;
 update public.property_video_job_sources s set state='ambiguous',last_error='expired_submission_lease',lease_until=null where s.state='dispatching'and s.lease_until<=now();
 update public.property_video_jobs j set state='needs_reconciliation',message='The provider receipt could not be confirmed. No duplicate generation will be started.',updated_at=now()where j.state in('queued','generating','quality_review')and exists(select 1 from public.property_video_job_sources s where s.job_id=j.id and s.state='ambiguous');
 update public.property_video_job_sources s set state='processing',lease_until=null where s.state='quality_review'and s.lease_until<=now()and s.cpu_attempts<3;
 update public.property_video_jobs j set state='failed',message='Video quality review could not finish. Saved photos and receipts remain private.',updated_at=now()where j.state in('generating','quality_review')and exists(select 1 from public.property_video_job_sources s where s.job_id=j.id and s.state='quality_review'and s.lease_until<=now()and s.cpu_attempts>=3);
 return n;end$$;
create or replace function public.property_video_job_claim(p_job uuid,p_worker text)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;token uuid;active integer;begin
 if current_setting('role',true)is distinct from'service_role'or p_worker not in('slot-0','slot-1')then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-global-slots',79));j:=public.property_video_job_scope(p_job,null,true);
 perform 1 from public.property_video_jobs where id=p_job for update;
 -- Recheck afterlocking: cancellation cancommitwhilewaiting for this row.
 j:=public.property_video_job_scope(p_job,null,true);
 if(j.manifest->>'narration_asset_id'is not null or j.manifest->>'narration_result_id'is not null)and j.audio_preflight is null then
  if j.audio_until>now()then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
  if j.audio_attempts>=3 then update public.property_video_jobs set state='failed',message='The saved narration could not be decoded. Record or upload a valid audio take before creating a new video.'where id=p_job;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  token:=gen_random_uuid();update public.property_video_jobs set state='queued',audio_lease=token,audio_until=now()+interval'5 minutes',audio_attempts=audio_attempts+1 where id=p_job returning * into j;return jsonb_build_object('action','inspect_audio','job',to_jsonb(j));end if;
 select * into s from public.property_video_job_sources where job_id=p_job and state='processing'and clip is null and(lease_until is null or lease_until<=now())order by position for update skip locked limit 1;
 if s.job_id is not null then token:=gen_random_uuid();update public.property_video_job_sources set lease_token=token,lease_until=now()+interval'5 minutes'where job_id=p_job and position=s.position returning * into s;return jsonb_build_object('action','poll','job',to_jsonb(j),'source',to_jsonb(s));end if;
 select * into s from public.property_video_job_sources where job_id=p_job and state='processing'and clip is not null and(cpu_attempts<3)and(lease_until is null or lease_until<=now())order by position for update skip locked limit 1;
 if s.job_id is not null then token:=gen_random_uuid();update public.property_video_job_sources set state='quality_review',lease_token=token,lease_until=now()+interval'5 minutes',cpu_attempts=cpu_attempts+1 where job_id=p_job and position=s.position returning * into s;
  return jsonb_build_object('action','extract_frames','job',to_jsonb(j),'source',to_jsonb(s));end if;
 if not exists(select 1 from public.property_video_job_sources where job_id=p_job and state not in('ready','original_photo'))then
  if j.compose_until>now()then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
  if j.compose_attempts>=3 then update public.property_video_jobs set state='failed',message='The video could not be assembled. Your saved photos are safe.'where id=p_job;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  token:=gen_random_uuid();update public.property_video_jobs set state='composing',compose_lease=token,compose_until=now()+interval'10 minutes',compose_attempts=compose_attempts+1,output_asset_id=gen_random_uuid(),poster_asset_id=gen_random_uuid(),updated_at=now()where id=p_job returning * into j;
  return jsonb_build_object('action','compose','job',to_jsonb(j),'sources',(select jsonb_agg(to_jsonb(x)order by position)from public.property_video_job_sources x where job_id=p_job));end if;
 select count(*)into active from public.property_video_job_sources src join public.property_video_jobs vj on vj.id=src.job_id where src.state in('dispatching','processing','quality_review','ambiguous')and src.provider_terminal_at is null and vj.deadline>now()and(vj.state<>'cancelled'or src.receipt is not null or exists(select 1 from public.app_video_cost_reservations r where r.actor_id=vj.actor_id and r.org_id=vj.org_id and r.idempotency_key=src.request_key and r.released_at is null));
 if active>=4 or(select count(*)from public.property_video_job_sources where job_id=p_job and state in('dispatching','processing','quality_review','ambiguous'))>=2 then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
 -- The existing20-per5min public burst gate is still charged by the actual
 -- paid helper. Waiting here prevents a long recipe becoming failed clips.
 if coalesce((select count from public.rate_limits where key='aivideo:'||public.library_actor_billing_org(j.actor_id,j.org_id)and window_start+window_seconds*interval'1 second'>now()),0)>=20 then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
 select * into s from public.property_video_job_sources where job_id=p_job and state='pending'order by position for update skip locked limit 1;
 if s.job_id is null then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
 token:=gen_random_uuid();update public.property_video_job_sources set state='dispatching',attempt_id=gen_random_uuid(),lease_token=token,lease_until=now()+interval'5 minutes'where job_id=p_job and position=s.position returning * into s;
 update public.property_video_job_sources set request_key='bgvideo:'||attempt_id where job_id=p_job and position=s.position returning * into s;
 update public.property_video_jobs set state='generating',updated_at=now()where id=p_job;
 return jsonb_build_object('action','dispatch','job',to_jsonb(j),'source',to_jsonb(s));end$$;
create or replace function public.property_video_job_worker_scope(p_job uuid,p_lease uuid,p_attempt uuid default null)returns jsonb
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 j:=public.property_video_job_scope(p_job,null,true);
 if p_attempt is not null then select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt and lease_token=p_lease and lease_until>now();
  if s.job_id is null or s.state not in('dispatching','processing','quality_review')then raise exception'RP409: Video attempt lease was superseded';end if;return jsonb_build_object('job',to_jsonb(j),'source',to_jsonb(s));
 end if;
 if j.audio_lease=p_lease and j.audio_until>now()and j.audio_preflight is null then return jsonb_build_object('action','inspect_audio','job',to_jsonb(j));end if;
 if j.state<>'composing'or j.compose_lease is distinct from p_lease or j.compose_until<=now()then raise exception'RP409: Video composition lease was superseded';end if;
 return jsonb_build_object('job',to_jsonb(j),'sources',(select jsonb_agg(to_jsonb(src)order by position)from public.property_video_job_sources src where job_id=p_job));end$$;
create or replace function public.property_video_job_heartbeat(p_job uuid,p_lease uuid,p_attempt uuid default null)returns boolean
language plpgsql security definer set search_path=''as $$begin
 perform public.property_video_job_worker_scope(p_job,p_lease,p_attempt);
 if p_attempt is null then if exists(select 1 from public.property_video_jobs where id=p_job and audio_lease=p_lease and audio_preflight is null)then update public.property_video_jobs set audio_until=now()+interval'5 minutes'where id=p_job;else update public.property_video_jobs set compose_until=now()+interval'10 minutes'where id=p_job;end if;else update public.property_video_job_sources set lease_until=now()+interval'5 minutes'where job_id=p_job and attempt_id=p_attempt;end if;return true;end$$;
create or replace function public.property_video_job_poll_release(p_job uuid,p_lease uuid,p_attempt uuid)returns boolean language plpgsql security definer set search_path=''as $$begin
 perform public.property_video_job_worker_scope(p_job,p_lease,p_attempt);update public.property_video_job_sources set lease_until=null where job_id=p_job and attempt_id=p_attempt and state='processing';return true;end$$;

create or replace function public.property_video_job_provenance(p_job uuid,p_attempt uuid,p_request text,p_model text)returns public.media_provenance
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;r public.app_video_cost_reservations;p public.media_provenance;begin
 j:=public.property_video_job_scope(p_job,null,true);select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 select * into r from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and provider_request_id=p_request and model=p_model and settled_at is not null and released_at is null;
 if s.job_id is null or r.id is null then raise exception'RP409: Accepted video payment is unavailable';end if;
 if s.generation_provenance_id is not null then select * into p from public.media_provenance where id=s.generation_provenance_id;return p;end if;
 insert into public.media_provenance(org_id,listing_id,kind,model_id,edit,style,label,disclosure)values(j.org_id,j.listing_id,'reel',r.model,'reel',s.motion,'Property video shot',public.provenance_disclosure('reel','reel'))returning * into p;
 update public.property_video_job_sources set generation_provenance_id=p.id where job_id=p_job and attempt_id=p_attempt;return p;end$$;
create or replace function public.property_video_job_receipt(p_job uuid,p_attempt uuid,p_receipt jsonb)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job;select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 if j.id is null or s.job_id is null or pg_column_size(p_receipt)>32768 or coalesce(p_receipt->>'request_id','')=''then raise exception'RP400: A saved accepted receipt is required';end if;
 if s.receipt is not null and s.receipt is distinct from p_receipt then raise exception'RP409: Provider receipt is immutable';end if;
 if not exists(select 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and (provider_request_id is null or provider_request_id=p_receipt->>'request_id')and model=p_receipt->>'model_id'and feature='reel'and released_at is null)then raise exception'RP409: Accepted payment reservation is unavailable';end if;
 update public.property_video_job_sources set receipt=p_receipt,state=case when j.cancelled_at is null then'processing'else state end,lease_until=null where job_id=p_job and attempt_id=p_attempt;return true;end$$;
create or replace function public.property_video_job_clip(p_job uuid,p_attempt uuid,p_clip jsonb)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 j:=public.property_video_job_scope(p_job,null,true);select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 if s.receipt is null or s.state<>'processing'or pg_column_size(p_clip)>32768 or p_clip->>'storage_key'is null then raise exception'RP409: Owned accepted clip is unavailable';end if;
 if s.clip is not null and s.clip is distinct from p_clip then raise exception'RP409: Retained clip identity is immutable';end if;
 update public.property_video_job_sources set clip=p_clip where job_id=p_job and attempt_id=p_attempt;return true;end$$;
create or replace function public.property_video_job_qc(p_job uuid,p_lease uuid,p_attempt uuid)returns boolean
language plpgsql security definer set search_path=''as $$declare ctx jsonb;j public.property_video_jobs;s public.property_video_job_sources;p public.media_provenance;bound public.property_video_sources;begin
 ctx:=public.property_video_job_worker_scope(p_job,p_lease,p_attempt);select * into j from public.property_video_jobs where id=p_job;select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 select * into p from public.media_provenance where id=s.generation_provenance_id and listing_id=j.listing_id and org_id=j.org_id and qc->>'publishable'='true';
 select * into bound from public.property_video_sources where request_id=s.receipt->>'request_id'and actor_id=j.actor_id and listing_id=j.listing_id and source_asset_id=s.asset_id and generation_provenance_id=p.id;
 if p.id is null or bound.request_id is null or p.qc->>'request_id'is distinct from bound.request_id or p.qc->>'source_sha256'is distinct from bound.qc_source_hash
  or not exists(select 1 from public.cost_ledger where org_id=j.org_id and feature='qc'and meta->>'request_id'=bound.request_id and meta->>'publishable'='true'and total_cents>0)then raise exception'RP409: This clip has no passing paid source quality receipt';end if;
 update public.property_video_job_sources set state='ready',lease_until=null where job_id=p_job and attempt_id=p_attempt;return true;end$$;
create or replace function public.property_video_job_failure(p_job uuid,p_lease uuid,p_attempt uuid,p_code text,p_ambiguous boolean default false)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job for update;if j.id is null then return false;end if;
 if p_attempt is null and j.audio_lease=p_lease and j.audio_preflight is null then update public.property_video_jobs set state=case when audio_attempts>=3 then'failed'else'queued'end,audio_until=now(),message='The saved narration could not be decoded. Re-record or upload a valid audio take.'where id=p_job;return true;end if;
 if p_attempt is null then if j.compose_lease is distinct from p_lease or j.state<>'composing'then raise exception'RP409: A current composition lease is required';end if;
  update public.property_video_jobs set state=case when compose_attempts>=3 then'failed'else'generating'end,compose_until=now(),message='Video assembly was interrupted. Saved work will resume.'where id=p_job;return true;end if;
 select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt and lease_token=p_lease for update;
 if s.job_id is null then raise exception'RP409: A current shot lease is required';end if;
 if p_code='capacity_before_dispatch'and not p_ambiguous then
  if s.receipt is not null or exists(select 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and released_at is null)then raise exception'RP409: Accepted or uncertain supplier work cannot be reset';end if;
  update public.property_video_job_sources set state='failed',last_error=p_code,lease_until=null where job_id=p_job and attempt_id=p_attempt;
  update public.property_video_jobs set state='failed',message='Video paused before the next unpaid clip. Completed clips are retained; resume after processing capacity is available.'where id=p_job;return true;end if;
 if p_code='cpu_extract_failed'and s.state='quality_review'and s.cpu_attempts<3 then update public.property_video_job_sources set state='processing',lease_until=null,last_error=p_code where job_id=p_job and attempt_id=p_attempt;return true;end if;
 update public.property_video_job_sources set state=case when p_ambiguous then'ambiguous'when coalesce((j.manifest->>'allow_original_photo_fallback')::boolean,false)and not p_ambiguous then'original_photo'else'failed'end,last_error=left(p_code,80),lease_until=null where job_id=p_job and attempt_id=p_attempt;
 if p_ambiguous or not coalesce((j.manifest->>'allow_original_photo_fallback')::boolean,false)then update public.property_video_jobs set state=case when p_ambiguous then'needs_reconciliation'else'failed'end,message=case when p_ambiguous then'The provider receipt could not be confirmed. No duplicate generation will be started.'else'A selected photo could not be generated or approved. Your photos are safe.'end where id=p_job;end if;return true;end$$;
-- Client upload receipt authority is preserved as a separate immutable function.
do $$begin if to_regprocedure('public.property_native_owned_upload(uuid,uuid,uuid,text)')is null then alter function public.property_owned_upload(uuid,uuid,uuid,text)rename to property_native_owned_upload;end if;end$$;
create or replace function public.property_owned_upload(p_actor uuid,p_listing uuid,p_asset uuid,p_kind text)returns jsonb
language plpgsql security definer set search_path=''as $$declare o public.property_video_job_outputs;j public.property_video_jobs;a public.capture_assets;begin
 select * into o from public.property_video_job_outputs where asset_id=p_asset and state='ready';
 if o.asset_id is null then return public.property_native_owned_upload(p_actor,p_listing,p_asset,p_kind);end if;
 if current_setting('role',true)is distinct from'service_role'and auth.uid()is distinct from p_actor then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=o.job_id and actor_id=p_actor;
 if j.id is null or not public.listing_content_access(p_actor,j.listing_id,true)or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP404: Verified server video is unavailable';end if;
 if exists(select 1 from public.property_video_job_sources s where s.job_id=j.id and(public.property_owned_upload(p_actor,j.listing_id,s.asset_id,'photo')is distinct from s.source or(s.photo_provenance_id is not null and not exists(select 1 from public.media_provenance p where p.id=s.photo_provenance_id and p.listing_id=j.listing_id and p.qc->>'publishable'is distinct from'false'and(p.original_key is null or public.studio_presenter_key_access(j.listing_id,p.original_key))and(p.altered_key is null or public.studio_presenter_key_access(j.listing_id,p.altered_key))))))then raise exception'RP409: A selected source photo was changed or withdrawn';end if;select * into a from public.capture_assets where id=p_asset and listing_id=p_listing;
 if j.listing_id is distinct from p_listing or j.state<>'ready'or o.kind is distinct from p_kind or a.id is null or not a.uploaded or a.upload_aborted or a.sha256 is distinct from o.sha256 then raise exception'RP409: Verified server video output is unavailable';end if;
 return jsonb_build_object('actor_id',p_actor,'org_id',j.org_id,'listing_id',p_listing,'asset_id',a.id,'bucket','renders','storage_key',o.storage_key,'bytes',o.bytes,'etag',o.etag,'content_type',o.content_type,'sha256',o.sha256);end$$;
create or replace function public.property_video_job_outputs_reserve(p_job uuid,p_lease uuid,p_bytes bigint,p_sha text,p_poster_bytes bigint,p_poster_sha text)returns jsonb
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;k text;pk text;o public.property_video_job_outputs;begin
 perform public.property_video_job_worker_scope(p_job,p_lease,null);select * into j from public.property_video_jobs where id=p_job for update;
 if p_bytes not between 1 and 1073741824 or p_poster_bytes not between 1 and 10485760 or coalesce(p_sha,'')!~'^[a-f0-9]{64}$'or coalesce(p_poster_sha,'')!~'^[a-f0-9]{64}$'then raise exception'RP400: Exact measured output identities are required';end if;
 k:='renders/'||j.org_id||'/'||j.listing_id||'/background/'||j.id||'/'||p_lease||'/master.mp4';pk:='renders/'||j.org_id||'/'||j.listing_id||'/background/'||j.id||'/'||p_lease||'/first-clip.jpg';
 perform public.media_storage_reserve(j.org_id,'renders',k,p_bytes);perform public.media_storage_reserve(j.org_id,'renders',pk,p_poster_bytes);
 insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type,content_type_declared)values
 (j.output_asset_id,j.listing_id,'video','renders',k,p_bytes,p_sha,false,2,'video/mp4',true),(j.poster_asset_id,j.listing_id,'photo','renders',pk,p_poster_bytes,p_poster_sha,false,2,'image/jpeg',true)on conflict do nothing;
 insert into public.property_video_job_outputs(asset_id,job_id,lease_token,kind,storage_key,bytes,sha256,content_type)values
 (j.output_asset_id,j.id,p_lease,'video',k,p_bytes,p_sha,'video/mp4'),(j.poster_asset_id,j.id,p_lease,'photo',pk,p_poster_bytes,p_poster_sha,'image/jpeg')on conflict do nothing;
 select * into o from public.property_video_job_outputs where asset_id=j.output_asset_id;
 if row(o.bytes,o.sha256,o.lease_token)is distinct from row(p_bytes,p_sha,p_lease)or not exists(select 1 from public.property_video_job_outputs where asset_id=j.poster_asset_id and bytes=p_poster_bytes and sha256=p_poster_sha and lease_token=p_lease)then raise exception'RP409: Output bytes are immutable';end if;
 return jsonb_build_object('asset_id',j.output_asset_id,'key',k,'poster_asset_id',j.poster_asset_id,'poster_key',pk);end$$;
create or replace function public.property_video_job_finish(p_job uuid,p_lease uuid,p_facts jsonb)returns public.property_video_jobs
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;o public.property_video_job_outputs;s public.property_video_job_sources;sources jsonb;note uuid;begin
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
 return j;end$$;
-- Own-recorded narration uses a real audio registry; never masquerades as video.
create or replace function public.property_video_audio_prepare(p_actor uuid,p_body jsonb)returns public.property_video_audio_assets
language plpgsql security definer set search_path=''as $$declare a public.property_video_audio_assets;org uuid;lib uuid;k text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 org:=public.property_video_actor_org(p_actor,(p_body->>'expected_org_id')::uuid,(p_body->>'listing_id')::uuid);lib:=public.listing_owner_library((p_body->>'listing_id')::uuid);
 perform pg_advisory_xact_lock(hashtextextended('property-video-audio:'||p_actor||':'||(p_body->>'operation_id'),79));
 select * into a from public.property_video_audio_assets where actor_id=p_actor and operation_id=(p_body->>'operation_id')::uuid;
 if a.id is not null then if row(a.listing_id,a.bytes,a.sha256,a.mime)is distinct from row((p_body->>'listing_id')::uuid,(p_body->>'bytes')::bigint,p_body->>'sha256',p_body->>'mime')then raise exception'RP409: Narration upload identity changed';end if;if a.state<>'ready'then perform public.media_storage_reserve(org,'renders',a.storage_key,a.bytes);update public.property_video_audio_assets set upload_until=now()+interval'10 minutes'where id=a.id returning * into a;end if;return a;end if;
 k:='presenter-private/'||org||'/'||p_actor||'/'||(p_body->>'listing_id')||'/narration/'||(p_body->>'operation_id')||case when p_body->>'mime'='audio/mp4'then'.m4a'else'.mp3'end;
 perform public.media_storage_reserve(org,'renders',k,(p_body->>'bytes')::bigint);
 perform public.register_private_ai_output(p_actor,org,(p_body->>'listing_id')::uuid,'renders',k,(p_body->>'bytes')::bigint);
 insert into public.property_video_audio_assets(operation_id,actor_id,listing_id,org_id,library_org_id,storage_key,bytes,sha256,mime)values((p_body->>'operation_id')::uuid,p_actor,(p_body->>'listing_id')::uuid,org,lib,k,(p_body->>'bytes')::bigint,p_body->>'sha256',p_body->>'mime')returning * into a;return a;end$$;
create or replace function public.property_video_audio_complete(p_actor uuid,p_asset uuid,p_etag text)returns public.property_video_audio_assets
language plpgsql security definer set search_path=''as $$declare a public.property_video_audio_assets;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into a from public.property_video_audio_assets where id=p_asset and actor_id=p_actor for update;
 if a.id is null or not public.listing_content_access(p_actor,a.listing_id,true)or(a.state<>'ready'and a.upload_until<=now())then raise exception'RP404: Narration upload is unavailable';end if;
 if a.etag is not null and a.etag<>p_etag then raise exception'RP409: Narration bytes changed';end if;
 update public.property_video_audio_assets set state='ready',etag=p_etag where id=p_asset returning * into a;return a;end$$;
create or replace function public.property_video_notification_current(p_job uuid,p_actor uuid)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 begin j:=public.property_video_job_scope(p_job,p_actor,false);return j.state='ready';exception when others then return false;end;end$$;
do $$declare f regprocedure;begin for f in select oid::regprocedure from pg_proc where pronamespace='public'::regnamespace and(proname like'property_video_job_%'or proname like'property_video_audio_%'or proname in('property_video_notification_current','property_video_actor_org'))loop
 execute format('revoke all on function %s from public,anon,authenticated',f);execute format('grant execute on function %s to service_role',f);end loop;end$$;
revoke all on function public.property_native_owned_upload(uuid,uuid,uuid,text)from public,anon,authenticated;
grant execute on function public.property_native_owned_upload(uuid,uuid,uuid,text)to service_role;
grant execute on function public.property_owned_upload(uuid,uuid,uuid,text)to authenticated,service_role;
-- Public discovery is a narrow, current opt-in index, never an account directory.
create or replace function public.public_property_tour_index(p_after uuid default null,p_limit integer default 100)returns jsonb
language plpgsql security definer set search_path=''as $$declare rows jsonb;next_id uuid;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_limit is null or p_limit not between 1 and 200 then raise exception'RP400: Use a bounded tour index page';end if;
 with latest as(select distinct on(r.listing_id)r.id,r.listing_id,r.slug,r.published_at from public.renders r where r.published_at is not null and r.published_at<=now()order by r.listing_id,r.published_at desc,r.id desc),eligible as(
  select r.id,r.slug,r.published_at,l.address,l.space_type from latest r join public.listings l on l.id=r.listing_id join public.orgs o on o.id=l.org_id
  where(p_after is null or r.id>p_after)and l.deleted_at is null and o.deleted_at is null and l.status<>'archived'
   and coalesce(case when l.details?'allow_indexing'then l.details->'allow_indexing'else o.brand_kit->'allow_indexing'end,'false'::jsonb)in('true'::jsonb,'"true"'::jsonb)
   and not exists(select 1 from public.deletion_requests d where d.user_id=l.agent_id and d.status in('pending','processing'))
   and(public.hosting_retention_state(l.org_id)->>'hosting_available')::boolean
   and public.studio_presenter_render_access(r.id)
  order by r.id limit p_limit+1),page as(select * from eligible order by id limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('slug',slug,'published_at',published_at,'allow_indexing',true,'address',address,'space_type',space_type)order by id),'[]'::jsonb),case when(select count(*)from eligible)>p_limit then(select id from page order by id desc limit 1)else null end into rows,next_id from page;
 return jsonb_build_object('tours',rows,'portfolios','[]'::jsonb,'next_cursor',next_id);end$$;
revoke all on function public.public_property_tour_index(uuid,integer)from public,anon,authenticated;
grant execute on function public.public_property_tour_index(uuid,integer)to service_role;

-- Cancellation doesnotrelease money liability. Only a knownaccepted supplier
-- receipt may free its concurrency slot aftermetadata-only terminalpolling.
create or replace function public.property_video_cancelled_attempts()returns jsonb language plpgsql security definer set search_path=''as $$declare rows jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 with candidates as(select s.job_id,s.position from public.property_video_job_sources s join public.property_video_jobs j on j.id=s.job_id where j.state in('cancelled','needs_reconciliation')and s.receipt is not null and s.provider_terminal_at is null and(s.provider_status_checked_at is null or s.provider_status_checked_at<now()-interval'30 seconds')order by j.created_at,s.position for update of s skip locked limit 4),touched as(update public.property_video_job_sources s set provider_status_checked_at=now()from candidates c where s.job_id=c.job_id and s.position=c.position returning s.*)
 select coalesce(jsonb_agg(jsonb_build_object('job_id',j.id,'actor_id',j.actor_id,'org_id',j.org_id,'listing_id',j.listing_id,'attempt_id',s.attempt_id,'request_key',s.request_key,'receipt',s.receipt,'provider',r.provider,'model',r.model)),'[]'::jsonb)into rows from touched s join public.property_video_jobs j on j.id=s.job_id join public.app_video_cost_reservations r on r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key and r.feature='reel'and r.model=s.receipt->>'model_id'and(r.provider_request_id is null or r.provider_request_id=s.receipt->>'request_id')and r.released_at is null;return rows;end$$;
create or replace function public.property_video_cancelled_terminal(p_job uuid,p_attempt uuid,p_request text,p_provider text,p_model text)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job for update;select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 if j.id is null or s.job_id is null or j.state not in('cancelled','needs_reconciliation')or s.receipt->>'request_id'is distinct from p_request or s.receipt->>'model_id'is distinct from p_model or not exists(select 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and feature='reel'and provider=p_provider and model=p_model and released_at is null and(provider_request_id is null or provider_request_id=p_request))then raise exception'RP409: Knowncancelled providerreceipt isunavailable';end if;
 update public.property_video_job_sources set provider_terminal_at=coalesce(provider_terminal_at,now())where job_id=p_job and attempt_id=p_attempt;return true;end$$;
revoke all on function public.property_video_cancelled_attempts(),public.property_video_cancelled_terminal(uuid,uuid,text,text,text)from public,anon,authenticated;
grant execute on function public.property_video_cancelled_attempts(),public.property_video_cancelled_terminal(uuid,uuid,text,text,text)to service_role;

create or replace function public.property_video_job_audio_source(p_job uuid,p_lease uuid,p_source jsonb)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;a public.property_video_audio_assets;v public.studio_creative_results;begin
 perform public.property_video_job_worker_scope(p_job,p_lease,null);select * into j from public.property_video_jobs where id=p_job for update;
 if j.audio_lease is distinct from p_lease or coalesce(p_source->>'sha256','')!~'^[a-f0-9]{64}$'or(p_source->>'bytes')::bigint not between 1 and 20971520 then raise exception'RP409: Exact saved narration receipt required';end if;
 if j.manifest->>'narration_asset_id'is not null then select * into a from public.property_video_audio_assets where id=(j.manifest->>'narration_asset_id')::uuid and actor_id=j.actor_id and listing_id=j.listing_id and state='ready';if a.id is null or row(p_source->>'bucket',p_source->>'storage_key',p_source->>'sha256',(p_source->>'bytes')::bigint)is distinct from row('renders',a.storage_key,a.sha256,a.bytes)then raise exception'RP409: Original recorded narration changed';end if;
 else select * into v from public.studio_creative_results where id=(j.manifest->>'narration_result_id')::uuid and user_id=j.actor_id and listing_id=j.listing_id and kind='voice';if v.id is null or row(p_source->>'bucket',p_source->>'storage_key')is distinct from row(v.bucket,v.storage_key)then raise exception'RP409: Original AI narration changed';end if;end if;
 if j.audio_source is not null and j.audio_source is distinct from p_source then raise exception'RP409: Frozen narration bytes changed';end if;update public.property_video_jobs set audio_source=p_source where id=p_job;return true;end$$;
create or replace function public.property_video_job_audio_preflight(p_job uuid,p_lease uuid,p_manifest text,p_source_sha text,p_duration numeric,p_streams integer)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;max_duration numeric;join_frames integer;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job for update;
 if j.audio_preflight is not null then if j.audio_lease=p_lease and j.manifest_sha256=p_manifest and j.audio_preflight->>'sha256'=p_source_sha and(j.audio_preflight->>'duration_s')::numeric=p_duration and(j.audio_preflight->>'audio_streams')::integer=p_streams then return j;else raise exception'RP409: Measured narration replay changed';end if;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,null);
 if j.audio_lease is distinct from p_lease or j.manifest_sha256 is distinct from p_manifest or j.audio_source->>'sha256'is distinct from p_source_sha or p_duration is null or p_duration<=0 or p_duration>7200 or p_streams<>1 then raise exception'RP409: Use actual measured frozen narration facts';end if;
 join_frames:=case j.manifest#>>'{presentation,transition}'when'dissolve'then 8 when'whip'then 5 else 0 end;max_duration:=j.source_count*5-(j.source_count-1)*join_frames/30.0;
 if p_duration>max_duration+.1 then update public.property_video_jobs set state='failed',message=format('Your narration is %s seconds; this video is %s seconds. Record a shorter take or choose more photos. No AI clip was started.',round(p_duration,1),round(max_duration,1)),audio_preflight=jsonb_build_object('sha256',p_source_sha,'duration_s',p_duration,'audio_streams',p_streams,'max_duration_s',max_duration,'within_limit',false),audio_until=null where id=p_job returning * into j;return j;end if;
 update public.property_video_jobs set audio_preflight=jsonb_build_object('within_limit',true,'sha256',p_source_sha,'duration_s',p_duration,'audio_streams',p_streams,'max_duration_s',max_duration),audio_until=null where id=p_job returning * into j;return j;end$$;
revoke all on function public.property_video_job_audio_source(uuid,uuid,jsonb),public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)from public,anon,authenticated;
grant execute on function public.property_video_job_audio_source(uuid,uuid,jsonb),public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)to service_role;
