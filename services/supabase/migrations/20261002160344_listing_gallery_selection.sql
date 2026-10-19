-- Explicit publication gallery. Null preserves legacy automatic gallery;
-- an empty array intentionally publishes no property photos. All uploaded
-- originals, edits and provenance remain intact when the selection changes.
alter table public.listings add column if not exists gallery_asset_ids uuid[] default null;
comment on column public.listings.gallery_asset_ids is
  'Ordered current published property gallery, max 40; NULL uses legacy automatic gallery, empty hides gallery. Original media/history is retained.';
grant update (gallery_asset_ids) on public.listings to authenticated;

-- Existing membership RLS and column grants remain the write authority. This
-- invoker trigger also fences direct REST writes to owned, completed gallery
-- assets; public reads separately recheck presenter/media revocation.
create or replace function public.validate_listing_gallery_selection()
returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
declare
  selection_changed boolean;
  cover_changed boolean;
  selected_count integer;
  cover_id uuid;
  prefix text;
begin
  if TG_OP='INSERT' then
    selection_changed:=new.gallery_asset_ids is not null;
    cover_changed:=new.main_photo_key is not null;
  else
    selection_changed:=new.gallery_asset_ids is distinct from old.gallery_asset_ids;
    cover_changed:=new.main_photo_key is distinct from old.main_photo_key;
  end if;
  if not selection_changed and not cover_changed then return new; end if;
  prefix:='renders/'||new.org_id::text||'/'||new.id::text||'/gallery-';
  if selection_changed and new.gallery_asset_ids is not null then
    if cardinality(new.gallery_asset_ids)>40 or
       coalesce(array_ndims(new.gallery_asset_ids),1)<>1 or
       array_position(new.gallery_asset_ids,null) is not null or
       cardinality(new.gallery_asset_ids)<>(select count(distinct x) from unnest(new.gallery_asset_ids)x) then
      raise exception 'RP400: Choose up to 40 distinct uploaded gallery photos.' using errcode='23514';
    end if;
    select count(*) into selected_count from public.capture_assets a
      where a.id=any(new.gallery_asset_ids) and a.listing_id=new.id and
      a.kind='photo' and a.bucket='renders' and a.uploaded=true and
      left(a.storage_key,length(prefix))=prefix and length(a.storage_key)>length(prefix) and
      length(a.storage_key)<=500 and position('/' in substring(a.storage_key from length(prefix)+1))=0 and
      position(chr(92) in a.storage_key)=0 and position('%' in a.storage_key)=0 and
      position('?' in a.storage_key)=0 and position('#' in a.storage_key)=0 and a.storage_key!~'[[:cntrl:]]';
    if selected_count<>cardinality(new.gallery_asset_ids) then
      raise exception 'RP400: Choose completed gallery photos belonging to this listing.' using errcode='23514';
    end if;
  end if;
  if new.main_photo_key is not null and (cover_changed or new.gallery_asset_ids is not null) then
    select a.id into cover_id from public.capture_assets a where
      a.listing_id=new.id and a.kind='photo' and a.bucket='renders' and a.uploaded=true and
      a.storage_key=new.main_photo_key and left(a.storage_key,length(prefix))=prefix and
      length(a.storage_key)>length(prefix) and length(a.storage_key)<=500 and
      position('/' in substring(a.storage_key from length(prefix)+1))=0 and
      position(chr(92) in a.storage_key)=0 and position('%' in a.storage_key)=0 and
      position('?' in a.storage_key)=0 and position('#' in a.storage_key)=0 and a.storage_key!~'[[:cntrl:]]';
    if cover_id is null or (new.gallery_asset_ids is not null and not(cover_id=any(new.gallery_asset_ids))) then
      if selection_changed and not cover_changed then
        new.main_photo_key:=null;
      else
        raise exception 'RP400: Choose an available main photo from the published gallery.' using errcode='23514';
      end if;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.validate_listing_gallery_selection() from public,anon,authenticated;
drop trigger if exists trg_validate_listing_gallery_selection on public.listings;
create trigger trg_validate_listing_gallery_selection before insert or update of gallery_asset_ids,main_photo_key
on public.listings for each row execute function public.validate_listing_gallery_selection();

-- A preservation prompt is not measured geometry. New audit records and
-- current public presentation request review; old stored audit rows remain
-- untouched. Keep the existing pure helper signature and execution grants.
create or replace function public.provenance_disclosure(p_kind text,p_edit text default null)
returns text language sql immutable set search_path=public as $$
 select case
  when p_kind='virtual_stage' then
   'This photo was virtually staged with AI: furniture and decor were digitally added or restyled. Compare with the original to check fixed features, layout and access before publication.'
  when p_kind='declutter' then
   'This photo was digitally decluttered with AI: clutter and personal items were removed. Compare with the original to check fixed features, layout and access before publication.'
  when p_kind='aerial' then
   'Drone-style movement is simulated. No drone footage was captured. This establishing shot was generated by AI.'
  when p_kind='reel' then
   'This clip was generated by AI from a still photo of the property. The motion is simulated; no video of this view was captured.'
  when p_kind='photo_edit' and lower(coalesce(p_edit,''))='twilight' then
   'This photo was digitally altered with AI: the sky and lighting were changed to simulate dusk. Compare with the original to check property features before publication.'
  when p_kind='photo_edit' and lower(coalesce(p_edit,''))='sky' then
   'This photo was digitally altered with AI: the sky was replaced. Compare with the original to check property features before publication.'
  when p_kind='photo_edit' and lower(coalesce(p_edit,''))='lawn' then
   'This photo was digitally altered with AI: the lawn and landscaping were digitally repaired. Compare with the original to check property features before publication.'
  when p_kind='photo_edit' then
   'This photo was digitally altered with AI. Compare with the original to check fixed features, layout and access before publication.'
  else 'This media was digitally altered or generated with AI.'
 end;
$$;
revoke execute on function public.provenance_disclosure(text,text) from public,anon;
grant execute on function public.provenance_disclosure(text,text) to authenticated,service_role;

-- Atomic cloud-project additions. Different devices append to the locked
-- latest row; they do not replace a stale client snapshot or infer edit
-- families. Cover selection is applied in that same validated transaction.
create or replace function public.append_listing_gallery(p_user uuid,p_org uuid,p_listing uuid,p_add uuid[],p_set_main boolean default false,p_main_photo_key text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 l public.listings;
 selected uuid[];
 added uuid;
 candidates uuid[];
 candidate_keys text[];
 visible jsonb;
 prefix text:='renders/'||p_org::text||'/'||p_listing::text||'/gallery-';
begin
 if current_setting('role',true) is distinct from 'service_role' then
  raise insufficient_privilege using message='service role required';end if;
 -- Same lock order as account/team/client writes. Check authority only after
 -- locks, so removal or deletion cannot slip between permission and save.
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=p_org for update;
 select * into l from public.listings where id=p_listing and org_id=p_org for update;
 perform public.client_listing_access(p_user,p_org,p_listing,true);
 if p_add is null or p_set_main is null or cardinality(p_add)>40 or
    coalesce(array_ndims(p_add),1)<>1 or array_position(p_add,null)is not null or
    cardinality(p_add)<>(select count(distinct x)from unnest(p_add)x) then
  raise exception 'RP400: Choose up to 40 distinct uploaded gallery photos.';end if;
 if l.gallery_asset_ids is null then
  -- Match the existing public automatic-gallery surface and order. Retired
  -- upload families cannot be guessed safely; explicit review comes later.
  select coalesce(array_agg(a.id order by a.created_at,a.id),'{}'::uuid[]),coalesce(array_agg(a.storage_key order by a.created_at,a.id),'{}'::text[])
   into candidates,candidate_keys from (
    select a.id,a.storage_key,a.created_at from public.capture_assets a where a.listing_id=p_listing and
      a.kind='photo' and a.bucket='renders' and a.uploaded=true and
      left(a.storage_key,length(prefix))=prefix and length(a.storage_key)>length(prefix) and
      length(a.storage_key)<=500 and position('/'in substring(a.storage_key from length(prefix)+1))=0 and
      position(chr(92)in a.storage_key)=0 and position('%'in a.storage_key)=0 and
      position('?'in a.storage_key)=0 and position('#'in a.storage_key)=0 and a.storage_key!~'[[:cntrl:]]'
      order by a.created_at,a.id limit 40
   )a;
  visible:=public.studio_presenter_media_visibility(p_listing,candidates,'{}'::uuid[],candidate_keys);
  select coalesce(array_agg(a.id order by a.created_at,a.id),'{}'::uuid[])into selected
   from public.capture_assets a where a.id=any(candidates) and
    coalesce((visible->'assets'->>a.id::text)::boolean,false) and
    coalesce((visible->'keys'->>a.storage_key)::boolean,false);
 else selected:=l.gallery_asset_ids;end if;
 select coalesce(array_agg(a.storage_key),'{}'::text[])into candidate_keys
  from public.capture_assets a where a.listing_id=p_listing and a.id=any(p_add);
 if p_set_main and p_main_photo_key is not null then
  candidate_keys:=array_append(candidate_keys,p_main_photo_key);
 end if;
 visible:=public.studio_presenter_media_visibility(p_listing,p_add,'{}'::uuid[],candidate_keys);
 if exists(select 1 from unnest(p_add)id where not coalesce((visible->'assets'->>id::text)::boolean,false)) or
    exists(select 1 from unnest(candidate_keys)key where not coalesce((visible->'keys'->>key)::boolean,false)) then
  raise exception 'RP400: Choose available gallery photos belonging to this listing.';end if;
 foreach added in array p_add loop
  if not(added=any(selected))then selected:=array_append(selected,added);end if;
 end loop;
 if cardinality(selected)>40 then
  raise exception 'RP400: The published gallery can contain up to 40 photos. Review the selection before adding more.';end if;
 update public.listings set gallery_asset_ids=selected,
  main_photo_key=case when p_set_main then p_main_photo_key else l.main_photo_key end
  where id=p_listing and org_id=p_org and deleted_at is null returning * into l;
 if not found then raise exception 'RP404: Listing not found in this workspace.';end if;
 return to_jsonb(l);
end;
$$;
revoke all on function public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text) from public,anon,authenticated,service_role;
grant execute on function public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text) to service_role;
