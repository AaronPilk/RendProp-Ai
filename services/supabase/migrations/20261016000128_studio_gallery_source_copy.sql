-- Prepare an existing owned photo for review using one exact-byte gallery copy.
-- This never selects media, changes cover, generates an image or changes QC.
begin;
create table if not exists public.studio_gallery_copies (
 operation_id uuid primary key,
 actor_id uuid not null references auth.users(id) on delete cascade,
 org_id uuid not null references public.orgs(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 source_asset_id uuid not null references public.capture_assets(id) on delete cascade,
 source_snapshot jsonb not null,
 destination_asset_id uuid unique references public.capture_assets(id) on delete cascade,
 caption text not null check(length(caption)<=500),
 created_at timestamptz not null default clock_timestamp(),
 completed_at timestamptz,
 unique(actor_id,listing_id,source_asset_id),
 check(completed_at is null or destination_asset_id is not null)
);
alter table public.studio_gallery_copies enable row level security;
revoke all on public.studio_gallery_copies from public,anon,authenticated,service_role;

-- Internal metadata proof. A conservative renders-bucket flag is never proof
-- that a file is an Original or that an edited file has a retained original.
create or replace function public.studio_gallery_copy_source(p_org uuid,p_listing uuid,p_source uuid,p_provenance uuid default null,p_destination uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.capture_assets;o public.capture_assets;m public.media_provenance;destination_key text;visible jsonb;ids uuid[];keys text[];kind text;proof jsonb;
begin
 select *into a from public.capture_assets where id=p_source and listing_id=p_listing;
 if a.id is null or a.kind<>'photo'or a.bucket<>'renders'or a.uploaded is not true or a.upload_aborted is true
  or a.storage_key is distinct from public.studio_photo_asset_key(a.id,p_org,p_listing)
  or starts_with(a.storage_key,'renders/'||p_org||'/'||p_listing||'/gallery-')
  or a.bytes is null or a.bytes not between 1 and 10485760 or a.sha256 is null or a.sha256!~'^[a-f0-9]{64}$'
  or a.content_type is null or a.content_type not in('image/jpeg','image/png','image/webp')then
  raise exception'RP409: This source needs a verified JPG, PNG or WebP original before it can be prepared';end if;
 if p_destination is not null then select storage_key into destination_key from public.capture_assets where id=p_destination and listing_id=p_listing;end if;
 if p_provenance is null then
  if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key)>1 then raise exception'RP409: This photo has conflicting edit history';end if;
  select *into m from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key;
 else
  select *into m from public.media_provenance where id=p_provenance and listing_id=p_listing and org_id=p_org
   and(altered_key=a.storage_key or destination_key is not null and altered_key=destination_key);
  if m.id is null then raise exception'RP409: The photo edit history changed. Refresh before preparing it';end if;
 end if;
 ids:=array[a.id];keys:=array[a.storage_key];
 if m.id is not null then
  kind:='altered';
  if m.org_id is distinct from p_org or m.kind not in('photo_edit','virtual_stage','declutter')or nullif(btrim(m.disclosure),'')is null
   or(m.qc is not null and(m.qc->'publishable'is distinct from'true'::jsonb or coalesce(m.qc->>'action','')not in('accept','pass')))
   or exists(select 1 from public.photo_edit_evidence where provenance_id=m.id and(state<>'accept'or purpose='calibration'))then
   raise exception'RP409: This edited photo has not passed its required accuracy review';end if;
  if m.original_key is null or m.original_key=a.storage_key or(select count(*)from public.capture_assets ca where ca.listing_id=p_listing and ca.storage_key=m.original_key and ca.kind='photo'and ca.uploaded and not ca.upload_aborted)<>1 then
   raise exception'RP409: This edited photo needs its retained original before it can be prepared';end if;
  select *into o from public.capture_assets ca where ca.listing_id=p_listing and ca.storage_key=m.original_key and ca.kind='photo'and ca.uploaded and not ca.upload_aborted;
  if o.bucket<>'renders'or not starts_with(o.storage_key,'renders/'||p_org||'/'||p_listing||'/')then raise exception'RP409: Save the retained original in the photo library before preparing this edited version';end if;
  ids:=array_append(ids,o.id);keys:=array_append(keys,o.storage_key);
  proof:=jsonb_build_object('id',m.id,'kind',m.kind,'edit',m.edit,'original_asset_id',o.id,'original_key',o.storage_key,'original_sha256',o.sha256,'original_bytes',o.bytes,'disclosure',m.disclosure,'qc',m.qc);
 else
  kind:='original';
  if not exists(select 1 from public.upload_reservations r where r.asset_id=a.id and r.org_id=p_org and r.listing_id=p_listing and r.state='completed'and r.spec->>'key_role'='original')then
   raise exception'RP409: This saved source has no verified original or edit history';end if;
  proof:='null'::jsonb;
 end if;
 visible:=public.studio_presenter_media_visibility(p_listing,ids,'{}'::uuid[],keys);
 if exists(select 1 from unnest(ids)x where visible#>array['assets',x::text]is distinct from'true'::jsonb)
  or exists(select 1 from unnest(keys)x where visible#>array['keys',x]is distinct from'true'::jsonb)then raise exception'RP409: This photo or its original was withdrawn';end if;
 return jsonb_build_object('asset_id',a.id,'key',a.storage_key,'bytes',a.bytes,'sha256',a.sha256,'mime',a.content_type,'kind',kind,'provenance',proof);
end$$;
revoke all on function public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)from public,anon,authenticated,service_role;

create or replace function public.studio_gallery_copy_response(p_actor uuid,p_org uuid,p_listing uuid,p_operation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.studio_gallery_copies;p public.photos;copy public.capture_assets;current_source jsonb;
begin
 select *into r from public.studio_gallery_copies where operation_id=p_operation and actor_id=p_actor and org_id=p_org and listing_id=p_listing;
 if r.operation_id is null then raise exception'RP404: Prepared photo not found';end if;
 current_source:=public.studio_gallery_copy_source(p_org,p_listing,r.source_asset_id,(r.source_snapshot#>>'{provenance,id}')::uuid,case when r.completed_at is not null then r.destination_asset_id else null end);
 if current_source is distinct from r.source_snapshot then raise exception'RP409: The source photo changed. Its existing copy is kept for review';end if;
 if r.destination_asset_id is not null then select *into copy from public.capture_assets where id=r.destination_asset_id and listing_id=p_listing;end if;
 if r.completed_at is not null then
  select *into p from public.photos where id=r.destination_asset_id and listing_id=p_listing;
  if p.id is null or copy.id is null or copy.uploaded is not true or copy.upload_aborted is true or copy.sha256 is distinct from r.source_snapshot->>'sha256'
   or copy.bytes is distinct from(r.source_snapshot->>'bytes')::bigint or copy.content_type is distinct from r.source_snapshot->>'mime'
   or coalesce(nullif(p.enhanced_key,''),p.original_key)is distinct from copy.storage_key then raise exception'RP409: This prepared version changed or was removed. Refresh the property';end if;
 end if;
 return jsonb_build_object('schema',1,'actor_id',p_actor,'org_id',p_org,'library_org_id',public.listing_owner_library(p_listing),'listing_id',p_listing,
  'operation_id',r.operation_id,'source',r.source_snapshot,'destination_asset_id',r.destination_asset_id,
  'destination',case when copy.id is null then null else jsonb_build_object('asset_id',copy.id,'key',copy.storage_key,'bytes',copy.bytes,'mime',copy.content_type,'uploaded',copy.uploaded)end,
  'complete',r.completed_at is not null,'photo',case when p.id is null then null else to_jsonb(p)end);
end$$;
revoke all on function public.studio_gallery_copy_response(uuid,uuid,uuid,uuid)from public,anon,authenticated,service_role;

create or replace function public.studio_gallery_copy_prepare(p_actor uuid,p_org uuid,p_listing uuid,p_source uuid,p_operation uuid,p_caption text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.studio_gallery_copies;snapshot jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.studio_photo_authority(p_actor,p_org,p_listing);
 if p_operation is null or p_caption is null or length(p_caption)>500 then raise exception'RP400: Choose a photo and a caption of 500 characters or fewer';end if;
 if exists(select 1 from public.studio_gallery_copies where operation_id=p_operation and row(actor_id,org_id,listing_id,source_asset_id)is distinct from row(p_actor,p_org,p_listing,p_source))then raise exception'RP409: The prepared photo request belongs to a different source';end if;
 select *into r from public.studio_gallery_copies where actor_id=p_actor and listing_id=p_listing and source_asset_id=p_source for update;
 if r.operation_id is null then
  if exists(select 1 from public.studio_gallery_copies where operation_id=p_operation)then raise exception'RP409: The prepared photo request belongs to a different source';end if;
  snapshot:=public.studio_gallery_copy_source(p_org,p_listing,p_source);
  insert into public.studio_gallery_copies(operation_id,actor_id,org_id,listing_id,source_asset_id,source_snapshot,caption)
   values(p_operation,p_actor,p_org,p_listing,p_source,snapshot,p_caption)returning *into r;
 end if;
 return public.studio_gallery_copy_response(p_actor,p_org,p_listing,r.operation_id);
end$$;
revoke all on function public.studio_gallery_copy_prepare(uuid,uuid,uuid,uuid,uuid,text)from public,anon,authenticated;
grant execute on function public.studio_gallery_copy_prepare(uuid,uuid,uuid,uuid,uuid,text)to service_role;

create or replace function public.studio_gallery_copy_status(p_actor uuid,p_org uuid,p_listing uuid,p_operation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.studio_photo_authority(p_actor,p_org,p_listing);
 return public.studio_gallery_copy_response(p_actor,p_org,p_listing,p_operation);
end$$;
revoke all on function public.studio_gallery_copy_status(uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.studio_gallery_copy_status(uuid,uuid,uuid,uuid)to service_role;

create or replace function public.studio_gallery_copy_bind(p_actor uuid,p_org uuid,p_listing uuid,p_operation uuid,p_destination uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.studio_gallery_copies;a public.capture_assets;u public.upload_reservations;response jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.studio_photo_authority(p_actor,p_org,p_listing);
 select *into r from public.studio_gallery_copies where operation_id=p_operation and actor_id=p_actor and org_id=p_org and listing_id=p_listing for update;
 if r.operation_id is null then raise exception'RP404: Prepared photo not found';end if;
 response:=public.studio_gallery_copy_response(p_actor,p_org,p_listing,p_operation);
 if r.destination_asset_id is not null then
  if r.destination_asset_id is distinct from p_destination then raise exception'RP409: This photo already has a different prepared copy';end if;
  return response;
 end if;
 select *into a from public.capture_assets where id=p_destination and listing_id=p_listing for update;
 select *into u from public.upload_reservations where asset_id=p_destination for update;
 if a.id is null or u.asset_id is null or u.actor_id is distinct from p_actor or u.org_id is distinct from p_org or u.listing_id is distinct from p_listing
  or u.state not in('open','completed')or u.spec->>'key_role'is distinct from'gallery'or a.kind<>'photo'or a.bucket<>'renders'or a.upload_aborted is true
  or a.bytes is distinct from(r.source_snapshot->>'bytes')::bigint or a.content_type is distinct from r.source_snapshot->>'mime'
  or not starts_with(a.storage_key,'renders/'||p_org||'/'||p_listing||'/gallery-')then raise exception'RP409: The upload does not match this exact prepared photo';end if;
 update public.studio_gallery_copies set destination_asset_id=a.id where operation_id=r.operation_id;
 return public.studio_gallery_copy_response(p_actor,p_org,p_listing,p_operation);
end$$;
revoke all on function public.studio_gallery_copy_bind(uuid,uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.studio_gallery_copy_bind(uuid,uuid,uuid,uuid,uuid)to service_role;

-- The Edge caller independently hashes BOTH bounded stored objects before this
-- service-only transaction. A browser hash/metadata field is not that proof.
create or replace function public.studio_gallery_copy_finish(p_actor uuid,p_org uuid,p_listing uuid,p_operation uuid,p_verified_sha256 text,p_verified_bytes bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.studio_gallery_copies;a public.capture_assets;m public.media_provenance;response jsonb;attached jsonb;selection_before jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.studio_photo_authority(p_actor,p_org,p_listing);
 select *into r from public.studio_gallery_copies where operation_id=p_operation and actor_id=p_actor and org_id=p_org and listing_id=p_listing for update;
 if r.operation_id is null then raise exception'RP404: Prepared photo not found';end if;
 response:=public.studio_gallery_copy_response(p_actor,p_org,p_listing,p_operation);
 if r.completed_at is not null then return response;end if;
 select jsonb_build_object('ids',gallery_asset_ids,'cover',main_photo_key)into selection_before from public.listings where id=p_listing;
 select *into a from public.capture_assets where id=r.destination_asset_id and listing_id=p_listing for update;
 if a.id is null or a.uploaded is not true or a.upload_aborted is true or a.kind<>'photo'or a.bucket<>'renders'
  or p_verified_sha256 is distinct from r.source_snapshot->>'sha256'or p_verified_bytes is distinct from(r.source_snapshot->>'bytes')::bigint
  or a.bytes is distinct from p_verified_bytes or a.content_type is distinct from r.source_snapshot->>'mime'
  or(a.sha256 is not null and a.sha256 is distinct from p_verified_sha256)then raise exception'RP409: The uploaded copy is not the exact saved photo';end if;
 update public.capture_assets set sha256=p_verified_sha256 where id=a.id and sha256 is null;
 if r.source_snapshot->>'kind'='altered'then
  select *into m from public.media_provenance where id=(r.source_snapshot#>>'{provenance,id}')::uuid and org_id=p_org and listing_id=p_listing for update;
  if m.altered_key is distinct from r.source_snapshot->>'key'or m.original_key is distinct from r.source_snapshot#>>'{provenance,original_key}'then raise exception'RP409: The edit history changed while preparing this photo';end if;
  -- Same exact-byte alias transition as the existing save path. Existing QC,
  -- calibration and immutable-provenance triggers remain in force.
  update public.media_provenance set altered_key=a.storage_key where id=m.id;
 end if;
 attached:=public.studio_attach_photo(p_actor,p_org,p_listing,a.id,r.caption,m.id);
 if(select jsonb_build_object('ids',gallery_asset_ids,'cover',main_photo_key)from public.listings where id=p_listing)is distinct from selection_before then raise exception'RP409: Preparing a photo must not change the listing selection or cover';end if;
 update public.studio_gallery_copies set completed_at=clock_timestamp()where operation_id=r.operation_id;
 return public.studio_gallery_copy_response(p_actor,p_org,p_listing,p_operation);
end$$;
revoke all on function public.studio_gallery_copy_finish(uuid,uuid,uuid,uuid,text,bigint)from public,anon,authenticated;
grant execute on function public.studio_gallery_copy_finish(uuid,uuid,uuid,uuid,text,bigint)to service_role;
commit;
