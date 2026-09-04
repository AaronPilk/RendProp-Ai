-- 0005b: lock down SECURITY DEFINER helper functions (advisor fixes, 2026-08-26).
--
-- Production history: supabase_migrations.schema_migrations version
-- 20260826213350 "lock_down_rpc_definer_functions" — applied between 0005 and
-- 0006 but never committed (audit F-supabase-03). Re-committed 2026-09-03 so the
-- repo replays to the same schema as project ymgqpbnjpztwjsyvceld.
--
-- Idempotent: safe to re-run on prod (where it is already applied) and on a
-- fresh database (where the platform-created rls_auto_enable() may not exist).
--
-- What these revokes do and don't do (verified on a local replay, 2026-09-03):
--   • They remove the EXPLICIT anon/authenticated EXECUTE grants that Supabase's
--     default privileges add to every new function. The implicit PUBLIC grant
--     (`=X` in proacl) remains on is_org_member() — DELIBERATELY. RLS policy
--     expressions run with the privileges of the querying user, so revoking
--     PUBLIC on is_org_member() without re-granting `authenticated` makes every
--     org policy fail with "permission denied for function is_org_member" for
--     every signed-in user. The advisor's "callable by anon" warning on that
--     function is a false positive: it returns false without a JWT sub.
--   • handle_new_user() and rls_auto_enable() are trigger / event-trigger
--     functions. Trigger firing does not check EXECUTE on the invoking role
--     (only CREATE TRIGGER does), so those two CAN safely lose PUBLIC as well —
--     which is the part of audit finding F-supabase-30 that is correct.

-- is_org_member: explicit API-role grants off, PUBLIC kept (see above).
revoke execute on function public.is_org_member(uuid) from anon, authenticated;

-- handle_new_user: an auth trigger, never client-callable.
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- rls_auto_enable: platform-created event-trigger helper (not created by any
-- repo migration) — guard so a fresh database replays cleanly.
do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'rls_auto_enable'
  ) then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end $$;
