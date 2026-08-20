-- Rendprop — Supabase schema v1 (source of truth). Money in integer cents.
-- Multi-business (space_type + details jsonb). RLS on everything.
-- Video bytes NEVER live here — only rows + R2/Stream keys/URLs.

-- ============================ Identity & org ============================
-- Profiles mirror auth.users (id == auth.users.id). Created by a trigger on signup.
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  phone       text,
  name        text,
  avatar_url  text,
  created_at  timestamptz not null default now()
);

create table if not exists orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  handle      text unique,                 -- public portfolio slug: /a/{handle}
  space_type  text not null default 'real_estate',
  brand_kit   jsonb not null default '{}', -- agent card, accent, socials
  plan        text not null default 'free' check (plan in ('free','pro','team')),
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

create table if not exists memberships (
  id       uuid primary key default gen_random_uuid(),
  user_id  uuid not null references profiles(id) on delete cascade,
  org_id   uuid not null references orgs(id) on delete cascade,
  role     text not null default 'owner' check (role in ('owner','admin','agent','marketing')),
  unique (user_id, org_id)
);

-- ============================ Listings ============================
create table if not exists listings (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  agent_id       uuid not null references profiles(id),
  space_type     text not null default 'real_estate',
  address        text,
  tagline        text,                      -- non-real-estate subtitle
  details        jsonb not null default '{}', -- industry-specific fields (see INDUSTRY-LOGIC.md)
  beds           smallint,
  baths          numeric(3,1),
  sqft           integer,
  price_cents    bigint,
  zillow_url     text,
  main_photo_key text,                       -- R2 key of the hero photo
  lat            double precision,
  lng            double precision,
  status         text not null default 'draft'
                 check (status in ('draft','capturing','processing','ready','expired','archived')),
  sold_at        timestamptz,               -- non-null = sold/archived folder
  source         text not null default 'manual' check (source in ('manual','url','mls')),
  mls_ref        text,
  created_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index if not exists idx_listings_org_status on listings(org_id, status);

create table if not exists capture_assets (
  id           uuid primary key default gen_random_uuid(),
  listing_id   uuid not null references listings(id) on delete cascade,
  kind         text not null default 'video' check (kind in ('video','photo')),
  storage_key  text not null,               -- R2 key
  duration_s   numeric(8,2),
  fps          numeric(6,2),
  width        integer,
  height       integer,
  codec        text,
  is_drone     boolean not null default false,
  has_gyro     boolean not null default false,
  sha256       text,
  bytes        bigint,
  uploaded     boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists idx_assets_listing on capture_assets(listing_id);

-- Area/room tags → the player's tap-to-jump dots
create table if not exists capture_chapters (
  id        uuid primary key default gen_random_uuid(),
  asset_id  uuid not null references capture_assets(id) on delete cascade,
  label     text not null,
  t_ms      integer not null,
  sort      smallint not null default 0
);

-- Enhanced listing photos (pro look / staged)
create table if not exists photos (
  id           uuid primary key default gen_random_uuid(),
  listing_id   uuid not null references listings(id) on delete cascade,
  original_key text,
  enhanced_key text,
  is_main      boolean not null default false,
  is_staged    boolean not null default false,  -- true → "virtually staged" disclosure required
  caption      text,
  sort         smallint not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists idx_photos_listing on photos(listing_id);

-- ============================ Render pipeline ============================
create table if not exists render_jobs (
  id                uuid primary key default gen_random_uuid(),
  listing_id        uuid not null references listings(id) on delete cascade,
  capture_asset_id  uuid references capture_assets(id),
  tier              text not null default 'smooth' check (tier in ('smooth','premium4k','cinematic')),
  enhancements      jsonb not null default '{}',  -- {"declutter":bool,"style":"..."}
  status            text not null default 'created',
  current_step      text,
  progress          numeric(4,3) not null default 0,
  error             jsonb,
  cost_cents        integer not null default 0,
  created_at        timestamptz not null default now(),
  started_at        timestamptz,
  finished_at       timestamptz
);
create index if not exists idx_jobs_status on render_jobs(status);

create table if not exists renders (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid not null references render_jobs(id) on delete cascade,
  listing_id   uuid not null references listings(id) on delete cascade,
  slug         text unique not null,        -- public /f/{slug}
  duration_s   numeric(8,2) not null,
  speed_factor numeric(4,2) not null default 2.0,
  video_key    text,                         -- R2 key (self-host player)
  stream_uid   text,                         -- Cloudflare Stream UID (managed delivery)
  poster_key   text,
  staged       boolean not null default false,
  published_at timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists idx_renders_slug on renders(slug);

-- ============================ Cost ledger ============================
-- One row per billable provider/GPU/stream unit. render_jobs.cost_cents = sum.
create table if not exists cost_ledger (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid references render_jobs(id) on delete set null,
  org_id       uuid references orgs(id) on delete set null,
  feature      text not null,               -- declutter|restage|hero|qc|render|stream_store|stream_deliver
  provider     text not null,               -- gemini|fal|anthropic|kie|cloudflare
  model        text,
  units        numeric(12,4) not null default 1,
  unit_cost_cents numeric(12,6) not null default 0,
  total_cents  numeric(12,4) not null default 0,
  meta         jsonb not null default '{}',
  created_at   timestamptz not null default now()
);
create index if not exists idx_ledger_job on cost_ledger(job_id);
create index if not exists idx_ledger_org on cost_ledger(org_id, created_at);

-- ============================ Leads & metering ============================
create table if not exists leads (
  id          uuid primary key default gen_random_uuid(),
  render_id   uuid references renders(id) on delete set null,
  listing_id  uuid references listings(id) on delete set null,
  org_id      uuid references orgs(id) on delete set null,
  name        text,
  phone       text,
  email       text,
  extra       jsonb not null default '{}',  -- party_size, event_date, guest_count, ...
  source      text not null default 'tour',
  synced_crm  boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists idx_leads_org on leads(org_id, created_at);

create table if not exists metering (
  id               uuid primary key default gen_random_uuid(),
  render_id        uuid references renders(id) on delete cascade,
  org_id           uuid references orgs(id) on delete set null,
  day              date not null default current_date,
  views            integer not null default 0,
  watch_ms         bigint not null default 0,
  streamed_minutes numeric(12,2) not null default 0,
  max_scroll_depth numeric(4,3) not null default 0,
  unique (render_id, day)
);

-- ============================ RLS ============================
alter table profiles         enable row level security;
alter table orgs             enable row level security;
alter table memberships      enable row level security;
alter table listings         enable row level security;
alter table capture_assets   enable row level security;
alter table capture_chapters enable row level security;
alter table photos           enable row level security;
alter table render_jobs      enable row level security;
alter table renders          enable row level security;
alter table cost_ledger      enable row level security;
alter table leads            enable row level security;
alter table metering         enable row level security;

-- Helper: is the current user a member of this org?
create or replace function is_org_member(target uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from memberships m where m.org_id = target and m.user_id = auth.uid());
$$;

create policy "own profile" on profiles for all using (id = auth.uid()) with check (id = auth.uid());
create policy "member orgs read"  on orgs for select using (is_org_member(id));
create policy "member orgs write" on orgs for update using (is_org_member(id));
create policy "own memberships"   on memberships for select using (user_id = auth.uid());

-- Org-scoped tables: readable/writable by org members.
create policy "org listings" on listings for all using (is_org_member(org_id)) with check (is_org_member(org_id));
create policy "org assets"   on capture_assets for all
  using (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)))
  with check (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)));
create policy "org chapters" on capture_chapters for all
  using (exists (select 1 from capture_assets a join listings l on l.id=a.listing_id where a.id=asset_id and is_org_member(l.org_id)));
create policy "org photos" on photos for all
  using (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)))
  with check (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)));
create policy "org jobs" on render_jobs for all
  using (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)));
create policy "org renders" on renders for all
  using (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)));
create policy "org ledger" on cost_ledger for select using (is_org_member(org_id));
create policy "org leads"  on leads for select using (is_org_member(org_id));
create policy "org metering" on metering for select using (is_org_member(org_id));

-- Public tour/lead/beacon access goes through SECURITY DEFINER functions in the
-- Edge layer (service role), NOT direct table access — so no public RLS policies
-- are granted on the base tables. See functions: tours/, leads/, beacon.

-- Auto-create a profile on signup.
create or replace function handle_new_user() returns trigger
language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'name', ''));
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();
