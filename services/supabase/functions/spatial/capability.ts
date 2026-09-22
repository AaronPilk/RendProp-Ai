import { assert, HttpError } from "../_shared/http.ts";
import { object, uuid } from "./contract.ts";
const encoder = new TextEncoder();
const encode = (b: Uint8Array) =>
  btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_")
    .replace(/=+$/, "");
function decode(s: string) {
  assert(/^[A-Za-z0-9_-]+$/.test(s), 401, "Invalid spatial access");
  return Uint8Array.from(
    atob(s.replace(/-/g, "+").replace(/_/g, "/")),
    (x) => x.charCodeAt(0),
  );
}
export interface Capability {
  v: 1;
  kind: "viewer" | "output";
  job: string;
  revision: string;
  actor: string;
  exp: number;
  lease?: string;
}
function secret(): string {
  const s = Deno.env.get("SPATIAL_CAPABILITY_SECRET");
  if (!s || s.length < 32 || s.length > 256 || s !== s.trim()) {
    throw new HttpError(503, "3D access signing is not configured");
  }
  return s;
}
export async function signCapability(
  payload: Capability,
  key = secret(),
): Promise<string> {
  const part = encode(encoder.encode(JSON.stringify(payload))),
    k = await crypto.subtle.importKey(
      "raw",
      encoder.encode(key),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
  return `${part}.${
    encode(
      new Uint8Array(await crypto.subtle.sign("HMAC", k, encoder.encode(part))),
    )
  }`;
}
export async function verifyCapability(
  token: string,
  kind: Capability["kind"],
  key = secret(),
): Promise<Capability> {
  assert(token.length <= 2048, 401, "Invalid spatial access");
  const parts = token.split(".");
  assert(parts.length === 2, 401, "Invalid spatial access");
  try {
    const k = await crypto.subtle.importKey(
      "raw",
      encoder.encode(key),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"],
    );
    assert(
      await crypto.subtle.verify(
        "HMAC",
        k,
        decode(parts[1]),
        encoder.encode(parts[0]),
      ),
      401,
      "Invalid spatial access",
    );
    const p = object(JSON.parse(new TextDecoder().decode(decode(parts[0]))));
    assert(
      p.v === 1 && p.kind === kind && typeof p.exp === "number" &&
        Number.isInteger(p.exp) && p.exp > Math.floor(Date.now() / 1000) &&
        p.exp <= Math.floor(Date.now() / 1000) + 900,
      401,
      "Spatial access expired",
    );
    uuid(p.job);
    uuid(p.revision);
    uuid(p.actor);
    if (kind === "output") uuid(p.lease);
    return p as unknown as Capability;
  } catch (error) {
    if (error instanceof HttpError && error.status === 503) throw error;
    throw new HttpError(401, "Invalid or expired spatial access");
  }
}
