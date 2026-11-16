// The PUBLIC agent card, shared by tours/ and portfolio/.
//
// Rules (decision A14, audit F-supabase-06 / F-E-10):
//   • Allow-list the display fields — never spread the whole brand_kit jsonb.
//   • The name is brand_kit.name, else the listing agent's profile name, else
//     null (the host hides the card). It NEVER falls back to orgs.name, which
//     the old signup trigger set to the user's sign-in email.
//   • Anything that looks like an email address is dropped, not published.

/** A display name that is safe to publish: non-empty and not an email. */
export function publicName(raw: unknown): string | null {
  const s = String(raw ?? "").trim();
  if (!s || s.includes("@")) return null;
  return s.slice(0, 120);
}

const AGENT_CARD_FIELDS = [
  "title", "brokerage", "phone", "email", "website",
  "avatar_url", "headshot_url", "business_logo_url", "instagram", "linkedin", "tiktok", "accent",
] as const;

export function buildAgentCard(
  brandKit: unknown,
  opts: { profileName?: unknown; orgHandle?: unknown },
): Record<string, unknown> {
  const brand = (brandKit && typeof brandKit === "object" ? brandKit : {}) as Record<string, unknown>;
  const card: Record<string, unknown> = {
    name: publicName(brand.name) ?? publicName(opts.profileName) ?? null,
    handle: (typeof brand.handle === "string" && brand.handle) ? brand.handle : (opts.orgHandle ?? null),
  };
  for (const f of AGENT_CARD_FIELDS) {
    if (brand[f] != null) card[f] = brand[f];
  }
  return card;
}

/** A listing contact belongs to its current agent, except an explicit legacy
 * sole-owner card. Workspace identity fields never replace a team member. */
export function buildPersonalListingCard(identity: Record<string, unknown>, portraitURL?: string): Record<string, unknown> {
  const business = identity.org_business && typeof identity.org_business === "object" ? identity.org_business as Record<string,unknown> : {};
  if (identity.legacy_owned_single_member === true) {
    const card=buildAgentCard(identity.legacy_brand, {profileName:identity.profile_name,orgHandle:identity.org_handle});
    if (typeof business.business_logo_url==="string") card.business_logo_url=business.business_logo_url;
    if (portraitURL) card.avatar_url=portraitURL;
    return card;
  }
  const personal = identity.personal_card && typeof identity.personal_card === "object" ? identity.personal_card as Record<string,unknown> : {};
  const card: Record<string,unknown> = {name:publicName(personal.name) ?? publicName(identity.profile_name),handle:identity.org_handle ?? null};
  for (const field of ["title","phone","email","website","instagram","linkedin","tiktok"] as const) {
    if (typeof personal[field] === "string") card[field]=personal[field];
  }
  for (const field of ["brokerage","accent","business_logo_url"] as const) {
    if (typeof business[field] === "string") card[field]=business[field];
  }
  if (typeof personal.brokerage === "string") card.brokerage=personal.brokerage;
  if (portraitURL) card.avatar_url=portraitURL;
  return card;
}
