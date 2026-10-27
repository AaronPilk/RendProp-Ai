-- A period paid at submission may lapse before KIE accepts. The exact saved
-- hold still settles, while unspent monthly credits are revoked on downgrade.
begin;
create temporary table downgrade_checks(n integer not null default 0);
insert into downgrade_checks default values;
grant all on downgrade_checks to service_role;
create function pg_temp.downgrade_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'AERIAL DOWNGRADE FAIL: %',label;end if;
 update downgrade_checks set n=n+1;
end$$;
create function pg_temp.downgrade_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
 begin execute statement;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.downgrade_ok(true,label);return;end if;
  raise;
 end;
 raise exception 'AERIAL DOWNGRADE FAIL admitted: %',label;
end$$;
create function pg_temp.claim_after_downgrade(p_job uuid,p_lease uuid)
returns void language sql security definer set search_path='' as $$
 update public.property_video_aerial_openings set generation_lease=p_lease,
  generation_claimed_at=now(),state='dispatching' where id=p_job
$$;
grant execute on function pg_temp.claim_after_downgrade(uuid,uuid) to service_role;
create temporary table paid_window(start_at timestamptz,end_at timestamptz);
insert into paid_window values(now()-interval '1 day',now()+interval '29 days');
update public.credit_monthly_catalog set active=true
 where product_id='com.rendprop.app.pro29.monthly';
update public.app_config set value=value||jsonb_build_object(
 'enabled',true,'activated_from',now()-interval '2 days')
 where key='credit_combined_budget';
update public.orgs set plan='pro',plan_source='apple',
 apple_product_id='com.rendprop.app.pro29.monthly',
 plan_expires_at=(select end_at from paid_window)
 where id='a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
insert into public.apple_subscriptions(original_transaction_id,org_id,user_id,
 product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,
 transaction_purchased_at,transaction_signed_at)
select 'aerial-paid-chain','a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'a0111111-1111-4111-8111-111111111111','com.rendprop.app.pro29.monthly',
 'pro','Production','active',end_at,true,'aerial-paid-tx',
 start_at,start_at+interval '1 minute' from paid_window;
insert into public.credit_monthly_events(environment,transaction_id,
 original_transaction_id,org_id,product_id,state,event_signed_at,
 price_milliunits,period_start,period_end)
select 'Production','aerial-paid-tx','aerial-paid-chain',
 'a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','com.rendprop.app.pro29.monthly',
 'paid',start_at+interval '1 minute',29990,start_at,end_at from paid_window;
insert into public.credit_grants(org_id,environment,source,reference,
 product_id,granted_credits,remaining_credits,starts_at,expires_at)
select 'a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production','monthly',
 'apple:aerial-paid-tx','com.rendprop.app.pro29.monthly',80,80,start_at,end_at
 from paid_window;
create temporary table downgrade_seed(manifest jsonb,quote jsonb,consent jsonb);
insert into downgrade_seed
with source as(select manifest,quote,consent from public.property_video_aerial_openings
 where operation_id='a0444444-4444-4444-8444-444444444444'),
 changed as(select jsonb_set(manifest,'{operation_id}',
 to_jsonb('a0888888-8888-4888-8888-888888888888'::uuid)) m,quote,consent from source)
select m,jsonb_set(quote,'{manifest_sha256}',
 to_jsonb(encode(sha256(convert_to(m::text,'UTF8')),'hex'))),consent from changed;
grant select on downgrade_seed to service_role;
create temporary table downgrade_job(id uuid,lease uuid);
grant all on downgrade_job to service_role;
set local role service_role;
do $$
declare m jsonb;q jsonb;c jsonb;j public.property_video_aerial_openings;
 org uuid:='a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
begin
 perform pg_temp.downgrade_ok(public.credit_primary_subscription(org,'Production'),
  'exact signed paid period activates credit-primary aerial funding');
 select manifest,quote,consent into m,q,c from downgrade_seed;
 perform pg_temp.downgrade_refuses(format(
  'select public.property_video_aerial_admit(%L,%L::jsonb,%L::jsonb,%L::jsonb)',
  'a0111111-1111-4111-8111-111111111111',m,q,c),
  'RP402:','credit-primary subscriber cannot bypass quote through legacy aerial allowance');
 j:=public.property_video_aerial_admit_credit(
  'a0111111-1111-4111-8111-111111111111',m,q,c,
  'Production','aerial-opening-v1');
 insert into downgrade_job values(j.id,'a0999999-9999-4999-8999-999999999999');
 perform pg_temp.downgrade_ok((select remaining_credits=60 from public.credit_grants
   where reference='apple:aerial-paid-tx') and
   (select state='reserved' from public.credit_holds
     where request_key='aerial-opening:a0888888-8888-4888-8888-888888888888'),
  'paid aerial admission allocated exactly 20 current-month credits');
end$$;
reset role;
-- Subscription loss revokes only unused monthly credits. The in-flight
-- hold/allocations remain available to reconcile the already-sent work.
update public.apple_subscriptions set status='expired',expires_at=now()-interval '1 second'
 where original_transaction_id='aerial-paid-chain';
update public.orgs set plan='free',plan_source=null,plan_expires_at=null,
 apple_product_id=null where id='a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
update public.credit_grants set revoked_at=now()
 where reference='apple:aerial-paid-tx';
set local role service_role;
do $$
declare j downgrade_job%rowtype;r jsonb;
 org uuid:='a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
begin
 select * into j from downgrade_job;
 perform pg_temp.downgrade_ok(not public.credit_primary_subscription(org,'Production') and
   (public.credit_wallet_state(org,'Production')->>'monthly_available')::integer=0,
  'downgrade removes new monthly-credit usage');
 perform pg_temp.claim_after_downgrade(j.id,j.lease);
 r:=jsonb_build_object('provider','kie','model','kling-3.0/video',
   'id','aerial-downgrade-accepted','submitted_at',now(),
   'poll_url','https://api.kie.ai/api/v1/jobs/recordInfo?taskId=aerial-downgrade-accepted');
 perform public.property_video_aerial_receipt(j.id,j.lease,r);
 perform pg_temp.downgrade_ok(
   (select state='settled' from public.credit_holds
    where request_key='aerial-opening:a0888888-8888-4888-8888-888888888888')
   and (public.credit_wallet_state(org,'Production')->>'total_available')::integer=60,
  'accepted supplier receipt settles only the admitted hold after downgrade');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',(select n from downgrade_checks));
rollback;
