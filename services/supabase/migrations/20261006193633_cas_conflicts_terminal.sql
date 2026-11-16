-- Semantic stale-value conflicts are terminal HTTP 409 responses. SQLSTATE
-- 40001 means a transient serialization failure: PostgREST 14 retries that
-- transaction indefinitely, even when the caller's HTTP request has timed out.
-- Change only the five explicit application-conflict codes in the reviewed
-- current bodies. Preserve comparison/locking logic, signatures and all grants.
-- https://supabase.com/docs/guides/troubleshooting/high-cpu-and-infinite-transaction-retries-when-using-custom-error-codes-in-rpc-functions-77326b
-- https://docs.postgrest.org/en/v14/references/errors.html#raise-errors-with-http-status-codes
do $terminal_cas$
declare
 item record; fn oid; body text; definition text; old_acl aclitem[];
 old_owner oid; old_config text[]; old_security boolean; old_volatility "char";
begin
 for item in select * from (values
  ('public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb)',
   '7ced278d1c3685915093ef333b701194','79b9931a7ee69d46436a80304145cacb',2),
  ('public.save_listing_measurements(uuid,uuid,uuid,text,text)',
   '90890dc9f97234d95caadd6a6c8ff037','18d0428995631a94c5506d8b8c14eee6',2),
  ('public.studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text)',
   'b35ee6a76f54347b4c6df872b395e905','9afe2477225c8f16a83a66fe47363d5e',1)
 ) as reviewed(identity,old_md5,new_md5,conflicts) loop
  fn:=pg_catalog.to_regprocedure(item.identity);
  if fn is null then raise exception 'Terminal CAS prerequisite missing: %',item.identity; end if;
  select prosrc,proacl,proowner,proconfig,prosecdef,provolatile
   into body,old_acl,old_owner,old_config,old_security,old_volatility
   from pg_catalog.pg_proc where oid=fn;
  if old_security or old_volatility<>'v' or old_config is distinct from array['search_path=""']
   or pg_catalog.has_function_privilege('anon',fn,'EXECUTE')
   or pg_catalog.has_function_privilege('authenticated',fn,'EXECUTE')
   or not pg_catalog.has_function_privilege('service_role',fn,'EXECUTE') then
   raise exception 'Terminal CAS authority prerequisite changed: %',item.identity;
  end if;
  if pg_catalog.md5(body)=item.new_md5 then continue; end if;
  if pg_catalog.md5(body)<>item.old_md5
   or (pg_catalog.length(body)-pg_catalog.length(pg_catalog.replace(body,'errcode=''40001''','')))
     /pg_catalog.length('errcode=''40001''')<>item.conflicts then
   raise exception 'Terminal CAS reviewed body changed: %',item.identity;
  end if;
  definition:=pg_catalog.pg_get_functiondef(fn);
  execute pg_catalog.replace(definition,'errcode=''40001''','errcode=''PT409''');
  if not exists(select 1 from pg_catalog.pg_proc where oid=fn
   and pg_catalog.md5(prosrc)=item.new_md5 and proacl is not distinct from old_acl
   and proowner=old_owner and proconfig is not distinct from old_config
   and prosecdef=old_security and provolatile=old_volatility) then
   raise exception 'Terminal CAS postcondition changed: %',item.identity;
  end if;
 end loop;
end $terminal_cas$;
