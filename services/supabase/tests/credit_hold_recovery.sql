-- Disposable proof that a crashed photo edit cannot reserve retail credits
-- forever, while supplier-ambiguous work is never refunded speculatively.
begin;
create temporary table credit_recovery_checks(n integer not null default 0);
insert into credit_recovery_checks default values;
grant all on credit_recovery_checks to service_role;
create function pg_temp.recovery_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'CREDIT RECOVERY FAIL: %',label;end if;
 update credit_recovery_checks set n=n+1;
end$$;

insert into auth.users(id,email,is_anonymous) values
 ('92111111-1111-4111-8111-111111111111','credit-recovery-a@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source) values
 ('92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Recovery workspace A','free',null),
 ('92bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Recovery workspace B','free',null);
insert into public.memberships(user_id,org_id,role) values
 ('92111111-1111-4111-8111-111111111111','92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner'),
 ('92111111-1111-4111-8111-111111111111','92bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','owner');
insert into public.credit_grants(org_id,environment,source,reference,product_id,
 granted_credits,remaining_credits,expires_at) values
 ('92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production','topup','recovery-pack-a',
  'com.rendprop.app.credits.100',100,100,null),
 ('92bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Production','topup','recovery-pack-b',
  'com.rendprop.app.credits.100',100,100,null);
-- Stage is deliberately disabled in the launch catalog. Enable it only inside
-- this rolled-back fixture to prove the shared hold recovery path works.
update public.credit_tariffs set active=true
 where operation='photo.stage' and version='photo-stage-v1';

set local role service_role;
do $$
declare actor uuid:='92111111-1111-4111-8111-111111111111';
 org uuid:='92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 other_actor uuid:='92111111-1111-4111-8111-111111111111';
 other_org uuid:='92bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
 key text; operation text; version text; result jsonb;
begin
 foreach key in array array[
   'recovery-no-dispatch','recovery-rejected','recovery-confirmed',
   'recovery-uncertain','recovery-pending','recovery-unproven',
   'recovery-stage-rejected','recovery-fresh'] loop
   operation:=case when key='recovery-stage-rejected' then 'photo.stage' else 'photo.declutter' end;
   version:=case when operation='photo.stage' then 'photo-stage-v1' else 'photo-declutter-v1' end;
   result:=public.serving_operation_begin(actor,org,key,'/ai-photo',repeat('a',64));
   result:=public.credit_wallet_reserve(actor,org,'Production',key,operation,version);
   perform pg_temp.recovery_ok(result->>'reserved'='true','seeded '||key);
   if key not in('recovery-no-dispatch','recovery-fresh') then
     result:=public.credit_serving_cost_reserve(actor,org,key,
       case when operation='photo.stage' then 'photo.stage:0' else 'photo.declutter:0' end,
       'gemini','gemini-3-pro-image',repeat('b',64),10,'quoted-pro4k',org,key,'Production');
     perform pg_temp.recovery_ok(result->>'reserved'='true','supplier reserved '||key);
     if key in('recovery-rejected','recovery-stage-rejected') then
       result:=public.serving_cost_finish(actor,org,key,
         case when operation='photo.stage' then 'photo.stage:0' else 'photo.declutter:0' end,
         'rejected',429);
     elsif key='recovery-confirmed' then
       result:=public.serving_cost_finish(actor,org,key,'photo.declutter:0','succeeded',null);
       insert into public.cost_ledger(org_id,feature,provider,model,total_cents,meta)
       values(org,'photo_edit','gemini','gemini-3-pro-image',10,
         jsonb_build_object('request_key',key,'stage','photo.declutter:0','actor_id',actor));
     elsif key='recovery-uncertain' then
       result:=public.serving_cost_finish(actor,org,key,'photo.declutter:0','uncertain',null);
     elsif key='recovery-unproven' then
       result:=public.serving_cost_finish(actor,org,key,'photo.declutter:0','succeeded',null);
     end if;
   end if;
 end loop;
 -- Same request key in another account must not be affected by A's stale hold.
 result:=public.serving_operation_begin(other_actor,other_org,'recovery-no-dispatch','/ai-photo',repeat('c',64));
 result:=public.credit_wallet_reserve(other_actor,other_org,'Production',
   'recovery-no-dispatch','photo.declutter','photo-declutter-v1');
 perform pg_temp.recovery_ok(result->>'reserved'='true','same key across workspaces');
end$$;
reset role;

update public.credit_holds set created_at=now()-interval '2 hours'
 where org_id='92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and request_key<>'recovery-fresh';
update public.credit_holds set created_at=now()-interval '3 hours'
 where org_id='92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and request_key='recovery-uncertain';

set local role service_role;
do $$
declare org uuid:='92aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 other_org uuid:='92bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
 result jsonb; first_result jsonb; before_balance integer;
begin
 perform pg_temp.recovery_ok((select ledger_id is not null from public.serving_cost_reservations
   where org_id=org and request_key='recovery-confirmed'),
   'confirmed photo has exact supplier cost receipt');
 before_balance:=(public.credit_wallet_state(org,'Production')->>'total_available')::integer;
 perform pg_temp.recovery_ok(before_balance=15,'all eight photo holds reserved their exact tariff');
 first_result:=public.credit_photo_hold_reconcile(1);
 perform pg_temp.recovery_ok((first_result->>'released')::integer+
   (first_result->>'settled')::integer=1 and first_result->>'needs_review'='3',
   'oldest uncertain hold does not starve a bounded safe batch');
 result:=public.credit_photo_hold_reconcile();
 perform pg_temp.recovery_ok((result->>'released')::integer+
   (first_result->>'released')::integer=3 and
   (result->>'settled')::integer+(first_result->>'settled')::integer=1
   and result->>'needs_review'='3','scheduled sweep releases only safe outcomes');
 perform pg_temp.recovery_ok((select state='released' from public.credit_holds
   where org_id=org and request_key='recovery-no-dispatch'),
   'stale no-dispatch credit is restored');
 perform pg_temp.recovery_ok((select state='released' from public.credit_holds
   where org_id=org and request_key='recovery-rejected'),
   'definitive rejection restores credit');
 perform pg_temp.recovery_ok((select state='released' from public.credit_holds
   where org_id=org and request_key='recovery-stage-rejected'),
   'staging rejection restores its separate tariff');
 perform pg_temp.recovery_ok((select state='settled' from public.credit_holds
   where org_id=org and request_key='recovery-confirmed'),
   'confirmed output settles the existing charge');
 perform pg_temp.recovery_ok((select count(*)=3 from public.credit_holds
   where org_id=org and request_key in('recovery-uncertain','recovery-pending','recovery-unproven')
     and state='reserved'),'uncertain and unproven supplier work remains held');
 perform pg_temp.recovery_ok((select state='reserved' from public.credit_holds
   where org_id=org and request_key='recovery-fresh'),
   'fresh active request is not swept');
 perform pg_temp.recovery_ok((select state='reserved' from public.credit_holds
   where org_id=other_org and request_key='recovery-no-dispatch'),
   'same actor and request key in another workspace are isolated');
 perform pg_temp.recovery_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=50,
   'only released credits return to spendable wallet');
 result:=public.credit_photo_hold_reconcile();
 perform pg_temp.recovery_ok(result->>'released'='0' and result->>'settled'='0'
   and (public.credit_wallet_state(org,'Production')->>'total_available')::integer=50,
   'repeated sweep cannot double restore or debit');
 perform pg_temp.recovery_ok(exists(select 1 from public.ops_health_findings()
   where code='credit_photo_holds_need_review'),
   'old ambiguous supplier holds page an operator');
end$$;
reset role;
select json_build_object('passed',true,'assertions',(select n from credit_recovery_checks));
rollback;
