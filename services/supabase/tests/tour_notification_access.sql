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
update public.notification_outbox set state='sending',attempts=1,claimed_at=clock_timestamp()
 where category='render_ready'and payload#>>'{data,render_id}' in(select render_id::text from tn_jobs);
select pg_temp.tn_ok((select count(*)=5 and bool_and(pg_temp.tn_current(id)) from public.notification_outbox
 where category='render_ready'and payload#>>'{data,render_id}' in(select render_id::text from tn_jobs)),'all current intended recipients pass the real claimed-row scope');
reset role;
create temp table tn_saved as select * from public.notification_outbox where category='render_ready'
 and payload#>>'{data,render_id}'='e0173000-0000-4000-8000-000000000001';
grant select on tn_saved to service_role;
create function pg_temp.tn_changed(p_sql text,label text) returns void language plpgsql as $$begin
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
do $$begin if(select count(*)from tn_checks)<>31 then raise exception 'Tour notification assertion inventory changed';end if;end$$;
select 'PASS tour notification access: 31 assertions';
rollback;
