import { tourLinks } from "./model";

export type TourLinks = NonNullable<ReturnType<typeof tourLinks>>;
export type ResolvedTourLinks = { links: TourLinks; verified: true; addressOnly: boolean };
/** False means Tour Host confirmed this publication is no longer public. */
export type TourShareProof = ResolvedTourLinks | false;
const origin = "https://rendprop.com";
const descriptor = "[a-z0-9](?:[a-z0-9-]{0,118}[a-z0-9])?";
const slugPattern = /^[A-Za-z0-9_-]{1,64}$/;

/** Only Tour Host's exact public response can replace the safe /f token link.
 * A dated or undated address path must end in this publication's unchanged slug;
 * a bare address needs the server's explicit reserved-address proof. */
export function verifiedTourShareURL(raw: unknown, addressOnly: unknown, slug: string): string | null {
  if (typeof raw !== "string" || raw.length > 300 || typeof addressOnly !== "boolean" || !slugPattern.test(slug)) return null;
  let url: URL;
  try { url = new URL(raw); } catch { return null; }
  if (url.href !== raw || url.origin !== origin || url.username || url.password || url.port || url.search || url.hash) return null;
  const path = url.pathname;
  if (addressOnly) return new RegExp(`^/property/${descriptor}$`).test(path) ? raw : null;
  const match = new RegExp(`^/property/${descriptor}/([^/]+)$`).exec(path);
  if (!match) return null;
  const tail = match[1];
  return tail === slug || new RegExp(`^[0-9]{8}\\.${slug}$`).test(tail) ? raw : null;
}

export function safeTourLinks(slug: string, resolved?: TourShareProof | null): TourLinks | null {
  const fallback = tourLinks(slug);
  if (resolved === false) return null;
  if (!fallback || !resolved || resolved.links.unbranded !== fallback.unbranded) return fallback;
  const branded = resolved.links.branded;
  return verifiedTourShareURL(branded, resolved.addressOnly, slug)
    ? { branded, unbranded: fallback.unbranded } : fallback;
}

/** Public, credential-free, no-referrer lookup. A bounded, exact not_found
 * response withholds stale links; null means transient/unknown and keeps the
 * published token fallback usable. The MLS /u link is unchanged by this read. */
export async function resolveTourLinks(slug: string, options: { signal?: AbortSignal; fetcher?: typeof fetch } = {}): Promise<TourShareProof | null> {
  const fallback = tourLinks(slug);
  if (!fallback || !slugPattern.test(slug)) return null;
  const endpoint = `${origin}/f/${slug}/share-link`;
  try {
    const response = await (options.fetcher ?? fetch)(endpoint, {
      method: "GET", cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer", redirect: "error",
      signal: options.signal ? AbortSignal.any([options.signal, AbortSignal.timeout(8000)]) : AbortSignal.timeout(8000),
      headers: { Accept: "application/json" },
    });
    if (options.signal?.aborted) options.signal.throwIfAborted();
    if (response.status !== 200 && response.status !== 404 || response.url !== endpoint ||
        Number(response.headers.get("content-length") ?? 0) > 2048) return null;
    const body = await response.text();
    if (options.signal?.aborted) options.signal.throwIfAborted();
    if (new TextEncoder().encode(body).length > 2048) return null;
    if (response.status === 404) return body === '{"error":"not_found"}' ? false : null;
    const value: unknown = JSON.parse(body);
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const row = value as Record<string, unknown>;
    const branded = verifiedTourShareURL(row.url, row.address_only, slug);
    return branded ? { links: { branded, unbranded: fallback.unbranded }, verified: true, addressOnly: row.address_only as boolean } : null;
  } catch (error) {
    if (options.signal?.aborted) throw error;
    return null;
  }
}
