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

const EFFECTIVE_DATE = "September 5, 2026";
// Source reconciliation is not publication approval: owner/legal must approve
// the effective date, notice, provider terms and retention evidence before deploy.
// See docs/audits/2026-09-10/PRIVACY-POLICY-RECONCILIATION.md.
const CONTACT_EMAIL = "aaron@pilk.ai";

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
  /* Provider names must not widen the whole policy beyond a narrow phone.
     Keep native table semantics while allowing its text to wrap in each cell. */
  table { width: 100%; table-layout: fixed; overflow-wrap: anywhere; border-collapse: collapse; margin: 14px 0 16px; font-size: 14.5px; }
  th:first-child { width: 25%; }
  th, td { text-align: left; padding: 10px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { font-size: 12.5px; letter-spacing: .06em; text-transform: uppercase; color: var(--ink-dim); font-weight: 650; }
  @media (max-width: 540px) {
    /* Read each processor vertically on phones. Explicit table/row/cell roles
       retain the relationships when WebKit sees block layout; headers remain
       in the accessibility tree instead of being hidden with display:none. */
    table, tbody, tr, td { display: block; }
    tr { margin-bottom: 14px; padding: 14px 16px; border: 1px solid var(--line); border-radius: 12px; }
    tr:first-child { position: absolute; width: 1px; height: 1px; padding: 0; border: 0; overflow: hidden; clip-path: inset(50%); }
    td { padding: 6px 0; border: 0; }
    td:first-child { font-weight: 650; font-size: 16px; color: var(--accent); }
    td:nth-child(2)::before, td:nth-child(3)::before { display: block; color: var(--ink-dim); font-size: 12px; font-weight: 650; }
    td:nth-child(2)::before { content: "What it does"; }
    td:nth-child(3)::before { content: "What it receives"; }
  }
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
  /** Canonical path of this page — `/terms` or `/privacy`. */
  path: string;
}): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${opts.title}</title>
<meta name="description" content="${opts.description}">
<link rel="canonical" href="https://rendprop.com${opts.path}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
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
      <a href="/support">Support</a>
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
<p>You can use Rendprop without signing in with Apple. The app creates a guest session for its
online features; signing in with Apple is optional. Keep your account to yourself: you are responsible for
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

<h2><span class="num">6.</span>Plans and payment</h2>
<p>Rendprop is free to download. A subscription unlocks monthly allowances for the things that
cost us money to make: tour renders, AI photo edits, reel clips, and aerial intros. Plans are
sold as <b>auto-renewable subscriptions through the App Store</b> — Starter and Pro, billed monthly
or yearly, and Team, billed monthly. <b>The app is the source of truth</b>: the plan names,
allowances, billing periods, and prices you see there come from the App Store in your own currency,
and they are what you are charged.</p>
<ul>
  <li><b>Free trial.</b> Each plan starts with a 7-day free trial. Apple grants that trial
  <b>once per Apple ID</b> across all Rendprop plans, so changing plans does not start a second
  one. Cancel at least 24 hours before it ends and you pay nothing.</li>
  <li><b>Auto-renewal.</b> Payment is charged to your Apple ID at confirmation of purchase. The
  subscription <b>renews automatically for the same period unless you cancel at least 24 hours
  before the current period ends</b>, and Apple charges the renewal within the 24 hours before
  that period ends.</li>
  <li><b>Cancelling.</b> Cancel any time on your device: <b>Settings → your name → Subscriptions
  → Rendprop</b>, or in the app under Settings → Plan &amp; usage → Manage subscription.
  Cancelling stops the next renewal; the plan keeps working until the end of the period you have
  already paid for. <b>Deleting the app does not cancel a subscription.</b></li>
  <li><b>Refunds.</b> Apple takes the payment, so Apple handles refunds — request one at
  <a href="https://reportaproblem.apple.com">reportaproblem.apple.com</a>. We cannot refund an
  App Store purchase ourselves.</li>
  <li><b>Price changes.</b> If a price rises, Apple notifies you before it takes effect and, where
  Apple requires it, asks you to agree — if you do not, the subscription simply stops renewing.
  We will flag a material change in the app as well.</li>
  <li><b>When a plan ends or lapses.</b> <b>Your content stays.</b> Cancelling or letting a plan
  expire does not delete your listings, photos, reels, or published tours, and share links you
  have already sent keep working. What stops is the monthly allowance: you cannot render new
  tours or run AI features until you subscribe again. If you want the content gone, delete it —
  see section 7.</li>
</ul>
<p><b>We never see or store your card details.</b> Apple sends us a signed record of the purchase
— the transaction identifiers, which plan you bought, and when it expires — and that record is
what unlocks your plan. See the <a href="/privacy">Privacy Policy</a>.</p>

<h2><span class="num">7.</span>Ending things</h2>
<p>You can request account deletion in <b>Settings → Delete account</b>. Deletion covers your
account and the content of workspaces only you belong to. Content in workspaces shared with
other members can remain for those members. The app reports request failures and whether
further cleanup is pending. Associated storage, video-delivery and CRM cleanup may finish
separately. We can suspend or close accounts that violate these Terms or create risk for the
service or other users; where reasonable, we'll tell you why.</p>

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
      "yours, we never use it for marketing or AI training without your written consent, " +
      "subscriptions renew through the App Store until you cancel (and your content stays even " +
      "when a plan lapses), and you can request account deletion in the app; shared-workspace " +
      "content and pending cleanup are explained in section 7.",
    body,
    otherLabel: "Privacy Policy",
    otherHref: "/privacy",
    path: "/terms",
  });
}

export function privacyPage(): string {
  const body = `
<h2><span class="num">1.</span>What we collect</h2>
<p>Rendprop collects the minimum it needs to run:</p>
<ul>
  <li><b>Account and session details</b> — Rendprop creates a guest session for online features.
  If you choose Sign in with Apple, Apple provides the name and email or private-relay address
  you choose to share. Apple-linked sign-in and account deletion can exchange tokens with Apple.</li>
  <li><b>Your content</b> — the listings you create and the video, photos, tours, and related
  details you upload or generate in the app. Depending on the feature you request, Rendprop
  sends selected photos or video, sampled frames, edit instructions, chat history and project
  context, scripts or transcript excerpts to the AI providers below. Media and text can contain
  personal information, including an address you include in a voiceover script. Review your
  inputs before requesting cloud processing.</li>
  <li><b>Listing location</b> — the address or business name you enter, and an approximate
  (rounded) map coordinate we derive from it. These are part of the listing and are
  <b>published on your public tour page</b> so viewers can find the space; the app may also use
  your device's approximate location, only when you ask it to fill in an address.</li>
  <li><b>Leads</b> — when someone submits the contact form on one of your tour pages, we store
  the details they enter (name, phone, email, and any message or preferred date) so you can see
  them in your Leads inbox in the app. When CRM sync is configured, we send GoHighLevel /
  LeadConnector the submitter's name, email and phone, plus tour, workspace and listing tags
  and the listing address used in the contact's source label. The message or preferred date
  remains part of the lead details stored for your Leads inbox. Lead forms carry a short notice
  linking to this policy.</li>
  <li><b>Tour viewers</b> — for each visit to a tour page we record engagement telemetry (that the
  tour started, how long it was watched, how far the viewer scrolled) tied to the tour, not to a
  named person. The viewer's IP address is used briefly as a rate-limit key to prevent abuse of
  the lead form and view counter. Bot protection may be provided by Cloudflare Turnstile.</li>
  <li><b>Subscriptions</b> — Apple takes the payment. When you subscribe, the App Store gives the
  app a signed record of the purchase, and we store <b>Apple's transaction identifiers, the plan
  (product id) you bought, the store environment, and when it expires</b> — that is what unlocks
  your plan. <b>We never see or store your card details</b>, and Apple does not give them to
  us.</li>
  <li><b>App analytics and diagnostics</b> — a short, fixed list of in-app events, a device
  identifier we generate ourselves, and crash and performance summaries from Apple. Section 4
  sets out exactly what those are, and what they are not.</li>
  <li><b>Operational logs</b> — short-lived technical logs (like errors and request metadata)
  used to keep the service running and secure.</li>
</ul>
<p><b>What we don't do:</b> there is <b>no third-party analytics SDK, no advertising SDK, no
advertising identifier (IDFA), and no tracking pixel</b> in the Rendprop app; we never link what
you do in Rendprop with data from another company's app or website; we never share your data
with a data broker; and we never sell your personal information.</p>

<h2><span class="num">2.</span>How we use it</h2>
<p>Only to operate and improve Rendprop: signing you in, storing and processing your media,
generating the AI enhancements you request, hosting your public tour pages, capturing your leads
into your Leads inbox (and our CRM provider) so you can follow up, measuring tour engagement,
unlocking the plan you subscribed to, understanding which parts of the app are used and where
they break (section 4), and keeping the service secure. <b>Your content is never used for our
marketing and never used to train AI models without your written consent.</b></p>

<h2><span class="num">3.</span>Who processes data for us</h2>
<p>Rendprop runs on a small set of infrastructure and AI providers. They process data solely to
provide their function to us:</p>
<table role="table" aria-label="Service providers and data processing">
  <tr role="row"><th role="columnheader" scope="col">Provider</th><th role="columnheader" scope="col">What it does</th><th role="columnheader" scope="col">What it receives</th></tr>
  <tr role="row"><td role="cell">Supabase</td><td role="cell">Authentication, database, and the app's API</td><td role="cell">Your account, listings, leads, and tour engagement counts. Inputs sent through Rendprop's API, including media and text supplied for AI processing</td></tr>
  <tr role="row"><td role="cell">Cloudflare</td><td role="cell">Media storage (R2), video delivery (Stream), hosting of your tour pages, and Turnstile bot protection on lead forms</td><td role="cell">Your uploaded and generated media; requests to your tour pages, including viewers' IP addresses</td></tr>
  <tr role="row"><td role="cell">Apple</td><td role="cell">Sign in with Apple; App Store subscriptions; crash and performance summaries (MetricKit); ad attribution (SKAdNetwork); Speech recognition for captions</td><td role="cell">Sign-in and account-deletion tokens; Apple gives us the email (or private relay address) and name you choose to share, and a signed record of any subscription you buy (never your card details). Recorded voiceover audio may be processed by Apple when on-device recognition is unavailable or a recognition attempt falls back to the server</td></tr>
  <tr role="row"><td role="cell">GoHighLevel (LeadConnector)</td><td role="cell">CRM — so a lead can be followed up, and so lead contacts can be deleted with your account</td><td role="cell">The name, phone and email submitted through a tour's lead form; tour, workspace and listing tags; and the listing address used in the contact's source label</td></tr>
  <tr role="row"><td role="cell">Google&nbsp;Gemini</td><td role="cell">Photo editing, video analysis, and writing assistance</td><td role="cell">Selected photos or video, sampled frames, and text inputs for those features</td></tr>
  <tr role="row"><td role="cell">fal.ai</td><td role="cell">AI image and video editing, generation, and upscaling, using the selected model</td><td role="cell">Photos, video, and prompts for those features, including exterior photos used for aerial intros</td></tr>
  <tr role="row"><td role="cell">Anthropic</td><td role="cell">Chat and writing assistance, planning, and quality checks on AI output</td><td role="cell">User text, chat history and project context; source photos and frames from generated clips for quality checks</td></tr>
  <tr role="row"><td role="cell">OpenAI</td><td role="cell">Chat and writing assistance, planning, quality checks on AI output, and photo editing</td><td role="cell">User text, chat history and project context; source photos and generated-clip frames for quality checks; photos and edit inputs for photo editing</td></tr>
  <tr role="row"><td role="cell">ElevenLabs</td><td role="cell">Voiceover generation</td><td role="cell">Your voiceover script, including any address or personal details in it, and your selected voice</td></tr>
</table>
<p>Rendprop sends inputs for the feature you request. Some AI features use more than one
provider, including for fallback or quality checks. Lead submissions are handled by our backend
and may also be synced to the CRM as described above. Rendprop does not send these inputs for
advertising.</p>

<h2><span class="num">4.</span>Analytics, crash reports, and ads</h2>
<p>All of this is <b>first-party</b>: our own code, sending to our own servers, read only by us.
There is no third-party analytics SDK, no advertising SDK, no advertising identifier (IDFA), no
App Tracking Transparency prompt, and no pixel in the Rendprop app — and none of what follows is
ever combined with data from another company's app or website, or given to a data broker.</p>
<ul>
  <li><b>Product analytics.</b> The app records a short, fixed list of event names so we can see
  which parts of Rendprop get used and where people get stuck: opening the app, signing up or in,
  creating a space, starting and finishing a capture, finishing a render, publishing a tour,
  running a photo edit, making a reel, adding a voiceover, making an aerial intro, opening the
  plans, and starting, completing, or failing a purchase. Each event carries the app version, the
  iOS version, a session id, and at most a couple of non-identifying values such as which
  business type you are working in. <b>No photo, address, listing, name, email address, or phone
  number is ever in an event.</b> The server enforces that three ways: only those event names are
  accepted, only a named list of properties is kept, and anything that still looks like personal
  data is stripped before it is stored.</li>
  <li><b>A device identifier.</b> A random identifier the app generates the first time it runs
  and keeps in this device's Keychain, sent with those events so the numbers count devices rather
  than taps. <b>It is not Apple's advertising identifier</b> — Rendprop never asks for the IDFA —
  it is not the identifier any other app can see, it is not shared with anyone, and it never
  leaves our own systems.</li>
  <li><b>Crash and performance diagnostics.</b> Delivered by <b>MetricKit</b>, which is part of
  iOS. We receive <b>summaries only</b>: what kind of crash or hang it was, a signal or exception
  number, a short termination reason with file paths removed, a single frame name, and timing
  figures such as a median launch time. We never receive a full call stack — that stays in
  Apple's own developer tools — and there is no third-party crash reporting SDK in the app.</li>
  <li><b>Ad attribution.</b> When Rendprop is advertised, iOS itself measures whether an ad
  worked, using Apple's <b>SKAdNetwork</b>. The app tells iOS a number from 0 to 5 marking how far
  a new install has got — installed, signed up, created a space, published a tour, opened the
  plans, subscribed — and <b>iOS</b>, not us, sends a signed postback to the ad network. That
  postback contains a campaign identifier and that number: <b>no personal data, and no identifier
  for you or your device</b>.</li>
  <li><b>How long.</b> Analytics events are <b>deleted 180 days</b> after we receive them.</li>
</ul>
<p>This is separate from the engagement counts on your tour pages (section 1): those measure your
tours for you, and you see them in the app.</p>

<h2><span class="num">5.</span>How long we keep it</h2>
<p>Your content stays until you delete it — delete a listing, tour, or asset in the app and the
associated records go with it. Deleting your account (<b>Settings → Delete account</b>) removes
your account data and the content of organizations that only you belong to. Content in shared
workspaces can remain for other members. Account deletion and completion of associated cleanup
are separate statuses; the app indicates when cleanup is pending. Analytics events are
deleted after 180 days (section 4), and residual copies in backups and logs age out on a short,
fixed schedule.</p>

<h2><span class="num">6.</span>Your rights</h2>
<p>You can see and manage your data directly in the app, and delete it there too. For anything
the app doesn't cover — a copy of your data, a correction, or a deletion request — email
<a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a> and we'll handle it. Depending on where
you live, you may have additional statutory rights (such as access, portability, and erasure);
we honor those.</p>

<h2><span class="num">7.</span>Children</h2>
<p>Rendprop is not for children under 13, and we don't knowingly collect their data. If you
believe a child has created an account, contact us and we'll delete it.</p>

<h2><span class="num">8.</span>Changes to this policy</h2>
<p>If we change this policy in a meaningful way, we'll flag it in the app or by email before
the change takes effect. The date at the top always shows the current version.</p>

<h2><span class="num">9.</span>Contact</h2>
<p>Privacy questions or requests: <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>.</p>`;

  return legalShell({
    title: "Privacy Policy — Rendprop",
    description: "What Rendprop collects, who processes it, how long it's kept, and your rights.",
    heading: "Privacy Policy",
    lede:
      "The plain-language version: we collect your account and session details, including details " +
      "from Apple if you choose to sign in, the content and " +
      "listing details you upload (your listing's address or business name is published on its " +
      "tour page), the leads viewers send you (stored for you and synced to the CRM when configured), " +
      "engagement counts on your tour pages, and our own app-usage and crash statistics. We use " +
      "them only to run and improve the service. There is no third-party analytics SDK, no ad " +
      "SDK and no advertising identifier in the app, we never track you across other companies' " +
      "apps or websites, Apple handles payments so we never see your card, and account deletion " +
      "and its shared-workspace and cleanup limits are explained in section 5.",
    body,
    otherLabel: "Terms of Service",
    otherHref: "/terms",
    path: "/privacy",
  });
}
