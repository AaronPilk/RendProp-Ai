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
  turnstile_token?: string; // Cloudflare Turnstile token (bot protection)
}

/**
 * Verify a Cloudflare Turnstile token. Returns true when the token is valid, OR
 * when Turnstile isn't configured yet (no TURNSTILE_SECRET_KEY) — so the widget
 * can be rolled out gradually: set the secret + the worker's site key and it
 * activates. Fail-closed only when a secret IS set and the token is missing/bad.
 */
async function verifyTurnstile(token: string | undefined, ip: string): Promise<boolean> {
  const secret = Deno.env.get("TURNSTILE_SECRET_KEY");
  if (!secret) return true; // not configured → don't block
  if (!token) return false;
  try {
    const form = new URLSearchParams();
    form.set("secret", secret);
    form.set("response", token);
    if (ip && ip !== "unknown") form.set("remoteip", ip);
    const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const data = await res.json().catch(() => ({ success: false }));
    return data?.success === true;
  } catch (e) {
    console.error("Turnstile verify error:", e);
    return false; // a configured verifier that errors should not let bots through
  }
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

    // Bot protection: Cloudflare Turnstile (no-op until TURNSTILE_SECRET_KEY is set).
    if (!(await verifyTurnstile(body.turnstile_token, clientIp(req)))) {
      throw new HttpError(403, "Bot check failed — please retry the form.");
    }

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

    // The public demo tour (rendprop.com/f/estate-demo) has no DB render row —
    // it's rendered from a hardcoded Tour. Still capture its leads (they route to
    // GHL like any other), tagged source "tour-demo", with null render/listing.
    const isDemo = body.slug === "estate-demo" || body.slug === "demo";

    let renderId: string | null = null;
    let listingId: string | null = null;
    let orgId: string | null = null;

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

      // org via the listing.
      const { data: listing } = await admin
        .from("listings")
        .select("id, org_id")
        .eq("id", render.listing_id)
        .maybeSingle();
      orgId = (listing?.org_id as string | null) ?? null;
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
