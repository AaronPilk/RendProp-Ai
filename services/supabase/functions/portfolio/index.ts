// portfolio — PUBLIC read of an org's whole-app share page by handle.
//
//   GET /portfolio/:handle -> { agent_card, org, tours: [ { slug, ... } ] }
//
// Powers the Cloudflare tour host's /a/:handle route: one link that shows all of
// an agent's published tours. Service-role client, but returns only a published,
// non-sensitive subset — same discipline as tours/.
//
// Fix wave 1 (2026-09-03): the agent-card name follows the shared rule (brand
// kit → agent profile → nothing; never the org name / an email), the public
// `org.name` is likewise email-guarded, and a listing's `main_photo_key` is used
// as a poster only when it is a PUBLIC `renders/` key — an `uploads/` key lives
// in the private bucket and rendered as a broken image (audit F-supabase-08).

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, pathSegments, respondError } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { publicR2Url } from "../_shared/r2.ts";
import { buildAgentCard, publicName } from "../_shared/agentcard.ts";

const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");

function formatUSD(cents: number | null | undefined): string | null {
  if (cents == null) return null;
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  }).format(Number(cents) / 100);
}

/** Only keys in the public renders bucket can be served as images. */
function publicPosterKey(key: unknown): string | null {
  const k = String(key ?? "");
  return k.startsWith("renders/") ? k : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "GET") throw new HttpError(405, "Only GET is supported");
    const seg = pathSegments(req, "portfolio");
    const handle = seg[0];
    if (!handle) throw new HttpError(400, "handle is required: GET /portfolio/:handle");

    const admin = adminClient();

    // 1. Org by public handle.
    const { data: org, error: oErr } = await admin
      .from("orgs")
      .select("id, name, handle, space_type, brand_kit")
      .eq("handle", handle)
      .is("deleted_at", null)
      .maybeSingle();
    if (oErr) throw new HttpError(500, `Org lookup failed: ${oErr.message}`);
    if (!org) throw new HttpError(404, "Portfolio not found");

    // 2. Active (non-archived, non-sold, non-deleted) listings for this org.
    const { data: listings, error: lErr } = await admin
      .from("listings")
      .select("id, agent_id, space_type, address, tagline, details, price_cents, main_photo_key, status, sold_at")
      .eq("org_id", org.id)
      .is("deleted_at", null)
      .is("sold_at", null)
      .neq("status", "archived");
    if (lErr) throw new HttpError(500, `Listings lookup failed: ${lErr.message}`);

    const listingIds = (listings ?? []).map((l) => l.id as string);
    let renders: Array<Record<string, unknown>> = [];
    if (listingIds.length > 0) {
      // 3. Their published renders (newest first → one tour per listing).
      const { data: rRows, error: rErr } = await admin
        .from("renders")
        .select("slug, listing_id, poster_key, published_at")
        .in("listing_id", listingIds)
        .not("published_at", "is", null)
        .order("published_at", { ascending: false });
      if (rErr) throw new HttpError(500, `Renders lookup failed: ${rErr.message}`);
      renders = rRows ?? [];
    }

    // Latest published render per listing.
    const latestByListing = new Map<string, Record<string, unknown>>();
    for (const r of renders) {
      const lid = r.listing_id as string;
      if (!latestByListing.has(lid)) latestByListing.set(lid, r);
    }

    const listingById = new Map((listings ?? []).map((l) => [l.id as string, l]));

    const tours = [...latestByListing.entries()].map(([lid, r]) => {
      const l = listingById.get(lid)!;
      const posterKey = publicPosterKey(r.poster_key) ?? publicPosterKey(l.main_photo_key);
      return {
        slug: r.slug as string,
        share_url: `${TOUR_BASE}/f/${r.slug as string}`,
        space_type: l.space_type as string,
        address: l.address as string | null,
        tagline: l.tagline as string | null,
        price: formatUSD(l.price_cents as number | null),
        poster: publicR2Url(posterKey),
        published_at: r.published_at,
      };
    });

    // Agent-card name fallback: the profile of the most common listing agent
    // (usually the only one) — never the org name.
    let profileName: unknown = null;
    const agentIds = (listings ?? []).map((l) => l.agent_id as string | null).filter((a): a is string => !!a);
    if (agentIds.length > 0) {
      const counts = new Map<string, number>();
      for (const a of agentIds) counts.set(a, (counts.get(a) ?? 0) + 1);
      const topAgent = [...counts.entries()].sort((a, b) => b[1] - a[1])[0][0];
      const { data: profile } = await admin.from("profiles").select("name").eq("id", topAgent).maybeSingle();
      profileName = profile?.name ?? null;
    }

    // PUBLIC response: allow-list display fields rather than spreading the whole
    // brand_kit jsonb (audit P1-4 — same discipline as tours/index.ts).
    const agent_card = buildAgentCard(org.brand_kit, { profileName, orgHandle: org.handle ?? null });

    return json({
      org: { name: publicName(org.name), handle: org.handle, space_type: org.space_type },
      agent_card,
      tours,
    });
  } catch (err) {
    return respondError(err);
  }
});
