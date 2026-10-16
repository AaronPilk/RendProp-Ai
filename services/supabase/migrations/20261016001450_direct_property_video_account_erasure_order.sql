-- Existing account erasure inventories these exact listing assets before
-- deleting them. Restrictive photo-video source FKs must clear in that same
-- scope first; no ownership, inventory, money or FK policy changes.
begin;
do $patch$declare definition text;body text;anchor text:=$anchor$  delete from public.capture_assets where listing_id=any(listing_ids);$anchor$;
 addition text:=$addition$  -- Clear only bindings inside the existing inventoried solo-listing scope.
  -- Shared/foreign libraries and all financial tombstones remain unchanged.
  delete from public.property_video_sources where listing_id=any(listing_ids);
  delete from public.property_video_job_sources where job_id in(select id from public.property_video_jobs where listing_id=any(listing_ids));
  delete from public.property_video_preparations where listing_id=any(listing_ids);
  delete from public.property_video_compositions where listing_id=any(listing_ids);
  delete from public.capture_assets where listing_id=any(listing_ids);$addition$;
begin
 select prosrc into body from pg_proc where oid='public.prepare_account_deletion(uuid,text,text)'::regprocedure;
 if md5(body)not in('40bcc50faa163a664b1f0e6efcc42ef8','bbab0c6a2f5b6efcb769da00aeeb2f2a')then raise exception'Review changed canonical account deletion before photo-video binding cleanup';end if;
 if md5(body)='40bcc50faa163a664b1f0e6efcc42ef8'then
  if(length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then raise exception'Exact canonical capture deletion anchor changed';end if;
  definition:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
  execute replace(definition,anchor,addition);
 end if;
 if(select md5(prosrc)from pg_proc where oid='public.prepare_account_deletion(uuid,text,text)'::regprocedure)<>'bbab0c6a2f5b6efcb769da00aeeb2f2a'then raise exception'Unexpected canonical deletion body after binding cleanup';end if;
end$patch$;
commit;
