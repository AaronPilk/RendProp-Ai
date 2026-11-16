import type { PropertyPage } from "./property-site";

/** Descriptive address plus the existing opaque publication ID. The address
 * never identifies a different property and two equal addresses cannot collide. */
export function propertyAddressSlug(value: unknown): string {
  if (typeof value !== "string") return "";
  return value.slice(0, 500).normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    .slice(0, 120).replace(/-+$/g, "");
}

export function propertyAddressPath(slug: string, address: unknown, base: "/property" | "/u" = "/property", publishedAt?: unknown): string {
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(slug)) throw new Error("Invalid published property identity");
  const descriptor = propertyAddressSlug(address);
  // The full publication slug, already unique in renders, makes same-address
  // and same-day publications collision-proof. republish_render preserves its
  // first published_at and slug; an older token URL remains a valid alias.
  const day = typeof publishedAt === "string" && /^\d{4}-\d{2}-\d{2}T/.test(publishedAt)
    && Number.isFinite(Date.parse(publishedAt)) ? publishedAt.slice(0, 10).replace(/-/g, "") : "";
  // A dot cannot occur in a legacy publication slug, so the dated alias
  // occupies a disjoint route namespace without extra database identity.
  const identity = base === "/property" && day ? `${day}.${slug}` : slug;
  return `${base}/${descriptor ? `${descriptor}/` : ""}${encodeURIComponent(identity)}`;
}

/** An address can identify a public page only after the publication authority
 * has proved it resolves to exactly one current tour. Empty descriptors keep
 * the existing address-plus-publication-ID path. */
export function propertyAddressOnlyPath(address: unknown): string | null {
  const descriptor = propertyAddressSlug(address);
  return descriptor ? `/property/${descriptor}` : null;
}

export function propertySearchMeta(page: PropertyPage | null, title: string, description: string, address: string) {
  const label = page && page !== "home" ? page[0].toUpperCase() + page.slice(1) : "";
  const descriptions: Record<string, string> = {
    gallery: `View the property photos for ${address}. Open each photo at full size and review any media disclosures.`,
    location: `Explore the location of ${address}, with a map and available nearby places.`,
    contact: `Request information or a showing for ${address} from its listing contact.`,
  };
  return { title: label ? `${label} · ${title}` : title, description: page && descriptions[page] || description };
}

export function propertyCanonical(origin: string, path: string, page: PropertyPage | null): string {
  const url = new URL(path, origin);
  if (url.origin !== new URL(origin).origin) throw new Error("Property canonical must stay on its host");
  if (page && page !== "home") url.searchParams.set("page", page);
  return url.href;
}
