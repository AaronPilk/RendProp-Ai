begin;
-- Separate empty, service-only startup funding overlay. No activation or cash is seeded.
-- Paid startup/account boundary costs are reserved once, rather than charging
-- each small org a whole million-operation billing unit. Empty until an owner
-- records actual paid cash and supplier/coverage evidence through service-only
-- provisioning. This is not a financial grant or a trial activation.
create table if not exists public.media_account_reserves(
 receipt_ref text primary key check(length(receipt_ref)between 8 and 200),
 account_id text not null check(account_id~'^[a-f0-9]{32}$'),cash_source text not null check(cash_source in('owner_paid_cash','business_paid_cash')),
 cash_evidence_sha256 text not null unique check(cash_evidence_sha256~'^[a-f0-9]{64}$'),
 starts_at timestamptz not null,ends_at timestamptz not null,cash_paid_cents bigint not null check(cash_paid_cents between 1 and 1000000000),
 tariff jsonb not null,reserves jsonb not null,allocated_org_cents bigint not null default 0 check(allocated_org_cents>=0),
 created_at timestamptz not null default now(),check(ends_at>starts_at and ends_at<=starts_at+interval '466 days')
);
alter table public.media_account_reserves enable row level security;
revoke all on public.media_account_reserves from public,anon,authenticated,service_role;
grant select on public.media_account_reserves to service_role;
create or replace function public.provision_media_account_reserve(p_ref text,p_account text,p_source text,p_evidence text,
 p_start timestamptz,p_end timestamptz,p_cash bigint,p_tariff jsonb,p_reserves jsonb)returns jsonb
language plpgsql security definer set search_path='' as $$
declare old public.media_account_reserves;k text;n numeric;total numeric:=0;boundary numeric;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_ref is null or length(p_ref)not between 8 and 200 or p_account is distinct from '9c332c75b96cc642621dad5d86d4bf18'
  or p_source is null or p_source not in('owner_paid_cash','business_paid_cash')or p_evidence is null or p_evidence!~'^[a-f0-9]{64}$'
  or p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>now()+interval '5 minutes'
  or p_end<=now()or p_end<=p_start or p_end>p_start+interval '466 days'or p_cash is null or p_cash not between 1 and 1000000000
  or jsonb_typeof(p_tariff)is distinct from 'object'or jsonb_typeof(p_reserves)is distinct from 'object'then raise exception 'RP400: Exact paid account reserve required';end if;
 foreach k in array array['r2_a_cents_per_million','r2_b_cents_per_million','worker_cents_per_million','worker_cpu_cents_per_million_ms','edge_cents_per_million','db_cents','logs_cents','storage_cents_per_gb_month']loop
  if jsonb_typeof(p_tariff->k)is distinct from 'number'then raise exception 'RP400: Complete account tariff required';end if;
  n:=(p_tariff->>k)::numeric;if n<0 or n>1000000000 then raise exception 'RP400: Invalid account tariff';end if;
 end loop;
 if(select count(*)from jsonb_object_keys(p_tariff))<>8 or(p_tariff->>'r2_a_cents_per_million')::numeric<450 or(p_tariff->>'r2_b_cents_per_million')::numeric<36
  or(p_tariff->>'worker_cents_per_million')::numeric<30 or(p_tariff->>'worker_cpu_cents_per_million_ms')::numeric<2 or(p_tariff->>'edge_cents_per_million')::numeric<200
  or(p_tariff->>'db_cents')::numeric<=0 or(p_tariff->>'storage_cents_per_gb_month')::numeric<1.5 then raise exception 'RP400: Complete supplier floor and fixed compute evidence required';end if;
 foreach k in array array['storage','delivery','compute','email','support','retention','uncertainty']loop
  if jsonb_typeof(p_reserves->k)is distinct from 'number'then raise exception 'RP400: Seven account reserves required';end if;
  n:=(p_reserves->>k)::numeric;if n<0 or n<>trunc(n)or n>1000000000 then raise exception 'RP400: Integer account reserves required';end if;total:=total+n;
 end loop;
 boundary:=ceil(extract(epoch from(p_end-p_start))/2592000)*((p_tariff->>'r2_a_cents_per_million')::numeric+(p_tariff->>'r2_b_cents_per_million')::numeric+(p_tariff->>'worker_cents_per_million')::numeric);
 if(select count(*)from jsonb_object_keys(p_reserves))<>7 or total>p_cash or(p_reserves->>'delivery')::numeric<ceil(boundary)
  or(p_reserves->>'compute')::numeric<(p_tariff->>'db_cents')::numeric+(p_tariff->>'logs_cents')::numeric+
   ceil(extract(epoch from(p_end-p_start))/2592000)*((p_tariff->>'edge_cents_per_million')::numeric+(p_tariff->>'worker_cpu_cents_per_million_ms')::numeric)then
  raise exception 'RP402: Paid account cash must cover fixed and rounded boundary costs';end if;
 perform pg_advisory_xact_lock(hashtextextended('media-account:'||p_account,72453));
 select * into old from public.media_account_reserves where receipt_ref=p_ref for update;
 if found then
  if row(old.account_id,old.cash_source,old.cash_evidence_sha256,old.starts_at,old.ends_at,old.cash_paid_cents,old.tariff,old.reserves)is distinct from
   row(p_account,p_source,p_evidence,p_start,p_end,p_cash,p_tariff,p_reserves)then raise exception 'RP409: Account reserve receipt is immutable';end if;
  return jsonb_build_object('reserved',true,'replay',true);end if;
 if exists(select 1 from public.media_account_reserves where cash_evidence_sha256=p_evidence or account_id=p_account and starts_at<p_end and ends_at>p_start)then
  raise exception 'RP409: Account cash or coverage cannot be reused';end if;
 insert into public.media_account_reserves(receipt_ref,account_id,cash_source,cash_evidence_sha256,starts_at,ends_at,cash_paid_cents,tariff,reserves)
 values(p_ref,p_account,p_source,p_evidence,p_start,p_end,p_cash,p_tariff,p_reserves);
 return jsonb_build_object('reserved',true,'replay',false);
end$$;
alter table public.media_delivery_budgets add column if not exists account_reserve_ref text references public.media_account_reserves(receipt_ref);
create or replace function public.provision_media_delivery_budget(p_org uuid,p_ref text,p_funding uuid,
 p_start timestamptz,p_end timestamptz,p_requests bigint,p_bytes bigint,p_storage bigint,
 p_tariff jsonb,p_reserves jsonb,p_evidence text,p_account_ref text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare old public.media_delivery_budgets; f public.serving_funding; a public.media_account_reserves; k text; n numeric;total numeric;
 delivery numeric;compute numeric;storage numeric;budget_id uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_org is null or p_ref is null or length(p_ref)not between 8 and 200 or p_evidence is null or p_evidence!~'^[a-f0-9]{64}$'
  or p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>now()+interval '5 minutes'
  or p_end<=now()or p_end<=p_start or p_end>p_start+interval '466 days'
  or p_requests is null or p_requests not between 1 and 10000000
  or p_bytes is null or p_bytes not between 1 and 10995116277760
  or p_storage is null or p_storage not between 1 and 1099511627776
  or jsonb_typeof(p_tariff)is distinct from 'object'or jsonb_typeof(p_reserves)is distinct from 'object'then
  raise exception 'RP400: Exact bounded media liability and supplier evidence required';end if;
 -- These are worst-case rates, without allocating free tiers. Invoice/plan
 -- evidence must cover DB compute and logs; a low average is not authority.
 foreach k in array array['r2_a_cents_per_million','r2_b_cents_per_million','worker_cents_per_million','worker_cpu_cents_per_million_ms','edge_cents_per_million','db_cents','logs_cents','storage_cents_per_gb_month']loop
  if jsonb_typeof(p_tariff->k)is distinct from 'number'then raise exception 'RP400: Complete media tariff required';end if;
  n:=(p_tariff->>k)::numeric;if n<0 or n>1000000000 then raise exception 'RP400: Invalid media tariff';end if;
 end loop;
 if(select count(*)from jsonb_object_keys(p_tariff))<>8 or(p_tariff->>'r2_a_cents_per_million')::numeric<450 or(p_tariff->>'r2_b_cents_per_million')::numeric<36
  or(p_tariff->>'worker_cents_per_million')::numeric<30 or(p_tariff->>'worker_cpu_cents_per_million_ms')::numeric<2
  or(p_tariff->>'edge_cents_per_million')::numeric<200 or(p_tariff->>'db_cents')::numeric<=0
  or(p_tariff->>'storage_cents_per_gb_month')::numeric<1.5 then raise exception 'RP400: Supplier floor and fixed compute reserve required';end if;
 foreach k in array array['delivery','compute','storage','retention']loop
  if jsonb_typeof(p_reserves->k)is distinct from 'number'then raise exception 'RP400: Complete media reserves required';end if;
  n:=(p_reserves->>k)::numeric;if n<0 or n<>trunc(n)or n>1000000000 then raise exception 'RP400: Integer media reserves required';end if;
 end loop;
 if(select count(*)from jsonb_object_keys(p_reserves))<>4 then raise exception 'RP400: Unknown media reserve';end if;
 -- Each charged authority request conservatively covers one Worker, four R2
 -- Class A writes, two Class B reads and one Edge invocation, even when it only validates/HEADs.
 -- Billable operation and GB-month rounding is included per budget.
 delivery:=p_requests::numeric/1000000*(4*(p_tariff->>'r2_a_cents_per_million')::numeric+2*(p_tariff->>'r2_b_cents_per_million')::numeric+(p_tariff->>'worker_cents_per_million')::numeric);
 compute:=p_requests::numeric/1000000*(p_tariff->>'edge_cents_per_million')::numeric+
  p_requests::numeric*1000/1000000*(p_tariff->>'worker_cpu_cents_per_million_ms')::numeric;
 storage:=ceil(p_storage::numeric/1000000000)*ceil(extract(epoch from(p_end-p_start))/2592000)*(p_tariff->>'storage_cents_per_gb_month')::numeric;
 if(p_reserves->>'delivery')::numeric<ceil(delivery)or(p_reserves->>'compute')::numeric<ceil(compute)
  or(p_reserves->>'storage')::numeric+(p_reserves->>'retention')::numeric<ceil(storage)then raise exception 'RP402: Media reserves do not cover the complete bounded period';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: Current workspace required';end if;
 perform pg_advisory_xact_lock(hashtextextended('media-budget:'||p_org,72453));
 select * into old from public.media_delivery_budgets where receipt_ref=p_ref;
 if found then
  if row(old.org_id,old.funding_id,old.account_reserve_ref,old.starts_at,old.ends_at,old.request_limit,old.byte_limit,old.storage_limit,old.tariff,old.reserves,old.evidence_sha256)
   is distinct from row(p_org,p_funding,p_account_ref,p_start,p_end,p_requests,p_bytes,p_storage,p_tariff,p_reserves,p_evidence)then raise exception 'RP409: Media budget receipt is immutable';end if;
  return jsonb_build_object('ok',true,'id',old.id,'replay',true);end if;
 select * into a from public.media_account_reserves where receipt_ref=p_account_ref for update;
 if not found or a.account_id<>'9c332c75b96cc642621dad5d86d4bf18'or a.starts_at>p_start or a.ends_at<p_end or a.tariff is distinct from p_tariff then
  raise exception 'RP402: Exact paid account reserve must cover complete media retention';end if;
 if exists(select 1 from public.media_delivery_budgets where org_id=p_org and starts_at<p_end and ends_at>p_start and(p_funding is null or funding_id is null))then raise exception 'RP409: Media periods cannot overlap or reset';end if;
 if p_funding is not null then
  select * into f from public.serving_funding where id=p_funding and org_id=p_org and revoked_at is null for update;
  if not found or p_start is distinct from f.starts_at or p_end is distinct from f.retention_ends_at or
   (p_reserves->>'delivery')::numeric>(f.reserve_components->>'delivery')::numeric or
   (p_reserves->>'compute')::numeric>(f.reserve_components->>'compute')::numeric or
   (p_reserves->>'storage')::numeric>(f.reserve_components->>'storage')::numeric or
   (p_reserves->>'retention')::numeric>(f.reserve_components->>'retention')::numeric then raise exception 'RP402: Verified funding does not cover media reserves';end if;
 elsif exists(select 1 from public.serving_funding where org_id=p_org)then
  raise exception 'RP402: Funded workspaces require their exact financial receipt';
 end if;
 total:=(p_reserves->>'delivery')::numeric+(p_reserves->>'compute')::numeric+(p_reserves->>'storage')::numeric+(p_reserves->>'retention')::numeric;
 if p_funding is null then
  if a.cash_paid_cents-a.allocated_org_cents-(select sum(value::numeric)from jsonb_each_text(a.reserves))<total then raise exception 'RP402: Account reserve has no unallocated org cash';end if;
  update public.media_account_reserves set allocated_org_cents=allocated_org_cents+total where receipt_ref=p_account_ref;
 end if;
 -- Legacy tester budgets are explicit operator-sponsored liabilities. The
 -- service-only RPC does not mint financial funding or activate a trial.
 insert into public.media_delivery_budgets(org_id,receipt_ref,funding_id,account_reserve_ref,starts_at,ends_at,request_limit,byte_limit,storage_limit,tariff,reserves,evidence_sha256)
 values(p_org,p_ref,p_funding,p_account_ref,p_start,p_end,p_requests,p_bytes,p_storage,p_tariff,p_reserves,p_evidence)returning media_delivery_budgets.id into budget_id;
 return jsonb_build_object('ok',true,'id',budget_id,'replay',false);
end$$;

drop function if exists public.provision_media_delivery_budget(uuid,text,uuid,timestamptz,timestamptz,bigint,bigint,bigint,jsonb,jsonb,text);
revoke all on function public.provision_media_account_reserve(text,text,text,text,timestamptz,timestamptz,bigint,jsonb,jsonb),public.provision_media_delivery_budget(uuid,text,uuid,timestamptz,timestamptz,bigint,bigint,bigint,jsonb,jsonb,text,text) from public,anon,authenticated;
grant execute on function public.provision_media_account_reserve(text,text,text,text,timestamptz,timestamptz,bigint,jsonb,jsonb),public.provision_media_delivery_budget(uuid,text,uuid,timestamptz,timestamptz,bigint,bigint,bigint,jsonb,jsonb,text,text) to service_role;
commit;
