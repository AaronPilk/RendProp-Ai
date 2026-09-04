// me — the signed-in user, their org, plan, and account lifecycle (owner).
//
//   GET    /me                  -> { user, org, plan, plan_raw, trial_ends_at, entitlement,
//                                    usage: { month, by_feature, windows, renders, leads, leads_new, listings, cost_cents },
//                                    portfolio_url }
//                                  plan = EFFECTIVE plan (an expired trial reads `free`),
//                                  entitlement = the plan_entitlements row the server enforces,
//                                  usage.by_feature = this window's consumption per meter
//                                  (audit F-supabase-16 / F-E-15; decision B4).
//   PATCH  /me/brand            -> { ok, brand_kit, org: { name, handle }, portfolio_url }
//                                  brand-kit fields + `handle` (public portfolio slug,
//                                  unique → 409) + `org_name` (business name; never an email)
//   POST   /me/apple-code       -> { ok, stored }      (Sign in with Apple: exchange +
//                                  store the refresh token for later revocation, TN3194)
//   DELETE /me                  -> { ok, deletion_request_id, cleanup_complete, pending, warnings? }
//   POST   /me/sweep-deletions  -> { ok, processed }   (service-role only; retry queue)
//
// Account deletion (audit P0-4) is DURABLE now:
//   1. Every external cleanup target (R2 objects, Stream UIDs, CRM lead emails,
//      the Apple refresh token) is collected and written to a
//      deletion_requests tombstone BEFORE anything is destroyed.
//   2. Share links are revoked immediately (renders unpublished → tours 404).
//   3. DB rows are purged, then external cleanup is attempted inline.
//   4. Whatever fails or exceeds inline caps STAYS in the tombstone and is
//      retried by /me/sweep-deletions (wire it to a schedule — see runbook)
//      until the payload is empty; the response reports the honest state via
//      `cleanup_complete` + `pending` counts instead of a blanket ok.
//   5. The auth record is deleted last; if THAT fails the request stays
//      pending and the response is a 500, not a false success.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError, round4 } from "../_shared/http.ts";
import { entitlementFor } from "../_shared/entitlements.ts";
import {
  deleteObjects,
  R2_BUCKET_RENDERS,
  R2_BUCKET_UPLOADS,
  type R2Object,
} from "../_shared/r2.ts";
import { deleteStreamVideo, streamConfigured } from "../_shared/stream.ts";
import { appleConfigured, exchangeAppleCode, revokeAppleToken } from "../_shared/apple.ts";
import {
  adminClient,
  getUser,
  isServiceRole,
  orgForUser,
  preferredOrg,
  userClient,
} from "../_shared/supabase.ts";

const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const seg = pathSegments(req, "me");

    // Service-role retry queue — no user JWT involved.
    if (req.method === "POST" && seg[0] === "sweep-deletions") {
      if (!isServiceRole(req)) throw new HttpError(403, "Service role required");
      return await sweepDeletions();
    }

    const user = await getUser(req);

    if (req.method === "GET") return await handleGet(req, user.id, user.email ?? null);
    if (req.method === "PATCH") {
      if (seg[0] === "brand") return await handleBrandPatch(req, user.id);
      throw new HttpError(404, "Unknown route — PATCH /me/brand");
    }
    if (req.method === "POST" && seg[0] === "apple-code") {
      return await handleAppleCode(req, user.id);
    }
    if (req.method === "DELETE") return await handleDelete(user.id, user.email ?? null);

    throw new HttpError(405, "Only GET, PATCH, POST /me/apple-code, and DELETE are supported");
  } catch (err) {
    return respondError(err);
  }
});

// ── GET /me ───────────────────────────────────────────────────────────────────
//
// The app builds its "plan + usage" screen and its tier gating from this ONE
// response, so it must say what the server actually enforces:
//   plan            effective_plan() — an expired trial reads `free` here exactly
//                   as it does in the charge paths (audit F-supabase-04/16)
//   plan_raw        orgs.plan as stored (so the UI can say "trial ended")
//   entitlement     the plan_entitlements row (renders/edits/clips/aerials/topaz/seats)
//   usage.by_feature this window's consumption per meter — the same rate_limits
//                   rows the AI routes charge, plus the month's WORKER render jobs
//                   (app publishes are free and excluded, decision A15)
//   usage.windows   when each 30-day meter resets (null = not started yet)
//   usage.renders   is MONTH-scoped (it was all-time, audit F-E-15)

const METERS: Record<string, string> = {
  photo_edits: "aiphotomo",
  reels: "reelmo",
  aerials: "aerialmo",
  drone: "dronemo",
};

async function handleGet(req: Request, userId: string, userEmail: string | null): Promise<Response> {
  const db = userClient(req);
  const admin = adminClient();
  const orgId = await orgForUser(userId, preferredOrg(req));

  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
  const month = monthStart.slice(0, 7); // YYYY-MM
  const meterKeys = Object.values(METERS).map((k) => `${k}:${orgId}`);

  const [profileRes, orgRes, ledgerRes, leadsRes, leadsNewRes, listingsRes, jobsRes, metersRes, entitlement] =
    await Promise.all([
      db.from("profiles").select("id, email, name, avatar_url, phone").eq("id", userId).maybeSingle(),
      db.from("orgs").select("id, name, handle, space_type, plan, trial_ends_at, brand_kit").eq("id", orgId).maybeSingle(),
      db.from("cost_ledger").select("total_cents").eq("org_id", orgId).gte("created_at", monthStart),
      db.from("leads").select("id", { count: "exact", head: true }).eq("org_id", orgId).gte("created_at", monthStart),
      db.from("leads").select("id", { count: "exact", head: true }).eq("org_id", orgId).eq("status", "new"),
      db.from("listings").select("id", { count: "exact", head: true }).eq("org_id", orgId).is("deleted_at", null),
      // Worker render jobs this calendar month — the exact count create_render_job
      // enforces the cap against. render_jobs has no org_id: join via listings.
      admin
        .from("render_jobs")
        .select("id, listings!inner(org_id)", { count: "exact", head: true })
        .eq("listings.org_id", orgId)
        .eq("source", "worker")
        .gte("created_at", monthStart),
      // rate_limits is service-role only (0004): read the org's meters here.
      admin.from("rate_limits").select("key, count, window_start, window_seconds").in("key", meterKeys),
      entitlementFor(orgId),
    ]);

  if (orgRes.error) throw new HttpError(500, `Org lookup failed: ${orgRes.error.message}`);
  if (!orgRes.data) throw new HttpError(404, "Org not found");
  const org = orgRes.data;

  const costCents = round4(
    (ledgerRes.data ?? []).reduce((s, r) => s + Number(r.total_cents ?? 0), 0),
  );

  // Meter rows → used/resets_at. bump_rate still increments past the cap, so
  // clamp what we show; an expired window counts as 0 (it resets on next use).
  const nowMs = now.getTime();
  const byFeature: Record<string, number> = { renders: jobsRes.count ?? 0 };
  const windows: Record<string, { started_at: string; resets_at: string } | null> = { renders: {
    started_at: monthStart,
    resets_at: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString(),
  } };
  const caps: Record<string, number> = {
    renders: entitlement.renders_per_month,
    photo_edits: entitlement.photo_edits_per_month,
    reels: entitlement.reels_per_month,
    aerials: entitlement.aerials_per_month,
    drone: entitlement.topaz_per_month,
  };
  const rows = (metersRes.data ?? []) as Array<{ key: string; count: number; window_start: string; window_seconds: number }>;
  for (const [feature, prefix] of Object.entries(METERS)) {
    const row = rows.find((r) => r.key === `${prefix}:${orgId}`);
    if (!row) { byFeature[feature] = 0; windows[feature] = null; continue; }
    const startMs = Date.parse(row.window_start);
    const endMs = startMs + Number(row.window_seconds ?? 2_592_000) * 1000;
    if (!Number.isFinite(startMs) || endMs <= nowMs) { byFeature[feature] = 0; windows[feature] = null; continue; }
    const cap = Math.max(0, caps[feature] ?? 0);
    const used = Math.max(0, Number(row.count ?? 0));
    byFeature[feature] = cap > 0 ? Math.min(used, cap) : used;
    windows[feature] = { started_at: new Date(startMs).toISOString(), resets_at: new Date(endMs).toISOString() };
  }
  byFeature.renders = Math.max(0, byFeature.renders);

  const portfolioUrl = org.handle ? `${TOUR_BASE}/a/${org.handle}` : null;

  return json({
    user: profileRes.data ?? { id: userId, email: userEmail },
    org: { id: org.id, name: org.name, handle: org.handle, space_type: org.space_type, plan: org.plan, brand_kit: org.brand_kit },
    plan: entitlement.plan,          // EFFECTIVE (expired trial → free)
    plan_raw: org.plan ?? null,
    trial_ends_at: org.trial_ends_at ?? null,
    entitlement: {
      plan: entitlement.plan,
      renders_per_month: entitlement.renders_per_month,
      photo_edits_per_month: entitlement.photo_edits_per_month,
      reels_per_month: entitlement.reels_per_month,
      aerials_per_month: entitlement.aerials_per_month,
      topaz_per_month: entitlement.topaz_per_month,
      seats: entitlement.seats,
      ...(entitlement.degraded ? { degraded: true } : {}),
    },
    usage: {
      month,
      by_feature: byFeature,        // { renders, photo_edits, reels, aerials, drone } — used this window
      caps,                         // same keys — what the plan allows
      windows,                      // same keys — { started_at, resets_at } | null
      renders: byFeature.renders,   // month-scoped, worker renders only (app publishes are free)
      leads: leadsRes.count ?? 0,
      leads_new: leadsNewRes.count ?? 0,
      listings: listingsRes.count ?? 0,
      cost_cents: costCents,        // internal provider COGS this month (legacy field)
    },
    portfolio_url: portfolioUrl,
  });
}

// ── PATCH /me/brand ───────────────────────────────────────────────────────────
//
// Writes the agent/business card into org.brand_kit. The PUBLIC tours and
// portfolio functions allow-list exactly these display fields, so this is the
// single write path that makes the card appear on every hosted share link.
// Uses the user client: RLS (owner/admin, 0007) + the column-scoped grant
// (0005) restrict the update to orgs the caller may edit, and `plan` stays
// untouchable.
//
// Also accepts the two org columns the card needs (audit F-supabase-15/06):
//   handle    public portfolio slug (/a/:handle) — ^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$,
//             not a reserved word, unique (→ 409). null/"" clears it.
//   org_name  the business name shown on the portfolio page (never an email).
// When `name` (the card name) is set and the org still carries a placeholder
// name ("My business" or an email left by the old trigger), the org is named
// after the card so the portfolio page heals without a second call.

const BRAND_FIELDS = [
  "name", "title", "brokerage", "phone", "email", "website",
  "avatar_url", "headshot_url", "instagram", "linkedin", "tiktok", "accent",
] as const;
const MAX_BRAND_FIELD_CHARS = 300;
const MAX_BRAND_KIT_BYTES = 8_000;
const HEX_COLOR = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;
const HANDLE_RE = /^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$/;
const RESERVED_HANDLES = new Set([
  "admin", "api", "app", "www", "rendprop", "f", "a", "tours", "tour", "pricing", "privacy",
  "terms", "support", "help", "login", "signup", "me", "leads", "static", "assets", "demo",
  "estate-demo", "about", "blog", "contact", "portfolio", "agent", "agents",
]);

function isPlaceholderOrgName(name: unknown): boolean {
  const s = String(name ?? "").trim();
  return s === "" || s === "My business" || s.includes("@");
}

async function handleBrandPatch(req: Request, userId: string): Promise<Response> {
  const db = userClient(req);
  const orgId = await orgForUser(userId, preferredOrg(req));
  const body = await readJson<Record<string, unknown>>(req);

  const patch: Record<string, string | null> = {};
  for (const f of BRAND_FIELDS) {
    if (!(f in body)) continue;
    const v = body[f];
    if (v === null || v === "") { patch[f] = null; continue; }
    assert(typeof v === "string", 400, `${f} must be a string`);
    const s = (v as string).trim();
    assert(s.length <= MAX_BRAND_FIELD_CHARS, 400, `${f} is too long (max ${MAX_BRAND_FIELD_CHARS} chars)`);
    if (f === "accent") assert(HEX_COLOR.test(s), 400, "accent must be a hex color like #7c3aed");
    if (f === "name") assert(!s.includes("@"), 400, "name must be a display name, not an email address");
    patch[f] = s;
  }

  // Org columns.
  const orgPatch: Record<string, string | null> = {};
  if ("handle" in body) {
    const v = body.handle;
    if (v === null || v === "") {
      orgPatch.handle = null;
    } else {
      assert(typeof v === "string", 400, "handle must be a string");
      const h = (v as string).trim().toLowerCase();
      assert(HANDLE_RE.test(h), 400, "handle must be 3–32 characters: lowercase letters, digits and hyphens, starting and ending with a letter or digit");
      assert(!RESERVED_HANDLES.has(h), 409, "That handle is reserved — choose another", "conflict");
      orgPatch.handle = h;
    }
  }
  if ("org_name" in body) {
    const v = body.org_name;
    assert(typeof v === "string" && v.trim().length > 0, 400, "org_name must be a non-empty string");
    const n = (v as string).trim();
    assert(n.length <= 120, 400, "org_name is too long (max 120 chars)");
    assert(!n.includes("@"), 400, "org_name must be a business name, not an email address");
    orgPatch.name = n;
  }

  assert(Object.keys(patch).length + Object.keys(orgPatch).length > 0, 400,
    `No brand fields provided. Accepted: ${BRAND_FIELDS.join(", ")}, handle, org_name`);

  const { data: org, error: oErr } = await db
    .from("orgs").select("id, name, handle, brand_kit").eq("id", orgId).maybeSingle();
  if (oErr) throw new HttpError(500, `Org lookup failed: ${oErr.message}`);
  if (!org) throw new HttpError(404, "Org not found");

  const merged: Record<string, unknown> = { ...((org.brand_kit as Record<string, unknown> | null) ?? {}) };
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete merged[k];
    else merged[k] = v;
  }
  assert(JSON.stringify(merged).length <= MAX_BRAND_KIT_BYTES, 400, "brand kit is too large");

  // Heal a placeholder/email org name from the card name (see header).
  if (!("name" in orgPatch) && typeof patch.name === "string" && isPlaceholderOrgName(org.name)) {
    orgPatch.name = patch.name;
  }

  const update: Record<string, unknown> = { ...orgPatch };
  if (Object.keys(patch).length > 0) update.brand_kit = merged;

  const { data: updated, error: upErr } = await db
    .from("orgs").update(update).eq("id", orgId).select("id, name, handle, brand_kit").maybeSingle();
  if (upErr) {
    // 23505 = unique_violation on orgs.handle.
    if ((upErr as { code?: string }).code === "23505" || /duplicate key|orgs_handle_key/i.test(upErr.message)) {
      throw new HttpError(409, "That handle is already taken — choose another", "conflict");
    }
    throw new HttpError(500, `Brand update failed: ${upErr.message}`);
  }
  // RLS (owner/admin only) filtered the row: a member without the right role.
  if (!updated) throw new HttpError(403, "Only the workspace owner or an admin can edit the brand card");

  const handle = (updated.handle as string | null) ?? null;
  return json({
    ok: true,
    brand_kit: updated.brand_kit ?? merged,
    org: { name: updated.name, handle },
    portfolio_url: handle ? `${TOUR_BASE}/a/${handle}` : null,
  });
}

// ── POST /me/apple-code ───────────────────────────────────────────────────────
// The app sends Sign in with Apple's authorizationCode right after sign-in
// (codes are single-use, ~5 min). We exchange it for a refresh token and store
// it so DELETE /me can revoke the Apple grant (TN3194). Best-effort by design:
// a failure here must never block sign-in.

async function handleAppleCode(req: Request, userId: string): Promise<Response> {
  const body = await readJson<{ authorization_code?: string }>(req);
  const code = (body.authorization_code ?? "").trim();
  assert(code.length > 0 && code.length <= 2048, 400, "authorization_code is required");

  if (!appleConfigured()) {
    return json({ ok: true, stored: false, reason: "apple revocation not configured" });
  }
  try {
    const refreshToken = await exchangeAppleCode(code);
    if (!refreshToken) return json({ ok: true, stored: false, reason: "no refresh token returned" });
    const { error } = await adminClient()
      .from("profiles")
      .update({ apple_refresh_token: refreshToken })
      .eq("id", userId);
    if (error) return json({ ok: true, stored: false, reason: error.message });
    return json({ ok: true, stored: true });
  } catch (e) {
    console.error("apple code exchange failed:", e);
    return json({ ok: true, stored: false, reason: "exchange failed" });
  }
}

// ── DELETE /me ────────────────────────────────────────────────────────────────

const ROLE_RANK: Record<string, number> = { owner: 0, admin: 1, agent: 2, marketing: 3 };
const ID_CHUNK = 200;
const INLINE_R2_CAP = 5000;
const INLINE_STREAM_CAP = 50;
const INLINE_CRM_CAP = 50;

interface DeletionPayload {
  r2: R2Object[];
  stream_uids: string[];
  ghl_emails: string[];
  apple_refresh_token: string | null;
  /** Row deletions that FAILED and must be retried. Previously these were
   * warnings only, so a failed row delete (or share-link revocation) was never
   * retried while the response still said ok:true — data retained, nobody
   * chasing it (audit round 4). */
  db?: {
    org_ids?: string[];
    listing_ids?: string[];
    render_ids?: string[];
    job_ids?: string[];
    asset_ids?: string[];
  };
}

const dbEmpty = (d: DeletionPayload["db"]) =>
  !d || (!d.org_ids?.length && !d.listing_ids?.length && !d.render_ids?.length &&
         !d.job_ids?.length && !d.asset_ids?.length);

/**
 * Re-run the row deletions + share revocation for a tombstone. Idempotent:
 * every statement is a delete-by-id or an update to a terminal state, so
 * re-running after a partial success is safe.
 */
// deno-lint-ignore no-explicit-any
async function retryDbCleanup(admin: any, db: NonNullable<DeletionPayload["db"]>): Promise<string[]> {
  const notes: string[] = [];
  const run = async (label: string, fn: () => PromiseLike<{ error: { message: string } | null }>) => {
    try {
      const { error } = await fn();
      if (error) notes.push(`${label}: ${error.message}`);
    } catch (e) {
      notes.push(`${label}: ${e instanceof Error ? e.message : String(e)}`);
    }
  };
  const listingIds = db.listing_ids ?? [];
  const renderIds = db.render_ids ?? [];
  const jobIds = db.job_ids ?? [];
  const assetIds = db.asset_ids ?? [];

  for (const ids of chunk(listingIds)) {
    await run("revoke share links", () =>
      admin.from("renders").update({ published_at: null }).in("listing_id", ids));
  }
  for (const orgId of db.org_ids ?? []) {
    await run("metering (org)", () => admin.from("metering").delete().eq("org_id", orgId));
    await run("leads (org)", () => admin.from("leads").delete().eq("org_id", orgId));
    await run("cost_ledger (org)", () => admin.from("cost_ledger").delete().eq("org_id", orgId));
  }
  for (const ids of chunk(renderIds)) {
    await run("metering (renders)", () => admin.from("metering").delete().in("render_id", ids));
    await run("leads (renders)", () => admin.from("leads").delete().in("render_id", ids));
  }
  for (const ids of chunk(listingIds)) {
    await run("leads (listings)", () => admin.from("leads").delete().in("listing_id", ids));
  }
  for (const ids of chunk(jobIds)) {
    await run("cost_ledger (jobs)", () => admin.from("cost_ledger").delete().in("job_id", ids));
  }
  for (const ids of chunk(listingIds)) {
    await run("renders", () => admin.from("renders").delete().in("listing_id", ids));
    await run("render_jobs", () => admin.from("render_jobs").delete().in("listing_id", ids));
  }
  for (const ids of chunk(assetIds)) {
    await run("capture_chapters", () => admin.from("capture_chapters").delete().in("asset_id", ids));
  }
  for (const ids of chunk(listingIds)) {
    await run("capture_assets", () => admin.from("capture_assets").delete().in("listing_id", ids));
    await run("photos", () => admin.from("photos").delete().in("listing_id", ids));
  }
  for (const orgId of db.org_ids ?? []) {
    await run("listings", () => admin.from("listings").delete().eq("org_id", orgId));
    await run("memberships", () => admin.from("memberships").delete().eq("org_id", orgId));
    await run("org", () => admin.from("orgs").delete().eq("id", orgId));
  }
  return notes;
}

function chunk<T>(items: T[], size = ID_CHUNK): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

// deno-lint-ignore no-explicit-any
async function collectIds(admin: any, table: string, column: string, filterColumn: string, filterIds: string[]): Promise<string[]> {
  const out: string[] = [];
  for (const ids of chunk(filterIds)) {
    const { data, error } = await admin.from(table).select(column).in(filterColumn, ids);
    if (error) throw new HttpError(500, `Deletion aborted — could not enumerate ${table}: ${error.message}`);
    for (const row of (data ?? []) as Record<string, unknown>[]) {
      const v = row[column];
      if (typeof v === "string" && v) out.push(v);
    }
  }
  return out;
}

/** Delete GHL contacts matching an exact email. Throws on API failure. */
async function deleteGhlContactsByEmail(email: string): Promise<number> {
  const key = Deno.env.get("GHL_API_KEY");
  const locationId = Deno.env.get("GHL_LOCATION_ID");
  if (!key || !locationId) throw new Error("GHL not configured");
  const headers = {
    Authorization: `Bearer ${key}`,
    Version: "2021-07-28",
    Accept: "application/json",
  };
  const url = new URL("https://services.leadconnectorhq.com/contacts/");
  url.searchParams.set("locationId", locationId);
  url.searchParams.set("query", email);
  const res = await fetch(url, { headers });
  if (!res.ok) throw new Error(`GHL search ${res.status}`);
  const data = await res.json().catch(() => ({}));
  const contacts = (data?.contacts ?? []) as Array<{ id?: string; email?: string }>;
  let removed = 0;
  for (const c of contacts) {
    if (!c.id || (c.email ?? "").toLowerCase() !== email.toLowerCase()) continue;
    const del = await fetch(`https://services.leadconnectorhq.com/contacts/${c.id}`, {
      method: "DELETE",
      headers,
    });
    if (del.ok || del.status === 404) removed++;
    else throw new Error(`GHL delete ${c.id} -> ${del.status}`);
  }
  return removed;
}

/** Attempt the external cleanup in a payload. Returns what REMAINS + notes. */
async function processPayload(payload: DeletionPayload): Promise<{ remaining: DeletionPayload; notes: string[] }> {
  const notes: string[] = [];
  const remaining: DeletionPayload = {
    r2: [],
    stream_uids: [],
    ghl_emails: [],
    apple_refresh_token: payload.apple_refresh_token ?? null,
  };

  // Row deletions / share revocation that failed on an earlier pass.
  if (!dbEmpty(payload.db)) {
    const dbNotes = await retryDbCleanup(adminClient(), payload.db!);
    if (dbNotes.length) {
      notes.push(...dbNotes.map((n) => `db retry: ${n}`));
      remaining.db = payload.db; // still failing — keep it queued
    }
  }

  // R2 (bounded per pass; leftovers stay queued).
  if (payload.r2.length) {
    const batch = payload.r2.slice(0, INLINE_R2_CAP);
    const rest = payload.r2.slice(INLINE_R2_CAP);
    try {
      const { errors } = await deleteObjects(batch, 8, INLINE_R2_CAP);
      // deleteObjects reports failures only as messages (not per-object), so
      // requeue the whole batch when any failed — deletes are idempotent
      // (404 = already gone), so re-running the batch is safe.
      if (errors.length) {
        notes.push(`r2: ${errors.length} objects failed this pass`);
        remaining.r2.push(...batch);
      }
    } catch (e) {
      notes.push(`r2: ${e instanceof Error ? e.message : String(e)}`);
      remaining.r2.push(...batch);
    }
    remaining.r2.push(...rest);
    if (rest.length) notes.push(`r2: ${rest.length} objects queued beyond the per-pass cap`);
  }

  // Stream.
  const streamTodo = payload.stream_uids ?? [];
  if (streamTodo.length) {
    if (!streamConfigured()) {
      notes.push("stream: API token not configured — queued");
      remaining.stream_uids.push(...streamTodo);
    } else {
      for (let i = 0; i < streamTodo.length; i++) {
        if (i >= INLINE_STREAM_CAP) { remaining.stream_uids.push(streamTodo[i]); continue; }
        try {
          await deleteStreamVideo(streamTodo[i]);
        } catch (e) {
          notes.push(`stream ${streamTodo[i]}: ${e instanceof Error ? e.message : String(e)}`);
          remaining.stream_uids.push(streamTodo[i]);
        }
      }
    }
  }

  // CRM (GoHighLevel) — the org's captured lead contacts.
  const crmTodo = payload.ghl_emails ?? [];
  if (crmTodo.length) {
    const ghlConfigured = Boolean(Deno.env.get("GHL_API_KEY") && Deno.env.get("GHL_LOCATION_ID"));
    if (!ghlConfigured) {
      notes.push("crm: GHL not configured — queued");
      remaining.ghl_emails.push(...crmTodo);
    } else {
      for (let i = 0; i < crmTodo.length; i++) {
        if (i >= INLINE_CRM_CAP) { remaining.ghl_emails.push(crmTodo[i]); continue; }
        try {
          await deleteGhlContactsByEmail(crmTodo[i]);
        } catch (e) {
          notes.push(`crm ${crmTodo[i]}: ${e instanceof Error ? e.message : String(e)}`);
          remaining.ghl_emails.push(crmTodo[i]);
        }
      }
    }
  }

  // Apple revocation.
  if (payload.apple_refresh_token) {
    if (!appleConfigured()) {
      notes.push("apple: revocation not configured — queued");
    } else {
      try {
        const ok = await revokeAppleToken(payload.apple_refresh_token);
        if (ok) remaining.apple_refresh_token = null;
        else notes.push("apple: revoke rejected — queued");
      } catch (e) {
        notes.push(`apple: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
  }

  return { remaining, notes };
}

function payloadEmpty(p: DeletionPayload): boolean {
  return p.r2.length === 0 && p.stream_uids.length === 0 &&
    p.ghl_emails.length === 0 && !p.apple_refresh_token && dbEmpty(p.db);
}

async function handleDelete(userId: string, userEmail: string | null): Promise<Response> {
  const admin = adminClient();
  const warnings: string[] = [];

  async function step(label: string, fn: () => PromiseLike<{ error: { message: string } | null }>) {
    try {
      const { error } = await fn();
      if (error) warnings.push(`${label}: ${error.message}`);
    } catch (e) {
      warnings.push(`${label}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  async function deleteIn(label: string, table: string, column: string, ids: string[]) {
    for (const part of chunk(ids)) {
      await step(label, () => admin.from(table).delete().in(column, part));
    }
  }

  // ── Phase 0: enumerate memberships. A failure here ABORTS (nothing touched).
  const { data: myMemberships, error: memErr } = await admin
    .from("memberships").select("org_id").eq("user_id", userId);
  if (memErr) throw new HttpError(500, `Deletion aborted — membership lookup failed: ${memErr.message}`);

  const orgIds = [...new Set((myMemberships ?? []).map((m) => m.org_id as string))];
  const soloOrgs: string[] = [];
  const sharedOrgs: string[] = [];
  for (const orgId of orgIds) {
    const { count, error } = await admin
      .from("memberships").select("id", { count: "exact", head: true }).eq("org_id", orgId);
    if (error) throw new HttpError(500, `Deletion aborted — member count failed for org ${orgId}: ${error.message}`);
    ((count ?? 0) <= 1 ? soloOrgs : sharedOrgs).push(orgId);
  }

  // ── Phase 1: collect EVERY cleanup target before destroying anything.
  const payload: DeletionPayload = { r2: [], stream_uids: [], ghl_emails: [], apple_refresh_token: null };
  const allListingIds: string[] = [];
  const allJobIds: string[] = [];
  const allRenderIds: string[] = [];
  const allAssetIds: string[] = [];

  for (const orgId of soloOrgs) {
    const listingIds = await collectIds(admin, "listings", "id", "org_id", [orgId]);
    const jobIds = await collectIds(admin, "render_jobs", "id", "listing_id", listingIds);
    const renderIds = await collectIds(admin, "renders", "id", "listing_id", listingIds);
    const assetIds = await collectIds(admin, "capture_assets", "id", "listing_id", listingIds);
    allListingIds.push(...listingIds);
    allJobIds.push(...jobIds);
    allRenderIds.push(...renderIds);
    allAssetIds.push(...assetIds);

    for (const ids of chunk(listingIds)) {
      const { data: assets, error: aErr } = await admin
        .from("capture_assets").select("storage_key, bucket").in("listing_id", ids);
      if (aErr) throw new HttpError(500, `Deletion aborted — asset key enumeration failed: ${aErr.message}`);
      for (const row of (assets ?? []) as { storage_key: string | null; bucket: string | null }[]) {
        if (row.storage_key) {
          payload.r2.push({
            bucket: row.bucket === "renders" ? R2_BUCKET_RENDERS : R2_BUCKET_UPLOADS,
            key: row.storage_key,
          });
        }
      }
      const { data: photos, error: pErr } = await admin
        .from("photos").select("original_key, enhanced_key").in("listing_id", ids);
      if (pErr) throw new HttpError(500, `Deletion aborted — photo key enumeration failed: ${pErr.message}`);
      for (const row of (photos ?? []) as { original_key: string | null; enhanced_key: string | null }[]) {
        if (row.original_key) payload.r2.push({ bucket: R2_BUCKET_UPLOADS, key: row.original_key });
        if (row.enhanced_key) payload.r2.push({ bucket: R2_BUCKET_RENDERS, key: row.enhanced_key });
      }
      const { data: renders, error: rErr } = await admin
        .from("renders").select("video_key, poster_key, stream_uid").in("listing_id", ids);
      if (rErr) throw new HttpError(500, `Deletion aborted — render key enumeration failed: ${rErr.message}`);
      for (const row of (renders ?? []) as { video_key: string | null; poster_key: string | null; stream_uid: string | null }[]) {
        if (row.video_key) payload.r2.push({ bucket: R2_BUCKET_RENDERS, key: row.video_key });
        if (row.poster_key) payload.r2.push({ bucket: R2_BUCKET_RENDERS, key: row.poster_key });
        if (row.stream_uid) payload.stream_uids.push(row.stream_uid);
      }
    }

    // CRM cleanup targets: the org's captured lead emails (pushed to GHL).
    const { data: leadRows, error: lErr } = await admin
      .from("leads").select("email").eq("org_id", orgId).not("email", "is", null);
    if (lErr) throw new HttpError(500, `Deletion aborted — lead enumeration failed: ${lErr.message}`);
    for (const row of (leadRows ?? []) as { email: string | null }[]) {
      if (row.email) payload.ghl_emails.push(row.email);
    }
  }
  payload.ghl_emails = [...new Set(payload.ghl_emails)];

  // Profile read failure is NOT ignorable: silently losing the Apple refresh
  // token means the grant is never revoked and nothing records that (audit).
  const { data: profile, error: profErr } = await admin
    .from("profiles").select("apple_refresh_token, email").eq("id", userId).maybeSingle();
  if (profErr) {
    throw new HttpError(500, `Deletion aborted — profile lookup failed: ${profErr.message}`);
  }
  payload.apple_refresh_token = (profile?.apple_refresh_token as string | null) ?? null;

  // ── Phase 2: tombstone FIRST. If this fails, nothing has been destroyed.
  const { data: tombstone, error: tErr } = await admin
    .from("deletion_requests")
    .insert({
      user_id: userId,
      email: userEmail ?? (profile?.email as string | null) ?? null,
      status: "processing",
      attempts: 1,
      payload: payload as unknown as Record<string, unknown>,
    })
    .select("id")
    .single();
  if (tErr) throw new HttpError(500, `Deletion aborted — could not record the deletion request: ${tErr.message}`);
  const requestId = tombstone.id as string;

  // ── Phase 3: immediate share-link revocation (tours 404 from this moment).
  for (const ids of chunk(allListingIds)) {
    await step("revoke share links", () =>
      admin.from("renders").update({ published_at: null }).in("listing_id", ids));
  }

  // ── Phase 4: shared orgs — reassign authored listings, drop membership.
  for (const orgId of sharedOrgs) {
    const { data: others, error } = await admin
      .from("memberships").select("user_id, role").eq("org_id", orgId).neq("user_id", userId);
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

  // ── Phase 5: purge solo-org rows, children first (targets already collected).
  for (const orgId of soloOrgs) {
    await step("delete metering (org)", () => admin.from("metering").delete().eq("org_id", orgId));
    await step("delete leads (org)", () => admin.from("leads").delete().eq("org_id", orgId));
    await step("delete cost_ledger (org)", () => admin.from("cost_ledger").delete().eq("org_id", orgId));
  }
  await deleteIn("delete metering (renders)", "metering", "render_id", allRenderIds);
  await deleteIn("delete leads (renders)", "leads", "render_id", allRenderIds);
  await deleteIn("delete leads (listings)", "leads", "listing_id", allListingIds);
  await deleteIn("delete cost_ledger (jobs)", "cost_ledger", "job_id", allJobIds);
  await deleteIn("delete renders", "renders", "listing_id", allListingIds);
  await deleteIn("delete render_jobs", "render_jobs", "listing_id", allListingIds);
  await deleteIn("delete capture_chapters", "capture_chapters", "asset_id", allAssetIds);
  await deleteIn("delete capture_assets", "capture_assets", "listing_id", allListingIds);
  await deleteIn("delete photos", "photos", "listing_id", allListingIds);
  for (const orgId of soloOrgs) {
    await step("delete listings", () => admin.from("listings").delete().eq("org_id", orgId));
    await step("delete memberships", () => admin.from("memberships").delete().eq("org_id", orgId));
    await step(`delete org ${orgId}`, () => admin.from("orgs").delete().eq("id", orgId));
  }

  // ── Phase 6: external cleanup, inline attempt. Leftovers stay tombstoned.
  const { remaining, notes } = await processPayload(payload);
  warnings.push(...notes);

  // Any row-deletion or share-revocation failure above becomes a RETRYABLE
  // payload, not just a warning — the sweeper re-runs it until it drains
  // (audit round 4: these were silently non-retryable while the response
  // still reported ok:true).
  if (warnings.length > 0) {
    remaining.db = {
      org_ids: soloOrgs,
      listing_ids: allListingIds,
      render_ids: allRenderIds,
      job_ids: allJobIds,
      asset_ids: allAssetIds,
    };
  }

  const cleanupComplete = payloadEmpty(remaining) && warnings.length === 0;
  await step("update deletion request", () =>
    admin.from("deletion_requests").update({
      status: cleanupComplete ? "completed" : "pending",
      payload: remaining as unknown as Record<string, unknown>,
      last_error: warnings.length ? warnings.slice(0, 10).join(" | ").slice(0, 2000) : null,
      completed_at: cleanupComplete ? new Date().toISOString() : null,
    }).eq("id", requestId));

  // ── Phase 7: profile + auth record. Auth deletion MUST succeed.
  await step("delete profile", () => admin.from("profiles").delete().eq("id", userId));
  const { error: authErr } = await admin.auth.admin.deleteUser(userId);
  if (authErr) {
    return json({
      ok: false,
      deletion_request_id: requestId,
      error: `Account data was removed but the sign-in record could not be deleted: ${authErr.message}`,
      ...(warnings.length ? { warnings } : {}),
    }, 500);
  }

  return json({
    ok: true,
    deletion_request_id: requestId,
    deleted_orgs: soloOrgs.length,
    left_orgs: sharedOrgs.length,
    cleanup_complete: cleanupComplete,
    pending: {
      r2_objects: remaining.r2.length,
      stream_videos: remaining.stream_uids.length,
      crm_contacts: remaining.ghl_emails.length,
      apple_revocation: Boolean(remaining.apple_refresh_token),
    },
    ...(warnings.length ? { warnings } : {}),
  });
}

// ── POST /me/sweep-deletions (service-role) ───────────────────────────────────
// Retries pending tombstones until their payloads drain. Wire to a schedule
// (Supabase cron → this endpoint with the service key) — see the runbook.

async function sweepDeletions(): Promise<Response> {
  const admin = adminClient();
  // Pick up `pending` AND stranded `processing` rows. A tombstone is inserted
  // as `processing` before any destruction; if the request then times out or
  // the status update itself fails, the row would sit in `processing` forever
  // and never be retried (audit: the sweeper only read `pending`). Anything
  // still `processing` after 15 minutes is by definition stranded.
  const stranded = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const { data: rows, error } = await admin
    .from("deletion_requests")
    .select("id, payload, attempts, status")
    .or(`status.eq.pending,and(status.eq.processing,requested_at.lt.${stranded})`)
    .order("requested_at", { ascending: true })
    .limit(5);
  if (error) throw new HttpError(500, `Sweep query failed: ${error.message}`);

  let processed = 0;
  for (const row of rows ?? []) {
    const raw = (row.payload ?? {}) as Record<string, unknown>;
    const payload: DeletionPayload = {
      r2: Array.isArray(raw.r2) ? raw.r2 as R2Object[] : [],
      stream_uids: Array.isArray(raw.stream_uids) ? raw.stream_uids as string[] : [],
      ghl_emails: Array.isArray(raw.ghl_emails) ? raw.ghl_emails as string[] : [],
      apple_refresh_token: (raw.apple_refresh_token as string | null) ?? null,
      db: (raw.db as DeletionPayload["db"]) ?? undefined,
    };
    const { remaining, notes } = await processPayload(payload);
    const done = payloadEmpty(remaining);
    await admin.from("deletion_requests").update({
      status: done ? "completed" : "pending",
      payload: remaining as unknown as Record<string, unknown>,
      attempts: (row.attempts as number ?? 0) + 1,
      last_error: notes.length ? notes.slice(0, 10).join(" | ").slice(0, 2000) : null,
      completed_at: done ? new Date().toISOString() : null,
    }).eq("id", row.id);
    processed++;
  }
  return json({ ok: true, processed });
}
