begin;
-- Account deletion already creates a verified leased cleanup request. Connect
-- its existing retry endpoint so temporary storage-write windows really drain.
-- Reuse the project's existing private service credential and functions base
-- in Vault; no credential is embedded in migration or cron command text.
create or replace function public.account_deletion_drain()
returns bigint language plpgsql security definer set search_path='' as $$
declare service_key text; functions_base text; request_id bigint;
begin
  if not exists(select 1 from public.deletion_requests where status in('pending','processing')
      and not manual_review_required and next_cleanup_at<=clock_timestamp()) then return null;end if;
  select decrypted_secret into service_key from vault.decrypted_secrets where name='notify_service_key';
  select decrypted_secret into functions_base from vault.decrypted_secrets where name='notify_functions_base';
  if service_key is null or functions_base is null or functions_base !~ '^https://[a-z0-9]{20}[.]supabase[.]co/functions/v1/?$' then
    raise exception 'Account cleanup requires the existing project service credential and functions base in Vault';
  end if;
  select net.http_post(url:=rtrim(functions_base,'/')||'/me/sweep-deletions',
    headers:=jsonb_build_object('Authorization','Bearer '||service_key,'Content-Type','application/json'),
    body:='{}'::jsonb,timeout_milliseconds:=25000) into request_id;
  return request_id;
end;
$$;
revoke all on function public.account_deletion_drain() from public,anon,authenticated;
grant execute on function public.account_deletion_drain() to service_role;
do $$
begin
  if exists(select 1 from pg_extension where extname='pg_cron') and exists(select 1 from pg_extension where extname='pg_net') then
    perform cron.schedule('account-deletion-drain','*/5 * * * *','select public.account_deletion_drain();');
  else
    raise notice 'Account cleanup schedule unavailable on this database; production deployment must verify pg_cron/pg_net and account-deletion-drain.';
  end if;
end;
$$;
commit;
