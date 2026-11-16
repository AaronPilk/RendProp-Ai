import { assert, HttpError, throwRpc } from "../_shared/http.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NONCE = /^[0-9a-f]{64}$/;
export const CLIENT_VERIFICATION_ERROR = "Verification link is invalid or expired.";

function body(raw: unknown, key: string): string {
  assert(raw && typeof raw === "object" && !Array.isArray(raw) &&
    Object.keys(raw).length === 1 && key in raw && typeof raw[key as keyof typeof raw] === "string",
    400, key === "token" ? CLIENT_VERIFICATION_ERROR : "Choose a saved listing contact.");
  return (raw as Record<string, string>)[key];
}

// deno-lint-ignore no-explicit-any
export async function requestClientVerification(admin: any, user: string, org: string, raw: unknown) {
  const listing = body(raw, "listing_id");
  assert(UUID.test(listing), 400, "Choose a saved listing contact.");
  const nonce = Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, "0")).join("");
  const { data, error } = await admin.rpc("client_recipient_verification_request", {
    p_user: user, p_org: org, p_listing: listing, p_nonce: nonce,
  });
  if (error) {
    if (/RP\d{3}:/.test(error.message ?? "")) throwRpc(error.message);
    throw new HttpError(503, "Verification email could not be queued. Please retry.");
  }
  assert(data && data.ok === true && ["queued", "verified"].includes(data.state),
    503, "Verification email could not be confirmed.");
  // No opaque nonce or recipient is reflected into an authenticated API result.
  return { ok: true, state: data.state };
}

// A scanner's GET never reaches this function. The public page requires an
// explicit POST, and the token is carried in JSON, never a URL or log field.
// deno-lint-ignore no-explicit-any
export async function verifyClientRecipient(admin: any, raw: unknown) {
  const nonce = body(raw, "token");
  assert(NONCE.test(nonce), 400, CLIENT_VERIFICATION_ERROR);
  const { data, error } = await admin.rpc("client_recipient_verification_consume", { p_nonce: nonce });
  if (error) throw new HttpError(503, "Verification is temporarily unavailable. Please retry.");
  assert(data === true, 400, CLIENT_VERIFICATION_ERROR);
  return { ok: true };
}
