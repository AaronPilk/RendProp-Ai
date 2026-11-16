-- Dedicated attachment rechecks actor authority at the atomic write. Ordinary
-- clients retain no UPDATE(details) grant and cannot choose attachment metadata.
create or replace function public.studio_attach_floorplan(
 p_actor uuid,p_org uuid,p_listing uuid,p_asset uuid,p_expected jsonb,p_url text
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare l public.listings; a public.capture_assets; next_details jsonb;
begin
 perform public.upload_service_only();
 if p_actor is null or p_org is null or p_listing is null or p_asset is null
  or pg_catalog.jsonb_typeof(p_expected) is distinct from 'object' then
  raise exception 'Invalid floor plan attachment' using errcode='22023'; end if;
 -- Deletion/adoption locks profiles before orgs. Keep the same order and hold
 -- the actor/membership/asset proofs until this transaction completes.
 perform 1 from public.profiles where id=p_actor for share;
 if not found then raise exception 'Workspace is not writable' using errcode='42501'; end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'Workspace is not writable' using errcode='42501'; end if;
 perform 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent') for share;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'Workspace is not writable' using errcode='42501'; end if;
 select * into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if not found then raise exception 'Listing not found' using errcode='P0002'; end if;
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing for share;
 if not found or a.kind is distinct from 'photo' or a.bucket is distinct from 'renders' or a.uploaded is distinct from true
  or a.content_type is null or a.content_type not in('image/jpeg','image/png','image/webp')
  or a.storage_key not like 'renders/'||p_org::text||'/'||p_listing::text||'/%'
  or length(a.storage_key)>=1024 or a.storage_key like '%..%' or a.storage_key ~ '[?#]'
  or a.storage_key like '%/contact-%' then
  raise exception 'Choose an uploaded floor plan from this listing' using errcode='22023'; end if;
 if p_url is null or length(p_url)>4096 or p_url !~ '^https://[^/?#@]+/' or p_url ~ '[?#]'
  or right(p_url,length(a.storage_key)+1) is distinct from '/'||a.storage_key then
  raise exception 'Invalid canonical floor plan URL' using errcode='22023'; end if;
 if l.details is distinct from p_expected then
  raise exception 'Listing details changed elsewhere' using errcode='40001'; end if;
 next_details:=l.details||pg_catalog.jsonb_build_object('floorplan_url',p_url,'floorplan_asset_id',a.id);
 if pg_catalog.octet_length(next_details::text)>16000 then
  raise exception 'Listing details too large' using errcode='22023'; end if;
 update public.listings set details=next_details where id=p_listing returning * into l;
 return pg_catalog.jsonb_build_object('id',l.id,'details',l.details);
end $$;
revoke all on function public.studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text) to service_role;
