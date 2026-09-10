-- ISOLATED DATABASE ONLY. Root's run_database_regression.py creates this exact
-- socket-only cluster. Every fixture/schema change below is rolled back.
\set ON_ERROR_STOP on
do $$ begin
  if current_database() <> 'rendprop_audit' or current_setting('listen_addresses') <> ''
     or current_setting('data_directory') !~ '^/tmp/rendprop-db-audit-[^/]+/cluster$' then
    raise exception 'worker publication fixture refuses any non-disposable database';
  end if;
end $$;
begin;
create temp table _wp_checks(name text primary key, pass boolean not null check(pass));
create temp table _wp_inputs(n int primary key, job uuid, payload jsonb, outcome jsonb, photos jsonb);
grant select, insert on _wp_checks to service_role, anon, authenticated;
grant select on _wp_inputs to service_role, anon, authenticated;
create function pg_temp.wp_assert(p_pass boolean, p_name text) returns void language plpgsql as $$
begin
  if p_pass is distinct from true then raise exception 'worker publish assertion failed: %', p_name; end if;
  insert into _wp_checks values(p_name, true);
end $$;

do $$
declare
  v_user uuid := 'a0350000-0000-0000-0000-000000000001';
  v_org uuid;
  v_listing uuid;
  v_asset uuid;
  v_job uuid;
  v_render uuid;
  v_prefix text;
begin
  insert into auth.users(id,email,raw_user_meta_data)
  values(v_user,'worker-publish-fixture@example.invalid','{}');
  select org_id into strict v_org from public.memberships where user_id=v_user;
  for n in 1..9 loop
    v_listing := ('a0351000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid;
    v_asset := ('a0352000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid;
    v_job := ('a0353000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid;
    v_render := ('a0354000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid;
    v_prefix := 'renders/' || v_listing::text || '/' || v_render::text;
    insert into public.listings(id,org_id,agent_id,status) values(v_listing,v_org,v_user,'draft');
    insert into public.capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,bytes)
    values(v_asset,v_listing,'video','uploads/fixture.mov','uploads',true,1);
    insert into public.render_jobs(id,listing_id,capture_asset_id,source,status,worker_id,attempts,lease_expires_at)
    values(v_job,v_listing,v_asset,'worker','processing','worker-B',2,clock_timestamp()+interval '10 minutes');
    insert into _wp_inputs values(n,v_job,jsonb_build_object('id',v_render,'slug','worker-fixture-'||n,
      'duration_s',30,'speed_factor',2,'video_key',v_prefix||'.mp4','poster_key',v_prefix||'-poster.jpg',
      'stream_uid',null,'hero_key',null),'{"ran":true,"staged":true}',
      jsonb_build_array(jsonb_build_object('listing_id',v_listing,'enhanced_key',v_prefix||'-staged-0.jpg',
        'original_key',null,'is_staged',true,'caption','Fixture','sort',0)));
  end loop;
end $$;

create function pg_temp.wp_call(p_n int, p_worker text default 'worker-B', p_attempt int default 2,
  p_render_patch jsonb default '{}', p_photo_patch jsonb default null)
returns jsonb language plpgsql as $$
declare v _wp_inputs;
begin
  select * into strict v from _wp_inputs where n=p_n;
  return public.publish_worker_render(v.job,p_worker,p_attempt,v.payload||p_render_patch,v.outcome,
    case when p_photo_patch is null then v.photos else jsonb_build_array(v.photos->0 || p_photo_patch) end);
end $$;

grant execute on function pg_temp.wp_call(int,text,int,jsonb,jsonb), pg_temp.wp_assert(boolean,text)
  to service_role, anon, authenticated;
do $$ declare v_schema text; begin
  select nspname into v_schema from pg_namespace where oid=pg_my_temp_schema();
  execute format('grant usage on schema %I to service_role, anon, authenticated',v_schema);
end $$;

-- Explicit role enforcement, not just printed ACLs. postgres also lacks the
-- current_user guard, representing a caller with no service-role claim.
do $$ begin
  begin
    perform pg_temp.wp_call(1);
    raise exception 'unguarded postgres caller was accepted';
  exception when insufficient_privilege then null; end;
  perform pg_temp.wp_assert(true,'no service-role identity is rejected');
  perform pg_temp.wp_assert(
    not has_function_privilege('anon','public.publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)','execute')
    and not has_function_privilege('authenticated','public.publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)','execute')
    and has_function_privilege('service_role','public.publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)','execute'),
    'exact role grants');
end $$;
set local role anon;
do $$ begin
  begin perform pg_temp.wp_call(1); raise exception 'anon accepted';
  exception when insufficient_privilege then null; end;
  perform pg_temp.wp_assert(true,'anon cannot execute');
end $$;
reset role;
set local role authenticated;
do $$ begin
  begin perform pg_temp.wp_call(1); raise exception 'authenticated accepted';
  exception when insufficient_privilege then null; end;
  perform pg_temp.wp_assert(true,'authenticated cannot execute');
end $$;
reset role;
set local role service_role;

do $$
declare first_result jsonb; replay_result jsonb; v_job uuid; before_job jsonb;
begin
  select job into v_job from _wp_inputs where n=1;
  select to_jsonb(j) into before_job from public.render_jobs j where id=v_job;
  begin perform pg_temp.wp_call(1,'worker-A',1); raise exception 'stale A accepted';
  exception when sqlstate 'WP001' then null; end;
  perform pg_temp.wp_assert((select to_jsonb(j)=before_job from public.render_jobs j where id=v_job)
    and not exists(select 1 from public.renders where job_id=v_job),'late A cannot publish while B owns claim');
  first_result := pg_temp.wp_call(1);
  perform pg_temp.wp_assert(first_result->>'status'='ready' and first_result->>'job_id'=v_job::text
    and first_result->'receipt'->'render'=first_result->'render','successful publication returns bound receipt');
  perform pg_temp.wp_assert((select j.status='ready' and j.progress=1 and j.current_step='ready'
    and j.finished_at is not null and j.error is null and j.enhancement_result='{"ran":true,"staged":true}'::jsonb
    and j.worker_publish_receipt=first_result->'receipt' and l.status='ready'
    from public.render_jobs j join public.listings l on l.id=j.listing_id where j.id=v_job),
    'render outcome listing and job readiness commit together');
  perform pg_temp.wp_assert((select count(*)=1 from public.photos p join public.render_jobs j
    on j.listing_id=p.listing_id where j.id=v_job),'enhancement photo committed once');
  update public.render_jobs set lease_expires_at=clock_timestamp()-interval '1 second' where id=v_job;
  replay_result := pg_temp.wp_call(1);
  perform pg_temp.wp_assert(replay_result=first_result and (select count(*)=1 from public.renders where job_id=v_job)
    and (select count(*)=1 from public.photos p join public.render_jobs j on j.listing_id=p.listing_id where j.id=v_job),
    'exact committed replay survives old lease expiry without duplicate photos');
  begin perform pg_temp.wp_call(1,'worker-B',2,'{"stream_uid":"changed"}'); raise exception 'changed replay accepted';
  exception when sqlstate 'WP002' then null; end;
  perform pg_temp.wp_assert((select stream_uid is null from public.renders where job_id=v_job),
    'changed-payload ready retry cannot replace output');
  begin perform pg_temp.wp_call(1,'worker-A',1); raise exception 'late A replaced B winner';
  exception when sqlstate 'WP001' then null; end;
  perform pg_temp.wp_assert((select to_jsonb(r)=first_result->'render' from public.renders r where job_id=v_job),
    'late A cannot replace B committed winner');
end $$;

-- Existing pre-0035 partial render: current owner can finish it, keeping its URL.
do $$
declare v _wp_inputs; result jsonb; old_id uuid := 'a0355000-0000-0000-0000-000000000002';
begin
  select * into v from _wp_inputs where n=2;
  insert into public.renders(id,job_id,listing_id,slug,duration_s,video_key)
  select old_id,v.job,j.listing_id,'kept-old-slug',30,'old-worker-output.mp4' from public.render_jobs j where j.id=v.job;
  result := pg_temp.wp_call(2);
  perform pg_temp.wp_assert(result->'render'->>'id'=old_id::text and result->'render'->>'slug'='kept-old-slug'
    and result->'render'->>'video_key'=v.payload->>'video_key','fenced legacy partial replacement keeps id and slug');
end $$;

do $$
declare v_job uuid; v_status text;
begin
  select job into v_job from _wp_inputs where n=3;
  begin perform pg_temp.wp_call(3,'worker-B',1); raise exception 'same worker stale attempt accepted';
  exception when sqlstate 'WP001' then null; end;
  perform pg_temp.wp_assert(not exists(select 1 from public.renders where job_id=v_job),
    'same worker id cannot publish an older attempt');
  update public.render_jobs set lease_expires_at=clock_timestamp()-interval '1 second' where id=v_job;
  begin perform pg_temp.wp_call(3); raise exception 'expired lease accepted';
  exception when sqlstate 'WP001' then null; end;
  perform pg_temp.wp_assert(not exists(select 1 from public.renders where job_id=v_job),'expired lease cannot publish');
  select job into v_job from _wp_inputs where n=4;
  update public.render_jobs set source='app' where id=v_job;
  begin perform pg_temp.wp_call(4); raise exception 'app job accepted';
  exception when sqlstate 'WP001' then null; end;
  perform pg_temp.wp_assert(not exists(select 1 from public.renders where job_id=v_job),'app source cannot publish through worker RPC');
  select job into v_job from _wp_inputs where n=5;
  update public.listings set deleted_at=clock_timestamp() where id=(select listing_id from public.render_jobs where id=v_job);
  begin perform pg_temp.wp_call(5); raise exception 'deleted listing published';
  exception when sqlstate 'WP001' then null; end;
  perform pg_temp.wp_assert(not exists(select 1 from public.renders where job_id=v_job),'soft-deleted listing cannot be revived');
  select job into v_job from _wp_inputs where n=6;
  begin perform pg_temp.wp_call(6,'worker-B',2,'{}','{"sort":40000}'); raise exception 'invalid photo insert succeeded';
  exception when numeric_value_out_of_range then null; end;
  perform pg_temp.wp_assert(not exists(select 1 from public.renders where job_id=v_job)
    and not exists(select 1 from public.photos p join public.render_jobs j on j.listing_id=p.listing_id where j.id=v_job)
    and (select j.status='processing' and j.enhancement_result is null and j.worker_publish_receipt is null
      and l.status='draft' from public.render_jobs j join public.listings l on l.id=j.listing_id where j.id=v_job),
    'photo write failure rolls back render outcome photos listing and job');
end $$;
reset role;

-- Force failures AFTER earlier writes, proving actual SQL rollback, not a mock.
create function pg_temp.wp_fail_job_write() returns trigger language plpgsql as $$
begin
  if new.id='a0353000-0000-0000-0000-000000000007'::uuid and new.status='ready' then
    raise exception using errcode='WP099', message='deliberate fixture job write failure';
  end if;
  if new.id='a0353000-0000-0000-0000-000000000009'::uuid and new.status='ready' then
    perform pg_sleep(0.1);
  end if;
  return new;
end $$;
create trigger wp_fail_job_write before update on public.render_jobs
for each row execute function pg_temp.wp_fail_job_write();
create function pg_temp.wp_delay_render() returns trigger language plpgsql as $$
begin
  if new.job_id='a0353000-0000-0000-0000-000000000008'::uuid then perform pg_sleep(0.1); end if;
  return new;
end $$;
create trigger wp_delay_render before insert on public.renders
for each row execute function pg_temp.wp_delay_render();
set local role service_role;
do $$
declare v_job uuid;
begin
  select job into v_job from _wp_inputs where n=7;
  begin perform pg_temp.wp_call(7); raise exception 'deliberate job write failure did not fail';
  exception when sqlstate 'WP099' then null; end;
  perform pg_temp.wp_assert(not exists(select 1 from public.renders where job_id=v_job)
    and not exists(select 1 from public.photos p join public.render_jobs j on j.listing_id=p.listing_id where j.id=v_job)
    and (select j.status='processing' and j.enhancement_result is null and j.worker_publish_receipt is null
      and l.status='draft' from public.render_jobs j join public.listings l on l.id=j.listing_id where j.id=v_job),
    'final job write failure rolls back all earlier writes');
  select job into v_job from _wp_inputs where n=8;
  update public.render_jobs set lease_expires_at=clock_timestamp()+interval '50 milliseconds' where id=v_job;
  begin perform pg_temp.wp_call(8); raise exception 'lease expiry during write was ignored';
  exception when sqlstate 'WP001' then null; end;
  perform pg_temp.wp_assert(not exists(select 1 from public.renders where job_id=v_job)
    and not exists(select 1 from public.photos p join public.render_jobs j on j.listing_id=p.listing_id where j.id=v_job),
    'database clock expiry during transaction rolls back media rows');
  select job into v_job from _wp_inputs where n=9;
  update public.render_jobs set lease_expires_at=clock_timestamp()+interval '50 milliseconds' where id=v_job;
  begin perform pg_temp.wp_call(9); raise exception 'lease expiry during final job write was ignored';
  exception when sqlstate 'WP001' then null; end;
  perform pg_temp.wp_assert(not exists(select 1 from public.renders where job_id=v_job)
    and not exists(select 1 from public.photos p join public.render_jobs j on j.listing_id=p.listing_id where j.id=v_job)
    and (select j.status='processing' and j.enhancement_result is null and j.worker_publish_receipt is null
      and l.status='draft' from public.render_jobs j join public.listings l on l.id=j.listing_id where j.id=v_job),
    'expiry during final job write rolls back receipt ready state and all media');
end $$;
reset role;
select * from _wp_checks order by name;
do $$ begin
  if (select count(*) from _wp_checks) <> 20 then raise exception 'expected exactly 20 publication checks'; end if;
end $$;
rollback;
\echo WORKER_PUBLISH_TRANSACTION_PASS_20
