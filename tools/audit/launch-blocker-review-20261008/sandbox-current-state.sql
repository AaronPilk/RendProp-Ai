-- Diagnostic reproduction of defects in f17d2bd; not a release-pass suite.
-- Run only on an owned disposable final-schema database with synthetic fixtures.
-- Timestamps are modeled; no clock wait, hosted calls or paid providers.
-- BEGIN/ROLLBACK scopes all fixture writes. Never run against production.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('a8100000-0000-4000-8000-000000000009','financial-inactive-replay@example.invalid',false,now());
insert into orgs(id,name,plan)values('a8200000-0000-4000-8000-000000000009','Synthetic distinct-window replay','free');
insert into memberships(user_id,org_id,role)values('a8100000-0000-4000-8000-000000000009','a8200000-0000-4000-8000-000000000009','owner');
set local role service_role;
select jsonb_build_object('case','old_receipt_first_window','result',grant_sandbox_trial('a8200000-0000-4000-8000-000000000009','a8100000-0000-4000-8000-000000000009','financial-old-window-original','financial-old-window-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now()-interval '2 minutes'));
reset role;
update orgs set trial_ends_at=now()-interval '1 day'where id='a8200000-0000-4000-8000-000000000009';
update apple_sandbox_receipts set trial_ends_at=now()-interval '1 day'where original_transaction_id='financial-old-window-original';
set local role service_role;
select jsonb_build_object('case','new_receipt_second_current_window','result',grant_sandbox_trial('a8200000-0000-4000-8000-000000000009','a8100000-0000-4000-8000-000000000009','financial-new-window-original','financial-new-window-tx','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now()-interval '1 minute'));
select jsonb_build_object('case','expired_old_receipt_replay_during_valid_different_window','result',grant_sandbox_trial('a8200000-0000-4000-8000-000000000009','a8100000-0000-4000-8000-000000000009','financial-old-window-original','financial-old-window-tx','com.rendprop.app.pro.monthly','expired',now()-interval '1 minute',now()),'actual_effective_plan',effective_plan('a8200000-0000-4000-8000-000000000009'),'actual_trial_end',(select trial_ends_at from orgs where id='a8200000-0000-4000-8000-000000000009'));
reset role;
update orgs set plan='pro',plan_source='apple',apple_product_id='com.rendprop.app.pro.monthly',plan_expires_at=now()+interval '30 days'where id='a8200000-0000-4000-8000-000000000009';
set local role service_role;
select jsonb_build_object('case','expired_just_granted_receipt_replay_during_paid_plan','result',grant_sandbox_trial('a8200000-0000-4000-8000-000000000009','a8100000-0000-4000-8000-000000000009','financial-new-window-original','financial-new-window-tx','com.rendprop.app.pro.monthly','expired',now()-interval '1 minute',now()),'actual_effective_plan',effective_plan('a8200000-0000-4000-8000-000000000009'));
rollback;
