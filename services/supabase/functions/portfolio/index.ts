// Public deliberate member portfolio. Legacy workspace handles stay empty.
// Current member, own listing, discovery, client and exact media scope are reread.

import { mediaVisibility } from "../_shared/media-source-access.ts";
import { bucketForKey } from "../studio/handler.ts";
import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, pathSegments, respondError } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { publishedR2Url } from "../_shared/r2.ts";
import { buildAgentCard, publicName } from "../_shared/agentcard.ts";
import { assertHostingAvailable } from "../_shared/hosting-retention.ts";

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
function publicPosterKey(key: unknown, orgId: string, listingId: string): string | null {
  return bucketForKey(key, { orgId, listingId }) === "renders" ? key as string : null;
}

/** A private sharing link is not permission to add an address to discovery.
 * Selection additionally requires discovery opt-in and excludes client delivery. */
function allowsDiscovery(details: unknown): boolean {
  if (!details || typeof details !== "object" || Array.isArray(details)) return false;
  const value = (details as Record<string, unknown>).allow_indexing;
  // Native listing details are String-valued; preserve that deliberate opt-in
  // while rejecting false, absent and merely truthy strings/objects.
  return value === true || value === "true";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "GET") throw new HttpError(405, "Only GET is supported");
    const seg = pathSegments(req, "portfolio");
    const handle = seg[0];
    if (!handle) throw new HttpError(400, "handle is required: GET /portfolio/:handle");

    const admin = adminClient();

    // Legacy workspace handles retain an empty public page. They never imply
    // that every member's listing was selected for somebody else's card.
    const member = /^member-([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/i.exec(handle);
    if (!member) {
      const {data: legacy,error} = await admin.from("orgs").select("id,name,handle,space_type").eq("handle",handle).is("deleted_at",null).maybeSingle();
      if(error) throw new HttpError(503,"Portfolio is temporarily unavailable.");
      if(!legacy) throw new HttpError(404,"Portfolio not found");
      await assertHostingAvailable(admin, legacy.id);
      return json({org:{name:publicName(legacy.name),handle:legacy.handle,space_type:legacy.space_type},agent_card:{name:null},tours:[]});
    }
    const {data: selection,error: selectionError} = await admin.from("member_portfolios").select("id,org_id,user_id,listing_ids,revision").eq("id",member[1]).maybeSingle();
    if(selectionError) throw new HttpError(503,"Portfolio is temporarily unavailable.");
    if(!selection) throw new HttpError(404,"Portfolio not found");
    const actor = selection.user_id as string;
    if(!Array.isArray(selection.listing_ids) || selection.listing_ids.length>100) throw new HttpError(503,"Portfolio is temporarily unavailable.");
    const {data: org,error: oErr} = await admin.from("orgs").select("id,name,handle,space_type,brand_kit").eq("id",selection.org_id).is("deleted_at",null).maybeSingle();
    if(oErr) throw new HttpError(503,"Portfolio is temporarily unavailable.");
    if(!org) throw new HttpError(404,"Portfolio not found");
    await assertHostingAvailable(admin, org.id);
    const memberActive = async () => {
      const {data: currentOrg,error: orgError} = await admin.from("orgs").select("id").eq("id",org.id).is("deleted_at",null).maybeSingle();
      if(orgError) throw new HttpError(503,"Portfolio is temporarily unavailable.");
      if(!currentOrg) return false;
      const {data: membership,error} = await admin.from("memberships").select("user_id").eq("org_id",org.id).eq("user_id",actor).maybeSingle();
      if(error) throw new HttpError(503,"Portfolio is temporarily unavailable.");
      const {data: deletions,error: deletionError} = await admin.from("deletion_requests").select("id").eq("user_id",actor).neq("status","completed").limit(1);
      if(deletionError) throw new HttpError(503,"Portfolio is temporarily unavailable.");
      return !!membership && !(deletions?.length);
    };
    if(!await memberActive()) throw new HttpError(404,"Portfolio not found");
    await assertHostingAvailable(admin, org.id);

    // 2. Active (non-archived, non-sold, non-deleted) listings for this org.
    const { data: listings, error: lErr } = await admin
      .from("listings")
      .select("id, agent_id, space_type, address, tagline, details, price_cents, main_photo_key, status, sold_at")
      .eq("org_id", org.id)
      .eq("agent_id",actor)
      .in("id",selection.listing_ids.length ? selection.listing_ids : ["00000000-0000-4000-8000-000000000000"])
      .is("deleted_at", null)
      .is("sold_at", null)
      .neq("status", "archived");
    if (lErr) throw new HttpError(503, "Portfolio is temporarily unavailable.");

    const listingIds = (listings ?? []).map((l) => l.id as string);
    let renders: Array<Record<string, unknown>> = [];
    if (listingIds.length > 0) {
      // 3. Their published renders (newest first → one tour per listing).
      const { data: rRows, error: rErr } = await admin
        .from("renders")
        .select("id, slug, listing_id, poster_key, published_at")
        .in("listing_id", listingIds)
        .not("published_at", "is", null)
        .order("published_at", { ascending: false });
      if (rErr) throw new HttpError(503, "Portfolio is temporarily unavailable.");
      renders = rRows ?? [];
    }

    // Latest published render per listing.
    const latestByListing = new Map<string, Record<string, unknown>>();
    for (const r of renders) {
      const lid = r.listing_id as string;
      if (!latestByListing.has(lid)) latestByListing.set(lid, r);
    }

    const listingById = new Map((listings ?? []).map((l) => [l.id as string, l]));

    // Service-role reads bypass render RLS. Keep the exact render identity and
    // scoped poster key until the final visibility check, before releasing URLs.
    const candidates = [...latestByListing.entries()].map(([lid, render]) => {
      const listing = listingById.get(lid);
      if (!listing) throw new HttpError(503, "Portfolio media scope could not be verified.");
      return { lid, render, listing, posterKey: publicPosterKey(render.poster_key, org.id, lid) ?? publicPosterKey(listing.main_photo_key, org.id, lid) };
    });
    const visibleCandidates: typeof candidates = [];
    const isVisible = async (card: typeof candidates[number]): Promise<boolean> => {
      // Re-read both discovery intent and client mode after every asynchronous
      // assembly boundary. Service-role reads otherwise bypass the privacy UI.
      if(!await memberActive()) return false;
      const {data: selected,error: selectedError} = await admin.from("member_portfolios").select("listing_ids").eq("id",selection.id).eq("org_id",org.id).eq("user_id",actor).maybeSingle();
      if(selectedError) throw new HttpError(503,"Portfolio is temporarily unavailable.");
      if(!selected || !Array.isArray(selected.listing_ids) || !selected.listing_ids.includes(card.lid)) return false;
      const { data: current, error: currentError } = await admin.from("listings")
        .select("id, agent_id, details, status, sold_at, deleted_at")
        .eq("id", card.lid).eq("org_id", org.id).maybeSingle();
      if (currentError) throw new HttpError(503, "Portfolio is temporarily unavailable.");
      if (!current || current.agent_id !== actor || current.deleted_at || current.sold_at || current.status === "archived" || !allowsDiscovery(current.details)) return false;
      const { data: client, error: clientError } = await admin.from("listing_client_contacts")
        .select("enabled").eq("listing_id", card.lid).eq("org_id", org.id).maybeSingle();
      if (clientError) throw new HttpError(503, "Portfolio is temporarily unavailable.");
      if (client?.enabled === true) return false;
      const id = card.render.id as string;
      const access = await mediaVisibility(admin, card.lid, { renders: [id], keys: card.posterKey ? [card.posterKey] : [] });
      return access.renders[id] === true && (!card.posterKey || access.keys[card.posterKey] === true);
    };
    for (const card of candidates) if (await isVisible(card)) visibleCandidates.push(card);

    // Account-owned contact identity only; workspace branding cannot substitute
    // an inviter's name, email, portrait or personal links.
    const {data: profile,error: profileError} = await admin.from("profiles").select("name,public_card").eq("id",actor).maybeSingle();
    if(profileError) throw new HttpError(503,"Portfolio is temporarily unavailable.");
    let personal = profile?.public_card && typeof profile.public_card==="object" ? profile.public_card : {};
    const business = org.brand_kit && typeof org.brand_kit==="object" ? org.brand_kit : {};
    let agent_card = buildAgentCard({...personal,accent:business.accent,brokerage:personal.brokerage ?? business.brokerage}, {profileName:profile?.name,orgHandle:handle});

    const tours: Record<string, unknown>[] = [];
    // A profile lookup can outlive a subject's approval. Recheck after that
    // async work and omit any withdrawn card's poster AND tour slug/link.
    for (const card of visibleCandidates) {
      if (!await isVisible(card)) continue;
      const { render: r, listing: l, posterKey } = card;
      tours.push({ slug: r.slug as string, share_url: `${TOUR_BASE}/f/${r.slug as string}`,
        space_type: l.space_type as string, address: l.address as string | null,
        tagline: l.tagline as string | null, price: formatUSD(l.price_cents as number | null),
        poster: publishedR2Url(r.slug as string,posterKey), published_at: r.published_at });
    }
    const {data: currentProfile,error: finalProfileError} = await admin.from("profiles").select("name,public_card").eq("id",actor).maybeSingle();
    if(finalProfileError) throw new HttpError(503,"Portfolio is temporarily unavailable.");
    personal = currentProfile?.public_card && typeof currentProfile.public_card==="object" ? currentProfile.public_card : {};
    agent_card = buildAgentCard({...personal,accent:business.accent,brokerage:personal.brokerage ?? business.brokerage},{profileName:currentProfile?.name,orgHandle:handle});
    if(!await memberActive()) throw new HttpError(404,"Portfolio not found");
    await assertHostingAvailable(admin, org.id);
    return json({
      org: { name: publicName(org.name), handle, space_type: org.space_type },
      agent_card,
      tours,
    });
  } catch (err) {
    return respondError(err);
  }
});
