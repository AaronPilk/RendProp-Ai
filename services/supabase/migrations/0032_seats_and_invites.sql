-- 0032 — SEATS ARE REAL NOW.
--
-- Until this migration `plan_entitlements.seats` was a number nothing read and
-- nothing enforced: `memberships` was written in exactly three places (the
-- signup trigger, adopt's one-row transfer, and account deletion), so there was
-- no way for anybody to add a second person to an org. The paywall was selling
-- "3 seats" that could not be occupied.
--
-- WHY A TOKEN AND NOT AN E-MAIL MATCH. An invited agent signs in with Apple,
-- and Apple hands back a private-relay address (…@privaterelay.appleid.com) by
-- default — the owner's own account does exactly this. Matching an invite to
-- the address the inviter typed would therefore fail for most real people. So
-- the invite IS the token: `email` is only for delivery and for showing the
-- owner who they invited. Holding an unexpired, unrevoked, unaccepted token is
-- what grants the seat.
--
-- The token is stored HASHED. This table is readable by the service role in
-- every edge function; a leaked backup or an over-broad admin query must not
-- hand out live seats. The plaintext exists once, in the response to the person
-- who created it, and is never stored.

-- ── The table ───────────────────────────────────────────────────────────────
create table if not exists public.org_invites (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  email       text,                                   -- delivery + display only
  role        text not null default 'agent'
              check (role in ('admin','agent','marketing')),
  token_hash  text not null unique,                   -- sha256 of the plaintext
  invited_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '14 days',
  accepted_at timestamptz,
  accepted_by uuid references public.profiles(id) on delete set null,
  revoked_at  timestamptz
);

-- 'owner' is deliberately NOT invitable. An org has exactly one owner, created
-- by the signup trigger; handing that role out over a link would let an invited
-- agent delete the org that invited them.

create index if not exists org_invites_org_live_idx
  on public.org_invites (org_id)
  where accepted_at is null and revoked_at is null;

-- One LIVE invite per address per org. Re-inviting the same person is a
-- revoke-then-invite, not a second seat quietly held open. Rows with a null
-- email (link-only invites) are exempt.
create unique index if not exists org_invites_one_live_per_email
  on public.org_invites (org_id, lower(email))
  where email is not null and accepted_at is null and revoked_at is null;

-- RLS ON WITH NO POLICIES, exactly like app_events (0020 §2): no tenant role
-- may read or write this table under any circumstances. Every legitimate read
-- and write goes through the `team` edge function on the service role, which
-- checks the caller's role first. A token_hash is a credential; `authenticated`
-- must not be able to select one, not even its own org's.
alter table public.org_invites enable row level security;
revoke all on public.org_invites from anon, authenticated;

-- ── Seat accounting ─────────────────────────────────────────────────────────
--
-- A pending invite HOLDS a seat. Without that, an owner on a 3-seat plan can
-- send thirty invites and the cap only bites for whoever accepts fourth —
-- which is the worst moment to discover it.
create or replace function public.org_seats_used(p_org uuid)
returns integer
language sql stable
set search_path = public
as $$
  select ((select count(*) from memberships m where m.org_id = p_org)
        + (select count(*) from org_invites i
            where i.org_id = p_org
              and i.accepted_at is null
              and i.revoked_at is null
              and i.expires_at > now()))::integer;
$$;

/** Seats the org's CURRENT plan is entitled to (an expired trial counts as free). */
create or replace function public.org_seats_allowed(p_org uuid)
returns integer
language sql stable
set search_path = public
as $$
  select coalesce(e.seats, 1)
    from plan_entitlements e
   where e.plan = public.effective_plan(p_org);
$$;

revoke execute on function public.org_seats_used(uuid)    from anon;
revoke execute on function public.org_seats_allowed(uuid) from anon;

-- ── The trial was doing nothing ─────────────────────────────────────────────
--
-- `free` and `trial` carried BYTE-IDENTICAL entitlements (1 render, 10 photo
-- edits, 1 reel, 2 aerials, 1 topaz, 800¢ ceiling), so the seven-day trial
-- granted nothing on day 1 and took nothing away on day 8. There was no trial
-- — only a label. Announcing it to the user, which is what the intro is about
-- to do, would have been announcing a fiction.
--
-- So: the trial becomes a real taste of Pro, and free becomes genuinely thinner
-- than it, which is the whole point of a trial ending.
--
-- Worst-case COGS of the new trial at the committed rate card
-- (_shared/ledger.ts APP_AI_UNIT_CENTS): 60 × 3.9¢ + 4 × 24¢ + 2 × 80¢ = $4.90
-- of AI, plus at most one Topaz pass, and the 1,200¢ ceiling is the hard stop.
-- Renders are on-device and cost nothing.
insert into public.plan_entitlements
  (plan, renders_per_month, photo_edits_per_month, reels_per_month,
   aerials_per_month, topaz_per_month, seats, cogs_ceiling_cents, price_cents)
values
  ('trial', 3, 60, 4, 2, 1, 1, 1200, 0),
  ('free',  1,  5, 0, 0, 0, 1,  300, 0)
on conflict (plan) do update set
  renders_per_month     = excluded.renders_per_month,
  photo_edits_per_month = excluded.photo_edits_per_month,
  reels_per_month       = excluded.reels_per_month,
  aerials_per_month     = excluded.aerials_per_month,
  topaz_per_month       = excluded.topaz_per_month,
  seats                 = excluded.seats,
  cogs_ceiling_cents    = excluded.cogs_ceiling_cents;
