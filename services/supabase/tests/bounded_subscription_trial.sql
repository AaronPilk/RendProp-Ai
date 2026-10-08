\set ON_ERROR_STOP on
begin;
-- Funded-model regression: pin funded serving mode for this transaction. The
-- live default since 2026-10-08 is ceiling mode (migration 20261008201736);
-- ceiling-mode admission is covered by launch_blockers.sql.
update public.app_config set value=value||'{"mode":"funded"}'::jsonb where key='serving_mode';
create temp table trial_checks(n integer default 0);
insert into trial_checks default values;
grant all on trial_checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'TRIAL FAIL: %',label;end if;update trial_checks set n=n+1;
end$$;
create function pg_temp.denied(command text,prefix text,label text)returns void language plpgsql as $$begin
 begin execute command;exception when others then if position(prefix in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;
 raise exception 'TRIAL FAIL expected %: %',prefix,label;
end$$;
create temp table fixture(u uuid,o uuid,free_o uuid,l uuid,other_l uuid,free_l uuid,a uuid,b uuid,free_a uuid,g uuid,job uuid);
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('c1000000-0000-4000-8000-000000000001','bounded-trial@example.invalid',false,now());
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('c1000000-0000-4000-8000-000000000002','bounded-trial-member@example.invalid',false,now());
insert into orgs(id,name,plan,plan_source)values
 ('c2000000-0000-4000-8000-000000000001','Synthetic bounded Apple trial','free','apple'),
 ('c2000000-0000-4000-8000-000000000002','Synthetic switched free workspace','free','manual');
insert into memberships(user_id,org_id,role)values('c1000000-0000-4000-8000-000000000001','c2000000-0000-4000-8000-000000000001','owner'),('c1000000-0000-4000-8000-000000000001','c2000000-0000-4000-8000-000000000002','owner');
insert into memberships(user_id,org_id,role)values('c1000000-0000-4000-8000-000000000002','c2000000-0000-4000-8000-000000000001','agent');
insert into fixture values('c1000000-0000-4000-8000-000000000001','c2000000-0000-4000-8000-000000000001','c2000000-0000-4000-8000-000000000002',gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),null,null);
grant all on fixture to service_role,authenticated;
insert into listings(id,org_id,agent_id,address)select l,o,u,'Synthetic first trial listing'from fixture union all select other_l,o,u,'Synthetic second trial listing'from fixture union all select free_l,free_o,u,'Synthetic switched free listing'from fixture;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,duration_s,bytes,transport_version,content_type)
 select a,l,'video','renders','renders/'||o||'/'||l||'/'||a||'.mp4',true,60,100,2,'video/mp4' from fixture union all
 select b,other_l,'video','renders','renders/'||o||'/'||other_l||'/'||b||'.mp4',true,60,100,2,'video/mp4' from fixture union all
 select free_a,free_l,'video','renders','renders/'||free_o||'/'||free_l||'/'||free_a||'.mp4',true,60,100,2,'video/mp4' from fixture;
-- Synthetic videos were finalized before the trial began; no ingress credits
-- are manufactured after the fixture fills its real trial upload meter.
update orgs set plan_source='manual'where id=(select o from fixture);
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,state,settled_at)
 select a.id,f.o,a.listing_id,f.u,current_date,'{}',0,'completed',clock_timestamp()from fixture f join capture_assets a on a.id in(f.a,f.b);
insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)
 select a.id,'copy','renders',a.storage_key,100,a.bytes,'video/mp4',true,'video','retained','synthetic-trial-video-'||a.id from fixture f join capture_assets a on a.id in(f.a,f.b);
update orgs set plan_source='apple'where id=(select o from fixture);
select pg_temp.ok(not enabled,'source migration leaves activation disabled')from subscription_trial_config;
select pg_temp.ok(not has_table_privilege(r,t,'INSERT,UPDATE,DELETE'),'trial counters cannot be rewritten by '||r||' '||t)
 from unnest(array['anon','authenticated','service_role'])r cross join unnest(array['subscription_trial_grants','subscription_trial_actions','subscription_trial_config'])t;
set local role service_role;
do $$declare f record;t timestamptz:=now()-interval '1 minute';e timestamptz:=t+interval '7 days';s timestamptz:=now()-interval '20 seconds';r jsonb;a uuid:=gen_random_uuid();begin
 select * into f from fixture;
 perform apply_apple_entitlement_v2(f.o,f.u,'synthetic-bounded-original','synthetic-bounded-trial-tx','com.rendprop.app.starter.monthly','starter','Production','active',e,true,'SUBSCRIBED',t,s,s,s);
 r:=fund_verified_apple_transaction(f.o,'synthetic-bounded-original','synthetic-bounded-trial-tx','com.rendprop.app.starter.monthly',0,'USD','USA',1,'FREE_TRIAL',t,e,s,repeat('a',64));
 perform pg_temp.ok(r->>'reason'='trial_purchase_reservation_required'and not exists(select 1 from serving_funding where org_id=f.o),'disabled config neither promises nor funds a new trial');
 perform pg_temp.ok(subscription_trial_context(f.u,f.o)='{"trial_usage":null,"trial_offer":null}'::jsonb,'no dormant numeric offer');
 perform pg_temp.ok(subscription_serving_activation(f.u,f.o)->>'available'='false','signed unpaid trial never displays usable paid service');
 perform pg_temp.denied(format('select reserve_upload_assets(%L,%L::jsonb)',f.u,jsonb_build_array(jsonb_build_object('id',a,'listing_id',f.l,'kind','photo','bucket','uploads','storage_key','uploads/'||f.o||'/'||f.l||'/'||a||'.jpg','bytes',10,'content_type','image/jpeg','content_type_declared',true,'idem_key','unfunded-trial-upload'))),'RP402','unfunded Apple trial cannot create a new cloud upload');
end$$;
reset role;
delete from apple_subscriptions where original_transaction_id='synthetic-bounded-original';
update orgs set plan='free',plan_expires_at=null where id=(select o from fixture);
-- Local synthetic funding only. No owner dollars or schedules are launch seeds.
update subscription_trial_config set enabled=true;
insert into serving_sponsor_pools(collection_ref,source,funded_cents,starts_at,ends_at,evidence_sha256)values('synthetic-bounded-local-pool','trial',5000,now()-interval '1 day',now()+interval '1 day',repeat('b',64));
insert into apple_serving_schedules(product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_sponsored_cents,trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
 select 'com.rendprop.app.starter.monthly','USA','USD',49000,4165,1,now()-interval '1 day',now()+interval '1 day',
 '{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}',500,
 '{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}',7,id,repeat('b',64)from serving_sponsor_pools where collection_ref='synthetic-bounded-local-pool';
update serving_sponsor_pools set admissions_enabled=true where collection_ref='synthetic-bounded-local-pool';
set local role service_role;
select prepare_subscription_trial_purchase(u,o,'com.rendprop.app.starter.monthly')from fixture;
reset role;
-- Disposable fixture clock advance: cash admission precedes the original
-- minute-old verified purchase, preserving genuine later paid-renewal ordering.
update subscription_trial_purchase_reservations set held_at=now()-interval '2 minutes'where actor_id=(select u from fixture);
set local role service_role;
do $$declare f record;r jsonb;begin select * into f from fixture;
 perform apply_apple_entitlement_v2(f.o,f.u,'synthetic-bounded-original','synthetic-bounded-trial-tx','com.rendprop.app.starter.monthly','starter','Production','active',now()-interval '1 minute'+interval '7 days',true,'SUBSCRIBED',now()-interval '1 minute',now()-interval '20 seconds',now()-interval '20 seconds',now()-interval '20 seconds');
 r:=fund_reserved_subscription_trial(f.u,f.o,'synthetic-bounded-original','synthetic-bounded-trial-tx','com.rendprop.app.starter.monthly',0,'USD','USA',1,'FREE_TRIAL',now()-interval '1 minute',now()-interval '1 minute'+interval '7 days',now()-interval '20 seconds',repeat('a',64));
 -- now() is stable for this transaction and matches the accepted chronology.
 perform pg_temp.ok((r->>'funded')::boolean and(select count(*)=1 from subscription_trial_grants where actor_id=f.u),'accepted funded trial registers atomically');
 perform pg_temp.ok(subscription_serving_activation(f.u,f.o)->>'authority'='funded_trial','funded registered trial has separately verified serving authority');
 update fixture set g=(select id from subscription_trial_grants where actor_id=f.u);
 r:=fund_reserved_subscription_trial(f.u,f.o,'synthetic-bounded-original','synthetic-bounded-trial-tx','com.rendprop.app.starter.monthly',0,'USD','USA',1,'FREE_TRIAL',now()-interval '1 minute',now()-interval '1 minute'+interval '7 days',now()-interval '20 seconds',repeat('a',64));
 perform pg_temp.ok((r->>'replay')::boolean and(select count(*)=1 from subscription_trial_grants where actor_id=f.u),'restore never resets lifetime grant');
 perform pg_temp.denied(format('select serving_cost_reserve(%L,%L,''trial-expensive-key'',''video.reel:0'',''fal'',''synthetic'',%L,1,''synthetic'')',f.u,f.o,repeat('a',64)),'RP402','paid video/reel/aerial/upscale/spatial stage is excluded');
 perform pg_temp.ok(not exists(select 1 from serving_cost_reservations where request_key='trial-expensive-key'),'excluded generation has no dispatch hold');
 -- Helpers have no trial credit and therefore cannot silently consume the
 -- sponsor cash intended for the five included image admissions.
 perform pg_temp.denied(format('select serving_cost_reserve(%L,%L,''trial-suggest-early-key'',''photo.suggest'',''gemini'',''synthetic'',%L,1,''synthetic'')',f.u,f.o,repeat('a',64)),'RP402','trial suggestion refused before any photo credit or cash is spent');
 perform pg_temp.denied(format('select serving_cost_reserve(%L,%L,''trial-prompt-early-key'',''photo.improve_prompt'',''gemini'',''synthetic'',%L,1,''synthetic'')',f.u,f.o,repeat('a',64)),'RP402','trial prompt rewriting refused before any photo credit or cash is spent');
 perform pg_temp.ok(not exists(select 1 from serving_cost_reservations where org_id=f.o)and not exists(select 1 from subscription_trial_actions where grant_id=(select g from fixture)),'denied trial helpers leave all five photo credits and provider cash untouched');
 perform serving_cost_reserve(f.u,f.o,'trial-photo-key-0','photo.declutter:0','gemini','synthetic',repeat('a',64),1,'synthetic');
 perform serving_cost_finish(f.u,f.o,'trial-photo-key-0','photo.declutter:0','rejected',429);
 perform serving_cost_reserve(f.u,f.o,'trial-photo-key-0','photo.declutter:1','fal','synthetic',repeat('a',64),1,'synthetic');
 perform serving_cost_finish(f.u,f.o,'trial-photo-key-0','photo.declutter:1','uncertain',null);
 for i in 1..4 loop perform serving_cost_reserve(f.u,f.o,'trial-photo-key-'||i,'photo.sky:0','gemini','synthetic',repeat('a',64),1,'synthetic');end loop;
 perform pg_temp.ok((select count(*)=5 from subscription_trial_actions where org_id=f.o and kind='photo'),'fallbacks share a single photo admission');
 perform pg_temp.denied(format('select serving_cost_reserve(%L,%L,''trial-photo-key-5'',''photo.stage:0'',''gemini'',''synthetic'',%L,1,''synthetic'')',f.u,f.o,repeat('a',64)),'RP402','sixth photo denied before provider');
 perform pg_temp.ok((select sum(hold_cents)=5 from serving_cost_reservations where org_id=f.o and state<>'rejected'),'reserved and ambiguous liability preserved independently of credits');
 perform pg_temp.ok((subscription_trial_context(f.u,f.o)#>>'{trial_usage,photo_edits,remaining}')::int=0 and subscription_trial_context(f.u,f.o)#>>'{trial_usage,status}'='active','individual exhausted bucket does not hide usable walkthrough/publication');
end$$;
create function pg_temp.ticket(o uuid,l uuid,id uuid,idem text,n bigint)returns jsonb language sql as $$select jsonb_build_array(jsonb_build_object('id',id,'listing_id',l,'kind',case when n>52428800 then 'video'else 'photo'end,'bucket','uploads','storage_key','uploads/'||o||'/'||l||'/'||id||case when n>52428800 then '.mp4'else '.jpg'end,'bytes',n,'parts_total',case when n>67108864 then ceil(n/33554432.0)::integer else null end,'part_size',case when n>67108864 then 33554432 else null end,'content_type',case when n>52428800 then 'video/mp4'else 'image/jpeg'end,'content_type_declared',true,'idem_key',idem));$$;
do $$declare f record;r jsonb;id uuid:=gen_random_uuid();begin select * into f from fixture;
 perform pg_temp.denied(format('select reserve_upload_assets(%L,%L)','c1000000-0000-4000-8000-000000000002',pg_temp.ticket(f.o,f.l,gen_random_uuid(),'trial-second-member-idem',10)),'RP403','another member cannot bypass the trial destination-org lifetime budget');
 r:=reserve_upload_assets(f.u,pg_temp.ticket(f.o,f.l,id,'trial-upload-stable-idem',10));
 perform pg_temp.ok((subscription_trial_context(f.u,f.o)#>>'{trial_usage,upload_used_bytes}')::bigint=20,'lifetime ingress counts real PUT plus copy holds');
 r:=reserve_upload_assets(f.u,pg_temp.ticket(f.o,f.l,gen_random_uuid(),'trial-upload-stable-idem',10));
 perform pg_temp.ok(r#>>'{0,replayed}'='true'and(select count(*)=1 from subscription_trial_actions where org_id=f.o and kind='upload'),'upload retry does not double lifetime bytes');
 r:=reserve_upload_assets(f.u,pg_temp.ticket(f.o,f.l,gen_random_uuid(),'trial-full-budget-idem',1073741804));
 perform pg_temp.ok((subscription_trial_context(f.u,f.o)#>>'{trial_usage,upload_used_bytes}')::bigint=1073741824 and subscription_trial_context(f.u,f.o)#>>'{trial_usage,status}'='active','full ingress keeps usable walkthrough/publication active');
 perform pg_temp.denied(format('select reserve_upload_assets(%L,%L)',f.u,pg_temp.ticket(f.o,f.l,gen_random_uuid(),'trial-over-budget-idem',10)),'RP402','lifetime upload ceiling precedes storage admission');
 perform pg_temp.denied(format('select reserve_upload_assets(%L,%L)',f.u,pg_temp.ticket(f.free_o,f.free_l,gen_random_uuid(),'trial-switch-org-idem',10)),'RP402','switching free workspace cannot reset ingress');
end$$;
reset role;
-- Simulate the durable transport/history crossing a UTC month; neither date
-- filter nor reservation release is allowed to replenish lifetime counters.
update subscription_trial_actions set created_at=date_trunc('month',now())-interval '1 day'where grant_id=(select g from fixture);
update upload_reservations set day=(date_trunc('month',now())-interval '1 day')::date where org_id=(select o from fixture);
set local role service_role;
do $$declare f record;begin select * into f from fixture;
 perform pg_temp.denied(format('select reserve_upload_assets(%L,%L)',f.u,pg_temp.ticket(f.o,f.l,gen_random_uuid(),'trial-new-month-idem',10)),'RP402','a new UTC month does not reset lifetime ingress');
 perform pg_temp.ok((subscription_trial_context(f.u,f.o)#>>'{trial_usage,photo_edits,used}')::int=5 and(subscription_trial_context(f.u,f.o)#>>'{trial_usage,upload_used_bytes}')::bigint=1073741824,'historical action dates never replenish photo or ingress counters');
end$$;
reset role;
-- Explicit local attestation fixture; never a production probe or cash seed.
set local role service_role;
select record_subscription_trial_video(f.u,f.o,a.listing_id,a.id,'renders',a.storage_key,'synthetic-trial-video-'||a.id,a.bytes,60,60,'mp4-timing-v1')
 from fixture f join capture_assets a on a.id in(f.a,f.b);
reset role;
do $$begin perform set_config('request.jwt.claim.sub',(select u::text from fixture),true);end$$;
set local role authenticated;
do $$declare f record;j public.render_jobs;r public.renders;begin select * into f from fixture;
 j:=create_render_job(f.l,f.a,'smooth','{}','trial-hosted-video-key','app');update fixture set job=j.id;
 r:=publish_render(j.id,60,2,'[]',null);
 perform pg_temp.ok(r.job_id=j.id,'actual publication returns its admitted walkthrough');
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''trial-second-video-key'',''app'')',f.other_l,f.b),'RP402','second trial video/listing denied at SQL boundary');
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''trial-free-workspace-key'',''app'')',f.free_l,f.free_a),'RP402','new unfunded free workspace cannot publish');
end$$;
reset role;
select pg_temp.ok((select count(*)=1 from subscription_trial_actions where grant_id=(select g from fixture)and kind='publication'),'actual publication boundary counts one distinct listing');
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,transport_version,bytes)
 select gen_random_uuid(),l,'photo','uploads','uploads/'||o||'/'||l||'/legacy-trial-cleanup.jpg',false,1,10 from fixture;
set local role service_role;
do $$declare f record;legacy uuid;r jsonb;begin select * into f from fixture;
 select id into legacy from capture_assets where listing_id=f.l and transport_version=1 and uploaded is false;
 r:=cancel_legacy_upload(legacy,f.u);
 perform pg_temp.ok((select state='cancelled'and held_bytes=0 from upload_reservations where asset_id=legacy),'retired v1 cancellation remains available when trial ingress is full');
 perform pg_temp.ok((subscription_trial_context(f.u,f.o)#>>'{trial_usage,upload_used_bytes}')::bigint=1073741824,'legacy cleanup never refunds or adds lifetime trial ingress');
 perform pg_temp.denied(format('select serving_cost_reserve(%L,%L,''trial-exhausted-helper-key'',''photo.suggest'',''gemini'',''synthetic'',%L,1,''synthetic'')',f.u,f.o,repeat('a',64)),'RP402','all included actions exhausted also stops new paid trial helpers');
end$$;
reset role;
update auth.users set is_anonymous=true where id=(select u from fixture);
set local role service_role;
do $$declare f record;begin select * into f from fixture;
 perform pg_temp.denied(format('select serving_cost_reserve(%L,%L,''trial-denamed-owner-key'',''photo.sky:0'',''gemini'',''synthetic'',%L,1,''synthetic'')',f.u,f.o,repeat('a',64)),'RP403','denamed actor cannot obtain another provider admission');
 perform pg_temp.ok(subscription_trial_context(f.u,f.o)#>>'{trial_usage,status}'='expired','denamed actor has no current active trial authority');
end$$;
reset role;
update auth.users set is_anonymous=false where id=(select u from fixture);
-- Metadata survives expiry; existing job/publication retries run before insert.
update subscription_trial_grants set starts_at=now()-interval '7 days',ends_at=now()-interval '1 second'where id=(select g from fixture);
set local role service_role;
do $$declare f record;begin select * into f from fixture;
 perform pg_temp.ok(subscription_trial_context(f.u,f.o)#>>'{trial_usage,status}'='expired','exact grant cutoff visible without deleting saved work');
 perform pg_temp.denied(format('select serving_cost_reserve(%L,%L,''trial-after-expiry-key'',''photo.sky:0'',''gemini'',''synthetic'',%L,1,''synthetic'')',f.u,f.o,repeat('a',64)),'RP402','expiry prevents new provider dispatch despite Apple raw active plan');
end$$;
set local role authenticated;
do $$declare f record;j public.render_jobs;r public.renders;begin select * into f from fixture;
 j:=create_render_job(f.l,f.a,'smooth','{}','trial-hosted-video-key','app');r:=publish_render(f.job,60,2,'[]',null);
 perform pg_temp.ok(j.id=f.job and r.job_id=f.job,'same recorded job and publication replay after expiry');
end$$;
reset role;
-- A signed funded paid renewal wins; old trial meters and restrictions vanish,
-- but original trial tombstones cannot be transferred or recreated.
set local role service_role;
do $$declare f record;t timestamptz:=now()-interval '30 seconds';e timestamptz;s timestamptz:=now();r jsonb;begin select * into f from fixture;e:=t+interval '1 month';
 perform apply_apple_entitlement_v2(f.o,f.u,'synthetic-bounded-original','synthetic-bounded-paid-tx','com.rendprop.app.starter.monthly','starter','Production','active',e,true,'DID_RENEW',t,s,s,s);
 r:=fund_verified_apple_transaction(f.o,'synthetic-bounded-original','synthetic-bounded-paid-tx','com.rendprop.app.starter.monthly',49000,'USD','USA',null,null,t,e,s,repeat('c',64));
 perform pg_temp.ok((r->>'funded')::boolean and subscription_trial_paid_or_override(f.o),'current paid renewal uses verified retail funding');
 perform pg_temp.ok(subscription_serving_activation(f.u,f.o)->>'authority'='verified_retail','verified paid renewal supersedes trial serving presentation');
 perform pg_temp.ok(subscription_trial_context(f.u,f.o)->'trial_usage'='null'::jsonb,'historical trial does not replace paid meters');
 perform serving_cost_reserve(f.u,f.o,'paid-helper-after-trial','photo.suggest','gemini','gemini-3.6-flash',repeat('a',64),158.0544,'synthetic-bounded-helper');
 perform pg_temp.ok(exists(select 1 from serving_cost_reservations where org_id=f.o and request_key='paid-helper-after-trial'and hold_cents=158.0544),'verified paid renewal retains separately metered helper availability');

 perform serving_cost_reserve(f.u,f.o,'after-paid-renewal-key','video.reel:0','fal','synthetic',repeat('a',64),1,'synthetic');
end$$;
reset role;
-- Deliberate local historical overlap: current retail has precedence for the
-- former grantee and another member, regardless of physical row ordering.
update serving_funding set revoked_at=null where id=(select funding_id from subscription_trial_grants where id=(select g from fixture));
set local role service_role;
do $$declare f record;begin select * into f from fixture;
 perform pg_temp.ok(subscription_serving_activation(f.u,f.o)->>'authority'='verified_retail','paid renewal wins over overlapping prior sponsor row');
 perform pg_temp.ok(subscription_serving_activation('c1000000-0000-4000-8000-000000000002',f.o)->>'authority'='verified_retail','paid workspace service is not incorrectly limited to previous trial grantee');
end$$;
reset role;
-- Existing finite sponsor authority is preserved; a nominal or bare old row
-- does not become a publication grant. These fixtures roll back with the suite.
update orgs set plan='trial',plan_source='trial',trial_ends_at=now()+interval '7 days'where id=(select free_o from fixture);
insert into memberships(user_id,org_id,role)select 'c1000000-0000-4000-8000-000000000002',free_o,'agent'from fixture;
do $$declare x record;f uuid;j public.render_jobs;begin select * into x from fixture;
 insert into serving_funding(org_id,source,collection_ref,actor_id,net_receipts_cents,sponsored_cents,starts_at,ends_at,retention_ends_at,service_months,recurring_reserve_cents,reserve_components,evidence_sha256)
 values(x.free_o,'trial','synthetic-historical-trial',x.u,0,500,now()-interval '1 day',now()+interval '7 days',now()+interval '97 days',1,7,
 '{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}',repeat('a',64))returning id into f;
 update serving_funding set created_at=(select created_at-interval '1 day'from subscription_trial_config where singleton)where id=f;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''historical-no-slice-key'',''app'')',x.free_l,x.free_a),'RP402','bare historical sponsor row is not finite serving authority');
 insert into serving_funding_slices(funding_id,slice_index,org_id,starts_at,ends_at,total_budget_cents,recurring_reserve_cents)values(f,0,x.free_o,now()-interval '1 day',now()+interval '7 days',500,7);
 update serving_funding set created_at=(select created_at from subscription_trial_config where singleton)where id=f;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''historical-current-key'',''app'')',x.free_l,x.free_a),'RP402','current-config unregistered trial cannot claim grandfathering');
 update serving_funding set created_at=(select created_at-interval '1 day'from subscription_trial_config where singleton)where id=f;
 j:=create_render_job(x.free_l,x.free_a,'smooth','{}','historical-funded-app-key','app');
 perform pg_temp.ok(j.source='app','current finite pre-config sponsor admits named-owner publication');
 update render_jobs set status='ready'where id=j.id;
 perform set_config('request.jwt.claim.sub','c1000000-0000-4000-8000-000000000002',true);
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''historical-wrong-actor-key'',''app'')',x.free_l,x.free_a),'RP402','another current editor cannot use a named historical sponsor');
 perform set_config('request.jwt.claim.sub',x.u::text,true);
 update serving_funding set revoked_at=now()where id=f;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''historical-revoked-key'',''app'')',x.free_l,x.free_a),'RP402','revoked historical sponsor cannot publish');
 update serving_funding set revoked_at=null,ends_at=now()-interval '1 second'where id=f;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''historical-expired-key'',''app'')',x.free_l,x.free_a),'RP402','expired historical sponsor cannot publish');
 update serving_funding set ends_at=now()+interval '7 days'where id=f;
 update auth.users set is_anonymous=true where id=x.u;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''historical-denamed-key'',''app'')',x.free_l,x.free_a),'RP402','denamed historical sponsor cannot publish');
 update auth.users set is_anonymous=false where id=x.u;
 for i in 1..3 loop
  j:=create_render_job(x.free_l,x.free_a,'smooth','{}','historical-worker-key-'||i,'worker');
  update render_jobs set status='ready'where id=j.id;
 end loop;
 perform pg_temp.ok((select count(*)=3 from render_jobs where listing_id=x.free_l and source='worker'),'funded historical trial keeps the existing three cloud-render cap');
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''historical-worker-key-4'',''worker'')',x.free_l,x.free_a),'RP402','historical fourth cloud render remains refused');
 delete from serving_funding_slices where funding_id=f;delete from serving_funding where id=f;
end$$;
update orgs set plan='pro',plan_source='apple',plan_expires_at=now()+interval '1 month'where id=(select free_o from fixture);
set local role authenticated;
do $$declare f record;begin select * into f from fixture;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''trial-raw-pro-key'',''app'')',f.free_l,f.free_a),'RP402','raw pro plan without signed funded authority cannot publish');
end$$;
reset role;
delete from listings where id=(select l from fixture);
select pg_temp.ok((select count(*)=1 from subscription_trial_grants where id=(select g from fixture))and(select count(*)=9 from subscription_trial_actions where grant_id=(select g from fixture)),'deletion retains all photo/video/publication/upload tombstones');
delete from listings where agent_id=(select u from fixture);
delete from auth.users where id=(select u from fixture);
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('c1000000-0000-4000-8000-000000000003','BOUNDED-TRIAL@example.invalid',false,now());
insert into orgs(id,name,plan,plan_source)values('c2000000-0000-4000-8000-000000000003','Synthetic recreated trial identity','free','apple');
insert into memberships(user_id,org_id,role)values('c1000000-0000-4000-8000-000000000003','c2000000-0000-4000-8000-000000000003','owner');
set local role service_role;
do $$declare t timestamptz:=now()-interval '1 minute';e timestamptz:=t+interval '7 days';s timestamptz:=now();begin
 perform pg_temp.denied('select prepare_subscription_trial_purchase(''c1000000-0000-4000-8000-000000000003'',''c2000000-0000-4000-8000-000000000003'',''com.rendprop.app.starter.monthly'')','RP409','new actor/org/Apple chain with the same confirmed identity cannot reset a deleted trial');
 perform pg_temp.ok(not exists(select 1 from serving_funding where org_id='c2000000-0000-4000-8000-000000000003'),'lifetime refusal rolls back sponsor allocation atomically');
end$$;
reset role;
select jsonb_build_object('assertions',n,'passed',true)from trial_checks;
rollback;
