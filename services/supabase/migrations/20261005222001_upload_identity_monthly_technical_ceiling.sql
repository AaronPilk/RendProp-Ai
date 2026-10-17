-- Technical ingress ceilings derived from the existing feature entitlements.
-- These do not allocate a storage/retention margin budget or alter plan pricing.
begin;
create index if not exists upload_reservations_org_month on public.upload_reservations(org_id,day);
create or replace function public.upload_new_admission(p_actor uuid,p_org uuid,p_hold bigint)returns void
language plpgsql security definer set search_path='' as $$
declare anonymous boolean;raw_source text;selected_plan text;e public.plan_entitlements;cap bigint;used numeric;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if p_hold is null or p_hold<1 or p_hold>12884901888 then raise exception 'RP400: invalid upload reservation';end if;
 select u.is_anonymous into anonymous from auth.users u where u.id=p_actor;
 if not found or anonymous is null then raise exception 'RP401: Sign in to upload media';end if;
 -- This org lock serializes monthly admissions across listings and UTC days.
 -- Existing reservations replay before this helper and keep their held bytes.
 select o.plan_source into raw_source from public.orgs o where o.id=p_org and o.deleted_at is null for update;
 if not found then raise exception 'RP403: upload workspace is not writable';end if;
 selected_plan:=public.effective_plan(p_org);
 if anonymous then
  if raw_source is distinct from 'apple' or selected_plan not in('starter','pro','team')or not exists(
   select 1 from public.apple_subscriptions s where s.org_id=p_org and s.user_id=p_actor and s.plan=selected_plan
    and s.environment='Production'and s.status in('active','grace')and s.expires_at>=clock_timestamp()-interval '16 days'
  )then raise exception 'RP401: Sign in to upload media, or restore your active subscription';end if;
 end if;
 e:=public.org_entitlement(p_org);
 if public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org)then
  -- Preserve the named internal tester's existing physical daily boundary;
  -- an explicit grant is never inferred from a retail plan or user metadata.
  cap:=214748364800::bigint*31;
 else
  cap:=e.renders_per_month::bigint*12884901888::bigint+e.photo_edits_per_month::bigint*104857600::bigint;
 end if;
 if cap is null or cap<0 then raise exception 'RP503: upload admission is unavailable';end if;
 select coalesce(sum(r.held_bytes::numeric+r.spent_bytes::numeric),0)into used from public.upload_reservations r
  where r.org_id=p_org and r.day>=date_trunc('month',clock_timestamp()at time zone 'UTC')::date
   and r.day<(date_trunc('month',clock_timestamp()at time zone 'UTC')+interval '1 month')::date;
 if used+p_hold>cap then raise exception 'RP429: monthly technical upload reservation ceiling exhausted';end if;
end$$;
revoke all on function public.upload_new_admission(uuid,uuid,bigint)from public,anon,authenticated;
grant execute on function public.upload_new_admission(uuid,uuid,bigint)to service_role;

-- Patch the real transport function, retaining spec/CAS/role/daily fences and
-- its complete existing-reservation replay path. Unknown bodies fail closed.
do $$declare body text;old text;patched text;begin
 body:=pg_get_functiondef('public.reserve_upload_assets(uuid,jsonb)'::regprocedure);
 old:='  select * into l from listings where id = (p_assets->0->>''listing_id'')::uuid and deleted_at is null for update;';
 patched:='  perform 1 from public.orgs where id=(select org_id from public.listings where id=(p_assets->0->>''listing_id'')::uuid)for update;'||E'\n'||old;
 if position(patched in body)=0 then
  if position(old in body)=0 then raise exception 'RP409: unknown upload listing lock body';end if;
  body:=replace(body,old,patched);
  old:='    hold := n * case when s->>''parts_total'' is null then 2 else 1 end;';
  patched:=old||E'\n'||'    perform public.upload_new_admission(p_actor,l.org_id,hold);';
  if position(old in body)=0 then raise exception 'RP409: unknown upload reservation hold body';end if;
  body:=replace(body,old,patched);execute body;
 elsif position('    perform public.upload_new_admission(p_actor,l.org_id,hold);'in body)=0 then
  raise exception 'RP409: partial upload admission patch';
 end if;
end$$;

-- Service-only drains use the existing Vault names. No service credential is
-- copied into a cron command, API response or migration source. Install schedules
-- inactive in this transaction. Deployment must review existing cleanup candidates
-- and retained-media references before explicitly enabling these maintenance jobs.
create or replace function public.media_privacy_drain(p_task text)returns bigint
language plpgsql security definer set search_path='' as $$
declare service_key text;functions_base text;request_id bigint;path text;
begin
 if current_setting('role',true)is distinct from 'service_role'and session_user<>'postgres'then raise insufficient_privilege using message='service role required';end if;
 if p_task='uploads'then path:='/uploads/sweep';
 elsif p_task='privacy'then path:='/me/sweep-privacy';
 else raise exception 'RP400: unknown maintenance task';end if;
 if not exists(select 1 from pg_catalog.pg_extension where extname='pg_net')or to_regclass('vault.decrypted_secrets')is null then
  raise exception 'RP503: media cleanup scheduler is not configured';end if;
 select decrypted_secret into service_key from vault.decrypted_secrets where name='notify_service_key';
 select decrypted_secret into functions_base from vault.decrypted_secrets where name='notify_functions_base';
 if nullif(btrim(service_key),'')is null or functions_base is null or functions_base!~'^https://[a-z0-9]{20}[.]supabase[.]co/functions/v1/?$'then
  raise exception 'RP503: media cleanup scheduler is not configured';end if;
 select net.http_post(url:=rtrim(functions_base,'/')||path,headers:=jsonb_build_object('Authorization','Bearer '||service_key,'Content-Type','application/json'),body:='{}'::jsonb,timeout_milliseconds:=25000)into request_id;
 return request_id;
end$$;
revoke all on function public.media_privacy_drain(text)from public,anon,authenticated;
grant execute on function public.media_privacy_drain(text)to service_role;
do $$begin
 if exists(select 1 from pg_catalog.pg_extension where extname='pg_cron')and exists(select 1 from pg_catalog.pg_extension where extname='pg_net')then
  perform cron.alter_job(cron.schedule('upload-cleanup-drain','*/5 * * * *',$command$select public.media_privacy_drain('uploads');$command$),active:=false);
  perform cron.alter_job(cron.schedule('listing-lead-privacy-drain','*/5 * * * *',$command$select public.media_privacy_drain('privacy');$command$),active:=false);
  perform cron.alter_job(cron.schedule('private-message-retention','43 4 * * *',$command$set role service_role;select public.privacy_retention_sweep();$command$),active:=false);
 else
  raise notice 'Media cleanup schedules unavailable; deployment must verify pg_cron/pg_net and all three maintenance jobs before any sweep rollout.';
 end if;
end$$;
commit;
