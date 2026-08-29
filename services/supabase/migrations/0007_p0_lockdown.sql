-- 0007: P0 hardening — lockdown half. Apply ONLY AFTER the function versions
-- that use the 0006 RPCs are deployed (uploads v13+, renders v12+, beacon v12+,
-- me v13+). This removes the direct Data-API write paths the audit flagged
-- (P0-7): a member JWT could previously mutate render_jobs / renders /
-- capture_assets directly via PostgREST, bypassing every server-side check.

-- ── 1. render_jobs / renders: members read, only the server writes ───────────
-- Writes now flow through the SECURITY DEFINER RPCs (create_render_job,
-- publish_render, log_job_cost) or the service-role worker.

drop policy if exists "org jobs" on public.render_jobs;
create policy "org jobs read" on public.render_jobs for select
  using (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)));

drop policy if exists "org renders" on public.renders;
create policy "org renders read" on public.renders for select
  using (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)));

revoke insert, update, delete on public.render_jobs from authenticated, anon;
revoke insert, update, delete on public.renders     from authenticated, anon;

-- ── 2. capture_assets / capture_chapters: members read, server writes ────────
-- The uploads function verifies membership with the user client, then writes
-- with the service role — so `uploaded`, `bytes`, `upload_id` and friends can
-- no longer be flipped by a raw PostgREST call.

drop policy if exists "org assets" on public.capture_assets;
create policy "org assets read" on public.capture_assets for select
  using (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)));

drop policy if exists "org chapters" on public.capture_chapters;
create policy "org chapters read" on public.capture_chapters for select
  using (exists (select 1 from capture_assets a join listings l on l.id = a.listing_id
                 where a.id = asset_id and is_org_member(l.org_id)));

revoke insert, update, delete on public.capture_assets   from authenticated, anon;
revoke insert, update, delete on public.capture_chapters from authenticated, anon;

-- ── 3. Role capabilities (P0-7): marketing is read-only on product data ──────

drop policy if exists "org listings" on public.listings;
create policy "org listings read" on public.listings for select
  using (is_org_member(org_id));
create policy "org listings insert" on public.listings for insert
  with check (org_role(org_id) in ('owner','admin','agent'));
create policy "org listings update" on public.listings for update
  using (org_role(org_id) in ('owner','admin','agent'))
  with check (org_role(org_id) in ('owner','admin','agent'));
create policy "org listings delete" on public.listings for delete
  using (org_role(org_id) in ('owner','admin'));

drop policy if exists "org photos" on public.photos;
create policy "org photos read" on public.photos for select
  using (exists (select 1 from listings l where l.id = listing_id and is_org_member(l.org_id)));
create policy "org photos write" on public.photos for insert
  with check (exists (select 1 from listings l where l.id = listing_id and org_role(l.org_id) in ('owner','admin','agent')));
create policy "org photos update" on public.photos for update
  using (exists (select 1 from listings l where l.id = listing_id and org_role(l.org_id) in ('owner','admin','agent')));
create policy "org photos delete" on public.photos for delete
  using (exists (select 1 from listings l where l.id = listing_id and org_role(l.org_id) in ('owner','admin','agent')));

-- Org profile (name/handle/brand_kit) edits: owner/admin only. The 0005
-- column-scoped grant still keeps `plan` untouchable.
drop policy if exists "member orgs write" on public.orgs;
create policy "org admin write" on public.orgs for update
  using (org_role(id) in ('owner','admin'))
  with check (org_role(id) in ('owner','admin'));

-- ── 4. Belt-and-suspenders grant revokes on server-only tables ───────────────

revoke insert, update, delete on public.cost_ledger from authenticated, anon;
revoke insert, update, delete on public.metering    from authenticated, anon;
revoke insert, update, delete on public.leads       from authenticated, anon;
revoke all on public.rate_limits        from authenticated, anon;
revoke all on public.deletion_requests  from authenticated, anon;

-- ── 5. Membership self-service is server-mediated only ───────────────────────
-- (No write policies existed, but revoke the grants too.)
revoke insert, update, delete on public.memberships from authenticated, anon;
