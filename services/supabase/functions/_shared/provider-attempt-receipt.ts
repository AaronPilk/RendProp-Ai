import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
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


/** A lost insert reply is uncertain until this exact server-stamped row can be
 * read back. Never resend a supplier request or accept a foreign ledger row. */
export async function recordPropertyAttemptCost(admin: SupabaseClient, attempt: PropertyAttempt, unitCents: number, result: Record<string, unknown>): Promise<{ recorded: boolean; total_cents: number }> {
  const total_cents = Math.round(unitCents * 10_000) / 10_000;
  const meta = { ...result, provider_attempt_id: attempt.id, actor_id: attempt.actor, cost_basis: "configured_per_call_estimate" };
  const row = { job_id: null, org_id: attempt.org, feature: "property_lookup", provider: "rentcast", model: "properties", units: 1, unit_cost_cents: unitCents, total_cents, meta };
  try {
    const written = await admin.from("cost_ledger").insert(row);
    if (!written.error) return { recorded: true, total_cents };
  } catch { /* The write may have committed. Verify without repeating it. */ }
  try {
    const authority = await admin.from("provider_attempt_receipts")
      .select("id,actor_id,org_id,billing_org_id,provider,model,stage,outcome,http_status,estimated_cents,ledger_status,terminal_at")
      .eq("id", attempt.id).eq("actor_id", attempt.actor).eq("org_id", attempt.org).maybeSingle();
    const receipt = authority.data as Record<string, unknown> | null;
    const intent = receipt?.outcome === "intent" && receipt.http_status === null && receipt.estimated_cents === null
      && receipt.ledger_status === "not_booked" && receipt.terminal_at === null;
    const terminal = receipt !== null && receipt.outcome === result.result && ["hit", "no_record"].includes(String(receipt.outcome))
      && typeof receipt.http_status === "number" && Number.isInteger(receipt.http_status)
      && ((receipt.http_status >= 200 && receipt.http_status <= 299) || (receipt.outcome === "no_record" && receipt.http_status === 404))
      && receipt.estimated_cents === total_cents && ["recorded", "unconfirmed"].includes(String(receipt.ledger_status))
      && typeof receipt.terminal_at === "string" && receipt.terminal_at.length > 0;
    if (authority.error || !receipt || receipt.id !== attempt.id || receipt.actor_id !== attempt.actor || receipt.org_id !== attempt.org
      || typeof receipt.billing_org_id !== "string" || !UUID.test(receipt.billing_org_id)
      || receipt.provider !== "rentcast" || receipt.model !== "properties" || receipt.stage !== "property.lookup" || !(intent || terminal))
      throw new Error("Unconfirmed immutable property attempt identity");
    const read = await admin.from("cost_ledger").select("id,job_id,org_id,billing_org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key")
      .eq("org_id", attempt.org).eq("idempotency_key", "provider-attempt:" + attempt.id).maybeSingle();
    const saved = read.data as Record<string, unknown> | null;
    const savedMeta = saved?.meta as Record<string, unknown> | null;
    if (!read.error && saved && savedMeta && typeof saved.id === "string" && UUID.test(saved.id)
      && saved.billing_org_id === receipt.billing_org_id
      && saved.job_id === null && saved.org_id === attempt.org && saved.feature === row.feature
      && saved.provider === row.provider && saved.model === row.model && saved.units === row.units
      && saved.unit_cost_cents === unitCents && saved.total_cents === total_cents
      && saved.idempotency_key === "provider-attempt:" + attempt.id
      && savedMeta.provider_attempt_id === attempt.id && savedMeta.actor_id === attempt.actor
      && savedMeta.result === result.result && savedMeta.cost_basis === meta.cost_basis)
      return { recorded: true, total_cents };
  } catch { /* Unknown stays unconfirmed; no insertion or supplier retry. */ }
  console.error("Property provider cost could not be confirmed; durable attempt retains unconfirmed accounting.");
  return { recorded: false, total_cents };
}
