// deliver.ts — what happens to ONE claimed outbox row.
//
// Extracted from index.ts for the same reason me/logic.ts and leads/turnstile.ts
// are: this is the part whose behaviour has to be PROVEN (notify.test.ts), and
// index.ts calls Deno.serve at import time, which a test running --deny-net
// cannot load at all.
//
// Everything here is a pure decision plus an injectable fetch. No database, no
// environment beyond the provider modules' own secret checks, and — the whole
// point — NOTHING THAT THROWS. Every path returns an Outcome, because the
// caller is a loop over a batch and one row must never take the rest with it.
//
// THE THREE OUTCOMES, and what the database does with each:
//   sent     → notification_mark writes sent_at and the permanent notification_log row.
//   skipped  → a normal, final "we are not sending this": no provider secret, no
//              device, an address the provider rejects outright. NOT retried.
//   failed   → a transient: an unreachable host, a 5xx, a timeout.
//              notification_mark turns it back into `queued` with a widening
//              backoff while attempts remain, and only then leaves it failed.

import * as apns from "./apns.ts";
import * as email from "./email.ts";
import { absoluteLink, emailText, render } from "./copy.ts";

export interface OutboxRow {
  id: string;
  org_id: string | null;
  user_id: string;
  category: string;
  channel: "push" | "email";
  dedupe_key: string;
  payload: Record<string, unknown>;
  attempts: number;
}

export interface DeviceRow {
  user_id: string;
  device_token: string;
  environment: "sandbox" | "production";
}

export interface Outcome {
  state: "sent" | "skipped" | "failed";
  /** Goes into notification_outbox.last_error. Never a secret, never a token. */
  reason: string | null;
  /** The provider's own message id, recorded in notification_log. */
  providerId: string | null;
  /** Device tokens APNs said are gone — the caller disables these rows. */
  deadTokens: string[];
}

/**
 * Push one row to every live device the person has.
 *
 * ONE SUCCESS IS SUCCESS: an agent with an iPhone and an iPad has two tokens,
 * and a message that reached the phone is delivered even if the iPad's token
 * has rotted. The rotted one is still reported in `deadTokens` so it stops
 * being tried.
 */
export async function deliverPush(
  row: OutboxRow,
  devices: DeviceRow[],
  base: string,
  fetchImpl: typeof fetch = fetch,
): Promise<Outcome> {
  // THE INERT PATH. Not an error and not a retry: this row has nowhere to go
  // until somebody sets three secrets, and naming them in last_error is how
  // they find out. E-mail rows in the same batch are unaffected.
  if (!apns.configured()) {
    return { state: "skipped", reason: apns.missingReason(), providerId: null, deadTokens: [] };
  }
  if (devices.length === 0) {
    // The device was disabled or removed between enqueue and drain. A push with
    // no device is not a failure worth retrying five times.
    return {
      state: "skipped",
      reason: "no live device for this user",
      providerId: null,
      deadTokens: [],
    };
  }

  const message = render(row.category, row.payload);
  const link = absoluteLink(row.payload, base);
  const data = (row.payload.data && typeof row.payload.data === "object" &&
      !Array.isArray(row.payload.data)
    ? row.payload.data
    : {}) as Record<string, unknown>;

  const deadTokens: string[] = [];
  let lastReason: string | null = null;

  for (const device of devices) {
    const result = await apns.send({
      deviceToken: device.device_token,
      environment: device.environment === "sandbox" ? "sandbox" : "production",
      title: message.title,
      body: message.body,
      deepLink: link,
      category: row.category,
      data,
      collapseId: row.dedupe_key,
    }, fetchImpl);

    if (result.ok) {
      return { state: "sent", reason: null, providerId: result.id, deadTokens };
    }
    lastReason = result.reason;
    // 410 Unregistered / 400 BadDeviceToken: the app is gone from that device.
    // Retrying is how a queue fills with rows that can never succeed.
    if (result.dead) deadTokens.push(device.device_token);
  }

  // EVERY token this person has is gone. Retrying cannot help, so the row is
  // closed as skipped rather than left to burn its five attempts against
  // phones that no longer exist.
  if (deadTokens.length > 0 && deadTokens.length === devices.length) {
    return {
      state: "skipped",
      reason: `every device token for this user was rejected by APNs (${lastReason ?? "unregistered"})`,
      providerId: null,
      deadTokens,
    };
  }
  return {
    state: "failed",
    reason: lastReason ?? "apns send failed",
    providerId: null,
    deadTokens,
  };
}

/** E-mail one row. Same three outcomes, same never-throws contract. */
export async function deliverEmail(
  row: OutboxRow,
  address: string | null,
  base: string,
  fetchImpl: typeof fetch = fetch,
): Promise<Outcome> {
  if (!email.configured()) {
    return { state: "skipped", reason: email.missingReason(), providerId: null, deadTokens: [] };
  }
  if (!address) {
    return {
      state: "skipped",
      reason: "no email address on file for this user",
      providerId: null,
      deadTokens: [],
    };
  }

  const message = render(row.category, row.payload);
  const link = absoluteLink(row.payload, base);
  const result = await email.sendEmail({
    to: address,
    subject: message.title,
    text: emailText(message, link),
  }, fetchImpl);

  if (result.ok) {
    return { state: "sent", reason: null, providerId: result.id, deadTokens: [] };
  }
  // A hard rejection of THIS address is not something a retry fixes.
  if (result.dead) {
    return { state: "skipped", reason: result.reason, providerId: null, deadTokens: [] };
  }
  return { state: "failed", reason: result.reason, providerId: null, deadTokens: [] };
}
