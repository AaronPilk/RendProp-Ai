// portfolio — PUBLIC read of an org's whole-app share page by handle.
//
//   GET /portfolio/:handle -> { agent_card, org, tours: [ { slug, ... } ] }
//
// Powers the Cloudflare tour host's /a/:handle route: one link that shows all of
// an agent's published tours. Service-role client, but returns only a published,
// non-sensitive subset — same discipline as tours/.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, pathSegments, respondError } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { publicR2Url } from "../_shared/r2.ts";

const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");

function formatUSD(cents: number | null | undefined): string | null {
  if (cents == null) return null;
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  }).format(Number(cents) / 100);
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

    // 2. Active (non-archived, non-deleted) listings for this org.
    const { data: listings, error: lErr } = await admin
      .from("listings")
      .select("id, space_type, address, tagline, details, price_cents, main_photo_key")
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
      return {
        slug: r.slug as string,
        share_url: `${TOUR_BASE}/f/${r.slug as string}`,
        space_type: l.space_type as string,
        address: l.address as string | null,
        tagline: l.tagline as string | null,
        price: formatUSD(l.price_cents as number | null),
        poster: publicR2Url((r.poster_key as string) ?? (l.main_photo_key as string)),
      };
    });

    // PUBLIC response: allow-list display fields rather than spreading the whole
    // brand_kit jsonb (audit P1-4 — same discipline as tours/index.ts).
    const brand = (org.brand_kit as Record<string, unknown> | null) ?? {};
    const AGENT_CARD_FIELDS = [
      "name", "handle", "title", "brokerage", "phone", "email", "website",
      "avatar_url", "headshot_url", "instagram", "linkedin", "tiktok", "accent",
    ] as const;
    const agent_card: Record<string, unknown> = {
      name: (brand.name as string) ?? org.name ?? null,
      handle: org.handle ?? null,
    };
    for (const f of AGENT_CARD_FIELDS) {
      if (brand[f] != null && agent_card[f] == null) agent_card[f] = brand[f];
    }

    return json({
      org: { name: org.name, handle: org.handle, space_type: org.space_type },
      agent_card,
      tours,
    });
  } catch (err) {
    return respondError(err);
  }
});
