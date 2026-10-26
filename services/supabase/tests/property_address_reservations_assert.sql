do $$begin
  if public.property_address_descriptor('855 Central Ave #1120, Saint Petersburg, FL 33701')
    <> '855-central-ave-1120-saint-petersburg-fl-33701' then
    raise exception 'address normalization mismatch';
  end if;
end$$;

set role service_role;
do $$
declare result jsonb;
begin
  result:=public.public_property_address_lookup('855-central-ave-1120-saint-petersburg-fl-33701');
  if result<>'{"status":"ambiguous"}'::jsonb then raise exception 'unclaimed collision leaked: %',result;end if;
end$$;
reset role;

do $$begin
  if not exists(select 1 from public.property_address_reservations
    where descriptor='123-other-st-saint-petersburg-fl-33701'
      and listing_id='00000000-0000-4000-8000-000000000006') then
    raise exception 'existing unique address was not preserved by backfill';
  end if;
  if exists(select 1 from public.property_address_reservations
    where descriptor='855-central-ave-1120-saint-petersburg-fl-33701') then
    raise exception 'ambiguous address was incorrectly assigned during backfill';
  end if;
end$$;

insert into public.property_address_reservations(descriptor,listing_id) values
  ('855-central-ave-1120-saint-petersburg-fl-33701','55739bcb-e589-853b-ad28-92a3a5521823');
set role service_role;
do $$
declare result jsonb;
begin
  result:=public.public_property_address_lookup('855-central-ave-1120-saint-petersburg-fl-33701');
  if result<>'{"status":"unique","slug":"g2afbgmv32","claimed":true}'::jsonb then
    raise exception 'reservation did not retain old bare publication: %',result;
  end if;
end$$;
reset role;

do $$
begin
  if has_table_privilege('anon','public.property_address_reservations','select')
     or has_table_privilege('authenticated','public.property_address_reservations','select')
     or has_table_privilege('anon','public.property_address_reservations','insert')
     or has_function_privilege('anon','public.public_property_address_lookup(text)','execute') then
    raise exception 'public address claim grant escaped';
  end if;
end$$;

update public.listings set address='855 Central Avenue Unit 1120, Saint Petersburg, FL 33701'
  where id='55739bcb-e589-853b-ad28-92a3a5521823';
set role service_role;
do $$
declare result jsonb;
begin
  result:=public.public_property_address_lookup('855-central-ave-1120-saint-petersburg-fl-33701');
  if result<>'{"status":"unique","slug":"g2afbgmv32","claimed":true}'::jsonb then
    raise exception 'address correction broke the old bare alias: %',result;
  end if;
end$$;
reset role;

update public.listings set deleted_at=now()
  where id='55739bcb-e589-853b-ad28-92a3a5521823';
set role service_role;
do $$
declare result jsonb;
begin
  result:=public.public_property_address_lookup('855-central-ave-1120-saint-petersburg-fl-33701');
  if result<>'{"status":"ambiguous"}'::jsonb then raise exception 'withdrawn owner was replaced: %',result;end if;
end$$;
reset role;

delete from public.listings where id='55739bcb-e589-853b-ad28-92a3a5521823';
do $$
begin
  if not exists(select 1 from public.property_address_reservations
    where descriptor='855-central-ave-1120-saint-petersburg-fl-33701' and listing_id is null) then
    raise exception 'deleted bare owner did not leave a tombstone';
  end if;
end$$;
set role service_role;
do $$
declare result jsonb;
begin
  result:=public.public_property_address_lookup('855-central-ave-1120-saint-petersburg-fl-33701');
  if result<>'{"status":"ambiguous"}'::jsonb then raise exception 'deleted reservation fell back: %',result;end if;
end$$;
reset role;

select 'address reservation database checks passed' as result;
