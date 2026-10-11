\set ON_ERROR_STOP on
-- Build 58 database controls: Recently deleted (30-day restore) and republish
-- in place, proved with the actual RPCs and triggers, then rolled back.
begin;
create temporary table b58_checks(n integer not null default 0);insert into b58_checks default values;grant select,update on b58_checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'BUILD58 FAIL: %',label;end if;update b58_checks set n=n+1;end$$;
create function pg_temp.refuse(command text,prefix text,label text)returns void language plpgsql as $$begin begin execute command;exception when raise_exception then if sqlerrm like prefix||'%'then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception 'BUILD58 FAIL: allowed %',label;end$$;
grant execute on function pg_temp.ok(boolean,text),pg_temp.refuse(text,text,text) to service_role,authenticated;
do $$ declare v_schema text; begin select nspname into v_schema from pg_namespace where oid=pg_my_temp_schema(); execute format('grant usage on schema %I to service_role,authenticated',v_schema); end $$;

insert into auth.users(id,email,is_anonymous)values
('fe580000-0000-4000-8000-000000000001','b58-owner@fixture.invalid',false),
('fe580000-0000-4000-8000-000000000002','b58-stranger@fixture.invalid',false),
('fe580000-0000-4000-8000-000000000003','b58-marketing@fixture.invalid',false);
create temp table b58 as select
 (select org_id from memberships where user_id='fe580000-0000-4000-8000-000000000001')org,
 (select org_id from memberships where user_id='fe580000-0000-4000-8000-000000000002')other;
grant select on b58 to service_role,authenticated;
update orgs set plan='pro',plan_source='manual',plan_expires_at=null where id=(select org from b58);
-- A marketing seat in the owner's library: read-only by the existing rules.
insert into memberships(user_id,org_id,role)values('fe580000-0000-4000-8000-000000000003',(select org from b58),'marketing');

-- Listing L1: published tour (job J1 / asset A1 / render R1 slug 'b58slug0001'), one photo, one lead delivery in flight.
insert into listings(id,org_id,agent_id,status,address)values('fe581000-0000-4000-8000-000000000001',(select org from b58),'fe580000-0000-4000-8000-000000000001','ready','1 Restore Lane');
insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,bytes,duration_s)values
('fe582000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000001','video','renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000001/a1.mp4','renders',true,10,30),
('fe582000-0000-4000-8000-000000000002','fe581000-0000-4000-8000-000000000001','video','renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000001/a2.mp4','renders',true,10,42);
insert into render_jobs(id,listing_id,capture_asset_id,source,status)values('fe583000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000001','fe582000-0000-4000-8000-000000000001','app','ready');
insert into renders(id,job_id,listing_id,slug,duration_s,speed_factor,video_key,published_at,created_at)values('fe584000-0000-4000-8000-000000000001','fe583000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000001','b58slug0001',30,2,'renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000001/a1.mp4',now()-interval '3 days',now()-interval '3 days');
-- Listing L2: never published; plain delete (no window) must behave exactly as before.
insert into listings(id,org_id,agent_id,status,address)values('fe581000-0000-4000-8000-000000000002',(select org from b58),'fe580000-0000-4000-8000-000000000001','draft','2 Immediate Way');
insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,bytes)values('fe582000-0000-4000-8000-000000000003','fe581000-0000-4000-8000-000000000002','video','uploads/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000002/raw.mov','uploads',true,10);
-- Listing L3: never published; republish on it must be an ordinary first publish.
insert into listings(id,org_id,agent_id,status,address)values('fe581000-0000-4000-8000-000000000003',(select org from b58),'fe580000-0000-4000-8000-000000000001','draft','3 First Publish Ct');
insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,bytes,duration_s)values('fe582000-0000-4000-8000-000000000004','fe581000-0000-4000-8000-000000000003','video','renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000003/a4.mp4','renders',true,10,12);

-- ── Trash: the delete route's write ──────────────────────────────────────────
set local role service_role;
update listings set deleted_at=now(),trash_expires_at=now()+interval '30 days' where id='fe581000-0000-4000-8000-000000000001';
select pg_temp.ok((select published_at is null and unpublished_by_delete_at is not null from renders where id='fe584000-0000-4000-8000-000000000001'),'delete takes the tour down and remembers it was live');
select pg_temp.ok(not exists(select 1 from privacy_cleanup_jobs where kind='listing'and source_id='fe581000-0000-4000-8000-000000000001'),'an open restore window queues no storage cleanup');
select pg_temp.ok((select (list_trashed_listings('fe580000-0000-4000-8000-000000000001',org)->'listings'->0->>'id')='fe581000-0000-4000-8000-000000000001' from b58),'Recently deleted lists the trashed listing');
select pg_temp.ok((select (list_trashed_listings('fe580000-0000-4000-8000-000000000001',org)->'listings'->0->>'had_published_tour')::boolean and (list_trashed_listings('fe580000-0000-4000-8000-000000000001',org)->'listings'->0->>'can_restore')::boolean from b58),'the row says it had a tour and that the owner may restore it');
select pg_temp.ok((select jsonb_array_length(list_trashed_listings('fe580000-0000-4000-8000-000000000003',org)->'listings')=1 and not (list_trashed_listings('fe580000-0000-4000-8000-000000000003',org)->'listings'->0->>'can_restore')::boolean from b58),'a marketing seat sees the trash but cannot restore');
select pg_temp.refuse($q$select list_trashed_listings('fe580000-0000-4000-8000-000000000002',(select org from b58))$q$,'RP403','a stranger cannot list another library''s trash');
select pg_temp.refuse($q$select listing_library_scope('fe580000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000001')$q$,'RP404','a trashed listing is invisible to ordinary listing authority');
select pg_temp.ok(not exists(select 1 from jsonb_array_elements((list_library_listings('fe580000-0000-4000-8000-000000000001',(select org from b58),500,0))->'listings')l where l->>'id'='fe581000-0000-4000-8000-000000000001'),'the trashed listing is out of the library sync page');

-- ── Restore ──────────────────────────────────────────────────────────────────
select pg_temp.refuse($q$select restore_listing('fe580000-0000-4000-8000-000000000002','fe581000-0000-4000-8000-000000000001')$q$,'RP403','a stranger cannot restore');
select pg_temp.refuse($q$select restore_listing('fe580000-0000-4000-8000-000000000003','fe581000-0000-4000-8000-000000000001')$q$,'RP403','a marketing seat cannot restore');
select pg_temp.refuse($q$select restore_listing('fe580000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000002')$q$,'RP409','a live listing is not restorable');
select pg_temp.refuse($q$select restore_listing('fe580000-0000-4000-8000-000000000001','00000000-0000-4000-8000-00000000dead')$q$,'RP404','an unknown listing is not found');
create temp table b58_restore as select restore_listing('fe580000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000001') r;
grant select on b58_restore to service_role,authenticated;
select pg_temp.ok((select (r->>'ok')::boolean and (r->>'republished_renders')::int=1 and r->>'listing_id'='fe581000-0000-4000-8000-000000000001' and r->>'address'='1 Restore Lane' from b58_restore),'restore answers with the listing and the republished tour count');
select pg_temp.ok((select deleted_at is null and trash_expires_at is null from listings where id='fe581000-0000-4000-8000-000000000001'),'restore clears the trash marks');
select pg_temp.ok((select published_at is not null and unpublished_by_delete_at is null and slug='b58slug0001' from renders where id='fe584000-0000-4000-8000-000000000001'),'restore brings the SAME tour link back');
select pg_temp.ok((select (listing_library_scope('fe580000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000001')->>'listing_id')='fe581000-0000-4000-8000-000000000001'),'ordinary listing authority works again after restore');
select pg_temp.ok(exists(select 1 from jsonb_array_elements((list_library_listings('fe580000-0000-4000-8000-000000000001',(select org from b58),500,0))->'listings')l where l->>'id'='fe581000-0000-4000-8000-000000000001'),'the restored listing is back in the library sync page');
select pg_temp.ok((select jsonb_array_length(list_trashed_listings('fe580000-0000-4000-8000-000000000001',org)->'listings')=0 from b58),'Recently deleted is empty after restore');
select pg_temp.refuse($q$select restore_listing('fe580000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000001')$q$,'RP409','a second restore of a live listing is refused');

-- ── The window closes: the owed cleanup is queued, restore is over ───────────
update listings set deleted_at=now(),trash_expires_at=now()+interval '30 days' where id='fe581000-0000-4000-8000-000000000001';
update listings set trash_expires_at=now()-interval '1 second' where id='fe581000-0000-4000-8000-000000000001';
select pg_temp.ok(listing_trash_sweep()=1,'the hourly sweep queues exactly the expired listing');
select pg_temp.ok((select state='pending' and payload->'r2' @> jsonb_build_array(jsonb_build_object('bucket','renders','key','renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000001/a1.mp4')) and not_before>=now()+interval '59 minutes' from privacy_cleanup_jobs where kind='listing'and source_id='fe581000-0000-4000-8000-000000000001'),'the queued cleanup carries the tour video with the usual one-hour settle');
select pg_temp.ok((select trash_expires_at is null and deleted_at is not null from listings where id='fe581000-0000-4000-8000-000000000001'),'the swept listing leaves the trash and stays deleted');
select pg_temp.ok(listing_trash_sweep()=0,'the sweep is idempotent');
select pg_temp.refuse($q$select restore_listing('fe580000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000001')$q$,'RP410','restore after the window is refused');
select pg_temp.ok((select jsonb_array_length(list_trashed_listings('fe580000-0000-4000-8000-000000000001',org)->'listings')=0 from b58),'a swept listing is not offered for restore');

-- ── A delete with no window (account deletion, older clients) is unchanged ──
update listings set deleted_at=now() where id='fe581000-0000-4000-8000-000000000002';
select pg_temp.ok((select state='pending' and payload->'r2' @> jsonb_build_array(jsonb_build_object('bucket','uploads','key','uploads/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000002/raw.mov')) from privacy_cleanup_jobs where kind='listing'and source_id='fe581000-0000-4000-8000-000000000002'),'a plain delete still queues cleanup immediately');
select pg_temp.refuse($q$select restore_listing('fe580000-0000-4000-8000-000000000001','fe581000-0000-4000-8000-000000000002')$q$,'RP410','a plain delete has no restore window');

-- ── Republish in place (the phone's own role) ────────────────────────────────
reset role;
select set_config('request.jwt.claim.sub','fe580000-0000-4000-8000-000000000001',true);
set local role authenticated;
-- A new app job on the new upload of listing L1 (restored above, then deleted again: use L3's twin instead — recreate a live published listing L4).
reset role;
insert into listings(id,org_id,agent_id,status,address)values('fe581000-0000-4000-8000-000000000004',(select org from b58),'fe580000-0000-4000-8000-000000000001','ready','4 Same Link Blvd');
insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,bytes,duration_s)values
('fe582000-0000-4000-8000-000000000005','fe581000-0000-4000-8000-000000000004','video','renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000004/old.mp4','renders',true,10,30),
('fe582000-0000-4000-8000-000000000006','fe581000-0000-4000-8000-000000000004','video','renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000004/new.mp4','renders',true,10,45),
('fe582000-0000-4000-8000-000000000007','fe581000-0000-4000-8000-000000000004','photo','renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000004/poster.jpg','renders',true,10,null);
insert into render_jobs(id,listing_id,capture_asset_id,source,status)values
('fe583000-0000-4000-8000-000000000004','fe581000-0000-4000-8000-000000000004','fe582000-0000-4000-8000-000000000005','app','ready'),
('fe583000-0000-4000-8000-000000000005','fe581000-0000-4000-8000-000000000004','fe582000-0000-4000-8000-000000000006','app','created'),
('fe583000-0000-4000-8000-000000000006','fe581000-0000-4000-8000-000000000003','fe582000-0000-4000-8000-000000000004','app','created');
insert into renders(id,job_id,listing_id,slug,duration_s,speed_factor,video_key,published_at,created_at)values('fe584000-0000-4000-8000-000000000004','fe583000-0000-4000-8000-000000000004','fe581000-0000-4000-8000-000000000004','b58slug0004',30,2,'renders/'||(select org from b58)||'/fe581000-0000-4000-8000-000000000004/old.mp4',now()-interval '10 days',now()-interval '10 days');
select set_config('request.jwt.claim.sub','fe580000-0000-4000-8000-000000000001',true);
set local role authenticated;
create temp table b58_rep as select republish_render('fe583000-0000-4000-8000-000000000005',45,2,'[{"label":"Kitchen","t_ms":1000,"sort":0}]'::jsonb,'fe582000-0000-4000-8000-000000000007') r;
grant select on b58_rep to service_role,authenticated;
select pg_temp.ok((select (r).id='fe584000-0000-4000-8000-000000000004' and (r).slug='b58slug0004' from b58_rep),'republish keeps the render row and its slug');
select pg_temp.ok((select (r).job_id='fe583000-0000-4000-8000-000000000005' and (r).video_key like '%/new.mp4' and (r).duration_s=45 and (r).poster_key like '%/poster.jpg' and (r).staged=false and (r).published_at<now()-interval '9 days' from b58_rep),'republish moves the media, poster and duration onto the same tour and keeps the original publish date');
select pg_temp.ok((select count(*)=1 from renders where listing_id='fe581000-0000-4000-8000-000000000004'),'no second render row, no second link');
select pg_temp.ok((select status='ready' and finished_at is not null from render_jobs where id='fe583000-0000-4000-8000-000000000005'),'the new job is marked ready');
select pg_temp.ok((select count(*)=1 and max(label)='Kitchen' from capture_chapters where asset_id='fe582000-0000-4000-8000-000000000006'),'chapters follow the new asset');
select pg_temp.ok((select (republish_render('fe583000-0000-4000-8000-000000000005',45,2,'[]'::jsonb,null)).id='fe584000-0000-4000-8000-000000000004'),'a replay of the same job answers the same render');
select pg_temp.ok((select (publish_render('fe583000-0000-4000-8000-000000000005',45,2,'[]'::jsonb,null)).id='fe584000-0000-4000-8000-000000000004'),'the ordinary publish replays to the same render for that job');
select pg_temp.ok((select (republish_render('fe583000-0000-4000-8000-000000000006',12,2,'[]'::jsonb,null)).listing_id='fe581000-0000-4000-8000-000000000003'),'a listing with no tour gets an ordinary first publish');
select pg_temp.ok((select published_at is not null and job_id='fe583000-0000-4000-8000-000000000006' from renders where listing_id='fe581000-0000-4000-8000-000000000003'),'the first publish created the tour');
reset role;
select set_config('request.jwt.claim.sub','fe580000-0000-4000-8000-000000000003',true);
set local role authenticated;
select pg_temp.refuse($q$select republish_render('fe583000-0000-4000-8000-000000000005',45,2,'[]'::jsonb,null)$q$,'RP403','a marketing seat cannot republish');
reset role;
select set_config('request.jwt.claim.sub','fe580000-0000-4000-8000-000000000002',true);
set local role authenticated;
select pg_temp.refuse($q$select republish_render('fe583000-0000-4000-8000-000000000005',45,2,'[]'::jsonb,null)$q$,'RP403','a stranger cannot republish');
reset role;

-- ── Privileges ───────────────────────────────────────────────────────────────
select pg_temp.ok(has_function_privilege('authenticated','public.republish_render(uuid,numeric,numeric,jsonb,uuid)','execute') and not has_function_privilege('anon','public.republish_render(uuid,numeric,numeric,jsonb,uuid)','execute'),'republish is callable by signed-in users only');
select pg_temp.ok(not has_function_privilege('authenticated','public.restore_listing(uuid,uuid)','execute') and not has_function_privilege('anon','public.restore_listing(uuid,uuid)','execute') and has_function_privilege('service_role','public.restore_listing(uuid,uuid)','execute'),'restore is service-only');
select pg_temp.ok(not has_function_privilege('authenticated','public.list_trashed_listings(uuid,uuid)','execute') and has_function_privilege('service_role','public.list_trashed_listings(uuid,uuid)','execute'),'trash listing is service-only');
select pg_temp.ok(not has_function_privilege('authenticated','public.listing_trash_sweep()','execute') and not has_function_privilege('anon','public.queue_listing_media_cleanup(uuid)','execute'),'sweep and enqueue are service-only');
select jsonb_build_object('suite','build58_db_controls','assertions',n)from b58_checks;
rollback;
