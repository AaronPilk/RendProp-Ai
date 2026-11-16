-- EXPAND PHASE: installs verified v2 chronology without changing the deployed
-- eleven-argument writer. Deploy and verify updated me/apple-subscriptions
-- handlers before applying 20261005032635_apple_entitlement_legacy_cutover.sql.
-- Existing legacy handlers retain their prior semantics during that transition.

-- Apple expiry is access duration, not event chronology. A valid older JWS
-- must not reverse a product change or resurrect a refunded transaction.
-- The later cutover fences unordered legacy updates. No native wire change.

alter table public.apple_subscriptions add column if not exists transaction_purchased_at timestamptz;
alter table public.apple_subscriptions add column if not exists transaction_signed_at timestamptz;
alter table public.apple_subscriptions add column if not exists entitlement_signed_at timestamptz;
alter table public.apple_subscriptions add column if not exists renewal_signed_at timestamptz;

-- During expansion an old handler may still update a v2 row without carrying
-- signed chronology. Never retain watermarks that certify an earlier state.
-- The v2 wrapper restores its verified watermarks after its private write.
create or replace function public.invalidate_unordered_apple_chronology()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='INSERT' then
  -- Existing legacy calls lock their row before INSERT/ON CONFLICT. Taking
  -- another lock there would reverse v2's lock order. Only an unseen original
  -- needs this lock, making concurrent first legacy/v2 receipts serialize.
  if not exists(select 1 from public.apple_subscriptions where original_transaction_id=new.original_transaction_id) then
   perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.original_transaction_id,72451));
  end if;
  return new;
 end if;
 if row(new.product_id,new.plan,new.environment,new.status,new.expires_at,new.auto_renew,new.last_transaction_id,new.last_notification_type)
   is distinct from row(old.product_id,old.plan,old.environment,old.status,old.expires_at,old.auto_renew,old.last_transaction_id,old.last_notification_type) then
  new.transaction_purchased_at:=null;new.transaction_signed_at:=null;
  new.entitlement_signed_at:=null;new.renewal_signed_at:=null;
 end if;
 return new;
end $$;
revoke all on function public.invalidate_unordered_apple_chronology() from public,anon,authenticated,service_role;
drop trigger if exists trg_invalidate_unordered_apple_chronology on public.apple_subscriptions;
create trigger trg_invalidate_unordered_apple_chronology before insert or update of product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,last_notification_type
 on public.apple_subscriptions for each row execute function public.invalidate_unordered_apple_chronology();

create or replace function public._apply_apple_entitlement_snapshot(
  p_org                     uuid,
  p_user                    uuid,
  p_original_transaction_id text,
  p_transaction_id          text,
  p_product_id              text,
  p_plan                    text,
  p_environment             text,
  p_status                  text,
  p_expires_at              timestamptz,
  p_auto_renew              boolean,
  p_notification_type       text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $apply_apple_entitlement$
declare
  v_existing   public.apple_subscriptions%rowtype;
  v_stale      boolean := false;
  v_status     text;
  v_expires    timestamptz;
  v_plan       text;
  v_source     text;
  v_org_source text;
  v_updated    boolean := false;
  v_reason     text := null;
  v_others     integer := 0;
  -- 0046: scratch for the cancellation stamp below. Never returned; the RPC's
  -- jsonb shape is byte-identical to 0026's.
  v_cancel_at  timestamptz;
  v_cancel_why text;
begin
  if p_original_transaction_id is null or btrim(p_original_transaction_id) = '' then
    raise exception 'RP400: original_transaction_id is required';
  end if;
  if p_status is null or p_status not in ('active','grace','expired','revoked','refunded') then
    raise exception 'RP400: status must be active, grace, expired, revoked or refunded';
  end if;

  select * into v_existing
    from apple_subscriptions
   where original_transaction_id = p_original_transaction_id
   for update;

  -- 0021 FINDING 1, sequential case: an EXISTING binding beats a disagreeing
  -- p_org. Unreachable for a brand-new original_transaction_id — `found` is
  -- false until some call has actually inserted a row — which is exactly the
  -- gap 0024 closes below.
  if found
     and v_existing.org_id is not null
     and p_org is not null
     and p_org <> v_existing.org_id
  then
    raise exception 'RP409: This subscription is already used by another account';
  end if;

  -- 0021 FINDING 3: environment is sticky. Sandbox must never move Production
  -- and Production must never be reset by a Sandbox replay, on EITHER path —
  -- functions/apple-subscriptions checked this, POST /me/entitlement did not.
  -- The arrival is recorded; nothing else changes.
  if found
     and v_existing.environment is not null
     and p_environment is not null
     and p_environment <> v_existing.environment
  then
    update apple_subscriptions
       set last_notification_type = coalesce(p_notification_type, last_notification_type),
           updated_at             = now()
     where original_transaction_id = p_original_transaction_id;

    return jsonb_build_object(
      'ok', true,
      'plan', (select o.plan from orgs o where o.id = v_existing.org_id),
      'source', 'apple',
      'expires_at', v_existing.expires_at,
      'status', v_existing.status,
      'org_updated', false,
      'reason', 'environment_mismatch');
  end if;

  -- The public wrappers serialize and order verified snapshots before calling this internal writer.
  v_status  := case when v_stale then v_existing.status     else p_status     end;
  v_expires := case when v_stale then v_existing.expires_at else p_expires_at end;
  v_plan    := case when v_stale then v_existing.plan       else p_plan       end;

  insert into apple_subscriptions as s (
    original_transaction_id, org_id, user_id, product_id, plan, environment,
    status, expires_at, auto_renew, last_transaction_id, last_notification_type,
    created_at, updated_at
  ) values (
    p_original_transaction_id, p_org, p_user, p_product_id, v_plan, p_environment,
    v_status, v_expires, p_auto_renew, p_transaction_id, p_notification_type,
    now(), now()
  )
  on conflict (original_transaction_id) do update set
    -- 0024: STICKY, not "prefer incoming". Two calls that both saw found=false
    -- for a brand-new key (the concurrent-first-bind race — see header) both
    -- reach this upsert; whichever commits durably SECOND now keeps the FIRST
    -- committed org_id instead of overwriting it. On every non-racing path this
    -- is a no-op: a genuine first link has s.org_id = null, so the incoming
    -- value still wins via coalesce's fallback.
    org_id                 = coalesce(s.org_id, excluded.org_id),
    -- user_id is informational only (0019: the ON DELETE SET NULL target) and
    -- decides no entitlement, so it is left exactly as 0019/0021 had it.
    user_id                = coalesce(excluded.user_id, s.user_id),
    -- 0021: on a stale signal the product must not move either, or the row
    -- ends up claiming a product whose plan it is not carrying.
    product_id             = case when v_stale then s.product_id
                                  else coalesce(excluded.product_id, s.product_id) end,
    plan                   = coalesce(excluded.plan, s.plan),
    environment            = coalesce(s.environment, excluded.environment),
    status                 = excluded.status,
    expires_at             = excluded.expires_at,
    auto_renew             = coalesce(excluded.auto_renew, s.auto_renew),
    last_transaction_id    = coalesce(excluded.last_transaction_id, s.last_transaction_id),
    last_notification_type = coalesce(excluded.last_notification_type, s.last_notification_type),
    updated_at             = now()
  returning * into v_existing;

  -- 0024: the re-check the sequential guard above cannot do for a first bind —
  -- it runs on `found`, captured BEFORE this statement wrote anything. This
  -- runs on what the upsert actually persisted. Raising here rolls back this
  -- entire call (including whatever this statement itself just wrote), so a
  -- call that loses the race leaves no trace — not a wrong org_id, not a stray
  -- last_transaction_id — and its caller gets the same RP409 copy as the
  -- sequential case, never a 200 with somebody else's binding.
  if v_existing.org_id is not null and p_org is not null and v_existing.org_id <> p_org then
    raise exception 'RP409: This subscription is already used by another account';
  end if;

  -- ── 0046: THE CANCELLATION FACT ───────────────────────────────────────────
  -- Read from the row the upsert actually persisted, so it is the same state
  -- every other consumer will see. Two arms, both of which the business calls a
  -- cancellation: the subscription ended (expired/revoked/refunded), or the
  -- customer turned auto-renew OFF while still entitled. A row first SEEN in
  -- one of those states counts as the transition — Apple's first word about a
  -- subscription can already be a REFUND, and "the first time this server knew"
  -- is the only cancellation date a webhook consumer can honestly claim.
  -- `cancelled_at is null`
  -- in both the IF and the UPDATE's WHERE: the FIRST transition wins and no
  -- later signal — including a duplicate EXPIRED — can move the date.
  -- The win-back arm clears both, so the columns always describe the CURRENT
  -- cancellation; the header says what that costs admin_churn() and why the
  -- transition itself is not recorded here.
  if (v_existing.status in ('expired','revoked','refunded') or v_existing.auto_renew is false)
     and v_existing.cancelled_at is null then
    update apple_subscriptions
       set cancelled_at  = now(),
           cancel_reason = left(coalesce(
             nullif(btrim(p_notification_type), ''),
             case when v_existing.status in ('expired','revoked','refunded')
                  then 'status_' || v_existing.status
                  else 'auto_renew_off' end), 80)
     where original_transaction_id = v_existing.original_transaction_id
       and cancelled_at is null
    returning cancelled_at, cancel_reason into v_cancel_at, v_cancel_why;
    v_existing.cancelled_at  := v_cancel_at;
    v_existing.cancel_reason := v_cancel_why;
  elsif v_existing.status = 'active' and v_existing.auto_renew is true
        and v_existing.cancelled_at is not null then
    update apple_subscriptions
       set cancelled_at = null, cancel_reason = null
     where original_transaction_id = v_existing.original_transaction_id;
    v_existing.cancelled_at  := null;
    v_existing.cancel_reason := null;
  end if;

  -- No org yet (a notification that beat the device here): the row is stored
  -- and POST /me/entitlement will replay it once the app links the workspace.
  if v_existing.org_id is null then
    return jsonb_build_object(
      'ok', true, 'plan', null, 'source', null, 'expires_at', v_expires,
      'status', v_status, 'org_updated', false, 'reason', 'no_org_linked');
  end if;

  select o.plan_source into v_org_source from orgs o where o.id = v_existing.org_id for update;
  if not found then
    return jsonb_build_object(
      'ok', true, 'plan', null, 'source', null, 'expires_at', v_expires,
      'status', v_status, 'org_updated', false, 'reason', 'org_missing');
  end if;

  -- RULE 2 (0019): an owner-granted plan is Apple-proof, in both directions.
  if v_org_source = 'manual' then
    return jsonb_build_object(
      'ok', true, 'plan', (select plan from orgs where id = v_existing.org_id),
      'source', 'manual', 'expires_at', v_expires, 'status', v_status,
      'org_updated', false, 'reason', 'manual_plan');
  end if;

  if v_stale then
    return jsonb_build_object(
      'ok', true, 'plan', (select plan from orgs where id = v_existing.org_id),
      'source', 'apple', 'expires_at', v_expires, 'status', v_status,
      'org_updated', false, 'reason', 'stale_notification');
  end if;

  if v_status in ('active','grace') then
    update orgs
       set plan             = coalesce(v_plan, plan),
           plan_source      = 'apple',
           plan_expires_at  = v_expires,
           apple_product_id = coalesce(v_existing.product_id, apple_product_id)
     where id = v_existing.org_id;
    v_updated := true;
    v_source  := 'apple';
  else
    -- A lapse only downgrades when nothing else is still paying for this org.
    -- 0021: `and x.expires_at > now()` as well, so a row that is still marked
    -- active only because its own EXPIRED was never delivered cannot hold an
    -- org on a paid plan forever. Rows with no expiry at all still count, the
    -- same way they did before.
    select count(*) into v_others
      from apple_subscriptions x
     where x.org_id = v_existing.org_id
       and x.original_transaction_id <> v_existing.original_transaction_id
       and x.status in ('active','grace')
       and (x.expires_at is null or x.expires_at > now() - interval '16 days');

    if v_others > 0 then
      v_reason := 'another_subscription_active';
    else
      update orgs
         set plan             = 'free',
             plan_source      = 'apple',
             plan_expires_at  = v_expires,
             apple_product_id = coalesce(v_existing.product_id, apple_product_id)
       where id = v_existing.org_id;
      v_updated := true;
    end if;
    v_source := 'apple';
  end if;

  return jsonb_build_object(
    'ok', true,
    'plan', (select plan from orgs where id = v_existing.org_id),
    'source', coalesce(v_source, 'apple'),
    'expires_at', v_expires,
    'status', v_status,
    'org_updated', v_updated,
    'reason', v_reason
  );
end;
$apply_apple_entitlement$;

-- Never expose the unordered writer, including to the service role. Only the
-- chronology wrapper and later legacy-cutover wrapper can reach it as owner.
revoke execute on function public._apply_apple_entitlement_snapshot(
  uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text
) from public,anon,authenticated,service_role;


create or replace function public.apply_apple_entitlement_v2(
  p_org uuid,p_user uuid,p_original_transaction_id text,p_transaction_id text,
  p_product_id text,p_plan text,p_environment text,p_status text,
  p_expires_at timestamptz,p_auto_renew boolean,p_notification_type text,
  p_transaction_purchased_at timestamptz,p_transaction_signed_at timestamptz,
  p_event_signed_at timestamptz,p_renewal_signed_at timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.apple_subscriptions; signed_at timestamptz;
  r jsonb; stale boolean:=false; next_renew boolean:=p_auto_renew; reason text:='stale_notification';
  next_status text:=p_status;next_expiry timestamptz:=p_expires_at;
begin
  if p_original_transaction_id is null or btrim(p_original_transaction_id)='' or
     p_transaction_id is null or btrim(p_transaction_id)='' or
     p_transaction_purchased_at is null or p_transaction_signed_at is null or
     p_transaction_purchased_at>p_transaction_signed_at or
     p_transaction_signed_at>now()+interval '5 minutes' or
     p_event_signed_at>now()+interval '5 minutes' or
     p_renewal_signed_at>now()+interval '5 minutes' or
     not pg_catalog.isfinite(p_transaction_purchased_at) or not pg_catalog.isfinite(p_transaction_signed_at) or
     (p_event_signed_at is not null and not pg_catalog.isfinite(p_event_signed_at)) or
     (p_renewal_signed_at is not null and not pg_catalog.isfinite(p_renewal_signed_at)) then
    raise exception 'RP400: Verified Apple transaction chronology is required';
  end if;
  if p_status is null or p_status not in('active','grace','expired','refunded','revoked') then
    raise exception 'RP400: status must be active, grace, expired, revoked or refunded';
  end if;
  signed_at:=greatest(p_transaction_signed_at,p_event_signed_at);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_original_transaction_id,72451));
  select * into s from public.apple_subscriptions where original_transaction_id=p_original_transaction_id for update;
  if found then
    if p_org is not null and s.org_id is not null and p_org<>s.org_id then
      raise exception 'RP409: This subscription is already used by another account';
    end if;
    if s.environment is not null and p_environment is distinct from s.environment then
      return jsonb_build_object('ok',true,'plan',(select plan from public.orgs where id=s.org_id),
        'source','apple','expires_at',s.expires_at,'status',s.status,'org_updated',false,'reason','environment_mismatch');
    end if;
    if s.transaction_purchased_at is null then
      -- An existing row has no trusted purchase chronology. Restore its exact
      -- current transaction, or admit a purchase made after its last server
      -- receipt. Historical product/transaction changes remain fenced. A fresh
      -- signature on an old receipt does not prove a new purchase.
      if p_transaction_id is distinct from s.last_transaction_id or p_product_id is distinct from s.product_id then
        stale:=p_transaction_purchased_at<=s.updated_at;
        reason:='chronology_unavailable';
      elsif s.status in('refunded','revoked') and p_status in('active','grace') then
        stale:=p_notification_type is distinct from 'REFUND_REVERSED' or
          p_event_signed_at is null or p_event_signed_at<=s.updated_at;
        reason:='chronology_unavailable';
      elsif p_status in('active','grace','expired') and p_expires_at<s.expires_at then
        stale:=true; reason:='chronology_unavailable';
      end if;
    else
      stale:=p_transaction_purchased_at<s.transaction_purchased_at;
      if p_transaction_purchased_at=s.transaction_purchased_at then
        if p_transaction_id is distinct from s.last_transaction_id then
          raise exception 'RP409: Equal purchase dates require the current Apple transaction';
        end if;
        if p_product_id is distinct from s.product_id then
          raise exception 'RP409: An Apple transaction cannot change its product';
        end if;
        -- A newer signed outer notification is itself Apple's snapshot. It
        -- may carry an unchanged transaction JWS alongside newer renewal data.
        stale:=stale or signed_at<s.entitlement_signed_at or
          (p_transaction_signed_at<s.transaction_signed_at and
            (p_event_signed_at is null or p_event_signed_at<s.entitlement_signed_at));
        -- Identical signed chronology cannot reverse a terminal decision.
        stale:=stale or (signed_at=s.entitlement_signed_at and s.status in('refunded','revoked') and p_status in('active','grace'));
        -- A re-signed historical transaction or later metadata event is not a
        -- refund reversal. Only Apple's explicit newer REFUND_REVERSED may
        -- restore this same refunded purchase; a genuinely newer purchase is
        -- handled by the purchase-date branch above.
        stale:=stale or (s.status in('refunded','revoked') and p_status in('active','grace') and
          (p_notification_type is distinct from 'REFUND_REVERSED' or
            p_event_signed_at is null or p_event_signed_at<=s.entitlement_signed_at));
      end if;
    end if;
    if stale then
      -- A device may be linking a newer pending notification with an older
      -- transaction. Bind and enforce the stored snapshot, never the replay.
      if s.org_id is null and p_org is not null then
        r:=public._apply_apple_entitlement_snapshot(p_org,p_user,p_original_transaction_id,s.last_transaction_id,
          s.product_id,s.plan,s.environment,s.status,s.expires_at,s.auto_renew,s.last_notification_type);
        return r||jsonb_build_object('reason',reason);
      end if;
      return jsonb_build_object('ok',true,'plan',(select plan from public.orgs where id=s.org_id),
        'source','apple','expires_at',s.expires_at,'status',s.status,'org_updated',false,'reason',reason);
    end if;
    if p_renewal_signed_at is null or p_renewal_signed_at<s.renewal_signed_at then next_renew:=null; end if;
    if p_event_signed_at is null and p_transaction_id=s.last_transaction_id and
       s.status='grace' and s.expires_at>now() and p_status='expired' and
       (p_renewal_signed_at is null or p_renewal_signed_at<s.renewal_signed_at) then
      -- Transaction-only restores cannot assert that a known, still-live
      -- renewal grace window ended. A newer outer EXPIRED is authoritative.
      next_status:=s.status;next_expiry:=s.expires_at;
    end if;
  end if;
  r:=public._apply_apple_entitlement_snapshot(p_org,p_user,p_original_transaction_id,p_transaction_id,
    p_product_id,p_plan,p_environment,next_status,next_expiry,next_renew,p_notification_type);
  update public.apple_subscriptions set transaction_purchased_at=p_transaction_purchased_at,
    transaction_signed_at=case when p_transaction_purchased_at=s.transaction_purchased_at
      then greatest(s.transaction_signed_at,p_transaction_signed_at) else p_transaction_signed_at end,
    entitlement_signed_at=signed_at,
    renewal_signed_at=case when p_renewal_signed_at is null then s.renewal_signed_at
      else greatest(s.renewal_signed_at,p_renewal_signed_at) end
    where original_transaction_id=p_original_transaction_id;
  return r;
end $$;

revoke execute on function public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz) to service_role;
comment on function public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz) is
  'Apply verified Apple snapshots in purchase and signed-event order. Serialize first-bind and replay under one advisory lock. No expiry-based product ordering.';
