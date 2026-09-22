-- 0031 — cache for third-party property lookups.
--
-- WHY A CACHE IS PART OF THE FEATURE AND NOT A LATER OPTIMISATION: the provider
-- bills PER CALL (RentCast is ~7c at the $74/1,000 tier), and an agent will look
-- up the same address more than once — they retype it, they come back tomorrow,
-- they open the home again. Without this, the second lookup of a house we
-- already know costs the same as the first, and a single agent hammering the
-- Look up button is a real bill.
--
-- Keyed on a NORMALISED address (lowercased, punctuation stripped, whitespace
-- collapsed) so "1401 45th Ave N, Saint Petersburg, FL 33703" and
-- "1401 45th ave n saint petersburg fl 33703" are one row rather than two
-- charges.
--
-- SERVICE-ROLE ONLY. There is no client-facing read policy on purpose: this
-- table holds bought data across every tenant, and one org must never be able
-- to read another's lookups — or to enumerate what addresses anybody has been
-- researching. The `property` edge function is the only reader.

create table if not exists public.property_lookups (
  address_key   text primary key,
  -- The address as the caller typed it, kept for support and for the response,
  -- since the key itself is lossy by design.
  address_input text not null,
  provider      text not null,
  -- The normalised fact set. Kept as jsonb rather than columns because the
  -- providers disagree about which fields exist and a second provider must not
  -- need a migration to be tried.
  facts         jsonb not null,
  -- Which org's spend paid for this row. Attribution only — any org may be
  -- SERVED from it, because re-buying a public record we already own would be
  -- spending the owner's money to enforce a boundary that protects nobody.
  paid_by_org   uuid references public.orgs(id) on delete set null,
  fetched_at    timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

comment on table public.property_lookups is
  'Cache of paid third-party property-record lookups, keyed by normalised address. Service-role only.';

create index if not exists property_lookups_fetched_idx
  on public.property_lookups (fetched_at desc);

alter table public.property_lookups enable row level security;
-- No policies, deliberately: RLS on with zero policies denies every non-service
-- role, which is exactly the intent. Nothing here is client-readable.

revoke all on public.property_lookups from anon, authenticated;
