import { tourLinks } from "./model";

export type TourLinks = NonNullable<ReturnType<typeof tourLinks>>;
export type ResolvedTourLinks = { links: TourLinks; verified: boolean; addressOnly: boolean | null };
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

export function safeTourLinks(slug: string, resolved?: ResolvedTourLinks | null): TourLinks | null {
  const fallback = tourLinks(slug);
  if (!fallback || !resolved || resolved.links.unbranded !== fallback.unbranded || !resolved.verified) return fallback;
  const branded = resolved.links.branded;
  return verifiedTourShareURL(branded, resolved.addressOnly, slug)
    ? { branded, unbranded: fallback.unbranded } : fallback;
}

/** Public, credential-free, no-referrer lookup. Failure keeps an already
 * published token URL usable; the MLS /u link is never changed by this read. */
export async function resolveTourLinks(slug: string, options: { signal?: AbortSignal; fetcher?: typeof fetch } = {}): Promise<ResolvedTourLinks | null> {
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
    if (response.status !== 200 || response.url !== endpoint || Number(response.headers.get("content-length") ?? 0) > 2048) return { links: fallback, verified: false, addressOnly: null };
    const body = await response.text();
    if (options.signal?.aborted) options.signal.throwIfAborted();
    if (new TextEncoder().encode(body).length > 2048) return { links: fallback, verified: false, addressOnly: null };
    const value: unknown = JSON.parse(body);
    if (!value || typeof value !== "object" || Array.isArray(value)) return { links: fallback, verified: false, addressOnly: null };
    const row = value as Record<string, unknown>;
    const branded = verifiedTourShareURL(row.url, row.address_only, slug);
    return branded ? { links: { branded, unbranded: fallback.unbranded }, verified: true, addressOnly: row.address_only as boolean } : { links: fallback, verified: false, addressOnly: null };
  } catch (error) {
    if (options.signal?.aborted) throw error;
    return { links: fallback, verified: false, addressOnly: null };
  }
}
