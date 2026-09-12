// notify — the drain. The half of lifecycle messaging that talks to providers.
//
//   POST /notify?limit=50   service role -> { claimed, sent, skipped, failed, by_channel, … }
//   POST /notify/sweep      service role -> { reclaimed, expired, swept_at }
//
// Migration 0047 is the other half: producers (an AFTER trigger on `leads`,
// both publish paths, and notification_tick() on a 15-minute pg_cron schedule)
// write rows into `notification_outbox`. This function claims them and delivers
// them. Nothing in the app ever calls it — it is invoked by a scheduler with
// the service-role key, exactly like POST /me/sweep-deletions (DEPLOYMENT.md §9).
//
// ── THE RULE THIS FILE IS BUILT AROUND ───────────────────────────────────────
//
// IT MUST NEVER 500, NEVER CRASH-LOOP, AND NEVER LET ONE CHANNEL BLOCK THE
// OTHER. A scheduler calls this every few minutes forever; a drain that throws
// on a missing secret is a permanent alarm that teaches everyone to ignore
// alarms, and a batch that dies half-way leaves its rows stuck in `sending`
// until the sweep rescues them.
//
// So:
//   • No APNs secrets? Every PUSH row in the batch is marked `skipped` with the
//     names of the missing variables, and the e-mail rows still go out.
//   • No e-mail secrets? The mirror image.
//   • Neither? Every row is marked `skipped` and the response is a 200 that
//     says so. THIS IS THE SHIPPING STATE: 0047 and this function go live inert
//     and turn on when the owner adds keys. Nothing is lost in the meantime —
//     rows sit in the outbox until notification_sweep() expires them at 72
//     hours, so a key added the same day still delivers the backlog.
//   • A single row that fails for any other reason is marked and the loop
//     continues. notification_mark() decides whether that is a retry (it is,
//     up to five attempts, with a widening backoff) or the end.
//
// ── WHERE THE WORDS ARE ──────────────────────────────────────────────────────
//
// Not here, and not in the database. The outbox row carries the FACTS; copy.ts
// renders them into a title and a body at send time. One wording serves both
// channels: the push alert's title IS the e-mail's subject.
//
// Errors carry { error, code } (see _shared/http.ts).

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, pathSegments, respondError } from "../_shared/http.ts";
import { adminClient, isServiceRole } from "../_shared/supabase.ts";
import * as apns from "./apns.ts";
import * as email from "./email.ts";
import { deliverEmail, deliverPush, type DeviceRow, type OutboxRow } from "./deliver.ts";

/** Same default as functions/me: the routed domain, never rendprop.app. */
const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");

const DEFAULT_BATCH = 50;
const MAX_BATCH = 200;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    // Service role ONLY. There is no tenant-facing behaviour here at all: an
    // app that could drain the outbox could read every other workspace's
    // messages out of the claimed batch.
    if (!isServiceRole(req)) throw new HttpError(403, "Service role required", "forbidden");
    if (req.method !== "POST") {
      throw new HttpError(405, "Only POST /notify and POST /notify/sweep are supported");
    }

    const seg = pathSegments(req, "notify");
    if (seg[0] === "sweep") return await handleSweep();
    if (seg.length > 0) throw new HttpError(404, "Unknown route — POST /notify or POST /notify/sweep");

    const raw = Number(new URL(req.url).searchParams.get("limit") ?? DEFAULT_BATCH);
    const limit = Number.isFinite(raw) ? Math.min(MAX_BATCH, Math.max(1, Math.round(raw))) : DEFAULT_BATCH;
    return await handleDrain(limit);
  } catch (err) {
    return respondError(err);
  }
});

// ── POST /notify/sweep ────────────────────────────────────────────────────────
//
// notification_tick() already calls notification_sweep() on its own 15-minute
// schedule, so this exists for the deployment where pg_cron is NOT enabled (the
// manual gate 0047 §12 and DEPLOYMENT.md describe) and an external scheduler is
// driving both halves over HTTP instead.

async function handleSweep(): Promise<Response> {
  const { data, error } = await adminClient().rpc("notification_sweep");
  if (error) {
    // Still not a 500: the caller is a cron job, and an unreachable database is
    // a transient it should retry on its own schedule.
    console.error("notification_sweep failed:", error.message);
    return json({ ok: false, reason: "sweep failed", reclaimed: 0, expired: 0 }, 200);
  }
  return json({ ok: true, ...(data as Record<string, unknown>) });
}

// ── POST /notify ──────────────────────────────────────────────────────────────

async function handleDrain(limit: number): Promise<Response> {
  const admin = adminClient();

  const { data: claimed, error: claimErr } = await admin.rpc("notification_claim_batch", {
    p_limit: limit,
  });
  if (claimErr) {
    console.error("notification_claim_batch failed:", claimErr.message);
    return json({ ok: false, reason: "claim failed", claimed: 0, sent: 0, skipped: 0, failed: 0 }, 200);
  }

  const rows = ((claimed ?? []) as OutboxRow[]).map((r) => ({
    ...r,
    payload: (r.payload && typeof r.payload === "object" ? r.payload : {}) as Record<string, unknown>,
  }));
  if (rows.length === 0) {
    return json({
      ok: true,
      claimed: 0,
      sent: 0,
      skipped: 0,
      failed: 0,
      by_channel: { push: 0, email: 0 },
      push_configured: apns.configured(),
      email_configured: email.configured(),
    });
  }

  // Two lookups for the whole batch rather than two per row.
  const pushUsers = [...new Set(rows.filter((r) => r.channel === "push").map((r) => r.user_id))];
  const mailUsers = [...new Set(rows.filter((r) => r.channel === "email").map((r) => r.user_id))];

  const devicesByUser = new Map<string, DeviceRow[]>();
  if (pushUsers.length > 0 && apns.configured()) {
    const { data, error } = await admin
      .from("notification_devices")
      .select("user_id, device_token, environment")
      .in("user_id", pushUsers)
      .is("disabled_at", null);
    if (error) console.error("device lookup failed:", error.message);
    for (const d of (data ?? []) as DeviceRow[]) {
      const list = devicesByUser.get(d.user_id) ?? [];
      list.push(d);
      devicesByUser.set(d.user_id, list);
    }
  }

  const emailByUser = new Map<string, string>();
  if (mailUsers.length > 0 && email.configured()) {
    const { data, error } = await admin.from("profiles").select("id, email").in("id", mailUsers);
    if (error) console.error("profile lookup failed:", error.message);
    for (const p of (data ?? []) as Array<{ id: string; email: string | null }>) {
      const address = (p.email ?? "").trim();
      if (address) emailByUser.set(p.id, address);
    }
  }

  let sent = 0;
  let skipped = 0;
  let failed = 0;
  const byChannel = { push: 0, email: 0 };
  const disabledTokens: string[] = [];

  for (const row of rows) {
    try {
      const outcome = row.channel === "push"
        ? await deliverPush(row, devicesByUser.get(row.user_id) ?? [], TOUR_BASE)
        : await deliverEmail(row, emailByUser.get(row.user_id) ?? null, TOUR_BASE);
      disabledTokens.push(...outcome.deadTokens);

      await mark(row.id, outcome.state, outcome.reason, outcome.providerId);
      if (outcome.state === "sent") {
        sent++;
        byChannel[row.channel]++;
      } else if (outcome.state === "skipped") skipped++;
      else failed++;
    } catch (e) {
      // Belt and braces: nothing above is supposed to throw, and if something
      // does, this row is marked and the batch keeps going. A thrown drain
      // would leave every remaining row stuck in `sending` until the sweep.
      const reason = e instanceof Error ? e.message : String(e);
      console.error(`notify row ${row.id} threw:`, reason);
      failed++;
      await mark(row.id, "failed", `unexpected: ${reason}`.slice(0, 400), null).catch(() => {});
    }
  }

  // Retire the tokens APNs told us are gone. Done after the loop so one
  // person's dead phone cannot slow the batch down, and never fatally.
  for (const token of [...new Set(disabledTokens)]) {
    const { error } = await admin.rpc("notification_disable_device", {
      p_token: token,
      p_reason: "rejected by APNs as unregistered",
    });
    if (error) console.error("notification_disable_device failed:", error.message);
  }

  return json({
    ok: true,
    claimed: rows.length,
    sent,
    skipped,
    failed,
    by_channel: byChannel,
    devices_disabled: new Set(disabledTokens).size,
    push_configured: apns.configured(),
    email_configured: email.configured(),
  });
}

/**
 * Close the row. notification_mark() owns the retry policy — `failed` becomes
 * `queued` with a widening backoff while attempts remain — so this just reports
 * what happened and never decides when to try again.
 */
async function mark(
  id: string,
  state: "sent" | "skipped" | "failed",
  reason: string | null,
  providerId: string | null,
): Promise<void> {
  const { error } = await adminClient().rpc("notification_mark", {
    p_id: id,
    p_state: state,
    p_error: reason,
    p_provider_id: providerId,
  });
  // A row that could not be marked is left in `sending` and recovered by
  // notification_sweep() after 10 minutes. Logged, never thrown.
  if (error) console.error(`notification_mark(${id}, ${state}) failed:`, error.message);
}
