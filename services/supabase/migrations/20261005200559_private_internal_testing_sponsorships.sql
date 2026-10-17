begin;
-- Explicit internal-test sponsorship only. No real people/orgs are seeded;
-- stored plans, Apple bindings, branding, listings and retail pricing stay put.
-- Acquire host locks BEFORE altering the invite table, matching seat writers.
do $$declare r record;begin
 for r in select distinct org_id from public.org_internal_testing_grants order by org_id loop
  perform 1 from public.orgs where id=r.org_id for update;
 end loop;
end$$;

create table if not exists public.private_internal_testing_hosts(
 org_id uuid primary key references public.orgs(id) on delete cascade,
 configured_at timestamptz not null default now()
);
alter table public.private_internal_testing_hosts enable row level security;
revoke all on public.private_internal_testing_hosts from public,anon,authenticated;
grant select,insert,update,delete on public.private_internal_testing_hosts to service_role;
insert into public.private_internal_testing_hosts(org_id)
 select distinct org_id from public.org_internal_testing_grants on conflict do nothing;

create table if not exists public.private_internal_testing_sponsorships(
 id uuid primary key default gen_random_uuid(),
 sponsor_org_id uuid not null references public.orgs(id) on delete cascade,
 sponsor_owner_user_id uuid not null references public.profiles(id) on delete cascade,
 beneficiary_user_id uuid not null references public.profiles(id) on delete cascade,
 private_org_id uuid not null references public.orgs(id) on delete cascade,
 starts_at timestamptz not null default now(),
 expires_at timestamptz,
 revoked_at timestamptz,
 created_at timestamptz not null default now(),
 check(sponsor_org_id<>private_org_id and sponsor_owner_user_id<>beneficiary_user_id),
 check(expires_at is null or expires_at>starts_at)
);
create unique index if not exists private_internal_testing_one_beneficiary
 on public.private_internal_testing_sponsorships(beneficiary_user_id)where revoked_at is null;
create unique index if not exists private_internal_testing_one_private_org
 on public.private_internal_testing_sponsorships(private_org_id)where revoked_at is null;
create index if not exists private_internal_testing_host_roster
 on public.private_internal_testing_sponsorships(sponsor_org_id)where revoked_at is null;
alter table public.private_internal_testing_sponsorships enable row level security;
revoke all on public.private_internal_testing_sponsorships from public,anon,authenticated;
grant select,insert,update,delete on public.private_internal_testing_sponsorships to service_role;

alter table public.org_invites add column if not exists private_testing boolean not null default false;
alter table public.org_invites add column if not exists accepted_private_org_id uuid references public.orgs(id) on delete set null;
alter table public.org_invites add column if not exists private_testing_receipt jsonb;

-- Trusted state predicate, independent of the member-facing master helper:
-- beneficiaries intentionally have no host content membership. Service-only;
-- nested definer callers use the pinned/qualified server predicate.
create or replace function public.private_internal_testing_master_owner(p_org uuid)
returns uuid language sql stable security definer set search_path='' as $$
 select g.owner_user_id from public.org_internal_testing_grants g
 join public.orgs o on o.id=g.org_id and o.deleted_at is null and o.plan='team'and o.plan_source='manual'
 join public.profiles p on p.id=g.owner_user_id and p.is_admin is true
 join auth.users u on u.id=g.owner_user_id and u.is_anonymous is false
 join public.memberships m on m.org_id=g.org_id and m.user_id=g.owner_user_id and m.role='owner'
 where g.org_id=p_org and g.unmetered_business_allowances is true
  and g.starts_at<=now()and(g.expires_at is null or g.expires_at>now())and g.revoked_at is null
  and not exists(select 1 from public.brokerage_contracts c where c.org_id=p_org and c.status='active'
   and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))
  and not exists(select 1 from public.deletion_requests d where d.user_id=g.owner_user_id and d.status in('pending','processing'))
  and not exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and s.revoked_at is null)
 order by g.created_at,g.owner_user_id limit 1;
$$;

create or replace function public.org_has_private_internal_testing(p_org uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if not(current_setting('role',true)='service_role'
  or(session_user=current_user and current_setting('role',true)='none'and auth.uid()is null)
  or exists(select 1 from public.private_internal_testing_sponsorships s
   where s.private_org_id=p_org and s.beneficiary_user_id=auth.uid()))then return false;end if;
 return exists(select 1 from public.private_internal_testing_sponsorships s
  join public.orgs o on o.id=s.private_org_id and o.deleted_at is null
  join public.profiles p on p.id=s.beneficiary_user_id
  join auth.users u on u.id=s.beneficiary_user_id and u.is_anonymous is false
  join public.memberships m on m.org_id=s.private_org_id and m.user_id=s.beneficiary_user_id and m.role='owner'
  where s.private_org_id=p_org and s.revoked_at is null and s.starts_at<=now()
   and(s.expires_at is null or s.expires_at>now())
   and public.private_internal_testing_master_owner(s.sponsor_org_id)=s.sponsor_owner_user_id
   and not exists(select 1 from public.memberships x where x.org_id=s.sponsor_org_id and x.user_id=s.beneficiary_user_id)
   and not exists(select 1 from public.memberships x where x.org_id=s.private_org_id and x.user_id<>s.beneficiary_user_id)
   and not exists(select 1 from public.org_invites i where i.org_id=s.private_org_id and i.accepted_at is null and i.revoked_at is null and i.expires_at>now())
   and not exists(select 1 from public.brokerage_contracts c where c.org_id=s.private_org_id and c.status='active'and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))
   and not exists(select 1 from public.deletion_requests d where d.user_id=s.beneficiary_user_id and d.status in('pending','processing')));
end$$;

create or replace function public.private_internal_testing_context(p_user uuid,p_private_org uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_private_org
  and s.beneficiary_user_id=p_user and s.revoked_at is null)or not public.org_has_private_internal_testing(p_private_org)then return null;end if;
 return(select jsonb_build_object('active',true,'sponsor_org_id',s.sponsor_org_id,'sponsor_org_name',o.name,
  'private_org_id',s.private_org_id,'beneficiary_user_id',s.beneficiary_user_id,'plan','team','source','manual',
  'unmetered_business_allowances',true,'access_mode','private_testing')
  from public.private_internal_testing_sponsorships s join public.orgs o on o.id=s.sponsor_org_id
  where s.private_org_id=p_private_org and s.beneficiary_user_id=p_user and s.revoked_at is null);
end$$;

create or replace function public.private_internal_testing_host_mode(p_actor uuid,p_org uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.memberships m join auth.users u on u.id=m.user_id and u.is_anonymous is false
  join public.orgs o on o.id=m.org_id and o.deleted_at is null
  where m.org_id=p_org and m.user_id=p_actor and m.role in('owner','admin'))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then
  raise exception 'RP403: Only a current named manager may inspect testing host mode';end if;
 if not exists(select 1 from public.private_internal_testing_hosts where org_id=p_org)then return null;end if;
 return jsonb_build_object('configured',true,'active',public.private_internal_testing_master_owner(p_org)is not null,'access_mode','private_testing');
end$$;

create or replace function public.private_internal_testing_members(p_actor uuid,p_sponsor_org uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform public.private_internal_testing_host_mode(p_actor,p_sponsor_org);
 return(select coalesce(jsonb_agg(jsonb_build_object('user_id',s.beneficiary_user_id,'role','agent','name',p.name,'email',p.email,
  'private_testing',true,'access_mode','private_testing','benefits_active',public.org_has_private_internal_testing(s.private_org_id),
  'joined_at',s.created_at)order by s.created_at,s.beneficiary_user_id),'[]'::jsonb)
  from public.private_internal_testing_sponsorships s join public.profiles p on p.id=s.beneficiary_user_id
  where s.sponsor_org_id=p_sponsor_org and s.revoked_at is null
   and not exists(select 1 from public.memberships m where m.org_id=s.sponsor_org_id and m.user_id=s.beneficiary_user_id));
end$$;

-- Immutable bindings; every sponsorship write takes the same ordered org locks
-- as private enrollment/removal and the beneficiary's cost-admission writer.
create or replace function public.lock_private_internal_testing_orgs()
returns trigger language plpgsql security definer set search_path='' as $$
declare ids uuid[];begin
 if tg_op='UPDATE'and(new.sponsor_org_id is distinct from old.sponsor_org_id or new.sponsor_owner_user_id is distinct from old.sponsor_owner_user_id
  or new.beneficiary_user_id is distinct from old.beneficiary_user_id or new.private_org_id is distinct from old.private_org_id)then
  raise exception 'RP400: Private testing allocation identity is immutable';end if;
 ids:=case when tg_op='DELETE'then array[old.sponsor_org_id,old.private_org_id]else array[new.sponsor_org_id,new.private_org_id]end;
 perform 1 from public.orgs where id=any(ids)order by id for update;
 if tg_op='DELETE'then return old;end if;return new;
end$$;
drop trigger if exists private_internal_testing_org_locks on public.private_internal_testing_sponsorships;
create trigger private_internal_testing_org_locks before insert or update or delete on public.private_internal_testing_sponsorships
 for each row execute function public.lock_private_internal_testing_orgs();

create or replace function public.register_private_internal_testing_host()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.private_internal_testing_hosts(org_id)values(new.org_id)on conflict do nothing;return new;
end$$;
drop trigger if exists internal_testing_private_host on public.org_internal_testing_grants;
create trigger internal_testing_private_host after insert or update on public.org_internal_testing_grants
 for each row execute function public.register_private_internal_testing_host();

create or replace function public.stamp_private_internal_testing_invite()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE'and old.private_testing and not new.private_testing then
  raise exception 'RP400: Private testing invite mode is immutable';end if;
 if tg_op='UPDATE'and old.private_testing and old.accepted_at is not null
  and((new.accepted_private_org_id is distinct from old.accepted_private_org_id
    and not(new.accepted_private_org_id is null and not exists(select 1 from public.orgs where id=old.accepted_private_org_id)))
   or new.private_testing_receipt is distinct from old.private_testing_receipt
   or(new.accepted_by is distinct from old.accepted_by
    and not(new.accepted_by is null and not exists(select 1 from public.profiles where id=old.accepted_by)))
   or new.accepted_at is distinct from old.accepted_at
   or new.org_id is distinct from old.org_id or new.token_hash is distinct from old.token_hash
   or new.role is distinct from old.role
   or(new.invited_by is distinct from old.invited_by
    and not(new.invited_by is null and not exists(select 1 from public.profiles where id=old.invited_by))))then
  raise exception 'RP400: Accepted private testing receipt is immutable';end if;
 if tg_op='INSERT'and exists(select 1 from public.private_internal_testing_hosts where org_id=new.org_id)then
  if new.role<>'agent'then raise exception 'RP400: Private testing invitations must use the agent role';end if;
  if public.private_internal_testing_master_owner(new.org_id)is null then
   raise exception 'RP402: Private testing sponsorship is not active';end if;
  new.private_testing:=true;
 end if;
 return new;
end$$;
drop trigger if exists internal_testing_private_invite on public.org_invites;
create trigger internal_testing_private_invite before insert or update on public.org_invites
 for each row execute function public.stamp_private_internal_testing_invite();
-- Only unaccepted active-master invitations are captured during rollout.
-- Accepted legacy receipts/codes never gain a private binding retroactively.
update public.org_invites i set private_testing=true
 where i.accepted_at is null and i.revoked_at is null
  and public.private_internal_testing_master_owner(i.org_id)is not null;

create or replace function public.enroll_private_internal_tester(
 p_actor uuid,p_sponsor_org uuid,p_beneficiary uuid,p_private_org uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid;private_id uuid;r public.private_internal_testing_sponsorships;result jsonb;
begin
 owner_id:=public.private_internal_testing_master_owner(p_sponsor_org);
 if owner_id is null then raise exception 'RP403: Internal testing sponsorship is not active';end if;
 if p_beneficiary is null or p_beneficiary=owner_id then raise exception 'RP400: A separate named tester is required';end if;
 perform 1 from public.profiles where id=any(array[p_actor,owner_id,p_beneficiary])order by id for update;
 if not exists(select 1 from auth.users u join public.profiles p on p.id=u.id where u.id=p_beneficiary and u.is_anonymous is false)
  or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)then
  raise exception 'RP403: Testing seats require current named accounts';end if;
 if exists(select 1 from public.deletion_requests where user_id=any(array[p_actor,owner_id,p_beneficiary])and status in('pending','processing'))then
  raise exception 'RP409: An account is being deleted';end if;

 private_id:=p_private_org;
 if private_id is null then
  select o.id into private_id from public.orgs o join public.memberships m on m.org_id=o.id and m.user_id=p_beneficiary and m.role='owner'
   where o.deleted_at is null and o.id<>p_sponsor_org
    and not exists(select 1 from public.memberships x where x.org_id=o.id and x.user_id<>p_beneficiary)
    and not exists(select 1 from public.org_invites i where i.org_id=o.id and i.accepted_at is null and i.revoked_at is null and i.expires_at>now())
    and not exists(select 1 from public.brokerage_contracts c where c.org_id=o.id and c.status='active'and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))
   order by exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=o.id and s.beneficiary_user_id=p_beneficiary and s.revoked_at is null)desc,
    exists(select 1 from public.listings l where l.org_id=o.id and l.deleted_at is null)desc,
    exists(select 1 from public.user_workspace_state w where w.user_id=p_beneficiary and w.active_org_id=o.id)desc,
    o.created_at,m.id limit 1;
 end if;
 if private_id is null or private_id=p_sponsor_org then raise exception 'RP409: No existing private owned workspace is eligible';end if;
 perform 1 from public.orgs where id=any(array[p_sponsor_org,private_id])order by id for update;
 if public.private_internal_testing_master_owner(p_sponsor_org)is distinct from owner_id then
  raise exception 'RP403: Internal testing sponsorship is not active';end if;
 if not exists(select 1 from public.memberships where org_id=p_sponsor_org and user_id=p_actor and role in('owner','admin'))then
  raise exception 'RP403: Only a current sponsor manager may allocate a testing seat';end if;
 if not exists(select 1 from public.orgs o join public.memberships m on m.org_id=o.id and m.user_id=p_beneficiary and m.role='owner'
  where o.id=private_id and o.deleted_at is null)
  or exists(select 1 from public.memberships where org_id=private_id and user_id<>p_beneficiary)
  or exists(select 1 from public.org_invites where org_id=private_id and accepted_at is null and revoked_at is null and expires_at>now())
  or exists(select 1 from public.brokerage_contracts c where c.org_id=private_id and c.status='active'and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))then
  raise exception 'RP409: Testing workspace must remain private and solely owned by the named tester';end if;
 if exists(select 1 from public.memberships where org_id=p_sponsor_org and user_id=p_beneficiary and role='owner')then
  raise exception 'RP403: A sponsor owner cannot become a private tester';end if;
 if p_actor<>owner_id and exists(select 1 from public.memberships where org_id=p_sponsor_org and user_id=p_beneficiary and role='admin')then
  raise exception 'RP403: Only the sponsor owner may convert an admin membership';end if;
 select * into r from public.private_internal_testing_sponsorships where beneficiary_user_id=p_beneficiary and revoked_at is null for update;
 if found and(r.sponsor_org_id<>p_sponsor_org or r.private_org_id<>private_id)then
  raise exception 'RP409: An existing testing allocation must be explicitly removed first';end if;
 if r.id is not null and(r.expires_at<=now())then
  update public.private_internal_testing_sponsorships set revoked_at=now()where id=r.id;r.id:=null;
 end if;
 if r.id is null then
  insert into public.private_internal_testing_sponsorships(sponsor_org_id,sponsor_owner_user_id,beneficiary_user_id,private_org_id)
   values(p_sponsor_org,owner_id,p_beneficiary,private_id)returning * into r;
 end if;
 -- Convert only content membership. No org, listing, card, asset or plan moves.
 perform set_config('rendprop.seat_actor',p_actor::text,true);
 delete from public.memberships where org_id=p_sponsor_org and user_id=p_beneficiary;
 perform set_config('rendprop.seat_actor','',true);
 insert into public.user_workspace_state(user_id,active_org_id)values(p_beneficiary,private_id)
  on conflict(user_id)do update set active_org_id=excluded.active_org_id,updated_at=now();
 if not public.org_has_private_internal_testing(private_id)then raise exception 'RP409: Private testing authority could not be verified';end if;
 select jsonb_build_object('ok',true,'org_id',private_id,'private_org_id',private_id,'org_name',o.name,'role','owner',
  'sponsor_org_id',p_sponsor_org,'team_name',s.name,'private_testing',true,'access_mode','private_testing')into result
  from public.orgs o,public.orgs s where o.id=private_id and s.id=p_sponsor_org;
 return result;
end$$;

create or replace function public.accept_private_internal_test_invite(p_user uuid,p_token_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.org_invites;owner_id uuid;result jsonb;private_id uuid;
begin
 select * into i from public.org_invites where token_hash=p_token_hash;
 if not found then return null;end if;
 -- An accepted legacy shared code remains subject to the original membership
 -- replay fence. Never retroactively turn that code into a sponsored receipt.
 if i.accepted_at is not null and not i.private_testing then return null;end if;
 if not i.private_testing and not exists(select 1 from public.private_internal_testing_hosts where org_id=i.org_id)then return null;end if;
 owner_id:=public.private_internal_testing_master_owner(i.org_id);
 if owner_id is null then raise exception 'RP403: Internal testing sponsorship is not active';end if;
 if i.role<>'agent'then raise exception 'RP400: Private testing invitations must use the agent role';end if;
 perform 1 from public.profiles where id=any(array[p_user,owner_id,i.invited_by])order by id for update;
 if not exists(select 1 from auth.users u join public.profiles p on p.id=u.id where u.id=p_user and u.is_anonymous is false)then
  raise exception 'RP403: Testing seats require a current named account';end if;
 if exists(select 1 from public.deletion_requests where user_id=any(array[p_user,owner_id,i.invited_by])and status in('pending','processing'))then
  raise exception 'RP409: An account is being deleted';end if;
 if i.accepted_at is not null then
  private_id:=i.accepted_private_org_id;
  perform 1 from public.orgs where id=any(array[i.org_id,private_id])order by id for update;
  select * into i from public.org_invites where id=i.id for update;
  if i.accepted_by is distinct from p_user or private_id is null or i.private_testing_receipt is null
   or not exists(select 1 from public.private_internal_testing_sponsorships s where s.sponsor_org_id=i.org_id and s.private_org_id=private_id
    and s.beneficiary_user_id=p_user and s.revoked_at is null)or not public.org_has_private_internal_testing(private_id)then
   raise exception 'RP404: That private testing invitation is no longer valid';end if;
  return i.private_testing_receipt;
 end if;
 if i.revoked_at is not null or i.expires_at<=now()then raise exception 'RP404: That invitation is no longer valid';end if;
 result:=public.enroll_private_internal_tester(i.invited_by,i.org_id,p_user,null);
 select * into i from public.org_invites where id=i.id for update;
 if i.accepted_at is not null or i.revoked_at is not null or i.expires_at<=now()then
  raise exception 'RP404: That invitation is no longer valid';end if;
 update public.org_invites set private_testing=true,accepted_at=now(),accepted_by=p_user,
  accepted_private_org_id=(result->>'private_org_id')::uuid,private_testing_receipt=result where id=i.id;
 return result;
end$$;

create or replace function public.remove_private_internal_tester(p_actor uuid,p_sponsor_org uuid,p_beneficiary uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.private_internal_testing_sponsorships;
begin
 if p_actor=p_beneficiary then raise exception 'RP400: A manager cannot remove their own testing allocation';end if;
 select * into r from public.private_internal_testing_sponsorships where sponsor_org_id=p_sponsor_org and beneficiary_user_id=p_beneficiary and revoked_at is null;
 if not found then raise exception 'RP404: That private testing seat is not active';end if;
 perform 1 from public.profiles where id=any(array[p_actor,p_beneficiary,r.sponsor_owner_user_id])order by id for update;
 perform 1 from public.orgs where id=any(array[p_sponsor_org,r.private_org_id])order by id for update;
 perform public.private_internal_testing_host_mode(p_actor,p_sponsor_org);
 if exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then
  raise exception 'RP409: This account is being deleted';end if;
 update public.private_internal_testing_sponsorships set revoked_at=now()where id=r.id and revoked_at is null;
 return jsonb_build_object('ok',true,'removed',true,'private_testing',true,'org_id',p_sponsor_org,'user_id',p_beneficiary,
  'seats',jsonb_build_object('used',public.org_seats_used(p_sponsor_org),'allowed',public.org_seats_allowed(p_sponsor_org)));
end$$;

-- New mutation/metadata RPCs are service-only. The sole member-facing boolean
-- has its own current beneficiary/caller fence and reveals no private record.
revoke all on function public.org_has_private_internal_testing(uuid)from public,anon,authenticated;
grant execute on function public.org_has_private_internal_testing(uuid)to authenticated,service_role;
revoke all on function public.private_internal_testing_master_owner(uuid),
 public.private_internal_testing_context(uuid,uuid),public.private_internal_testing_host_mode(uuid,uuid),
 public.private_internal_testing_members(uuid,uuid),public.enroll_private_internal_tester(uuid,uuid,uuid,uuid),
 public.accept_private_internal_test_invite(uuid,text),public.remove_private_internal_tester(uuid,uuid,uuid)
 from public,anon,authenticated;
grant execute on function public.private_internal_testing_master_owner(uuid),
 public.private_internal_testing_context(uuid,uuid),public.private_internal_testing_host_mode(uuid,uuid),
 public.private_internal_testing_members(uuid,uuid),public.enroll_private_internal_tester(uuid,uuid,uuid,uuid),
 public.accept_private_internal_test_invite(uuid,text),public.remove_private_internal_tester(uuid,uuid,uuid)to service_role;
revoke all on function public.lock_private_internal_testing_orgs(),public.register_private_internal_testing_host(),
 public.stamp_private_internal_testing_invite()from public,anon,authenticated,service_role;

-- Preserve exact deployed bodies, ACLs and function attributes. Unknown SQL
-- aborts the whole migration; replay accepts only these reviewed insertions.
do $patch$
declare definition text;body text;anchor text;insertion text;master text;extra text;
begin
 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc
  where oid='public.org_has_internal_testing_grant(uuid)'::regprocedure;
 anchor:=E'begin\n';
 insertion:=E'  if exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and s.revoked_at is null) then return false; end if;\n';
 if md5(replace(body,insertion,''))<>'3c8aee548951b93d4a2e0630cd375aa6' then
  raise exception 'org_has_internal_testing_grant definition changed; review private sponsorship';end if;
 if position(insertion in body)=0 then execute replace(definition,anchor,anchor||insertion);end if;

 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc where oid='public.org_entitlement(uuid)'::regprocedure;
 anchor:=E'  v_base := plan_entitlement(effective_plan(p_org));\n';
 master:=E'  if public.org_has_internal_testing_grant(p_org) then\n    v_base.seats := 2147483647;\n    v_base.renders_per_month := 2147483647;\n    v_base.photo_edits_per_month := 2147483647;\n    v_base.reels_per_month := 2147483647;\n    v_base.aerials_per_month := 2147483647;\n    v_base.topaz_per_month := 2147483647;\n    v_base.cogs_ceiling_cents := 2147483647;\n    return v_base;\n  end if;\n';
 insertion:=E'  if public.org_has_private_internal_testing(p_org) then\n    v_base.plan := ''team'';\n    v_base.seats := 1;\n    v_base.renders_per_month := 2147483647;\n    v_base.photo_edits_per_month := 2147483647;\n    v_base.reels_per_month := 2147483647;\n    v_base.aerials_per_month := 2147483647;\n    v_base.topaz_per_month := 2147483647;\n    v_base.cogs_ceiling_cents := 2147483647;\n    return v_base;\n  end if;\n';
 if md5(replace(replace(body,insertion,''),master,''))<>'555f204626eb76a2e594394d23553c19'
  or(length(body)-length(replace(body,master,'')))/length(master)<>1 then
  raise exception 'org_entitlement definition changed; review private sponsorship';end if;
 if position(insertion in body)=0 then execute replace(definition,anchor,anchor||insertion);end if;

 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc where oid='public.org_seats_allowed(uuid)'::regprocedure;
 anchor:=E'  select coalesce(\n';
 master:=E'    (select 2147483647 where public.org_has_internal_testing_grant(p_org)),\n';
 insertion:=E'    (select 1 where public.org_has_private_internal_testing(p_org)),\n';
 if md5(replace(replace(body,insertion,''),master,''))<>'627538faa6d77f97a228a1bca7299fa3'
  or(length(body)-length(replace(body,master,'')))/length(master)<>1 then
  raise exception 'org_seats_allowed definition changed; review private sponsorship';end if;
 if position(insertion in body)=0 then execute replace(definition,anchor,anchor||insertion);end if;

 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc where oid='public.org_seats_used(uuid)'::regprocedure;
 anchor:=E'              and i.expires_at > now()))::integer;';
 insertion:=E'\n        + (select count(*) from public.private_internal_testing_sponsorships s\n            where s.sponsor_org_id=p_org and s.revoked_at is null and s.starts_at<=now()\n              and(s.expires_at is null or s.expires_at>now())\n              and not exists(select 1 from public.memberships m where m.org_id=p_org and m.user_id=s.beneficiary_user_id))';
 extra:=E'              and i.expires_at > now())'||insertion||E')::integer;';
 if md5(replace(body,extra,anchor))<>'2405f0ad7c8571fc3fa1c22d06e73f75' then
  raise exception 'org_seats_used definition changed; review private sponsorship';end if;
 if position(insertion in body)=0 then execute replace(definition,anchor,extra);end if;

 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc where oid='public.accept_org_invite(uuid,text)'::regprocedure;
 insertion:=E'  v_private_result jsonb;\n';
 extra:=E'  v_private_result := public.accept_private_internal_test_invite(p_user,p_token_hash);\n  if v_private_result is not null then return v_private_result; end if;\n';
 if md5(replace(replace(body,insertion,''),extra,''))<>'55f13d625c8593f018e1df48c4ec4fad' then
  raise exception 'accept_org_invite definition changed; review private sponsorship';end if;
 if position(insertion in body)=0 then
  definition:=replace(definition,E'declare\n',E'declare\n'||insertion);
  execute replace(definition,E'begin\n',E'begin\n'||extra);
 end if;
end $patch$;

comment on table public.private_internal_testing_hosts is
 'Sticky private invitation mode for configured internal-test hosts, retained after grant revocation/deletion. No customer org is seeded.';
comment on table public.private_internal_testing_sponsorships is
 'Service-only revocable allowance projection to a named beneficiary sole-owned private org. No host content membership, plan/source mutation, retail sponsorship or chaining.';
commit;
