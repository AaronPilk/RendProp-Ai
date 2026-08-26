// Durable, cross-instance rate limiting for the PUBLIC endpoints.
//
// Primary: the bump_rate() Postgres function (migration 0004) — an atomic
// fixed-window counter shared by every edge-function instance.
// Fallback: the in-memory limiter from http.ts, used only if the RPC is
// missing or errors (fail-open on infrastructure, fail-closed on volume).

import { rateLimit as memoryRateLimit } from "./http.ts";
import { adminClient } from "./supabase.ts";

/**
 * Returns true when the caller is within `max` hits per `windowSeconds`
 * for `key` (e.g. "leads:1.2.3.4"). Durable across instances.
 */
export async function durableRateLimit(
  key: string,
  max: number,
  windowSeconds: number,
): Promise<boolean> {
  try {
    const { data, error } = await adminClient().rpc("bump_rate", {
      p_key: key,
      p_window_seconds: windowSeconds,
      p_max: max,
    });
    if (error) throw new Error(error.message);
    return data === true;
  } catch (e) {
    console.error("bump_rate unavailable, falling back to memory limiter:", e);
    return memoryRateLimit(key, max, windowSeconds * 1000);
  }
}
