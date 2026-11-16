-- Signed TestFlight free-intro path, entirely inside disposable PostgreSQL.
begin;
create temporary table sandbox_intro_checks(n integer not null default 0);
insert into sandbox_intro_checks default values;
grant all on sandbox_intro_checks to service_role;
create function pg_temp.sandbox_ok(v boolean,label text) returns void language plpgsql as $$
begin if v is distinct from true then raise exception 'SANDBOX INTRO FAIL: %',label;end if;
 update sandbox_intro_checks set n=n+1;end$$;
create function pg_temp.sandbox_refuses(q text,needle text,label text)
returns void language plpgsql as $$
begin begin execute q;exception when others then
 if position(needle in sqlerrm)>0 then perform pg_temp.sandbox_ok(true,label);return;end if;
 raise;end;raise exception 'SANDBOX INTRO FAIL admitted: %',label;end$$;

select pg_temp.sandbox_ok(not has_function_privilege('authenticated',
 'public.grant_sandbox_intro_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz,timestamptz,bigint,text,text,integer,text,uuid,text)','execute'),
 'tenant SQL cannot invoke test-trial grant');
update public.app_config set value='{"mode":"ceiling","free_published_listings":1}'::jsonb
 where key='serving_mode';
update public.app_config set value=jsonb_build_object('cap_cents',29000,
 'starts_at',now()-interval '1 day','ends_at',now()+interval '20 days')
 where key='trial_sponsor_pool';
insert into auth.users(id,email,is_anonymous) values
 ('71111111-1111-4111-8111-111111111111','sandbox-intro@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source) values
 ('71aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Sandbox intro fixture','free',null),
 ('72aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Closed sponsor fixture','free',null);
insert into public.memberships(user_id,org_id,role) values
 ('71111111-1111-4111-8111-111111111111',
  '71aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner'),
 ('71111111-1111-4111-8111-111111111111',
  '72aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');
set local role service_role;
do $$declare actor uuid:='71111111-1111-4111-8111-111111111111';
 org uuid:='71aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';result jsonb;ends timestamptz;begin
 perform pg_temp.sandbox_refuses(format($q$select public.grant_sandbox_intro_trial(%L,%L,'bad-paid','bad-paid-tx','com.rendprop.app.pro29.monthly','active',now()+interval '6 days',now(),now()-interval '1 minute',29990,'USD','USA',1,'FREE_TRIAL',%L,'Auto-Renewable Subscription')$q$,org,actor,actor),
   'RP400:','paid Sandbox receipt is not a free intro');
 perform pg_temp.sandbox_refuses(format($q$select public.grant_sandbox_intro_trial(%L,%L,'bad-actor','bad-actor-tx','com.rendprop.app.pro29.monthly','active',now()+interval '6 days',now(),now()-interval '1 minute',0,'USD','USA',1,'FREE_TRIAL',%L,'Auto-Renewable Subscription')$q$,org,actor,'71111111-1111-4111-8111-111111111112'),
   'RP400:','signed account token must bind to actor');
 perform pg_temp.sandbox_refuses(format($q$select public.grant_sandbox_intro_trial(%L,%L,'bad-term','bad-term-tx','com.rendprop.app.pro29.monthly','active',now()+interval '8 days',now(),now()-interval '1 minute',0,'USD','USA',1,'FREE_TRIAL',%L,'Auto-Renewable Subscription')$q$,org,actor,actor),
   'RP400:','signed introductory term cannot exceed seven days');
 result:=public.grant_sandbox_intro_trial(org,actor,'valid-intro','valid-intro-tx',
  'com.rendprop.app.pro29.monthly','active',now()+interval '6 days 23 hours',
  now(),now()-interval '1 minute',0,'USD','USA',1,'FREE_TRIAL',actor,
  'Auto-Renewable Subscription');
 perform pg_temp.sandbox_ok((result->>'granted')::boolean and result->>'plan'='trial',
  'one verified zero-price Apple intro opens bounded TestFlight trial');
 ends:=(result->>'expires_at')::timestamptz;
 perform pg_temp.sandbox_ok((select plan='trial' and trial_ends_at=ends
  from public.orgs where id=org), 'workspace carries exactly one finite trial');
 result:=public.grant_sandbox_intro_trial(org,actor,'valid-intro','valid-intro-tx',
  'com.rendprop.app.pro29.monthly','active',now()+interval '6 days 23 hours',
  now(),now()-interval '1 minute',0,'USD','USA',1,'FREE_TRIAL',actor,
  'Auto-Renewable Subscription');
 perform pg_temp.sandbox_ok(not(result->>'granted')::boolean and
  (result->>'replay')::boolean and (result->>'expires_at')::timestamptz=ends,
  'replay cannot restart or add a second trial');
end$$;
reset role;
update public.app_config set value=jsonb_set(value,'{ends_at}',
 to_jsonb(now()+interval '1 day')) where key='trial_sponsor_pool';
set local role service_role;
select pg_temp.sandbox_refuses(format($q$select public.grant_sandbox_intro_trial(%L,%L,'closed-intro','closed-intro-tx','com.rendprop.app.pro29.monthly','active',now()+interval '6 days',now(),now()-interval '1 minute',0,'USD','USA',1,'FREE_TRIAL',%L,'Auto-Renewable Subscription')$q$,
 '72aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 '71111111-1111-4111-8111-111111111111',
 '71111111-1111-4111-8111-111111111111'),
 'RP402:','expired-week sponsor allocation refuses and rolls back new grant');
select pg_temp.sandbox_ok((select plan='free' and trial_ends_at is null
 from public.orgs where id='72aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') and
 not exists(select 1 from public.apple_sandbox_receipts
   where original_transaction_id='closed-intro'),
 'failed sponsor check leaves no trial or receipt mutation');
reset role;
select json_build_object('passed',true,'assertions',(select n from sandbox_intro_checks));
rollback;
