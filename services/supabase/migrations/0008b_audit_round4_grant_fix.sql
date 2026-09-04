-- 0008b: re-grant the client-writable listing columns (2026-09-01).
--
-- Production history: supabase_migrations.schema_migrations version
-- 20260901180549 "audit_round4_grant_fix" — applied right after 0008 but never
-- committed (audit F-supabase-03). The first pass of 0008 §2 shipped with a
-- column list that omitted status/space_type/source and broke the sold/archive
-- flow; the repo copy of 0008 was patched in place, so against this repo the
-- statement below is a no-op. It is committed for migration-history parity and
-- so the invariants test "every client-writable listing column is still
-- granted" has a single, explicit source.
--
-- Idempotent (GRANT is). Only ownership/identity columns stay unwritable:
-- org_id, agent_id, id, created_at.

grant update (
  space_type, address, tagline, details, beds, baths, sqft, price_cents,
  zillow_url, main_photo_key, lat, lng, status, sold_at, source, mls_ref,
  deleted_at
) on public.listings to authenticated;
