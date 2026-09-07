// beacon/logic.ts — the one decision in this route worth testing without a
// database: whether THIS beacon should count as a new view.
//
// Pulled out of index.ts (which calls Deno.serve at module load and so is
// never imported by a test — see events/schema.ts or apple-subscriptions/
// logic.ts for the same pattern in this codebase) so it gets a direct unit
// test. See logic.test.ts.
//
// ── Audit: "Public beacon metrics are replayable" ───────────────────────────
//
// bump_metering() clamps p_views to [0,1] PER CALL, but nothing stopped a
// caller from POSTing `view_start:true` for the same tour over and over — the
// per-IP 120/60s limiter in index.ts bounds request VOLUME, not how many of
// those requests get to count as a NEW view. See index.ts for the
// per-(IP, slug) dedupe window this decision is built on (durableRateLimit
// used as a one-shot-per-window gate), and its header + docs/ADMIN-CONSOLE-
// CONTRACT.md for the honest limits of that mitigation: these counts remain
// public, unauthenticated, best-effort telemetry — never billing truth.

/**
 * Whether this beacon should count as a NEW view.
 *
 * `viewStart` is the player's own claim that this is the first beacon of a
 * session (see BeaconBody in index.ts) — under honest client behavior that is
 * true at most once per real viewing session. `reserve()` is the dedupe gate:
 * callers pass a one-shot-per-window check (index.ts wires this to
 * `durableRateLimit(key, 1, window)`, which answers true only the FIRST time
 * it's called for a given key inside the window) so a claim of
 * `view_start:true` only actually counts once per (IP, slug) per window, no
 * matter how many times it's replayed inside it.
 *
 * `reserve` is never even called when `viewStart` isn't `true` — a normal
 * watch/scroll-progress beacon (the vast majority of traffic) does zero extra
 * rate-limit work.
 */
export async function shouldCountView(
  viewStart: boolean | undefined,
  reserve: () => Promise<boolean>,
): Promise<boolean> {
  if (viewStart !== true) return false;
  return await reserve();
}
