-- Already-authorized media is a functional product service, not a new paid AI
-- dispatch. Keep immutable funding/budget records untouched; meter actual
-- authority requests and conservatively admitted bytes without fabricating cash.
begin;
create table if not exists public.media_serving_usage (
  org_id uuid not null references public.orgs(id) on delete cascade,
  usage_day date not null,
  used_requests bigint not null default 0 check(used_requests>=0),
  used_bytes bigint not null default 0 check(used_bytes>=0),
  updated_at timestamptz not null default now(),
  primary key(org_id,usage_day)
);
alter table public.media_serving_usage enable row level security;
revoke all on public.media_serving_usage from public,anon,authenticated,service_role;
grant select on public.media_serving_usage to service_role;
comment on table public.media_serving_usage is
  'Unpriced media authority-request/admitted-byte usage, not a supplier bill, paid cash, AI grant or subscription entitlement. Current publication/ownership/hosting authority stays in the media caller.';
do $guard$declare prior text;current_body text;begin
  if to_regprocedure('public.media_delivery_admit_before_product_serving_20261015(uuid,bigint,boolean)') is null then
    select md5(prosrc)into prior from pg_proc where oid='public.media_delivery_admit(uuid,bigint,boolean)'::regprocedure;
    if prior is distinct from 'df4b527bf5c38dabbfcae08494367cdd' then raise exception 'Review changed media delivery admission before product serving';end if;
    alter function public.media_delivery_admit(uuid,bigint,boolean) rename to media_delivery_admit_before_product_serving_20261015;
  else
    select md5(prosrc)into prior from pg_proc where oid='public.media_delivery_admit_before_product_serving_20261015(uuid,bigint,boolean)'::regprocedure;
    if prior is distinct from 'df4b527bf5c38dabbfcae08494367cdd' then raise exception 'Review changed previous media delivery admission';end if;
    select md5(prosrc)into current_body from pg_proc where oid=to_regprocedure('public.media_delivery_admit(uuid,bigint,boolean)');
    if current_body is not null and current_body is distinct from '8ff14f22887cd9e76e5beaee4a031c6d' then raise exception 'Review changed product media admission';end if;
  end if;
end$guard$;
create or replace function public.media_delivery_admit(p_org uuid,p_bytes bigint,p_required boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare billing uuid;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_org is null or p_bytes is null or p_bytes not between 0 and 268435456 or p_required is null then
    raise exception 'RP400: Invalid media admission';
  end if;
  -- Shared reads may proceed together. Deletion still conflicts with SHARE;
  -- content/publication/hosting authority remains fresh in the caller.
  perform 1 from public.orgs where id=p_org and deleted_at is null for share;
  if not found then raise exception 'RP404: Workspace unavailable'; end if;
  billing:=public.library_billing_org(p_org);
  perform 1 from public.orgs where id=billing and deleted_at is null for share;
  if not found then raise exception 'RP404: Billing workspace unavailable'; end if;
  insert into public.media_serving_usage(org_id,usage_day,used_requests,used_bytes)
    values(billing,(now() at time zone 'UTC')::date,1,p_bytes)
  on conflict(org_id,usage_day) do update
    set used_requests=public.media_serving_usage.used_requests+1,
        used_bytes=public.media_serving_usage.used_bytes+excluded.used_bytes,
        updated_at=now();
  return jsonb_build_object('admitted',true,'legacy_unbudgeted',false,
    'basis','product_media_serving','financial_budget_bypassed',true,
    'request_counted',true,'bytes_counted',p_bytes,'infrastructure_cost','unpriced');
end$$;
revoke all on function public.media_delivery_admit(uuid,bigint,boolean),
 public.media_delivery_admit_before_product_serving_20261015(uuid,bigint,boolean)from public,anon,authenticated;
grant execute on function public.media_delivery_admit(uuid,bigint,boolean),
 public.media_delivery_admit_before_product_serving_20261015(uuid,bigint,boolean)to service_role;
commit;
