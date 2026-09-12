// me — the signed-in user, their org, plan, and account lifecycle (owner).
//
//   GET    /me                  -> { user, org, plan, plan_raw, trial_ends_at, entitlement,
//                                    plan_source, plan_expires_at, apple_product_id,
//                                    usage: { month, by_feature, windows, renders, leads, leads_new, listings, cost_cents },
//                                    portfolio_url }
//                                  plan = EFFECTIVE plan (an expired trial reads `free`),
//                                  entitlement = the plan_entitlements row the server enforces,
//                                  usage.by_feature = this window's consumption per meter
//                                  (audit F-supabase-16 / F-E-15; decision B4).
//   PATCH  /me/brand            -> { ok, brand_kit, org: { name, handle, space_type }, portfolio_url }
//                                  brand-kit fields + `handle` (public portfolio slug,
//                                  unique → 409) + `org_name` (business name; never an email)
//                                  + `space_type` (the workspace's industry, one of the six
//                                  the app knows; 400 otherwise — 0044 reads it for the
//                                  industry-aware trial)
//   GET    /me/compliance       -> { org_id, from, to, count, truncated, rows[] }
//                                  ?from=&to=&listing_id=&limit=&format=csv
//                                  The BROKER-EXPORTABLE AI audit log: every
//                                  media_provenance row for the workspace (see
//                                  §"Compliance export" below).
//   PATCH  /me/compliance/:id   -> { ok, provenance }
//                                  { original_asset_id?, altered_asset_id?, label? }
//                                  Attaches the untouched original and/or the
//                                  published result to a provenance row after
//                                  their uploads finish.
//   POST   /me/apple-code       -> { ok, stored }      (Sign in with Apple: exchange +
//                                  store the refresh token for later revocation, TN3194)
//   POST   /me/entitlement      -> { plan, source, expires_at, product_id,
//                                    original_transaction_id, environment, status,
//                                    replayed_notifications }
//                                  { signed_transaction, signed_renewal_info? } —
//                                  the StoreKit 2 JWS the app holds after a verified
//                                  purchase or restore. See §"Entitlement sync" below.
//   DELETE /me                  -> { ok, deletion_request_id, cleanup_complete, pending, warnings? }
//   POST   /me/sweep-deletions  -> { ok, processed, manual_review, deferred, escalated }
//                                  (service-role only; retry queue)
//
// Deletion ownership is now DB-owned (0039), not an Edge enumeration followed
// by later DELETEs. Under the same Auth/profile/org locks as adoption, SQL
// snapshots verified listing keys, writes the intent, revokes/purges DB rows,
// and returns a bound cleanup lease. Any SQL failure rolls everything back.
// The handler and sweeper execute only that receipt; failed external work and
// Auth deletion remain queued. Unbound legacy requests are manual-only and
// cannot erase an adoption winner. A separate controlled old-handler drain
// is required at rollout; a migration cannot retract a sent provider DELETE.
// `ok` requires the Auth user to be gone; `cleanup_complete` additionally
// requires all queued work done and no historical manual-review leftovers.
// Retained work no sweep can finish does not loop forever: after twelve
// passes without progress, or a GPU lease still unjournaled a day later, the
// DB parks the row (manual_review_required + escalation_reason) and the
// sweeper stops picking it up; nothing is erased to force completion.
// A non-`RPnnn` database failure on either RPC is a 503 "retry", never a 400
// that echoes the error text.

import { deleteAccount, sweepAccounts } from "./deletion.ts";
import { handleOptions } from "../_shared/cors.ts";
import {
  HttpError,
  assert,
  json,
  pathSegments,
  readJson,
  readJsonLimited,
  respondError,
  round4,
  throwRpc,
} from "../_shared/http.ts";
import { entitlementFor } from "../_shared/entitlements.ts";
import { isSpaceType, SPACE_TYPES } from "../_shared/spacetypes.ts";
import {
  abortMultipartUpload,
  deleteObjects,
  publicR2Url,
  R2_BUCKET_RENDERS,
  R2_BUCKET_UPLOADS,
  type R2Object,
} from "../_shared/r2.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { deleteStreamVideo, streamConfigured } from "../_shared/stream.ts";
import { appleConfigured, exchangeAppleCode, revokeAppleToken } from "../_shared/apple.ts";
import {
  type AppleRenewalInfo,
  decodeRenewalInfo,
  decodeTransaction,
  deriveEntitlement,
  productToPlan,
  verifyAppleJWS,
} from "../_shared/applejws.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import {
  adminClient,
  getUser,
  isServiceRole,
  orgForUser,
  preferredOrg,
  userClient,
} from "../_shared/supabase.ts";
import {
  decideGhlTagAction,
  type DeletionPayload,
  type GhlCleanupTarget,
} from "./logic.ts";

const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");
// The bundle id every Apple-signed transaction must carry. NAME only — this is
// the app's public identifier (it is in the binary and on the App Store), not a
// credential. Kept identical to apple-subscriptions/index.ts.
const APPLE_BUNDLE_ID = (Deno.env.get("APPLE_BUNDLE_ID") ?? "com.rendprop.app").trim();

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

    // The broker's AI audit log (compliance wave, W2-B3).
    if (req.method === "GET" && seg[0] === "compliance") {
      return await handleCompliance(req, user.id);
    }
    if (req.method === "PATCH" && seg[0] === "compliance") {
      return await handleCompliancePatch(req, user.id, seg[1]);
    }

    if (req.method === "GET") return await handleGet(req, user.id, user.email ?? null);
    if (req.method === "PATCH") {
      if (seg[0] === "brand") return await handleBrandPatch(req, user.id);
      throw new HttpError(404, "Unknown route — PATCH /me/brand or PATCH /me/compliance/:id");
    }
    if (req.method === "POST" && seg[0] === "apple-code") {
      return await handleAppleCode(req, user.id);
    }
    if (req.method === "POST" && seg[0] === "entitlement") {
      return await handleEntitlement(req, user.id);
    }
    if (req.method === "DELETE") return await handleDelete(user.id, user.email ?? null);

    throw new HttpError(
      405,
      "Only GET, GET /me/compliance, PATCH /me/brand, PATCH /me/compliance/:id, POST /me/apple-code, POST /me/entitlement, and DELETE are supported",
    );
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
      db.from("orgs").select(
        "id, name, handle, space_type, plan, trial_ends_at, brand_kit, plan_source, plan_expires_at, apple_product_id",
      ).eq("id", orgId).maybeSingle(),
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
    // Additive (launch wave, decision LC-§"Entitlement sync"). Optional in the
    // client: an app build older than migration 0019 simply ignores them.
    plan_source: org.plan_source ?? null,          // 'apple' | 'manual' | 'trial' | null
    plan_expires_at: org.plan_expires_at ?? null,  // end of the paid/grace window
    apple_product_id: org.apple_product_id ?? null,
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
// Also accepts the org columns the card needs (audit F-supabase-15/06):
//   handle      public portfolio slug (/a/:handle) — ^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$,
//               not a reserved word, unique (→ 409). null/"" clears it.
//   org_name    the business name shown on the portfolio page (never an email).
//   space_type  the workspace's industry — exactly one of _shared/spacetypes.ts
//               (real_estate | venue | restaurant | retail | fitness | other), 400
//               otherwise; the DB CHECK (0044) refuses anything else too. It is
//               what org_entitlement() reads for the industry-aware trial, so the
//               app should send it as soon as the person picks their business
//               type. Never cleared: the column is NOT NULL (default real_estate).
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
  if ("space_type" in body) {
    const v = body.space_type;
    const s = typeof v === "string" ? v.trim().toLowerCase() : v;
    assert(isSpaceType(s), 400, `space_type must be one of ${SPACE_TYPES.join(", ")}`);
    orgPatch.space_type = s;
  }

  assert(Object.keys(patch).length + Object.keys(orgPatch).length > 0, 400,
    `No brand fields provided. Accepted: ${BRAND_FIELDS.join(", ")}, handle, org_name, space_type`);

  const { data: org, error: oErr } = await db
    .from("orgs").select("id, name, handle, space_type, brand_kit").eq("id", orgId).maybeSingle();
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
    .from("orgs").update(update).eq("id", orgId).select("id, name, handle, space_type, brand_kit").maybeSingle();
  if (upErr) {
    // 23505 = unique_violation on orgs.handle.
    if ((upErr as { code?: string }).code === "23505" || /duplicate key|orgs_handle_key/i.test(upErr.message)) {
      throw new HttpError(409, "That handle is already taken — choose another", "conflict");
    }
    // 23514 = check_violation: orgs_space_type_check (0044). Unreachable past
    // the allowlist above unless the two lists drift — say so, not "500".
    if ((upErr as { code?: string }).code === "23514" || /orgs_space_type_check/i.test(upErr.message)) {
      throw new HttpError(400, `space_type must be one of ${SPACE_TYPES.join(", ")}`);
    }
    throw new HttpError(500, `Brand update failed: ${upErr.message}`);
  }
  // RLS (owner/admin only) filtered the row: a member without the right role.
  if (!updated) throw new HttpError(403, "Only the workspace owner or an admin can edit the brand card");

  const handle = (updated.handle as string | null) ?? null;
  return json({
    ok: true,
    brand_kit: updated.brand_kit ?? merged,
    org: { name: updated.name, handle, space_type: updated.space_type ?? org.space_type ?? null },
    portfolio_url: handle ? `${TOUR_BASE}/a/${handle}` : null,
  });
}

// ── GET /me/compliance ────────────────────────────────────────────────────────
//
// The broker-exportable AI audit log (W2-B3). One row per AI-altered or
// AI-generated asset the workspace has produced: what was changed, by which
// model, against which unaltered original, and the exact disclosure sentence the
// public tour prints.
//
// WHY IT EXISTS. California AB 723 (in force 1 Jan 2026) makes both the
// disclosure AND access to the original unaltered image the licensee's legal
// obligation, at up to $2,500 per violation; NorthstarMLS (10 Jul 2026) wants an
// unaltered "Before" for every altered room; Wisconsin Act 69 extends the same
// to generated video from 1 Jan 2027. A compliance officer needs to be able to
// pull the whole workspace's record, not click through listings — so this route
// is member-gated (any role, including marketing: reading the audit log is not a
// write) and offers `format=csv` for the file they actually email.
//
// Member-scoped by RLS: the user client only ever sees the caller's orgs, and
// this route narrows to the acting workspace (X-Org-Id / default).
//
//   ?from=  ISO date/timestamp, inclusive   ?to= ISO date/timestamp, exclusive
//   ?listing_id=  one listing only (this is what the iOS COMPLIANCE card reads)
//   ?limit=  default 500, max 5000
//   ?format=csv  → text/csv attachment instead of JSON

const COMPLIANCE_DEFAULT_LIMIT = 500;
const COMPLIANCE_MAX_LIMIT = 5000;

const CSV_COLUMNS = [
  "created_at", "listing_id", "listing_address", "kind", "label", "edit", "style",
  "model_id", "disclosure", "original_url", "altered_url", "prompt_summary", "id",
] as const;

/** RFC4180-ish cell: quote everything, double interior quotes, never a raw newline. */
function csvCell(v: unknown): string {
  const s = v == null ? "" : String(v).replace(/\r?\n/g, " ");
  return `"${s.replace(/"/g, '""')}"`;
}

/** An ISO date/timestamp query param, or null. Rejects junk rather than ignoring it. */
function isoParam(raw: string | null, name: string): string | null {
  if (!raw) return null;
  const t = Date.parse(raw);
  assert(Number.isFinite(t), 400, `${name} must be an ISO date or timestamp (e.g. 2026-01-01)`);
  return new Date(t).toISOString();
}

async function handleCompliance(req: Request, userId: string): Promise<Response> {
  const db = userClient(req);
  const orgId = await orgForUser(userId, preferredOrg(req));
  const params = new URL(req.url).searchParams;

  const from = isoParam(params.get("from"), "from");
  const to = isoParam(params.get("to"), "to");
  const listingId = (params.get("listing_id") ?? "").trim();
  if (listingId) {
    assert(UUID_RE.test(listingId), 400, "listing_id must be a UUID");
  }
  const rawLimit = Number(params.get("limit") ?? COMPLIANCE_DEFAULT_LIMIT);
  const limit = Number.isFinite(rawLimit)
    ? Math.min(COMPLIANCE_MAX_LIMIT, Math.max(1, Math.round(rawLimit)))
    : COMPLIANCE_DEFAULT_LIMIT;
  const wantCsv = (params.get("format") ?? "").toLowerCase() === "csv";

  let q = db
    .from("media_provenance")
    .select(
      "id, listing_id, render_id, kind, label, model_id, edit, style, prompt_summary, " +
        "original_key, altered_key, disclosure, created_at, listings(address, space_type)",
    )
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
    .limit(limit + 1); // one extra so we can report `truncated` honestly
  if (from) q = q.gte("created_at", from);
  if (to) q = q.lt("created_at", to);
  if (listingId) q = q.eq("listing_id", listingId);

  const { data, error } = await q;
  if (error) throw new HttpError(500, `Compliance lookup failed: ${error.message}`);

  const all = (data ?? []) as unknown as Array<Record<string, unknown>>;
  const truncated = all.length > limit;
  const rows = all.slice(0, limit).map((r) => {
    const l = (Array.isArray(r.listings) ? r.listings[0] : r.listings) as
      | { address: string | null; space_type: string | null }
      | null
      | undefined;
    return {
      id: r.id as string,
      created_at: r.created_at as string,
      listing_id: (r.listing_id as string | null) ?? null,
      listing_address: l?.address ?? null,
      space_type: l?.space_type ?? null,
      render_id: (r.render_id as string | null) ?? null,
      kind: r.kind as string,
      label: (r.label as string | null) ?? null,
      edit: (r.edit as string | null) ?? null,
      style: (r.style as string | null) ?? null,
      model_id: (r.model_id as string | null) ?? null,
      // The org's OWN audit export may see the prompt summary; the public tour
      // never does (tours/index.ts returns the disclosure + URLs only).
      prompt_summary: (r.prompt_summary as string | null) ?? null,
      disclosure: r.disclosure as string,
      original_url: publicR2Url(r.original_key as string | null),
      altered_url: publicR2Url(r.altered_key as string | null),
      /** true when the unaltered original is publicly reachable (AB 723). */
      original_available: publicR2Url(r.original_key as string | null) !== null,
    };
  });

  if (wantCsv) {
    const lines = [CSV_COLUMNS.map(csvCell).join(",")];
    for (const r of rows) {
      lines.push(CSV_COLUMNS.map((c) => csvCell((r as Record<string, unknown>)[c])).join(","));
    }
    const stamp = new Date().toISOString().slice(0, 10);
    return new Response(lines.join("\r\n") + "\r\n", {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "text/csv; charset=utf-8",
        "Content-Disposition": `attachment; filename="rendprop-ai-disclosure-${stamp}.csv"`,
      },
    });
  }

  return json({
    org_id: orgId,
    from,
    to,
    listing_id: listingId || null,
    count: rows.length,
    truncated,
    rows,
  });
}

// ── PATCH /me/compliance/:id ──────────────────────────────────────────────────
//
// The generation call records the provenance row, but the media it points at is
// uploaded around it: the untouched ORIGINAL may go up before or after the edit,
// and the published RESULT always after. This attaches either (or both) once
// their uploads complete — the RPC derives the R2 keys from the asset ids and
// refuses an asset that is not an uploaded photo in the public renders bucket
// for the SAME listing, so "View original" can never be pointed at somebody
// else's object.

async function handleCompliancePatch(req: Request, userId: string, id: string | undefined): Promise<Response> {
  assert(id && UUID_RE.test(id), 400, "PATCH /me/compliance/:id requires the provenance record's UUID");
  const db = userClient(req);
  const body = await readJson<Record<string, unknown>>(req);

  const originalAsset = optionalUuidField(body.original_asset_id, "original_asset_id");
  const alteredAsset = optionalUuidField(body.altered_asset_id, "altered_asset_id");
  const label = typeof body.label === "string" ? body.label.trim().slice(0, 80) : null;
  assert(
    originalAsset || alteredAsset || label,
    400,
    "Send at least one of original_asset_id, altered_asset_id, label",
  );

  const { data, error } = await db.rpc("set_provenance_media", {
    p_id: id,
    p_original_asset: originalAsset,
    p_altered_asset: alteredAsset,
    p_label: label,
  });
  if (error) throwRpc(error.message);

  const row = (data ?? {}) as Record<string, unknown>;
  return json({
    ok: true,
    provenance: {
      id: row.id as string,
      listing_id: (row.listing_id as string | null) ?? null,
      kind: row.kind as string,
      label: (row.label as string | null) ?? null,
      disclosure: row.disclosure as string,
      original_url: publicR2Url(row.original_key as string | null),
      altered_url: publicR2Url(row.altered_key as string | null),
      created_at: (row.created_at as string | null) ?? null,
    },
  });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** An optional UUID body field. Rejects a present-but-malformed value. */
function optionalUuidField(v: unknown, name: string): string | null {
  if (v === undefined || v === null || v === "") return null;
  assert(typeof v === "string" && UUID_RE.test(v), 400, `${name} must be a UUID`);
  return v as string;
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

// ── POST /me/entitlement ──────────────────────────────────────────────────────
//
// The app just verified a StoreKit 2 transaction on the device and is telling
// the server about it. The DEVICE'S WORD IS NOT THE INPUT — the JWS Apple signed
// is. `Transaction.jwsRepresentation` is a compact JWS whose x5c chain ends at
// the Apple Root CA - G3 bytes pinned in _shared/applejws.ts, so a jailbroken
// device or a replayed HTTP call cannot mint a plan: it would have to forge an
// Apple signature.
//
// This is the path that LINKS an App Store subscription to a workspace. Until it
// runs, Apple's own notifications for that subscription have nowhere to land —
// so once the link exists, every notification that arrived early is replayed,
// in order, before the response is written.
//
// The checks, and what each one is protecting:
//
//   bundle id        a perfectly-signed transaction for another app is a 400,
//                    not a plan.
//   product id       a product we do not sell is a 400. There is no "unknown
//                    product, assume pro" branch.
//   ownership type   FAMILY_SHARED is a 403. One subscription unlocks ONE
//                    workspace; the buyer's. (Family Sharing is off for these
//                    products in App Store Connect — this is the server saying
//                    the same thing, in case that ever changes by accident.)
//   account token    when the transaction carries an appAccountToken it must be
//                    THIS user's id, or 403. A signed transaction is not a
//                    secret — it is on the buyer's device and in whatever the
//                    app logs — and without this check whoever posts a copy
//                    FIRST gets the plan and the real customer gets the 409
//                    below. Soft on purpose: the shipped build sets no token,
//                    so an absent one is accepted. (S1 review; migration 0021
//                    adds the column that records it.)
//   environment      Sandbox and Production are both accepted (App Review and
//                    every TestFlight tester buys in Sandbox) but they may not
//                    mix: a transaction from the other environment than the one
//                    on file is a 409, the same rule /apple-subscriptions has
//                    always applied to notifications.
//   expiresDate      a purchase with no expiry is not a subscription: 400.
//   role             only the workspace owner or an admin may attach a
//                    subscription, so an `agent` seat in someone else's org
//                    cannot redirect their own purchase into it.
//   409 conflict     an originalTransactionId already bound to a DIFFERENT org
//                    is refused rather than silently re-pointed. One person, one
//                    subscription, one workspace — and the app shows the copy
//                    verbatim so the user knows to sign in with the other account.
//                    The check below is the friendly one; migration 0021 raises
//                    RP409 inside the RPC's row lock, because a read-then-write
//                    check is a race two concurrent claims both win (S1 review:
//                    before 0021 the loser's org kept its plan AND the winner
//                    got one, so a single purchase entitled two workspaces).
//                    0021's guard reads `found`, from a SELECT … FOR UPDATE run
//                    BEFORE the insert — which cannot see a row that doesn't
//                    exist yet, so it covers a SECOND claim against an already-
//                    linked subscription but not two claims racing to make the
//                    FIRST link (exactly the unbound-JWS scenario this route
//                    exists for). Migration 0024 closes that: the upsert keeps
//                    whichever org's write actually persisted first instead of
//                    letting a losing INSERT's own values win the ON CONFLICT,
//                    and a post-write re-check raises the same RP409 for the
//                    loser — reproduced end-to-end on a scratch Postgres before
//                    and after (see 0024's header for the exact repro).
//
// The plan write itself goes through apply_apple_entitlement() (migration 0019),
// a SECURITY DEFINER RPC only the service role may call, which is also what
// refuses to move an owner-granted (`plan_source = 'manual'`) plan.

const ENTITLEMENT_MAX_PER_WINDOW = 30;
const ENTITLEMENT_WINDOW_SECONDS = 60;
const MAX_JWS_CHARS = 64 * 1024;
/** Hard ceiling on the bytes read off the wire, before any JSON parsing. */
const MAX_ENTITLEMENT_BODY_BYTES = 256 * 1024;
/** How many early notifications one link may replay. Far above any real backlog. */
const MAX_REPLAY = 50;

const ENTITLEMENT_ROLES = new Set(["owner", "admin"]);

async function handleEntitlement(req: Request, userId: string): Promise<Response> {
  if (
    !(await durableRateLimit(
      `entitlement:${userId}`,
      ENTITLEMENT_MAX_PER_WINDOW,
      ENTITLEMENT_WINDOW_SECONDS,
    ))
  ) {
    throw new HttpError(429, "Too many subscription checks — try again in a moment.", "rate_limited");
  }

  // Capped before it is buffered: two JWS blobs are at most ~128 KB of JSON and
  // req.json() would read whatever the caller sent into memory first.
  const body = await readJsonLimited<
    { signed_transaction?: unknown; signed_renewal_info?: unknown }
  >(req, MAX_ENTITLEMENT_BODY_BYTES);
  const signedTransaction = body.signed_transaction;
  assert(
    typeof signedTransaction === "string" && signedTransaction.length > 0 &&
      signedTransaction.length <= MAX_JWS_CHARS,
    400,
    "signed_transaction is required (Transaction.jwsRepresentation)",
  );

  // 401 unless Apple really signed this.
  const tx = decodeTransaction(await verifyAppleJWS(signedTransaction as string));

  assert(tx.bundleId === APPLE_BUNDLE_ID, 400, "That purchase belongs to a different app");

  const plan = productToPlan(tx.productId);
  if (!plan) {
    throw new HttpError(400, "That product isn't a Rendprop subscription", "validation", {
      product_id: tx.productId,
    });
  }

  if (tx.inAppOwnershipType !== null && tx.inAppOwnershipType !== "PURCHASED") {
    throw new HttpError(
      403,
      "This subscription is shared through Family Sharing — the person who bought it has the plan.",
      "forbidden",
    );
  }

  assert(tx.expiresDate !== null, 400, "That purchase isn't a subscription");

  // ── appAccountToken: the only thing that makes a JWS non-transferable ──────
  //
  // A signed transaction is not a secret. It lives on the buyer's device, it is
  // in whatever the app logs, and anything that can read one HTTPS body can
  // replay it. Nothing above this line distinguishes the buyer from someone
  // holding a copy: the 409 further down only refuses a transaction that is
  // ALREADY bound, so whoever posts it FIRST gets the plan — and the real
  // customer then gets the 409.
  //
  // StoreKit's answer is `Product.PurchaseOption.appAccountToken(uuid)`: a UUID
  // the app stamps on the purchase, which Apple then signs into every
  // transaction and every notification for that subscription forever. Set it to
  // the signed-in user's own id and a stolen JWS is worthless to anyone else.
  //
  // SOFT, deliberately: the shipped build calls `product.purchase()` with no
  // options, so a real customer's transaction carries no token at all and must
  // still work. A token that is PRESENT and names someone else is refused —
  // that is the replay — while an absent one is accepted and the review report
  // carries the exact iOS change that makes it present. Once a build that sets
  // it has fully rolled out, this can be tightened to require the token.
  if (tx.appAccountToken !== null && tx.appAccountToken.toLowerCase() !== userId.toLowerCase()) {
    throw new HttpError(
      403,
      "That purchase belongs to a different Rendprop account. Sign in with the account that bought it, or use Restore Purchases there.",
      "forbidden",
    );
  }

  // Renewal info is optional and only trusted for THIS subscription.
  let renewal: AppleRenewalInfo | null = null;
  const signedRenewal = body.signed_renewal_info;
  if (typeof signedRenewal === "string" && signedRenewal.length > 0) {
    assert(signedRenewal.length <= MAX_JWS_CHARS, 400, "signed_renewal_info is too large");
    const candidate = decodeRenewalInfo(await verifyAppleJWS(signedRenewal));
    if (
      candidate.originalTransactionId === null ||
      candidate.originalTransactionId === tx.originalTransactionId
    ) {
      renewal = candidate;
    }
  }

  const admin = adminClient();
  const orgId = await orgForUser(userId, preferredOrg(req));

  const { data: membership, error: mErr } = await admin
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Membership lookup failed: ${mErr.message}`);
  if (!membership || !ENTITLEMENT_ROLES.has(String(membership.role))) {
    throw new HttpError(
      403,
      "Only the workspace owner or an admin can add a subscription",
      "forbidden",
    );
  }

  // One subscription, one workspace. This is the friendly pre-check; the RPC
  // enforces the same rule inside its row lock (migration 0021), so two
  // requests racing to claim the same transaction cannot both win.
  const { data: existing, error: exErr } = await admin
    .from("apple_subscriptions")
    .select("org_id, environment")
    .eq("original_transaction_id", tx.originalTransactionId)
    .maybeSingle();
  if (exErr) throw new HttpError(503, "Subscription lookup failed — try again.", "upstream");
  const boundTo = (existing?.org_id as string | null) ?? null;
  if (boundTo && boundTo !== orgId) {
    throw new HttpError(409, "This subscription is already used by another account", "conflict");
  }

  // Sandbox and Production are both accepted — App Review and every TestFlight
  // tester buys in Sandbox, so refusing it would fail review — but they may
  // never mix. /apple-subscriptions has always refused a notification whose
  // environment disagrees with the stored row; this is the same rule on the
  // device path, which did not have it. (0021 enforces it in the RPC too, for
  // both callers at once; this is the version that produces a sentence.)
  const storedEnvironment = (existing?.environment as string | null) ?? null;
  if (storedEnvironment !== null && storedEnvironment !== tx.environment) {
    throw new HttpError(
      409,
      "That purchase is from a different App Store environment than this subscription.",
      "conflict",
    );
  }

  const derived = deriveEntitlement(tx, renewal);

  const { error: rpcErr } = await admin.rpc("apply_apple_entitlement", {
    p_org: orgId,
    p_user: userId,
    p_original_transaction_id: tx.originalTransactionId,
    p_transaction_id: tx.transactionId,
    p_product_id: tx.productId,
    p_plan: plan,
    p_environment: tx.environment,
    p_status: derived.status,
    p_expires_at: derived.expiresAt,
    p_auto_renew: derived.autoRenew,
    p_notification_type: null,
  });
  if (rpcErr) {
    // RPnnn is the RPC refusing the input (a bug on our side — the only one it
    // raises here is RP400). Anything else is Postgres being unreachable, which
    // is a 503 "try again", not a 400 that tells the customer their purchase
    // was invalid.
    if (/RP\d{3}:/.test(rpcErr.message)) throwRpc(rpcErr.message);
    console.error("apply_apple_entitlement failed:", rpcErr.message);
    throw new HttpError(503, "Could not record the subscription — try again.", "upstream");
  }

  // Record the token when the build sent one, so support and the console can
  // see which account a subscription is bound to. Best effort and non-plan:
  // apply_apple_entitlement() stays the only writer of anything that decides a
  // plan (migration 0019 RULE 1), and this column decides nothing — the check
  // that matters already ran above, against the VERIFIED transaction.
  if (tx.appAccountToken !== null) {
    const { error: tokErr } = await admin
      .from("apple_subscriptions")
      .update({ app_account_token: tx.appAccountToken })
      .eq("original_transaction_id", tx.originalTransactionId);
    if (tokErr) console.error("app_account_token write failed:", tokErr.message);
  }

  const replayed = await replayPendingNotifications(tx.originalTransactionId, orgId);

  // Answer with what the server now ENFORCES, read back after every write —
  // effective_plan() is the same function the charge paths call, so the app can
  // never be told it has a plan the next AI request will refuse.
  const [{ data: effective }, { data: org }] = await Promise.all([
    admin.rpc("effective_plan", { p_org: orgId }),
    admin.from("orgs").select("plan, plan_source, plan_expires_at").eq("id", orgId).maybeSingle(),
  ]);

  return json({
    plan: String(effective ?? org?.plan ?? "free"),
    source: (org?.plan_source as string | null) ?? "apple",
    expires_at: derived.expiresAt,
    product_id: tx.productId,
    original_transaction_id: tx.originalTransactionId,
    environment: tx.environment,
    // Additive extras the app may ignore.
    status: derived.status,
    auto_renew: derived.autoRenew,
    replayed_notifications: replayed,
  });
}

/**
 * Apply the notifications that arrived before this workspace was linked.
 *
 * apple-subscriptions/index.ts stores the exact RPC arguments it computed on
 * each `pending` row (`payload.entitlement`), so a replay re-applies the SAME
 * decision rather than re-deriving it here from a second copy of the rules. In
 * receipt order, because apply_apple_entitlement() resolves out-of-order
 * signals by comparing expiries.
 *
 * Best effort: a failure here must not turn a successful purchase into an error
 * the customer sees. The rows stay `pending` and the next sync retries them.
 */
async function replayPendingNotifications(
  originalTransactionId: string,
  orgId: string,
): Promise<number> {
  const admin = adminClient();
  const { data, error } = await admin
    .from("apple_notifications")
    .select("notification_uuid, payload")
    .eq("original_transaction_id", originalTransactionId)
    .eq("pending", true)
    .order("received_at", { ascending: true })
    .limit(MAX_REPLAY);
  if (error || !data || data.length === 0) return 0;

  let applied = 0;
  for (const row of data) {
    const e = (row.payload as { entitlement?: Record<string, unknown> } | null)?.entitlement;
    const uuid = row.notification_uuid as string;
    if (!e || typeof e.status !== "string" || typeof e.original_transaction_id !== "string") {
      // Nothing replayable on this row — clear the flag so it is not retried forever.
      await admin.from("apple_notifications")
        .update({ pending: false, org_id: orgId }).eq("notification_uuid", uuid);
      continue;
    }
    const { error: rpcErr } = await admin.rpc("apply_apple_entitlement", {
      p_org: orgId,
      p_user: null,
      p_original_transaction_id: e.original_transaction_id,
      p_transaction_id: (e.transaction_id as string | null) ?? null,
      p_product_id: (e.product_id as string | null) ?? null,
      p_plan: (e.plan as string | null) ?? null,
      p_environment: (e.environment as string | null) ?? null,
      p_status: e.status,
      p_expires_at: (e.expires_at as string | null) ?? null,
      p_auto_renew: typeof e.auto_renew === "boolean" ? e.auto_renew : null,
      p_notification_type: (e.notification_type as string | null) ?? null,
    });
    if (rpcErr) {
      console.error("pending notification replay failed:", rpcErr.message);
      continue; // stays pending; the next sync retries it
    }
    await admin.from("apple_notifications")
      .update({ pending: false, org_id: orgId }).eq("notification_uuid", uuid);
    applied++;
  }
  return applied;
}

// ── DELETE /me ────────────────────────────────────────────────────────────────

const INLINE_R2_CAP = 5000;
const INLINE_STREAM_CAP = 50;
const INLINE_CRM_CAP = 50;

// DeletionPayload and decideGhlTagAction live in
// ./logic.ts (imported above) so they can be unit-tested without pulling in
// Deno.serve — see logic.ts's own header for what each one is responsible for.

/**
 * Reach every GHL contact matching an exact email, and do to EACH ONE only
 * what its tags say belongs to THIS org.
 *
 * GHL_LOCATION_ID is one shared CRM location for every tenant (leads/index.ts)
 * — a contact is never in "this tenant's location", only ever "this tenant's
 * TAG" (`rendprop_org:<org_id>`, _shared/ghl.ts). Deleting by email alone, as
 * this used to, means two tenants whose leads share an email (a property
 * manager, a common vendor, a family member on two listings) have ONE shared
 * contact — and deleting account A's copy deletes tenant B's contact outright
 * (external release audit). decideGhlTagAction() is the entire policy:
 *
 *   only this tenant's org tag         -> delete the contact
 *   this tenant's tag + another's too  -> strip only this tenant's tag
 *   this tenant's tag missing/unreadable -> touch NOTHING; stays queued
 *
 * The search endpoint is not guaranteed to return tags on its summary rows, so
 * each match is re-fetched by id before any decision is made — a contact this
 * tenant cannot positively confirm ownership of is never guessed at.
 *
 * Throws only on a transport/API failure (search, tag GET, delete or untag),
 * which the caller treats as "retry this email later". `leftover` counts
 * contacts that were reached but deliberately left untouched — those are
 * requeued too (same as a retryable failure): retrying costs nothing, and if
 * the contact is ever re-tagged for this tenant a later pass will finish it,
 * while nothing here ever deletes on a guess.
 */
async function cleanupGhlContactForTenant(
  email: string,
  orgId: string,
): Promise<{ removed: number; untagged: number; leftover: number }> {
  const key = Deno.env.get("GHL_API_KEY");
  const locationId = Deno.env.get("GHL_LOCATION_ID");
  if (!key || !locationId) throw new Error("GHL not configured");
  const headers = {
    Authorization: `Bearer ${key}`,
    Version: "2021-07-28",
    Accept: "application/json",
  };
  const searchUrl = new URL("https://services.leadconnectorhq.com/contacts/");
  searchUrl.searchParams.set("locationId", locationId);
  searchUrl.searchParams.set("query", email);
  const res = await fetch(searchUrl, { headers });
  if (!res.ok) throw new Error(`GHL search ${res.status}`);
  const data = await res.json().catch(() => ({}));
  const contacts = (data?.contacts ?? []) as Array<{ id?: string; email?: string }>;

  let removed = 0;
  let untagged = 0;
  let leftover = 0;

  for (const c of contacts) {
    if (!c.id || (c.email ?? "").toLowerCase() !== email.toLowerCase()) continue;

    // Re-fetch the full record: the search result is not a contract that it
    // carries tags, and a tag we cannot positively read is not a tag we act on.
    const getRes = await fetch(`https://services.leadconnectorhq.com/contacts/${c.id}`, { headers });
    if (!getRes.ok) throw new Error(`GHL contact fetch ${c.id} -> ${getRes.status}`);
    const full = await getRes.json().catch(() => null) as { contact?: { tags?: unknown } } | null;
    const decision = decideGhlTagAction(full?.contact?.tags, orgId);

    if (decision.action === "leftover") {
      leftover++;
      continue;
    }
    if (decision.action === "untag") {
      const untagRes = await fetch(`https://services.leadconnectorhq.com/contacts/${c.id}/tags`, {
        method: "DELETE",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ tags: [decision.tag] }),
      });
      if (!untagRes.ok) throw new Error(`GHL untag ${c.id} -> ${untagRes.status}`);
      untagged++;
      continue;
    }
    // decision.action === "delete": only this tenant's org tag is present.
    const del = await fetch(`https://services.leadconnectorhq.com/contacts/${c.id}`, {
      method: "DELETE",
      headers,
    });
    if (del.ok || del.status === 404) removed++;
    else throw new Error(`GHL delete ${c.id} -> ${del.status}`);
  }
  return { removed, untagged, leftover };
}

/** Attempt the external cleanup in a payload. Returns what REMAINS + notes. */
async function processPayload(payload: DeletionPayload): Promise<{ remaining: DeletionPayload; notes: string[] }> {
  const notes: string[] = [];
  const remaining: DeletionPayload = {
    r2: [],
    stream_uids: [],
    ghl_targets: [],
    apple_refresh_token: payload.apple_refresh_token ?? null,
    analytics_user_id: payload.analytics_user_id ?? null,
    profile_id: payload.profile_id ?? null,
    auth_user_id: payload.auth_user_id ?? null,
    provider_leases: [],
    multipart_uploads: [],
    unresolved_uploads: [...(payload.unresolved_uploads ?? [])],
    unresolved_render_jobs: [...(payload.unresolved_render_jobs ?? [])],
    storage_not_before: payload.storage_not_before ?? null,
  };

  // Only the durable journal can prove a provider is finished with room files.
  // It is intentionally independent of spatial_jobs, whose sidecars and
  // manifests were already purged in the deletion transaction.
  for (const [i, target] of (payload.provider_leases ?? []).entries()) {
    if (i>=16) { remaining.provider_leases!.push(target); continue; }
    try {
      const {data,error}=await adminClient().rpc("account_deletion_provider_ready",
        {p_job:target.job_id,p_lease:target.lease_token});
      if(error || data!==true) remaining.provider_leases!.push(target);
    } catch { remaining.provider_leases!.push(target); }
  }
  if(remaining.provider_leases!.length) notes.push("spatial: provider file removal and shutdown remain queued");
  if(remaining.unresolved_uploads!.length) notes.push("uploads: ambiguous multipart allocation needs reconciliation; queued");
  if(remaining.unresolved_render_jobs!.length) notes.push("renders: legacy worker output cleanup needs reconciliation; queued");
  const storageDrained=!payload.storage_not_before || Date.parse(payload.storage_not_before)<=Date.now();
  if(storageDrained) remaining.storage_not_before=null;
  else notes.push("storage: waiting for previously issued writes to expire; queued");
  for(const [i,target] of (payload.multipart_uploads??[]).entries()) {
    if(!storageDrained || i>=16) {remaining.multipart_uploads!.push(target);continue;}
    try { await abortMultipartUpload({bucket:target.bucket,key:target.key,uploadId:target.upload_id}); }
    catch { remaining.multipart_uploads!.push(target);notes.push("multipart: abort failed; queued"); }
  }

  // R2 (bounded per pass; leftovers stay queued).
  if (!storageDrained) remaining.r2.push(...payload.r2);
  else if (payload.r2.length) {
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

  // CRM (GoHighLevel) — the org's captured lead contacts, tag-scoped so a
  // shared CRM location never loses another tenant's contact to this deletion
  // (see cleanupGhlContactForTenant's own header for the full policy).
  const crmTodo = payload.ghl_targets ?? [];
  if (crmTodo.length) {
    const ghlConfigured = Boolean(Deno.env.get("GHL_API_KEY") && Deno.env.get("GHL_LOCATION_ID"));
    if (!ghlConfigured) {
      notes.push("crm: GHL not configured — queued");
      remaining.ghl_targets.push(...crmTodo);
    } else {
      for (let i = 0; i < crmTodo.length; i++) {
        if (i >= INLINE_CRM_CAP) { remaining.ghl_targets.push(crmTodo[i]); continue; }
        const target = crmTodo[i];
        try {
          const outcome = await cleanupGhlContactForTenant(target.email, target.org_id);
          if (outcome.leftover > 0) {
            // Never guessed at — this tenant's own tag could not be confirmed
            // on the match, so nothing was touched. Stays queued (same as a
            // retryable failure) rather than being dropped or force-deleted.
            notes.push(`crm ${target.email}: ${outcome.leftover} contact(s) left for manual review — tenant tag unconfirmed`);
            remaining.ghl_targets.push(target);
          }
        } catch (e) {
          notes.push(`crm ${target.email}: ${e instanceof Error ? e.message : String(e)}`);
          remaining.ghl_targets.push(target);
        }
      }
    }
  }

  // Analytics — forget this person in app_events (0020 keeps no FK on user_id
  // / org_id on purpose, so this is a plain UPDATE that cannot fail on a
  // missing referenced row, before OR after the auth user is gone).
  if (payload.analytics_user_id) {
    try {
      const { error } = await adminClient()
        .from("app_events")
        .update({ user_id: null, org_id: null })
        .eq("user_id", payload.analytics_user_id);
      if (error) notes.push(`analytics: ${error.message}`);
      else remaining.analytics_user_id = null;
    } catch (e) {
      notes.push(`analytics: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  // Profile row. `profiles.id references auth.users(id) on delete cascade`
  // (0001), so once the auth user is gone this is a harmless no-op retry —
  // never a reason to leave the tombstone pending forever.
  if (payload.profile_id) {
    try {
      const { error } = await adminClient().from("profiles").delete().eq("id", payload.profile_id);
      if (error) notes.push(`profile: ${error.message}`);
      else remaining.profile_id = null;
    } catch (e) {
      notes.push(`profile: ${e instanceof Error ? e.message : String(e)}`);
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

  // Auth deletion is last and remains in the SAME durable payload on failure.
  // 404 means this exact identity is already gone; other errors must retry.
  if (payload.auth_user_id) {
    try {
      const { error } = await adminClient().auth.admin.deleteUser(payload.auth_user_id);
      if (error && error.status !== 404) notes.push("auth: sign-in deletion failed; queued");
      else remaining.auth_user_id = null;
    } catch {
      notes.push("auth: sign-in deletion unavailable; queued");
    }
  }

  return { remaining, notes };
}

async function handleDelete(userId: string, _userEmail: string | null): Promise<Response> {
  return await deleteAccount(adminClient(), userId, processPayload);
}

async function sweepDeletions(): Promise<Response> {
  return await sweepAccounts(adminClient(), processPayload);
}
