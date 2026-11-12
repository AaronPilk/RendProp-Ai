\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'credit_wallet_test' or inet_server_addr() is not null
  then raise exception 'Owned socket-only fixture required';end if;end$$;

insert into auth.users(id,email,is_anonymous) values
  ('51111111-1111-4111-8111-111111111111','race-owner@example.invalid',false),
  ('51111111-1111-4111-8111-111111111112','race-agent-a@example.invalid',false),
  ('51111111-1111-4111-8111-111111111113','race-agent-b@example.invalid',false),
  ('51111111-1111-4111-8111-111111111114','race-agent-c@example.invalid',false),
  ('51111111-1111-4111-8111-111111111115','race-new@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)
  values ('5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Race Team','team','apple',
    'com.rendprop.app.team5.monthly',now()+interval '25 days');
insert into public.memberships(user_id,org_id,role) values
  ('51111111-1111-4111-8111-111111111111','5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner'),
  ('51111111-1111-4111-8111-111111111112','5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','agent'),
  ('51111111-1111-4111-8111-111111111113','5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','agent'),
  ('51111111-1111-4111-8111-111111111114','5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','agent');
insert into public.org_invites(org_id,role,token_hash,invited_by,accepted_at,accepted_by)
  select '5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','agent',repeat(n::text,64),
    '51111111-1111-4111-8111-111111111111',now()-interval '4 days'+n*interval '1 hour',
    ('51111111-1111-4111-8111-11111111111'||(n+1))::uuid
    from generate_series(1,3)n;
update public.team_paid_seat_variants set active=true where seats=5;
update public.credit_monthly_catalog set active=true
  where product_id='com.rendprop.app.team5.monthly';
insert into public.apple_subscriptions(original_transaction_id,org_id,user_id,
  product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,
  transaction_purchased_at,transaction_signed_at) values
  ('race-team-chain','5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '51111111-1111-4111-8111-111111111111',
   'com.rendprop.app.team5.monthly','team','Production','active',
   now()+interval '25 days',true,'race-team-five',now()-interval '5 days',
   now()-interval '5 days'+interval '1 minute');
insert into public.apple_serving_schedules(product_id,storefront,currency,
  price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,
  reserve_components,trial_reserve_components,evidence_sha256) values
  ('com.rendprop.app.team5.monthly','USA','USD',349990,23000,1,
   now()-interval '6 days',now()+interval '1 day',
   '{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',
   '{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',
   repeat('c',64));
insert into public.serving_funding(org_id,source,collection_ref,net_receipts_cents,
  starts_at,ends_at,retention_ends_at,service_months,recurring_reserve_cents,
  reserve_components,evidence_sha256,apple_original_transaction_id) values
  ('5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','retail','apple:race-team-five',23000,
   now()-interval '5 days',now()+interval '25 days',now()+interval '25 days',
   1,0,'{}',repeat('c',64),'race-team-chain');
do $$begin if public.org_seats_allowed('5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>5
  then raise exception 'Signed Team5 seed did not grant five seats';end if;end$$;
commit;
