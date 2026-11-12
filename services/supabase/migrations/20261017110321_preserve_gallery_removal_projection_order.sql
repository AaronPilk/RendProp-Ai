begin;
-- Correct only legacy NULL ordering in the existing removal authority. Modern
-- explicit selection, full CAS, cover clearing and immutable replay are exact.
do $guard$declare f record;begin
 select p.*,l.lanname into f from pg_proc p join pg_language l on l.oid=p.prolang
 where p.oid=to_regprocedure('public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)');
 if not found or md5(f.prosrc)not in('83f4773cc6fd293891817cf75f4f54d7','5d70d5ef8b25d1ccc3bc1c2ac18b57e0')
  or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""']
  or f.proacl is distinct from array['postgres=X/postgres','service_role=X/postgres']::aclitem[]
  or pg_get_userbyid(f.proowner)is distinct from'postgres' or f.lanname is distinct from'plpgsql'
  or f.prorettype is distinct from'jsonb'::regtype or f.proretset or f.prokind<>'f'
  or f.proisstrict or f.proleakproof or f.provolatile<>'v' or f.proparallel<>'u'
  or f.proargnames is distinct from array['p_user','p_org','p_listing','p_operation','p_remove','p_expected','p_expected_main']
  or f.proargmodes is not null or f.proallargtypes is not null
  or f.pronargs<>7 or f.pronargdefaults<>0 or f.proargdefaults is not null or f.provariadic<>0 then
  raise exception'Review changed shared gallery removal authority';end if;
end$guard$;
create or replace function public.remove_listing_gallery(
 p_user uuid,p_org uuid,p_listing uuid,p_operation uuid,p_remove uuid[],p_expected uuid[],p_expected_main text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 l public.listings;
 receipt public.listing_gallery_removals;
 selected uuid[];
 mapped uuid[];ordered uuid[];item uuid;position_in_mapped integer:=1;
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
 -- Match the modern projection's mapped slots before visibility filtering.
  -- Keep the same first100 candidates and every unknown/hidden anchor; only
  -- the ordering of already mapped candidate slots follows saved Studio order.
  select coalesce(array_agg(x.asset_id order by x.sort,x.created_at,x.photo_id,x.asset_id),'{}'::uuid[])into mapped from(
   select distinct on(a.id)a.id asset_id,p.sort,p.created_at,p.id photo_id
   from public.capture_assets a join public.photos p on p.listing_id=p_listing and coalesce(nullif(p.enhanced_key,''),p.original_key)=a.storage_key
   where a.id=any(selected)and a.listing_id=p_listing order by a.id,p.sort,p.created_at,p.id)x;
  ordered:='{}'::uuid[];foreach item in array selected loop
   if item=any(mapped)then ordered:=array_append(ordered,mapped[position_in_mapped]);position_in_mapped:=position_in_mapped+1;
   else ordered:=array_append(ordered,item);end if;
  end loop;selected:=ordered;
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

do $verify$begin
 if(select md5(prosrc)from pg_proc where oid='public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)'::regprocedure)is distinct from'5d70d5ef8b25d1ccc3bc1c2ac18b57e0'then raise exception'Shared gallery removal body did not match';end if;
end$verify$;
commit;
