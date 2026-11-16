do $replay_guard$
declare f record;t record;begin
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_reject_abandoned()');
 if found and(md5(f.prosrc)<>'6f271083de51bac9add9b74af521a0aa'or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""'])then raise exception'Review changed native photo v2 helper: native_gallery_selection_reject_abandoned()';end if;
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_request_v2(jsonb)');
 if found and(md5(f.prosrc)<>'baaea2a39d365973dd50d3c77e763752'or f.prosecdef is distinct from false or f.proconfig is distinct from array['search_path=""'])then raise exception'Review changed native photo v2 helper: native_gallery_selection_request_v2(jsonb)';end if;
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_snapshot_v2(uuid,uuid,uuid,uuid,uuid)');
 if found and(md5(f.prosrc)<>'f0f715f12a59877f1a9404cb740425eb'or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""'])then raise exception'Review changed native photo v2 helper: native_gallery_selection_snapshot_v2(uuid,uuid,uuid,uuid,uuid)';end if;
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_change_v2(uuid,uuid,uuid,uuid,uuid,jsonb)');
 if found and(md5(f.prosrc)<>'2533d0d9f675b6a22cc47a9a136d4230'or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""'])then raise exception'Review changed native photo v2 helper: native_gallery_selection_change_v2(uuid,uuid,uuid,uuid,uuid,jsonb)';end if;
 select *into f from pg_proc where oid=to_regprocedure('public.native_gallery_selection_abandon(uuid,uuid,uuid,uuid,uuid,jsonb)');
 if found and(md5(f.prosrc)<>'0efa49ffe35b33dbd0ca42bdd5a64d43'or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""'])then raise exception'Review changed native photo v2 helper: native_gallery_selection_abandon(uuid,uuid,uuid,uuid,uuid,jsonb)';end if;
 -- An unexpected privileged trigger must not be silently replaced or enabled.
 select *into t from pg_trigger where tgrelid='public.native_gallery_selection_operations'::regclass and tgname='native_gallery_selection_abandoned_insert';
 if found and(t.tgfoid is distinct from to_regprocedure('public.native_gallery_selection_reject_abandoned()')or t.tgtype<>7 or t.tgenabled<>'O'or t.tgisinternal or t.tgqual is not null or t.tgnargs<>0 or t.tgargs<>''::bytea or t.tgconstraint<>0 or t.tgdeferrable or t.tginitdeferred or t.tgconstrrelid<>0 or t.tgconstrindid<>0 or t.tgattr<>''::int2vector or t.tgoldtable is not null or t.tgnewtable is not null or t.tgparentid<>0)then raise exception'Review changed native photo v2 trigger: native_gallery_selection_abandoned_insert';end if;
end$replay_guard$;

-- Additive receipt states; the four original helpers and their replay guard remain byte-exact.
create table if not exists public.native_gallery_selection_abandonments(
 actor_id uuid not null references public.profiles(id)on delete cascade,
 operation_id uuid not null,org_id uuid not null references public.orgs(id)on delete cascade,
 library_org_id uuid not null references public.orgs(id)on delete cascade,
 listing_id uuid not null references public.listings(id)on delete cascade,
 request jsonb not null check(jsonb_typeof(request)='object'),created_at timestamptz not null default now(),primary key(actor_id,operation_id)
);
create index if not exists native_gallery_selection_abandon_listing_idx on public.native_gallery_selection_abandonments(listing_id);
alter table public.native_gallery_selection_abandonments enable row level security;
revoke all on public.native_gallery_selection_abandonments from public,anon,authenticated,service_role;
create or replace function public.native_gallery_selection_reject_abandoned()
returns trigger language plpgsql security definer set search_path='' as $$begin
 -- Also fences delayed clients still calling the unchanged legacy change RPC.
 if exists(select 1 from public.native_gallery_selection_abandonments where actor_id=new.actor_id and operation_id=new.operation_id)then raise exception'RP409: This saved photo operation was abandoned';end if;
 return new;
end$$;
revoke all on function public.native_gallery_selection_reject_abandoned()from public,anon,authenticated,service_role;
do $trigger_install$begin
 if not exists(select 1 from pg_trigger where tgrelid='public.native_gallery_selection_operations'::regclass and tgname='native_gallery_selection_abandoned_insert')then
  create trigger native_gallery_selection_abandoned_insert before insert on public.native_gallery_selection_operations for each row execute function public.native_gallery_selection_reject_abandoned();
 end if;
end$trigger_install$;
create or replace function public.native_gallery_selection_request_v2(p_request jsonb)
returns jsonb language plpgsql immutable security invoker set search_path='' as $$
declare family uuid[];expected uuid[];target uuid;target_sha text;target_bytes bigint;follow_cover boolean;reviewed boolean;begin
 if jsonb_typeof(p_request)is distinct from'object'or(select count(*)from jsonb_object_keys(p_request))not in(5,6)or exists(select 1 from jsonb_object_keys(p_request)k where k not in('family_asset_ids','target','expected_selection','follow_family_cover','reviewed','promote_cover')) or not(p_request?'family_asset_ids'and p_request?'target'and p_request?'expected_selection'and p_request?'follow_family_cover'and p_request?'reviewed')then raise exception'RP400: Send only the saved family photo intent';end if;
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
 if p_request?'promote_cover'and jsonb_typeof(p_request->'promote_cover')is distinct from'boolean'then raise exception'RP400: Keep an explicit cover intent';end if;
 if coalesce((p_request->>'promote_cover')::boolean,false)and(target is null or follow_cover)then raise exception'RP400: Cover promotion needs one selected exact target and no follow-cover intent';end if;
 if p_request->'promote_cover'='false'::jsonb then p_request:=p_request-'promote_cover';end if;
 return p_request;
end$$;
revoke all on function public.native_gallery_selection_request_v2(jsonb)from public,anon,authenticated,service_role;
create or replace function public.native_gallery_selection_snapshot_v2(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_operation uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb;a public.native_gallery_selection_abandonments;state text;abandoned jsonb:='null';begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 -- Read a coherent current selection and operation state under the canonical locks.
 perform 1 from public.profiles where id=p_actor for update;
 perform 1 from public.orgs where id=p_org for update;
 perform 1 from public.listings where id=p_listing and org_id=p_org for update;
 s:=public.native_gallery_selection_snapshot(p_actor,p_org,p_library,p_listing,p_operation);
 if p_operation is not null then
  if s->'operation'<>'null'::jsonb then state:='accepted';
  else
   select *into a from public.native_gallery_selection_abandonments where actor_id=p_actor and operation_id=p_operation;
   if found then
    if row(a.org_id,a.library_org_id,a.listing_id)is distinct from row(p_org,p_library,p_listing)then raise exception'RP409: This operation belongs to another photo selection';end if;
    state:='abandoned';abandoned:=jsonb_build_object('operation_id',a.operation_id,'request',a.request);
   else state:='not_found';end if;
  end if;
 end if;
 return s||jsonb_build_object('operation_status',state,'abandoned_operation',abandoned);
end$$;
revoke all on function public.native_gallery_selection_snapshot_v2(uuid,uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.native_gallery_selection_snapshot_v2(uuid,uuid,uuid,uuid,uuid)to service_role;
create or replace function public.native_gallery_selection_change_v2(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_operation uuid,p_request jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.listings;op public.native_gallery_selection_operations;family uuid[];expected uuid[];selected uuid[];next_ids uuid[]:='{}';target uuid;target_key text;target_sha text;target_bytes bigint;next_cover text;item uuid;added boolean:=false;own_cover boolean;follow_cover boolean;reviewed boolean;s jsonb;result jsonb;valid_count integer;promote boolean;prefix text:='renders/'||p_org||'/'||p_listing||'/gallery-';begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_org is null or p_library is null or p_listing is null or p_operation is null then raise exception'RP400: Keep the exact saved photo operation';end if;
 p_request:=public.native_gallery_selection_request_v2(p_request);
 family:=public.native_gallery_selection_ids(p_request->'family_asset_ids');
 expected:=public.native_gallery_selection_ids(p_request#>'{expected_selection,gallery_asset_ids}',true);
 follow_cover:=(p_request->>'follow_family_cover')::boolean;reviewed:=(p_request->>'reviewed')::boolean;promote:=coalesce((p_request->>'promote_cover')::boolean,false);
 if p_request->'target'<>'null'::jsonb then target:=(p_request#>>'{target,asset_id}')::uuid;target_sha:=p_request#>>'{target,sha256}';target_bytes:=(p_request#>>'{target,bytes}')::bigint;end if;
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
  return public.native_gallery_selection_snapshot_v2(p_actor,p_org,p_library,p_listing,p_operation)||jsonb_build_object('ok',true,'replayed',true);
 end if;
 if exists(select 1 from public.native_gallery_selection_abandonments where actor_id=p_actor and operation_id=p_operation)then raise exception'RP409: This saved photo operation was abandoned';end if;
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
 if promote then
  if not(target=any(selected))or(select count(*)from unnest(selected)x where x=any(family))<>1 then raise exception'RP409: Select this exact family version before promoting its cover';end if;
  next_ids:=l.gallery_asset_ids;next_cover:=target_key;
 else
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
 end if;
 update public.listings set gallery_asset_ids=next_ids,main_photo_key=next_cover where id=p_listing and org_id=p_org and deleted_at is null returning *into l;
 if not found then raise exception'RP404: Listing not found in this workspace';end if;
 if l.gallery_asset_ids is distinct from next_ids or l.main_photo_key is distinct from next_cover then raise exception'RP409: The existing gallery or cover could not be preserved';end if;
 if target is not null and public.native_gallery_selection_target(p_org,p_listing,target,target_sha,target_bytes,reviewed)is distinct from target_key then raise exception'RP409: The prepared target changed';end if;
 result:=jsonb_build_object('gallery_asset_ids',l.gallery_asset_ids,'main_photo_key',l.main_photo_key);
 insert into public.native_gallery_selection_operations(actor_id,operation_id,org_id,library_org_id,listing_id,request,result)values(p_actor,p_operation,p_org,p_library,p_listing,p_request,result);
 return public.native_gallery_selection_snapshot_v2(p_actor,p_org,p_library,p_listing,p_operation)||jsonb_build_object('ok',true,'replayed',false);
end$$;
revoke all on function public.native_gallery_selection_change_v2(uuid,uuid,uuid,uuid,uuid,jsonb)from public,anon,authenticated;
grant execute on function public.native_gallery_selection_change_v2(uuid,uuid,uuid,uuid,uuid,jsonb)to service_role;
create or replace function public.native_gallery_selection_abandon(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_operation uuid,p_request jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare op public.native_gallery_selection_operations;a public.native_gallery_selection_abandonments;replayed boolean:=false;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_org is null or p_library is null or p_listing is null or p_operation is null then raise exception'RP400: Keep the exact saved photo operation';end if;
 p_request:=public.native_gallery_selection_request_v2(p_request);
 perform 1 from public.profiles where id=p_actor for update;
 perform 1 from public.orgs where id=p_org for update;
 perform 1 from public.listings where id=p_listing and org_id=p_org for update;
 perform public.client_listing_access(p_actor,p_org,p_listing,true);
 if public.listing_owner_library(p_listing)is distinct from p_library then raise exception'RP404: This property is no longer in the selected library';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP409: Account deletion is in progress';end if;
 select *into op from public.native_gallery_selection_operations where actor_id=p_actor and operation_id=p_operation;
 if found then
  if row(op.org_id,op.library_org_id,op.listing_id,op.request)is distinct from row(p_org,p_library,p_listing,p_request)then raise exception'RP409: This saved operation belongs to another photo choice';end if;
  return public.native_gallery_selection_snapshot_v2(p_actor,p_org,p_library,p_listing,p_operation)||jsonb_build_object('ok',true,'abandoned',false,'replayed',true);
 end if;
 select *into a from public.native_gallery_selection_abandonments where actor_id=p_actor and operation_id=p_operation;
 if found then
  if row(a.org_id,a.library_org_id,a.listing_id,a.request)is distinct from row(p_org,p_library,p_listing,p_request)then raise exception'RP409: This saved operation belongs to another photo choice';end if;
  replayed:=true;
 else
  insert into public.native_gallery_selection_abandonments(actor_id,operation_id,org_id,library_org_id,listing_id,request)values(p_actor,p_operation,p_org,p_library,p_listing,p_request);
 end if;
 return public.native_gallery_selection_snapshot_v2(p_actor,p_org,p_library,p_listing,p_operation)||jsonb_build_object('ok',true,'abandoned',true,'replayed',replayed);
end$$;
revoke all on function public.native_gallery_selection_abandon(uuid,uuid,uuid,uuid,uuid,jsonb)from public,anon,authenticated;
grant execute on function public.native_gallery_selection_abandon(uuid,uuid,uuid,uuid,uuid,jsonb)to service_role;
