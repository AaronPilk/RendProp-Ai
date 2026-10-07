begin;
-- Contract only after Studio uses the service-owned actor-scoped photo RPCs.
-- Older direct photo mutations fail closed; authenticated gallery reads stay.
revoke insert,update,delete on table public.photos from public,anon,authenticated;
-- Explicit column grants are independent of table grants in PostgreSQL.
revoke insert(id,listing_id,original_key,enhanced_key,is_staged,caption,sort,created_at,is_main),
 update(id,listing_id,original_key,enhanced_key,is_staged,caption,sort,created_at,is_main)
 on table public.photos from public,anon,authenticated;
revoke execute on function public.studio_gallery_update(uuid,uuid,text,uuid,jsonb,jsonb)
 from public,anon,authenticated;
commit;
