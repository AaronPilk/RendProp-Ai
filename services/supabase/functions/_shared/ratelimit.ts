// Durable, cross-instance rate limiting.
//
// Primary: the bump_rate() Postgres function (migrations 0004 + 0006) — an
// atomic fixed-window counter shared by every edge-function instance. Each row
// remembers its own window length, so 30-day monthly caps survive cleanup
// (audit P0-3: the old cleanup deleted every counter older than a day).
//
// `cost` lets one call charge more than one unit — the uploads batch endpoint
// charges one unit PER FILE (audit P0-2: charging per batch let 200-file
// batches mint 400k tickets/day against a 2k cap).
//
// Paid operations, deduplication and private writes FAIL CLOSED if the RPC is
// unreachable. A per-instance counter cannot enforce their cross-instance
// allowance. Only explicitly public, unbilled ingestion may opt into the
// quarter-ceiling memory fallback via publicRateLimit().

import { HttpError, rateLimit as memoryRateLimit } from "./http.ts";
import { adminClient } from "./supabase.ts";

/**
 * Returns true when the caller is within `max` units per `windowSeconds`
 * for `key` (e.g. "leads:1.2.3.4"). Durable across instances.
 */
export async function durableRateLimit(
  key: string,
  max: number,
  windowSeconds: number,
  cost = 1,
): Promise<boolean> {
  return await checkRateLimit(key, max, windowSeconds, cost, false);
}

/** Degraded fallback ONLY for unbilled public leads/beacon/events ingestion. */
export async function publicRateLimit(
  key: string,
  max: number,
  windowSeconds: number,
  cost = 1,
): Promise<boolean> {
  return await checkRateLimit(key, max, windowSeconds, cost, true);
}

async function checkRateLimit(
  key: string,
  max: number,
  windowSeconds: number,
  cost: number,
  publicFallback: boolean,
): Promise<boolean> {
  try {
    const { data, error } = await adminClient().rpc("bump_rate", {
      p_key: key,
      p_window_seconds: windowSeconds,
      p_max: max,
      p_cost: Math.max(1, Math.round(cost)),
    });
    if (error || typeof data !== "boolean") throw new Error("Meter unavailable");
    return data;
  } catch {
    if (!publicFallback) {
      // Do not expose raw RPC responses, credentials or tenant keys in logs.
      console.error("bump_rate unavailable; request refused before admission");
      throw new HttpError(503, "Processing limits are temporarily unavailable — try again shortly.", "upstream");
    }
    console.error("bump_rate unavailable; public ingestion using degraded memory limit");
    // Degraded mode: quarter ceiling, still per-cost.
    const degradedMax = Math.max(1, Math.floor(max / 4));
    let ok = true;
    for (let i = 0; i < Math.max(1, Math.round(cost)); i++) {
      ok = memoryRateLimit(key, degradedMax, windowSeconds * 1000);
      if (!ok) break;
    }
    return ok;
  }
}

/**
 * Give back units charged by `durableRateLimit` for work that then FAILED
 * (audit F-E-16). The AI guards charge the monthly meter immediately before
 * the billable provider call, so a 502 from Gemini/fal used to cost the org an
 * allowance for a request that produced nothing.
 *
 * Delegates to refund_rate() (migration 0014), which subtracts inside the
 * charge's OWN window and floors at zero — a refund can neither mint free
 * allowance in a later window nor drive a counter negative.
 *
 * Best effort and never throws: a failed refund must not turn a provider error
 * into a 500 the user sees instead of the real reason. There is no degraded
 * fallback — the in-memory limiter is per-instance, so "refunding" there would
 * usually target a counter that is not the one that was charged.
 *
 * @returns true when the counter was actually decremented.
 */
export async function refundRateLimit(
  key: string,
  windowSeconds: number,
  cost = 1,
): Promise<boolean> {
  try {
    const { data, error } = await adminClient().rpc("refund_rate", {
      p_key: key,
      p_window_seconds: windowSeconds,
      p_cost: Math.max(1, Math.round(cost)),
    });
    if (error) throw new Error(error.message);
    return data === true;
  } catch (e) {
    // Key names are org ids + feature slugs — no secrets, no user content.
    console.error("refund_rate unavailable; quota stays charged:", e);
    return false;
  }
}

export interface RateChargeReceipt { key: string; windowSeconds: number; windowStart: string; }
/** Paid video uses the exact SQL window that charged this request. */
export async function chargeRateReceipt(key: string, max: number, windowSeconds: number): Promise<{ accepted: boolean; receipt: RateChargeReceipt }> {
  try {
    const { data, error } = await adminClient().rpc("bump_rate_receipt", { p_key: key, p_max: max, p_window_seconds: windowSeconds, p_cost: 1 });
    if (error || typeof data?.accepted !== "boolean" || typeof data?.window_start !== "string" || !Number.isFinite(Date.parse(data.window_start))) throw new Error("Unconfirmed quota receipt");
    return { accepted: data.accepted, receipt: { key, windowSeconds, windowStart: data.window_start } };
  } catch {
    throw new HttpError(503, "Processing limits could not be confirmed. Please retry shortly.", "upstream");
  }
}
export async function refundRateReceipt(receipt: RateChargeReceipt): Promise<boolean> {
  try {
    const { data, error } = await adminClient().rpc("refund_rate_receipt", { p_key: receipt.key, p_window_seconds: receipt.windowSeconds, p_window_start: receipt.windowStart, p_cost: 1 });
    return !error && data === true;
  } catch { return false; }
}
