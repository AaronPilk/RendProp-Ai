// player.ts — renders a published tour (the JSON from GET /tours/:slug) into a
// full, self-contained scroll-scrub player page.
//
// The scroll-scrub engine (rAF lerp, buffer gate, chapter rail, room label,
// jank watchdog + autoplay fallback) is ported from the iOS webview player at
// apps/ios/Rendprop/Resources/player/index.html. The only material change is the
// video source: instead of a bundled all-intra demo.mp4, the source is the
// tour's `video_url` — a Cloudflare Stream HLS manifest (.m3u8) or an R2 mp4.
// HLS is played natively on Safari/iOS and via hls.js (lazy-loaded from cdnjs)
// everywhere else. Both are zero-egress origins.

import type { Cta, SecondaryLink, Tour } from "./types";
import {
  type AgentModel,
  escapeAttr,
  escapeHtml,
  extractAgent,
  humanize,
  isHlsUrl,
  jsonForScript,
  spaceLabel,
  TOKENS_CSS,
} from "./html";

// Pinned hls.js (cdnjs) + Subresource Integrity hash for the 1.5.20 min bundle.
const HLS_SRC = "https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.20/hls.min.js";
const HLS_SRI = "sha384-V5ruNBgmYcC3SJRUQeNykAAAgde5gOFq/Hu0CZj7bygDP0yRIhkvX8+w0u/7mRvr";

// ---------------------------------------------------------------------------
// Agent card (extractAgent lives in html.ts; shared with the portfolio page)
// ---------------------------------------------------------------------------

function telHref(phone: string): string {
  const d = phone.replace(/[^\d+]/g, "");
  return "tel:" + d;
}

function renderAgentCard(a: AgentModel): string {
  const avatar = a.photo
    ? `<div class="avatar photo"><img src="${escapeAttr(a.photo)}" alt="${escapeAttr(a.name || "Agent")}" loading="lazy" decoding="async"></div>`
    : `<div class="avatar">${escapeHtml(a.initials)}</div>`;

  const subBits: string[] = [];
  if (a.company) subBits.push(escapeHtml(a.company));
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
        <div class="nm">${escapeHtml(a.name || "Your agent")}</div>
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

function fmtInt(n: number): string {
  return new Intl.NumberFormat("en-US").format(n);
}

function buildHeader(tour: Tour): HeaderModel {
  const l = tour.listing;
  const isRE = tour.space_type === "real_estate";

  if (isRE) {
    const bits: string[] = [];
    if (l.beds != null) bits.push(`${l.beds} bd`);
    if (l.baths != null) bits.push(`${String(l.baths)} ba`);
    if (l.sqft != null) bits.push(`${fmtInt(l.sqft)} sqft`);

    const primary = l.price
      ? `<div class="price">${escapeHtml(l.price)}</div>`
      : l.address
        ? `<div class="price">${escapeHtml(l.address)}</div>`
        : "";
    const lines: string[] = [];
    if (bits.length) lines.push(bits.join(" · "));
    if (l.price && l.address) lines.push(l.address);

    const titleText = l.address || "Property tour";
    const ogDesc = "Scroll to fly through this home." +
      (bits.length ? " " + bits.join(" · ") : "") +
      (l.price ? " · " + l.price : "");
    return {
      pageTitle: `${titleText} — Rendprop`,
      ogTitle: titleText + (l.price ? " — " + l.price : ""),
      ogDesc,
      chipHtml: `${primary}${lines.map((x) => `<div class="meta">${escapeHtml(x)}</div>`).join("")}`,
    };
  }

  const title = l.tagline || l.address || spaceLabel(tour.space_type);
  const lines: string[] = [];
  if (l.tagline && l.address) lines.push(l.address);
  return {
    pageTitle: `${title} — Rendprop`,
    ogTitle: title,
    ogDesc: l.tagline || `Take a cinematic scroll-through tour of this ${spaceLabel(tour.space_type).toLowerCase()}.`,
    chipHtml: `<div class="price">${escapeHtml(title)}</div>${lines.map((x) => `<div class="meta">${escapeHtml(x)}</div>`).join("")}`,
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
  notes: { label: "Notes (optional)", type: "textarea" },
  fitness_goal: { label: "Your fitness goal", type: "text" },
  preferred_time: { label: "Preferred time", type: "text" },
  interested_class: { label: "Class you're interested in", type: "text" },
  message: { label: "Message", type: "textarea" },
};

function renderField(key: string): string {
  const f = FIELD_REG[key] || { label: humanize(key), type: "text" as const };
  const nm = escapeAttr(key);
  if (f.type === "textarea") {
    return `<div class="field"><textarea name="${nm}" rows="3" placeholder="${escapeAttr(f.label)}"></textarea></div>`;
  }
  if (f.type === "date" || f.type === "time" || f.type === "number") {
    const extra = f.type === "number" ? ' min="1" inputmode="numeric"' : "";
    return `<div class="field"><label class="lbl" for="lf_${nm}">${escapeHtml(f.label)}</label><input id="lf_${nm}" type="${f.type}" name="${nm}"${extra}></div>`;
  }
  return `<div class="field"><input type="text" name="${nm}" placeholder="${escapeAttr(f.label)}"></div>`;
}

function textInput(type: string, name: string, ph: string, required: boolean, autocomplete: string): string {
  return `<div class="field"><input type="${type}" name="${escapeAttr(name)}" placeholder="${escapeAttr(ph)}"${required ? " required" : ""} autocomplete="${escapeAttr(autocomplete)}"></div>`;
}

function renderSecondary(links: SecondaryLink[]): string {
  if (!links || !links.length) return "";
  return `<div class="secondary">${links
    .map((s) => `<a class="slink" href="${escapeAttr(s.url)}" target="_blank" rel="noopener nofollow">${escapeHtml(s.label)}</a>`)
    .join("")}</div>`;
}

function formSub(tour: Tour): string {
  const addr = tour.listing.address;
  switch (tour.space_type) {
    case "real_estate": return `See ${addr || "this home"} in person — the agent will text you times.`;
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

function renderLeadForm(tour: Tour): string {
  const cta: Cta = tour.cta;
  const fields = cta.lead_fields || [];
  const emailOnly = fields.length === 1 && fields[0] === "email";

  const base = emailOnly
    ? textInput("email", "email", "Email address", true, "email")
    : textInput("text", "name", "Your name", true, "name") +
      textInput("tel", "phone", "Phone", true, "tel") +
      textInput("email", "email", "Email (optional)", false, "email");

  const extras = fields
    .filter((k) => k !== "name" && k !== "phone" && k !== "email")
    .map(renderField)
    .join("");

  return `<form id="leadform" novalidate>
      <h2>${escapeHtml(cta.label)}</h2>
      <p class="sub">${escapeHtml(formSub(tour))}</p>
      ${base}
      ${extras}
      <input class="hp" type="text" name="_hp" tabindex="-1" autocomplete="off" aria-hidden="true">
      <button class="cta" type="submit">${escapeHtml(cta.label)}</button>
    </form>
    ${renderSecondary(cta.secondary)}
    <div id="leadok">
      <div class="check">✓</div>
      <h2>Request sent</h2>
      <p>Thanks — expect a reply shortly.</p>
    </div>`;
}

function renderCtaBlock(tour: Tour): string {
  const cta = tour.cta;
  if (cta.mode === "deeplink" && cta.url) {
    const copy = deeplinkCopy(tour);
    return `<h2>${escapeHtml(copy.headline)}</h2>
      ${copy.sub ? `<p class="sub">${escapeHtml(copy.sub)}</p>` : ""}
      <a class="cta cta-link" href="${escapeAttr(cta.url)}" target="_blank" rel="noopener nofollow">${escapeHtml(cta.label)}</a>
      ${renderSecondary(cta.secondary)}`;
  }
  return renderLeadForm(tour);
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
  .field input, .field textarea { width: 100%; padding: 13px 14px; border-radius: 10px; border: 1px solid rgba(255,255,255,.12); background: rgba(255,255,255,.05); color: var(--ink); font-size: 15px; font-family: inherit; outline: none; }
  .field textarea { resize: vertical; min-height: 76px; }
  .field input:focus, .field textarea:focus { border-color: var(--accent); }
  .hp { position: absolute !important; left: -9999px !important; width: 1px; height: 1px; opacity: 0; pointer-events: none; }
  .cta { width: 100%; padding: 15px; border: 0; border-radius: 12px; cursor: pointer; background: var(--accent); color: #14100a; font-size: 15.5px; font-weight: 650; font-family: inherit; margin-top: 4px; }
  .cta:active { transform: scale(.985); }
  .cta:disabled { opacity: .6; cursor: default; }
  .cta-link { display: block; text-align: center; text-decoration: none; }
  .secondary { display: flex; flex-wrap: wrap; gap: 16px; justify-content: center; margin-top: 16px; }
  .secondary .slink { color: var(--accent); font-size: 13px; font-weight: 600; text-decoration: none; }
  .disclosure { margin-top: 18px; padding-top: 16px; border-top: 1px solid rgba(255,255,255,.08); font-size: 11px; line-height: 1.5; color: rgba(242,243,245,.5); }
  #leadok { display: none; text-align: center; padding: 26px 0 10px; }
  #leadok .check { font-size: 40px; margin-bottom: 10px; color: var(--accent); }
  #leadok p { color: var(--ink-dim); font-size: 14px; }

  @media (prefers-reduced-motion: reduce) { #hint { animation: none; } }
`;

// ---------------------------------------------------------------------------
// Client engine — ported scrub loop, adapted for HLS/Stream + R2 mp4 and wired
// to the live /beacon and /leads endpoints. Authored WITHOUT template literals
// or `${` so it can be embedded inside the outer template literal untouched.
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

  var CH  = Array.isArray(CFG.chapters) ? CFG.chapters : [];
  var HAS_CH = CH.length > 0;
  var PX_PER_SEC  = CFG.pxPerSec || 240;
  var BUFFER_GATE = CFG.bufferGate || 0.96;
  var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var LERP = reduce ? 0.08 : 0.14;

  function clamp(v,a,b){ return Math.min(b, Math.max(a, v)); }

  /* ---- Track sizing (100svh-safe, toolbar-resize-safe) ---- */
  var duration = Number(CFG.durationS) || 0;
  function sizeTrack(){
    if (!duration || !track) return;
    track.style.height = Math.round(duration * PX_PER_SEC + innerHeight) + 'px';
  }
  addEventListener('resize', sizeTrack, { passive: true });
  if (window.visualViewport) visualViewport.addEventListener('resize', sizeTrack, { passive: true });

  /* ---- Chapter rail (buttons are server-rendered) ---- */
  var railBtns = railEl ? Array.prototype.slice.call(railEl.querySelectorAll('button')) : [];
  for (var r = 0; r < railBtns.length; r++){
    (function(btn){
      btn.addEventListener('click', function(){
        var t = parseFloat(btn.getAttribute('data-t')) || 0;
        var p = duration ? t / duration : 0;
        scrollTo({ top: p * (track.offsetHeight - innerHeight), behavior: 'smooth' });
      });
    })(railBtns[r]);
  }

  /* ---- Overlays ---- */
  function updateOverlays(p){
    if (progEl) progEl.style.transform = 'scaleX(' + p + ')';
    if (!HAS_CH || !roomEl) return;
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
  var curT = 0, lastSet = -1, started = false, interacted = false;
  var longFrames = 0, lastTick = performance.now();

  function tick(now){
    if (now - lastTick > 90){ if (++longFrames > 24) return fallbackLoop(); }
    lastTick = now;
    var total = track.offsetHeight - innerHeight;
    var p = clamp(-track.getBoundingClientRect().top / total, 0, 1);
    var target = p * Math.max(0, (duration || video.duration || 0) - 0.05);
    curT += (target - curT) * LERP;
    if (Math.abs(video.currentTime - curT) > 0.016 && Math.abs(curT - lastSet) > 0.016){
      try { video.currentTime = curT; lastSet = curT; } catch (e) {}
    }
    updateOverlays(p);
    meter(p, now);
    requestAnimationFrame(tick);
  }

  function begin(){
    if (started) return;
    started = true;
    if (loader) loader.classList.add('done');
    reportViewAndDelivery();
    lastTick = performance.now();
    requestAnimationFrame(tick);
  }

  /* ---- Buffer gate + % loader ---- */
  function buffered(){
    try { return video.buffered.length ? video.buffered.end(video.buffered.length - 1) : 0; }
    catch (e) { return 0; }
  }
  function reportBuffer(){
    var dur = duration || video.duration;
    if (!dur) return;
    var f = clamp(buffered() / dur, 0, 1);
    var pc = Math.round(f * 100);
    if (pctEl) pctEl.textContent = pc + '%';
    if (barEl) barEl.style.width = pc + '%';
    if (f >= BUFFER_GATE) begin();
  }
  video.addEventListener('progress', reportBuffer);
  video.addEventListener('loadedmetadata', function(){
    if (!duration || Math.abs(duration - video.duration) > 0.5) duration = video.duration;
    sizeTrack(); reportBuffer();
  });
  video.addEventListener('canplaythrough', function(){ setTimeout(begin, 1200); });
  if (CFG.isHls){ video.addEventListener('loadeddata', function(){ setTimeout(begin, 700); }); }
  var pollBuf = setInterval(function(){ reportBuffer(); if (started) clearInterval(pollBuf); }, 250);
  setTimeout(function(){ if (!started && buffered() > 3) begin(); }, 6000);
  setTimeout(function(){ if (!started) begin(); }, 12000);

  /* ---- Fallback: autoplay loop (Low Power Mode / webview jank) ---- */
  var fellBack = false;
  function fallbackLoop(){
    if (fellBack) return; fellBack = true;
    if (loader) loader.classList.add('done');
    video.loop = true;
    var pr = video.play(); if (pr && pr.catch) pr.catch(function(){});
    (function loopTick(){
      var p = video.duration ? video.currentTime / video.duration : 0;
      updateOverlays(p);
      requestAnimationFrame(loopTick);
    })();
  }

  /* ---- Scrub hint ---- */
  function dismissHint(){ if (interacted) return; interacted = true; if (hintEl) hintEl.classList.add('gone'); }
  addEventListener('scroll', dismissHint, { passive: true, once: true });
  addEventListener('touchstart', dismissHint, { passive: true, once: true });

  /* ---- Metering beacon (batched; view + streamed-minutes once, watch_ms deltas) ---- */
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
    if (viewSent) return; viewSent = true;
    var mins = Number(CFG.durationS) ? Math.round((CFG.durationS / 60) * 1000) / 1000 : 0;
    postBeacon({ view_start: true, streamed_minutes: mins });
  }
  setInterval(function(){ if (document.visibilityState === 'visible' && viewSent) postBeacon(null); }, 20000);
  addEventListener('pagehide', function(){ postBeacon(null); });
  document.addEventListener('visibilitychange', function(){ if (document.hidden) postBeacon(null); });

  /* ---- Lead form ---- */
  var leadHeaders = { 'Content-Type': 'application/json' };
  if (CFG.anonKey){ leadHeaders['apikey'] = CFG.anonKey; leadHeaders['Authorization'] = 'Bearer ' + CFG.anonKey; }
  var form = document.getElementById('leadform');
  if (form){
    form.addEventListener('submit', function(e){
      e.preventDefault();
      var fd = new FormData(form);
      var top = { slug: CFG.slug, extra: {} };
      fd.forEach(function(v, k){
        if (k === 'name' || k === 'phone' || k === 'email'){ if (v) top[k] = v; }
        else if (k === '_hp'){ top._hp = v; }
        else if (v) top.extra[k] = v;
      });
      var btn = form.querySelector('button[type=submit]');
      var orig = btn ? btn.textContent : '';
      if (btn){ btn.disabled = true; btn.textContent = 'Sending...'; }
      fetch(CFG.functionsBase + '/leads', { method: 'POST', headers: leadHeaders, body: JSON.stringify(top), mode: 'cors', credentials: 'omit' })
        .then(function(res){ if (!res.ok) throw new Error('bad'); return res.json().catch(function(){ return {}; }); })
        .then(function(){
          form.style.display = 'none';
          var ok = document.getElementById('leadok');
          if (ok) ok.style.display = 'block';
        })
        .catch(function(){
          if (btn){ btn.disabled = false; btn.textContent = orig || 'Try again'; }
          alert('Could not send right now. Please try again.');
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

  /* ---- Video source: HLS (native Safari OR hls.js) / R2 mp4 ---- */
  function directSrc(url){ try { video.src = url; video.load(); } catch (e) {} }
  function loadHls(url){
    function attach(){
      if (window.Hls && window.Hls.isSupported()){
        var hls = new window.Hls({
          maxBufferLength: 600, maxMaxBufferLength: 600, backBufferLength: 600,
          maxBufferSize: 300 * 1000 * 1000, capLevelToPlayerSize: true,
          lowLatencyMode: false, enableWorker: true, startFragPrefetch: true
        });
        hls.on(window.Hls.Events.ERROR, function(evt, data){
          if (!data || !data.fatal) return;
          if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR){ try { hls.startLoad(); } catch (e) { directSrc(url); } }
          else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR){ try { hls.recoverMediaError(); } catch (e) { directSrc(url); } }
          else { try { hls.destroy(); } catch (e) {} directSrc(url); }
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
  function setupVideo(){
    var url = CFG.videoUrl;
    if (!url){ if (pctEl) pctEl.textContent = '--'; return; }
    video.muted = true; video.playsInline = true;
    video.setAttribute('playsinline', ''); video.setAttribute('webkit-playsinline', '');
    var canNative = video.canPlayType('application/vnd.apple.mpegurl') || video.canPlayType('application/x-mpegURL');
    if (CFG.isHls && !canNative){ loadHls(url); }
    else { directSrc(url); }
  }
  setupVideo();
})();
`;

// ---------------------------------------------------------------------------
// Full page
// ---------------------------------------------------------------------------

export function renderTourPage(tour: Tour, functionsBase: string, anonKey: string): string {
  const agent = extractAgent(tour.agent_card || {});
  const header = buildHeader(tour);
  const poster = tour.poster || "";
  const staged = !!tour.staged;
  const chapters = Array.isArray(tour.chapters) ? tour.chapters : [];
  const hasChapters = chapters.length > 0;

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

  const ogImage = poster ? `<meta property="og:image" content="${escapeAttr(poster)}">\n<meta name="twitter:image" content="${escapeAttr(poster)}">` : "";
  const shareUrl = tour.share_url || "";

  const cfg = {
    slug: tour.slug,
    functionsBase,
    anonKey: anonKey || "",
    videoUrl: tour.video_url || "",
    isHls: isHlsUrl(tour.video_url),
    durationS: tour.duration_s || 0,
    pxPerSec: 240,
    bufferGate: 0.96,
    hasChapters,
    staged,
    chapters: chapters.map((c) => ({ t: c.t_ms / 1000, label: c.label })),
    hlsSrc: HLS_SRC,
    hlsSri: HLS_SRI,
  };

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0b0d10">
<title>${escapeHtml(header.pageTitle)}</title>
<meta name="description" content="${escapeAttr(header.ogDesc)}">
<meta property="og:title" content="${escapeAttr(header.ogTitle)}">
<meta property="og:description" content="${escapeAttr(header.ogDesc)}">
<meta property="og:type" content="website">
${shareUrl ? `<meta property="og:url" content="${escapeAttr(shareUrl)}">` : ""}
<meta name="twitter:card" content="summary_large_image">
${ogImage}
${accentOverride}
<style>${PLAYER_CSS}</style>
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

    <div id="progress"><i></i></div>

    <div class="chrome" id="brand">RENDPROP</div>

    <div class="chrome" id="listing">${header.chipHtml}</div>

    ${roomHtml}

    ${railHtml}

    <div class="chrome" id="hint">
      <span>Scroll to fly through</span>
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 4v14m0 0l-6-6m6 6l6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
    </div>

    <a class="chrome" id="wm" href="https://rendprop.app" target="_blank" rel="noopener">Made with <b>Rendprop</b></a>

    ${stagedHtml}
  </div>
</div>

<section id="endcard">
  <div class="panel">
    ${renderAgentCard(agent)}
    ${renderCtaBlock(tour)}
    ${disclosurePanel}
  </div>
</section>

<script>window.__CFG__=${jsonForScript(cfg)};</script>
<script>${ENGINE_JS}</script>
</body>
</html>`;
}
