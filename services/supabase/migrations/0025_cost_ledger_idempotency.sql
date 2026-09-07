-- 0025: cost_ledger idempotency key (2026-09-07, external release audit finding 6).
--
-- services/pipeline/cost_spool.py and services/worker/db.py both retry a
-- cost_ledger insert on failure and, if retries are exhausted, spool the row
-- to a local file for a later flush. Two related gaps meant the SAME charge
-- could land in cost_ledger twice with no way to tell:
--
--   1. A write that actually SUCCEEDED server-side but whose response was
--      lost (a network blip after the commit) is retried by the client and
--      inserted again.
--   2. Two flushers reading the same spool file — two threads on one host
--      before this audit's file-locking fix, or two SEPARATE hosts, which a
--      local `fcntl.flock` can never coordinate — can each successfully
--      submit the same spooled row.
--
-- Both callers now generate a random `idempotency_key` once, when the row is
-- FIRST built (before any attempt), and carry that same key through every
-- retry and every spool/flush replay of that one logical charge:
--   • services/worker/db.py: record_cost() / _insert_cost_row()
--   • services/pipeline/cost_ledger.py: CostLedger.record() / _insert_once()
-- This unique index turns a duplicate submission into an HTTP 409 the client
-- already knows how to read as "already recorded" (both call sites check
-- for it and treat it as success, not failure) instead of a second
-- billed/estimated row inflating render_jobs.cost_cents or an org's spend.
--
-- Safe on a table that already has rows: the column is nullable (existing
-- rows get NULL, no rewrite/backfill needed) and the unique index is PARTIAL
-- (`where idempotency_key is not null`) — Postgres never treats two NULLs as
-- equal in a unique index, so pre-migration rows are exempt from the
-- constraint and can never collide with each other or with new rows. Every
-- row written from here on always populates a real key, so it IS covered.
--
-- Idempotent: `add column if not exists` + `create ... if not exists`, so
-- re-applying this file to a database that already has it is a no-op.

alter table public.cost_ledger
  add column if not exists idempotency_key text;

comment on column public.cost_ledger.idempotency_key is
  'Random key generated once when the row is first built (services/worker/db.py '
  'record_cost / services/pipeline/cost_ledger.py CostLedger.record), unchanged '
  'across every retry and spool/flush replay of that same charge. NULL on rows '
  'written before this migration. See uq_cost_ledger_idempotency below — a '
  'duplicate submission of the same charge now 409s instead of double-counting '
  'spend (external release audit finding 6).';

create unique index if not exists uq_cost_ledger_idempotency
  on public.cost_ledger (idempotency_key)
  where idempotency_key is not null;

-- No new grant: the column inherits cost_ledger's existing table-level grants
-- (anon/authenticated SELECT scoped by the unchanged "org ledger" RLS policy,
-- service_role write — 0001_init.sql / 0017_admin_role.sql).
