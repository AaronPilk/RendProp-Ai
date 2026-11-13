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
  /** Nullable since 0053: a team invitee has no account yet. */
  user_id: string | null;
  /** Set only on rows addressed to someone with no profile to look up. */
  to_email?: string | null;
  client_delivery_id?: string | null;
  client_verification_id?: string | null;
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

/** The paired admin email is the only actionable destination for an ops alert. */
export type OperationalEmailState = "sent" | "queued" | "sending" | "failed" | "skipped" | "expired" | "missing" | "lookup_unavailable";

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
  authorizeDevice?: (device:DeviceRow)=>Promise<boolean>,
  operationalEmailState: OperationalEmailState = "lookup_unavailable",
): Promise<Outcome> {
  // Operational findings live in server configuration and provider accounts.
  // The native app has no review destination for them; the paired admin email
  // carries the actionable details. Do not send a generic "review it" push
  // that opens Home with no context.
  if (row.category === "ops_alert") {
    return {
      state: operationalEmailState === "sent" ? "skipped" : "failed",
      reason: operationalEmailState === "sent"
        ? "Operational alert has no mobile review destination; paired admin email was sent."
        : `Operational alert has no mobile review destination; paired admin email is ${operationalEmailState}.`,
      providerId: null,
      deadTokens: [],
    };
  }
  // THE INERT PATH. Not an error and not a retry: this row has nowhere to go
  // until somebody sets three secrets, and naming them in last_error is how
  // they find out. E-mail rows in the same batch are unaffected.
  if (!apns.configured()) {
    return { state: "skipped", reason: apns.missingReason(), providerId: null, deadTokens: [] };
  }
  // The drain groups devices by the row's own user_id; a caller that hands this
  // row somebody else's devices gets them dropped here rather than pushed to.
  const ownDevices = row.user_id ? devices.filter((device) => device.user_id === row.user_id) : [];
  if (ownDevices.length === 0 || !row.user_id) {
    // The device was disabled or removed between enqueue and drain. A push with
    // no device is not a failure worth retrying five times.
    return {
      state: "skipped",
      reason: NO_LIVE_DEVICE,
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

  let authorizedDevices=0;
  let authorizationDenied = false;
  for (const device of ownDevices) {
    if(authorizeDevice&&!await authorizeDevice(device)){authorizationDenied = true;continue;}
    authorizedDevices++;
    const result = await apns.send({
      deviceToken: device.device_token,
      environment: device.environment === "sandbox" ? "sandbox" : "production",
      title: message.title,
      body: message.body,
      deepLink: link,
      category: row.category,
      recipientUserId: row.user_id,
      data: apns.pushRouteData(data),
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
  if(authorizationDenied||authorizedDevices===0)return {state:"skipped",reason:"the current account or device enrollment changed",providerId:null,deadTokens};
  if (deadTokens.length > 0 && deadTokens.length === authorizedDevices) {
    return {
      state: "skipped",
      reason: `${ALL_TOKENS_REJECTED} (${lastReason ?? "unregistered"})`,
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

/** The two closed-push reasons that mean "this person's phone can no longer be
 * reached", as opposed to "this message must not be sent". */
const NO_LIVE_DEVICE = "no live device for this user";
const ALL_TOKENS_REJECTED = "every device token for this user was rejected by APNs";

/**
 * notification_enqueue() picks ONE channel when the row is written: push when
 * the person has any enabled device, e-mail otherwise. A device that died after
 * that choice (app deleted, token rotated) closes the push as `skipped`, and
 * until now nothing else was ever sent: the first inquiry after an agent
 * reinstalled the app reached nobody.
 *
 * True only for those undeliverable-phone outcomes, and only for the messages a
 * person acts on. An access or enrollment refusal ("account access changed",
 * "device enrollment changed") is a privacy decision and never falls back.
 */
export function pushNeedsEmailFallback(row: OutboxRow, outcome: Outcome): boolean {
  if (row.channel !== "push" || outcome.state !== "skipped" || !row.user_id || !outcome.reason) return false;
  if (!["lead_received", "render_ready", "upload_stuck"].includes(row.category)) return false;
  return outcome.reason === NO_LIVE_DEVICE || outcome.reason.startsWith(ALL_TOKENS_REJECTED);
}

/** The e-mail twin of an undeliverable push. Its key is derived from the push
 * row's, so a replayed drain cannot queue the same fallback twice. */
export function emailFallbackRow(row: OutboxRow): Record<string, unknown> {
  return {
    org_id: row.org_id,
    user_id: row.user_id,
    category: row.category,
    channel: "email",
    dedupe_key: `${row.dedupe_key}:email-fallback`,
    payload: row.payload,
  };
}

/** E-mail one row. Same three outcomes, same never-throws contract. */
export async function deliverEmail(
  row: OutboxRow,
  address: string | null,
  base: string,
  fetchImpl: typeof fetch = fetch,
  clientMessage?: email.EmailMessage,
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

  if(["client_lead_received", "client_recipient_verification"].includes(row.category) && (!clientMessage || clientMessage.to !== address)) {
    return {state:"skipped",reason:"Client forwarding was not authorized.",providerId:null,deadTokens:[]};
  }

  const message = render(row.category, row.payload);
  const link = absoluteLink(row.payload, base);
  const result = await email.sendEmail(clientMessage ?? {
    to: address,
    subject: message.title,
    text: emailText(message, link, row.category),
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
