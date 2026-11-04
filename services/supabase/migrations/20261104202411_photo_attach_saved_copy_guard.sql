-- Studio's direct photo attachment is only for a file just uploaded from the
-- current browser. Old unattached gallery uploads can be saved edits whose
-- original/provenance was lost with an app reinstall. They remain private
-- cloud files until a verified original or edit history can be recovered.
-- The internal studio_gallery_copy_finish path continues to use the existing
-- studio_attach_photo after its server-side exact-byte/source proof.
begin;
create or replace function public.studio_attach_photo_from_upload(
 p_actor uuid,p_org uuid,p_listing uuid,p_asset uuid,p_caption text,p_provenance uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare key text;prior public.photos;reservation public.upload_reservations;asset public.capture_assets;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.studio_photo_authority(p_actor,p_org,p_listing);
 key:=public.studio_photo_asset_key(p_asset,p_org,p_listing);
 -- An already attached row is an idempotent replay, even after its upload
 -- reservation ages out. The underlying RPC still verifies its saved keys.
 select *into prior from public.photos where id=p_asset for share;
 if prior.id is not null then
  return public.studio_attach_photo(p_actor,p_org,p_listing,p_asset,p_caption,p_provenance);
 end if;
 -- Accepted edits are attached with their real retained original/disclosure.
 -- The underlying RPC does the final lineage check; this wrapper cannot
 -- infer or invent that proof from a gallery filename.
 if exists(select 1 from public.media_provenance m where m.org_id=p_org and m.listing_id=p_listing and m.altered_key=key)then
  return public.studio_attach_photo(p_actor,p_org,p_listing,p_asset,p_caption,p_provenance);
 end if;
 select *into asset from public.capture_assets where id=p_asset and listing_id=p_listing for share;
 select *into reservation from public.upload_reservations where asset_id=p_asset for share;
 if asset.id is null or reservation.asset_id is null or reservation.actor_id is distinct from p_actor
  or reservation.org_id is distinct from p_org or reservation.listing_id is distinct from p_listing
  or reservation.state<>'completed' or reservation.spec->>'key_role' is distinct from'gallery'
  or asset.upload_aborted is distinct from false or asset.idem_key is null
  or asset.idem_key!~'^studio-upload:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  or reservation.settled_at is null or reservation.settled_at<clock_timestamp()-interval'48 hours'
  or reservation.settled_at>clock_timestamp()then
  raise exception'RP409: This older saved copy needs its original or verified edit history before it can be added to listing photos';
 end if;
 return public.studio_attach_photo(p_actor,p_org,p_listing,p_asset,p_caption,p_provenance);
end$$;
revoke all on function public.studio_attach_photo_from_upload(uuid,uuid,uuid,uuid,text,uuid)from public,anon,authenticated,service_role;
grant execute on function public.studio_attach_photo_from_upload(uuid,uuid,uuid,uuid,text,uuid)to service_role;
commit;
