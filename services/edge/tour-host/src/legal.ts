// Legal pages served by the tour host:
//
//   GET /terms    Terms of Service
//   GET /privacy  Privacy Policy
//
// These back the links in the iOS app (Settings → Terms of Service / Privacy
// Policy → https://rendprop.com/terms | /privacy) and the App Store listing.
// Self-contained HTML, inline CSS, mobile-first, Rendprop purple accent
// (#7C3AED light / #9B6DFF dark — the app's Theme.accent), automatic
// light/dark via prefers-color-scheme.

const EFFECTIVE_DATE = "August 26, 2026";
const CONTACT_EMAIL = "aaron@skyway.media";

const LEGAL_CSS = `
  :root {
    --bg: #faf9fc;
    --ink: #1b1424;
    --ink-dim: #5f576c;
    --accent: #7c3aed;
    --line: rgba(27, 20, 36, 0.12);
    --card: rgba(124, 58, 237, 0.06);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0b0d10;
      --ink: #f2f3f5;
      --ink-dim: rgba(242, 243, 245, 0.66);
      --accent: #9b6dff;
      --line: rgba(242, 243, 245, 0.14);
      --card: rgba(155, 109, 255, 0.10);
    }
  }
  * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body {
    background: var(--bg); color: var(--ink);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
    font-size: 16px; line-height: 1.65;
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 720px; margin: 0 auto; padding: 40px 22px 72px; }
  .mark {
    font-size: 12px; letter-spacing: .35em; text-transform: uppercase;
    color: var(--accent); font-weight: 700; margin-bottom: 26px;
  }
  .mark a { color: inherit; text-decoration: none; }
  h1 { font-size: 30px; font-weight: 700; letter-spacing: -.015em; line-height: 1.2; margin-bottom: 8px; }
  .updated { color: var(--ink-dim); font-size: 14px; margin-bottom: 8px; }
  .lede {
    color: var(--ink-dim); font-size: 15.5px; margin: 18px 0 8px;
    padding: 14px 16px; background: var(--card); border-radius: 12px;
  }
  h2 { font-size: 19px; font-weight: 650; letter-spacing: -.01em; margin: 34px 0 10px; }
  h2 .num { color: var(--accent); margin-right: 8px; }
  p { margin: 0 0 12px; }
  ul { margin: 0 0 12px 22px; }
  li { margin-bottom: 6px; }
  b, strong { font-weight: 650; }
  a { color: var(--accent); }
  table { width: 100%; border-collapse: collapse; margin: 14px 0 16px; font-size: 14.5px; }
  th, td { text-align: left; padding: 10px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { font-size: 12.5px; letter-spacing: .06em; text-transform: uppercase; color: var(--ink-dim); font-weight: 650; }
  footer {
    margin-top: 48px; padding-top: 20px; border-top: 1px solid var(--line);
    color: var(--ink-dim); font-size: 14px;
  }
  footer a { margin-right: 16px; }
`;

function legalShell(opts: {
  title: string;
  description: string;
  heading: string;
  lede: string;
  body: string;
  otherLabel: string;
  otherHref: string;
}): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${opts.title}</title>
<meta name="description" content="${opts.description}">
<meta name="theme-color" content="#0b0d10" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#faf9fc" media="(prefers-color-scheme: light)">
<style>${LEGAL_CSS}</style>
</head>
<body>
  <div class="wrap">
    <div class="mark"><a href="https://rendprop.com">RENDPROP</a></div>
    <h1>${opts.heading}</h1>
    <div class="updated">Effective ${EFFECTIVE_DATE}</div>
    <p class="lede">${opts.lede}</p>
    ${opts.body}
    <footer>
      <a href="${opts.otherHref}">${opts.otherLabel}</a>
      <a href="https://rendprop.com">rendprop.com</a>
      <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>
    </footer>
  </div>
</body>
</html>`;
}

export function termsPage(): string {
  const body = `
<h2><span class="num">1.</span>What Rendprop is</h2>
<p>Rendprop is an app and hosting service for showing off physical spaces. You film or photograph
a property (or venue, restaurant, store, or studio), and Rendprop turns that footage into
polished, shareable tours, enhanced photos, and short videos — some of it processed with AI —
hosted on public pages you can send to anyone. These Terms are an agreement between you and
Rendprop ("we", "us") and apply whenever you use the app or any page we host for you.</p>

<h2><span class="num">2.</span>Your account</h2>
<p>You sign in with your Apple account. Keep your account to yourself: you are responsible for
what happens under it. You must be at least 13 years old (and old enough to form a binding
contract where you live) to use Rendprop. If you use Rendprop for a business or team, you
confirm you have the authority to accept these Terms for it.</p>

<h2><span class="num">3.</span>Acceptable use</h2>
<p>The one big rule: <b>only record and upload spaces you have the right to record.</b> That
means your own property, a client's listing you represent, or a space whose owner gave you
permission. Beyond that, don't:</p>
<ul>
  <li>upload content that is unlawful, infringing, deceptive, or invades someone's privacy;</li>
  <li>misrepresent a property — AI enhancements are for presentation, not for hiding real defects
  or misleading buyers;</li>
  <li>abuse the service (scraping, probing, reselling access, or overloading our systems).</li>
</ul>
<p>We can remove content or suspend accounts that break these rules.</p>

<h2><span class="num">4.</span>Your content stays yours</h2>
<p><b>You own your videos, photos, and tours.</b> Uploading them to Rendprop doesn't transfer
ownership to us — ever. You give us only the narrow permission we need to run the service:
to store, process, enhance, and deliver your content so your tours and pages work, including
passing it to the processing providers listed in our <a href="/privacy">Privacy Policy</a>.</p>
<p><b>Rendprop never uses your content for our own marketing and never uses it to train AI
models without your written consent.</b> Delete your content and that permission ends with it.</p>

<h2><span class="num">5.</span>AI-generated content</h2>
<p>Some Rendprop features generate or alter imagery with AI — for example virtual staging,
sky and twilight edits, and synthetic aerial shots. We label these features in the product,
and virtually staged or AI-generated media should always be disclosed as such to buyers.
You are responsible for meeting any disclosure rules that apply to you (for example MLS or
local advertising rules) when you publish or share AI-enhanced media.</p>

<h2><span class="num">6.</span>Payment</h2>
<p>Rendprop is currently in early access. Some or all features are free during this period.
When paid plans launch, pricing and billing terms will be shown in the app before you are
charged anything, and continued use of paid features will require an active plan.</p>

<h2><span class="num">7.</span>Ending things</h2>
<p>You can delete your account any time in the app: <b>Settings → Delete account</b>. That
removes your account, your organizations that only you belong to, and their listings, tours,
media records, and leads. We can suspend or close accounts that violate these Terms or create
risk for the service or other users; where reasonable, we'll tell you why.</p>

<h2><span class="num">8.</span>Service provided "as is"</h2>
<p>We work hard to keep Rendprop fast and reliable, but we provide it <b>"as is" and "as
available"</b>, without warranties of any kind — express or implied — including fitness for a
particular purpose, non-infringement, and uninterrupted or error-free operation. AI output
can be imperfect; review it before you publish it.</p>

<h2><span class="num">9.</span>Limits on liability</h2>
<p>To the fullest extent the law allows, Rendprop is not liable for indirect, incidental,
special, consequential, or punitive damages, or for lost profits, revenue, data, or goodwill.
Our total liability for all claims relating to the service is capped at the greater of the
amount you paid us in the 12 months before the claim or USD $100. Some jurisdictions don't
allow certain limits, so parts of this section may not apply to you.</p>

<h2><span class="num">10.</span>Changes to these Terms</h2>
<p>We may update these Terms as Rendprop evolves. If a change is material, we'll flag it in
the app or by email before it takes effect. Using Rendprop after a change takes effect means
you accept the updated Terms.</p>

<h2><span class="num">11.</span>Contact</h2>
<p>Questions about these Terms: <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>.</p>`;

  return legalShell({
    title: "Terms of Service — Rendprop",
    description: "The terms that govern your use of the Rendprop app and hosted tour pages.",
    heading: "Terms of Service",
    lede:
      "The plain-language version: only record spaces you have rights to, your content stays " +
      "yours, we never use it for marketing or AI training without your written consent, and " +
      "you can delete your account (and everything in it) from the app at any time.",
    body,
    otherLabel: "Privacy Policy",
    otherHref: "/privacy",
  });
}

export function privacyPage(): string {
  const body = `
<h2><span class="num">1.</span>What we collect</h2>
<p>Rendprop collects the minimum it needs to run:</p>
<ul>
  <li><b>Account details</b> — your email and name, provided by Apple when you sign in
  (Sign in with Apple lets you hide your real email; that works fine with Rendprop).</li>
  <li><b>Your content</b> — the listings you create and the video, photos, tours, and related
  details you upload or generate in the app.</li>
  <li><b>Leads and tour activity</b> — when someone submits the contact form on one of your
  tour pages, their details go to you; we also count basic, aggregate tour views so you can
  see how a tour performs.</li>
  <li><b>Operational logs</b> — short-lived technical logs (like errors and request metadata)
  used to keep the service running and secure.</li>
</ul>
<p><b>What we don't do:</b> no advertising trackers, no third-party analytics SDKs in the app,
and we never sell your personal information.</p>

<h2><span class="num">2.</span>How we use it</h2>
<p>Only to operate Rendprop: signing you in, storing and processing your media, generating the
AI enhancements you request, hosting your public tour pages, delivering your leads to you, and
keeping the service secure. <b>Your content is never used for our marketing and never used to
train AI models without your written consent.</b></p>

<h2><span class="num">3.</span>Who processes data for us</h2>
<p>Rendprop runs on a small set of infrastructure and AI providers. They process data solely to
provide their function to us:</p>
<table>
  <tr><th>Provider</th><th>What it does</th></tr>
  <tr><td>Supabase</td><td>Authentication and database (accounts, listings, leads)</td></tr>
  <tr><td>Cloudflare</td><td>Media storage and delivery of tour pages and video</td></tr>
  <tr><td>Google&nbsp;Gemini</td><td>AI photo enhancement (only the photos you submit for editing)</td></tr>
  <tr><td>fal.ai</td><td>AI video generation (only the media you submit for video features)</td></tr>
  <tr><td>Anthropic</td><td>Automated quality checks on AI output</td></tr>
</table>
<p>AI providers receive only the specific media you actively submit to an AI feature, and only
to produce your result.</p>

<h2><span class="num">4.</span>How long we keep it</h2>
<p>Your content stays until you delete it — delete a listing, tour, or asset in the app and the
associated records go with it. Deleting your account (<b>Settings → Delete account</b>) removes
your account data and the content of organizations that only you belong to. Residual copies in
backups and logs age out on a short, fixed schedule.</p>

<h2><span class="num">5.</span>Your rights</h2>
<p>You can see and manage your data directly in the app, and delete it there too. For anything
the app doesn't cover — a copy of your data, a correction, or a deletion request — email
<a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a> and we'll handle it. Depending on where
you live, you may have additional statutory rights (such as access, portability, and erasure);
we honor those.</p>

<h2><span class="num">6.</span>Children</h2>
<p>Rendprop is not for children under 13, and we don't knowingly collect their data. If you
believe a child has created an account, contact us and we'll delete it.</p>

<h2><span class="num">7.</span>Changes to this policy</h2>
<p>If we change this policy in a meaningful way, we'll flag it in the app or by email before
the change takes effect. The date at the top always shows the current version.</p>

<h2><span class="num">8.</span>Contact</h2>
<p>Privacy questions or requests: <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>.</p>`;

  return legalShell({
    title: "Privacy Policy — Rendprop",
    description: "What Rendprop collects, who processes it, how long it's kept, and your rights.",
    heading: "Privacy Policy",
    lede:
      "The plain-language version: we collect your account details (via Apple) and the content " +
      "you upload, we use them only to run the service, there's no ad tracking and no analytics " +
      "SDKs, and deleting your account removes your data.",
    body,
    otherLabel: "Terms of Service",
    otherHref: "/terms",
  });
}
