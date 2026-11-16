-- The public property host may use an address as its one-segment canonical
-- path only when this current publication authority proves it unique. The
-- descriptor mirrors Tourhost's propertyAddressSlug, including its UTF-16
-- input bound and NFKD/combining-mark treatment. It is never a stored alias:
-- an address edit, withdrawal or hosting expiry immediately removes the hit.
create function public.property_address_descriptor(p_address text)
returns text language plpgsql immutable strict set search_path='' as $$
declare prefix text:=''; character text; units integer:=0; width integer; i integer; descriptor text;
begin
  for i in 1..least(pg_catalog.char_length(p_address),500) loop
    character:=pg_catalog.substr(p_address,i,1);
    width:=case when pg_catalog.ascii(character)>65535 then 2 else 1 end;
    if units+width>500 then exit;end if;
    units:=units+width;
    prefix:=prefix||character;
    if units=500 then exit;end if;
  end loop;
  descriptor:=pg_catalog.normalize(prefix,'NFKD');
  descriptor:=pg_catalog.regexp_replace(descriptor,U&'[\0300-\036f]','','g');
  descriptor:=pg_catalog.lower(descriptor collate "C");
  descriptor:=pg_catalog.regexp_replace(descriptor,'[^a-z0-9]+','-','g');
  descriptor:=pg_catalog.regexp_replace(descriptor,'^-+|-+$','','g');
  descriptor:=pg_catalog.left(descriptor,120);
  descriptor:=pg_catalog.regexp_replace(descriptor,'-+$','','g');
  return nullif(descriptor,'');
end$$;

-- Avoid scanning every listing for every public page request. The lookup still
-- verifies the live render, deletion, hosting and presenter fences below.
create index listings_public_address_descriptor_idx on public.listings
  (public.property_address_descriptor(address))
  where deleted_at is null and space_type='real_estate' and status<>'archived';

create function public.public_property_address_lookup(p_descriptor text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare matches integer; current_slug text; alias_slug text;
begin
  if current_setting('role',true)is distinct from 'service_role' then raise insufficient_privilege;end if;
  if p_descriptor is null or pg_catalog.length(p_descriptor)>120 or
     p_descriptor !~ '^[a-z0-9][a-z0-9-]{0,119}$' or p_descriptor ~ '-$' then
    raise exception 'RP400: Use one bounded property address descriptor';
  end if;
  -- The sample pages are served by the host without database renders.
  if p_descriptor in ('demo','estate-demo') then return jsonb_build_object('status','ambiguous');end if;

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
        and public.property_address_descriptor(l.address)=p_descriptor
        and not exists(select 1 from public.deletion_requests d
          where d.user_id=l.agent_id and d.status in ('pending','processing'))
        and (public.hosting_retention_state(l.org_id)->>'hosting_available')::boolean
      limit 2
  )
  select count(*)::integer,max(slug) into matches,current_slug from hits;
  if matches=0 then return null;end if;
  if matches>1 then return jsonb_build_object('status','ambiguous');end if;
  -- The host accepts only this legacy slug alphabet and bound. Returning an
  -- unusable identity would silently alias an unrelated one-segment path.
  if current_slug !~ '^[A-Za-z0-9_-]{1,64}$' then return jsonb_build_object('status','ambiguous');end if;

  -- /property/:slug still names an existing public render. A previously
  -- published slug may belong even to this same listing, so never reuse its
  -- one-segment path for another current publication. Conservative refusal for
  -- a stale but still published slug is safe; the host also checks the alias.
  select r.slug into alias_slug from public.renders r
    where r.slug=p_descriptor and r.published_at is not null
      and r.published_at<=now() and r.slug<>current_slug limit 1;
  if alias_slug is not null then return jsonb_build_object('status','ambiguous');end if;
  return jsonb_build_object('status','unique','slug',current_slug);
end$$;

revoke all on function public.property_address_descriptor(text),
  public.public_property_address_lookup(text) from public,anon,authenticated;
grant execute on function public.property_address_descriptor(text),
  public.public_property_address_lookup(text) to service_role;
