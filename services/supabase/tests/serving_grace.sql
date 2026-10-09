\set ON_ERROR_STOP on
-- Real functions on a disposable final schema. Relative dates simulate paid,
-- grace and recovered terms; no clock changes, provider calls or live writes.
begin;
create temporary table grace_assertions(n integer not null default 0);
insert into grace_assertions default values;
grant all on grace_assertions to service_role;
create function pg_temp.grace_ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'SERVING-GRACE FAIL: %',label;end if;
 update grace_assertions set n=n+1;
end$$;
create function pg_temp.grace_refuse(statement text,label text)returns void language plpgsql as $$begin
 begin execute statement;exception when others then
  if position('RP402: AI usage limit reached' in sqlerrm)>0 then perform pg_temp.grace_ok(true,label);return;end if;
  raise exception 'SERVING-GRACE FAIL: % — unexpected %',label,sqlerrm;
 end;
 raise exception 'SERVING-GRACE FAIL: % — expected financial refusal',label;
end$$;

update public.app_config set value=jsonb_build_object('mode','ceiling','free_published_listings',1)where key='serving_mode';
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
 ('b9100000-0000-4000-8000-000000000001','grace-owner@example.invalid',false,now());
insert into orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)values
 ('b9200000-0000-4000-8000-000000000001','Exhausted monthly fallback','starter','apple','com.rendprop.app.starter.monthly',now()-interval '2 days'),
 ('b9200000-0000-4000-8000-000000000002','Partly unused monthly fallback','starter','apple','com.rendprop.app.starter.monthly',now()-interval '2 days'),
 ('b9200000-0000-4000-8000-000000000003','Exhausted annual fallback','starter','apple','com.rendprop.app.starter.annual',now()-interval '2 days'),
 ('b9200000-0000-4000-8000-000000000004','Partly unused annual fallback','starter','apple','com.rendprop.app.starter.annual',now()-interval '2 days'),
 ('b9200000-0000-4000-8000-000000000005','Ended actual grace','starter','apple','com.rendprop.app.starter.monthly',now()-interval '2 days'),
 ('b9200000-0000-4000-8000-000000000006','Manual no receipt','pro','manual',null,null),
 ('b9200000-0000-4000-8000-000000000007','Legacy no receipt','starter','apple','com.rendprop.app.starter.monthly',now()+interval '20 days'),
 ('b9200000-0000-4000-8000-000000000008','Grace missing chronology','starter','apple','com.rendprop.app.starter.monthly',now()+interval '5 days'),
 ('b9200000-0000-4000-8000-000000000009','Expired intro no paid renewal','starter','apple','com.rendprop.app.starter.monthly',now()-interval '1 day'),
 ('b9200000-0000-4000-8000-000000000010','Seven-day intro plus28-day grace','starter','apple','com.rendprop.app.starter.monthly',now()+interval '25 days'),
 ('b9200000-0000-4000-8000-000000000011','Paid-looking actual grace without retained paid expiry','starter','apple','com.rendprop.app.starter.monthly',now()+interval '5 days');
insert into memberships(user_id,org_id,role)
select 'b9100000-0000-4000-8000-000000000001',id,'owner'from orgs where id::text like 'b9200000-%';
insert into apple_subscriptions(original_transaction_id,org_id,user_id,product_id,plan,environment,status,expires_at,last_transaction_id,transaction_purchased_at)
select 'grace-original-'||right(id::text,2),id,'b9100000-0000-4000-8000-000000000001',apple_product_id,plan,'Production',
 case when right(id::text,2)in('05','08','10','11')then 'grace'else 'active'end,
 plan_expires_at,'grace-tx-'||right(id::text,2),
 case when right(id::text,2)='08'then null
      when right(id::text,2)='09'then now()-interval '8 days'
      when right(id::text,2)='10'then now()-interval '10 days'
      when right(id::text,2)in('03','04')then (now()-interval '2 days')-interval '1 year'
      when right(id::text,2)='05'then (now()-interval '10 days')-interval '1 month'
      else (now()-interval '2 days')-interval '1 month'end
from orgs where id::text like 'b9200000-%'and right(id::text,2)not in('06','07');

-- The exhausted paid term's ledger falls before the old grace-only window.
-- The annual partial ledger begins at the true last slice, before a wrongly
-- stretched annual-with-grace slice would start. Active records here retain
-- the signed paid expiry; real statusgrace records cannot prove it and refuse.
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,created_at)
select o.id,'photo_edit','gemini','gemini-3.1-flash-image',1,c,c,
 case when right(o.id::text,2)='04'then
  (now()-interval '2 days')-((now()-interval '2 days')-((now()-interval '2 days')-interval '1 year'))/12+interval '1 hour'
 else now()-interval '3 days'end
from orgs o cross join lateral(select (public.plan_serving_ceiling(o.id)->>'ceiling_cents')::numeric-
 case when right(o.id::text,2)='02'then 50 when right(o.id::text,2)='04'then 90 else 0 end as c)price
where right(o.id::text,2)in('01','02','03','04')and o.id::text like 'b9200000-%';
-- Prior annual slices are not funded again or charged against the last slice.
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,created_at)values
 ('b9200000-0000-4000-8000-000000000004','photo_edit','gemini','gemini-3.1-flash-image',1,200,200,now()-interval '60 days'),
 ('b9200000-0000-4000-8000-000000000002','photo_edit','gemini','gemini-3.1-flash-image',1,20,20,now()-interval '1 day'),
 ('b9200000-0000-4000-8000-000000000004','photo_edit','gemini','gemini-3.1-flash-image',1,10,10,now()-interval '1 day');

set local role service_role;
do $$declare u uuid:='b9100000-0000-4000-8000-000000000001';o uuid;env jsonb;state jsonb;r jsonb;cap numeric;start_at timestamptz;begin
 o:='b9200000-0000-4000-8000-000000000001';env:=public.plan_serving_ceiling(o);cap:=(env->>'ceiling_cents')::numeric;
 state:=public.serving_envelope_state(o);
 perform pg_temp.grace_ok((state->>'spent_cents')::numeric=cap and(state->>'available_cents')::numeric=0,'exhausted monthly term leaves no grace money');
 perform pg_temp.grace_ok(env->>'kind'='grace'and(env->>'period_start')::timestamptz=(now()-interval '2 days')-interval '1 month','monthly fallback retains the purchased term start');
 perform pg_temp.grace_refuse(format('select public.serving_envelope_admit(%L,1,''monthly-exhausted'')',o),'exhausted monthly grace refuses another cent');

 o:='b9200000-0000-4000-8000-000000000002';env:=public.plan_serving_ceiling(o);cap:=(env->>'ceiling_cents')::numeric;
 perform pg_temp.grace_ok(env->>'kind'='grace'and(env->>'period_end')::timestamptz=now()+interval '14 days','monthly unused allowance retains the original paid term through the fallback');
 state:=public.serving_envelope_state(o);
 perform pg_temp.grace_ok((state->>'spent_cents')::numeric=cap-30 and(state->>'available_cents')::numeric=30,'partial monthly allowance includes paid and existing grace ledger');
 r:=public.serving_cost_reserve(u,o,'grace-monthly-partial','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),30,'verified');
 perform pg_temp.grace_ok((r->>'reserved')::boolean,'remaining monthly grace money is usable');
 perform pg_temp.grace_refuse(format('select public.serving_envelope_admit(%L,1,''monthly-after-hold'')',o),'new monthly grace hold exhausts the same paid allowance');

 o:='b9200000-0000-4000-8000-000000000003';env:=public.plan_serving_ceiling(o);cap:=(env->>'ceiling_cents')::numeric;
 start_at:=(now()-interval '2 days')-((now()-interval '2 days')-((now()-interval '2 days')-interval '1 year'))/12;
 perform pg_temp.grace_ok((env->>'period_start')::timestamptz=start_at,'annual fallback retains only the last paid slice');
 state:=public.serving_envelope_state(o);
 perform pg_temp.grace_ok((state->>'spent_cents')::numeric=cap and(state->>'available_cents')::numeric=0,'exhausted final annual slice leaves no grace money');
 perform pg_temp.grace_refuse(format('select public.serving_envelope_admit(%L,1,''annual-exhausted'')',o),'exhausted annual grace refuses another cent');

 o:='b9200000-0000-4000-8000-000000000004';env:=public.plan_serving_ceiling(o);cap:=(env->>'ceiling_cents')::numeric;
 perform pg_temp.grace_ok(env->>'kind'='grace'and(env->>'period_start')::timestamptz=start_at,'annual grace carries the last paid slice without stretching the purchased year');
 state:=public.serving_envelope_state(o);
 perform pg_temp.grace_ok((state->>'spent_cents')::numeric=cap-80 and(state->>'available_cents')::numeric=80,'partial annual grace counts the true last-slice and grace ledger, excluding previous slices');
 r:=public.serving_cost_reserve(u,o,'grace-annual-partial','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),80,'verified');
 perform pg_temp.grace_ok((r->>'reserved')::boolean,'remaining annual grace money is usable');
 perform pg_temp.grace_refuse(format('select public.serving_envelope_admit(%L,1,''annual-after-hold'')',o),'new annual grace hold exhausts the same paid slice');

 foreach o in array array['b9200000-0000-4000-8000-000000000005'::uuid,'b9200000-0000-4000-8000-000000000008'::uuid,'b9200000-0000-4000-8000-000000000009'::uuid,'b9200000-0000-4000-8000-000000000010'::uuid,'b9200000-0000-4000-8000-000000000011'::uuid]loop
  env:=public.plan_serving_ceiling(o);
  perform pg_temp.grace_ok((env->>'ceiling_cents')::numeric=0,'ended grace, unverified paid expiry and freeintro with28-day grace cannot create paid money');
  perform pg_temp.grace_refuse(format('select public.serving_envelope_admit(%L,1,''no-verified-paid-money'')',o),'no new allowance without a recoverable verified paid term');
 end loop;
 env:=public.plan_serving_ceiling('b9200000-0000-4000-8000-000000000006');
 perform pg_temp.grace_ok(env->>'kind'='manual'and(env->>'ceiling_cents')::numeric=2400 and(env->>'period_start')::timestamptz=date_trunc('month',now()),'manual plan without a receipt keeps its existing calendar budget');
 env:=public.plan_serving_ceiling('b9200000-0000-4000-8000-000000000007');
 perform pg_temp.grace_ok(env->>'kind'='retail'and env->>'window'='calendar_month'and(env->>'period_start')::timestamptz=date_trunc('month',now()),'legacy no-receipt fallback remains unchanged');
end$$;

-- Recoveries are separate verified transactions. Their backdated paid period
-- includes the actual grace ledger/holds, so those costs are never forgiven.
do $$declare o uuid;sku text;r jsonb;begin
 foreach o in array array['b9200000-0000-4000-8000-000000000002'::uuid,'b9200000-0000-4000-8000-000000000004'::uuid]loop
  select apple_product_id into sku from public.orgs where id=o;
  r:=public.apply_apple_entitlement_v2(o,'b9100000-0000-4000-8000-000000000001',
   'grace-original-'||right(o::text,2),'grace-tx-'||right(o::text,2)||'-recovered',sku,'starter','Production','active',
   (now()-interval '2 days')+case when sku like '%.annual'then interval '1 year'else interval '1 month'end,
   true,'DID_RENEW',now()-interval '2 days',now(),now(),null);
  perform pg_temp.grace_ok((r->>'org_updated')::boolean and r->>'status'='active','verified recovered transaction applies through the real entitlement authority');
 end loop;
end$$;
do $$declare o uuid;env jsonb;state jsonb;begin
 o:='b9200000-0000-4000-8000-000000000002';env:=public.plan_serving_ceiling(o);state:=public.serving_envelope_state(o);
 perform pg_temp.grace_ok(env->>'kind'='retail'and env->>'window'='apple_term'and(env->>'period_start')::timestamptz=now()-interval '2 days','recovered monthly payment starts its verified new term');
 perform pg_temp.grace_ok((state->>'spent_cents')::numeric=20 and(state->>'held_cents')::numeric=30 and(state->>'available_cents')::numeric=(env->>'ceiling_cents')::numeric-50,'monthly recovery counts existing grace expense and hold against the new paid term');
 perform pg_temp.grace_ok((public.serving_envelope_admit(o,(env->>'ceiling_cents')::numeric-50,'monthly-recovered')->>'spent_cents')::numeric=50,'monthly recovered balance is usable without discarding grace cost');
 o:='b9200000-0000-4000-8000-000000000004';env:=public.plan_serving_ceiling(o);state:=public.serving_envelope_state(o);
 perform pg_temp.grace_ok(env->>'kind'='retail'and env->>'window'='apple_slice'and(env->>'period_start')::timestamptz=now()-interval '2 days','recovered annual payment starts the first new paid slice');
 perform pg_temp.grace_ok((state->>'spent_cents')::numeric=10 and(state->>'held_cents')::numeric=80 and(state->>'available_cents')::numeric=(env->>'ceiling_cents')::numeric-90,'annual recovery counts existing grace expense and hold against the new slice');
 perform pg_temp.grace_ok((public.serving_envelope_admit(o,(env->>'ceiling_cents')::numeric-90,'annual-recovered')->>'spent_cents')::numeric=90,'annual recovered balance is usable without discarding grace cost');
end$$;
reset role;
select pg_temp.grace_ok(not has_function_privilege('anon','public.plan_serving_ceiling(uuid)','EXECUTE')and not has_function_privilege('authenticated','public.plan_serving_ceiling(uuid)','EXECUTE'),'serving envelope remains service-only');
select 'serving_grace assertions: '||n from grace_assertions;
rollback;
