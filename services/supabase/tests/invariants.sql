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
    join (values ('trial',   10, 1,  0, 0, 1),
                 ('free',    10, 1,  0, 0, 1),
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
