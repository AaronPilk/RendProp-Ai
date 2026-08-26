-- 0005: authorization hardening (audit 2026-08-26).
--
-- (A) Pin search_path on is_org_member — it is SECURITY DEFINER and is the
--     linchpin of every org RLS policy. Without a pinned path a temp-table
--     shadow of `memberships` could subvert it. (Supabase advisor:
--     function_search_path_mutable.)
alter function public.is_org_member(uuid) set search_path = public, pg_temp;

-- (B) Stop tenants from writing billing/identity columns on their own org.
--     The "member orgs write" RLS policy (0001) has no WITH CHECK and no column
--     scope, so a member could PATCH orgs.plan to 'team' via PostgREST and
--     self-upgrade. Column privileges are enforced independently of RLS, so
--     revoke UPDATE on the sensitive columns from the tenant roles and grant
--     only the display columns they legitimately edit.
revoke update on public.orgs from authenticated, anon;
grant  update (name, handle, space_type, brand_kit) on public.orgs to authenticated;
-- `plan`, `id`, `created_at` are intentionally omitted → only service_role
-- (billing) can change them.
