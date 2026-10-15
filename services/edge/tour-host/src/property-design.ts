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

  /* Shared light glass materials. The property provides every photo/fact.
     Blur is confined to one navigation panel; cards use inexpensive alpha
     surfaces. No JS animations, remote fonts or generated website bundles. */
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; --card:rgba(255,255,255,.78); --grad-text:linear-gradient(var(--ink),var(--ink)); }
  .property-site.site-theme-signature-estate { --bg:#f4f1ec; --ink:#201c18; --ink-dim:#62594f; --accent:#8a6746; --accent-3:#79573b; --accent-soft:rgba(159,122,78,.09); background:radial-gradient(ellipse at 15% 0%,#efe4d4 0,transparent 45%),var(--bg); }
  .property-site.site-theme-coastal-luxe { --bg:#f3f8f6; --ink:#13332f; --ink-dim:#4d655f; --accent:#166a60; --accent-3:#125c53; --accent-soft:rgba(28,122,108,.08); background:radial-gradient(ellipse at 85% 0%,#ddeee8 0,transparent 45%),var(--bg); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { position:sticky; top:12px; max-width:1180px; width:calc(100% - 32px); margin:12px auto 20px; border:1px solid rgba(255,255,255,.85); border-radius:24px; color:var(--ink); background:rgba(255,255,255,.86); box-shadow:0 10px 36px rgba(25,30,35,.08),inset 0 1px 0 rgba(255,255,255,.8); backdrop-filter:blur(18px) saturate(1.12); -webkit-backdrop-filter:blur(18px) saturate(1.12); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-nav-inner { padding:10px 14px; gap:10px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav a,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav button { color:var(--ink); min-height:44px; border-radius:18px; font-size:13px; letter-spacing:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .listing-nav-links a { padding:12px 16px; border:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .listing-nav-links a[aria-current=page] { color:var(--accent-3); background:var(--accent-soft); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .property-primary-play { background:var(--accent-3); color:#fff; padding:12px 18px; border:0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .walkthrough-secondary { padding:12px 10px; border:0; background:transparent; color:var(--ink-dim); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { max-width:1200px; margin:0 auto; border-radius:28px; border:1px solid rgba(255,255,255,.75); box-shadow:0 22px 60px rgba(25,30,35,.1); overflow:hidden; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero { background:rgba(255,255,255,.62); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-copy { background:rgba(255,255,255,.48); padding:clamp(24px,4vw,48px); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-title,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-h,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-page-head h1 { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; font-weight:600; letter-spacing:-.045em; line-height:1.1; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-title { font-size:clamp(30px,4.3vw,60px); max-width:18em; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-price { font-size:22px; font-weight:500; }
  /* Signature Estate's own voice: an editorial high-contrast serif for display
     type (installed system faces only), so the two luxury designs differ at a
     glance on a phone, not only in colour. Body and form text stay sans. */
  .property-site.site-theme-signature-estate :is(.property-hero-title,.lp-h,.property-page-head h1,.panel h2,.property-location-copy address) { font-family:Didot,"Bodoni 72","Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif; font-weight:400; letter-spacing:-.01em; }
  .property-site.site-theme-coastal-luxe .property-location-copy address { font-family:inherit; font-weight:500; letter-spacing:-.02em; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-eyebrow { color:var(--accent-3); letter-spacing:.15em; font-weight:600; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-eyebrow::before { background:var(--accent-3); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-link,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-btn.ghost { background:rgba(255,255,255,.7); color:var(--ink); border:1px solid rgba(140,145,150,.24); border-radius:16px; min-height:48px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-sec { padding:clamp(36px,6vw,64px) 0; border-color:rgba(100,115,120,.12); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview { padding:30px 0; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #overview .lp-eyebrow { display:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stats { border:0; gap:12px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat { border:1px solid rgba(255,255,255,.85); border-radius:20px; background:rgba(255,255,255,.68); padding:20px 12px; box-shadow:0 6px 20px rgba(25,30,35,.035); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat .v { font-family:inherit; font-size:28px; font-weight:500; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal { gap:20px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell { border:1px solid rgba(255,255,255,.8); border-radius:22px; background:rgba(255,255,255,.72); padding:10px; box-shadow:0 10px 30px rgba(25,30,35,.06); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell img { border-radius:14px; transition:none; transform:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell figcaption { padding:12px 4px 4px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-card,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-nearby-list li,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-fact,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-level,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .disc-item { background:rgba(255,255,255,.7); border:1px solid rgba(255,255,255,.85); border-radius:22px; box-shadow:0 8px 28px rgba(25,30,35,.045); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-visual { background-color:var(--accent-soft); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-location-visual span { background:var(--accent-3); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-page-head { max-width:1200px; margin:0 auto; padding:42px 0; background:transparent; color:var(--ink); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-page-head p { color:var(--ink-dim); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-page-head + #gallery { padding-top:12px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #endcard .panel { background:rgba(255,255,255,.7); border:1px solid rgba(255,255,255,.9); border-radius:28px; box-shadow:0 16px 50px rgba(25,30,35,.07); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .panel h2 { font-family:inherit; font-weight:600; letter-spacing:-.03em; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .field input,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .field textarea { background:rgba(255,255,255,.85); border-color:rgba(130,145,145,.28); border-radius:14px; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-btn,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .cta { background:var(--accent-3); border-radius:16px; box-shadow:none; }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .privacy,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .privacy a,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .disclosure { color:var(--ink-dim); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) a:focus-visible,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) button:focus-visible { outline-color:var(--accent); }
  .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe).site-preview #listing-nav { position:relative; top:auto; }
  /* Coastal's desktop composition places the facts beside the full 16:9
     player. Signature keeps an immersive full-width film above its details. */
  @media(min-width:1000px) {
    .property-site.site-theme-coastal-luxe .property-video-hero { display:grid; grid-template-columns:minmax(0,1.7fr) minmax(0,1fr); align-items:center; }
    .property-site.site-theme-coastal-luxe .property-video-hero .property-hero-copy { padding:32px; }
    .property-site.site-theme-coastal-luxe .property-hero-title { font-size:clamp(30px,3vw,44px); }
  }
  @media(hover:hover) and (pointer:fine) and (prefers-reduced-motion:no-preference) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-link { transition:transform .16s ease,box-shadow .16s ease; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gcell:hover,.property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-link:hover { transform:translateY(-2px); box-shadow:0 14px 32px rgba(25,30,35,.1); }
  }
  @media(prefers-reduced-motion:reduce) {
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *, .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *::before, .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) *::after { transition:none!important; animation:none!important; }
    .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-btn:hover, .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-partner:hover { transform:none; }
  }
  @media(max-width:759px) { .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-cover { margin:0 12px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-gal { gap:12px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stats { gap:8px; } }
  @media(max-width:600px) { .property-site .property-preview-banner { padding:10px 16px; font-size:12px; } .property-site .property-preview-watermark { padding:6px 9px; font-size:10px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav { width:calc(100% - 24px); top:8px; margin:8px auto 12px; border-radius:22px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .listing-nav-inner { padding:6px 8px; gap:4px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .listing-nav-links a { padding:11px 12px; font-size:12px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .property-primary-play { padding:11px 13px; font-size:12px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) #listing-nav .walkthrough-secondary { padding:11px 8px; font-size:11px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-hero-title { font-size:30px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .property-video-hero .property-hero-copy { padding:22px; } .property-site:is(.site-theme-signature-estate,.site-theme-coastal-luxe) .lp-stat { padding:16px 8px; } }
`;
