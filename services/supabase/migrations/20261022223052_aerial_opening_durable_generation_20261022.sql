-- SOURCE ONLY: additive aerial opening authority. No route/config activation.
-- Root must create the normal timestamped migration after independent review.
begin;
create table public.property_video_aerial_openings(
 id uuid primary key default gen_random_uuid(),operation_id uuid not null,
 actor_id uuid not null references auth.users(id)on delete cascade,org_id uuid not null references public.orgs(id)on delete cascade,
 billing_org_id uuid not null,policy jsonb not null,library_org_id uuid not null,listing_id uuid not null references public.listings(id)on delete cascade,
 manifest jsonb not null,manifest_sha256 text not null check(manifest_sha256~'^[a-f0-9]{64}$'),
 original_source jsonb not null,quote jsonb not null,consent jsonb not null,
 state text not null default 'queued_input' check(state in('queued_input','preparing_input','queued_assessment','checking_source','ineligible','queued_generation','dispatching','ambiguous','processing','queued_qualification','qualifying','queued_quality','checking_quality','ready_for_acceptance','accepted','failed','cancelled')),
 input_lease uuid,input_lease_until timestamptz,input_claimed_at timestamptz,input_asset_id uuid,input_key text,input_output jsonb,
 assessment_lease uuid,assessment_claimed_at timestamptz,eligibility jsonb,
 generation_lease uuid,generation_claimed_at timestamptz,provider_receipt jsonb,
 provider_clip jsonb,qualification_lease uuid,qualification_lease_until timestamptz,qualification_claimed_at timestamptz,
 output_asset_id uuid,output_key text,poster_asset_id uuid,poster_key text,qualified_output jsonb,
 quality_lease uuid,quality_claimed_at timestamptz,quality jsonb,
 allowance_refunded_at timestamptz,future_reconciled_at timestamptz,accepted_at timestamptz,cancel_requested_at timestamptz,message text,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 deadline timestamptz not null default now()+interval '24 hours',unique(actor_id,operation_id));
create index property_video_aerial_openings_scope on public.property_video_aerial_openings(actor_id,org_id,library_org_id,listing_id,created_at);
create index property_video_aerial_openings_queue on public.property_video_aerial_openings(state,created_at) where state in('queued_input','queued_assessment','queued_generation','processing','queued_qualification','queued_quality');
create table public.property_video_aerial_observations(
 aerial_job_id uuid not null references public.property_video_aerial_openings(id)on delete cascade,phase text not null check(phase in('input','qualification')),
 lease_token uuid not null,manifest_sha256 text not null,producer_identity jsonb,processing_wall_ms bigint,
 outcome text not null check(outcome in('completed','failed')),facts jsonb not null,created_at timestamptz not null default now(),primary key(aerial_job_id,phase));
alter table public.property_video_aerial_openings enable row level security;
alter table public.property_video_aerial_observations enable row level security;
revoke all on public.property_video_aerial_openings,public.property_video_aerial_observations from public,anon,authenticated,service_role;
-- A lost admission response can be stopped without authorizing a second POST.
create table public.property_video_aerial_stops(actor_id uuid not null references auth.users(id)on delete cascade,operation_id uuid not null,org_id uuid not null references public.orgs(id)on delete cascade,library_org_id uuid not null,listing_id uuid not null references public.listings(id)on delete cascade,manifest jsonb not null,created_at timestamptz not null default now(),primary key(actor_id,operation_id));
alter table public.property_video_aerial_stops enable row level security;
revoke all on public.property_video_aerial_stops from public,anon,authenticated,service_role;

-- A fresh raw private capture may be registered without selecting a gallery
-- or converting a HEIC original into a browser-delivery alias.
create table public.property_video_aerial_original_sources(
 actor_id uuid not null references auth.users(id)on delete cascade,operation_id uuid not null,
 org_id uuid not null references public.orgs(id)on delete cascade,library_org_id uuid not null,listing_id uuid not null references public.listings(id)on delete cascade,
 asset_id uuid not null references public.capture_assets(id)on delete cascade,source jsonb not null,owned_receipt jsonb not null,
 intent text not null default'original_front_candidate'check(intent='original_front_candidate'),created_at timestamptz not null default now(),primary key(actor_id,operation_id));
create index property_video_aerial_original_asset on public.property_video_aerial_original_sources(asset_id,actor_id,listing_id,library_org_id);
alter table public.property_video_aerial_original_sources enable row level security;
revoke all on public.property_video_aerial_original_sources from public,anon,authenticated,service_role;
create function public.property_video_aerial_original_register(p_actor uuid,p_operation uuid,p_library uuid,p_listing uuid,p_source jsonb)returns jsonb language plpgsql security definer set search_path=''as $$declare ctx jsonb;org uuid;prior public.property_video_aerial_original_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('aerial-original:'||p_actor||':'||p_operation,79));
 org:=public.property_video_actor_org(p_actor,p_library,p_listing);
 if p_operation is null or jsonb_typeof(p_source)is distinct from'object'or(select count(*)from jsonb_object_keys(p_source))<>5
 or exists(select 1 from jsonb_object_keys(p_source)k where k not in('photo_asset_id','photo_version_id','photo_provenance_id','sha256','bytes'))
 or p_source->'photo_provenance_id'is distinct from'null'::jsonb or p_source->>'photo_version_id'is distinct from'asset:'||(p_source->>'photo_asset_id')
 or coalesce(p_source->>'sha256','')!~'^[a-f0-9]{64}$'or jsonb_typeof(p_source->'bytes')is distinct from'number'or(p_source->>'bytes')::numeric not between 1 and 52428800 or(p_source->>'bytes')::numeric<>trunc((p_source->>'bytes')::numeric)
 then raise exception'RP400: Keep the exact unchanged original capture';end if;
 ctx:=public.property_owned_upload(p_actor,p_listing,(p_source->>'photo_asset_id')::uuid,'photo');
 if ctx->>'org_id'is distinct from org::text or ctx->>'bucket'is distinct from'uploads'
 or ctx->>'sha256'is distinct from p_source->>'sha256'or(ctx->>'bytes')::numeric is distinct from(p_source->>'bytes')::numeric
 or ctx->>'content_type'not in('image/jpeg','image/png','image/webp','image/heic','image/heif')
 or ctx->>'storage_key'not like'uploads/'||org||'/'||p_listing||'/%'
 or exists(select 1 from public.property_video_preparations where asset_id=(p_source->>'photo_asset_id')::uuid)
 or exists(select 1 from public.media_provenance where altered_key=ctx->>'storage_key')
 or not exists(select 1 from public.upload_reservations where asset_id=(p_source->>'photo_asset_id')::uuid and actor_id=p_actor and listing_id=p_listing and org_id=org and state='completed'and spec->>'bucket'='uploads'and spec->>'kind'='photo')
 then raise exception'RP409: Upload the actual raw original through the normal private capture lane';end if;
 select*into prior from public.property_video_aerial_original_sources where actor_id=p_actor and operation_id=p_operation;
 if prior.operation_id is not null then if row(prior.org_id,prior.library_org_id,prior.listing_id,prior.source,prior.owned_receipt)is distinct from row(org,public.listing_owner_library(p_listing),p_listing,p_source,ctx)then raise exception'RP409: This original-source registration has different saved inputs';end if;
 else insert into public.property_video_aerial_original_sources(actor_id,operation_id,org_id,library_org_id,listing_id,asset_id,source,owned_receipt)values(p_actor,p_operation,org,public.listing_owner_library(p_listing),p_listing,(p_source->>'photo_asset_id')::uuid,p_source,ctx);end if;
 return jsonb_build_object('actor_id',p_actor,'org_id',org,'selected_library_org_id',public.listing_owner_library(p_listing),'listing_id',p_listing,'source',p_source);end$$;

-- Original means a saved photos.original_key, never an absent edit label.
create function public.property_video_aerial_original(p_actor uuid,p_library uuid,p_listing uuid,p_source jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$declare ctx jsonb;org uuid;begin
 if current_setting('role',true)is distinct from'service_role'and(p_actor is null or auth.uid()is distinct from p_actor)then raise insufficient_privilege;end if;
 if jsonb_typeof(p_source)is distinct from'object' or (select count(*)from jsonb_object_keys(p_source))<>5
 or exists(select 1 from jsonb_object_keys(p_source)k where k not in('photo_asset_id','photo_version_id','photo_provenance_id','sha256','bytes'))
 or p_source->'photo_provenance_id'is distinct from'null'::jsonb
 or p_source->>'photo_version_id'is distinct from'asset:'||(p_source->>'photo_asset_id')
 or coalesce(p_source->>'sha256','')!~'^[a-f0-9]{64}$'
 or jsonb_typeof(p_source->'bytes')is distinct from'number' or (p_source->>'bytes')::numeric not between 1 and 52428800
 or (p_source->>'bytes')::numeric<>trunc((p_source->>'bytes')::numeric) then raise exception'RP400: Choose the exact original front-of-home photo';end if;
 ctx:=public.property_owned_upload(p_actor,p_listing,(p_source->>'photo_asset_id')::uuid,'photo');
 if current_setting('role',true)='service_role'then org:=public.property_video_actor_org(p_actor,p_library,p_listing);
 else
  org:=(ctx->>'org_id')::uuid;
  if p_library is null or p_library not in(org,public.listing_owner_library(p_listing))or not public.listing_content_access(p_actor,p_listing,true)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))
  then raise exception'RP404: This accepted opening library is unavailable';end if;
 end if;
 if ctx->>'org_id'is distinct from org::text or ctx->>'asset_id'is distinct from p_source->>'photo_asset_id'
 or ctx->>'sha256'is distinct from p_source->>'sha256' or (ctx->>'bytes')::numeric is distinct from(p_source->>'bytes')::numeric
 or ctx->>'content_type'not in('image/jpeg','image/png','image/webp','image/heic','image/heif') or coalesce(ctx->>'etag','')=''
 or not(exists(select 1 from public.photos where listing_id=p_listing and original_key=ctx->>'storage_key')or exists(select 1 from public.property_video_aerial_original_sources where actor_id=p_actor and org_id=org and library_org_id=public.listing_owner_library(p_listing)and listing_id=p_listing and asset_id=(p_source->>'photo_asset_id')::uuid and source=p_source and owned_receipt=ctx))
 or exists(select 1 from public.media_provenance where org_id=org and listing_id=p_listing and altered_key=ctx->>'storage_key'and kind in('photo_edit','virtual_stage','declutter'))
 then raise exception'RP409: Use this property original, not an edited image or video alias';end if;
 return ctx;
end$$;

create function public.property_video_aerial_scope(p_id uuid,p_actor uuid default null)returns public.property_video_aerial_openings
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'and(p_actor is null or auth.uid()is distinct from p_actor)then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id;
 if j.id is null or(p_actor is not null and j.actor_id<>p_actor)then raise exception'RP404: This saved aerial opening is unavailable';end if;
 if public.property_video_aerial_original(j.actor_id,j.library_org_id,j.listing_id,j.manifest->'source')is distinct from j.original_source
 then raise exception'RP409: The original aerial source changed or was withdrawn';end if;return j;
end$$;

-- Pricing/config is a separate explicit root-owned adoption. Never consult legacy video.aerial.
create function public.property_video_aerial_policy()returns jsonb language plpgsql stable security definer set search_path=''as $$
declare c jsonb;r public.ai_routes;a public.ai_routes;q public.ai_routes;processors jsonb;begin
 select value into c from public.app_config where key='property_video_aerial_opening';
 if jsonb_typeof(c)is distinct from'object' or c->'enabled'is distinct from'true'::jsonb
 or c->>'profile'is distinct from'kie-kling3-4k-aerial-opening-v1'
 or c->>'vendor_content_license'is distinct from'kie-terms-2025-08-01-section-3-owner-accepted'
 or coalesce(c->>'rate_evidence_sha256','')!~'^[a-f0-9]{64}$'
 or jsonb_typeof(c->'maximum_operation_cents')is distinct from'number'
 or not((c->>'maximum_operation_cents')::numeric between 167.5 and 10000000)
 or coalesce(c->>'assessment_route_id','')!~'^[a-f0-9-]{36}$'or coalesce(c->>'quality_route_id','')!~'^[a-f0-9-]{36}$'
 or jsonb_typeof(c->'processor_consent')is distinct from'object'
 or(select count(*)from jsonb_object_keys(c->'processor_consent'))<>3
 or c#>>'{processor_consent,token}'is distinct from'aerial-opening-v1'
 or coalesce(c#>>'{processor_consent,disclosure_revision}','')!~'^[!-~]{1,200}$'
 or jsonb_typeof(c#>'{processor_consent,processors}')is distinct from'array'
 or jsonb_typeof(c->'producer_identity')is distinct from'object'
 or coalesce(c#>>'{producer_identity,image_uri}','')!~'^registry\.cloudflare\.com/[a-f0-9]{32}/[a-z0-9][a-z0-9._/-]{0,180}@sha256:[a-f0-9]{64}$'
 or coalesce(c#>>'{producer_identity,controller_sha256}','')!~'^[a-f0-9]{64}$'
 or coalesce(c#>>'{producer_identity,renderer_source_sha256}','')!~'^[a-f0-9]{64}$'
 or(select count(*)from jsonb_object_keys(c->'producer_identity'))<>3
 then raise exception'RP503: Aerial openings are waiting for their verified route and renderer';end if;
 select*into r from public.ai_routes where id=(c->>'route_id')::uuid;
 if r.id is null or not r.enabled or r.retire_after<=now() or r.task is distinct from'video.aerial_opening_kie'
 or r.provider is distinct from'kie' or r.model is distinct from'kling-3.0/video' or r.unit is distinct from'second'
 or r.unit_cents is distinct from 33.5 or r.privacy_tier is distinct from'trains_by_default'
 or not(r.capabilities @> array['i2v','1080p','5s','native4k','preserve_photo'])
 or r.params is distinct from'{"sound":false,"kie_mode":"4K","aerial_opening_profile":"kie-kling3-4k-aerial-opening-v1"}'::jsonb
 then raise exception'RP503: No exact grounded KIE aerial opening route is qualified';end if;
 select*into a from public.ai_routes where id=(c->>'assessment_route_id')::uuid;
 select*into q from public.ai_routes where id=(c->>'quality_route_id')::uuid;
 if a.id is null or q.id is null or not a.enabled or not q.enabled or a.retire_after<=now()or q.retire_after<=now()
 or a.provider not in('openai','anthropic')or q.provider not in('openai','anthropic')
 then raise exception'RP503: Source and finished-opening checks need their current qualified vision routes';end if;
 select jsonb_agg(v order by v)into processors from(select distinct v from unnest(array['kie',a.provider,q.provider])v)t;
 if(select jsonb_agg(value order by value)from jsonb_array_elements(c#>'{processor_consent,processors}'))is distinct from processors
 then raise exception'RP503: The aerial disclosure must name exactly its actual processors';end if;
 return c||jsonb_build_object('route',to_jsonb(r),'assessment_route',to_jsonb(a),'quality_route',to_jsonb(q));
end$$;

create function public.property_video_aerial_manifest(p_actor uuid,p_manifest jsonb)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare ctx jsonb;c jsonb;w bigint;h bigint;x bigint;y bigint;sw bigint;sh bigint;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if jsonb_typeof(p_manifest)is distinct from'object'or(select count(*)from jsonb_object_keys(p_manifest))<>10
 or exists(select 1 from jsonb_object_keys(p_manifest)k where k not in('schema','profile','operation_id','listing_id','expected_org_id','source','role','aspect','seconds','reviewed_crop'))
 or p_manifest->'schema'is distinct from'1'::jsonb or p_manifest->>'profile'is distinct from'kie-kling3-4k-aerial-opening-v1'
 or p_manifest->>'role'is distinct from'front_of_home' or p_manifest->>'aspect'not in('16:9','9:16')or p_manifest->'seconds'is distinct from'5'::jsonb
 or jsonb_typeof(p_manifest->'reviewed_crop')is distinct from'object' or(select count(*)from jsonb_object_keys(p_manifest->'reviewed_crop'))<>6
 or exists(select 1 from jsonb_object_keys(p_manifest->'reviewed_crop')k where k not in('x','y','width','height','source_width','source_height'))
 then raise exception'RP400: Choose one original front-of-home photo and review its opening crop';end if;
 perform(p_manifest->>'operation_id')::uuid;
 c:=p_manifest->'reviewed_crop';
 if exists(select 1 from jsonb_each(c)e where jsonb_typeof(e.value)<>'number'or e.value::text!~'^[0-9]{1,6}$')then raise exception'RP400: Use the exact reviewed raster crop';end if;
 x:=(c->>'x')::bigint;y:=(c->>'y')::bigint;w:=(c->>'width')::bigint;h:=(c->>'height')::bigint;sw:=(c->>'source_width')::bigint;sh:=(c->>'source_height')::bigint;
 if w<=0 or h<=0 or sw not between 1 and 20000 or sh not between 1 and 20000 or sw*sh>100000000 or x+w>sw or y+h>sh
 or(case when p_manifest->>'aspect'='16:9'then w*9<>h*16 or w<1920 or h<1080 else w*16<>h*9 or w<1080 or h<1920 end)
 then raise exception'RP400: The reviewed crop needs native1080p pixels in the selected aspect';end if;
 ctx:=public.property_video_aerial_original(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid,p_manifest->'source');
 return ctx;
end$$;

-- Quote supplied by the server's existing textAttemptQuote/vision bound helper,
-- checked against the currently adopted exact policy and full manifest hash.
create function public.property_video_aerial_quote_check(p_manifest jsonb,p_quote jsonb,p_policy jsonb)returns boolean
language plpgsql immutable security definer set search_path=''as $$declare g numeric;a numeric;q numeric;p numeric;total numeric;begin
 if jsonb_typeof(p_quote->'generation_cents')is distinct from'number'or jsonb_typeof(p_quote->'processing_cents')is distinct from'number'or jsonb_typeof(p_quote->'maximum_total_cents')is distinct from'number'or jsonb_typeof(p_quote#>'{assessment,cents}')is distinct from'number'or jsonb_typeof(p_quote#>'{quality,cents}')is distinct from'number'or jsonb_typeof(p_quote)is distinct from'object'or (select count(*)from jsonb_object_keys(p_quote))<>14
 or exists(select 1 from jsonb_object_keys(p_quote)k where k not in('schema','profile','manifest_sha256','route_id','generation_cents','assessment','quality','processing_cents','maximum_total_cents','tariff_version','rate_evidence_sha256','processor_consent','expires_at','privacy_stop_at'))
 or not(p_quote?'privacy_stop_at')or(p_quote->'privacy_stop_at'<>'null'::jsonb and jsonb_typeof(p_quote->'privacy_stop_at')is distinct from'string')
 or p_quote->'schema'is distinct from'1'::jsonb or p_quote->>'profile'is distinct from p_manifest->>'profile'
 or p_quote->>'manifest_sha256'is distinct from encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex')
 or p_quote->>'route_id'is distinct from p_policy->>'route_id'
 or p_quote->>'rate_evidence_sha256'is distinct from p_policy->>'rate_evidence_sha256'
 or p_quote->>'tariff_version'is distinct from'published-standard-20261006'
 or p_quote->'processor_consent'is distinct from p_policy->'processor_consent'
 then raise exception'RP409: Restore the exact current aerial quote and processor disclosure';end if;
 g:=(p_quote->>'generation_cents')::numeric;a:=(p_quote#>>'{assessment,cents}')::numeric;q:=(p_quote#>>'{quality,cents}')::numeric;p:=(p_quote->>'processing_cents')::numeric;total:=(p_quote->>'maximum_total_cents')::numeric;
 if g is distinct from 167.5 or a is null or q is null or p is null or total is null
 or a<=0 or q<=0 or a>100 or q>100 or p<2*1260*.006112 or p>100
 or total is distinct from g+a+q+p or total>(p_policy->>'maximum_operation_cents')::numeric
 or total::text in('NaN','Infinity','-Infinity')
 or p_quote#>>'{assessment,route_id}'is distinct from p_policy->>'assessment_route_id'
 or p_quote#>>'{quality,route_id}'is distinct from p_policy->>'quality_route_id'
 or p_quote#>>'{assessment,provider}'is distinct from p_policy#>>'{assessment_route,provider}'or p_quote#>>'{assessment,model}'is distinct from p_policy#>>'{assessment_route,model}'
 or p_quote#>>'{quality,provider}'is distinct from p_policy#>>'{quality_route,provider}'or p_quote#>>'{quality,model}'is distinct from p_policy#>>'{quality_route,model}'
 then raise exception'RP503: Every aerial assessment,processing,generation and quality stage needs a bounded quote';end if;
 return true;
end$$;

create function public.property_video_aerial_admit(p_actor uuid,p_manifest jsonb,p_quote jsonb,p_consent jsonb)returns public.property_video_aerial_openings
language plpgsql security definer set search_path=''as $$
declare j public.property_video_aerial_openings;ctx jsonb;c jsonb;org uuid;billing uuid;h text;ent public.plan_entitlements;mr jsonb;br jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('aerial-privacy:'||p_actor,79));
 perform pg_advisory_xact_lock(hashtextextended('aerial-opening:'||p_actor||':'||(p_manifest->>'operation_id'),79));
 h:=encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex');
 select*into j from public.property_video_aerial_openings where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if j.id is not null then if j.manifest is distinct from p_manifest or j.consent is distinct from p_consent then raise exception'RP409: This aerial operation has different saved inputs or permission';end if;return public.property_video_aerial_scope(j.id,p_actor);end if;
 if exists(select 1 from public.property_video_aerial_stops where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid)then raise exception'RP409: This aerial operation was stopped before admission. Keep its stop receipt and use a new operation for a new choice';end if;
 org:=public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);billing:=public.library_actor_billing_org(p_actor,org);
 perform pg_advisory_xact_lock(hashtextextended('serving:'||billing,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||org,72452));perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||billing,42));
 perform 1 from auth.users where id=p_actor for share;perform 1 from public.orgs where id=billing and deleted_at is null for update;if not found then raise exception'RP404: Aerial billing library unavailable';end if;
 perform 1 from public.orgs where id=org and deleted_at is null for update;if not found then raise exception'RP404: Aerial library unavailable';end if;
 perform 1 from public.listings where id=(p_manifest->>'listing_id')::uuid and deleted_at is null for share;if not found then raise exception'RP404: Aerial property unavailable';end if;
 perform 1 from public.capture_assets where id=(p_manifest#>>'{source,photo_asset_id}')::uuid for share;
 ctx:=public.property_video_aerial_manifest(p_actor,p_manifest);c:=public.property_video_aerial_policy();perform public.property_video_aerial_quote_check(p_manifest,p_quote,c);
 if(p_quote->>'privacy_stop_at')::timestamptz is distinct from(select max(created_at)from public.property_video_stop_operations where actor_id=p_actor)then raise exception'RP409: Privacy permission changed after this aerial quote. Review a fresh operation before sending more media';end if;
 if(p_quote->>'expires_at')::timestamptz<=now()or(p_quote->>'expires_at')::timestamptz>now()+interval'15 minutes'
 or p_consent is distinct from p_quote->'processor_consent'then raise exception'RP409: Allow the listed processors for this exact current aerial quote';end if;
 ent:=public.org_entitlement(billing);
 if ent.aerials_per_month<=0 or public.org_month_spend_cents(billing)+(p_quote->>'maximum_total_cents')::numeric>ent.cogs_ceiling_cents then raise exception'RP402: This aerial opening exceeds the current plan or processing capacity';end if;
 if public.serving_mode()='ceiling'then perform public.library_serving_envelope_admit(org,billing,(p_quote->>'maximum_total_cents')::numeric,null);end if;
 mr:=public.bump_rate_receipt('aerialmo:'||billing,2592000,ent.aerials_per_month,1);br:=public.bump_rate_receipt('aivideo:'||billing,300,12,1);
 if mr->'accepted'is distinct from'true'::jsonb or br->'accepted'is distinct from'true'::jsonb then raise exception'RP402: The current aerial allowance is unavailable';end if;
 -- A distinct normal hold per possible stage, all before any asynchronous work.
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial_input','cloudflare','container-standard-3',h,(p_quote->>'processing_cents')::numeric/2,'container-standard3-20261021');
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial_qualification','cloudflare','container-standard-3',h,(p_quote->>'processing_cents')::numeric/2,'container-standard3-20261021');
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial_assessment',p_quote#>>'{assessment,provider}',p_quote#>>'{assessment,model}',h,(p_quote#>>'{assessment,cents}')::numeric,p_quote->>'tariff_version');
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial_quality',p_quote#>>'{quality,provider}',p_quote#>>'{quality,model}',h,(p_quote#>>'{quality,cents}')::numeric,p_quote->>'tariff_version');
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial','kie','kling-3.0/video',h,167.5,p_quote->>'tariff_version');
 perform public.app_video_cost_reserve_v2(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial','kie','kling-3.0/video',h,167.5,5,33.5,
 jsonb_build_object('task','video.aerial_opening_kie','route_id',c->>'route_id','unit','second','grounded',true,'seconds',5,'aspect',p_manifest->>'aspect','price_estimated',true),(mr->>'window_start')::timestamptz,(br->>'window_start')::timestamptz,(p_manifest->>'listing_id')::uuid);
 insert into public.property_video_aerial_openings(operation_id,actor_id,org_id,billing_org_id,policy,library_org_id,listing_id,manifest,manifest_sha256,original_source,quote,consent)
 values((p_manifest->>'operation_id')::uuid,p_actor,org,billing,c,public.listing_owner_library((p_manifest->>'listing_id')::uuid),(p_manifest->>'listing_id')::uuid,p_manifest,h,ctx,p_quote,p_consent)returning*into j;return j;
end$$;

create function public.property_video_aerial_operation_stop(p_actor uuid,p_manifest jsonb)returns jsonb language plpgsql security definer set search_path=''as $$declare org uuid;j public.property_video_aerial_openings;s public.property_video_aerial_stops;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 org:=public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);
 perform pg_advisory_xact_lock(hashtextextended('aerial-opening:'||p_actor||':'||(p_manifest->>'operation_id'),79));
 select*into j from public.property_video_aerial_openings where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid for update;
 if j.id is not null then if j.manifest is distinct from p_manifest then raise exception'RP409: Stop only the exact saved aerial operation';end if;return jsonb_build_object('job',to_jsonb(public.property_video_aerial_cancel(p_actor,j.id)));end if;
 select*into s from public.property_video_aerial_stops where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if s.actor_id is not null and s.manifest is distinct from p_manifest then raise exception'RP409: This stopped aerial operation has different saved inputs';end if;
 if s.actor_id is null then insert into public.property_video_aerial_stops(actor_id,operation_id,org_id,library_org_id,listing_id,manifest)values(p_actor,(p_manifest->>'operation_id')::uuid,org,public.listing_owner_library((p_manifest->>'listing_id')::uuid),(p_manifest->>'listing_id')::uuid,p_manifest);end if;
 return jsonb_build_object('operation_id',p_manifest->>'operation_id','operation_confirmed',true,'admitted',false,'cancelled',true,'may_submit',false);end$$;
create function public.property_video_aerial_stopped(p_actor uuid,p_library uuid,p_listing uuid,p_operation uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$declare org uuid;s public.property_video_aerial_stops;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 org:=public.property_video_actor_org(p_actor,p_library,p_listing);select*into s from public.property_video_aerial_stops where actor_id=p_actor and operation_id=p_operation;
 if s.actor_id is null then return null;end if;if row(s.org_id,s.library_org_id,s.listing_id)is distinct from row(org,public.listing_owner_library(p_listing),p_listing)then raise exception'RP409: This stopped operation belongs to another selected property';end if;
 return jsonb_build_object('operation_id',p_operation,'operation_confirmed',true,'admitted',false,'cancelled',true,'may_submit',false);end$$;

-- Scope-bound cancellation does not erase submitted receipts or paid media.
create function public.property_video_aerial_cancel(p_actor uuid,p_id uuid)returns public.property_video_aerial_openings
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id,p_actor);
 if j.state='accepted'then return j;end if;
 update public.property_video_aerial_openings set cancel_requested_at=coalesce(cancel_requested_at,now()),state='cancelled',message='Stopped. Any submitted opening and its processing receipt remain private.',updated_at=now()where id=p_id returning*into j;return j;
end$$;

-- Each potentially billable stage has ONE permanent claim. Expiry never resets it.
create function public.property_video_aerial_claim(p_id uuid,p_stage text)returns jsonb
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;lease uuid;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);
 if j.cancel_requested_at is not null or j.deadline<=now()then return jsonb_build_object('claimed',false,'job',to_jsonb(j));end if;
 perform public.property_video_aerial_policy();
 if public.property_video_aerial_policy()is distinct from j.policy then raise exception'RP409: This saved aerial route or producer changed; no replacement was sent';end if;
 if p_stage in('input','qualification')then
  perform pg_advisory_xact_lock(hashtextextended('property-video-photo-motion-slot-0',79));
  if exists(select 1 from public.property_video_jobs where manifest->>'source_mode'='photo_motion_v1'and ((state='composing'and compose_until>now())or(audio_preflight is null and audio_until>now())))or exists(select 1 from public.property_video_aerial_openings where id<>p_id and((state='preparing_input'and input_lease_until>now())or(state='qualifying'and qualification_lease_until>now())))then return jsonb_build_object('claimed',false,'job',to_jsonb(j));end if;
 end if;
 if p_stage='input'and j.state='queued_input'and j.input_claimed_at is null then
  lease:=gen_random_uuid();update public.property_video_aerial_openings set state='preparing_input',input_lease=lease,input_lease_until=now()+interval'21 minutes',input_claimed_at=now(),input_asset_id=gen_random_uuid(),input_key='renders/'||org_id||'/'||listing_id||'/aerial-input/'||id||'.jpg'where id=p_id returning*into j;
 elsif p_stage='assessment'and j.state='queued_assessment'and j.assessment_claimed_at is null then
  lease:=gen_random_uuid();update public.property_video_aerial_openings set state='checking_source',assessment_lease=lease,assessment_claimed_at=now()where id=p_id returning*into j;
 elsif p_stage='generation'and j.state='queued_generation'and j.generation_claimed_at is null and j.eligibility->'exterior'is not distinct from'true'::jsonb and j.eligibility->'uncertain'is not distinct from'false'::jsonb then
  lease:=gen_random_uuid();update public.property_video_aerial_openings set state='dispatching',generation_lease=lease,generation_claimed_at=now()where id=p_id returning*into j;
 elsif p_stage='qualification'and j.state='queued_qualification'and j.qualification_claimed_at is null then
  lease:=gen_random_uuid();update public.property_video_aerial_openings set state='qualifying',qualification_lease=lease,qualification_lease_until=now()+interval'21 minutes',qualification_claimed_at=now(),output_asset_id=gen_random_uuid(),output_key='renders/'||org_id||'/'||listing_id||'/aerial-opening/'||id||'.mp4',poster_asset_id=gen_random_uuid(),poster_key='renders/'||org_id||'/'||listing_id||'/aerial-opening/'||id||'.jpg'where id=p_id returning*into j;
 elsif p_stage='quality'and j.state='queued_quality'and j.quality_claimed_at is null then
  lease:=gen_random_uuid();update public.property_video_aerial_openings set state='checking_quality',quality_lease=lease,quality_claimed_at=now()where id=p_id returning*into j;
 else return jsonb_build_object('claimed',false,'job',to_jsonb(j));end if;
 return jsonb_build_object('claimed',true,'lease_token',lease,'job',to_jsonb(j));
end$$;

create function public.property_video_aerial_receipt(p_id uuid,p_lease uuid,p_receipt jsonb)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id;
 if j.id is null then raise exception'RP404: Aerial receipt unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_aerial_openings where id=p_id for update;
 if j.id is null or j.generation_lease is distinct from p_lease or j.generation_claimed_at is null
 or jsonb_typeof(p_receipt)is distinct from'object' or(select count(*)from jsonb_object_keys(p_receipt))<>5
 or exists(select 1 from jsonb_object_keys(p_receipt)k where k not in('provider','model','id','submitted_at','poll_url'))
 or p_receipt->>'provider'is distinct from'kie'or p_receipt->>'model'is distinct from'kling-3.0/video'
 or coalesce(p_receipt->>'id','')!~'^[A-Za-z0-9_-]{1,200}$'
 or p_receipt->>'poll_url'is distinct from'https://api.kie.ai/api/v1/jobs/recordInfo?taskId='||(p_receipt->>'id')
 then raise exception'RP409: Keep the exact original KIE aerial receipt';end if;
 perform(p_receipt->>'submitted_at')::timestamptz;
 if j.provider_receipt is not null then if j.provider_receipt is distinct from p_receipt then raise exception'RP409: Aerial acceptance is immutable';end if;return true;end if;
 update public.property_video_aerial_openings set provider_receipt=p_receipt,state=case when cancel_requested_at is null then'processing'else'cancelled'end,updated_at=now()where id=p_id;
 perform public.app_video_cost_settle(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,p_receipt->>'id');
 perform public.serving_cost_finish(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,'aerial','succeeded',null);return true;
end$$;

create function public.property_video_aerial_ambiguous(p_id uuid,p_lease uuid)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id;
 if j.id is null then raise exception'RP404: Aerial receipt unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_aerial_openings where id=p_id for update;
 if j.id is null or j.generation_lease is distinct from p_lease then raise exception'RP409: This aerial dispatch was superseded';end if;
 if j.provider_receipt is null then update public.property_video_aerial_openings set state='ambiguous',message='Checking the saved submission. No second provider request will be sent.',updated_at=now()where id=p_id;perform public.serving_cost_finish(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,'aerial','uncertain',null);end if;return true;
end$$;

-- Accepted catalogue helper: no raw URLs and no legacy provenance promotion.
create function public.property_video_aerial_opening_scope(p_ref jsonb,p_actor uuid,p_org uuid,p_selected_library uuid,p_listing uuid,p_aspect text)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_aerial_openings;o jsonb;ref jsonb;a public.capture_assets;g public.media_provenance;r public.app_video_cost_reservations;c public.cost_ledger;begin
 if current_setting('role',true)is distinct from'service_role'and(p_actor is null or auth.uid()is distinct from p_actor)then raise insufficient_privilege;end if;
 if jsonb_typeof(p_ref)is distinct from'object'or(select count(*)from jsonb_object_keys(p_ref))<>7 or exists(select 1 from jsonb_object_keys(p_ref)k where k not in('aerial_job_id','asset_id','provenance_id','sha256','bytes','visible_frames','source')) then raise exception'RP400: Choose one exact accepted aerial opening';end if;
 j:=public.property_video_aerial_scope((p_ref->>'aerial_job_id')::uuid,p_actor);o:=j.qualified_output;
 if row(j.org_id,j.library_org_id,j.listing_id)is distinct from row(p_org,p_selected_library,p_listing)or j.manifest->>'aspect'is distinct from p_aspect
 or j.state is distinct from'accepted'or j.accepted_at is null or j.eligibility->'exterior'is distinct from'true'::jsonb or j.eligibility->'uncertain'is distinct from'false'::jsonb
 or j.quality->>'action'is distinct from'accept'or j.quality->>'verdict'is distinct from'pass' or j.quality->'publishable'is distinct from'true'::jsonb
 or j.quality->>'output_sha256'is distinct from o->>'sha256' or j.quality->>'source_sha256'is distinct from j.manifest#>>'{source,sha256}'
 or j.provider_receipt is null or o is null or o->'producer_identity'is distinct from j.policy->'producer_identity'or o->'fps'is distinct from'24'::jsonb or coalesce((o->>'available_frames')::integer,0)not in(120,121)
 or coalesce(abs((o->>'duration_s')::numeric-(o->>'available_frames')::numeric/24),1)>.000001 or (o->>'bytes')::bigint not between 1 and 134217728
 or o->>'content_type'is distinct from'video/mp4' or o->>'codec'is distinct from'h264' or o->>'pix_fmt'is distinct from'yuv420p'
 or o->>'color_space'is distinct from'bt709'or o->>'sample_aspect_ratio'is distinct from'1:1'or o->'rotation'is distinct from'0'::jsonb or o->'audio_streams'is distinct from'0'::jsonb
 or o->'width'is distinct from to_jsonb(case when p_aspect='16:9'then 1920 else 1080 end)or o->'height'is distinct from to_jsonb(case when p_aspect='16:9'then 1080 else 1920 end)
 then raise exception'RP409: The aerial opening no longer has an exact accepted quality and timeline receipt';end if;
 ref:=jsonb_build_object('aerial_job_id',j.id,'asset_id',o->'asset_id','provenance_id',o->'provenance_id','sha256',o->'sha256','bytes',o->'bytes','visible_frames',o->'available_frames','source',j.manifest->'source');
 if p_ref is distinct from ref then raise exception'RP409: The accepted aerial reference changed';end if;
 select*into a from public.capture_assets where id=(o->>'asset_id')::uuid and listing_id=p_listing and kind='video'and bucket='renders'and uploaded and not upload_aborted;
 select*into g from public.media_provenance where id=(o->>'provenance_id')::uuid and org_id=p_org and listing_id=p_listing and kind='aerial';
 select*into r from public.app_video_cost_reservations where actor_id=p_actor and org_id=p_org and idempotency_key='aerial-opening:'||j.operation_id;
 select*into c from public.cost_ledger where id=r.cost_ledger_id;
 if a.id is null or row(a.storage_key,a.sha256,a.bytes)is distinct from row(o->>'storage_key',o->>'sha256',(o->>'bytes')::bigint)
 or g.id is null or g.altered_key is distinct from a.storage_key or g.original_key is distinct from j.original_source->>'storage_key' or g.qc is distinct from j.quality
 or r.provider is distinct from'kie'or r.model is distinct from'kling-3.0/video'or r.feature is distinct from'aerial'or r.provider_request_id is distinct from j.provider_receipt->>'id'
 or r.settled_at is null or r.released_at is not null or c.id is null or c.total_cents is distinct from 167.5
 or c.org_id is distinct from j.org_id or c.billing_org_id is distinct from r.billing_org_id or c.provider is distinct from r.provider or c.model is distinct from r.model or c.feature is distinct from'aerial'
 or c.meta->>'request_key'is distinct from r.idempotency_key or c.meta->>'app_video_reservation_id'is distinct from r.id::text or c.meta->>'request_id'is distinct from r.provider_request_id
 then raise exception'RP409: The accepted aerial custody,provenance or paid receipt changed';end if;
 perform public.assert_studio_asset_quality(a.id);
 if not public.studio_presenter_key_access(p_listing,a.storage_key)then raise exception'RP404: The accepted aerial opening was withdrawn';end if;
 return jsonb_build_object('opening',ref||jsonb_build_object('schema',1,'kind','aerial_opening','position',0,'scope',jsonb_build_object('actor_id',j.actor_id,'org_id',j.org_id,'selected_library_org_id',j.library_org_id,'listing_id',j.listing_id),'aspect',p_aspect,'fps',24,'available_frames',o->'available_frames','width',o->'width','height',o->'height','duration_s',o->'duration_s','disclosure',g.disclosure,'accepted_at',j.accepted_at),
 'media',jsonb_build_object('bucket','renders','storage_key',a.storage_key,'content_type','video/mp4','sha256',a.sha256,'bytes',a.bytes,'etag',o->>'etag'));
end$$;

create function public.property_video_aerial_accept(p_actor uuid,p_id uuid,p_ref jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id,p_actor);
 if j.state not in('ready_for_acceptance','accepted')or j.cancel_requested_at is not null then raise exception'RP409: Review one qualified opening before using it';end if;
 update public.property_video_aerial_openings set state='accepted',accepted_at=coalesce(accepted_at,now()),updated_at=now()where id=p_id returning*into j;
 return public.property_video_aerial_opening_scope(p_ref,p_actor,j.org_id,j.library_org_id,j.listing_id,j.manifest->>'aspect');
end$$;

-- The controller observation is immutable per stage/lease; unknown time never
-- becomes zero cost and never releases a conservative processing hold.
create function public.property_video_aerial_observe(p_id uuid,p_phase text,p_lease uuid,p_outcome text,p_wall_ms bigint,p_producer jsonb,p_facts jsonb)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;o public.property_video_aerial_observations;stage text;wall bigint;cost numeric;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id;
 if j.id is null then raise exception'RP404: Aerial processing receipt unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_aerial_openings where id=p_id for update;
 stage:=case p_phase when'input'then'aerial_input'when'qualification'then'aerial_qualification'else null end;
 if stage is null or p_outcome not in('completed','failed')or p_lease is distinct from(case p_phase when'input'then j.input_lease else j.qualification_lease end)
 or jsonb_typeof(p_facts)is distinct from'object'or p_facts->>'manifest_sha256'is distinct from j.manifest_sha256
 or(p_producer is not null and p_producer is distinct from j.policy->'producer_identity')then raise exception'RP409: This aerial CPU receipt is not the captured producer and lease';end if;
 wall:=case when p_wall_ms between 0 and 1260000 and p_wall_ms%10=0 and p_producer is not null then p_wall_ms else null end;
 select*into o from public.property_video_aerial_observations where aerial_job_id=p_id and phase=p_phase;
 if o.aerial_job_id is not null then
  if row(o.lease_token,o.outcome,o.processing_wall_ms,o.producer_identity,o.facts)is distinct from row(p_lease,p_outcome,wall,p_producer,p_facts)then raise exception'RP409: Aerial CPU observations are immutable';end if;return true;
 end if;
 insert into public.property_video_aerial_observations(aerial_job_id,phase,lease_token,manifest_sha256,producer_identity,processing_wall_ms,outcome,facts)values(p_id,p_phase,p_lease,j.manifest_sha256,p_producer,wall,p_outcome,p_facts);
 if wall is null or p_outcome='failed'then perform public.serving_cost_finish(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,stage,'uncertain',null);
 else
  cost:=ceil(wall::numeric/1000*.006112*10000)/10000;
  if cost>0 then insert into public.cost_ledger(org_id,billing_org_id,feature,provider,model,units,unit_cost_cents,total_cents,idempotency_key,meta)
   values(j.org_id,j.billing_org_id,'aerial','cloudflare','container-standard-3',wall::numeric/1000,.006112,cost,'aerial-cpu:'||j.id||':'||p_phase,
   jsonb_build_object('request_key','aerial-opening:'||j.operation_id,'stage',stage,'aerial_job_id',j.id,'lease_token',p_lease,'price_estimated',true,'invoice_actual',false,'rate_evidence_sha256','8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a'));
  end if;
  perform public.serving_cost_finish(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,stage,'succeeded',null);
 end if;return true;
end$$;

create function public.property_video_aerial_cpu_output(p_id uuid,p_phase text,p_lease uuid,p_facts jsonb,p_complete boolean)returns public.property_video_aerial_openings
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;prior jsonb;f jsonb;asset uuid;key_ text;kind_ text;mime text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);
 if p_phase not in('input','qualification')or p_lease is distinct from(case p_phase when'input'then j.input_lease else j.qualification_lease end)
 or p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or p_facts->>'source_sha256'is distinct from j.manifest#>>'{source,sha256}'
 or p_facts->'producer_identity'is distinct from j.policy->'producer_identity'
 or coalesce(p_facts->>'sha256','')!~'^[a-f0-9]{64}$'or jsonb_typeof(p_facts->'bytes')is distinct from'number'
 or(p_facts->>'bytes')::numeric<>trunc((p_facts->>'bytes')::numeric)
 then raise exception'RP409: Exact original,producer,lease and measured aerial output are required';end if;
 if p_phase='input'then
  if j.state not in('preparing_input','queued_assessment','checking_source','queued_generation','dispatching','ambiguous','processing','queued_qualification','qualifying','queued_quality','checking_quality','ready_for_acceptance','accepted','cancelled')or j.input_lease is null
  or p_facts->'source_bytes'is distinct from j.manifest#>'{source,bytes}'or p_facts->>'mime'is distinct from'image/jpeg'or p_facts->'reviewed_crop'is distinct from j.manifest->'reviewed_crop'
  or(p_facts->>'bytes')::numeric not between 1 and 8388608
  or greatest((p_facts->>'width')::integer,(p_facts->>'height')::integer)>2048
  or(case j.manifest->>'aspect'when'16:9'then(p_facts->>'width')::bigint*9<>(p_facts->>'height')::bigint*16 or(p_facts->>'width')::integer<1920 or(p_facts->>'height')::integer<1080 else(p_facts->>'width')::bigint*16<>(p_facts->>'height')::bigint*9 or(p_facts->>'width')::integer<1080 or(p_facts->>'height')::integer<1920 end)
  then raise exception'RP409: The actual reviewed input must keep its exact aspect and native pixels';end if;
  asset:=j.input_asset_id;key_:=j.input_key;kind_:='photo';mime:='image/jpeg';prior:=j.input_output;
  f:=jsonb_build_object('asset_id',asset,'bucket','renders','storage_key',key_,'sha256',p_facts->'sha256','bytes',p_facts->'bytes','content_type',mime,'width',p_facts->'width','height',p_facts->'height','original_asset_id',j.manifest#>'{source,photo_asset_id}','original_sha256',j.manifest#>'{source,sha256}','original_bytes',j.manifest#>'{source,bytes}','aspect',j.manifest->'aspect','reviewed_crop',j.manifest->'reviewed_crop','producer_identity',p_facts->'producer_identity');
 else
  if j.state not in('qualifying','queued_quality','checking_quality','ready_for_acceptance','accepted','cancelled')or j.qualification_lease is null
  or p_facts->>'source_clip_sha256'is distinct from j.provider_clip->>'sha256'or p_facts->'source_clip_bytes'is distinct from j.provider_clip->'bytes'
  or(p_facts->>'bytes')::numeric not between 1 and 134217728
  or p_facts->'fps'is distinct from'24'::jsonb or coalesce((p_facts->>'available_frames')::integer,0)not in(120,121)or coalesce(abs((p_facts->>'duration_s')::numeric-(p_facts->>'available_frames')::numeric/24),1)>.000001
  or p_facts->'width'is distinct from to_jsonb(case j.manifest->>'aspect'when'16:9'then 1920 else 1080 end)or p_facts->'height'is distinct from to_jsonb(case j.manifest->>'aspect'when'16:9'then 1080 else 1920 end)
  or jsonb_typeof(p_facts->'source_metadata')is distinct from'object'or(select count(*)from jsonb_object_keys(p_facts->'source_metadata'))<>14
  or p_facts#>'{source_metadata,total_frames}'is distinct from p_facts->'available_frames'
  or p_facts#>'{source_metadata,fps}'is distinct from'24'::jsonb
  or coalesce(abs((p_facts#>>'{source_metadata,duration_s}')::numeric-(p_facts->>'available_frames')::numeric/24),1)>.000001
  or p_facts#>>'{source_metadata,codec}'is distinct from'h264'or p_facts#>>'{source_metadata,pix_fmt}'is distinct from'yuv420p'
  or p_facts#>'{source_metadata,rotation}'is distinct from'0'::jsonb or p_facts#>'{source_metadata,audio_streams}'is distinct from'0'::jsonb
  or p_facts->>'source_color_interpretation'not in('tagged-sdr','untagged-sdr-bt709-defaults')
  or p_facts->>'codec'is distinct from'h264'or p_facts->>'pix_fmt'is distinct from'yuv420p'or p_facts->>'color_space'is distinct from'bt709'or p_facts->>'sample_aspect_ratio'is distinct from'1:1'or p_facts->'rotation'is distinct from'0'::jsonb or p_facts->'audio_streams'is distinct from'0'::jsonb
  or p_facts->'frame_indices'is distinct from jsonb_build_array(0,60,(p_facts->>'available_frames')::integer-1) or jsonb_typeof(p_facts->'frame_sha256s')is distinct from'array'or jsonb_array_length(p_facts->'frame_sha256s')<>3
  or exists(select 1 from jsonb_array_elements_text(p_facts->'frame_sha256s')v where v!~'^[a-f0-9]{64}$')
  then raise exception'RP409: The whole accepted opening must match the exact silent full-frame1080p qualification';end if;
  asset:=j.output_asset_id;key_:=j.output_key;kind_:='video';mime:='video/mp4';prior:=j.qualified_output;
  f:=(p_facts-'manifest_sha256'-'source_sha256'-'producer_identity'-'processing_wall_ms'-'etag'-'poster_etag')||jsonb_build_object('asset_id',asset,'bucket','renders','storage_key',key_,'content_type',mime,'provenance_id',coalesce(j.qualified_output->'provenance_id',to_jsonb(gen_random_uuid())),'producer_identity',p_facts->'producer_identity');
 end if;
 if p_facts->>'asset_id'is distinct from asset::text then raise exception'RP409: Keep the allocated private aerial output';end if;
 if prior is not null and(prior-array['etag','poster_etag','review_frames'])is distinct from f then raise exception'RP409: Measured aerial output facts are immutable';end if;
 if prior?'review_frames'then f:=f||jsonb_build_object('review_frames',prior->'review_frames');end if;
 if p_complete then
  if prior is null or coalesce(p_facts->>'etag','')=''or length(p_facts->>'etag')>512 then raise exception'RP409: Reserve and verify the exact aerial upload first';end if;
  f:=f||jsonb_build_object('etag',p_facts->>'etag');
  if p_phase='qualification'then
   if coalesce(p_facts->>'poster_etag','')=''then raise exception'RP409: Verify the actual aerial poster upload';end if;
   f:=f||jsonb_build_object('poster_etag',p_facts->>'poster_etag');
   update public.capture_assets set uploaded=true where id=j.poster_asset_id and listing_id=j.listing_id and storage_key=j.poster_key and sha256=f->>'poster_sha256'and bytes=(f->>'poster_bytes')::bigint;if not found then raise exception'RP409: Aerial poster receipt changed';end if;
  end if;
  if prior?'etag'then if prior is distinct from f then raise exception'RP409: Aerial upload receipt is immutable';end if;return j;end if;
  update public.capture_assets set uploaded=true where id=asset and listing_id=j.listing_id and storage_key=key_ and sha256=f->>'sha256'and bytes=(f->>'bytes')::bigint;if not found then raise exception'RP409: The allocated aerial upload changed';end if;
  if p_phase='input'then update public.property_video_aerial_openings set input_output=f,state=case when cancel_requested_at is null then'queued_assessment'else'cancelled'end,updated_at=now()where id=p_id returning*into j;
  else update public.property_video_aerial_openings set qualified_output=f,state=case when cancel_requested_at is null then'queued_quality'else'cancelled'end,updated_at=now()where id=p_id returning*into j;end if;
 else
  if prior?'etag'then return j;end if;
  perform public.media_storage_reserve(j.org_id,'renders',key_,(f->>'bytes')::bigint);
  insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type,content_type_declared)
  values(asset,j.listing_id,kind_,'renders',key_,(f->>'bytes')::bigint,f->>'sha256',false,2,mime,true)on conflict do nothing;
  if p_phase='qualification'then
   if p_facts->>'poster_asset_id'is distinct from j.poster_asset_id::text or coalesce(p_facts->>'poster_sha256','')!~'^[a-f0-9]{64}$'or(p_facts->>'poster_bytes')::bigint not between 1 and 10485760 then raise exception'RP409: Keep the exact measured aerial poster';end if;
   perform public.media_storage_reserve(j.org_id,'renders',j.poster_key,(p_facts->>'poster_bytes')::bigint);
   insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type,content_type_declared)values(j.poster_asset_id,j.listing_id,'photo','renders',j.poster_key,(p_facts->>'poster_bytes')::bigint,p_facts->>'poster_sha256',false,2,'image/jpeg',true)on conflict do nothing;
  end if;
  if p_phase='input'then update public.property_video_aerial_openings set input_output=f where id=p_id returning*into j;
  else update public.property_video_aerial_openings set qualified_output=f where id=p_id returning*into j;end if;
 end if;return j;
end$$;

create function public.property_video_aerial_assessment(p_id uuid,p_lease uuid,p_evidence jsonb)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;c public.cost_ledger;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);
 if p_lease is distinct from j.assessment_lease or j.input_output->>'etag'is null
 or p_evidence->>'source_sha256'is distinct from j.manifest#>>'{source,sha256}'or p_evidence->>'input_sha256'is distinct from j.input_output->>'sha256'
 or jsonb_typeof(p_evidence->'exterior')is distinct from'boolean'or jsonb_typeof(p_evidence->'uncertain')is distinct from'boolean'or p_evidence->>'reason'not in('exterior','interior','not_home','uncertain')
 then raise exception'RP409: Keep the actual scoped exterior analysis for this exact original and crop';end if;
 select*into c from public.cost_ledger where id=(p_evidence->>'ledger_id')::uuid;
 if c.id is null or c.org_id<>j.org_id or c.billing_org_id<>j.billing_org_id or c.meta->>'request_key'is distinct from'aerial-opening:'||j.operation_id
 or c.meta->>'stage'is distinct from'aerial_assessment' or c.provider is distinct from j.quote#>>'{assessment,provider}'or c.model is distinct from j.quote#>>'{assessment,model}'or c.total_cents<=0 or c.total_cents>(j.quote#>>'{assessment,cents}')::numeric then raise exception'RP409: The exterior assessment paid receipt is unavailable';end if;
 if j.eligibility is not null then if j.eligibility is distinct from p_evidence then raise exception'RP409: Exterior analysis is immutable';end if;return true;end if;
 update public.property_video_aerial_openings set eligibility=p_evidence,state=case when cancel_requested_at is not null then'cancelled'when p_evidence->'exterior'='true'::jsonb and p_evidence->'uncertain'='false'::jsonb and p_evidence->>'reason'='exterior'then'queued_generation'else'ineligible'end,updated_at=now()where id=p_id;return true;
end$$;

create function public.property_video_aerial_clip(p_id uuid,p_receipt jsonb,p_clip jsonb)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;
 if j.id is null or j.provider_receipt is null or j.provider_receipt is distinct from p_receipt
 or p_clip->>'bucket'is distinct from'renders' or p_clip->>'storage_key'is distinct from'renders/'||j.org_id||'/'||j.listing_id||'/aerial-provider/'||j.id||'.mp4'
 or coalesce(p_clip->>'sha256','')!~'^[a-f0-9]{64}$'or(p_clip->>'bytes')::numeric not between 1 and 134217728 or(p_clip->>'bytes')::numeric<>trunc((p_clip->>'bytes')::numeric)
 or p_clip->>'content_type'is distinct from'video/mp4'or coalesce(p_clip->>'etag','')=''then raise exception'RP409: Retain only this original accepted KIE output';end if;
 if j.provider_clip is not null then if j.provider_clip is distinct from p_clip then raise exception'RP409: Retained KIE bytes are immutable';end if;return true;end if;
 update public.property_video_aerial_openings set provider_clip=p_clip,state=case when cancel_requested_at is null then'queued_qualification'else'cancelled'end,updated_at=now()where id=p_id;return true;
end$$;

create function public.property_video_aerial_quality(p_id uuid,p_lease uuid,p_quality jsonb)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;c public.cost_ledger;pass boolean;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);
 if p_lease is distinct from j.quality_lease or j.qualified_output->>'etag'is null
 or p_quality->>'source_sha256'is distinct from j.manifest#>>'{source,sha256}'or p_quality->>'output_sha256'is distinct from j.qualified_output->>'sha256'
 or p_quality->'frame_indices'is distinct from j.qualified_output->'frame_indices' or p_quality->'frame_sha256s'is distinct from j.qualified_output->'frame_sha256s'
 or p_quality->>'action'not in('accept','hold','retry','refuse')or p_quality->>'verdict'not in('pass','hold','fail')or jsonb_typeof(p_quality->'publishable')is distinct from'boolean'
 then raise exception'RP409: Bind the quality check to the exact retained opening and measured three frames';end if;
 select*into c from public.cost_ledger where id=(p_quality->>'ledger_id')::uuid;
 if c.id is null or c.org_id<>j.org_id or c.billing_org_id<>j.billing_org_id or c.meta->>'request_key'is distinct from'aerial-opening:'||j.operation_id
 or c.meta->>'stage'is distinct from'aerial_quality' or c.provider is distinct from j.quote#>>'{quality,provider}'or c.model is distinct from j.quote#>>'{quality,model}'or c.total_cents<=0 or c.total_cents>(j.quote#>>'{quality,cents}')::numeric then raise exception'RP409: The exact finished-opening quality receipt is unavailable';end if;
 if j.quality is not null then if j.quality is distinct from p_quality then raise exception'RP409: Opening quality is immutable';end if;return true;end if;
 pass:=p_quality->>'action'='accept'and p_quality->>'verdict'='pass'and p_quality->'publishable'='true'::jsonb;
 if pass then insert into public.media_provenance(id,org_id,listing_id,kind,label,model_id,original_key,altered_key,disclosure,qc)
  values((j.qualified_output->>'provenance_id')::uuid,j.org_id,j.listing_id,'aerial','AI aerial-style opening','kling-3.0/video',j.original_source->>'storage_key',j.qualified_output->>'storage_key','AI-generated aerial-style opening based on the chosen front exterior photo. It is not captured drone footage or a3D representation.',p_quality);
 end if;
 update public.property_video_aerial_openings set quality=p_quality,state=case when cancel_requested_at is not null then'cancelled'when pass then'ready_for_acceptance'else'failed'end,message=case when pass then'Review the generated opening before using it.'else'The generated opening did not pass its property quality check. No replacement was submitted.'end,updated_at=now()where id=p_id;return true;
end$$;

create function public.property_video_aerial_quote_context(p_actor uuid,p_manifest jsonb)returns jsonb language plpgsql stable security definer set search_path=''as $$declare source_ jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 source_:=public.property_video_aerial_manifest(p_actor,p_manifest);return jsonb_build_object('source',source_,'manifest_sha256',encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex'),'policy',public.property_video_aerial_policy(),'privacy_stop_at',(select max(created_at)from public.property_video_stop_operations where actor_id=p_actor));end$$;
create function public.property_video_aerial_operation(p_actor uuid,p_library uuid,p_listing uuid,p_operation uuid)returns public.property_video_aerial_openings language plpgsql stable security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_actor_org(p_actor,p_library,p_listing);select*into j from public.property_video_aerial_openings where actor_id=p_actor and operation_id=p_operation;
 if j.id is null then return null;end if;if j.listing_id<>p_listing or j.library_org_id<>public.listing_owner_library(p_listing) then raise exception'RP409: This aerial operation belongs to another selected property';end if;return public.property_video_aerial_scope(j.id,p_actor);end$$;
create function public.property_video_aerial_catalogue(p_actor uuid,p_library uuid,p_listing uuid,p_aspect text)returns jsonb language plpgsql stable security definer set search_path=''as $$declare org uuid;j public.property_video_aerial_openings;checked jsonb;refs jsonb:='[]';ref jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 org:=public.property_video_actor_org(p_actor,p_library,p_listing);if p_aspect not in('16:9','9:16')then raise exception'RP400: Use the exact opening aspect';end if;
 for j in select*from public.property_video_aerial_openings where actor_id=p_actor and org_id=org and library_org_id=public.listing_owner_library(p_listing)and listing_id=p_listing and state='accepted'and manifest->>'aspect'=p_aspect order by accepted_at desc,id limit 100 loop
  ref:=jsonb_build_object('aerial_job_id',j.id,'asset_id',j.qualified_output->'asset_id','provenance_id',j.qualified_output->'provenance_id','sha256',j.qualified_output->'sha256','bytes',j.qualified_output->'bytes','visible_frames',j.qualified_output->'available_frames','source',j.manifest->'source');
  begin checked:=public.property_video_aerial_opening_scope(ref,p_actor,org,public.listing_owner_library(p_listing),p_listing,p_aspect);refs:=refs||jsonb_build_array(checked);exception when others then if sqlerrm not like'RP404:%'and sqlerrm not like'RP409:%'then raise;end if;end;
 end loop;return jsonb_build_object('actor_id',p_actor,'org_id',org,'selected_library_org_id',public.listing_owner_library(p_listing),'listing_id',p_listing,'aspect',p_aspect,'accepted',refs);end$$;

create function public.property_video_aerial_vision_result(p_id uuid,p_phase text,p_lease uuid,p_result jsonb)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;q jsonb;stage text;l uuid;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id;
 if j.id is null then raise exception'RP404: Aerial check unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_aerial_openings where id=p_id for update;
 if p_phase='assessment'and p_lease=j.assessment_lease then q:=j.quote->'assessment';stage:='aerial_assessment';
 elsif p_phase='quality'and p_lease=j.quality_lease then q:=j.quote->'quality';stage:='aerial_quality';else raise exception'RP409: Keep the exact once-only aerial check';end if;
 if(p_phase='assessment'and j.eligibility is not null)or(p_phase='quality'and j.quality is not null)then
  if((case p_phase when'assessment'then j.eligibility else j.quality end)-'ledger_id')is distinct from p_result then raise exception'RP409: Aerial check result is immutable';end if;return true;
 end if;
 insert into public.cost_ledger(org_id,billing_org_id,feature,provider,model,units,unit_cost_cents,total_cents,idempotency_key,meta)
 values(j.org_id,j.billing_org_id,'qc',q->>'provider',q->>'model',1,(q->>'cents')::numeric,(q->>'cents')::numeric,'aerial-vision:'||j.id||':'||p_phase,
 jsonb_build_object('request_key','aerial-opening:'||j.operation_id,'stage',stage,'aerial_job_id',j.id,'source_sha256',j.manifest#>>'{source,sha256}','output_sha256',p_result->>'output_sha256','route_id',q->>'route_id','price_estimated',true,'invoice_actual',false))returning id into l;
 if p_phase='assessment'then perform public.property_video_aerial_assessment(p_id,p_lease,p_result||jsonb_build_object('ledger_id',l));else perform public.property_video_aerial_quality(p_id,p_lease,p_result||jsonb_build_object('ledger_id',l));end if;
 perform public.serving_cost_finish(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,stage,'succeeded',null);return true;
end$$;
create function public.property_video_aerial_worker_read(p_id uuid)returns public.property_video_aerial_openings language plpgsql stable security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;select*into j from public.property_video_aerial_openings where id=p_id;return j;end$$;
create function public.property_video_aerial_queue()returns jsonb language plpgsql stable security definer set search_path=''as $$begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 return coalesce((select jsonb_agg(jsonb_build_object('job_id',j.id,'source_mode','photo_motion_v1')||case j.state when'queued_input'then'{"work_kind":"aerial_opening_input_v1"}'::jsonb when'queued_qualification'then'{"work_kind":"aerial_opening_qualify_v1"}'::jsonb else'{}'::jsonb end)from(select*from public.property_video_aerial_openings where((cancel_requested_at is null and deadline>now()and state in('queued_input','queued_assessment','queued_generation','processing','queued_qualification','queued_quality'))or(state in('cancelled','failed','ineligible')and future_reconciled_at is null))order by created_at limit 20)j),'[]'::jsonb);end$$;
create function public.property_video_aerial_heartbeat(p_id uuid,p_phase text,p_lease uuid)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);
 if j.cancel_requested_at is not null or j.deadline<=now()then return false;end if;
 if p_phase='input'and j.state='preparing_input'and j.input_lease=p_lease then update public.property_video_aerial_openings set input_lease_until=least(input_claimed_at+interval'21 minutes',now()+interval'2 minutes')where id=p_id;return true;
 elsif p_phase='qualification'and j.state='qualifying'and j.qualification_lease=p_lease then update public.property_video_aerial_openings set qualification_lease_until=least(qualification_claimed_at+interval'21 minutes',now()+interval'2 minutes')where id=p_id;return true;end if;return false;
end$$;
create function public.property_video_aerial_failure(p_id uuid,p_phase text,p_lease uuid)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;select*into j from public.property_video_aerial_openings where id=p_id for update;
 if j.id is null or p_lease is distinct from(case p_phase when'input'then j.input_lease when'qualification'then j.qualification_lease when'assessment'then j.assessment_lease when'quality'then j.quality_lease when'generation'then j.generation_lease else null end)or p_lease is null then raise exception'RP409: Keep the exact stopped aerial stage';end if;
 if j.state not in('accepted','ready_for_acceptance','cancelled')then update public.property_video_aerial_openings set state='failed',message='This opening stopped safely. Your original photo and any already saved files are kept. No replacement generation was submitted.',updated_at=now()where id=p_id;end if;return true;
end$$;
create function public.property_video_aerial_reject_before_dispatch(p_id uuid,p_lease uuid,p_status integer,p_error_class text)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;select*into j from public.property_video_aerial_openings where id=p_id;
 if j.id is null then raise exception'RP404: Aerial dispatch unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_aerial_openings where id=p_id for update;
 if j.generation_lease is distinct from p_lease or j.provider_receipt is not null or p_status not in(0,400,401,402,403,404,405,413,415,422,429)or p_error_class not in('validation','upstream','rate_limit','nsfw')then raise exception'RP409: An accepted aerial cannot be reset';end if;
 perform public.app_video_cost_release_rejected(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,p_status,p_error_class);
 perform public.serving_cost_finish(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,'aerial','rejected',p_status);
 update public.property_video_aerial_openings set state='failed',message=case when p_status=0 then'The opening was refused before submission. No provider generation was sent.'else'The provider refused this opening without accepting a generation. Your source checks are kept.'end,updated_at=now()where id=p_id;return true;
end$$;
-- These are immutable operation/evidence rows even for privileged accidental writes.
create function public.property_video_aerial_immutable()returns trigger language plpgsql security definer set search_path=''as $$begin
 if row(new.operation_id,new.actor_id,new.org_id,new.billing_org_id,new.library_org_id,new.listing_id,new.manifest,new.manifest_sha256,new.original_source,new.policy,new.quote,new.consent,new.created_at,new.deadline)is distinct from row(old.operation_id,old.actor_id,old.org_id,old.billing_org_id,old.library_org_id,old.listing_id,old.manifest,old.manifest_sha256,old.original_source,old.policy,old.quote,old.consent,old.created_at,old.deadline)
 or(old.input_claimed_at is not null and row(new.input_claimed_at,new.input_lease,new.input_asset_id,new.input_key)is distinct from row(old.input_claimed_at,old.input_lease,old.input_asset_id,old.input_key))
 or(old.assessment_claimed_at is not null and row(new.assessment_claimed_at,new.assessment_lease)is distinct from row(old.assessment_claimed_at,old.assessment_lease))
 or(old.qualification_claimed_at is not null and row(new.qualification_claimed_at,new.qualification_lease,new.output_asset_id,new.output_key,new.poster_asset_id,new.poster_key)is distinct from row(old.qualification_claimed_at,old.qualification_lease,old.output_asset_id,old.output_key,old.poster_asset_id,old.poster_key))
 or(old.quality_claimed_at is not null and row(new.quality_claimed_at,new.quality_lease)is distinct from row(old.quality_claimed_at,old.quality_lease))
 or(old.generation_claimed_at is not null and row(new.generation_claimed_at,new.generation_lease)is distinct from row(old.generation_claimed_at,old.generation_lease))
 or(old.provider_receipt is not null and new.provider_receipt is distinct from old.provider_receipt)
 or(old.provider_clip is not null and new.provider_clip is distinct from old.provider_clip)
 or(old.eligibility is not null and new.eligibility is distinct from old.eligibility)
 or(old.quality is not null and new.quality is distinct from old.quality)
 or(old.accepted_at is not null and row(new.accepted_at,new.state)is distinct from row(old.accepted_at,old.state))
 then raise exception'RP409: Aerial identity,once-only acceptance and evidence cannot be rewritten';end if;return new;end$$;
create trigger property_video_aerial_immutable before update on public.property_video_aerial_openings for each row execute function public.property_video_aerial_immutable();

create function public.property_video_aerial_frame_reserve(p_id uuid,p_lease uuid,p_index integer,p_sha text,p_bytes bigint)returns text language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;k text;n integer;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);n:=array_position(array[0,60,(j.qualified_output->>'available_frames')::integer-1],p_index)-1;
 if j.qualification_lease is distinct from p_lease or n is null or j.qualified_output->'frame_sha256s'->>n is distinct from p_sha or p_bytes not between 1 and 393216 then raise exception'RP409: Keep the three exact measured aerial review frames';end if;
 k:='renders/'||j.org_id||'/'||j.listing_id||'/aerial-review/'||j.id||'/frame-'||p_index||'.jpg';perform public.media_storage_reserve(j.org_id,'renders',k,p_bytes);return k;end$$;
create function public.property_video_aerial_frames(p_id uuid,p_lease uuid,p_frames jsonb)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;f jsonb;n integer:=0;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);
 if j.qualification_lease is distinct from p_lease or coalesce(j.qualified_output->>'etag','')=''or jsonb_typeof(p_frames)is distinct from'array'or jsonb_array_length(p_frames)<>3 then raise exception'RP409: Keep the qualified opening and its three stored review frames';end if;
 for f in select value from jsonb_array_elements(p_frames)loop
  if f->'frame_index'is distinct from to_jsonb((array[0,60,(j.qualified_output->>'available_frames')::integer-1])[n+1])or f->>'sha256'is distinct from j.qualified_output->'frame_sha256s'->>n
  or f->>'bucket'is distinct from'renders'or f->>'storage_key'is distinct from'renders/'||j.org_id||'/'||j.listing_id||'/aerial-review/'||j.id||'/frame-'||((array[0,60,(j.qualified_output->>'available_frames')::integer-1])[n+1])||'.jpg'
  or f->>'content_type'is distinct from'image/jpeg'or(f->>'bytes')::bigint not between 1 and 393216 or coalesce(f->>'etag','')=''then raise exception'RP409: Aerial review-frame custody changed';end if;n:=n+1;
 end loop;
 if j.qualified_output?'review_frames'then if j.qualified_output->'review_frames'is distinct from p_frames then raise exception'RP409: Aerial review frames are immutable';end if;return true;end if;
 update public.property_video_aerial_openings set qualified_output=qualified_output||jsonb_build_object('review_frames',p_frames)where id=p_id;return true;end$$;

create function public.property_video_aerial_release_future(p_id uuid)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_aerial_openings;s text;started boolean;r public.app_video_cost_reservations;a public.app_video_allowance_receipts;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;select*into j from public.property_video_aerial_openings where id=p_id;if j.id is null then return false;end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_aerial_openings where id=p_id for update;
 if j.state not in('cancelled','failed','ineligible')then return false;end if;
 foreach s in array array['aerial_input','aerial_qualification','aerial_assessment','aerial_quality','aerial']loop
  started:=case s when'aerial_input'then j.input_claimed_at is not null when'aerial_qualification'then j.qualification_claimed_at is not null when'aerial_assessment'then j.assessment_claimed_at is not null when'aerial_quality'then j.quality_claimed_at is not null else j.generation_claimed_at is not null end;
  if not started and exists(select 1 from public.serving_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and request_key='aerial-opening:'||j.operation_id and stage=s and state='reserved')then perform public.serving_cost_finish(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,s,'rejected',0);end if;
 end loop;
 select*into r from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key='aerial-opening:'||j.operation_id;
 if j.generation_claimed_at is null and r.released_at is null then perform public.app_video_cost_release_rejected(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,0,'validation');select*into r from public.app_video_cost_reservations where id=r.id;end if;
 if r.released_at is not null and r.provider_request_id is null and j.allowance_refunded_at is null then
  select*into a from public.app_video_allowance_receipts where reservation_id=r.id;
  if a.reservation_id is not null then perform public.refund_rate_receipt(a.monthly_key,2592000,a.monthly_window_start,1);perform public.refund_rate_receipt(a.burst_key,300,a.burst_window_start,1);end if;
  update public.property_video_aerial_openings set allowance_refunded_at=now()where id=p_id;
 end if;
 update public.property_video_aerial_openings set future_reconciled_at=coalesce(future_reconciled_at,now())where id=p_id;return true;
end$$;
-- Extend the existing actor-wide privacy stop without replacing its body or
-- replaying it. Accepted media stays an explicit accepted record; no new work.
create function public.property_video_aerial_privacy_stop()returns trigger language plpgsql security definer set search_path=''as $$begin
 perform pg_advisory_xact_lock(hashtextextended('aerial-privacy:'||new.actor_id,79));
 update public.property_video_aerial_openings set cancel_requested_at=coalesce(cancel_requested_at,now()),state='cancelled',updated_at=now(),message='Aerial processing was stopped. Submitted receipts and already saved media remain private.'where actor_id=new.actor_id and state not in('accepted','cancelled');return new;end$$;
create trigger property_video_aerial_privacy_stop after insert on public.property_video_stop_operations for each row execute function public.property_video_aerial_privacy_stop();

-- Service-only accessors. No client can write acceptance/exterior evidence.
do $$declare f regprocedure;begin for f in select oid::regprocedure from pg_proc where pronamespace='public'::regnamespace and proname like'property_video_aerial_%'loop
 execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
 execute format('grant execute on function %s to service_role',f);
end loop;end$$;
commit;
