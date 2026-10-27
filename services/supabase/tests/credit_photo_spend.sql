-- Disposable proof: a Free member can spend purchased credits on one bounded
-- Declutter, while supplier journal, idempotency and no-dispatch release hold.
begin;
create temporary table credit_photo_checks(n integer not null default 0);
insert into credit_photo_checks default values;
grant all on credit_photo_checks to service_role;
create function pg_temp.photo_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'PHOTO CREDIT FAIL: %',label;end if;
 update credit_photo_checks set n=n+1;
end$$;
create function pg_temp.photo_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
 begin execute statement;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.photo_ok(true,label);return;end if;
  raise;
 end;
 raise exception 'PHOTO CREDIT FAIL: admitted %',label;
end$$;
create function pg_temp.seed_saved_declutter_check(p_actor uuid,p_org uuid,p_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare evidence uuid; check_id uuid;
begin
 insert into public.photo_edit_evidence(org_id,actor_id,library_org_id,
   request_key,request_sha256,policy,edit,input)
 values(p_org,p_actor,p_org,p_key,repeat('a',64),'photo-fixed-features-v1',
   'declutter','{}'::jsonb) returning id into evidence;
 insert into public.photo_quality_checks(evidence_id,policy)
 values(evidence,'photo-fixed-features-v1') returning id into check_id;
 return check_id;
end$$;
create function pg_temp.backdate_assess(p_org uuid) returns void
language sql security definer set search_path='' as $$
  update public.photo_declutter_assessment_admissions
    set admitted_at=now()-interval '1 day' where billing_org_id=p_org
$$;

insert into auth.users(id,email,is_anonymous)values
 ('31111111-1111-4111-8111-111111111111','credit-photo@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source)values
 ('3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Purchased credit Free test','free',null);
insert into public.memberships(user_id,org_id,role)values
 ('31111111-1111-4111-8111-111111111111','3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');
insert into public.credit_grants(org_id,environment,source,reference,product_id,
 granted_credits,remaining_credits,expires_at)values
 ('3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production','topup','apple-photo-fixture',
 'com.rendprop.app.credits.100',100,100,null);

insert into auth.users(id,email,is_anonymous)values
 ('41111111-1111-4111-8111-111111111111','credit-trial@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source)values
 ('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Funded trial assessment test','trial',null),
 ('5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Max assessment test','starter','apple');
insert into public.memberships(user_id,org_id,role)values
 ('41111111-1111-4111-8111-111111111111','4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner'),
 ('31111111-1111-4111-8111-111111111111','5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');
with funding as (
 insert into public.serving_funding(org_id,source,collection_ref,actor_id,
   net_receipts_cents,sponsored_cents,starts_at,ends_at,retention_ends_at,
   service_months,recurring_reserve_cents,reserve_components,evidence_sha256,
   apple_original_transaction_id)
 values('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','trial','fixture-trial-assess-001',
   '41111111-1111-4111-8111-111111111111',0,100,now()-interval '1 day',
   now()+interval '6 days',now()+interval '6 days',1,0,'{}',repeat('e',64),
   'fixture-trial-chain') returning id
)
insert into public.subscription_trial_grants(actor_id,identity_sha256,org_id,
 original_transaction_id,funding_id,starts_at,ends_at,walkthrough_cap,photo_cap,
 listing_cap,upload_budget_bytes,max_video_seconds,evidence_sha256)
select '41111111-1111-4111-8111-111111111111',repeat('d',64),
 '4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','fixture-trial-chain',id,
 now()-interval '1 day',now()+interval '6 days',1,5,1,1073741824,90,repeat('e',64)
from funding;
insert into public.apple_subscriptions(original_transaction_id,org_id,user_id,
 product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,
 transaction_purchased_at,transaction_signed_at)values
 ('fixture-max-chain','5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '31111111-1111-4111-8111-111111111111','com.rendprop.app.starter.monthly',
  'starter','Production','active',now()+interval '29 days',true,'fixture-max-tx',
  now()-interval '1 day',now()-interval '1 day'+interval '1 minute');

insert into auth.users(id,email,is_anonymous) values
 ('71111111-1111-4111-8111-111111111111','assessment-team-owner@example.invalid',false),
 ('81111111-1111-4111-8111-111111111111','assessment-team-agent@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source) values
 ('7aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Assessment Team','team','manual'),
 ('8aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Agent private library','free',null);
insert into public.memberships(user_id,org_id,role) values
 ('71111111-1111-4111-8111-111111111111',
  '7aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner'),
 ('81111111-1111-4111-8111-111111111111',
  '8aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');

set local role service_role;
do $$
declare actor uuid:='31111111-1111-4111-8111-111111111111';
 org uuid:='3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 key text:='declutter-credit-0001'; second_key text:='declutter-credit-0002';
 result jsonb; supplier uuid; qc_id uuid; qc_key text; i integer;
 trial_actor uuid:='41111111-1111-4111-8111-111111111111';
 trial_org uuid:='4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 max_org uuid:='5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 team_owner uuid:='71111111-1111-4111-8111-111111111111';
 team_agent uuid:='81111111-1111-4111-8111-111111111111';
 team_org uuid:='7aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 agent_library uuid:='8aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
begin
 result:=public.create_org_invite(team_owner,team_org,null,'agent',repeat('f',64));
 result:=public.accept_org_invite(team_agent,repeat('f',64));
 perform pg_temp.photo_ok(public.library_actor_billing_org(team_agent,agent_library)=team_org and
   public.library_financial_actor(team_agent,agent_library),
   'Team agent may edit private library against shared owner-funded billing org');
 result:=public.photo_declutter_assessment_admit(team_agent,agent_library,
   'assessment-team-agent-0001',repeat('c',64));
 perform pg_temp.photo_ok(result->>'tier'='team_legacy' and
   (select billing_org_id=team_org from public.photo_declutter_assessment_admissions
     where request_key='assessment-team-agent-0001'),
   'Team agent consumes the shared assessment quota through private library');
 perform pg_temp.photo_refuses(format(
   'select public.credit_purchase_intent_create(%L,%L,%L)',team_agent,agent_library,
   'com.rendprop.app.credits.100'),
   'RP403:','Team agent cannot buy an invisible credit pack into a private library');
 perform pg_temp.photo_ok(public.credit_primary_subscription(org,'Production')=false,
   'Free top-up is opt-in, not an invented paid subscription');
 result:=public.serving_operation_begin(actor,org,key,'/ai-photo',repeat('a',64));
 perform pg_temp.photo_ok(result->>'begun'='true','operation journal precedes credits');
 result:=public.credit_wallet_reserve(actor,org,'Production',key,'photo.declutter','photo-declutter-v1');
 perform pg_temp.photo_ok(result->>'reserved'='true'and result->>'credits'='10'and
   (public.credit_wallet_state(org,'Production')->>'total_available')::integer=90,
   'Free plan can reserve a bounded purchased top-up');
 result:=public.credit_serving_cost_reserve(actor,org,key,'photo.declutter:0',
   'gemini','gemini-3-pro-image',repeat('b',64),33.8304,'quoted-pro4k',org,key,'Production');
 supplier:=(result->>'id')::uuid;
 perform pg_temp.photo_ok(result->>'budget'='credits'and
   (select budget_source='credits'and credit_hold_id=(select id from public.credit_holds
    where org_id=org and request_key=key)from public.serving_cost_reservations where id=supplier),
   'supplier liability binds exact customer hold');
 perform pg_temp.photo_refuses(format(
   'select public.credit_serving_cost_reserve(%L,%L,%L,%L,%L,%L,%L,33.8304,%L,%L,%L,%L)',
   actor,org,key,'photo.declutter:0','gemini','gemini-3-pro-image',repeat('b',64),
   'quoted-pro4k',org,key,'Production'),
   'RP409:','same attempt cannot dispatch twice');
 perform pg_temp.photo_refuses(format(
   'select public.credit_serving_cost_reserve(%L,%L,%L,%L,%L,%L,%L,70,%L,%L,%L,%L)',
   actor,org,key,'photo.declutter:1','gemini','gemini-3-pro-image',repeat('c',64),
   'quoted-pro4k',org,key,'Production'),
   'RP402:','all provider attempts stay within five cents per credit');
 perform pg_temp.photo_refuses(format(
   'select public.credit_wallet_finish(%L,%L,%L,%L,%L)',actor,org,
   'Production',key,'released'),
   'RP409:','provider uncertainty cannot falsely release customer hold');
 result:=public.serving_cost_finish(actor,org,key,'photo.declutter:0','succeeded',null);
 perform pg_temp.photo_ok(result->>'finished'='true','provider success is journaled');
 insert into public.cost_ledger(org_id,feature,provider,model,total_cents,meta)
 values(org,'photo_edit','gemini','gemini-3-pro-image',33.8304,
   jsonb_build_object('request_key',key,'stage','photo.declutter:0','actor_id',actor));
 perform pg_temp.photo_ok((select ledger_id is not null from public.serving_cost_reservations
   where id=supplier),'exact supplier liability gets cost receipt');
 result:=public.credit_wallet_finish(actor,org,'Production',key,'settled');
 perform pg_temp.photo_ok(result->>'state'='settled'and
   (public.credit_wallet_state(org,'Production')->>'total_available')::integer=90,
   'confirmed output settles exactly once');
 result:=public.credit_wallet_finish(actor,org,'Production',key,'settled');
 perform pg_temp.photo_ok(result->>'replay'='true','settlement replay cannot double charge');
 qc_id:=pg_temp.seed_saved_declutter_check(actor,org,key);
 qc_key:='photo-qc:'||qc_id::text;
 result:=public.serving_operation_begin(actor,org,qc_key,'/ai-photo/judge',repeat('f',64));
 result:=public.credit_serving_cost_reserve(actor,org,qc_key,'photo.qc:0',
   'anthropic','claude-sonnet-5',repeat('c',64),10.8624,'quoted-sonnet-qc',org,key,'Production');
 perform pg_temp.photo_ok(result->>'budget'='credits' and
   (select credit_hold_id=(select id from public.credit_holds where org_id=org
     and request_key=key) from public.serving_cost_reservations
      where id=(result->>'id')::uuid),
   'saved judge shares settled original customer quote without another debit');
 result:=public.serving_cost_finish(actor,org,qc_key,'photo.qc:0','succeeded',null);
 perform pg_temp.photo_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=90,
   'judge supplier cost does not double-charge customer credits');

 result:=public.serving_operation_begin(actor,org,second_key,'/ai-photo',repeat('d',64));
 result:=public.credit_wallet_reserve(actor,org,'Production',second_key,
   'photo.declutter','photo-declutter-v1');
 result:=public.credit_wallet_finish(actor,org,'Production',second_key,'released');
 perform pg_temp.photo_ok(result->>'state'='released'and
   (public.credit_wallet_state(org,'Production')->>'total_available')::integer=90,
   'definite no-dispatch returns all credits');
 perform pg_temp.photo_refuses(format(
   'select public.credit_serving_cost_reserve(%L,%L,%L,%L,%L,%L,%L,5,%L,%L,%L,%L)',
   actor,org,second_key,'photo.declutter:0','gemini','gemini-3-pro-image',repeat('e',64),
   'quoted-pro4k',org,second_key,'Production'),
   'RP402:','released hold cannot fund later provider work');
 perform pg_temp.photo_refuses(format(
   'select public.credit_serving_cost_reserve(%L,%L,%L,%L,%L,%L,%L,5,%L,%L,%L,%L)',
   actor,org,key,'photo.declutter:1','gemini','gemini-3-pro-image',repeat('f',64),
   'quoted-pro4k','3bbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',key,'Production'),
   'RP403:','credit admission cannot bill a different workspace');

 for i in 1..30 loop
   result:=public.photo_declutter_assessment_admit(actor,org,
     'assess-free-'||lpad(i::text,4,'0'),repeat('a',64));
   if i=30 then perform pg_temp.photo_ok(result->>'tier'='topup_only' and
     result->>'daily_remaining'='0' and result->>'monthly_remaining'='20',
     'Free top-up assessments cap at 30 per UTC day and 50 per month');end if;
 end loop;
 result:=public.photo_declutter_assessment_admit(actor,org,'assess-free-0030',repeat('a',64));
 perform pg_temp.photo_ok(result->>'replay'='true' and
   (select count(*)=30 from public.photo_declutter_assessment_admissions where billing_org_id=org),
   'exact assessment retry does not consume another slot');
 perform pg_temp.photo_refuses(format(
   'select public.photo_declutter_assessment_admit(%L,%L,%L,%L)',
   actor,org,'assess-free-0030',repeat('b',64)),
   'RP409:','same assessment key cannot refer to another prepared image');
 perform pg_temp.photo_refuses(format(
   'select public.photo_declutter_assessment_admit(%L,%L,%L,%L)',
   actor,org,'assess-free-0031',repeat('a',64)),
   'RP429:','assessment daily budget refuses before another Gemini call');
 -- On the UTC first day of a month there is no earlier day in this month to
 -- create a realistic monthly-exhaustion fixture.
 if extract(day from now() at time zone 'UTC')>1 then
   perform pg_temp.backdate_assess(org);
   for i in 31..50 loop
     result:=public.photo_declutter_assessment_admit(actor,org,
       'assess-free-'||lpad(i::text,4,'0'),repeat('a',64));
   end loop;
   perform pg_temp.photo_ok(result->>'monthly_remaining'='0',
     'assessment monthly cap includes prior-day skipped photos');
   perform pg_temp.photo_refuses(format(
     'select public.photo_declutter_assessment_admit(%L,%L,%L,%L)',
     actor,org,'assess-free-0051',repeat('a',64)),
     'RP429:','assessment monthly budget refuses despite daily headroom');
 end if;

 for i in 1..5 loop
   result:=public.photo_declutter_assessment_admit(trial_actor,trial_org,
     'assess-trial-'||lpad(i::text,4,'0'),repeat('b',64));
 end loop;
 perform pg_temp.photo_ok(result->>'tier'='trial' and
   result->>'daily_remaining'='0' and result->>'monthly_remaining'='5',
   'funded trial limits image assessments to five per day and ten per month');
 perform pg_temp.photo_refuses(format(
   'select public.photo_declutter_assessment_admit(%L,%L,%L,%L)',
   trial_actor,trial_org,'assess-trial-0006',repeat('b',64)),
   'RP429:','trial assessment sixth photo is stopped before supplier spend');

 for i in 1..60 loop
   result:=public.photo_declutter_assessment_admit(actor,max_org,
     'assess-max-'||lpad(i::text,4,'0'),repeat('c',64));
 end loop;
 perform pg_temp.photo_ok(result->>'tier'='max' and
   result->>'daily_remaining'='0' and result->>'monthly_remaining'='40',
   'Max paid receipt permits a 38-photo listing but caps daily reviews at sixty');
 perform pg_temp.photo_refuses(format(
   'select public.photo_declutter_assessment_admit(%L,%L,%L,%L)',
   actor,max_org,'assess-max-0061',repeat('c',64)),
   'RP429:','paid Max assessment ceiling is server-enforced');
end$$;
reset role;
select json_build_object('passed',true,'assertions',(select n from credit_photo_checks));
rollback;
