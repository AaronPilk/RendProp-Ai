-- ROAM Postgres schema v0.1 (Master Build Prompt Part 8.2)
-- Money in integer cents. Soft-delete + audit for compliance.

-- ============ Identity & org ============
CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text UNIQUE,
  phone         text UNIQUE,
  apple_sub     text UNIQUE,
  name          text,
  avatar_url    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);

CREATE TABLE orgs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  type          text NOT NULL DEFAULT 'solo' CHECK (type IN ('solo','team','brokerage')),
  brand_kit     jsonb NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);

CREATE TABLE memberships (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id),
  org_id        uuid NOT NULL REFERENCES orgs(id),
  role          text NOT NULL CHECK (role IN ('owner','admin','agent','marketing')),
  UNIQUE (user_id, org_id)
);

-- ============ Listings & capture ============
CREATE TABLE listings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES orgs(id),
  agent_id      uuid NOT NULL REFERENCES users(id),
  address       text,
  beds          smallint,
  baths         numeric(3,1),
  sqft          integer,
  price_cents   bigint,
  description   text,
  status        text NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft','capturing','processing','ready','expired','archived')),
  source        text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','url','mls')),
  mls_ref       text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);
CREATE INDEX idx_listings_org_status ON listings(org_id, status);

CREATE TABLE capture_assets (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id    uuid NOT NULL REFERENCES listings(id),
  storage_key   text NOT NULL,             -- R2 key
  duration_s    numeric(8,2),
  fps           numeric(6,2),
  width         integer,
  height        integer,
  codec         text,
  is_drone      boolean NOT NULL DEFAULT false,
  has_gyro      boolean NOT NULL DEFAULT false,  -- gyro sidecar present → Gyroflow path
  sha256        text NOT NULL,
  bytes         bigint NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE capture_chapters (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id      uuid NOT NULL REFERENCES capture_assets(id),
  label         text NOT NULL,             -- "Kitchen", "Primary", ...
  t_seconds     numeric(8,2) NOT NULL,
  sort          smallint NOT NULL DEFAULT 0
);

-- ============ Render pipeline ============
-- State machine (Part 6.1): created → uploaded → validating → queued → ingesting →
-- stabilizing → interpolating → grading → upscaling → segmenting → generating_hero →
-- stitching → encoding → packaging → publishing → ready
-- Terminal: failed / needs_reshoot / canceled / expired / archived
CREATE TABLE render_jobs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id        uuid NOT NULL REFERENCES listings(id),
  capture_asset_id  uuid NOT NULL REFERENCES capture_assets(id),
  tier              text NOT NULL CHECK (tier IN ('smooth','premium4k','cinematic')),
  -- AI enhancement add-ons: {"declutter": bool, "style": "as_is|modern|rustic|minimalist|scandinavian"}
  -- When active, the share page MUST render the "Virtually staged" disclosure (MLS compliance).
  enhancements      jsonb NOT NULL DEFAULT '{}',
  status            text NOT NULL DEFAULT 'created',
  current_step      text,
  error             jsonb,
  cost_cents        integer NOT NULL DEFAULT 0,   -- aggregated job cost
  priority          integer NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  started_at        timestamptz,
  finished_at       timestamptz
);
CREATE INDEX idx_render_jobs_status_priority ON render_jobs(status, priority DESC);

CREATE TABLE render_step_costs (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id              uuid NOT NULL REFERENCES render_jobs(id),
  step                text NOT NULL,
  gpu_type            text,
  gpu_seconds         numeric(10,2),
  provider            text,
  provider_cost_cents integer NOT NULL DEFAULT 0,
  bytes_in            bigint,
  bytes_out           bigint,
  ms                  integer,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_step_costs_job ON render_step_costs(job_id);

CREATE TABLE renders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id          uuid NOT NULL REFERENCES render_jobs(id),
  listing_id      uuid NOT NULL REFERENCES listings(id),
  duration_s      numeric(8,2) NOT NULL,
  has_4k          boolean NOT NULL DEFAULT false,
  scrub_playback_id text,                   -- low-res all-intra scrub proxy
  playback_ids    jsonb NOT NULL DEFAULT '{}', -- {\"1080p\": id, \"4k\": id}
  sprite_key      text,
  vtt_key         text,
  poster_key      text,
  published_at    timestamptz,
  expires_at      timestamptz,              -- hosting TTL
  hosting_plan_id uuid
);

-- ============ Sharing & leads ============
CREATE TABLE share_pages (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  render_id     uuid NOT NULL REFERENCES renders(id),
  slug          text UNIQUE NOT NULL,
  cta_config    jsonb NOT NULL DEFAULT '{}',
  lead_capture  boolean NOT NULL DEFAULT true,
  watermark     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE share_views (               -- metering + analytics
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  share_page_id    uuid NOT NULL REFERENCES share_pages(id),
  ts               timestamptz NOT NULL DEFAULT now(),
  minutes_streamed numeric(8,3) NOT NULL DEFAULT 0,  -- core billing unit
  scroll_depth     numeric(4,3),          -- 0..1, % of home seen
  country          text,
  referrer         text,
  device           text,
  in_app_browser   text                   -- 'instagram' | 'tiktok' | 'facebook' | ...
);
CREATE INDEX idx_share_views_page_ts ON share_views(share_page_id, ts);

CREATE TABLE leads (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  share_page_id  uuid NOT NULL REFERENCES share_pages(id),
  listing_id     uuid NOT NULL REFERENCES listings(id),
  name           text,
  email          text,
  phone          text,
  message        text,
  status         text NOT NULL DEFAULT 'new' CHECK (status IN ('new','contacted','won','lost')),
  routed_to      uuid REFERENCES users(id),
  crm_synced     boolean NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- ============ Billing (server-authoritative ledger) ============
CREATE TABLE credit_ledger (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES orgs(id),
  delta         integer NOT NULL,          -- +credit / -debit
  reason        text NOT NULL,             -- 'purchase' | 'render_debit' | 'refund' | 'referral' | ...
  ref_type      text,
  ref_id        uuid,
  balance_after integer NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ledger_org_created ON credit_ledger(org_id, created_at);

CREATE TABLE purchases (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES orgs(id),
  platform      text NOT NULL CHECK (platform IN ('apple','stripe')),
  product_id    text NOT NULL,
  amount_cents  integer NOT NULL,
  apple_txn_id  text UNIQUE,               -- idempotency: no double-credit
  stripe_pi     text UNIQUE,
  status        text NOT NULL DEFAULT 'pending',
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE subscriptions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES orgs(id),
  platform           text NOT NULL CHECK (platform IN ('apple','stripe')),
  product_id         text NOT NULL,
  status             text NOT NULL,
  current_period_end timestamptz,
  seats              integer NOT NULL DEFAULT 1,
  plan               text NOT NULL CHECK (plan IN ('hosting','team','pro')),
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE metering (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  render_id           uuid NOT NULL REFERENCES renders(id),
  month               date NOT NULL,
  minutes_streamed    numeric(12,3) NOT NULL DEFAULT 0,
  delivery_cost_cents integer NOT NULL DEFAULT 0,
  UNIQUE (render_id, month)
);

-- ============ Notifications & audit ============
CREATE TABLE notifications (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id   uuid NOT NULL REFERENCES users(id),
  type      text NOT NULL,
  payload   jsonb NOT NULL DEFAULT '{}',
  sent_at   timestamptz,
  read_at   timestamptz
);

CREATE TABLE audit_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id    uuid,
  action      text NOT NULL,
  target_type text,
  target_id   uuid,
  meta        jsonb NOT NULL DEFAULT '{}',
  ts          timestamptz NOT NULL DEFAULT now()
);
