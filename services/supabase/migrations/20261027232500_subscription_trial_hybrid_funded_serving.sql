-- Keep the existing global ceiling service for legacy paid/manual workspaces.
-- An exact signed Production intro purchase, once converted from its immutable
-- cash hold, instead spends only its own seven-component net funded slice.
-- This migration remains dormant: it creates no cash, schedule, trial, or grant.
begin;

-- Every cash-held public trial needs a finite media delivery/storage budget
-- before StoreKit. The account receipt covers pooled fixed startup costs once;
-- each org's variable media reserve remains inside its own $5 sponsor hold.
-- No account cash, tariff, or active template is supplied by this migration.
create table public.subscription_trial_media_template(
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false,
 account_reserve_ref text references public.media_account_reserves(receipt_ref),
 request_limit bigint not null default 10000 check(request_limit between 1000 and 100000),
 byte_limit bigint not null default 21474836480 check(byte_limit between 1073741824 and 107374182400),
 storage_limit bigint not null default 2147483648 check(storage_limit between 1342177280 and 10737418240),
 evidence_sha256 text check(evidence_sha256~'^[a-f0-9]{64}$'),
 check(not enabled or(account_reserve_ref is not null and evidence_sha256 is not null))
);
insert into public.subscription_trial_media_template(singleton) values(true);
alter table public.subscription_trial_media_template enable row level security;
revoke all on public.subscription_trial_media_template from public,anon,authenticated,service_role;
grant select on public.subscription_trial_media_template to service_role;

-- Existing immutable holds retain their original fields. Newly admitted
-- purchases freeze the exact media account and limits at cash commitment.
alter table public.subscription_trial_purchase_reservations
 add column trial_media_account_ref text references public.media_account_reserves(receipt_ref),
 add column trial_media_requests bigint,
 add column trial_media_bytes bigint,
 add column trial_media_storage bigint,
 add column trial_media_evidence_sha256 text,
 add constraint subscription_trial_media_snapshot_complete check(
  (trial_media_account_ref is null and trial_media_requests is null and trial_media_bytes is null
   and trial_media_storage is null and trial_media_evidence_sha256 is null)
  or(trial_media_account_ref is not null and trial_media_requests between 1000 and 100000
   and trial_media_bytes between 1073741824 and 107374182400
   and trial_media_storage between 1342177280 and 10737418240
   and trial_media_evidence_sha256~'^[a-f0-9]{64}$'));

create function public.subscription_trial_media_template_ready(p_schedule uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare t public.subscription_trial_media_template;a public.media_account_reserves;
 s public.apple_serving_schedules;p public.serving_sponsor_pools; c public.subscription_trial_config;
 tariff jsonb; r jsonb;delivery numeric;compute numeric;storage numeric;
begin
 select * into t from public.subscription_trial_media_template where singleton;
 select * into s from public.apple_serving_schedules where id=p_schedule;
 select * into c from public.subscription_trial_config where singleton;
 if t.enabled is distinct from true or s.id is null or c.singleton is distinct from true
  or t.account_reserve_ref is null or t.evidence_sha256 is null
  or t.storage_limit<c.upload_budget_bytes+5*50331648 then return false;end if;
 select * into p from public.serving_sponsor_pools where id=s.trial_pool_id;
 select * into a from public.media_account_reserves where receipt_ref=t.account_reserve_ref;
 if p.id is null or a.receipt_ref is null or a.account_id<>'9c332c75b96cc642621dad5d86d4bf18'
  or a.cash_paid_cents>50000 or a.starts_at>now()
  or a.ends_at<p.ends_at+interval '97 days' then return false;end if;
 tariff:=a.tariff;r:=s.trial_reserve_components;
 delivery:=t.request_limit::numeric/1000000*(4*(tariff->>'r2_a_cents_per_million')::numeric
  +2*(tariff->>'r2_b_cents_per_million')::numeric+(tariff->>'worker_cents_per_million')::numeric);
 compute:=t.request_limit::numeric/1000000*(tariff->>'edge_cents_per_million')::numeric
  +t.request_limit::numeric*1000/1000000*(tariff->>'worker_cpu_cents_per_million_ms')::numeric;
 storage:=ceil(t.storage_limit::numeric/1000000000)*4*(tariff->>'storage_cents_per_gb_month')::numeric;
 return (r->>'delivery')::numeric>=ceil(delivery)
  and(r->>'compute')::numeric>=ceil(compute)
  and(r->>'storage')::numeric+(r->>'retention')::numeric>=ceil(storage);
end$$;
revoke all on function public.subscription_trial_media_template_ready(uuid) from public,anon,authenticated;
grant execute on function public.subscription_trial_media_template_ready(uuid) to service_role;

do $patch$ declare d text;a text;b text;
begin
 d:=pg_get_functiondef('public.prepare_subscription_trial_purchase(uuid,uuid,text)'::regprocedure);
 a:='identity_hash text;committed bigint;';
 b:='identity_hash text;committed bigint;media_template public.subscription_trial_media_template;';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed media purchase declaration';end if;
 d:=replace(d,a,b);
 a:=' if p.id is null or not p.admissions_enabled or p.starts_at>now()or p.ends_at<now()+interval ''168 hours'' then raise exception ''RP402: Trial sponsor admission is unavailable'';end if;';
 b:=a||E'\n'||$body$
 -- One cash-backed first cohort: no second overlapping enabled pool can
 -- silently double the owner's $500/100-trial allocation.
 if p.source<>'trial' or p.funded_cents>50000 or s.trial_sponsored_cents<>500
  or(select count(*) from public.subscription_trial_purchase_reservations where pool_id=p.id)>=100
  or exists(select 1 from public.serving_sponsor_pools other
    where other.id<>p.id and other.source='trial' and other.admissions_enabled
      and other.starts_at<now()+interval '7 days' and other.ends_at>now())
 then raise exception 'RP402: First 100 trial commitments exceed the owner allocation';end if;
 select * into media_template from public.subscription_trial_media_template where singleton for share;
 if not public.subscription_trial_media_template_ready(s.id) then
  raise exception 'RP402: Seven-day trial media coverage is unavailable';end if;$body$;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed media purchase sponsor gate';end if;
 d:=replace(d,a,b);
 a:='max_video_seconds,upload_budget_bytes)';
 b:='max_video_seconds,upload_budget_bytes,trial_media_account_ref,trial_media_requests,trial_media_bytes,trial_media_storage,trial_media_evidence_sha256)';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed media purchase insert fields';end if;
 d:=replace(d,a,b);
 a:='c.max_video_seconds,c.upload_budget_bytes);';
 b:='c.max_video_seconds,c.upload_budget_bytes,media_template.account_reserve_ref,media_template.request_limit,media_template.byte_limit,media_template.storage_limit,media_template.evidence_sha256);';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed media purchase snapshot values';end if;
 execute replace(d,a,b);
end $patch$;

-- Conversion is one transaction with the immutable provider/media journal.
-- A lost Apple response can replay the same funding and budget, never renew it.
do $patch$ declare d text;a text;b text;
begin
 d:=pg_get_functiondef('public.fund_reserved_subscription_trial(uuid,uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)'::regprocedure);
 a:='declare h public.subscription_trial_purchase_reservations;s public.apple_subscriptions;f public.serving_funding;r jsonb;g uuid;';
 b:='declare h public.subscription_trial_purchase_reservations;s public.apple_subscriptions;f public.serving_funding;r jsonb;g uuid;media_tariff jsonb;';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed media conversion declaration';end if;
 d:=replace(d,a,b);
 a:=' update public.subscription_trial_purchase_reservations set funding_id=(r->>''funding_id'')::uuid,original_transaction_id=p_original,converted_at=now()where id=h.id;';
 b:=$body$
 -- Expired historical receipts retain their financial tombstone without
 -- creating a live media budget. Active signed trials need it atomically.
 if s.status='active' and p_expires_at>now() then
  if h.trial_media_account_ref is null or h.trial_media_evidence_sha256 is null then
   raise exception 'RP402: Cash-held trial media snapshot is unavailable';end if;
  select tariff into media_tariff from public.media_account_reserves
   where receipt_ref=h.trial_media_account_ref;
  perform public.provision_media_delivery_budget(
   p_org,'trial-media:'||h.id,(r->>'funding_id')::uuid,
   p_purchased_at,p_expires_at+interval '90 days',
   h.trial_media_requests,h.trial_media_bytes,h.trial_media_storage,
   media_tariff,jsonb_build_object('delivery',h.reserve_components->'delivery',
    'compute',h.reserve_components->'compute','storage',h.reserve_components->'storage',
    'retention',h.reserve_components->'retention'),
   h.trial_media_evidence_sha256,h.trial_media_account_ref);
 end if;
$body$||a;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed media conversion completion';end if;
 execute replace(d,a,b);
end $patch$;

-- Exactly the current seven-day Production Apple term, not an older expired
-- or superseded original transaction left after a paid renewal/upgrade.
create function public.serving_signed_production_intro(p_org uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
  select 1 from public.orgs o join public.apple_subscriptions a
    on a.org_id=o.id and a.product_id=o.apple_product_id
   and a.expires_at=o.plan_expires_at
  where o.id=p_org and o.deleted_at is null and o.plan_source='apple'
    and a.environment='Production' and a.status in('active','grace')
    and a.transaction_purchased_at is not null and a.expires_at>now()
    and a.expires_at<=a.transaction_purchased_at+interval '8 days'
 );
$$;
revoke all on function public.serving_signed_production_intro(uuid) from public,anon,authenticated;
grant execute on function public.serving_signed_production_intro(uuid) to service_role,postgres;

create function public.serving_trial_funded_actor(p_actor uuid,p_org uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
  select 1 from public.subscription_trial_purchase_reservations h
  join public.serving_funding f on f.id=h.funding_id
  join public.serving_funding_slices sl on sl.funding_id=f.id and sl.slice_index=0
  join public.subscription_trial_grants g on g.funding_id=f.id
  join public.apple_subscriptions a on a.original_transaction_id=h.original_transaction_id
  join public.orgs o on o.id=h.org_id and o.apple_product_id=a.product_id
    and o.plan_expires_at=a.expires_at
  where h.actor_id=p_actor and h.org_id=public.library_actor_billing_org(p_actor,p_org)
    and public.serving_signed_production_intro(h.org_id)
    and h.funding_id is not null and h.pool_id=f.sponsor_pool_id
    and h.product_id=a.product_id and f.source='trial' and f.actor_id=p_actor
    and f.org_id=h.org_id and f.apple_original_transaction_id=h.original_transaction_id
    and f.revoked_at is null and f.starts_at<=now() and f.ends_at>now()
    and sl.org_id=h.org_id and sl.starts_at<=now() and sl.ends_at>now()
    and g.actor_id=p_actor and g.org_id=h.org_id
    and g.original_transaction_id=h.original_transaction_id
    and g.starts_at<=now() and g.ends_at>now()
    and a.org_id=h.org_id and a.environment='Production'
    and a.status in('active','grace') and a.expires_at>now()
 );
$$;
revoke all on function public.serving_trial_funded_actor(uuid,uuid) from public,anon,authenticated;
grant execute on function public.serving_trial_funded_actor(uuid,uuid) to service_role;

-- The current product media-read implementation records usage but deliberately
-- bypasses financial budgets for existing paid/manual workspaces. A converted
-- cash-held intro must instead consume its frozen request/byte budget before
-- that usage record, including HEAD/replay reads; otherwise public trial
-- delivery could exceed the $5 sponsor liability without a supplier hold.
do $patch$ declare d text;a text;b text;
begin
 d:=pg_get_functiondef('public.media_delivery_admit(uuid,bigint,boolean)'::regprocedure);
 a:='  perform 1 from public.orgs where id=p_org and deleted_at is null for share;';
 b:=$body$
  if public.serving_signed_production_intro(public.library_billing_org(p_org)) then
   if not exists(select 1 from public.subscription_trial_purchase_reservations h
     where h.org_id=public.library_billing_org(p_org)
       and public.serving_trial_funded_actor(h.actor_id,p_org)) then
    raise exception 'RP402: Verified trial media funding is unavailable';end if;
   perform public.media_delivery_admit_before_owner_testing_20261015(p_org,p_bytes,p_required);
  end if;
$body$||a;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid media read predecessor';end if;
 execute replace(d,a,b);
end $patch$;

do $patch$
declare d text; a text; b text;
begin
 d:=pg_get_functiondef('public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)'::regprocedure);
 a:='unlimited boolean;spent numeric;reservation uuid;envelope jsonb;ceiling numeric;basis text;kind text;';
 b:='unlimited boolean;spent numeric;reservation uuid;envelope jsonb;ceiling numeric;basis text;kind text;trial_funded boolean;';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid serving predecessor declaration';end if;
 d:=replace(d,a,b);
 a:=' unlimited:=public.org_has_internal_testing_grant(public.library_actor_billing_org(p_actor,p_org))or public.org_has_private_internal_testing(public.library_actor_billing_org(p_actor,p_org));';
 b:=$body$
 trial_funded:=public.serving_trial_funded_actor(p_actor,p_org);
 unlimited:=(public.org_has_internal_testing_grant(public.library_actor_billing_org(p_actor,p_org))or public.org_has_private_internal_testing(public.library_actor_billing_org(p_actor,p_org)))and not trial_funded;
 -- A signed Production intro without an exact converted purchase may not
 -- fall back to the legacy ceiling. No supplier request is authorized.
 if public.serving_mode()='ceiling' and not trial_funded and
    public.serving_signed_production_intro(public.library_actor_billing_org(p_actor,p_org))
 then raise exception 'RP402: Verified trial funding is unavailable';end if;$body$;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid serving predecessor authority';end if;
 d:=replace(d,a,b);
 a:='if public.serving_mode()=''ceiling'' then
   -- Ceiling mode: serving_envelope_admit';
 b:='if public.serving_mode()=''ceiling'' and not trial_funded then
   -- Ceiling mode: serving_envelope_admit';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid serving predecessor ceiling branch';end if;
 d:=replace(d,a,b);
 a:='select funding.* into f from public.serving_funding funding where org_id=public.library_actor_billing_org(p_actor,p_org) and revoked_at is null and starts_at<=now()and ends_at>now();';
 b:='select funding.* into f from public.serving_funding funding where org_id=public.library_actor_billing_org(p_actor,p_org) and revoked_at is null and starts_at<=now()and ends_at>now() and (not trial_funded or (funding.source=''trial'' and funding.actor_id=p_actor and funding.id=(select h.funding_id from public.subscription_trial_purchase_reservations h where h.actor_id=p_actor and h.org_id=public.library_actor_billing_org(p_actor,p_org))));';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid serving predecessor funding selection';end if;
 execute replace(d,a,b);
end $patch$;

do $patch$ declare d text; a text; b text;
begin
 d:=pg_get_functiondef('public.subscription_serving_activation(uuid,uuid)'::regprocedure);
 a:=' if public.serving_mode()=''ceiling''then return jsonb_build_object(''org_id'',p_org,''available'',true,''funded'',false,''authority'',''existing_non_apple'');end if;';
 b:=$body$ if public.serving_trial_funded_actor(p_actor,p_org)then return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','funded_trial');end if;
 if public.serving_mode()='ceiling' and
    public.serving_signed_production_intro(public.library_actor_billing_org(p_actor,p_org))
 then return jsonb_build_object('org_id',p_org,'available',false,'funded',false,'authority','subscription_activation_unavailable');end if;
$body$||a;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid activation predecessor';end if;
 execute replace(d,a,b);
end $patch$;

-- The paid-plan ceiling shortcut predated cash-held intros. For the current
-- signed intro it bypassed grant counters in photo/upload and hid /me usage.
-- Paid renewals, manual plans and private QA keep their original branch.
do $patch$ declare d text; a text; b text;
begin
 d:=pg_get_functiondef('public.subscription_trial_paid_or_override(uuid)'::regprocedure);
 a:='select public.library_internal_content_unlimited(p_org)or public.subscription_trial_paid_or_override_before_team(public.library_billing_org(p_org));';
 b:='select not public.serving_signed_production_intro(public.library_billing_org(p_org)) and (public.library_internal_content_unlimited(p_org)or public.subscription_trial_paid_or_override_before_team(public.library_billing_org(p_org)));';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid trial override predecessor';end if;
 execute replace(d,a,b);
end $patch$;

-- Old clients may deliver a signed zero-price intro before using the new
-- prepare endpoint. They cannot create a draft or storage liability unless
-- that same buyer/org/SKU was cash-held and converted to an active grant.
do $patch$ declare d text; a text; b text;
begin
 d:=pg_get_functiondef('public.trial_intro_listing_guard()'::regprocedure);
 a:='  if envelope->>''kind''=''free'' or';
 b:=$body$  if public.serving_signed_production_intro(billing) and
     not public.serving_trial_funded_actor(auth.uid(),new.org_id) then
    raise exception 'RP402: Verified trial funding is unavailable';end if;
$body$||a;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid listing predecessor';end if;
 execute replace(d,a,b);
 d:=pg_get_functiondef('public.trial_intro_upload_guard()'::regprocedure);
 a:='        and t.environment in(''Production'',''Sandbox'')) into paid_property;';
 b:=a||E'\n'||$body$    if public.serving_signed_production_intro(billing) and
     not public.serving_trial_funded_actor(new.actor_id,org) and
     not (new.spec->>'kind'='video' and paid_property) then
    raise exception 'RP402: Verified trial funding is unavailable';end if;$body$;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid upload predecessor';end if;
 execute replace(d,a,b);
end $patch$;

-- A separately purchased one-time property website remains usable during an
-- intro. Its exact paid listing/video does not spend the five trial edits or
-- require the trial sponsor hold; unpaid photos and videos remain gated.
do $patch$ declare d text; a text; b text;
begin
 d:=pg_get_functiondef('public.subscription_trial_upload_guard()'::regprocedure);
 a:=' if public.subscription_trial_paid_or_override(new.org_id)then return new;end if;';
 b:=$body$ if new.spec->>'kind'='video' and exists(
   select 1 from public.listings l join public.property_website_transactions t
     on t.assigned_listing_id=l.id and t.revoked_at is null
   where l.id=new.listing_id and l.org_id=new.org_id and l.deleted_at is null
     and t.environment in('Production','Sandbox')) then return new;end if;
$body$||a;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid paid upload predecessor';end if;
 execute replace(d,a,b);
 d:=pg_get_functiondef('public.subscription_trial_render_guard()'::regprocedure);
 a:=' if public.subscription_trial_paid_or_override(org)then return new;end if;';
 b:=$body$ if ((tg_table_name='render_jobs' and to_jsonb(new)->>'source'='app')
   or(tg_table_name='renders' and exists(select 1 from public.render_jobs j
      where j.id=(to_jsonb(new)->>'job_id')::uuid and j.source='app')))
  and exists(
   select 1 from public.property_website_transactions t
   where t.assigned_listing_id=listing and t.revoked_at is null
     and t.environment in('Production','Sandbox')) then return new;end if;
$body$||a;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid paid render predecessor';end if;
 execute replace(d,a,b);
end $patch$;

-- This release's cash-backed intro includes a draft listing, photos and five
-- bounded edits. Video/aerial generation and website publication start after
-- payment. Preserve historical grant rows, but new held offers must carry
-- zeros rather than the obsolete walkthrough/publication promise.
do $$begin
 if exists(select 1 from public.subscription_trial_config where enabled) then
  raise exception 'Review active trial before zero-video offer migration';end if;
end$$;
alter table public.subscription_trial_config drop constraint if exists subscription_trial_config_walkthroughs_check;
alter table public.subscription_trial_config drop constraint if exists subscription_trial_config_published_listings_check;
alter table public.subscription_trial_config drop constraint if exists subscription_trial_config_max_video_seconds_check;
alter table public.subscription_trial_config alter column walkthroughs set default 0;
alter table public.subscription_trial_config alter column published_listings set default 0;
alter table public.subscription_trial_config alter column max_video_seconds set default 0;
update public.subscription_trial_config set walkthroughs=0,published_listings=0,max_video_seconds=0;
alter table public.subscription_trial_config add constraint subscription_trial_config_walkthroughs_check check(walkthroughs=0);
alter table public.subscription_trial_config add constraint subscription_trial_config_published_listings_check check(published_listings=0);
alter table public.subscription_trial_config add constraint subscription_trial_config_max_video_seconds_check check(max_video_seconds=0);
alter table public.subscription_trial_purchase_reservations drop constraint if exists subscription_trial_purchase_reservations_walkthrough_cap_check;
alter table public.subscription_trial_purchase_reservations drop constraint if exists subscription_trial_purchase_reservations_listing_cap_check;
alter table public.subscription_trial_purchase_reservations drop constraint if exists subscription_trial_purchase_reservations_max_video_seconds_check;
alter table public.subscription_trial_purchase_reservations drop constraint if exists subscription_trial_purchase_reservation_max_video_seconds_check;
alter table public.subscription_trial_purchase_reservations add constraint subscription_trial_purchase_reservations_walkthrough_cap_check check(walkthrough_cap between 0 and 1);
alter table public.subscription_trial_purchase_reservations add constraint subscription_trial_purchase_reservations_listing_cap_check check(listing_cap between 0 and 1);
alter table public.subscription_trial_purchase_reservations add constraint subscription_trial_purchase_reservations_max_video_seconds_check check(max_video_seconds between 0 and 90);
alter table public.subscription_trial_grants drop constraint if exists subscription_trial_grants_walkthrough_cap_check;
alter table public.subscription_trial_grants drop constraint if exists subscription_trial_grants_listing_cap_check;
alter table public.subscription_trial_grants drop constraint if exists subscription_trial_grants_max_video_seconds_check;
alter table public.subscription_trial_grants add constraint subscription_trial_grants_walkthrough_cap_check check(walkthrough_cap between 0 and 1);
alter table public.subscription_trial_grants add constraint subscription_trial_grants_listing_cap_check check(listing_cap between 0 and 1);
alter table public.subscription_trial_grants add constraint subscription_trial_grants_max_video_seconds_check check(max_video_seconds between 0 and 90);

-- The immutable $5 purchase reservation is the entire trial cash authority.
-- Step25's old ceiling-mode admission window and headroom requirement would
-- double-gate that same seven-day promise against an unrelated QA budget.
do $patch$ declare d text; a text; b text;
begin
 d:=pg_get_functiondef('public.prepare_subscription_trial_purchase(uuid,uuid,text)'::regprocedure);
 a:=$body$
 if public.serving_mode()='ceiling' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));
  -- Production intro usage draws this operational cap as well as the
  -- immutable purchase sponsor commitment. A few remaining cents cannot
  -- support the advertised seven-day package.
  if not exists(
    select 1 from (select public.trial_sponsor_pool() as pool) runtime
    where now()>=(runtime.pool->>'starts_at')::timestamptz
      and (runtime.pool->>'ends_at')::timestamptz>=now()+interval '168 hours'
      and (runtime.pool->>'cap_cents')::numeric-public.trial_sponsor_spent_cents()>=s.trial_sponsored_cents
  ) then raise exception 'RP402: Seven-day trial serving capacity is unavailable';end if;
 end if;$body$;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid purchase admission predecessor';end if;
 execute replace(d,a,E'\n -- The exact seven-day sponsor hold below is the purchase cash gate.');
end $patch$;

-- Keep the legacy runtime ceiling as a separately reported operational/QA
-- limit. It is not a prerequisite for a trial whose own slice is funded.
do $patch$ declare d text; a text; b text;
begin
 d:=pg_get_functiondef('public.subscription_trial_activation_readiness()'::regprocedure);
 a:='c.walkthroughs=1 and c.photo_edits=5 and';
 b:='c.walkthroughs=0 and c.photo_edits=5 and';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid readiness terms';end if;
 d:=replace(d,a,b);
 a:='c.published_listings=1 and c.max_days=7 and c.max_video_seconds<=90';
 b:='c.published_listings=0 and c.max_days=7 and c.max_video_seconds=0';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid readiness media terms';end if;
 d:=replace(d,a,b);
 a:='''local_prerequisites_met'',bounded and runtime_ready and cardinality(missing)=0';
 b:='''trial_funded_dispatch_ready'',true,'||chr(10)||'    ''local_prerequisites_met'',bounded and cardinality(missing)=0';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid readiness predecessor';end if;
 d:=replace(d,a,b);
 a:='Owner-funded sponsor deposit and evidence verified against bank or provider receipt';
 b:='Owner-approved $1,000 existing-business-cash launch allocation recorded; first 100 seven-day trial holds are bounded to $500 total and shared, QA, and legacy future commitments fit the other $500';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid readiness owner funding predecessor';end if;
 d:=replace(d,a,b);
 a:='and public.serving_reserve_total(s.trial_reserve_components)<s.trial_sponsored_cents';
 b:='and s.trial_sponsored_cents=500 and public.serving_reserve_total(s.trial_reserve_components)<s.trial_sponsored_cents and public.subscription_trial_media_template_ready(s.id)';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid readiness schedule media predecessor';end if;
 d:=replace(d,a,b);
 a:='and p.source=''trial'' and p.admissions_enabled and';
 b:='and p.source=''trial'' and p.admissions_enabled and p.funded_cents<=50000 and (select count(*) from public.subscription_trial_purchase_reservations h where h.pool_id=p.id)<100 and';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed hybrid readiness cohort predecessor';end if;
 execute replace(d,a,b);
end $patch$;

commit;
