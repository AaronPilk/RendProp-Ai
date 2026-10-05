\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'rendprop_audit' or inet_server_addr() is not null then raise exception 'Owned socket-only fixture required';end if;end$$;
create temp table chronology_checks(name text primary key,passed boolean not null);
create function pg_temp.ok(value boolean,label text) returns void language plpgsql as $$begin
  if value is distinct from true then raise exception 'CHRONOLOGY FAIL: %',label;end if;
  insert into chronology_checks values(label,true);
end$$;
create function pg_temp.apply_snapshot(o uuid,original text,tx text,product text,plan text,status text,purchase_seconds int,signed_seconds int,event_seconds int,kind text,expiry_days int default 30,renew boolean default true,renewal_seconds int default null)
returns jsonb language sql as $$select public.apply_apple_entitlement_v2(o,null,original,tx,product,plan,'Sandbox',status,now()+expiry_days*interval '1 day',renew,kind,
  now()+purchase_seconds*interval '1 second',now()+signed_seconds*interval '1 second',
  case when event_seconds is null then null else now()+event_seconds*interval '1 second' end,
  case when renewal_seconds is null then null else now()+renewal_seconds*interval '1 second' end)$$;
do $$declare o uuid;o2 uuid;o3 uuid;o4 uuid;o5 uuid;actor uuid:=gen_random_uuid();r jsonb;before_row jsonb;denied boolean;field text;orig text;
begin
  insert into orgs(name,plan,plan_source)values('Chronology fixture','free',null)returning id into o;
  insert into orgs(name,plan,plan_source)values('Renewal fixture','free',null)returning id into o2;
  insert into orgs(name,plan,plan_source)values('Legacy fixture','free',null)returning id into o3;
  insert into orgs(name,plan,plan_source)values('Crossgrade fixture','free',null)returning id into o4;
  foreach field in array array['anon','authenticated'] loop
    perform pg_temp.ok(not has_function_privilege(field,'public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)','execute'),'v2 service only for '||field);
    perform pg_temp.ok(not has_function_privilege(field,'public._apply_apple_entitlement_snapshot(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text)','execute'),'internal writer private for '||field);
  end loop;
  perform pg_temp.ok(not has_function_privilege('service_role','public._apply_apple_entitlement_snapshot(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text)','execute'),'service cannot bypass chronology');
  perform pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','active',-1000,-900,-800,'SUBSCRIBED');
  perform pg_temp.ok((select plan='pro'from orgs where id=o),'introductory subscription grants chosen plan');
  perform pg_temp.ok((org_entitlement(o)).photo_edits_per_month=200 and (org_entitlement(o)).renders_per_month=10,'Pro allowances preserved');
  perform pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','refunded',-1000,-700,-600,'REFUND',-1,false);
  perform pg_temp.ok((select plan='free'from orgs where id=o),'refund removes access');
  select to_jsonb(s) into before_row from apple_subscriptions s where original_transaction_id='chronology-refund';
  r:=pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','active',-1000,-900,null,null);
  perform pg_temp.ok(r->>'reason'='stale_notification'and(select plan='free'from orgs where id=o),'old pre-refund restore preserves refund');
  perform pg_temp.ok((select to_jsonb(s)=before_row from apple_subscriptions s where original_transaction_id='chronology-refund'),'stale restore leaves complete receipt and cancellation unchanged');
  perform pg_temp.ok((org_entitlement(o)).reels_per_month=0 and (org_entitlement(o)).photo_edits_per_month=5,'refunded workspace has Free allowance');
  r:=pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','active',-1000,-550,null,null);
  perform pg_temp.ok(r->>'reason'='stale_notification'and(select plan='free'from orgs where id=o),'re-signed same purchase cannot reverse refund');
  r:=pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','active',-1000,-900,-540,'METADATA_UPDATE');
  perform pg_temp.ok(r->>'reason'='stale_notification'and(select plan='free'from orgs where id=o),'later metadata with old active transaction cannot reverse refund');
  r:=pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','active',-1000,-500,-650,'REFUND_REVERSED');
  perform pg_temp.ok(r->>'reason'='stale_notification'and(select plan='free'from orgs where id=o),'old reversal with freshly signed transaction preserves newer refund');
  perform pg_temp.ok((select to_jsonb(s)=before_row from apple_subscriptions s where original_transaction_id='chronology-refund'),'old reversal leaves complete refund receipt unchanged');
  perform pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','active',-1000,-500,-400,'REFUND_REVERSED');
  perform pg_temp.ok((select plan='pro'from orgs where id=o),'new verified refund reversal restores access');
  r:=pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','refunded',-1000,-700,-600,'REFUND',-1,false);
  perform pg_temp.ok(r->>'reason'='stale_notification'and(select plan='pro'from orgs where id=o),'older refund cannot reverse newer reversal');
  -- An upgrade has a newer purchase, even when its expiry becomes shorter.
  perform pg_temp.apply_snapshot(o,'chronology-refund','tx-2','com.rendprop.app.team.monthly','team','active',-300,-250,-200,'DID_CHANGE_RENEWAL_PREF',30);
  perform pg_temp.ok((select plan='team'from orgs where id=o),'new purchase updates product and plan');
  r:=pg_temp.apply_snapshot(o,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','active',-1000,-100,null,null,365);
  perform pg_temp.ok(r->>'reason'='stale_notification'and(select plan='team'from orgs where id=o),'fresh signature on old purchase cannot reverse upgrade');
  denied:=false;begin
    perform apply_apple_entitlement(o,null,'chronology-refund','tx-1','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '365 days',true,null);
  exception when others then if sqlerrm like 'RP409:%'then denied:=true;else raise;end if;end;
  perform pg_temp.ok(denied and(select plan='team'from orgs where id=o),'legacy call cannot reverse dated upgrade');
  -- Refunding an earlier renewal does not revoke a later paid transaction.
  perform pg_temp.apply_snapshot(o2,'chronology-renewal','renew-old','com.rendprop.app.starter.monthly','starter','active',-3000,-2900,-2800,'SUBSCRIBED');
  perform pg_temp.apply_snapshot(o2,'chronology-renewal','renew-new','com.rendprop.app.starter.monthly','starter','active',-2000,-1900,-1800,'DID_RENEW');
  r:=pg_temp.apply_snapshot(o2,'chronology-renewal','renew-old','com.rendprop.app.starter.monthly','starter','refunded',-3000,-1000,-900,'REFUND',-1,false);
  perform pg_temp.ok(r->>'reason'='stale_notification'and(select plan='starter'from orgs where id=o2),'refund of prior renewal preserves current renewal');
  perform pg_temp.apply_snapshot(o2,'chronology-renewal','renew-new','com.rendprop.app.starter.monthly','starter','active',-2000,-1900,-1700,'DID_CHANGE_RENEWAL_STATUS',30,false,-1700);
  perform pg_temp.ok((select not auto_renew and status='active'from apple_subscriptions where original_transaction_id='chronology-renewal'),'cancellation keeps current period');
  perform pg_temp.apply_snapshot(o2,'chronology-renewal','renew-new','com.rendprop.app.starter.monthly','starter','active',-2000,-1600,null,null,30,true,-2000);
  perform pg_temp.ok((select not auto_renew from apple_subscriptions where original_transaction_id='chronology-renewal'),'older renewal info cannot undo cancellation');
  perform pg_temp.apply_snapshot(o2,'chronology-renewal','renew-new','com.rendprop.app.starter.monthly','starter','active',-2000,-1900,-1550,'DID_CHANGE_RENEWAL_STATUS',30,true,-1550);
  perform pg_temp.ok((select auto_renew and transaction_signed_at=now()-interval '1600 seconds'from apple_subscriptions where original_transaction_id='chronology-renewal'),'new outer snapshot updates renewal without lowering transaction chronology');
  r:=pg_temp.apply_snapshot(o2,'chronology-renewal','renew-new','com.rendprop.app.starter.monthly','starter','active',-2000,-1500,null,null,30,null,null);
  perform pg_temp.ok(r->>'ok'='true'and(select plan='starter'from orgs where id=o2),'fresh legitimate current restore succeeds');
  perform pg_temp.apply_snapshot(o2,'chronology-renewal','renew-new','com.rendprop.app.starter.monthly','starter','grace',-2000,-1450,-1440,'DID_FAIL_TO_RENEW/GRACE_PERIOD',1,true,-1440);
  perform pg_temp.apply_snapshot(o2,'chronology-renewal','renew-new','com.rendprop.app.starter.monthly','starter','expired',-2000,-1430,null,null,-1,null,null);
  perform pg_temp.ok((select status='grace'and expires_at>now()from apple_subscriptions where original_transaction_id='chronology-renewal'),'transaction-only restore preserves verified live grace');
  perform pg_temp.apply_snapshot(o2,'chronology-renewal','renew-new','com.rendprop.app.starter.monthly','starter','expired',-2000,-1400,-1300,'EXPIRED',-1,false,-1300);
  perform pg_temp.ok((select plan='free'from orgs where id=o2),'new current expiration removes access');
  -- A legacy refunded row has no signed evidence of a later new purchase.
  perform apply_apple_entitlement(o3,null,'legacy-refund','legacy-tx','com.rendprop.app.pro.monthly','pro','Sandbox','refunded',now()-interval '1 day',false,'REFUND');
  r:=pg_temp.apply_snapshot(o3,'legacy-refund','legacy-tx','com.rendprop.app.pro.monthly','pro','active',-2000,-1000,null,null);
  perform pg_temp.ok(r->>'reason'='chronology_unavailable'and(select plan='free'from orgs where id=o3),'untracked refunded history cannot bootstrap from pre-refund restore');
  r:=pg_temp.apply_snapshot(o3,'legacy-refund','legacy-tx','com.rendprop.app.pro.monthly','pro','active',-2000,-1000,-900,'REFUND_REVERSED');
  perform pg_temp.ok(r->>'reason'='chronology_unavailable'and(select plan='free'from orgs where id=o3),'old reversal cannot bootstrap over an untracked later refund');
  denied:=false;begin perform apply_apple_entitlement(o3,null,'legacy-refund','legacy-tx','com.rendprop.app.pro.monthly','pro','Sandbox','active',now()+interval '30 days',true,null);
  exception when others then if sqlerrm like 'RP409:%'then denied:=true;else raise;end if;end;
  perform pg_temp.ok(denied,'legacy restore cannot resurrect untracked refund');
  -- A pending newer receipt can be linked by an older signed device receipt.
  perform pg_temp.apply_snapshot(null,'chronology-pending','pending-new','com.rendprop.app.team.monthly','team','active',-800,-700,-600,'DID_RENEW');
  r:=pg_temp.apply_snapshot(o3,'chronology-pending','pending-old','com.rendprop.app.starter.monthly','starter','active',-1000,-900,null,null);
  perform pg_temp.ok((select org_id=o3 and plan='team'from apple_subscriptions where original_transaction_id='chronology-pending')and(select plan='team'from orgs where id=o3),'older device receipt links and enforces newer pending snapshot');
  denied:=false;begin perform pg_temp.apply_snapshot(o2,'chronology-pending','pending-new','com.rendprop.app.team.monthly','team','active',-800,-700,-600,'DID_RENEW');
  exception when others then if sqlerrm like 'RP409:%'then denied:=true;else raise;end if;end;
  perform pg_temp.ok(denied,'dated receipt keeps its original workspace binding');
  perform pg_temp.apply_snapshot(o4,'chronology-crossgrade','annual-tx','com.rendprop.app.starter.annual','starter','active',-1000,-900,-800,'SUBSCRIBED',365);
  perform pg_temp.apply_snapshot(o4,'chronology-crossgrade','monthly-tx','com.rendprop.app.pro.monthly','pro','active',-400,-300,-250,'DID_CHANGE_RENEWAL_PREF',30);
  perform pg_temp.ok((select plan='pro'and plan_expires_at=now()+interval '30 days'from orgs where id=o4),'annual to monthly upgrade accepts shorter expiry');
  r:=pg_temp.apply_snapshot(o4,'chronology-crossgrade','annual-tx','com.rendprop.app.starter.annual','starter','active',-1000,-200,null,null,365);
  perform pg_temp.ok(r->>'reason'='stale_notification'and(select plan='pro'from orgs where id=o4),'old annual restore cannot reverse shorter dated upgrade');
  perform pg_temp.apply_snapshot(o4,'chronology-crossgrade','monthly-tx','com.rendprop.app.pro.monthly','pro','refunded',-400,-180,-150,'REFUND',-1,false);
  perform pg_temp.apply_snapshot(o4,'chronology-crossgrade','new-purchase','com.rendprop.app.pro.monthly','pro','active',-100,-90,-80,'SUBSCRIBED',30);
  perform pg_temp.ok((select plan='pro'from orgs where id=o4),'genuinely newer purchase succeeds after refund');
  denied:=false;begin
    perform pg_temp.apply_snapshot(o4,'chronology-crossgrade','ambiguous-purchase','com.rendprop.app.pro.monthly','pro','active',-100,-70,null,null,365);
  exception when others then if sqlerrm like 'RP409:%'then denied:=true;else raise;end if;end;
  perform pg_temp.ok(denied and(select last_transaction_id='new-purchase'from apple_subscriptions where original_transaction_id='chronology-crossgrade'),'equal date different transaction cannot change receipt');
  insert into auth.users(id,email,is_anonymous)values(actor,'chronology-budget@fixture.invalid',false);
  select org_id into o5 from memberships where user_id=actor;
  perform pg_temp.apply_snapshot(o5,'chronology-budget','budget-tx','com.rendprop.app.pro.monthly','pro','active',-1000,-900,-800,'SUBSCRIBED');
  r:=app_video_cost_reserve(actor,o5,'chronology-budget-first','reel','fal','synthetic/reel',repeat('a',64),24,5,4.8,'{}');
  perform pg_temp.ok((r->>'reserved')::boolean,'paid subscription admits priced video hold');
  perform pg_temp.apply_snapshot(o5,'chronology-budget','budget-tx','com.rendprop.app.pro.monthly','pro','refunded',-1000,-700,-600,'REFUND',-1,false);
  denied:=false;begin
    perform app_video_cost_reserve(actor,o5,'chronology-budget-second','reel','fal','synthetic/reel',repeat('b',64),24,5,4.8,'{}');
  exception when others then if sqlerrm like 'RP402:%'then denied:=true;else raise;end if;end;
  perform pg_temp.ok(denied,'refund closes new paid video admission');
  perform pg_temp.ok((select count(*)=1 and sum(total_cents)=24 from app_video_cost_reservations where org_id=o5),'refund preserves existing priced hold without new admission');
end$$;
select count(*)from chronology_checks;
select name,passed from chronology_checks order by name;
rollback;
