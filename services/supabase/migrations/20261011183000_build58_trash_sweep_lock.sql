-- Serialize the expiry sweep with restore_listing's row lock. A restore that
-- began before expiry must not race an uncommitted cleanup enqueue and revive
-- a listing whose files are already queued for removal.
begin;
create or replace function public.listing_trash_sweep() returns integer
 language plpgsql security definer set search_path to ''
as $function$
declare r record;n integer:=0;
begin
 if current_setting('role',true)is distinct from 'service_role'and session_user<>'postgres'then raise insufficient_privilege using message='service role required';end if;
 for r in select id from public.listings where deleted_at is not null and trash_expires_at is not null and trash_expires_at<=now()
   and not exists(select 1 from public.privacy_cleanup_jobs j where j.kind='listing'and j.source_id=listings.id)
   order by trash_expires_at,id limit 200 for update of listings skip locked loop
  perform public.queue_listing_media_cleanup(r.id);
  update public.listings set trash_expires_at=null where id=r.id;
  n:=n+1;
 end loop;
 return n;
end$function$;
revoke all on function public.listing_trash_sweep() from public,anon,authenticated;
grant execute on function public.listing_trash_sweep() to service_role,postgres;
commit;
