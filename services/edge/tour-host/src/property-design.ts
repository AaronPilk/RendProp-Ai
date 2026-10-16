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

  /* Premium presentation is scoped to the server-selected theme. Every media,
     fact, link and enquiry still comes from the shared property renderer. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; --grad-text:linear-gradient(var(--ink),var(--ink)); --premium-line:rgba(40,46,40,.18); --card:var(--premium-paper); }
  .property-site.site-theme-signature-estate { --bg:#f5f1e9; --premium-paper:#fffdf8; --ink:#29251e; --ink-dim:#635b50; --accent:#7d613f; --accent-3:#735538; --accent-soft:#eae2d4; background:var(--bg); }
  .property-site.site-theme-coastal-luxe { --bg:#f7f7ef; --premium-paper:#edf3ed; --ink:#173c34; --ink-dim:#4d665c; --accent:#216b58; --accent-3:#185440; --accent-soft:#dce9df; background:var(--bg); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-wrap { max-width:1240px; padding-inline:40px; }
  /* One floating material surface; all other sections have a quiet, open edge.
     The opaque base works without blur, script, or reduced-transparency support. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { position:sticky; top:12px; width:calc(100% - 48px); max-width:1192px; margin:12px auto 24px; border:1px solid var(--premium-line); border-radius:18px; color:var(--ink); background:var(--premium-paper); box-shadow:0 8px 28px rgba(30,40,30,.07),inset 0 1px rgba(255,255,255,.8); }
  .property-site.site-preview:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { position:relative; top:auto; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-nav-inner { padding:7px 10px; gap:12px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav :is(a,button,summary) { min-height:44px; min-width:44px; color:var(--ink); border:0; border-radius:10px; font:500 12px/1.3 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; letter-spacing:0; padding:10px 13px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav a[aria-current=page] { color:var(--accent-3); background:var(--accent-soft); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav :is(.property-primary-play,.watch-button) { color:#fff; background:var(--accent-3); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .walkthrough-secondary { color:var(--ink-dim); background:transparent; }
  .property-site .property-page-menu { display:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) a:focus-visible,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) button:focus-visible,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) summary:focus-visible { outline:3px solid var(--accent-3); outline-offset:3px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { max-width:1200px; width:calc(100% - 48px); margin:0 auto; min-height:0; overflow:visible; border:0; border-radius:0; box-shadow:none; background:transparent; color:var(--ink); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover::after { display:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-media { min-width:0; overflow:hidden; background:#242c28; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-media > img { display:block; width:100%; height:clamp(300px,48vw,660px); max-height:none; object-fit:cover; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .property-hero-copy { position:static; max-width:none; color:var(--ink); background:transparent; padding:32px 0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-title { text-wrap:balance; overflow-wrap:anywhere; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-copy .lp-eyebrow { color:var(--accent-3); margin-bottom:12px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-eyebrow { color:var(--accent-3); letter-spacing:.16em; font-weight:600; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-eyebrow::before { background:var(--accent-3); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-price { color:var(--ink); font:500 21px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; margin-top:18px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-link { min-height:44px; border-radius:0; padding:10px 0; color:var(--ink); background:transparent; border:0; border-bottom:1px solid var(--accent-3); font-weight:500; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions { gap:20px; margin-top:16px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover-actions button { min-height:44px; border:1px solid var(--premium-line); background:var(--premium-paper); color:var(--ink); border-radius:6px; padding:10px 16px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover .listing-cover-actions p,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-media-label { color:var(--ink-dim); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-media-label { padding:0; margin-top:8px; font-size:11px; line-height:1.6; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option { margin-top:8px; padding-top:4px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option summary { display:flex; align-items:center; gap:8px; min-height:44px; padding:6px 0; font-size:12px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option summary::before { content:"+"; font-size:16px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-recorded-option[open] summary::before { content:"−"; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-sec { padding:64px 0; border-color:var(--premium-line); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview { padding:0 0 42px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview .lp-eyebrow { display:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stats { border:0; gap:0; margin-top:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat { border:0; border-radius:0; box-shadow:none; background:transparent; padding:22px 18px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat + .lp-stat { border-left:1px solid var(--premium-line); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat .k { color:var(--ink-dim); letter-spacing:.1em; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-prose p { max-width:62ch; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell { border:0; padding:0; box-shadow:none; background:transparent; border-radius:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell img { transition:none; transform:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell figcaption { padding:12px 0 0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-fact,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-level,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .disc-item { background:transparent; border:0; border-bottom:1px solid var(--premium-line); border-radius:0; box-shadow:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-page-head { padding:46px 0 32px; color:var(--ink); background:transparent; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-page-head p { color:var(--ink-dim); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-card { border-color:var(--premium-line); border-radius:0; background:var(--premium-paper); box-shadow:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-visual { background-color:var(--accent-soft); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-visual span { background:var(--accent-3); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-nearby-list li { border:0; border-top:1px solid var(--premium-line); border-radius:0; background:transparent; padding:20px 0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel { max-width:1160px; padding:40px; border:1px solid var(--premium-line); border-radius:0; box-shadow:none; background:var(--premium-paper); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .field input,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .field textarea { background:var(--bg); border-color:#a8afa5; border-radius:6px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-btn,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .cta { color:white; background:var(--accent-3); border-radius:6px; box-shadow:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-btn.ghost { color:var(--ink); background:transparent; border:1px solid var(--premium-line); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .privacy,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .privacy a,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .disclosure { color:var(--ink-dim); }
  /* Signature: film first, editorial display, a single fine-rule facts dock. */
  .property-site.site-theme-signature-estate :is(.property-hero-title,.lp-h,.property-page-head h1,.panel h2,.property-location-copy address) { font-family:"Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif; font-weight:400; letter-spacing:-.025em; }
  .property-site.site-theme-signature-estate .property-hero-title { font-size:clamp(42px,5.4vw,76px); line-height:1.04; max-width:23ch; }
  .property-site.site-theme-signature-estate .property-hero-media { border-radius:2px; }
  .property-site.site-theme-signature-estate #overview .lp-stats { background:var(--premium-paper); border:1px solid var(--premium-line); box-shadow:0 8px 28px rgba(40,35,25,.05); }
  .property-site.site-theme-signature-estate .lp-stat .v { font:400 32px/1.2 Georgia,serif; }
  .property-site.site-theme-signature-estate .lp-gal { grid-template-columns:repeat(2,minmax(0,1fr)); gap:32px; align-items:start; }
  .property-site.site-theme-signature-estate .lp-gcell:nth-child(even) { margin-top:44px; }
  .property-site.site-theme-signature-estate .lp-gcell img { aspect-ratio:4/3; border-radius:2px; }
  .property-site.site-theme-signature-estate #endcard .panel { border-inline:0; border-bottom:0; background:transparent; }
  .property-site.site-theme-signature-estate .panel h2 { font-size:clamp(30px,4vw,46px); }
  /* Coastal: information first on phones and a generous split on desktop. */
  .property-site.site-theme-coastal-luxe .listing-cover { display:grid; grid-template-columns:minmax(0,.85fr) minmax(0,1.15fr); align-items:start; gap:clamp(28px,5vw,72px); padding:24px 0 40px; }
  .property-site.site-theme-coastal-luxe .listing-cover .property-hero-copy { padding:0; }
  .property-site.site-theme-coastal-luxe :is(.property-hero-title,.lp-h,.property-page-head h1,.panel h2) { font-family:Georgia,"Times New Roman",serif; font-weight:600; letter-spacing:-.035em; }
  .property-site.site-theme-coastal-luxe .property-hero-title { font-size:clamp(38px,4vw,58px); line-height:1.12; max-width:18ch; }
  .property-site.site-theme-coastal-luxe .property-hero-media { border-radius:28px; }
  .property-site.site-theme-coastal-luxe .property-hero-media > img { height:auto; aspect-ratio:4/3; }
  .property-site.site-theme-coastal-luxe #overview .lp-wrap { max-width:1320px; padding:0 24px; }
  .property-site.site-theme-coastal-luxe .lp-stats { padding:10px; background:var(--premium-paper); border-radius:18px; }
  .property-site.site-theme-coastal-luxe .lp-stat .v { font:600 28px/1.2 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  .property-site.site-theme-coastal-luxe .lp-gal { gap:24px; }
  .property-site.site-theme-coastal-luxe .lp-gcell img { border-radius:18px; }
  .property-site.site-theme-coastal-luxe .property-location-card { grid-template-columns:1fr; border-radius:22px; }
  .property-site.site-theme-coastal-luxe .property-location-visual { min-height:170px; }
  .property-site.site-theme-coastal-luxe #endcard .panel { border-radius:22px; }
  @supports ((backdrop-filter:blur(16px)) or (-webkit-backdrop-filter:blur(16px))) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { background:rgba(255,253,248,.86); backdrop-filter:blur(18px) saturate(1.1); -webkit-backdrop-filter:blur(18px) saturate(1.1); }
  }
  @media(hover:hover) and (pointer:fine) and (prefers-reduced-motion:no-preference) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { transition:box-shadow .2s ease; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav:hover { box-shadow:0 8px 28px rgba(30,40,30,.08),inset 0 1px 16px rgba(255,255,255,.85); }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-copy { animation:premium-arrive .4s ease-out; }
  }
  @keyframes premium-arrive { from { transform:translateY(4px); } to { transform:none; } }
  @media(prefers-reduced-motion:reduce) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *, .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *::before, .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *::after { transition:none!important; animation:none!important; scroll-behavior:auto!important; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-btn:hover,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-partner:hover { transform:none; }
  }
  @media(prefers-reduced-transparency:reduce) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { background:var(--premium-paper); backdrop-filter:none; -webkit-backdrop-filter:none; }
  }
  @media(max-width:759px) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-wrap { padding-inline:24px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { width:calc(100% - 32px); }
    .property-site.site-theme-coastal-luxe .listing-cover { grid-template-columns:minmax(0,1fr); padding:12px 0 24px; gap:28px; }
    .property-site.site-theme-signature-estate .listing-cover .property-hero-copy { padding:28px 8px 32px; }
    .property-site.site-theme-signature-estate .property-hero-title { font-size:42px; }
    .property-site.site-theme-signature-estate .property-hero-media > img { height:300px; }
    .property-site.site-theme-signature-estate .lp-gal { gap:22px; grid-template-columns:minmax(0,1fr); }
    .property-site.site-theme-signature-estate .lp-gcell:nth-child(even) { margin-top:0; }
    .property-site.site-theme-coastal-luxe .listing-cover .property-hero-copy { padding:8px; }
    .property-site.site-theme-coastal-luxe .property-hero-title { font-size:38px; }
    .property-site.site-theme-coastal-luxe .property-hero-media { border-radius:22px; }
    .property-site.site-theme-coastal-luxe .lp-gal { gap:16px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat { padding:20px 8px; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-sec { padding:44px 0; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel { padding:26px 8px; }
    .property-site.site-theme-coastal-luxe #endcard .panel { padding:28px 20px; }
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
