-- Deliberate hosted sharing belongs to one member. Existing workspace handles
-- never silently collect another member's properties.
create table if not exists public.member_portfolios (
 id uuid primary key default gen_random_uuid(),
 org_id uuid not null references public.orgs(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 listing_ids uuid[] not null default '{}',
 revision bigint not null default 1 check(revision>0),
 updated_at timestamptz not null default now(),
 unique(org_id,user_id),
 check(cardinality(listing_ids)<=100)
);
alter table public.member_portfolios enable row level security;
revoke all on public.member_portfolios from public,anon,authenticated;
grant select,insert,update,delete on public.member_portfolios to service_role;

create or replace function public.member_portfolio_receipt(p_actor uuid,p_org uuid,p_id uuid,p_revision bigint,p_ids uuid[])
returns jsonb language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object('user_id',p_actor,'org_id',p_org,'id',p_id,'revision',p_revision,'listing_ids',to_jsonb(p_ids));
$$;

create or replace function public.read_member_portfolio(p_actor uuid,p_org uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.member_portfolios;
begin
 perform public.upload_service_only();
 perform 1 from public.profiles where id=p_actor for share;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed')
  or not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor) then
  raise exception 'RP403: portfolio workspace is unavailable';end if;
 select * into p from public.member_portfolios where user_id=p_actor and org_id=p_org;
 return public.member_portfolio_receipt(p_actor,p_org,p.id,coalesce(p.revision,0),coalesce(p.listing_ids,'{}'));
end $$;

create or replace function public.save_member_portfolio(p_actor uuid,p_org uuid,p_expected bigint,p_ids uuid[])
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.member_portfolios; lid uuid;
begin
 perform public.upload_service_only();
 perform 1 from public.profiles where id=p_actor for update;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then raise exception 'RP403: account is unavailable';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: portfolio workspace is unavailable';end if;
 perform 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent') for share;
 if not found then raise exception 'RP403: this member cannot publish a portfolio';end if;
 if p_expected is null or p_expected<0 or p_ids is null or cardinality(p_ids)>100
  or exists(select 1 from unnest(p_ids)v where v is null) or cardinality(p_ids)<>(select count(distinct v)from unnest(p_ids)v) then
  raise exception 'RP400: choose up to 100 distinct listings';end if;
 foreach lid in array p_ids loop
  perform 1 from public.listings l where l.id=lid and l.org_id=p_org and l.agent_id=p_actor
   and l.deleted_at is null and l.sold_at is null and l.status<>'archived'
   and l.details->>'allow_indexing'='true'
   and not exists(select 1 from public.listing_client_contacts c where c.listing_id=l.id and c.org_id=p_org and c.enabled is true)
   and exists(select 1 from public.renders r where r.listing_id=l.id and r.published_at is not null) for share;
  if not found then raise exception 'RP409: a selected listing is unavailable for your public portfolio';end if;
 end loop;
 select * into p from public.member_portfolios where user_id=p_actor and org_id=p_org for update;
 if p.id is not null and p.listing_ids=p_ids then return public.member_portfolio_receipt(p_actor,p_org,p.id,p.revision,p.listing_ids);end if;
 if coalesce(p.revision,0)<>p_expected then raise exception 'RP409: your portfolio changed; reload before saving';end if;
 insert into public.member_portfolios(org_id,user_id,listing_ids)values(p_org,p_actor,p_ids)
 on conflict(org_id,user_id)do update set listing_ids=excluded.listing_ids,revision=member_portfolios.revision+1,updated_at=now()
 returning * into p;
 return public.member_portfolio_receipt(p_actor,p_org,p.id,p.revision,p.listing_ids);
end $$;
revoke all on function public.member_portfolio_receipt(uuid,uuid,uuid,bigint,uuid[]),public.read_member_portfolio(uuid,uuid),public.save_member_portfolio(uuid,uuid,bigint,uuid[]) from public,anon,authenticated;
grant execute on function public.member_portfolio_receipt(uuid,uuid,uuid,bigint,uuid[]),public.read_member_portfolio(uuid,uuid),public.save_member_portfolio(uuid,uuid,bigint,uuid[]) to service_role;
