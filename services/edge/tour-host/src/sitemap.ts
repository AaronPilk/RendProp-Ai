// sitemap.ts — `GET /sitemap.xml`, served by the Worker.
//
// WHAT THIS REPLACED
// `public/sitemap.xml` was a hand-maintained file of eight URLs. It listed the
// five marketing pages, the two legal pages and the demo tour, and in the
// lifetime of the product it never once named a real customer tour or a single
// portfolio — the only pages on this domain that grow. A static sitemap cannot:
// a new tour is published from an iPhone, and nobody edits an XML file after.
//
// TWO RULES THAT MAY NOT BE RELAXED
//
//   1. NO `/u/<slug>` URL, ever. The MLS-unbranded twin is `noindex` by
//      construction and the branded `/f/` page is its canonical. Putting it in
//      a sitemap would be asking a crawler to index the one page whose whole
//      job is not to be branded content. `sitemapXml()` builds `/f/` and `/a/`
//      paths only and never takes a path from a caller.
//   2. NO tour that is not opted into indexing. `/f/<slug>` is
//      `noindex, nofollow` until its owner opts in (src/player.ts
//      `allowsIndexing`), because the page carries their name, phone, email and
//      the listing address. A sitemap entry is a REQUEST to index; listing a
//      page we simultaneously tell the crawler to drop is both contradictory
//      and a disclosure the owner never agreed to. Every tour handed to this
//      builder must already have been filtered by that same predicate.
//
// Current customer enumeration comes from the fresh, service-filtered
// `GET /tours/index`. The index names bounded200-publication child files.
// The static marketing/demo child keeps its actual edit dates separately.
// Neither an upstream failure nor a truncated page list becomes a partial
// success. Customer index/child responses are no-store for publication revocation.

/** One `<url>` entry. `lastmod` is omitted when there is no real date for it. */
import { propertyAddressPath } from "./property-seo";

export interface SitemapEntry {
  loc: string;
  lastmod?: string;
  changefreq?: string;
  priority?: string;
}

/** A published tour, already filtered by the indexing opt-in (rule 2 above). */
export interface SitemapTour {
  slug: string;
  /** renders.published_at. Omitted from the output when absent/unparseable. */
  publishedAt?: string | null;
}

/** An org's public portfolio handle. */
export interface SitemapPortfolio {
  handle: string;
  updatedAt?: string | null;
}

/**
 * The marketing + legal pages, with the dates carried over from the
 * hand-maintained `public/sitemap.xml` this route replaced.
 *
 * These are the ONE hand-maintained thing left here, and deliberately so: they
 * are real "last substantially edited" dates that a Worker has no way to read
 * at runtime (static assets are served by the edge, not by this script), and
 * dropping them would be a regression from the file being replaced. Bump the
 * date with the page. Everything below this constant is derived from live data.
 */
const SITE_PAGES: SitemapEntry[] = [
  { loc: "/", lastmod: "2026-09-12", changefreq: "weekly", priority: "1.0" },
  { loc: "/features", lastmod: "2026-09-05", changefreq: "weekly", priority: "0.9" },
  { loc: "/pricing", lastmod: "2026-09-12", changefreq: "weekly", priority: "0.9" },
  { loc: "/compare", lastmod: "2026-09-05", changefreq: "weekly", priority: "0.8" },
  { loc: "/support", lastmod: "2026-09-12", changefreq: "monthly", priority: "0.7" },
  { loc: "/terms", lastmod: "2026-10-09", changefreq: "yearly", priority: "0.3" },
  { loc: "/privacy", lastmod: "2026-09-05", changefreq: "yearly", priority: "0.3" },
];

/** The demo tour and the demo agent's portfolio. Rendprop's own content, served
 *  from src/demo.ts with no database behind it, opted into indexing in the
 *  payload itself, and the page every marketing link points at. */
const DEMO_PAGES: SitemapEntry[] = [
  { loc: "/f/estate-demo", lastmod: "2026-09-05", changefreq: "weekly", priority: "0.8" },
  { loc: "/a/meridian", lastmod: "2026-09-05", changefreq: "weekly", priority: "0.6" },
];

/** `<loc>` is character data: escape it even though our own paths never need it. */
function escapeXml(value: string): string {
  return String(value ?? "").replace(/[&<>"']/g, (c) =>
    c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : c === '"' ? "&quot;" : "&apos;");
}

/** `2026-09-12` — the W3C date form sitemaps take. "" when there is no real date. */
function lastmodOf(raw: unknown): string {
  const s = String(raw ?? "").trim();
  if (!s) return "";
  const t = Date.parse(s);
  return Number.isFinite(t) ? new Date(t).toISOString().slice(0, 10) : "";
}

/** Slugs are nanoid (base64url); handles are the portfolio route's own charset.
 *  Anything else never reaches a `<loc>` — a sitemap is not a place to find out
 *  that an upstream row was malformed. */
const SLUG_RE = /^[A-Za-z0-9_-]{1,64}$/;
const HANDLE_RE = /^[A-Za-z0-9_.-]{1,64}$/;

function urlBlock(origin: string, e: SitemapEntry): string {
  return [
    "  <url>",
    `    <loc>${escapeXml(origin + e.loc)}</loc>`,
    ...(e.lastmod ? [`    <lastmod>${escapeXml(e.lastmod)}</lastmod>`] : []),
    ...(e.changefreq ? [`    <changefreq>${escapeXml(e.changefreq)}</changefreq>`] : []),
    ...(e.priority ? [`    <priority>${escapeXml(e.priority)}</priority>`] : []),
    "  </url>",
  ].join("\n");
}

/**
 * The sitemap body.
 *
 * `tours` must already be filtered to tours whose owner opted into indexing —
 * this function cannot check (it has no Tour payload) and will not guess.
 */
export function sitemapXml(
  origin: string,
  tours: SitemapTour[] = [],
  portfolios: SitemapPortfolio[] = [],
): string {
  const base = String(origin || "").replace(/\/+$/, "");
  const seen = new Set<string>();
  const entries: SitemapEntry[] = [];
  const add = (e: SitemapEntry) => {
    if (seen.has(e.loc)) return;
    seen.add(e.loc);
    entries.push(e);
  };

  for (const page of [...SITE_PAGES, ...DEMO_PAGES]) add(page);

  for (const t of tours) {
    const slug = String(t?.slug || "");
    if (!SLUG_RE.test(slug)) continue;
    add({
      loc: `/f/${encodeURIComponent(slug)}`,
      lastmod: lastmodOf(t.publishedAt) || undefined,
      changefreq: "weekly",
      priority: "0.7",
    });
  }

  for (const p of portfolios) {
    const handle = String(p?.handle || "");
    if (!HANDLE_RE.test(handle)) continue;
    add({
      loc: `/a/${encodeURIComponent(handle)}`,
      lastmod: lastmodOf(p.updatedAt) || undefined,
      changefreq: "weekly",
      priority: "0.6",
    });
  }

  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${entries.map((e) => urlBlock(base, e)).join("\n")}
</urlset>
`;
}

const CURSOR_RE = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
export const sitemapCursor = (value: unknown): value is string =>
  typeof value === "string" && CURSOR_RE.test(value);

/** Each child is at most200 current, opted-in publications. An incomplete
 * index refuses instead of silently hiding listings after a service limit. */
export function propertySitemapCursors(value: unknown): (string | null)[] | null {
  if (!value || typeof value !== "object") return null;
  const v = value as Record<string, unknown>;
  if (v.page_size !== 200 || v.truncated !== false || !Array.isArray(v.pages)
      || v.pages.length < 1 || v.pages.length > 250) return null;
  const cursors: (string | null)[] = [];
  for (const row of v.pages) {
    if (!row || typeof row !== "object") return null;
    const cursor = (row as Record<string, unknown>).cursor;
    if (cursors.length === 0 ? cursor !== null : !sitemapCursor(cursor)) return null;
    if (cursors.includes(cursor as string | null)) return null;
    cursors.push(cursor as string | null);
  }
  return cursors;
}

export function sitemapIndexXml(origin: string, cursors: (string | null)[]): string {
  const paths = ["/sitemap-site.xml", ...cursors.map(cursor =>
    "/sitemap-properties.xml" + (cursor ? "?cursor=" + encodeURIComponent(cursor) : ""))];
  return `<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${paths.map(path => `  <sitemap><loc>${escapeXml(origin + path)}</loc></sitemap>`).join("\n")}\n</sitemapindex>\n`;
}

/** Refuse a malformed upstream page as a whole. No private or opted-out
 * fallback rows, guessed addresses, preview links or unbranded URLs. */
export function propertySitemapXml(origin: string, value: unknown): string | null {
  if (!value || typeof value !== "object") return null;
  const v = value as Record<string, unknown>;
  if (!Array.isArray(v.tours) || v.tours.length > 200
      || !(v.next_cursor === null || sitemapCursor(v.next_cursor))) return null;
  const entries: SitemapEntry[] = [];
  const seen = new Set<string>();
  for (const item of v.tours) {
    if (!item || typeof item !== "object") return null;
    const row = item as Record<string, unknown>;
    if (typeof row.slug !== "string" || !SLUG_RE.test(row.slug)
        || seen.has(row.slug) || row.allow_indexing !== true
        || typeof row.published_at !== "string" || !lastmodOf(row.published_at)
        || (row.address != null && (typeof row.address !== "string" || row.address.length > 500))) return null;
    seen.add(row.slug);
    entries.push({loc: propertyAddressPath(row.slug, row.address), lastmod: lastmodOf(row.published_at)});
  }
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries.map(e => urlBlock(origin, e)).join("\n")}\n</urlset>\n`;
}
