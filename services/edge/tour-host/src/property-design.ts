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

// Derived from the owner's PILK Signature Estate and Coastal Luxe templates.
// Local system fonts only; no example properties, tracking, remote fonts or
// theme-specific media. Every design uses the same actual listing components.
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

  /* Paid layouts share the actual renderer, not content or entitlement logic.
     System display faces and the published property's own photographs only. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; --grad-text:linear-gradient(var(--ink),var(--ink)); --card:var(--premium-paper); --premium-line:rgba(34,48,42,.18); }
  .property-site.site-theme-signature-estate { --bg:#f4f0e7; --premium-paper:#fffcf5; --ink:#242a26; --ink-dim:#62675e; --accent:#8b6b3d; --accent-3:#72532c; --accent-soft:#e9dfcb; background:var(--bg); }
  .property-site.site-theme-coastal-luxe { --bg:#faf9f3; --premium-paper:#edf3ed; --ink:#163e38; --ink-dim:#50675e; --accent:#25695d; --accent-3:#18594d; --accent-soft:#dfebe3; background:var(--bg); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-wrap { max-width:1280px; padding-inline:48px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { position:sticky; top:12px; width:calc(100% - 48px); max-width:1320px; margin:12px auto 24px; border:1px solid var(--premium-line); border-radius:999px; color:var(--ink); background:var(--premium-paper); box-shadow:0 8px 32px #182d2310,inset 0 1px #ffffffcc; }
  .property-site.site-preview:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { position:relative; top:auto; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-nav-inner { padding:7px 10px; gap:12px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav :is(a,button,summary) { min-height:44px; min-width:44px; color:var(--ink); border:0; border-radius:999px; font:500 12px/1.3 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; letter-spacing:0; padding:10px 13px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav a[aria-current=page] { color:var(--accent-3); background:var(--accent-soft); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav :is(.property-primary-play,.watch-button) { color:#fff; background:var(--accent-3); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .walkthrough-secondary { color:var(--ink-dim); background:transparent; }
  .property-site .property-page-menu { display:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) :is(a,button,summary,input,textarea):focus-visible { outline:3px solid var(--accent); outline-offset:4px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { display:grid; grid-template-columns:minmax(0,.9fr) minmax(0,1.1fr); align-items:center; max-width:1440px; width:calc(100% - 48px); margin:0 auto; min-height:0; overflow:visible; border:0; border-radius:0; box-shadow:none; color:var(--ink); background:transparent; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover::after { display:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-media { min-width:0; overflow:hidden; background:#202b26; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-media > img { display:block; width:100%; height:480px; max-height:none; object-fit:cover; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-copy { position:static; max-width:none; padding:clamp(28px,4vw,64px); color:inherit; background:transparent; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-title { text-wrap:balance; overflow-wrap:anywhere; margin:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-locality { display:block; margin-top:18px; font:400 13px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; letter-spacing:.015em; color:var(--hero-dim,var(--ink-dim)); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-eyebrow { color:var(--accent-3); letter-spacing:.18em; font-weight:600; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-eyebrow::before { background:currentColor; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-copy .lp-eyebrow { margin-bottom:22px; color:var(--hero-accent,var(--accent-3)); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-price { color:inherit; font:400 25px/1.3 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; letter-spacing:-.03em; margin:24px 0 0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions { display:flex; flex-wrap:wrap; gap:10px; margin-top:24px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover :is(.property-hero-link,.listing-cover-actions button) { display:inline-flex; align-items:center; justify-content:center; min-height:44px; padding:12px 19px; border:1px solid var(--hero-line,var(--premium-line)); border-radius:999px; color:inherit; background:transparent; font:500 12px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; text-decoration:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions .property-hero-contact { color:var(--hero-button-ink,#fff); background:var(--hero-button,var(--accent-3)); border-color:transparent; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover-actions p { display:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-media-label { display:block; color:var(--hero-dim,var(--ink-dim)); padding:0; margin-top:18px; font-size:10px; line-height:1.7; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-media-label a { color:inherit; text-decoration:underline; text-underline-offset:3px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option { margin-top:14px; padding-top:2px; border-color:var(--hero-line,var(--premium-line)); color:var(--hero-dim,var(--ink-dim)); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option summary { display:flex; align-items:center; gap:10px; min-height:44px; padding:6px 0; font-size:12px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option summary::before { content:"+"; font-size:18px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option[open] summary::before { content:"−"; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option button { color:inherit; border-radius:999px; min-height:44px; background:transparent; border-color:var(--hero-line,var(--premium-line)); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-sec { padding:88px 0; border-color:var(--premium-line); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-h { font-size:clamp(32px,4vw,54px); line-height:1.1; margin-bottom:24px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview { padding:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview .lp-eyebrow { display:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stats { border:0; border-bottom:1px solid var(--premium-line); gap:0; margin:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat { flex:1; border:0; border-radius:0; box-shadow:none; background:transparent; padding:30px 20px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat + .lp-stat { border-left:1px solid var(--premium-line); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat .v { font:400 32px/1.15 Georgia,serif; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat .k { color:var(--ink-dim); letter-spacing:.12em; font-size:10px; margin-top:8px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-prose { color:var(--ink-dim); font-size:17px; line-height:1.9; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-prose p { max-width:62ch; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-story-spread { display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); align-items:center; gap:clamp(32px,7vw,96px); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-story-photo { margin:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-story-photo img { width:100%; aspect-ratio:4/5; object-fit:cover; display:block; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-story-photo figcaption { font-size:11px; color:var(--ink-dim); margin-top:14px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell { border:0; padding:0; box-shadow:none; background:transparent; border-radius:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell img { transition:none; transform:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell figcaption { padding:14px 0 0; font-size:12px; color:var(--ink-dim); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-fact,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-level,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .disc-item { background:transparent; border:0; border-bottom:1px solid var(--premium-line); border-radius:0; box-shadow:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .disc-sum { display:flex; align-items:center; gap:8px; width:fit-content; max-width:100%; min-height:44px; padding:12px 18px; border:1px solid var(--premium-line); border-radius:999px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-feat { gap:40px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-fcol { border-top:1px solid var(--premium-line); padding-top:24px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-fcol h3 { font:500 13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; letter-spacing:.08em; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-page-head { padding:54px 0 36px; color:var(--ink); background:transparent; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-page-head p { color:var(--ink-dim); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-card { border:0; border-radius:0; background:var(--premium-paper); box-shadow:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-copy { padding:40px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-copy address { font-size:clamp(25px,3vw,38px); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-visual { background-color:var(--accent-soft); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-visual span { background:var(--accent-3); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-nearby-list li { border:0; border-top:1px solid var(--premium-line); border-radius:0; background:transparent; padding:20px 0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-nearby-list a { color:var(--ink); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-nearby-map { --nearby-paper:var(--premium-paper); --nearby-ring:var(--premium-line); --nearby-ink:var(--ink); --nearby-dim:var(--ink-dim); --nearby-home:var(--accent-3); margin-top:32px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-nearby-list { margin-top:32px; }
  .property-site.site-theme-signature-estate .property-nearby-map { --nearby-restaurant:#9a4a2c; --nearby-cafe:#7d613f; --nearby-shop:#4d6b5a; }
  .property-site.site-theme-coastal-luxe .property-nearby-map { --nearby-restaurant:#a9532f; --nearby-cafe:#8c6d2c; --nearby-shop:#216b58; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel { max-width:1184px; width:100%; padding:56px; border:1px solid var(--premium-line); border-radius:0; box-shadow:none; background:var(--premium-paper); display:grid; grid-template-columns:minmax(0,.8fr) minmax(0,1.2fr); column-gap:80px; text-align:left; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .agent { align-self:start; margin:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .agent .avatar { width:64px; height:64px; flex-basis:64px; border:1px solid var(--premium-line); background:var(--accent-soft); color:var(--ink); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .agent .nm { font-size:24px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel > :not(.agent) { grid-column:2; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel > :is(.disclosure,.property-preview-note) { grid-column:1/-1; margin-top:32px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .field input,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .field textarea { background:var(--bg); border-color:#a8afa5; border-radius:14px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) :is(.lp-btn,.cta) { color:white; background:var(--accent-3); border-radius:999px; box-shadow:none; min-height:44px; padding:13px 22px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-btn.ghost { color:var(--ink); background:transparent; border:1px solid var(--premium-line); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) :is(.privacy,.privacy a,.disclosure) { color:var(--ink-dim); }
  /* Signature: a dark architectural opening, then ivory editorial spreads. */
  .property-site.site-theme-signature-estate :is(.property-hero-title,.lp-h,.property-page-head h1,.panel h2,.property-location-copy address) { font-family:"Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif; font-weight:400; letter-spacing:-.035em; }
  .property-site.site-theme-signature-estate .listing-cover { --hero-dim:#c6c6b9; --hero-accent:#d1b780; --hero-line:#e6dfca55; --hero-button:#e4d4b0; --hero-button-ink:#202620; background:#1d2521; color:#faf6e9; }
  .property-site.site-theme-signature-estate .listing-cover.property-video-hero { background:#1d2521; color:#faf6e9; }
  .property-site.site-theme-signature-estate .property-hero-title { font-size:clamp(40px,4.2vw,64px); line-height:1.04; }
  .property-site.site-theme-signature-estate .property-hero-media { align-self:stretch; display:grid; align-items:center; }
  .property-site.site-theme-signature-estate .property-hero-media > img { height:100%; min-height:460px; max-height:570px; }
  .property-site.site-theme-signature-estate .lp-gal { gap:40px; grid-template-columns:repeat(2,minmax(0,1fr)); align-items:start; }
  .property-site.site-theme-signature-estate .lp-gcell:nth-child(even) { margin-top:72px; }
  .property-site.site-theme-signature-estate .lp-gcell img { aspect-ratio:4/3; border-radius:0; }
  .property-site.site-theme-signature-estate #gallery { background:#e9e6dc; }
  .property-site.site-theme-signature-estate #endcard .panel { border:0; border-top:1px solid var(--premium-line); background:transparent; }
  .property-site.site-theme-signature-estate .panel h2 { font-size:42px; }
  /* Coastal: sunlit asymmetric photography, sea-glass paper and open space. */
  .property-site.site-theme-coastal-luxe .listing-cover { max-width:1280px; grid-template-columns:minmax(0,.85fr) minmax(0,1.15fr); gap:56px; padding:24px 32px 56px; }
  .property-site.site-theme-coastal-luxe .listing-cover .property-hero-copy { padding:0; }
  .property-site.site-theme-coastal-luxe :is(.property-hero-title,.lp-h,.property-page-head h1,.panel h2,.property-location-copy address) { font-family:Georgia,"Times New Roman",serif; font-weight:400; letter-spacing:-.045em; }
  .property-site.site-theme-coastal-luxe .property-hero-title { font-size:clamp(40px,4.3vw,62px); line-height:1.08; }
  .property-site.site-theme-coastal-luxe .property-hero-media { border-radius:48% 48% 4px 4px; box-shadow:20px 24px 0 #dfe9df; }
  .property-site.site-theme-coastal-luxe .property-video-hero .property-hero-media { border-radius:24px 24px 4px 4px; }
  .property-site.site-theme-coastal-luxe #overview .lp-wrap { max-width:1184px; background:var(--premium-paper); }
  .property-site.site-theme-coastal-luxe .lp-gal { gap:24px; grid-template-columns:repeat(2,minmax(0,1fr)); }
  .property-site.site-theme-coastal-luxe #gallery .lp-wrap > .lp-gal > .lp-gcell:first-child { grid-column:1/-1; }
  .property-site.site-theme-coastal-luxe #gallery .lp-wrap > .lp-gal > .lp-gcell:first-child img { aspect-ratio:2/1; }
  .property-site.site-theme-coastal-luxe .lp-gcell img { border-radius:4px; aspect-ratio:4/3; }
  .property-site.site-theme-coastal-luxe #story { background:var(--premium-paper); }
  .property-site.site-theme-coastal-luxe .property-story-photo { order:1; }
  .property-site.site-theme-coastal-luxe .property-story-photo img { border-radius:120px 4px 4px 4px; }
  .property-site.site-theme-coastal-luxe .property-location-card { grid-template-columns:1.2fr .8fr; border-radius:24px; }
  .property-site.site-theme-coastal-luxe #endcard .panel { border-radius:28px; background:var(--premium-paper); }
  @supports ((backdrop-filter:blur(16px)) or (-webkit-backdrop-filter:blur(16px))) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { background:#fffcf5e8; backdrop-filter:blur(20px) saturate(1.15); -webkit-backdrop-filter:blur(20px) saturate(1.15); }
  }
  @media(prefers-reduced-motion:reduce) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *, .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *::before, .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *::after { transition:none!important; animation:none!important; scroll-behavior:auto!important; }
  }
  @media(prefers-reduced-transparency:reduce) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { background:var(--premium-paper); backdrop-filter:none; -webkit-backdrop-filter:none; }
  }
  @media(max-width:900px) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { grid-template-columns:minmax(0,1fr); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-media > img { height:340px; min-height:0; }
    .property-site.site-theme-coastal-luxe .listing-cover { gap:28px; padding:20px 8px 40px; }
    .property-site.site-theme-coastal-luxe .property-hero-media { margin:0 20px 16px 0; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel { grid-template-columns:minmax(0,1fr); gap:32px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel > :not(.agent) { grid-column:1; }
  }
  @media(max-width:759px) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-wrap { padding-inline:24px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { width:calc(100% - 24px); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-copy { padding:28px 24px; }
    .property-site.site-theme-coastal-luxe .listing-cover .property-hero-copy { padding:8px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-title { font-size:40px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-locality { margin-top:12px; font-size:12px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-copy .lp-eyebrow { margin-bottom:16px; font-size:10px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-price { margin-top:18px; font-size:23px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions { gap:8px; margin-top:18px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover :is(.property-hero-link,.listing-cover-actions button) { padding:12px 14px; font-size:11px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-sec { padding:56px 0; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat { padding:24px 8px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat .v { font-size:27px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-story-spread { grid-template-columns:minmax(0,1fr); gap:32px; }
    .property-site.site-theme-coastal-luxe .property-story-photo { order:0; }
    .property-site.site-theme-signature-estate .lp-gal { gap:24px; grid-template-columns:minmax(0,1fr); }
    .property-site.site-theme-signature-estate .lp-gcell:nth-child(even) { margin-top:0; }
    .property-site.site-theme-coastal-luxe #gallery .lp-wrap > .lp-gal > .lp-gcell:first-child img { aspect-ratio:4/3; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel { padding:32px 24px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-copy { padding:28px; }
  }
  /* Room-grouped editorial Gallery: a small rule-led heading above each room. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal-rooms { display:grid; gap:56px; margin-top:28px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal-room-title { display:flex; align-items:baseline; gap:14px; margin:0 0 18px; font:600 12px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; letter-spacing:.16em; text-transform:uppercase; color:var(--accent-3); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal-room-title::after { content:""; flex:1; height:1px; background:var(--premium-line); align-self:center; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal-room-count { order:1; color:var(--ink-dim); font-weight:400; letter-spacing:0; text-transform:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal-rooms .lp-mediadate { margin-top:0; }
  /* Rows fill edge to edge in document order (the order the photo viewer
     walks). Two kinds of row: the photos of a room with several photos, and a
     run of consecutive one-photo rooms (.lp-gal-run), which shares the same
     columns so those rooms sit side by side at the ordinary size. A short last
     row widens instead of leaving empty columns; widened photos take a 16:9
     crop, and the viewer always opens the complete photo. Within a run, each
     room's photo sits at the foot of its cell, so photos in a row stay aligned
     even when one heading wraps. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal-run { display:grid; row-gap:56px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal-run > .lp-gal-room { display:flex; flex-direction:column; justify-content:flex-end; min-width:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal-run .lp-gal { grid-template-columns:minmax(0,1fr); }
  @media(min-width:760px) {
    /* Signature: two columns. */
    .property-site.site-theme-signature-estate .lp-gal-run { grid-template-columns:repeat(2,minmax(0,1fr)); column-gap:32px; }
    .property-site.site-theme-signature-estate :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(odd):last-child { grid-column:1/-1; }
    .property-site.site-theme-signature-estate :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(odd):last-child img { aspect-ratio:16/9; }
    /* Coastal: three columns as six tracks, so a last row of two shares the width. */
    .property-site.site-theme-coastal-luxe :is(.lp-gal-rooms > .lp-gal-room > .lp-gal,.lp-gal-run) { grid-template-columns:repeat(6,minmax(0,1fr)); }
    .property-site.site-theme-coastal-luxe .lp-gal-run { column-gap:24px; }
    .property-site.site-theme-coastal-luxe :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room) { grid-column:span 2; }
    .property-site.site-theme-coastal-luxe :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):is(:nth-child(3n+1):nth-last-child(2),:nth-child(3n+2):last-child) { grid-column:span 3; }
    .property-site.site-theme-coastal-luxe :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(3n+1):last-child { grid-column:1/-1; }
    .property-site.site-theme-coastal-luxe :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):is(:nth-child(3n+1):nth-last-child(-n+2),:nth-child(3n+2):last-child) img { aspect-ratio:16/9; }
  }
  @media(max-width:759px) {
    /* Coastal phones: two columns. Signature phones are one column already. */
    .property-site.site-theme-coastal-luxe .lp-gal-run { grid-template-columns:repeat(2,minmax(0,1fr)); column-gap:16px; }
    /* Half-width cells have no room for the heading rule; never leave a stub. */
    .property-site.site-theme-coastal-luxe .lp-gal-run > .lp-gal-room:not(:nth-child(odd):last-child) .lp-gal-room-title::after { display:none; }
    .property-site.site-theme-coastal-luxe :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(odd):last-child { grid-column:1/-1; }
    .property-site.site-theme-coastal-luxe :is(.lp-gal-rooms > .lp-gal-room > .lp-gal > .lp-gcell,.lp-gal-run > .lp-gal-room):nth-child(odd):last-child img { aspect-ratio:16/9; }
  }
  /* Paid property openings use the property's own media as the architecture.
     The complete film stays opt-in and uncropped; photo openings may crop the
     display image, with the complete image available in Gallery. The floating
     material navigation retains its native, keyboard-accessible links. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { z-index:7; }
  /* Move only the visible hero under the floating navigation. The main landmark
     stays after the nav in layout, so Skip to content clears sticky chrome. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { position:relative; display:block; isolation:isolate; width:100%; max-width:none; min-height:clamp(640px,calc(100svh - 28px),940px); margin:0 0 -100px; transform:translateY(-100px); overflow:hidden; color:#fff; background:#1d2925; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover::after { display:block; position:absolute; inset:0; z-index:1; content:""; pointer-events:none; background:linear-gradient(90deg,rgba(8,17,14,.68),rgba(8,17,14,.25) 58%,transparent 95%),linear-gradient(180deg,rgba(10,18,16,.3) 0%,transparent 32%,rgba(10,18,16,.13) 48%,rgba(7,14,13,.82) 100%); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-media { position:absolute; inset:0; width:100%; height:100%; overflow:hidden; background:#1d2925; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-media > img { display:block; width:100%; height:100%; max-height:none; min-height:0; object-fit:cover; object-position:center center; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-copy { position:absolute; z-index:2; inset:auto auto clamp(30px,5vw,72px) clamp(24px,6vw,96px); width:min(760px,calc(100% - 48px)); max-width:none; padding:0; color:#fff; background:transparent; text-shadow:0 2px 24px rgba(0,0,0,.24); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-copy .lp-eyebrow { margin-bottom:16px; color:#f2e6c8; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-title { max-width:13ch; font-size:clamp(56px,7.5vw,118px); line-height:.95; letter-spacing:-.055em; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-locality { margin-top:16px; color:#fff; font-size:clamp(14px,1.3vw,18px); line-height:1.4; text-shadow:0 2px 12px rgba(0,0,0,.55); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-price { margin-top:12px; color:#fff; font-size:clamp(20px,2vw,27px); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions { margin-top:20px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover :is(.property-hero-link,.listing-cover-actions button) { min-height:48px; padding:13px 22px; border:1px solid rgba(255,255,255,.72); border-radius:999px; color:#fff; background:rgba(12,21,18,.34); text-shadow:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions .property-hero-contact { color:#1e2824; background:#f7f2e8; border-color:#f7f2e8; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-media-label { margin-top:12px; color:#fff; font-size:11px; line-height:1.5; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-recorded-option { border-color:rgba(255,255,255,.5); color:#fff; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-recorded-option button { border-color:rgba(255,255,255,.7); color:#fff; }
  .property-site.site-theme-coastal-luxe .listing-cover { background:#173a34; }
  .property-site.site-theme-coastal-luxe .listing-cover::after { background:linear-gradient(90deg,rgba(7,33,30,.7),rgba(7,33,30,.27) 58%,transparent 95%),linear-gradient(180deg,rgba(9,32,31,.24),transparent 30%,rgba(9,36,34,.12) 47%,rgba(8,43,39,.86) 100%); }
  .property-site.site-theme-coastal-luxe .property-hero-media { border-radius:0; box-shadow:none; }
  .property-site.site-theme-coastal-luxe .listing-cover .listing-cover-actions .property-hero-contact { color:#124a40; background:#f4f7ef; border-color:#f4f7ef; }
  /* The film keeps its true 16:9 frame and native controls after explicit Play.
     Desktop overlays the identity in the dark lower-left, clear of the center
     play target; on a phone the film and address are separate, readable bands. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover.property-video-hero { min-height:0; background:#1d2925; color:#fff; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-media { position:relative; inset:auto; height:auto; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-video-stage { width:100%; aspect-ratio:16/9; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-copy { position:absolute; inset:auto auto clamp(60px,6vw,100px) clamp(24px,6vw,96px); z-index:3; width:min(540px,43%); padding:0; color:#fff; background:transparent; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-title { font-size:clamp(48px,5.2vw,84px); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .listing-media-label { color:#fff; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero::after { background:linear-gradient(90deg,rgba(8,17,15,.74),transparent 59%),linear-gradient(0deg,rgba(8,17,15,.56),transparent 54%); }
  /* The poster and Play control must be visible on the first paint. Media
     decoding already has an explicit loading status after a deliberate tap. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-video-stage.property-film,
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-video-stage.property-film > video,
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-video-stage.property-film .property-video-play,
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-video-stage.property-film .property-film-label { animation:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview { padding:64px 0 0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview .lp-wrap { max-width:1200px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stats { margin-top:20px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat { padding-block:32px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat .v { font-size:clamp(31px,3.6vw,52px); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat .k { letter-spacing:.08em; font-size:11px; }
  @media(max-width:900px) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { min-height:720px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-title { font-size:clamp(50px,10vw,78px); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover.property-video-hero { min-height:0; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-title { font-size:clamp(42px,5.8vw,60px); }
  }
  @media(max-width:600px) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { min-height:max(690px,calc(100svh - 52px)); margin-bottom:-70px; transform:translateY(-70px); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-copy { inset:auto 22px 30px; width:auto; padding:0; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-title { max-width:12ch; font-size:clamp(43px,10.5vw,58px); line-height:.99; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-locality { margin-top:12px; font-size:13px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-price { margin-top:9px; font-size:21px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions { gap:8px; margin-top:16px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover :is(.property-hero-link,.listing-cover-actions button) { padding:11px 14px; font-size:11px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover.property-video-hero { display:flex; flex-direction:column; min-height:0; overflow:visible; background:var(--bg); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover.property-video-hero::after { display:none; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-media { order:0; width:100%; height:auto; margin:0; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-copy { position:relative; order:1; inset:auto; width:100%; padding:32px 24px 44px; color:var(--ink); background:var(--bg); text-shadow:none; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-title { font-size:clamp(44px,11vw,60px); color:var(--ink); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-copy .lp-eyebrow { color:var(--accent-3); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-locality,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-price,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .listing-media-label { color:var(--ink); text-shadow:none; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .listing-cover-actions :is(.property-hero-link,button) { color:var(--ink); border-color:var(--premium-line); background:transparent; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .listing-cover-actions .property-hero-contact { color:#fff; background:var(--accent-3); border-color:var(--accent-3); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-recorded-option { color:var(--ink-dim); border-color:var(--premium-line); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-recorded-option button { color:var(--ink); border-color:var(--premium-line); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview { padding-top:34px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stats { grid-template-columns:repeat(2,minmax(0,1fr)); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat { min-width:0; padding:20px 10px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat:nth-child(odd) { border-left:0; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat .v { font-size:31px; }
  }
  @media(prefers-reduced-transparency:reduce) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover :is(.property-hero-link,.listing-cover-actions button) { background:#172822; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions .property-hero-contact { background:#f7f2e8; }
  }
  @media(max-width:600px) {
    .property-site .property-preview-banner { padding:10px 16px; font-size:12px; }
    .property-site .property-preview-watermark { padding:6px 9px; font-size:10px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { width:calc(100% - 24px); top:8px; margin:8px auto 18px; border-radius:14px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-nav-inner { display:flex; gap:4px; padding:5px 6px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-nav-links { display:none; }
    .property-site .property-page-menu { display:block; }
    .property-site .property-page-menu summary { display:flex; align-items:center; justify-content:space-between; gap:12px; cursor:pointer; list-style:none; }
    .property-site .property-page-menu summary::-webkit-details-marker { display:none; }
    .property-site .property-page-menu summary svg { width:12px; height:12px; }
    .property-site .property-page-menu[open] summary { background:var(--accent-soft); }
    .property-site .property-page-menu-links { position:absolute; top:calc(100% + 8px); left:0; width:200px; padding:8px; border:1px solid var(--premium-line); border-radius:14px; background:var(--premium-paper); box-shadow:0 12px 32px rgba(25,35,25,.12); }
    .property-site .property-page-menu-links a { display:flex; align-items:center; padding:12px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-nav-actions { display:flex; justify-content:flex-end; gap:2px; width:auto; flex:1; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .listing-nav-actions > :is(a,button) { padding-inline:9px; font-size:11px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .listing-nav-actions > .listing-backtop { display:none; }
  }
  @media(forced-colors:active) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav,.property-site .property-page-menu-links { background:Canvas; color:CanvasText; border:1px solid CanvasText; box-shadow:none; }
  }
`;
