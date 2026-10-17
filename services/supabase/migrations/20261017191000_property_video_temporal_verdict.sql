-- Temporal motion verdict (CPU profile temporal-motion-v2) recorded per steady
-- profile shot BEFORE the paid drift judge decides (property-video-worker/temporal.ts).
-- Additive only: one new service-only table, one service-only RPC and one
-- immutability guard. property_video_job_sources keeps its exact row shape, so
-- every whole-row snapshot of it is unchanged: property_video_compose_snapshot
-- hashes to_jsonb(row) into sources_sha256 and the claim compares that with the
-- snapshot recorded when assembly recovery began, so new columns there would
-- send a job already in assembly recovery to needs_reconciliation. Worker claim
-- payloads and prior_source histories are unchanged too. No price, grant,
-- profile, selector or paid-retry change; the single paid quality retry
-- (20261015040518) keeps its drift-only grant. A recorded verdict never
-- advances, approves, substitutes or buys anything: the shot still needs the
-- paid drift receipt (property_video_job_qc), and an original-photo fallback
-- still needs a paid structural rejection (property_video_fallback_source_guard).
-- No historical DML.
-- Rollback (operator step, never a migration): docs/handoff/PROPERTY-VIDEO-TEMPORAL-ROLLBACK.sql
begin;
-- Before ANY DDL, replay accepts only this migration's exact own objects: the
-- table's exact columns, constraints, index, RLS, policies, owner and ACL; the
-- guard trigger's exact timing, function and enabled state; and each function's
-- exact body (md5 of prosrc), owner, language, security, volatility, config,
-- signature, single overload and ACL. The four objects exist together or not at
-- all (one transaction creates them); a partial set or any unknown same-name
-- object is refused rather than normalised by IF NOT EXISTS / OR REPLACE.
-- Nothing below is historical DML.
do $own_replay_guard$
declare e record;p pg_catalog.pg_proc;rel oid;owner_expected oid;service_oid oid;postgres_oid oid;present integer;prior_path text;shape text;cons text;bad integer;
begin
 -- Deterministic deparse of constraint references, restored before any DDL.
 prior_path:=current_setting('search_path');perform set_config('search_path','public',true);
 select proowner into owner_expected from pg_catalog.pg_proc where oid=to_regprocedure('public.property_video_job_worker_scope(uuid,uuid,uuid)');
 select oid into service_oid from pg_catalog.pg_roles where rolname='service_role';
 select oid into postgres_oid from pg_catalog.pg_roles where rolname='postgres';
 if to_regclass('public.property_video_job_sources')is null or owner_expected is null or service_oid is null then raise exception'Temporal verdicts need the background property-video schema and service_role';end if;
 rel:=to_regclass('public.property_video_job_temporal_verdicts');
 present:=(select count(*)from pg_catalog.pg_proc where pronamespace='public'::regnamespace and proname in('property_video_temporal_verdict_guard','property_video_job_temporal'))
  +(select count(*)from pg_catalog.pg_class where relnamespace='public'::regnamespace and relname='property_video_job_temporal_verdicts')
  +(select count(*)from pg_catalog.pg_trigger where not tgisinternal and(tgrelid=rel and tgname='property_video_temporal_verdict_guard'or tgfoid=to_regprocedure('public.property_video_temporal_verdict_guard()')));
 if present=0 then perform set_config('search_path',prior_path,true);return;end if; -- first apply
 if present<>4 then raise exception'Review partial or unknown temporal verdict objects (% present, 4 expected)',present;end if;
 for e in select *from(values
  ('public.property_video_temporal_verdict_guard()','8a4b9a3242bb6d0642a6efdaf5ebbfd6','trigger',null::text[]),
  ('public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','cdef6bae9b0a8e04a636dcd1969965ab','jsonb',array['p_job','p_lease','p_attempt','p_clip_sha256','p_report'])
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
   ||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),'')||coalesce(' acl '||a.attacl::text,''),', 'order by a.attnum)
  into shape from pg_catalog.pg_attribute a left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
  where a.attrelid=rel and a.attnum>0 and not a.attisdropped;
 select string_agg(conname||': '||pg_get_constraintdef(oid),'; 'order by conname)into cons from pg_catalog.pg_constraint where conrelid=rel;
 -- BEFORE UPDATE FOR EACH ROW is tgtype 19 (ROW 1 | BEFORE 2 | UPDATE 16).
 select count(*)into bad from pg_catalog.pg_trigger t where not t.tgisinternal and(t.tgrelid=rel or t.tgfoid=to_regprocedure('public.property_video_temporal_verdict_guard()'))
  and(t.tgrelid<>rel or t.tgname<>'property_video_temporal_verdict_guard'or t.tgfoid<>to_regprocedure('public.property_video_temporal_verdict_guard()')or t.tgtype<>19 or t.tgenabled<>'O'
   or t.tgnargs<>0 or t.tgqual is not null or t.tgconstraint<>0 or t.tgdeferrable or t.tgoldtable is not null or t.tgnewtable is not null or cardinality(t.tgattr::int2[])<>0);
 if shape is distinct from'job_id uuid not null, position integer not null, attempt_id uuid not null, limits_sha256 text not null, record jsonb not null, recorded_at timestamp with time zone not null default now()'
  or cons is distinct from'property_video_job_temporal_verdicts_limits_check: CHECK ((limits_sha256 ~ ''^[a-f0-9]{64}$''::text)); property_video_job_temporal_verdicts_pkey: PRIMARY KEY (job_id, "position", attempt_id, limits_sha256); property_video_job_temporal_verdicts_record_check: CHECK (((jsonb_typeof(record) = ''object''::text) AND ((record ->> ''attempt_id''::text) = (attempt_id)::text) AND ((record #>> ''{limits,sha256}''::text[]) = limits_sha256))); property_video_job_temporal_verdicts_source_fkey: FOREIGN KEY (job_id, "position") REFERENCES property_video_job_sources(job_id, "position") ON DELETE CASCADE'
  or(select string_agg(indexrelid::regclass::text,', 'order by indexrelid::regclass::text)from pg_catalog.pg_index where indrelid=rel)is distinct from'property_video_job_temporal_verdicts_pkey'
  or(select relkind<>'r'or not relrowsecurity or relforcerowsecurity or relowner<>owner_expected from pg_catalog.pg_class where oid=rel)
  or exists(select 1 from pg_catalog.pg_policy where polrelid=rel)
  or bad<>0
  or exists(select 1 from pg_catalog.pg_class c,aclexplode(coalesce(c.relacl,acldefault('r',c.relowner)))a where c.oid=rel
     and(a.grantor<>owner_expected or a.is_grantable or(a.grantee<>owner_expected and(a.grantee<>service_oid or a.privilege_type<>'SELECT'))))
  or not exists(select 1 from pg_catalog.pg_class c,aclexplode(coalesce(c.relacl,acldefault('r',c.relowner)))a where c.oid=rel and a.grantee=service_oid and a.privilege_type='SELECT')then
  raise exception'Review changed temporal verdict relation: public.property_video_job_temporal_verdicts';
 end if;
 perform set_config('search_path',prior_path,true);
end$own_replay_guard$;

-- One immutable row per shot, paid attempt and limit version. A later attempt
-- or a new limit version adds a row; nothing is ever replaced. Rows follow
-- their shot on account erasure (ON DELETE CASCADE from the source row).
create table if not exists public.property_video_job_temporal_verdicts(
 job_id uuid not null,
 position integer not null,
 attempt_id uuid not null,
 limits_sha256 text not null,
 record jsonb not null,
 recorded_at timestamptz not null default now(),
 constraint property_video_job_temporal_verdicts_pkey primary key(job_id,position,attempt_id,limits_sha256),
 constraint property_video_job_temporal_verdicts_source_fkey foreign key(job_id,position)references public.property_video_job_sources(job_id,position)on delete cascade,
 constraint property_video_job_temporal_verdicts_limits_check check(limits_sha256~'^[a-f0-9]{64}$'),
 constraint property_video_job_temporal_verdicts_record_check check(jsonb_typeof(record)='object'and record->>'attempt_id'=attempt_id::text and record#>>'{limits,sha256}'=limits_sha256)
);
alter table public.property_video_job_temporal_verdicts enable row level security;
revoke all on public.property_video_job_temporal_verdicts from public,anon,authenticated,service_role;
grant select on public.property_video_job_temporal_verdicts to service_role;

-- A recorded verdict is immutable, even for a privileged direct write.
create or replace function public.property_video_temporal_verdict_guard()returns trigger
language plpgsql security definer set search_path=''as $$begin
 raise exception'RP409: A recorded temporal verdict is immutable';
end$$;
do $own_trigger$begin
 if not exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.property_video_job_temporal_verdicts'::regclass and tgname='property_video_temporal_verdict_guard'and not tgisinternal)then
  create trigger property_video_temporal_verdict_guard before update on public.property_video_job_temporal_verdicts for each row execute function public.property_video_temporal_verdict_guard();
 end if;
end$own_trigger$;

-- Worker callback: the CPU's closed report for THIS retained clip under THIS
-- live review lease. The first measurement of an attempt under a limit version
-- stands and is returned on every repeat (a re-extract after a lapsed lease must
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
 select v.record into rec from public.property_video_job_temporal_verdicts v where v.job_id=p_job and v.position=s.position and v.attempt_id=p_attempt and v.limits_sha256=p_report#>>'{limits,sha256}';
 if rec is not null then return rec;end if;
 rec:=p_report||jsonb_build_object('attempt_id',p_attempt,'clip_sha256',p_clip_sha256,'recorded_at',now());
 insert into public.property_video_job_temporal_verdicts(job_id,position,attempt_id,limits_sha256,record,recorded_at)values(p_job,s.position,p_attempt,p_report#>>'{limits,sha256}',rec,now());
 return rec;end$$;
revoke all on function public.property_video_temporal_verdict_guard(),public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.property_video_temporal_verdict_guard(),public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)to service_role;
commit;
