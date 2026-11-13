-- Switch the free trial to the per-user allowance (owner decision 2026-11-12).
--
-- Requires 20261112223000_trial_per_user_allowance. This file changes rows, not
-- code:
--   1. records a standing trial hosting record (basis per_user_allowance, no
--      end date) copied from the supplier tariff and account reserves of the
--      record the trial template uses today;
--   2. points subscription_trial_media_template at it;
--   3. sets subscription_trial_admission_policy.mode = 'per_user'.
--
-- From that moment a new subscriber's trial is no longer refused by the
-- expired sponsor allocation, the first-100 pool, its 2026-11-22 last-hold
-- date, or the 24-hour supplier attestation. Each user is bounded by
-- subscription_trial_config (photo edits) and per_user_budget_cents.
--
-- It does nothing on a database that has no enabled trial hosting template (a
-- fresh schema), and nothing when the mode is already per_user, so it is safe
-- to apply twice. The first-100 pool, its schedules, the card authority and
-- app_config.trial_sponsor_pool are left untouched for audit and for rollback.
--
-- Rollback (restores today's pool rules; holds taken meanwhile still convert):
--   update public.subscription_trial_admission_policy
--      set mode='pool',updated_at=now(),note='rolled back to pool rules' where singleton;
--   update public.subscription_trial_media_template
--      set account_reserve_ref='card-trial-media-2026-10' where singleton;
-- One transaction, however the file is applied: a refused function pin leaves
-- nothing behind.
begin;

do $activate$
declare pol public.subscription_trial_admission_policy;
 t public.subscription_trial_media_template;a public.media_account_reserves;
 standing constant text:='per-user-trial-hosting-20261112';
begin
 if to_regclass('public.subscription_trial_admission_policy') is null
  or to_regprocedure('public.trial_spend_alerts()') is null
  or to_regprocedure('public.subscription_trial_per_user_readiness()') is null then
  raise exception 'trial per-user activation: apply 20261112223000_trial_per_user_allowance first';
 end if;
 -- Same order as prepare_subscription_trial_purchase: admission lock first.
 perform pg_advisory_xact_lock(hashtextextended('subscription-trial-admission',72456));
 select * into pol from public.subscription_trial_admission_policy where singleton for update;
 if pol.singleton is null then
  raise exception 'trial per-user activation: the policy row is missing';
 end if;
 if pol.mode='per_user' then
  raise notice 'trial per-user activation: already active';return;
 end if;
 select * into t from public.subscription_trial_media_template where singleton for update;
 if t.enabled is distinct from true or t.account_reserve_ref is null or t.evidence_sha256 is null then
  raise notice 'trial per-user activation skipped: this database has no enabled trial hosting template (fresh schema). Mode stays pool.';
  return;
 end if;
 select * into a from public.media_account_reserves where receipt_ref=t.account_reserve_ref;
 if a.receipt_ref is null then
  raise exception 'trial per-user activation: the trial template names a hosting record that does not exist';
 end if;
 if a.cash_source<>'per_user_allowance' then
  insert into public.media_account_reserves(receipt_ref,account_id,cash_source,cash_evidence_sha256,
   starts_at,ends_at,cash_paid_cents,tariff,reserves,allocated_org_cents,
   card_authority_id,card_authorized_cents,card_evidence_sha256)
  values(standing,a.account_id,'per_user_allowance',null,
   date_trunc('day',now()),'infinity'::timestamptz,0,a.tariff,a.reserves,0,
   null,0,pol.evidence_sha256)
  on conflict(receipt_ref) do nothing;
  if not exists(select 1 from public.media_account_reserves r
    where r.receipt_ref=standing and r.cash_source='per_user_allowance'
      and r.account_id=a.account_id and r.tariff=a.tariff and r.ends_at='infinity'::timestamptz) then
   raise exception 'trial per-user activation: the standing hosting record % exists with different terms',standing;
  end if;
  update public.subscription_trial_media_template set account_reserve_ref=standing where singleton;
 end if;
 update public.subscription_trial_admission_policy
  set mode='per_user',updated_at=now(),
   note='Per-user trial allowance active since '||to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI"Z"')
    ||' (owner decision 2026-11-12). Previous hosting record: '||a.receipt_ref||'.'
  where singleton;
 raise notice 'trial per-user activation: mode=per_user, hosting record=%',
  (select account_reserve_ref from public.subscription_trial_media_template where singleton);
end $activate$;

commit;
