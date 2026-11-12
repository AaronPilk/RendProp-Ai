-- Never overwrite an unexpected privileged helper during migration replay.
do $replay_guard$
declare f record; expected text; secure boolean;begin
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_ids(jsonb,boolean)');
 if found and (md5(f.prosrc)<>'90a1524922b624e5b3ca9edb6c5f176e' or f.prosecdef is distinct from false or f.proconfig is distinct from array['search_path=""'])then raise exception 'Review changed native photo selection helper: native_gallery_selection_ids(jsonb,boolean)';end if;
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)');
 if found and (md5(f.prosrc)<>'c9457011c3ae8bb39a9599bcad6f38c8' or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""'])then raise exception 'Review changed native photo selection helper: native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)';end if;
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_snapshot(uuid,uuid,uuid,uuid,uuid)');
 if found and (md5(f.prosrc)<>'a39966b84960429448e820cc73f78699' or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""'])then raise exception 'Review changed native photo selection helper: native_gallery_selection_snapshot(uuid,uuid,uuid,uuid,uuid)';end if;
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_change(uuid,uuid,uuid,uuid,uuid,jsonb)');
 if found and (md5(f.prosrc)<>'2d5ae4a8ea0719808899b778f7a2e217' or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""'])then raise exception 'Review changed native photo selection helper: native_gallery_selection_change(uuid,uuid,uuid,uuid,uuid,jsonb)';end if;
end$replay_guard$;

-- Prospective exact-footprint photo choices. No existing endpoint, receipt,
-- saved photo version, upload, provenance or accepted video job is rewritten.
create table if not exists public.native_gallery_selection_operations (
 actor_id uuid not null references public.profiles(id) on delete cascade,
 operation_id uuid not null,
 org_id uuid not null references public.orgs(id) on delete cascade,
 library_org_id uuid not null references public.orgs(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 request jsonb not null check(jsonb_typeof(request)='object'),
 result jsonb not null check(jsonb_typeof(result)='object'),
 created_at timestamptz not null default now(),
 primary key(actor_id,operation_id)
);
create index if not exists native_gallery_selection_listing_idx on public.native_gallery_selection_operations(listing_id);
alter table public.native_gallery_selection_operations enable row level security;
revoke all on public.native_gallery_selection_operations from public,anon,authenticated,service_role;

create or replace function public.native_gallery_selection_ids(p_value jsonb,p_nullable boolean default false)
returns uuid[] language plpgsql immutable security invoker set search_path='' as $$
declare ids uuid[];begin
 if p_value='null'::jsonb and p_nullable then return null;end if;
 if jsonb_typeof(p_value)is distinct from'array' or jsonb_array_length(p_value)>100 then raise exception'RP400: Keep a bounded saved photo selection';end if;
 if exists(select 1 from jsonb_array_elements(p_value)x where jsonb_typeof(x)is distinct from'string' or (x#>>'{}')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')then raise exception'RP400: Choose valid gallery asset identities';end if;
 select coalesce(array_agg(value::uuid order by n),'{}'::uuid[])into ids from jsonb_array_elements_text(p_value)with ordinality x(value,n);
 if cardinality(ids)<>(select count(distinct x)from unnest(ids)x)then raise exception'RP400: Choose each gallery asset once';end if;
 return ids;
end$$;
revoke all on function public.native_gallery_selection_ids(jsonb,boolean)from public,anon,authenticated,service_role;

-- This validates only an exact already prepared target. It does not upload,
-- generate, infer a family, or accept a client-supplied storage key/disclosure.
create or replace function public.native_gallery_selection_target(p_org uuid,p_listing uuid,p_target uuid,p_sha text,p_bytes bigint,p_reviewed boolean)
returns text language plpgsql security definer set search_path='' as $$
declare a public.capture_assets;m public.media_provenance;o public.capture_assets;visible jsonb;ids uuid[];keys text[];prefix text:='renders/'||p_org||'/'||p_listing||'/gallery-';begin
 select *into a from public.capture_assets where id=p_target and listing_id=p_listing for share;
 if not found or a.kind<>'photo' or a.bucket<>'renders' or a.uploaded is not true or a.upload_aborted is true
  or not starts_with(a.storage_key,prefix)or length(a.storage_key)<=length(prefix)or length(a.storage_key)>500
  or position('/'in substr(a.storage_key,length(prefix)+1))>0 or a.storage_key~'[?#%\\[:cntrl:]]'
  or p_sha!~'^[a-f0-9]{64}$'or p_bytes not between 1 and 134217728 or a.sha256 is distinct from p_sha or a.bytes is distinct from p_bytes then
  raise exception'RP409: The exact prepared photo changed or is unavailable';end if;
 ids:=array[a.id];keys:=array[a.storage_key];
 if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key)>1 then raise exception'RP409: This photo has ambiguous edit evidence';end if;
 select *into m from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key for share;
 if found then
  if p_reviewed is distinct from true or m.org_id is distinct from p_org or m.kind not in('photo_edit','virtual_stage','declutter')or nullif(btrim(m.disclosure),'')is null or m.original_key is null or m.original_key=a.storage_key
   or(m.qc is not null and(m.qc->'publishable'is distinct from'true'::jsonb or coalesce(m.qc->>'action','')not in('accept','pass')))
   or exists(select 1 from public.photo_edit_evidence where provenance_id=m.id and(state<>'accept'or purpose='calibration'))then raise exception'RP409: Compare the accepted edit with its retained original before choosing it';end if;
  if(select count(*)from public.capture_assets where listing_id=p_listing and storage_key=m.original_key and kind='photo'and uploaded)<>1 then raise exception'RP409: The retained original is unavailable or ambiguous';end if;
  select *into o from public.capture_assets where listing_id=p_listing and storage_key=m.original_key and kind='photo'and uploaded for share;
  if o.bucket not in('uploads','renders')or not starts_with(o.storage_key,o.bucket||'/'||p_org||'/'||p_listing||'/')or o.upload_aborted is true then raise exception'RP409: The retained original is unavailable';end if;
  perform 1 from public.photo_edit_evidence where provenance_id=m.id order by id for share;
  ids:=array_append(ids,o.id);keys:=array_append(keys,o.storage_key);
 end if;
 visible:=public.studio_presenter_media_visibility(p_listing,ids,'{}'::uuid[],keys);
 if exists(select 1 from unnest(ids)x where visible#>array['assets',x::text]is distinct from'true'::jsonb)
  or exists(select 1 from unnest(keys)x where visible#>array['keys',x]is distinct from'true'::jsonb)then raise exception'RP409: This photo or its original was withdrawn';end if;
 return a.storage_key;
end$$;
revoke all on function public.native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)from public,anon,authenticated,service_role;

create or replace function public.native_gallery_selection_snapshot(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_operation uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb;ids uuid[];keys text[];visible jsonb;assets jsonb;op public.native_gallery_selection_operations;receipt jsonb:='null';begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.client_listing_access(p_actor,p_org,p_listing,false);
 if public.listing_owner_library(p_listing)is distinct from p_library then raise exception'RP404: This property is no longer in the selected library';end if;
 s:=public.listing_gallery_projection(p_listing);
 select coalesce(array_agg(value::uuid order by n),'{}'::uuid[])into ids from jsonb_array_elements_text(s->'effective_asset_ids')with ordinality x(value,n);
 select coalesce(array_agg(storage_key),'{}'::text[])into keys from public.capture_assets where listing_id=p_listing and id=any(ids);
 visible:=public.studio_presenter_media_visibility(p_listing,ids,'{}'::uuid[],keys);
 select coalesce(jsonb_agg(jsonb_build_object('asset_id',a.id,'sha256',a.sha256,'bytes',a.bytes,'storage_key',a.storage_key)order by array_position(ids,a.id)),'[]')into assets
 from public.capture_assets a where a.listing_id=p_listing and a.id=any(ids)and a.sha256~'^[a-f0-9]{64}$'and a.bytes between 1 and 134217728
  and visible#>array['assets',a.id::text]='true'::jsonb and visible#>array['keys',a.storage_key]='true'::jsonb;
 if p_operation is not null then
  select *into op from public.native_gallery_selection_operations where actor_id=p_actor and operation_id=p_operation;
  if found then
   if row(op.org_id,op.library_org_id,op.listing_id)is distinct from row(p_org,p_library,p_listing)then raise exception'RP409: This operation belongs to another photo selection';end if;
   receipt:=jsonb_build_object('operation_id',op.operation_id,'request',op.request,'result',op.result);
  end if;
 end if;
 perform public.client_listing_access(p_actor,p_org,p_listing,false);
 if public.listing_owner_library(p_listing)is distinct from p_library then raise exception'RP404: This property is no longer in the selected library';end if;
 return s||jsonb_build_object('schema',1,'actor_id',p_actor,'library_org_id',p_library,'gallery_assets',assets,'operation',receipt);
end$$;
revoke all on function public.native_gallery_selection_snapshot(uuid,uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.native_gallery_selection_snapshot(uuid,uuid,uuid,uuid,uuid)to service_role;

create or replace function public.native_gallery_selection_change(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_operation uuid,p_request jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.listings;op public.native_gallery_selection_operations;family uuid[];expected uuid[];selected uuid[];next_ids uuid[]:='{}';target uuid;target_key text;target_sha text;target_bytes bigint;next_cover text;item uuid;added boolean:=false;own_cover boolean;follow_cover boolean;reviewed boolean;s jsonb;result jsonb;valid_count integer;prefix text:='renders/'||p_org||'/'||p_listing||'/gallery-';begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_org is null or p_library is null or p_listing is null or p_operation is null then raise exception'RP400: Keep the exact saved photo operation';end if;
 if jsonb_typeof(p_request)is distinct from'object'or(select count(*)from jsonb_object_keys(p_request))<>5 or not(p_request?'family_asset_ids'and p_request?'target'and p_request?'expected_selection'and p_request?'follow_family_cover'and p_request?'reviewed')then raise exception'RP400: Send only the saved family photo intent';end if;
 family:=public.native_gallery_selection_ids(p_request->'family_asset_ids');
 if cardinality(family)=0 or jsonb_typeof(p_request->'follow_family_cover')is distinct from'boolean'or jsonb_typeof(p_request->'reviewed')is distinct from'boolean'then raise exception'RP400: Keep the exact bounded family and review intent';end if;
 follow_cover:=(p_request->>'follow_family_cover')::boolean;reviewed:=(p_request->>'reviewed')::boolean;
 if jsonb_typeof(p_request->'expected_selection')is distinct from'object'or(select count(*)from jsonb_object_keys(p_request->'expected_selection'))<>2 or not((p_request->'expected_selection')?'gallery_asset_ids'and(p_request->'expected_selection')?'main_photo_key')then raise exception'RP400: Keep the complete raw gallery and cover snapshot';end if;
 expected:=public.native_gallery_selection_ids(p_request#>'{expected_selection,gallery_asset_ids}',true);
 if not(p_request#>'{expected_selection,main_photo_key}'='null'::jsonb or jsonb_typeof(p_request#>'{expected_selection,main_photo_key}')='string'and length(p_request#>>'{expected_selection,main_photo_key}')between 1 and 500)then raise exception'RP400: Keep the saved cover snapshot';end if;
 if p_request->'target'<>'null'::jsonb then
  if jsonb_typeof(p_request->'target')is distinct from'object'or(select count(*)from jsonb_object_keys(p_request->'target'))<>3 or not((p_request->'target')?'asset_id'and(p_request->'target')?'sha256'and(p_request->'target')?'bytes')
   or coalesce(p_request#>>'{target,asset_id}','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   or coalesce(p_request#>>'{target,sha256}','')!~'^[a-f0-9]{64}$'or jsonb_typeof(p_request#>'{target,bytes}')is distinct from'number'or(p_request#>>'{target,bytes}')!~'^[0-9]{1,9}$'then raise exception'RP400: Choose one exact prepared target';end if;
  target:=(p_request#>>'{target,asset_id}')::uuid;target_sha:=p_request#>>'{target,sha256}';target_bytes:=(p_request#>>'{target,bytes}')::bigint;
  if not(target=any(family))or target_bytes not between 1 and 134217728 then raise exception'RP400: The prepared target must be in this exact family footprint';end if;
 elsif follow_cover or reviewed then raise exception'RP400: Removing exposure does not choose a cover or approve an edit';end if;
 -- Match canonical content mutation lock order, then recheck authority/mapping.
 perform 1 from public.profiles where id=p_actor for update;
 perform 1 from public.orgs where id=p_org for update;
 select *into l from public.listings where id=p_listing and org_id=p_org for update;
 perform public.client_listing_access(p_actor,p_org,p_listing,true);
 if public.listing_owner_library(p_listing)is distinct from p_library then raise exception'RP404: This property is no longer in the selected library';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP409: Account deletion is in progress';end if;
 select *into op from public.native_gallery_selection_operations where actor_id=p_actor and operation_id=p_operation;
 if found then
  if row(op.org_id,op.library_org_id,op.listing_id,op.request)is distinct from row(p_org,p_library,p_listing,p_request)then raise exception'RP409: This saved operation belongs to another photo choice';end if;
  return public.native_gallery_selection_snapshot(p_actor,p_org,p_library,p_listing,p_operation)||jsonb_build_object('ok',true,'replayed',true);
 end if;
 if p_request->'expected_selection'is distinct from jsonb_build_object('gallery_asset_ids',l.gallery_asset_ids,'main_photo_key',l.main_photo_key)then raise exception using errcode='PT409',message='RP409: The listing photo selection changed';end if;
 -- The caller supplies a byte-resolved footprint, never an entire replacement.
 -- SQL still admits only owned complete gallery IDs; unknown IDs are preserved.
 perform 1 from public.capture_assets where listing_id=p_listing and id=any(family)order by id for share;
 select count(*)into valid_count from public.capture_assets a where a.listing_id=p_listing and a.id=any(family)and a.kind='photo'and a.bucket='renders'and a.uploaded and a.upload_aborted is not true
  and starts_with(a.storage_key,prefix)and length(a.storage_key)>length(prefix)and length(a.storage_key)<=500 and position('/'in substr(a.storage_key,length(prefix)+1))=0 and a.storage_key!~'[?#%\\[:cntrl:]]';
 if valid_count<>cardinality(family)then raise exception'RP409: One of the exact family assets is unavailable';end if;
 if target is not null then target_key:=public.native_gallery_selection_target(p_org,p_listing,target,target_sha,target_bytes,reviewed);end if;
 s:=public.listing_gallery_projection(p_listing);
 if l.gallery_asset_ids is null then select coalesce(array_agg(value::uuid order by n),'{}'::uuid[])into selected from jsonb_array_elements_text(s->'effective_asset_ids')with ordinality x(value,n);else selected:=l.gallery_asset_ids;end if;
 foreach item in array selected loop
  if item=any(family)then
   if target is not null and not added then next_ids:=array_append(next_ids,target);added:=true;end if;
  else next_ids:=array_append(next_ids,item);end if;
 end loop;
 if target is not null and not added then next_ids:=array_append(next_ids,target);end if;
 if cardinality(next_ids)>100 then raise exception'RP409: The listing gallery is full';end if;
 own_cover:=exists(select 1 from public.capture_assets where listing_id=p_listing and id=any(family)and storage_key=l.main_photo_key);
 next_cover:=l.main_photo_key;
 if own_cover then
  if target is null then next_cover:=null;
  elsif follow_cover then next_cover:=target_key;
  else raise exception'RP409: Confirm the current family cover before replacing this version';end if;
 elsif follow_cover then raise exception'RP409: This family is not the current cover';end if;
 update public.listings set gallery_asset_ids=next_ids,main_photo_key=next_cover where id=p_listing and org_id=p_org and deleted_at is null returning *into l;
 if not found then raise exception'RP404: Listing not found in this workspace';end if;
 if l.gallery_asset_ids is distinct from next_ids or l.main_photo_key is distinct from next_cover then raise exception'RP409: The existing gallery or cover could not be preserved';end if;
 if target is not null and public.native_gallery_selection_target(p_org,p_listing,target,target_sha,target_bytes,reviewed)is distinct from target_key then raise exception'RP409: The prepared target changed';end if;
 result:=jsonb_build_object('gallery_asset_ids',l.gallery_asset_ids,'main_photo_key',l.main_photo_key);
 insert into public.native_gallery_selection_operations(actor_id,operation_id,org_id,library_org_id,listing_id,request,result)values(p_actor,p_operation,p_org,p_library,p_listing,p_request,result);
 return public.native_gallery_selection_snapshot(p_actor,p_org,p_library,p_listing,p_operation)||jsonb_build_object('ok',true,'replayed',false);
end$$;
revoke all on function public.native_gallery_selection_change(uuid,uuid,uuid,uuid,uuid,jsonb)from public,anon,authenticated;
grant execute on function public.native_gallery_selection_change(uuid,uuid,uuid,uuid,uuid,jsonb)to service_role;
