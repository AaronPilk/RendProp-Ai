-- Plan caching for the access-chain leaves.
--
-- The remaining cost after the two memos (20261106230000, 20261106233000)
-- is planning: these are LANGUAGE sql functions, which Postgres re-parses
-- and re-plans on every call. EXPLAIN on private_team_content_binding_valid
-- measured 26.5 ms of planning for 13 ms of execution, and the nested calls
-- inside it (team_library_owner, effective_plan_before_team, ...) plan again
-- each. A plpgsql function keeps its plans per connection, and PostgREST's
-- pooled connections live long, so the second call onwards skips planning.
--
-- The bodies are not rewritten by hand: each function's current definition
-- is read, md5-pinned, and converted mechanically from
--     LANGUAGE sql ... AS $f$ <one select>; $f$
-- to  LANGUAGE plpgsql ... AS $f$ begin return (<one select>); end $f$
-- which returns the same scalar (every body here is a single SELECT that
-- yields at most one row: PK lookups, aggregates, EXISTS, or LIMIT 1).
-- CREATE OR REPLACE keeps OIDs, ACLs, STABLE, SECURITY DEFINER and the
-- per-function search_path. Set-returning functions and the two policy
-- functions (current_listing_access, is_org_member) are not touched.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $convert$
declare
 target record;
 d text; head text; body text; pos int; tail int;
 expected jsonb := '{
  "agent_private_library(uuid)": "0330b7136e128a92fa0d1754886f16d3",
  "effective_plan_before_team(uuid)": "26e50416ae805f68bdb3aa26e1e64989",
  "effective_plan(uuid)": "bf370abddcde5d2a6763742042123928",
  "library_billing_org_compute(uuid)": "764ffd5428474f638e429b0cb70e1a5c",
  "library_content_access_compute(uuid,uuid,boolean)": "2c000242919f52a6c8e4b28328488cb7",
  "library_internal_content_unlimited(uuid)": "a04c702a79be72acd14a88143f5b04dd",
  "library_team_org_compute(uuid)": "ee0288c8498db6e2ac43d5dc18141e38",
  "library_team_owner_compute(uuid)": "897c17c8866da5c3ae955ce58fbabec5",
  "listing_content_access_compute(uuid,uuid,boolean)": "a33c1ea0b72b7cae9919edbb33da4b55",
  "listing_owner_library(uuid)": "7856e37ba066ebd43731966716411da5",
  "org_has_app_review_funding(uuid)": "788dcbc1d53da643da3d4bbf9f128d56",
  "org_seats_allowed(uuid)": "3fe9f599eb91051b5ea660e3c87dd5e4",
  "private_internal_testing_master_owner(uuid)": "bff9937b511d4a16cd557524f0bd6b8c",
  "private_team_content_binding_valid(uuid)": "cbb8cbbb7f5cd4f9028144f751070398",
  "resolve_actor_owned_library(uuid,boolean)": "b4b46f68c2df8394f90e9a04c2e7bc61",
  "team_library_binding_valid(uuid)": "d716c597857d93b1434d9f058a13ab5a",
  "team_library_owner(uuid)": "b7aa096c31cdbea46551c4a8989812d7",
  "team_member_seat_active(uuid,uuid)": "bfb967555a78f16b7b1de66bb3219869"
 }'::jsonb;
 before_meta jsonb; after_meta jsonb;
begin
 for target in select key as sig, value #>> '{}' as md5 from jsonb_each(expected) loop
  if (select md5(prosrc) from pg_proc where oid = ('public.' || target.sig)::regprocedure) is distinct from target.md5 then
   raise exception '% changed since 2026-11-06; review before converting', target.sig;
  end if;
  if (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = ('public.' || target.sig)::regprocedure) <> 'sql' then
   raise exception '% is not a SQL function', target.sig;
  end if;
  if (select proretset from pg_proc where oid = ('public.' || target.sig)::regprocedure) then
   raise exception '% returns a set', target.sig;
  end if;
  select to_jsonb(p) - 'prosrc' - 'prolang' - 'probin' - 'prosqlbody' into before_meta from pg_proc p where p.oid = ('public.' || target.sig)::regprocedure;
  d := pg_get_functiondef(('public.' || target.sig)::regprocedure);
  if position(E'\n LANGUAGE sql\n' in d) = 0 then raise exception '% definition has no LANGUAGE sql line', target.sig; end if;
  head := replace(d, E'\n LANGUAGE sql\n', E'\n LANGUAGE plpgsql\n');
  pos := position('AS $function$' in head);
  if pos = 0 then raise exception '% body delimiter not found', target.sig; end if;
  body := substr(head, pos + length('AS $function$'));
  tail := position('$function$' in body);
  if tail = 0 or btrim(substr(body, tail + length('$function$')), E' \n') <> '' then raise exception '% body end not found', target.sig; end if;
  body := btrim(substr(body, 1, tail - 1), E' \n\t');
  if right(body, 1) = ';' then body := btrim(substr(body, 1, length(body) - 1), E' \n\t'); end if;
  if position(';' in body) > 0 then raise exception '% body has more than one statement', target.sig; end if;
  if lower(left(body, 6)) <> 'select' then raise exception '% body is not a single select', target.sig; end if;
  execute substr(head, 1, pos - 1) || E'AS $function$\nbegin\n return (' || body || E');\nend\n$function$';
  select to_jsonb(p) - 'prosrc' - 'prolang' - 'probin' - 'prosqlbody' into after_meta from pg_proc p where p.oid = ('public.' || target.sig)::regprocedure;
  if after_meta is distinct from before_meta then raise exception '% metadata changed during conversion: % vs %', target.sig, before_meta, after_meta; end if;
 end loop;
end
$convert$;
commit;
