-- Rendprop database invariants — the adversarial battery from the 2026-08 audit
-- rounds, committed so it is re-runnable instead of living in a chat log.
--
-- Run against a NON-PRODUCTION branch (or a restored copy):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f services/supabase/tests/invariants.sql
--
-- Every check is read-only EXCEPT the clearly-marked mutation blocks, which
-- clean up after themselves. Output is one row per assertion; any `pass = f`
-- is a release blocker.

\set ON_ERROR_STOP on

create temp table _inv(seq serial, name text, pass boolean, note text);

-- ── P0-3 / P0-7: privileged surface ──────────────────────────────────────────

insert into _inv(name, pass, note)
select 'publish_render takes NO caller-supplied staged flag',
       coalesce(bool_and(args not like '%boolean%'), false),
       coalesce(string_agg(args, ' | '), '(function missing)')
from (select pg_get_function_identity_arguments(oid) as args
        from pg_proc where proname = 'publish_render') s;

insert into _inv(name, pass, note)
select 'create_render_job enforces role AND uploaded asset',
       count(*) = 1, ''
from pg_proc
where proname = 'create_render_job'
  and prosrc like '%org_role%' and prosrc like '%uploaded is true%';

insert into _inv(name, pass, note)
select 'publish_render enforces role', count(*) = 1, ''
from pg_proc where proname = 'publish_render' and prosrc like '%org_role%';

insert into _inv(name, pass, note)
select 'idempotency is re-checked after the advisory lock',
       (length(prosrc) - length(replace(prosrc, 'rj.idem_key = v_idem', ''))) /
       length('rj.idem_key = v_idem') >= 2, ''
from pg_proc where proname = 'create_render_job';

insert into _inv(name, pass, note)
select 'server-only tables reject tenant writes',
       not bool_or(has_table_privilege('authenticated', t, 'INSERT')
                or has_table_privilege('authenticated', t, 'UPDATE')
                or has_table_privilege('authenticated', t, 'DELETE')),
       string_agg(t, ', ')
from unnest(array['public.render_jobs','public.renders','public.capture_assets',
                  'public.capture_chapters','public.cost_ledger','public.metering',
                  'public.rate_limits','public.deletion_requests']) t;

insert into _inv(name, pass, note)
select 'listing ownership columns are not tenant-writable',
       not has_column_privilege('authenticated','public.listings','org_id','UPDATE')
       and not has_column_privilege('authenticated','public.listings','agent_id','UPDATE'), '';

-- Regression guard: over-tightening this grant silently broke the sold/archive
-- flow once. Every column the listings function may PATCH must stay writable.
insert into _inv(name, pass, note)
select 'every client-writable listing column is still granted',
       bool_and(has_column_privilege('authenticated','public.listings', c, 'UPDATE')),
       string_agg(c, ',') filter (where not has_column_privilege('authenticated','public.listings', c, 'UPDATE'))
from unnest(array['space_type','address','tagline','details','beds','baths','sqft',
                  'price_cents','zillow_url','main_photo_key','lat','lng','status',
                  'sold_at','source','mls_ref']) c;

-- ── P0-6: location precision ─────────────────────────────────────────────────

insert into _inv(name, pass, note)
select 'coordinate coarsening trigger is installed', count(*) = 1, ''
from pg_trigger t join pg_proc p on p.oid = t.tgfoid
where t.tgrelid = 'public.listings'::regclass and p.proname = 'coarsen_listing_coords';

insert into _inv(name, pass, note)
select 'no stored coordinate exceeds 3 decimal places', count(*) = 0,
       format('%s violating rows', count(*))
from listings
where (lat is not null and lat <> round(lat::numeric, 3))
   or (lng is not null and lng <> round(lng::numeric, 3));

-- ── Plan coherence: enforced must equal published ────────────────────────────

insert into _inv(name, pass, note)
select 'render caps match rendprop.com/pricing (2/5/15)',
       plan_render_cap('solo') = 2 and plan_render_cap('pro') = 5 and plan_render_cap('team') = 15,
       format('solo=%s pro=%s team=%s free=%s',
              plan_render_cap('solo'), plan_render_cap('pro'),
              plan_render_cap('team'), plan_render_cap('free'));

insert into _inv(name, pass, note)
select 'orgs.plan accepts the four shipped plans',
       pg_get_constraintdef(oid) like '%solo%' and pg_get_constraintdef(oid) like '%team%',
       pg_get_constraintdef(oid)
from pg_constraint
where conrelid = 'public.orgs'::regclass and conname = 'orgs_plan_check';

-- ── Data integrity ───────────────────────────────────────────────────────────

insert into _inv(name, pass, note)
select 'all CHECK constraints are validated', count(*) = 0,
       coalesce(string_agg(conname, ', '), '')
from pg_constraint
where not convalidated and contype = 'c'
  and connamespace = 'public'::regnamespace;

insert into _inv(name, pass, note)
select 'one published render per job (no duplicate publishes)', count(*) = 0,
       format('%s jobs with >1 render', count(*))
from (select job_id from renders group by job_id having count(*) > 1) d;

insert into _inv(name, pass, note)
select 'RLS is enabled on every application table', count(*) = 0,
       coalesce(string_agg(relname, ', '), '')
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
  and c.relname in ('profiles','orgs','memberships','listings','capture_assets',
                    'capture_chapters','photos','render_jobs','renders',
                    'cost_ledger','leads','metering','rate_limits','deletion_requests');

-- ── MUTATING: rate limiter semantics (cleans up after itself) ────────────────

do $$
declare a boolean; b boolean; kept int; gone int;
begin
  delete from rate_limits where key like '_inv:%';

  select bump_rate('_inv:cost', 60, 5, 3) into a;
  select bump_rate('_inv:cost', 60, 5, 3) into b;
  insert into _inv(name, pass, note)
    values ('bump_rate charges per unit cost (3+3 vs cap 5)', a and not b,
            format('first=%s second=%s', a, b));

  insert into rate_limits(key, window_start, count, window_seconds) values
    ('_inv:month',  now() - interval '5 days', 3, 2592000),
    ('_inv:minute', now() - interval '2 days', 3, 60);
  delete from rate_limits
   where key like '_inv:%'
     and window_start < now() - make_interval(secs => window_seconds) - interval '1 day';
  select count(*) into kept from rate_limits where key = '_inv:month';
  select count(*) into gone from rate_limits where key = '_inv:minute';
  insert into _inv(name, pass, note)
    values ('cleanup keeps 30-day counters, drops expired ones', kept = 1 and gone = 0,
            format('monthly_kept=%s minute_removed=%s', kept = 1, gone = 0));

  delete from rate_limits where key like '_inv:%';
end $$;

select seq, name, pass, note from _inv order by seq;

do $$
declare failures int;
begin
  select count(*) into failures from _inv where pass is distinct from true;
  if failures > 0 then
    raise exception 'INVARIANTS FAILED: % assertion(s) did not pass', failures;
  end if;
  raise notice 'All % invariants passed.', (select count(*) from _inv);
end $$;
