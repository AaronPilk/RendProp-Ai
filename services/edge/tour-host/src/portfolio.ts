// portfolio.ts — renders GET /a/:handle: an org's public "whole-app" page with
// an agent header and a grid of tour cards linking to /f/:slug.
//
// Contract (services/supabase/functions/portfolio/index.ts):
//   { org: {name, handle, space_type}, agent_card, tours: [{ slug, share_url,
//     space_type, address, tagline, price, poster }] }
// The renderer stays defensive (normalizes the array from a few likely keys,
// tolerates missing fields) and always links cards to the local /f/:slug path
// rather than the absolute share_url, so it works on workers.dev too.

import type { Portfolio, PortfolioTour } from "./types";
import {
  absolutize,
  escapeAttr,
  escapeHtml,
  extractAgent,
  looksLikeEmail,
  safeUrl,
  spaceLabel,
  TOKENS_CSS,
} from "./html";

function fmtInt(n: number): string {
  return new Intl.NumberFormat("en-US").format(n);
}

/** Accept `tours`, `listings`, or `items` — whatever the endpoint ends up using. */
function normalizeTours(data: Portfolio): PortfolioTour[] {
  const anyData = data as unknown as Record<string, unknown>;
  const raw =
    (Array.isArray(data.tours) && data.tours) ||
    (Array.isArray(data.listings) && data.listings) ||
    (Array.isArray(anyData.items) && (anyData.items as PortfolioTour[])) ||
    [];
  return (raw as PortfolioTour[]).filter((t) => t && t.slug);
}

function cardTitle(t: PortfolioTour): string {
  return (
    t.title ||
    t.address ||
    t.tagline ||
    spaceLabel(t.space_type)
  );
}

function pos(n: number | null | undefined): n is number {
  return typeof n === "number" && Number.isFinite(n) && n > 0;
}

function cardMeta(t: PortfolioTour): string {
  // 0 = unknown (the app never invents beds/baths) → skip, like the tour page.
  if (t.price && !/^\$?0(\.0+)?$/.test(t.price.trim()) && (t.price_cents == null || pos(t.price_cents))) return t.price;
  const bits: string[] = [];
  if (pos(t.beds)) bits.push(`${t.beds} bd`);
  if (pos(t.baths)) bits.push(`${String(t.baths)} ba`);
  if (pos(t.sqft)) bits.push(`${fmtInt(t.sqft)} sqft`);
  if (bits.length) return bits.join(" · ");
  if (t.tagline && t.tagline !== cardTitle(t)) return t.tagline;
  return spaceLabel(t.space_type);
}

function renderCard(t: PortfolioTour): string {
  const href = `/f/${encodeURIComponent(t.slug)}`;
  const poster = safeUrl(t.poster);
  const thumb = poster
    ? `<img src="${escapeAttr(poster)}" alt="" loading="lazy" decoding="async">`
    : `<span class="ph" aria-hidden="true">&#9654;</span>`;
  const badge = t.staged ? `<span class="badge">&#10022; Staged</span>` : "";
  return `<a class="card" href="${escapeAttr(href)}">
      <div class="thumb">${thumb}${badge}</div>
      <div class="cardbody">
        <div class="t">${escapeHtml(cardTitle(t))}</div>
        <div class="m">${escapeHtml(cardMeta(t))}</div>
      </div>
    </a>`;
}

const PORTFOLIO_CSS = `${TOKENS_CSS}
  .wrap { max-width: 1040px; margin: 0 auto; padding: 40px 20px calc(64px + env(safe-area-inset-bottom)); }
  .brandmark { font-size: 12px; letter-spacing: .35em; text-transform: uppercase; color: var(--ink-dim); margin-bottom: 26px; }
  .phead { display: flex; align-items: center; gap: 16px; margin-bottom: 8px; }
  .phead .avatar { width: 64px; height: 64px; border-radius: 50%; overflow: hidden; flex: 0 0 auto; background: linear-gradient(135deg, #33404f, #1c242e); display: flex; align-items: center; justify-content: center; font-weight: 650; font-size: 22px; color: var(--accent); }
  .phead .avatar img { width: 100%; height: 100%; object-fit: cover; }
  .phead .pname { font-size: 24px; font-weight: 700; letter-spacing: -.01em; }
  .phead .pcompany { font-size: 14px; color: var(--ink-dim); margin-top: 3px; }
  .phead .phandle { font-size: 13px; color: var(--accent); margin-top: 2px; }
  .psocial { display: flex; flex-wrap: wrap; gap: 16px; margin: 14px 0 30px; }
  .psocial a { color: var(--accent); font-size: 13.5px; font-weight: 600; text-decoration: none; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 16px; }
  .card { display: block; text-decoration: none; color: inherit; background: var(--card); border: 1px solid rgba(255,255,255,.08); border-radius: 14px; overflow: hidden; transition: transform .15s ease, border-color .15s ease; }
  .card:hover { transform: translateY(-2px); border-color: rgba(155,109,255,.5); }
  .thumb { position: relative; aspect-ratio: 4 / 5; background: #12161b; display: flex; align-items: center; justify-content: center; }
  .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .thumb .ph { font-size: 30px; color: rgba(255,255,255,.28); }
  .thumb .badge { position: absolute; top: 10px; left: 10px; font-size: 10.5px; letter-spacing: .03em; color: rgba(255,255,255,.85); background: rgba(11,13,16,.6); backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px); padding: 4px 8px; border-radius: 999px; border: 1px solid rgba(255,255,255,.16); }
  .cardbody { padding: 12px 13px 14px; }
  .cardbody .t { font-size: 14.5px; font-weight: 600; line-height: 1.3; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
  .cardbody .m { font-size: 12.5px; color: var(--ink-dim); margin-top: 4px; }
  .empty { color: var(--ink-dim); font-size: 15px; padding: 30px 0; }
  .foot { margin-top: 40px; font-size: 11px; color: rgba(242,243,245,.4); }
  .foot a { color: rgba(242,243,245,.6); text-decoration: none; }
`;

export function renderPortfolioPage(data: Portfolio): string {
  const agent = extractAgent(data.agent_card || {});
  const tours = normalizeTours(data);

  // extractAgent already scheme-checks the photo (safeUrl) and refuses an
  // email-looking name. og:image must be absolute for scrapers, so resolve a
  // root-relative photo against the first tour's share URL (else rendprop.com).
  const shareBase = tours.map((t) => t.share_url || "").find((u) => !!u) || "";
  const photo = agent.photo;
  const ogPhoto = absolutize(photo, shareBase);

  // The org name is never an email (decision A14); the org.name fallback is
  // only used when it is a real business name.
  const orgName = data.org?.name && !looksLikeEmail(data.org.name) ? String(data.org.name).trim() : "";
  const name = agent.name || agent.company || orgName || "Portfolio";

  const avatar = photo
    ? `<div class="avatar"><img src="${escapeAttr(photo)}" alt="${escapeAttr(name)}" loading="lazy" decoding="async"></div>`
    : `<div class="avatar">${escapeHtml(agent.initials)}</div>`;

  const socials = agent.socials
    .map((s) => `<a href="${escapeAttr(s.url)}" target="_blank" rel="noopener nofollow">${escapeHtml(s.label)}</a>`)
    .join("");
  const emailLink = agent.email ? `<a href="mailto:${escapeAttr(agent.email)}">Email</a>` : "";
  const socialRow = socials || emailLink ? `<div class="psocial">${socials}${emailLink}</div>` : "";

  const company = agent.company && agent.company !== name ? agent.company : "";
  const accentOverride = agent.accent ? `<style>:root{--accent:${agent.accent};}</style>` : "";
  const title = `${name}${company ? " · " + company : ""} — Rendprop`;
  const desc = `${name}${company ? " at " + company : ""} — ${tours.length} tour${tours.length === 1 ? "" : "s"} on Rendprop.`;

  const grid = tours.length
    ? `<div class="grid">${tours.map(renderCard).join("")}</div>`
    : `<div class="empty">No published tours yet.</div>`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0b0d10">
<title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeAttr(desc)}">
<meta property="og:title" content="${escapeAttr(name)}">
<meta property="og:description" content="${escapeAttr(desc)}">
<meta property="og:type" content="profile">
<meta name="twitter:card" content="summary">
${ogPhoto ? `<meta property="og:image" content="${escapeAttr(ogPhoto)}">` : ""}
${accentOverride}
<style>${PORTFOLIO_CSS}</style>
</head>
<body>
  <div class="wrap">
    <div class="brandmark">RENDPROP</div>
    <header class="phead">
      ${avatar}
      <div>
        <div class="pname">${escapeHtml(name)}</div>
        ${agent.title ? `<div class="pcompany">${escapeHtml(agent.title)}</div>` : ""}
        ${company ? `<div class="pcompany">${escapeHtml(company)}</div>` : ""}
        ${agent.handle ? `<div class="phandle">@${escapeHtml(agent.handle)}</div>` : ""}
      </div>
    </header>
    ${socialRow}
    ${grid}
    <div class="foot">Made with <a href="https://rendprop.com" target="_blank" rel="noopener">Rendprop</a></div>
  </div>
</body>
</html>`;
}
