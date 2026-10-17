-- Explicit existing product-admin testing authority may serve its published
-- media without fabricating paid account reserves. Ordinary financial budgets
-- remain byte-for-byte delegated to the previous service-only implementation.
begin;

create table if not exists public.owner_testing_media_usage (
  org_id uuid not null references public.orgs(id) on delete cascade,
  usage_day date not null,
  used_requests bigint not null default 0 check (used_requests >= 0),
  used_bytes bigint not null default 0 check (used_bytes >= 0),
  updated_at timestamptz not null default now(),
  primary key (org_id, usage_day)
);
alter table public.owner_testing_media_usage enable row level security;
revoke all on public.owner_testing_media_usage from public, anon, authenticated, service_role;
grant select on public.owner_testing_media_usage to service_role;
comment on table public.owner_testing_media_usage is
  'Conservative authority-request and admitted-byte usage for existing product-admin owner testing. Infrastructure cost is unpriced, not zero or paid funding. No client writes or entitlement grant.';

do $$begin
  if to_regprocedure('public.media_delivery_admit_before_owner_testing_20261015(uuid,bigint,boolean)') is null then
    if (select md5(prosrc) from pg_proc where oid='public.media_delivery_admit(uuid,bigint,boolean)'::regprocedure)
      is distinct from 'e1fde5a0b8b7942c07bb95eac48f0ae5' then
      raise exception 'Review changed media delivery admission';
    end if;
    alter function public.media_delivery_admit(uuid,bigint,boolean)
      rename to media_delivery_admit_before_owner_testing_20261015;
  elsif (select md5(prosrc) from pg_proc where oid='public.media_delivery_admit_before_owner_testing_20261015(uuid,bigint,boolean)'::regprocedure)
    is distinct from 'e1fde5a0b8b7942c07bb95eac48f0ae5' then
    raise exception 'Review changed previous media delivery admission';
  end if;
end$$;

create or replace function public.media_delivery_admit(p_org uuid, p_bytes bigint, p_required boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare billing uuid;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_org is null or p_bytes is null or p_bytes not between 0 and 268435456 or p_required is null then
    raise exception 'RP400: Invalid media admission';
  end if;
  perform 1 from public.orgs where id=p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: Workspace unavailable'; end if;
  billing:=public.library_billing_org(p_org);
  -- This existing helper rechecks a named, live product-admin owner, manual
  -- Team workspace, explicit active grant, contract precedence and deletion.
  -- JWT metadata, a Team plan alone and private sponsorship are not authority.
  if public.org_has_internal_testing_grant(billing) then
    insert into public.owner_testing_media_usage(org_id,usage_day,used_requests,used_bytes)
      values(billing,(now() at time zone 'UTC')::date,1,p_bytes)
    on conflict(org_id,usage_day) do update
      set used_requests=public.owner_testing_media_usage.used_requests+1,
          used_bytes=public.owner_testing_media_usage.used_bytes+excluded.used_bytes,
          updated_at=now();
    return jsonb_build_object('admitted',true,'legacy_unbudgeted',false,
      'basis','owner_internal_testing','financial_budget_bypassed',true,
      'request_counted',true,'bytes_counted',p_bytes,'infrastructure_cost','unpriced');
  end if;
  return public.media_delivery_admit_before_owner_testing_20261015(p_org,p_bytes,p_required);
end$$;

revoke all on function public.media_delivery_admit(uuid,bigint,boolean),
  public.media_delivery_admit_before_owner_testing_20261015(uuid,bigint,boolean)
  from public, anon, authenticated;
grant execute on function public.media_delivery_admit(uuid,bigint,boolean),
  public.media_delivery_admit_before_owner_testing_20261015(uuid,bigint,boolean)
  to service_role;
commit;
