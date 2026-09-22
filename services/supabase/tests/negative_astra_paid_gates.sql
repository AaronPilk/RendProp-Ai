-- ONLY the disposable, socket-only cluster made by run_database_regression.py.
-- No provider calls. All mutations roll back, including on psql connection exit.
-- This tests the EXACT include used by invariants.sql; a bare-printing check
-- fails the row-count assertion instead of yielding a misleading green run.
\set ON_ERROR_STOP on
begin;
do $$
begin
  if current_database() <> 'rendprop_audit'
     or current_setting('listen_addresses') <> ''
     or current_setting('data_directory') !~ '^/tmp/rendprop-db-audit-[^/]+/cluster$' then
    raise exception 'Refusing to mutate anything except the disposable audit cluster';
  end if;
end $$;

create temp table _inv(seq serial, name text, pass boolean, note text) on commit drop;
\ir invariant_astra_paid_gates.sql
do $$
begin
  if (select count(*) from _inv) <> 2
     or exists (select 1 from _inv where pass is distinct from true) then
    raise exception 'Baseline must register two passing paid-plan assertions';
  end if;
end $$;

truncate _inv;
do $$
declare changed integer;
begin
  update public.ai_routes set min_plan = 'free'
    where task = 'copy.agent_reel' and model = 'gpt-6-astra' and position = 1;
  get diagnostics changed = row_count;
  if changed <> 1 then raise exception 'Free-tier negative control changed % rows, expected 1', changed; end if;
end $$;
\ir invariant_astra_paid_gates.sql
do $$
begin
  if (select count(*) from _inv) <> 2
     or exists (select 1 from _inv where pass is distinct from false) then
    raise exception 'Free-tier exposure must register two actual failures';
  end if;
end $$;

truncate _inv;
do $$
declare changed integer;
begin
  -- Preserve three total rows and a paid tier, but destroy the first-seat
  -- identity. A count-only check would incorrectly pass this mutation.
  update public.ai_routes set min_plan = 'pro', position = 17
    where task = 'copy.agent_reel' and model = 'gpt-6-astra' and position = 1;
  get diagnostics changed = row_count;
  if changed <> 1 then raise exception 'Seat negative control changed % rows, expected 1', changed; end if;
end $$;
\ir invariant_astra_paid_gates.sql
do $$
begin
  if (select count(*) from _inv) <> 2
     or (select pass from _inv where name = 'all three explicit Astra writing seats keep their 0030/0034 paid-plan gates') is distinct from false
     or (select pass from _inv where name = 'no gpt-6-astra row is reachable on the free or trial tier') is distinct from true then
    raise exception 'Wrong first-seat identity must fail while the no-free-tier assertion still passes';
  end if;
end $$;
rollback;
\echo 'PASS: exact paid-plan predicates registered 6 expected outcomes across baseline and 2 negative fixtures; all mutations rolled back.'
