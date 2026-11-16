-- New accounts no longer receive an automatic seven-day allowance on signup.
-- The seven-day introductory offer starts only after Apple confirms the user's
-- subscription. The existing verified-JWS entitlement path grants the selected
-- paid plan and its Apple expiry; there is no client-clock or signup trial grant.
-- Existing trial windows, manual grants and active subscriptions are preserved.

alter table public.orgs alter column plan_source drop default;
comment on column public.orgs.plan_source is
  'NULL for a new unsubscribed workspace; apple for verified StoreKit subscriptions; '
  'manual for owner grants; brokerage for contracted seats; trial for legacy signup windows.';

create or replace function public.handle_new_user() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_org uuid;
  v_email text := coalesce(lower(btrim(new.email)), '');
  v_admin boolean := false;
  v_name text := left(trim(coalesce(
    nullif(trim(new.raw_user_meta_data->>'name'), ''),
    nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
    ''
  )), 120);
begin
  -- Allowlisted e-mail → admin on first sign-up. No password, no shared secret,
  -- nothing hardcoded in the app.
  if v_email <> '' then
    select exists (select 1 from public.admin_allowlist a where a.email = v_email)
      into v_admin;
  end if;

  insert into public.profiles (id, email, name, is_admin)
  values (new.id, new.email, v_name, v_admin)
  on conflict (id) do nothing;

  -- Covers the on-conflict path (a profile row that somehow already existed):
  -- the insert above would have been skipped, so promote explicitly.
  if v_admin then
    update public.profiles set is_admin = true where id = new.id and is_admin is not true;
  end if;

  insert into public.orgs (name, plan, trial_ends_at, plan_source)
  values (
    case when v_name <> '' and v_name not like '%@%' then v_name else 'My business' end,
    'free',
    null,
    null
  )
  returning id into new_org;
  insert into public.memberships (user_id, org_id, role) values (new.id, new_org, 'owner');
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

