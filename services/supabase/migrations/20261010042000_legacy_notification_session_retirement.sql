-- Close legacy NULL-session device registration during account switching.
-- No existing device rows or Auth sessions are rewritten. Recovery uses a new
-- verified Auth session; the exact current binding continues to work.
begin;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.notification_register_device_session(uuid,uuid,text,text,text,text,text)'::regprocedure; if h not in('496ab4845be208fa8e59ed40100d3d70','1864eeb90382f6e43ecb140ae2b29fed')then raise exception 'Review changed function notification_register_device_session';end if;end$pin$;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.notification_unregister_device(uuid,uuid,text,text)'::regprocedure; if h not in('32bfb5f12ab89b71cfc1ceb90f52fcb4','a3c0fcb96cc119bb0130aa4449a77430')then raise exception 'Review changed function notification_unregister_device';end if;end$pin$;

create table if not exists public.notification_legacy_device_retirements(
 user_id uuid not null references public.profiles(id)on delete cascade,
 token_sha256 text not null check(token_sha256~'^[0-9a-f]{64}$'),
 environment text not null check(environment in('sandbox','production')),
 retired_at timestamptz not null,
 primary key(user_id,token_sha256,environment));
alter table public.notification_legacy_device_retirements enable row level security;
revoke all on public.notification_legacy_device_retirements from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.notification_register_device_session(p_user uuid, p_session uuid, p_token text, p_bundle_id text DEFAULT NULL::text, p_environment text DEFAULT NULL::text, p_locale text DEFAULT NULL::text, p_app_version text DEFAULT NULL::text)
 RETURNS notification_devices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_token text:=lower(btrim(coalesce(p_token,'')));v_env text:=lower(btrim(coalesce(p_environment,'production')));digest text;v_row public.notification_devices;prior public.notification_devices;
begin
 if p_user is null or p_session is null then raise exception 'RP400: A device session is required';end if;
 if v_token=''or length(v_token)>400 or v_token!~'^[0-9a-fA-F]+$'then raise exception 'RP400: device_token must be a hexadecimal APNs token';end if;
 if v_env not in('sandbox','production')then raise exception 'RP400: environment must be sandbox or production';end if;
 digest:=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_token,'UTF8')),'hex');
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('notification-device:'||digest,72453));
 perform 1 from public.profiles where id=p_user for key share;
 if not found then raise exception 'RP401: Sign in again';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: This account is being deleted';end if;
 if exists(select 1 from public.notification_device_session_tombstones t where t.user_id=p_user and t.session_id=p_session and t.token_sha256=digest)
 then raise exception 'RP409: This device session has signed out';end if;
 -- A legacy row did not record the outgoing session. A cutoff fences its
 -- older sessions without blocking this already-bound session or a verified
 -- genuinely new Auth sign-in. Missing/undated Auth evidence fails closed.
 if exists(select 1 from public.notification_legacy_device_retirements r
  where r.user_id=p_user and r.token_sha256=digest
   and not exists(select 1 from public.notification_devices d where lower(d.device_token)=v_token
    and d.user_id=p_user and d.environment=v_env and d.registration_session_id=p_session)
   and not exists(select 1 from auth.sessions s where s.id=p_session and s.user_id=p_user and s.created_at>r.retired_at))
 then raise exception 'RP409: This device session has signed out';end if;
 -- A failed/expired outgoing DELETE must not allow its late session POST to
 -- reclaim a token after a verified newer account/session has taken it over.
 -- Do not lock a device row before its old profile: account deletion starts
 -- at profiles and may cascade this row. NOWAIT refuses a concurrent profile
 -- purge without introducing an inverse wait; retry sees the purged row gone.
 for prior in select *from public.notification_devices
  where lower(device_token)=v_token
   and(user_id is distinct from p_user or registration_session_id is distinct from p_session)
  order by user_id,id
 loop
  begin
   perform 1 from public.profiles where id=prior.user_id for key share nowait;
  exception when lock_not_available then raise exception 'RP409: Device ownership is changing; retry registration';end;
  if found then
   if prior.registration_session_id is null then
    insert into public.notification_legacy_device_retirements(user_id,token_sha256,environment,retired_at)
    values(prior.user_id,digest,prior.environment,pg_catalog.clock_timestamp())
    on conflict(user_id,token_sha256,environment)do update set retired_at=greatest(public.notification_legacy_device_retirements.retired_at,excluded.retired_at);
   else
    insert into public.notification_device_session_tombstones(user_id,session_id,token_sha256,environment)
    values(prior.user_id,prior.registration_session_id,digest,prior.environment)on conflict do nothing;
   end if;
  end if;
 end loop;
 -- Retire pre-normalization spellings under the canonical token lock.
 -- A legitimate new registration rebinds that physical device, as before.
 delete from public.notification_devices where lower(device_token)=v_token and device_token<>v_token;
 v_row:=public.notification_register_device(p_user,v_token,p_bundle_id,v_env,p_locale,p_app_version);
 update public.notification_devices set registration_session_id=p_session where id=v_row.id returning *into v_row;
 return v_row;
end$function$;

revoke all on function public.notification_register_device_session(uuid,uuid,text,text,text,text,text)from public,anon,authenticated;
grant execute on function public.notification_register_device_session(uuid,uuid,text,text,text,text,text)to service_role,postgres;
CREATE OR REPLACE FUNCTION public.notification_unregister_device(p_user uuid, p_session uuid, p_token text, p_environment text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_token text:=lower(btrim(coalesce(p_token,'')));v_env text:=lower(btrim(coalesce(p_environment,'production')));digest text;removed integer;
begin
 if p_user is null or p_session is null then raise exception 'RP400: A device session is required';end if;
 if v_token=''or length(v_token)>400 or v_token!~'^[0-9a-fA-F]+$'then raise exception 'RP400: device_token must be a hexadecimal APNs token';end if;
 if v_env not in('sandbox','production')then raise exception 'RP400: environment must be sandbox or production';end if;
 digest:=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_token,'UTF8')),'hex');
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('notification-device:'||digest,72453));
 perform 1 from public.profiles where id=p_user for key share;
 if not found then raise exception 'RP401: Sign in again';end if;
 insert into public.notification_device_session_tombstones(user_id,session_id,token_sha256,environment)
 values(p_user,p_session,digest,v_env)on conflict do nothing;
 -- Preserve the legacy owner's session boundary before successful removal
 -- erases the last device row. The token lock also serializes replacement.
 insert into public.notification_legacy_device_retirements(user_id,token_sha256,environment,retired_at)
 select p_user,digest,d.environment,pg_catalog.clock_timestamp()
 from public.notification_devices d where d.user_id=p_user and lower(d.device_token)=v_token
  and d.environment=v_env and d.registration_session_id is null
 on conflict(user_id,token_sha256,environment)do update set retired_at=greatest(public.notification_legacy_device_retirements.retired_at,excluded.retired_at);
 delete from public.notification_devices where user_id=p_user and lower(device_token)=v_token and environment=v_env
  and(registration_session_id=p_session or registration_session_id is null);
 get diagnostics removed=row_count;
 return jsonb_build_object('ok',true,'unregistered',true,'removed',removed>0);
end$function$;

revoke all on function public.notification_unregister_device(uuid,uuid,text,text)from public,anon,authenticated;
grant execute on function public.notification_unregister_device(uuid,uuid,text,text)to service_role,postgres;
commit;
