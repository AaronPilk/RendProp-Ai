import { assert, HttpError, json } from "../_shared/http.ts";

/** Address-only paths are public, but the address→slug directory is not. A
 * separate Worker→API credential keeps noindex slugs out of guessed direct
 * Edge Function requests, including while the Worker feature flag is off. */
async function requireAddressLookupGateway(req: Request): Promise<void> {
  const expected = Deno.env.get("ADDRESS_LOOKUP_SECRET") || "";
  const offered = req.headers.get("X-Rendprop-Address-Lookup") || "";
  assert(/^[a-f0-9]{64}$/.test(expected), 503, "Property address lookup is unavailable.");
  assert(/^[a-f0-9]{64}$/.test(offered), 403, "Property address lookup gateway required.");
  const encode = new TextEncoder();
  const [a, b] = await Promise.all([expected, offered].map((value) =>
    crypto.subtle.digest("SHA-256", encode.encode(value))));
  let difference = 0;
  const left = new Uint8Array(a), right = new Uint8Array(b);
  for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i];
  assert(difference === 0, 403, "Property address lookup gateway required.");
}

/** The host accepts only a current, unique address-to-publication proof. The
 * RPC examines all hostable real-estate publications, including noindex rows;
 * the browser never receives a listing ID or raw address from this endpoint. */
// deno-lint-ignore no-explicit-any
export async function propertyAddressLookup(req: Request, descriptor: string, admin: any): Promise<Response> {
  await requireAddressLookupGateway(req);
  assert(!new URL(req.url).search, 400, "Use an exact property address path.");
  assert(/^[a-z0-9][a-z0-9-]{0,119}$/.test(descriptor) && !descriptor.endsWith("-"),
    400, "Use one bounded property address descriptor.");
  const { data, error } = await admin.rpc("public_property_address_lookup", { p_descriptor: descriptor });
  if (error) throw new HttpError(503, "The property address could not be verified. Please retry.");
  if (data === null) throw new HttpError(404, "Property address not found.");
  if (data && typeof data === "object" && !Array.isArray(data) &&
      Object.keys(data).length === 1 && data.status === "ambiguous")
    return json({ status: "ambiguous" }, 200, { "Cache-Control": "no-store" });
  if (data && typeof data === "object" && !Array.isArray(data) &&
      Object.keys(data).length === 2 && data.status === "unique" &&
      typeof data.slug === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(data.slug))
    return json({ status: "unique", slug: data.slug }, 200, { "Cache-Control": "no-store" });
  throw new HttpError(503, "The property address could not be verified. Please retry.");
}
