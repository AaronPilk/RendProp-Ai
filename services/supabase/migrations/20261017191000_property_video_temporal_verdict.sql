-- Temporal motion verdict (CPU profile temporal-motion-v2) recorded per steady
-- profile shot BEFORE the paid drift judge decides (property-video-worker/temporal.ts).
-- Additive only: one nullable column, one append-only history, one service-only
-- RPC and its guard. No price, grant, profile, selector or paid-retry change; the
-- single paid quality retry (20261015040518) keeps its drift-only grant.
begin;
do $pin$begin
 if to_regclass('public.property_video_job_sources')is null or to_regprocedure('public.property_video_job_worker_scope(uuid,uuid,uuid)')is null then raise exception'Temporal verdicts need the background property-video schema';end if;
end$pin$;
alter table public.property_video_job_sources add column if not exists temporal jsonb check(temporal is null or jsonb_typeof(temporal)='object');
alter table public.property_video_job_sources add column if not exists temporal_history jsonb not null default'[]'::jsonb check(jsonb_typeof(temporal_history)='array');

-- A recorded verdict is immutable. The current record may only be replaced by
-- archiving it unchanged (a superseded attempt, or a new limit version for the
-- same clip); prior archive entries never change.
create or replace function public.property_video_temporal_guard()returns trigger
language plpgsql security definer set search_path=''as $$declare i integer;begin
 if new.temporal is not distinct from old.temporal and new.temporal_history is not distinct from old.temporal_history then return new;end if;
 if old.temporal is null then
  if new.temporal_history is distinct from old.temporal_history then raise exception'RP409: Temporal history is append-only';end if;return new;end if;
 if new.temporal is null or jsonb_array_length(new.temporal_history)<>jsonb_array_length(old.temporal_history)+1 or new.temporal_history->-1 is distinct from old.temporal then raise exception'RP409: A recorded temporal verdict is immutable';end if;
 for i in 0..jsonb_array_length(old.temporal_history)-1 loop if new.temporal_history->i is distinct from old.temporal_history->i then raise exception'RP409: Prior temporal verdicts are immutable';end if;end loop;
 return new;end$$;
drop trigger if exists property_video_temporal_guard on public.property_video_job_sources;
create trigger property_video_temporal_guard before update of temporal,temporal_history on public.property_video_job_sources for each row execute function public.property_video_temporal_guard();

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
