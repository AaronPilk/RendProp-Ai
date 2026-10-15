\set ON_ERROR_STOP on
begin;
create temp table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated,anon;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception'VIDEO SUBMISSION RECEIPT FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.denied(command text,label text,needle text default'RP409:')returns void language plpgsql as $$declare msg text;begin
 begin execute command;exception when others then msg:=sqlerrm;end;
 perform pg_temp.ok(position(needle in coalesce(msg,''))>0,label);end$$;
-- BEGIN SYNTHETIC FIXTURE: real immutable priced/allowance/serving/ledger rows,
-- no provider accepts or customer media. Prices are existing held facts only.
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
 ('f9100000-0000-4000-8000-000000000001','submission-owner@fixture.invalid',false,now()),
 ('f9100000-0000-4000-8000-000000000002','submission-other@fixture.invalid',false,now());
create temp table vf as select 'f9100000-0000-4000-8000-000000000001'::uuid actor,
 'f9100000-0000-4000-8000-000000000002'::uuid other,
 (select org_id from memberships where user_id='f9100000-0000-4000-8000-000000000001'and role='owner')org,
 (select org_id from memberships where user_id='f9100000-0000-4000-8000-000000000002'and role='owner')other_org,
 'f9300000-0000-4000-8000-000000000001'::uuid listing,
 'f9300000-0000-4000-8000-000000000002'::uuid other_listing;
insert into listings(id,org_id,agent_id,address)select listing,org,actor,'Synthetic held video home'from vf
 union all select other_listing,other_org,other,'Synthetic foreign video home'from vf;
grant select on vf to service_role,authenticated,anon;
create function pg_temp.ref(i integer)returns jsonb language sql as $$select jsonb_build_object(
 'provider','fal','model','fal-ai/kling-video/v3/4k/image-to-video','id','accepted-'||i,
 'poll_url','https://queue.fal.run/fal-ai/kling-video/requests/accepted-'||i||'/status',
 'submitted_at',to_char(now()at time zone'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))$$;
create function pg_temp.acceptance(i integer,paid boolean default false,hold_state text default'succeeded',wrong_input boolean default false,hold_amount numeric default 210,task text default'video.reel_clip',listing_override uuid default null,omit_allowance boolean default false)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$declare f record;r uuid:=gen_random_uuid();begin
 select*into f from vf;
 insert into app_video_cost_reservations(id,org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)
 values(r,f.org,f.actor,'animate-fixture:'||i,'reel','fal','fal-ai/kling-video/v3/4k/image-to-video',repeat('a',64),5,42,210,210,jsonb_build_object('task',task));
 if not omit_allowance then
  insert into app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)
  values(r,coalesce(listing_override,f.listing),'reelmo:'||f.org,now(),'aivideo:'||f.org,now());end if;
 insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state)
 values(f.org,f.actor,'animate-fixture:'||i,'reel','fal','fal-ai/kling-video/v3/4k/image-to-video',repeat(case when wrong_input then'b'else'a'end,64),'synthetic-existing-price',hold_amount,'ceiling',hold_state);
 if paid then perform app_video_cost_settle(f.actor,f.org,'animate-fixture:'||i,'accepted-'||i);end if;
 return r;end$$;
set local role service_role;
select pg_temp.acceptance(1);select pg_temp.acceptance(2,true);
reset role;
-- END SYNTHETIC FIXTURE
select pg_temp.ok((select relrowsecurity from pg_class where oid='app_video_submission_receipts'::regclass),'receipt RLS enabled');
select pg_temp.ok(not has_table_privilege(r,'app_video_submission_receipts','SELECT,INSERT,UPDATE,DELETE'),'no direct table access for '||r)
 from unnest(array['anon','authenticated','service_role'])r;
select pg_temp.ok(not has_function_privilege(r,'app_video_submission_receipt_save(uuid,uuid,text,uuid,jsonb)','execute')
 and not has_function_privilege(r,'app_video_submission_receipt_read(uuid,uuid,text,uuid)','execute'),'receipt RPCs private for '||r)from unnest(array['anon','authenticated'])r;
select pg_temp.ok(has_function_privilege('service_role','app_video_submission_receipt_save(uuid,uuid,text,uuid,jsonb)','execute')
 and has_function_privilege('service_role','app_video_submission_receipt_read(uuid,uuid,text,uuid)','execute'),'service RPCs callable');
create temp table before_money as select
 (select jsonb_object_agg(id,md5(to_jsonb(x)::text))from cost_ledger x)ledger,
 (select jsonb_object_agg(id,md5(to_jsonb(x)::text))from app_video_cost_reservations x)app,
 (select jsonb_object_agg(id,md5(to_jsonb(x)::text))from serving_cost_reservations x)serving,
 (select jsonb_object_agg(reservation_id,md5(to_jsonb(x)::text))from app_video_allowance_receipts x)allowances;
grant select on before_money to service_role;
set local role service_role;
do $$declare f record;r jsonb;s jsonb;x jsonb;resid uuid;lid uuid:=gen_random_uuid();part text;begin
 select*into f from vf;
 r:=app_video_submission_receipt_read(f.actor,f.org,'animate-fixture:unknown',f.listing);
 perform pg_temp.ok(r=jsonb_build_object('status','pending','actor_id',f.actor,'org_id',f.org,'listing_id',f.listing,'operation_id','animate-fixture:unknown'),'unknown receipt stays pending with exact scope');
 r:=app_video_submission_receipt_read(f.actor,f.org,'animate-fixture:1',f.listing);
 perform pg_temp.ok(r->>'status'='pending'and not(r?'receipt'),'existing reservation cannot fabricate a provider receipt');
 r:=app_video_submission_receipt_save(f.actor,f.org,'animate-fixture:1',f.listing,pg_temp.ref(1));
 perform pg_temp.ok(r=jsonb_build_object('saved',true,'receipt',pg_temp.ref(1)),'held succeeded acceptance saved before settlement');
 r:=app_video_submission_receipt_read(f.actor,f.org,'animate-fixture:1',f.listing);
 perform pg_temp.ok(r=jsonb_build_object('status','accepted','actor_id',f.actor,'org_id',f.org,'listing_id',f.listing,'operation_id','animate-fixture:1','receipt',pg_temp.ref(1)),'held acceptance readable without settlement');
 perform pg_temp.ok(app_video_submission_receipt_save(f.actor,f.org,'animate-fixture:1',f.listing,pg_temp.ref(1))->>'saved'='true','exact immutable replay acknowledged');
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:1',f.listing,pg_temp.ref(1)||jsonb_build_object('submitted_at',to_char((now()+interval'1 second')at time zone'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))),'original submitted_at cannot change');
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:1',f.listing,pg_temp.ref(100)),'held acceptance cannot replace first provider request');
 r:=app_video_submission_receipt_save(f.actor,f.org,'animate-fixture:2',f.listing,pg_temp.ref(2));
 perform pg_temp.ok(r->>'saved'='true'and app_video_submission_receipt_read(f.actor,f.org,'animate-fixture:2',f.listing)->>'status'='accepted','settled exact paid acceptance saved and read');
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:2',f.listing,pg_temp.ref(3)),'settled request identity cannot change');
 foreach part in array array['reserved','uncertain','rejected']loop
  resid:=pg_temp.acceptance(case part when'reserved'then 3 when'uncertain'then 4 else 5 end,false,part);
  perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:'||(case part when'reserved'then 3 when'uncertain'then 4 else 5 end),f.listing,pg_temp.ref(case part when'reserved'then 3 when'uncertain'then 4 else 5 end)),'unknown or rejected serving hold cannot authorize acceptance '||part);
 end loop;
 perform pg_temp.acceptance(6,false,'succeeded',true);
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:6',f.listing,pg_temp.ref(6)),'held input hash exact');
 perform pg_temp.acceptance(7,false,'succeeded',false,209);
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:7',f.listing,pg_temp.ref(7)),'held price must cover accepted attempt');
 perform pg_temp.acceptance(8,false,'succeeded',false,210,'video.aerial');
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:8',f.listing,pg_temp.ref(8)),'nonreel task refused');
 perform pg_temp.acceptance(10,false,'succeeded',false,210,'video.reel_clip',f.other_listing);
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:10',f.listing,pg_temp.ref(10)),'allowance must bind the exact listing');
 perform pg_temp.acceptance(11,false,'succeeded',false,210,'video.reel_clip',null,true);
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:11',f.listing,pg_temp.ref(11)),'missing allowance cannot authorize acceptance');
 perform pg_temp.acceptance(12);perform app_video_cost_release_rejected(f.actor,f.org,'animate-fixture:12',403,'upstream');
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:12',f.listing,pg_temp.ref(12)),'released admission cannot authorize acceptance');
 resid:=pg_temp.acceptance(13);
 insert into cost_ledger(id,org_id,feature,provider,model,total_cents,meta)values(lid,f.org,'reel','fal','fal-ai/kling-video/v3/4k/image-to-video',210,
  jsonb_build_object('app_video_reservation_id',resid,'request_key','animate-fixture:13','stage','reel','request_id','foreign-request','billing_org_id',f.org));
 update app_video_cost_reservations set provider_request_id='accepted-13',cost_ledger_id=lid,settled_at=now()where app_video_cost_reservations.id=resid;
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:13',f.listing,pg_temp.ref(13)),'paid ledger request must match the accepted request');
 perform pg_temp.acceptance(9);
 for x in select value from jsonb_array_elements(jsonb_build_array(
  pg_temp.ref(9)-'submitted_at',pg_temp.ref(9)||'{"extra":"forged"}',pg_temp.ref(9)||'{"provider":"kie"}',pg_temp.ref(9)||'{"model":"different/model"}',
  pg_temp.ref(9)||'{"poll_url":"https://evil.invalid/requests/accepted-9/status"}',
  pg_temp.ref(9)||'{"poll_url":"https://queue.fal.run/fal-ai/other/requests/accepted-9/status"}',
  pg_temp.ref(9)||'{"poll_url":"https://queue.fal.run/fal-ai/kling-video/requests/foreign/status"}',
  pg_temp.ref(9)||'{"poll_url":"https://queue.fal.run/fal-ai/kling-video/requests/accepted-9/status?secret=forged"}',
  pg_temp.ref(9)||'{"poll_url":"https://name:password@queue.fal.run/fal-ai/kling-video/requests/accepted-9/status"}',
  pg_temp.ref(9)||'{"submitted_at":"infinity"}',pg_temp.ref(9)||'{"submitted_at":"2026-99-99T00:00:00Z"}',
  pg_temp.ref(9)||jsonb_build_object('submitted_at',to_char((now()+interval'6 minutes')at time zone'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
  pg_temp.ref(9)||jsonb_build_object('submitted_at',to_char((now()-interval'6 minutes')at time zone'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))))loop
  perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:9',f.listing,x),'malformed, foreign or fabricated receipt refused '||md5(x::text),'RP4');
 end loop;
 x:=pg_temp.ref(9)||jsonb_build_object('poll_url','https://queue.fal.run/fal-ai/kling-video/v3/4k/image-to-video/requests/accepted-9/status');
 perform pg_temp.ok(app_video_submission_receipt_save(f.actor,f.org,'animate-fixture:9',f.listing,x)->'receipt'=x,'exact full-model endpoint accepted without URL rewriting');
 perform pg_temp.acceptance(14);
 x:=pg_temp.ref(14)||jsonb_build_object('id',repeat('x',256),'poll_url','https://queue.fal.run/fal-ai/kling-video/requests/'||repeat('x',256)||'/status');
 perform pg_temp.ok(app_video_submission_receipt_save(f.actor,f.org,'animate-fixture:14',f.listing,x)->'receipt'=x,'256-character provider request accepted exactly');
 perform pg_temp.acceptance(15);
 x:=pg_temp.ref(15)||jsonb_build_object('id',repeat('x',257),'poll_url','https://queue.fal.run/fal-ai/kling-video/requests/'||repeat('x',257)||'/status');
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:15',f.listing,x),'257-character provider request refused','RP400:');
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.other,f.org,'animate-fixture:1',f.listing,pg_temp.ref(1)),'foreign actor cannot adopt receipt','RP403:');
 perform pg_temp.denied(format('select app_video_submission_receipt_read(%L,%L,%L,%L)',f.actor,f.other_org,'animate-fixture:1',f.listing),'wrong physical org refused','RP404:');
 perform pg_temp.denied(format('select app_video_submission_receipt_read(%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:1',f.other_listing),'foreign listing refused','RP403:');
 r:=app_video_submission_receipt_read(f.other,f.other_org,'animate-fixture:1',f.other_listing);
 perform pg_temp.ok(r->>'status'='pending'and r->>'actor_id'=f.other::text,'another own library reveals no foreign operation');
 perform pg_temp.ok(not exists(select 1 from jsonb_each((select ledger from before_money))b where
  (select md5(to_jsonb(old_row)::text)from cost_ledger old_row where old_row.id=b.key::uuid)is distinct from b.value#>>'{}'),'receipt save/read never settles or changes old paid records');
 perform pg_temp.ok(not exists(select 1 from jsonb_each((select app from before_money))b where
  (select md5(to_jsonb(old_row)::text)from app_video_cost_reservations old_row where old_row.id=b.key::uuid)is distinct from b.value#>>'{}'),'receipt save/read preserves old reservation facts');
 perform pg_temp.ok(not exists(select 1 from jsonb_each((select serving from before_money))b where
  (select md5(to_jsonb(old_row)::text)from serving_cost_reservations old_row where old_row.id=b.key::uuid)is distinct from b.value#>>'{}'),'receipt save/read preserves old serving holds');
 perform pg_temp.ok(not exists(select 1 from jsonb_each((select allowances from before_money))b where
  (select md5(to_jsonb(old_row)::text)from app_video_allowance_receipts old_row where old_row.reservation_id=b.key::uuid)is distinct from b.value#>>'{}'),'receipt save/read preserves old quota charges');
end$$;
reset role;
do $$declare f record;before jsonb;begin select*into f from vf;
 perform pg_temp.denied('update app_video_submission_receipts set receipt=receipt||''{"submitted_at":"2026-01-01T00:00:00Z"}''','privileged UPDATE cannot rewrite first receipt');
 update memberships set role='marketing'where user_id=f.actor and org_id=f.org;
 set local role service_role;
 perform pg_temp.ok(app_video_submission_receipt_read(f.actor,f.org,'animate-fixture:1',f.listing)->>'status'='accepted','current read-only paid actor status remains readable');
 reset role;update memberships set role='owner'where user_id=f.actor and org_id=f.org;
 update orgs set deleted_at=now()where id=f.org;set local role service_role;
 perform pg_temp.denied(format('select app_video_submission_receipt_read(%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:1',f.listing),'revoked org denies saved receipt','RP403:');
 reset role;update orgs set deleted_at=null where id=f.org;
 insert into deletion_requests(user_id,status)values(f.actor,'pending');set local role service_role;
 perform pg_temp.denied(format('select app_video_submission_receipt_read(%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:1',f.listing),'pending deletion denies saved receipt','RP403:');
 reset role;delete from deletion_requests where user_id=f.actor;
 select jsonb_agg(to_jsonb(r)order by reservation_id)into before from app_video_submission_receipts r;
 set local role service_role;perform app_video_cost_settle(f.actor,f.org,'animate-fixture:1','accepted-1');
 perform pg_temp.ok(app_video_submission_receipt_read(f.actor,f.org,'animate-fixture:1',f.listing)->>'status'='accepted','same acceptance survives later exact settlement');
 reset role;perform pg_temp.ok((select jsonb_agg(to_jsonb(r)order by reservation_id)=before from app_video_submission_receipts r),'settlement cannot rewrite original receipt or timestamp');
 -- Production account deletion itself inventories and deletes this owned
 -- listing/org. Its FK cascades remove receipts, retaining payment tombstones.
 set local role service_role;perform prepare_account_deletion(f.actor,'fixture-uploads','fixture-renders');reset role;
 perform pg_temp.ok(not exists(select 1 from app_video_submission_receipts where actor_id=f.actor),'canonical account erasure cascades private acceptance receipts');
 perform pg_temp.ok(exists(select 1 from app_video_cost_reservations where actor_id=f.actor and cost_ledger_id is not null),'canonical erasure retains paid accounting tombstones');
 set local role service_role;
 perform pg_temp.denied(format('select app_video_submission_receipt_save(%L,%L,%L,%L,%L)',f.actor,f.org,'animate-fixture:1',f.listing,pg_temp.ref(1)),'late saved receipt cannot resurrect erased listing','RP404:');
end$$;
reset role;
set local role authenticated;
select pg_temp.denied('select app_video_submission_receipt_read(null,null,''forged-op'',null)','client cannot call private read','permission denied');
reset role;
select jsonb_build_object('passed',true,'assertions',n)from checks;
rollback;
