-- 0050: a brokerage can finally buy this (2026-09-13).
--
-- THE PROBLEM, read live from production before writing a line of this:
--
--     plan_entitlements   team   seats = 2   25 renders/month   $249
--
-- `team` is the largest thing that exists, and org_seats_allowed() reads
-- plan_entitlements.seats directly, so the third person to accept an invite
-- into a brokerage is refused by 0033 with
--
--     RP402: this team is full — every seat on its plan is taken
--
-- A 400-agent brokerage is not an expensive customer today. It is an
-- impossible one. Migration 0048 already shipped every mechanism such a
-- customer needs — create_org_invites_bulk, the org_seat_events ledger,
-- brokerage_overview, compliance_audit — and all of it has been sitting
-- behind a two-seat ceiling since the day it deployed.
--
-- ── WHY A CONTRACT TABLE AND NOT ANOTHER plan_entitlements ROW ──────────────
-- plan_entitlements is keyed by plan name and carries ONE fixed seat count.
-- Brokerage pricing is per-seat and volume-banded, so every deal has a
-- different seat count and a different price. One more row cannot express
-- that; a row per signed brokerage can. brokerage_contracts is therefore a
-- commercial object, not a config table: it is the signed deal, it carries
-- who agreed what and when, and it is the thing an invoice is generated from.
--
-- ── THE BAND (the owner's call, 13 Sep 2026) ───────────────────────────────
--     10-49 seats    $49/seat/month
--     50-199 seats   $35/seat/month
--     200+ seats     $25/seat/month
-- Under 10 seats is not a brokerage — that is `team`, on the App Store.
-- brokerage_price_cents() is the single source of that ladder so a quote, an
-- invoice and a renewal cannot disagree about it.
--
-- ── ALLOWANCES ARE PER SEAT AND POOLED ─────────────────────────────────────
-- The contract stores a PER-SEAT allowance; org_entitlement() multiplies it by
-- the seat count and hands back one pooled monthly allowance for the whole
-- office. That is deliberate and it is what protects the margin: a brokerage
-- has never had every agent active in the same month, and the agents who do
-- not shoot this month pay for the ones who shoot four times. It also means
-- the broker never has to administer per-agent quotas, which is the thing
-- that kills these deals in month two.
--
-- Defaults are sized to what an agent actually lists (3 tours), NOT to what
-- Pro gives one paying individual (10). At 400 seats the pooled allowance is
-- 1,200 tours a month, which no 400-agent office has ever used.
--
-- ── THE SPEND CEILING IS THE REAL GUARD ────────────────────────────────────
-- cogs_ceiling_cents is enforced by 0024's spend lock, and this migration
-- computes it from the contract rather than letting it be guessed:
--   per seat = renders x 240c + photo_edits x 4c + reels x 24c + aerials x 80c
-- So a signed contract's worst-case COGS is a number that exists in the
-- database before the first agent is invited, and the ledger stops spending
-- when it is reached. Nobody has to notice.
--
-- ── OFF THE APP STORE, ON PURPOSE ──────────────────────────────────────────
-- Nothing here creates an in-app purchase and nothing here touches App Store
-- Connect. Apple takes 15-30%, IAP cannot do invoiced seat billing, and no
-- broker signs a 400-seat contract against a personal Apple ID. plan_source
-- for these orgs is 'brokerage', which effective_plan() treats as authoritative
-- and which the Apple receipt path in 0026 never writes.
--
-- ── IDEMPOTENT ─────────────────────────────────────────────────────────────
-- Tables `if not exists`, constraints dropped before added, functions
-- `create or replace`, the seed row upserted. CI applies this file twice.

-- ── 1. plan vocabulary ──────────────────────────────────────────────────────
-- Every CHECK that enumerates plans has to learn the new name, or an UPDATE to
-- 'brokerage' fails at the last moment with a constraint violation.

alter table public.orgs drop constraint if exists orgs_plan_check;
alter table public.orgs add constraint orgs_plan_check
  check (plan in ('trial','free','solo','starter','pro','team','brokerage'));

-- plan_source too. Caught by the test harness before this went anywhere near
-- production: the org UPDATE at the end of set_brokerage_contract wrote
-- plan_source='brokerage' into a CHECK that allowed only manual/trial/apple,
-- and the whole transaction rolled back. 'brokerage' has to be its own source
-- and not 'manual', because 0026's Apple receipt path and every report that
-- asks "where did this revenue come from" key off this column.
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'orgs_plan_source_check') then
    alter table public.orgs drop constraint orgs_plan_source_check;
  end if;
  alter table public.orgs add constraint orgs_plan_source_check
    check (plan_source is null or plan_source in ('manual','trial','apple','brokerage'));
end $$;

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'ai_routes_min_plan_check') then
    alter table public.ai_routes drop constraint ai_routes_min_plan_check;
    alter table public.ai_routes add constraint ai_routes_min_plan_check
      check (min_plan in ('free','trial','starter','solo','pro','team','brokerage'));
  end if;
end $$;

-- The floor row. org_entitlement() overwrites every number on it from the
-- contract, so these values are only what a 'brokerage' org would get if its
-- contract were somehow missing — deliberately equal to `team`, never zero,
-- because a paying brokerage that loses its contract row must degrade to a
-- working product and not to nothing.
insert into public.plan_entitlements
  (plan, renders_per_month, photo_edits_per_month, reels_per_month,
   aerials_per_month, topaz_per_month, seats, cogs_ceiling_cents, price_cents)
values
  ('brokerage', 25, 400, 25, 8, 2, 2, 6000, 0)
on conflict (plan) do update set
  renders_per_month     = excluded.renders_per_month,
  photo_edits_per_month = excluded.photo_edits_per_month,
  reels_per_month       = excluded.reels_per_month,
  aerials_per_month     = excluded.aerials_per_month,
  topaz_per_month       = excluded.topaz_per_month,
  seats                 = excluded.seats,
  cogs_ceiling_cents    = excluded.cogs_ceiling_cents,
  price_cents           = excluded.price_cents;

-- ── 2. the signed deal ──────────────────────────────────────────────────────

create table if not exists public.brokerage_contracts (
  org_id                uuid primary key references public.orgs(id) on delete cascade,
  -- Commercials
  seats                 integer not null check (seats >= 10 and seats <= 100000),
  price_cents_per_seat  integer not null check (price_cents_per_seat >= 0),
  -- Per-seat monthly allowance; org_entitlement multiplies by seats.
  renders_per_seat      integer not null default 3  check (renders_per_seat     between 0 and 1000),
  photo_edits_per_seat  integer not null default 40 check (photo_edits_per_seat between 0 and 10000),
  reels_per_seat        integer not null default 3  check (reels_per_seat       between 0 and 1000),
  aerials_per_seat      integer not null default 1  check (aerials_per_seat     between 0 and 1000),
  topaz_per_seat        integer not null default 0  check (topaz_per_seat       between 0 and 1000),
  -- Lifecycle. `status` is the whole truth: only 'active' grants anything.
  status                text not null default 'active'
                        check (status in ('pending','active','suspended','ended')),
  starts_at             timestamptz not null default now(),
  ends_at               timestamptz,
  -- Who this is, for an invoice and for a human reading the table
  legal_name            text,
  billing_email         text,
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint brokerage_contracts_window check (ends_at is null or ends_at > starts_at)
);

comment on table public.brokerage_contracts is
  'One row per signed brokerage. Grants seats and a POOLED monthly allowance '
  '(per-seat numbers x seats) that org_entitlement() returns and '
  'org_seats_allowed() reads. Sold direct and invoiced — never an in-app '
  'purchase. Only status=''active'' inside [starts_at, ends_at) grants anything.';

create index if not exists brokerage_contracts_active_idx
  on public.brokerage_contracts (status, starts_at, ends_at);

alter table public.brokerage_contracts enable row level security;
revoke all on public.brokerage_contracts from public, anon, authenticated;
grant select, insert, update on public.brokerage_contracts to service_role;

-- ── 3. the price ladder, in one place ───────────────────────────────────────

create or replace function public.brokerage_price_cents(p_seats integer)
returns integer language sql immutable set search_path = public as $$
  select case
           when p_seats is null or p_seats < 10 then null
           when p_seats < 50  then 4900
           when p_seats < 200 then 3500
           else 2500
         end::integer;
$$;

comment on function public.brokerage_price_cents(integer) is
  'The volume band, per seat per month, in cents: 10-49 -> $49, 50-199 -> $35, '
  '200+ -> $25. NULL under 10 seats, which is `team` territory and belongs on '
  'the App Store. The only definition of the ladder — a quote, an invoice and '
  'a renewal all read it here.';

-- Worst-case monthly COGS for a contract, from the committed rate card
-- (_shared/ledger.ts APP_AI_UNIT_CENTS): a render 240c, a photo edit 4c,
-- a reel 24c, an aerial 80c. This becomes cogs_ceiling_cents, which 0024's
-- spend lock enforces, so the exposure on a signed deal is a number that
-- exists before the first agent is invited.
create or replace function public.brokerage_cogs_ceiling_cents(c public.brokerage_contracts)
returns integer language sql immutable set search_path = public as $$
  select (c.seats * (c.renders_per_seat * 240
                   + c.photo_edits_per_seat * 4
                   + c.reels_per_seat * 24
                   + c.aerials_per_seat * 80))::integer;
$$;

-- ── 4. is this org on a live contract? ──────────────────────────────────────

create or replace function public.brokerage_contract(p_org uuid)
returns public.brokerage_contracts language sql stable set search_path = public as $$
  select c.* from public.brokerage_contracts c
   where c.org_id = p_org
     and c.status = 'active'
     and c.starts_at <= now()
     and (c.ends_at is null or c.ends_at > now())
   limit 1;
$$;

-- ── 5. effective_plan: a live contract outranks everything ──────────────────
-- Re-stated whole from 0019 with ONE branch added at the top, because a
-- brokerage org must not be demoted to 'free' by the Apple grace-period rule
-- below it — it has no Apple subscription and never will.

create or replace function public.effective_plan(p_org uuid)
returns text language sql stable set search_path = public as $$
  select case
           when exists (
             select 1 from public.brokerage_contracts c
              where c.org_id = p_org and c.status = 'active'
                and c.starts_at <= now()
                and (c.ends_at is null or c.ends_at > now()))
             then 'brokerage'
           when o.plan = 'trial' and o.trial_ends_at is not null and o.trial_ends_at < now()
             then 'free'
           when o.plan_source = 'apple'
                and o.plan_expires_at is not null
                and o.plan_expires_at < now() - interval '16 days'
             then 'free'
           else coalesce(o.plan, 'trial')
         end
    from orgs o where o.id = p_org;
$$;

revoke execute on function public.effective_plan(uuid) from public, anon;
grant  execute on function public.effective_plan(uuid) to authenticated, service_role;

-- ── 6. seats ────────────────────────────────────────────────────────────────
-- Restated from 0032 with the contract consulted first. This one function is
-- what turns RP402 at the third agent into 400 agents joining.

create or replace function public.org_seats_allowed(p_org uuid)
returns integer language sql stable set search_path = public as $$
  select coalesce(
    (select c.seats from public.brokerage_contracts c
      where c.org_id = p_org and c.status = 'active'
        and c.starts_at <= now()
        and (c.ends_at is null or c.ends_at > now())
      limit 1),
    (select coalesce(e.seats, 1) from plan_entitlements e
      where e.plan = public.effective_plan(p_org)),
    1
  )::integer;
$$;

revoke execute on function public.org_seats_allowed(uuid) from anon;

-- ── 7. the pooled allowance ─────────────────────────────────────────────────
-- Restated from 0044 with the contract layered ON TOP of the industry
-- override, because a brokerage's allowance is the contract's and nothing
-- else: a brokerage that happens to be tagged space_type='venue' must not have
-- its 1,200 pooled tours cut to the venue trial's 1.

create or replace function public.org_entitlement(p_org uuid)
returns public.plan_entitlements language plpgsql stable set search_path = public as $$
declare
  v_base public.plan_entitlements;
  v_over public.plan_entitlement_overrides;
  v_con  public.brokerage_contracts;
begin
  v_base := plan_entitlement(effective_plan(p_org));

  select o.* into v_over
    from plan_entitlement_overrides o
    join orgs g on g.id = p_org
   where o.plan = v_base.plan and o.space_type = g.space_type;
  if found then
    v_base.renders_per_month     := coalesce(v_over.renders_per_month,     v_base.renders_per_month);
    v_base.photo_edits_per_month := coalesce(v_over.photo_edits_per_month, v_base.photo_edits_per_month);
    v_base.reels_per_month       := coalesce(v_over.reels_per_month,       v_base.reels_per_month);
    v_base.aerials_per_month     := coalesce(v_over.aerials_per_month,     v_base.aerials_per_month);
    v_base.topaz_per_month       := coalesce(v_over.topaz_per_month,       v_base.topaz_per_month);
    v_base.seats                 := coalesce(v_over.seats,                 v_base.seats);
    v_base.cogs_ceiling_cents    := coalesce(v_over.cogs_ceiling_cents,    v_base.cogs_ceiling_cents);
  end if;

  -- LAST, so it wins. A signed contract is the deal; nothing above it applies.
  v_con := brokerage_contract(p_org);
  if v_con.org_id is not null then
    v_base.plan                  := 'brokerage';
    v_base.seats                 := v_con.seats;
    v_base.renders_per_month     := v_con.seats * v_con.renders_per_seat;
    v_base.photo_edits_per_month := v_con.seats * v_con.photo_edits_per_seat;
    v_base.reels_per_month       := v_con.seats * v_con.reels_per_seat;
    v_base.aerials_per_month     := v_con.seats * v_con.aerials_per_seat;
    v_base.topaz_per_month       := v_con.seats * v_con.topaz_per_seat;
    v_base.cogs_ceiling_cents    := brokerage_cogs_ceiling_cents(v_con);
    v_base.price_cents           := v_con.seats * v_con.price_cents_per_seat;
  end if;

  return v_base;
end;
$$;

-- ── 8. signing a deal ───────────────────────────────────────────────────────
-- One RPC so a contract is never hand-edited into the table. It sets the org's
-- plan and plan_source in the SAME transaction as the contract row, because an
-- org carrying a contract while still reading plan='trial' is the kind of
-- half-state that produces a support ticket on day one.
--
-- p_price_cents_per_seat NULL means "use the band" — the normal case. Passing
-- a number overrides it for a negotiated deal, and the override is recorded on
-- the row rather than living in somebody's inbox.

create or replace function public.set_brokerage_contract(
  p_org                  uuid,
  p_seats                integer,
  p_legal_name           text    default null,
  p_billing_email        text    default null,
  p_price_cents_per_seat integer default null,
  p_renders_per_seat     integer default 3,
  p_photo_edits_per_seat integer default 40,
  p_reels_per_seat       integer default 3,
  p_aerials_per_seat     integer default 1,
  p_status               text    default 'active',
  p_ends_at              timestamptz default null,
  p_notes                text    default null
) returns public.brokerage_contracts
language plpgsql security definer set search_path = public as $$
declare
  v_price integer;
  v_row   public.brokerage_contracts;
begin
  if not exists (select 1 from orgs where id = p_org) then
    raise exception 'RP404: no such org %', p_org;
  end if;
  if p_seats is null or p_seats < 10 then
    raise exception 'RP400: a brokerage contract starts at 10 seats — % is `team` territory, which sells on the App Store', coalesce(p_seats, 0);
  end if;

  v_price := coalesce(p_price_cents_per_seat, brokerage_price_cents(p_seats));
  if v_price is null then
    raise exception 'RP400: no band covers % seats and no price was given', p_seats;
  end if;

  insert into public.brokerage_contracts as c
    (org_id, seats, price_cents_per_seat, renders_per_seat, photo_edits_per_seat,
     reels_per_seat, aerials_per_seat, status, ends_at, legal_name, billing_email, notes)
  values
    (p_org, p_seats, v_price, p_renders_per_seat, p_photo_edits_per_seat,
     p_reels_per_seat, p_aerials_per_seat, p_status, p_ends_at, p_legal_name, p_billing_email, p_notes)
  on conflict (org_id) do update set
    seats                = excluded.seats,
    price_cents_per_seat = excluded.price_cents_per_seat,
    renders_per_seat     = excluded.renders_per_seat,
    photo_edits_per_seat = excluded.photo_edits_per_seat,
    reels_per_seat       = excluded.reels_per_seat,
    aerials_per_seat     = excluded.aerials_per_seat,
    status               = excluded.status,
    ends_at              = excluded.ends_at,
    legal_name           = coalesce(excluded.legal_name,    c.legal_name),
    billing_email        = coalesce(excluded.billing_email, c.billing_email),
    notes                = coalesce(excluded.notes,         c.notes),
    updated_at           = now()
  returning * into v_row;

  -- Same transaction, so the org can never carry a contract while reading as
  -- a trial. An ended or suspended contract hands the org back to `free`,
  -- which is the honest state for somebody who stopped paying.
  update orgs
     set plan        = case when v_row.status = 'active' then 'brokerage' else 'free' end,
         plan_source = case when v_row.status = 'active' then 'brokerage' else plan_source end
   where id = p_org;

  return v_row;
end;
$$;

comment on function public.set_brokerage_contract is
  'Sign, amend or end a brokerage contract and move the org onto it in one '
  'transaction. Price defaults to brokerage_price_cents(seats). Under 10 seats '
  'is refused — that is `team`. Service role only.';

revoke execute on function public.set_brokerage_contract(uuid,integer,text,text,integer,integer,integer,integer,integer,text,timestamptz,text)
  from public, anon, authenticated;
grant  execute on function public.set_brokerage_contract(uuid,integer,text,text,integer,integer,integer,integer,integer,text,timestamptz,text)
  to service_role;

-- ── 9. what a deal is worth, before it is signed ────────────────────────────
-- A quote is arithmetic, and arithmetic done in a spreadsheet drifts from what
-- the database will actually grant. This returns the same numbers the product
-- will enforce, so the sheet cannot disagree with the software.

create or replace function public.brokerage_quote(
  p_seats integer,
  p_renders_per_seat integer default 3,
  p_photo_edits_per_seat integer default 40,
  p_reels_per_seat integer default 3,
  p_aerials_per_seat integer default 1
) returns table (
  seats integer, price_cents_per_seat integer, mrr_cents bigint, arr_cents bigint,
  pooled_renders integer, pooled_photo_edits integer, pooled_reels integer, pooled_aerials integer,
  worst_case_cogs_cents bigint, worst_case_margin_pct numeric
) language sql stable set search_path = public as $$
  with b as (
    select p_seats as s, brokerage_price_cents(p_seats) as pps
  ), m as (
    select s, pps,
           (s::bigint * pps) as mrr,
           (s * (p_renders_per_seat * 240 + p_photo_edits_per_seat * 4
               + p_reels_per_seat * 24 + p_aerials_per_seat * 80))::bigint as cogs
      from b
  )
  select s, pps, mrr, mrr * 12,
         s * p_renders_per_seat, s * p_photo_edits_per_seat,
         s * p_reels_per_seat, s * p_aerials_per_seat,
         cogs,
         case when mrr > 0 then round(((mrr - cogs)::numeric / mrr) * 100, 1) else null end
    from m;
$$;

grant execute on function public.brokerage_quote(integer,integer,integer,integer,integer) to service_role;
