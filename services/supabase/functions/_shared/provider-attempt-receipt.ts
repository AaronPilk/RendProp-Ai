import { HttpError, throwRpc } from "./http.ts";
import { propertyRequestId } from "./property/provider.ts";

type Authority = { rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }> };
export type PropertyAttempt = { actor: string; org: string; id: string };
export type PropertyOutcome = { outcome: "hit" | "no_record" | "http_error" | "invalid_response" | "transport_unknown"; status: number | null; requestId: string | null; estimatedCents?: number; ledgerStatus?: "recorded" | "unconfirmed" };
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
async function sha256(value: string): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))), b => b.toString(16).padStart(2, "0")).join("");
}
async function rpc(admin: Authority, name: string, args: Record<string, unknown>) {
  const query = admin.rpc(name, args) as ReturnType<Authority["rpc"]> & { abortSignal?: (signal: AbortSignal) => ReturnType<Authority["rpc"]> };
  return await (typeof query.abortSignal === "function" ? query.abortSignal(AbortSignal.timeout(10_000)) : query);
}

/** One intent per incoming request unless the caller supplies an existing
 * operation key. Keys/inputs are hashed; this stores no address or raw key.
 * A lost begin reply never grants a supplier dispatch. */
export async function beginPropertyAttempt(admin: Authority, actor: string, org: string, req: Request, normalizedAddress: string): Promise<PropertyAttempt> {
  const supplied = req.headers.get("idempotency-key");
  if (supplied !== null && !/^[\x21-\x7e]{8,128}$/.test(supplied)) throw new HttpError(400, "Use a valid lookup operation identifier.");
  const operation = await sha256(supplied ?? crypto.randomUUID()), input = await sha256(normalizedAddress);
  let result;
  try { result = await rpc(admin, "provider_attempt_begin", { p_actor: actor, p_org: org, p_operation_sha256: operation, p_input_sha256: input }); }
  catch { throw new HttpError(503, "This lookup could not be recorded safely. No property-records request was sent."); }
  if (result.error) {
    const message = typeof result.error === "object" && result.error !== null ? (result.error as { message?: unknown }).message : null;
    if (typeof message === "string" && /RP(?:400|403|409):/.test(message)) throwRpc(message);
    throw new HttpError(503, "This lookup could not be recorded safely. No property-records request was sent.");
  }
  const value = result.data as Record<string, unknown> | null;
  if (!value || typeof value !== "object" || Array.isArray(value) || typeof value.attempt_id !== "string" || !UUID.test(value.attempt_id) || value.actor_id !== actor || value.org_id !== org || value.operation_sha256 !== operation || value.input_sha256 !== input || typeof value.dispatch !== "boolean" || !["intent", "hit", "no_record", "http_error", "invalid_response", "transport_unknown"].includes(String(value.outcome)))
    throw new HttpError(503, "The saved lookup identity could not be verified. No property-records request was sent.");
  if (!value.dispatch) throw new HttpError(409, value.outcome === "intent" || value.outcome === "transport_unknown"
    ? "This lookup was already started. Its outcome is still in progress or unknown; no second request was sent."
    : "This lookup is already recorded. No second property-records request was sent.", "conflict");
  if (value.outcome !== "intent") throw new HttpError(503, "The saved lookup dispatch could not be verified. No property-records request was sent.");
  return { actor, org, id: value.attempt_id };
}

/** A lost terminal write leaves the durable intent unresolved. It cannot
 * trigger another supplier call, remove the intent, or fabricate a charge. */
export async function finishPropertyAttempt(admin: Authority, attempt: PropertyAttempt, evidence: PropertyOutcome): Promise<boolean> {
  try {
    const result = await rpc(admin, "provider_attempt_finish", {
      p_actor: attempt.actor, p_org: attempt.org, p_attempt: attempt.id,
      p_outcome: evidence.outcome, p_http_status: evidence.status,
      p_provider_request_id: propertyRequestId(evidence.requestId),
      p_estimated_cents: evidence.estimatedCents ?? null,
      p_ledger_status: evidence.ledgerStatus ?? "not_booked",
    });
    const value = result.data as Record<string, unknown> | null;
    if (!result.error && value && value.saved === true && value.attempt_id === attempt.id) return true;
  } catch { /* Only bounded, content-free failure information is logged below. */ }
  console.error("Property provider outcome could not be persisted; durable intent remains unresolved.");
  return false;
}
