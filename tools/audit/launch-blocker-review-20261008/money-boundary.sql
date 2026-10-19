-- Diagnostic reproduction of defects in f17d2bd; not a release-pass suite.
-- Run only on an owned disposable final-schema database with synthetic fixtures.
-- Timestamps are modeled; no clock wait, hosted calls or paid providers.
-- BEGIN/ROLLBACK scopes all fixture writes. Never run against production.
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'Reproducer expectation failed: %',label;end if;end$$;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('f1000000-0000-4000-8000-000000000001','f17-money-audit@example.invalid',false,now());
insert into orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at,trial_ends_at)values
('f2000000-0000-4000-8000-000000000001','Synthetic video mixed ceiling','starter','apple','com.rendprop.app.starter.monthly',now()+interval '20 days',null),
('f2000000-0000-4000-8000-000000000002','Synthetic successful ledger outage','starter','apple','com.rendprop.app.starter.monthly',now()+interval '20 days',null),
('f2000000-0000-4000-8000-000000000003','Synthetic trial video sponsor','trial','trial',null,null,now()+interval '6 days'),
('f2000000-0000-4000-8000-000000000004','Synthetic prior month uncertainty','starter','apple','com.rendprop.app.starter.monthly',now()+interval '20 days',null);
insert into memberships(user_id,org_id,role)select 'f1000000-0000-4000-8000-000000000001',id,'owner'from orgs where id::text like 'f2000000-%';
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents)values
('f2000000-0000-4000-8000-000000000001','photo_edit','gemini','gemini-3.1-flash-image',1,980,980),
('f2000000-0000-4000-8000-000000000002','photo_edit','gemini','gemini-3.1-flash-image',1,985,985);
set local role service_role;
select serving_cost_reserve('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','f17-photo-hold','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),10,'route-catalog');
select bump_rate_receipt('reelmo:f2000000-0000-4000-8000-000000000001',2592000,6,1);
select bump_rate_receipt('aivideo:f2000000-0000-4000-8000-000000000001',300,6,1);
select app_video_cost_reserve_v2('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','f17-video-over','reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('b',64),9.72,2,4.86,'{}',
 (select window_start from rate_limits where key='reelmo:f2000000-0000-4000-8000-000000000001'),(select window_start from rate_limits where key='aivideo:f2000000-0000-4000-8000-000000000001'),null);
select pg_temp.must(serving_ceiling_spent_cents('f2000000-0000-4000-8000-000000000001','month')=999.72,'actual video v2 writer ignores991c envelope and10c existing serving hold');
select jsonb_build_object('case','mixed_photo_video_admission','sku_ceiling',plan_serving_ceiling('f2000000-0000-4000-8000-000000000001'),'legacy_video_spend',org_month_spend_cents('f2000000-0000-4000-8000-000000000001'),'true_committed',serving_ceiling_spent_cents('f2000000-0000-4000-8000-000000000001','month'));
select serving_cost_reserve('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000002','f17-success-first','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),6,'route-catalog');
select serving_cost_finish('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000002','f17-success-first','photo.stage:0','succeeded',null);
select pg_temp.must(serving_ceiling_spent_cents('f2000000-0000-4000-8000-000000000002','month')=991,'fresh successful hold counts');
reset role;
-- Move only the local synthetic receipt clock to model a ledger outage lasting >2min.
update serving_cost_reservations set settled_at=now()-interval '3 minutes'where org_id='f2000000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.must(serving_ceiling_spent_cents('f2000000-0000-4000-8000-000000000002','month')=985,'successful hold vanished without a ledger row');
select serving_cost_reserve('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000002','f17-success-second','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('c',64),6,'route-catalog');
select jsonb_build_object('case','successful_hold_missing_ledger_after2m','counted_committed',serving_ceiling_spent_cents('f2000000-0000-4000-8000-000000000002','month'),'actual_prior_ledger_plus_nonrejected_holds',985+(select sum(hold_cents)from serving_cost_reservations where org_id='f2000000-0000-4000-8000-000000000002'and state<>'rejected'));
reset role;
update app_config set value=value||'{"trial_sponsor_cap_cents":0}'::jsonb where key='serving_envelope';
set local role service_role;
select bump_rate_receipt('reelmo:f2000000-0000-4000-8000-000000000003',2592000,4,1);
select bump_rate_receipt('aivideo:f2000000-0000-4000-8000-000000000003',300,6,1);
select app_video_cost_reserve_v2('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000003','f17-trial-video','reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('d',64),9.72,2,4.86,'{}',
 (select window_start from rate_limits where key='reelmo:f2000000-0000-4000-8000-000000000003'),(select window_start from rate_limits where key='aivideo:f2000000-0000-4000-8000-000000000003'),null);
select jsonb_build_object('case','trial_video_ignores_global_pool','pool_cap',serving_envelope_int('trial_sponsor_cap_cents',29000),'trial_pool_counted',trial_sponsor_spent_cents(),'accepted_video_hold',app_video_held_cents('f2000000-0000-4000-8000-000000000003'));
do $$begin begin perform serving_cost_reserve('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000003','f17-trial-helper','copy.initial:0','anthropic','claude-sonnet-5',repeat('e',64),1,'route-catalog');raise exception 'Expected helper pool refusal';exception when others then if position('RP402: Free-trial AI limit reached' in sqlerrm)=0 then raise;end if;end;end$$;
select serving_cost_reserve('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000004','f17-old-uncertain','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('f',64),991,'route-catalog');
select serving_cost_finish('f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000004','f17-old-uncertain','photo.stage:0','uncertain',null);
reset role;
update serving_cost_reservations set created_at=date_trunc('month',now())-interval '1 second'where org_id='f2000000-0000-4000-8000-000000000004';
set local role service_role;
select jsonb_build_object('case','month_rollover_uncertain_hold','counted_spend',serving_ceiling_spent_cents('f2000000-0000-4000-8000-000000000004','month'),'unresolved_liability',(select sum(hold_cents)from serving_cost_reservations where org_id='f2000000-0000-4000-8000-000000000004'and state='uncertain'));
rollback;
