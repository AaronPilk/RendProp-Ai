\set ON_ERROR_STOP on
-- Launch blockers (2026-10-08, migrations 20261008220411_launch_blockers and
-- 20261008235900_launch_round2): one ceiling-mode money authority for photo,
-- text, video and erase writers; holds bound to their ledger rows (no timer);
-- allocations per paid service window; SKU envelopes; fail-closed
-- configuration; Sandbox receipts in signature order reporting current state;
-- durable free publication slots; hosting retention incl. the notice consumer;
-- admin alert currency; provider status evidence.
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

-- Ceiling mode is the live default; pin it and the launch pool explicitly for this transaction.
update public.app_config set value=jsonb_build_object('mode','ceiling','free_published_listings',1)where key='serving_mode';
-- Pin the commission: the dated Small Business switch is asserted on its own below.
update public.app_config set value=(value-'reduced_commission_bps'-'reduced_commission_from')||'{"apple_commission_bps":3000}'::jsonb where key='serving_envelope';
update public.app_config set value=jsonb_build_object('cap_cents',29000,'starts_at',to_char(now()-interval '1 day','YYYY-MM-DD"T"HH24:MI:SS"Z"'),'ends_at',to_char(now()+interval '30 days','YYYY-MM-DD"T"HH24:MI:SS"Z"'))where key='trial_sponsor_pool';

insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
 ('d1000000-0000-4000-8000-000000000001','launch-owner@example.invalid',false,now()),
 ('d1000000-0000-4000-8000-000000000002','launch-guest@example.invalid',true,null),
 ('d1000000-0000-4000-8000-000000000003','launch-outsider@example.invalid',false,now()),
 ('d1000000-0000-4000-8000-000000000004','launch-second-owner@example.invalid',false,now()),
 ('d1000000-0000-4000-8000-000000000005','launch-not-admin@example.invalid',false,now());
insert into orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)values
 ('d2000000-0000-4000-8000-000000000001','Synthetic Pro monthly','pro','apple','com.rendprop.app.pro.monthly',now()+interval '20 days'),
 ('d2000000-0000-4000-8000-000000000002','Synthetic Starter annual','starter','apple','com.rendprop.app.starter.annual',now()+interval '265 days'),
 ('d2000000-0000-4000-8000-000000000003','Synthetic Team monthly','team','apple','com.rendprop.app.team.monthly',now()+interval '25 days'),
 ('d2000000-0000-4000-8000-000000000004','Synthetic intro week','pro','apple','com.rendprop.app.pro.monthly',now()+interval '6 days'),
 ('d2000000-0000-4000-8000-000000000005','Synthetic free','free',null,null,null),
 ('d2000000-0000-4000-8000-000000000006','Synthetic sandbox tester','free',null,null,null),
 ('d2000000-0000-4000-8000-000000000007','Synthetic manual pro','pro','manual',null,null),
 ('d2000000-0000-4000-8000-000000000008','Synthetic QA','team','manual',null,null),
 ('d2000000-0000-4000-8000-000000000009','Synthetic Starter monthly','starter','apple','com.rendprop.app.starter.monthly',now()+interval '20 days'),
 ('d2000000-0000-4000-8000-000000000010','Synthetic second sandbox workspace','free',null,null,null),
 ('d2000000-0000-4000-8000-000000000011','Synthetic grace','starter','apple','com.rendprop.app.starter.monthly',now()-interval '2 days'),
 ('d2000000-0000-4000-8000-000000000012','Synthetic pre-policy tester','free','apple','com.rendprop.app.pro.monthly',now()-interval '40 days');
insert into memberships(user_id,org_id,role)select 'd1000000-0000-4000-8000-000000000001',id,'owner'from orgs where id::text like 'd2000000-%'and id<>'d2000000-0000-4000-8000-000000000010';
insert into memberships(user_id,org_id,role)values('d1000000-0000-4000-8000-000000000004','d2000000-0000-4000-8000-000000000010','owner'),
 ('d1000000-0000-4000-8000-000000000002','d2000000-0000-4000-8000-000000000006','agent'),('d1000000-0000-4000-8000-000000000003','d2000000-0000-4000-8000-000000000006','agent');
update profiles set is_admin=true where id='d1000000-0000-4000-8000-000000000001';
insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)values('d2000000-0000-4000-8000-000000000008','d1000000-0000-4000-8000-000000000001',true);
-- Verified Production subscription rows define each paid workspace's service window.
insert into apple_subscriptions(original_transaction_id,org_id,user_id,product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,transaction_purchased_at,created_at)values
 ('lb-pro-original','d2000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000001','com.rendprop.app.pro.monthly','pro','Production','active',now()+interval '20 days',true,'lb-pro-tx-1',now()-interval '10 days',now()-interval '1 day'),
 ('lb-annual-original','d2000000-0000-4000-8000-000000000002','d1000000-0000-4000-8000-000000000001','com.rendprop.app.starter.annual','starter','Production','active',now()+interval '265 days',true,'lb-annual-tx-1',now()-interval '100 days',now()-interval '1 day'),
 ('lb-team-original','d2000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000001','com.rendprop.app.team.monthly','team','Production','active',now()+interval '25 days',true,'lb-team-tx-1',now()-interval '5 days',now()-interval '1 day'),
 ('lb-intro-original','d2000000-0000-4000-8000-000000000004','d1000000-0000-4000-8000-000000000001','com.rendprop.app.pro.monthly','pro','Production','active',now()+interval '6 days',true,'lb-intro-tx-1',now()-interval '1 day',now()-interval '1 day'),
 ('lb-starter-original','d2000000-0000-4000-8000-000000000009','d1000000-0000-4000-8000-000000000001','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval '20 days',true,'lb-starter-tx-1',now()-interval '10 days',now()-interval '1 day'),
 ('lb-grace-original','d2000000-0000-4000-8000-000000000011','d1000000-0000-4000-8000-000000000001','com.rendprop.app.starter.monthly','starter','Production','active',now()-interval '2 days',true,'lb-grace-tx-1',now()-interval '32 days',now()-interval '1 day'),
 ('lb-prepolicy-original','d2000000-0000-4000-8000-000000000012','d1000000-0000-4000-8000-000000000001','com.rendprop.app.pro.monthly','pro','Production','expired',now()-interval '40 days',false,'lb-prepolicy-tx-1',now()-interval '70 days','2026-09-20T00:00:00Z');
-- Ledger history inside and outside the windows.
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,created_at)values
 ('d2000000-0000-4000-8000-000000000001','photo_edit','gemini','gemini-3.1-flash-image',1,2000,2000,now()-interval '1 day'),
 ('d2000000-0000-4000-8000-000000000009','photo_edit','gemini','gemini-3.1-flash-image',1,985,985,now()-interval '1 day'),
 ('d2000000-0000-4000-8000-000000000009','photo_edit','gemini','gemini-3.1-flash-image',1,500,500,now()-interval '15 days'),
 ('d2000000-0000-4000-8000-000000000005','photo_edit','gemini','gemini-3.1-flash-image',1,295,295,now()-interval '2 months');
-- An open video hold counts against the Team envelope until it settles.
insert into app_video_cost_reservations(org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents)values
 ('d2000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000001','lb-video-hold-1','reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('a',64),10,4.86,48.6,4200);
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
  'public.plan_serving_ceiling(uuid)','public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)','public.serving_envelope_admit(uuid,numeric,text)','public.serving_envelope_state(uuid)',
  'public.trial_sponsor_spent_cents()','public.trial_sponsor_pool()','public.serving_envelope_int(text,integer)',
  'public.serving_mode_config_state()','public.hosting_retention_enroll(uuid,text,text,timestamptz)','public.free_publication_admit(uuid,uuid)',
  'public.grant_sandbox_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz)','public.ops_alert_current(uuid)'])f;
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

-- ------------------------------------------------------------ Small Business commission switches at its dated instant
do $$declare saved jsonb;begin
 select value into saved from public.app_config where key='serving_envelope';
 update public.app_config set value=value||'{"reduced_commission_bps":1500}'::jsonb||jsonb_build_object('reduced_commission_from',to_char(now()+interval '1 day','YYYY-MM-DD"T"HH24:MI:SS"Z"'))where key='serving_envelope';
 perform pg_temp.ok(public.serving_envelope_int('apple_commission_bps',0)=3000,'before the Small Business effective instant the 30% commission applies');
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000009')->>'ceiling_cents')::int=807,'Starter is 807c before the switch');
 update public.app_config set value=value||jsonb_build_object('reduced_commission_from',to_char(now()-interval '1 minute','YYYY-MM-DD"T"HH24:MI:SS"Z"'))where key='serving_envelope';
 perform pg_temp.ok(public.serving_envelope_int('apple_commission_bps',0)=1500,'from the effective instant the 15% commission applies with no config edit');
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000009')->>'ceiling_cents')::int=991
  and(public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000001')->>'ceiling_cents')::int=2053
  and(public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000003')->>'ceiling_cents')::int=5241,'after the switch: Starter 991c, Pro 2053c, Team 5241c');
 perform pg_temp.ok(public.serving_envelope_int('net_margin_bps',0)=7500,'other envelope keys are unaffected by the commission switch');
 update public.app_config set value=value||'{"reduced_commission_from":"soon"}'::jsonb where key='serving_envelope';
 perform pg_temp.ok(public.serving_envelope_int('apple_commission_bps',0)=3000,'a malformed effective date keeps the 30% commission (smaller envelope)');
 update public.app_config set value=value||'{"reduced_commission_from":"2020-01-01T00:00:00Z","reduced_commission_bps":"1500"}'::jsonb where key='serving_envelope';
 perform pg_temp.ok(public.serving_envelope_int('apple_commission_bps',0)=3000,'a non-numeric reduced rate keeps the 30% commission');
 update public.app_config set value=value||'{"reduced_commission_bps":20000}'::jsonb where key='serving_envelope';
 perform pg_temp.ok(public.serving_envelope_int('apple_commission_bps',0)=3000,'an out-of-range reduced rate keeps the 30% commission');
 update public.app_config set value=saved where key='serving_envelope';
end$$;

-- ------------------------------------------------------------ 2+3. envelopes and their service windows
do $$declare c jsonb;begin
 perform pg_temp.ok(public.serving_envelope_int('apple_commission_bps',0)=3000,'commission assumption defaults to 30% until the Small Business rate is observed');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000001');
 perform pg_temp.ok((c->>'ceiling_cents')::int=1682 and c->>'kind'='retail'and c->>'window'='apple_term','Pro monthly at 30%: floor(9900 x 0.70 x 0.25) - 50 = 1682c');
 perform pg_temp.ok((c->>'period_start')::timestamptz between now()-interval '10 days 1 minute'and now()-interval '9 days 23 hours'and(c->>'period_end')::timestamptz between now()+interval '19 days 23 hours'and now()+interval '20 days 1 minute','monthly window = the verified transaction [purchase, expiry)');
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000009')->>'ceiling_cents')::int=807,'Starter monthly at 30%: 807c');
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000003')->>'ceiling_cents')::int=4307,'Team monthly at 30%: 4307c');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000002');
 perform pg_temp.ok((c->>'ceiling_cents')::int=664 and c->>'window'='apple_slice','Starter annual at 30%: ten monthly prices over twelve months = 664c per slice');
 perform pg_temp.ok((c->>'period_start')::timestamptz<=now()and(c->>'period_end')::timestamptz>now()
  and(c->>'period_end')::timestamptz-(c->>'period_start')::timestamptz between interval '30 days'and interval '31 days','annual term is sliced into twelve purchase-anchored windows; the current one contains now');
 update public.app_config set value=value||'{"apple_commission_bps":1500}'::jsonb where key='serving_envelope';
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000001')->>'ceiling_cents')::int=2053,'Pro monthly at 15%: 2053c');
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000009')->>'ceiling_cents')::int=991,'Starter monthly at 15%: 991c');
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000003')->>'ceiling_cents')::int=5241,'Team monthly at 15%: 5241c');
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000002')->>'ceiling_cents')::int=817,'Starter annual at 15%: 817c');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000004');
 perform pg_temp.ok((c->>'ceiling_cents')::int=500 and c->>'kind'='trial'and c->>'window'='intro_window'and(c->>'period_end')::timestamptz between now()+interval '5 days 23 hours'and now()+interval '6 days 1 minute','introductory week is a trial inside its own seven-day window');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000011');
 perform pg_temp.ok((c->>'ceiling_cents')::int=991 and c->>'kind'='grace'and c->>'window'='apple_grace'and(c->>'period_start')::timestamptz<now()and(c->>'period_end')::timestamptz between now()+interval '13 days 23 hours'and now()+interval '14 days 1 minute','billing retry keeps one envelope for the 16-day grace window');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000005');
 perform pg_temp.ok((c->>'ceiling_cents')::int=300 and c->>'basis'='lifetime'and c->>'window'='lifetime'and c->'period_start'='null'::jsonb,'free tier is a 300c lifetime sample');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000007');
 perform pg_temp.ok((c->>'ceiling_cents')::int=2400 and c->>'kind'='manual'and c->>'window'='calendar_month','owner-granted plan keeps its entitlement ceiling per calendar month');
 c:=public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000008');
 perform pg_temp.ok((c->>'ceiling_cents')::int=2147483647 and c->>'kind'='sponsored','testing grant is sponsored');
 update public.app_config set value=value-'net_margin_bps' where key='serving_envelope';
 perform pg_temp.ok((public.plan_serving_ceiling('d2000000-0000-4000-8000-000000000001')->>'ceiling_cents')::int=2053,'a missing envelope key uses its documented default');
 update public.app_config set value=value||'{"net_margin_bps":7500}'::jsonb where key='serving_envelope';
 -- Window accounting: Starter spent 985c in this window and 500c in the previous one.
 perform pg_temp.ok(public.serving_ceiling_spent_cents('d2000000-0000-4000-8000-000000000009',now()-interval '10 days',now()+interval '20 days')=985,'spend outside the paid window does not count');
 perform pg_temp.ok(public.serving_ceiling_spent_cents('d2000000-0000-4000-8000-000000000009',null,null)=1485,'lifetime basis counts everything');
 perform pg_temp.ok(public.serving_ceiling_spent_cents('d2000000-0000-4000-8000-000000000003',now()-interval '5 days',now()+interval '25 days')=4200,'open video holds count against the envelope');
end$$;

set local role service_role;
-- ------------------------------------------------------------ 1+2. one authority, holds bound to ledger rows
do $$declare u uuid:='d1000000-0000-4000-8000-000000000001';pro uuid:='d2000000-0000-4000-8000-000000000001';starter uuid:='d2000000-0000-4000-8000-000000000009';
 free_o uuid:='d2000000-0000-4000-8000-000000000005';intro uuid:='d2000000-0000-4000-8000-000000000004';qa uuid:='d2000000-0000-4000-8000-000000000008';team uuid:='d2000000-0000-4000-8000-000000000003';
 grace uuid:='d2000000-0000-4000-8000-000000000011';r jsonb;ledger uuid;hold uuid;begin
 -- Codex's reproduction: 985 + 6.7 > 991 refused, 985 + 6 admitted.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-starter-over'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,6.7,''verified'')',u,starter,repeat('a',64)),'RP402: AI usage limit reached [kind=retail]','ceiling refuses the attempt that would cross it and names the kind');
 r:=serving_cost_reserve(u,starter,'lb-starter-fit','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),6,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean and r->>'budget'='ceiling'and(r->>'ceiling_cents')::int=991 and(r->>'spent_cents')::numeric=985 and not(r->>'sponsored_unlimited')::boolean,'attempt inside the envelope is reserved against the ceiling budget');
 perform pg_temp.ok((select budget_source='ceiling'and funding_id is null and slice_index is null and state='reserved'and not trial_kind and ledger_id is null from serving_cost_reservations where org_id=starter and request_key='lb-starter-fit'),'ceiling reservation journaled without a funding slice');
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-starter-next'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,0.5,''verified'')',u,starter,repeat('a',64)),'RP402','an open hold counts while the attempt is in flight');
 perform serving_cost_finish(u,starter,'lb-starter-fit','photo.stage:0','rejected',400);
 r:=serving_cost_reserve(u,starter,'lb-starter-next','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),6,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean,'a proven prequeue rejection releases its hold');
 perform serving_cost_finish(u,starter,'lb-starter-next','photo.stage:0','uncertain',null);
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-starter-after-uncertain'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,0.5,''verified'')',u,starter,repeat('a',64)),'RP402','an uncertain (potentially billable) outcome keeps its hold');
 -- Pro: 2000 of 2053. A settled success is NOT dropped on a timer.
 r:=serving_cost_reserve(u,pro,'lb-pro-fit','copy.initial:0','anthropic','claude-sonnet-5',repeat('a',64),53,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean,'Pro attempt exactly at the ceiling is admitted');
 perform serving_cost_finish(u,pro,'lb-pro-fit','copy.initial:0','succeeded',null);
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-pro-over'',''copy.initial:0'',''anthropic'',''claude-sonnet-5'',%L,0.1,''verified'')',u,pro,repeat('a',64)),'RP402','a settled success counts until its ledger row lands');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(pro,now()-interval '10 days',now()+interval '20 days')=2053,'succeeded hold is counted in full');
 -- The ledger row for the same attempt binds the hold (request_key + stage); money is counted exactly once.
 insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values(pro,'copy_assist','anthropic','claude-sonnet-5',1,2.1,2.1,jsonb_build_object('request_key','lb-pro-fit','stage','copy.initial:0'))returning id into ledger;
 perform pg_temp.ok((select r2.ledger_id=ledger from serving_cost_reservations r2 where org_id=pro and request_key='lb-pro-fit'),'ledger row binds the hold of its attempt');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(pro,now()-interval '10 days',now()+interval '20 days')=2002.1,'bound hold stops counting; the ledger row counts instead');
 r:=serving_cost_reserve(u,pro,'lb-pro-over','copy.initial:0','anthropic','claude-sonnet-5',repeat('a',64),50,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean,'money released by the ledger row is admitted again');
 -- A duplicate ledger write binds nothing twice and only adds its own cost.
 insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values(pro,'copy_assist','anthropic','claude-sonnet-5',1,2.1,2.1,jsonb_build_object('request_key','lb-pro-fit','stage','copy.initial:0'));
 perform pg_temp.ok((select count(*)=1 from serving_cost_reservations where org_id=pro and ledger_id is not null),'duplicate ledger write binds no second hold');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(pro,now()-interval '10 days',now()+interval '20 days')=2054.2,'duplicate ledger row still counts as cost (never under)');
 -- A receipt without exact identity cannot release another successful attempt.
 perform serving_cost_finish(u,pro,'lb-pro-over','copy.initial:0','succeeded',null);
 insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents)values(pro,'copy_assist','anthropic','claude-sonnet-5',1,2.1,2.1);
 perform pg_temp.ok((select ledger_id is null from serving_cost_reservations where org_id=pro and request_key='lb-pro-over'),'keyless ledger row preserves the successful hold for reconciliation');
 -- Video: the legacy writer and the serving reservation share ONE authority and count ONCE.
 update public.app_config set value=value||'{"apple_commission_bps":1500}'::jsonb where key='serving_envelope';
 perform pg_temp.refuse(format('select app_video_cost_reserve(%L,%L,''lb-video-over'',''reel'',''fal'',''bytedance/seedance/v1/pro/fast/image-to-video'',%L,9.72,2,4.86,''{}''::jsonb)',u,starter,repeat('b',64)),'RP402: AI usage limit reached [kind=retail]','the video writer is admitted by the same envelope authority (985 + 6 open + 9.72 > 991)');
end$$;
do $$declare u uuid:='d1000000-0000-4000-8000-000000000001';starter uuid:='d2000000-0000-4000-8000-000000000009';team uuid:='d2000000-0000-4000-8000-000000000003';intro uuid:='d2000000-0000-4000-8000-000000000004';
 qa uuid:='d2000000-0000-4000-8000-000000000008';free_o uuid:='d2000000-0000-4000-8000-000000000005';grace uuid:='d2000000-0000-4000-8000-000000000011';pro uuid:='d2000000-0000-4000-8000-000000000001';r jsonb;begin
 -- Release the uncertain Starter hold directly (test authority) so the video path can be shown end to end.
 reset role;update serving_cost_reservations set state='rejected' where org_id=starter and request_key='lb-starter-next';set local role service_role;
 r:=app_video_cost_reserve(u,starter,'lb-video-fit','reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('b',64),4,2,2,'{}'::jsonb);
 perform pg_temp.ok((r->>'reserved')::boolean,'video hold admitted inside the envelope (985 + 4 <= 991)');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(starter,now()-interval '10 days',now()+interval '20 days')=989,'open video hold counts');
 r:=serving_cost_reserve(u,starter,'lb-video-fit','reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('b',64),5,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean and(r->>'spent_cents')::numeric=985,'the serving reservation for the same attempt replaces the legacy hold instead of adding to it');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(starter,now()-interval '10 days',now()+interval '20 days')=990,'one attempt, one count (the serving hold)');
 perform serving_cost_finish(u,starter,'lb-video-fit','reel','succeeded',null);
 r:=app_video_cost_settle(u,starter,'lb-video-fit','fal-request-1');
 perform pg_temp.ok((r->>'settled')::boolean,'video settles into the ledger');
 perform pg_temp.ok((select ledger_id=(r->>'ledger_id')::uuid from serving_cost_reservations where org_id=starter and request_key='lb-video-fit'),'the video ledger row binds the serving hold through the app-video reservation id');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(starter,now()-interval '10 days',now()+interval '20 days')=989,'after settlement only the ledger row (4c) counts');
 -- Team: the open 4200c video hold leaves 1041c of 5241c.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-team-over'',''video.reel_clip'',''fal'',''bytedance/seedance/v1/pro/fast/image-to-video'',%L,1042,''verified'')',u,team,repeat('a',64)),'RP402','video holds share the envelope');
 r:=serving_cost_reserve(u,team,'lb-team-fit','video.reel_clip','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('a',64),1041,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean,'the remainder is still admitted');
 -- Free: 295c lifetime of 300c.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-free-over'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,6,''verified'')',u,free_o,repeat('a',64)),'RP402: AI usage limit reached [kind=free]','free lifetime sample counts spend from earlier months and names the kind');
 r:=serving_cost_reserve(u,free_o,'lb-free-fit','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),5,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean and r->>'basis'='lifetime','free attempt inside the lifetime sample');
 -- Grace: 991c in the 16-day retry window, kind named.
 r:=serving_cost_reserve(u,grace,'lb-grace-fit','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),100,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean and r->>'kind'='grace','billing-retry window still serves');
 -- Trial kind: 500c per window AND the dated sponsor pool; the video writer is bound by the pool too.
 r:=serving_cost_reserve(u,intro,'lb-intro-1','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),400,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean and r->>'kind'='trial'and(select trial_kind from serving_cost_reservations where org_id=intro and request_key='lb-intro-1'),'introductory-week attempt draws from the trial pool');
 perform pg_temp.ok(public.trial_sponsor_spent_cents()=400,'sponsor pool accounts the trial hold');
 update public.app_config set value=value||'{"cap_cents":450}'::jsonb where key='trial_sponsor_pool';
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-intro-2'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,60,''verified'')',u,intro,repeat('a',64)),'RP402: Free-trial AI limit reached [pool=cap]','global sponsor cap refuses trial attempts');
 perform pg_temp.refuse(format('select app_video_cost_reserve(%L,%L,''lb-intro-video'',''reel'',''fal'',''bytedance/seedance/v1/pro/fast/image-to-video'',%L,60,2,4.86,''{}''::jsonb)',u,intro,repeat('c',64)),'RP402: Free-trial AI limit reached [pool=cap]','the video writer honours the sponsor cap');
 update public.app_config set value=value||'{"cap_cents":29000}'::jsonb where key='trial_sponsor_pool';
 r:=serving_cost_reserve(u,intro,'lb-intro-2','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),60,'verified');
 perform pg_temp.ok((r->>'reserved')::boolean,'trial attempt admitted under the cap');
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-intro-3'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,50,''verified'')',u,intro,repeat('a',64)),'RP402: AI usage limit reached [kind=trial]','trial workspace ceiling is 500c per window');
 update public.app_config set value=value||jsonb_build_object('ends_at',to_char(now()-interval '1 minute','YYYY-MM-DD"T"HH24:MI:SS"Z"'))where key='trial_sponsor_pool';
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-intro-4'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,1,''verified'')',u,intro,repeat('a',64)),'RP402: Free-trial AI limit reached [pool=closed]','an ended allocation refuses trial attempts');
 perform pg_temp.ok(exists(select 1 from ops_health_findings()where code='trial_pool_ending'),'an ended allocation is alerted');
 update public.app_config set value=value||jsonb_build_object('ends_at',to_char(now()+interval '30 days','YYYY-MM-DD"T"HH24:MI:SS"Z"'))where key='trial_sponsor_pool';
 delete from public.app_config where key='trial_sponsor_pool';
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-intro-5'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,1,''verified'')',u,intro,repeat('a',64)),'RP402: Free-trial AI limit reached [pool=closed]','no allocation = no trial money');
 perform pg_temp.ok(exists(select 1 from ops_health_findings()where code='trial_pool_missing'),'a missing allocation is alerted');
 insert into public.app_config(key,value)values('trial_sponsor_pool',jsonb_build_object('cap_cents',29000,'starts_at',to_char(now()-interval '1 day','YYYY-MM-DD"T"HH24:MI:SS"Z"'),'ends_at',to_char(now()+interval '30 days','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
 -- Sponsored QA keeps unlimited private sponsorship.
 r:=serving_cost_reserve(u,qa,'lb-qa-unlimited','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),100000,'verified');
 perform pg_temp.ok((r->>'sponsored_unlimited')::boolean,'testing grant remains unlimited sponsorship');
 -- Unpriced attempts stay refused outside sponsorship.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-unpriced'',''presenter.motion'',''higgsfield'',''motion-transfer'',%L,1,''unpriced-private-sponsorship'')',u,pro,repeat('a',64)),'RP403','unpriced route is refused in ceiling mode too');
 -- Guests and outsiders are refused before any money moves.
 perform pg_temp.refuse(format('select serving_cost_reserve(%L,%L,''lb-guest-key'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',%L,1,''verified'')','d1000000-0000-4000-8000-000000000002','d2000000-0000-4000-8000-000000000006',repeat('a',64)),'RP403','anonymous member cannot reserve');
 -- Generated results need an admitted attempt again.
 perform serving_operation_begin(u,pro,'lb-op-no-attempt','coach.chat',repeat('a',64));
 perform pg_temp.refuse(format('select serving_operation_complete(%L,%L,''lb-op-no-attempt'',''{"reply":"invented"}'')',u,pro),'RP409','a result without an admitted provider attempt is refused');
 -- /me state: counted spend, held liability, availability and the window.
 r:=public.serving_envelope_state(starter);
 perform pg_temp.ok((r->>'ceiling_cents')::numeric=991 and(r->>'spent_cents')::numeric=989 and(r->>'held_cents')::numeric=0 and(r->>'available_cents')::numeric=2 and r->>'window'='apple_term'and(r->>'period_end')::timestamptz>now(),'/me envelope state reports ceiling, spend, held, availability and window');
 r:=public.serving_envelope_state(intro);
 perform pg_temp.ok(r->>'kind'='trial'and(r->'pool'->>'cap_cents')::int=29000 and(r->'pool'->>'spent_cents')::numeric=460,'trial state carries the pool');
 perform pg_temp.ok((select count(*)from ops_health_findings()where code like 'org_near_ceiling:%')>=3 and not exists(select 1 from ops_health_findings()where code='org_near_ceiling:'||free_o),'paying workspaces at 80% of their envelope are reported; free samples are not operational alerts');
end$$;

-- ------------------------------------------------------------ 3. Sandbox receipts in signature order, current state reported
do $$declare u uuid:='d1000000-0000-4000-8000-000000000001';o uuid:='d2000000-0000-4000-8000-000000000006';pro uuid:='d2000000-0000-4000-8000-000000000001';r jsonb;first timestamptz;begin
 perform pg_temp.refuse(format('select grant_sandbox_trial(%L,%L,''lb-sb-bad'',''lb-sb-bad-tx'',''com.rendprop.app.pro.monthly'',''bogus'',now()+interval ''3 minutes'',now())',o,u),'RP400','unknown receipt status refused');
 r:=grant_sandbox_trial(o,u,'lb-sb-expired','lb-sb-expired-tx','com.rendprop.app.pro.monthly','expired',now()-interval '1 hour',now()-interval '2 hours');
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='receipt_inactive'and r->>'plan'='free','expired Sandbox receipt grants nothing');
 perform pg_temp.ok((select status='expired'and receipt_expires_at<now()and trial_granted_at is null from apple_sandbox_receipts where original_transaction_id='lb-sb-expired'),'expired receipt is persisted with its facts');
 -- Chronology: a newer refunded receipt, then older active evidence for the same original.
 r:=grant_sandbox_trial(o,u,'lb-sb-refunded','lb-sb-refunded-tx','com.rendprop.app.pro.monthly','refunded',now()+interval '3 minutes',now()-interval '1 minute');
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='receipt_inactive','refunded Sandbox receipt grants nothing');
 r:=grant_sandbox_trial(o,u,'lb-sb-refunded','lb-sb-refunded-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now()-interval '1 hour');
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='stale_receipt'and r->>'receipt_status'='refunded','older active evidence cannot revive a refunded receipt');
 perform pg_temp.ok((select status='refunded'and signed_at>now()-interval '2 minutes'from apple_sandbox_receipts where original_transaction_id='lb-sb-refunded'),'stored facts keep the newer signature');
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
 r:=public.plan_serving_ceiling(o);
 perform pg_temp.ok((r->>'ceiling_cents')::int=500 and r->>'kind'='trial'and r->>'window'='trial_window'and(r->>'period_end')::timestamptz=first,'trial workspace is capped at 500c inside its own window');
 r:=grant_sandbox_trial(o,u,'lb-sb-live','lb-sb-live-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and(r->>'replay')::boolean and(r->>'expires_at')::timestamptz=first and(r->>'grant_ends_at')::timestamptz=first,'replay reports the same window');
 perform pg_temp.ok((select trial_ends_at=first from orgs where id=o),'replay never restarts the clock');
 r:=grant_sandbox_trial(o,u,'lb-sb-second','lb-sb-second-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='trial_active'and(r->>'expires_at')::timestamptz=first,'a second receipt during an open window is recorded, not added');
 perform pg_temp.ok((select trial_granted_at is null from apple_sandbox_receipts where original_transaction_id='lb-sb-second'),'ungranted receipt carries no grant');
 perform pg_temp.refuse(format('select grant_sandbox_trial(%L,%L,''lb-sb-live'',''lb-sb-live-tx'',''com.rendprop.app.pro.monthly'',''active'',now()+interval ''3 minutes'',now())','d2000000-0000-4000-8000-000000000010','d1000000-0000-4000-8000-000000000004'),'RP409','a receipt cannot move to another workspace or account');
 r:=grant_sandbox_trial(pro,u,'lb-sb-paid','lb-sb-paid-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and r->>'reason'='paid_workspace'and r->>'plan'='pro'and r->>'source'='apple'and(r->>'expires_at')::timestamptz>now()+interval '19 days','paid workspace is never downgraded and the reply carries the paid state');
 perform pg_temp.ok((select plan='pro'and plan_source='apple'from orgs where id=pro),'paid plan untouched');
end$$;
-- Eight days later (simulated): the window ended; the spent receipt cannot reopen it, a new purchase can.
reset role;
update orgs set trial_ends_at=now()-interval '1 day'where id='d2000000-0000-4000-8000-000000000006';
update apple_sandbox_receipts set trial_ends_at=now()-interval '1 day'where original_transaction_id='lb-sb-live';
set local role service_role;
do $$declare u uuid:='d1000000-0000-4000-8000-000000000001';o uuid:='d2000000-0000-4000-8000-000000000006';r jsonb;second timestamptz;begin
 perform pg_temp.ok(public.effective_plan(o)='free','ended trial reads as free');
 r:=grant_sandbox_trial(o,u,'lb-sb-live','lb-sb-live-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(not(r->>'granted')::boolean and(r->>'replay')::boolean and r->>'plan'='free'and(r->>'grant_ends_at')::timestamptz<now(),'a spent receipt cannot reopen a window and reports the current free state');
 perform pg_temp.ok((select trial_ends_at<now()from orgs where id=o),'replay of a spent receipt leaves the workspace free');
 r:=grant_sandbox_trial(o,u,'lb-sb-third','lb-sb-third-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok((r->>'granted')::boolean and(r->>'expires_at')::timestamptz>now()+interval '6 days','a new purchase after the window opens one more');
 second:=(r->>'expires_at')::timestamptz;
 r:=grant_sandbox_trial(o,u,'lb-sb-live','lb-sb-live-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok((r->>'replay')::boolean and r->>'plan'='trial'and(r->>'expires_at')::timestamptz=second and(r->>'grant_ends_at')::timestamptz<now(),'an old replay during a newer window reports the CURRENT window, with its own history separate');
 perform pg_temp.ok((select count(*)=2 from apple_sandbox_receipts where org_id=o and trial_granted_at is not null),'each receipt grants at most once');
 -- A paid upgrade afterwards: the old replay reports the paid plan.
 reset role;update orgs set plan='pro',plan_source='apple',plan_expires_at=now()+interval '30 days' where id='d2000000-0000-4000-8000-000000000006';set local role service_role;
 r:=grant_sandbox_trial(o,u,'lb-sb-live','lb-sb-live-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now());
 perform pg_temp.ok(r->>'plan'='pro'and r->>'reason'='paid_workspace'and(r->>'replay')::boolean,'replay after an upgrade reports the paid plan, not the old trial');
 reset role;update orgs set plan='trial',plan_source='trial',plan_expires_at=null where id='d2000000-0000-4000-8000-000000000006';set local role service_role;
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

-- ------------------------------------------------------------ 6. retention: enrollment, consumer, policy start
set local role service_role;
do $$declare pro uuid:='d2000000-0000-4000-8000-000000000001';prepolicy uuid:='d2000000-0000-4000-8000-000000000012';u uuid:='d1000000-0000-4000-8000-000000000001';r jsonb;deadline timestamptz;notice uuid;begin
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
 -- Pre-policy testers: a late EXPIRED notification for a subscription first seen before Oct 6 enrolls nothing.
 r:=apply_apple_entitlement_v2(prepolicy,u,'lb-prepolicy-original','lb-prepolicy-tx-1','com.rendprop.app.pro.monthly','pro','Production','expired',now()-interval '40 days',false,'EXPIRED',now()-interval '70 days',now()-interval '69 days',now()-interval '1 hour',null);
 perform pg_temp.ok(not exists(select 1 from hosting_retention_enrollments where org_id=prepolicy)and public.hosting_retention_state(prepolicy)->>'policy'='preserved','a subscription first seen before the October 6 policy keeps its prior hosting arrangement');
 -- Notice producer AND consumer agree on the enrollment deadline.
 reset role;update hosting_retention_enrollments set retention_ends_at=now()+interval '5 days' where org_id='d2000000-0000-4000-8000-000000000001';set local role service_role;
 r:=public.queue_hosting_retention_notices();
 select id into notice from public.notification_outbox where org_id=pro and payload?'hosting_retention' order by created_at desc limit 1;
 perform pg_temp.ok(notice is not null,'a ceiling-mode enrollment produces a hosting notice');
 perform pg_temp.ok(public.hosting_retention_notice_current(notice),'the delivery consumer recognises the enrollment-backed notice');
 perform pg_temp.ok((select state<>'expired'from public.notification_outbox where id=notice),'the notice is not expired at delivery');
 reset role;update hosting_retention_enrollments set retention_ends_at=now()+interval '60 days' where org_id='d2000000-0000-4000-8000-000000000001';set local role service_role;
 perform pg_temp.ok(not public.hosting_retention_notice_current(notice),'a renewal that moved the deadline withdraws the stale notice');
 perform pg_temp.ok((select state='expired'from public.notification_outbox where id=notice),'withdrawn notice is expired');
 -- The four fixture subscribers without a sync (02, 03, 04, 09, 11) are the alert's subject; synced Pro and the pre-policy tester are not.
 perform pg_temp.ok((select (data->>'orgs')::int=5 from ops_health_findings()where code='retention_missing'),'policy subscriptions without a retention record are alerted; synced and pre-policy workspaces are not');
end$$;
reset role;
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
delete from hosting_retention_enrollments where org_id='d2000000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.ok((select (data->>'orgs')::int=6 from ops_health_findings()where code='retention_missing'),'a paid workspace that lost its retention record joins the alert');
reset role;

-- ------------------------------------------------------------ 7. provider evidence + admin alert currency
set local role service_role;
do $$declare admin_user uuid:='d1000000-0000-4000-8000-000000000001';other uuid:='d1000000-0000-4000-8000-000000000005';row_id uuid;r jsonb;begin
 perform report_provider_outcome('fal','synthetic/dead-model',false,620,'upstream',401);
 perform report_provider_outcome('fal','synthetic/dead-model',false,610,'upstream',401);
 perform report_provider_outcome('fal','synthetic/dead-model',false,630,'upstream');
 perform pg_temp.ok((select consecutive_failures=3 and last_status is null and open_until>now()from provider_health where provider='fal'and model='synthetic/dead-model'),'five-argument reports still work and clear an unknown status');
 perform report_provider_outcome('fal','synthetic/dead-model',false,640,'upstream',402);
 perform pg_temp.ok((select last_status=402 from provider_health where provider='fal'and model='synthetic/dead-model'),'the breaker keeps the last upstream status');
 perform pg_temp.ok(exists(select 1 from ops_health_findings()where code='provider_dead:fal:synthetic/dead-model'and body like '%last HTTP 402 = the provider account is out of balance%'and(data->>'last_status')::int=402),'the hourly alert names the status');
 -- Alerts are labelled, re-validated at delivery, and die with their finding or their recipient's admin status.
 r:=public.ops_health_check();
 select id into row_id from public.notification_outbox where category='ops_alert'and user_id=admin_user and payload->>'code'='provider_dead:fal:synthetic/dead-model'and channel='email';
 perform pg_temp.ok(row_id is not null and(select payload->>'title'like 'Admin alert: %'from public.notification_outbox where id=row_id),'admin alerts are queued for admins and labelled');
 perform pg_temp.ok(public.ops_alert_current(row_id),'a current finding for a current admin delivers');
 perform report_provider_outcome('fal','synthetic/dead-model',true,500,null,null);
 perform pg_temp.ok((select consecutive_failures=0 and open_until is null from provider_health where provider='fal'and model='synthetic/dead-model'),'a success closes the circuit');
 perform pg_temp.ok(not public.ops_alert_current(row_id),'a cleared finding is not delivered');
 perform pg_temp.ok((select state='expired'from public.notification_outbox where id=row_id),'a cleared finding expires its queued alert instead of delivering stale news');
 reset role;
 insert into public.notification_outbox(org_id,user_id,category,channel,dedupe_key,payload)values(null,other,'ops_alert','email','lb-ops-non-admin',jsonb_build_object('title','Admin alert: x','body','y','code','serving_mode_config'))returning id into row_id;
 set local role service_role;
 perform pg_temp.ok(not public.ops_alert_current(row_id),'a non-admin recipient never receives an admin alert');
 perform pg_temp.ok(not has_function_privilege('authenticated','public.report_provider_outcome(text,text,boolean,integer,text,integer)','execute'),'tenants cannot write provider health');
 perform pg_temp.ok(not has_function_privilege('authenticated','public.ops_alert_current(uuid)','execute'),'tenants cannot consult alert currency');
end$$;
reset role;
-- ------------------------------------------------------------ audit 2026-10-09: video hold netted once, never twice
insert into orgs(id,name,plan)values('d2000000-0000-4000-8000-0000000000c1','Synthetic pre netting','free');
insert into memberships(user_id,org_id,role)select user_id,'d2000000-0000-4000-8000-0000000000c1','owner' from memberships where org_id='d2000000-0000-4000-8000-000000000009' and role='owner' limit 1;
do $$declare actor uuid;begin
 select user_id into actor from memberships where org_id='d2000000-0000-4000-8000-0000000000c1';
 insert into app_video_cost_reservations(org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)values
  ('d2000000-0000-4000-8000-0000000000c1',actor,'pre-key-0001','drone_render','fal','fal-ai/topaz/upscale/video',repeat('c',64),10,20,200,200,'{}');
 perform pg_temp.ok((public.serving_envelope_admit('d2000000-0000-4000-8000-0000000000c1',200,'pre-key-0001')->>'spent_cents')::numeric=0,
  'first serving admission for a video attempt replaces its legacy hold (200 + 200 <= 300 lifetime)');
 insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state,settled_at)values
  ('d2000000-0000-4000-8000-0000000000c1',actor,'pre-key-0001','drone_render','fal','fal-ai/topaz/upscale/video',repeat('c',64),'x',200,'ceiling','uncertain',now());
 begin perform public.serving_envelope_admit('d2000000-0000-4000-8000-0000000000c1',290,'pre-key-0001');
  perform pg_temp.ok(false,'a later admission under the same key must not subtract the video hold a second time');
 exception when others then perform pg_temp.ok(sqlerrm like 'RP402: AI usage limit reached [kind=free] (200 of 300%','a later admission under the same key counts the attempt once: 200 + 290 > 300 refused');end;
 begin perform public.serving_envelope_admit('d2000000-0000-4000-8000-0000000000c1',290,'pre-key-other');
  perform pg_temp.ok(false,'another key is refused at the same boundary');
 exception when others then perform pg_temp.ok(sqlerrm like 'RP402:%','the same request key gets no discount over any other key');end;
 perform pg_temp.ok((public.serving_envelope_admit('d2000000-0000-4000-8000-0000000000c1',100,'pre-key-0001')->>'spent_cents')::numeric=200,'exactly the remaining 100c is still admissible under that key');
end$$;
select pg_temp.ok(not exists(select 1 from information_schema.table_privileges where table_schema='public' and grantee in('anon','authenticated') and privilege_type in('TRUNCATE','TRIGGER','REFERENCES')),'client roles hold no TRUNCATE/TRIGGER/REFERENCES on public tables');

select jsonb_build_object('assertions',n,'passed',true)from lb_assertions;
rollback;
