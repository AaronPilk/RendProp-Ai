-- Build 59 follow-up — 2026-10-11 (TestFlight 58/59 beta feedback)
--
-- Deleting a listing failed for everyone on builds 58 and 59. The build-58
-- DELETE route wrote `trash_expires_at` through the tenant (RLS) client, but
-- `authenticated` only holds column UPDATE grants on listings for deleted_at,
-- gallery_asset_ids, main_photo_key, mls_ref and source — so PostgREST answered
-- "permission denied for table listings", the route returned 400, the phone
-- swallowed it (fire-and-forget), and Recently deleted stayed empty while the
-- listing came back on the next sync. The build-58 SQL suite ran that write as
-- service_role, which is why it never saw the grant.
--
-- The delete now goes through this service-only RPC with the same authority
-- the RLS policy applies (listing_content_access(actor, listing, write)). It
-- keeps the 30-day window and the trigger behaviour from build 58 unchanged:
-- the unpublish trigger still takes the tour down at once and the cleanup
-- trigger still waits for the window.
begin;

create or replace function public.trash_listing(p_actor uuid,p_listing uuid) returns jsonb
 language plpgsql security definer set search_path to ''
as $function$
declare l public.listings;until timestamptz;
begin
 if current_setting('role',true)not in('service_role','postgres','supabase_admin')and not(current_setting('role',true)='none'and session_user in('postgres','supabase_admin'))then raise insufficient_privilege;end if;
 if p_actor is null or p_listing is null then raise exception 'RP400: Choose a valid listing';end if;
 select * into l from public.listings where id=p_listing for update;
 -- An already-trashed listing answers exactly as the build-57 route did: not found.
 if l.id is null or l.deleted_at is not null then raise exception 'RP404: Listing not found';end if;
 if not public.listing_content_access(p_actor,p_listing,true)then raise exception 'RP403: Your role does not permit deleting listings';end if;
 if exists(select 1 from public.deletion_requests d where d.user_id=p_actor and d.status in('pending','processing'))then raise exception 'RP409: This account is being deleted';end if;
 if exists(select 1 from public.orgs o where o.id=l.org_id and o.deleted_at is not null)then raise exception 'RP403: This listing library is unavailable';end if;
 until:=now()+interval '30 days';
 update public.listings set deleted_at=now(),trash_expires_at=until where id=l.id;
 return jsonb_build_object('ok',true,'actor_id',p_actor,'listing_id',l.id,'org_id',l.org_id,'address',l.address,'restorable_until',until);
end$function$;
revoke all on function public.trash_listing(uuid,uuid) from public,anon,authenticated;
grant execute on function public.trash_listing(uuid,uuid) to service_role,postgres;
comment on function public.trash_listing(uuid,uuid) is
 'Service-only. Opens the 30-day restore window for a live listing with the writer''s own listing authority; the tenant client has no column grant on trash_expires_at.';

commit;
