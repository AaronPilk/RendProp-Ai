-- Rendprop database invariants — the adversarial battery from the 2026-08/09
-- audit rounds, committed so it is re-runnable instead of living in a chat log.
--
-- Run against a NON-PRODUCTION branch (or a restored copy), or in CI on a plain
-- Postgres prepared with tests/ci-bootstrap.sql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f services/supabase/tests/invariants.sql
--
-- Every check is read-only EXCEPT the clearly-marked mutation blocks, which
-- clean up after themselves (the lifecycle fixture creates two throwaway auth
-- users through the real signup trigger and deletes them at the end). Output is
-- one row per assertion; any `pass = f` is a release blocker.
--
-- Numbers in the "plan coherence" section are the PUBLISHED entitlements from
-- services/edge/tour-host/public/pricing.html. Change them there and here
-- together — that is the whole point of the check ("enforced == published").

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
select 'publish_render accepts a server-verified poster asset (p_poster_asset uuid)',
       coalesce(bool_and(args like '%p_poster_asset uuid%'), false),
       coalesce(string_agg(args, ' | '), '(function missing)')
from (select pg_get_function_identity_arguments(oid) as args
        from pg_proc where proname = 'publish_render') s;

-- Two overloads of an RPC make PostgREST unable to pick a candidate → every
-- call 300s. A partial replay of an old migration can reintroduce this.
insert into _inv(name, pass, note)
select 'exactly one overload of each RPC (no PostgREST ambiguity)',
       coalesce(bool_and(n = 1), false),
       string_agg(proname || '=' || n, ', ')
from (select proname, count(*) as n
        from pg_proc
       where pronamespace = 'public'::regnamespace
         and proname in ('create_render_job','publish_render','fail_render_job',
                         'set_render_chapters','set_lead_status','bump_rate','log_job_cost')
       group by proname) s;

insert into _inv(name, pass, note)
select 'create_render_job enforces role AND uploaded asset',
       count(*) = 1, ''
from pg_proc
where proname = 'create_render_job'
  and prosrc like '%org_role%' and prosrc like '%uploaded is true%';

insert into _inv(name, pass, note)
select 'create_render_job takes p_source and reads effective_plan()',
       count(*) = 1, ''
from pg_proc
where proname = 'create_render_job'
  and pg_get_function_identity_arguments(oid) like '%p_source text%'
  and prosrc like '%effective_plan(%'
  and prosrc like '%rj.source = ''worker''%';

insert into _inv(name, pass, note)
select 'publish_render enforces role', count(*) = 1, ''
from pg_proc where proname = 'publish_render' and prosrc like '%org_role%';

insert into _inv(name, pass, note)
select 'fail_render_job / set_render_chapters / set_lead_status are role-gated definers',
       count(*) = 3, format('%s of 3 found', count(*))
from pg_proc
where proname in ('fail_render_job','set_render_chapters','set_lead_status')
  and prosecdef and prosrc like '%org_role%';

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
                  'public.rate_limits','public.deletion_requests','public.leads',
                  'public.plan_entitlements']) t;

insert into _inv(name, pass, note)
select 'tenant RPCs are executable by authenticated, not by anon',
       bool_and(has_function_privilege('authenticated', f, 'EXECUTE'))
       and not bool_or(has_function_privilege('anon', f, 'EXECUTE')),
       string_agg(f, ', ') filter (where not has_function_privilege('authenticated', f, 'EXECUTE')
                                      or has_function_privilege('anon', f, 'EXECUTE'))
from unnest(array['public.create_render_job(uuid,uuid,text,jsonb,text,text)',
                  'public.publish_render(uuid,numeric,numeric,jsonb,uuid)',
                  'public.fail_render_job(uuid,text)',
                  'public.set_render_chapters(uuid,jsonb)',
                  'public.set_lead_status(uuid,text)']) f;

insert into _inv(name, pass, note)
select 'internal / trigger functions are not client-executable',
       not bool_or(has_function_privilege('authenticated', f, 'EXECUTE')
                or has_function_privilege('anon', f, 'EXECUTE')),
       string_agg(f, ', ') filter (where has_function_privilege('authenticated', f, 'EXECUTE')
                                      or has_function_privilege('anon', f, 'EXECUTE'))
from unnest(array['public.replace_asset_chapters(uuid,jsonb)',
                  'public.handle_new_user()',
                  'public.unpublish_deleted_listing_renders()',
                  'public.bump_rate(text,integer,integer,integer)',
                  'public.log_job_cost(uuid,uuid,text,text,text,numeric,numeric,jsonb,numeric)']) f;

-- RLS policy expressions run with the QUERYING user's privileges, so the policy
-- helper MUST stay executable by authenticated (revoking PUBLIC on it without a
-- re-grant breaks every org policy — verified 2026-09-03; see 0005b).
insert into _inv(name, pass, note)
select 'RLS helper is_org_member stays executable by authenticated',
       has_function_privilege('authenticated', 'public.is_org_member(uuid)', 'EXECUTE'), '';

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
                  'sold_at','source','mls_ref','deleted_at']) c;

insert into _inv(name, pass, note)
select 'orgs: tenants may edit name/handle/brand_kit but never plan',
       has_column_privilege('authenticated','public.orgs','name','UPDATE')
       and has_column_privilege('authenticated','public.orgs','handle','UPDATE')
       and has_column_privilege('authenticated','public.orgs','brand_kit','UPDATE')
       and not has_column_privilege('authenticated','public.orgs','plan','UPDATE')
       and not has_column_privilege('authenticated','public.orgs','trial_ends_at','UPDATE'), '';

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

-- ── Plan coherence: enforced must equal published (pricing.html) ─────────────

insert into _inv(name, pass, note)
select 'render caps match rendprop.com/pricing (8/25/80; trial 1)',
       plan_render_cap('solo') = 8 and plan_render_cap('starter') = 8
       and plan_render_cap('pro') = 25 and plan_render_cap('team') = 80
       and plan_render_cap('trial') = 1,
       format('solo=%s starter=%s pro=%s team=%s trial=%s free=%s',
              plan_render_cap('solo'), plan_render_cap('starter'), plan_render_cap('pro'),
              plan_render_cap('team'), plan_render_cap('trial'), plan_render_cap('free'));

insert into _inv(name, pass, note)
select 'plan_entitlements match rendprop.com/pricing for every metered feature',
       coalesce(bool_and(ok), false),
       coalesce(string_agg(plan, ', ') filter (where not ok), '')
from (
  select e.plan,
         (e.photo_edits_per_month, e.reels_per_month, e.aerials_per_month, e.topaz_per_month, e.seats)
           = (x.edits, x.reels, x.aerials, x.topaz, x.seats) as ok
    from plan_entitlements e
    join (values ('trial',   10, 1,  2, 1, 1),
                 ('free',    10, 1,  2, 1, 1),
                 ('starter',150, 8,  2, 0, 1),
                 ('solo',   150, 8,  2, 0, 1),
                 ('pro',    300, 20, 6, 0, 1),
                 ('team',   600, 40, 15, 2, 3)) as x(plan, edits, reels, aerials, topaz, seats)
      on x.plan = e.plan
) s;

insert into _inv(name, pass, note)
select 'every shipped plan has an entitlement row',
       count(*) = 6, format('%s of 6', count(*))
from plan_entitlements where plan in ('trial','free','starter','solo','pro','team');

insert into _inv(name, pass, note)
select 'orgs.plan accepts every shipped plan (trial/free/solo/starter/pro/team)',
       pg_get_constraintdef(oid) like '%trial%' and pg_get_constraintdef(oid) like '%solo%'
       and pg_get_constraintdef(oid) like '%starter%' and pg_get_constraintdef(oid) like '%team%',
       pg_get_constraintdef(oid)
from pg_constraint
where conrelid = 'public.orgs'::regclass and conname = 'orgs_plan_check';

insert into _inv(name, pass, note)
select 'effective_plan() demotes an expired trial to free', count(*) = 1, ''
from pg_proc where proname = 'effective_plan' and prosrc like '%trial_ends_at < now()%';

-- ── Lifecycle schema (0011) ──────────────────────────────────────────────────

insert into _inv(name, pass, note)
select 'render_jobs.source exists and is constrained to worker|app',
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'render_jobs' and column_name = 'source')
       and exists (select 1 from pg_constraint
                    where conrelid = 'public.render_jobs'::regclass and conname = 'render_jobs_source_check'), '';

insert into _inv(name, pass, note)
select 'capture_assets.content_type_declared exists (F-E-01)',
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'capture_assets'
                  and column_name = 'content_type_declared'), '';

insert into _inv(name, pass, note)
select 'leads.status exists with the new|contacted|won|lost check',
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'leads' and column_name = 'status')
       and exists (select 1 from pg_constraint
                    where conrelid = 'public.leads'::regclass and conname = 'leads_status_check'), '';

insert into _inv(name, pass, note)
select 'listings.status accepts the app''s uploading state',
       pg_get_constraintdef(oid) like '%uploading%' and pg_get_constraintdef(oid) like '%archived%',
       pg_get_constraintdef(oid)
from pg_constraint
where conrelid = 'public.listings'::regclass and conname = 'listings_status_check';

insert into _inv(name, pass, note)
select 'soft-delete → unpublish trigger is installed', count(*) = 1, ''
from pg_trigger t join pg_proc p on p.oid = t.tgfoid
where t.tgrelid = 'public.listings'::regclass and p.proname = 'unpublish_deleted_listing_renders';

insert into _inv(name, pass, note)
select 'no published render belongs to a deleted listing', count(*) = 0,
       format('%s live tours on deleted listings', count(*))
from renders r join listings l on l.id = r.listing_id
where r.published_at is not null and l.deleted_at is not null;

insert into _inv(name, pass, note)
select 'handle_new_user never names the org after the email', count(*) = 1, ''
from pg_proc
where proname = 'handle_new_user'
  and prosrc like '%My business%'
  and prosrc not like '%coalesce(new.email%';

insert into _inv(name, pass, note)
select 'no org is named after an email address', count(*) = 0,
       format('%s orgs with @ in name', count(*))
from orgs where name like '%@%';

-- ── Job leases (0015) ────────────────────────────────────────────────────────
-- Without these the worker prints "NO stuck-job recovery" and a worker that
-- dies mid-render locks the workspace out of publishing after three orphans.

insert into _inv(name, pass, note)
select 'render_jobs has the lease columns the worker writes (0015)',
       count(*) = 3, coalesce(string_agg(column_name || ' ' || data_type, ', ' order by column_name), '(none)')
from information_schema.columns
where table_schema = 'public' and table_name = 'render_jobs'
  and column_name in ('lease_expires_at', 'attempts', 'worker_id');

insert into _inv(name, pass, note)
select 'render_jobs.attempts is NOT NULL default 0 (the reaper counts on it)',
       count(*) = 1, ''
from information_schema.columns
where table_schema = 'public' and table_name = 'render_jobs' and column_name = 'attempts'
  and is_nullable = 'NO' and column_default like '%0%';

insert into _inv(name, pass, note)
select 'the claim/reclaim/reaper index exists', count(*) = 1,
       coalesce(string_agg(indexdef, ' '), '(missing)')
from pg_indexes
where schemaname = 'public' and tablename = 'render_jobs' and indexname = 'idx_jobs_lease';

-- An orphan is not in flight. The predicate must lease-check `processing` ONLY:
-- lease-checking created/queued/claimed would weaken the 3-in-flight cap, and
-- dropping the `is null` arm would silently uncap pre-0015 rows.
insert into _inv(name, pass, note)
select 'create_render_job excludes expired leases from the in-flight cap',
       coalesce(bool_and(prosrc like '%lease_expires_at is null or rj.lease_expires_at > now()%'
                     and prosrc like '%rj.status in (''created'',''queued'',''claimed'')%'
                     and prosrc not like '%rj.status in (''created'',''queued'',''claimed'',''processing'')%'), false),
       ''
from pg_proc where proname = 'create_render_job';

insert into _inv(name, pass, note)
select 'create_render_job still caps at 3 in flight and is org-locked',
       coalesce(bool_and(prosrc like '%v_active >= 3%' and prosrc like '%pg_advisory_xact_lock%'
                     and prosrc like '%rj.source = ''worker''%'), false), ''
from pg_proc where proname = 'create_render_job';

-- ── Compliance spine (0012): AI provenance + disclosure ──────────────────────
-- The compliance wedge is the product's moat and its legal exposure at once
-- (CA AB 723, NorthstarMLS 10 Jul 2026, WI Act 69, HUD 2024). These assert the
-- shape the edge functions and the public tour depend on.

insert into _inv(name, pass, note)
select 'media_provenance exists with the disclosure columns',
       count(*) = 14, format('%s columns', count(*))
from information_schema.columns
where table_schema = 'public' and table_name = 'media_provenance';

insert into _inv(name, pass, note)
select 'media_provenance.disclosure is NOT NULL (a row can never be silent)',
       count(*) = 1, ''
from information_schema.columns
where table_schema = 'public' and table_name = 'media_provenance'
  and column_name = 'disclosure' and is_nullable = 'NO';

insert into _inv(name, pass, note)
select 'media_provenance has RLS enabled', coalesce(bool_and(relrowsecurity), false), ''
from pg_class where oid = 'public.media_provenance'::regclass;

insert into _inv(name, pass, note)
select 'media_provenance is member-read only (one SELECT policy on is_org_member)',
       count(*) = 1, coalesce(string_agg(polname || ':' || polcmd::text, ', '), '(none)')
from pg_policy
where polrelid = 'public.media_provenance'::regclass
  and polcmd = 'r'
  and pg_get_expr(polqual, polrelid) like '%is_org_member%';

-- anon must not reach the table at all: the PUBLIC tour reads it through the
-- service-role client and returns only the disclosure/label/URL subset.
insert into _inv(name, pass, note)
select 'anon has NO privilege on media_provenance',
       not has_table_privilege('anon', 'public.media_provenance', 'SELECT')
       and not has_table_privilege('anon', 'public.media_provenance', 'INSERT'), '';

insert into _inv(name, pass, note)
select 'authenticated may SELECT but never write media_provenance',
       has_table_privilege('authenticated', 'public.media_provenance', 'SELECT')
       and not has_table_privilege('authenticated', 'public.media_provenance', 'INSERT')
       and not has_table_privilege('authenticated', 'public.media_provenance', 'UPDATE')
       and not has_table_privilege('authenticated', 'public.media_provenance', 'DELETE'), '';

insert into _inv(name, pass, note)
select 'record_provenance / set_provenance_media are role-gated definers',
       count(*) = 2, format('%s of 2 found', count(*))
from pg_proc
where proname in ('record_provenance', 'set_provenance_media')
  and prosecdef and prosrc like '%org_role%';

insert into _inv(name, pass, note)
select 'the provenance RPCs are NOT executable by anon',
       not has_function_privilege('anon', 'public.record_provenance(uuid,text,text,text,text,text,text,uuid,uuid,uuid)', 'EXECUTE')
       and not has_function_privilege('anon', 'public.set_provenance_media(uuid,uuid,uuid,text)', 'EXECUTE'), '';

insert into _inv(name, pass, note)
select 'the provenance RPCs ARE executable by authenticated',
       has_function_privilege('authenticated', 'public.record_provenance(uuid,text,text,text,text,text,text,uuid,uuid,uuid)', 'EXECUTE')
       and has_function_privilege('authenticated', 'public.set_provenance_media(uuid,uuid,uuid,text)', 'EXECUTE'), '';

-- The caller never supplies the public sentence: record_provenance derives it.
insert into _inv(name, pass, note)
select 'record_provenance takes NO caller-supplied disclosure',
       coalesce(bool_and(args not like '%p_disclosure%'), false),
       coalesce(string_agg(args, ' | '), '(function missing)')
from (select pg_get_function_identity_arguments(oid) as args
        from pg_proc where proname = 'record_provenance') s;

insert into _inv(name, pass, note)
select 'record_provenance derives the disclosure via provenance_disclosure()',
       count(*) = 1, ''
from pg_proc where proname = 'record_provenance' and prosrc like '%provenance_disclosure(%';

-- HousingWire's recommended wording, verbatim. The tour host renders this
-- sentence for every aerial; changing it here changes what the law sees.
insert into _inv(name, pass, note)
select 'an aerial discloses the exact simulated-movement sentence',
       public.provenance_disclosure('aerial') like
         'Drone-style movement is simulated. No drone footage was captured.%',
       left(public.provenance_disclosure('aerial'), 66);

insert into _inv(name, pass, note)
select 'every provenance kind has a non-empty disclosure',
       bool_and(length(coalesce(public.provenance_disclosure(k), '')) > 20),
       string_agg(k, ', ')
from unnest(array['photo_edit','virtual_stage','declutter','aerial','reel','other']) as k;

-- Media keys are SERVER-DERIVED from capture_asset ids (the poster anti-spoof
-- rule from 0008): a free-text key would let a caller point "View original" at
-- any object in the public bucket.
insert into _inv(name, pass, note)
select 'the provenance RPCs take ASSET IDS, never free-text R2 keys',
       coalesce(bool_and(args like '%uuid%' and args not like '%_key text%'), false),
       coalesce(string_agg(proname || '(' || args || ')', ' | '), '(missing)')
from (select proname, pg_get_function_identity_arguments(oid) as args
        from pg_proc where proname in ('record_provenance','set_provenance_media')) s;

insert into _inv(name, pass, note)
select 'provenance_asset_key is internal (no role may execute it)',
       not has_function_privilege('anon', 'public.provenance_asset_key(uuid,uuid)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.provenance_asset_key(uuid,uuid)', 'EXECUTE')
       and not has_function_privilege('service_role', 'public.provenance_asset_key(uuid,uuid)', 'EXECUTE'), '';

insert into _inv(name, pass, note)
select 'provenance rows are indexed for the tour + the audit export',
       count(*) >= 2, string_agg(indexname, ', ')
from pg_indexes
where schemaname = 'public' and tablename = 'media_provenance'
  and indexname in ('idx_provenance_listing', 'idx_provenance_org');

-- ── Disclosure outcome (0016): staged is what RAN, not what was asked for ────
-- `renders.staged` drives the "✦ Virtually staged" chip and the disclosure
-- sheet on the public tour. MLS virtual-media rules and California AB 723 make
-- both errors a compliance failure: stamping an unaltered tour is false
-- advertising, not stamping an altered one is a disclosure violation.

insert into _inv(name, pass, note)
select 'render_jobs.enhancement_result is jsonb (the worker''s outcome record)',
       count(*) = 1, coalesce(string_agg(data_type, ','), '(missing)')
from information_schema.columns
where table_schema = 'public' and table_name = 'render_jobs'
  and column_name = 'enhancement_result' and data_type = 'jsonb';

insert into _inv(name, pass, note)
select 'renders.hero_key exists (the Seedance hero clip has somewhere to live)',
       count(*) = 1, ''
from information_schema.columns
where table_schema = 'public' and table_name = 'renders'
  and column_name = 'hero_key' and data_type = 'text';

-- The new columns must inherit the existing table grants, never widen them.
insert into _inv(name, pass, note)
select 'the 0016 columns granted anon nothing beyond the table''s existing SELECT',
       has_column_privilege('anon', 'public.renders', 'hero_key', 'SELECT')
       and not has_column_privilege('anon', 'public.renders', 'hero_key', 'UPDATE')
       and not has_column_privilege('anon', 'public.render_jobs', 'enhancement_result', 'UPDATE')
       and not has_column_privilege('authenticated', 'public.render_jobs', 'enhancement_result', 'UPDATE'), '';

insert into _inv(name, pass, note)
select 'publish_render derives staged from the pipeline OUTCOME',
       coalesce(bool_and(prosrc like '%enhancement_result ? ''staged''%'), false), ''
from pg_proc where proname = 'publish_render';

-- The fallback is what stops an under-disclosure: a worker job whose result
-- never landed still falls back to the requested toggles (over-disclose, the
-- survivable direction), and only a source='app' job — no AI path exists there —
-- resolves to false without a recorded outcome.
insert into _inv(name, pass, note)
select 'publish_render keeps the intent fallback for a worker job with no outcome',
       coalesce(bool_and(prosrc like '%v_job.enhancements->>''declutter''%'
                     and prosrc like '%''as_is'',''as-is'',''asis'',''none''%'
                     and prosrc like '%v_job.source, ''worker'') = ''app''%'), false), ''
from pg_proc where proname = 'publish_render';

-- No live tour may be stamped without a reason to be: an app-source publish with
-- no recorded enhancement outcome must never carry the disclosure.
insert into _inv(name, pass, note)
select 'no app-published tour is stamped staged without a pipeline outcome',
       count(*) = 0, format('%s falsely stamped tours', count(*))
from renders r join render_jobs j on j.id = r.job_id
where r.staged and j.source = 'app' and j.enhancement_result is null;

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
                    'cost_ledger','leads','metering','rate_limits','deletion_requests',
                    'plan_entitlements');

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

-- ── MUTATING: publish / quota / lifecycle fixture (cleans up after itself) ────
-- Two throwaway users go through the REAL signup trigger, then every RPC is
-- exercised as those users (auth.uid() reads request.jwt.claims, exactly as
-- PostgREST sets it). Runs on a plain Postgres prepared with ci-bootstrap.sql
-- and on a Supabase branch alike. Never run on production.

do $fx$
declare
  u  uuid := '0f1e2d3c-4b5a-4968-8776-655443322110';
  u2 uuid := '0f1e2d3c-4b5a-4968-8776-655443322111';
  v_org uuid; v_org2 uuid; v_listing uuid; v_asset uuid; v_poster uuid;
  v_job render_jobs; v_job2 render_jobs; v_render renders; v_lead leads;
  v_n int; v_cnt int; v_name text;
begin
  -- Defensive cleanup from an aborted earlier run (leads only SET NULL on
  -- listing/org deletion, so they are removed explicitly).
  delete from leads where email = '_inv-lead@example.com';
  delete from orgs where id in (select org_id from memberships where user_id in (u, u2));
  delete from auth.users where id in (u, u2);

  insert into auth.users (id, email, raw_user_meta_data)
    values (u, 'inv-fixture@example.com', '{"full_name":"Fixture Agent"}');
  insert into auth.users (id, email, raw_user_meta_data)
    values (u2, 'inv-fixture2@example.com', '{}');
  select m.org_id into v_org  from memberships m where m.user_id = u;
  select m.org_id into v_org2 from memberships m where m.user_id = u2;

  select name into v_name from orgs where id = v_org;
  insert into _inv(name, pass, note)
    values ('signup names the org from user metadata', v_name = 'Fixture Agent', v_name);
  select name into v_name from orgs where id = v_org2;
  insert into _inv(name, pass, note)
    values ('signup without a name uses My business, never the email', v_name = 'My business', v_name);
  insert into _inv(name, pass, note)
    select 'signup starts a 7-day trial', plan = 'trial' and trial_ends_at > now() + interval '6 days', plan
      from orgs where id = v_org;

  -- Act as the first user.
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);

  insert into listings (org_id, agent_id, address) values (v_org, u, '1 Fixture Way') returning id into v_listing;
  insert into capture_assets (listing_id, kind, bucket, storage_key, bytes, uploaded, duration_s)
    values (v_listing, 'video', 'renders', 'renders/_inv/a.mp4', 1000, true, 30) returning id into v_asset;
  insert into capture_assets (listing_id, kind, bucket, storage_key, bytes, uploaded)
    values (v_listing, 'photo', 'renders', 'renders/_inv/p.jpg', 100, true) returning id into v_poster;

  -- App publishes are free: the trial cap is 1 render/month and BOTH must succeed.
  v_job  := create_render_job(v_listing, v_asset, 'smooth', '{}', '_inv-app-000001', 'app');
  v_job2 := create_render_job(v_listing, v_asset, 'smooth', '{}', '_inv-app-000002', 'app');
  insert into _inv(name, pass, note)
    values ('app-source jobs are stored as source=app', v_job.source = 'app' and v_job2.source = 'app', v_job.source);

  v_render := publish_render(v_job.id, 30, 2.0,
               '[{"label":"Kitchen","t_ms":1000,"sort":99999},{"label":"","t_ms":5}]'::jsonb, v_poster);
  insert into _inv(name, pass, note)
    values ('publish_render stores the verified poster key',
            v_render.poster_key = 'renders/_inv/p.jpg', coalesce(v_render.poster_key, '<null>'));
  select count(*) into v_cnt from capture_chapters where asset_id = v_asset;
  insert into _inv(name, pass, note)
    values ('chapters: empty labels dropped, sort clamped to smallint',
            v_cnt = 1 and (select max(sort) from capture_chapters where asset_id = v_asset) = 999, v_cnt::text);
  insert into _inv(name, pass, note)
    select 'publish flips the job to ready', status = 'ready', status from render_jobs where id = v_job.id;

  begin
    perform publish_render(v_job2.id, 30, 2.0, '[]', v_asset);  -- a video is not a poster
    insert into _inv(name, pass, note) values ('publish_render rejects a non-photo poster', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note) values ('publish_render rejects a non-photo poster', sqlerrm like 'RP400%', sqlerrm);
  end;

  begin
    perform fail_render_job(v_job.id, 'boom');
    insert into _inv(name, pass, note) values ('fail_render_job refuses a published job', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note) values ('fail_render_job refuses a published job', sqlerrm like 'RP409%', sqlerrm);
  end;
  v_job2 := fail_render_job(v_job2.id, 'publish failed in test');
  insert into _inv(name, pass, note)
    values ('fail_render_job marks an unpublished app job failed',
            v_job2.status = 'failed' and v_job2.error->>'message' = 'publish failed in test', v_job2.status);

  -- Worker jobs DO count: the first fits the trial cap, the second must hit RP402.
  v_job := create_render_job(v_listing, v_asset, 'smooth', '{}', '_inv-wrk-000001', 'worker');
  insert into _inv(name, pass, note)
    values ('worker job #1 fits the trial cap (app jobs did not count)', v_job.source = 'worker', v_job.source);
  begin
    perform create_render_job(v_listing, v_asset, 'smooth', '{}', '_inv-wrk-000002', 'worker');
    insert into _inv(name, pass, note) values ('worker job #2 exceeds the trial cap (RP402)', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note) values ('worker job #2 exceeds the trial cap (RP402)', sqlerrm like 'RP402%', sqlerrm);
  end;
  v_job2 := create_render_job(v_listing, v_asset, 'smooth', '{}', '_inv-app-000003', 'app');
  insert into _inv(name, pass, note)
    values ('app publish still allowed at the render cap', v_job2.source = 'app', '');

  -- Idempotent replay returns the original job, not a new one.
  v_job2 := create_render_job(v_listing, v_asset, 'smooth', '{}', '_inv-app-000003', 'app');
  insert into _inv(name, pass, note)
    values ('same Idempotency-Key replays the same job',
            (select count(*) from render_jobs where idem_key = '_inv-app-000003') = 1, '');

  select * into v_render from renders where job_id = (select id from render_jobs where idem_key = '_inv-app-000001');
  v_n := set_render_chapters(v_render.id, '[{"label":"Living","t_ms":0,"sort":0},{"label":"Patio","t_ms":9000,"sort":1}]'::jsonb);
  insert into _inv(name, pass, note)
    values ('set_render_chapters replaces chapters',
            v_n = 2 and (select count(*) from capture_chapters where asset_id = v_asset) = 2, v_n::text);

  insert into leads (render_id, listing_id, org_id, name, email)
    values (v_render.id, v_listing, v_org, 'Lead', '_inv-lead@example.com') returning * into v_lead;
  insert into _inv(name, pass, note) values ('leads default to status new', v_lead.status = 'new', v_lead.status);
  v_lead := set_lead_status(v_lead.id, 'contacted');
  insert into _inv(name, pass, note) values ('set_lead_status updates the status', v_lead.status = 'contacted', v_lead.status);
  begin
    perform set_lead_status(v_lead.id, 'bogus');
    insert into _inv(name, pass, note) values ('set_lead_status rejects unknown statuses', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note) values ('set_lead_status rejects unknown statuses', sqlerrm like 'RP400%', sqlerrm);
  end;

  -- A member of ANOTHER org must not reach this org's rows through the RPCs.
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  begin
    perform set_lead_status(v_lead.id, 'won');
    insert into _inv(name, pass, note) values ('RPCs are org-scoped (other org gets RP404)', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note) values ('RPCs are org-scoped (other org gets RP404)', sqlerrm like 'RP404%', sqlerrm);
  end;
  begin
    perform set_render_chapters(v_render.id, '[]');
    insert into _inv(name, pass, note) values ('chapters RPC is org-scoped (other org gets RP404)', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note) values ('chapters RPC is org-scoped (other org gets RP404)', sqlerrm like 'RP404%', sqlerrm);
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);

  update listings set deleted_at = now() where id = v_listing;
  select count(*) into v_cnt from renders where listing_id = v_listing and published_at is not null;
  insert into _inv(name, pass, note)
    values ('soft-deleting a listing unpublishes its renders', v_cnt = 0, v_cnt::text);

  -- Cleanup (children cascade from listings/orgs; profiles cascade from auth.users;
  -- leads are only SET NULL, so delete them first).
  perform set_config('request.jwt.claims', '', true);
  delete from leads where id = v_lead.id;
  delete from listings where id = v_listing;
  delete from orgs where id in (v_org, v_org2);
  delete from auth.users where id in (u, u2);
end $fx$;

-- ── MUTATING: job lease + disclosure outcome (0015/0016) ─────────────────────
-- A third throwaway user on a plan with head-room (the trial cap of 1 would
-- mask RP429 behind RP402), exercising the two behaviours 0015/0016 changed.
-- Worker jobs point at an UPLOADS-bucket asset, which is what the worker's own
-- claim filter requires; the publish path needs a RENDERS-bucket one.

do $lease$
declare
  u3 uuid := '0f1e2d3c-4b5a-4968-8776-655443322112';
  v_org uuid; v_listing uuid; v_src uuid; v_pub uuid;
  j1 render_jobs; j2 render_jobs; j3 render_jobs; jx render_jobs;
  r renders;
begin
  delete from orgs where id in (select org_id from memberships where user_id = u3);
  delete from auth.users where id = u3;
  insert into auth.users (id, email, raw_user_meta_data)
    values (u3, 'inv-fixture3@example.com', '{"full_name":"Lease Fixture"}');
  select m.org_id into v_org from memberships m where m.user_id = u3;
  update orgs set plan = 'team', trial_ends_at = null where id = v_org;
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);

  insert into listings (org_id, agent_id, address) values (v_org, u3, '2 Lease Way') returning id into v_listing;
  insert into capture_assets (listing_id, kind, bucket, storage_key, bytes, uploaded, duration_s)
    values (v_listing, 'video', 'uploads', 'uploads/_inv/src.mp4', 1000, true, 30) returning id into v_src;
  insert into capture_assets (listing_id, kind, bucket, storage_key, bytes, uploaded, duration_s)
    values (v_listing, 'video', 'renders', 'renders/_inv/out.mp4', 1000, true, 30) returning id into v_pub;

  -- ── in-flight cap: three LIVE leases block, three EXPIRED ones do not ──
  j1 := create_render_job(v_listing, v_src, 'smooth', '{}', '_inv-lease-00001', 'worker');
  j2 := create_render_job(v_listing, v_src, 'smooth', '{}', '_inv-lease-00002', 'worker');
  j3 := create_render_job(v_listing, v_src, 'smooth', '{}', '_inv-lease-00003', 'worker');

  update render_jobs set status = 'processing', started_at = now(), worker_id = '_inv-live',
         attempts = 1, lease_expires_at = now() + interval '10 minutes'
   where id in (j1.id, j2.id, j3.id);
  begin
    perform create_render_job(v_listing, v_src, 'smooth', '{}', '_inv-lease-00004', 'worker');
    insert into _inv(name, pass, note)
      values ('3 LIVE worker jobs still hit the in-flight cap (RP429)', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note)
      values ('3 LIVE worker jobs still hit the in-flight cap (RP429)', sqlerrm like 'RP429%', sqlerrm);
  end;

  -- A pre-0015 row (no lease at all) must keep counting: never silently uncapped.
  update render_jobs set lease_expires_at = null, worker_id = null
   where id in (j1.id, j2.id, j3.id);
  begin
    perform create_render_job(v_listing, v_src, 'smooth', '{}', '_inv-lease-00005', 'worker');
    insert into _inv(name, pass, note)
      values ('a processing job with NO lease still counts (pre-0015 rows)', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note)
      values ('a processing job with NO lease still counts (pre-0015 rows)', sqlerrm like 'RP429%', sqlerrm);
  end;

  update render_jobs set lease_expires_at = now() - interval '1 minute', worker_id = '_inv-dead'
   where id in (j1.id, j2.id, j3.id);
  jx := create_render_job(v_listing, v_src, 'smooth', '{}', '_inv-lease-00006', 'worker');
  insert into _inv(name, pass, note)
    values ('3 ORPHANED worker jobs do NOT lock the workspace out (F-G-05)',
            jx.id is not null and jx.status = 'created', coalesce(jx.status, '<none>'));

  -- queued/created/claimed are never lease-exempt, whatever the lease says.
  update render_jobs set status = 'queued', lease_expires_at = now() - interval '1 day'
   where id in (j1.id, j2.id, j3.id);
  delete from render_jobs where id = jx.id;
  begin
    perform create_render_job(v_listing, v_src, 'smooth', '{}', '_inv-lease-00007', 'worker');
    insert into _inv(name, pass, note)
      values ('a stale lease on a QUEUED job does not exempt it', false, 'no error raised');
  exception when others then
    insert into _inv(name, pass, note)
      values ('a stale lease on a QUEUED job does not exempt it', sqlerrm like 'RP429%', sqlerrm);
  end;
  delete from render_jobs where listing_id = v_listing;

  -- ── disclosure: staged follows the OUTCOME ──
  -- The pipeline shipped a real edit → the tour MUST carry the disclosure.
  jx := create_render_job(v_listing, v_pub, 'smooth', '{}', '_inv-disc-00001', 'worker');
  update render_jobs set enhancement_result = '{"ran":true,"staged":true}'::jsonb where id = jx.id;
  r := publish_render(jx.id, 30, 2.0, '[]', null);
  insert into _inv(name, pass, note)
    values ('an edit that actually shipped IS disclosed as staged', r.staged is true, r.staged::text);

  -- Toggles ticked, pipeline skipped/denied → stamping it would be false
  -- advertising of an add-on that never ran.
  jx := create_render_job(v_listing, v_pub, 'smooth', '{"declutter":true,"style":"modern"}',
                          '_inv-disc-00002', 'worker');
  update render_jobs set enhancement_result = '{"ran":true,"staged":false,"reason":"qc_denied"}'::jsonb
   where id = jx.id;
  r := publish_render(jx.id, 30, 2.0, '[]', null);
  insert into _inv(name, pass, note)
    values ('an UNALTERED tour is never stamped, even with the toggles on', r.staged is false, r.staged::text);

  -- App publish: no worker, no AI path, no outcome → not staged.
  jx := create_render_job(v_listing, v_pub, 'smooth', '{}', '_inv-disc-00003', 'app');
  r := publish_render(jx.id, 30, 2.0, '[]', null);
  insert into _inv(name, pass, note)
    values ('an app-published tour with no pipeline outcome is not staged', r.staged is false, r.staged::text);

  jx := create_render_job(v_listing, v_pub, 'smooth', '{"declutter":true}', '_inv-disc-00004', 'app');
  r := publish_render(jx.id, 30, 2.0, '[]', null);
  insert into _inv(name, pass, note)
    values ('app toggles alone never stamp a tour (nothing on that path alters pixels)',
            r.staged is false, r.staged::text);

  -- Worker job whose result never landed: fall back to intent rather than
  -- silently under-disclosing a staging that may really have happened.
  jx := create_render_job(v_listing, v_pub, 'smooth', '{"declutter":true}', '_inv-disc-00005', 'worker');
  r := publish_render(jx.id, 30, 2.0, '[]', null);
  insert into _inv(name, pass, note)
    values ('a worker job with no recorded outcome falls back to intent (over-discloses)',
            r.staged is true, r.staged::text);

  jx := create_render_job(v_listing, v_pub, 'smooth', '{"style":"as_is"}', '_inv-disc-00006', 'worker');
  r := publish_render(jx.id, 30, 2.0, '[]', null);
  insert into _inv(name, pass, note)
    values ('the as_is fallback still resolves to not staged', r.staged is false, r.staged::text);

  update renders set hero_key = 'renders/_inv/x-hero.mp4' where id = r.id;
  insert into _inv(name, pass, note)
    select 'renders.hero_key stores the worker''s hero clip key',
           hero_key = 'renders/_inv/x-hero.mp4', coalesce(hero_key, '<null>')
      from renders where id = r.id;

  perform set_config('request.jwt.claims', '', true);
  delete from listings where id = v_listing;
  delete from orgs where id = v_org;
  delete from auth.users where id = u3;
end $lease$;

-- ── 0017: the owner/admin role (spend console) ───────────────────────────────
-- Two halves. STATIC: the flag is where it should be, is not client-writable,
-- the helper is a pinned definer, the admin policies are SELECT-only and every
-- pre-existing tenant policy is byte-for-byte what it was. MUTATING: three
-- throwaway users prove promotion-on-signup, promotion-of-an-existing-account,
-- and — the security-critical one — that a NON-ADMIN with a valid JWT cannot
-- read another org's cost_ledger rows while an admin can. The cross-org reads
-- are executed AS THE `authenticated` ROLE; run as the table owner they would
-- bypass RLS and prove nothing.

insert into _inv(name, pass, note)
select 'user rows carry is_admin (profiles is where user rows live)',
       count(*) = 1, format('%s column(s)', count(*))
from information_schema.columns
where table_schema = 'public' and table_name = 'profiles' and column_name = 'is_admin'
  and data_type = 'boolean' and is_nullable = 'NO';

-- The escalation that adding the column would otherwise have opened: profiles
-- is tenant-writable through the "own profile" policy, so the UPDATE grant must
-- be column-scoped and INSERT/DELETE must be gone (delete-then-insert).
insert into _inv(name, pass, note)
select 'is_admin is NOT client-writable, and the display columns still are',
       not has_column_privilege('authenticated','public.profiles','is_admin','UPDATE')
       and not has_column_privilege('authenticated','public.profiles','apple_refresh_token','UPDATE')
       and not has_table_privilege('authenticated','public.profiles','INSERT')
       and not has_table_privilege('authenticated','public.profiles','DELETE')
       and has_column_privilege('authenticated','public.profiles','name','UPDATE')
       and has_column_privilege('authenticated','public.profiles','phone','UPDATE')
       and has_column_privilege('authenticated','public.profiles','avatar_url','UPDATE'), '';

insert into _inv(name, pass, note)
select 'admin_allowlist is service-role only (RLS on, no policies, no tenant grants)',
       (select relrowsecurity from pg_class where oid = 'public.admin_allowlist'::regclass)
       and (select count(*) from pg_policy where polrelid = 'public.admin_allowlist'::regclass) = 0
       and not has_table_privilege('authenticated','public.admin_allowlist','SELECT')
       and not has_table_privilege('authenticated','public.admin_allowlist','INSERT')
       and not has_table_privilege('anon','public.admin_allowlist','SELECT'), '';

insert into _inv(name, pass, note)
select 'the allowlist holds exactly the seeded owner, normalised',
       count(*) = 1 and bool_and(email = 'aaron@pilk.ai'),
       coalesce(string_agg(email, ', '), '(empty)')
from admin_allowlist;

insert into _inv(name, pass, note)
select 'is_admin() is a SECURITY DEFINER with search_path pinned to public',
       count(*) = 1, format('%s match(es)', count(*))
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.proname = 'is_admin' and p.pronargs = 0
  and p.prosecdef
  and 'search_path=public' = any(p.proconfig);

-- Same reasoning as is_org_member (0005b): a helper used inside an RLS policy
-- must stay executable by every role that can reach the table, or an anonymous
-- read turns into "permission denied for function" instead of zero rows.
insert into _inv(name, pass, note)
select 'RLS helper is_admin stays executable by authenticated and anon',
       has_function_privilege('authenticated','public.is_admin()','EXECUTE')
       and has_function_privilege('anon','public.is_admin()','EXECUTE'), '';

insert into _inv(name, pass, note)
select 'every admin policy is SELECT-only and predicated solely on is_admin()',
       count(*) = 4
       and bool_and(polcmd = 'r' and polpermissive)
       and bool_and(pg_get_expr(polqual, polrelid) = 'is_admin()')
       and bool_and(polwithcheck is null),
       format('%s of 4: %s', count(*), coalesce(string_agg(polname, ', '), ''))
from pg_policy
where polname in ('admin ledger read','admin jobs read','admin orgs read','admin rate limits read');

-- The whole safety argument for 0017: no tenant policy was dropped, rewritten
-- or widened. These four are quoted from 0001/0007 and must still read exactly
-- this way, so a non-admin's visible rows are unchanged by construction.
insert into _inv(name, pass, note)
select 'tenant read policies are untouched by the admin grants',
       coalesce(bool_and(ok), false),
       coalesce(string_agg(polname, ', ') filter (where not ok), '')
from (
  select p.polname,
         pg_get_expr(p.polqual, p.polrelid) = x.expected and p.polcmd = 'r' as ok
    from pg_policy p
    join (values
            ('org ledger',        'is_org_member(org_id)'),
            ('member orgs read',  'is_org_member(id)'),
            ('entitlements readable', 'true')
         ) as x(name, expected) on x.name = p.polname
) s;

insert into _inv(name, pass, note)
select 'plan_entitlements is already world-readable, so admins need no new policy',
       (select count(*) from pg_policy
         where polrelid = 'public.plan_entitlements'::regclass and polcmd = 'r') = 1
       and has_table_privilege('authenticated','public.plan_entitlements','SELECT'), '';

-- rate_limits: SELECT granted so the admin policy can take effect, writes still
-- revoked, bump_rate() still service-role only.
insert into _inv(name, pass, note)
select 'rate_limits: SELECT granted for the admin policy, every write still revoked',
       has_table_privilege('authenticated','public.rate_limits','SELECT')
       and not has_table_privilege('authenticated','public.rate_limits','INSERT')
       and not has_table_privilege('authenticated','public.rate_limits','UPDATE')
       and not has_table_privilege('authenticated','public.rate_limits','DELETE')
       and not has_table_privilege('anon','public.rate_limits','SELECT'), '';

-- 0010 §5 re-installs its own pre-0011 trigger body unless the installed source
-- says 'My business' AND does NOT contain `coalesce(new.email`. 0017 rewrites
-- this function, so it has to keep clearing that bar or a 0010 replay silently
-- reverts BOTH the org-name fix and the admin promotion.
insert into _inv(name, pass, note)
select 'handle_new_user promotes from the allowlist AND survives a 0010 replay',
       count(*) = 1, format('%s match(es)', count(*))
from pg_proc
where proname = 'handle_new_user'
  and prosrc like '%admin_allowlist%'
  and prosrc like '%My business%'
  and prosrc not like '%coalesce(new.email%';

-- ── MUTATING: signup promotion, back-fill, and the cross-org read boundary ────

do $adm$
declare
  uA uuid := '0f1e2d3c-4b5a-4968-8776-6554433221a0';  -- allowlisted, signs up now
  uB uuid := '0f1e2d3c-4b5a-4968-8776-6554433221a1';  -- exists first, allowlisted later
  uC uuid := '0f1e2d3c-4b5a-4968-8776-6554433221a2';  -- ordinary tenant, another org
  vA uuid; vB uuid; vC uuid;
  lA uuid; lC uuid; jA uuid; jC uuid; ledA uuid; ledC uuid; ledApp uuid;
  b boolean; n int; m int;
begin
  delete from cost_ledger where meta->>'_inv' = 'admin';
  delete from orgs where id in (select org_id from memberships where user_id in (uA,uB,uC));
  delete from auth.users where id in (uA,uB,uC);
  delete from admin_allowlist where email = '_inv-existing@example.com';

  -- (a) an allowlisted e-mail becomes an admin at SIGN-UP — no password, no
  -- secret in the app, mixed case on purpose (the allowlist is normalised).
  insert into auth.users (id, email, raw_user_meta_data)
    values (uA, 'AARON@Pilk.ai', '{"full_name":"Owner"}');
  select p.is_admin into b from profiles p where p.id = uA;
  insert into _inv(name, pass, note)
    values ('an allowlisted sign-up e-mail becomes an admin (case-insensitive)',
            b is true, coalesce(b::text,'<null>'));

  insert into auth.users (id, email, raw_user_meta_data)
    values (uC, '_inv-tenant@example.com', '{"full_name":"Tenant"}');
  select p.is_admin into b from profiles p where p.id = uC;
  insert into _inv(name, pass, note)
    values ('an ordinary sign-up is NOT an admin', b is false, coalesce(b::text,'<null>'));

  -- (b) an account that ALREADY EXISTS when the allowlist gains it is promoted
  -- by the migration's back-fill (this is how the owner's real account works).
  insert into auth.users (id, email, raw_user_meta_data)
    values (uB, '_inv-existing@example.com', '{"full_name":"Existing"}');
  select p.is_admin into b from profiles p where p.id = uB;
  insert into _inv(name, pass, note)
    values ('precondition: the pre-existing account starts as a non-admin',
            b is false, coalesce(b::text,'<null>'));

  insert into admin_allowlist (email, note) values ('_inv-existing@example.com', 'invariants fixture');

  -- verbatim copies of migration 0017 §6
  update public.profiles p
     set is_admin = true
    from auth.users u
    join public.admin_allowlist a on a.email = coalesce(lower(btrim(u.email)), '')
   where u.id = p.id and p.is_admin is not true;
  update public.profiles p
     set is_admin = true
    from public.admin_allowlist a
   where a.email = coalesce(lower(btrim(p.email)), '') and p.is_admin is not true;

  select p.is_admin into b from profiles p where p.id = uB;
  insert into _inv(name, pass, note)
    values ('the 0017 back-fill promotes an already-existing allowlisted account',
            b is true, coalesce(b::text,'<null>'));

  update public.profiles p set is_admin = true
    from public.admin_allowlist a
   where a.email = coalesce(lower(btrim(p.email)), '') and p.is_admin is not true;
  get diagnostics n = ROW_COUNT;
  insert into _inv(name, pass, note)
    values ('the 0017 back-fill is idempotent (a replay updates 0 rows)', n = 0, n::text);

  -- One ledger row and one usage counter in EACH of two different orgs.
  select mm.org_id into vA from memberships mm where mm.user_id = uA;
  select mm.org_id into vB from memberships mm where mm.user_id = uB;
  select mm.org_id into vC from memberships mm where mm.user_id = uC;

  insert into listings (org_id, agent_id, address) values (vA, uA, '1 Admin Way')  returning id into lA;
  insert into listings (org_id, agent_id, address) values (vC, uC, '1 Tenant Way') returning id into lC;
  insert into render_jobs (listing_id, tier, status, source) values (lA,'smooth','created','worker') returning id into jA;
  insert into render_jobs (listing_id, tier, status, source) values (lC,'smooth','created','worker') returning id into jC;
  insert into cost_ledger (job_id, org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta)
    values (jA, vA, 'restage', 'gemini', 'gemini-2.5-flash-image', 1, 3.9, 3.9, '{"_inv":"admin"}')
    returning id into ledA;
  insert into cost_ledger (job_id, org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta)
    values (jC, vC, 'hero', 'fal', 'seedance', 5, 4.8, 24.0, '{"_inv":"admin"}')
    returning id into ledC;

  -- F-E-15: an in-app AI generation (POST /ai-photo, /ai-video) has NO render
  -- job, so its cost_ledger row carries job_id = NULL and is scoped to the org
  -- alone. The whole coverage heal rests on this row being (a) insertable at all
  -- and (b) under the same tenant/admin RLS as a job-scoped row. Prove both.
  insert into cost_ledger (job_id, org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta)
    values (null, vA, 'photo_edit', 'gemini', 'gemini-2.5-flash-image', 1, 3.9, 3.9, '{"_inv":"admin","app_ai":true}')
    returning id into ledApp;
  insert into _inv(name, pass, note)
    values ('an app-AI cost row (job_id NULL, org-scoped) is insertable',
            ledApp is not null
              and exists (select 1 from cost_ledger where id = ledApp and job_id is null and org_id = vA),
            coalesce(ledApp::text, '<null>'));

  insert into rate_limits (key, window_start, count, window_seconds)
    values ('aiphotomo:'||vA::text, now(), 4, 2592000),
           ('aiphotomo:'||vC::text, now(), 7, 2592000)
    on conflict (key) do update set count = excluded.count;

  -- ══ the security-critical assertion ═══════════════════════════════════════
  -- A hostile client holding a VALID non-admin JWT. Run as `authenticated`, so
  -- RLS is actually in force (as the owner it would be bypassed entirely).
  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uC, 'role','authenticated')::text, true);
  select count(*) filter (where id = ledC), count(*) filter (where id = ledA)
    into n, m from cost_ledger;
  reset role;
  insert into _inv(name, pass, note)
    values ('a NON-ADMIN cannot read another org''s cost_ledger rows',
            n = 1 and m = 0, format('own=%s foreign=%s (expected 1 / 0)', n, m));

  -- F-E-15: the same boundary holds for the job_id-NULL app-AI row (org vA):
  -- a tenant of another org sees it exactly zero times.
  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uC, 'role','authenticated')::text, true);
  select count(*) into n from cost_ledger where id = ledApp;
  reset role;
  insert into _inv(name, pass, note)
    values ('a NON-ADMIN cannot read another org''s app-AI (job_id NULL) cost row',
            n = 0, n::text);

  set role authenticated; select count(*) into n from orgs where id = vA; reset role;
  insert into _inv(name, pass, note)
    values ('a non-admin cannot read another org''s orgs row', n = 0, n::text);

  set role authenticated; select count(*) into n from render_jobs where id = jA; reset role;
  insert into _inv(name, pass, note)
    values ('a non-admin cannot read another org''s render_jobs row', n = 0, n::text);

  set role authenticated; select count(*) into n from rate_limits; reset role;
  insert into _inv(name, pass, note)
    values ('a non-admin sees ZERO rate_limits rows', n = 0, n::text);

  set role authenticated; select is_admin() into b; reset role;
  insert into _inv(name, pass, note) values ('is_admin() is false for a tenant', b is false, b::text);

  -- Self-promotion, the three ways a hostile client would try it.
  begin
    set role authenticated;
    update profiles set is_admin = true where id = uC;
    reset role;
    insert into _inv(name, pass, note) values ('a tenant cannot UPDATE its own is_admin', false, 'update succeeded');
  exception when insufficient_privilege then
    reset role;
    insert into _inv(name, pass, note) values ('a tenant cannot UPDATE its own is_admin', true, sqlerrm);
  end;

  begin
    set role authenticated;
    delete from profiles where id = uC;
    reset role;
    insert into _inv(name, pass, note)
      values ('a tenant cannot DELETE its profile row (delete-then-insert escalation)', false, 'delete succeeded');
  exception when insufficient_privilege then
    reset role;
    insert into _inv(name, pass, note)
      values ('a tenant cannot DELETE its profile row (delete-then-insert escalation)', true, sqlerrm);
  end;

  begin
    set role authenticated;
    insert into admin_allowlist (email) values ('_inv-tenant@example.com');
    reset role;
    insert into _inv(name, pass, note) values ('a tenant cannot add itself to admin_allowlist', false, 'insert succeeded');
  exception when insufficient_privilege then
    reset role;
    insert into _inv(name, pass, note) values ('a tenant cannot add itself to admin_allowlist', true, sqlerrm);
  end;

  begin
    set role authenticated;
    select count(*) into n from admin_allowlist;
    reset role;
    insert into _inv(name, pass, note) values ('a tenant cannot READ admin_allowlist', false, format('%s rows', n));
  exception when insufficient_privilege then
    reset role;
    insert into _inv(name, pass, note) values ('a tenant cannot READ admin_allowlist', true, sqlerrm);
  end;

  -- ══ and the admin, through the SAME role and the SAME JWT mechanism ═══════
  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uA, 'role','authenticated')::text, true);

  select count(*) filter (where id = ledA), count(*) filter (where id = ledC)
    into n, m from cost_ledger;
  reset role;
  insert into _inv(name, pass, note)
    values ('an ADMIN reads cost_ledger rows from every org', n = 1 and m = 1,
            format('own=%s foreign=%s (expected 1 / 1)', n, m));

  -- F-E-15: the admin ledger policy covers the job_id-NULL app-AI row too — the
  -- console's coverage probe reads exactly this shape with the service role, and
  -- the human owner reads it here through the admin RLS path.
  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uA, 'role','authenticated')::text, true);
  select count(*) into n from cost_ledger where id = ledApp;
  reset role;
  insert into _inv(name, pass, note)
    values ('an ADMIN reads an app-AI (job_id NULL, org-scoped) cost row', n = 1, n::text);

  set role authenticated; select count(*) into n from orgs where id in (vA, vB, vC); reset role;
  insert into _inv(name, pass, note) values ('an admin reads every org', n = 3, n::text);

  set role authenticated; select count(*) into n from render_jobs where id in (jA, jC); reset role;
  insert into _inv(name, pass, note) values ('an admin reads every org''s render_jobs', n = 2, n::text);

  set role authenticated;
  select count(*) into n from rate_limits where key in ('aiphotomo:'||vA::text, 'aiphotomo:'||vC::text);
  reset role;
  insert into _inv(name, pass, note) values ('an admin reads the rate_limits usage counters across orgs', n = 2, n::text);

  set role authenticated; select count(*) into n from plan_entitlements; reset role;
  insert into _inv(name, pass, note) values ('an admin reads plan_entitlements', n = 6, n::text);

  set role authenticated; select is_admin() into b; reset role;
  insert into _inv(name, pass, note) values ('is_admin() is true for an allowlisted owner', b is true, b::text);

  insert into _inv(name, pass, note)
    select 'admin is READ-only: 0017 opened no write grant',
           not (has_table_privilege('authenticated','public.cost_ledger','INSERT')
             or has_table_privilege('authenticated','public.cost_ledger','UPDATE')
             or has_table_privilege('authenticated','public.render_jobs','UPDATE')
             or has_table_privilege('authenticated','public.rate_limits','INSERT')
             or has_table_privilege('authenticated','public.rate_limits','UPDATE')
             or has_table_privilege('authenticated','public.rate_limits','DELETE')), '';

  -- anon still reaches nothing, and is_admin() inside the policy must not error
  -- for it (the reason the implicit PUBLIC EXECUTE grant is kept — see 0017 §4).
  set role anon;
  perform set_config('request.jwt.claims', '', true);
  select count(*) into n from cost_ledger;
  reset role;
  insert into _inv(name, pass, note)
    values ('anon reads zero cost_ledger rows and is_admin() does not error for it', n = 0, n::text);

  perform set_config('request.jwt.claims', '', true);
  delete from cost_ledger where meta->>'_inv' = 'admin';
  delete from rate_limits where key in ('aiphotomo:'||vA::text, 'aiphotomo:'||vC::text);
  delete from listings where id in (lA, lC);
  delete from orgs where id in (vA, vB, vC);
  delete from auth.users where id in (uA, uB, uC);
  delete from admin_allowlist where email = '_inv-existing@example.com';
end $adm$;

-- ── 0018: the AI router (routes in a table, not in code) ─────────────────────
--
-- Six things must stay true or the brain is not trustworthy:
--   1. the master flag exists and is OFF, so a deploy changes nothing;
--   2. every task the contract defines can actually resolve to something;
--   3. a retired model is never something the router would pick;
--   4. every plan has a routing policy (a missing row silently means "best");
--   5. an outage map is not tenant-readable;
--   6. the circuit breaker opens where it is supposed to and closes on success.

insert into _inv(name, pass, note)
select 'app_config carries the ai_router flag and it is OFF by default',
       count(*) = 1 and coalesce(bool_and((value->>'enabled')::boolean is not true), false),
       coalesce(string_agg(value::text, ' | '), '(row missing)')
from app_config where key = 'ai_router';

-- The task vocabulary of docs/AI-ROUTER-CONTRACT.md §3, spelled out so a
-- renamed or dropped task fails here instead of at runtime.
create temp table _inv_tasks(task text primary key);
insert into _inv_tasks(task) values
  ('photo.sky'),('photo.twilight'),('photo.lawn'),('photo.declutter'),('photo.stage'),('photo.custom'),
  ('video.reel_clip'),('video.aerial'),('video.aerial_no_photo'),('video.upscale_4k'),('video.upscale_1080p60'),
  ('tts.captioned'),('tts.plain'),('stt.captions'),('stt.plain'),('text.listing_copy'),
  ('judge.fair_housing'),('judge.qc_drift'),('video.chapters'),('vision.room_label'),
  ('3d.world'),('floorplan');

insert into _inv(name, pass, note)
select 'every contract §3 task exists in ai_routes',
       count(*) = 0,
       coalesce(string_agg(t.task, ', '), 'none missing')
from _inv_tasks t
where not exists (select 1 from ai_routes r where r.task = t.task);

-- THE availability invariant: a task must resolve to SOMETHING. Either the
-- flag-ON chain has at least one live step, or the flag-OFF legacy row exists.
insert into _inv(name, pass, note)
select 'every §3 task has >= 1 enabled step OR a legacy step',
       count(*) = 0,
       coalesce(string_agg(t.task, ', '), 'all resolvable')
from _inv_tasks t
where not exists (
        select 1 from ai_routes r
         where r.task = t.task and r.enabled
           and r.note is distinct from 'legacy'
           and (r.retire_after is null or r.retire_after >= current_date))
  and not exists (select 1 from ai_routes r where r.task = t.task and r.note = 'legacy');

-- A retirement is a date in a row. An ENABLED row past its own date would be
-- one the table still offers and resolveRoute() silently drops — a table that
-- disagrees with the resolver. Fix by disabling the row or replacing the model.
insert into _inv(name, pass, note)
select 'no ENABLED step is past its retire_after',
       count(*) = 0,
       coalesce(string_agg(format('%s/%s/%s retired %s', task, provider, model, retire_after), '; '),
                'none retired')
from ai_routes
where enabled and retire_after is not null and retire_after < current_date;

insert into _inv(name, pass, note)
select 'plan_routing_policy covers all six plans with a valid policy',
       count(*) = 6, format('%s of 6: %s', count(*), string_agg(plan || '=' || policy, ', ' order by plan))
from plan_routing_policy
where plan in ('free','trial','starter','solo','pro','team') and policy in ('best','cheapest');

-- The contract's own split: the tiers that pay nothing or little route cheapest.
insert into _inv(name, pass, note)
select 'free/trial/starter route cheapest; solo/pro/team route best',
       coalesce(bool_and(
         case when plan in ('free','trial','starter') then policy = 'cheapest'
              else policy = 'best' end), false),
       string_agg(plan || '=' || policy, ', ' order by plan)
from plan_routing_policy;

-- The flag-off answer is looked up by `note = 'legacy'` with LIMIT 1, so a
-- second row would make "what runs today" depend on a sort order.
insert into _inv(name, pass, note)
select 'at most ONE legacy row per task, and every legacy row is disabled',
       coalesce(bool_and(n = 1), true) and
       (select coalesce(bool_and(not enabled), true) from ai_routes where note = 'legacy'),
       coalesce(string_agg(task || '=' || n, ', '), 'no legacy rows')
from (select task, count(*) n from ai_routes where note = 'legacy' group by task) s;

insert into _inv(name, pass, note)
select 'the six live app tasks all have a legacy (flag-off) row',
       count(*) = 6, format('%s of 6', count(*))
from ai_routes
where note = 'legacy'
  and task in ('photo.sky','video.reel_clip','video.aerial','video.aerial_no_photo',
               'video.upscale_1080p60','tts.captioned');

-- Contract §3: every reseller row stays OFF until its commercial terms are
-- confirmed, and until then it assumes the WORST data posture — which is also
-- what keeps customer media off it if somebody enables it early.
insert into _inv(name, pass, note)
select 'every kie / higgsfield row is disabled and assumes trains_by_default',
       count(*) = 0,
       coalesce(string_agg(format('%s/%s/%s enabled=%s tier=%s', task, provider, model, enabled, privacy_tier), '; '),
                'all reseller rows disabled + worst-case tier')
from ai_routes
where provider in ('kie','higgsfield')
  and (enabled or privacy_tier is distinct from 'trains_by_default');

-- The resell relationship is RECORDED, not implied: a failover between two
-- steps sharing a family key buys a different queue, not a different model.
insert into _inv(name, pass, note)
select 'every reseller step shares same_model_as with a fal step in the same task',
       count(*) filter (where twin = 0) = 0 and count(*) >= 4,
       format('%s reseller rows carry a family key; %s without a fal twin: %s',
              count(*), count(*) filter (where twin = 0),
              coalesce(string_agg(format('%s %s/%s', task, provider, model), '; ')
                       filter (where twin = 0), 'none'))
from (
  select r.task, r.provider, r.model,
         (select count(*) from ai_routes f
           where f.task = r.task and f.provider = 'fal'
             and f.same_model_as = r.same_model_as) as twin
    from ai_routes r
   where r.provider in ('kie','higgsfield') and r.same_model_as is not null
) s;

insert into _inv(name, pass, note)
select 'every ai_routes row carries a legal privacy_tier and min_plan',
       count(*) = 0, coalesce(string_agg(task || '/' || model, ', '), 'all valid')
from ai_routes
where privacy_tier not in ('no_retention','retained_30d','trains_by_default')
   or min_plan not in ('free','trial','starter','solo','pro','team');

-- ── 0018 grants ─────────────────────────────────────────────────────────────
-- Model ids and list prices are not secret, so `authenticated` READS the two
-- route tables. Nothing tenant-facing may WRITE any of the four, and `anon`
-- reaches none of them at all.

insert into _inv(name, pass, note)
select 'authenticated may SELECT ai_routes and plan_routing_policy',
       has_table_privilege('authenticated','public.ai_routes','SELECT')
   and has_table_privilege('authenticated','public.plan_routing_policy','SELECT'), '';

insert into _inv(name, pass, note)
select 'no tenant role may WRITE any 0018 table',
       not (has_table_privilege('authenticated','public.ai_routes','INSERT')
         or has_table_privilege('authenticated','public.ai_routes','UPDATE')
         or has_table_privilege('authenticated','public.ai_routes','DELETE')
         or has_table_privilege('authenticated','public.plan_routing_policy','INSERT')
         or has_table_privilege('authenticated','public.plan_routing_policy','UPDATE')
         or has_table_privilege('authenticated','public.provider_health','INSERT')
         or has_table_privilege('authenticated','public.provider_health','UPDATE')
         or has_table_privilege('authenticated','public.provider_health','DELETE')
         or has_table_privilege('authenticated','public.app_config','INSERT')
         or has_table_privilege('authenticated','public.app_config','UPDATE')
         or has_table_privilege('authenticated','public.app_config','DELETE')
         or has_table_privilege('anon','public.ai_routes','INSERT')
         or has_table_privilege('anon','public.app_config','UPDATE')), '';

insert into _inv(name, pass, note)
select 'anon reaches none of the 0018 tables',
       not (has_table_privilege('anon','public.ai_routes','SELECT')
         or has_table_privilege('anon','public.plan_routing_policy','SELECT')
         or has_table_privilege('anon','public.provider_health','SELECT')
         or has_table_privilege('anon','public.app_config','SELECT')), '';

insert into _inv(name, pass, note)
select 'RLS is enabled on all four 0018 tables',
       count(*) = 4, format('%s of 4', count(*))
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('ai_routes','plan_routing_policy','provider_health','app_config')
  and c.relrowsecurity;

insert into _inv(name, pass, note)
select 'provider_health and app_config are readable ONLY through is_admin()',
       count(*) = 2, format('%s of 2 admin-only policies', count(*))
from pg_policies
where schemaname = 'public'
  and tablename in ('provider_health','app_config')
  and cmd = 'SELECT' and qual like '%is_admin%';

-- ── report_provider_outcome: the only writer of the breaker ──────────────────

insert into _inv(name, pass, note)
select 'report_provider_outcome is a definer with a pinned search_path',
       count(*) = 1, format('%s match(es)', count(*))
from pg_proc
where proname = 'report_provider_outcome'
  and pronamespace = 'public'::regnamespace
  and prosecdef
  and 'search_path=public' = any(coalesce(proconfig, array[]::text[]));

insert into _inv(name, pass, note)
select 'report_provider_outcome executes for service_role ONLY',
       has_function_privilege('service_role', p.oid, 'EXECUTE')
   and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
   and not has_function_privilege('anon', p.oid, 'EXECUTE'), ''
from pg_proc p
where p.proname = 'report_provider_outcome' and p.pronamespace = 'public'::regnamespace;

-- ── MUTATING: the circuit breaker, and who may see it ───────────────────────

do $rt$
declare
  uAdm uuid := '0f1e2d3c-4b5a-4968-8776-6554433221b0';  -- allowlisted → admin
  uTen uuid := '0f1e2d3c-4b5a-4968-8776-6554433221b1';  -- ordinary tenant
  n int; ts timestamptz; lat int;
begin
  delete from provider_health where provider = '_inv';
  delete from orgs where id in (select org_id from memberships where user_id in (uAdm, uTen));
  delete from auth.users where id in (uAdm, uTen);

  -- (a) two failures do NOT open the circuit; the third does.
  perform report_provider_outcome('_inv','m', false, 1200, 'upstream');
  perform report_provider_outcome('_inv','m', false, 1250, 'upstream');
  select consecutive_failures, open_until into n, ts
    from provider_health where provider = '_inv' and model = 'm';
  insert into _inv(name, pass, note)
    values ('two consecutive failures leave the circuit CLOSED',
            n = 2 and ts is null, format('failures=%s open_until=%s', n, ts));

  perform report_provider_outcome('_inv','m', false, 1300, 'upstream');
  select consecutive_failures, open_until into n, ts
    from provider_health where provider = '_inv' and model = 'm';
  insert into _inv(name, pass, note)
    values ('the THIRD consecutive failure opens the circuit for ~10 minutes',
            n = 3 and ts is not null and ts > now() and ts <= now() + interval '11 minutes',
            format('failures=%s open_until=%s', n, ts));

  -- (b) a success resets the counter AND closes the circuit immediately.
  perform report_provider_outcome('_inv','m', true, 800, null);
  select consecutive_failures, open_until, p95_latency_ms into n, ts, lat
    from provider_health where provider = '_inv' and model = 'm';
  insert into _inv(name, pass, note)
    values ('a success resets the counter and closes the circuit',
            n = 0 and ts is null, format('failures=%s open_until=%s', n, ts));
  insert into _inv(name, pass, note)
    values ('the latency EWMA is populated (not a true p95 — see the column comment)',
            lat is not null and lat > 0, coalesce(lat::text, '<null>'));

  -- (c) being throttled opens the circuit on the FIRST failure: more attempts
  -- are what keep you throttled.
  perform report_provider_outcome('_inv','rl', false, 40, 'rate_limit');
  select consecutive_failures, open_until into n, ts
    from provider_health where provider = '_inv' and model = 'rl';
  insert into _inv(name, pass, note)
    values ('a rate_limit opens the circuit on the FIRST failure',
            n = 1 and ts is not null and ts > now(), format('failures=%s open_until=%s', n, ts));

  -- (d) a blank provider/model is a no-op, not a junk breaker row that no
  -- route ever matches.
  perform report_provider_outcome('', '', false, 10, 'other');
  select count(*) into n from provider_health where provider = '' or model = '';
  insert into _inv(name, pass, note)
    values ('report_provider_outcome ignores a blank provider/model', n = 0, n::text);

  -- (e) WHO MAY SEE THE OUTAGE MAP. Same shape as 0017's rate_limits check: a
  -- non-admin gets ZERO ROWS (not an error), an admin sees everything.
  insert into auth.users (id, email, raw_user_meta_data)
    values (uAdm, 'aaron@pilk.ai', '{"full_name":"Owner"}');
  insert into auth.users (id, email, raw_user_meta_data)
    values (uTen, '_inv-router-tenant@example.com', '{"full_name":"Tenant"}');

  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uTen, 'role','authenticated')::text, true);
  select count(*) into n from provider_health;
  reset role;
  insert into _inv(name, pass, note)
    values ('a NON-ADMIN reads zero provider_health rows', n = 0, n::text);

  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uTen, 'role','authenticated')::text, true);
  select count(*) into n from app_config;
  reset role;
  insert into _inv(name, pass, note)
    values ('a NON-ADMIN reads zero app_config rows (the flag is not tenant business)',
            n = 0, n::text);

  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uAdm, 'role','authenticated')::text, true);
  select count(*) into n from provider_health where provider = '_inv';
  reset role;
  insert into _inv(name, pass, note)
    values ('an ADMIN reads the provider_health outage map', n = 2, n::text);

  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uAdm, 'role','authenticated')::text, true);
  select count(*) into n from app_config where key = 'ai_router';
  reset role;
  insert into _inv(name, pass, note)
    values ('an ADMIN reads the ai_router flag', n = 1, n::text);

  -- (f) the route table IS tenant-readable — model ids and list prices are not
  -- secrets, and the app shows which model produced a result.
  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uTen, 'role','authenticated')::text, true);
  select count(*) into n from ai_routes where task = 'photo.sky';
  reset role;
  insert into _inv(name, pass, note)
    values ('a tenant CAN read ai_routes (model ids and prices are not secret)',
            n >= 3, n::text);

  set role authenticated;
  perform set_config('request.jwt.claims',
           json_build_object('sub', uTen, 'role','authenticated')::text, true);
  select count(*) into n from plan_routing_policy;
  reset role;
  insert into _inv(name, pass, note)
    values ('a tenant CAN read plan_routing_policy', n = 6, n::text);

  perform set_config('request.jwt.claims', '', true);
  delete from provider_health where provider = '_inv';
  delete from orgs where id in (select org_id from memberships where user_id in (uAdm, uTen));
  delete from auth.users where id in (uAdm, uTen);
end $rt$;

-- ── 0019/0020/0021: subscriptions, analytics, and the money path ─────────────
--
-- The App Store now decides `orgs.plan`, so the privilege story around it is a
-- release blocker in its own right: two service-role-only tables with RLS on
-- and no policies, one SECURITY DEFINER writer, and three plan columns no
-- tenant may write. Then the three things the S1 pre-money review actually
-- broke on a scratch database and 0021 fixed.

insert into _inv(name, pass, note)
select 'apple_subscriptions + apple_notifications + app_events: RLS on, NO policies',
       coalesce(bool_and(t.relrowsecurity) and count(p.polname) = 0, false),
       'rls=' || coalesce(bool_and(t.relrowsecurity)::text, 'null') ||
       ' policies=' || count(p.polname)
from pg_class t
left join pg_policy p on p.polrelid = t.oid
where t.relname in ('apple_subscriptions','apple_notifications','app_events')
  and t.relnamespace = 'public'::regnamespace;

insert into _inv(name, pass, note)
select 'no tenant privilege on apple_subscriptions / apple_notifications / app_events',
       count(*) = 0,
       coalesce(string_agg(table_name::text || '.' || privilege_type::text || '->' || grantee::text, ', '), 'none')
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('apple_subscriptions','apple_notifications','app_events')
  and grantee in ('anon','authenticated');

insert into _inv(name, pass, note)
select 'apply_apple_entitlement is SECURITY DEFINER, service_role only',
       coalesce(bool_and(prosecdef), false)
         and not has_function_privilege('authenticated', oid, 'execute')
         and not has_function_privilege('anon', oid, 'execute')
         and has_function_privilege('service_role', oid, 'execute'),
       'secdef=' || coalesce(bool_and(prosecdef)::text, '(missing)')
from pg_proc where proname = 'apply_apple_entitlement' group by oid;

insert into _inv(name, pass, note)
select 'admin_funnel + purge_app_events are service_role only',
       coalesce(bool_and(
         prosecdef
         and not has_function_privilege('authenticated', oid, 'execute')
         and not has_function_privilege('anon', oid, 'execute')), false),
       coalesce(string_agg(proname, ', '), '(missing)')
from pg_proc where proname in ('admin_funnel','purge_app_events');

-- 0019 §3: the three plan columns are server-controlled. A tenant that could
-- write plan_source could mark itself `manual` and become Apple-proof forever.
insert into _inv(name, pass, note)
select 'the orgs UPDATE grant still lists exactly name, handle, space_type, brand_kit',
       coalesce(array_agg(column_name::text order by column_name::text), '{}'::text[]) =
         array['brand_kit','handle','name','space_type']::text[],
       coalesce(string_agg(column_name::text, ', ' order by column_name::text), 'none')
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'orgs'
  and grantee = 'authenticated' and privilege_type = 'UPDATE';

do $ap$
declare
  oA uuid; oB uuid; oM uuid; oX uuid;
  r jsonb; msg text; ok boolean;
begin
  insert into orgs (name, plan, plan_source) values ('_inv apple A','trial','trial') returning id into oA;
  insert into orgs (name, plan, plan_source) values ('_inv apple B','trial','trial') returning id into oB;
  insert into orgs (name, plan, plan_source) values ('_inv apple M','pro','manual')  returning id into oM;
  -- oX buys ONE subscription, so the lapse below is not held up by the
  -- `another_subscription_active` guard (which oA would trip, correctly).
  insert into orgs (name, plan, plan_source) values ('_inv apple X','trial','trial') returning id into oX;

  -- S1 FINDING 1: one subscription must not entitle two workspaces. Before
  -- 0021 the second call re-pointed the row and set the second org's plan while
  -- the first kept its own — one purchase, two paid workspaces.
  r := apply_apple_entitlement(oA, null, '_inv-OT-1', 'T1',
        'com.rendprop.app.pro.monthly', 'pro', 'Production', 'active',
        now() + interval '30 days', true, null);
  ok := false;
  begin
    r := apply_apple_entitlement(oB, null, '_inv-OT-1', 'T1',
          'com.rendprop.app.pro.monthly', 'pro', 'Production', 'active',
          now() + interval '30 days', true, null);
  exception when others then msg := SQLERRM; ok := msg like 'RP409:%';
  end;
  insert into _inv(name, pass, note)
    values ('a subscription bound to one org cannot be claimed by another (RP409)',
            ok, coalesce(msg, 'NO ERROR RAISED'));
  insert into _inv(name, pass, note)
    select 'and the second org was given nothing', plan = 'trial', plan from orgs where id = oB;

  -- S1 FINDING 2: a crossgrade inside the group shortens the expiry. Treating
  -- that as stale froze the plan AND the expiry, which then made every later
  -- signal stale too — including the EXPIRED, so the plan never lapsed.
  r := apply_apple_entitlement(oX, null, '_inv-OT-2', 'T1',
        'com.rendprop.app.pro.annual', 'pro', 'Production', 'active',
        now() + interval '365 days', true, 'SUBSCRIBED');
  r := apply_apple_entitlement(oX, null, '_inv-OT-2', 'T2',
        'com.rendprop.app.team.monthly', 'team', 'Production', 'active',
        now() + interval '30 days', true, 'DID_CHANGE_RENEWAL_PREF');
  insert into _inv(name, pass, note)
    select 'an upgrade to a shorter-dated product moves the plan',
           plan = 'team' and plan_expires_at < now() + interval '60 days',
           plan || ' until ' || coalesce(plan_expires_at::text, 'null')
      from orgs where id = oX;
  r := apply_apple_entitlement(oX, null, '_inv-OT-2', 'T3',
        'com.rendprop.app.team.monthly', 'team', 'Production', 'expired',
        now() + interval '30 days', false, 'EXPIRED');
  insert into _inv(name, pass, note)
    select 'and the eventual lapse still downgrades it to free',
           plan = 'free' and effective_plan(id) = 'free', plan from orgs where id = oX;

  -- …and the guard that DID hold oA back is itself worth asserting: an org with
  -- a second live subscription is not dropped to free by an old one expiring.
  r := apply_apple_entitlement(oA, null, '_inv-OT-1b', 'T9',
        'com.rendprop.app.starter.monthly', 'starter', 'Production', 'expired',
        now() - interval '1 day', false, 'EXPIRED');
  insert into _inv(name, pass, note)
    values ('a lapse does not downgrade an org that still has a live subscription',
            r->>'reason' = 'another_subscription_active', r::text);

  -- The behaviour the stale guard exists for is unchanged: a late signal about
  -- the SAME product with an older expiry is news we already have.
  r := apply_apple_entitlement(oB, null, '_inv-OT-3', 'T1',
        'com.rendprop.app.pro.monthly', 'pro', 'Production', 'active',
        now() + interval '30 days', true, 'DID_RENEW');
  r := apply_apple_entitlement(oB, null, '_inv-OT-3', 'T0',
        'com.rendprop.app.pro.monthly', 'pro', 'Production', 'expired',
        now() - interval '1 day', false, 'EXPIRED');
  insert into _inv(name, pass, note)
    values ('an out-of-order EXPIRED for the same product is still stale',
            r->>'reason' = 'stale_notification', r::text);
  insert into _inv(name, pass, note)
    select 'and it does not take the plan away', plan = 'pro', plan from orgs where id = oB;

  -- S1 FINDING 3: Sandbox and Production may never overwrite each other.
  r := apply_apple_entitlement(oB, null, '_inv-OT-4', 'T1',
        'com.rendprop.app.team.annual', 'team', 'Production', 'active',
        now() + interval '365 days', true, 'SUBSCRIBED');
  r := apply_apple_entitlement(oB, null, '_inv-OT-4', 'T2',
        'com.rendprop.app.team.annual', 'team', 'Sandbox', 'active',
        now() + interval '400 days', true, null);
  insert into _inv(name, pass, note)
    values ('a Sandbox write cannot move a Production subscription',
            r->>'reason' = 'environment_mismatch', r::text);
  insert into _inv(name, pass, note)
    select 'and the stored environment is untouched', environment = 'Production', environment
      from apple_subscriptions where original_transaction_id = '_inv-OT-4';

  -- 0019 RULE 2: an owner-granted plan is Apple-proof in both directions.
  r := apply_apple_entitlement(oM, null, '_inv-OT-5', 'T1',
        'com.rendprop.app.team.monthly', 'team', 'Production', 'active',
        now() + interval '30 days', true, 'SUBSCRIBED');
  insert into _inv(name, pass, note)
    values ('Apple cannot RAISE a manual plan', r->>'reason' = 'manual_plan', r::text);
  r := apply_apple_entitlement(oM, null, '_inv-OT-5', 'T2',
        'com.rendprop.app.team.monthly', 'team', 'Production', 'expired',
        now() + interval '31 days', false, 'EXPIRED');
  insert into _inv(name, pass, note)
    select 'and Apple cannot LOWER one either', plan = 'pro' and plan_source = 'manual',
           plan || '/' || plan_source from orgs where id = oM;

  -- 0019 §5: the 16-day backstop, and the 0010 trial arm it sits behind.
  update orgs set plan = 'pro', plan_source = 'apple',
                  plan_expires_at = now() - interval '17 days' where id = oB;
  insert into _inv(name, pass, note)
    select 'effective_plan reads free 17 days past an apple expiry',
           effective_plan(id) = 'free', effective_plan(id) from orgs where id = oB;
  update orgs set plan_expires_at = now() - interval '15 days' where id = oB;
  insert into _inv(name, pass, note)
    select 'and still reads the plan at 15 days past (Apple is still retrying)',
           effective_plan(id) = 'pro', effective_plan(id) from orgs where id = oB;
  update orgs set plan = 'trial', plan_source = 'trial', plan_expires_at = null,
                  trial_ends_at = now() - interval '1 day' where id = oB;
  insert into _inv(name, pass, note)
    select 'the 0010 expired-trial arm has not regressed',
           effective_plan(id) = 'free', effective_plan(id) from orgs where id = oB;

  -- S1 FINDING 4: the funnel's purchase count is client-reported. `app_events`
  -- is writable with the shipped anon key and `device_id` is a UUID the client
  -- invents, so the honest number has to come from somewhere a client cannot
  -- reach.
  insert into app_events (name, device_id, user_id, t) values
    ('purchase_completed', gen_random_uuid(), null, now()),
    ('purchase_completed', gen_random_uuid(), null, now());
  r := admin_funnel(interval '1 hour');
  insert into _inv(name, pass, note)
    values ('admin_funnel reports a purchase count no client can fabricate',
            r ? 'purchases_verified' and r ? 'purchases_verified_sandbox'
              and r ? 'purchase_completed_attributed',
            r::text);
  insert into _inv(name, pass, note)
    values ('and unattributed events do not reach it',
            (r->>'purchase_completed_attributed')::int = 0
              and (r#>>'{steps,7,count}')::int >= 2,
            'attributed=' || (r->>'purchase_completed_attributed') ||
            ' reported=' || (r#>>'{steps,7,count}'));

  delete from app_events where name = 'purchase_completed' and user_id is null and t > now() - interval '1 hour';
  delete from apple_subscriptions where original_transaction_id like '\_inv-OT-%';
  delete from orgs where id in (oA, oB, oM, oX);
end $ap$;

drop table if exists _inv_tasks;

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
