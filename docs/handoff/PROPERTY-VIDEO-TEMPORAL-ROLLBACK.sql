-- PROPERTY-VIDEO-TEMPORAL-ROLLBACK.sql: undo migration
-- services/supabase/migrations/20261017191000_property_video_temporal_verdict.sql.
-- OPERATOR STEP, never a migration.
--
-- Order: FIRST redeploy the previous property-video-worker (the build that never
-- sends temporal_qc and never calls property_video_job_temporal), THEN run this.
-- In the other order a steady-profile quality callback fails while the new
-- worker is live: the CPU failure path re-extracts and then pauses that job
-- with its paid clip retained. Nothing is published or bought, but steady jobs
-- stall until the worker is rolled back. Neither the renderer's extra `limits`
-- report field nor the varied-motion property-video-jobs function reads these
-- objects; they need no rollback for this script.
--
-- Removes exactly: trigger property_video_temporal_guard, the functions
-- public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb) and
-- public.property_video_temporal_guard(), and the columns temporal and
-- temporal_history (with their two CHECK constraints) of
-- public.property_video_job_sources. Recorded verdicts in those two columns are
-- DISCARDED: they are diagnostic measurements only, and the NOTICE prints how
-- many. Paid receipts, clips, provenance, drift QC, cost rows, shot and job
-- states and every other column and object are untouched.
--
-- Refusals change nothing: only some of the five objects exist, or any of them
-- differs from the migration's own (the same pins as its replay guard). Already
-- rolled back (none exist): a NOTICE and no change, so a lost reply can rerun it.
--
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -f docs/handoff/PROPERTY-VIDEO-TEMPORAL-ROLLBACK.sql
--
-- Re-applying the migration afterwards recreates the five objects with empty
-- verdicts. Proven on a disposable cluster by
-- services/supabase/tests/property_video_temporal_pg.py: exact predecessor
-- catalog, untouched existing rows, refusal of a changed object, idempotent
-- second run, then a clean re-apply.
\set ON_ERROR_STOP on
set lock_timeout = '15s';
begin;
do $temporal_rollback$
declare e record;p pg_catalog.pg_proc;rel oid;owner_expected oid;service_oid oid;postgres_oid oid;present integer;shape text;cons text;bad integer;current_n bigint;archived_n bigint;
begin
 rel:=to_regclass('public.property_video_job_sources');
 select proowner into owner_expected from pg_catalog.pg_proc where oid=to_regprocedure('public.property_video_job_worker_scope(uuid,uuid,uuid)');
 select oid into service_oid from pg_catalog.pg_roles where rolname='service_role';
 select oid into postgres_oid from pg_catalog.pg_roles where rolname='postgres';
 if rel is null or owner_expected is null or service_oid is null then
  raise exception'PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: the background property-video schema or service_role is missing. Nothing changed.';
 end if;
 present:=(select count(*)from pg_catalog.pg_proc where pronamespace='public'::regnamespace and proname in('property_video_temporal_guard','property_video_job_temporal'))
  +(select count(*)from pg_catalog.pg_attribute where attrelid=rel and attname in('temporal','temporal_history')and attnum>0 and not attisdropped)
  +(select count(*)from pg_catalog.pg_trigger where not tgisinternal and(tgrelid=rel and tgname='property_video_temporal_guard'or tgfoid=to_regprocedure('public.property_video_temporal_guard()')));
 if present=0 then
  raise notice'PROPERTY-VIDEO-TEMPORAL-ROLLBACK: nothing to roll back (no temporal verdict objects exist). Nothing changed.';
  return;
 end if;
 if present<>5 then
  raise exception'PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: % of the 5 temporal verdict objects exist (partial or unknown objects). Nothing changed.',present;
 end if;
 for e in select *from(values
  ('public.property_video_temporal_guard()','cbb16aa2a4914b5171cae2ff267f0ce0','trigger',null::text[]),
  ('public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','8f6510439ec4910290e753ac93f7c976','jsonb',array['p_job','p_lease','p_attempt','p_clip_sha256','p_report'])
 )v(signature,body_md5,result_type,arg_names)loop
  select *into p from pg_catalog.pg_proc where oid=to_regprocedure(e.signature);
  if p.oid is null or md5(p.prosrc)<>e.body_md5 or p.proowner<>owner_expected or p.prokind<>'f'
   or p.prolang<>(select oid from pg_catalog.pg_language where lanname='plpgsql')
   or not p.prosecdef or p.provolatile<>'v' or p.proisstrict or p.proleakproof or p.proparallel<>'u'
   or p.proconfig is distinct from array['search_path=""']::text[]
   or p.proargnames is distinct from e.arg_names or p.proargmodes is not null or p.proallargtypes is not null
   or p.provariadic<>0 or p.pronargdefaults<>0 or p.proargdefaults is not null
   or p.prorettype is distinct from to_regtype(e.result_type)::oid
   or exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a
     where a.grantor<>owner_expected or a.privilege_type<>'EXECUTE'or a.is_grantable
      or a.grantee not in(owner_expected,service_oid,coalesce(postgres_oid,owner_expected)))then
   raise exception'PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: % differs from the migration''s own. Nothing changed.',e.signature;
  end if;
 end loop;
 select string_agg(a.attname||' '||format_type(a.atttypid,a.atttypmod)||case when a.attnotnull then' not null'else''end
   ||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),'')||coalesce(' acl '||a.attacl::text,''),', 'order by a.attname)
  into shape from pg_catalog.pg_attribute a left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
  where a.attrelid=rel and a.attname in('temporal','temporal_history')and a.attnum>0 and not a.attisdropped;
 select string_agg(c.conname||': '||pg_get_constraintdef(c.oid),'; 'order by c.conname)into cons from pg_catalog.pg_constraint c
  where c.conrelid=rel and exists(select 1 from pg_catalog.pg_attribute a where a.attrelid=rel and a.attnum=any(c.conkey)and a.attname in('temporal','temporal_history'));
 select count(*)into bad from pg_catalog.pg_trigger t where not t.tgisinternal and(t.tgrelid=rel and t.tgname='property_video_temporal_guard'or t.tgfoid=to_regprocedure('public.property_video_temporal_guard()'))
  and(t.tgrelid<>rel or t.tgname<>'property_video_temporal_guard'or t.tgfoid<>to_regprocedure('public.property_video_temporal_guard()')or t.tgtype<>19 or t.tgenabled<>'O'
   or t.tgnargs<>0 or t.tgqual is not null or t.tgconstraint<>0 or t.tgdeferrable or t.tgoldtable is not null or t.tgnewtable is not null
   or(select array_agg(a.attname::text order by a.attname)from pg_catalog.pg_attribute a where a.attrelid=rel and a.attnum=any(t.tgattr::int2[]))is distinct from array['temporal','temporal_history']);
 if shape is distinct from'temporal jsonb, temporal_history jsonb not null default ''[]''::jsonb'
  or cons is distinct from'property_video_job_sources_temporal_check: CHECK (((temporal IS NULL) OR (jsonb_typeof(temporal) = ''object''::text))); property_video_job_sources_temporal_history_check: CHECK ((jsonb_typeof(temporal_history) = ''array''::text))'
  or bad<>0 then
  raise exception'PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: the temporal columns, constraints or trigger on public.property_video_job_sources differ from the migration''s own. Nothing changed.';
 end if;
 execute'select count(*) filter(where temporal is not null),coalesce(sum(jsonb_array_length(temporal_history)),0)from public.property_video_job_sources'into current_n,archived_n;
 drop trigger property_video_temporal_guard on public.property_video_job_sources;
 drop function public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb);
 drop function public.property_video_temporal_guard();
 alter table public.property_video_job_sources drop column temporal_history,drop column temporal;
 raise notice'PROPERTY-VIDEO-TEMPORAL-ROLLBACK done: removed the temporal verdict trigger, both functions and both columns; discarded % current and % archived temporal verdicts.',current_n,archived_n;
end$temporal_rollback$;
commit;
