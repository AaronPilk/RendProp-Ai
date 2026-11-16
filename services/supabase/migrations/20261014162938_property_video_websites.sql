-- Additive photo-video publication and one verified consumable website credit
-- per property. No SKU activation, purchase, funding seed or hosted mutation.
begin;

alter table public.renders add column if not exists presentation_kind text not null default 'recorded_walkthrough'
 check(presentation_kind in('recorded_walkthrough','photo_video'));
create table if not exists public.property_video_sources(
 request_id text primary key check(length(request_id) between 1 and 256),
 actor_id uuid not null references auth.users(id) on delete cascade,
 org_id uuid not null references public.orgs(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 source_asset_id uuid not null references public.capture_assets(id),
 source_provenance_id uuid references public.media_provenance(id),
 generation_provenance_id uuid not null references public.media_provenance(id),
 input_sha256 text not null check(input_sha256~'^[a-f0-9]{64}$'),
 qc_source_hash text not null check(qc_source_hash~'^[a-f0-9]{32}$'),
 created_at timestamptz not null default now());
create table if not exists public.property_video_attestations(
 asset_id uuid primary key references public.capture_assets(id) on delete cascade,
 actor_id uuid not null references auth.users(id) on delete cascade,
 org_id uuid not null references public.orgs(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 storage_key text not null, etag text not null, bytes bigint not null,
 width integer not null check(width>=1920),height integer not null check(height>=1080 and width*9=height*16),
 duration_s numeric not null check(duration_s>0 and duration_s<=600),
 checked_at timestamptz not null default now());
create table if not exists public.property_video_compositions(
 id uuid primary key default gen_random_uuid(), listing_id uuid not null references public.listings(id) on delete cascade,
 org_id uuid not null references public.orgs(id) on delete cascade, actor_id uuid not null references auth.users(id) on delete cascade,
 asset_id uuid not null references public.capture_assets(id), poster_asset_id uuid not null references public.capture_assets(id), manifest jsonb not null,
 disclosure text not null, selected boolean not null default false,
 publication_key text not null,created_at timestamptz not null default now(),
 unique(actor_id,listing_id,publication_key),unique(asset_id));
create table if not exists public.property_video_publication_ops(
 operation_key text primary key, actor_id uuid not null references auth.users(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 composition_id uuid not null references public.property_video_compositions(id) on delete cascade,
 selection_revision bigint not null check(selection_revision>0),created_at timestamptz not null default now(),
 unique(listing_id,selection_revision));
create unique index if not exists property_video_one_selected on public.property_video_compositions(listing_id) where selected;
create index if not exists property_video_sources_listing on public.property_video_sources(listing_id);

create table if not exists public.property_website_products(
 product_id text primary key,
 production_enabled boolean not null default false,sandbox_enabled boolean not null default false);
insert into public.property_website_products(product_id) values('com.rendprop.app.website.premium.property')on conflict do nothing;
create table if not exists public.property_website_transactions(
 environment text not null check(environment in('Production','Sandbox')),transaction_id text not null,
 actor_id uuid not null references auth.users(id) on delete cascade,
 product_id text not null references public.property_website_products(product_id),
 purchased_at timestamptz not null, signed_at timestamptz not null,
 revoked_at timestamptz,notification_signed_at timestamptz,assigned_listing_id uuid references public.listings(id) on delete set null,
 assignment_identity uuid, assigned_at timestamptz,
 primary key(environment,transaction_id),
 check((assigned_at is null)=(assignment_identity is null)),
 check(assigned_listing_id is null or assigned_listing_id=assignment_identity));
create unique index if not exists property_website_one_active_credit on public.property_website_transactions(environment,assigned_listing_id)
 where assigned_listing_id is not null and revoked_at is null;
create index if not exists property_website_transactions_actor on public.property_website_transactions(actor_id);
create table if not exists public.property_website_settings(
 listing_id uuid primary key references public.listings(id) on delete cascade,
 theme text not null default 'basic' check(theme in('basic','signature-estate','coastal-luxe')),
 updated_at timestamptz not null default now());

-- All writers are service-owned or authenticated RPCs with fresh listing
-- authority. No direct Data API write can claim a purchase/composition.
do $$declare t text;begin foreach t in array array['property_video_sources','property_video_attestations','property_video_compositions',
 'property_video_publication_ops','property_website_products','property_website_transactions','property_website_settings']loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant all on public.%I to service_role',t);
end loop;end$$;

create or replace function public.property_owned_upload(p_actor uuid,p_listing uuid,p_asset uuid,p_kind text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.capture_assets;r public.upload_reservations;op public.upload_operations;o uuid;
begin
 if current_setting('role',true)is distinct from 'service_role' and auth.uid() is distinct from p_actor then raise insufficient_privilege;end if;
 select org_id into o from public.listings where id=p_listing and deleted_at is null;
 if o is null or not public.listing_content_access(p_actor,p_listing,true)then raise exception 'RP404: Property is unavailable';end if;
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing;
 select * into r from public.upload_reservations where asset_id=p_asset and actor_id=p_actor and listing_id=p_listing and org_id=o and state='completed';
 if coalesce(p_kind,'')not in('photo','video')or a.id is null or a.kind is distinct from p_kind or not a.uploaded or a.upload_aborted or a.transport_version<>2 or r.asset_id is null
  or a.bucket not in('uploads','renders')or a.bytes is null or a.bytes<=0
  or a.storage_key not like a.bucket||'/'||o||'/'||p_listing||'/%'or position('..'in a.storage_key)>0 then
  raise exception 'RP409: A completed upload owned by this account and property is required';end if;
 select * into op from public.upload_operations where asset_id=a.id and kind in('copy','assemble')and state='retained'
  and bucket=a.bucket and object_key=a.storage_key and asset_kind=p_kind and expected_bytes=a.bytes and etag is not null;
 if op.id is null or(select count(*)from public.upload_operations where asset_id=a.id and kind in('copy','assemble')and state='retained')<>1 then
  raise exception 'RP409: The retained upload receipt is unavailable';end if;
 perform public.assert_studio_asset_quality(a.id);
 return jsonb_build_object('actor_id',p_actor,'org_id',o,'listing_id',p_listing,'asset_id',a.id,'bucket',a.bucket,
  'storage_key',a.storage_key,'bytes',a.bytes,'etag',op.etag,'content_type',op.content_type,'sha256',a.sha256);
end$$;

create or replace function public.property_photo_reference(p_actor uuid,p_listing uuid,p_asset uuid,p_provenance uuid)returns jsonb
language plpgsql security definer set search_path='' as $$declare ctx jsonb;p public.media_provenance;begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 ctx:=public.property_owned_upload(p_actor,p_listing,p_asset,'photo');
 if p_provenance is not null then select * into p from public.media_provenance where id=p_provenance and listing_id=p_listing
  and org_id=(ctx->>'org_id')::uuid and kind in('photo_edit','virtual_stage','declutter');
  if p.id is null then raise exception 'RP404: Photo source provenance is unavailable';end if;
  if p.qc->>'publishable'='false'or(p.original_key is not null and not public.studio_presenter_key_access(p_listing,p.original_key))
   or(p.altered_key is not null and not public.studio_presenter_key_access(p_listing,p.altered_key))then raise exception 'RP409: This source photo has not passed its property quality check or was withdrawn';end if;
 end if;
 return ctx;
end$$;

create or replace function public.record_property_video_attestation(p_actor uuid,p_listing uuid,p_asset uuid,p_etag text,p_bytes bigint,
 p_width integer,p_height integer,p_duration numeric)returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb;prior public.property_video_attestations;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 perform 1 from public.capture_assets where id=p_asset for share;
 perform 1 from public.upload_operations where asset_id=p_asset for share;
 ctx:=public.property_owned_upload(p_actor,p_listing,p_asset,'video');
 if ctx->>'bucket'<>'renders'or lower(split_part(ctx->>'content_type',';',1))<>'video/mp4'
  or row(p_etag,p_bytes)is distinct from row(ctx->>'etag',(ctx->>'bytes')::bigint)
  or p_width is null or p_height is null or p_width<1920 or p_height<1080 or p_width>7680 or p_height>4320
  or p_width::bigint*9<>p_height::bigint*16 or p_duration is null or p_duration::text in('NaN','Infinity','-Infinity')
  or p_duration<=0 or p_duration>600 then raise exception 'RP400: Choose a verified landscape1080p property video';end if;
 insert into public.property_video_attestations(asset_id,actor_id,org_id,listing_id,storage_key,etag,bytes,width,height,duration_s)
 values(p_asset,p_actor,(ctx->>'org_id')::uuid,p_listing,ctx->>'storage_key',p_etag,p_bytes,p_width,p_height,p_duration)on conflict do nothing;
 select * into prior from public.property_video_attestations where asset_id=p_asset;
 if row(prior.actor_id,prior.listing_id,prior.etag,prior.bytes,prior.width,prior.height,prior.duration_s)
  is distinct from row(p_actor,p_listing,p_etag,p_bytes,p_width,p_height,p_duration)then raise exception 'RP409: Video attestation is immutable';end if;
 return jsonb_build_object('attested',true,'width',prior.width,'height',prior.height,'duration_s',prior.duration_s);
end$$;

create or replace function public.bind_property_video_source(p_actor uuid,p_listing uuid,p_asset uuid,p_photo_provenance uuid,
 p_request text,p_generation_provenance uuid,p_sha256 text,p_qc_hash text)returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb;p public.media_provenance;g public.media_provenance;s public.property_video_sources;r public.app_video_cost_reservations;paid public.cost_ledger;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 ctx:=public.property_owned_upload(p_actor,p_listing,p_asset,'photo');
 if p_photo_provenance is not null then select * into p from public.media_provenance where id=p_photo_provenance and listing_id=p_listing
  and org_id=(ctx->>'org_id')::uuid and kind in('photo_edit','virtual_stage','declutter');
  if p.id is null then raise exception 'RP404: Source photo provenance is unavailable';end if;end if;
 select * into g from public.media_provenance where id=p_generation_provenance and listing_id=p_listing and org_id=(ctx->>'org_id')::uuid and kind='reel';
 select * into r from public.app_video_cost_reservations where actor_id=p_actor and org_id=(ctx->>'org_id')::uuid and provider_request_id=p_request and feature='reel';
 select * into paid from public.cost_ledger where id=r.cost_ledger_id;
 if g.id is null or r.id is null or r.released_at is not null or r.settled_at is null or g.model_id is distinct from r.model
  or r.meta->>'task'is distinct from 'video.reel_clip'or paid.id is null or paid.total_cents<=0
  or row(paid.org_id,paid.billing_org_id,paid.feature,paid.provider,paid.model)is distinct from row(r.org_id,r.billing_org_id,r.feature,r.provider,r.model)
  or paid.meta->>'app_video_reservation_id'is distinct from r.id::text or paid.meta->>'request_id'is distinct from r.provider_request_id
  or paid.meta->>'request_key'is distinct from r.idempotency_key or paid.meta->>'stage'is distinct from 'reel'
  or not exists(select 1 from public.app_video_allowance_receipts where reservation_id=r.id and listing_id=p_listing)
  or(select count(*)from public.app_video_cost_reservations where actor_id=p_actor and org_id=r.org_id and provider_request_id=p_request)<>1
  or p_sha256 is distinct from ctx->>'sha256'or coalesce(p_qc_hash,'')!~'^[a-f0-9]{32}$'then raise exception 'RP409: Generated clip source could not be bound';end if;
 insert into public.property_video_sources(request_id,actor_id,org_id,listing_id,source_asset_id,source_provenance_id,generation_provenance_id,input_sha256,qc_source_hash)
 values(p_request,p_actor,(ctx->>'org_id')::uuid,p_listing,p_asset,p_photo_provenance,p_generation_provenance,p_sha256,p_qc_hash)on conflict do nothing;
 select * into s from public.property_video_sources where request_id=p_request;
 if row(s.actor_id,s.listing_id,s.source_asset_id,s.source_provenance_id,s.generation_provenance_id,s.input_sha256,s.qc_source_hash)
  is distinct from row(p_actor,p_listing,p_asset,p_photo_provenance,p_generation_provenance,p_sha256,p_qc_hash)then raise exception 'RP409: Clip source identity is immutable';end if;
 return jsonb_build_object('bound',true);
end$$;

create or replace function public.publish_property_video(p_listing uuid,p_asset uuid,p_manifest jsonb,p_poster uuid,p_key text)
returns public.renders language plpgsql security definer set search_path='' as $$
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
 for s in select value from jsonb_array_elements(p_manifest->'sources')loop
  perform public.property_owned_upload(actor,p_listing,(s->>'photo_asset_id')::uuid,'photo');
  if coalesce(length(s->>'photo_version_id'),0)not between 1 and 200 or coalesce(s->>'motion_kind','')not in('ai','original_photo')then raise exception 'RP400: Invalid video source';end if;
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
end$$;

create or replace function public.publish_recorded_render(p_job uuid,p_republish boolean,p_duration numeric,p_speed numeric,p_chapters jsonb,p_poster uuid)
returns public.renders language plpgsql security definer set search_path='' as $$declare r public.renders;begin
 if auth.uid()is null then raise insufficient_privilege;end if;
 if exists(select 1 from public.render_jobs j join public.property_video_compositions c on c.asset_id=j.capture_asset_id where j.id=p_job)then raise exception 'RP409: Publish the saved photo video using its typed source receipts';end if;
 if p_republish then r:=public.republish_render(p_job,p_duration,p_speed,p_chapters,p_poster);
 else r:=public.publish_render(p_job,p_duration,p_speed,p_chapters,p_poster);end if;
 update public.renders set presentation_kind='recorded_walkthrough'where id=r.id returning * into r;
 return r;
end$$;

create or replace function public.property_public_presentation(p_listing uuid)returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.property_video_compositions;a public.property_video_attestations;ctx jsonb;poster jsonb;p public.media_provenance;video jsonb:=null;theme text:='basic';s jsonb;ids uuid[]:='{}';
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if not exists(select 1 from public.listings where id=p_listing and deleted_at is null)then raise exception 'RP404: Property is unavailable';end if;
 select * into c from public.property_video_compositions where listing_id=p_listing and selected;
 if c.id is not null then
  ctx:=public.property_owned_upload(c.actor_id,p_listing,c.asset_id,'video');
  select * into a from public.property_video_attestations where asset_id=c.asset_id and etag=ctx->>'etag'and bytes=(ctx->>'bytes')::bigint;
  if a.asset_id is null then raise exception 'RP404: The selected property video is unavailable';end if;
  for s in select value from jsonb_array_elements(c.manifest->'sources')loop
   if s->>'photo_provenance_id'is not null then
    select * into p from public.media_provenance where id=(s->>'photo_provenance_id')::uuid and org_id=c.org_id and listing_id=p_listing;
    if p.id is null or p.qc->>'publishable'='false'or(p.original_key is not null and not public.studio_presenter_key_access(p_listing,p.original_key))
     or(p.altered_key is not null and not public.studio_presenter_key_access(p_listing,p.altered_key))then raise exception 'RP404: The selected video source was withdrawn';end if;
   end if;
   ids:=array_append(ids,(s->>'photo_asset_id')::uuid);
   if not public.studio_presenter_media_access_inner((s->>'photo_asset_id')::uuid)then raise exception 'RP404: The selected video source was withdrawn';end if;
  end loop;
  poster:=public.property_owned_upload(c.actor_id,p_listing,c.poster_asset_id,'photo');
  if not public.studio_presenter_media_access_inner(c.poster_asset_id)then raise exception 'RP404: The selected video poster was withdrawn';end if;
  video:=jsonb_build_object('poster_asset_id',c.poster_asset_id,'poster_key',poster->>'storage_key','composition_id',c.id,'asset_id',c.asset_id,'storage_key',a.storage_key,'width',a.width,'height',a.height,
   'duration_s',a.duration_s,'branding_policy',c.manifest->>'branding_policy','disclosure',c.disclosure,'source_asset_ids',ids);
 end if;
 if exists(select 1 from public.property_website_transactions where environment='Production'and assigned_listing_id=p_listing and revoked_at is null)then
  select coalesce(s.theme,'basic')into theme from public.property_website_settings s where listing_id=p_listing;
 end if;
 return jsonb_build_object('listing_video',video,'website_theme',coalesce(theme,'basic'));
end$$;

create or replace function public.property_website_state(p_actor uuid,p_listing uuid,p_expected_org uuid default null)returns jsonb
language plpgsql security definer set search_path='' as $$
declare o uuid;logical uuid;theme text;prod boolean;test boolean;config public.property_website_products;
begin
 if current_setting('role',true)is distinct from 'service_role'and auth.uid()is distinct from p_actor then raise insufficient_privilege;end if;
 select org_id into o from public.listings where id=p_listing and deleted_at is null;
 logical:=public.listing_owner_library(p_listing);
 if o is null or not public.listing_content_access(p_actor,p_listing,false)or(p_expected_org is not null and p_expected_org<>o and p_expected_org<>logical)then raise exception 'RP404: Property is unavailable';end if;
 select * into config from public.property_website_products where product_id='com.rendprop.app.website.premium.property';
 select s.theme into theme from public.property_website_settings s where listing_id=p_listing;
 select exists(select 1 from public.property_website_transactions where assigned_listing_id=p_listing and environment='Production'and revoked_at is null),
  exists(select 1 from public.property_website_transactions where assigned_listing_id=p_listing and environment='Sandbox'and revoked_at is null)into prod,test;
 return jsonb_build_object('listing_id',p_listing,'org_id',coalesce(p_expected_org,logical),'website_theme',case when prod then coalesce(theme,'basic')else 'basic'end,
  'selected_theme',coalesce(theme,'basic'),'purchase_enabled',coalesce(config.production_enabled,false),
  'sandbox_purchase_enabled',coalesce(config.sandbox_enabled,false),'premium_website',jsonb_build_object('unlocked',prod or test,
  'product_id','com.rendprop.app.website.premium.property','test_only',not prod and test,
  'purchase_enabled',coalesce(config.production_enabled,false),'sandbox_purchase_enabled',coalesce(config.sandbox_enabled,false)));
end$$;

create or replace function public.property_website_transaction(p_actor uuid,p_listing uuid,p_expected_org uuid,p_environment text,p_transaction text,
 p_product text,p_purchased timestamptz,p_signed timestamptz,p_revoked timestamptz,p_event text,p_notification boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior public.property_website_transactions;config public.property_website_products;result jsonb;replay boolean:=false;assigned boolean:=false;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if coalesce(p_environment,'')not in('Production','Sandbox')or p_product is distinct from 'com.rendprop.app.website.premium.property'
  or coalesce(length(p_transaction),0)not between 1 and 100 or p_purchased is null or p_signed is null
  or coalesce(p_event,'')not in('purchase','refund','revoke','refund_reversed')then raise exception 'RP400: Invalid verified property website transaction';end if;
 if not exists(select 1 from auth.users where id=p_actor and not is_anonymous)or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: A connected account is required';end if;
 if p_listing is not null then result:=public.property_website_state(p_actor,p_listing,p_expected_org);
  if not public.listing_content_access(p_actor,p_listing,true)then raise exception 'RP403: Property editing permission is required';end if;end if;
 perform pg_advisory_xact_lock(hashtextextended('property_purchase:'||p_environment||':'||p_transaction,42));
 if p_listing is not null then perform pg_advisory_xact_lock(hashtextextended('property_upgrade:'||p_environment||':'||p_listing,42));end if;
  select * into prior from public.property_website_transactions where environment=p_environment and transaction_id=p_transaction for update;
 if prior.assigned_listing_id is not null and p_listing is null then
  perform pg_advisory_xact_lock(hashtextextended('property_upgrade:'||p_environment||':'||prior.assigned_listing_id,42));end if;
 if prior.transaction_id is not null then
  replay:=true;
  if row(prior.actor_id,prior.product_id,prior.purchased_at)is distinct from row(p_actor,p_product,p_purchased)or
   (p_listing is not null and prior.assignment_identity is not null and prior.assignment_identity<>p_listing)then raise exception 'RP409: This purchase is already bound to another account or property';end if;
  -- Device restore cannot resurrect a later refund. Only a newer signed
  -- REFUND_REVERSED notification can restore a revoked transaction.
  if (p_notification and(prior.notification_signed_at is null or p_signed>prior.notification_signed_at
   or p_signed=prior.notification_signed_at and p_event in('refund','revoke')and prior.revoked_at is null))
   or(not p_notification and p_signed>=prior.signed_at and(p_event not in('refund','revoke')or prior.notification_signed_at is null or coalesce(p_revoked,p_signed)>=prior.notification_signed_at))then
   if p_event in('refund','revoke')then update public.property_website_transactions set signed_at=greatest(signed_at,p_signed),notification_signed_at=case when p_notification then p_signed else notification_signed_at end,revoked_at=coalesce(p_revoked,p_signed)where environment=p_environment and transaction_id=p_transaction;
   elsif p_event='refund_reversed'and p_notification then
    if prior.assigned_listing_id is not null and exists(select 1 from public.property_website_transactions where environment=p_environment and assigned_listing_id=prior.assigned_listing_id and transaction_id<>p_transaction and revoked_at is null)then
     raise exception 'RP409: This property already has another active upgrade';end if;
    update public.property_website_transactions set signed_at=greatest(signed_at,p_signed),notification_signed_at=case when p_notification then p_signed else notification_signed_at end,revoked_at=null where environment=p_environment and transaction_id=p_transaction;
   elsif prior.revoked_at is null then update public.property_website_transactions set signed_at=greatest(signed_at,p_signed),notification_signed_at=case when p_notification then p_signed else notification_signed_at end where environment=p_environment and transaction_id=p_transaction;end if;
  end if;
 else
  select * into config from public.property_website_products where product_id=p_product;
  if not p_notification and not(case p_environment when 'Production'then config.production_enabled else config.sandbox_enabled end)then raise exception 'RP503: Premium property website purchases are not available yet';end if;
  insert into public.property_website_transactions(environment,transaction_id,actor_id,product_id,purchased_at,signed_at,revoked_at,notification_signed_at)
  values(p_environment,p_transaction,p_actor,p_product,p_purchased,p_signed,case when p_event in('refund','revoke')or p_revoked is not null then coalesce(p_revoked,p_signed)end,case when p_notification then p_signed end);
 end if;
 select * into prior from public.property_website_transactions where environment=p_environment and transaction_id=p_transaction;
 if p_listing is not null and prior.assignment_identity is null and prior.revoked_at is null then
  select * into config from public.property_website_products where product_id=p_product;
  if not(case p_environment when 'Production'then config.production_enabled else config.sandbox_enabled end)then
   raise exception 'RP503: Premium property website purchases are not available yet';end if;end if;
 if p_listing is not null and prior.assignment_identity is null and prior.revoked_at is null and not exists(select 1 from public.property_website_transactions
  where environment=p_environment and assigned_listing_id=p_listing and revoked_at is null)then
  update public.property_website_transactions set assigned_listing_id=p_listing,assignment_identity=p_listing,assigned_at=now()
   where environment=p_environment and transaction_id=p_transaction;assigned:=true;
 end if;
 if p_listing is null then return jsonb_build_object('recorded',true,'replay',replay,'revoked',prior.revoked_at is not null);end if;
 return public.property_website_state(p_actor,p_listing,p_expected_org)||jsonb_build_object('assigned',coalesce(assigned or prior.assignment_identity=p_listing,false),
  'receipt_grants_upgrade',prior.revoked_at is null and coalesce(assigned or prior.assignment_identity=p_listing,false),'transaction_id',p_transaction,'replay',replay,'revoked',prior.revoked_at is not null,'environment',p_environment,'credit_available',prior.assignment_identity is null and not assigned and prior.revoked_at is null);
end$$;

create or replace function public.set_property_website_theme(p_actor uuid,p_listing uuid,p_expected_org uuid,p_theme text)returns jsonb
language plpgsql security definer set search_path='' as $$declare state jsonb;begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 state:=public.property_website_state(p_actor,p_listing,p_expected_org);
 if not public.listing_content_access(p_actor,p_listing,true)then raise exception 'RP403: Property editing permission is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('property_upgrade:Production:'||p_listing,42));
 perform pg_advisory_xact_lock(hashtextextended('property_upgrade:Sandbox:'||p_listing,42));
 state:=public.property_website_state(p_actor,p_listing,p_expected_org);
 if p_theme not in('basic','signature-estate','coastal-luxe')then raise exception 'RP400: Choose a supported property website theme';end if;
 if p_theme<>'basic'and state->'premium_website'->>'unlocked'is distinct from 'true'then raise exception 'RP402: This property needs its own verified website upgrade';end if;
 insert into public.property_website_settings(listing_id,theme)values(p_listing,p_theme)on conflict(listing_id)do update set theme=excluded.theme,updated_at=now();
 return public.property_website_state(p_actor,p_listing,p_expected_org);
end$$;

revoke all on function public.property_owned_upload(uuid,uuid,uuid,text),public.record_property_video_attestation(uuid,uuid,uuid,text,bigint,integer,integer,numeric),
 public.bind_property_video_source(uuid,uuid,uuid,uuid,text,uuid,text,text),public.publish_property_video(uuid,uuid,jsonb,uuid,text),
 public.property_website_state(uuid,uuid,uuid),public.property_website_transaction(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,boolean),
 public.set_property_website_theme(uuid,uuid,uuid,text),public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid),
 public.property_public_presentation(uuid),public.property_photo_reference(uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.property_owned_upload(uuid,uuid,uuid,text),public.record_property_video_attestation(uuid,uuid,uuid,text,bigint,integer,integer,numeric),
 public.bind_property_video_source(uuid,uuid,uuid,uuid,text,uuid,text,text),public.property_website_state(uuid,uuid,uuid),
 public.property_website_transaction(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,boolean),public.set_property_website_theme(uuid,uuid,uuid,text),
 public.property_public_presentation(uuid),public.property_photo_reference(uuid,uuid,uuid,uuid)to service_role;
grant execute on function public.property_owned_upload(uuid,uuid,uuid,text),public.publish_property_video(uuid,uuid,jsonb,uuid,text)to authenticated;
grant execute on function public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)to authenticated;
commit;
