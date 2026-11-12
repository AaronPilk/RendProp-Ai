-- Partial/cloud libraries must never replace photos they have not downloaded.
-- Keep a bounded immutable receipt per explicit action so replay cannot remove
-- an asset someone deliberately re-added later. No media bytes/history change.
create table if not exists public.listing_gallery_removals (
 actor_id uuid not null references public.profiles(id) on delete cascade,
 operation_id uuid not null,
 org_id uuid not null references public.orgs(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 requested_asset_ids uuid[] not null check(cardinality(requested_asset_ids) between 1 and 100),
 expected_gallery_asset_ids uuid[],
 expected_main_photo_key text check(expected_main_photo_key is null or length(expected_main_photo_key)<=500),
 removed_asset_ids uuid[] not null check(cardinality(removed_asset_ids)<=100),
 created_at timestamptz not null default now(),
 primary key(actor_id,operation_id)
);
create index if not exists listing_gallery_removals_listing_idx on public.listing_gallery_removals(listing_id);
alter table public.listing_gallery_removals enable row level security;
revoke all on public.listing_gallery_removals from public,anon,authenticated,service_role;
grant select on public.listing_gallery_removals to service_role;

create or replace function public.remove_listing_gallery(
 p_user uuid,p_org uuid,p_listing uuid,p_operation uuid,p_remove uuid[],p_expected uuid[],p_expected_main text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 l public.listings;
 receipt public.listing_gallery_removals;
 selected uuid[];
 remaining uuid[];
 removed uuid[];
 valid_count integer;
 prefix text:='renders/'||p_org::text||'/'||p_listing::text||'/gallery-';
begin
 if current_setting('role',true) is distinct from 'service_role' then
  raise insufficient_privilege using message='service role required';end if;
 if p_user is null or p_org is null or p_listing is null or p_operation is null or p_remove is null
  or cardinality(p_remove) not between 1 and 100 or coalesce(array_ndims(p_remove),1)<>1
  or array_position(p_remove,null)is not null
  or cardinality(p_remove)<>(select count(distinct x)from unnest(p_remove)x)
  or (p_expected is not null and(cardinality(p_expected)>100 or coalesce(array_ndims(p_expected),1)<>1
   or array_position(p_expected,null)is not null
   or cardinality(p_expected)<>(select count(distinct x)from unnest(p_expected)x)))
  or length(p_expected_main)>500 then raise exception 'RP400: Choose distinct uploaded photos with their saved gallery snapshot';end if;
 -- Same authority/lock order as append/account writes; actor lock also fences
 -- reuse of an operation UUID against a different listing concurrently.
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=p_org for update;
 select * into l from public.listings where id=p_listing and org_id=p_org for update;
 perform public.client_listing_access(p_user,p_org,p_listing,true);
 select * into receipt from public.listing_gallery_removals where actor_id=p_user and operation_id=p_operation;
 if found then
  if row(receipt.org_id,receipt.listing_id,receipt.requested_asset_ids,receipt.expected_gallery_asset_ids,receipt.expected_main_photo_key)
   is distinct from row(p_org,p_listing,p_remove,p_expected,p_expected_main)
  then raise exception 'RP409: This saved photo-removal operation belongs to another request';end if;
  -- Return the current row, not the original snapshot: a later explicit add
  -- remains visible and is never undone by delivery of this earlier receipt.
  return to_jsonb(l)||jsonb_build_object('gallery_remove',jsonb_build_object(
   'operation_id',p_operation,'actor_id',p_user,'replayed',true,'requested_asset_ids',receipt.requested_asset_ids,'removed_asset_ids',receipt.removed_asset_ids));
 end if;
 if l.gallery_asset_ids is distinct from p_expected or l.main_photo_key is distinct from p_expected_main then
  raise exception using errcode='PT409',message='RP409: The listing photo selection changed';end if;
 select count(*)into valid_count from public.capture_assets a where a.id=any(p_remove)and a.listing_id=p_listing
  and a.kind='photo'and a.bucket='renders'and a.uploaded
  and left(a.storage_key,length(prefix))=prefix and length(a.storage_key)>length(prefix)and length(a.storage_key)<=500
  and position('/'in substring(a.storage_key from length(prefix)+1))=0 and position(chr(92)in a.storage_key)=0
  and position('%'in a.storage_key)=0 and position('?'in a.storage_key)=0 and position('#'in a.storage_key)=0
  and a.storage_key!~'[[:cntrl:]]';
 if valid_count<>cardinality(p_remove)then raise exception 'RP400: Remove only completed gallery photos belonging to this listing';end if;
 if l.gallery_asset_ids is null then
  -- Match the legacy public query's FIRST100 eligible uploads and exact order.
  -- Do not infer edit families or discard an unknown/revoked historical asset;
  -- public reads still independently enforce its current media visibility.
  select coalesce(array_agg(a.id order by a.created_at,a.id),'{}'::uuid[])into selected from(
   select a.id,a.created_at from public.capture_assets a where a.listing_id=p_listing and a.kind='photo'
    and a.bucket='renders'and a.uploaded and left(a.storage_key,length(prefix))=prefix
    and length(a.storage_key)>length(prefix)and length(a.storage_key)<=500
    and position('/'in substring(a.storage_key from length(prefix)+1))=0 and position(chr(92)in a.storage_key)=0
    and position('%'in a.storage_key)=0 and position('?'in a.storage_key)=0 and position('#'in a.storage_key)=0
    and a.storage_key!~'[[:cntrl:]]' order by a.created_at,a.id limit 100
  )a;
 else selected:=l.gallery_asset_ids;end if;
 select coalesce(array_agg(id order by n)filter(where not(id=any(p_remove))),'{}'::uuid[]),
  coalesce(array_agg(id order by n)filter(where id=any(p_remove)),'{}'::uuid[])
 into remaining,removed from unnest(selected)with ordinality x(id,n);
 update public.listings set gallery_asset_ids=remaining,
  main_photo_key=case when exists(select 1 from public.capture_assets a where a.id=any(removed)
   and a.listing_id=p_listing and a.storage_key=l.main_photo_key)then null else l.main_photo_key end
 where id=p_listing and org_id=p_org and deleted_at is null returning * into l;
 if not found then raise exception 'RP404: Listing not found in this workspace';end if;
 insert into public.listing_gallery_removals(actor_id,operation_id,org_id,listing_id,requested_asset_ids,
  expected_gallery_asset_ids,expected_main_photo_key,removed_asset_ids)
 values(p_user,p_operation,p_org,p_listing,p_remove,p_expected,p_expected_main,removed);
 return to_jsonb(l)||jsonb_build_object('gallery_remove',jsonb_build_object(
  'operation_id',p_operation,'actor_id',p_user,'replayed',false,'requested_asset_ids',p_remove,'removed_asset_ids',removed));
end;
$$;
revoke all on function public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text) from public,anon,authenticated;
grant execute on function public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text) to service_role;

-- Read only the current selection's immutable upload identities. Imported
-- photos-table UUIDs and local filenames are not capture/gallery asset IDs.
create or replace function public.listing_gallery_snapshot(p_user uuid,p_org uuid,p_listing uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.listings; ids uuid[]; keys text[]; visible jsonb; assets jsonb;
 prefix text:='renders/'||p_org::text||'/'||p_listing::text||'/gallery-';
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 perform public.client_listing_access(p_user,p_org,p_listing,false);
 select *into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null;
 if not found then raise exception 'RP404: Listing not found in this workspace';end if;
 select coalesce(array_agg(a.id order by a.n),'{}'::uuid[]),coalesce(array_agg(a.storage_key order by a.n),'{}'::text[])into ids,keys from(
  select a.id,a.storage_key,case when l.gallery_asset_ids is null then row_number()over(order by a.created_at,a.id)
   else array_position(l.gallery_asset_ids,a.id)::bigint end n
  from public.capture_assets a where a.listing_id=p_listing and a.kind='photo'and a.bucket='renders'and a.uploaded
   and(l.gallery_asset_ids is null or a.id=any(l.gallery_asset_ids))
   and left(a.storage_key,length(prefix))=prefix and length(a.storage_key)>length(prefix)and length(a.storage_key)<=500
   and position('/'in substring(a.storage_key from length(prefix)+1))=0 and position(chr(92)in a.storage_key)=0
   and position('%'in a.storage_key)=0 and position('?'in a.storage_key)=0 and position('#'in a.storage_key)=0
   and a.storage_key!~'[[:cntrl:]]'order by n limit 100
 )a;
 visible:=public.studio_presenter_media_visibility(p_listing,ids,'{}'::uuid[],keys);
 select coalesce(jsonb_agg(jsonb_build_object('asset_id',a.id,'sha256',a.sha256,'bytes',a.bytes)order by array_position(ids,a.id)),'[]'::jsonb)
 into assets from public.capture_assets a where a.id=any(ids)and a.listing_id=p_listing
  and a.sha256~'^[a-f0-9]{64}$'and a.bytes>0 and a.bytes<=9007199254740991
  and coalesce((visible->'assets'->>a.id::text)::boolean,false)
  and coalesce((visible->'keys'->>a.storage_key)::boolean,false);
 return to_jsonb(l)||jsonb_build_object('gallery_assets',assets);
end;
$$;
revoke all on function public.listing_gallery_snapshot(uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.listing_gallery_snapshot(uuid,uuid,uuid)to service_role;
