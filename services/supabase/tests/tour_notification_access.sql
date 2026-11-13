-- Owned clean/replayed audit clusters only. No provider or scheduler calls.
\set ON_ERROR_STOP on
begin;
do $$begin
 if current_database() not in ('rendprop_audit','rendprop_replay') or inet_server_addr() is not null
    or current_setting('data_directory') !~ '^/tmp/rendprop-db-audit-[^/]+/cluster$' then
  raise exception 'Tour notification fixture requires the owned socket-only audit cluster';
 end if;
end$$;
create temp table tn_checks(name text primary key);
create function pg_temp.tn_ok(value boolean, label text) returns void language plpgsql as $$begin
 if value is distinct from true then raise exception 'TOUR NOTIFICATION FAIL: %',label;end if;
 insert into tn_checks values(label);
end$$;
select pg_temp.tn_ok((select md5(prosrc)='31df14b830c092d0b22ea1f8bf94f4c7' from pg_proc
 where oid='public.publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)'::regprocedure),'current worker body is pinned');
select pg_temp.tn_ok((select not prosecdef and proconfig=array['search_path=""']::text[]
 and proacl::text='{postgres=X/postgres,service_role=X/postgres}' from pg_proc
 where oid='public.publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)'::regprocedure),'worker security and grants preserved');
select pg_temp.tn_ok(not has_function_privilege('anon','public.tour_notification_current(uuid,jsonb)','execute')
 and not has_function_privilege('authenticated','public.tour_notification_current(uuid,jsonb)','execute')
 and has_function_privilege('service_role','public.tour_notification_current(uuid,jsonb)','execute')
 and (select prosecdef and proconfig=array['search_path=""']::text[] from pg_proc
 where oid='public.tour_notification_current(uuid,jsonb)'::regprocedure),'tour scope is service-only with empty search path');

insert into auth.users(id,email,is_anonymous,email_confirmed_at) values
 ('e0170000-0000-4000-8000-000000000001','tour-team-owner@fixture.invalid',false,now()),
 ('e0170000-0000-4000-8000-000000000002','tour-agent@fixture.invalid',false,now()),
 ('e0170000-0000-4000-8000-000000000003','tour-sibling-admin@fixture.invalid',false,now()),
 ('e0170000-0000-4000-8000-000000000004','tour-shared-owner@fixture.invalid',false,now()),
 ('e0170000-0000-4000-8000-000000000005','tour-shared-admin@fixture.invalid',false,now()),
 ('e0170000-0000-4000-8000-000000000006','tour-personal-owner@fixture.invalid',false,now());
create temp table tn_actors as select u.id actor,m.org_id from auth.users u join public.memberships m on m.user_id=u.id
 where u.id::text like 'e0170000-0000-4000-8000-%';
update public.orgs set plan='pro',plan_source='manual',plan_expires_at=null where id in(select org_id from tn_actors);
update public.orgs set plan='team' where id=(select org_id from tn_actors where actor='e0170000-0000-4000-8000-000000000001');
update public.plan_entitlements set seats=8 where plan='team';
-- Synthetic reachable-at-enqueue device; no provider call is made here.
insert into public.notification_devices(user_id,device_token,environment)
 values('e0170000-0000-4000-8000-000000000006',repeat('e',64),'production');
grant all on tn_checks,tn_actors to service_role;
set local role service_role;
select public.create_org_invite('e0170000-0000-4000-8000-000000000001',
 (select org_id from tn_actors where actor='e0170000-0000-4000-8000-000000000001'),null,'agent',repeat('1',64));
select public.accept_org_invite('e0170000-0000-4000-8000-000000000002',repeat('1',64));
select public.create_org_invite('e0170000-0000-4000-8000-000000000001',
 (select org_id from tn_actors where actor='e0170000-0000-4000-8000-000000000001'),null,'admin',repeat('2',64));
select public.accept_org_invite('e0170000-0000-4000-8000-000000000003',repeat('2',64));
reset role;
-- This admin is an existing shared non-Team library member, not an accepted
-- Team seat. Keeping its access proves the fix intersects the old policy.
insert into public.memberships(user_id,org_id,role) select 'e0170000-0000-4000-8000-000000000005',org_id,'admin'
 from tn_actors where actor='e0170000-0000-4000-8000-000000000004';
create temp table tn_listings(n integer primary key,listing uuid,org_id uuid,agent uuid);
insert into tn_listings select 1,'e0171000-0000-4000-8000-000000000001',org_id,'e0170000-0000-4000-8000-000000000002'
 from tn_actors where actor='e0170000-0000-4000-8000-000000000001';
insert into tn_listings select 2,'e0171000-0000-4000-8000-000000000002',org_id,actor
 from tn_actors where actor='e0170000-0000-4000-8000-000000000002';
insert into tn_listings select 3,'e0171000-0000-4000-8000-000000000003',org_id,actor
 from tn_actors where actor='e0170000-0000-4000-8000-000000000004';
insert into tn_listings select 4,'e0171000-0000-4000-8000-000000000004',org_id,actor
 from tn_actors where actor='e0170000-0000-4000-8000-000000000006';
insert into public.listings(id,org_id,agent_id,address) select listing,org_id,agent,'Fictional notification fixture '||n from tn_listings;
create temp table tn_jobs(n integer primary key,job uuid,render_id uuid,listing uuid,payload jsonb);
do $$declare x record;j uuid;r uuid;a uuid;p text;begin
 for x in select n,listing from tn_listings union all select 5,listing from tn_listings where n=1 loop
  j:=('e0172000-0000-4000-8000-'||lpad(x.n::text,12,'0'))::uuid;
  r:=('e0173000-0000-4000-8000-'||lpad(x.n::text,12,'0'))::uuid;
  a:=('e0174000-0000-4000-8000-'||lpad(x.n::text,12,'0'))::uuid;
  insert into public.capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,bytes)
   values(a,x.listing,'video','uploads/tour-notification-fixture.mov','uploads',true,1);
  insert into public.render_jobs(id,listing_id,capture_asset_id,source,status,worker_id,attempts,lease_expires_at)
   values(j,x.listing,a,'worker','processing','tour-fixture-worker',1,clock_timestamp()+interval '10 minutes');
  p:='renders/'||x.listing||'/'||r;
  insert into tn_jobs values(x.n,j,r,x.listing,jsonb_build_object('id',r,'slug','tour-notice-'||x.n,
   'duration_s',30,'speed_factor',2,'video_key',p||'.mp4','poster_key',p||'-poster.jpg','stream_uid',null,'hero_key',null));
 end loop;
end$$;
create function pg_temp.tn_publish(p_n integer) returns jsonb language plpgsql as $$declare j tn_jobs;begin
 select * into strict j from tn_jobs where n=p_n;
 return public.publish_worker_render(j.job,'tour-fixture-worker',1,j.payload,'{"ran":false,"staged":false}','[]');
end$$;
create function pg_temp.tn_current(p_outbox uuid,p_patch jsonb default '{}') returns boolean language plpgsql as $$declare o public.notification_outbox;begin
 select * into strict o from public.notification_outbox where id=p_outbox;
 return public.tour_notification_current(o.id,jsonb_build_object('outbox_id',o.id,'org_id',o.org_id,'recipient_user_id',o.user_id,
  'render_id',o.payload#>>'{data,render_id}','listing_id',o.payload#>>'{data,listing_id}',
  'slug',o.payload#>>'{data,slug}','deep_link',o.payload->>'deep_link')||p_patch);
end$$;
grant all on tn_listings,tn_jobs to service_role;
do $$begin execute format('grant usage on schema %I to service_role',(select nspname from pg_namespace where oid=pg_my_temp_schema()));end$$;
set local role service_role;
select pg_temp.tn_ok(public.listing_content_access('e0170000-0000-4000-8000-000000000001',listing,false),'actual Team owner can read agent legacy listing') from tn_listings where n=1;
select pg_temp.tn_ok(not public.listing_content_access('e0170000-0000-4000-8000-000000000003',listing,false),'sibling Team admin cannot read agent legacy listing') from tn_listings where n=1;
select pg_temp.tn_ok(public.listing_content_access('e0170000-0000-4000-8000-000000000005',listing,false),'shared non-Team admin retains real listing access') from tn_listings where n=3;
select pg_temp.tn_publish(n) from tn_jobs where n between 1 and 4 order by n;
select pg_temp.tn_ok((select array_agg(user_id order by user_id)=array['e0170000-0000-4000-8000-000000000001'::uuid]
 from public.notification_outbox where category='render_ready'and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000001'),'legacy publication preserves Team owner and excludes sibling admin');
select pg_temp.tn_ok((select array_agg(user_id order by user_id)=array['e0170000-0000-4000-8000-000000000002'::uuid]
 from public.notification_outbox where category='render_ready'and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000002'),'private physical library preserves its existing owner recipient');
select pg_temp.tn_ok((select array_agg(user_id order by user_id)=array['e0170000-0000-4000-8000-000000000004'::uuid,'e0170000-0000-4000-8000-000000000005'::uuid]
 from public.notification_outbox where category='render_ready'and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000003'),'shared owner and accessible admin both remain recipients');
select pg_temp.tn_ok((select array_agg(user_id order by user_id)=array['e0170000-0000-4000-8000-000000000006'::uuid]
 from public.notification_outbox where category='render_ready'and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000004'),'personal owner still receives completion');
select pg_temp.tn_ok((select count(*)=5 and bool_and(o.payload->>'deep_link'='/f/'||(o.payload#>>'{data,slug}')
 and o.payload#>>'{data,listing_id}'=r.listing_id::text and o.org_id=l.org_id
 and o.dedupe_key='render_ready:'||r.id||':'||o.user_id and o.payload#>>'{data,source}'='worker')
 from public.notification_outbox o join public.renders r on r.id::text=o.payload#>>'{data,render_id}' join public.listings l on l.id=r.listing_id
 where o.category='render_ready'and r.id in(select render_id from tn_jobs)),'publication commits exact route facts and existing dedupe');
select pg_temp.tn_publish(1);
select pg_temp.tn_ok((select count(*)=5 from public.notification_outbox where category='render_ready'and payload#>>'{data,render_id}' in(select render_id::text from tn_jobs)),'exact publication replay does not duplicate notifications');
reset role;
-- Only fixture setup writes this table directly. The production service role
-- intentionally has SELECT plus the narrow notification RPCs, not UPDATE.
update public.notification_outbox set state='sending',attempts=1,claimed_at=clock_timestamp()
 where category='render_ready'and payload#>>'{data,render_id}' in(select render_id::text from tn_jobs);
set local role service_role;
select pg_temp.tn_ok((select count(*)=5 and bool_and(pg_temp.tn_current(id)) from public.notification_outbox
 where category='render_ready'and payload#>>'{data,render_id}' in(select render_id::text from tn_jobs)),'all current intended recipients pass the real claimed-row scope');
reset role;
create temp table tn_saved as select * from public.notification_outbox where category='render_ready'
 and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000001';
grant select on tn_saved to service_role;
-- A transaction-local fixture helper owns the synthetic outbox mutations.
-- Its service-role caller still exercises the real RPC's role guard; no
-- permanent table privilege or production function is changed.
create function pg_temp.tn_changed(p_sql text,label text) returns void language plpgsql
security definer set search_path='pg_temp' as $$begin
 execute p_sql;
 perform pg_temp.tn_ok(not pg_temp.tn_current((select id from tn_saved)),label);
 update public.notification_outbox o set org_id=s.org_id,user_id=s.user_id,payload=s.payload,state=s.state from tn_saved s where o.id=s.id;
end$$;
set local role service_role;
select pg_temp.tn_ok(not pg_temp.tn_current(id,jsonb_build_object('recipient_user_id','e0170000-0000-4000-8000-000000000003')),'claimed recipient snapshot cannot change') from tn_saved;
select pg_temp.tn_ok(not pg_temp.tn_current(id,jsonb_build_object('render_id','e0173000-0000-4000-8000-000000000002')),'claimed render snapshot cannot change') from tn_saved;
select pg_temp.tn_changed('update public.notification_outbox set state=''queued''where id=(select id from tn_saved)','unclaimed row cannot authorize delivery');
update public.renders set published_at=null where id='e0173000-0000-4000-8000-000000000001';
select pg_temp.tn_ok(not pg_temp.tn_current(id),'withdrawn render cannot authorize delivery') from tn_saved;
update public.renders set published_at=now() where id='e0173000-0000-4000-8000-000000000001';
update public.listings set deleted_at=now()where id='e0171000-0000-4000-8000-000000000001';
select pg_temp.tn_ok(not pg_temp.tn_current(id),'deleted listing cannot authorize delivery') from tn_saved;
update public.listings set deleted_at=null where id='e0171000-0000-4000-8000-000000000001';
-- Restore publication too: ordinary deletion machinery can unpublish it.
update public.renders set published_at=now()where id='e0173000-0000-4000-8000-000000000001';
select pg_temp.tn_changed('update public.notification_outbox set user_id=''e0170000-0000-4000-8000-000000000003''where id=(select id from tn_saved)','old queued sibling admin notice is suppressed');
select pg_temp.tn_changed('update public.notification_outbox set payload=jsonb_set(payload,''{data,render_id}'',''"e0173000-0000-4000-8000-000000000002"'')where id=(select id from tn_saved)','cross-listing render is refused');
select pg_temp.tn_changed('update public.notification_outbox set payload=jsonb_set(payload,''{data,listing_id}'',''"e0171000-0000-4000-8000-000000000002"'')where id=(select id from tn_saved)','wrong listing is refused');
select pg_temp.tn_changed('update public.notification_outbox set org_id=(select org_id from tn_actors where actor=''e0170000-0000-4000-8000-000000000004'')where id=(select id from tn_saved)','wrong physical org is refused');
select pg_temp.tn_changed('update public.notification_outbox set payload=jsonb_set(payload,''{data,slug}'',''"other-tour"'')where id=(select id from tn_saved)','wrong slug is refused');
select pg_temp.tn_changed('update public.notification_outbox set payload=jsonb_set(payload,''{deep_link}'',''"/f/other-tour"'')where id=(select id from tn_saved)','wrong public route is refused');
select pg_temp.tn_changed('update public.notification_outbox set payload=jsonb_set(payload,''{data,render_id}'',''123'')where id=(select id from tn_saved)','malformed routing scalar refuses without cast exception');
select pg_temp.tn_changed('update public.notification_outbox set payload=jsonb_set(payload,''{data,property_video_job_id}'',''"e0172000-0000-4000-8000-000000000001"'')where id=(select id from tn_saved)','mixed private-video and tour payload is refused');
select pg_temp.tn_changed('update public.notification_outbox set payload=payload#-''{data,render_id}''where id=(select id from tn_saved)','missing render cannot become a generic Home notice');
select public.remove_org_member((select org_id from tn_actors where actor='e0170000-0000-4000-8000-000000000001'),
 'e0170000-0000-4000-8000-000000000001','e0170000-0000-4000-8000-000000000002');
select pg_temp.tn_ok(not pg_temp.tn_current(id),'Team-owner access revoked after enqueue suppresses delivery') from tn_saved;
select pg_temp.tn_ok((select bool_and(pg_temp.tn_current(id)) from public.notification_outbox
 where category='render_ready'and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000004'),'unrelated personal notice remains current after Team revocation');
reset role;

-- Remove the exact new predicate, publish real owned fixture work, and require
-- the recipient-set assertion to catch the resulting inaccessible sibling.
create temp table tn_definition as select pg_get_functiondef('public.publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)'::regprocedure) definition;
do $$declare definition text;predicate text:=E'\n         and public.listing_content_access(m.user_id, v_listing.id, false)';begin
 select t.definition into strict definition from tn_definition t;
 if (length(definition)-length(replace(definition,predicate,'')))/length(predicate)<>1 then raise exception 'Tour predicate mutation no longer matches exactly';end if;
 execute replace(definition,predicate,'');
end$$;
set local role service_role;
select pg_temp.tn_publish(5);
do $$begin
 begin
  if exists(select 1 from public.notification_outbox where category='render_ready'
   and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000005'
   and user_id='e0170000-0000-4000-8000-000000000003')then
   raise exception 'inaccessible sibling received a completion';
  end if;
  raise exception 'Tour predicate-removal control did not detect the wrong recipient';
 exception when raise_exception then
  if sqlerrm<>'inaccessible sibling received a completion'then raise;end if;
 end;
 perform pg_temp.tn_ok(true,'removing actual producer predicate is detected by wrong recipient');
end$$;
reset role;
do $$declare definition text;begin select t.definition into strict definition from tn_definition t;execute definition;end$$;
select pg_temp.tn_ok((select md5(prosrc)='31df14b830c092d0b22ea1f8bf94f4c7'from pg_proc
 where oid='public.publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)'::regprocedure),'predicate control restores the exact current worker definition');

-- Real table ACLs and fallback transaction, not a PostgREST write mock.
select pg_temp.tn_ok(has_table_privilege('service_role','public.notification_outbox','SELECT')
 and not has_table_privilege('service_role','public.notification_outbox','INSERT,UPDATE,DELETE'),'outbox remains SELECT-only for service role');
select pg_temp.tn_ok(not has_function_privilege('anon','public.notification_email_fallback_enqueue(uuid,integer,jsonb,text)','execute')
 and not has_function_privilege('authenticated','public.notification_email_fallback_enqueue(uuid,integer,jsonb,text)','execute')
 and has_function_privilege('service_role','public.notification_email_fallback_enqueue(uuid,integer,jsonb,text)','execute')
 and(select prosecdef and proconfig=array['search_path=""']::text[] from pg_proc
 where oid='public.notification_email_fallback_enqueue(uuid,integer,jsonb,text)'::regprocedure),'fallback capability has exact service-only authority');
create temp table tn_fallback_saved as select * from public.notification_outbox where category='render_ready'
 and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000004';
grant select on tn_fallback_saved to service_role;
create function pg_temp.tn_fallback(p_id uuid,p_attempt integer default null,p_patch jsonb default '{}',
 p_reason text default 'no live device for this user') returns text language plpgsql as $$declare o public.notification_outbox;begin
 select *into strict o from public.notification_outbox where id=p_id;
 return public.notification_email_fallback_enqueue(o.id,coalesce(p_attempt,o.attempts),jsonb_build_object('outbox_id',o.id,
  'org_id',o.org_id,'recipient_user_id',o.user_id,'category',o.category,'channel',o.channel,'dedupe_key',o.dedupe_key,
  'payload',o.payload,'to_email',o.to_email)||p_patch,p_reason);
end$$;
create function pg_temp.tn_reclaim(p_id uuid,p_attempt integer,p_state text default 'sending')returns void
language plpgsql security definer set search_path='pg_temp' as $$begin
 update public.notification_outbox set state=p_state,attempts=p_attempt,claimed_at=clock_timestamp()
  where id=p_id and user_id in(select actor from tn_actors);
end$$;
-- Separate RPC completion from the subsequent state read. SQL expression
-- evaluation order must not decide whether this fixture sees its own write.
create function pg_temp.tn_fallback_is(p_id uuid,p_status text,p_state text)returns boolean language plpgsql as $$
declare outcome text;actual_state text;begin
 outcome:=pg_temp.tn_fallback(p_id);
 select state into strict actual_state from public.notification_outbox where id=p_id;
 return outcome=p_status and actual_state=p_state;
end$$;
set local role service_role;
select pg_temp.tn_ok(pg_temp.tn_fallback_is(id,'queued','skipped'),
 'actual fallback RPC queues and closes the same claim atomically')from tn_fallback_saved s;
select pg_temp.tn_ok((select count(*)=1 and bool_and(e.org_id=s.org_id and e.user_id=s.user_id and e.category=s.category
 and e.channel='email'and e.payload=s.payload and e.to_email is null and e.client_delivery_id is null and e.client_verification_id is null)
 from public.notification_outbox e where e.dedupe_key=s.dedupe_key||':email-fallback'),'twin fields derive only from the saved claim')from tn_fallback_saved s;
select pg_temp.tn_ok(pg_temp.tn_fallback(id)='stale'and(select state='skipped'from public.notification_outbox where id=s.id),
 'replayed completed claim is untouched')from tn_fallback_saved s;
select pg_temp.tn_reclaim(id,2)from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback(id)='duplicate'and(select count(*)=1 from public.notification_outbox where dedupe_key=s.dedupe_key||':email-fallback'),
 'recovered later claim reuses one exact email twin')from tn_fallback_saved s;
select pg_temp.tn_reclaim(id,3)from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback(id,2)='stale'and(select state='sending'and attempts=3 from public.notification_outbox where id=s.id),
 'stale attempt cannot close or enqueue for a newer claim')from tn_fallback_saved s;
select pg_temp.tn_reclaim(id,3,'queued')from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback(id)='stale'and(select state='queued'from public.notification_outbox where id=s.id),
 'unclaimed push cannot request a fallback')from tn_fallback_saved s;
select pg_temp.tn_reclaim(id,3)from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback(id,null,jsonb_build_object('recipient_user_id','e0170000-0000-4000-8000-000000000003'))='stale',
 'caller cannot select another fallback recipient')from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback(id,null,jsonb_build_object('payload',jsonb_build_object('injected',true)))='stale',
 'caller cannot inject fallback payload')from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback(id,null,jsonb_build_object('to_email','injected@fixture.invalid'))='stale',
 'caller cannot inject a fallback address')from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback(id,null,'{}','account access changed')='stale',
 'access refusal is not an eligible fallback transport outcome')from tn_fallback_saved;
reset role;
update public.notification_outbox set category='allowance_low'where id=(select id from tn_fallback_saved);
set local role service_role;
select pg_temp.tn_ok(pg_temp.tn_fallback(id)='stale','only the three original fallback categories are eligible')from tn_fallback_saved;
reset role;
update public.notification_outbox set category='render_ready'where id=(select id from tn_fallback_saved);
update public.notification_outbox set payload='{"conflict":true}'where dedupe_key=(select dedupe_key||':email-fallback'from tn_fallback_saved);
set local role service_role;
select pg_temp.tn_ok(pg_temp.tn_fallback_is(id,'retry','queued')
 and(select payload='{"conflict":true}'::jsonb from public.notification_outbox where dedupe_key=s.dedupe_key||':email-fallback'),
 'conflicting twin is not accepted or mutated and original claim retries')from tn_fallback_saved s;
reset role;
update public.notification_outbox set payload=s.payload,to_email='wrong@fixture.invalid'from tn_fallback_saved s
 where notification_outbox.dedupe_key=s.dedupe_key||':email-fallback';
set local role service_role;
select pg_temp.tn_reclaim(id,3)from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback(id)='retry'and(select to_email='wrong@fixture.invalid'from public.notification_outbox where dedupe_key=s.dedupe_key||':email-fallback'),
 'conflicting twin address cannot be treated as idempotent success')from tn_fallback_saved s;
reset role;
delete from public.notification_outbox where dedupe_key=(select dedupe_key||':email-fallback'from tn_fallback_saved);
create function pg_temp.tn_fail_fallback()returns trigger language plpgsql as $$begin
 if new.dedupe_key=(select dedupe_key||':email-fallback'from tn_fallback_saved)then raise exception 'synthetic fallback insert failure';end if;return new;
end$$;
create trigger tn_fallback_failure before insert on public.notification_outbox for each row execute function pg_temp.tn_fail_fallback();
set local role service_role;
select pg_temp.tn_reclaim(id,3)from tn_fallback_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback_is(id,'retry','queued')
 and not exists(select 1 from public.notification_outbox where dedupe_key=s.dedupe_key||':email-fallback'),
 'actual insert failure rolls back twin and retries the exact claim')from tn_fallback_saved s;
reset role;
drop trigger tn_fallback_failure on public.notification_outbox;
set local role authenticated;
do $$begin
 begin perform public.notification_email_fallback_enqueue('e0175000-0000-4000-8000-000000000001',1,'{}','no live device for this user');
  raise exception 'Authenticated caller was allowed to enqueue fallback';
 exception when insufficient_privilege then null;end;
end$$;
reset role;
select pg_temp.tn_ok(true,'actual authenticated caller is refused by fallback authority');
-- The lead and upload cases exercise the two other already-eligible kinds.
insert into public.leads(id,org_id,listing_id,render_id,name)select 'e0175000-0000-4000-8000-000000000001',l.org_id,l.listing,j.render_id,'Fictional fallback inquiry'
 from tn_listings l join tn_jobs j using(n)where n=4;
insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,expires_at)
 select 'e0175000-0000-4000-8000-000000000002',org_id,listing,agent,current_date,'{}',0,now()-interval '1 hour'from tn_listings where n=4;
set local role service_role;
select public.notification_enqueue(org_id,agent,'upload_stuck',jsonb_build_object('deep_link',null,'data',jsonb_build_object('asset_id','e0175000-0000-4000-8000-000000000002')),
 'tour-fixture-upload-stuck',null)from tn_listings where n=4;
select pg_temp.tn_reclaim(id,1)from public.notification_outbox where category='lead_received'and payload#>>'{data,lead_id}'='e0175000-0000-4000-8000-000000000001';
select pg_temp.tn_ok(pg_temp.tn_fallback(id)='queued','current lead fallback uses the same recipient and listing scope')
 from public.notification_outbox where category='lead_received'and payload#>>'{data,lead_id}'='e0175000-0000-4000-8000-000000000001'and channel='push';
select pg_temp.tn_reclaim(id,1)from public.notification_outbox where dedupe_key='tour-fixture-upload-stuck';
select pg_temp.tn_ok(pg_temp.tn_fallback(id)='queued','current actor-owned stuck upload keeps its existing fallback')
 from public.notification_outbox where dedupe_key='tour-fixture-upload-stuck';
select public.notification_enqueue(org_id,agent,'render_ready',jsonb_build_object('data',jsonb_build_object('property_video_job_id','e0175000-0000-4000-8000-000000000003',
 'reel_job_id','e0175000-0000-4000-8000-000000000003','listing_id',listing)),'tour-fixture-unavailable-private-video',null)from tn_listings where n=4;
select pg_temp.tn_reclaim(id,1)from public.notification_outbox where dedupe_key='tour-fixture-unavailable-private-video';
select pg_temp.tn_ok(pg_temp.tn_fallback_is(id,'denied','skipped'),
 'unavailable private video cannot fall back to another route')from public.notification_outbox o where dedupe_key='tour-fixture-unavailable-private-video';
reset role;
update public.notification_outbox set channel='push'where id=(select id from tn_saved);
set local role service_role;
select pg_temp.tn_reclaim(id,1)from tn_saved;
select pg_temp.tn_ok(pg_temp.tn_fallback_is(id,'denied','skipped')
 and not exists(select 1 from public.notification_outbox where dedupe_key=s.dedupe_key||':email-fallback'),
 'revoked tour access atomically skips without a fallback twin')from tn_saved s;
reset role;
do $$begin if(select count(*)from tn_checks)<>52 then raise exception 'Tour notification assertion inventory changed';end if;end$$;
select 'PASS tour notification access: 52 assertions';
rollback;
