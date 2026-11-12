-- Video-only derivatives of an exact selected master. Original media, gallery
-- selection and export pixels are preserved. CPU runtime activation stays off.
create table if not exists public.property_video_preparations(
 id uuid primary key default gen_random_uuid(),operation_id uuid not null,actor_id uuid not null references auth.users(id)on delete cascade,listing_id uuid not null references public.listings(id)on delete cascade,org_id uuid not null references public.orgs(id)on delete cascade,library_org_id uuid not null,
 photo_id text not null,version_id text not null,original_asset_id uuid not null references public.capture_assets(id),photo_provenance_id uuid references public.media_provenance(id),original_source jsonb not null,
 state text not null default'queued'check(state in('queued','preparing','ready','failed')),lease_token uuid,lease_until timestamptz,attempts integer not null default 0 check(attempts between 0 and 3),asset_id uuid,storage_key text,bytes bigint,sha256 text,etag text,width integer,height integer,message text,created_at timestamptz not null default now(),unique(actor_id,operation_id));
alter table public.property_video_preparations enable row level security;
revoke all on public.property_video_preparations from public,anon,authenticated;
grant select,insert,update,delete on public.property_video_preparations to service_role;
create index if not exists property_video_preparations_pending on public.property_video_preparations(state,created_at)where state in('queued','preparing');
create or replace function public.property_video_preparation_scope(p_id uuid,p_actor uuid default null)returns public.property_video_preparations language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into p from public.property_video_preparations where id=p_id;
 if p.id is null or(p_actor is not null and p.actor_id<>p_actor)or not public.listing_content_access(p.actor_id,p.listing_id,true)or exists(select 1 from public.deletion_requests where user_id=p.actor_id and status in('pending','processing'))then raise exception'RP404: Prepared video source is unavailable';end if;
 if public.property_photo_reference(p.actor_id,p.listing_id,p.original_asset_id,p.photo_provenance_id)is distinct from p.original_source then raise exception'RP409: The selected master changed or was withdrawn';end if;return p;end$$;
create or replace function public.property_video_preparation_enqueue(p_actor uuid,p_body jsonb)returns public.property_video_preparations language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;ctx jsonb;org uuid;selected uuid[];actual_provenance uuid;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 org:=public.property_video_actor_org(p_actor,(p_body->>'expected_org_id')::uuid,(p_body->>'listing_id')::uuid);
 perform pg_advisory_xact_lock(hashtextextended('video-prepare:'||p_actor||':'||(p_body->>'operation_id'),79));
 select * into p from public.property_video_preparations where actor_id=p_actor and operation_id=(p_body->>'operation_id')::uuid;
 if p.id is not null then if row(p.listing_id,p.original_asset_id,p.version_id,p.photo_id,p.photo_provenance_id)is distinct from row((p_body->>'listing_id')::uuid,(p_body->>'photo_asset_id')::uuid,p_body->>'photo_version_id',p_body->>'photo_id',(p_body->>'photo_provenance_id')::uuid)then raise exception'RP409: Saved video-source preparation changed';end if;return public.property_video_preparation_scope(p.id,p_actor);end if;
 if not exists(select 1 from public.app_config where key='property_video_jobs'and value->'enabled'='true'::jsonb)then raise exception'RP503: Background video preparation is not active yet';end if;
 ctx:=public.property_photo_reference(p_actor,(p_body->>'listing_id')::uuid,(p_body->>'photo_asset_id')::uuid,(p_body->>'photo_provenance_id')::uuid);
 if(ctx->>'bytes')::bigint>52428800 or coalesce(ctx->>'content_type','')not in('image/jpeg','image/png','image/webp')or coalesce(ctx->>'sha256','')!~'^[a-f0-9]{64}$'then raise exception'RP400: Choose a complete JPEG,PNG orWebP property master up to50MiB';end if;
 select gallery_asset_ids into selected from public.listings where id=(p_body->>'listing_id')::uuid;
 if selected is not null then if not((p_body->>'photo_asset_id')::uuid=any(selected))then raise exception'RP409: Choose an exact selected gallery master';end if;
 elsif not exists(select 1 from public.capture_assets a where a.id=(p_body->>'photo_asset_id')::uuid and a.listing_id=(p_body->>'listing_id')::uuid and a.kind='photo'and a.bucket='renders'and a.uploaded and a.storage_key like 'renders/'||org||'/'||(p_body->>'listing_id')||'/gallery-%')then raise exception'RP409: This image is not a selected property master';end if;
 select id into actual_provenance from public.media_provenance where listing_id=(p_body->>'listing_id')::uuid and altered_key=ctx->>'storage_key'and kind in('photo_edit','virtual_stage','declutter')order by created_at desc limit 1;
 if actual_provenance is distinct from(p_body->>'photo_provenance_id')::uuid or p_body->>'photo_version_id'is distinct from'asset:'||(p_body->>'photo_asset_id')then raise exception'RP409: Preserve the exact selected photo version and effects';end if;
 insert into public.property_video_preparations(operation_id,actor_id,listing_id,org_id,library_org_id,photo_id,version_id,original_asset_id,photo_provenance_id,original_source)values((p_body->>'operation_id')::uuid,p_actor,(p_body->>'listing_id')::uuid,org,public.listing_owner_library((p_body->>'listing_id')::uuid),p_body->>'photo_id',p_body->>'photo_version_id',(p_body->>'photo_asset_id')::uuid,actual_provenance,ctx)returning * into p;return p;end$$;
create or replace function public.property_video_preparation_claim(p_id uuid)returns jsonb language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;begin
 p:=public.property_video_preparation_scope(p_id);select * into p from public.property_video_preparations where id=p_id for update;
 if p.state in('ready','failed')then return jsonb_build_object('action','done','preparation',to_jsonb(p));end if;
 if p.lease_until>now()then return jsonb_build_object('action','wait','preparation',to_jsonb(p));end if;
 if p.attempts>=3 then update public.property_video_preparations set state='failed',message='This selected image could not be prepared for video. Its original is unchanged.'where id=p_id returning * into p;return jsonb_build_object('action','done','preparation',to_jsonb(p));end if;
 update public.property_video_preparations set state='preparing',lease_token=gen_random_uuid(),lease_until=now()+interval'10 minutes',attempts=attempts+1,asset_id=gen_random_uuid(),bytes=null,sha256=null,etag=null where id=p_id returning * into p;
 update public.property_video_preparations set storage_key='uploads/'||p.org_id||'/'||p.listing_id||'/prepared-video/'||p.id||'/'||p.lease_token||'.jpg'where id=p_id returning * into p;return jsonb_build_object('action','prepare_image','preparation',to_jsonb(p));end$$;
create or replace function public.property_video_preparation_lease(p_id uuid,p_lease uuid)returns public.property_video_preparations language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;begin
 p:=public.property_video_preparation_scope(p_id);if p.state<>'preparing'or p.lease_token is distinct from p_lease or p.lease_until<=now()then raise exception'RP409: Prepared-source CPU lease was superseded';end if;return p;end$$;
create or replace function public.property_video_preparation_outputs(p_id uuid,p_lease uuid,p_source_sha text,p_asset uuid,p_bytes bigint,p_sha text,p_width integer,p_height integer)returns public.property_video_preparations language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;begin
 p:=public.property_video_preparation_lease(p_id,p_lease);perform 1 from public.property_video_preparations where id=p_id for update;
 if p_source_sha is distinct from p.original_source->>'sha256'or p_asset is distinct from p.asset_id or p_bytes not between 1 and 8388608 or coalesce(p_sha,'')!~'^[a-f0-9]{64}$'or p_width not between 1 and 2048 or p_height not between 1 and 2048 then raise exception'RP400: Exact measured prepared-image receipts are required';end if;
 if p.bytes is not null and row(p.bytes,p.sha256,p.width,p.height)is distinct from row(p_bytes,p_sha,p_width,p_height)then raise exception'RP409: Prepared-image bytes are immutable';end if;
 perform public.media_storage_reserve(p.org_id,'uploads',p.storage_key,p_bytes);
 insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type,content_type_declared)values(p.asset_id,p.listing_id,'photo','uploads',p.storage_key,p_bytes,p_sha,false,2,'image/jpeg',true)on conflict do nothing;
 update public.property_video_preparations set bytes=p_bytes,sha256=p_sha,width=p_width,height=p_height where id=p_id returning * into p;return p;end$$;
create or replace function public.property_video_preparation_finish(p_id uuid,p_lease uuid,p_etag text)returns public.property_video_preparations language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;begin
 p:=public.property_video_preparation_scope(p_id);if p.state='ready'then if p.lease_token is distinct from p_lease or p.etag is distinct from p_etag then raise exception'RP409: Finished prepared-image receipt changed';end if;return p;end if;p:=public.property_video_preparation_lease(p_id,p_lease);if p.bytes is null or p_etag is null or length(p_etag)>200 then raise exception'RP409: Actual prepared-image storage receipt is required';end if;
 update public.capture_assets set uploaded=true where id=p.asset_id;update public.property_video_preparations set state='ready',etag=p_etag where id=p_id returning * into p;return p;end$$;
create or replace function public.property_video_preparation_failure(p_id uuid,p_lease uuid)returns boolean language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;begin
 p:=public.property_video_preparation_lease(p_id,p_lease);update public.property_video_preparations set state=case when attempts>=3 then'failed'else'queued'end,lease_until=null,message='Video image preparation was interrupted. Its original is unchanged.'where id=p_id;return true;end$$;
create or replace function public.property_video_preparation_heartbeat(p_id uuid,p_lease uuid)returns boolean language plpgsql security definer set search_path=''as $$begin perform public.property_video_preparation_lease(p_id,p_lease);update public.property_video_preparations set lease_until=now()+interval'10 minutes'where id=p_id;return true;end$$;
-- Integrate a server-derived photo while preserving existing upload/video rules.
do $$begin if to_regprocedure('public.property_video_previous_owned_upload(uuid,uuid,uuid,text)')is null then alter function public.property_owned_upload(uuid,uuid,uuid,text)rename to property_video_previous_owned_upload;end if;end$$;
create or replace function public.property_owned_upload(p_actor uuid,p_listing uuid,p_asset uuid,p_kind text)returns jsonb language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;a public.capture_assets;begin
 select * into p from public.property_video_preparations where asset_id=p_asset and state='ready';if p.id is null then return public.property_video_previous_owned_upload(p_actor,p_listing,p_asset,p_kind);end if;
 if current_setting('role',true)is distinct from'service_role'and auth.uid()is distinct from p_actor then raise insufficient_privilege;end if;
 if p.actor_id<>p_actor or p.listing_id<>p_listing or p_kind<>'photo'or not public.listing_content_access(p_actor,p_listing,true)or public.property_native_owned_upload(p_actor,p_listing,p.original_asset_id,'photo')is distinct from p.original_source or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP404: Prepared photo source is unavailable';end if;
 if p.photo_provenance_id is not null and not exists(select 1 from public.media_provenance m where m.id=p.photo_provenance_id and m.listing_id=p_listing and m.qc->>'publishable'is distinct from'false'and(m.original_key is null or public.studio_presenter_key_access(p_listing,m.original_key))and(m.altered_key is null or public.studio_presenter_key_access(p_listing,m.altered_key)))then raise exception'RP409: The selected photo was withdrawn';end if;
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing and uploaded and not upload_aborted and bytes=p.bytes and sha256=p.sha256 and storage_key=p.storage_key;
 if a.id is null then raise exception'RP409: Prepared-source upload receipt changed';end if;
 return jsonb_build_object('actor_id',p_actor,'org_id',p.org_id,'listing_id',p_listing,'asset_id',p_asset,'bucket','uploads','storage_key',p.storage_key,'bytes',p.bytes,'etag',p.etag,'content_type','image/jpeg','sha256',p.sha256);end$$;
do $$declare f regprocedure;begin for f in select oid::regprocedure from pg_proc where pronamespace='public'::regnamespace and proname like'property_video_preparation_%'loop execute format('revoke all on function %s from public,anon,authenticated',f);execute format('grant execute on function %s to service_role',f);end loop;end$$;
revoke all on function public.property_video_previous_owned_upload(uuid,uuid,uuid,text)from public,anon,authenticated;
grant execute on function public.property_video_previous_owned_upload(uuid,uuid,uuid,text)to service_role;
grant execute on function public.property_owned_upload(uuid,uuid,uuid,text)to authenticated,service_role;
-- Upfront recipe check uses the same meter/money authority as each real clip.
-- It does not reserve the whole recipe; shared capacity can change afterwards.
create or replace function public.property_video_recipe_capacity(p_actor uuid,p_listing uuid,p_count integer,p_quote numeric)returns jsonb language plpgsql security definer set search_path=''as $$declare org uuid;billing uuid;e public.plan_entitlements;used integer;spent numeric;env jsonb;fund public.serving_funding;slice public.serving_funding_slices;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select org_id into org from public.listings where id=p_listing and deleted_at is null;
 if org is null or not public.listing_content_access(p_actor,p_listing,true)then raise exception'RP404: Property video library is unavailable';end if;
 if p_count not between 1 and 100 or p_quote is null or p_quote<=0 or p_quote>10000000 then raise exception'RP400: Use an exact bounded whole-recipe quote';end if;
 billing:=public.library_actor_billing_org(p_actor,org);perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||billing::text,42));e:=public.org_entitlement(billing);
 select coalesce(count,0)into used from public.rate_limits where key='reelmo:'||billing and window_start+window_seconds*interval'1 second'>now();used:=coalesce(used,0);
 if e.reels_per_month<=0 or used+p_count>e.reels_per_month then raise exception'RP402: This video needs % photo clips; % remain in the current plan allowance. Choose fewer photos or a plan with enough clips before generating.',p_count,greatest(0,e.reels_per_month-used);end if;
 spent:=public.org_month_spend_cents(billing);if spent+p_quote>e.cogs_ceiling_cents then raise exception'RP402: This complete video is estimated at % cents; % cents of processing capacity remain. No clip was started.',round(p_quote,2),greatest(0,e.cogs_ceiling_cents-spent);end if;
 if public.serving_mode()='ceiling'then env:=public.library_serving_envelope_admit(org,billing,p_quote,null);
 else select * into fund from public.serving_funding where org_id=billing and revoked_at is null and starts_at<=now()and ends_at>now();if fund.id is null then raise exception'RP402: This workspace has no funded serving allowance';end if;
 select * into slice from public.serving_funding_slices where funding_id=fund.id and starts_at<=now()and ends_at>now();if slice.funding_id is null then raise exception'RP402: This service interval is not funded';end if;
 select coalesce(sum(hold_cents),0)into spent from public.serving_cost_reservations where funding_id=slice.funding_id and slice_index=slice.slice_index and state<>'rejected';if spent+p_quote>slice.total_budget_cents-slice.recurring_reserve_cents then raise exception'RP402: This complete video exceeds the remaining funded allowance. No clip was started.';end if;end if;
 return jsonb_build_object('admitted',true,'estimated_cents',p_quote,'remaining_clips',e.reels_per_month-used,'atomic_reservation',false,'concurrency_caveat','Shared allowance can change; each actual attempt still reserves before dispatch.');end$$;
revoke all on function public.property_video_recipe_capacity(uuid,uuid,integer,numeric)from public,anon,authenticated;
grant execute on function public.property_video_recipe_capacity(uuid,uuid,integer,numeric)to service_role;

-- An alias cannot relabel the actual selected master's AI effects.
do $$begin if to_regprocedure('public.property_video_previous_photo_reference(uuid,uuid,uuid,uuid)')is null then alter function public.property_photo_reference(uuid,uuid,uuid,uuid)rename to property_video_previous_photo_reference;end if;end$$;
create or replace function public.property_photo_reference(p_actor uuid,p_listing uuid,p_asset uuid,p_provenance uuid)returns jsonb language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into p from public.property_video_preparations where asset_id=p_asset and state='ready';if p.id is not null and p_provenance is distinct from p.photo_provenance_id then raise exception'RP409: Preserve the selected master effects';end if;
 return public.property_video_previous_photo_reference(p_actor,p_listing,p_asset,p_provenance);end$$;
revoke all on function public.property_video_previous_photo_reference(uuid,uuid,uuid,uuid),public.property_photo_reference(uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.property_video_previous_photo_reference(uuid,uuid,uuid,uuid),public.property_photo_reference(uuid,uuid,uuid,uuid)to service_role;

-- Admission/refusal and lookup serialize the same operation. A definitive
-- capacity refusal cannot race into an accepted job after a client edits it.
create or replace function public.property_video_operation_lookup(p_actor uuid,p_listing uuid,p_expected uuid,p_operation uuid)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;r public.property_video_refused_operations;org uuid;begin
 org:=public.property_video_actor_org(p_actor,p_expected,p_listing);
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||p_operation,79));
 select * into j from public.property_video_jobs where actor_id=p_actor and operation_id=p_operation;
 select * into r from public.property_video_refused_operations where actor_id=p_actor and operation_id=p_operation;
 if(j.id is not null and j.listing_id<>p_listing)or(r.operation_id is not null and r.listing_id<>p_listing)then raise exception'RP409: This saved operation belongs to another property';end if;
 return jsonb_build_object('operation_id',p_operation,'listing_id',p_listing,'org_id',org,'selected_library_org_id',p_expected,'operation_closed',r.operation_id is not null,'message',r.message,'job_id',j.id);end$$;
create or replace function public.property_video_job_admit(p_actor uuid,p_manifest jsonb,p_quote numeric)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;r public.property_video_refused_operations;h text;message text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||(p_manifest->>'operation_id'),79));
 h:=encode(pg_catalog.sha256(pg_catalog.convert_to(p_manifest::text,'UTF8')),'hex');
 select * into j from public.property_video_jobs where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if j.id is not null then j:=public.property_video_job_enqueue(p_actor,p_manifest);return jsonb_build_object('accepted',true,'job',to_jsonb(j));end if;
 select * into r from public.property_video_refused_operations where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if r.operation_id is not null then if r.manifest_sha256<>h then raise exception'RP409: The refused operation has different saved inputs';end if;return jsonb_build_object('accepted',false,'message',r.message,'operation_closed',true);end if;
 begin perform public.property_video_recipe_capacity(p_actor,(p_manifest->>'listing_id')::uuid,jsonb_array_length(p_manifest->'sources'),p_quote);
 exception when others then get stacked diagnostics message=message_text;if position('RP402:'in message)<>1 then raise;end if;
 insert into public.property_video_refused_operations(actor_id,operation_id,listing_id,library_org_id,manifest_sha256,message)values(p_actor,(p_manifest->>'operation_id')::uuid,(p_manifest->>'listing_id')::uuid,public.listing_owner_library((p_manifest->>'listing_id')::uuid),h,substr(message,8,1000));return jsonb_build_object('accepted',false,'message',substr(message,8,1000),'operation_closed',true);end;
 j:=public.property_video_job_enqueue(p_actor,p_manifest);return jsonb_build_object('accepted',true,'job',to_jsonb(j));end$$;
revoke all on function public.property_video_operation_lookup(uuid,uuid,uuid,uuid),public.property_video_job_admit(uuid,jsonb,numeric)from public,anon,authenticated;
grant execute on function public.property_video_operation_lookup(uuid,uuid,uuid,uuid),public.property_video_job_admit(uuid,jsonb,numeric)to service_role;

-- The actor-wide privacy stop also stops queued CPU source preparations.
-- Its first durable count is replayed without touching later work.
create or replace function public.property_video_job_cancel_all(p_actor uuid,p_operation uuid,p_reason text)returns jsonb language plpgsql security definer set search_path=''as $$declare o public.property_video_stop_operations;n integer;prep_count integer;begin
 if current_setting('role',true)is distinct from'service_role'or p_actor is null then raise insufficient_privilege;end if;
 if p_reason not in('ai_consent_revoked','local_data_erasure')or p_operation is null then raise exception'RP400: Use a saved cancellation identity';end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-stop:'||p_actor||':'||p_operation,79));
 select * into o from public.property_video_stop_operations where actor_id=p_actor and operation_id=p_operation;
 if o.operation_id is not null then if o.reason<>p_reason then raise exception'RP409: Saved cancellation reason changed';end if;return jsonb_build_object('cancelled_count',o.cancelled_count);end if;
 update public.property_video_jobs set state='cancelled',cancelled_at=now(),updated_at=now(),message='Video work was cancelled. Completed media remains private.'where actor_id=p_actor and state not in('ready','cancelled','failed');get diagnostics n=row_count;
 update public.property_video_preparations set state='failed',lease_until=null,message='Video image preparation was cancelled.'where actor_id=p_actor and state in('queued','preparing');get diagnostics prep_count=row_count;
 insert into public.property_video_stop_operations values(p_actor,p_operation,p_reason,n+prep_count,now());return jsonb_build_object('cancelled_count',n+prep_count);end$$;
revoke all on function public.property_video_job_cancel_all(uuid,uuid,text)from public,anon,authenticated;grant execute on function public.property_video_job_cancel_all(uuid,uuid,text)to service_role;

create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;n integer;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select * into j from public.property_video_jobs where id=p_job for update;
 if j.state in('queued','generating','quality_review','composing')then return j;end if;
 if j.state<>'failed'or j.cancelled_at is not null or j.deadline<=now()or not exists(select 1 from public.property_video_job_sources where job_id=p_job and state='failed'and last_error='capacity_before_dispatch')or exists(select 1 from public.property_video_job_sources where job_id=p_job and(state='ambiguous'or(state='failed'and(last_error<>'capacity_before_dispatch'or receipt is not null or admission_retries>=3))))then raise exception'RP409: This saved video is not a safely resumable capacity pause';end if;
 if exists(select 1 from public.property_video_job_sources s join public.app_video_cost_reservations r on r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key where s.job_id=p_job and s.state='failed'and r.released_at is null)then raise exception'RP409: An unsettled supplier attempt cannot be restarted';end if;
 select count(*)into n from public.property_video_job_sources where job_id=p_job and state in('pending','failed');perform public.property_video_recipe_capacity(p_actor,j.listing_id,n,p_quote);
 update public.property_video_job_sources set state='pending',admission_retries=admission_retries+1,non_dispatch_history=non_dispatch_history||jsonb_build_array(jsonb_build_object('attempt_id',attempt_id,'request_key',request_key,'reason',last_error)),attempt_id=null,lease_token=null,lease_until=null,request_key=null,last_error=null where job_id=p_job and state='failed'and last_error='capacity_before_dispatch';
 update public.property_video_jobs set state='generating',message=null,updated_at=now()where id=p_job returning * into j;return j;end$$;
revoke all on function public.property_video_job_resume(uuid,uuid,numeric)from public,anon,authenticated;grant execute on function public.property_video_job_resume(uuid,uuid,numeric)to service_role;
