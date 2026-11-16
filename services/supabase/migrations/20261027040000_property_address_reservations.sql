-- A public bare address which has already been shared keeps its first listing
-- identity when another agent publishes the same normalized address. This
-- reservation never blocks another publication or grants it the bare alias.
-- New/unclaimed addresses are refused at this authority even before the dated
-- Worker flag is deployed, so no temporary bare link can be issued during the
-- database-to-Worker cutover. A deleted listing leaves a tombstone, so the URL
-- cannot silently change owner.
begin;

create table public.property_address_reservations (
  descriptor text primary key
    check (pg_catalog.length(descriptor) between 1 and 120
      and descriptor ~ '^[a-z0-9][a-z0-9-]{0,119}$'
      and descriptor !~ '-$'),
  listing_id uuid unique references public.listings(id) on delete set null,
  reserved_at timestamptz not null default now()
);
alter table public.property_address_reservations enable row level security;
revoke all on public.property_address_reservations from public, anon, authenticated;
grant select on public.property_address_reservations to service_role;

-- Pin every currently shareable bare address before changing the Worker to
-- dated links. Count *all* hosted publications at an address, including
-- noindex rows, before deciding that an indexable page was truly unique.
-- New publications will use dated identity links and cannot acquire a bare
-- alias merely by being the first listing at an address.
with live as (
  select l.id as listing_id, public.property_address_descriptor(l.address) as descriptor,
    ((l.details->>'allow_indexing')='true' or (l.details->>'allowIndexing')='true'
      or (l.details->>'search_indexing')='true') as indexable
  from public.listings l join public.orgs o on o.id=l.org_id
  where l.deleted_at is null and o.deleted_at is null
    and l.space_type='real_estate' and l.status<>'archived'
    and not exists(select 1 from public.deletion_requests d
      where d.user_id=l.agent_id and d.status in ('pending','processing'))
    and (public.hosting_retention_state(l.org_id)->>'hosting_available')::boolean
    and exists(select 1 from public.renders r
      where r.listing_id=l.id and r.published_at is not null
        and r.published_at<=now() and public.studio_presenter_render_access(r.id))
), unique_live as (
  select listing_id,descriptor,indexable,
    count(*) over(partition by descriptor) as address_count from live
)
insert into public.property_address_reservations(descriptor,listing_id)
select descriptor,listing_id from unique_live
  where address_count=1 and indexable and descriptor is not null
on conflict do nothing;

create or replace function public.public_property_address_lookup(p_descriptor text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare matches integer; current_slug text; alias_slug text;
        reserved_listing uuid; reservation_exists boolean:=false;
begin
  if current_setting('role',true)is distinct from 'service_role' then raise insufficient_privilege;end if;
  if p_descriptor is null or pg_catalog.length(p_descriptor)>120 or
     p_descriptor !~ '^[a-z0-9][a-z0-9-]{0,119}$' or p_descriptor ~ '-$' then
    raise exception 'RP400: Use one bounded property address descriptor';
  end if;
  if p_descriptor in ('demo','estate-demo') then return jsonb_build_object('status','ambiguous');end if;

  select c.listing_id into reserved_listing from public.property_address_reservations c
    where c.descriptor=p_descriptor;
  reservation_exists:=found;
  if reservation_exists and reserved_listing is null then return jsonb_build_object('status','ambiguous');end if;

  with hits as (
    select r.slug from public.listings l
      join public.orgs o on o.id=l.org_id
      join lateral (
        select published.id,published.slug from public.renders published
          where published.listing_id=l.id and published.published_at is not null
            and published.published_at<=now()
            and public.studio_presenter_render_access(published.id)
          order by published.published_at desc,published.id desc limit 1
      ) r on true
      where l.deleted_at is null and o.deleted_at is null
        and l.space_type='real_estate' and l.status<>'archived'
        -- Once reserved, the former address remains an alias even if that
        -- listing later corrects its text address or transfers to a new agent.
        and ((reservation_exists and l.id=reserved_listing) or
             (not reservation_exists and public.property_address_descriptor(l.address)=p_descriptor))
        and not exists(select 1 from public.deletion_requests d
          where d.user_id=l.agent_id and d.status in ('pending','processing'))
        and (public.hosting_retention_state(l.org_id)->>'hosting_available')::boolean
      limit 2
  )
  select count(*)::integer,max(slug) into matches,current_slug from hits;
  if matches=0 then
    return case when reservation_exists then jsonb_build_object('status','ambiguous') else null end;
  end if;
  if matches>1 then return jsonb_build_object('status','ambiguous');end if;
  if current_slug !~ '^[A-Za-z0-9_-]{1,64}$' then return jsonb_build_object('status','ambiguous');end if;
  select r.slug into alias_slug from public.renders r
    where r.slug=p_descriptor and r.published_at is not null
      and r.published_at<=now() and r.slug<>current_slug limit 1;
  if alias_slug is not null then return jsonb_build_object('status','ambiguous');end if;
  if reservation_exists then
    return jsonb_build_object('status','unique','slug',current_slug,'claimed',true);
  end if;
  -- The current Worker already treats "ambiguous" as no bare-address claim
  -- and keeps /property/<address>/<publication-id> available. Return it even
  -- for a single *new* publication: the later dated Worker deployment cannot
  -- revoke a bare URL that was never issued.
  return jsonb_build_object('status','ambiguous');
end$$;

revoke all on function public.public_property_address_lookup(text) from public,anon,authenticated;
grant execute on function public.public_property_address_lookup(text) to service_role;

commit;
