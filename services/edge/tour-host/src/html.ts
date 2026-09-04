// Shared HTML helpers: escaping, safe JSON-into-<script> embedding, design
// tokens (ported from the iOS player/index.html), the agent-card extraction
// (from org.brand_kit), and the branded fallback pages.

import type { AgentCard, SecondaryLink } from "./types";

export const BRAND_ACCENT = "#d9a441";

/** HTML-escape for text nodes and attribute values. */
export function escapeHtml(input: unknown): string {
  return String(input ?? "").replace(/[&<>"']/g, (c) => {
    switch (c) {
      case "&": return "&amp;";
      case "<": return "&lt;";
      case ">": return "&gt;";
      case '"': return "&quot;";
      default: return "&#39;"; // '
    }
  });
}

/** Alias — clarity at call sites that build attributes. */
export const escapeAttr = escapeHtml;

/**
 * Serialize an object for safe embedding inside a <script> block.
 * Neutralizes `</script>`, `<!--`, and the JS line/paragraph separators
 * (U+2028 / U+2029) which are valid in JSON but break inline scripts.
 */
export function jsonForScript(obj: unknown): string {
  return JSON.stringify(obj)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/&/g, "\\u0026")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
}

/** True when the URL points at an HLS manifest (Cloudflare Stream). */
export function isHlsUrl(url: string | null | undefined): boolean {
  return !!url && /\.m3u8(\?|#|$)/i.test(url);
}

/** Only allow a strict hex color as a brand accent (prevents CSS injection). */
export function safeColor(v: unknown): string | null {
  const s = String(v ?? "").trim();
  return /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(s) ? s : null;
}

/**
 * Scheme-allowlist for publisher-supplied URLs (audit P1: a `javascript:` URL
 * in cta.url/secondary executed on click because CSP allows unsafe-inline).
 * Returns the URL when its scheme is safe, else "" so call sites degrade to
 * not rendering the link/media. Scheme-relative and relative URLs are allowed
 * (they resolve against our own https origin).
 */
export function safeUrl(v: unknown, extraSchemes: string[] = []): string {
  const s = String(v ?? "").trim();
  if (!s) return "";
  const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(s);
  if (!m) return s; // relative / anchor / query — resolves on our origin
  const scheme = m[1].toLowerCase();
  const allowed = ["http", "https", ...extraSchemes];
  return allowed.includes(scheme) ? s : "";
}

/** Same shape the leads function accepts as an email. Used to keep a sign-in
 *  address from ever being printed as a person's or business's NAME (audit
 *  F-H-05: `orgs.name` used to be seeded with the account email). */
export function looksLikeEmail(v: unknown): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(v ?? "").trim());
}

/** Resolve a root-relative URL against the share URL's origin (social scrapers
 *  need absolute og:image URLs). Absolute URLs pass through untouched. */
export function absolutize(url: string, shareUrl: string | null | undefined): string {
  if (!url || !url.startsWith("/")) return url;
  let origin = "https://rendprop.com";
  try { if (shareUrl) origin = new URL(shareUrl).origin; } catch { /* keep default */ }
  return origin + url;
}

/** "party_size" -> "Party Size". */
export function humanize(key: string): string {
  return String(key || "")
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase())
    .trim();
}

/** First non-empty stringified value. */
export function first(...vals: unknown[]): string {
  for (const v of vals) {
    const s = typeof v === "string" ? v.trim() : v == null ? "" : String(v);
    if (s) return s;
  }
  return "";
}

export function initialsFrom(name: string): string {
  const parts = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return "R";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

export function spaceLabel(spaceType: string | null | undefined): string {
  switch (spaceType) {
    case "venue": return "Event venue";
    case "restaurant": return "Restaurant";
    case "retail": return "Store";
    case "fitness": return "Studio";
    case "other": return "Business";
    case "real_estate":
    default: return "Property";
  }
}

// ---------------------------------------------------------------------------
// Agent card extraction — org.brand_kit is freeform jsonb spread into
// agent_card by the tours function, so we read many likely key names.
// ---------------------------------------------------------------------------

export interface AgentModel {
  name: string;
  /** Job title / role line (brand_kit.title) — shown under the name when set. */
  title: string;
  company: string;
  phone: string;
  email: string;
  /** Already scheme-checked (safeUrl) — "" when absent or unsafe. */
  photo: string;
  handle: string;
  accent: string | null;
  initials: string;
  socials: SecondaryLink[];
}

const SOCIAL_DEFS: Array<{ keys: string[]; label: string; base: string; digits?: boolean }> = [
  { keys: ["instagram", "ig"], label: "Instagram", base: "https://instagram.com/" },
  { keys: ["tiktok"], label: "TikTok", base: "https://tiktok.com/@" },
  { keys: ["facebook", "fb"], label: "Facebook", base: "https://facebook.com/" },
  { keys: ["linkedin"], label: "LinkedIn", base: "https://linkedin.com/in/" },
  { keys: ["youtube", "yt"], label: "YouTube", base: "https://youtube.com/@" },
  { keys: ["twitter", "x"], label: "X", base: "https://x.com/" },
  { keys: ["whatsapp"], label: "WhatsApp", base: "https://wa.me/", digits: true },
  { keys: ["website", "site", "url", "web"], label: "Website", base: "" },
];

function normalizeSocial(def: { base: string; digits?: boolean }, raw: unknown): string | null {
  const s = String(raw ?? "").trim();
  if (!s) return null;
  if (/^https?:\/\//i.test(s)) return s;
  if (def.digits) {
    const d = s.replace(/[^\d]/g, "");
    return d ? def.base + d : null;
  }
  if (def.base === "") return "https://" + s.replace(/^\/+/, "");
  return def.base + s.replace(/^@/, "").replace(/^\/+/, "");
}

export function collectSocials(agent: AgentCard): SecondaryLink[] {
  const out: SecondaryLink[] = [];
  const seen = new Set<string>();
  const pools: Record<string, unknown>[] = [];
  const nested = agent.socials as unknown;
  if (nested && typeof nested === "object" && !Array.isArray(nested)) {
    pools.push(nested as Record<string, unknown>);
  }
  pools.push(agent as Record<string, unknown>);

  for (const def of SOCIAL_DEFS) {
    if (seen.has(def.label)) continue;
    for (const pool of pools) {
      let val: unknown;
      for (const k of def.keys) {
        if (pool[k] != null && pool[k] !== "") { val = pool[k]; break; }
      }
      const url = normalizeSocial(def, val);
      if (url) { out.push({ label: def.label, url }); seen.add(def.label); break; }
    }
  }

  if (Array.isArray(nested)) {
    for (const item of nested as Array<Record<string, unknown>>) {
      const label = first(item.label, item.type, item.name);
      const url = first(item.url, item.href, item.link);
      if (label && url && /^https?:\/\//i.test(url) && !seen.has(label)) {
        out.push({ label, url });
        seen.add(label);
      }
    }
  }
  return out;
}

/** A publishable display string: trimmed, and never an email address. */
function displayName(...vals: unknown[]): string {
  const s = first(...vals);
  return looksLikeEmail(s) ? "" : s;
}

export function extractAgent(agent: AgentCard): AgentModel {
  const a = agent || {};
  // The tours/portfolio functions already refuse to publish an email as the
  // name (decision A14); this is defence in depth for older payloads.
  const name = displayName(a.name, a.agent_name, a.full_name, a.display_name);
  const title = displayName(a.title, a.role, a.job_title);
  const company = displayName(
    a.company, a.brokerage, a.subtitle, a.team,
    a.org_name, a.business_name, a.org, a.tagline,
  );
  const phone = first(a.phone, a.phone_number, a.tel, a.mobile);
  const email = first(a.email);
  // headshot_url / logo_url are the keys PATCH /me/brand allow-lists; the rest
  // are legacy spellings kept for older brand kits.
  const photo = safeUrl(first(
    a.headshot_url, a.logo_url, a.avatar_url, a.photo_url, a.image_url,
    a.photo, a.avatar, a.image, a.headshot,
  ));
  const handle = first(a.handle);
  const accent = safeColor(first(a.accent, a.accent_color, a.color, a.brand_color));
  return {
    name, title, company, phone, email, photo, handle, accent,
    initials: initialsFrom(name || company),
    socials: collectSocials(a),
  };
}

/** Design tokens + reset, ported verbatim from the iOS player. */
export const TOKENS_CSS = `
  :root {
    --bg: #0b0d10;
    --ink: #f2f3f5;
    --ink-dim: rgba(242,243,245,.62);
    --accent: ${BRAND_ACCENT};
    --card: rgba(16,19,24,.78);
    --radius: 16px;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html { scroll-behavior: auto; }
  body {
    background: var(--bg); color: var(--ink);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
    overscroll-behavior-y: none;
  }
  a { color: var(--accent); }
`;

/** Common <head> boilerplate shared by the non-player pages. */
export function headMeta(title: string, description?: string): string {
  return `<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${escapeHtml(title)}</title>${description ? `\n<meta name="description" content="${escapeAttr(description)}">` : ""}
<meta name="theme-color" content="#0b0d10">`;
}

function centeredPage(opts: {
  title: string;
  heading: string;
  body: string;
  cta?: { label: string; href: string };
}): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
${headMeta(opts.title)}
<style>${TOKENS_CSS}
  .wrap { min-height:100svh; min-height:100vh; display:flex; align-items:center; justify-content:center; padding:32px 20px; text-align:center; }
  .box { max-width:420px; }
  .mark { font-size:12px; letter-spacing:.35em; text-transform:uppercase; color:var(--ink-dim); margin-bottom:22px; }
  h1 { font-size:26px; font-weight:650; letter-spacing:-.01em; margin-bottom:10px; }
  p { color:var(--ink-dim); font-size:15px; line-height:1.5; margin-bottom:22px; }
  .btn { display:inline-block; padding:13px 22px; border-radius:12px; background:var(--accent); color:#14100a; font-weight:650; font-size:15px; text-decoration:none; }
</style>
</head>
<body>
  <div class="wrap"><div class="box">
    <div class="mark">RENDPROP</div>
    <h1>${escapeHtml(opts.heading)}</h1>
    <p>${opts.body}</p>
    ${opts.cta ? `<a class="btn" href="${escapeAttr(opts.cta.href)}">${escapeHtml(opts.cta.label)}</a>` : ""}
  </div></div>
</body>
</html>`;
}

/** Branded 404. `kind` picks the copy: a missing/unpublished tour vs any
 *  other unknown path (audit F-H-21: "/anything" used to say "tour not found"). */
export function notFoundPage(kind: "tour" | "page" = "tour"): string {
  if (kind === "page") {
    return centeredPage({
      title: "Page not found — Rendprop",
      heading: "There's nothing at this address",
      body: "The link may be mistyped. Tours live at rendprop.com/f/… and the rest of the site is at rendprop.com.",
      cta: { label: "Go to Rendprop", href: "https://rendprop.com" },
    });
  }
  return centeredPage({
    title: "Tour not found — Rendprop",
    heading: "This tour isn't available",
    body: "The link may have expired, been unpublished, or mistyped.",
    cta: { label: "Go to Rendprop", href: "https://rendprop.com" },
  });
}

/** Branded 5xx. Used for upstream (502) and for any exception the Worker
 *  itself throws (500) — a viewer must never see Cloudflare's raw error page. */
export function errorPage(kind: "tour" | "page" = "tour"): string {
  return centeredPage({
    title: "Temporarily unavailable — Rendprop",
    heading: kind === "tour" ? "We couldn't load this tour" : "Something went wrong",
    body: "Something went wrong on our side. Please try again in a moment.",
    cta: { label: "Retry", href: "" },
  });
}

export function portfolioUnavailablePage(handle: string): string {
  return centeredPage({
    title: "Portfolio not found — Rendprop",
    heading: "No portfolio here yet",
    body: `We couldn't find a public portfolio for <b>${escapeHtml("@" + handle)}</b>.`,
    cta: { label: "Go to Rendprop", href: "https://rendprop.com" },
  });
}
