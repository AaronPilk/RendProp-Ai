-- Room edits never write listing facts. Serialize against the exact cached plan.
-- Older iOS builds camel-case JSON map keys: keep that private namespace out of
-- ordinary full-row PATCHes, and recover its unambiguous legacy spelling.
create or replace function public.is_measurement_detail_key(k text) returns boolean
language sql immutable security invoker set search_path='' as $$
 select pg_catalog.replace(pg_catalog.lower(k),'_','') like 'floormeasurements%'
$$;
create or replace function public.canonical_measurement_details(d jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare result jsonb:=coalesce(d,'{}'); vals text[]; k text;
begin
 if pg_catalog.jsonb_typeof(result)<>'object' then return '{}'::jsonb; end if;
 select array_agg(distinct value) into vals from pg_catalog.jsonb_each_text(result)
 where pg_catalog.replace(pg_catalog.lower(key),'_','')='floormeasurementsv1';
 -- Conflicting aliases are retained, private and uneditable until resolved.
 if pg_catalog.cardinality(vals)=1 then
  for k in select key from pg_catalog.jsonb_each(result)
   where pg_catalog.replace(pg_catalog.lower(key),'_','')='floormeasurementsv1' loop
   result:=result-k;
  end loop;
  result:=result||pg_catalog.jsonb_build_object('floor_measurements_v1',vals[1]);
 end if;
 return result;
end $$;

create or replace function public.protect_measurement_details() returns trigger
language plpgsql security invoker set search_path='' as $$
declare protected jsonb; k text;
begin
 if TG_OP='UPDATE' and not (
  coalesce(pg_catalog.current_setting('rendprop.measurement_cas',true),'')='allowed'
  and current_user in('service_role','postgres')) then
  select coalesce(pg_catalog.jsonb_object_agg(key,value),'{}') into protected
   from pg_catalog.jsonb_each(coalesce(old.details,'{}'))
   where public.is_measurement_detail_key(key);
  new.details:=coalesce(new.details,'{}');
  for k in select key from pg_catalog.jsonb_each(new.details)
   where public.is_measurement_detail_key(key) loop new.details:=new.details-k; end loop;
  new.details:=new.details||protected;
 end if;
 new.details:=public.canonical_measurement_details(new.details);
 if pg_catalog.octet_length(new.details::text)>16000 then
  raise exception 'Listing details too large' using errcode='22023';
 end if;
 return new;
end $$;
drop trigger if exists trg_protect_measurement_details on public.listings;
create trigger trg_protect_measurement_details before insert or update of details on public.listings
 for each row execute function public.protect_measurement_details();
-- Safe canonicalization only; conflicting legacy variants remain intact.
update public.listings set details=public.canonical_measurement_details(details)
 where details is distinct from public.canonical_measurement_details(details);

create or replace function public.save_listing_measurements(
 p_actor uuid,p_org uuid,p_listing uuid,p_expected text,p_value text
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare l public.listings; d jsonb; vals text[]; current_plan text; previous_setting text;
begin
 perform public.upload_service_only();
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 select * into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if l.id is null then raise exception 'Listing not found' using errcode='P0002'; end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent'))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'Workspace is not writable' using errcode='42501';
 end if;
 if p_value is null or pg_catalog.octet_length(p_value)>10000 then
  raise exception 'Invalid measurement size' using errcode='22023';
 end if;
 d:=p_value::jsonb;
 if pg_catalog.jsonb_typeof(d)<>'object' or pg_catalog.jsonb_typeof(d->'version') is distinct from 'number'
  or (d->>'version') is null or d->>'version' not in('1','2')
  or pg_catalog.jsonb_typeof(d->'rooms') is distinct from 'array'
  or pg_catalog.jsonb_array_length(d->'rooms')>24 then
  raise exception 'Invalid measurement plan' using errcode='22023';
 end if;
 if coalesce(d->>'unit','') not in('feet','meters')
  or pg_catalog.jsonb_typeof(d->'updatedAt') is distinct from 'number' then
  raise exception 'Invalid measurement metadata' using errcode='22023';
 end if;
 if d->>'version'='2' and (pg_catalog.jsonb_typeof(d->'outlines') is distinct from 'array'
  or pg_catalog.jsonb_array_length(d->'outlines')>12) then
  raise exception 'Invalid measurement outlines' using errcode='22023';
 end if;
 d:=public.canonical_measurement_details(l.details);
 select array_agg(distinct value) into vals from pg_catalog.jsonb_each_text(d)
  where pg_catalog.replace(pg_catalog.lower(key),'_','')='floormeasurementsv1';
 if pg_catalog.cardinality(vals)>1 then raise exception 'Conflicting legacy plans' using errcode='40001'; end if;
 current_plan:=d->>'floor_measurements_v1';
 -- A response can be lost after commit. An identical retry is already saved.
 if current_plan is not distinct from p_value then return pg_catalog.to_jsonb(l); end if;
 if current_plan is distinct from p_expected then
  raise exception 'Measurements changed elsewhere' using errcode='40001';
 end if;
 d:=d||pg_catalog.jsonb_build_object('floor_measurements_v1',p_value);
 if pg_catalog.octet_length(d::text)>16000 then raise exception 'Listing details too large' using errcode='22023'; end if;
 previous_setting:=pg_catalog.current_setting('rendprop.measurement_cas',true);
 perform pg_catalog.set_config('rendprop.measurement_cas','allowed',true);
 update public.listings set details=d where id=p_listing returning * into l;
 perform pg_catalog.set_config('rendprop.measurement_cas',coalesce(previous_setting,''),true);
 return pg_catalog.to_jsonb(l);
end $$;
revoke all on function public.save_listing_measurements(uuid,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.save_listing_measurements(uuid,uuid,uuid,text,text) to service_role;
-- Trigger helpers operate on already RLS-scoped rows, never fetch private rows.
revoke all on function public.protect_measurement_details() from public,anon,authenticated;
comment on function public.save_listing_measurements(uuid,uuid,uuid,text,text) is
 'Service-only exact-plan CAS: preserves sqft, sold_at, status, price and every other details key.';
