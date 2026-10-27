-- The expression index on listings.address evaluates this immutable helper
-- as the row writer. Authenticated listing inserts must therefore be allowed
-- to execute the pure text transform. The public address lookup still reads
-- publication state only under service_role, and listing RLS is unchanged.
begin;

do $$
declare descriptor oid:=to_regprocedure('public.property_address_descriptor(text)');
        body pg_proc%rowtype;
begin
  if descriptor is null then
    raise exception 'Review missing address descriptor before index-writer grant';
  end if;
  select * into body from pg_proc where oid=descriptor;
  if md5(body.prosrc)<>'cd764799a9a0f1467ca6eee161af4d71'
      or body.provolatile<>'i' or not body.proisstrict or body.prosecdef
      or body.proconfig is distinct from array['search_path=""']::text[] then
    raise exception 'Review changed address descriptor before index-writer grant';
  end if;
  if not exists(
    select 1 from pg_index i join pg_depend d
      on d.classid='pg_class'::regclass and d.objid=i.indexrelid
      and d.refclassid='pg_proc'::regclass and d.refobjid=descriptor
    where i.indexrelid=to_regclass('public.listings_public_address_descriptor_idx')
      and i.indrelid='public.listings'::regclass and i.indisvalid and i.indisready
  ) then
    raise exception 'Review changed address index before index-writer grant';
  end if;
  if has_function_privilege('anon',descriptor,'execute')
      or not has_function_privilege('service_role',descriptor,'execute')
      or has_function_privilege('anon','public.public_property_address_lookup(text)','execute')
      or has_function_privilege('authenticated','public.public_property_address_lookup(text)','execute') then
    raise exception 'Review changed address RPC privileges before index-writer grant';
  end if;
end$$;

grant execute on function public.property_address_descriptor(text) to authenticated;

do $$begin
  if not has_function_privilege('authenticated','public.property_address_descriptor(text)','execute')
      or has_function_privilege('anon','public.property_address_descriptor(text)','execute')
      or has_function_privilege('authenticated','public.public_property_address_lookup(text)','execute')
      or has_function_privilege('anon','public.public_property_address_lookup(text)','execute') then
    raise exception 'Address index-writer grant changed a public lookup boundary';
  end if;
end$$;

commit;
