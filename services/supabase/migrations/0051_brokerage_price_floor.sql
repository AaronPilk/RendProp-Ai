-- 0051: anchor high, and put the floor where it cannot be crossed by accident
-- (2026-09-13, same day as 0050).
--
-- Two owner calls, in order, both correct:
--
--   "it needs to be min $50 an agent per month thats nothing in reality"
--   "we can make more money id rather them tell me no its too much and me be
--    able to negotiate"
--
-- 0050 shipped a ladder bottoming out at $25/seat. That was under-priced
-- against everything this sits next to — an agent spends on the order of
-- $9,500 a year running their business, the outsourced listing video this
-- replaces runs several hundred dollars PER PROPERTY on a scheduled visit, and
-- per-seat real-estate software in this market runs $69-$179 an agent. At $25
-- the number argued against the product.
--
-- ── WHY LIST HIGH AND NEGOTIATE DOWN ───────────────────────────────────────
-- A price can always come down and can never go up. A broker who says "that is
-- too much" has told you something and left the conversation open; a broker who
-- says yes in four seconds has told you the same thing and closed it. So the
-- LIST price is set near the top of the defensible range — high enough to be
-- negotiated, not so high it gets dismissed instead of countered — and the
-- floor is stored separately, in the database, where a long call at 6pm cannot
-- erode it.
--
--       10-49 seats    $25-49  ->  $149
--      50-199 seats            ->  $119
--        200+ seats            ->   $89     <- LIST
--       every band     floor       $50      <- never below this
--
-- The gap between list and floor IS the negotiating room, and it is deliberate:
-- at 200+ seats there is a 44% concession available that still clears the
-- floor. A discount that large feels like a win to the person receiving it,
-- which is the point of having it to give.
--
-- ── THE FLOOR IS ENFORCED, NOT REMEMBERED ──────────────────────────────────
-- set_brokerage_contract() already accepted an explicit per-seat price so a
-- negotiated deal could be recorded. It accepted ANY price, including zero.
-- It now refuses anything under $50 a seat and names the floor in the error.
-- p_allow_below_floor exists for the deal that genuinely warrants it — a
-- design partner, a pilot — but it has to be asked for by name, so nobody
-- crosses the floor without deciding to.
--
-- ── WHAT IT DOES TO THE NUMBERS ────────────────────────────────────────────
-- Worst-case COGS is unchanged at $10.32 a seat a month (3 tours, 40 photo
-- edits, 3 reel clips, 1 aerial at the committed rate card), so all of it is
-- margin:
--
--    400 seats at list   $35,600/mo   ARR $427,200   worst-case margin 88.4%
--    400 seats at floor  $20,000/mo   ARR $240,000   worst-case margin 79.4%
--    (0050 shipped this at $10,000/mo and 58.7%)
--
-- Allowances are deliberately NOT raised with the price. They track what an
-- agent actually lists, not what a seat costs. Pooling is what makes the offer
-- generous; inflating per-seat numbers to justify a price is how a COGS
-- ceiling stops meaning anything.
--
-- ── ALREADY-SIGNED DEALS ARE SAFE ──────────────────────────────────────────
-- A contract keeps price_cents_per_seat on its own row — which is exactly why
-- that column exists instead of the price being looked up live — so nothing
-- here re-prices an agreed deal. Amending a contract without passing a price
-- picks up the new ladder, which is the correct behaviour at renewal.
--
-- Idempotent: create or replace only.

-- ── 1. the floor, in one place ──────────────────────────────────────────────

create or replace function public.brokerage_price_floor_cents()
returns integer language sql immutable set search_path = public as $$
  select 5000::integer;
$$;

comment on function public.brokerage_price_floor_cents() is
  'The lowest per-seat monthly price a brokerage contract may be signed at, in '
  'cents. $50, set by the owner 13 Sep 2026. set_brokerage_contract() refuses '
  'anything below it unless p_allow_below_floor is passed explicitly.';

-- ── 2. the list ladder ──────────────────────────────────────────────────────

create or replace function public.brokerage_price_cents(p_seats integer)
returns integer language sql immutable set search_path = public as $$
  select case
           when p_seats is null or p_seats < 10 then null
           when p_seats < 50  then 14900
           when p_seats < 200 then 11900
           else 8900
         end::integer;
$$;

comment on function public.brokerage_price_cents(integer) is
  'LIST price per seat per month, in cents: 10-49 -> $149, 50-199 -> $119, '
  '200+ -> $89. This is the opening number, set to be negotiated down toward '
  'brokerage_price_floor_cents() ($50) — not the expected close. NULL under 10 '
  'seats, which is `team` territory and belongs on the App Store. The only '
  'definition of the ladder: a quote, an invoice and a renewal all read it '
  'here. A signed contract keeps its own price and is never re-priced by a '
  'change to this function.';

-- ── 3. refuse to sign below the floor ───────────────────────────────────────
-- Restated whole from 0050 with the floor check added. Everything else about
-- this function is unchanged.

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
  p_notes                text    default null,
  p_allow_below_floor    boolean default false
) returns public.brokerage_contracts
language plpgsql security definer set search_path = public as $$
declare
  v_price integer;
  v_floor integer := brokerage_price_floor_cents();
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

  -- THE FLOOR. A negotiated price is fine; a forgotten one is not.
  if v_price < v_floor and not p_allow_below_floor then
    raise exception
      'RP400: $%/seat is below the $%/seat floor. Pass p_allow_below_floor => true to sign it anyway.',
      round(v_price / 100.0, 2), round(v_floor / 100.0, 2);
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

  update orgs
     set plan        = case when v_row.status = 'active' then 'brokerage' else 'free' end,
         plan_source = case when v_row.status = 'active' then 'brokerage' else plan_source end
   where id = p_org;

  return v_row;
end;
$$;

revoke execute on function public.set_brokerage_contract(uuid,integer,text,text,integer,integer,integer,integer,integer,text,timestamptz,text,boolean)
  from public, anon, authenticated;
grant  execute on function public.set_brokerage_contract(uuid,integer,text,text,integer,integer,integer,integer,integer,text,timestamptz,text,boolean)
  to service_role;

-- The 12-argument form from 0050 would still resolve and would skip the floor
-- check, so it is dropped. Every caller goes through the version that enforces
-- the floor.
drop function if exists public.set_brokerage_contract(uuid,integer,text,text,integer,integer,integer,integer,integer,text,timestamptz,text);

-- ── 4. the quote shows the room, not just the number ────────────────────────
-- A quote that prints one price is a quote you cannot negotiate from. This
-- prints the list, the floor, and what the deal is worth at each end, so the
-- concession available is a number that was decided in advance rather than in
-- the last two minutes of a call.

-- `create or replace` cannot change a function's return type, and this one's
-- column list is changing — caught by the test harness, which is the only
-- reason it is not a failed production migration. Drop first.
drop function if exists public.brokerage_quote(integer,integer,integer,integer,integer);

create or replace function public.brokerage_quote(
  p_seats integer,
  p_renders_per_seat integer default 3,
  p_photo_edits_per_seat integer default 40,
  p_reels_per_seat integer default 3,
  p_aerials_per_seat integer default 1
) returns table (
  seats integer,
  list_cents_per_seat integer, floor_cents_per_seat integer, max_discount_pct numeric,
  mrr_at_list_cents bigint, arr_at_list_cents bigint,
  mrr_at_floor_cents bigint, arr_at_floor_cents bigint,
  pooled_renders integer, pooled_photo_edits integer, pooled_reels integer, pooled_aerials integer,
  worst_case_cogs_cents bigint,
  margin_at_list_pct numeric, margin_at_floor_pct numeric
) language sql stable set search_path = public as $$
  with m as (
    select p_seats as s,
           brokerage_price_cents(p_seats)   as list,
           brokerage_price_floor_cents()    as flr,
           (p_seats * (p_renders_per_seat * 240 + p_photo_edits_per_seat * 4
                     + p_reels_per_seat * 24 + p_aerials_per_seat * 80))::bigint as cogs
  )
  select s, list, flr,
         case when list > 0 then round(((list - flr)::numeric / list) * 100, 1) end,
         (s::bigint * list), (s::bigint * list * 12),
         (s::bigint * flr),  (s::bigint * flr  * 12),
         s * p_renders_per_seat, s * p_photo_edits_per_seat,
         s * p_reels_per_seat,   s * p_aerials_per_seat,
         cogs,
         case when s::bigint * list > 0 then round((((s::bigint*list) - cogs)::numeric / (s::bigint*list)) * 100, 1) end,
         case when s::bigint * flr  > 0 then round((((s::bigint*flr)  - cogs)::numeric / (s::bigint*flr))  * 100, 1) end
    from m;
$$;

grant execute on function public.brokerage_quote(integer,integer,integer,integer,integer) to service_role;
