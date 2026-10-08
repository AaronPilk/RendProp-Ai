-- Diagnostic reproduction of defects in f17d2bd; not a release-pass suite.
-- Run only on an owned disposable final-schema database with synthetic fixtures.
-- Timestamps are modeled; no clock wait, hosted calls or paid providers.
-- BEGIN/ROLLBACK scopes all fixture writes. Never run against production.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('a8100000-0000-4000-8000-000000000001','financial-review@example.invalid',false,now());
insert into orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)values
 ('a8200000-0000-4000-8000-000000000001','Synthetic paid cycle boundary','starter','apple','com.rendprop.app.starter.monthly',date_trunc('month',now())-interval '2 days'+interval '30 days'),
 ('a8200000-0000-4000-8000-000000000002','Synthetic refunded test receipt','free',null,null,null),
 ('a8200000-0000-4000-8000-000000000003','Synthetic paid replay response','free',null,null,null),
 ('a8200000-0000-4000-8000-000000000004','Synthetic ceiling hosting notice','free',null,null,null);
insert into memberships(user_id,org_id,role)select 'a8100000-0000-4000-8000-000000000001',id,'owner'from orgs where id::text like 'a8200000-%';
insert into apple_subscriptions(original_transaction_id,org_id,user_id,product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,transaction_purchased_at)values
 ('financial-cycle-boundary','a8200000-0000-4000-8000-000000000001','a8100000-0000-4000-8000-000000000001','com.rendprop.app.starter.monthly','starter','Production','active',date_trunc('month',now())-interval '2 days'+interval '30 days',false,'financial-cycle-tx',date_trunc('month',now())-interval '2 days');
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,created_at)values
 ('a8200000-0000-4000-8000-000000000001','photo_edit','gemini','gemini-3.1-flash-image',1,991,991,date_trunc('month',now())-interval '1 day');
set local role service_role;
select jsonb_build_object('case','paid_calendar_boundary','ceiling',plan_serving_ceiling('a8200000-0000-4000-8000-000000000001'),'counted_spend',serving_ceiling_spent_cents('a8200000-0000-4000-8000-000000000001','month'),'already_spent_in_this_same_paid_period',(select sum(total_cents)from cost_ledger where org_id='a8200000-0000-4000-8000-000000000001'));
select jsonb_build_object('case','paid_calendar_full_budget_admitted_again','result',serving_cost_reserve('a8100000-0000-4000-8000-000000000001','a8200000-0000-4000-8000-000000000001','financial-calendar-key','copy.initial:0','anthropic','claude-sonnet-5',repeat('a',64),991,'route-catalog'));
select jsonb_build_object('case','sandbox_new_refund','result',grant_sandbox_trial('a8200000-0000-4000-8000-000000000002','a8100000-0000-4000-8000-000000000001','financial-refund-original','financial-refund-tx','com.rendprop.app.pro.monthly','refunded',now()+interval '3 minutes',now()));
select jsonb_build_object('case','sandbox_replay_older_active_after_refund','result',grant_sandbox_trial('a8200000-0000-4000-8000-000000000002','a8100000-0000-4000-8000-000000000001','financial-refund-original','financial-active-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now()-interval '1 minute'));
select jsonb_build_object('case','sandbox_row_after_older_active','receipt_status',status,'latest_signed_stays_newer',signed_at=now(),'trial_granted',trial_granted_at is not null)from apple_sandbox_receipts where original_transaction_id='financial-refund-original';
select jsonb_build_object('case','sandbox_first_grant_before_paid','result',grant_sandbox_trial('a8200000-0000-4000-8000-000000000003','a8100000-0000-4000-8000-000000000001','financial-paid-replay-original','financial-paid-replay-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now()));
reset role;
update orgs set plan='pro',plan_source='apple',apple_product_id='com.rendprop.app.pro.monthly',plan_expires_at=now()+interval '30 days'where id='a8200000-0000-4000-8000-000000000003';
set local role service_role;
select jsonb_build_object('case','sandbox_already_granted_replay_after_paid_upgrade','result',grant_sandbox_trial('a8200000-0000-4000-8000-000000000003','a8100000-0000-4000-8000-000000000001','financial-paid-replay-original','financial-paid-replay-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now()),'actual_effective_plan',effective_plan('a8200000-0000-4000-8000-000000000003'));
select jsonb_build_object('case','ceiling_notice_enrollment','result',hosting_retention_enroll('a8200000-0000-4000-8000-000000000004','apple_subscription','financial-notice-original',now()-interval '70 days'));
select jsonb_build_object('case','ceiling_notice_queue','queued_count',queue_hosting_retention_notices());
select jsonb_build_object('case','ceiling_notice_before_consumer','id',id,'state',state,'payload',payload)from notification_outbox where org_id='a8200000-0000-4000-8000-000000000004';
select jsonb_build_object('case','ceiling_notice_consumer_acceptance','accepted',hosting_retention_notice_current(id))from notification_outbox where org_id='a8200000-0000-4000-8000-000000000004';
select jsonb_build_object('case','ceiling_notice_after_consumer','state',state,'hosting_state',hosting_retention_state(org_id))from notification_outbox where org_id='a8200000-0000-4000-8000-000000000004';
rollback;
