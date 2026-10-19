-- Ordinary phone edits carry explicit intent and expected values. Unrelated
-- Studio facts, state, nested details and plan attachments remain unchanged.
-- Older full-row clients must upgrade; direct authenticated writes cannot
-- circumvent that boundary through PostgREST.
revoke update (space_type,address,tagline,details,beds,baths,sqft,price_cents,zillow_url,lat,lng,sold_at,status)
 on public.listings from authenticated,anon;

create or replace function public.save_listing_facts(
 p_actor uuid,p_org uuid,p_listing uuid,p_expected jsonb,p_changes jsonb,
 p_details_expected jsonb,p_details_changes jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 l public.listings; old_row jsonb; d jsonb; k text; desired jsonb; expected jsonb; actual jsonb;
 field_keys text[]:=array['space_type','address','tagline','beds','baths','sqft','price_cents','zillow_url','lat','lng','sold_at','status'];
 detail_keys text[]:=array['allow_indexing','capacitySeated','capacityStanding','startingPrice','eventTypes','catering','spaceSetting','amenities','bookingUrl','cuisineType','priceRange','hours','reservationUrl','menuUrl','phone','storeCategory','onlineStoreUrl','weeklySpecial','shoppingOptions','departments','facilityType','membershipPrice','dayPassPrice','is247','freeTrialOffer','website'];
 current_matches boolean; desired_matches boolean;
begin
 perform public.upload_service_only();
 if p_actor is null or p_org is null or p_listing is null then
  raise exception 'Choose an account, workspace and listing' using errcode='22023'; end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 select * into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if l.id is null then raise exception 'Listing not found' using errcode='P0002'; end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent'))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'Workspace is not writable' using errcode='42501'; end if;
 if pg_catalog.jsonb_typeof(p_expected) is distinct from 'object'
  or pg_catalog.jsonb_typeof(p_changes) is distinct from 'object'
  or pg_catalog.jsonb_typeof(p_details_expected) is distinct from 'object'
  or pg_catalog.jsonb_typeof(p_details_changes) is distinct from 'object'
  or (p_changes='{}'::jsonb and p_details_changes='{}'::jsonb)
  or pg_catalog.octet_length(p_expected::text||p_changes::text||p_details_expected::text||p_details_changes::text)>45000 then
  raise exception 'Invalid explicit listing edit' using errcode='22023'; end if;
 if (select array_agg(key order by key) from pg_catalog.jsonb_each(p_expected)) is distinct from
    (select array_agg(key order by key) from pg_catalog.jsonb_each(p_changes))
  or (select array_agg(key order by key) from pg_catalog.jsonb_each(p_details_expected)) is distinct from
    (select array_agg(key order by key) from pg_catalog.jsonb_each(p_details_changes)) then
  raise exception 'Every edit needs its cached value' using errcode='22023'; end if;
 if (p_changes ? 'lat') is distinct from (p_changes ? 'lng')
  or ((p_changes ? 'lat') and ((p_changes->'lat'='null'::jsonb) is distinct from (p_changes->'lng'='null'::jsonb))) then
  raise exception 'Save both coordinates together' using errcode='22023'; end if;
 old_row:=pg_catalog.to_jsonb(l); d:=coalesce(l.details,'{}');
 for k,desired in select key,value from pg_catalog.jsonb_each(p_changes) loop
  if not k=any(field_keys) then raise exception 'Unsupported listing field' using errcode='22023'; end if;
  expected:=p_expected->k; actual:=coalesce(old_row->k,'null'::jsonb);
  if desired<>'null'::jsonb then
   if k in('beds','baths','sqft','price_cents','lat','lng') then
    if pg_catalog.jsonb_typeof(desired)<>'number' then raise exception 'Invalid number' using errcode='22023'; end if;
    if k in('beds','sqft','price_cents') and ((desired#>>'{}')::numeric<0 or trunc((desired#>>'{}')::numeric)<>(desired#>>'{}')::numeric) then
     raise exception 'Invalid non-negative integer' using errcode='22023'; end if;
    if k='baths' and ((desired#>>'{}')::numeric<0 or (desired#>>'{}')::numeric>99
     or round((desired#>>'{}')::numeric,1)<>(desired#>>'{}')::numeric) then
     raise exception 'Bathrooms must use tenths' using errcode='22023'; end if;
    if k in('lat','lng') and (abs((desired#>>'{}')::numeric)>case when k='lat' then 90 else 180 end
     or round((desired#>>'{}')::numeric,3)<>(desired#>>'{}')::numeric) then
     raise exception 'Invalid coarse coordinate' using errcode='22023'; end if;
   elsif pg_catalog.jsonb_typeof(desired)<>'string' or length(desired#>>'{}')>500 then
    raise exception 'Invalid listing text' using errcode='22023'; end if;
  end if;
  if k='space_type' and (desired='null'::jsonb or desired#>>'{}' not in('real_estate','venue','restaurant','retail','fitness','other')) then
   raise exception 'Invalid business type' using errcode='22023'; end if;
  if k='status' and (desired='null'::jsonb or desired#>>'{}' not in('draft','capturing','uploading','processing','ready','expired','archived')) then
   raise exception 'Invalid listing status' using errcode='22023'; end if;
  if k='sold_at' then
   current_matches:= (actual#>>'{}')::timestamptz is not distinct from (expected#>>'{}')::timestamptz;
   desired_matches:= (actual#>>'{}')::timestamptz is not distinct from (desired#>>'{}')::timestamptz;
  else current_matches:=actual=expected; desired_matches:=actual=desired; end if;
  if not current_matches and not desired_matches then
   raise exception 'Listing details changed elsewhere' using errcode='40001'; end if;
 end loop;
 for k,desired in select key,value from pg_catalog.jsonb_each(p_details_changes) loop
  if not k=any(detail_keys) or (desired<>'null'::jsonb and pg_catalog.jsonb_typeof(desired)<>'string') then
   raise exception 'Unsupported detail edit' using errcode='22023'; end if;
  expected:=p_details_expected->k; actual:=d->k;
  if pg_catalog.jsonb_typeof(expected) is distinct from 'object'
   or pg_catalog.jsonb_typeof(expected->'present') is distinct from 'boolean'
   or not(expected ? 'value') or (select count(*) from pg_catalog.jsonb_object_keys(expected))<>2 then
   raise exception 'Every detail edit needs its cached presence and value' using errcode='22023'; end if;
  current_matches:=case when expected->'present'='false'::jsonb then not(d ? k) else (d ? k) and actual=expected->'value' end;
  desired_matches:=case when desired='null'::jsonb then not(d ? k) else actual=desired end;
  if not coalesce(current_matches,false) and not coalesce(desired_matches,false) then
   raise exception 'Listing details changed elsewhere' using errcode='40001'; end if;
  if desired='null'::jsonb then d:=d-k; else d:=d||pg_catalog.jsonb_build_object(k,desired); end if;
 end loop;
 if pg_catalog.octet_length(d::text)>16000 then raise exception 'Listing details too large' using errcode='22023'; end if;
 update public.listings set
  space_type=case when p_changes ? 'space_type' then p_changes->>'space_type' else l.space_type end,
  address=case when p_changes ? 'address' then p_changes->>'address' else l.address end,
  tagline=case when p_changes ? 'tagline' then p_changes->>'tagline' else l.tagline end,
  beds=case when p_changes ? 'beds' then (p_changes->>'beds')::smallint else l.beds end,
  baths=case when p_changes ? 'baths' then (p_changes->>'baths')::numeric else l.baths end,
  sqft=case when p_changes ? 'sqft' then (p_changes->>'sqft')::integer else l.sqft end,
  price_cents=case when p_changes ? 'price_cents' then (p_changes->>'price_cents')::bigint else l.price_cents end,
  zillow_url=case when p_changes ? 'zillow_url' then p_changes->>'zillow_url' else l.zillow_url end,
  lat=case when p_changes ? 'lat' then (p_changes->>'lat')::double precision else l.lat end,
  lng=case when p_changes ? 'lng' then (p_changes->>'lng')::double precision else l.lng end,
  sold_at=case when p_changes ? 'sold_at' then (p_changes->>'sold_at')::timestamptz else l.sold_at end,
  status=case when p_changes ? 'status' then p_changes->>'status' else l.status end,
  details=d where id=p_listing returning * into l;
 return pg_catalog.to_jsonb(l);
end $$;
revoke all on function public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb) to service_role;
comment on function public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb) is
 'Service-only per-field CAS. Old broad writes require upgrade; preserves untouched facts and private plans.';
