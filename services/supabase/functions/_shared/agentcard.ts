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
  "avatar_url", "headshot_url", "instagram", "linkedin", "tiktok", "accent",
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
