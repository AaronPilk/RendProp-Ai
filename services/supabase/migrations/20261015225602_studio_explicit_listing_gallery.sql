-- Preserve the currently served legacy gallery before new gallery uploads;
-- retaining a Studio version must not silently select it for publication.
begin;
do $new_functions$begin
 if to_regprocedure('public.listing_gallery_projection(uuid)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.listing_gallery_projection(uuid)'))is distinct from'1ea8c119e5a5f9849b10f16647ddfb62'then raise exception'Review changed listing_gallery_projection';end if;
 if to_regprocedure('public.freeze_listing_gallery_for_upload(uuid,uuid,uuid)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.freeze_listing_gallery_for_upload(uuid,uuid,uuid)'))is distinct from'6da3b9ff16f232dbad8e9e897d883025'then raise exception'Review changed freeze_listing_gallery_for_upload';end if;
 if to_regprocedure('public.studio_gallery_photo_choice(uuid,uuid,uuid)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.studio_gallery_photo_choice(uuid,uuid,uuid)'))is distinct from'eb0931ac25a4f16e3902dfb01b2e3ac1'then raise exception'Review changed studio_gallery_photo_choice';end if;
 if to_regprocedure('public.studio_gallery_selection_snapshot(uuid,uuid,uuid)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.studio_gallery_selection_snapshot(uuid,uuid,uuid)'))is distinct from'804615f7b20257b2b70a4c49d4e91840'then raise exception'Review changed studio_gallery_selection_snapshot';end if;
 if to_regprocedure('public.studio_gallery_selection_change(uuid,uuid,uuid,text,uuid,jsonb,jsonb,jsonb,boolean)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.studio_gallery_selection_change(uuid,uuid,uuid,text,uuid,jsonb,jsonb,jsonb,boolean)'))is distinct from'36b0c7d7480a6f8a449bf99f15921483'then raise exception'Review changed studio_gallery_selection_change';end if;
end$new_functions$;

create or replace function public.listing_gallery_projection(p_listing uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare l public.listings;ids uuid[];keys text[];visible jsonb;ordered uuid[];known uuid[];item uuid;n integer:=1;
 prefix text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select x.*into l from public.listings x join public.orgs o on o.id=x.org_id where x.id=p_listing and x.deleted_at is null and o.deleted_at is null;
 if not found then raise exception'RP404: Property not found';end if;
 prefix:='renders/'||l.org_id||'/'||l.id||'/gallery-';
 if l.gallery_asset_ids is not null then
  if cardinality(l.gallery_asset_ids)>100 or coalesce(array_ndims(l.gallery_asset_ids),1)<>1 or array_position(l.gallery_asset_ids,null)is not null then raise exception'RP409: Review the listing photo selection before continuing';end if;
  ids:=l.gallery_asset_ids;
 else
  select coalesce(array_agg(a.id order by a.created_at,a.id),'{}'::uuid[])into ids from(
   select id,created_at from public.capture_assets a where a.listing_id=l.id and a.kind='photo'and a.bucket='renders'and a.uploaded
    and left(a.storage_key,length(prefix))=prefix and length(a.storage_key)>length(prefix)and length(a.storage_key)<=500
    and position('/'in substr(a.storage_key,length(prefix)+1))=0 and a.storage_key!~'[?#%\\[:cntrl:]]'
   order by a.created_at,a.id limit 100)a;
  -- Only permute mapped slots in the existing candidate set. Unknown legacy
  -- uploads keep their anchors; saved history never adds a candidate here.
  select coalesce(array_agg(x.asset_id order by x.sort,x.created_at,x.photo_id,x.asset_id),'{}'::uuid[])into known from(
   select distinct on(a.id)a.id asset_id,p.sort,p.created_at,p.id photo_id
   from public.capture_assets a join public.photos p on p.listing_id=l.id and coalesce(nullif(p.enhanced_key,''),p.original_key)=a.storage_key
   where a.id=any(ids)and a.listing_id=l.id order by a.id,p.sort,p.created_at,p.id)x;
  ordered:='{}'::uuid[];foreach item in array ids loop
   if item=any(known)then ordered:=array_append(ordered,known[n]);n:=n+1;else ordered:=array_append(ordered,item);end if;
  end loop;ids:=ordered;
 end if;
 select coalesce(array_agg(distinct a.storage_key),'{}'::text[])into keys from public.capture_assets a where a.id=any(ids)and a.listing_id=l.id;
 visible:=public.studio_presenter_media_visibility(l.id,ids,'{}'::uuid[],keys);
 select coalesce(array_agg(x.id order by x.n),'{}'::uuid[])into ordered from unnest(ids)with ordinality x(id,n)
  join public.capture_assets a on a.id=x.id and a.listing_id=l.id
  where visible#>array['assets',a.id::text]='true'::jsonb and visible#>array['keys',a.storage_key]='true'::jsonb;
 return jsonb_build_object('org_id',l.org_id,'listing_id',l.id,'gallery_asset_ids',l.gallery_asset_ids,'main_photo_key',l.main_photo_key,'effective_asset_ids',ordered);
end$$;
revoke all on function public.listing_gallery_projection(uuid)from public,anon,authenticated;
grant execute on function public.listing_gallery_projection(uuid)to service_role;

create or replace function public.freeze_listing_gallery_for_upload(p_actor uuid,p_org uuid,p_listing uuid)
returns void language plpgsql security definer set search_path='' as $$
declare l public.listings;s jsonb;ids uuid[];begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 -- Upload reservation already holds org->listing; settlement already holds
 -- listing->asset. Re-enter only the listing lock, never an earlier lock.
 select *into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not public.listing_content_access(p_actor,p_listing,true)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed')then raise exception'RP403: upload workspace is not writable';end if;
 if l.gallery_asset_ids is not null then return;end if;
 s:=public.listing_gallery_projection(p_listing);
 select coalesce(array_agg(value::uuid order by n),'{}'::uuid[])into ids from jsonb_array_elements_text(s->'effective_asset_ids')with ordinality x(value,n);
 if l.main_photo_key is not null and not exists(select 1 from public.capture_assets where listing_id=l.id and id=any(ids)and storage_key=l.main_photo_key)then
  raise exception'RP409: Review the existing cover and listing photos before uploading another gallery photo';end if;
 update public.listings set gallery_asset_ids=ids where id=l.id and org_id=p_org and gallery_asset_ids is null;
 if(select main_photo_key from public.listings where id=l.id)is distinct from l.main_photo_key then raise exception'RP409: The existing cover must be preserved';end if;
end$$;
revoke all on function public.freeze_listing_gallery_for_upload(uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.freeze_listing_gallery_for_upload(uuid,uuid,uuid)to service_role;

-- A single validated upload transaction owns both the selection freeze and
-- reservation. Idempotent reservations/settlements return before these seams.
do $upload$declare b text;needle text;patched text;begin
 select pg_get_functiondef(oid)into b from pg_proc where oid='public.reserve_upload_assets(uuid,jsonb)'::regprocedure;
 if(select md5(prosrc)from pg_proc where oid='public.reserve_upload_assets(uuid,jsonb)'::regprocedure)='b5ddb4e2bb4f8b81fa5e6c44d83dd860'then null;
 elsif(select md5(prosrc)from pg_proc where oid='public.reserve_upload_assets(uuid,jsonb)'::regprocedure)is distinct from'bf485a75663bd67d1ecb94d469b527b4'then raise exception'Review changed gallery upload reservation';
 else
  needle:='    insert into capture_assets(id,listing_id,kind,bucket,storage_key,sha256,bytes,content_type,content_type_declared,';
  if(length(b)-length(replace(b,needle,'')))<>length(needle)then raise exception'Review changed upload insertion seam';end if;
  patched:='    if s->>''kind''=''photo''and s->>''bucket''=''renders''and s->>''storage_key''like ''%/gallery-%''then'||E'\n'||'      perform public.freeze_listing_gallery_for_upload(p_actor,l.org_id,l.id);'||E'\n'||'    end if;'||E'\n'||needle;
  execute replace(b,needle,patched);
 end if;
 select pg_get_functiondef(oid)into b from pg_proc where oid='public.settle_upload_reservation(uuid,boolean,uuid,jsonb)'::regprocedure;
 if(select md5(prosrc)from pg_proc where oid='public.settle_upload_reservation(uuid,boolean,uuid,jsonb)'::regprocedure)='969802c6b012530f58756e38279c27b7'then null;
 elsif(select md5(prosrc)from pg_proc where oid='public.settle_upload_reservation(uuid,boolean,uuid,jsonb)'::regprocedure)is distinct from'61b54d9e84d089b9f71318a8f44dce94'then raise exception'Review changed gallery upload completion';
 else
  needle:='    update capture_assets set uploaded=true,upload_id=null,storage_key=coalesce(op.object_key,storage_key),';
  if(length(b)-length(replace(b,needle,'')))<>length(needle)then raise exception'Review changed upload completion seam';end if;
  patched:='    if a.kind=''photo''and a.bucket=''renders''and a.storage_key like ''%/gallery-%''then'||E'\n'||'      perform public.freeze_listing_gallery_for_upload(r.actor_id,r.org_id,r.listing_id);'||E'\n'||'    end if;'||E'\n'||needle;
  execute replace(b,needle,patched);
 end if;
end$upload$;

create or replace function public.studio_gallery_photo_choice(p_org uuid,p_listing uuid,p_photo uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p public.photos;a public.capture_assets;o public.capture_assets;m public.media_provenance;key text;altered boolean;visible jsonb;ids uuid[];keys text[];begin
 select *into p from public.photos where id=p_photo and listing_id=p_listing;
 if not found then return jsonb_build_object('photo_id',p_photo,'asset_id',null,'can_use',false,'review_required',false);end if;
 key:=coalesce(nullif(p.enhanced_key,''),p.original_key);altered:=coalesce(p.is_staged,false)or nullif(p.enhanced_key,'')is not null;
 if(select count(*)from public.capture_assets where listing_id=p_listing and storage_key=key)<>1 then return jsonb_build_object('photo_id',p_photo,'asset_id',null,'can_use',false,'review_required',altered);end if;
 select *into a from public.capture_assets where listing_id=p_listing and storage_key=key;
 if a.kind<>'photo'or a.bucket<>'renders'or a.uploaded is not true or a.upload_aborted is true
  or not starts_with(key,'renders/'||p_org||'/'||p_listing||'/gallery-')or length(key)>500
  or position('/'in substr(key,length('renders/'||p_org||'/'||p_listing||'/gallery-')+1))>0 or key~'[?#%\\[:cntrl:]]'then
  return jsonb_build_object('photo_id',p_photo,'asset_id',null,'can_use',false,'review_required',altered);end if;
 ids:=array[a.id];keys:=array[key];
 if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=key)>1 then return jsonb_build_object('photo_id',p_photo,'asset_id',a.id,'can_use',false,'review_required',true);end if;
 select *into m from public.media_provenance where listing_id=p_listing and altered_key=key;
 altered:=altered or m.id is not null;
 if altered then
  if m.id is null or m.org_id is distinct from p_org or m.original_key is distinct from p.original_key or nullif(btrim(m.disclosure),'')is null
   or(m.qc is not null and(m.qc->'publishable'is distinct from'true'::jsonb or coalesce(m.qc->>'action','')not in('accept','pass')))
   or exists(select 1 from public.photo_edit_evidence where provenance_id=m.id and state<>'accept')then
   return jsonb_build_object('photo_id',p_photo,'asset_id',a.id,'can_use',false,'review_required',true);end if;
  if(select count(*)from public.capture_assets where listing_id=p_listing and storage_key=m.original_key and kind='photo'and uploaded)<>1 then return jsonb_build_object('photo_id',p_photo,'asset_id',a.id,'can_use',false,'review_required',true);end if;
  select *into o from public.capture_assets where listing_id=p_listing and storage_key=m.original_key and kind='photo'and uploaded;
  if o.bucket not in('uploads','renders')or not starts_with(o.storage_key,o.bucket||'/'||p_org||'/'||p_listing||'/')or o.upload_aborted is true then return jsonb_build_object('photo_id',p_photo,'asset_id',a.id,'can_use',false,'review_required',true);end if;
  ids:=array_append(ids,o.id);keys:=array_append(keys,o.storage_key);
 end if;
 visible:=public.studio_presenter_media_visibility(p_listing,ids,'{}'::uuid[],keys);
 return jsonb_build_object('photo_id',p_photo,'asset_id',a.id,'review_required',altered,'can_use',
  not exists(select 1 from unnest(ids)x where visible#>array['assets',x::text]is distinct from'true'::jsonb)
  and not exists(select 1 from unnest(keys)x where visible#>array['keys',x]is distinct from'true'::jsonb));
end$$;
revoke all on function public.studio_gallery_photo_choice(uuid,uuid,uuid)from public,anon,authenticated,service_role;

create or replace function public.studio_gallery_selection_snapshot(p_actor uuid,p_org uuid,p_listing uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb;photos jsonb:='[]';p record;choice jsonb;selected uuid[];ord uuid[];begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.client_listing_access(p_actor,p_org,p_listing,false);
 s:=public.listing_gallery_projection(p_listing);
 select coalesce(array_agg(value::uuid),'{}'::uuid[])into selected from jsonb_array_elements_text(coalesce(nullif(s->'gallery_asset_ids','null'::jsonb),s->'effective_asset_ids'));
 if(select count(*)from public.photos where listing_id=p_listing)>10000 then raise exception'RP409: This property has too much media to open at once';end if;
 for p in select id from public.photos where listing_id=p_listing order by sort,created_at,id loop
  choice:=public.studio_gallery_photo_choice(p_org,p_listing,p.id);
  photos:=photos||jsonb_build_array(choice||jsonb_build_object('selected',coalesce((choice->>'asset_id')::uuid=any(selected),false)));
 end loop;
 select coalesce(array_agg(id order by sort,created_at,id),'{}'::uuid[])into ord from public.photos where listing_id=p_listing;
 perform public.client_listing_access(p_actor,p_org,p_listing,false);
 return s||jsonb_build_object('schema',1,'actor_id',p_actor,'org_id',p_org,'library_org_id',public.listing_owner_library(p_listing),'listing_id',p_listing,'photo_order',ord,'photos',photos);
end$$;
revoke all on function public.studio_gallery_selection_snapshot(uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.studio_gallery_selection_snapshot(uuid,uuid,uuid)to service_role;

create or replace function public.studio_gallery_selection_change(
 p_actor uuid,p_org uuid,p_listing uuid,p_action text,p_photo uuid,p_expected jsonb,p_expected_order jsonb,p_order jsonb,p_reviewed boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.listings;choice jsonb;a public.capture_assets;current_order jsonb;ids uuid[];mapped uuid[];next_ids uuid[];item uuid;n integer:=1;key text;result jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.studio_photo_authority(p_actor,p_org,p_listing);
 select *into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if p_action not in('use','use_cover','reorder_selected')or p_action is null or jsonb_typeof(p_expected)is distinct from'object'
  or(select count(*)from jsonb_object_keys(p_expected))<>2 or not(p_expected?'gallery_asset_ids'and p_expected?'main_photo_key')then raise exception'RP400: Refresh the saved listing photo selection';end if;
 if p_expected is distinct from jsonb_build_object('gallery_asset_ids',l.gallery_asset_ids,'main_photo_key',l.main_photo_key)then raise exception'RP409: The listing photo selection changed. Refresh before choosing again';end if;
 if p_action in('use','use_cover')then
  choice:=public.studio_gallery_photo_choice(p_org,p_listing,p_photo);
  if choice->'can_use'is distinct from'true'::jsonb then raise exception'RP409: Review this photo, its original and disclosure before using it on the listing';end if;
  if choice->'review_required'='true'::jsonb and p_reviewed is distinct from true then raise exception'RP400: Compare this edited photo with its original before using it on the listing';end if;
  select *into a from public.capture_assets where id=(choice->>'asset_id')::uuid and listing_id=p_listing for share;
  perform public.freeze_listing_gallery_for_upload(p_actor,p_org,p_listing);
  result:=public.append_listing_gallery(p_actor,p_org,p_listing,array[a.id],p_action='use_cover',case when p_action='use_cover'then a.storage_key else null end);
  if p_action='use_cover'then update public.photos set is_main=(id=p_photo)where listing_id=p_listing and is_main is distinct from(id=p_photo);end if;
  if public.studio_gallery_photo_choice(p_org,p_listing,p_photo)is distinct from choice then raise exception'RP409: The selected photo changed or was withdrawn';end if;
 else
  perform 1 from public.photos where listing_id=p_listing order by id for update;
  select coalesce(jsonb_agg(id order by sort,created_at,id),'[]'::jsonb)into current_order from public.photos where listing_id=p_listing;
  if current_order is distinct from p_expected_order then raise exception'RP409: The gallery changed on another device. Refresh before reordering';end if;
  -- Existing validated complete-order RPC preserves the500-photo reorder bound.
  result:=public.studio_gallery_update_v2(p_actor,p_org,p_listing,'reorder',null,p_expected_order,p_order);
  if l.gallery_asset_ids is not null then
   ids:=l.gallery_asset_ids;
   select coalesce(array_agg(x.asset_id order by x.n),'{}'::uuid[])into mapped from(
    select distinct on(ca.id)ca.id asset_id,q.n from jsonb_array_elements_text(p_order)with ordinality q(photo_id,n)
     join public.photos p on p.id=q.photo_id::uuid and p.listing_id=p_listing
     join public.capture_assets ca on ca.listing_id=p_listing and ca.storage_key=coalesce(nullif(p.enhanced_key,''),p.original_key)
     where ca.id=any(ids)order by ca.id,q.n)x;
   next_ids:='{}'::uuid[];foreach item in array ids loop
    if item=any(mapped)then next_ids:=array_append(next_ids,mapped[n]);n:=n+1;else next_ids:=array_append(next_ids,item);end if;
   end loop;
   update public.listings set gallery_asset_ids=next_ids where id=p_listing and org_id=p_org;
   if(select main_photo_key from public.listings where id=p_listing)is distinct from l.main_photo_key then raise exception'RP409: The existing cover must be preserved';end if;
  end if;
 end if;
 return public.studio_gallery_selection_snapshot(p_actor,p_org,p_listing)||jsonb_build_object('ok',true,'action',p_action,'photo_id',p_photo);
end$$;
revoke all on function public.studio_gallery_selection_change(uuid,uuid,uuid,text,uuid,jsonb,jsonb,jsonb,boolean)from public,anon,authenticated;
grant execute on function public.studio_gallery_selection_change(uuid,uuid,uuid,text,uuid,jsonb,jsonb,jsonb,boolean)to service_role;
commit;
