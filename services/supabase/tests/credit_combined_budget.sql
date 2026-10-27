-- Synthetic signed-period projection; no hosted price, wallet or policy writes.
begin;
create temporary table combined_checks(n integer not null default 0);
insert into combined_checks default values;
grant all on combined_checks to service_role;
create function pg_temp.combined_ok(v boolean,label text) returns void language plpgsql as $$
begin if v is distinct from true then raise exception 'COMBINED BUDGET FAIL: %',label;end if;
 update combined_checks set n=n+1;end$$;
create function pg_temp.combined_refuses(q text,needle text,label text)returns void language plpgsql as $$
begin begin execute q;exception when others then
 if position(needle in sqlerrm)>0 then perform pg_temp.combined_ok(true,label);return;end if;
 raise;end;raise exception 'COMBINED BUDGET FAIL admitted: %',label;end$$;

select pg_temp.combined_ok((select value->'enabled'='false'::jsonb
  from public.app_config where key='credit_combined_budget'),
  'new shared margin authority is dormant by migration');
insert into auth.users(id,email,is_anonymous) values
 ('91111111-1111-4111-8111-111111111111','combined-fixture@example.invalid',false);
create temporary table combined_cases(org_id uuid,sku text,plan text,price bigint,
  monthly_credits integer,expected_budget integer,expected_noncredit integer);
insert into combined_cases values
 ('91aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','com.rendprop.app.pro29.monthly','pro',29990,80,894,494),
 ('92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','com.rendprop.app.starter.monthly','starter',49990,200,1524,524),
 ('93aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','com.rendprop.app.pro.monthly','pro',99990,440,3099,899),
 ('94aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','com.rendprop.app.team.monthly','team',249990,1000,7824,2824);
grant select on combined_cases to service_role;
insert into public.orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)
select org_id,'Combined supplier fixture',plan,'apple',sku,now()+interval '29 days'
 from combined_cases;
insert into public.memberships(user_id,org_id,role)
select '91111111-1111-4111-8111-111111111111',org_id,'owner' from combined_cases;
insert into public.apple_subscriptions(original_transaction_id,org_id,user_id,
  product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,
  transaction_purchased_at,transaction_signed_at)
select 'combined-chain-'||org_id,org_id,
 '91111111-1111-4111-8111-111111111111',sku,plan,'Production','active',
 now()+interval '29 days',true,'combined-tx-'||org_id,
 now()-interval '1 day',now()-interval '1 day'+interval '1 minute'
from combined_cases;
insert into public.credit_monthly_events(environment,transaction_id,
 original_transaction_id,org_id,product_id,state,event_signed_at,
 price_milliunits,period_start,period_end)
select 'Production','combined-tx-'||org_id,'combined-chain-'||org_id,
 org_id,sku,'paid',now()-interval '1 day'+interval '1 minute',price,
 now()-interval '1 day',now()+interval '29 days' from combined_cases;
update public.credit_monthly_catalog set active=true
 where product_id in(select sku from combined_cases);
insert into public.credit_grants(org_id,environment,source,reference,
 product_id,granted_credits,remaining_credits,starts_at,expires_at)
select org_id,'Production','monthly','apple:combined-tx-'||org_id,
 sku,monthly_credits,monthly_credits,now()-interval '1 day',now()+interval '29 days'
from combined_cases;
set local role service_role;
select pg_temp.combined_ok(
 (public.credit_combined_budget_state((select org_id from combined_cases
   where plan='team'))->>'applicable')::boolean=false and
 not public.credit_primary_subscription((select org_id from combined_cases
   where plan='team'),'Production'),
 'a monthly grant alone never activates the combined paid serving policy');
reset role;
update public.app_config set value=value||jsonb_build_object(
 'enabled',true,'activated_from',now()-interval '2 days')
 where key='credit_combined_budget';
set local role service_role;
do $$declare c record;s jsonb;e jsonb;begin
 for c in select * from combined_cases loop
  s:=public.credit_combined_budget_state(c.org_id);
  perform pg_temp.combined_ok((s->>'applicable')::boolean and
    (s->>'combined_ceiling_cents')::integer=c.expected_budget and
    (s->>'monthly_credit_face_cents')::integer=c.monthly_credits*5 and
    (s->>'noncredit_ceiling_cents')::integer=c.expected_noncredit,
    'exact signed price gives conservative combined cap and full credit ring-fence: '||c.sku);
 end loop;
 e:=public.plan_serving_ceiling((select org_id from combined_cases
   where sku='com.rendprop.app.pro.monthly'));
 perform pg_temp.combined_ok(e->>'allowance_policy'='credit-combined-v1' and
   (e->>'ceiling_cents')::integer=899 and
   public.credit_primary_subscription((select org_id from combined_cases
     where sku='com.rendprop.app.pro.monthly'),'Production'),
   'active Ultra period exposes only noncredit headroom while all 440 credits remain funded');
 perform pg_temp.combined_refuses(format(
   'select public.library_serving_envelope_admit(%L,%L,900,%L)',
   (select org_id from combined_cases where sku='com.rendprop.app.pro.monthly'),
   (select org_id from combined_cases where sku='com.rendprop.app.pro.monthly'),
   'combined-over'),
   'RP402:','noncredit tool cannot spend the monthly credit ring-fence');
end$$;
reset role;
insert into public.credit_grants(org_id,environment,source,reference,
 product_id,granted_credits,remaining_credits,expires_at)
select org_id,'Production','topup','separate-paid-topup',
 'com.rendprop.app.credits.100',100,100,null from combined_cases
 where sku='com.rendprop.app.starter.monthly';
set local role service_role;
select pg_temp.combined_ok(
 (public.credit_combined_budget_state((select org_id from combined_cases
   where sku='com.rendprop.app.starter.monthly'))->>'monthly_credit_face_cents')::integer=1000,
 'independent purchased top-ups do not consume subscription credit reserve');
do $$declare actor uuid:='91111111-1111-4111-8111-111111111111';
 org uuid:='92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 key text:='combined-credit-0001';result jsonb;begin
 result:=public.serving_operation_begin(actor,org,key,'/ai-photo',repeat('a',64));
 result:=public.credit_wallet_reserve(actor,org,'Production',key,
   'photo.declutter','photo-declutter-v1');
 perform pg_temp.combined_ok((result->>'reserved')::boolean,
   'monthly credit remains spendable inside ring-fenced liability');
 result:=public.credit_serving_cost_reserve(actor,org,key,'photo.declutter:0',
   'gemini','gemini-3-pro-image',repeat('b',64),25,'quoted-pro4k',org,key,'Production');
 result:=public.serving_cost_finish(actor,org,key,'photo.declutter:0','succeeded',null);
 insert into public.cost_ledger(org_id,feature,provider,model,total_cents,meta)
 values(org,'photo_edit','gemini','gemini-3-pro-image',25,
   jsonb_build_object('request_key',key,'stage','photo.declutter:0','actor_id',actor));
 result:=public.credit_combined_budget_state(org);
 if (result->>'linked_credit_ledger_cents')::numeric<>25 or
   (public.plan_serving_ceiling(org)->>'ceiling_cents')::numeric<>549 or
   public.org_month_spend_cents(org)<>0 then
   raise exception 'COMBINED DIAGNOSTIC: state %, plan %, spend %',result,
     public.plan_serving_ceiling(org),public.org_month_spend_cents(org);
 end if;
 perform pg_temp.combined_ok((result->>'linked_credit_ledger_cents')::numeric=25 and
   (public.plan_serving_ceiling(org)->>'ceiling_cents')::numeric=549 and
   public.org_month_spend_cents(org)=0,
   'settled credit supplier cost is counted once, outside noncredit early spend');
 insert into public.cost_ledger(org_id,feature,provider,model,total_cents,meta)
 values(org,'photo_helper','gemini','gemini-2.5-flash',20,
   jsonb_build_object('request_key','combined-assessment-0001','stage','photo.suggest'));
 perform pg_temp.combined_ok(public.org_month_spend_cents(org)=20 and
   public.serving_ceiling_spent_cents(org,
     (result->>'period_start')::timestamptz,
     (result->>'period_end')::timestamptz)=45,
   'pre-generation assessment supplier cost stays inside the noncredit slice');
end$$;
reset role;
insert into public.credit_grants(org_id,environment,source,reference,
 product_id,granted_credits,remaining_credits,starts_at,expires_at)
select org_id,'Production','monthly','apple:overlap-seat-upgrade',
 sku,1000,1000,now()-interval '1 day',now()+interval '29 days'
from combined_cases where sku='com.rendprop.app.team.monthly';
set local role service_role;
select pg_temp.combined_refuses(format(
 'select public.credit_combined_budget_state(%L)',
 (select org_id from combined_cases where sku='com.rendprop.app.team.monthly')),
 'RP503:','overlapping seat-upgrade grants fail closed before supplier overspend');
reset role;
select json_build_object('passed',true,'assertions',(select n from combined_checks));
rollback;
