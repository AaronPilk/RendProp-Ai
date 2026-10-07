import { assert, HttpError } from "./http.ts";

/** A publishable anon key is not a private gateway identity. Reject before DB
 * lookup, including malformed or missing configured secrets. */
export async function requireMediaGateway(req: Request): Promise<void> {
  const expected = Deno.env.get("MEDIA_GATEWAY_SECRET") || "";
  const offered = req.headers.get("X-Rendprop-Media-Gateway") || "";
  assert(/^[a-f0-9]{64}$/.test(expected), 503, "Media service activation pending.");
  assert(/^[a-f0-9]{64}$/.test(offered), 403, "Media gateway verification required.");
  const encode = new TextEncoder();
  const [a, b] = await Promise.all([expected, offered].map(value => crypto.subtle.digest("SHA-256", encode.encode(value))));
  let difference = 0;
  const left = new Uint8Array(a), right = new Uint8Array(b);
  for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i];
  assert(difference === 0, 403, "Media gateway verification required.");
}

export function deliveryBytes(req: Request): number {
  const value = new URL(req.url).searchParams.get("bytes");
  if (value === null) return 0;
  assert(/^(0|[1-9][0-9]{0,8})$/.test(value), 400, "Invalid media byte admission.");
  const bytes = Number(value);
  assert(Number.isSafeInteger(bytes) && bytes <= 256 * 1024 * 1024, 400, "Invalid media byte admission.");
  return bytes;
}

/** Counts all authority reads, HEAD and conditional reads too. Spending is
 * conservative: lost responses/cancelled downloads cannot release allowance.
 * Legacy private replay remains compatible until an explicit budget is staged;
 * any financially funded workspace always needs its exact bounded budget. */
// deno-lint-ignore no-explicit-any
export async function admitMediaRead(admin: any, org: string, bytes: number, required = true): Promise<void> {
  const {data, error} = await admin.rpc("media_delivery_admit", {p_org:org,p_bytes:bytes,p_required:required});
  if (error) {
    const prefix = /^RP(404|429):/.exec(error.message || "");
    throw new HttpError(prefix ? Number(prefix[1]) : 503, prefix?.[1] === "429" ? "Media serving allowance exhausted." : "Media service is unavailable.");
  }
  assert(data?.admitted === true && typeof data.legacy_unbudgeted === "boolean" && (!required || data.legacy_unbudgeted === false), 503, "Media admission could not be verified.");
}
