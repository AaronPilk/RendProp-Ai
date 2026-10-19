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
-- Removes exactly: table public.property_video_job_temporal_verdicts (with its
-- guard trigger, key, checks and foreign key) and the functions
-- public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb) and
-- public.property_video_temporal_verdict_guard(). Recorded verdicts are
-- DISCARDED: they are diagnostic measurements only, and the NOTICE prints how
-- many. property_video_job_sources and every other relation, row and function
-- (paid receipts, clips, provenance, drift QC, cost rows, shot and job states)
-- are untouched.
--
-- Refusals change nothing: only some of the four objects exist, any of them
-- differs from the migration's own identity (the replay guard's md5-pinned
-- function bodies, signatures, security and grantees; the table's columns,
-- constraints, key, owner and guard trigger), or another object depends on the
-- table. A changed grant or policy on the table does not block removing it.
-- Already rolled back (none exist): a NOTICE and no change, so a lost reply can
-- rerun it.
--
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -f docs/handoff/PROPERTY-VIDEO-TEMPORAL-ROLLBACK.sql
--
-- Re-applying the migration afterwards recreates the four objects with no
-- verdicts. Proven on a disposable cluster by
-- services/supabase/tests/property_video_temporal_pg.py: exact predecessor
-- catalog, untouched existing rows, refusal of a changed object, idempotent
-- second run, then a clean re-apply.
\set ON_ERROR_STOP on
set lock_timeout = '15s';
begin;
do $temporal_rollback$
declare e record;p pg_catalog.pg_proc;rel oid;owner_expected oid;service_oid oid;postgres_oid oid;present integer;prior_path text;shape text;cons text;bad integer;n bigint;
begin
 prior_path:=current_setting('search_path');perform set_config('search_path','public',true);
 select proowner into owner_expected from pg_catalog.pg_proc where oid=to_regprocedure('public.property_video_job_worker_scope(uuid,uuid,uuid)');
 select oid into service_oid from pg_catalog.pg_roles where rolname='service_role';
 select oid into postgres_oid from pg_catalog.pg_roles where rolname='postgres';
 if to_regclass('public.property_video_job_sources')is null or owner_expected is null or service_oid is null then
  raise exception'PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: the background property-video schema or service_role is missing. Nothing changed.';
 end if;
 rel:=to_regclass('public.property_video_job_temporal_verdicts');
 present:=(select count(*)from pg_catalog.pg_proc where pronamespace='public'::regnamespace and proname in('property_video_temporal_verdict_guard','property_video_job_temporal'))
  +(select count(*)from pg_catalog.pg_class where relnamespace='public'::regnamespace and relname='property_video_job_temporal_verdicts')
  +(select count(*)from pg_catalog.pg_trigger where not tgisinternal and(tgrelid=rel and tgname='property_video_temporal_verdict_guard'or tgfoid=to_regprocedure('public.property_video_temporal_verdict_guard()')));
 if present=0 then
  raise notice'PROPERTY-VIDEO-TEMPORAL-ROLLBACK: nothing to roll back (no temporal verdict objects exist). Nothing changed.';
  perform set_config('search_path',prior_path,true);return;
 end if;
 if present<>4 then
  raise exception'PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: % of the 4 temporal verdict objects exist (partial or unknown objects). Nothing changed.',present;
 end if;
 for e in select *from(values
  ('public.property_video_temporal_verdict_guard()','8a4b9a3242bb6d0642a6efdaf5ebbfd6','trigger',null::text[]),
  ('public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','cdef6bae9b0a8e04a636dcd1969965ab','jsonb',array['p_job','p_lease','p_attempt','p_clip_sha256','p_report'])
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
   ||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),'')||coalesce(' acl '||a.attacl::text,''),', 'order by a.attnum)
  into shape from pg_catalog.pg_attribute a left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
  where a.attrelid=rel and a.attnum>0 and not a.attisdropped;
 select string_agg(conname||': '||pg_get_constraintdef(oid),'; 'order by conname)into cons from pg_catalog.pg_constraint where conrelid=rel;
 select count(*)into bad from pg_catalog.pg_trigger t where not t.tgisinternal and(t.tgrelid=rel or t.tgfoid=to_regprocedure('public.property_video_temporal_verdict_guard()'))
  and(t.tgrelid<>rel or t.tgname<>'property_video_temporal_verdict_guard'or t.tgfoid<>to_regprocedure('public.property_video_temporal_verdict_guard()')or t.tgtype<>19 or t.tgenabled<>'O'
   or t.tgnargs<>0 or t.tgqual is not null or t.tgconstraint<>0 or t.tgdeferrable or t.tgoldtable is not null or t.tgnewtable is not null or cardinality(t.tgattr::int2[])<>0);
 if shape is distinct from'job_id uuid not null, position integer not null, attempt_id uuid not null, limits_sha256 text not null, record jsonb not null, recorded_at timestamp with time zone not null default now()'
  or cons is distinct from'property_video_job_temporal_verdicts_limits_check: CHECK ((limits_sha256 ~ ''^[a-f0-9]{64}$''::text)); property_video_job_temporal_verdicts_pkey: PRIMARY KEY (job_id, "position", attempt_id, limits_sha256); property_video_job_temporal_verdicts_record_check: CHECK (((jsonb_typeof(record) = ''object''::text) AND ((record ->> ''attempt_id''::text) = (attempt_id)::text) AND ((record #>> ''{limits,sha256}''::text[]) = limits_sha256))); property_video_job_temporal_verdicts_source_fkey: FOREIGN KEY (job_id, "position") REFERENCES property_video_job_sources(job_id, "position") ON DELETE CASCADE'
  or(select string_agg(indexrelid::regclass::text,', 'order by indexrelid::regclass::text)from pg_catalog.pg_index where indrelid=rel)is distinct from'property_video_job_temporal_verdicts_pkey'
  or(select relkind<>'r'or relowner<>owner_expected from pg_catalog.pg_class where oid=rel)
  or exists(select 1 from pg_catalog.pg_depend d where d.refobjid=rel and d.classid='pg_catalog.pg_rewrite'::regclass)
  or exists(select 1 from pg_catalog.pg_constraint where confrelid=rel)
  or bad<>0 then
  raise exception'PROPERTY-VIDEO-TEMPORAL-ROLLBACK refused: public.property_video_job_temporal_verdicts differs from the migration''s own or has dependants. Nothing changed.';
 end if;
 execute'select count(*)from public.property_video_job_temporal_verdicts'into n;
 perform set_config('search_path',prior_path,true);
 drop table public.property_video_job_temporal_verdicts;
 drop function public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb);
 drop function public.property_video_temporal_verdict_guard();
 raise notice'PROPERTY-VIDEO-TEMPORAL-ROLLBACK done: removed the temporal verdict table, its guard trigger and both functions; discarded % recorded temporal verdicts.',n;
end$temporal_rollback$;
commit;
