/** Presentation only. Published selection is a server-resolved entitlement;
 * a preview request never changes the listing or grants a paid design. */
export const WEBSITE_THEMES = ["basic", "signature-estate", "coastal-luxe"] as const;
export type WebsiteTheme = typeof WEBSITE_THEMES[number];

export function websiteTheme(value: unknown): WebsiteTheme {
  return value === "signature-estate" || value === "coastal-luxe" ? value : "basic";
}

export function previewWebsiteTheme(value: unknown): WebsiteTheme | null {
  return typeof value === "string" && (WEBSITE_THEMES as readonly string[]).includes(value)
    ? value as WebsiteTheme : null;
}

export function websiteThemeName(theme: WebsiteTheme): string {
  return theme === "signature-estate" ? "Signature Estate" : theme === "coastal-luxe" ? "Coastal Luxe" : "Classic";
}

// Paid designs: Signature Estate and Coastal Luxe. Both are a presentation
// layer over the same actual listing components as Classic. Local system
// faces only; the published property's own photographs and film only; no
// example properties, tracking or theme media. Entitlement is server-resolved.
const PAID = ".property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe)";
const SIGNATURE = ".property-site.site-theme-signature-estate";
const COASTAL = ".property-site.site-theme-coastal-luxe";
const DESIGN_CSS = `
  /* ───────────────────────────── Paid designs ─────────────────────────────
     Signature Estate and Coastal Luxe share one quiet material system and the
     actual listing components. Local system faces only, the property's own
     media only, no tracking, no theme media. Classic markup is untouched. */
  $P { font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif; -webkit-font-smoothing:antialiased; line-height:1.6; --grad-text:linear-gradient(var(--ink),var(--ink)); --card:var(--premium-paper); --lux-ease:cubic-bezier(.23,1,.32,1); --lux-ease-io:cubic-bezier(.77,0,.175,1); --lux-radius:0px; --lux-radius-s:0px; --lux-nav-h:52px; --listing-nav-offset:96px; background:var(--bg); color:var(--ink); }
  $P .lp-wrap { max-width:1240px; padding-inline:clamp(22px,5vw,64px); }
  /* The opening tucks under the floating navigation with a negative margin; the
     main landmark itself must keep its top below that chrome for Skip to content. */
  $P #property-content { display:flow-root; }
  $P :is(a,button,summary,input,textarea):focus-visible { outline:2px solid var(--accent); outline-offset:4px; border-radius:6px; }
  $P ::selection { background:var(--accent-soft); color:var(--ink); }
  $P .lp-sec { padding:clamp(72px,9vw,136px) 0; border-top:0; }
  $P .lp-sec + .lp-sec { border-top:1px solid var(--premium-line); }
  $P .lp-eyebrow { gap:12px; margin-bottom:22px; color:var(--accent-3); font:600 11px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:.22em; text-transform:uppercase; }
  $P .lp-eyebrow::before { width:28px; height:1px; border-radius:0; background:currentColor; opacity:.7; }
  $P .lp-h,$P .property-page-head h1,$P .panel h2,$P .property-location-copy address,$P .lp-stat .v,$P .property-hero-title,$P .property-hero-price { font-family:var(--lux-serif); font-weight:400; letter-spacing:-.025em; }
  $P .lp-h { font-size:clamp(36px,4.6vw,60px); line-height:1.04; margin:0 0 28px; max-width:18ch; text-wrap:balance; }
  $P .lp-tag { font-size:15px; color:var(--ink-dim); margin-top:8px; }
  $P .lp-fine { color:var(--ink-dim); }
  $P .lp-prose { color:var(--ink-dim); }
  $P .lp-prose p { max-width:60ch; font-size:clamp(16px,1.25vw,18px); line-height:1.85; color:var(--ink-dim); }
  $P .lp-prose p:first-child { color:var(--ink); font-size:clamp(18px,1.6vw,22px); line-height:1.6; font-weight:400; }

  /* Floating glass navigation: one capsule, native links, 44px targets. */
  $P #listing-nav { position:sticky; top:14px; z-index:30; width:calc(100% - 40px); max-width:1240px; margin:14px auto 0; border:1px solid var(--premium-line); border-radius:999px; color:var(--ink); background:var(--premium-paper); box-shadow:0 1px 2px rgba(20,24,20,.05),0 14px 40px -18px rgba(20,24,20,.28); }
  $P.site-preview #listing-nav { position:relative; top:auto; }
  $P .listing-nav-inner { max-width:none; padding:5px 6px 5px 10px; gap:10px; }
  $P #listing-nav :is(a,button,summary) { min-height:44px; min-width:44px; padding:10px 15px; border:0; border-radius:999px; color:var(--ink); background:transparent; font:500 13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:.01em; transition:background-color .16s ease,color .16s ease,transform .16s var(--lux-ease); }
  $P #listing-nav .listing-nav-links { gap:2px; }
  $P #listing-nav .listing-nav-links a { color:var(--ink-dim); }
  $P #listing-nav .listing-nav-links a[aria-current=page] { color:var(--ink); background:var(--accent-soft); }
  $P #listing-nav :is(.property-primary-play,.watch-button) { color:var(--on-accent); background:var(--lux-fill); padding-inline:18px; font-weight:600; }
  $P #listing-nav .walkthrough-secondary { color:var(--ink-dim); background:transparent; }
  $P #listing-nav .listing-backtop { color:var(--ink-dim); }
  $P #listing-nav :is(a,button):active { transform:scale(.97); }
  $P .property-page-menu { display:none; }
  @supports ((backdrop-filter:blur(16px)) or (-webkit-backdrop-filter:blur(16px))) {
    $P #listing-nav { background:var(--premium-glass); backdrop-filter:blur(24px) saturate(1.5); -webkit-backdrop-filter:blur(24px) saturate(1.5); }
  }
  @media(hover:hover) and (pointer:fine) {
    $P #listing-nav .listing-nav-links a:hover { color:var(--ink); background:var(--accent-soft); }
    $P #listing-nav .walkthrough-secondary:hover,$P #listing-nav .listing-backtop:hover { color:var(--ink); }
  }

  /* Capsule controls everywhere: 44px+, press feedback, no card chrome. */
  $P :is(.lp-btn,.cta) { display:inline-flex; align-items:center; justify-content:center; gap:8px; min-height:48px; padding:13px 24px; border:1px solid var(--lux-fill); border-radius:999px; color:var(--on-accent); background:var(--lux-fill); box-shadow:none; font:600 14px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:.01em; text-decoration:none; cursor:pointer; transition:transform .16s var(--lux-ease),background-color .2s ease,border-color .2s ease,box-shadow .2s ease; }
  $P :is(.lp-btn,.cta):active { transform:scale(.97); box-shadow:none; }
  $P .lp-btn.ghost,$P .lp-btn-ghost { color:var(--ink); background:transparent; border:1px solid var(--premium-line-strong); }
  @media(hover:hover) and (pointer:fine) {
    $P :is(.lp-btn,.cta):hover { transform:translateY(-1px); background:var(--lux-fill-hover); border-color:var(--lux-fill-hover); box-shadow:0 10px 24px -14px rgba(20,24,20,.45); }
    $P .lp-btn.ghost:hover { background:var(--accent-soft); border-color:var(--premium-line-strong); color:var(--ink); }
  }

  /* ─────────────── Opening: the property's own media is the architecture ──
     Desktop: the poster (or cover photo) fills the viewport under the glass
     navigation; the complete, uncropped film plays after an explicit tap with
     native controls, over a softened still of itself. Identity, price and the
     actions stay inside the first screen at every size. */
  $P .listing-cover { position:relative; display:block; isolation:isolate; width:100%; max-width:none; min-height:clamp(620px,100svh,1040px); margin:calc(-1 * (var(--lux-nav-h) + 28px)) 0 0; border:0; border-radius:0; overflow:hidden; box-shadow:none; color:#fff; background:var(--hero-bg); transform:none; }
  $P .listing-cover.property-video-hero { min-height:clamp(620px,100svh,1040px); color:#fff; background:var(--hero-bg); }
  $P .listing-cover::after { display:block; position:absolute; inset:0; z-index:1; content:""; pointer-events:none; background:linear-gradient(180deg,rgba(6,10,9,.42) 0%,rgba(6,10,9,0) 26%,rgba(6,10,9,0) 48%,rgba(6,10,9,.62) 78%,rgba(6,10,9,.86) 100%); transition:opacity .6s ease; }
  /* Shared video CSS is appended after this sheet and hides its generic hero
     overlay. Keep the film poster readable behind Signature's white identity. */
  $S .listing-cover.property-video-hero::after { display:block; }
  $P .property-hero-media { position:absolute; inset:0; z-index:0; width:100%; height:100%; overflow:hidden; background:var(--hero-bg); border-radius:0; box-shadow:none; }
  $P .property-hero-media > img { display:block; width:100%; height:100%; max-height:none; min-height:0; object-fit:cover; object-position:center; }
  $P .listing-cover-empty { position:absolute; inset:0; display:grid; place-items:center; color:#fff; }
  $P .property-video-hero .property-hero-media { position:absolute; inset:0; height:100%; }
  $P .property-video-hero .property-video-stage { position:absolute; inset:0; width:100%; height:100%; aspect-ratio:auto; background:var(--hero-bg); }
  $P .property-video-hero .property-video-stage.property-film .property-film-backdrop { inset:0; width:100%; height:100%; max-height:none; object-fit:cover; filter:none; transition:filter .9s ease,transform .9s var(--lux-ease),opacity .6s ease; }
  $P .property-video-hero .property-video-stage.property-film > video { position:absolute; inset:0; width:100%; height:100%; object-fit:contain; opacity:0; transition:opacity .5s ease; }
  $P .property-video-hero .property-video-stage.property-film.is-playing > video { opacity:1; }
  $P .property-video-hero .property-video-stage.property-film.is-playing .property-film-backdrop { filter:blur(34px) saturate(1.1) brightness(.42); transform:scale(1.08); }
  $P .property-video-hero .property-video-stage.property-film .property-video-play { top:31%; transform:translate(-50%,-50%); gap:16px; font-size:11px; letter-spacing:.2em; }
  $P .property-video-hero .property-video-stage.property-film .property-film-play-mark { width:84px; height:84px; border-color:rgba(255,255,255,.55); background:rgba(10,14,13,.28); box-shadow:0 18px 50px -10px rgba(0,0,0,.5),inset 0 1px rgba(255,255,255,.35); }
  $P .property-video-hero .property-video-stage.property-film .property-film-play-mark::after { border-width:11px 0 11px 19px; margin-left:6px; }
  $P .property-video-hero .property-video-stage.property-film .property-film-label { left:auto; right:clamp(20px,3vw,40px); bottom:clamp(20px,3vw,36px); font-size:10.5px; letter-spacing:.22em; color:rgba(255,255,255,.72); }
  $P .property-video-hero .property-video-stage.property-film #property-video-status { top:calc(31% + 70px); }
  $P .property-video-hero .property-video-stage.property-film.is-playing #property-video-status { top:18px; }
  $P .property-video-hero .property-video-stage.property-film,$P .property-video-hero .property-video-stage.property-film > video,$P .property-video-hero .property-video-stage.property-film .property-video-play,$P .property-video-hero .property-video-stage.property-film .property-film-label { animation:none; }
  /* Once the film plays the identity steps aside; the navigation keeps every page one tap away. */
  $P .listing-cover:has(.property-film.is-playing)::after { opacity:0; }
  $P .listing-cover:has(.property-film.is-playing) .property-hero-copy { opacity:0; pointer-events:none; transform:translateY(12px); }
  /* Signature desktop fades this copy out while the film plays. Hidden
     controls must also leave the keyboard order; the title remains readable
     to assistive technology. The phone layout keeps its copy visible. */
  @media(min-width:601px) {
    $S .listing-cover:has(.property-film.is-playing) .property-hero-copy :is(a,button,summary) { visibility:hidden; }
  }

  $P .listing-cover .property-hero-copy { position:absolute; z-index:2; inset:auto 0 clamp(36px,6vh,80px) 0; width:min(920px,calc(100% - 48px)); max-width:none; margin:0 auto; padding:0; color:#fff; background:transparent; text-align:center; text-shadow:0 1px 2px rgba(0,0,0,.25),0 12px 40px rgba(0,0,0,.35); transition:opacity .45s ease,transform .45s var(--lux-ease); }
  $P .listing-cover .property-hero-copy .lp-eyebrow { justify-content:center; margin-bottom:18px; color:var(--hero-accent); }
  $P .listing-cover .property-hero-copy .lp-eyebrow::before { display:none; }
  $P .listing-cover .property-hero-title { margin:0 auto; max-width:14ch; font-size:clamp(48px,6.2vw,96px); line-height:.98; letter-spacing:-.03em; text-wrap:balance; overflow-wrap:anywhere; }
  $P .listing-cover .property-hero-locality { display:block; margin-top:18px; color:rgba(255,255,255,.84); font:400 clamp(14px,1.15vw,17px)/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:.08em; text-transform:uppercase; }
  $P .listing-cover .property-hero-price { margin:14px 0 0; color:#fff; font-size:clamp(22px,2.2vw,32px); line-height:1.2; letter-spacing:-.01em; }
  $P .listing-cover .listing-cover-actions { display:flex; flex-wrap:wrap; justify-content:center; gap:10px; margin-top:26px; padding:0; }
  $P .listing-cover-actions p { display:none; }
  $P .listing-cover :is(.property-hero-link,.listing-cover-actions button) { display:inline-flex; align-items:center; justify-content:center; min-height:48px; padding:13px 24px; border:1px solid rgba(255,255,255,.55); border-radius:999px; color:#fff; background:rgba(12,18,16,.28); font:500 13.5px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:.01em; text-decoration:none; text-shadow:none; cursor:pointer; transition:transform .16s var(--lux-ease),background-color .2s ease,border-color .2s ease; }
  $P .listing-cover :is(.property-hero-link,.listing-cover-actions button):active { transform:scale(.97); }
  $P .listing-cover .listing-cover-actions .property-hero-contact { color:var(--hero-cta-ink); background:var(--hero-cta); border-color:var(--hero-cta); font-weight:600; }
  $P .listing-cover .listing-media-label { display:block; margin:16px 0 0; padding:0; color:rgba(255,255,255,.78); font-size:12px; line-height:1.6; letter-spacing:.01em; }
  $P .listing-cover .listing-media-label + .listing-media-label { margin-top:4px; }
  $P .listing-media-label a { color:inherit; text-decoration:underline; text-underline-offset:3px; text-decoration-color:rgba(255,255,255,.5); }
  $P .listing-cover .property-recorded-option { margin:14px auto 0; padding:0; border:0; color:rgba(255,255,255,.82); font-size:12px; }
  $P .listing-cover .property-recorded-option summary { display:inline-flex; align-items:center; justify-content:center; gap:8px; min-height:44px; padding:6px 12px; border-radius:999px; font-size:12px; letter-spacing:.02em; cursor:pointer; }
  $P .listing-cover .property-recorded-option summary::before { content:"+"; font-size:16px; line-height:1; opacity:.8; }
  $P .listing-cover .property-recorded-option[open] summary::before { content:"−"; }
  $P .listing-cover .property-recorded-option p { padding:4px 0 10px; }
  $P .listing-cover .property-recorded-option button { min-height:44px; padding:11px 18px; border:1px solid rgba(255,255,255,.55); border-radius:999px; color:#fff; background:rgba(12,18,16,.28); font:500 13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; cursor:pointer; }
  @supports ((backdrop-filter:blur(12px)) or (-webkit-backdrop-filter:blur(12px))) {
    $P .listing-cover :is(.property-hero-link,.listing-cover-actions button:not(.property-hero-contact),.property-recorded-option button) { backdrop-filter:blur(14px) saturate(1.3); -webkit-backdrop-filter:blur(14px) saturate(1.3); }
  }
  @media(hover:hover) and (pointer:fine) {
    $P .listing-cover :is(.property-hero-link:not(.property-hero-contact),.listing-cover-actions button,.property-recorded-option button):hover { background:rgba(255,255,255,.16); border-color:rgba(255,255,255,.85); }
    $P .listing-cover .listing-cover-actions .property-hero-contact:hover { background:#fff; border-color:#fff; }
  }

  /* ─────────────── Overview: a quiet strip of serif figures ─────────────── */
  $P #overview { padding:clamp(28px,4vw,48px) 0 0; border-top:0; background:var(--bg); }
  $P #overview .lp-wrap { max-width:1240px; }
  $P #overview .lp-eyebrow { display:none; }
  $P #overview .lp-h { margin-top:clamp(56px,8vw,96px); }
  $P .lp-price { margin-top:8px; font-family:var(--lux-serif); font-weight:400; font-size:clamp(24px,2.4vw,34px); }
  $P .lp-stats { display:flex; flex-wrap:wrap; gap:0; margin:0; border:0; border-bottom:1px solid var(--premium-line); }
  $P .lp-stat { flex:1 1 0; min-width:120px; padding:clamp(34px,4vw,56px) 16px; border:0; border-radius:0; box-shadow:none; background:transparent; text-align:center; }
  $P .lp-stat + .lp-stat { border-left:1px solid var(--premium-line); }
  $P .lp-stat .v { display:block; font-size:clamp(34px,3.6vw,56px); line-height:1.05; color:var(--ink); font-variant-numeric:lining-nums; }
  $P .lp-stat .k { display:block; margin-top:12px; color:var(--ink-dim); font:500 11px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:.18em; text-transform:uppercase; }
  $P .lp-soldtag { color:var(--on-accent); background:var(--lux-fill); }
  $P .lp-soldnote { color:var(--ink-dim); }

  /* ─────────────── Story: an editorial spread ─────────────── */
  $P .property-story-spread { display:grid; grid-template-columns:minmax(0,.9fr) minmax(0,1.1fr); align-items:center; gap:clamp(32px,7vw,110px); }
  $P .property-story-photo { margin:0; }
  $P .property-story-photo img { display:block; width:100%; aspect-ratio:4/5; object-fit:cover; border-radius:var(--lux-radius); }
  $P .property-story-photo figcaption { margin-top:14px; color:var(--ink-dim); font-size:12px; letter-spacing:.04em; }
  $P #story .lp-h { margin-bottom:22px; }

  /* ─────────────── Gallery: large, calm, in published order ─────────────── */
  $P .lp-gal { gap:clamp(14px,2vw,28px); grid-template-columns:repeat(2,minmax(0,1fr)); align-items:start; }
  $P #gallery .lp-wrap > .lp-gal > .lp-gcell:first-child { grid-column:1/-1; }
  $P #gallery .lp-wrap > .lp-gal > .lp-gcell:first-child img { aspect-ratio:16/9; }
  $P .lp-gcell { border:0; padding:0; box-shadow:none; background:transparent; border-radius:0; overflow:visible; aspect-ratio:auto; }
  $P .lp-gcell img { display:block; width:100%; aspect-ratio:4/3; height:auto; object-fit:cover; border-radius:var(--lux-radius); background:var(--accent-soft); transform:none; transition:transform .6s var(--lux-ease),filter .6s ease; }
  $P .property-photo { display:block; overflow:hidden; border-radius:var(--lux-radius); }
  $P .lp-gcell figcaption { position:static; padding:12px 0 0; background:none; color:var(--ink-dim); font-size:12px; font-weight:400; letter-spacing:.04em; }
  $P #gallery .lp-tag { margin-top:-10px; margin-bottom:22px; }
  $P #gallery p:has(> .lp-btn) { margin-top:36px; text-align:center; }
  $P #gallery .lp-btn { margin-top:0; }
  $P .lp-mediadate { color:var(--ink-dim); font-size:12px; }
  @media(hover:hover) and (pointer:fine) and (prefers-reduced-motion:no-preference) {
    $P .lp-gcell:hover img,$P .property-story-photo:hover img { transform:scale(1.025); }
  }
  /* Room-grouped editorial Gallery page. */
  $P .lp-gal-rooms { display:grid; gap:clamp(48px,6vw,80px); margin-top:28px; }
  $P .lp-gal-room-title { display:flex; align-items:baseline; gap:14px; margin:0 0 18px; color:var(--accent-3); font:600 11px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:.2em; text-transform:uppercase; }
  $P .lp-gal-room-title::after { content:""; flex:1; height:1px; align-self:center; background:var(--premium-line); }
  $P .lp-gal-room-count { order:1; color:var(--ink-dim); font-weight:400; letter-spacing:0; text-transform:none; }
  $P .lp-gal-rooms .lp-mediadate { margin-top:0; }
  $P .lp-gal-run { display:grid; row-gap:clamp(48px,6vw,80px); }
  $P .lp-gal-run > .lp-gal-room { display:flex; flex-direction:column; justify-content:flex-end; min-width:0; }
  $P .lp-gal-run .lp-gal { grid-template-columns:minmax(0,1fr); }
  @media(min-width:760px) {
    /* Signature: two columns. */
    $S .lp-gal-run { grid-template-columns:repeat(2,minmax(0,1fr)); column-gap:32px; }
    $S :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(odd):last-child { grid-column:1/-1; }
    $S :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(odd):last-child img { aspect-ratio:16/9; }
    /* Coastal: three columns as six tracks, so a last row of two shares the width. */
    $C :is(.lp-gal-rooms > .lp-gal-room > .lp-gal,.lp-gal-run) { grid-template-columns:repeat(6,minmax(0,1fr)); }
    $C .lp-gal-run { column-gap:24px; }
    $C :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room) { grid-column:span 2; }
    $C :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):is(:nth-child(3n+1):nth-last-child(2),:nth-child(3n+2):last-child) { grid-column:span 3; }
    $C :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(3n+1):last-child { grid-column:1/-1; }
    $C :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):is(:nth-child(3n+1):nth-last-child(-n+2),:nth-child(3n+2):last-child) img { aspect-ratio:16/9; }
  }
  @media(max-width:759px) {
    /* Coastal phones: two columns. Signature phones are one column already. */
    $C .lp-gal-run { grid-template-columns:repeat(2,minmax(0,1fr)); column-gap:16px; }
    /* Half-width cells have no room for the heading rule; never leave a stub. */
    $C .lp-gal-run > .lp-gal-room:not(:nth-child(odd):last-child) .lp-gal-room-title::after { display:none; }
    $C :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(odd):last-child { grid-column:1/-1; }
    $C :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(odd):last-child img { aspect-ratio:16/9; }
  }

  /* ─────────────── Features, floor plans, facts ─────────────── */
  $P .lp-feat { gap:clamp(28px,4vw,56px); grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); }
  $P .lp-fcol { padding-top:22px; border-top:1px solid var(--premium-line); }
  $P .lp-fcol h3 { margin-bottom:16px; color:var(--ink); font:600 11px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:.18em; text-transform:uppercase; }
  $P .lp-fcol li { padding-left:0; margin-bottom:10px; color:var(--ink-dim); font-size:15px; line-height:1.55; }
  $P .lp-fcol li::before { display:none; }
  $P .lp-levels { gap:0; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); }
  $P .lp-level,$P .lp-fact,$P .disc-item,$P .lp-cm { background:transparent; border:0; border-top:1px solid var(--premium-line); border-radius:0; box-shadow:none; padding:22px 0; }
  $P .lp-level + .lp-level,$P .lp-cm + .lp-cm { margin-left:0; }
  @media(min-width:760px) { $P .lp-level + .lp-level,$P .lp-cm + .lp-cm { padding-left:24px; border-left:1px solid var(--premium-line); } }
  $P .lp-lvhead .nm { font-family:var(--lux-serif); font-weight:400; font-size:22px; letter-spacing:-.01em; }
  $P .lp-lvhead .sf { color:var(--accent-3); font-size:12px; letter-spacing:.08em; }
  $P .lp-fpimg { border:1px solid var(--premium-line); border-radius:var(--lux-radius); background:#fff; }
  $P .lp-commute { gap:0; margin-top:32px; }
  $P .lp-cm .t { color:var(--ink); font-family:var(--lux-serif); font-weight:400; font-size:30px; }
  $P .lp-cm .l { color:var(--ink-dim); font-size:13px; }
  $P .lp-chip { color:var(--ink); background:var(--accent-soft); border-color:transparent; }
  $P .disc-sum { display:inline-flex; align-items:center; gap:8px; width:fit-content; max-width:100%; min-height:44px; padding:11px 18px; border:1px solid var(--premium-line-strong); border-radius:999px; color:var(--ink); font-size:14px; }
  $P .disc-sum::after,$P .disc[open] .disc-sum::after { color:var(--accent-3); }
  $P .disc-item { padding:18px 0; }
  $P .lp-fine a,$P .lp-tag a { color:var(--accent-3); }

  /* ─────────────── Sub-pages: Gallery, Location, Contact ─────────────── */
  $P .property-page-head { padding:clamp(48px,8vw,96px) 0 clamp(28px,4vw,48px); color:var(--ink); background:transparent; }
  $P .property-page-head .lp-eyebrow { color:var(--accent-3); }
  $P .property-page-head h1 { font-size:clamp(40px,6vw,84px); line-height:1; letter-spacing:-.03em; }
  $P .property-page-head p { margin-top:16px; color:var(--ink-dim); font-size:15px; letter-spacing:.02em; }
  $P .property-location-card { grid-template-columns:1.15fr .85fr; margin-top:0; border:1px solid var(--premium-line); border-radius:var(--lux-radius); overflow:hidden; background:var(--premium-paper); box-shadow:none; }
  $P .property-location-copy { padding:clamp(28px,4vw,56px); }
  $P .property-location-copy address { font-size:clamp(26px,3vw,42px); line-height:1.15; }
  $P .property-location-copy .lp-btn { margin-top:28px; }
  $P .property-location-visual { min-height:280px; background-color:var(--accent-soft); background-image:radial-gradient(circle at center,var(--premium-line) 1px,transparent 1.5px); background-size:28px 28px; }
  $P .property-location-visual span { width:68px; height:68px; background:var(--lux-fill); color:var(--on-accent); box-shadow:0 18px 40px -16px rgba(20,24,20,.5); }
  $P #location .lp-prose { margin-top:40px; }
  $P .property-nearby-map { --nearby-paper:var(--premium-paper); --nearby-ring:var(--premium-line-strong); --nearby-ink:var(--ink); --nearby-dim:var(--ink-dim); --nearby-home:var(--accent-3); margin-top:32px; border:1px solid var(--premium-line); border-radius:var(--lux-radius); overflow:hidden; }
  $P .property-nearby-list { margin-top:32px; gap:0; }
  $P .property-nearby-list li { padding:18px 0; border:0; border-top:1px solid var(--premium-line); border-radius:0; background:transparent; }
  $P .property-nearby-list a { color:var(--ink); font-weight:500; }
  $P .property-nearby-list span { margin-top:4px; font-size:12px; letter-spacing:.02em; }
  @media(min-width:1000px) { $P #property-nearby .property-nearby-list { column-gap:40px; } }

  /* ─────────────── Contact: the agent, then the enquiry ─────────────── */
  $P #disclosure { padding:clamp(40px,5vw,64px) 0; }
  $P #endcard { padding:clamp(56px,7vw,104px) 0; background:var(--bg); }
  $P #endcard .panel { display:grid; grid-template-columns:minmax(0,.9fr) minmax(0,1.1fr); column-gap:clamp(40px,6vw,96px); row-gap:32px; width:100%; max-width:1240px; padding:0 clamp(22px,5vw,64px); border:0; border-radius:0; box-shadow:none; background:transparent; backdrop-filter:none; -webkit-backdrop-filter:none; text-align:left; }
  $P #endcard .panel > :not(.agent) { grid-column:2; }
  $P #endcard .panel > :is(.disclosure,.property-preview-note) { grid-column:1/-1; margin-top:12px; color:var(--ink-dim); }
  $P #endcard .agent { align-self:start; flex-direction:column; align-items:flex-start; gap:20px; margin:0; padding:clamp(28px,3vw,40px); border:1px solid var(--premium-line); border-bottom:1px solid var(--premium-line); border-radius:var(--lux-radius); background:var(--premium-paper); }
  $P #endcard .agent .avatar { width:88px; height:88px; flex-basis:88px; border:1px solid var(--premium-line); background:var(--accent-soft); color:var(--accent-3); font-family:var(--lux-serif); font-weight:400; font-size:28px; }
  $P #endcard .agent .who .nm { font-family:var(--lux-serif); font-weight:400; font-size:30px; letter-spacing:-.02em; line-height:1.1; }
  $P #endcard .agent .who .bk { margin-top:8px; color:var(--ink-dim); font-size:14px; line-height:1.6; }
  $P #endcard .agent .who .bk a { color:var(--ink); }
  $P #endcard .agent .social { gap:6px 16px; margin-top:12px; }
  $P #endcard .agent .social a,$P #endcard .agent .more { color:var(--accent-3); font-size:13px; font-weight:600; letter-spacing:.04em; }
  $P .panel h2 { margin-top:0; font-size:clamp(30px,3.4vw,44px); line-height:1.08; }
  $P .panel .sub { margin:10px 0 26px; color:var(--ink-dim); font-size:15px; }
  $P .field { margin-bottom:14px; }
  $P .field .lbl { margin:0 0 8px 2px; color:var(--ink-dim); font-size:11px; letter-spacing:.16em; }
  $P .field input,$P .field textarea { min-height:52px; padding:14px 16px; border:1px solid var(--premium-line-strong); border-radius:var(--lux-radius-s); background:var(--premium-paper); color:var(--ink); font-size:16px; transition:border-color .16s ease,box-shadow .16s ease; }
  $P .field input:focus,$P .field textarea:focus { border-color:var(--accent-3); box-shadow:0 0 0 3px var(--accent-soft); outline:none; }
  $P .field input[aria-invalid="true"],$P .field textarea[aria-invalid="true"] { border-color:#b4473a; }
  $P .field .err { color:#9a3a2e; }
  $P .formmsg { color:#7f2d24; background:#fbeeec; border-radius:var(--lux-radius-s); }
  $P :is(.privacy,.privacy a,.disclosure) { color:var(--ink-dim); }
  $P .privacy a { text-decoration-color:var(--premium-line-strong); }

  /* ─────────────── Footer and app band ─────────────── */
  $P .lp-foot { border-color:var(--premium-line); color:var(--ink-dim); }
  $P .lp-foot a { color:var(--ink); }
  $P .lp-partner { border:1px solid var(--premium-line); border-radius:var(--lux-radius); background:var(--premium-paper); }
  $P .lp-partner .nm { color:var(--ink); font-weight:600; }
  @media(hover:hover) and (pointer:fine) { $P .lp-partner:hover { border-color:var(--premium-line-strong); } }
  $P #getapp { border-top:1px solid var(--premium-line); }

  /* ─────────────── Photo viewer and walkthrough dialog ─────────────── */
  $P #property-photo-modal { border:1px solid rgba(255,255,255,.14); border-radius:22px; background:#0f1211; }
  $P #property-photo-modal::backdrop { background:rgba(6,8,7,.9); }
  $P #property-photo-close,$P .property-photo-nav button { border:1px solid rgba(255,255,255,.22); border-radius:999px; background:rgba(255,255,255,.08); color:#fff; }
  $P #property-photo-full { border-radius:12px; }
  $P #property-photo-modal a { color:#e7dcc3; }
  $P #flythrough-modal { --bg:#0f1211; --ink:#f3f1ea; --ink-dim:#c9c6bb; --card:#1c211f; --accent:var(--hero-accent); --accent-3:#e7dcc3; border-radius:22px; }
  $P #flythrough-close,$P .video-action { border-radius:999px; }

  /* ─────────────── Motion: purposeful, short, opacity/transform only ─────── */
  @media(prefers-reduced-motion:no-preference) {
    $P .listing-cover .property-hero-copy > * { animation:lux-rise .8s var(--lux-ease) both; }
    $P .listing-cover .property-hero-copy > :nth-child(2) { animation-delay:.08s; }
    $P .listing-cover .property-hero-copy > :nth-child(3) { animation-delay:.16s; }
    $P .listing-cover .property-hero-copy > :nth-child(4) { animation-delay:.24s; }
    $P .listing-cover .property-hero-copy > :nth-child(n+5) { animation-delay:.32s; }
    $S .property-hero-media > img,$S .property-video-stage.property-film .property-film-backdrop { animation:lux-settle 2.2s var(--lux-ease) both; }
    $C .property-hero-media { animation:lux-fade .9s ease both; }
    $P .property-video-stage.property-film .property-video-play,$P .property-video-stage.property-film .property-film-label { animation:lux-fade .8s ease .35s both; }
  }
  @keyframes lux-rise { from { transform:translateY(14px); } to { transform:none; } }
  @keyframes lux-fade { from { opacity:0; } to { opacity:1; } }
  @keyframes lux-settle { from { transform:scale(1.06); } to { transform:none; } }
  @media(prefers-reduced-motion:reduce) {
    $P *,$P *::before,$P *::after { transition:none!important; animation:none!important; scroll-behavior:auto!important; }
    $P .listing-cover .property-hero-copy,$P .listing-cover .property-hero-copy > * { opacity:1!important; transform:none!important; }
  }
  /* Signature keeps copy off the desktop film; Coastal and Signature phones
     keep their identity beside or below the playing frame. */
  @media(prefers-reduced-motion:reduce) and (min-width:601px) {
    $S .listing-cover:has(.property-film.is-playing) .property-hero-copy { opacity:0!important; }
  }
  @media(prefers-reduced-transparency:reduce) {
    $P #listing-nav { background:var(--premium-paper); backdrop-filter:none; -webkit-backdrop-filter:none; }
    $P .listing-cover :is(.property-hero-link,.listing-cover-actions button,.property-recorded-option button) { background:#161d1b; backdrop-filter:none; -webkit-backdrop-filter:none; }
    $P .listing-cover .listing-cover-actions .property-hero-contact { background:var(--hero-cta); }
    $P .property-video-stage.property-film .property-film-play-mark,$P .property-video-stage.property-film #property-video-status { background:#161d1b; backdrop-filter:none; -webkit-backdrop-filter:none; }
  }
  @media(prefers-contrast:more) {
    $P #listing-nav { background:var(--premium-paper); border-color:var(--ink); }
    $P .listing-cover :is(.property-hero-link,.listing-cover-actions button) { background:#0e1412; border-color:#fff; }
  }
  @media(forced-colors:active) {
    $P #listing-nav,$P .property-page-menu-links,$P #endcard .agent { background:Canvas; color:CanvasText; border:1px solid CanvasText; box-shadow:none; }
    $P .listing-cover :is(.property-hero-link,.listing-cover-actions button) { border:1px solid ButtonText; }
  }

  /* ─────────────── Tablet ─────────────── */
  @media(max-width:900px) {
    $P .listing-cover,$P .listing-cover.property-video-hero { min-height:clamp(600px,100svh,900px); }
    $P .listing-cover .property-hero-title { font-size:clamp(44px,8.6vw,72px); }
    $P #endcard .panel { grid-template-columns:minmax(0,1fr); row-gap:28px; }
    $P #endcard .panel > :not(.agent) { grid-column:1; }
    $P .property-story-spread { gap:40px; }
  }
  /* Full page links collide with the media actions before the phone breakpoint.
     Keep the compact page menu through narrow tablet widths. */
  @media(min-width:601px) and (max-width:900px) {
    $P .listing-nav-links { display:none; }
    $P .property-page-menu { display:block; position:relative; }
    $P .property-page-menu summary { display:flex; align-items:center; justify-content:space-between; gap:10px; min-height:44px; padding:8px 12px; border-radius:12px; cursor:pointer; list-style:none; font-weight:600; }
    $P .property-page-menu summary::-webkit-details-marker { display:none; }
    $P .property-page-menu summary svg { width:12px; height:12px; }
    $P .property-page-menu[open] summary { background:var(--accent-soft); }
    $P .property-page-menu-links { position:absolute; top:calc(100% + 10px); left:0; width:220px; padding:8px; border:1px solid var(--premium-line); border-radius:16px; background:var(--premium-paper); box-shadow:0 20px 48px -16px rgba(20,24,20,.35); }
    $P .property-page-menu-links a { display:flex; align-items:center; min-height:44px; padding:10px 14px; border-radius:10px; }
    $P .property-page-menu-links a[aria-current=page] { background:var(--accent-soft); }
    $P .listing-nav-actions { display:flex; flex:1; justify-content:flex-end; gap:2px; width:auto; }
    $P #listing-nav .listing-nav-actions > :is(a,button) { padding-inline:11px; font-size:12px; }
    $P #listing-nav .listing-nav-actions > .listing-backtop { display:none; }
  }
  /* On short landscape screens the centred identity can sit over the film's
     Play target. Keep the architectural poster, with copy and Play in separate
     halves so both remain visible and independently tappable. */
  @media(min-width:601px) and (max-width:900px) and (orientation:landscape) {
    $S .listing-cover.property-video-hero .property-hero-copy { inset:auto auto clamp(28px,5vh,48px) clamp(24px,4vw,48px); width:min(46%,440px); margin:0; text-align:left; }
    $S .listing-cover.property-video-hero .property-hero-copy .lp-eyebrow,$S .listing-cover.property-video-hero .listing-cover-actions { justify-content:flex-start; }
    $S .listing-cover.property-video-hero .property-hero-title { margin:0; }
    $S .property-video-hero .property-video-stage.property-film .property-video-play { left:75%; }
  }
  @media(max-width:759px) {
    $P .lp-wrap { padding-inline:22px; }
    $P .lp-sec { padding:56px 0; }
    $P .lp-h { font-size:clamp(32px,9vw,44px); margin-bottom:22px; }
    $P .property-story-spread { grid-template-columns:minmax(0,1fr); gap:28px; }
    $P .lp-gal { grid-template-columns:repeat(2,minmax(0,1fr)); gap:10px; }
    /* Signature phones: one generous column, so every editorial row is full. */
    $S .lp-gal { grid-template-columns:minmax(0,1fr); gap:20px; }
    $P #gallery .lp-wrap > .lp-gal > .lp-gcell:first-child img { aspect-ratio:4/3; }
    $P .lp-gcell figcaption { padding-top:8px; font-size:11px; }
    $P .lp-stat { min-width:0; flex-basis:50%; padding:22px 8px; }
    $P .lp-stat:nth-child(odd) { border-left:0; }
    $P .lp-stat:nth-child(n+3) { border-top:1px solid var(--premium-line); }
    $P .lp-stat .v { font-size:30px; }
    $P .lp-stat .k { margin-top:8px; font-size:10px; letter-spacing:.14em; }
    $P .property-location-card { grid-template-columns:minmax(0,1fr); }
    $P .property-location-copy { padding:26px 22px; }
    $P .property-location-visual { min-height:160px; }
    $P #endcard { padding:56px 0; }
    $P #endcard .panel { padding:0 22px; }
    $P #endcard .agent { padding:24px; }
    $P #endcard .agent .avatar { width:72px; height:72px; flex-basis:72px; font-size:24px; }
    $P #endcard .agent .who .nm { font-size:26px; }
    $P .property-page-head { padding:40px 0 20px; }
  }
  /* ─────────────── Phone opening ───────────────
     A full-height portrait opening on the poster; identity, price and every
     action stay inside the first screen. Once the film plays, the opening
     becomes a true 16:9 band with native controls and the identity returns
     below it, so the complete film is never covered or cropped. */
  @media(max-width:600px) {
    $P { --lux-nav-h:48px; --listing-nav-offset:84px; }
    $P #listing-nav { width:calc(100% - 20px); top:10px; margin:10px auto 0; border-radius:16px; }
    $P .listing-nav-inner { display:flex; gap:4px; padding:5px 6px; }
    $P .listing-nav-links { display:none; }
    $P .property-page-menu { display:block; position:relative; }
    $P .property-page-menu summary { display:flex; align-items:center; justify-content:space-between; gap:10px; min-height:44px; padding:8px 12px; border-radius:12px; cursor:pointer; list-style:none; font-weight:600; }
    $P .property-page-menu summary::-webkit-details-marker { display:none; }
    $P .property-page-menu summary svg { width:12px; height:12px; }
    $P .property-page-menu[open] summary { background:var(--accent-soft); }
    $P .property-page-menu-links { position:absolute; top:calc(100% + 10px); left:0; width:220px; padding:8px; border:1px solid var(--premium-line); border-radius:16px; background:var(--premium-paper); box-shadow:0 20px 48px -16px rgba(20,24,20,.35); }
    $P .property-page-menu-links a { display:flex; align-items:center; min-height:44px; padding:10px 14px; border-radius:10px; }
    $P .property-page-menu-links a[aria-current=page] { background:var(--accent-soft); }
    $P .listing-nav-actions { display:flex; flex:1; justify-content:flex-end; gap:2px; width:auto; }
    $P #listing-nav .listing-nav-actions > :is(a,button) { padding-inline:11px; font-size:12px; }
    $P #listing-nav .listing-nav-actions > .listing-backtop { display:none; }
    $P .listing-cover,$P .listing-cover.property-video-hero { min-height:max(600px,calc(100svh - var(--lux-chrome,0px))); max-height:none; margin-top:calc(-1 * (var(--lux-nav-h) + 20px)); }
    /* The preview banner is sticky chrome above the opening; keep the whole identity in the first screen under it. */
    $P.site-preview { --lux-chrome:76px; }
    $P .listing-cover::after { background:linear-gradient(180deg,rgba(6,10,9,.5) 0%,rgba(6,10,9,0) 24%,rgba(6,10,9,0) 44%,rgba(6,10,9,.66) 72%,rgba(6,10,9,.9) 100%); }
    $P .listing-cover .property-hero-copy { inset:auto 20px 22px; width:auto; }
    $P .listing-cover .property-hero-copy .lp-eyebrow { margin-bottom:14px; font-size:10px; }
    $P .listing-cover .property-hero-title { max-width:12ch; font-size:clamp(40px,11vw,52px); line-height:1; }
    $P .listing-cover .property-hero-locality { margin-top:12px; font-size:12px; letter-spacing:.1em; }
    $P .listing-cover .property-hero-price { margin-top:10px; font-size:22px; }
    $P .listing-cover .listing-cover-actions { gap:8px; margin-top:18px; }
    $P .listing-cover :is(.property-hero-link,.listing-cover-actions button) { min-height:46px; padding:12px 18px; font-size:13px; }
    $P .listing-cover .listing-media-label { margin-top:10px; font-size:11px; line-height:1.45; }
    $P .listing-cover .listing-media-label + .listing-media-label { margin-top:2px; }
    $P .listing-cover .property-recorded-option { margin-top:4px; font-size:11px; }
    $P .listing-cover .property-recorded-option summary { min-height:44px; padding-block:4px; }
    $P .property-video-hero .property-video-stage.property-film .property-video-play { top:34%; gap:12px; font-size:10px; }
    $P .property-video-hero .property-video-stage.property-film .property-film-play-mark { width:68px; height:68px; }
    $P .property-video-hero .property-video-stage.property-film .property-film-label { right:16px; bottom:auto; top:calc(var(--lux-nav-h) + 36px); font-size:9.5px; }
    $P .property-video-hero .property-video-stage.property-film #property-video-status { top:calc(34% + 56px); }
    /* Playing: a real 16:9 band, then the identity on the page's own paper. */
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) { display:flex; flex-direction:column; min-height:0; margin-top:0; overflow:visible; color:var(--ink); background:var(--bg); }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing)::after { display:none; }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .property-hero-media { position:relative; order:0; inset:auto; width:100%; height:auto; aspect-ratio:16/9; }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .property-video-stage { aspect-ratio:16/9; }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .property-hero-copy { position:relative; order:1; inset:auto; width:100%; padding:28px 22px 36px; opacity:1; pointer-events:auto; transform:none; color:var(--ink); background:var(--bg); text-shadow:none; text-align:left; }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .property-hero-copy .lp-eyebrow { justify-content:flex-start; color:var(--accent-3); }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .property-hero-title { margin:0; font-size:clamp(36px,10vw,46px); }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) :is(.property-hero-locality,.property-hero-price,.listing-media-label,.property-recorded-option) { color:var(--ink-dim); text-shadow:none; }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .property-hero-price { color:var(--ink); }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .listing-cover-actions { justify-content:flex-start; }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) :is(.property-hero-link,.listing-cover-actions button,.property-recorded-option button) { color:var(--ink); border-color:var(--premium-line-strong); background:transparent; backdrop-filter:none; -webkit-backdrop-filter:none; }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .listing-cover-actions .property-hero-contact { color:var(--on-accent); background:var(--lux-fill); border-color:var(--lux-fill); }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .listing-media-label a { text-decoration-color:var(--premium-line-strong); }
    $S .listing-cover.property-video-hero:has(.property-film.is-playing) .property-recorded-option summary { justify-content:flex-start; padding-inline:0; }
    $P #overview { padding-top:0; }
    .property-site .property-preview-banner { padding:10px 16px; font-size:12px; }
    .property-site .property-preview-watermark { padding:6px 9px; font-size:10px; }
  }
  @media(max-width:374px) {
    /* A full film + walkthrough + share row otherwise runs under Pages at
       320px. Keep the video and share actions at 44px with their accessible
       names, and let the hero retain its first-screen clearance. */
    $P #listing-nav .listing-nav-actions > .property-primary-play,$P #listing-nav #share { width:44px; min-width:44px; padding-inline:0; }
    $P #listing-nav .property-primary-play .nav-short { font-size:0; }
    $P #listing-nav .property-primary-play .nav-short::before { content:"▶"; font-size:13px; line-height:1; }
    $P #listing-nav #share .share-lbl { display:none; }
  }
  @media(max-width:359px) {
    $S .property-video-hero .property-video-stage.property-film .property-video-play { top:26%; }
    $S .property-video-hero .property-video-stage.property-film #property-video-status { top:calc(26% - 14px); }
  }

  /* ═══════════ Signature Estate: an architectural dark opening, then ivory
     editorial spreads. Sharp corners, hairlines, brass only as a whisper. ═══ */
  $S { --bg:#f5f1e9; --premium-paper:#fbf8f1; --premium-glass:rgba(251,248,241,.74); --ink:#1c201d; --ink-dim:#5f645d; --accent:#7a5f31; --accent-3:#7a5f31; --accent-soft:#ece5d4; --premium-line:rgba(28,32,29,.12); --premium-line-strong:rgba(28,32,29,.3); --lux-fill:#1d2320; --lux-fill-hover:#2c342f; --on-accent:#f5f1e9; --hero-bg:#141816; --hero-accent:#d9c493; --hero-cta:#f3ecdc; --hero-cta-ink:#1d2320; --lux-serif:"Iowan Old Style","Palatino Linotype",Palatino,"Book Antiqua",Georgia,"Times New Roman",serif; --lux-radius:0px; --lux-radius-s:4px; }
  $S .listing-cover .property-hero-price { color:var(--hero-accent); }
  $S #gallery { background:#efe9dc; }
  $S #gallery + .lp-sec,$S #story + #gallery { border-top:0; }
  $S .lp-h { letter-spacing:-.03em; }
  $S .lp-stat .v { letter-spacing:-.02em; }
  $S #endcard .agent { border-radius:0; }
  $S .lp-fcol li { padding-left:18px; }
  $S .lp-fcol li::before { display:block; left:0; top:11px; width:6px; height:1px; border-radius:0; background:var(--accent-3); }

  /* ═══════════ Coastal Luxe: sunlit sand, sea glass and open space. The opening
     is a framed panel beside the identity; everything is softly rounded. ═══ */
  $C { --bg:#f8f7f2; --premium-paper:#ffffff; --premium-glass:rgba(255,255,255,.72); --ink:#10302c; --ink-dim:#57716b; --accent:#1f6b60; --accent-3:#1f6b60; --accent-soft:#e4efe9; --premium-line:rgba(16,48,44,.12); --premium-line-strong:rgba(16,48,44,.3); --lux-fill:#124a42; --lux-fill-hover:#0d3b35; --on-accent:#f3f8f5; --hero-bg:#10302c; --hero-accent:#bfe3d6; --hero-cta:#f3f8f5; --hero-cta-ink:#124a42; --lux-serif:"Hoefler Text",Baskerville,"Baskerville Old Face","Palatino Linotype",Palatino,Georgia,"Times New Roman",serif; --lux-radius:24px; --lux-radius-s:14px; }
  $C .lp-h,$C .property-hero-title,$C .property-page-head h1,$C .panel h2 { letter-spacing:-.02em; }
  $C #listing-nav { border-radius:999px; }
  $C .lp-sec + .lp-sec { border-top:0; }
  $C #story { background:var(--premium-paper); }
  $C #story .lp-wrap { padding-block:0; }
  $C .property-story-photo { order:1; }
  $C .property-story-photo img { border-radius:var(--lux-radius); }
  $C .lp-stats { border-top:1px solid var(--premium-line); }
  $C #features { background:var(--premium-paper); }
  $C .lp-fcol li { padding-left:20px; }
  $C .lp-fcol li::before { display:block; left:0; top:9px; width:6px; height:6px; border-radius:50%; background:var(--accent-3); opacity:.7; }
  $C .property-location-card { border-radius:28px; }
  $C #endcard { background:var(--premium-paper); border-top:1px solid var(--premium-line); }
  $C #endcard .agent { border-radius:28px; background:var(--bg); }
  $C .field input,$C .field textarea { background:var(--bg); }
  $C .property-video-hero .property-video-stage.property-film .property-film-label { left:20px; right:auto; }
  /* Desktop and tablet-wide: identity beside the framed media panel. */
  @media(min-width:901px), (min-width:601px) and (orientation:landscape) {
    $C .listing-cover,$C .listing-cover.property-video-hero { display:grid; grid-template-columns:minmax(0,.78fr) minmax(0,1.22fr); align-items:center; gap:clamp(28px,4vw,64px); width:calc(100% - clamp(40px,6vw,96px)); max-width:1440px; min-height:0; margin:clamp(20px,3vw,36px) auto 0; padding:0; overflow:visible; color:var(--ink); background:transparent; }
    $C .listing-cover::after { display:none; }
    $C .listing-cover .property-hero-copy { position:static; align-self:center; width:auto; max-width:560px; margin:0; padding:clamp(24px,3vw,40px) 0; color:var(--ink); text-align:left; text-shadow:none; }
    $C .listing-cover .property-hero-copy .lp-eyebrow { justify-content:flex-start; color:var(--accent-3); }
    $C .listing-cover .property-hero-copy .lp-eyebrow::before { display:block; }
    $C .listing-cover .property-hero-title { margin:0; max-width:none; font-size:clamp(44px,4.8vw,74px); line-height:1; letter-spacing:-.025em; }
    $C .listing-cover .property-hero-locality { color:var(--ink-dim); }
    $C .listing-cover .property-hero-price { color:var(--ink); }
    $C .listing-cover .listing-cover-actions { justify-content:flex-start; }
    $C .listing-cover :is(.property-hero-link,.listing-cover-actions button,.property-recorded-option button) { color:var(--ink); border-color:var(--premium-line-strong); background:transparent; backdrop-filter:none; -webkit-backdrop-filter:none; }
    $C .listing-cover .listing-cover-actions .property-hero-contact { color:var(--on-accent); background:var(--lux-fill); border-color:var(--lux-fill); }
    $C .listing-cover .listing-media-label,$C .listing-cover .property-recorded-option { color:var(--ink-dim); }
    $C .listing-cover .listing-media-label a { text-decoration-color:var(--premium-line-strong); }
    $C .listing-cover .property-recorded-option summary { justify-content:flex-start; padding-inline:0; }
    $C .property-hero-media,$C .property-video-hero .property-hero-media { position:relative; inset:auto; align-self:center; width:100%; height:auto; min-height:0; aspect-ratio:16/9; border-radius:32px; overflow:hidden; box-shadow:0 30px 80px -40px rgba(16,48,44,.45); }
    $C .listing-cover:has(.property-film.is-playing) .property-hero-copy { opacity:1; pointer-events:auto; transform:none; }
  }
  @media(hover:hover) and (pointer:fine) and (min-width:901px) {
    $C .listing-cover :is(.property-hero-link:not(.property-hero-contact),.listing-cover-actions button,.property-recorded-option button):hover { background:var(--accent-soft); border-color:var(--premium-line-strong); }
    $C .listing-cover .listing-cover-actions .property-hero-contact:hover { background:var(--lux-fill-hover); border-color:var(--lux-fill-hover); }
  }
  /* Phones and narrow tablets: the framed panel first, then the identity. */
  @media(max-width:600px), (max-width:900px) and (orientation:portrait) {
    $C .listing-cover,$C .listing-cover.property-video-hero { display:flex; flex-direction:column; min-height:0; max-height:none; margin:8px 0 0; overflow:visible; color:var(--ink); background:var(--bg); }
    $C .listing-cover::after { display:none; }
    $C .property-hero-media,$C .property-video-hero .property-hero-media { position:relative; order:0; inset:auto; width:calc(100% - 24px); height:auto; aspect-ratio:4/3; margin:0 auto; border-radius:24px; overflow:hidden; box-shadow:0 24px 60px -36px rgba(16,48,44,.5); transition:aspect-ratio .4s var(--lux-ease); }
    $C .listing-cover:has(.property-film.is-playing) .property-hero-media { aspect-ratio:16/9; }
    $C .listing-cover .property-hero-copy,$C .listing-cover:has(.property-film.is-playing) .property-hero-copy { position:relative; order:1; inset:auto; width:100%; margin:0; padding:26px 22px 4px; opacity:1; pointer-events:auto; transform:none; color:var(--ink); background:transparent; text-align:left; text-shadow:none; }
    $C .listing-cover .property-hero-copy .lp-eyebrow { justify-content:flex-start; color:var(--accent-3); }
    $C .listing-cover .property-hero-copy .lp-eyebrow::before { display:block; }
    $C .listing-cover .property-hero-title { margin:0; max-width:none; font-size:clamp(38px,9.5vw,64px); line-height:1; }
    $C .listing-cover .property-hero-locality { color:var(--ink-dim); }
    $C .listing-cover .property-hero-price { color:var(--ink); }
    $C .listing-cover .listing-cover-actions { justify-content:flex-start; }
    $C .listing-cover :is(.property-hero-link,.listing-cover-actions button,.property-recorded-option button) { color:var(--ink); border-color:var(--premium-line-strong); background:transparent; backdrop-filter:none; -webkit-backdrop-filter:none; }
    $C .listing-cover .listing-cover-actions .property-hero-contact { color:var(--on-accent); background:var(--lux-fill); border-color:var(--lux-fill); }
    $C .listing-cover .listing-media-label,$C .listing-cover .property-recorded-option { color:var(--ink-dim); }
    $C .listing-cover .listing-media-label a { text-decoration-color:var(--premium-line-strong); }
    $C .listing-cover .property-recorded-option summary { justify-content:flex-start; padding-inline:0; }
    $C .property-video-hero .property-video-stage.property-film .property-video-play { top:50%; }
    $C .property-video-hero .property-video-stage.property-film #property-video-status { top:calc(50% + 60px); }
    $C .property-video-hero .property-video-stage.property-film .property-film-label { top:auto; bottom:14px; left:16px; right:auto; }
    $C #overview { padding-top:0; }
    $C #overview .lp-stats { margin-top:28px; }
  }
  @media(max-width:600px) {
    $C .property-hero-media,$C .property-video-hero .property-hero-media { aspect-ratio:1/1; }
    $C .listing-cover,$C .listing-cover.property-video-hero { margin-top:6px; }
  }
  @media(max-width:359px) {
    $C .property-hero-media,$C .property-video-hero .property-hero-media { aspect-ratio:16/9; }
  }
`;

export const PROPERTY_DESIGN_CSS = `
  .property-site .property-preview-banner { position:sticky; top:0; z-index:9; padding:14px 24px; background:#352349; color:white; text-align:center; font:600 13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  .property-site .property-preview-banner span { display:block; font-weight:400; }
  .property-site .property-preview-watermark { position:fixed; right:12px; bottom:12px; z-index:8; padding:8px 14px; background:rgba(53,35,73,.9); border:1px solid rgba(255,255,255,.5); border-radius:12px; color:white; pointer-events:none; font:600 12px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; letter-spacing:.08em; }
  .property-site.site-preview #listing-nav { position:relative; top:auto; }
  .property-site .property-recorded-option { margin-top:22px; border-top:1px solid rgba(120,120,130,.2); padding-top:14px; font-size:13px; color:var(--ink-dim); }
  .property-site .property-recorded-option summary { cursor:pointer; padding:8px 0; }
  .property-site .property-recorded-option p { padding:12px 0; }
  .property-site .property-recorded-option button { font:inherit; color:var(--ink); background:var(--card); padding:12px 16px; border:1px solid rgba(120,120,130,.3); border-radius:12px; cursor:pointer; }
  .property-site #listing-nav .walkthrough-secondary { background:transparent; border-color:transparent; font-weight:400; color:inherit; }
  .property-site #listing-nav .property-primary-play { background:var(--accent-3); border:1px solid transparent; color:#fff; font-weight:600; }
` + DESIGN_CSS.split("$P").join(PAID).split("$S").join(SIGNATURE).split("$C").join(COASTAL);
