\set ON_ERROR_STOP on
-- Launch blockers (2026-10-08, migration 20261008220411_launch_blockers):
-- ceiling-mode money admission, SKU envelopes, fail-closed configuration,
-- Sandbox trial grants, durable free publication slots and hosting retention.
-- Everything here is synthetic and rolled back. The two-connection races live
-- in launch_blockers_pg.py.
begin;
create temporary table lb_assertions(n integer not null default 0);insert into lb_assertions default values;
grant all on lb_assertions to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'LAUNCH-BLOCKERS FAIL: %',label;end if;update lb_assertions set n=n+1;end$$;
create function pg_temp.refuse(statement text,expected text,label text)returns void language plpgsql as $$begin
 begin execute statement;exception when others then
  if position(expected in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;
  raise exception 'LAUNCH-BLOCKERS FAIL: % — expected % got %',label,expected,sqlerrm;end;
 raise exception 'LAUNCH-BLOCKERS FAIL: % — expected refusal %',label,expected;end$$;

-- Ceiling mode is the live default; pin it explicitly for this transaction.
update public.app_config set value=jsonb_build_object('mode','ceiling','free_published_listings',1)where key='serving_mode';

insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
 ('d1000000-0000-4000-8000-000000000001','launch-owner@example.invalid',false,now()),
 ('d1000000-0000-4000-8000-000000000002','launch-guest@example.invalid',true,null),
 ('d1000000-0000-4000-8000-000000000003','launch-outsider@example.invalid',false,now()),
 ('d1000000-0000-4000-8000-000000000004','launch-second-owner@example.invalid',false,now());
insert into orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)values
 ('d2000000-0000-4000-8000-000000000001','Synthetic Pro monthly','pro','apple','com.rendprop.app.pro.monthly',now()+interval '20 days'),
 ('d2000000-0000-4000-8000-000000000002','Synthetic Starter annual','starter','apple','com.rendprop.app.starter.annual',now()+interval '300 days'),
 ('d2000000-0000-4000-8000-000000000003','Synthetic Team monthly','team','apple','com.rendprop.app.team.monthly',now()+interval '20 days'),
 ('d2000000-0000-4000-8000-000000000004','Synthetic intro week','pro','apple','com.rendprop.app.pro.monthly',now()+interval '6 days'),
 ('d2000000-0000-4000-8000-000000000005','Synthetic free','free',null,null,null),
 ('d2000000-0000-4000-8000-000000000006','Synthetic sandbox tester','free',null,null,null),
 ('d2000000-0000-4000-8000-000000000007','Synthetic manual pro','pro','manual',null,null),
 ('d2000000-0000-4000-8000-000000000008','Synthetic QA','team','manual',null,null),
 ('d2000000-0000-4000-8000-000000000009','Synthetic Starter monthly','starter','apple','com.rendprop.app.starter.monthly',now()+interval '20 days'),
 ('d2000000-0000-4000-8000-000000000010','Synthetic second sandbox workspace','free',null,null,null);
insert into memberships(user_id,org_id,role)select 'd1000000-0000-4000-8000-000000000001',id,'owner'from orgs where id::text like 'd2000000-%'and id<>'d2000000-0000-4000-8000-000000000010';
insert into memberships(user_id,org_id,role)values('d1000000-0000-4000-8000-000000000004','d2000000-0000-4000-8000-000000000010','owner'),
 ('d1000000-0000-4000-8000-000000000002','d2000000-0000-4000-8000-000000000006','agent'),('d1000000-0000-4000-8000-000000000003','d2000000-0000-4000-8000-000000000006','agent');
update profiles set is_admin=true where id='d1000000-0000-4000-8000-000000000001';
insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)values('d2000000-0000-4000-8000-000000000008','d1000000-0000-4000-8000-000000000001',true);
-- Production subscription rows: a retail month and an introductory week.
insert into apple_subscriptions(original_transaction_id,org_id,user_id,product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,transaction_purchased_at)values
 ('lb-pro-original','d2000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000001','com.rendprop.app.pro.monthly','pro','Production','active',now()+interval '20 days',true,'lb-pro-tx-1',now()-interval '10 days'),
 ('lb-intro-original','d2000000-0000-4000-8000-000000000004','d1000000-0000-4000-8000-000000000001','com.rendprop.app.pro.monthly','pro','Production','active',now()+interval '6 days',true,'lb-intro-tx-1',now()-interval '1 day');
-- Ledger history: Pro spent 2000c this month; Starter 985c; free 295c two months ago.
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,created_at)values
 ('d2000000-0000-4000-8000-000000000001','photo_edit','gemini','gemini-3.1-flash-image',1,2000,2000,date_trunc('month',now())+interval '1 hour'),
 ('d2000000-0000-4000-8000-000000000009','photo_edit','gemini','gemini-3.1-flash-image',1,985,985,date_trunc('month',now())+interval '1 hour'),
 ('d2000000-0000-4000-8000-000000000005','photo_edit','gemini','gemini-3.1-flash-image',1,295,295,now()-interval '2 months');
-- An open video hold counts against the Team envelope until it settles.
insert into app_video_cost_reservations(org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents)values
 ('d2000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000001','lb-video-hold-1','reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('a',64),10,4.86,48.6,5200);
-- Listings + capture assets for the publication guard.
insert into listings(id,org_id,agent_id,address)values
 ('d3000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000005','d1000000-0000-4000-8000-000000000001','Synthetic free listing A'),
 ('d3000000-0000-4000-8000-000000000002','d2000000-0000-4000-8000-000000000005','d1000000-0000-4000-8000-000000000001','Synthetic free listing B'),
 ('d3000000-0000-4000-8000-000000000003','d2000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000001','Synthetic paid listing');
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,duration_s,bytes,transport_version,content_type)values
 ('d4000000-0000-4000-8000-000000000001','d3000000-0000-4000-8000-000000000001','video','renders','renders/lb/a.mp4',true,30,100,2,'video/mp4'),
 ('d4000000-0000-4000-8000-000000000002','d3000000-0000-4000-8000-000000000002','video','renders','renders/lb/b.mp4',true,30,100,2,'video/mp4'),
 ('d4000000-0000-4000-8000-000000000003','d3000000-0000-4000-8000-000000000003','video','renders','renders/lb/c.mp4',true,30,100,2,'video/mp4');

-- ------------------------------------------------------------ privileges
select pg_temp.ok(not has_function_privilege(r,f,'execute'),'tenant roles cannot call '||f)
 from unnest(array['anon','authenticated'])r cross join unnest(array[
  'public.plan_serving_ceiling(uuid)','public.serving_ceiling_spent_cents(uuid,text)','public.trial_sponsor_spent_cents()','public.serving_envelope_int(text,integer)',
  'public.serving_mode_config_state()','public.hosting_retention_enroll(uuid,text,text,timestamptz)','public.free_publication_admit(uuid,uuid)',
  'public.grant_sandbox_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz)'])f;
select pg_temp.ok(not has_table_privilege(r,t,'SELECT,INSERT,UPDATE,DELETE'),r||' cannot touch '||t)
 from unnest(array['anon','authenticated'])r cross join unnest(array['public.hosting_retention_enrollments','public.workspace_publication_slots'])t;
select pg_temp.ok(not has_table_privilege('service_role','public.workspace_publication_slots','UPDATE,DELETE'),'service cannot rewrite consumed slots');
select pg_temp.ok(not has_table_privilege('service_role','public.hosting_retention_enrollments','DELETE'),'service cannot erase a promised grace');

-- ------------------------------------------------------------ 5. fail closed
do $$declare saved jsonb;begin
 select value into saved from public.app_config where key='serving_mode';
 perform pg_temp.ok(public.serving_mode()='ceiling'and public.serving_mode_config_state()='ceiling','explicit ceiling row enables ceiling mode');
 update public.app_config set value='{}'::jsonb where key='serving_mode';
 perform pg_temp.ok(public.serving_mode()='funded'and public.serving_mode_config_state()='invalid','empty object is funded (closed) and flagged invalid');
 update public.app_config set value='{"mode":"ceiling"}'::jsonb where key='serving_mode';
 perform pg_temp.ok(public.serving_mode()='funded'and public.serving_mode_config_state()='invalid','ceiling without a numeric free listing count is invalid');
 update public.app_config set value='{"mode":"ceiling","free_published_listings":"1"}'::jsonb where key='serving_mode';
 perform pg_temp.ok(public.serving_mode()='funded','a string listing count is invalid');
 update public.app_config set value='{"mode":"CEILING","free_published_listings":1}'::jsonb where key='serving_mode';
 perform pg_temp.ok(public.serving_mode()='funded','mode is matched exactly');
 update public.app_config set value='{"mode":"funded"}'::jsonb where key='serving_mode';
 perform pg_temp.ok(public.serving_mode()='funded'and public.serving_mode_config_state()='funded','explicit funded row');
 delete from public.app_config where key='serving_mode';
 perform pg_temp.ok(public.serving_mode()='funded'and public.serving_mode_config_state()='missing','missing row is funded (closed) and flagged missing');
 perform pg_temp.ok(exists(select 1 from public.ops_health_findings()where code='serving_mode_config'),'hourly alert reports the missing configuration');
 perform pg_temp.ok(not public.free_publication_admit('d2000000-0000-4000-8000-000000000005','d3000000-0000-4000-8000-000000000001'),'no free publication outside ceiling mode');
 insert into public.app_config(key,value)values('serving_mode',saved);
 perform pg_temp.ok(public.serving_mode()='ceiling','configuration restored');
 perform pg_temp.ok(not exists(select 1 from public.ops_health_findings()where code='serving_mode_config'),'no configuration alert with a valid row');
end$$;

-- ------------------------------------------------------------ 2. envelopes
do $$declare c jsonb;begin
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000001');
 perform pg_temp.ok((c->>'ceiling_cents')::int=2053 and c->>'basis'='month'and c->>'kind'='retail'and c->>'sku'='com.rendprop.app.pro.monthly','Pro monthly: floor(9900 x 0.85 x 0.25) - 50 = 2053c');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000009');
 perform pg_temp.ok((c->>'ceiling_cents')::int=991 and c->>'kind'='retail','Starter monthly: 991c');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000002');
 perform pg_temp.ok((c->>'ceiling_cents')::int=817 and c->>'kind'='retail','Starter annual: ten monthly prices over twelve months = 817c');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000003');
 perform pg_temp.ok((c->>'ceiling_cents')::int=5241,'Team monthly: 5241c');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000004');
 perform pg_temp.ok((c->>'ceiling_cents')::int=500 and c->>'kind'='trial','introductory week is capped like a trial');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000005');
 perform pg_temp.ok((c->>'ceiling_cents')::int=300 and c->>'basis'='lifetime'and c->>'kind'='free','free tier is a 300c lifetime sample');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000007');
 perform pg_temp.ok((c->>'ceiling_cents')::int=2400 and c->>'kind'='manual','owner-granted plan keeps its entitlement ceiling');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000008');
 perform pg_temp.ok((c->>'ceiling_cents')::int=2147483647 and c->>'kind'='sponsored','testing grant is sponsored');
 update public.app_config set value=value||'{"apple_commission_bps":3000}'::jsonb where key='serving_envelope';
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000001')->>'ceiling_cents')::int=1682,'30% commission: floor(9900 x 0.70 x 0.25) - 50 = 1682c');
 update public.app_config set value=value||'{"apple_commission_bps":1500}'::jsonb where key='serving_envelope';
 update public.app_config set value=value-'net_margin_bps' where key='serving_envelope';
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000001')->>'ceiling_cents')::int=2053,'a missing envelope key uses its documented default');
 update public.app_config set value=value||'{"net_margin_bps":7500}'::jsonb where key='serving_envelope';
 perform pg_temp.ok(public.serving_ceiling_spent_cents('d2000000-0000-4000-8000-000000000003','month')=5200,'open video holds count against the envelope');
end$$;

set local role service_role;
-- ------------------------------------------------------------ 1. admission
do $$declare u uuid:='d1000000-0000-4000-8000-000000000001';pro uuid:='d2000000-0000-4000-8000-000000000001';starter uuid:='d2000000-0000-4000-8000-000000000009';
 free_o uuid:='d2000000-0000-4000-8000-000000000005';intro uuid:='d2000000-0000-4000-8000-000000000004';qa uuid:='d2000000-0000-4000-8000-000000000008';team uuid:='d2000000-0000-4000-8000-000000000003';r jsonb;begin
 -- Codex's reproduction: 1,195c spent against a 1,200c ceiling admitted 6.7c. Now: 985 + 6.7 > 991 refused, 985 + 6 admitted.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-starter-over'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,6.7,''route-catalog'')',u,starter,repeat('a',64)),'RP402: AI usage limit reached','ceiling refuses the attempt that would cross it');
 r:=serving_cost_reserve(u,starter,'lb-starter-fit','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),6,'route-catalog');
 perform pg_temp.ok((r->>'reserved')::boolean and r->>'budget'='ceiling'and(r->>'ceiling_cents')::int=991 and(r->>'spent_cents')::numeric=985 and not(r->>'sponsored_unlimited')::boolean,'attempt inside the envelope is reserved against the ceiling budget');
 perform pg_temp.ok((select budget_source='ceiling'and funding_id is null and slice_index is null and state='reserved'and not trial_kind from serving_cost_reservations where org_id=starter and request_key='lb-starter-fit'),'ceiling reservation journaled without a funding slice');
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-starter-next'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,0.5,''route-catalog'')',u,starter,repeat('a',64)),'RP402','an open hold counts while the attempt is in flight');
 perform serving_cost_finish(u,starter,'lb-starter-fit','photo.stage:0','rejected',400);
 r:=serving_cost_reserve(u,starter,'lb-starter-next','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),6,'route-catalog');
 perform pg_temp.ok((r->>'reserved')::boolean,'a proven prequeue rejection releases its hold');
 perform serving_cost_finish(u,starter,'lb-starter-next','photo.stage:0','uncertain',null);
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-starter-after-uncertain'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,0.5,''route-catalog'')',u,starter,repeat('a',64)),'RP402','an uncertain (potentially billable) outcome keeps its hold');
 -- Pro: 2000 spent of 2053.
 r:=serving_cost_reserve(u,pro,'lb-pro-fit','copy.initial:0','anthropic','claude-sonnet-5',repeat('a',64),53,'route-catalog');
 perform pg_temp.ok((r->>'reserved')::boolean,'Pro attempt exactly at the ceiling is admitted');
 perform serving_cost_finish(u,pro,'lb-pro-fit','copy.initial:0','succeeded',null);
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-pro-over'',''copy.initial:0'',''anthropic'',''claude-sonnet-5'',%L,0.1,''route-catalog'')',u,pro,repeat('a',64)),'RP402','a settled success still counts until its ledger row lands');
 -- Team: the open 5200c video hold leaves 41c of 5241c.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-team-over'',''video.reel_clip'',''fal'',''bytedance/seedance/v1/pro/fast/image-to-video'',%L,42,''route-catalog'')',u,team,repeat('a',64)),'RP402','video holds share the envelope');
 r:=serving_cost_reserve(u,team,'lb-team-fit','video.reel_clip','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('a',64),41,'route-catalog');
 perform pg_temp.ok((r->>'reserved')::boolean,'the remainder is still admitted');
 -- Free: 295c lifetime of 300c.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-free-over'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,6,''route-catalog'')',u,free_o,repeat('a',64)),'RP402','free lifetime sample counts spend from earlier months');
 r:=serving_cost_reserve(u,free_o,'lb-free-fit','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),5,'route-catalog');
 perform pg_temp.ok((r->>'reserved')::boolean and r->>'basis'='lifetime','free attempt inside the lifetime sample');
 -- Trial kind: capped at 500c per workspace and by the global sponsor pool.
 r:=serving_cost_reserve(u,intro,'lb-intro-1','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),400,'route-catalog');
 perform pg_temp.ok((r->>'reserved')::boolean and r->>'kind'='trial'and(select trial_kind from serving_cost_reservations where org_id=intro and request_key='lb-intro-1'),'introductory-week attempt draws from the trial pool');
 perform pg_temp.ok(public.trial_sponsor_spent_cents()=400,'sponsor pool accounts the trial hold');
 update public.app_config set value=value||'{"trial_sponsor_cap_cents":450}'::jsonb where key='serving_envelope';
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-intro-2'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,60,''route-catalog'')',u,intro,repeat('a',64)),'RP402: Free-trial AI limit reached','global sponsor cap refuses trial attempts');
 update public.app_config set value=value||'{"trial_sponsor_cap_cents":29000}'::jsonb where key='serving_envelope';
 r:=serving_cost_reserve(u,intro,'lb-intro-2','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),60,'route-catalog');
 perform pg_temp.ok((r->>'reserved')::boolean,'trial attempt admitted under the cap');
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-intro-3'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,50,''route-catalog'')',u,intro,repeat('a',64)),'RP402: AI usage limit reached','trial workspace ceiling is 500c');
 -- Sponsored QA keeps unlimited private sponsorship.
 r:=serving_cost_reserve(u,qa,'lb-qa-unlimited','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),100000,'route-catalog');
 perform pg_temp.ok((r->>'sponsored_unlimited')::boolean,'testing grant remains unlimited sponsorship');
 -- Unpriced attempts stay refused outside sponsorship.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-unpriced'',''presenter.motion'',''higgsfield'',''motion-transfer'',%L,1,''unpriced-private-sponsorship'')',u,pro,repeat('a',64)),'RP403','unpriced route is refused in ceiling mode too');
 -- Guests and outsiders are refused before any money moves.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-guest-key'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,1,''route-catalog'')','d1000000-0000-4000-8000-000000000002','d2000000-0000-4000-8000-000000000006',repeat('a',64)),'RP403','anonymous member cannot reserve');
 -- Generated results need an admitted attempt again.
 perform serving_operation_begin(u,pro,'lb-op-no-attempt','coach.chat',repeat('a',64));
 perform pg_temp.refuse(format('select serving_operation_complete(%L,%L,''lb-op-no-attempt'',''{"reply":"invented"}'')',u,pro),'RP409','a result without an admitted provider attempt is refused');
 perform pg_temp.ok((select count(*)from ops_health_findings()where code like 'org_near_ceiling:%')>=4,'workspaces at 80% of their envelope are reported');
end$$;

-- ------------------------------------------------------------ 3. Sandbox trial
do $$declare u uuid:='d1000000-0000-4000-8000-000000000001';o uuid:='d2000000-0000-4000-8000-000000000006';pro uuid:='d2000000-0000-4000-8000-000000000001';r jsonb;first timestamptz;begin
 perform pg_temp.refuse(format('select grant_sandbox_trial(%L,%L,''lb-sb-bad'',''lb-sb-bad-tx'',''com.rendprop.app.pro.monthly'',''bogus'',now()+interval ''3 minutes'',now())',o,u),'RP400','unknown receipt status refused');
 r:=grant_sandbox_trial(o,u,'lb-sb-expired','lb-sb-expired-tx','com.rendprop.app.pro.monthly','expired',now()-interval '1 hour',now()-interval '2 hours');
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='receipt_inactive'and r->>'plan'='free','expired Sandbox receipt grants nothing');
 perform pg_temp.ok((select status='expired'and receipt_expires_at<now()and trial_granted_at is null from apple_sandbox_receipts where original_transaction_id='lb-sb-expired'),'expired receipt is persisted with its facts');
 r:=grant_sandbox_trial(o,u,'lb-sb-refunded','lb-sb-refunded-tx','com.rendprop.app.pro.monthly','refunded',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='receipt_inactive','refunded Sandbox receipt grants nothing');
 r:=grant_sandbox_trial(o,u,'lb-sb-stale','lb-sb-stale-tx','com.rendprop.app.pro.monthly','active',now()-interval '1 minute',now()-interval '2 minutes');
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='receipt_inactive','an active status with a past expiry grants nothing');
 perform pg_temp.ok((select plan='free'and trial_ends_at is null from orgs where id=o),'workspace untouched by inactive receipts');
 perform pg_temp.refuse(format('select grant_sandbox_trial(%L,%L,''lb-sb-guest'',''lb-sb-guest-tx'',''com.rendprop.app.pro.monthly'',''active'',now()+interval ''3 minutes'',now())',o,'d1000000-0000-4000-8000-000000000002'),'RP403','anonymous tester cannot receive a trial');
 perform pg_temp.refuse(format('select grant_sandbox_trial(%L,%L,''lb-sb-agent'',''lb-sb-agent-tx'',''com.rendprop.app.pro.monthly'',''active'',now()+interval ''3 minutes'',now())',o,'d1000000-0000-4000-8000-000000000003'),'RP403','non-owner cannot receive a trial');
 r:=grant_sandbox_trial(o,u,'lb-sb-live','lb-sb-live-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok((r->>'granted')::boolean and r->>'plan'='trial'and(r->>'expires_at')::timestamptz between now()+interval '6 days 23 hours'and now()+interval '7 days 1 minute','active Sandbox receipt opens a 7-day trial');
 first:=(r->>'expires_at')::timestamptz;
 perform pg_temp.ok((select plan='trial'and plan_source='trial'and trial_ends_at=first from orgs where id=o),'workspace carries the trial window');
 perform pg_temp.ok((select trial_granted_at is not null and trial_ends_at=first from apple_sandbox_receipts where original_transaction_id='lb-sb-live'),'grant recorded on the receipt');
 perform pg_temp.ok((select retention_ends_at=first+interval '90 days'from hosting_retention_enrollments where org_id=o and source='sandbox_trial'and reference='lb-sb-live'),'trial enrolls hosting retention');
 perform pg_temp.ok(public.hosting_retention_state(o)->>'policy'='prospective_90_day_grace'and(public.hosting_retention_state(o)->>'hosting_available')::boolean,'trial hosting is prospective and available');
 perform pg_temp.ok((public.plan_serving_ceiling(o)->>'ceiling_cents')::int=500 and public.plan_serving_ceiling(o)->>'kind'='trial','trial workspace is capped at 500c');
 r:=grant_sandbox_trial(o,u,'lb-sb-live','lb-sb-live-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and(r->>'replay')::boolean and(r->>'expires_at')::timestamptz=first,'replay reports the same window');
 perform pg_temp.ok((select trial_ends_at=first from orgs where id=o),'replay never restarts the clock');
 r:=grant_sandbox_trial(o,u,'lb-sb-second','lb-sb-second-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='trial_active'and(r->>'expires_at')::timestamptz=first,'a second receipt during an open window is recorded, not added');
 perform pg_temp.ok((select trial_granted_at is null from apple_sandbox_receipts where original_transaction_id='lb-sb-second'),'ungranted receipt carries no grant');
 perform pg_temp.refuse(format('select grant_sandbox_trial(%L,%L,''lb-sb-live'',''lb-sb-live-tx'',''com.rendprop.app.pro.monthly'',''active'',now()+interval ''3 minutes'',now())','d2000000-0000-4000-8000-000000000010','d1000000-0000-4000-8000-000000000004'),'RP409','a receipt cannot move to another workspace or account');
 r:=grant_sandbox_trial(pro,u,'lb-sb-paid','lb-sb-paid-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='paid_workspace'and r->>'plan'='pro','paid workspace is never downgraded');
 perform pg_temp.ok((select plan='pro'and plan_source='apple'from orgs where id=pro),'paid plan untouched');
end$$;
-- Eight days later (simulated): the window ended; the spent receipt cannot reopen it, a new purchase can.
reset role;
update orgs set trial_ends_at=now()-interval '1 day'where id='d2000000-0000-4000-8000-000000000006';
update apple_sandbox_receipts set trial_ends_at=now()-interval '1 day'where original_transaction_id='lb-sb-live';
set local role service_role;
do $$declare u uuid:='d1000000-0000-4000-8000-000000000001';o uuid:='d2000000-0000-4000-8000-000000000006';r jsonb;begin
 perform pg_temp.ok(public.effective_plan(o)='free','ended trial reads as free');
 r:=grant_sandbox_trial(o,u,'lb-sb-live','lb-sb-live-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and(r->>'replay')::boolean and r->>'plan'='free','a spent receipt cannot reopen a window');
 perform pg_temp.ok((select trial_ends_at<now()from orgs where id=o),'replay of a spent receipt leaves the workspace free');
 r:=grant_sandbox_trial(o,u,'lb-sb-third','lb-sb-third-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok((r->>'granted')::boolean and(r->>'expires_at')::timestamptz>now()+interval '6 days','a new purchase after the window opens one more');
 perform pg_temp.ok((select count(*)=2 from apple_sandbox_receipts where org_id=o and trial_granted_at is not null),'each receipt grants at most once');
end$$;

-- ------------------------------------------------------------ 4. free slot
do $$declare o uuid:='d2000000-0000-4000-8000-000000000005';a uuid:='d3000000-0000-4000-8000-000000000001';b uuid:='d3000000-0000-4000-8000-000000000002';begin
 perform pg_temp.ok(public.free_publication_admitted(o,a)and public.free_publication_admitted(o,b),'before consumption any listing could take the slot');
 perform pg_temp.ok(public.free_publication_admit(o,a),'first listing consumes the slot');
 perform pg_temp.ok(public.free_publication_admit(o,a),'re-admitting the same listing is free');
 perform pg_temp.ok((select count(*)=1 from workspace_publication_slots where org_id=o),'one durable slot row');
 perform pg_temp.ok(not public.free_publication_admit(o,b),'second listing is refused');
 perform pg_temp.ok(public.free_publication_admitted(o,a)and not public.free_publication_admitted(o,b),'read-only view agrees');
 perform pg_temp.ok(not public.free_publication_admit(o,null),'null listing never admitted');
end$$;
reset role;
do $$begin perform set_config('request.jwt.claim.sub','d1000000-0000-4000-8000-000000000001',true);end$$;
do $$begin
 insert into render_jobs(listing_id,capture_asset_id,tier,enhancements,idem_key,source)values('d3000000-0000-4000-8000-000000000001','d4000000-0000-4000-8000-000000000001','smooth','{}','lb-free-job-a','app');
 perform pg_temp.ok(true,'publication guard admits the slot holder');
 perform pg_temp.refuse($q$insert into render_jobs(listing_id,capture_asset_id,tier,enhancements,idem_key,source)values('d3000000-0000-4000-8000-000000000002','d4000000-0000-4000-8000-000000000002','smooth','{}','lb-free-job-b','app')$q$,'RP402: Subscribe to activate hosted publication','publication guard refuses a second free listing');
 insert into render_jobs(listing_id,capture_asset_id,tier,enhancements,idem_key,source)values('d3000000-0000-4000-8000-000000000003','d4000000-0000-4000-8000-000000000003','smooth','{}','lb-paid-job','app');
 perform pg_temp.ok(not exists(select 1 from workspace_publication_slots where org_id='d2000000-0000-4000-8000-000000000001'),'paid workspace publishes without consuming a free slot');
end$$;

-- ------------------------------------------------------------ 6. retention
set local role service_role;
do $$declare pro uuid:='d2000000-0000-4000-8000-000000000001';u uuid:='d1000000-0000-4000-8000-000000000001';r jsonb;deadline timestamptz;begin
 perform pg_temp.ok(public.hosting_retention_state(pro)->>'policy'='preserved','no deadline before any applied entitlement');
 r:=apply_apple_entitlement_v2(pro,u,'lb-pro-original','lb-pro-tx-1','com.rendprop.app.pro.monthly','pro','Production','active',now()+interval '20 days',true,null,now()-interval '10 days',now()-interval '9 days',null,null);
 perform pg_temp.ok((r->>'org_updated')::boolean,'device sync applies the Production entitlement');
 select retention_ends_at into deadline from hosting_retention_enrollments where org_id=pro and source='apple_subscription'and reference='lb-pro-original';
 perform pg_temp.ok(deadline between now()+interval '109 days 23 hours'and now()+interval '110 days 1 minute','ceiling purchase records expiry + 90 days');
 r:=public.hosting_retention_state(pro);
 perform pg_temp.ok(r->>'policy'='prospective_90_day_grace'and(r->>'retention_ends_at')::timestamptz=deadline and(r->>'hosting_available')::boolean,'retention state reads the enrollment');
 r:=apply_apple_entitlement_v2(pro,u,'lb-pro-original','lb-pro-tx-2','com.rendprop.app.pro.monthly','pro','Production','active',now()+interval '50 days',true,'DID_RENEW',now()-interval '1 day',now()-interval '1 day',now()-interval '1 day',null);
 perform pg_temp.ok((select retention_ends_at between now()+interval '139 days 23 hours'and now()+interval '140 days 1 minute'from hosting_retention_enrollments where org_id=pro and reference='lb-pro-original'),'renewal extends the deadline');
 r:=apply_apple_entitlement_v2(pro,u,'lb-pro-original','lb-pro-tx-2','com.rendprop.app.pro.monthly','pro','Production','refunded',now()+interval '50 days',false,'REFUND',now()-interval '1 day',now()-interval '1 day',now()-interval '1 hour',null);
 perform pg_temp.ok((select retention_ends_at between now()+interval '139 days 23 hours'and now()+interval '140 days 1 minute'from hosting_retention_enrollments where org_id=pro and reference='lb-pro-original'),'refund never shortens the promised grace');
 perform pg_temp.ok((public.hosting_retention_state(pro)->>'hosting_available')::boolean,'hosting continues through the grace');
 -- The four fixture subscribers inserted without a sync (02, 03, 04, 09) are the alert's subject; the synced Pro workspace is not.
 perform pg_temp.ok((select (data->>'orgs')::int=4 from ops_health_findings()where code='retention_missing'),'paid ceiling workspaces without a retention record are alerted; the synced one is not');
end$$;
reset role;
-- A lapsed deadline closes hosting; an owner-granted paid plan reopens it.
update hosting_retention_enrollments set retention_ends_at=now()-interval '1 minute'where org_id='d2000000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.ok(not(public.hosting_retention_state('d2000000-0000-4000-8000-000000000001')->>'hosting_available')::boolean,'past deadline denies hosting');
reset role;
select pg_temp.ok((select plan='free'from orgs where id='d2000000-0000-4000-8000-000000000001'),'refund lapsed the Apple plan');
update orgs set plan='pro',plan_source='manual'where id='d2000000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.ok(public.hosting_retention_state('d2000000-0000-4000-8000-000000000001')->>'policy'='preserved','owner-granted paid plan is preserved');
reset role;
update orgs set plan='free',plan_source='manual'where id='d2000000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.ok(not(public.hosting_retention_state('d2000000-0000-4000-8000-000000000001')->>'hosting_available')::boolean,'an owner-granted free plan gets no exemption');
reset role;
update orgs set plan='pro',plan_source='apple'where id='d2000000-0000-4000-8000-000000000001';
-- A subscriber applied before this migration ran is backfilled by it: simulate the
-- alert that catches a missing record.
delete from hosting_retention_enrollments where org_id='d2000000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.ok((select (data->>'orgs')::int=5 from ops_health_findings()where code='retention_missing'),'a paid workspace that lost its retention record joins the alert');
reset role;
-- ------------------------------------------------------------ 7. provider evidence
set local role service_role;
do $$begin
 perform report_provider_outcome('fal','synthetic/dead-model',false,620,'upstream',401);
 perform report_provider_outcome('fal','synthetic/dead-model',false,610,'upstream',401);
 perform report_provider_outcome('fal','synthetic/dead-model',false,630,'upstream');
 perform pg_temp.ok((select consecutive_failures=3 and last_status is null and open_until>now()from provider_health where provider='fal'and model='synthetic/dead-model'),'five-argument reports still work and clear an unknown status');
 perform report_provider_outcome('fal','synthetic/dead-model',false,640,'upstream',402);
 perform pg_temp.ok((select last_status=402 from provider_health where provider='fal'and model='synthetic/dead-model'),'the breaker keeps the last upstream status');
 perform pg_temp.ok(exists(select 1 from ops_health_findings()where code='provider_dead:fal:synthetic/dead-model'and body like '%last HTTP 402 = the provider account is out of balance%'and(data->>'last_status')::int=402),'the hourly alert names the status');
 perform report_provider_outcome('fal','synthetic/dead-model',false,1,'upstream',999);
 perform pg_temp.ok((select last_status is null from provider_health where provider='fal'and model='synthetic/dead-model'),'an impossible status is not recorded');
 perform report_provider_outcome('fal','synthetic/dead-model',true,500,null,null);
 perform pg_temp.ok((select consecutive_failures=0 and open_until is null from provider_health where provider='fal'and model='synthetic/dead-model'),'a success closes the circuit');
 perform pg_temp.ok(not has_function_privilege('authenticated','public.report_provider_outcome(text,text,boolean,integer,text,integer)','execute'),'tenants cannot write provider health');
end$$;
reset role;
select jsonb_build_object('assertions',n,'passed',true)from lb_assertions;
rollback;
