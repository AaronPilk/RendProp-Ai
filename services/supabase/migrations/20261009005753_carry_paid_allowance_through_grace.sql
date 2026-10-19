-- Carry paid AI allowance through billing grace; never fund a second unpaid
-- period. Prices, feature meters, sponsor allocations and retention are unchanged.
-- Replay-safe replacement; no one-shot function-definition patches.
-- Staged safety fix only: verified grace keeps service entitlement, but current
-- receipt storage cannot prove paid AI balance. Not commercial grace acceptance.
begin;

create or replace function public.plan_serving_ceiling(p_org uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o public.orgs;e public.plan_entitlements;s public.apple_subscriptions;plan text;annual boolean;commission integer;margin integer;reserve integer;
 monthly_net numeric;envelope integer;sku text;trial_cap integer;ps timestamptz;pe timestamptz;term_start timestamptz;term_end timestamptz;grace_end timestamptz;slice interval;k integer;
 month_start timestamptz:=date_trunc('month',now());
begin
 select * into o from public.orgs where id=p_org and deleted_at is null;
 if o.id is null then raise exception 'RP404: Workspace unavailable';end if;
 if public.org_has_private_internal_testing(p_org)or public.org_has_internal_testing_grant(p_org)then
  return jsonb_build_object('ceiling_cents',2147483647,'basis','period','kind','sponsored','plan','team','sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 if public.org_has_app_review_funding(p_org)then
  return jsonb_build_object('ceiling_cents',500,'basis','period','kind','app_review','plan','pro','sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 e:=public.org_entitlement(p_org);plan:=e.plan;trial_cap:=public.serving_envelope_int('trial_ceiling_cents',500);
 if plan='brokerage'then return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','brokerage','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 if plan='free'then return jsonb_build_object('ceiling_cents',public.serving_envelope_int('free_lifetime_cents',300),'basis','lifetime','kind','free','plan',plan,'sku',null,'period_start',null,'period_end',null,'window','lifetime');end if;
 if plan='trial'then
  -- One Sandbox window: the seven days the grant opened, never a calendar refill.
  if o.trial_ends_at is not null then ps:=o.trial_ends_at-interval '7 days';pe:=o.trial_ends_at;
  else ps:=month_start;pe:=month_start+interval '1 month';end if;
  return jsonb_build_object('ceiling_cents',trial_cap,'basis','period','kind','trial','plan',plan,'sku',null,'period_start',ps,'period_end',pe,'window','trial_window');end if;
 if plan in('starter','solo','pro','team')then
  if o.plan_source='manual'then return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','manual','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
  sku:=o.apple_product_id;annual:=coalesce(sku,'')like '%.annual';
  commission:=public.serving_envelope_int('apple_commission_bps',3000);margin:=public.serving_envelope_int('net_margin_bps',7500);
  reserve:=public.serving_envelope_int('hosting_reserve_cents',50);
  -- Annual SKUs are ten monthly prices for twelve months of service.
  monthly_net:=case when annual then coalesce(e.price_cents,0)*10.0*(10000-commission)/10000/12 else coalesce(e.price_cents,0)*(10000-commission)/10000.0 end;
  envelope:=greatest(0,floor(monthly_net*(10000-margin)/10000.0)::integer-reserve);
  select * into s from public.apple_subscriptions where org_id=p_org and environment='Production' and status in('active','grace')
   order by expires_at desc nulls last limit 1;
  if s.original_transaction_id is not null and s.expires_at is not null then
   term_end:=s.expires_at;
   term_start:=coalesce(s.transaction_purchased_at,term_end-(case when annual then interval '1 year' else interval '1 month' end));
   if term_start>=term_end then term_start:=term_end-(case when annual then interval '1 year' else interval '1 month' end);end if;
   -- A free introductory term never turns into paid AI allowance merely
   -- because its renewal notification is delayed. Its sponsor week has ended.
   if s.status='active' and s.transaction_purchased_at is not null and s.expires_at<=s.transaction_purchased_at+interval '8 days' then
    return jsonb_build_object('ceiling_cents',case when s.expires_at>now() then least(envelope,trial_cap) else 0 end,
     'basis','period','kind','trial','plan',plan,'sku',sku,'period_start',s.transaction_purchased_at,'period_end',s.expires_at,'window','intro_window');end if;
   -- A grace snapshot overwrites expires_at with Apple's grace deadline.
   -- This schema does not retain the transaction's signed paid expiry or offer
   -- facts in ceiling mode. A seven-day free intro plus 28-day grace can look
   -- longer than a normal monthly term: duration cannot prove paid funds.
   -- Do not invent money or infer annual slices from that deadline. Complete
   -- commercial grace needs authoritative paid-term/proceeds evidence first.
   if s.status='grace' then
    return jsonb_build_object('ceiling_cents',0,'basis','period','kind','grace','plan',plan,'sku',sku,
     'period_start',term_start,'period_end',s.expires_at,'window','apple_grace');
   end if;
   -- A delayed EXPIRED notification retains the existing 16-day entitlement
   -- fallback. Its active snapshot still carries the signed paid expiry, so
   -- unused paid money can carry through without adding a second allowance.
   grace_end:=term_end+interval '16 days';
   if term_end<=now() then
    ps:=case when annual then term_end-(term_end-term_start)/12 else term_start end;
    pe:=grace_end;
    if now()>=pe then envelope:=0;end if;
    -- Count the original paid term (last annual slice) AND every grace attempt
    -- against one allowance. A recovered transaction later starts its verified
    -- new term, which includes any backdated grace expense in that new term.
    return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','grace','plan',plan,'sku',sku,'period_start',ps,'period_end',pe,'window','apple_grace');
   end if;
   if annual then
    slice:=(term_end-term_start)/12;
    k:=least(11,greatest(0,floor(extract(epoch from(now()-term_start))/extract(epoch from slice))::integer));
    return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',term_start+slice*k,'period_end',term_start+slice*(k+1),'window','apple_slice');end if;
   return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',term_start,'period_end',term_end,'window','apple_term');
  end if;
  return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');
 end if;
 return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','other','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');
end$$;

revoke all on function public.plan_serving_ceiling(uuid) from public,anon,authenticated;
grant execute on function public.plan_serving_ceiling(uuid) to service_role,postgres;
commit;
