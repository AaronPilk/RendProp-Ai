// me — the signed-in user, their org, plan, and a usage rollup (owner).
//
//   GET    /me -> { user, org, plan, usage }
//   DELETE /me -> { ok: true, deleted_orgs, left_orgs, warnings? }   (App Store account deletion)
//
// GET usage: this-month AI/infra spend (sum of cost_ledger.total_cents for the
// org), plus lead / render / listing counts. All reads go through the user
// client so RLS scopes everything to the caller's org.
//
// DELETE removes the caller's account and every org they are the ONLY member
// of (shared orgs survive — we just remove their membership, reassigning any
// listings they authored to another member so the profile FK can't block the
// deletion). Deletes are sequential, child-tables-first, and best-effort: an
// individual failure is collected as a warning and we keep going. The request
// only fails (500) if the final auth-user deletion itself fails.
//
// TODO(storage): R2 objects (uploads/renders/photos) are NOT deleted here —
// edge functions shouldn't fan out thousands of S3 deletes inline. Ship an
// async batch cleaner that sweeps R2 keys for org ids with no surviving rows.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, respondError, round4 } from "../_shared/http.ts";
import {
  adminClient,
  getUser,
  orgForUser,
  preferredOrg,
  userClient,
} from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = await getUser(req);

    if (req.method === "GET") return await handleGet(req, user.id, user.email ?? null);
    if (req.method === "DELETE") return await handleDelete(user.id);

    throw new HttpError(405, "Only GET and DELETE are supported");
  } catch (err) {
    return respondError(err);
  }
});

// ── GET /me ───────────────────────────────────────────────────────────────────

async function handleGet(req: Request, userId: string, userEmail: string | null): Promise<Response> {
  const db = userClient(req);
  const orgId = await orgForUser(userId, preferredOrg(req));

  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
  const month = monthStart.slice(0, 7); // YYYY-MM

  const [profileRes, orgRes, ledgerRes, leadsRes, rendersRes, listingsRes] = await Promise.all([
    db.from("profiles").select("id, email, name, avatar_url, phone").eq("id", userId).maybeSingle(),
    db.from("orgs").select("id, name, handle, space_type, plan, brand_kit").eq("id", orgId).maybeSingle(),
    db.from("cost_ledger").select("total_cents").eq("org_id", orgId).gte("created_at", monthStart),
    db.from("leads").select("id", { count: "exact", head: true }).eq("org_id", orgId).gte("created_at", monthStart),
    // renders has no org_id; RLS already scopes it to the caller's org.
    db.from("renders").select("id", { count: "exact", head: true }).not("published_at", "is", null),
    db.from("listings").select("id", { count: "exact", head: true }).is("deleted_at", null),
  ]);

  if (orgRes.error) throw new HttpError(500, `Org lookup failed: ${orgRes.error.message}`);

  const costCents = round4(
    (ledgerRes.data ?? []).reduce((s, r) => s + Number(r.total_cents ?? 0), 0),
  );

  return json({
    user: profileRes.data ?? { id: userId, email: userEmail },
    org: orgRes.data,
    plan: orgRes.data?.plan ?? "free",
    usage: {
      month,
      cost_cents: costCents,
      leads: leadsRes.count ?? 0,
      renders: rendersRes.count ?? 0,
      listings: listingsRes.count ?? 0,
    },
  });
}

// ── DELETE /me ────────────────────────────────────────────────────────────────

// Same ranking as orgForUser: prefer the highest-privilege remaining member
// when reassigning authored listings in a shared org.
const ROLE_RANK: Record<string, number> = { owner: 0, admin: 1, agent: 2, marketing: 3 };

// PostgREST filters travel in the query string, so keep .in() lists bounded.
const ID_CHUNK = 200;

function chunk<T>(items: T[], size = ID_CHUNK): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

async function handleDelete(userId: string): Promise<Response> {
  const admin = adminClient();
  const warnings: string[] = [];

  /** Run one step; on failure record a warning and keep going.
   * (PromiseLike: PostgREST query builders are thenables, not Promises.) */
  async function step(label: string, fn: () => PromiseLike<{ error: { message: string } | null }>) {
    try {
      const { error } = await fn();
      if (error) warnings.push(`${label}: ${error.message}`);
    } catch (e) {
      warnings.push(`${label}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /** Select a column across id chunks; failures become warnings. */
  async function selectIds(
    label: string,
    table: string,
    column: string,
    filterColumn: string,
    filterIds: string[],
  ): Promise<string[]> {
    const out: string[] = [];
    for (const ids of chunk(filterIds)) {
      try {
        const { data, error } = await admin.from(table).select(column).in(filterColumn, ids);
        if (error) { warnings.push(`${label}: ${error.message}`); continue; }
        for (const row of (data ?? []) as unknown as Record<string, unknown>[]) {
          const v = row[column];
          if (typeof v === "string") out.push(v);
        }
      } catch (e) {
        warnings.push(`${label}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    return out;
  }

  /** Chunked delete-by-.in(); failures become warnings. */
  async function deleteIn(label: string, table: string, column: string, ids: string[]) {
    for (const part of chunk(ids)) {
      await step(label, () => admin.from(table).delete().in(column, part));
    }
  }

  // 1. Which orgs does this user belong to, and which are solely theirs?
  const { data: myMemberships, error: memErr } = await admin
    .from("memberships")
    .select("org_id")
    .eq("user_id", userId);
  if (memErr) warnings.push(`membership lookup: ${memErr.message}`);

  const orgIds = [...new Set((myMemberships ?? []).map((m) => m.org_id as string))];
  const soloOrgs: string[] = [];
  const sharedOrgs: string[] = [];

  for (const orgId of orgIds) {
    const { count, error } = await admin
      .from("memberships")
      .select("id", { count: "exact", head: true })
      .eq("org_id", orgId);
    if (error) {
      // Can't tell — treat as shared (never destroy an org we aren't sure about).
      warnings.push(`member count for org ${orgId}: ${error.message}`);
      sharedOrgs.push(orgId);
    } else if ((count ?? 0) <= 1) {
      soloOrgs.push(orgId);
    } else {
      sharedOrgs.push(orgId);
    }
  }

  // 2. Shared orgs: leave them intact. Reassign listings this user authored
  //    (listings.agent_id -> profiles has no cascade, so it would otherwise
  //    block the profile/auth deletion), then drop the membership.
  for (const orgId of sharedOrgs) {
    const { data: others, error } = await admin
      .from("memberships")
      .select("user_id, role")
      .eq("org_id", orgId)
      .neq("user_id", userId);
    if (error || !others || others.length === 0) {
      warnings.push(`org ${orgId}: no other member found to reassign listings to`);
    } else {
      others.sort((a, b) => (ROLE_RANK[a.role as string] ?? 9) - (ROLE_RANK[b.role as string] ?? 9));
      const heir = others[0].user_id as string;
      await step(`reassign listings in shared org ${orgId}`, () =>
        admin.from("listings").update({ agent_id: heir }).eq("org_id", orgId).eq("agent_id", userId));
    }
    await step(`leave shared org ${orgId}`, () =>
      admin.from("memberships").delete().eq("org_id", orgId).eq("user_id", userId));
  }

  // 3. Solely-owned orgs: purge everything, children first (FK-safe order).
  for (const orgId of soloOrgs) {
    const listingIds = await selectIds("listing ids", "listings", "id", "org_id", [orgId]);
    const jobIds = await selectIds("render_job ids", "render_jobs", "id", "listing_id", listingIds);
    const renderIds = await selectIds("render ids", "renders", "id", "listing_id", listingIds);
    const assetIds = await selectIds("asset ids", "capture_assets", "id", "listing_id", listingIds);

    // Rows that reference the org directly (their listing/job FKs are set-null,
    // so deleting them first also removes the user's lead/usage/spend data).
    await step("delete metering (org)", () => admin.from("metering").delete().eq("org_id", orgId));
    await deleteIn("delete metering (renders)", "metering", "render_id", renderIds);
    await step("delete leads (org)", () => admin.from("leads").delete().eq("org_id", orgId));
    await deleteIn("delete leads (renders)", "leads", "render_id", renderIds);
    await deleteIn("delete leads (listings)", "leads", "listing_id", listingIds);
    await step("delete cost_ledger (org)", () => admin.from("cost_ledger").delete().eq("org_id", orgId));
    await deleteIn("delete cost_ledger (jobs)", "cost_ledger", "job_id", jobIds);

    // Render pipeline: renders before their jobs.
    await deleteIn("delete renders", "renders", "listing_id", listingIds);
    await deleteIn("delete render_jobs", "render_jobs", "listing_id", listingIds);

    // Capture data: chapters before their assets.
    await deleteIn("delete capture_chapters", "capture_chapters", "asset_id", assetIds);
    await deleteIn("delete capture_assets", "capture_assets", "listing_id", listingIds);
    await deleteIn("delete photos", "photos", "listing_id", listingIds);

    // Listings, then the org shell.
    await step("delete listings", () => admin.from("listings").delete().eq("org_id", orgId));
    await step("delete memberships", () => admin.from("memberships").delete().eq("org_id", orgId));
    await step(`delete org ${orgId}`, () => admin.from("orgs").delete().eq("id", orgId));
  }

  // 4. The user's profile row (auth cascade would get it too — be explicit).
  await step("delete profile", () => admin.from("profiles").delete().eq("id", userId));

  // 5. Finally the auth user. This is the one step that MUST succeed.
  const { error: authErr } = await admin.auth.admin.deleteUser(userId);
  if (authErr) {
    return json(
      {
        ok: false,
        error: `Account data was removed but the sign-in record could not be deleted: ${authErr.message}`,
        ...(warnings.length ? { warnings } : {}),
      },
      500,
    );
  }

  return json({
    ok: true,
    deleted_orgs: soloOrgs.length,
    left_orgs: sharedOrgs.length,
    ...(warnings.length ? { warnings } : {}),
  });
}
