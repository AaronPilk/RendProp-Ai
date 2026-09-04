// player.ts — renders a published tour (the JSON from GET /tours/:slug) into a
// full, self-contained scroll-scrub player page.
//
// CANONICAL ENGINE: the scroll-scrub engine in ENGINE_JS below (rAF lerp,
// buffer gate, chapter rail, room label, decaying jank watchdog + autoplay
// fallback, explicit "video unavailable" state) is the production engine. The
// iOS in-app preview (apps/ios/Rendprop/Resources/player/index.html) carries a
// copy of the same tick()/watchdog logic; apps/web/player is an archived
// prototype. When the engine changes, change it HERE first and port to iOS.
//
// VIDEO SOURCE CONTRACT (must match services/supabase/functions/tours/index.ts):
// `scrub_url` — the all-intra R2 mp4 over HTTP byte-range — is the PRIMARY
// source: every frame is a keyframe, so currentTime seeks are frame-accurate
// and the scroll-scrub stays buttery. `hls_url` (Cloudflare Stream) is a
// FALLBACK ONLY — Stream re-encodes away the all-intra GOP and snaps seeks to
// keyframes, which kills the scrub feel. So: hls.js (lazy, cdnjs) or native
// Safari HLS is attached only when there is no scrub_url, or if the mp4 errors
// out before playback starts. Both origins are zero-egress.
//
// If neither source can deliver metadata (missing R2 object, expired link) the
// page shows an explicit "This tour's video isn't available right now" state —
// never a black stage with a bobbing scroll hint — and reports NO view.
//
// CHAPTER TIMEBASE: chapter t_ms is already rescaled to the RENDERED timeline
// by the app before publish (RendpropApp.swift divides by speed_factor). The
// player must therefore use t_ms/1000 against duration_s directly and must NOT
// divide by speed_factor again.

import type { Cta, SecondaryLink, Tour } from "./types";
import {
  type AgentModel,
  absolutize,
  escapeAttr,
  escapeHtml,
  extractAgent,
  first,
  humanize,
  isHlsUrl,
  jsonForScript,
  safeUrl,
  spaceLabel,
  TOKENS_CSS,
} from "./html";

// Pinned hls.js (cdnjs) + Subresource Integrity hash for the 1.5.20 min bundle.
const HLS_SRC = "https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.20/hls.min.js";
const HLS_SRI = "sha384-V5ruNBgmYcC3SJRUQeNykAAAgde5gOFq/Hu0CZj7bygDP0yRIhkvX8+w0u/7mRvr";

// ---------------------------------------------------------------------------
// Listing state helpers (sold / archived, price, counts)
// ---------------------------------------------------------------------------

function isRealEstate(tour: Tour): boolean {
  return (tour.space_type || "real_estate") === "real_estate";
}

/** Non-null when the owner marked the listing sold (RE) / archived (others). */
function soldAt(tour: Tour): string {
  return first(tour.sold_at, tour.listing?.sold_at);
}

function listingStatus(tour: Tour): string {
  return first(tour.status, tour.listing?.status).toLowerCase();
}

/** SOLD (real estate) / Archived (every other type). */
function isSoldOrArchived(tour: Tour): boolean {
  if (tour.sold === true || tour.archived === true) return true;
  if (soldAt(tour)) return true;
  const s = listingStatus(tour);
  return s === "archived" || s === "sold";
}

function archiveLabel(tour: Tour): string {
  return isRealEstate(tour) ? "Sold" : "Archived";
}

/** Positive number → true. The app sends 0 for "unknown" beds/baths/sqft. */
function pos(n: number | null | undefined): n is number {
  return typeof n === "number" && Number.isFinite(n) && n > 0;
}

/** The display price, or "" when the listing has no price (0 / null). */
function priceText(tour: Tour): string {
  const l = tour.listing;
  if (l.price_cents != null) {
    if (!pos(l.price_cents)) return "";
    return l.price || usd(Number(l.price_cents) / 100);
  }
  const p = first(l.price);
  return /^\$?0(\.0+)?$/.test(p) ? "" : p;
}

function fmtInt(n: number): string {
  return new Intl.NumberFormat("en-US").format(n);
}

function usd(n: number): string {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 }).format(n);
}

/** Owner-entered money ("3500", "$3,500", "49.99") → "$3,500"; anything else verbatim. */
function money(raw: string): string {
  const s = String(raw || "").trim();
  if (!s) return "";
  const m = /^\$?\s*([\d,]+(?:\.\d+)?)$/.exec(s);
  if (!m) return s;
  const n = Number(m[1].replace(/,/g, ""));
  return Number.isFinite(n) ? new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: n % 1 ? 2 : 0 }).format(n) : s;
}

function telHref(phone: string): string {
  const d = phone.replace(/[^\d+]/g, "");
  return "tel:" + d;
}

// ---------------------------------------------------------------------------
// Agent card (extractAgent lives in html.ts; shared with the portfolio page)
// ---------------------------------------------------------------------------

function renderAgentCard(a: AgentModel, tour: Tour): string {
  const isRE = isRealEstate(tour);
  // "Your agent" is a real-estate concept. A business card falls back to the
  // business itself (brand company, else the listing's business name) and
  // simply omits the name line when there is nothing publishable.
  const name = a.name || (isRE ? "Your agent" : (a.company || first(tour.listing.address)));
  const avatarAlt = name || (isRE ? "Agent" : "Business");
  const avatar = a.photo
    ? `<div class="avatar photo"><img src="${escapeAttr(a.photo)}" alt="${escapeAttr(avatarAlt)}" loading="lazy" decoding="async"></div>`
    : `<div class="avatar">${escapeHtml(a.initials)}</div>`;

  const subBits: string[] = [];
  if (a.title) subBits.push(escapeHtml(a.title));
  // Don't repeat the company when it is already the headline.
  if (a.company && a.company !== name) subBits.push(escapeHtml(a.company));
  if (a.phone) subBits.push(`<a href="${escapeAttr(telHref(a.phone))}">${escapeHtml(a.phone)}</a>`);
  const sub = subBits.length ? `<div class="bk">${subBits.join(" · ")}</div>` : "";

  const socialLinks = a.socials
    .map((s) => `<a href="${escapeAttr(s.url)}" target="_blank" rel="noopener nofollow">${escapeHtml(s.label)}</a>`)
    .join("");
  const emailLink = a.email
    ? `<a href="mailto:${escapeAttr(a.email)}">Email</a>`
    : "";
  const social = socialLinks || emailLink
    ? `<div class="social">${socialLinks}${emailLink}</div>`
    : "";

  return `<div class="agent">
      ${avatar}
      <div class="who">
        ${name ? `<div class="nm">${escapeHtml(name)}</div>` : ""}
        ${sub}
        ${social}
      </div>
    </div>`;
}

// ---------------------------------------------------------------------------
// Listing header (top-right chip) + page/OG metadata
// ---------------------------------------------------------------------------

interface HeaderModel {
  pageTitle: string;
  ogTitle: string;
  ogDesc: string;
  chipHtml: string;
}

function buildHeader(tour: Tour): HeaderModel {
  const l = tour.listing;
  const sold = isSoldOrArchived(tour);
  const pill = sold ? `<div class="soldpill">${escapeHtml(archiveLabel(tour))}</div>` : "";

  if (isRealEstate(tour)) {
    const bits: string[] = [];
    if (pos(l.beds)) bits.push(`${l.beds} bd`);
    if (pos(l.baths)) bits.push(`${String(l.baths)} ba`);
    if (pos(l.sqft)) bits.push(`${fmtInt(l.sqft)} sqft`);
    const price = priceText(tour);

    const primary = price
      ? `<div class="price">${escapeHtml(price)}</div>`
      : l.address
        ? `<div class="price">${escapeHtml(l.address)}</div>`
        : "";
    const lines: string[] = [];
    if (bits.length) lines.push(bits.join(" · "));
    if (price && l.address) lines.push(l.address);

    const titleText = l.address || "Property tour";
    const ogDesc = (sold ? "Sold. " : "") + "Scroll to fly through this home." +
      (bits.length ? " " + bits.join(" · ") : "") +
      (price ? " · " + price : "");
    return {
      pageTitle: `${titleText}${sold ? " (Sold)" : ""} — Rendprop`,
      ogTitle: titleText + (sold ? " — Sold" : price ? " — " + price : ""),
      ogDesc,
      chipHtml: `${pill}${primary}${lines.map((x) => `<div class="meta">${escapeHtml(x)}</div>`).join("")}`,
    };
  }

  // Every other space type: `address` holds the BUSINESS NAME — that is the
  // title; the tagline is the meta line (audit F-H-13).
  const title = l.address || l.tagline || spaceLabel(tour.space_type);
  const lines: string[] = [];
  if (l.tagline && l.address) lines.push(l.tagline);
  const ogDesc = l.tagline || `Take a cinematic scroll-through tour of this ${spaceLabel(tour.space_type).toLowerCase()}.`;
  return {
    pageTitle: `${title} — Rendprop`,
    ogTitle: title,
    ogDesc: sold ? `${archiveLabel(tour)}. ${ogDesc}` : ogDesc,
    chipHtml: `${pill}<div class="price">${escapeHtml(title)}</div>${lines.map((x) => `<div class="meta">${escapeHtml(x)}</div>`).join("")}`,
  };
}

// ---------------------------------------------------------------------------
// CTA / lead form
// ---------------------------------------------------------------------------

const FIELD_REG: Record<string, { label: string; type: "text" | "date" | "time" | "number" | "textarea" }> = {
  preferred_date: { label: "Preferred showing date", type: "date" },
  event_date: { label: "Event date", type: "date" },
  guest_count: { label: "Guest count", type: "number" },
  event_type: { label: "Event type", type: "text" },
  party_size: { label: "Party size", type: "number" },
  date: { label: "Preferred date", type: "date" },
  time: { label: "Preferred time", type: "time" },
  occasion: { label: "Occasion", type: "text" },
  notes: { label: "Notes", type: "textarea" },
  fitness_goal: { label: "Your fitness goal", type: "text" },
  preferred_time: { label: "Preferred time", type: "text" },
  interested_class: { label: "Class you're interested in", type: "text" },
  message: { label: "Message", type: "textarea" },
};

const OPTIONAL_TAG = ' <span class="opt">(optional)</span>';

/** Extra (per-industry) field — always optional, always with a real <label>. */
function renderField(key: string, labelOverride?: string): string {
  const f = FIELD_REG[key] || { label: humanize(key), type: "text" as const };
  const nm = escapeAttr(key);
  const id = `lf_${nm}`;
  const label = `<label class="lbl" for="${id}">${escapeHtml(labelOverride || f.label)}${OPTIONAL_TAG}</label>`;
  if (f.type === "textarea") {
    return `<div class="field">${label}<textarea id="${id}" name="${nm}" rows="3" maxlength="1000"></textarea></div>`;
  }
  const extra = f.type === "number" ? ' min="1" inputmode="numeric"' : f.type === "text" ? ' maxlength="200"' : "";
  return `<div class="field">${label}<input id="${id}" type="${f.type}" name="${nm}"${extra}></div>`;
}

/** Core contact field with a real <label>, an inline error slot, and the same
 *  length caps the leads function applies (name 120, email 200, phone 40). */
function textInput(type: "text" | "tel" | "email", name: string, label: string, required: boolean, autocomplete: string): string {
  const nm = escapeAttr(name);
  const id = `lf_${nm}`;
  const max = type === "email" ? 200 : type === "tel" ? 40 : 120;
  const mode = type === "tel" ? ' inputmode="tel"' : type === "email" ? ' inputmode="email"' : "";
  return `<div class="field">
        <label class="lbl" for="${id}">${escapeHtml(label)}${required ? "" : OPTIONAL_TAG}</label>
        <input id="${id}" type="${type}" name="${nm}"${required ? " required" : ""} autocomplete="${escapeAttr(autocomplete)}" maxlength="${max}"${mode}>
        <div class="err" data-err="${nm}" role="alert"></div>
      </div>`;
}

function renderSecondary(links: SecondaryLink[]): string {
  if (!links || !links.length) return "";
  const safe = links
    .map((s) => ({ label: s.label, url: safeUrl(s.url, ["tel", "mailto"]) }))
    .filter((s) => s.url && s.label);
  if (!safe.length) return "";
  return `<div class="secondary">${safe
    .map((s) => `<a class="slink" href="${escapeAttr(s.url)}" target="_blank" rel="noopener nofollow">${escapeHtml(s.label)}</a>`)
    .join("")}</div>`;
}

function formSub(tour: Tour): string {
  const addr = tour.listing.address;
  switch (tour.space_type) {
    case "real_estate": return `See ${addr || "this home"} in person — the agent will follow up with times.`;
    case "venue": return "Tell us about your event and we'll follow up with availability.";
    case "restaurant": return "Request a table and we'll confirm shortly.";
    case "fitness": return "Leave your details and we'll get you set up.";
    case "retail": return "Get deals and updates in your inbox.";
    default: return "Leave your details and we'll be in touch.";
  }
}

function deeplinkCopy(tour: Tour): { headline: string; sub: string } {
  switch (tour.space_type) {
    case "restaurant": return { headline: "Reserve your table", sub: "Book directly with the restaurant." };
    case "venue": return { headline: "Plan your event", sub: "Check availability and start planning." };
    case "retail": return { headline: "Shop the collection", sub: "Browse and buy online." };
    case "fitness": return { headline: "Ready to start?", sub: "Book your first session." };
    case "other": return { headline: "Get in touch", sub: "Reach out directly." };
    default: return { headline: tour.cta.label, sub: "" };
  }
}

interface FormCopy { heading: string; sub: string; button: string; ok: string; }

/** Heading / sub / button / confirmation for the four form flavours. The
 *  confirmation only promises what the system does: the lead is stored in the
 *  owner's Leads inbox in the app (decision A13) — no "expect a text" claims. */
function formCopy(tour: Tour, opts: { emailOnly: boolean; secondary: boolean; sold: boolean }): FormCopy {
  const cta = tour.cta;
  if (opts.sold && isRealEstate(tour)) {
    return {
      heading: "Ask about similar homes",
      sub: "This home has sold. Tell the agent what you're looking for and they'll follow up with similar listings.",
      button: "Send my request",
      ok: "Thanks — your request is with the agent.",
    };
  }
  if (opts.emailOnly) {
    return {
      heading: "Get deals and updates",
      sub: "Occasional specials and news from the store — no spam.",
      button: "Sign me up",
      ok: "You're on the list.",
    };
  }
  if (opts.secondary) {
    return {
      heading: "Leave your details",
      sub: formSub(tour),
      button: "Send",
      ok: "Thanks — your details are with the team.",
    };
  }
  return {
    heading: cta.label,
    sub: formSub(tour),
    button: cta.label,
    ok: isRealEstate(tour) ? "Thanks — your request is with the agent." : "Thanks — your request is with the team.",
  };
}

interface LeadFormOpts {
  /** Rendered underneath a deep-link button ("Or leave your details"). */
  secondary?: boolean;
  /** After a successful submit, the page offers (and tries to open) this URL —
   *  the "form → then hand off" flow for booking/reservation links. */
  handoffUrl?: string;
  handoffLabel?: string;
}

function renderLeadForm(tour: Tour, turnstileSiteKey = "", opts: LeadFormOpts = {}): string {
  const cta: Cta = tour.cta;
  const sold = isSoldOrArchived(tour) && isRealEstate(tour);
  const fields = sold ? ["message"] : (cta.lead_fields || []);
  const emailOnly = !sold && fields.length === 1 && fields[0] === "email";
  const copy = formCopy(tour, { emailOnly, secondary: !!opts.secondary, sold });

  // Turnstile widget (bot protection). Rendered only when a site key is
  // configured; the implicit widget injects a `cf-turnstile-response` field the
  // submit handler forwards to /leads as `turnstile_token`.
  const turnstile = turnstileSiteKey
    ? `<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
       <div class="cf-turnstile" data-sitekey="${escapeAttr(turnstileSiteKey)}" data-theme="auto" data-size="flexible"></div>`
    : "";

  const base = emailOnly
    ? textInput("email", "email", "Email address", true, "email")
    : textInput("text", "name", "Your name", true, "name") +
      textInput("tel", "phone", "Phone", true, "tel") +
      textInput("email", "email", "Email", false, "email");

  const extras = fields
    .filter((k) => k !== "name" && k !== "phone" && k !== "email")
    .map((k) => renderField(k, sold && k === "message" ? "What are you looking for?" : undefined))
    .join("");

  const handoff = opts.handoffUrl
    ? `<a class="cta cta-link" href="${escapeAttr(opts.handoffUrl)}" target="_blank" rel="noopener nofollow">${escapeHtml(opts.handoffLabel || "Continue")}</a>`
    : "";

  return `<form id="leadform" ${opts.secondary ? 'class="secondary-form" ' : ""}aria-describedby="leadmsg">
      <h2>${escapeHtml(copy.heading)}</h2>
      <p class="sub">${escapeHtml(copy.sub)}</p>
      ${base}
      ${extras}
      <input class="hp" type="text" name="_hp" tabindex="-1" autocomplete="off" aria-hidden="true">
      ${turnstile}
      <div id="leadmsg" class="formmsg" role="alert" aria-live="polite"></div>
      <button class="cta" type="submit">${escapeHtml(copy.button)}</button>
      <p class="privacy">By sending, you agree that your details are shared with the ${isRealEstate(tour) ? "agent" : "business"} and stored by Rendprop and its CRM provider. <a href="/privacy" target="_blank" rel="noopener">Privacy</a></p>
    </form>
    ${renderSecondary(cta.secondary)}
    <div id="leadok">
      <div class="check">✓</div>
      <h2>Request sent</h2>
      <p>${escapeHtml(copy.ok)}</p>
      ${handoff}
    </div>`;
}

interface CtaBlock { html: string; handoffUrl: string; }

function renderCtaBlock(tour: Tour, turnstileSiteKey = ""): CtaBlock {
  const cta = tour.cta;
  const sold = isSoldOrArchived(tour) && isRealEstate(tour);
  // Scheme-allowlist the publisher-supplied deeplink (audit P1: javascript:
  // URLs would execute on click). An unsafe URL falls back to the lead form.
  const deeplink = cta.mode === "deeplink" && !sold ? safeUrl(cta.url, ["tel", "mailto"]) : "";
  if (deeplink) {
    const copy = deeplinkCopy(tour);
    const fields = cta.lead_fields || [];
    const emailOnly = fields.length === 1 && fields[0] === "email";
    // Deep-link CTAs still capture the lead when the industry asks for it
    // (docs/INDUSTRY-LOGIC.md: "form → then hand off"). The retail promo opt-in
    // is a plain sign-up, so it never hands off to the shop.
    const withForm = fields.length > 0;
    const handoffUrl = withForm && !emailOnly ? deeplink : "";
    const form = withForm
      ? renderLeadForm(tour, turnstileSiteKey, { secondary: true, handoffUrl, handoffLabel: handoffUrl ? cta.label : "" })
      : renderSecondary(cta.secondary);
    return {
      handoffUrl,
      html: `<h2>${escapeHtml(copy.headline)}</h2>
      ${copy.sub ? `<p class="sub">${escapeHtml(copy.sub)}</p>` : ""}
      <a class="cta cta-link" href="${escapeAttr(deeplink)}" target="_blank" rel="noopener nofollow">${escapeHtml(cta.label)}</a>
      ${withForm ? '<div class="or"><span>or</span></div>' : ""}
      ${form}`,
    };
  }
  // Fitness free-trial flow: the tours function returns mode "lead_form" with
  // the booking system as a "Book now" secondary link — capture the lead, then
  // hand off (docs/INDUSTRY-LOGIC.md "form → then open bookingUrl").
  let handoffUrl = "";
  if (tour.space_type === "fitness" && !sold) {
    const book = (cta.secondary || []).find((s) => /book/i.test(s.label || "") && safeUrl(s.url));
    if (book) handoffUrl = safeUrl(book.url);
  }
  return { html: renderLeadForm(tour, turnstileSiteKey, handoffUrl ? { handoffUrl, handoffLabel: "Book now" } : {}), handoffUrl };
}

// ---------------------------------------------------------------------------
// Page CSS — ported from player/index.html, plus additions for the dynamic
// agent card / deep-link CTA / form fields / staged disclosure sheet.
// ---------------------------------------------------------------------------

const PLAYER_CSS = `${TOKENS_CSS}
  /* ===== Track & sticky stage ===== */
  #track { position: relative; }
  #stage { position: sticky; top: 0; height: 100vh; height: 100svh; overflow: hidden; background: #000; }
  #scrub { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; pointer-events: none; }

  /* ===== Loader ===== */
  #loader { position: absolute; inset: 0; z-index: 30; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px; background: var(--bg); transition: opacity .5s ease; }
  #loader.done { opacity: 0; pointer-events: none; }
  #loader .mark { font-size: 13px; letter-spacing: .35em; color: var(--ink-dim); text-transform: uppercase; }
  #loader .pct { font-size: 34px; font-weight: 600; font-variant-numeric: tabular-nums; }
  #loader .bar { width: 140px; height: 2px; background: rgba(255,255,255,.12); border-radius: 2px; overflow: hidden; }
  #loader .bar i { display: block; height: 100%; width: 0%; background: var(--accent); transition: width .2s ease; }

  /* ===== Unavailable state (dead / missing video) ===== */
  #unavail { position: absolute; inset: 0; z-index: 31; display: none; flex-direction: column; align-items: center; justify-content: center; gap: 10px; padding: 32px 24px; text-align: center; background: var(--bg); }
  #unavail.on { display: flex; }
  #unavail .mark { font-size: 13px; letter-spacing: .35em; color: var(--ink-dim); text-transform: uppercase; margin-bottom: 8px; }
  #unavail h2 { font-size: 20px; font-weight: 650; letter-spacing: -.01em; max-width: 22em; }
  #unavail p { font-size: 14px; color: var(--ink-dim); max-width: 30em; line-height: 1.5; }
  #unavail .cta-sm { width: auto; padding: 11px 20px; margin-top: 8px; font-size: 14px; }

  /* ===== Progress ===== */
  #progress { position: absolute; top: 0; left: 0; right: 0; height: 3px; z-index: 20; background: rgba(255,255,255,.10); }
  #progress i { display: block; height: 100%; background: var(--accent); transform-origin: 0 50%; transform: scaleX(0); will-change: transform; }

  /* ===== Overlay chrome ===== */
  .chrome { position: absolute; z-index: 10; }
  #brand { top: calc(14px + env(safe-area-inset-top)); left: 16px; font-size: 12px; letter-spacing: .3em; text-transform: uppercase; color: var(--ink); text-shadow: 0 1px 8px rgba(0,0,0,.6); }
  #hint { left: 50%; bottom: calc(34px + env(safe-area-inset-bottom)); transform: translateX(-50%); display: flex; flex-direction: column; align-items: center; gap: 6px; font-size: 13px; color: var(--ink); text-shadow: 0 1px 8px rgba(0,0,0,.7); transition: opacity .6s ease; animation: bob 2.2s ease-in-out infinite; }
  #hint.gone { opacity: 0; }
  @keyframes bob { 0%,100% { transform: translateX(-50%) translateY(0); } 50% { transform: translateX(-50%) translateY(7px); } }
  #hint svg { opacity: .9; }

  /* Room label */
  #room { left: 16px; bottom: calc(96px + env(safe-area-inset-bottom)); opacity: 0; will-change: transform, opacity; }
  #room .kicker { font-size: 11px; letter-spacing: .28em; text-transform: uppercase; color: var(--accent); margin-bottom: 4px; }
  #room .name { font-size: 30px; font-weight: 650; letter-spacing: -.01em; text-shadow: 0 2px 14px rgba(0,0,0,.65); }

  /* Chapter rail */
  #rail { right: 10px; top: 50%; transform: translateY(-50%); display: flex; flex-direction: column; gap: 14px; align-items: flex-end; }
  #rail button { appearance: none; border: 0; background: none; cursor: pointer; display: flex; align-items: center; gap: 8px; padding: 4px; color: var(--ink-dim); font-size: 11px; font-family: inherit; }
  #rail button .dot { width: 7px; height: 7px; border-radius: 50%; background: rgba(255,255,255,.35); transition: all .25s ease; }
  #rail button .lbl { opacity: 0; transition: opacity .25s ease; text-shadow: 0 1px 6px rgba(0,0,0,.7); }
  #rail button.active .dot { background: var(--accent); box-shadow: 0 0 10px var(--accent); }
  #rail button.active .lbl { opacity: 1; color: var(--ink); }

  /* Listing chip */
  #listing { top: calc(12px + env(safe-area-inset-top)); right: 16px; text-align: right; text-shadow: 0 1px 8px rgba(0,0,0,.6); max-width: 62vw; }
  #listing .price { font-size: 16px; font-weight: 650; }
  #listing .meta { font-size: 11.5px; color: var(--ink-dim); margin-top: 2px; }
  #listing .soldpill { display: inline-block; font-size: 10.5px; font-weight: 700; letter-spacing: .18em; text-transform: uppercase; padding: 3px 9px; border-radius: 999px; background: var(--accent); color: #fff; text-shadow: none; margin-bottom: 6px; }

  /* Watermark */
  #wm { left: 16px; bottom: calc(14px + env(safe-area-inset-bottom)); font-size: 10.5px; color: rgba(255,255,255,.45); letter-spacing: .06em; text-decoration: none; }
  #wm b { color: rgba(255,255,255,.72); font-weight: 600; }

  /* Virtual-staging disclosure (MLS compliance) */
  #staged { right: 16px; bottom: calc(14px + env(safe-area-inset-bottom)); display: none; align-items: center; gap: 5px; font-size: 10.5px; color: rgba(255,255,255,.65); letter-spacing: .04em; padding: 5px 10px; border: 1px solid rgba(255,255,255,.18); border-radius: 999px; background: rgba(11,13,16,.45); backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px); cursor: pointer; }
  #staged.on { display: flex; }
  #stageddisc { right: 16px; bottom: calc(50px + env(safe-area-inset-bottom)); max-width: min(78vw, 320px); display: none; font-size: 11.5px; line-height: 1.45; color: var(--ink-dim); padding: 12px 14px; border: 1px solid rgba(255,255,255,.12); border-radius: 12px; background: rgba(11,13,16,.86); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); }
  #stageddisc.on { display: block; }

  /* ===== End card: agent + CTA/lead form ===== */
  #endcard { position: relative; z-index: 5; min-height: 100vh; min-height: 100svh; display: flex; align-items: center; justify-content: center; padding: 48px 20px calc(64px + env(safe-area-inset-bottom)); background: linear-gradient(180deg, rgba(11,13,16,0) 0%, var(--bg) 18%); }
  .panel { width: 100%; max-width: 420px; background: var(--card); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); border: 1px solid rgba(255,255,255,.08); border-radius: var(--radius); padding: 26px 22px; }
  .agent { display: flex; align-items: center; gap: 14px; margin-bottom: 20px; }
  .agent .avatar { width: 52px; height: 52px; border-radius: 50%; background: linear-gradient(135deg, #33404f, #1c242e); display: flex; align-items: center; justify-content: center; font-weight: 650; font-size: 18px; color: var(--accent); overflow: hidden; flex: 0 0 auto; }
  .agent .avatar.photo { background: none; }
  .agent .avatar img { width: 100%; height: 100%; object-fit: cover; }
  .agent .who .nm { font-weight: 650; font-size: 16px; }
  .agent .who .bk { font-size: 12.5px; color: var(--ink-dim); margin-top: 2px; }
  .agent .who .bk a { color: var(--ink-dim); text-decoration: none; }
  .agent .social { display: flex; flex-wrap: wrap; gap: 14px; margin-top: 6px; }
  .agent .social:empty { display: none; }
  .agent .social a { color: var(--accent); font-size: 12.5px; font-weight: 600; text-decoration: none; }
  .panel h2 { font-size: 21px; font-weight: 650; letter-spacing: -.01em; margin-bottom: 4px; }
  .panel .sub { font-size: 13.5px; color: var(--ink-dim); margin-bottom: 18px; }
  .field { margin-bottom: 12px; }
  .field .lbl { display: block; font-size: 11px; letter-spacing: .06em; text-transform: uppercase; color: var(--ink-dim); margin: 0 0 6px 2px; }
  .field .lbl .opt { text-transform: none; letter-spacing: 0; opacity: .8; }
  .field input, .field textarea { width: 100%; padding: 13px 14px; border-radius: 10px; border: 1px solid rgba(255,255,255,.12); background: rgba(255,255,255,.05); color: var(--ink); font-size: 15px; font-family: inherit; outline: none; }
  .field textarea { resize: vertical; min-height: 76px; }
  .field input:focus, .field textarea:focus { border-color: var(--accent); }
  .field input[aria-invalid="true"], .field textarea[aria-invalid="true"] { border-color: #ff7a7a; }
  .field .err { display: none; font-size: 12px; color: #ff9b9b; margin: 6px 0 0 2px; line-height: 1.4; }
  .field .err.on { display: block; }
  .formmsg { display: none; font-size: 13px; line-height: 1.45; color: #ffb4b4; background: rgba(255,90,90,.12); border: 1px solid rgba(255,120,120,.3); border-radius: 10px; padding: 10px 12px; margin: 4px 0 12px; }
  .formmsg.on { display: block; }
  .privacy { font-size: 11px; line-height: 1.5; color: rgba(242,243,245,.5); margin-top: 12px; }
  .privacy a { color: rgba(242,243,245,.7); }
  .hp { position: absolute !important; left: -9999px !important; width: 1px; height: 1px; opacity: 0; pointer-events: none; }
  .cta { width: 100%; padding: 15px; border: 0; border-radius: 12px; cursor: pointer; background: var(--accent); color: #14100a; font-size: 15.5px; font-weight: 650; font-family: inherit; margin-top: 4px; }
  .cta:active { transform: scale(.985); }
  .cta:disabled { opacity: .6; cursor: default; }
  .cta-link { display: block; text-align: center; text-decoration: none; }
  .or { display: flex; align-items: center; gap: 12px; margin: 22px 0 18px; color: var(--ink-dim); font-size: 12px; letter-spacing: .12em; text-transform: uppercase; }
  .or::before, .or::after { content: ""; flex: 1; height: 1px; background: rgba(255,255,255,.1); }
  .secondary-form h2 { font-size: 17px; }
  .secondary { display: flex; flex-wrap: wrap; gap: 16px; justify-content: center; margin-top: 16px; }
  .secondary .slink { color: var(--accent); font-size: 13px; font-weight: 600; text-decoration: none; }
  .disclosure { margin-top: 18px; padding-top: 16px; border-top: 1px solid rgba(255,255,255,.08); font-size: 11px; line-height: 1.5; color: rgba(242,243,245,.5); }
  #leadok { display: none; text-align: center; padding: 26px 0 10px; }
  #leadok .check { font-size: 40px; margin-bottom: 10px; color: var(--accent); }
  #leadok p { color: var(--ink-dim); font-size: 14px; }
  #leadok .cta-link { margin-top: 18px; }

  @media (prefers-reduced-motion: reduce) { #hint { animation: none; } }
`;

// ---------------------------------------------------------------------------
// Client engine — ported scrub loop, adapted for HLS/Stream + R2 mp4 and wired
// to the live /beacon and /leads endpoints. Authored WITHOUT template literals
// or `${` so it can be embedded inside the outer template literal untouched.
// NOTE: this string IS a template literal, so backslashes are processed once —
// regex escapes below are written doubled (\\d, \\s) on purpose.
// ---------------------------------------------------------------------------

const ENGINE_JS = `
(function(){
  'use strict';
  var CFG = window.__CFG__ || {};
  var track  = document.getElementById('track');
  var video  = document.getElementById('scrub');
  var loader = document.getElementById('loader');
  var pctEl  = loader ? loader.querySelector('.pct') : null;
  var barEl  = loader ? loader.querySelector('.bar i') : null;
  var progEl = document.querySelector('#progress i');
  var roomEl = document.getElementById('room');
  var roomNm = roomEl ? roomEl.querySelector('.name') : null;
  var railEl = document.getElementById('rail');
  var hintEl = document.getElementById('hint');
  var unavailEl = document.getElementById('unavail');

  var CH  = Array.isArray(CFG.chapters) ? CFG.chapters : [];
  var HAS_CH = CH.length > 0;
  var PX_PER_SEC  = CFG.pxPerSec || 240;
  var BUFFER_GATE = CFG.bufferGate || 0.96;
  var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var LERP = reduce ? 0.08 : 0.14;

  function clamp(v,a,b){ return Math.min(b, Math.max(a, v)); }

  /* ---- State ---- */
  var curT = 0, lastSet = -1, started = false, interacted = false, unavailable = false, fellBack = false;
  var longFrames = 0, lastTick = performance.now();
  var usingHls = false, triedHlsFallback = false, hlsJs = null;
  var pollBuf = null;

  /* ---- Track sizing (100svh-safe, toolbar-resize-safe) ---- */
  var duration = Number(CFG.durationS) || 0;
  function sizeTrack(){
    if (!track) return;
    if (unavailable){ track.style.height = ''; return; }
    if (!duration) return;
    track.style.height = Math.round(duration * PX_PER_SEC + innerHeight) + 'px';
  }
  addEventListener('resize', sizeTrack, { passive: true });
  if (window.visualViewport) visualViewport.addEventListener('resize', sizeTrack, { passive: true });
  // Size from the server-known duration right away: loadedmetadata never fires
  // on a dead source, and a 0-height track made the scroll math NaN.
  sizeTrack();

  /* ---- Chapter rail (buttons are server-rendered) ---- */
  var railBtns = railEl ? Array.prototype.slice.call(railEl.querySelectorAll('button')) : [];
  for (var r = 0; r < railBtns.length; r++){
    (function(btn){
      btn.addEventListener('click', function(){
        var t = parseFloat(btn.getAttribute('data-t')) || 0;
        // Clamp: a chapter tagged past the video's end must not scroll the
        // viewer straight past the track into the microsite.
        var p = duration ? clamp(t / duration, 0, 1) : 0;
        scrollTo({ top: p * Math.max(0, track.offsetHeight - innerHeight), behavior: 'smooth' });
      });
    })(railBtns[r]);
  }

  /* ---- Overlays ---- */
  function updateOverlays(p){
    if (progEl) progEl.style.transform = 'scaleX(' + p + ')';
    if (!HAS_CH || !roomEl) return; // empty chapters must never kill the rAF loop
    var t = p * duration, active = 0, best = 1e9;
    for (var i = 0; i < CH.length; i++){
      var d = Math.abs(t - (CH[i].t + 2.5));
      if (t >= CH[i].t - 0.5 && d < best){ best = d; active = i; }
    }
    var c = CH[active];
    var dNorm = clamp(1 - Math.abs(t - (c.t + 2.0)) / 4.5, 0, 1);
    if (roomNm && roomNm.textContent !== c.label) roomNm.textContent = c.label;
    roomEl.style.opacity = dNorm;
    roomEl.style.transform = 'translateY(' + ((1 - dNorm) * 14) + 'px)';
    for (var j = 0; j < railBtns.length; j++) railBtns[j].classList.toggle('active', j === active);
  }

  /* ---- Core scrub loop ---- */
  function tick(now){
    // Jank watchdog → fallback ladder (ported from the iOS engine). Only
    // SUSTAINED jank trips it: gaps over ~1s are suspensions (app switch,
    // webview paused offscreen in the outer scroll, rAF throttled in a
    // background tab), not jank, and smooth frames pay the counter back down —
    // so the embedded 460pt Home card can't drift into autoplay over a session.
    var gap = now - lastTick;
    lastTick = now;
    if (gap > 90){ if (gap < 1000 && ++longFrames > 24) return fallbackLoop(); }
    else if (longFrames > 0) longFrames--;

    var total = Math.max(1, track.offsetHeight - innerHeight); // duration=0 → no NaN/-Infinity
    var p = clamp(-track.getBoundingClientRect().top / total, 0, 1);
    var target = p * Math.max(0, (duration || video.duration || 0) - 0.05);
    curT += (target - curT) * LERP;
    // readyState 0 = no metadata yet → seeking is meaningless (and throws on old WebKit).
    if (video.readyState > 0 &&
        Math.abs(video.currentTime - curT) > 0.016 && Math.abs(curT - lastSet) > 0.016){
      try { video.currentTime = curT; lastSet = curT; } catch (e) {}
    }
    updateOverlays(p);
    meter(p, now);
    if (!viewSent && video.readyState >= 2) reportViewAndDelivery();
    requestAnimationFrame(tick);
  }

  function begin(){
    if (started || unavailable) return;
    started = true;
    if (loader) loader.classList.add('done');
    lastTick = performance.now();
    requestAnimationFrame(tick);
  }

  /* ---- Unavailable: the video can't be delivered. Say so; count nothing. ---- */
  function showUnavailable(){
    if (started || unavailable) return;
    unavailable = true;
    if (pollBuf) clearInterval(pollBuf);
    if (loader) loader.classList.add('done');
    if (hintEl) hintEl.classList.add('gone');
    if (roomEl) roomEl.style.opacity = 0;
    if (progEl) progEl.style.transform = 'scaleX(0)';
    if (unavailEl) unavailEl.classList.add('on');
    sizeTrack(); // collapse the scrub track to one viewport → straight to the card
  }
  var retryBtn = document.getElementById('unavail-retry');
  if (retryBtn) retryBtn.addEventListener('click', function(){ location.reload(); });

  /* ---- Buffer gate + % loader ---- */
  function buffered(){
    try { return video.buffered.length ? video.buffered.end(video.buffered.length - 1) : 0; }
    catch (e) { return 0; }
  }
  function reportBuffer(){
    if (unavailable) return;
    var dur = duration || video.duration;
    if (!dur || !isFinite(dur)) return;
    var f = clamp(buffered() / dur, 0, 1);
    var pc = Math.round(f * 100);
    if (pctEl) pctEl.textContent = pc + '%';
    if (barEl) barEl.style.width = pc + '%';
    if (f >= BUFFER_GATE) begin();
  }
  video.addEventListener('progress', reportBuffer);
  video.addEventListener('loadedmetadata', function(){
    var vd = video.duration;
    if (isFinite(vd) && vd > 0 && (!duration || Math.abs(duration - vd) > 0.5)) duration = vd;
    sizeTrack(); reportBuffer();
  });
  video.addEventListener('canplaythrough', function(){ setTimeout(begin, 1200); });
  video.addEventListener('loadeddata', function(){ if (usingHls) setTimeout(begin, 700); });
  pollBuf = setInterval(function(){ reportBuffer(); if (started || unavailable) clearInterval(pollBuf); }, 250);
  setTimeout(function(){ if (!started && !unavailable && buffered() > 3) begin(); }, 6000);
  // Last resort at 12s. Metadata present → start anyway (partial buffer is
  // fine). No metadata → the source is dead (error/no-source) or crawling: a
  // dead one is declared unavailable now, a crawling one gets 12 more seconds.
  function lastResort(final){
    if (started || unavailable) return;
    if (video.readyState > 0){ begin(); return; }
    var dead = !!video.error || video.networkState === 3 || video.networkState === 0;
    if (dead || final){ showUnavailable(); return; }
    setTimeout(function(){ lastResort(true); }, 12000);
  }
  setTimeout(function(){ lastResort(false); }, 12000);

  /* ---- Fallback: autoplay loop (Low Power Mode / webview jank) ---- */
  function fallbackLoop(){
    if (fellBack) return; fellBack = true;
    if (loader) loader.classList.add('done');
    video.loop = true;
    var pr = video.play(); if (pr && pr.catch) pr.catch(function(){});
    (function loopTick(now){
      var p = video.duration ? video.currentTime / video.duration : 0;
      updateOverlays(p);
      meter(p, now || performance.now()); // keep watch_ms flowing after fallback
      if (!viewSent && video.readyState >= 2) reportViewAndDelivery();
      requestAnimationFrame(loopTick);
    })(performance.now());
  }

  /* ---- Scrub hint ---- */
  function dismissHint(){ if (interacted) return; interacted = true; if (hintEl) hintEl.classList.add('gone'); }
  addEventListener('scroll', dismissHint, { passive: true, once: true });
  addEventListener('touchstart', dismissHint, { passive: true, once: true });

  /* ---- Metering beacon (batched; view + streamed-minutes once the video has
     actually delivered frames, then watch_ms deltas) ---- */
  var maxDepth = 0, engagedMs = 0, lastMeter = 0, sentWatchMs = 0, viewSent = false;
  function meter(p, now){
    if (p > maxDepth) maxDepth = p;
    if (lastMeter) engagedMs += Math.min(now - lastMeter, 100);
    lastMeter = now;
  }
  function beaconUrl(){
    var u = CFG.functionsBase + '/beacon/' + encodeURIComponent(CFG.slug);
    if (CFG.anonKey) u += (u.indexOf('?') > -1 ? '&' : '?') + 'apikey=' + encodeURIComponent(CFG.anonKey);
    return u;
  }
  function sendBody(body){
    var s = JSON.stringify(body);
    var url = beaconUrl();
    try {
      if (navigator.sendBeacon){
        // text/plain keeps it a CORS-simple request (no preflight) so it fires
        // reliably during pagehide; the function parses the body as JSON anyway.
        if (navigator.sendBeacon(url, new Blob([s], { type: 'text/plain;charset=UTF-8' }))) return;
      }
    } catch (e) {}
    try { fetch(url, { method: 'POST', body: s, headers: { 'Content-Type': 'text/plain' }, keepalive: true, mode: 'cors', credentials: 'omit' }).catch(function(){}); } catch (e) {}
  }
  function postBeacon(extra){
    if (!CFG.functionsBase || !CFG.slug) return;
    var delta = Math.max(0, Math.round(engagedMs - sentWatchMs));
    sentWatchMs = engagedMs;
    var body = { watch_ms: delta, scroll_depth: Math.round(maxDepth * 1000) / 1000, streamed_minutes: 0 };
    if (extra){ for (var k in extra) body[k] = extra[k]; }
    sendBody(body);
  }
  function reportViewAndDelivery(){
    if (viewSent || unavailable) return; viewSent = true;
    var mins = Number(CFG.durationS) ? Math.round((CFG.durationS / 60) * 1000) / 1000 : 0;
    postBeacon({ view_start: true, streamed_minutes: mins });
  }
  setInterval(function(){ if (document.visibilityState === 'visible' && viewSent) postBeacon(null); }, 20000);
  addEventListener('pagehide', function(){ if (viewSent) postBeacon(null); });
  document.addEventListener('visibilitychange', function(){ if (document.hidden && viewSent) postBeacon(null); });

  /* ---- Lead form: client validation mirrors services/supabase/functions/leads
     (name ≤120, phone /^[+()\\d\\s.-]{7,40}$/, email /^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/),
     inline errors, the server's own error message on failure. ---- */
  var EMAIL_RE = /^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/;
  var PHONE_RE = /^[+()\\d\\s.-]{7,40}$/;
  var leadHeaders = { 'Content-Type': 'application/json' };
  if (CFG.anonKey){ leadHeaders['apikey'] = CFG.anonKey; leadHeaders['Authorization'] = 'Bearer ' + CFG.anonKey; }
  var form = document.getElementById('leadform');
  var msgEl = document.getElementById('leadmsg');
  function fieldEl(name){ return form ? form.querySelector('[name="' + name + '"]') : null; }
  function setErr(name, msg){
    if (!form) return;
    var el = form.querySelector('[data-err="' + name + '"]');
    var input = fieldEl(name);
    if (el){ el.textContent = msg || ''; el.classList.toggle('on', !!msg); }
    if (input){ if (msg) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid'); }
  }
  function showMsg(msg){ if (!msgEl) return; msgEl.textContent = msg || ''; msgEl.classList.toggle('on', !!msg); }
  function validate(fd){
    var ok = true, firstBad = null;
    function bad(name, msg){ ok = false; setErr(name, msg); if (!firstBad) firstBad = fieldEl(name); }
    var nameIn = fieldEl('name'), phoneIn = fieldEl('phone'), emailIn = fieldEl('email');
    var name = String(fd.get('name') || '').trim();
    var phone = String(fd.get('phone') || '').trim();
    var email = String(fd.get('email') || '').trim();
    setErr('name'); setErr('phone'); setErr('email');
    if (nameIn && !name) bad('name', 'Please enter your name.');
    else if (name.length > 120) bad('name', 'That name is too long (120 characters max).');
    if (phoneIn && phoneIn.hasAttribute('required') && !phone) bad('phone', 'Please enter a phone number.');
    else if (phone && !PHONE_RE.test(phone)) bad('phone', 'Enter a valid phone number: 7 to 40 digits, spaces, or + ( ) . - only.');
    if (emailIn && emailIn.hasAttribute('required') && !email) bad('email', 'Please enter your email address.');
    else if (email && !EMAIL_RE.test(email)) bad('email', 'Please check the email address (name@example.com).');
    if (firstBad){ try { firstBad.focus(); } catch (e) {} }
    return ok;
  }
  function resetTurnstile(){
    try { if (window.turnstile && window.turnstile.reset) window.turnstile.reset(); } catch (e) {}
  }
  if (form){
    form.addEventListener('submit', function(e){
      e.preventDefault();
      showMsg('');
      var fd = new FormData(form);
      if (!validate(fd)) return;
      var top = { slug: CFG.slug, extra: {} };
      fd.forEach(function(v, k){
        if (typeof v !== 'string') return;
        var s = v.trim();
        if (k === 'name' || k === 'phone' || k === 'email'){ if (s) top[k] = s; }
        else if (k === '_hp'){ top._hp = v; }
        else if (k === 'cf-turnstile-response'){ if (s) top.turnstile_token = s; }
        else if (s) top.extra[k] = s.slice(0, 1000);
      });
      var btn = form.querySelector('button[type=submit]');
      var orig = btn ? btn.textContent : '';
      if (btn){ btn.disabled = true; btn.textContent = 'Sending...'; }
      fetch(CFG.functionsBase + '/leads', { method: 'POST', headers: leadHeaders, body: JSON.stringify(top), mode: 'cors', credentials: 'omit' })
        .then(function(res){
          return res.json().catch(function(){ return {}; }).then(function(body){
            if (!res.ok){
              var err = new Error(body && typeof body.error === 'string' ? body.error : '');
              err.status = res.status;
              throw err;
            }
            return body;
          });
        })
        .then(function(){
          form.style.display = 'none';
          var ok = document.getElementById('leadok');
          if (ok) ok.style.display = 'block';
          // Deep-link industries: the lead is captured, now hand the viewer to
          // the booking system. Browsers may block a post-fetch popup — the
          // confirmation card carries the same link as a button.
          if (CFG.handoffUrl){ try { window.open(CFG.handoffUrl, '_blank', 'noopener'); } catch (e2) {} }
        })
        .catch(function(err){
          if (btn){ btn.disabled = false; btn.textContent = orig || 'Try again'; }
          resetTurnstile(); // a consumed Turnstile token can't be re-sent
          var st = err && err.status;
          var msg = err && err.message ? err.message : '';
          if (st === 429) msg = 'Too many requests from your network — please wait a minute and try again.';
          else if (!msg) msg = st ? 'Could not send right now (error ' + st + '). Please try again.' : 'Could not send right now. Check your connection and try again.';
          showMsg(msg);
        });
    });
  }

  /* ---- Staged disclosure toggle ---- */
  var chip = document.getElementById('staged');
  var disc = document.getElementById('stageddisc');
  if (chip && disc){
    chip.addEventListener('click', function(){ disc.classList.toggle('on'); });
    chip.addEventListener('keydown', function(ev){ if (ev.key === 'Enter' || ev.key === ' '){ ev.preventDefault(); disc.classList.toggle('on'); } });
  }

  /* ---- Video source: all-intra scrub mp4 (PRIMARY, frame-accurate byte-range
     scrubbing) with HLS strictly as fallback (no scrub source, or the mp4
     errors before playback starts — HLS seeks snap to keyframes). ---- */
  function directSrc(url){ try { video.src = url; video.load(); } catch (e) {} }
  function giveUpHls(hls, url){
    try { hls.destroy(); } catch (e) {}
    hlsJs = null;
    // Native attempt is the very last try; if that errors too, the error
    // listener below declares the video unavailable.
    directSrc(url);
  }
  function loadHls(url){
    function attach(){
      if (window.Hls && window.Hls.isSupported()){
        var hls = new window.Hls({
          maxBufferLength: 600, maxMaxBufferLength: 600, backBufferLength: 600,
          maxBufferSize: 300 * 1000 * 1000, capLevelToPlayerSize: true,
          lowLatencyMode: false, enableWorker: true, startFragPrefetch: true
        });
        hlsJs = hls;
        hls.on(window.Hls.Events.ERROR, function(evt, data){
          if (!data || !data.fatal) return;
          if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR){ try { hls.startLoad(); } catch (e) { giveUpHls(hls, url); } }
          else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR){ try { hls.recoverMediaError(); } catch (e) { giveUpHls(hls, url); } }
          else { giveUpHls(hls, url); }
        });
        hls.on(window.Hls.Events.FRAG_BUFFERED, function(){ reportBuffer(); });
        hls.loadSource(url);
        hls.attachMedia(video);
      } else {
        directSrc(url);
      }
    }
    if (window.Hls){ attach(); return; }
    var s = document.createElement('script');
    s.src = CFG.hlsSrc;
    if (CFG.hlsSri){ s.integrity = CFG.hlsSri; s.crossOrigin = 'anonymous'; }
    s.onload = attach;
    s.onerror = function(){ directSrc(url); };
    document.head.appendChild(s);
  }
  function startHls(url){
    usingHls = true;
    var canNative = video.canPlayType('application/vnd.apple.mpegurl') || video.canPlayType('application/x-mpegURL');
    if (canNative){ directSrc(url); } else { loadHls(url); }
  }
  video.addEventListener('error', function(){
    if (started || fellBack || unavailable) return;
    // The scrub mp4 failed before we started (missing R2 object, codec, CDN
    // hiccup) — degrade to HLS once rather than showing a dead loader.
    if (!usingHls && CFG.hlsUrl && !triedHlsFallback){ triedHlsFallback = true; startHls(CFG.hlsUrl); return; }
    if (hlsJs) return; // hls.js owns recovery while it is attached
    showUnavailable();  // no fallback left: say so instead of a black stage
  });
  function setupVideo(){
    if (!CFG.scrubUrl && !CFG.hlsUrl){ if (pctEl) pctEl.textContent = '--'; showUnavailable(); return; }
    video.muted = true; video.playsInline = true;
    video.setAttribute('playsinline', ''); video.setAttribute('webkit-playsinline', '');
    if (CFG.scrubUrl){ directSrc(CFG.scrubUrl); }
    else { startHls(CFG.hlsUrl); }
  }
  setupVideo();
})();
`;

// ===========================================================================
// Listing microsite — the full editorial page rendered BELOW the flythrough.
// Everything is driven by the listing's own data (core fields + the freeform
// `details` JSON bag + chapters). Every section hides when its data is absent,
// so a bare listing renders clean and a rich one becomes a full website. No
// schema changes: `details` already flows through GET /tours/:slug untouched.
//
// Two dialects live in `details`:
//   • non-real-estate listings: the camelCase keys the iOS app collects per
//     SpaceType (Listing.swift `detailFields`) — rendered by the industry
//     section below (venue / restaurant / retail / fitness / other);
//   • the demo (and any future editorial editor): snake_case story / gallery /
//     features / floorplan / neighborhood / reel_url — rendered by the RE-style
//     editorial sections.
// ===========================================================================

// House promo — SINGLE SOURCE OF TRUTH. Buyer-facing, tasteful. Edit here.
interface PromoItem { name: string; tagline: string; url: string; }
const PROMO: { mortgage: PromoItem; agency: PromoItem; partner: PromoItem } = {
  mortgage: {
    name: "Wholesale Mortgage Lending",
    tagline: "Get pre-approved fast with our in-house lending team.",
    url: "https://wsmlending.com/",
  },
  agency: {
    name: "Pilk.ai",
    tagline: "Custom sites, apps, and AI marketing systems for modern brands.",
    url: "https://pilk.ai/",
  },
  partner: {
    name: "Tract",
    tagline: "The all-in-one real estate platform we built.",
    url: "https://tractrealestate.com/",
  },
};

// --- details readers (defensive: the bag is freeform jsonb) ---
function det(tour: Tour, ...keys: string[]): unknown {
  const d = (tour.listing.details || {}) as Record<string, unknown>;
  for (const k of keys) if (d[k] != null && d[k] !== "") return d[k];
  return undefined;
}
function detStr(tour: Tour, ...keys: string[]): string {
  return first(det(tour, ...keys));
}
function toLines(v: unknown): string[] {
  if (Array.isArray(v)) return v.map((x) => first(x)).filter(Boolean);
  const s = first(v);
  return s ? s.split(/\r?\n/).map((x) => x.trim()).filter(Boolean) : [];
}
function paragraphs(v: unknown): string[] {
  const s = first(v);
  return s ? s.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean) : [];
}
/** iOS multiSelect values arrive as "A, B, C" — split them into chips. */
function csv(v: unknown): string[] {
  if (Array.isArray(v)) return v.map((x) => first(x)).filter(Boolean);
  const s = first(v);
  return s ? s.split(",").map((x) => x.trim()).filter(Boolean) : [];
}
function isTrue(v: unknown): boolean {
  if (typeof v === "boolean") return v;
  const s = first(v).toLowerCase();
  return s === "true" || s === "1" || s === "yes" || s === "on";
}

function overviewTiles(tour: Tour): Array<{ v: string; k: string }> {
  const l = tour.listing;
  const tiles: Array<{ v: string; k: string }> = [];
  if (!isRealEstate(tour)) return tiles; // beds/baths/sqft are meaningless for a venue or a gym
  if (pos(l.beds)) tiles.push({ v: String(l.beds), k: "Beds" });
  if (pos(l.baths)) tiles.push({ v: String(l.baths), k: "Baths" });
  if (pos(l.sqft)) tiles.push({ v: fmtInt(l.sqft), k: "Sq Ft" });
  const extra: Array<[string, string]> = [
    ["Acres", detStr(tour, "acres", "lot_acres")],
    ["Lot", detStr(tour, "lot", "lot_size")],
    ["Year built", detStr(tour, "year_built", "year")],
    ["Garage", detStr(tour, "garage", "parking")],
    ["Frontage", detStr(tour, "frontage", "water_frontage")],
    ["HOA", detStr(tour, "hoa")],
  ];
  for (const [k, v] of extra) if (v) tiles.push({ v, k });
  return tiles;
}

function galleryItems(tour: Tour): Array<{ url: string; label: string }> {
  const g = det(tour, "gallery", "photos");
  const out: Array<{ url: string; label: string }> = [];
  if (Array.isArray(g)) {
    for (const it of g) {
      if (typeof it === "string") { const u = safeUrl(it); if (u) out.push({ url: u, label: "" }); }
      else if (it && typeof it === "object") {
        const o = it as Record<string, unknown>;
        const url = safeUrl(first(o.url, o.src, o.image));
        if (url) out.push({ url, label: first(o.label, o.caption, o.name) });
      }
    }
  }
  return out;
}

function featureGroups(tour: Tour): Array<{ title: string; items: string[] }> {
  const f = det(tour, "features", "finishes");
  const groups: Array<{ title: string; items: string[] }> = [];
  if (Array.isArray(f)) {
    const items = f.map((x) => first(x)).filter(Boolean);
    if (items.length) groups.push({ title: "Highlights", items });
  } else if (f && typeof f === "object") {
    for (const [title, val] of Object.entries(f as Record<string, unknown>)) {
      const items = toLines(val);
      if (items.length) groups.push({ title: humanize(title), items });
    }
  }
  return groups;
}

function floorLevels(tour: Tour): Array<{ name: string; sqft: string; blurb: string }> {
  const fp = det(tour, "floorplan", "floor_plan");
  const levels = fp && typeof fp === "object" ? (fp as Record<string, unknown>).levels : undefined;
  const out: Array<{ name: string; sqft: string; blurb: string }> = [];
  if (Array.isArray(levels)) {
    for (const lv of levels) {
      const o = (lv || {}) as Record<string, unknown>;
      const name = first(o.name, o.level);
      if (name) out.push({ name, sqft: first(o.sqft, o.area), blurb: first(o.blurb, o.description) });
    }
  }
  return out;
}
function floorImage(tour: Tour): string {
  const fp = det(tour, "floorplan", "floor_plan");
  const o = fp && typeof fp === "object" ? (fp as Record<string, unknown>) : {};
  return safeUrl(first(detStr(tour, "floorplan_url", "floor_plan_url"), o.image_url, o.image));
}

function commuteItems(tour: Tour): Array<{ time: string; label: string }> {
  const n = det(tour, "neighborhood", "location");
  let arr: unknown = det(tour, "commute");
  if (!arr && n && typeof n === "object") arr = (n as Record<string, unknown>).commute;
  const out: Array<{ time: string; label: string }> = [];
  if (Array.isArray(arr)) {
    for (const it of arr) {
      const o = (it || {}) as Record<string, unknown>;
      const time = first(o.time, o.minutes);
      const label = first(o.label, o.place, o.name);
      if (time || label) out.push({ time, label });
    }
  }
  return out;
}
function neighborhoodBlurb(tour: Tour): string {
  const n = det(tour, "neighborhood", "location");
  if (typeof n === "string") return n;
  if (n && typeof n === "object") return first((n as Record<string, unknown>).blurb, (n as Record<string, unknown>).description, (n as Record<string, unknown>).text);
  return "";
}

/** Rough monthly P&I for the financing block (illustrative only). */
function monthlyEstimate(priceCents: number | null | undefined): number | null {
  if (!pos(priceCents)) return null;
  const price = Number(priceCents) / 100;
  const down = 0.2, r = 0.065 / 12, n = 360;
  const loan = price * (1 - down);
  const m = (loan * r * Math.pow(1 + r, n)) / (Math.pow(1 + r, n) - 1);
  return Number.isFinite(m) ? Math.round(m) : null;
}

function sec(id: string, eyebrow: string, title: string, inner: string): string {
  return `<section class="lp-sec" id="${id}"><div class="lp-wrap">
    <div class="lp-eyebrow">${escapeHtml(eyebrow)}</div>
    <h2 class="lp-h">${escapeHtml(title)}</h2>
    ${inner}
  </div></section>`;
}

/** Vertical social reel — shows only when a reel_url is set on the listing
 *  (details.reel_url). Tap-to-play so it never fights the scroll-scrub hero
 *  for autoplay/bandwidth. */
function reelSection(tour: Tour): string {
  const reel = safeUrl(detStr(tour, "reel_url", "reel"));
  if (!reel) return "";
  const poster = safeUrl(detStr(tour, "reel_poster", "reel_thumb"));
  return `<section class="lp-sec" id="reel"><div class="lp-wrap">
    <div class="lp-eyebrow">Social reel</div>
    <h2 class="lp-h">The vertical cut, ready to post</h2>
    <p class="lp-tag">Made from this listing — drop it straight onto Reels, TikTok, or Shorts.</p>
    <div class="lp-reel-wrap"><div class="lp-phone">
      <video class="lp-reelvid" src="${escapeAttr(reel)}"${poster ? ` poster="${escapeAttr(poster)}"` : ""} controls playsinline preload="none" loop></video>
    </div></div>
  </div></section>`;
}

// --- Per-industry details (the camelCase bag the iOS app collects) ---------

interface Fact { k: string; v: string; href?: string; }
interface ChipGroup { title: string; items: string[]; }
interface Button { label: string; url: string; ghost?: boolean; }
interface IndustryBlock { title: string; banner: string; facts: Fact[]; chips: ChipGroup[]; buttons: Button[]; }

function directionsUrl(tour: Tour): string {
  const l = tour.listing;
  if (typeof l.lat === "number" && typeof l.lng === "number" && Number.isFinite(l.lat) && Number.isFinite(l.lng)) {
    return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${l.lat},${l.lng}`)}`;
  }
  const q = first(l.address);
  return q ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(q)}` : "";
}

/** Owner-entered URL → https:// form, scheme-checked. "" when unusable. */
function detUrl(tour: Tour, key: string): string {
  const raw = detStr(tour, key);
  if (!raw) return "";
  const withScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw) ? raw : `https://${raw}`;
  return safeUrl(withScheme);
}

function hoursText(tour: Tour): string {
  return toLines(det(tour, "hours")).join(" · ");
}

function industryBlock(tour: Tour): IndustryBlock | null {
  const type = tour.space_type;
  const facts: Fact[] = [];
  const chips: ChipGroup[] = [];
  const buttons: Button[] = [];
  let banner = "";
  let title = "Good to know";

  const phone = detStr(tour, "phone");
  const hours = hoursText(tour);
  const amenities = csv(det(tour, "amenities"));
  const dir = directionsUrl(tour);

  switch (type) {
    case "venue": {
      title = "Plan it here";
      const from = money(detStr(tour, "startingPrice"));
      if (from) facts.push({ k: "Starting price", v: `From ${from}` });
      const seated = detStr(tour, "capacitySeated");
      const standing = detStr(tour, "capacityStanding");
      const cap = [seated ? `Seats ${seated}` : "", standing ? `${standing} standing` : ""].filter(Boolean).join(" · ");
      if (cap) facts.push({ k: "Capacity", v: cap });
      const setting = detStr(tour, "spaceSetting");
      if (setting) facts.push({ k: "Setting", v: setting });
      const catering = detStr(tour, "catering");
      if (catering) facts.push({ k: "Catering", v: catering });
      const events = csv(det(tour, "eventTypes"));
      if (events.length) chips.push({ title: "Event types", items: events });
      if (amenities.length) chips.push({ title: "Amenities", items: amenities });
      const booking = detUrl(tour, "bookingUrl");
      if (booking) buttons.push({ label: "Check availability", url: booking });
      break;
    }
    case "restaurant": {
      title = "Come hungry";
      const cuisine = csv(det(tour, "cuisineType"));
      const range = detStr(tour, "priceRange");
      const line = [...cuisine, range].filter(Boolean).join(" · ");
      if (line) facts.push({ k: "Cuisine", v: line });
      if (hours) facts.push({ k: "Hours", v: hours });
      if (phone) facts.push({ k: "Phone", v: phone, href: telHref(phone) });
      if (amenities.length) chips.push({ title: "Features", items: amenities });
      const res = detUrl(tour, "reservationUrl");
      if (res) buttons.push({ label: "Reserve a table", url: res });
      const menu = detUrl(tour, "menuUrl");
      if (menu) buttons.push({ label: "View menu", url: menu, ghost: true });
      break;
    }
    case "retail": {
      title = "Shop with us";
      const special = detStr(tour, "weeklySpecial");
      if (special) banner = `This week: ${special}`;
      const cat = detStr(tour, "storeCategory");
      if (cat) facts.push({ k: "Store type", v: cat });
      if (hours) facts.push({ k: "Hours", v: hours });
      if (phone) facts.push({ k: "Phone", v: phone, href: telHref(phone) });
      const options = csv(det(tour, "shoppingOptions"));
      if (options.length) chips.push({ title: "How to shop", items: options });
      const depts = csv(det(tour, "departments"));
      if (depts.length) chips.push({ title: "Departments", items: depts });
      const shop = detUrl(tour, "onlineStoreUrl");
      if (shop) buttons.push({ label: "Shop online", url: shop });
      break;
    }
    case "fitness": {
      title = "Train here";
      const trial = detStr(tour, "freeTrialOffer");
      if (trial) banner = `Free trial: ${trial}`;
      const facility = detStr(tour, "facilityType");
      if (facility) facts.push({ k: "Facility", v: facility });
      const membership = money(detStr(tour, "membershipPrice"));
      if (membership) facts.push({ k: "Membership", v: `${membership}/mo` });
      const dayPass = money(detStr(tour, "dayPassPrice"));
      if (dayPass) facts.push({ k: "Day pass", v: dayPass });
      if (isTrue(det(tour, "is247"))) facts.push({ k: "Hours", v: "Open 24/7" });
      else if (hours) facts.push({ k: "Hours", v: hours });
      if (amenities.length) chips.push({ title: "Amenities", items: amenities });
      const booking = detUrl(tour, "bookingUrl");
      if (booking) buttons.push({ label: "Book a session", url: booking });
      break;
    }
    case "other": {
      if (hours) facts.push({ k: "Hours", v: hours });
      if (phone) facts.push({ k: "Phone", v: phone, href: telHref(phone) });
      const site = detUrl(tour, "website");
      if (site) buttons.push({ label: "Visit website", url: site });
      break;
    }
    default:
      return null;
  }

  if (phone && (type === "venue" || type === "fitness" || type === "other")) {
    // Venue/fitness/other collect no phone field today; if one is ever added it
    // renders the same way. (Restaurant/retail already list it as a fact.)
    if (!facts.some((f) => f.k === "Phone")) facts.push({ k: "Phone", v: phone, href: telHref(phone) });
  }
  if (dir) buttons.push({ label: "Get directions", url: dir, ghost: true });
  if (phone) buttons.push({ label: "Call", url: telHref(phone), ghost: true });

  if (!banner && !facts.length && !chips.length && !buttons.length) return null;
  return { title, banner, facts, chips, buttons };
}

function renderIndustrySection(tour: Tour): string {
  const b = industryBlock(tour);
  if (!b) return "";
  const banner = b.banner ? `<div class="lp-banner">${escapeHtml(b.banner)}</div>` : "";
  const facts = b.facts.length
    ? `<div class="lp-facts">${b.facts.map((f) => {
        const v = f.href ? `<a href="${escapeAttr(f.href)}">${escapeHtml(f.v)}</a>` : escapeHtml(f.v);
        return `<div class="lp-fact"><span class="k">${escapeHtml(f.k)}</span><span class="v">${v}</span></div>`;
      }).join("")}</div>`
    : "";
  const chips = b.chips.map((g) => `<div class="lp-chipgroup"><h3>${escapeHtml(g.title)}</h3><div class="lp-chips">${g.items.map((i) => `<span class="lp-chip">${escapeHtml(i)}</span>`).join("")}</div></div>`).join("");
  const buttons = b.buttons.length
    ? `<div class="lp-btnrow">${b.buttons.map((x) => `<a class="lp-btn${x.ghost ? " ghost" : ""}" href="${escapeAttr(x.url)}"${x.url.startsWith("tel:") ? "" : ' target="_blank" rel="noopener nofollow"'}>${escapeHtml(x.label)}</a>`).join("")}</div>`
    : "";
  return sec("details", "The details", b.title, `${banner}${facts}${chips}${buttons}`);
}

/** The full editorial page below the flythrough. */
function renderListingSections(tour: Tour): string {
  const l = tour.listing;
  const isRE = isRealEstate(tour);
  const sold = isSoldOrArchived(tour);
  const out: string[] = [];

  // Overview (always — built from core listing data).
  const tiles = overviewTiles(tour);
  const price = priceText(tour);
  const priceBig = price ? `<div class="lp-price">${escapeHtml(price)}</div>` : "";
  const headingRaw = l.address || l.tagline || spaceLabel(tour.space_type);
  const tagline = l.tagline && l.address ? `<p class="lp-tag">${escapeHtml(l.tagline)}</p>` : "";
  const soldNote = sold
    ? `<div class="lp-soldnote">${escapeHtml(isRE ? "This home has sold." : "This listing has been archived.")}</div>`
    : "";
  out.push(`<section class="lp-sec lp-lead" id="overview"><div class="lp-wrap">
    <div class="lp-eyebrow">${escapeHtml(isRE ? "The residence" : spaceLabel(tour.space_type))}${sold ? `<span class="lp-soldtag">${escapeHtml(archiveLabel(tour))}</span>` : ""}</div>
    <h2 class="lp-h">${escapeHtml(headingRaw)}</h2>
    ${priceBig}
    ${tagline}
    ${soldNote}
    ${tiles.length ? `<div class="lp-stats">${tiles.map((t) => `<div class="lp-stat"><span class="v">${escapeHtml(t.v)}</span><span class="k">${escapeHtml(t.k)}</span></div>`).join("")}</div>` : ""}
  </div></section>`);

  // Per-industry details (venue / restaurant / retail / fitness / other).
  if (!isRE) out.push(renderIndustrySection(tour));

  // Story.
  const story = paragraphs(det(tour, "story", "description", "about"));
  if (story.length) {
    out.push(sec("story", "The story", detStr(tour, "story_title") || (isRE ? "How this home lives" : "About the space"),
      `<div class="lp-prose">${story.map((p) => `<p>${escapeHtml(p)}</p>`).join("")}</div>`));
  }

  // Gallery — real images if provided, else the chapter list as a teaser.
  const imgs = galleryItems(tour);
  if (imgs.length) {
    out.push(sec("gallery", "Gallery", "A closer look",
      `<div class="lp-gal">${imgs.map((g) => `<figure class="lp-gcell"><img src="${escapeAttr(g.url)}" alt="${escapeAttr(g.label || headingRaw)}" loading="lazy" decoding="async">${g.label ? `<figcaption>${escapeHtml(g.label)}</figcaption>` : ""}</figure>`).join("")}</div>`));
  } else if (Array.isArray(tour.chapters) && tour.chapters.length) {
    out.push(sec("gallery", "Inside the tour", isRE ? "Every room, one scroll" : "Every area, one scroll",
      `<div class="lp-chips">${tour.chapters.map((c) => `<span class="lp-chip">${escapeHtml(c.label)}</span>`).join("")}</div>`));
  }

  // Social reel (vertical cut) — appears when a reel_url is set.
  out.push(reelSection(tour));

  // Features & finishes.
  const groups = featureGroups(tour);
  if (groups.length) {
    out.push(sec("features", "Features & finishes", "Built to a standard you can feel",
      `<div class="lp-feat">${groups.map((g) => `<div class="lp-fcol"><h3>${escapeHtml(g.title)}</h3><ul>${g.items.map((i) => `<li>${escapeHtml(i)}</li>`).join("")}</ul></div>`).join("")}</div>`));
  }

  // Floor plans.
  const levels = floorLevels(tour);
  const fpImg = floorImage(tour);
  if (levels.length || fpImg) {
    const lv = levels.length ? `<div class="lp-levels">${levels.map((x) => `<div class="lp-level"><div class="lp-lvhead"><span class="nm">${escapeHtml(x.name)}</span>${x.sqft ? `<span class="sf">${escapeHtml(x.sqft)}</span>` : ""}</div>${x.blurb ? `<p>${escapeHtml(x.blurb)}</p>` : ""}</div>`).join("")}</div>` : "";
    const im = fpImg ? `<div class="lp-fpimg"><img src="${escapeAttr(fpImg)}" alt="Floor plan" loading="lazy" decoding="async"></div>` : "";
    out.push(sec("floorplan", "Floor plans", "How it all fits together", lv + im));
  }

  // Neighborhood / commute.
  const nb = neighborhoodBlurb(tour);
  const commute = commuteItems(tour);
  if (nb || commute.length) {
    const c = commute.length ? `<div class="lp-commute">${commute.map((x) => `<div class="lp-cm"><span class="t">${escapeHtml(x.time)}</span><span class="l">${escapeHtml(x.label)}</span></div>`).join("")}</div>` : "";
    out.push(sec("location", "The location", detStr(tour, "neighborhood_title") || "The neighborhood",
      `${nb ? `<div class="lp-prose"><p>${escapeHtml(nb)}</p></div>` : ""}${c}`));
  }

  // Financing — powered by Wholesale Mortgage Lending. Real estate only, and
  // pointless once the home has sold.
  const est = isRE && !sold ? monthlyEstimate(l.price_cents) : null;
  if (est) {
    out.push(`<section class="lp-sec" id="financing"><div class="lp-wrap lp-fin">
      <div class="lp-eyebrow">Financing</div>
      <h2 class="lp-h">Estimated from ${escapeHtml(usd(est))}/mo</h2>
      <p class="lp-tag">Powered by ${escapeHtml(PROMO.mortgage.name)} — ${escapeHtml(PROMO.mortgage.tagline)}</p>
      <a class="lp-btn" href="${escapeAttr(PROMO.mortgage.url)}" target="_blank" rel="noopener nofollow">Get pre-approved</a>
      <p class="lp-fine">Illustrative only — 30-yr fixed at 6.5% with 20% down; taxes and insurance excluded. Not a commitment to lend.</p>
    </div></section>`);
  }

  return `<div id="listing-page">${out.join("")}</div>`;
}

/** Footer + house partner strip (Pilk.ai · Wholesale Mortgage · Tract). */
function renderFooter(): string {
  const cards = [PROMO.agency, PROMO.mortgage, PROMO.partner]
    .map((x) => `<a class="lp-partner" href="${escapeAttr(x.url)}" target="_blank" rel="noopener nofollow"><span class="nm">${escapeHtml(x.name)}</span><span class="tg">${escapeHtml(x.tagline)}</span></a>`)
    .join("");
  return `<footer class="lp-foot"><div class="lp-wrap">
    <div class="lp-eyebrow">More from us</div>
    <div class="lp-partners">${cards}</div>
    <div class="lp-madeby"><a href="https://rendprop.com" target="_blank" rel="noopener">Made with <b>Rendprop</b></a> · A <a href="${escapeAttr(PROMO.agency.url)}" target="_blank" rel="noopener">Pilk.ai</a> company</div>
    <div class="lp-legal"><a href="/terms">Terms</a> · <a href="/privacy">Privacy</a></div>
  </div></footer>`;
}

// Editorial CSS — Rendprop purple system layered over the player tokens. The
// :root override flips the player's default accent (gold) to brand purple; a
// per-agent accent override (injected after this) still wins when set.
const EDITORIAL_CSS = `
  :root {
    --accent:#9b6dff; --accent-2:#7c3aed; --accent-3:#c4a8ff;
    --accent-soft:rgba(155,109,255,.12);
    --faint:rgba(242,243,245,.42);
    --grad:linear-gradient(135deg,#9b6dff,#7c3aed);
    --grad-text:linear-gradient(115deg,#e9defc,#c4a8ff 55%,#9b6dff);
    --ease:cubic-bezier(0.23,1,0.32,1);
  }
  #listing-page { position: relative; z-index: 5; background: var(--bg); }
  .lp-wrap { max-width: 1080px; margin: 0 auto; padding: 0 22px; }
  .lp-sec { padding: clamp(54px,9vw,104px) 0; border-top: 1px solid rgba(255,255,255,.06); }
  .lp-lead { border-top: 0; background: linear-gradient(180deg, rgba(11,13,16,0), var(--bg) 14%); }
  .lp-eyebrow { display:flex; align-items:center; gap:8px; color:var(--accent-3);
    letter-spacing:.24em; text-transform:uppercase; font-size:12px; font-weight:700; margin-bottom:14px; }
  .lp-eyebrow::before { content:""; width:20px; height:2px; border-radius:2px;
    background:linear-gradient(90deg,var(--accent-2),var(--accent)); }
  .lp-soldtag { margin-left:6px; padding:3px 9px; border-radius:999px; background:var(--accent); color:#fff; font-size:10.5px; letter-spacing:.18em; }
  .lp-soldnote { margin-top:14px; font-size:15px; color:var(--ink-dim); }
  .lp-h { font-size:clamp(26px,4.4vw,44px); font-weight:800; letter-spacing:-.02em; line-height:1.08; }
  .lp-price { font-size:clamp(20px,3vw,28px); font-weight:800; margin-top:12px;
    background:var(--grad-text); -webkit-background-clip:text; background-clip:text; -webkit-text-fill-color:transparent; }
  .lp-tag { color:var(--ink-dim); margin-top:14px; font-size:16px; line-height:1.6; max-width:44em; }
  .lp-stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(88px,1fr)); gap:12px; margin-top:30px; }
  .lp-stat { background:var(--card); border:1px solid rgba(255,255,255,.07); border-radius:14px; padding:16px 12px; text-align:center; }
  .lp-stat .v { display:block; font-size:22px; font-weight:750; }
  .lp-stat .k { display:block; font-size:11px; letter-spacing:.12em; text-transform:uppercase; color:var(--ink-dim); margin-top:5px; }
  .lp-prose p { color:var(--ink-dim); font-size:17px; line-height:1.75; margin-top:14px; max-width:46em; }
  .lp-gal { display:grid; grid-template-columns:repeat(auto-fill,minmax(240px,1fr)); gap:12px; }
  .lp-gcell { position:relative; border-radius:16px; overflow:hidden; aspect-ratio:4/3; background:var(--card); border:1px solid rgba(255,255,255,.06); }
  .lp-gcell img { width:100%; height:100%; object-fit:cover; transition:transform .5s var(--ease); }
  .lp-gcell figcaption { position:absolute; left:0; right:0; bottom:0; padding:16px 14px 12px; font-size:13px; font-weight:600;
    background:linear-gradient(0deg, rgba(0,0,0,.62), transparent); }
  @media (hover:hover) and (pointer:fine) { .lp-gcell:hover img { transform:scale(1.04); } }
  .lp-chips { display:flex; flex-wrap:wrap; gap:10px; }
  .lp-chip { padding:9px 14px; border-radius:999px; background:var(--accent-soft);
    border:1px solid rgba(155,109,255,.24); color:var(--accent-3); font-size:13.5px; font-weight:600; }
  /* Per-industry details */
  .lp-banner { display:inline-block; margin:4px 0 22px; padding:12px 16px; border-radius:12px; font-weight:700; font-size:15px;
    color:#fff; background:linear-gradient(135deg,var(--accent),var(--accent-2)); box-shadow:0 10px 30px rgba(124,58,237,.3); }
  .lp-facts { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:12px; margin-top:6px; }
  .lp-fact { background:var(--card); border:1px solid rgba(255,255,255,.07); border-radius:14px; padding:14px 16px; }
  .lp-fact .k { display:block; font-size:11px; letter-spacing:.12em; text-transform:uppercase; color:var(--ink-dim); }
  .lp-fact .v { display:block; font-size:16px; font-weight:650; margin-top:5px; line-height:1.4; overflow-wrap:anywhere; }
  .lp-fact .v a { color:var(--ink); text-decoration:none; }
  .lp-chipgroup { margin-top:26px; }
  .lp-chipgroup h3 { font-size:12px; letter-spacing:.12em; text-transform:uppercase; color:var(--ink-dim); margin-bottom:12px; }
  .lp-btnrow { display:flex; flex-wrap:wrap; gap:12px; margin-top:8px; }
  .lp-btnrow .lp-btn { margin-top:18px; }
  .lp-btn.ghost { background:var(--accent-soft); color:var(--accent-3); box-shadow:none; border:1px solid rgba(155,109,255,.3); }
  .lp-feat { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:28px; }
  .lp-fcol h3 { font-size:15px; letter-spacing:.01em; margin-bottom:14px; }
  .lp-fcol ul { list-style:none; }
  .lp-fcol li { position:relative; padding-left:22px; color:var(--ink-dim); font-size:15px; line-height:1.5; margin-bottom:11px; }
  .lp-fcol li::before { content:""; position:absolute; left:2px; top:8px; width:7px; height:7px; border-radius:2px;
    background:linear-gradient(135deg,var(--accent),var(--accent-2)); }
  .lp-levels { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:14px; }
  .lp-level { background:var(--card); border:1px solid rgba(255,255,255,.07); border-radius:16px; padding:18px; }
  .lp-lvhead { display:flex; justify-content:space-between; align-items:baseline; gap:10px; }
  .lp-lvhead .nm { font-weight:700; font-size:16px; }
  .lp-lvhead .sf { color:var(--accent-3); font-size:13px; font-weight:600; }
  .lp-level p { color:var(--ink-dim); font-size:14px; line-height:1.5; margin-top:8px; }
  .lp-fpimg { margin-top:16px; border-radius:16px; overflow:hidden; border:1px solid rgba(255,255,255,.07); }
  .lp-commute { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-top:22px; }
  .lp-cm { background:var(--card); border:1px solid rgba(255,255,255,.07); border-radius:14px; padding:16px; }
  .lp-cm .t { display:block; font-size:20px; font-weight:750; color:var(--accent-3); }
  .lp-cm .l { display:block; font-size:13.5px; color:var(--ink-dim); margin-top:5px; line-height:1.4; }
  .lp-btn { display:inline-flex; align-items:center; justify-content:center; margin-top:22px; padding:14px 26px;
    border-radius:999px; font-weight:700; font-size:15.5px; text-decoration:none; color:#fff;
    background:linear-gradient(135deg,var(--accent),var(--accent-2)); box-shadow:0 10px 30px rgba(124,58,237,.35);
    transition:transform .2s var(--ease), box-shadow .3s var(--ease); }
  @media (hover:hover) and (pointer:fine) { .lp-btn:hover { transform:translateY(-2px); box-shadow:0 16px 40px rgba(124,58,237,.45); } }
  .lp-btn:active { transform:scale(.98); }
  .lp-fine { color:var(--faint); font-size:12px; line-height:1.5; margin-top:16px; max-width:44em; }
  /* Social reel — vertical phone frame */
  .lp-reel-wrap { display:flex; justify-content:center; margin-top:10px; }
  .lp-phone { width:min(300px,78vw); aspect-ratio:9/16; border-radius:30px; overflow:hidden;
    border:1px solid rgba(255,255,255,.12); background:#000; box-shadow:0 30px 80px rgba(0,0,0,.5); }
  .lp-reelvid { width:100%; height:100%; object-fit:cover; display:block; background:#000; }
  /* Endcard cohesion with the editorial flow + white CTA text on purple. */
  #endcard { background:var(--bg) !important; }
  .panel .cta, .cta { color:#fff !important; }
  /* Footer + partner strip */
  footer.lp-foot { padding:clamp(48px,7vw,80px) 0 calc(40px + env(safe-area-inset-bottom));
    border-top:1px solid rgba(255,255,255,.07); background:var(--bg); }
  .lp-partners { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px; }
  .lp-partner { display:flex; flex-direction:column; gap:6px; padding:18px; border-radius:16px;
    background:var(--card); border:1px solid rgba(255,255,255,.08); text-decoration:none;
    transition:border-color .25s var(--ease), transform .25s var(--ease); }
  .lp-partner .nm { font-weight:750; font-size:16px; color:var(--ink); }
  .lp-partner .tg { font-size:13.5px; color:var(--ink-dim); line-height:1.45; }
  @media (hover:hover) and (pointer:fine) { .lp-partner:hover { border-color:rgba(155,109,255,.42); transform:translateY(-2px); } }
  .lp-madeby { margin-top:26px; font-size:13px; color:var(--ink-dim); }
  .lp-madeby a { color:var(--ink-dim); text-decoration:none; }
  .lp-madeby b { color:var(--ink); }
  .lp-legal { margin-top:10px; font-size:12.5px; }
  .lp-legal a { color:var(--ink-dim); text-decoration:none; margin-right:12px; }
`;

// ---------------------------------------------------------------------------
// Full page
// ---------------------------------------------------------------------------

export interface RenderOpts { embed?: boolean; }

export function renderTourPage(tour: Tour, functionsBase: string, anonKey: string, turnstileSiteKey = "", opts: RenderOpts = {}): string {
  const agent = extractAgent(tour.agent_card || {});
  const header = buildHeader(tour);
  const poster = safeUrl(tour.poster || "");
  const staged = !!tour.staged;
  const chapters = Array.isArray(tour.chapters) ? tour.chapters : [];
  const hasChapters = chapters.length > 0;
  const embed = !!opts.embed;

  const accentOverride = agent.accent
    ? `<style>:root{--accent:${agent.accent};}</style>`
    : "";

  const railHtml = hasChapters
    ? `<div class="chrome" id="rail">${chapters
        .map((c, i) => `<button type="button" data-i="${i}" data-t="${c.t_ms / 1000}"><span class="lbl">${escapeHtml(c.label)}</span><span class="dot"></span></button>`)
        .join("")}</div>`
    : "";

  const roomHtml = hasChapters
    ? `<div class="chrome" id="room"><div class="kicker">Now entering</div><div class="name"></div></div>`
    : "";

  const stagedHtml = staged
    ? `<div class="chrome on" id="staged" role="button" tabindex="0" aria-label="Virtual staging disclosure">${escapeHtml(tour.disclosure_chip || "✦ Virtually staged")}</div>
       <div class="chrome" id="stageddisc">${escapeHtml(tour.staged_disclosure || "")}</div>`
    : "";

  const disclosurePanel = staged && tour.staged_disclosure
    ? `<p class="disclosure">${escapeHtml(tour.staged_disclosure)}</p>`
    : "";

  // Social scrapers need an ABSOLUTE og:image (the demo's poster is
  // root-relative). Resolve relative posters against the share URL's origin.
  const shareUrl = safeUrl(tour.share_url || "");
  const ogPoster = absolutize(poster, shareUrl);
  const ogImage = ogPoster ? `<meta property="og:image" content="${escapeAttr(ogPoster)}">\n<meta name="twitter:image" content="${escapeAttr(ogPoster)}">` : "";

  // Contract: scrub_url (all-intra R2 mp4) is the PRIMARY scrub source and
  // hls_url is fallback-only. Older payloads may only carry video_url
  // (= scrub_url ?? hls_url), so classify it by extension as a back-compat path.
  const scrubUrl = safeUrl(
    tour.scrub_url ??
    (tour.video_url && !isHlsUrl(tour.video_url) ? tour.video_url : null),
  );
  const hlsUrl = safeUrl(
    tour.hls_url ??
    (tour.video_url && isHlsUrl(tour.video_url) ? tour.video_url : null),
  );

  const ctaBlock = embed ? { html: "", handoffUrl: "" } : renderCtaBlock(tour, turnstileSiteKey);

  const cfg = {
    slug: tour.slug,
    functionsBase,
    anonKey: anonKey || "",
    scrubUrl,
    hlsUrl,
    durationS: tour.duration_s || 0,
    pxPerSec: 240,
    bufferGate: 0.96,
    hasChapters,
    staged,
    chapters: chapters.map((c) => ({ t: c.t_ms / 1000, label: c.label })),
    handoffUrl: ctaBlock.handoffUrl,
    hlsSrc: HLS_SRC,
    hlsSri: HLS_SRI,
  };

  // Embed mode (?embed=1): render ONLY the flythrough hero — for the in-app
  // "See it in action" card. Otherwise render the full listing microsite.
  const sectionsHtml = embed ? "" : renderListingSections(tour);
  const endcardHtml = embed ? "" : `<section id="endcard">
  <div class="panel">
    ${renderAgentCard(agent, tour)}
    ${ctaBlock.html}
    ${disclosurePanel}
  </div>
</section>`;
  const footerHtml = embed ? "" : renderFooter();

  const isRE = isRealEstate(tour);
  const unavailHtml = `<div id="unavail" role="status">
      <div class="mark">RENDPROP</div>
      <h2>This tour's video isn't available right now</h2>
      <p>${embed ? "Try again in a few minutes." : `The ${isRE ? "agent" : "owner"} may be re-publishing it. Try again in a few minutes${isRE ? " — or reach out below" : ""}.`}</p>
      <button type="button" id="unavail-retry" class="cta cta-sm">Try again</button>
    </div>`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0b0d10">
<title>${escapeHtml(header.pageTitle)}</title>
<meta name="description" content="${escapeAttr(header.ogDesc)}">
${embed ? `<meta name="robots" content="noindex">` : ""}
${shareUrl ? `<link rel="canonical" href="${escapeAttr(shareUrl)}">` : ""}
<meta property="og:title" content="${escapeAttr(header.ogTitle)}">
<meta property="og:description" content="${escapeAttr(header.ogDesc)}">
<meta property="og:type" content="website">
${shareUrl ? `<meta property="og:url" content="${escapeAttr(shareUrl)}">` : ""}
<meta name="twitter:card" content="summary_large_image">
${ogImage}
<style>${PLAYER_CSS}
${EDITORIAL_CSS}</style>
${accentOverride}
</head>
<body>

<div id="track">
  <div id="stage">
    <video id="scrub" muted playsinline webkit-playsinline preload="auto"
           disablepictureinpicture disableremoteplayback${poster ? ` poster="${escapeAttr(poster)}"` : ""}></video>

    <div id="loader">
      <div class="mark">RENDPROP</div>
      <div class="pct">0%</div>
      <div class="bar"><i></i></div>
    </div>

    ${unavailHtml}

    <div id="progress"><i></i></div>

    <div class="chrome" id="brand">RENDPROP</div>

    <div class="chrome" id="listing">${header.chipHtml}</div>

    ${roomHtml}

    ${railHtml}

    <div class="chrome" id="hint">
      <span>Scroll to fly through</span>
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 4v14m0 0l-6-6m6 6l6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
    </div>

    <a class="chrome" id="wm" href="https://rendprop.com" target="_blank" rel="noopener">Made with <b>Rendprop</b></a>

    ${stagedHtml}
  </div>
</div>

${sectionsHtml}
${endcardHtml}
${footerHtml}

<script>window.__CFG__=${jsonForScript(cfg)};</script>
<script>${ENGINE_JS}</script>
</body>
</html>`;
}
