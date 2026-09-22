-- Actual transactional deletion/spatial/upload RPCs; synthetic rows only.
\set ON_ERROR_STOP on
do $$ begin
  if current_database()<>'rendprop_deletion_audit' or current_setting('listen_addresses')<>'' or
    current_setting('data_directory') !~ '^/tmp/rendprop-deletion-db-[^/]+/cluster$' then raise exception 'unsafe deletion fixture'; end if;
end $$;
begin;
create temp table _checks(name text primary key,pass boolean not null check(pass));
create temp table _fixture(n integer primary key,s uuid,o uuid,l uuid,j uuid,a uuid,lease uuid,receipt jsonb);
create function pg_temp.a(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'spatial deletion assertion failed: %',label; end if;
  insert into _checks values(label,true);
end $$;
create function pg_temp.denied(command text,expected text,label text) returns void language plpgsql as $$ begin
  begin execute command; raise exception 'fixture accepted forbidden operation';
  exception when others then if sqlerrm not like expected then raise exception 'wrong failure for %: %',label,sqlerrm; end if; end;
  perform pg_temp.a(true,label);
end $$;
do $$ declare s uuid;o uuid;l uuid;j uuid;a uuid;lease uuid;rev uuid; begin
  for n in 1..6 loop
    s:=('b0390000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    l:=('b0391000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    j:=('b0392000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    a:=('b0393000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    lease:=('b0394000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    rev:=('b0395000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    insert into auth.users(id,email,raw_user_meta_data) values(s,'spatial-deletion-'||n||'@fixture.invalid','{}');
    select org_id into strict o from public.memberships where user_id=s;
    insert into public.listings(id,org_id,agent_id) values(l,o,s);
    insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes,transport_version,content_type)
      values(a,l,'photo','uploads','uploads/'||o||'/'||l||'/'||a||'.jpg',true,1,2,'image/jpeg');
    insert into public.spatial_jobs(id,org_id,listing_id,actor_id,capture_id,idem_key,room_label,capture_manifest,
      status,attempt_key,lease_token,deadline_at,artifact_revision,output_key,output_state,approved,review_revision,published_at)
    values(j,o,l,s,gen_random_uuid(),gen_random_uuid(),'Fixture room','{"frames":["frames/000000.json"]}',
      'ready',gen_random_uuid(),lease,clock_timestamp()-interval '2 hours',rev,
      'spatial/'||o||'/'||l||'/'||j||'/'||rev||'/model.sog','stored',true,rev,clock_timestamp());
    insert into public.spatial_inputs(job_id,relative_path,ticket_id,storage_key,bytes,frame)
      values(j,'images/000000.jpg',a,'uploads/'||o||'/'||l||'/'||a||'.jpg',1,
        '{"image":"images/000000.jpg","pose":"synthetic-sidecar-marker","raw_feature_points":[[1,2,3]]}');
    insert into _fixture values(n,s,o,l,j,a,lease,null);
  end loop;
end $$;
create function pg_temp.prepare(n integer) returns jsonb language sql as $$
  select public.prepare_account_deletion(s,'fixture-uploads','fixture-renders') from _fixture where _fixture.n=$1
$$;
-- One sweeper pass that removes nothing: reclaim, then hand back the whole
-- leased payload unchanged.
create function pg_temp.sweep(n integer) returns jsonb language plpgsql as $$
declare request uuid; claimed jsonb; begin
  select (receipt->>'request_id')::uuid into strict request from _fixture where _fixture.n=sweep.n;
  claimed:=public.claim_account_deletion(request);
  if claimed->>'ok' is distinct from 'true' then return claimed; end if;
  return public.finish_account_deletion(request,(claimed->>'lease_token')::uuid,claimed->'payload','sweep: nothing removed');
end $$;
grant select,insert on _checks to service_role;
grant select,update on _fixture to service_role;
do $$ declare ns text; begin select nspname into ns from pg_namespace where oid=pg_my_temp_schema();
  execute format('grant usage on schema %I to service_role',ns); end $$;
grant execute on function pg_temp.a(boolean,text),pg_temp.denied(text,text,text),pg_temp.prepare(integer),pg_temp.sweep(integer) to service_role;

-- A previous failed copy is still personal data, even when never published.
insert into public.spatial_attempt_history(job_id,attempt_key,attempt_number,snapshot)
  select scene.id,'b0396000-0000-4000-8000-000000000001',1,to_jsonb(scene)||jsonb_build_object(
    'lease_token','b0397000-0000-4000-8000-000000000001','artifact_revision','b0398000-0000-4000-8000-000000000001',
    'output_key','spatial/'||scene.org_id||'/'||scene.listing_id||'/'||scene.id||'/b0398000-0000-4000-8000-000000000001/model.sog',
    'output_state','dispatching','capture_manifest',jsonb_build_object('private_marker','history-room-data'))
  from public.spatial_jobs scene join _fixture f on f.j=scene.id where f.n=1;
-- The first destructive sidecar operation MUST already have both models and
-- both GPU identities inventoried, and the scene must already be unshared.
create function pg_temp.before_spatial_delete() returns trigger language plpgsql as $$ begin
  if not exists(select 1 from public.deletion_requests d join public.spatial_jobs j on j.id=old.job_id
    where d.user_id=j.actor_id and d.snapshot_version=2 and not j.approved and j.published_at is null and
    jsonb_array_length(d.payload->'provider_leases')>=1) then raise exception 'spatial intent/revocation missing'; end if;
  return old;
end $$;
create trigger before_spatial_delete before delete on public.spatial_inputs for each row execute function pg_temp.before_spatial_delete();
set local role service_role;
update _fixture set receipt=pg_temp.prepare(1) where n=1;
select pg_temp.a((select jsonb_array_length(receipt->'payload'->'r2')=3 from _fixture where n=1),'input current and historical output all inventoried');
select pg_temp.a((select jsonb_array_length(receipt->'payload'->'provider_leases')=2 from _fixture where n=1),'current and historical provider leases all inventoried');
select pg_temp.a(not public.account_deletion_provider_ready((select j from _fixture where n=1),(select lease from _fixture where n=1)),
  'missing provider proof is not cleanup success');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,
  jsonb_set(receipt->''payload'',''{provider_leases}'',''[]''),'''') from _fixture where n=1','RP409: provider cleanup%',
  'Edge cannot erase unconfirmed provider targets');
reset role;
select pg_temp.a((select not exists(select 1 from public.spatial_jobs where id=f.j) and
  not exists(select 1 from public.spatial_inputs where job_id=f.j) and not exists(select 1 from public.spatial_attempt_history where job_id=f.j)
  from _fixture f where n=1),'all spatial rows including pose sidecars and history purged');
select pg_temp.a((select receipt->'payload'::text is not null and receipt::text not like '%synthetic-sidecar-marker%'
  and receipt::text not like '%history-room-data%' from _fixture where n=1),'tombstone retains targets not room metadata');
set local role service_role;
select pg_temp.denied('select public.spatial_start(s,j) from _fixture where n=1','RP403:%','deleted capture cannot be restarted');
reset role;

-- Shared-team rooms belong to the surviving workspace, not the departing seat.
insert into public.memberships(org_id,user_id,role) select f.o,g.s,'admin' from _fixture f cross join _fixture g where f.n=2 and g.n=6;
set local role service_role;
update _fixture set receipt=pg_temp.prepare(2) where n=2;
reset role;
select pg_temp.a((select j.actor_id=g.s and j.approved and j.published_at is not null from _fixture f
  join public.spatial_jobs j on j.id=f.j cross join _fixture g where f.n=2 and g.n=6),'shared room preserved and attribution follows surviving teammate');
select pg_temp.a((select receipt->'payload'->'provider_leases'='[]' and receipt->'payload'->'r2'='[]' from _fixture where n=2),
  'shared provider and storage identities excluded');

-- History is validated against parent ownership, not trusted just for being JSON.
insert into public.spatial_attempt_history(job_id,attempt_key,attempt_number,snapshot)
  select scene.id,gen_random_uuid(),1,to_jsonb(scene)||'{"output_key":"spatial/foreign/model.sog"}'
  from public.spatial_jobs scene join _fixture f on f.j=scene.id where n=3;
set local role service_role;
select pg_temp.denied('select pg_temp.prepare(3)','RP409: unverified media ownership%',
  'foreign historical model aborts before destruction');
reset role;
select pg_temp.a((select j.approved and j.published_at is not null and
  exists(select 1 from public.spatial_inputs where job_id=j.id) and
  not exists(select 1 from public.deletion_requests where user_id=f.s)
  from _fixture f join public.spatial_jobs j on j.id=f.j where n=3),'enumeration failure preserves room and no intent is committed');
update public.spatial_attempt_history set snapshot='[]' where job_id=(select j from _fixture where n=3);
set local role service_role;
select pg_temp.denied('select pg_temp.prepare(3)','RP409: invalid spatial attempt history%',
  'malformed history cannot masquerade as an empty target list');
reset role;
select pg_temp.a((select exists(select 1 from public.spatial_inputs where job_id=f.j) and
  not exists(select 1 from public.deletion_requests where user_id=f.s) from _fixture f where n=3),
  'malformed history abort preserves every sidecar');

-- Active uploads can finish writing after the DB transaction. Every journaled
-- object/session survives in the intent until its write window drains.
insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes)
  select a,o,l,s,current_date,'{}',0 from _fixture where n=4;
insert into public.upload_operations(id,asset_id,kind,bucket,object_key,upload_id,bytes,expected_bytes,content_type,
  content_type_declared,asset_kind,state,write_deadline)
  select 'b0399000-0000-4000-8000-000000000004',a,'init','uploads','uploads/'||o||'/'||l||'/'||a||'.jpg',
    'synthetic-upload-id',0,1,'image/jpeg',true,'photo','stored',clock_timestamp()+interval '1 hour' from _fixture where n=4;
update public.spatial_jobs set status='processing',deadline_at=clock_timestamp()+interval '2 hours' where id=(select j from _fixture where n=4);
set local role service_role;
update _fixture set receipt=pg_temp.prepare(4) where n=4;
select pg_temp.a((select jsonb_array_length(receipt->'payload'->'multipart_uploads')=1 from _fixture where n=4),'multipart identity preserved before journal purge');
select pg_temp.a((select (receipt->'payload'->>'storage_not_before')::timestamptz>clock_timestamp()+interval '2 hours' from _fixture where n=4),'last GPU write deadline bounds object cleanup');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,
  jsonb_set(receipt->''payload'',''{r2}'',''[]''),'''') from _fixture where n=4','RP409: storage writes have not drained','early object-delete success rejected');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,
  jsonb_set(receipt->''payload'',''{storage_not_before}'',''null''),'''') from _fixture where n=4','RP409: storage writes have not drained','deadline cannot be bypassed by null');
-- Passes that only wait for that window are not stalled sweeps: however many
-- run before the deadline, the request stays automated and uncounted.
select pg_temp.a((select (public.finish_account_deletion((receipt->>'request_id')::uuid,(receipt->>'lease_token')::uuid,receipt->'payload','waiting')
    ->>'stalled_sweeps')::int=0 from _fixture where n=4)
  and (select bool_and((s->>'stalled_sweeps')::int=0 and not (s->>'manual_review_required')::boolean and s->'escalation_reason'='null'::jsonb)
    from (select pg_temp.sweep(4) s from generate_series(1,13)) x),'waiting for a storage write window is never a stalled sweep');
reset role;
select pg_temp.a((select not exists(select 1 from public.upload_reservations where asset_id=f.a) and
  not exists(select 1 from public.upload_operations where asset_id=f.a) from _fixture f where n=4),'obsolete upload journals purged only after identities preserved');

-- CREATE ambiguity retains the only known immutable key for manual provider
-- listing/reconciliation. A sweep has no authority to guess an upload ID.
insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes)
  select a,o,l,s,current_date,'{}',0 from _fixture where n=5;
insert into public.upload_operations(id,asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,
  content_type_declared,asset_kind,state,write_deadline)
  select 'b0399000-0000-4000-8000-000000000005',a,'init','uploads','uploads/'||o||'/'||l||'/'||a||'.jpg',
    0,1,'image/jpeg',true,'photo','uncertain',clock_timestamp() from _fixture where n=5;
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes,transport_version)
  select 'b039a000-0000-4000-8000-000000000005',l,'video','uploads','uploads/'||o||'/'||l||'/worker.mov',true,1,2 from _fixture where n=5;
insert into public.render_jobs(id,listing_id,capture_asset_id,source,status)
  select 'b039b000-0000-4000-8000-000000000005',l,'b039a000-0000-4000-8000-000000000005','worker','processing' from _fixture where n=5;
set local role service_role;
update _fixture set receipt=pg_temp.prepare(5) where n=5;
select pg_temp.a((select jsonb_array_length(receipt->'payload'->'unresolved_uploads')=1 from _fixture where n=5),'ambiguous allocation remains explicitly queued');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,
  jsonb_set(receipt->''payload'',''{unresolved_uploads}'',''[]''),'''') from _fixture where n=5','RP409: ambiguous multipart allocation%',
  'ambiguous allocation cannot be reported removed');
select pg_temp.a((select receipt->'payload'->'unresolved_render_jobs'='["b039b000-0000-4000-8000-000000000005"]' from _fixture where n=5),
  'legacy active worker remains assisted-pending');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,
  jsonb_set(receipt->''payload'',''{unresolved_render_jobs}'',''[]''),'''') from _fixture where n=5','RP409: legacy render worker cleanup%',
  'legacy worker data cannot be falsely marked removed');
reset role;
-- Legacy completed single PUT still has a reusable staging URL. Recover its
-- canonical staging identity from its unique completion key and wait expiry.
update public.capture_assets set transport_version=1 where id=(select a from _fixture where n=6);
set local role service_role;
update _fixture set receipt=pg_temp.prepare(6) where n=6;
select pg_temp.a((select exists(select 1 from jsonb_array_elements(receipt->'payload'->'r2') t
  where starts_with(t->>'key','_staging/uploads/'||o||'/'||l||'/')) from _fixture where n=6),'legacy staging key is retained');
select pg_temp.a((select (receipt->'payload'->>'storage_not_before')::timestamptz>clock_timestamp()+interval '74 minutes' from _fixture where n=6),
  'legacy staging URL cannot recreate data after cleanup is reported');
reset role;

-- Optional 0041 is not needed to apply0039. Its later journal contract is
-- modelled exactly here if absent; this tests the real dynamic SQL reader.
create table if not exists public.spatial_provider_attempts(
  lease_token uuid primary key,job_id uuid not null,attempt_key uuid not null,app_name text,sandbox_name text,sandbox_id text,
  allocation_state text,files_removed boolean not null default false,terminated boolean not null default false,
  deadline_at timestamptz,source_sha256 text,reason_code text,exit_code integer,last_error_code text
);
insert into public.spatial_provider_attempts(lease_token,job_id,attempt_key,app_name,sandbox_name,sandbox_id,source_sha256,allocation_state,deadline_at,files_removed,terminated)
  -- 0041 names the sandbox after the lease alone (Modal caps names at 64
  -- chars; the old job+lease form was 81 and could never allocate). The
  -- fixture must satisfy the real check constraint when 0041 is present.
  select lease,j,gen_random_uuid(),'rendprop-spatial-worker','spatial-'||lease,'sb-fixture00000001',repeat('a',64),'created',clock_timestamp(),false,true from _fixture where n=1;
set local role service_role;
select pg_temp.a(not public.account_deletion_provider_ready((select j from _fixture where n=1),(select lease from _fixture where n=1)),
  'termination alone does not prove private-file removal');
reset role;
-- With the sibling0041 migration installed, exercise its ACTUAL cleanup RPC
-- after0039 removed the account's spatial parent. The stand-in path is only
-- for proving0039's optional-table/fresh-install behavior by itself.
grant select,update on public.spatial_provider_attempts to service_role;
create function pg_temp.confirm_provider_files() returns void language plpgsql as $$
declare row public.spatial_provider_attempts; begin
  select * into strict row from public.spatial_provider_attempts where lease_token=(select lease from _fixture where n=1);
  if to_regprocedure('public.spatial_provider_attempt_update(uuid,uuid,uuid,text,jsonb)') is not null then
    perform public.spatial_provider_attempt_update(row.job_id,row.lease_token,row.attempt_key,'cleanup','{"files_removed":true}');
  else update public.spatial_provider_attempts set files_removed=true where lease_token=row.lease_token; end if;
end $$;
set local role service_role;
select pg_temp.confirm_provider_files();
select pg_temp.a(public.account_deletion_provider_ready((select j from _fixture where n=1),(select lease from _fixture where n=1)),
  'durable removed plus terminated proof can drain deleted-parent lease');
select pg_temp.a(not public.account_deletion_provider_ready((select j from _fixture where n=3),(select lease from _fixture where n=1)),
  'foreign job cannot borrow another lease cleanup proof');
select pg_temp.a((select not (public.finish_account_deletion((receipt->>'request_id')::uuid,(receipt->>'lease_token')::uuid,
  jsonb_set(receipt->'payload','{provider_leases}',jsonb_build_array(jsonb_build_object('job_id',j,
  'lease_token','b0397000-0000-4000-8000-000000000001'))),'')->>'cleanup_complete')::boolean from _fixture where n=1),
  'confirmed current lease drains while unresolved historical lease remains');
reset role;
select pg_temp.a((select next_cleanup_at>clock_timestamp()+interval '4 minutes' and status='pending' and cleanup_token is null
  from public.deletion_requests where user_id=(select s from _fixture where n=1)),
  'pending provider backoff does not monopolize due queue');
select pg_temp.a((select not manual_review_required and escalation_reason is null and stalled_sweeps=0
  from public.deletion_requests where user_id=(select s from _fixture where n=1)),'unjournaled lease younger than a day stays automated');
-- The historical lease has no journal row and its job is gone: nobody will
-- ever confirm it. A day after the request the sweeper hands it to a person,
-- naming the lease, and keeps the target in the payload.
update public.deletion_requests set requested_at=clock_timestamp()-interval '25 hours' where user_id=(select s from _fixture where n=1);
set local role service_role;
select pg_temp.a((select (s->>'manual_review_required')::boolean and s->>'cleanup_complete'='false'
  and s->>'escalation_reason' like 'provider lease without a cleanup journal 24 hours after the request%'
  and s->>'escalation_reason' like '%lease b0397000-0000-4000-8000-000000000001%' and (s->>'stalled_sweeps')::int=1 from pg_temp.sweep(1) s),
  'unjournaled provider lease escalates after a day with the lease named');
reset role;
select pg_temp.a((select d.manual_review_required and d.status='pending' and d.escalated_at is not null
  and d.payload->'provider_leases'=jsonb_build_array(jsonb_build_object('job_id',f.j,'lease_token','b0397000-0000-4000-8000-000000000001'))
  from public.deletion_requests d join _fixture f on d.user_id=f.s where f.n=1),'escalated lease is retained, not erased');
-- Without any provider journal installed (0041 absent) the same day-old lease
-- is escalated instead of being polled forever. The drop rolls back below.
drop table public.spatial_provider_attempts cascade;
update public.deletion_requests set requested_at=clock_timestamp()-interval '25 hours' where user_id=(select s from _fixture where n=6);
set local role service_role;
select pg_temp.a((select (res->>'manual_review_required')::boolean and res->>'escalation_reason' like 'provider lease without a cleanup journal%'
  and res->>'escalation_reason' like ('%job '||f.j||' lease '||f.lease||'%')
  from _fixture f,public.finish_account_deletion((f.receipt->>'request_id')::uuid,(f.receipt->>'lease_token')::uuid,f.receipt->'payload','') res where f.n=6),
  'missing provider journal table escalates a day-old lease instead of polling forever');
reset role;
select pg_temp.a((select count(*)=34 from _checks),'exact spatial assertion count');
select 'PASS: 35 spatial deletion SQL assertions; all fixtures rolled back.';
rollback;
