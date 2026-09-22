// jsonld.ts — schema.org structured data for the two pages that describe a
// real thing: a published tour (`/f/<slug>`) and an agent's portfolio
// (`/a/<handle>`).
//
// WHY IT LIVES HERE AND NOT IN player.ts
// The tour page and the portfolio page describe the SAME entities (an agent, a
// listing, a video), so a single builder keeps their `@id`s, their types and
// their escaping in step. It is also the only file allowed to decide what a
// space type IS in schema.org terms — see spaceTypeNode().
//
// WHERE IT IS ALLOWED TO APPEAR — three rules, all load-bearing:
//
//   1. NEVER on `/u/<slug>`. An MLS unbranded virtual-tour field bans agent /
//      broker identification and links to external content; JSON-LD naming the
//      agent, the brokerage and rendprop.com would be all of that at once, in
//      machine-readable form. The callers guard on `unbranded`, and
//      `unbrandedViolations()` (src/player.ts) fails the page closed if a guard
//      is ever broken: the block carries `rendprop.com` and the agent's name.
//   2. NEVER on `?embed=1`. The embed is the in-app hero card — a duplicate of
//      a page that already carries this, in a webview no crawler reads.
//   3. On `/f/<slug>` ONLY when the page is allowed to index — the same
//      `allowsIndexing(tour)` predicate that decides the robots tag. A tour is
//      `noindex, nofollow` until its owner opts in because the page carries
//      their name, phone, email and the listing address; handing a crawler a
//      structured, machine-readable copy of exactly those fields on a page we
//      just told it not to index would be worse than pointless.
//      `/a/<handle>` is indexable by default (it is a profile the agent asked
//      to publish), so its structured data ships with the page.
//
// NO PLACEHOLDERS, EVER. Every builder drops a field it has no real value for
// (see `compact`). A tour with no price emits no `Offer`; a render with no
// publish timestamp emits no `uploadDate`. An invented number in structured
// data is a lie told to a machine that will repeat it.

import type { Tour } from "./types";
import type { AgentModel } from "./html";
import { absolutize, jsonForScript, safeUrl } from "./html";

type LdNode = Record<string, unknown>;

/**
 * Drop every key whose value is not real data: undefined, null, "", an empty
 * array, a non-finite number, or a nested node that carries nothing but its
 * `@type`/`@id`. Applied to the whole graph on the way out, so no builder has
 * to remember to guard a single field.
 */
function compact(node: LdNode): LdNode {
  const out: LdNode = {};
  for (const [k, v] of Object.entries(node)) {
    if (v === undefined || v === null || v === "") continue;
    if (typeof v === "number") { if (Number.isFinite(v)) out[k] = v; continue; }
    if (Array.isArray(v)) {
      const items = v
        .map((x) => (x && typeof x === "object" && !Array.isArray(x) ? compact(x as LdNode) : x))
        .filter((x) => x !== undefined && x !== null && x !== "");
      if (items.length) out[k] = items;
      continue;
    }
    if (typeof v === "object") {
      const inner = compact(v as LdNode);
      // `{"@id":"…#property"}` IS the value — a JSON-LD reference to another
      // node in this graph. `{"@type":"PostalAddress"}` with no address in it
      // is not: it says nothing, so it goes.
      if (!inner["@id"] && !Object.keys(inner).some((key) => key !== "@type")) continue;
      out[k] = inner;
      continue;
    }
    out[k] = v;
  }
  return out;
}

/** A node is worth emitting only if it says something beyond its own identity. */
function hasContent(node: LdNode): boolean {
  return Object.keys(node).some((k) => k !== "@type" && k !== "@id");
}

/**
 * An ISO-8601 instant, or "" when the input is not a parseable date. The tours
 * function sends `published_at` straight from Postgres; anything that does not
 * parse is dropped rather than guessed at.
 */
function isoDate(raw: unknown): string {
  const s = String(raw ?? "").trim();
  if (!s) return "";
  const t = Date.parse(s);
  return Number.isFinite(t) ? new Date(t).toISOString() : "";
}

/** Seconds → ISO-8601 duration ("PT2M17S"). "" for 0 / unknown. */
export function isoDuration(seconds: number | null | undefined): string {
  const total = Math.round(Number(seconds));
  if (!Number.isFinite(total) || total <= 0) return "";
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return "PT" + (h ? `${h}H` : "") + (m ? `${m}M` : "") + (s || (!h && !m) ? `${s}S` : "");
}

/** An absolute https URL for a crawler, or "" — relative URLs are useless in
 *  structured data, which is read detached from the page it came from. */
function absUrl(raw: unknown, base: string): string {
  const u = absolutize(safeUrl(raw), base);
  return /^https?:\/\//i.test(u) ? u : "";
}

/**
 * The schema.org type for one of the app's space types.
 *
 * A venue, a restaurant, a shop and a gym are NOT residences, and marking them
 * up as one is the kind of error that gets structured data ignored wholesale.
 * Each of these is the narrowest schema.org type that is true of the space:
 *
 *   real_estate → ["Residence","Accommodation"]. `Residence` (Place > Residence)
 *     is true of a house, a condo or a townhouse without claiming which —
 *     `SingleFamilyResidence` would be an invented fact about half of them.
 *     But `Residence` alone carries no room or size properties, so the node is
 *     ALSO typed `Accommodation` (Place > Accommodation), which is where
 *     schema.org defines `numberOfBedrooms`, `numberOfBathroomsTotal`,
 *     `floorSize` and `yearBuilt`. Multi-typing is ordinary JSON-LD and both
 *     statements are true of a dwelling.
 *   venue      → EventVenue          (Place > CivicStructure > EventVenue)
 *   restaurant → Restaurant          (LocalBusiness > FoodEstablishment)
 *   retail     → Store               (LocalBusiness > Store)
 *   fitness    → ExerciseGym         (LocalBusiness > SportsActivityLocation)
 *   other      → LocalBusiness       — the honest generic for "a business".
 */
function spaceTypeNode(spaceType: string | null | undefined): string | string[] {
  switch (spaceType) {
    case "venue": return "EventVenue";
    case "restaurant": return "Restaurant";
    case "retail": return "Store";
    case "fitness": return "ExerciseGym";
    case "other": return "LocalBusiness";
    case "real_estate":
    default: return ["Residence", "Accommodation"];
  }
}

/** Positive number → true. The app sends 0 for "unknown" beds/baths/sqft. */
function pos(n: unknown): n is number {
  return typeof n === "number" && Number.isFinite(n) && n > 0;
}

/**
 * Wrap a finished `@graph` in the script tag.
 *
 * `jsonForScript` escapes `<`, `>` and `&` to their `\u` forms, which is still
 * valid JSON (and therefore valid JSON-LD) and makes a `</script>` inside any
 * owner-entered string — an address, a tagline, a disclosure sentence —
 * impossible to spell. Returns "" for an empty graph rather than an empty tag.
 */
function ldScript(graph: LdNode[]): string {
  const nodes = graph.map(compact).filter(hasContent);
  if (!nodes.length) return "";
  return `<script type="application/ld+json">${jsonForScript({
    "@context": "https://schema.org",
    "@graph": nodes,
  })}</script>`;
}

// ---------------------------------------------------------------------------
// The agent / business behind a page
// ---------------------------------------------------------------------------

/**
 * The person or organisation the page is by.
 *
 * A named human is a `Person`: `RealEstateAgent` is a `LocalBusiness` — an
 * ORGANISATION type — so using it for an individual says the agent is a company.
 * The brokerage goes where it belongs, in `worksFor`, and IS typed
 * `RealEstateAgent` for a real-estate listing. When the card carries only a
 * company (no human), the node is that organisation directly.
 */
function agentNode(agent: AgentModel, opts: { id: string; url: string; isRealEstate: boolean }): LdNode {
  const org = opts.isRealEstate ? "RealEstateAgent" : "Organization";
  if (!agent.name) {
    if (!agent.company) return {};
    return {
      "@type": opts.isRealEstate ? "RealEstateAgent" : "LocalBusiness",
      "@id": opts.id,
      name: agent.company,
      image: agent.photo ? absUrl(agent.photo, opts.url) : "",
      telephone: agent.phone,
      email: agent.email,
      url: opts.url,
      sameAs: (agent.socials || []).map((s) => safeUrl(s.url)).filter(Boolean),
    };
  }
  return {
    "@type": "Person",
    "@id": opts.id,
    name: agent.name,
    jobTitle: agent.title,
    image: agent.photo ? absUrl(agent.photo, opts.url) : "",
    telephone: agent.phone,
    email: agent.email,
    url: opts.url,
    sameAs: (agent.socials || []).map((s) => safeUrl(s.url)).filter(Boolean),
    worksFor: agent.company ? { "@type": org, name: agent.company } : undefined,
  };
}

// ---------------------------------------------------------------------------
// `/f/<slug>` — the branded tour page
// ---------------------------------------------------------------------------

export interface TourLdInput {
  /** The tour as rendered. Never the unbranded (sanitized) one — callers must
   *  not reach this file at all on `/u/`. */
  tour: Tour;
  agent: AgentModel;
  /** The branded canonical, e.g. `https://rendprop.com/f/estate-demo`. */
  canonical: string;
  /** Page title and description — the same strings `<title>` and og:* use. */
  name: string;
  description: string;
  /** Absolute poster URL (the og:image). "" when the tour has no poster. */
  poster: string;
  /** The all-intra scrub mp4 as rendered. Absolutized here. */
  videoUrl: string;
  /** The listing's price in dollars, or null when it has none (0 / absent). */
  priceValue: number | null;
  /** SOLD (real estate) / Archived (every other type). */
  sold: boolean;
}

/**
 * The `<script type="application/ld+json">` for a branded tour page, or "".
 *
 * The caller decides WHETHER to call this (see the three rules at the top of
 * this file); this function decides what the page can honestly say.
 */
export function tourJsonLd(input: TourLdInput): string {
  const { tour, agent, canonical, name, description, poster, priceValue, sold } = input;
  if (!/^https?:\/\//i.test(canonical)) return ""; // no canonical, no @id space
  const listing = tour.listing || ({} as Tour["listing"]);
  const isRealEstate = (tour.space_type || "real_estate") === "real_estate";

  const id = (fragment: string) => `${canonical}#${fragment}`;
  const origin = canonical.replace(/^(https?:\/\/[^/]+).*$/i, "$1");

  const published = isoDate(tour.published_at);
  const video = absUrl(input.videoUrl, canonical);

  // The space itself. Everything measurable about it is optional and every one
  // of these guards is the difference between a fact and a fabrication: the app
  // stores 0 for "the agent did not say", which is NOT "zero bedrooms".
  const place: LdNode = {
    "@type": spaceTypeNode(tour.space_type),
    "@id": id("property"),
    name,
    description: listing.tagline || "",
    // `listing.address` is a STREET ADDRESS only for real estate — for every
    // other space type the app stores the BUSINESS NAME in that column (see
    // TourListing in src/types.ts). Marking "The Foundry Loft" up as a
    // `streetAddress` would be a fabricated postal address; the business name
    // is already `name` above, which is where it belongs.
    address: isRealEstate && listing.address
      ? { "@type": "PostalAddress", streetAddress: listing.address }
      : undefined,
    image: poster,
    // `beds` is a BEDROOM count, so `numberOfBedrooms` is the property that
    // says so. schema.org's `numberOfRooms` is total rooms — a different,
    // larger number this payload does not carry, so it is not emitted.
    numberOfBedrooms: isRealEstate && pos(listing.beds) ? listing.beds : undefined,
    numberOfBathroomsTotal: isRealEstate && pos(listing.baths) ? listing.baths : undefined,
    floorSize: pos(listing.sqft)
      // FTK is the UN/CEFACT code for square foot, which is the unit the app
      // collects. `unitText` alone would leave the number ambiguous.
      ? { "@type": "QuantitativeValue", value: listing.sqft, unitCode: "FTK", unitText: "sqft" }
      : undefined,
    // Coordinates are published only for a business, whose page already renders
    // a "Get directions" link built from these exact values. A private home's
    // page does not, and structured data is not the place to start.
    geo: !isRealEstate && typeof listing.lat === "number" && Number.isFinite(listing.lat) &&
         typeof listing.lng === "number" && Number.isFinite(listing.lng)
      ? { "@type": "GeoCoordinates", latitude: listing.lat, longitude: listing.lng }
      : undefined,
  };

  // The flythrough. `contentUrl` is the mp4 the page actually scrubs;
  // `embedUrl` is the hero-only render the in-app card already uses.
  const videoNode: LdNode = {
    "@type": "VideoObject",
    "@id": id("video"),
    name: `${name} — video tour`,
    description,
    thumbnailUrl: poster,
    contentUrl: video,
    embedUrl: `${canonical}?embed=1`,
    uploadDate: published,
    duration: isoDuration(tour.duration_s),
    about: { "@id": id("property") },
  };

  // For a business page the "agent card" with no human on it IS the business
  // this page is already about — a second node for it would be the same entity
  // under a second @id. Only a NAMED person adds anything there.
  const agentLd = !isRealEstate && !agent.name
    ? {}
    : agentNode(agent, {
        id: id("agent"),
        url: agent.handle ? `${origin}/a/${encodeURIComponent(agent.handle)}` : canonical,
        isRealEstate,
      });
  const hasAgent = hasContent(compact(agentLd));

  // Price. An `Offer` is the only schema.org shape that carries one, and it
  // exists only when the listing HAS a price — a venue's "from $3,500" hire
  // rate is not an offer to sell the building, so this is real estate only.
  const offer: LdNode = isRealEstate && priceValue != null && priceValue > 0
    ? {
        "@type": "Offer",
        "@id": id("offer"),
        price: priceValue,
        priceCurrency: "USD",
        availability: sold ? "https://schema.org/SoldOut" : "https://schema.org/InStock",
        itemOffered: { "@id": id("property") },
        seller: hasAgent ? { "@id": id("agent") } : undefined,
        url: canonical,
      }
    : {};

  // Breadcrumb: the site, the agent's portfolio (when the card names a handle,
  // which is the same link the end card renders), and this tour.
  const crumbs: LdNode[] = [
    { "@type": "ListItem", position: 1, name: "Rendprop", item: `${origin}/` },
  ];
  if (agent.handle) {
    crumbs.push({
      "@type": "ListItem",
      position: crumbs.length + 1,
      name: agent.name || agent.company || `@${agent.handle}`,
      item: `${origin}/a/${encodeURIComponent(agent.handle)}`,
    });
  }
  crumbs.push({ "@type": "ListItem", position: crumbs.length + 1, name, item: canonical });

  const graph: LdNode[] = [];

  if (isRealEstate) {
    // `RealEstateListing` is a WebPage subtype — it is the LISTING (this page),
    // not the building. The building is the `mainEntity` below it. For every
    // other space type there is no listing: the page is the business's own
    // profile, so the business node stands alone as the page's subject.
    graph.push({
      "@type": "RealEstateListing",
      "@id": id("listing"),
      url: canonical,
      name,
      description,
      image: poster,
      datePosted: published,
      mainEntity: { "@id": id("property") },
      video: { "@id": id("video") },
      provider: hasAgent ? { "@id": id("agent") } : undefined,
    });
  } else {
    place.url = canonical;
    place.subjectOf = { "@id": id("video") };
    // A LocalBusiness is an Organization, so a named human on the card is its
    // employee. (`agentLd` above is already empty when there is no human.)
    if (hasAgent) place.employee = { "@id": id("agent") };
  }

  graph.push(place, videoNode);
  if (hasContent(offer)) graph.push(offer);
  if (hasAgent) graph.push(agentLd);
  graph.push({ "@type": "BreadcrumbList", "@id": id("breadcrumb"), itemListElement: crumbs });

  return ldScript(graph);
}

// ---------------------------------------------------------------------------
// `/a/<handle>` — the portfolio page
// ---------------------------------------------------------------------------

export interface PortfolioLdInput {
  agent: AgentModel;
  /** `https://rendprop.com/a/<handle>` — the page's own canonical. */
  canonical: string;
  /** Display name and description, the same strings `<title>`/og:* use. */
  name: string;
  description: string;
  /** Whether this org sells real estate — picks Person/RealEstateAgent typing. */
  isRealEstate: boolean;
  /** The cards the page actually renders, in the order it renders them. */
  tours: Array<{ slug: string; name: string; poster?: string | null }>;
}

/**
 * `ProfilePage` + the agent + an `ItemList` of the published tours.
 *
 * The ItemList MIRRORS THE VISIBLE GRID — every card on the page, in page
 * order. It deliberately does NOT filter by each tour's own indexing opt-in:
 * an ItemList is a description of this page's contents, and a page that claims
 * six tours while showing eight is the misrepresentation the format exists to
 * prevent. The sitemap is where the opt-in rule lives, because a sitemap is a
 * request to index, and this is not (see src/sitemap.ts).
 */
export function portfolioJsonLd(input: PortfolioLdInput): string {
  const { agent, canonical, name, description, isRealEstate, tours } = input;
  if (!/^https?:\/\//i.test(canonical)) return "";
  const id = (fragment: string) => `${canonical}#${fragment}`;
  const origin = canonical.replace(/^(https?:\/\/[^/]+).*$/i, "$1");

  const agentLd = agentNode(agent, { id: id("agent"), url: canonical, isRealEstate });
  const hasAgent = hasContent(compact(agentLd));

  const graph: LdNode[] = [
    {
      "@type": "ProfilePage",
      "@id": id("page"),
      url: canonical,
      name,
      description,
      mainEntity: hasAgent ? { "@id": id("agent") } : undefined,
    },
  ];
  if (hasAgent) graph.push(agentLd);

  if (tours.length) {
    graph.push({
      "@type": "ItemList",
      "@id": id("tours"),
      name: `Tours by ${name}`,
      numberOfItems: tours.length,
      itemListOrder: "https://schema.org/ItemListUnordered",
      itemListElement: tours.map((t, i) => ({
        "@type": "ListItem",
        position: i + 1,
        name: t.name,
        url: `${origin}/f/${encodeURIComponent(t.slug)}`,
        image: absUrl(t.poster, canonical),
      })),
    });
  }

  return ldScript(graph);
}
