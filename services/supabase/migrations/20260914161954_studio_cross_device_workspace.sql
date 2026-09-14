-- Private cross-device edit intent and trusted creative output associations.
-- Existing listings/media/entitlements remain the source of truth.
begin;
create table public.studio_documents (
  user_id uuid not null references auth.users(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  key text not null check (length(key) between 1 and 160),
  kind text not null check (kind in ('edit','planner','creative','native')),
  listing_id uuid references public.listings(id) on delete cascade,
  revision integer not null default 1 check (revision > 0),
  payload jsonb not null check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 2097152),
  updated_at timestamptz not null default now(),
  primary key (user_id, org_id, key)
);
create index studio_documents_org_listing on public.studio_documents(org_id, listing_id);
alter table public.studio_documents enable row level security;
revoke all on public.studio_documents from public, anon, authenticated;
grant select on public.studio_documents to authenticated;
grant all on public.studio_documents to service_role;
create policy studio_documents_owner_read on public.studio_documents for select to authenticated
using (user_id = (select auth.uid()) and public.is_org_member(org_id)
  and exists (select 1 from public.orgs o where o.id = studio_documents.org_id and o.deleted_at is null)
  and (listing_id is null or exists (select 1 from public.listings l where l.id = studio_documents.listing_id and l.org_id = studio_documents.org_id and l.deleted_at is null)));

create table public.studio_creative_results (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  listing_id uuid not null references public.listings(id) on delete cascade,
  kind text not null check (kind in ('voice','video')),
  storage_key text check (length(storage_key) <= 1024),
  bucket text check (bucket in ('uploads','renders')),
  provenance_id uuid references public.media_provenance(id) on delete set null,
  request_key text not null check (length(request_key) between 1 and 160),
  metadata jsonb not null default '{}' check (jsonb_typeof(metadata) = 'object' and octet_length(metadata::text) <= 262144),
  created_at timestamptz not null default now(),
  unique (user_id, org_id, request_key)
);
create index studio_creative_results_org_listing on public.studio_creative_results(org_id,listing_id,created_at desc);
create index studio_creative_results_provenance on public.studio_creative_results(provenance_id) where provenance_id is not null;
alter table public.studio_creative_results enable row level security;
revoke all on public.studio_creative_results from public, anon, authenticated;
-- Results contain trusted internal job references. Only the scoped Edge handler
-- projects public fields; even an authenticated client cannot alter or read them.
grant all on public.studio_creative_results to service_role;
commit;
