begin;
-- Optional, empty package authority. No SKU, count, funding or offer is seeded.
-- The existing inclusive quarter-of-net fence stays authoritative. A protected
-- count means admitted operations, never a promise of successful image outputs.
create table if not exists public.serving_photo_partitions(
 funding_id uuid not null, slice_index integer not null, org_id uuid not null,
 starts_at timestamptz not null,ends_at timestamptz not null,
 photo_cap integer not null check(photo_cap between 0 and 10000),
 photo_hold_cents numeric(20,4) not null check(photo_hold_cents=35.1296),
 protected_photo_cents bigint not null check(protected_photo_cents>=0),
 other_ai_cents bigint not null check(other_ai_cents>=0),
 policy text not null check(policy='one-gemini-1k-4096-plus-one-kontext-20261007'),
 tariff_version text not null check(tariff_version='published-standard-20261006'),
 evidence_sha256 text not null check(evidence_sha256~'^[a-f0-9]{64}$'),
 created_at timestamptz not null default now(),primary key(funding_id,slice_index),
 foreign key(funding_id,slice_index)references public.serving_funding_slices(funding_id,slice_index),
 check(ends_at>starts_at and protected_photo_cents=ceil(photo_cap*photo_hold_cents))
);
create table if not exists public.serving_photo_admissions(
 funding_id uuid not null,slice_index integer not null,org_id uuid not null,actor_id uuid not null,
 request_key text not null,task text not null,input_sha256 text not null,
 created_at timestamptz not null default now(),primary key(funding_id,slice_index,actor_id,request_key),
 foreign key(funding_id,slice_index)references public.serving_photo_partitions(funding_id,slice_index),
 check(task~'^photo\.(twilight|sky|lawn|declutter|stage|custom)$'),
 check(request_key~'^[A-Za-z0-9:_-]{8,128}$'and input_sha256~'^[a-f0-9]{64}$')
);
alter table public.serving_photo_partitions enable row level security;
alter table public.serving_photo_admissions enable row level security;
revoke all on public.serving_photo_partitions,public.serving_photo_admissions from public,anon,authenticated,service_role;
grant select on public.serving_photo_partitions,public.serving_photo_admissions to service_role;
comment on table public.serving_photo_admissions is 'Retained account-related provider-admission tombstones. Membership, deletion, refunds and device changes cannot replenish included photo admissions. No raw input or media capability is retained.';

create or replace function public.provision_serving_photo_partition(p_funding uuid,p_slice integer,p_photo_cap integer,
 p_other_ai_cents bigint,p_policy text,p_tariff_version text,p_evidence text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare f public.serving_funding;s public.serving_funding_slices;old public.serving_photo_partitions;protected bigint;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_funding is null or p_slice is null or p_photo_cap is null or p_photo_cap not between 0 and 10000
  or p_other_ai_cents is null or p_other_ai_cents not between 0 and 100000000
  or p_policy is distinct from 'one-gemini-1k-4096-plus-one-kontext-20261007'
  or p_tariff_version is distinct from 'published-standard-20261006'
  or p_evidence is null or p_evidence!~'^[a-f0-9]{64}$'then raise exception 'RP400: Exact bounded photo package and tariff evidence required';end if;
 select * into f from public.serving_funding where id=p_funding;
 if not found then raise exception 'RP403: A verified funding receipt is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||f.org_id,72452));
 select * into f from public.serving_funding where id=p_funding for update;
 select * into s from public.serving_funding_slices where funding_id=p_funding and slice_index=p_slice for update;
 if s.funding_id is null or f.revoked_at is not null or f.ends_at<=now()or s.org_id<>f.org_id
  or not exists(select 1 from public.orgs where id=f.org_id and deleted_at is null)
 then raise exception 'RP403: A current immutable funding interval is required';end if;
 if exists(select 1 from public.serving_funding other where other.org_id=f.org_id and other.id<>f.id and other.revoked_at is null
  and other.starts_at<s.ends_at and other.ends_at>s.starts_at)then raise exception 'RP409: A package requires one unambiguous funded interval';end if;
 protected:=ceil(p_photo_cap*35.1296);
 if protected+p_other_ai_cents>s.total_budget_cents-s.recurring_reserve_cents then raise exception 'RP402: The photo package and other AI wallet exceed funded cash after serving reserves';end if;
 select * into old from public.serving_photo_partitions where funding_id=p_funding and slice_index=p_slice;
 if found then
  if row(old.photo_cap,old.other_ai_cents,old.policy,old.tariff_version,old.evidence_sha256)is distinct from
   row(p_photo_cap,p_other_ai_cents,p_policy,p_tariff_version,p_evidence)then raise exception 'RP409: The funded package partition is immutable';end if;
  return jsonb_build_object('partitioned',true,'replay',true,'photo_cap',old.photo_cap,'protected_photo_cents',old.protected_photo_cents,'other_ai_cents',old.other_ai_cents);
 end if;
 if exists(select 1 from public.serving_cost_reservations where funding_id=p_funding and slice_index=p_slice)
 then raise exception 'RP409: A package cannot reinterpret an already admitted financial interval';end if;
 insert into public.serving_photo_partitions(funding_id,slice_index,org_id,starts_at,ends_at,photo_cap,photo_hold_cents,
  protected_photo_cents,other_ai_cents,policy,tariff_version,evidence_sha256)
 values(p_funding,p_slice,f.org_id,s.starts_at,s.ends_at,p_photo_cap,35.1296,protected,p_other_ai_cents,p_policy,p_tariff_version,p_evidence);
 return jsonb_build_object('partitioned',true,'replay',false,'photo_cap',p_photo_cap,'protected_photo_cents',protected,'other_ai_cents',p_other_ai_cents);
end$$;
revoke all on function public.provision_serving_photo_partition(uuid,integer,integer,bigint,text,text,text)from public,anon,authenticated;
grant execute on function public.provision_serving_photo_partition(uuid,integer,integer,bigint,text,text,text)to service_role;

create or replace function public.serving_photo_partition_guard()returns trigger
language plpgsql security definer set search_path='' as $$
declare p public.serving_photo_partitions;a public.serving_photo_admissions;task text;spent numeric;
begin
 if new.sponsored_unlimited then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||new.org_id,72452));
 if exists(select 1 from public.serving_photo_partitions package join public.serving_funding f on f.id=package.funding_id
  where package.org_id=new.org_id and package.starts_at<=now()and package.ends_at>now()and f.revoked_at is null)
  and(select count(*)from public.serving_funding where org_id=new.org_id and revoked_at is null and starts_at<=now()and ends_at>now())<>1
 then raise exception 'RP409: The configured package funding interval is ambiguous';end if;
 if exists(select 1 from public.serving_photo_partitions where funding_id=new.funding_id and starts_at<=now()and ends_at>now())
  and(select count(*)from public.serving_funding_slices where funding_id=new.funding_id and starts_at<=now()and ends_at>now())<>1
 then raise exception 'RP409: The configured package service slice is ambiguous';end if;
 select * into p from public.serving_photo_partitions where funding_id=new.funding_id and slice_index=new.slice_index;
 if not found then return new;end if;
 if new.org_id<>p.org_id or p.starts_at>now()or p.ends_at<=now()then raise exception 'RP403: The package belongs to another or expired funding interval';end if;
 if new.stage~'^photo\.(twilight|sky|lawn|declutter|stage|custom):[01]$'then
  task:=split_part(new.stage,':',1);
  if new.tariff_version<>p.tariff_version
   or(right(new.stage,2)=':0'and(new.provider<>'gemini'or new.model<>'gemini-3.1-flash-image'or new.hold_cents<>31.1296))
   or(right(new.stage,2)=':1'and(new.provider<>'fal'or new.model not in('flux-pro/kontext','fal-ai/flux-pro/kontext')or new.hold_cents<>4))
  then raise exception 'RP403: This photo attempt does not match the immutable bounded tariff';end if;
  select * into a from public.serving_photo_admissions where funding_id=p.funding_id and slice_index=p.slice_index and actor_id=new.actor_id and request_key=new.request_key;
  if right(new.stage,2)=':0'then
   if a.funding_id is not null then raise exception 'RP409: This photo admission is already retained';end if;
   if(select count(*)from public.serving_photo_admissions where funding_id=p.funding_id and slice_index=p.slice_index)>=p.photo_cap
   then raise exception 'RP402: The included photo admissions are exhausted';end if;
   insert into public.serving_photo_admissions(funding_id,slice_index,org_id,actor_id,request_key,task,input_sha256)
   values(p.funding_id,p.slice_index,p.org_id,new.actor_id,new.request_key,task,new.input_sha256);
  elsif a.funding_id is null or a.task<>task or a.input_sha256<>new.input_sha256 then
   raise exception 'RP409: A fallback requires its exact retained primary photo admission';
  end if;
  -- Cash is reserved for every included two-attempt operation even when a
  -- proven predispatch rejection releases the provider's particular hold.
  return new;
 end if;
 if new.stage~'^photo\.'and new.stage not in('photo.suggest','photo.improve_prompt')then
  raise exception 'RP403: This photo stage is outside the bounded package';end if;
 select coalesce(sum(hold_cents),0)into spent from public.serving_cost_reservations
  where funding_id=p.funding_id and slice_index=p.slice_index and state<>'rejected'
   and stage!~'^photo\.(twilight|sky|lawn|declutter|stage|custom):[01]$';
 if spent+new.hold_cents>p.other_ai_cents then raise exception 'RP402: The separate helper and other AI wallet is exhausted';end if;
 return new;
end$$;
revoke all on function public.serving_photo_partition_guard()from public,anon,authenticated,service_role;
drop trigger if exists serving_photo_partition_admission on public.serving_cost_reservations;
create trigger serving_photo_partition_admission before insert on public.serving_cost_reservations for each row execute function public.serving_photo_partition_guard();

-- An optional wire contract for a configured current package. No partition
-- means no replacement for existing nominal quotas. Saved-result recovery is
-- independent; this reader grants neither money nor media access.
create or replace function public.serving_photo_package_context(p_actor uuid,p_org uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare p public.serving_photo_partitions;f public.serving_funding;s public.serving_funding_slices;used integer;spent numeric;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent'))
  or(not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)and not public.org_has_verified_retail_guest(p_actor,p_org))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then return null;end if;
 if public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org)then return null;end if;
 if not exists(select 1 from public.serving_photo_partitions package join public.serving_funding funding on funding.id=package.funding_id
  where package.org_id=p_org and package.starts_at<=now()and package.ends_at>now()and funding.revoked_at is null)then return null;end if;
 if(select count(*)from public.serving_funding where org_id=p_org and revoked_at is null and starts_at<=now()and ends_at>now())<>1
 then raise exception 'RP409: The configured package funding interval is ambiguous';end if;
 -- Same selected receipt/slice predicates as serving_cost_reserve. The exact
 -- one-row guards make selection independent of physical order or query plan.
 select funding.* into f from public.serving_funding funding where org_id=p_org and revoked_at is null and starts_at<=now()and ends_at>now();
 if f.source<>'retail'and f.actor_id is distinct from p_actor then return null;end if;
 if(select count(*)from public.serving_funding_slices where funding_id=f.id and starts_at<=now()and ends_at>now())<>1
 then raise exception 'RP409: The configured package service slice is ambiguous';end if;
 select * into s from public.serving_funding_slices where funding_id=f.id and starts_at<=now()and ends_at>now();
 select * into p from public.serving_photo_partitions where funding_id=s.funding_id and slice_index=s.slice_index and org_id=p_org;
 if not found then return null;end if;
 if row(p.starts_at,p.ends_at)is distinct from row(s.starts_at,s.ends_at)then raise exception 'RP409: The configured package interval was changed';end if;
 select count(*)into used from public.serving_photo_admissions where funding_id=p.funding_id and slice_index=p.slice_index;
 select coalesce(sum(hold_cents),0)into spent from public.serving_cost_reservations
  where funding_id=p.funding_id and slice_index=p.slice_index and state<>'rejected'
   and stage!~'^photo\.(twilight|sky|lawn|declutter|stage|custom):[01]$';
 return jsonb_build_object('org_id',p.org_id,'policy',p.policy,'tariff_version',p.tariff_version,'starts_at',p.starts_at,'ends_at',p.ends_at,
  'photo_admissions',jsonb_build_object('cap',p.photo_cap,'used',used,'remaining',greatest(0,p.photo_cap-used)),
  'photo_hold_cents',p.photo_hold_cents,'protected_photo_cents',p.protected_photo_cents,
  'other_ai',jsonb_build_object('cap_cents',p.other_ai_cents,'used_cents',ceil(spent)::bigint,'remaining_cents',greatest(0,floor(p.other_ai_cents-spent))::bigint));
end$$;
revoke all on function public.serving_photo_package_context(uuid,uuid)from public,anon,authenticated;
grant execute on function public.serving_photo_package_context(uuid,uuid)to service_role;
commit;
