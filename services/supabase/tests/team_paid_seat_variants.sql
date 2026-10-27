-- Team seats require a current, signed, paid Apple term and matching funded
-- schedule. A midterm upgrade closes old credits without touching top-ups.
begin;
create temporary table monthly_checks(n integer not null default 0);
insert into monthly_checks default values;
grant all on monthly_checks to service_role;
create function pg_temp.monthly_ok(v boolean,label text) returns void language plpgsql as $$
begin
  if v is distinct from true then raise exception 'TEAM SEAT FAIL: %',label; end if;
  update monthly_checks set n=n+1;
end$$;

insert into auth.users(id,email,is_anonymous) values
  ('41111111-1111-4111-8111-111111111111','team-seat@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)
values ('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Team seats','team','apple',
  'com.rendprop.app.team4.monthly',now()+interval '25 days');
insert into public.memberships(user_id,org_id,role) values
  ('41111111-1111-4111-8111-111111111111',
   '4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');
insert into public.apple_subscriptions(original_transaction_id,org_id,user_id,
  product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,
  transaction_purchased_at,transaction_signed_at) values
  ('team-chain','4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '41111111-1111-4111-8111-111111111111',
   'com.rendprop.app.team4.monthly','team','Production','active',
   now()+interval '25 days',true,'team-four',now()-interval '5 days',
   now()-interval '5 days'+interval '1 minute');

select pg_temp.monthly_ok(public.org_seats_allowed('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')=3
  and not exists(select 1 from public.team_current_paid_variant('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')),
  'known but unapproved Apple SKU grants only the existing three seats');
update public.team_paid_seat_variants set active=true where seats in(4,5);
update public.credit_monthly_catalog set active=true
  where product_id in('com.rendprop.app.team4.monthly','com.rendprop.app.team5.monthly');
select pg_temp.monthly_ok(public.org_seats_allowed('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')=3,
  'catalog activation alone cannot grant seats without paid funding');
set local role service_role;
select pg_temp.monthly_ok(
  public.credit_verified_monthly_apply('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'com.rendprop.app.team4.monthly','Production','team-chain','team-four',
    now()-interval '5 days',now()+interval '25 days',299990,
    now()-interval '5 days'+interval '1 minute',
    now()-interval '5 days'+interval '1 minute','paid')->>'reason'='variant_not_funded',
  'variant credits stay closed until the same seat SKU is retail-funded');
reset role;

-- This fixture explicitly simulates an already active launch policy before
-- either signed Team period. The real catalog and combined policy stay dormant.
update public.app_config set value=value || jsonb_build_object(
  'enabled',true,'activated_from',(now()-interval '6 days')::text)
where key='credit_combined_budget';

insert into public.apple_serving_schedules(product_id,storefront,currency,
  price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,
  reserve_components,trial_reserve_components,evidence_sha256) values
  ('com.rendprop.app.team4.monthly','USA','USD',299990,20000,1,
   now()-interval '6 days',now()+interval '1 day',
   '{"storage":115,"delivery":120,"compute":60,"email":30,"support":160,"retention":55,"uncertainty":60}',
   '{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',
   repeat('a',64)),
  ('com.rendprop.app.team5.monthly','USA','USD',349990,23000,1,
   now()-interval '2 days',now()+interval '1 day',
   '{"storage":130,"delivery":140,"compute":70,"email":35,"support":195,"retention":60,"uncertainty":70}',
   '{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',
   repeat('b',64));
insert into public.serving_funding(org_id,source,collection_ref,net_receipts_cents,
  starts_at,ends_at,retention_ends_at,service_months,recurring_reserve_cents,
  reserve_components,evidence_sha256,apple_original_transaction_id) values
  ('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','retail','apple:team-four',20000,
   now()-interval '5 days',now()+interval '25 days',now()+interval '25 days',
   1,600,'{"storage":115,"delivery":120,"compute":60,"email":30,"support":160,"retention":55,"uncertainty":60}',repeat('a',64),'team-chain');

select pg_temp.monthly_ok(public.org_seats_allowed('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')=4
  and (select seats=4 and price_cents=29999 from public.team_current_paid_variant(
      '4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')),
  'exact current funded Apple transaction grants four seats at attested price');
select pg_temp.monthly_ok((select seats=4 and price_cents=29999
    from public.org_entitlement('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')),
  'consumer entitlement agrees with team invitation capacity and price');

set local role service_role;
do $$
declare r jsonb;org uuid:='4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
begin
 r:=public.credit_verified_monthly_apply(org,'com.rendprop.app.team4.monthly',
   'Production','team-chain','team-four',now()-interval '5 days',
   now()+interval '25 days',299990,now()-interval '5 days'+interval '1 minute',
   now()-interval '5 days'+interval '1 minute','paid');
 perform pg_temp.monthly_ok(r->>'credits'='700' and
   (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=700,
   'four-seat paid term mints exactly 700 credits');
end$$;
reset role;

-- The effective paid transaction changes immediately on an Apple upgrade.
-- A future renewal preference alone is irrelevant to this snapshot.
update public.orgs set apple_product_id='com.rendprop.app.team5.monthly',
  plan_expires_at=now()+interval '29 days'
  where id='4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
update public.apple_subscriptions set product_id='com.rendprop.app.team5.monthly',
  last_transaction_id='team-five',expires_at=now()+interval '29 days'
  where original_transaction_id='team-chain';
update public.apple_subscriptions set transaction_purchased_at=now()-interval '1 day',
  transaction_signed_at=now()-interval '1 day'+interval '1 minute'
  where original_transaction_id='team-chain';
insert into public.serving_funding(org_id,source,collection_ref,net_receipts_cents,
  starts_at,ends_at,retention_ends_at,service_months,recurring_reserve_cents,
  reserve_components,evidence_sha256,apple_original_transaction_id) values
  ('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','retail','apple:team-five',23000,
   now()-interval '1 day',now()+interval '29 days',now()+interval '29 days',
   1,700,'{"storage":130,"delivery":140,"compute":70,"email":35,"support":195,"retention":60,"uncertainty":70}',repeat('b',64),'team-chain');
select pg_temp.monthly_ok(public.org_seats_allowed('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')=5,
  'five-seat upgrade uses current signed transaction, not the old four-seat term');
set local role service_role;
do $$
declare r jsonb;org uuid:='4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
begin
 r:=public.credit_verified_monthly_apply(org,'com.rendprop.app.team5.monthly',
   'Production','team-chain','team-five',now()-interval '1 day',
   now()+interval '29 days',349990,now()-interval '1 day'+interval '1 minute',
   now()-interval '1 day'+interval '1 minute','paid');
 perform pg_temp.monthly_ok(r->>'credits'='800' and
   (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=800,
   'upgrade starts new paid period and closes old unspent 700-credit grant');
 perform pg_temp.monthly_ok((select count(*)=1 from public.credit_grants
     where reference='apple:team-four' and revoked_at is not null),
   'superseded credit grant is revoked exactly once');
 r:=public.credit_verified_monthly_apply(org,'com.rendprop.app.team4.monthly',
   'Production','team-chain','team-four',now()-interval '5 days',
   now()+interval '25 days',299990,now()-interval '5 days'+interval '1 minute',
   now(),'reversed');
 perform pg_temp.monthly_ok(r->>'reason'='not_current_paid_period' and
   (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=800,
   'late refund reversal cannot resurrect a superseded allowance');
 r:=public.credit_verified_monthly_apply(org,'com.rendprop.app.team5.monthly',
   'Production','team-chain','team-five',now()-interval '1 day',
   now()+interval '29 days',349990,now()-interval '1 day'+interval '1 minute',
   now(),'paid');
 perform pg_temp.monthly_ok(r->>'replay'='true' and
   (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=800,
   'notification replay does not double-grant upgrade credits');
end$$;
reset role;

-- Five real accepted people survive the paid tier change as memberships, but
-- only the earliest two plus the owner retain Team-funded access at three.
insert into auth.users(id,email,is_anonymous) values
  ('41111111-1111-4111-8111-111111111112','seat-two@example.invalid',false),
  ('41111111-1111-4111-8111-111111111113','seat-three@example.invalid',false),
  ('41111111-1111-4111-8111-111111111114','seat-four@example.invalid',false),
  ('41111111-1111-4111-8111-111111111115','seat-five@example.invalid',false);
create temporary table seat_people(user_id uuid primary key,invite_hash text,private_org uuid,accepted_order integer);
insert into seat_people(user_id,invite_hash,accepted_order) values
  ('41111111-1111-4111-8111-111111111115',repeat('5',64),1),
  ('41111111-1111-4111-8111-111111111112',repeat('2',64),2),
  ('41111111-1111-4111-8111-111111111114',repeat('4',64),3),
  ('41111111-1111-4111-8111-111111111113',repeat('3',64),4);
grant all on seat_people to service_role;
set local role service_role;
do $$declare p record;r jsonb;owner_id uuid:='41111111-1111-4111-8111-111111111111';
  team_id uuid:='4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';begin
  for p in select * from seat_people order by accepted_order loop
    perform public.create_org_invite(owner_id,team_id,null,'agent',p.invite_hash);
    r:=public.accept_org_invite(p.user_id,p.invite_hash);
    update seat_people set private_org=(r->>'org_id')::uuid where user_id=p.user_id;
    update public.org_invites set accepted_at=now()-interval '5 days'+p.accepted_order*interval '1 hour'
      where token_hash=p.invite_hash;
  end loop;
  perform pg_temp.monthly_ok(public.org_seats_used(team_id)=5
    and (select count(*)=5 from public.team_seat_status(team_id) where seat_active),
    'five accepted seats are active on signed five-seat term');
end$$;
reset role;

-- The signed current subscription, not a renewal preference, now has the
-- three-seat SKU. Saved memberships and private originals remain intact.
update public.apple_subscriptions set product_id='com.rendprop.app.team.monthly',
  last_transaction_id='team-three',transaction_purchased_at=now(),
  transaction_signed_at=now()
  where original_transaction_id='team-chain';
update public.orgs set apple_product_id='com.rendprop.app.team.monthly'
  where id='4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select pg_temp.monthly_ok(public.org_seats_allowed('4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')=3,
  'current signed base SKU immediately grants only three seats');
do $$declare team_id uuid:='4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';begin
  perform pg_temp.monthly_ok((select count(*)=5 from public.memberships where org_id=team_id)
    and (select count(*)=2 from public.team_seat_status(team_id) where not seat_active),
    'downgrade keeps five memberships but pauses exactly two');
  perform pg_temp.monthly_ok(public.team_member_seat_active('41111111-1111-4111-8111-111111111111',team_id)
    and public.team_member_seat_active('41111111-1111-4111-8111-111111111115',team_id)
    and public.team_member_seat_active('41111111-1111-4111-8111-111111111112',team_id)
    and not public.team_member_seat_active('41111111-1111-4111-8111-111111111114',team_id)
    and not public.team_member_seat_active('41111111-1111-4111-8111-111111111113',team_id),
    'owner is pinned and earliest accepted members win over user-ID order');
  perform pg_temp.monthly_ok((select bool_and(public.library_billing_org(private_org)=team_id
    and public.library_team_owner(private_org)='41111111-1111-4111-8111-111111111111'::uuid)
    from seat_people where accepted_order<=2)
    and (select bool_and(public.library_billing_org(private_org)=private_org
      and public.library_team_owner(private_org)is null
      and public.library_team_org(private_org)is null
      and public.paused_team_org(user_id)=team_id
      and public.library_content_access(user_id,private_org,true))
      from seat_people where accepted_order>2),
    'only active seats borrow Team funding; paused people keep their own saved libraries');
end$$;
set local role service_role;
do $$declare team_id uuid:='4aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  owner_id uuid:='41111111-1111-4111-8111-111111111111';refused boolean:=false;begin
  begin perform public.create_org_invite(owner_id,team_id,null,'agent',repeat('e',64));
  exception when others then refused:=sqlerrm like 'RP402:%';end;
  perform pg_temp.monthly_ok(refused,'over-capacity Team cannot issue a new invitation');
  perform public.remove_org_member(team_id,owner_id,'41111111-1111-4111-8111-111111111115');
  perform pg_temp.monthly_ok(public.team_member_seat_active('41111111-1111-4111-8111-111111111114',team_id)
    and not public.team_member_seat_active('41111111-1111-4111-8111-111111111113',team_id),
    'removing the earliest seat automatically resumes the next accepted person');
end$$;
reset role;
select json_build_object('passed',true,'assertions',(select n from monthly_checks));
rollback;
