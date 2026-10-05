\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'rendprop_audit' or inet_server_addr() is not null then raise exception 'Run only in the owned socket-only rendprop_audit fixture';end if;end$$;
create temp table subscription_checks(name text primary key,passed boolean not null);
create function pg_temp.subscription_ok(value boolean,label text) returns void language plpgsql as $$begin if value is distinct from true then raise exception 'SUBSCRIPTION FAIL: %',label;end if;insert into subscription_checks values(label,true);end$$;
grant all on subscription_checks to service_role;
create temp table subscription_fixture(named_user uuid,guest_user uuid,named_org uuid,guest_org uuid,other_org uuid);
do $$declare n uuid:=gen_random_uuid();g uuid:=gen_random_uuid();o uuid;go uuid;other uuid;begin
 insert into auth.users(id,email,raw_user_meta_data,is_anonymous)values(n,'subscription@fixture.invalid','{"name":"Subscribed Later","plan":"pro","trial":true}',false),(g,null,'{"full_name":"Guest Fixture"}',true);
 select org_id into strict o from memberships where user_id=n;select org_id into strict go from memberships where user_id=g;
 perform pg_temp.subscription_ok((select plan='free' and trial_ends_at is null and plan_source is null from orgs where id=o),'named signup starts free without automatic trial');
 perform pg_temp.subscription_ok((select plan='free' and trial_ends_at is null and plan_source is null from orgs where id=go),'anonymous signup starts free without automatic trial');
 perform pg_temp.subscription_ok((select name='Subscribed Later'from profiles where id=n)and(select name='Guest Fixture'from profiles where id=g),'signup keeps profile name and full-name metadata compatibility');
 perform pg_temp.subscription_ok((select not is_admin from profiles where id=n),'user metadata cannot forge administrative access');
 perform pg_temp.subscription_ok((select count(*)=2 from memberships where user_id in(n,g) and role='owner'),'new users retain one owned workspace each');
 perform pg_temp.subscription_ok((org_entitlement(o)).plan='free' and (org_entitlement(go)).plan='free','entitlement resolver grants only free access before confirmation');
 insert into orgs(name) values('Unsubscribed default fixture')returning id into other;
 perform pg_temp.subscription_ok((select plan='free'and plan_source is null and trial_ends_at is null from orgs where id=other),'raw workspace defaults do not claim a trial');
 insert into subscription_fixture values(n,g,o,go,other);
end$$;
grant select on subscription_fixture to service_role;
select pg_temp.subscription_ok(not has_function_privilege(role,'public.apply_apple_entitlement(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text)','execute'),'client cannot grant subscription as '||role)from unnest(array['anon','authenticated'])role;
select pg_temp.subscription_ok(not has_column_privilege('authenticated','public.orgs','plan','update') and not has_column_privilege('authenticated','public.orgs','trial_ends_at','update'),'client cannot start trial by editing org');
set local role service_role;
do $$declare f record;r jsonb;expiry timestamptz:=now()+interval '7 days'; original text:='fixture-intro-'||gen_random_uuid(); second text:='fixture-expiry-'||gen_random_uuid();operation uuid:=gen_random_uuid();denied boolean:=false;base timestamptz:=now()-interval '1 hour';begin
 select * into f from subscription_fixture;
 r:=apply_apple_entitlement_v2(f.named_org,f.named_user,original,'fixture-intro','com.rendprop.app.pro.monthly','pro','Sandbox','active',expiry,true,'SUBSCRIBED',base+interval '0 seconds',base+interval '1 seconds',null,base+interval '1 seconds');
 perform pg_temp.subscription_ok(r->>'ok'='true'and r->>'org_updated'='true','verified-transaction adapter can activate introductory entitlement');
 perform pg_temp.subscription_ok((select plan='pro'and plan_source='apple'and plan_expires_at=expiry and trial_ends_at is null from orgs where id=f.named_org),'confirmed introductory offer grants selected plan with Apple expiry');
 perform pg_temp.subscription_ok((org_entitlement(f.named_org)).photo_edits_per_month=200 and (org_entitlement(f.named_org)).renders_per_month=10,'confirmed introductory offer uses selected Pro allowances');
 r:=apply_apple_entitlement_v2(f.named_org,f.named_user,original,'fixture-intro','com.rendprop.app.pro.monthly','pro','Sandbox','active',expiry,false,'DID_CHANGE_RENEWAL_STATUS',base+interval '0 seconds',base+interval '2 seconds',null,base+interval '2 seconds');
 perform pg_temp.subscription_ok((select plan='pro'and plan_expires_at=expiry from orgs where id=f.named_org),'cancelling renewal retains access through existing period');
 perform pg_temp.subscription_ok((select auto_renew=false from apple_subscriptions where original_transaction_id=original),'cancellation is recorded without starting another trial');
 r:=apply_apple_entitlement_v2(f.named_org,f.named_user,original,'fixture-intro','com.rendprop.app.pro.monthly','pro','Sandbox','refunded',expiry,false,'REFUND',base+interval '0 seconds',base+interval '3 seconds',null,base+interval '3 seconds');
 perform pg_temp.subscription_ok((select plan='free'from orgs where id=f.named_org),'refund returns workspace to free');
 -- Apple EXPIRED is authoritative; this calls the same service-only writer
 -- used after JWS verification, never a fake purchase or public API bypass.
 r:=apply_apple_entitlement_v2(f.guest_org,f.guest_user,second,'fixture-expiry','com.rendprop.app.starter.monthly','starter','Sandbox','active',expiry,true,'SUBSCRIBED',base+interval '0 seconds',base+interval '4 seconds',null,base+interval '4 seconds');
 r:=apply_apple_entitlement_v2(f.guest_org,f.guest_user,second,'fixture-expiry','com.rendprop.app.starter.monthly','starter','Sandbox','expired',expiry,false,'EXPIRED',base+interval '0 seconds',base+interval '5 seconds',null,base+interval '5 seconds');
 perform pg_temp.subscription_ok((select plan='free'and trial_ends_at is null from orgs where id=f.guest_org),'expiration returns to free without automatic signup-trial fallback');
 perform pg_temp.subscription_ok((select count(*)=2 from apple_subscriptions where org_id in(f.named_org,f.guest_org)),'only confirmed synthetic transactions create subscription rows');
 -- A guest buys, then connects an existing named account. The signed token
 -- remains the guest ID forever; the immutable adoption receipt is the alias.
 r:=apply_apple_entitlement_v2(f.guest_org,f.guest_user,second,'fixture-guest','com.rendprop.app.starter.monthly','starter','Sandbox','active',expiry+interval '1 day',true,'SUBSCRIBED',base+interval '6 seconds',base+interval '7 seconds',null,base+interval '7 seconds');
 update apple_subscriptions set app_account_token=f.guest_user where original_transaction_id=second;
 perform pg_temp.subscription_ok((select plan='starter'and plan_source='apple'from orgs where id=f.guest_org),'guest can hold confirmed subscription before identity connection');
 r:=adopt_anonymous_org(f.named_user,f.guest_user,f.guest_org,operation);
 perform pg_temp.subscription_ok(r->>'adopted'='true'and (r->>'org_id')::uuid=f.guest_org,'subscribed guest workspace transfers with exact adoption proof');
 perform pg_temp.subscription_ok(adoption_receipt(f.named_user,f.guest_user,operation)=r,'live receipt verifies exact subscription token alias');
 perform pg_temp.subscription_ok((select active_org_id=f.guest_org from user_workspace_state where user_id=f.named_user) and (select role='owner'from memberships where user_id=f.named_user and org_id=f.guest_org),'identity connection selects subscribed workspace and transfers ownership');
 perform pg_temp.subscription_ok((select plan='free'from orgs where id=f.named_org),'destination personal workspace receives no duplicate entitlement');
 r:=apply_apple_entitlement_v2(f.guest_org,f.named_user,second,'fixture-guest','com.rendprop.app.starter.monthly','starter','Sandbox','active',expiry+interval '1 day',true,null,base+interval '6 seconds',base+interval '8 seconds',null,base+interval '8 seconds');
 perform pg_temp.subscription_ok(r->>'ok'='true' and (select org_id=f.guest_org and user_id=f.named_user and app_account_token=f.guest_user from apple_subscriptions where original_transaction_id=second),'connected restore preserves transaction workspace and original signed guest token');
 begin
  perform apply_apple_entitlement_v2(f.named_org,f.named_user,second,'fixture-guest','com.rendprop.app.starter.monthly','starter','Sandbox','active',expiry+interval '1 day',true,null,base+interval '6 seconds',base+interval '8 seconds',null,base+interval '8 seconds');
 exception when others then if sqlerrm like 'RP409:%'then denied:=true;else raise;end if;end;
 perform pg_temp.subscription_ok(denied,'connected receipt cannot move subscription into another personal workspace');
 delete from memberships where user_id=f.named_user and org_id=f.guest_org;
 denied:=false;begin perform adoption_receipt(f.named_user,f.guest_user,operation);
 exception when others then if sqlerrm like 'RP409:%'then denied:=true;else raise;end if;end;
 perform pg_temp.subscription_ok(denied,'revoking adopted membership invalidates the purchase alias');
end$$;
reset role;
select count(*) as passed from subscription_checks;
select name,passed from subscription_checks order by name;
rollback;
