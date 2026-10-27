\set ON_ERROR_STOP on
begin;
do $$begin if current_setting('rendprop.build68_fixture',true)is distinct from 'owned-local' or inet_server_addr()is not null then raise exception 'Use owned socket-only Build68 fixture';end if;end$$;
create temp table review_checks(label text primary key,passed boolean not null);
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'BUILD68 FAIL: %',label;end if;insert into review_checks values(label,true);end$$;
create function pg_temp.denied(command text,prefix text,label text)returns void language plpgsql as $$declare problem text;begin begin execute command;exception when others then problem:=sqlerrm;end;perform pg_temp.ok(problem like prefix||'%',label);end$$;
grant all on review_checks to service_role,authenticated,anon;
create temp table fixture(owner_id uuid,sally uuid,solo uuid,team uuid,sally_org uuid,solo_org uuid,sally_listing uuid,solo_listing uuid,request_id text,reservation_id uuid);
grant all on fixture to service_role;
insert into admin_allowlist(email,note)values('allowlisted68@fixture.invalid','synthetic verification control');
insert into auth.users(id,email,is_anonymous,email_confirmed_at,raw_user_meta_data)values
 ('c068be01-0000-4000-8000-000000000001','owner68@fixture.invalid',false,now(),'{}'),
 ('c068be01-0000-4000-8000-000000000002','sally68@fixture.invalid',false,now(),'{}'),
 ('c068be01-0000-4000-8000-000000000003','solo68@fixture.invalid',false,now(),'{}'),
 ('c068be01-0000-4000-8000-000000000004','allowlisted68@fixture.invalid',false,null,'{"is_admin":true,"role":"admin"}');
select pg_temp.ok(not is_admin,'unverified allowlisted email cannot become admin from metadata')from profiles where id='c068be01-0000-4000-8000-000000000004';
update auth.users set email_confirmed_at=now()where id='c068be01-0000-4000-8000-000000000004';
select pg_temp.ok(is_admin,'Auth confirmation promotes the verified allowlisted address')from profiles where id='c068be01-0000-4000-8000-000000000004';
update auth.users set email_confirmed_at=now()where id='c068be01-0000-4000-8000-000000000003';
select pg_temp.ok(not is_admin,'ordinary confirmed account never gains admin')from profiles where id='c068be01-0000-4000-8000-000000000003';
update profiles set is_admin=true where id='c068be01-0000-4000-8000-000000000003';
select set_config('request.jwt.claims','{"sub":"c068be01-0000-4000-8000-000000000003","role":"authenticated"}',true);
select pg_temp.ok(is_admin(),'confirmed manual admin keeps current authority');
update auth.users set email_confirmed_at=null where id='c068be01-0000-4000-8000-000000000003';
select pg_temp.ok(not public.is_admin(),'unverified admin loses SQL authority');
select pg_temp.ok(not is_admin,'existing admin loses authority when its email becomes unconfirmed')from profiles where id='c068be01-0000-4000-8000-000000000003';
update auth.users set email_confirmed_at=now()where id='c068be01-0000-4000-8000-000000000003';
insert into fixture select 'c068be01-0000-4000-8000-000000000001','c068be01-0000-4000-8000-000000000002','c068be01-0000-4000-8000-000000000003',
 (select org_id from memberships where user_id='c068be01-0000-4000-8000-000000000001'),
 (select org_id from memberships where user_id='c068be01-0000-4000-8000-000000000002'),
 (select org_id from memberships where user_id='c068be01-0000-4000-8000-000000000003'),gen_random_uuid(),gen_random_uuid(),'paid-source-68',null;
update orgs set plan='team',plan_source='manual'where id=(select team from fixture);
update orgs set plan='pro',plan_source='manual'where id=(select solo_org from fixture);
-- Create the agent's original listing while her synthetic intro trial can
-- lawfully admit it, then keep the Free private-library state under review.
update orgs set plan='trial',plan_source='trial',trial_ends_at=now()+interval '7 days'
 where id=(select sally_org from fixture);
insert into listings(id,org_id,agent_id,address)select sally_listing,sally_org,sally,'Private agent fixture'from fixture;
update orgs set plan='free',plan_source=null,trial_ends_at=null
 where id=(select sally_org from fixture);
insert into listings(id,org_id,agent_id,address)select solo_listing,solo_org,solo,'Private solo fixture'from fixture;
select pg_temp.ok((select relrowsecurity from pg_class where oid='public.app_video_drift_checks'::regclass),'QC journal enables RLS');
select pg_temp.ok(not has_table_privilege('authenticated','app_video_drift_checks','SELECT,INSERT,UPDATE,DELETE')and not has_table_privilege('anon','app_video_drift_checks','SELECT,INSERT,UPDATE,DELETE'),'QC journal has no tenant grants');
select pg_temp.ok(not has_table_privilege('service_role','app_video_drift_checks','INSERT,UPDATE,DELETE'),'service cannot bypass journal transitions');
select pg_temp.ok(not has_function_privilege('authenticated','app_video_drift_check_begin(uuid,uuid,text,text,text,uuid)','EXECUTE')and not has_function_privilege('anon','app_video_drift_check_finish(uuid,uuid,uuid,text,jsonb)','EXECUTE'),'QC transitions service-only');
set local role service_role;
do $$declare x fixture;r jsonb;m jsonb;b jsonb;feature text;actor uuid;counter integer:=0;begin
 select *into x from fixture;
 perform create_org_invite(x.owner_id,x.team,null,'agent',repeat('c',64));
 r:=accept_org_invite(x.sally,repeat('c',64));
 perform pg_temp.ok((r->>'org_id')::uuid=x.sally_org,'invite preserves private content org');
 perform pg_temp.ok(library_actor_billing_org(x.sally,x.sally_org)=x.team,'agent billing resolves Team plan');
 foreach actor in array array[x.sally,x.owner_id]loop
  foreach feature in array array['reel','aerial','drone_render']loop
   counter:=counter+1;
   b:=bump_rate_receipt('aivideo:'||x.team,300,20,1);
   m:=bump_rate_receipt((case feature when 'reel'then 'reelmo'when 'aerial'then 'aerialmo'else 'dronemo'end)||':'||x.team,2592000,1000,1);
   r:=app_video_cost_reserve_v2(actor,x.sally_org,'team-video-'||counter,feature,'fal','fixture-model',repeat('a',64),2,1,2,
     jsonb_build_object('task',case feature when 'reel'then 'video.reel_clip'when 'aerial'then 'video.aerial'else 'video.upscale_4k'end),
     (m->>'window_start')::timestamptz,(b->>'window_start')::timestamptz,x.sally_listing);
   perform pg_temp.ok(r->>'reserved'='true','Team admission '||counter);
   perform pg_temp.ok(exists(select 1 from app_video_allowance_receipts where reservation_id=(r->>'id')::uuid
    and monthly_key=(case feature when 'reel'then 'reelmo'when 'aerial'then 'aerialmo'else 'dronemo'end)||':'||x.team and burst_key='aivideo:'||x.team),'pinned Team receipts '||counter);
   perform pg_temp.ok(exists(select 1 from app_video_cost_reservations where id=(r->>'id')::uuid and org_id=x.sally_org and actor_id=actor and billing_org_id=x.team),'private identity and parent liability '||counter);
   if counter=1 then
    perform app_video_cost_settle(actor,x.sally_org,'team-video-1',x.request_id);
    update fixture set reservation_id=(r->>'id')::uuid;
   elsif counter=4 then
    perform app_video_cost_settle(actor,x.sally_org,'team-video-4','owner-paid-request68');
    perform pg_temp.ok((app_video_refund_drift(actor,x.sally_org,'owner-paid-request68','reel')->>'refunded')='true','delegated Team owner can restore own charged allowance');
   end if;
  end loop;
 end loop;
 -- Paid request and quality allowance refund remain separate liabilities.
 perform pg_temp.ok((app_video_refund_drift(x.sally,x.sally_org,x.request_id,'reel')->>'refunded')='true','agent refund uses original billing window');
 perform pg_temp.ok(exists(select 1 from cost_ledger where id=(select cost_ledger_id from app_video_cost_reservations where id=(select reservation_id from fixture))and total_cents=2),'quality refund retains supplier ledger cost');
 b:=bump_rate_receipt('aivideo:'||x.solo_org,300,20,1);m:=bump_rate_receipt('reelmo:'||x.solo_org,2592000,1000,1);
 r:=app_video_cost_reserve_v2(x.solo,x.solo_org,'solo-video-68','reel','fal','fixture-model',repeat('b',64),2,1,2,'{}',(m->>'window_start')::timestamptz,(b->>'window_start')::timestamptz,x.solo_listing);
 perform pg_temp.ok(r->>'reserved'='true','ordinary solo video remains admitted');
 perform pg_temp.denied(format('select app_video_cost_reserve_v2(%L,%L,''foreign-billing-68'',''reel'',''fal'',''fixture-model'',%L,2,1,2,''{}'',%L,%L,%L)',x.sally,x.sally_org,repeat('b',64),((m->>'window_start')::timestamptz-interval '1 second')::text,b->>'window_start',x.sally_listing),'RP409:','foreign billing windows cannot admit private video');
end$$;
do $$declare x fixture;c jsonb;first_id uuid;next_id uuid;k text;funded jsonb;before_count integer;result jsonb:='{"drift":{"action":"refuse","publishable":false},"kind":"reel"}';begin
 select *into x from fixture;
 c:=app_video_drift_check_begin(x.sally,x.sally_org,x.request_id,'reel',repeat('a',32),x.sally_listing);first_id:=(c->>'id')::uuid;k:='drift-check:'||first_id;
 perform pg_temp.ok(c->>'ordinal'='1'and c->>'replay'='false','first owned paid check admits one ordinal');
 perform pg_temp.denied(format('select app_video_drift_check_begin(%L,%L,%L,''reel'',%L,%L)',x.sally,x.sally_org,x.request_id,repeat('a',32),x.sally_listing),'RP409:','concurrent running check cannot obtain a new key');
 perform serving_operation_begin(x.sally,x.sally_org,k,'/ai-video/drift',repeat('a',64));
 funded:=serving_cost_reserve(x.sally,x.sally_org,k,'qc.initial:0','anthropic','fixture-judge',repeat('c',64),3,'published-standard-20261006');
 perform serving_cost_finish(x.sally,x.sally_org,k,'qc.initial:0','uncertain',null);
 perform pg_temp.ok(app_video_drift_check_finish(x.sally,x.sally_org,first_id,'hold',null),'provider-unavailable check becomes durable HOLD');
 c:=app_video_drift_check_begin(x.sally,x.sally_org,x.request_id,'reel',repeat('a',32),x.sally_listing);next_id:=(c->>'id')::uuid;
 perform pg_temp.ok(c->>'ordinal'='2'and next_id<>first_id,'manual recheck obtains a distinct server funding key');
 perform pg_temp.ok(exists(select 1 from serving_cost_reservations where actor_id=x.sally and request_key=k and state='uncertain'and hold_cents=3),'manual recheck never releases old uncertain liability');
 perform serving_operation_begin(x.sally,x.sally_org,'drift-check:'||next_id,'/ai-video/drift',repeat('d',64));
 funded:=serving_cost_reserve(x.sally,x.sally_org,'drift-check:'||next_id,'qc.initial:0','anthropic','fixture-judge',repeat('e',64),3,'published-standard-20261006');
 perform pg_temp.ok(funded->>'reserved'='true','same client key and changed frame body can use the next paid ordinal');
 perform pg_temp.ok((select sum(hold_cents)=6 from serving_cost_reservations where actor_id=x.sally and request_key in(k,'drift-check:'||next_id)),'both QC money holds remain counted');
 perform pg_temp.denied(format('select app_video_drift_check_finish(%L,%L,%L,''hold'',null)',x.sally,x.sally_org,first_id),'RP404:','stale check cannot reopen a newer running ordinal');
 perform pg_temp.ok(app_video_drift_check_finish(x.sally,x.sally_org,next_id,'refuse',result),'terminal verdict durably saved');
 c:=app_video_drift_check_begin(x.sally,x.sally_org,x.request_id,'reel',repeat('a',32),x.sally_listing);
 perform pg_temp.ok(c->>'replay'='true'and c->'result'=result and(c->>'id')::uuid=next_id,'terminal recovery returns same recorded response without new key');
 perform pg_temp.denied(format('select app_video_drift_check_finish(%L,%L,%L,''accept'',''{"drift":{"action":"accept","publishable":true}}'')',x.sally,x.sally_org,next_id),'RP409:','terminal refusal cannot be changed to acceptance');
 perform pg_temp.denied(format('select app_video_drift_check_begin(%L,%L,%L,''reel'',%L,%L)',x.owner_id,x.sally_org,x.request_id,repeat('a',32),x.sally_listing),'RP404:','Team owner cannot judge another actor paid request');
 perform pg_temp.denied(format('select app_video_drift_check_begin(%L,%L,%L,''reel'',%L,%L)',x.sally,x.sally_org,x.request_id,repeat('b',32),x.sally_listing),'RP409:','new source cannot recover existing clip verdict');
 perform pg_temp.denied(format('select app_video_drift_check_begin(%L,%L,%L,''reel'',%L,%L)',x.sally,x.sally_org,x.request_id,repeat('a',32),x.solo_listing),'RP404:','foreign declared listing cannot obtain verdict');
 perform pg_temp.denied(format('select app_video_drift_check_begin(%L,%L,''invented-request'',''reel'',%L,%L)',x.sally,x.sally_org,repeat('a',32),x.sally_listing),'RP404:','invented provider request cannot buy a check');
 perform pg_temp.denied(format('select app_video_drift_check_begin(%L,%L,%L,''aerial'',%L,%L)',x.sally,x.sally_org,x.request_id,repeat('a',32),x.sally_listing),'RP404:','wrong clip kind cannot reuse receipt');
end$$;
do $$declare x fixture;c jsonb;k text;old_id uuid;held jsonb:='{"drift":{"action":"hold","publishable":false},"kind":"aerial"}';begin
 select *into x from fixture;
 perform app_video_cost_settle(x.sally,x.sally_org,'team-video-2','crash-paid68');
 c:=app_video_drift_check_begin(x.sally,x.sally_org,'crash-paid68','aerial',repeat('c',32),x.sally_listing);old_id:=(c->>'id')::uuid;k:='drift-check:'||old_id;
 perform serving_operation_begin(x.sally,x.sally_org,k,'/ai-video/drift',repeat('f',64));
 perform serving_cost_reserve(x.sally,x.sally_org,k,'qc.initial:0','anthropic','fixture-judge',repeat('e',64),3,'published-standard-20261006');
 perform serving_cost_finish(x.sally,x.sally_org,k,'qc.initial:0','uncertain',null);
 perform serving_operation_complete(x.sally,x.sally_org,k,held);
 -- Simulate worker loss after saving the independent serving result, before
 -- the QC journal gets its finish call. No financial liability is released.
 c:=app_video_drift_check_begin(x.sally,x.sally_org,'crash-paid68','aerial',repeat('c',32),x.sally_listing);
 perform pg_temp.ok(c->>'ordinal'='2'and(c->>'id')::uuid<>old_id,'saved HOLD recovers an interrupted QC journal save');
 perform pg_temp.ok(exists(select 1 from serving_cost_reservations where request_key=k and state='uncertain'and hold_cents=3),'crash recovery keeps the old uncertain money hold');
 perform pg_temp.denied(format('select app_video_drift_check_begin(%L,%L,''crash-paid68'',''aerial'',%L,%L)',x.sally,x.sally_org,repeat('c',32),x.sally_listing),'RP409:','newly active ordinal cannot be reopened by another request');
end$$;
reset role;
-- Only the fixture owner changes its clock to simulate an abandoned worker.
update app_video_drift_checks set updated_at=clock_timestamp()-interval '9 minutes'where reservation_id=(select id from app_video_cost_reservations where idempotency_key='team-video-2');
set local role service_role;
do $$declare x fixture;c jsonb;begin select *into x from fixture;
 c:=app_video_drift_check_begin(x.sally,x.sally_org,'crash-paid68','aerial',repeat('c',32),x.sally_listing);
 perform pg_temp.ok(c->>'ordinal'='3','abandoned execution claim can recover after maximum worker lifetime');
 perform pg_temp.ok((select sum(hold_cents)=3 from serving_cost_reservations where actor_id=x.sally and request_key like 'drift-check:%'and input_sha256=repeat('e',64)and state='uncertain'),'execution timeout never refunds uncertain provider liability');
 perform pg_temp.ok(app_video_drift_check_finish(x.sally,x.sally_org,(c->>'id')::uuid,'hold',null),'fresh manual ordinal remains finishable');
end$$;
reset role;
insert into notification_devices(user_id,device_token,environment)select solo,repeat('c',64),'sandbox'from fixture;
set local role service_role;
do $$declare x fixture;r jsonb;begin select *into x from fixture;
 r:=notification_enqueue(x.solo_org,x.solo,'first_tour_nudge','{}','no-marketing-nudge68',now());
 perform pg_temp.ok(r->>'state'='skipped'and r->>'reason'='promotional_push_disabled','default-enabled first-tour push is suppressed');
 r:=notification_enqueue(x.solo_org,x.solo,'free_week_ending','{}','no-marketing-trial68',now());
 perform pg_temp.ok(r->>'state'='skipped'and r->>'reason'='promotional_push_disabled','default-enabled trial-ending push is suppressed');
 perform pg_temp.ok(not exists(select 1 from notification_outbox where dedupe_key in('no-marketing-nudge68','no-marketing-trial68')),'promotional push never reaches outbox');
 r:=notification_enqueue(x.solo_org,x.solo,'render_ready','{}','transactional-render68',now());
 perform pg_temp.ok(r->>'state'='queued','transactional render notice remains available');
end$$;
reset role;
select count(*)as build68_assertions from review_checks;
rollback;
