import type { PropertyPage } from "./property-site";

/** Descriptive address plus the existing opaque publication ID. The address
 * never identifies a different property and two equal addresses cannot collide. */
export function propertyAddressSlug(value: unknown): string {
  if (typeof value !== "string") return "";
  return value.slice(0, 500).normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    .slice(0, 120).replace(/-+$/g, "");
}

export function propertyAddressPath(slug: string, address: unknown): string {
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(slug)) throw new Error("Invalid published property identity");
  const descriptor = propertyAddressSlug(address);
  return `/property/${descriptor ? `${descriptor}/` : ""}${encodeURIComponent(slug)}`;
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
