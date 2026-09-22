// attribution.ts — the ONE place that builds an outbound acquisition link.
//
// WHY THIS FILE EXISTS
// Every published tour is a public page an agent shares with buyers and
// sellers, and the App Store button on it was a bare
// `https://apps.apple.com/us/app/id6808982413`. An install from a tour, a
// portfolio and the marketing site were therefore indistinguishable in App
// Store Connect: the surface that produced the download could never be known,
// so there was no way to tell whether the tour page acquires agents at all.
//
// APPLE'S CAMPAIGN PARAMETERS, and which of them we can actually use:
//
//   ct  campaign token — free text, OURS to choose. Max 40 characters.
//   pt  provider token — issued by Apple, found in App Store Connect.
//   mt  media type     — 8 = "software" (iOS apps). Always 8 for us.
//
// `pt` is NOT in this repo and cannot be derived: it is an account-level value
// the owner has to copy out of App Store Connect. So this builder emits `ct`
// and `mt` only, which is what works without it — the link is valid, the click
// is a normal App Store open, and nothing breaks when `pt` is added later.
//
//   TODO(owner): add the provider token. App Store Connect → App Analytics →
//   Acquisition → Campaigns → "Create Campaign" shows a generated link of the
//   form `...?pt=<providerToken>&ct=<campaignToken>&mt=8`. Copy the `pt` value
//   into APPLE_PROVIDER_TOKEN below (it is public — it ships in every campaign
//   link) and every surface starts attributing at once. Until then the `ct`
//   values below are still carried on the click; `pt` is what files them under
//   this provider in the Campaigns report.
//
// WHERE THE NUMBERS SHOW UP: App Store Connect → App Analytics → Acquisition
// → Sources, dimension "Campaign" (and the Campaigns report once `pt` is set).
// Campaign tokens are NOT retroactive — a campaign only reports from the day
// its links start being clicked.
//
// PRIVACY: these are query parameters on an outbound link the viewer chooses to
// tap. No cookie is set, no identifier is stored, nothing is sent anywhere
// else, and the privacy policy's "no third-party analytics SDK, no advertising
// SDK, no advertising identifier (IDFA), and no tracking pixel" stays true.

/** The iOS app's App Store id. Also the `app-id` in the smart banner. */
export const APP_STORE_ID = "6808982413";

/** Apple's provider token. Empty until the owner pastes it in — see the TODO
 *  above. When it is set, `appStoreUrl` starts emitting `pt` automatically. */
export const APPLE_PROVIDER_TOKEN = "";

/** App Store Connect caps a campaign token at 40 characters. */
const CT_MAX_LENGTH = 40;

/** The canonical, parameter-free App Store URL. Used where a tracking
 *  parameter would be wrong — e.g. `installUrl` inside structured data, which
 *  is an identity statement about the app, not a click. */
export const APP_STORE_URL = `https://apps.apple.com/us/app/id${APP_STORE_ID}`;

/**
 * A campaign token, joined from its parts with `-`.
 *
 * CASE AND `_` ARE PRESERVED, deliberately. Tour slugs are nanoid/base64url —
 * `Ab_9-Zz` and `ab-9-zz` are two different tours, and lowercasing or folding
 * `_` to `-` would file both under one campaign, which is a wrong number
 * rather than a missing one. Apple's campaign tokens accept letters, digits,
 * `-`, `_` and `.`, so a slug passes through untouched; anything outside that
 * set is replaced.
 *
 * Over 40 characters (Apple's cap) the token falls back to the bare SURFACE
 * rather than being cut: "tour-abcdef…" and "tour-abcxyz…" truncated to the
 * same 40 bytes would silently merge two campaigns, and "tour" is at least
 * true.
 */
export function campaignToken(...parts: Array<string | null | undefined>): string {
  const clean = (p: unknown) =>
    String(p ?? "").replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
  const token = parts.map(clean).filter(Boolean).join("-");
  if (token.length <= CT_MAX_LENGTH) return token;
  return clean(parts[0]).slice(0, CT_MAX_LENGTH);
}

/**
 * The App Store link for one acquisition surface.
 *
 * `surface` is the campaign: "tour", "portfolio", "site". A tour also carries
 * its slug ("tour-estate-demo") so a single listing's page can be credited —
 * slugs are nanoid/base64url, so they survive `campaignToken` unchanged and a
 * long one degrades to the bare surface rather than to a truncated twin.
 */
export function appStoreUrl(...surface: Array<string | null | undefined>): string {
  const ct = campaignToken(...surface);
  const params = [
    ...(APPLE_PROVIDER_TOKEN ? [`pt=${encodeURIComponent(APPLE_PROVIDER_TOKEN)}`] : []),
    ...(ct ? [`ct=${encodeURIComponent(ct)}`] : []),
    "mt=8",
  ];
  return `${APP_STORE_URL}?${params.join("&")}`;
}

/**
 * An outbound link to the marketing site, tagged with the page it came from:
 * `https://rendprop.com/?ref=tour`.
 *
 * Deliberately inert on arrival. `public/assets/site.js` does NOT read it — no
 * cookie, no localStorage, no pixel, no third-party script (see the comment
 * there). It exists so the value is present in the Worker's own request logs
 * and in a server-side referrer, and so that when the owner ever does want the
 * number there is one spelling of it already in the wild. `ref` is not Apple's
 * `ct` and the two never mix: this one never leaves rendprop.com.
 */
export function siteUrl(ref: string): string {
  const clean = campaignToken(ref);
  return clean ? `https://rendprop.com/?ref=${clean}` : "https://rendprop.com/";
}
