begin;
-- New links use the CSPRNG UUID's 122 random bits. Historical slugs are not
-- changed. Preserve publication behavior, function attributes and all ACLs.
do $patch$declare body text;definition text;sig regprocedure:='public.publish_render(uuid,numeric,numeric,jsonb,uuid)'::regprocedure;
begin
 select prosrc into body from pg_catalog.pg_proc where oid=sig;
 if md5(body)='965c26447ca27ac12b278f2995268fba'then return;end if;
 if md5(body)<>'64e1d5b07860672a837079565287644e'then raise exception 'Unknown publish_render body; crypto slug patch refused';end if;
 definition:=pg_catalog.pg_get_functiondef(sig);
 definition:=replace(definition,$needle$v_slug := (
      select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', (random()*30)::integer + 1, 1), '')
      from generate_series(1, 10)
    );$needle$,$replacement$v_slug := replace(pg_catalog.gen_random_uuid()::text,'-','');$replacement$);
 execute definition;
end$patch$;
commit;
