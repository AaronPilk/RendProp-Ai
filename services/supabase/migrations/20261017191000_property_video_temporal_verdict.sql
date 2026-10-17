-- Temporal motion verdict (CPU profile temporal-motion-v2) recorded per steady
-- profile shot BEFORE the paid drift judge decides (property-video-worker/temporal.ts).
-- Additive only: one nullable column, one append-only history, one service-only
-- RPC and its guard. No price, grant, profile, selector or paid-retry change; the
-- single paid quality retry (20261015040518) keeps its drift-only grant. A
-- recorded verdict never advances, approves, substitutes or buys anything: the
-- shot still needs the paid drift receipt (property_video_job_qc), and an
-- original-photo fallback still needs a paid structural rejection
-- (property_video_fallback_source_guard). No historical DML.
-- Rollback (operator step, never a migration): docs/handoff/PROPERTY-VIDEO-TEMPORAL-ROLLBACK.sql
begin;
-- Before ANY DDL, replay accepts only this migration's exact own objects: both
-- columns' exact type/default/column ACL and their two CHECK constraints, the
-- trigger's exact timing/columns/function/enabled state, and each function's
-- exact body (md5 of prosrc), owner, language, security, volatility, config,
-- signature, single overload and ACL. The five objects exist together or not at
-- all (one transaction creates them); a partial set or any unknown same-name
-- object is refused rather than normalised by IF NOT EXISTS / OR REPLACE.
-- Nothing below is historical DML.
do $own_replay_guard$
declare e record;p pg_catalog.pg_proc;rel oid;owner_expected oid;service_oid oid;postgres_oid oid;present integer;shape text;cons text;bad integer;
begin
 rel:=to_regclass('public.property_video_job_sources');
 select proowner into owner_expected from pg_catalog.pg_proc where oid=to_regprocedure('public.property_video_job_worker_scope(uuid,uuid,uuid)');
 select oid into service_oid from pg_catalog.pg_roles where rolname='service_role';
 select oid into postgres_oid from pg_catalog.pg_roles where rolname='postgres';
 if rel is null or owner_expected is null or service_oid is null then raise exception'Temporal verdicts need the background property-video schema and service_role';end if;
 present:=(select count(*)from pg_catalog.pg_proc where pronamespace='public'::regnamespace and proname in('property_video_temporal_guard','property_video_job_temporal'))
  +(select count(*)from pg_catalog.pg_attribute where attrelid=rel and attname in('temporal','temporal_history')and attnum>0 and not attisdropped)
  +(select count(*)from pg_catalog.pg_trigger where not tgisinternal and(tgrelid=rel and tgname='property_video_temporal_guard'or tgfoid=to_regprocedure('public.property_video_temporal_guard()')));
 if present=0 then return;end if; -- first apply
 if present<>5 then raise exception'Review partial or unknown temporal verdict objects on public.property_video_job_sources (% present, 5 expected)',present;end if;
 for e in select *from(values
  ('public.property_video_temporal_guard()','cbb16aa2a4914b5171cae2ff267f0ce0','trigger',null::text[]),
  ('public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','8f6510439ec4910290e753ac93f7c976','jsonb',array['p_job','p_lease','p_attempt','p_clip_sha256','p_report'])
 )v(signature,body_md5,result_type,arg_names)loop
  if to_regprocedure(e.signature)is null then raise exception'Review changed temporal verdict helper: %',e.signature;end if;
  select *into p from pg_catalog.pg_proc where oid=to_regprocedure(e.signature);
  if md5(p.prosrc)<>e.body_md5 or p.proowner<>owner_expected or p.prokind<>'f'
   or p.prolang<>(select oid from pg_catalog.pg_language where lanname='plpgsql')
   or not p.prosecdef or p.provolatile<>'v' or p.proisstrict or p.proleakproof or p.proparallel<>'u'
   or p.proconfig is distinct from array['search_path=""']::text[]
   or p.proargnames is distinct from e.arg_names or p.proargmodes is not null or p.proallargtypes is not null
   or p.provariadic<>0 or p.pronargdefaults<>0 or p.proargdefaults is not null
   or p.prorettype is distinct from to_regtype(e.result_type)::oid
   or exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a
     where a.grantor<>owner_expected or a.privilege_type<>'EXECUTE'or a.is_grantable
      or a.grantee not in(owner_expected,service_oid,coalesce(postgres_oid,owner_expected)))
   or not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where a.grantee=owner_expected)
   or not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where a.grantee=service_oid)then
   raise exception'Review changed temporal verdict helper: %',e.signature;
  end if;
 end loop;
 select string_agg(a.attname||' '||format_type(a.atttypid,a.atttypmod)||case when a.attnotnull then' not null'else''end
   ||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),'')||coalesce(' acl '||a.attacl::text,''),', 'order by a.attname)
  into shape from pg_catalog.pg_attribute a left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
  where a.attrelid=rel and a.attname in('temporal','temporal_history')and a.attnum>0 and not a.attisdropped;
 select string_agg(c.conname||': '||pg_get_constraintdef(c.oid),'; 'order by c.conname)into cons from pg_catalog.pg_constraint c
  where c.conrelid=rel and exists(select 1 from pg_catalog.pg_attribute a where a.attrelid=rel and a.attnum=any(c.conkey)and a.attname in('temporal','temporal_history'));
 -- BEFORE UPDATE FOR EACH ROW is tgtype 19 (ROW 1 | BEFORE 2 | UPDATE 16).
 select count(*)into bad from pg_catalog.pg_trigger t where not t.tgisinternal and(t.tgrelid=rel and t.tgname='property_video_temporal_guard'or t.tgfoid=to_regprocedure('public.property_video_temporal_guard()'))
  and(t.tgrelid<>rel or t.tgname<>'property_video_temporal_guard'or t.tgfoid<>to_regprocedure('public.property_video_temporal_guard()')or t.tgtype<>19 or t.tgenabled<>'O'
   or t.tgnargs<>0 or t.tgqual is not null or t.tgconstraint<>0 or t.tgdeferrable or t.tgoldtable is not null or t.tgnewtable is not null
   or(select array_agg(a.attname::text order by a.attname)from pg_catalog.pg_attribute a where a.attrelid=rel and a.attnum=any(t.tgattr::int2[]))is distinct from array['temporal','temporal_history']);
 if shape is distinct from'temporal jsonb, temporal_history jsonb not null default ''[]''::jsonb'
  or cons is distinct from'property_video_job_sources_temporal_check: CHECK (((temporal IS NULL) OR (jsonb_typeof(temporal) = ''object''::text))); property_video_job_sources_temporal_history_check: CHECK ((jsonb_typeof(temporal_history) = ''array''::text))'
  or bad<>0 then
  raise exception'Review changed temporal verdict relation objects: public.property_video_job_sources';
 end if;
end$own_replay_guard$;

-- First apply only (the guard proved all five objects absent or exactly ours).
do $own_columns$begin
 if not exists(select 1 from pg_catalog.pg_attribute where attrelid='public.property_video_job_sources'::regclass and attname='temporal'and attnum>0 and not attisdropped)then
  alter table public.property_video_job_sources
   add column temporal jsonb constraint property_video_job_sources_temporal_check check(temporal is null or jsonb_typeof(temporal)='object'),
   add column temporal_history jsonb not null default'[]'::jsonb constraint property_video_job_sources_temporal_history_check check(jsonb_typeof(temporal_history)='array');
 end if;
end$own_columns$;

-- A recorded verdict is immutable. The current record may only be replaced by
-- archiving it unchanged, and only by a later attempt or a new limit version
-- (the first measurement of an attempt under a limit version stands, which also
-- refuses archiving a record without replacing it); prior archive entries never
-- change.
create or replace function public.property_video_temporal_guard()returns trigger
language plpgsql security definer set search_path=''as $$declare i integer;begin
 if new.temporal is not distinct from old.temporal and new.temporal_history is not distinct from old.temporal_history then return new;end if;
 if old.temporal is null then
  if new.temporal_history is distinct from old.temporal_history then raise exception'RP409: Temporal history is append-only';end if;return new;end if;
 if new.temporal is null or jsonb_array_length(new.temporal_history)<>jsonb_array_length(old.temporal_history)+1 or new.temporal_history->-1 is distinct from old.temporal then raise exception'RP409: A recorded temporal verdict is immutable';end if;
 if new.temporal->>'attempt_id'is not distinct from old.temporal->>'attempt_id'and new.temporal#>>'{limits,sha256}'is not distinct from old.temporal#>>'{limits,sha256}'then raise exception'RP409: The first temporal verdict for this attempt and limit version stands';end if;
 for i in 0..jsonb_array_length(old.temporal_history)-1 loop if new.temporal_history->i is distinct from old.temporal_history->i then raise exception'RP409: Prior temporal verdicts are immutable';end if;end loop;
 return new;end$$;
do $own_trigger$begin
 if not exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.property_video_job_sources'::regclass and tgname='property_video_temporal_guard'and not tgisinternal)then
  create trigger property_video_temporal_guard before update of temporal,temporal_history on public.property_video_job_sources for each row execute function public.property_video_temporal_guard();
 end if;
end$own_trigger$;

-- Worker callback: the CPU's closed report for THIS retained clip under THIS
-- live review lease. First measurement of an attempt under a limit version
-- wins and is returned on every repeat (a re-extract after a lapsed lease must
-- not stall on decoder float noise). Never a pass, a publication or a purchase.
create or replace function public.property_video_job_temporal(p_job uuid,p_lease uuid,p_attempt uuid,p_clip_sha256 text,p_report jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare s public.property_video_job_sources;rec jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,p_attempt);
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 if s.job_id is null or s.lease_token is distinct from p_lease or s.lease_until is null or s.lease_until<=now()or s.state<>'quality_review'then raise exception'RP409: This clip is not under a live quality review lease';end if;
 if s.clip is null or coalesce(p_clip_sha256,'')!~'^[a-f0-9]{64}$'or p_clip_sha256 is distinct from s.clip->>'sha256'then raise exception'RP409: The temporal report names a different clip';end if;
 if jsonb_typeof(p_report)is distinct from'object'or(select array_agg(k order by k)from jsonb_object_keys(p_report)k)is distinct from array['limits','metrics','profile','verdict']
  or p_report->>'profile'is distinct from'temporal-motion-v2'or p_report#>>'{limits,profile}'is distinct from'temporal-motion-v2'or coalesce(p_report#>>'{limits,sha256}','')!~'^[a-f0-9]{64}$'
  or jsonb_typeof(p_report->'metrics')is distinct from'object'or jsonb_typeof(p_report->'verdict')is distinct from'object'
  or p_report#>>'{verdict,profile}'is distinct from'temporal-motion-v2'or jsonb_typeof(p_report#>'{verdict,pass}')is distinct from'boolean'or jsonb_typeof(p_report#>'{verdict,reasons}')is distinct from'array'
  or(p_report#>'{verdict,pass}')::boolean<>(jsonb_array_length(p_report#>'{verdict,reasons}')=0)
  or exists(select 1 from jsonb_array_elements(p_report#>'{verdict,reasons}')r where jsonb_typeof(r)<>'string'or r#>>'{}'not in('vertical_bob','lateral_sway','walking_cadence','roll_wobble','zoom_pumping','walk_through_travel','horizon_roll','duplicate_frames','unmeasurable','invalid_metrics','invalid_limits'))
  or pg_column_size(p_report)>16384 then raise exception'RP400: Use a closed temporal motion report';end if;
 if s.temporal is not null and s.temporal->>'attempt_id'=p_attempt::text and s.temporal#>>'{limits,sha256}'=p_report#>>'{limits,sha256}'then return s.temporal;end if;
 rec:=p_report||jsonb_build_object('attempt_id',p_attempt,'clip_sha256',p_clip_sha256,'recorded_at',now());
 update public.property_video_job_sources set temporal=rec,temporal_history=case when s.temporal is null then temporal_history else temporal_history||jsonb_build_array(s.temporal)end where job_id=p_job and position=s.position;
 return rec;end$$;
revoke all on function public.property_video_temporal_guard(),public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.property_video_temporal_guard(),public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)to service_role;
commit;
