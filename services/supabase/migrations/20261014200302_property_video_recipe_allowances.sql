-- Owner-authorized shot allowances for actual multi-photo property videos.
-- A cap is an individual meter maximum, not a promise that every meter can be
-- exhausted together. The authorized allocation changes to50% of net paid receipts (less the existing hosting reserve). Existing per-attempt, paid-window and shared pool money
-- admission remains the authority; no new funded credit/allocation is seeded.
update public.plan_entitlements set reels_per_month=case plan when'starter'then 30 when'solo'then 30 when'pro'then 60 when'team'then 150 when'trial'then 20 else reels_per_month end
 where plan in('starter','solo','pro','team','trial');
update public.plan_entitlements set cogs_ceiling_cents=case plan when'starter'then 2032 when'solo'then 2032 when'pro'then 4157 when'team'then 10532 else cogs_ceiling_cents end where plan in('starter','solo','pro','team');
update public.plan_entitlement_overrides set reels_per_month=case plan when'starter'then 30 when'solo'then 30 when'pro'then 60 when'team'then 150 when'trial'then 20 else reels_per_month end where plan in('starter','solo','pro','team','trial')and reels_per_month is not null;
update public.plan_entitlement_overrides set cogs_ceiling_cents=case plan when'starter'then 2032 when'solo'then 2032 when'pro'then 4157 when'team'then 10532 else cogs_ceiling_cents end where plan in('starter','solo','pro','team')and cogs_ceiling_cents is not null;
update public.plan_entitlements set photo_edits_per_month=20,cogs_ceiling_cents=1500 where plan='trial';
update public.plan_entitlement_overrides set photo_edits_per_month=case when photo_edits_per_month is null then null else 20 end,cogs_ceiling_cents=case when cogs_ceiling_cents is null then null else 1500 end where plan='trial';
update public.app_config set value=jsonb_set(jsonb_set(value,'{trial_ceiling_cents}','1500'::jsonb),'{net_margin_bps}','5000'::jsonb)where key='serving_envelope';

-- Bound the chosen public gallery/video input set, not the owned photo library.
do $$declare body text;begin body:=pg_get_functiondef('public.validate_listing_gallery_selection()'::regprocedure);
 if position('cardinality(new.gallery_asset_ids)>40'in body)>0 then body:=replace(body,'cardinality(new.gallery_asset_ids)>40','cardinality(new.gallery_asset_ids)>100');body:=replace(body,'Choose up to 40 distinct uploaded gallery photos.','Choose up to 100 distinct uploaded gallery photos.');execute body;
 elsif position('cardinality(new.gallery_asset_ids)>100'in body)=0 then raise exception'Review changed gallery validator before widening only its selected-photo cap';end if;end$$;

-- Future funded trial grants may offer20 edits when their existing attested
-- schedule supports the cost. Prior grants/counters/commitments are preserved.
do $$declare c record;begin for c in select conrelid::regclass tab,conname from pg_constraint where contype='c'and conrelid in('public.subscription_trial_config'::regclass,'public.subscription_trial_grants'::regclass,'public.subscription_trial_purchase_reservations'::regclass,'public.apple_serving_schedules'::regclass)and(pg_get_constraintdef(oid)like'%photo_edits = 5%'or pg_get_constraintdef(oid)like'%photo_cap = 5%'or pg_get_constraintdef(oid)like'%trial_sponsored_cents%500%')loop execute format('alter table %s drop constraint %I',c.tab,c.conname);end loop;end$$;
alter table public.subscription_trial_config drop constraint if exists trial_photo_config_bound;
alter table public.subscription_trial_grants drop constraint if exists trial_photo_grant_bound;
alter table public.subscription_trial_purchase_reservations drop constraint if exists trial_photo_hold_bound;
alter table public.apple_serving_schedules drop constraint if exists trial_schedule_budget_bound;
alter table public.subscription_trial_config add constraint trial_photo_config_bound check(photo_edits between 5 and 20);
alter table public.subscription_trial_grants add constraint trial_photo_grant_bound check(photo_cap between 5 and 20);
alter table public.subscription_trial_purchase_reservations add constraint trial_photo_hold_bound check(photo_cap between 5 and 20);
alter table public.apple_serving_schedules add constraint trial_schedule_budget_bound check(trial_sponsored_cents between 0 and 1500);
update public.subscription_trial_config set photo_edits=20;
-- No trial schedule funding is increased here; an attested allocation/update
-- must still precede a larger inclusive future commitment. Existing pool/end,
-- grant cap, used action count and money liabilities remain unchanged.

-- New retail receipts use the same reviewed cost-allocation config. Existing
-- funding identity/replay and anchored slices remain untouched until renewal.
do $$declare body text;begin body:=pg_get_functiondef('public.provision_serving_funding(uuid,text,text,uuid,bigint,bigint,timestamptz,timestamptz,integer,jsonb,text)'::regprocedure);
 if position('p_net_receipts_cents/4'in body)>0 then body:=replace(body,'p_net_receipts_cents/4','floor(p_net_receipts_cents::numeric*least(5000,greatest(0,10000-public.serving_envelope_int(''net_margin_bps'',7500)))/10000)::bigint');execute body;
 elsif position('net_margin_bps'in body)=0 then raise exception'Review changed funding budget authority before alignment';end if;end$$;
