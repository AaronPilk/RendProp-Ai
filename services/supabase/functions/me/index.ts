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
//   PATCH  /me/brand            -> { ok, brand_kit, org: { name, handle }, portfolio_url }
//                                  brand-kit fields + `handle` (public portfolio slug,
//                                  unique → 409) + `org_name` (business name; never an email)
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
import {
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

  // ── Phase 6b: forget this person in the analytics table.
  //
  // `app_events` has no foreign key on user_id or org_id — deliberately, so a
  // deletion can never fail on it or silently rewrite historical counts
  // (migration 0020 §1). But that also means nothing was clearing them: 0020's
  // own comment says "the purge and DELETE /me are what remove the rows" and
  // DELETE /me did not touch the table, so a deleted account's id sat in it for
  // the rest of the 180-day retention window (S1 review). Nulling the two
  // identifiers keeps every funnel number exactly as it was — a row is still a
  // row and device_id is still device_id — and leaves nothing in the table
  // pointing at a person who asked to be forgotten. `device_id` stays because
  // once user_id and org_id are gone it is a random install UUID with nothing
  // left to join it to, and dropping it would silently rewrite every distinct-
  // device count 0020 went out of its way to protect.
  await step("forget analytics identifiers", () =>
    admin.from("app_events").update({ user_id: null, org_id: null }).eq("user_id", userId));

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
