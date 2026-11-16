-- Second transaction-scoped memo: the library ownership leaves.
--
-- 20261106230000 memoized library_content_access / listing_content_access.
-- After it, workspace_directory (called on almost every request, ~30k/day)
-- still cost ~110 ms warm, all of it in library_access -> library_team_owner,
-- library_team_org and library_billing_org, which the first memo does not
-- cover and which re-run the sponsorship/team binding chain (~40 ms per org,
-- ~140 ms for a sponsored private library) every time they are called.
-- These three read only the tables already guarded by the access_cache_epoch
-- statement triggers, so the same epoch invalidates them.
--
-- Same shape as before: original bodies kept as *_compute (md5 pinned), a
-- plpgsql memo in front with the same name/signature/ACL; semantics unchanged.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $pin$
begin
 if to_regprocedure('public.library_content_access_compute(uuid,uuid,boolean)') is null then
  raise exception 'apply 20261106230000_listing_access_transaction_memo first';
 end if;
 if (select md5(prosrc) from pg_proc where oid = 'public.library_team_owner(uuid)'::regprocedure)
    is distinct from '897c17c8866da5c3ae955ce58fbabec5' then
  raise exception 'library_team_owner changed since 2026-11-06; review the memo before applying';
 end if;
 if (select md5(prosrc) from pg_proc where oid = 'public.library_team_org(uuid)'::regprocedure)
    is distinct from 'ee0288c8498db6e2ac43d5dc18141e38' then
  raise exception 'library_team_org changed since 2026-11-06; review the memo before applying';
 end if;
 if (select md5(prosrc) from pg_proc where oid = 'public.library_billing_org(uuid)'::regprocedure)
    is distinct from '764ffd5428474f638e429b0cb70e1a5c' then
  raise exception 'library_billing_org changed since 2026-11-06; review the memo before applying';
 end if;
 if to_regprocedure('public.library_team_owner_compute(uuid)') is not null
    or to_regprocedure('public.library_team_org_compute(uuid)') is not null
    or to_regprocedure('public.library_billing_org_compute(uuid)') is not null then
  raise exception 'library owner memo already applied';
 end if;
 if (select count(*) from pg_trigger where tgname = 'access_cache_epoch' and not tgisinternal) <> 16 then
  raise exception 'access_cache_epoch triggers are not the expected 16';
 end if;
end
$pin$;

alter function public.library_team_owner(uuid) rename to library_team_owner_compute;
alter function public.library_team_org(uuid) rename to library_team_org_compute;
alter function public.library_billing_org(uuid) rename to library_billing_org_compute;

-- Memo fronts. 'n' stands for a NULL result.
create function public.library_team_owner(p_org uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to ''
as $$
declare k text; v text; e text; r uuid;
begin
 if p_org is null then return null; end if;
 e := coalesce(pg_catalog.current_setting('rp.access_epoch', true), '');
 k := 'rp.lto.o' || replace(p_org::text, '-', '');
 v := pg_catalog.current_setting(k, true);
 if v is not null and v <> '' and pg_catalog.split_part(v, '|', 1) = e then
  return case when pg_catalog.split_part(v, '|', 2) = 'n' then null else pg_catalog.split_part(v, '|', 2)::uuid end;
 end if;
 r := public.library_team_owner_compute(p_org);
 perform pg_catalog.set_config(k, e || '|' || coalesce(r::text, 'n'), true);
 return r;
end
$$;
revoke all on function public.library_team_owner(uuid) from public, anon, authenticated;
grant execute on function public.library_team_owner(uuid) to service_role;

create function public.library_team_org(p_org uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to ''
as $$
declare k text; v text; e text; r uuid;
begin
 if p_org is null then return null; end if;
 e := coalesce(pg_catalog.current_setting('rp.access_epoch', true), '');
 k := 'rp.ltg.o' || replace(p_org::text, '-', '');
 v := pg_catalog.current_setting(k, true);
 if v is not null and v <> '' and pg_catalog.split_part(v, '|', 1) = e then
  return case when pg_catalog.split_part(v, '|', 2) = 'n' then null else pg_catalog.split_part(v, '|', 2)::uuid end;
 end if;
 r := public.library_team_org_compute(p_org);
 perform pg_catalog.set_config(k, e || '|' || coalesce(r::text, 'n'), true);
 return r;
end
$$;
revoke all on function public.library_team_org(uuid) from public, anon, authenticated;
grant execute on function public.library_team_org(uuid) to service_role;

create function public.library_billing_org(p_org uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to ''
as $$
declare k text; v text; e text; r uuid;
begin
 if p_org is null then return null; end if;
 e := coalesce(pg_catalog.current_setting('rp.access_epoch', true), '');
 k := 'rp.lbo.o' || replace(p_org::text, '-', '');
 v := pg_catalog.current_setting(k, true);
 if v is not null and v <> '' and pg_catalog.split_part(v, '|', 1) = e then
  return case when pg_catalog.split_part(v, '|', 2) = 'n' then null else pg_catalog.split_part(v, '|', 2)::uuid end;
 end if;
 r := public.library_billing_org_compute(p_org);
 perform pg_catalog.set_config(k, e || '|' || coalesce(r::text, 'n'), true);
 return r;
end
$$;
revoke all on function public.library_billing_org(uuid) from public, anon, authenticated;
grant execute on function public.library_billing_org(uuid) to service_role;

do $check$
declare f text;
begin
 foreach f in array array['library_team_owner', 'library_team_org', 'library_billing_org'] loop
  if (select proacl::text from pg_proc where oid = ('public.' || f || '(uuid)')::regprocedure)
     is distinct from (select proacl::text from pg_proc where oid = ('public.' || f || '_compute(uuid)')::regprocedure) then
   raise exception '% ACL drifted from its compute function', f;
  end if;
 end loop;
end
$check$;
commit;
