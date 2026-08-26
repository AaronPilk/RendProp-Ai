// leads — PUBLIC lead capture from the tour end-card.
//
//   POST /leads  { slug, name, phone, email?, extra?, _hp? } -> { ok, id }
//
// Resolves render(slug) -> listing -> org, inserts a `leads` row (service role;
// there is no public RLS insert policy by design), then optionally upserts the
// contact to GoHighLevel when GHL_API_KEY + GHL_LOCATION_ID are set.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, clientIp, json, readJson, respondError } from "../_shared/http.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { adminClient } from "../_shared/supabase.ts";

interface LeadBody {
  slug: string;
  name?: string;
  phone?: string;
  email?: string;
  extra?: Record<string, unknown>;
  _hp?: string; // honeypot — real users never fill this
}

/** Upsert the lead to GoHighLevel. Returns true on success; never throws. */
async function pushToGHL(lead: { name?: string; email?: string; phone?: string }): Promise<boolean> {
  const key = Deno.env.get("GHL_API_KEY");
  const locationId = Deno.env.get("GHL_LOCATION_ID");
  if (!key || !locationId) return false;
  try {
    const [firstName, ...rest] = (lead.name ?? "").trim().split(/\s+/);
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
        source: "Rendprop Tour",
        tags: ["rendprop", "tour"],
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "POST") throw new HttpError(405, "Only POST is supported");

    // Durable per-IP limit (Postgres-backed, shared across instances; falls
    // back to the in-memory limiter if the RPC is unavailable).
    if (!(await durableRateLimit(`leads:${clientIp(req)}`, 20, 60))) {
      throw new HttpError(429, "Too many requests, slow down");
    }

    const body = await readJson<LeadBody>(req);

    // Honeypot: pretend success so bots don't learn anything.
    if (body._hp) return json({ ok: true });

    assert(body.slug, 400, "slug is required");
    assert(body.name || body.phone || body.email, 400, "name, phone, or email is required");

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
    if (body.extra !== undefined) {
      const size = JSON.stringify(body.extra).length;
      assert(size <= 4000, 400, "extra is too large");
    }

    const admin = adminClient();

    // Resolve the published render for this slug.
    const { data: render, error: rErr } = await admin
      .from("renders")
      .select("id, listing_id")
      .eq("slug", body.slug)
      .not("published_at", "is", null)
      .maybeSingle();
    if (rErr) throw new HttpError(500, `Render lookup failed: ${rErr.message}`);
    if (!render) throw new HttpError(404, "Tour not found");

    // org via the listing.
    const { data: listing } = await admin
      .from("listings")
      .select("id, org_id")
      .eq("id", render.listing_id)
      .maybeSingle();

    const { data: lead, error: insErr } = await admin
      .from("leads")
      .insert({
        render_id: render.id,
        listing_id: render.listing_id,
        org_id: listing?.org_id ?? null,
        name: body.name ?? null,
        phone: body.phone ?? null,
        email: body.email ?? null,
        extra: body.extra ?? {},
        source: "tour",
        synced_crm: false,
      })
      .select("id")
      .single();
    if (insErr) throw new HttpError(500, `Lead insert failed: ${insErr.message}`);

    // Optional CRM sync — never blocks/breaks lead capture.
    const synced = await pushToGHL({ name: body.name, email: body.email, phone: body.phone });
    if (synced) {
      await admin.from("leads").update({ synced_crm: true }).eq("id", lead.id);
    }

    // TODO: notify the agent (email/push) — architecture step 7.
    return json({ ok: true, id: lead.id }, 201);
  } catch (err) {
    return respondError(err);
  }
});
