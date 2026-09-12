// leads — PUBLIC lead capture from the tour end-card + the agent's inbox (owner).
//
//   POST  /leads                        PUBLIC { slug, name, phone, email?, extra?, _hp? } -> { ok, id }
//   GET   /leads?listing_id=&since=&limit=   OWNER -> { leads: [ … ] }   (member-scoped via RLS)
//   PATCH /leads/:id  { status }        OWNER -> { ok, lead }             (new|contacted|won|lost)
//
// POST resolves render(slug) -> listing -> org, inserts a `leads` row (service
// role; there is no public RLS insert policy by design), then optionally
// upserts the contact to GoHighLevel when GHL_API_KEY + GHL_LOCATION_ID are set.
//
// GET/PATCH are what make lead capture a real feature for every tenant (audit
// F-supabase-02, decision A13): the app lists leads per listing and marks them
// worked. Both require a user JWT (this function is deployed --no-verify-jwt
// for the public POST, so getUser() validates the token itself).
//
// PUSH/E-MAIL ALERTS EXIST NOW (migration 0047): the insert below fires an
// AFTER INSERT trigger that queues a `lead_received` message for every
// owner/admin, and functions/notify delivers it. Nothing in this file changes
// shape for it and nothing here can be slowed down or failed by a provider.
//
// Bot protection on the public POST (audit — "Turnstile fails open when
// unconfigured"): Cloudflare Turnstile now FAILS CLOSED when
// TURNSTILE_SECRET_KEY is not set, instead of silently accepting every
// submission. See turnstile.ts, README.md and services/supabase/DEPLOYMENT.md
// for the opt-out (TURNSTILE_OPTIONAL=1) and where it's documented.
//
// Errors carry { error, code } (see _shared/http.ts).

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, clientIp, json, pathSegments, readJson, respondError, throwRpc } from "../_shared/http.ts";
import { ghlOrgTag } from "../_shared/ghl.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { adminClient, getUser, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { verifyTurnstile } from "./turnstile.ts";

interface LeadBody {
  slug: string;
  name?: string;
  phone?: string;
  email?: string;
  extra?: Record<string, unknown>;
  _hp?: string; // honeypot — real users never fill this
  turnstile_token?: string; // Cloudflare Turnstile token (bot protection)
}

const LEAD_STATUSES = ["new", "contacted", "won", "lost"];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_LIST = 500;

/** Upsert the lead to GoHighLevel. Returns true on success; never throws. */
async function pushToGHL(
  lead: { name?: string; email?: string; phone?: string },
  attribution: { org_id: string | null; listing_id: string | null; slug: string; address?: string | null },
): Promise<boolean> {
  const key = Deno.env.get("GHL_API_KEY");
  const locationId = Deno.env.get("GHL_LOCATION_ID");
  if (!key || !locationId) return false;
  try {
    const [firstName, ...rest] = (lead.name ?? "").trim().split(/\s+/);
    // Tag the contact with the tenant/listing so a shared CRM location can be
    // attributed (and deletion can target only this org's contacts —
    // F-supabase-23 / external release audit P0). The org tag is built by
    // ghlOrgTag() — functions/me/index.ts reads contacts back through the same
    // helper, so a deletion can never drift from what this write actually set.
    const tags = ["rendprop", "tour", `rendprop_slug:${attribution.slug}`];
    if (attribution.org_id) tags.push(ghlOrgTag(attribution.org_id));
    if (attribution.listing_id) tags.push(`rendprop_listing:${attribution.listing_id}`);
    const resp = await fetch("https://services.leadconnectorhq.com/contacts/upsert", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        Version: "2021-07-28",
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        locationId,
        name: lead.name || undefined,
        firstName: firstName || undefined,
        lastName: rest.join(" ") || undefined,
        email: lead.email || undefined,
        phone: lead.phone || undefined,
        source: attribution.address ? `Rendprop Tour — ${attribution.address}`.slice(0, 120) : "Rendprop Tour",
        tags,
      }),
    });
    if (!resp.ok) {
      console.error("GHL upsert failed:", resp.status, await resp.text());
      return false;
    }
    return true;
  } catch (e) {
    console.error("GHL upsert error:", e);
    return false;
  }
}

/** The lead shape the app decodes (contract B4). `message` is lifted out of extra. */
function shapeLead(row: Record<string, unknown>): Record<string, unknown> {
  const extra = (row.extra && typeof row.extra === "object" ? row.extra : {}) as Record<string, unknown>;
  const msg = extra.message ?? extra.notes ?? extra.comment ?? null;
  const listing = (Array.isArray(row.listings) ? row.listings[0] : row.listings) as
    | { address?: string | null; space_type?: string | null }
    | null
    | undefined;
  return {
    id: row.id,
    listing_id: row.listing_id ?? null,
    render_id: row.render_id ?? null,
    name: row.name ?? null,
    phone: row.phone ?? null,
    email: row.email ?? null,
    message: typeof msg === "string" ? msg.slice(0, 2000) : null,
    extra,
    source: row.source ?? "tour",
    status: row.status ?? "new",
    synced_crm: row.synced_crm ?? false,
    created_at: row.created_at,
    listing_address: listing?.address ?? null,
    listing_space_type: listing?.space_type ?? null,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const seg = pathSegments(req, "leads");

    // ---- GET /leads (owner) ----
    if (req.method === "GET") {
      const user = await getUser(req);
      const db = userClient(req); // RLS: "org leads" select policy (member)
      const orgId = await orgForUser(user.id, preferredOrg(req));
      const params = new URL(req.url).searchParams;

      const listingId = params.get("listing_id");
      if (listingId) assert(UUID_RE.test(listingId), 400, "listing_id must be a UUID");
      const since = params.get("since");
      let sinceIso: string | null = null;
      if (since) {
        const t = Date.parse(since);
        assert(Number.isFinite(t), 400, "since must be an ISO-8601 timestamp");
        sinceIso = new Date(t).toISOString();
      }
      const limitRaw = Number(params.get("limit") ?? 200);
      const limit = Number.isFinite(limitRaw) ? Math.min(MAX_LIST, Math.max(1, Math.round(limitRaw))) : 200;
      const status = params.get("status");
      if (status) assert(LEAD_STATUSES.includes(status), 400, `status must be one of ${LEAD_STATUSES.join(", ")}`);

      let q = db
        .from("leads")
        .select("id, listing_id, render_id, name, phone, email, extra, source, status, synced_crm, created_at, listings(address, space_type)")
        .eq("org_id", orgId)
        .order("created_at", { ascending: false })
        .limit(limit);
      if (listingId) q = q.eq("listing_id", listingId);
      if (sinceIso) q = q.gte("created_at", sinceIso);
      if (status) q = q.eq("status", status);

      const { data, error } = await q;
      if (error) throw new HttpError(400, `Leads lookup failed: ${error.message}`);
      return json({ leads: (data ?? []).map((r) => shapeLead(r as Record<string, unknown>)) });
    }

    // ---- PATCH /leads/:id (owner) ----
    if (req.method === "PATCH" && seg.length === 1) {
      await getUser(req);
      const db = userClient(req);
      const leadId = seg[0];
      assert(UUID_RE.test(leadId), 400, "lead id must be a UUID");
      const body = await readJson<{ status?: string }>(req);
      const status = String(body.status ?? "").trim().toLowerCase();
      assert(LEAD_STATUSES.includes(status), 400, `status must be one of ${LEAD_STATUSES.join(", ")}`);

      // Role-gated SECURITY DEFINER RPC (0011): tenants have no direct UPDATE on leads.
      const { data: updated, error } = await db.rpc("set_lead_status", { p_lead: leadId, p_status: status });
      if (error) throwRpc(error.message);

      // Read back in the same shape as GET (with the listing address).
      const { data: row } = await db
        .from("leads")
        .select("id, listing_id, render_id, name, phone, email, extra, source, status, synced_crm, created_at, listings(address, space_type)")
        .eq("id", leadId)
        .maybeSingle();
      return json({ ok: true, lead: shapeLead((row ?? updated ?? {}) as Record<string, unknown>) });
    }

    if (req.method !== "POST") throw new HttpError(405, "Only POST (public capture), GET and PATCH are supported");

    // ---- POST /leads (public) ----

    // Durable per-IP limit (Postgres-backed, shared across instances; falls
    // back to the in-memory limiter if the RPC is unavailable).
    if (!(await durableRateLimit(`leads:${clientIp(req)}`, 20, 60))) {
      throw new HttpError(429, "Too many requests, slow down", "rate_limited");
    }

    const body = await readJson<LeadBody>(req);

    // Honeypot: pretend success so bots don't learn anything.
    if (body._hp) return json({ ok: true });

    // Bot protection: Cloudflare Turnstile. FAILS CLOSED when
    // TURNSTILE_SECRET_KEY is unset — see turnstile.ts — unless
    // TURNSTILE_OPTIONAL=1 is set as a deliberate opt-out.
    if (!(await verifyTurnstile(body.turnstile_token, clientIp(req)))) {
      throw new HttpError(403, "Bot check failed — please retry the form.");
    }

    assert(body.slug, 400, "slug is required");

    // Validate + bound the public input (#14). Reject malformed contact info and
    // cap every field so a bot can't stuff the DB or the CRM with junk.
    const clip = (s: unknown, n: number) =>
      typeof s === "string" ? s.trim().slice(0, n) : undefined;
    body.name = clip(body.name, 120);
    body.email = clip(body.email, 200);
    body.phone = clip(body.phone, 40);
    if (body.email) {
      assert(/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(body.email), 400, "email is not valid");
    }
    if (body.phone) {
      assert(/^[+()\d\s.-]{7,40}$/.test(body.phone), 400, "phone is not valid");
    }
    // A lead the agent cannot contact is not a lead (audit F-supabase-33).
    assert(body.phone || body.email, 400, "A phone number or email is required so the agent can reach you");
    if (body.extra !== undefined) {
      assert(body.extra && typeof body.extra === "object" && !Array.isArray(body.extra), 400, "extra must be an object");
      const size = JSON.stringify(body.extra).length;
      assert(size <= 4000, 400, "extra is too large");
    }

    const admin = adminClient();

    // The public demo tour (rendprop.com/f/estate-demo) has no DB render row —
    // it's rendered from a hardcoded Tour. Still capture its leads (they route to
    // GHL like any other), tagged source "tour-demo", with null render/listing.
    const isDemo = body.slug === "estate-demo" || body.slug === "demo";

    let renderId: string | null = null;
    let listingId: string | null = null;
    let orgId: string | null = null;
    let address: string | null = null;

    if (!isDemo) {
      // Resolve the published render for this slug.
      const { data: render, error: rErr } = await admin
        .from("renders")
        .select("id, listing_id")
        .eq("slug", body.slug)
        .not("published_at", "is", null)
        .maybeSingle();
      if (rErr) throw new HttpError(500, `Render lookup failed: ${rErr.message}`);
      if (!render) throw new HttpError(404, "Tour not found");
      renderId = render.id as string;
      listingId = render.listing_id as string;

      // org via the listing; a deleted listing takes no leads.
      const { data: listing } = await admin
        .from("listings")
        .select("id, org_id, address, deleted_at")
        .eq("id", render.listing_id)
        .maybeSingle();
      if (!listing || listing.deleted_at) throw new HttpError(404, "Tour not found");
      orgId = (listing.org_id as string | null) ?? null;
      address = (listing.address as string | null) ?? null;

      // Dedupe a double-tap: same contact on the same tour within 10 minutes.
      const tenMinAgo = new Date(Date.now() - 10 * 60 * 1000).toISOString();
      let dq = admin.from("leads").select("id").eq("render_id", renderId).gte("created_at", tenMinAgo).limit(1);
      dq = body.email ? dq.eq("email", body.email) : dq.eq("phone", body.phone as string);
      const { data: dup } = await dq.maybeSingle();
      if (dup?.id) return json({ ok: true, id: dup.id, deduplicated: true });
    }

    const { data: lead, error: insErr } = await admin
      .from("leads")
      .insert({
        render_id: renderId,
        listing_id: listingId,
        org_id: orgId,
        name: body.name ?? null,
        phone: body.phone ?? null,
        email: body.email ?? null,
        extra: body.extra ?? {},
        source: isDemo ? "tour-demo" : "tour",
        synced_crm: false,
      })
      .select("id")
      .single();
    if (insErr) throw new HttpError(500, `Lead insert failed: ${insErr.message}`);

    // Optional CRM sync — never blocks/breaks lead capture.
    const synced = await pushToGHL(
      { name: body.name, email: body.email, phone: body.phone },
      { org_id: orgId, listing_id: listingId, slug: body.slug, address },
    );
    if (synced) {
      await admin.from("leads").update({ synced_crm: true }).eq("id", lead.id);
    }

    // The agent is TOLD. Migration 0047 puts an AFTER INSERT trigger on `leads`
    // that queues a `lead_received` message — carrying the buyer's name and the
    // listing — for every owner/admin of the org, inside the same transaction as
    // the insert above, so it cannot be missed and cannot be sent twice (the
    // outbox dedupe key is the lead's own id). functions/notify drains it.
    // Nothing here waits on a provider: the capture commits either way, and if
    // no APNs or e-mail secret is set the row is marked `skipped` with a reason.
    // (This replaces decision A13's "the Leads screen is the delivery channel
    // for now" — GET /leads is still where the details live, but silence until
    // the agent happens to open the app is no longer how they find out.)
    return json({ ok: true, id: lead.id }, 201);
  } catch (err) {
    return respondError(err);
  }
});
