// admin/funnel.ts — GET /admin/funnel, the launch-week screen.
//
//   GET /admin/funnel?window=7d|30d|90d   (default 30d)
//    -> { generated_at, window, from, to,
//         steps: [ { name, label, count, pct_of_previous, pct_of_first } ],
//         crashes, errors, active_devices, sessions, events, by_day: [...],
//         purchases_verified, purchases_verified_sandbox,
//         purchase_completed_attributed }
//
// The owner is spending money on Meta ads. This route answers the only two
// questions that matter while that money is running: WHERE do people fall out,
// and IS THE APP BREAKING. Both come from `app_events` (migration 0020) via one
// SECURITY DEFINER call, `admin_funnel(interval)`.
//
// ── HOW THIS FILE IS WIRED IN ────────────────────────────────────────────────
//
// index.ts owns the gate. It runs requireAdmin() (401/403) and the per-admin
// rate limit BEFORE the route switch, then dispatches here — so this file does
// no auth of its own by design, exactly like handleUsage()/handleHealth(). The
// integrator adds ONE line to that switch:
//
//     case "funnel":
//       return await handleFunnel(req);
//
// ── WHAT THE NUMBERS MEAN (and what they do not) ─────────────────────────────
//
// A step counts DISTINCT DEVICES in the window, not events: one person who
// opens the app forty times is one device at `app_open`. It is NOT a cohort
// funnel — the device counted at `purchase_completed` is not required to have
// appeared at `app_open` inside the same window — so a long window and a short
// one can disagree slightly at the tail. `note` says so on every response, and
// the iOS screen renders it, because a funnel that quietly implies more rigour
// than it has is how people talk themselves into bad ad spend.
//
// `pct_of_previous` / `pct_of_first` are null (never 0) when the divisor is 0:
// "nobody got here" and "nobody converted" are different facts.
//
// Privacy: aggregates only. Not one row, id, e-mail or address leaves the
// database through this route — the RPC returns counts, and `app_events` has no
// SELECT policy for anyone, so there is no row stream to leak in the first place.

import { HttpError, json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

/** The windows the screen offers. Anything else is a 400, not a silent default. */
const WINDOWS: Readonly<Record<string, string>> = Object.freeze({
  "7d": "7 days",
  "30d": "30 days",
  "90d": "90 days",
});
const DEFAULT_WINDOW = "30d";

/**
 * Plain-words label per step, in the order the funnel runs. The server sends
 * them so the phone and the console can never disagree about what a step is
 * called, and so a step added to the RPC shows up as words on a shipped build
 * rather than as a raw slug.
 */
const STEP_LABELS: Readonly<Record<string, string>> = Object.freeze({
  app_open: "Opened the app",
  signup: "Signed up",
  home_created: "Added a home",
  capture_finished: "Finished a walkthrough",
  render_finished: "Tour rendered",
  tour_published: "Tour published",
  paywall_viewed: "Saw plans",
  purchase_completed: "Subscribed",
});

/** Title-case a slug we have no label for, so nothing renders as `foo_bar`. */
function prettyStep(name: string): string {
  return name.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

interface FunnelStep {
  name?: unknown;
  count?: unknown;
  pct_of_previous?: unknown;
  pct_of_first?: unknown;
}

/** A number the app can decode, or null. Postgres numerics arrive as strings. */
function num(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

/** A count is never null on the wire — "we don't know" is not a thing here. */
function count(v: unknown): number {
  return num(v) ?? 0;
}

export async function handleFunnel(req: Request): Promise<Response> {
  const requested = (new URL(req.url).searchParams.get("window") ?? DEFAULT_WINDOW).trim();
  const interval = WINDOWS[requested];
  if (!interval) {
    throw new HttpError(400, `window must be one of ${Object.keys(WINDOWS).join(", ")}`);
  }

  const { data, error } = await adminClient().rpc("admin_funnel", { p_window: interval });
  if (error) throw new HttpError(500, `Funnel lookup failed: ${error.message}`);

  const report = (data ?? {}) as Record<string, unknown>;
  const rawSteps = Array.isArray(report.steps) ? (report.steps as FunnelStep[]) : [];

  // Reshape rather than pass through: the phone decodes this with Codable, so
  // every key is always present, optionals are explicit nulls, and arrays are
  // never omitted (the same contract the rest of the admin console keeps).
  const steps = rawSteps.map((s) => {
    const name = typeof s.name === "string" ? s.name : "";
    return {
      name,
      label: STEP_LABELS[name] ?? prettyStep(name),
      count: count(s.count),
      pct_of_previous: num(s.pct_of_previous),
      pct_of_first: num(s.pct_of_first),
    };
  });

  const byDay = Array.isArray(report.by_day) ? (report.by_day as Record<string, unknown>[]) : [];

  return json({
    generated_at: report.generated_at ?? new Date().toISOString(),
    window: requested,
    from: report.from ?? null,
    to: report.to ?? null,
    steps,
    crashes: count(report.crashes),
    errors: count(report.errors),
    active_devices: count(report.active_devices),
    sessions: count(report.sessions),
    events: count(report.events),
    // ── The three purchase numbers, and why there are three ────────────────
    //
    // `steps[purchase_completed]` above is what the APP reported. POST /events
    // accepts the project anon key (half the funnel happens before anyone signs
    // in) and `device_id` is a UUID the client invents, so anyone who pulls the
    // anon key out of the shipped binary can add to that count. It is kept
    // because a shipped screen reads it and because it is still the right
    // number for "did the app get to the purchase call".
    //
    // `purchase_completed_attributed` is the subset that arrived on a real user
    // JWT — the server resolves user_id from the token and never from the body.
    //
    // `purchases_verified` is ground truth: rows in `apple_subscriptions`,
    // which only apply_apple_entitlement() writes, only from a JWS this server
    // verified against the pinned Apple root. Nothing a client sends can move
    // it. Sandbox (App Review, TestFlight) is reported apart, because a tester
    // is not a customer. THIS is the number to trust when deciding ad spend.
    purchases_verified: count(report.purchases_verified),
    purchases_verified_sandbox: count(report.purchases_verified_sandbox),
    purchase_completed_attributed: count(report.purchase_completed_attributed),
    by_day: byDay.map((d) => ({
      day: typeof d.day === "string" ? d.day : "",
      opens: count(d.opens),
      signups: count(d.signups),
      purchases: count(d.purchases),
      crashes: count(d.crashes),
    })),
    note:
      "Each step counts distinct devices in the window, not events. It is not a " +
      "cohort funnel: a device counted at a later step need not have appeared at " +
      "an earlier one inside the same window, so a long window and a short one " +
      "can disagree slightly at the end. A percentage is blank when the step " +
      "above it had nobody in it. The purchase STEP is client-reported and can " +
      "be inflated by anyone holding the app's anon key; purchases_verified is " +
      "counted from verified App Store subscriptions and cannot be.",
  });
}
