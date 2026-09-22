// apns.ts — Apple Push Notification service, token-based (p8) auth.
//
// SECRETS (all three, or this ships inert):
//   APNS_KEY_P8    the .p8 key file's contents (PEM, real newlines or \n-escaped)
//   APNS_KEY_ID    the key id from the Apple Developer key page
//   APNS_TEAM_ID   the 10-character team id
//
// With any of them missing, `configured()` is false, the drain marks every push
// row `skipped` with a reason and carries on with e-mail. Nothing throws,
// nothing retries, nothing 500s — turning push on is adding three secrets, not
// deploying code.
//
// THE PARTS THAT ARE EASY TO GET WRONG, and what this file does about each:
//
//   • TOKEN LIFETIME. Apple rejects a provider token older than 1 hour
//     (ExpiredProviderToken) AND rejects generating them more often than once
//     every 20 minutes (TooManyProviderTokenUpdates). So the JWT is cached for
//     50 minutes and reused across every send in that window.
//   • HOST. A sandbox (development) token sent to api.push.apple.com is a 400
//     BadDeviceToken and the notification is silently lost. The host comes from
//     the DEVICE ROW's `environment` column, never from a global setting.
//   • HTTP/2. APNs is HTTP/2-only. Deno's fetch negotiates h2 over TLS, so this
//     is plain fetch; no library, no connection pool of our own.
//   • DEAD TOKENS. 410 Unregistered and 400 BadDeviceToken mean the app is gone
//     from that device. Retrying is how a queue fills with rows that can never
//     succeed, so the caller disables the device row instead (the `dead` flag
//     on the result).
//
// This file never reads or writes the database and never logs a token or a key.

const TOPIC = "com.rendprop.app";
/** Refreshed well inside Apple's 1-hour ceiling and outside its 20-minute floor. */
const TOKEN_TTL_MS = 50 * 60 * 1000;

export interface ApnsMessage {
  deviceToken: string;
  environment: "sandbox" | "production";
  title: string;
  body: string;
  /** Goes in the custom payload so the app can route the tap. */
  deepLink: string | null;
  category: string;
  /** Arbitrary facts the app may use; kept small. */
  data: Record<string, unknown>;
  /** APNs collapses same-id notifications — the outbox dedupe key, truncated. */
  collapseId?: string;
}

export interface ApnsResult {
  ok: boolean;
  /** apns-id — the provider's own message id, recorded in notification_log. */
  id: string | null;
  status: number | null;
  /** Apple's machine-readable reason, e.g. "Unregistered", "BadDeviceToken". */
  reason: string | null;
  /** True when this TOKEN is gone for good and must be disabled, not retried. */
  dead: boolean;
}

// Read at CALL time, not at module load: a secret added to the project takes
// effect on the next drain instead of the next cold start, and the tests can
// exercise both the configured and the unconfigured path in one process.
const env = (name: string): string | undefined => {
  const v = Deno.env.get(name);
  return v && v.trim() ? v : undefined;
};

/** True when all three secrets are present. */
export function configured(): boolean {
  return Boolean(env("APNS_KEY_P8") && env("APNS_KEY_ID") && env("APNS_TEAM_ID"));
}

/** The one sentence the drain writes into `last_error` when it is not. */
export function missingReason(): string {
  const missing = ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID"].filter((n) => !env(n));
  return `push is not configured: set ${missing.join(", ")}`;
}

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Same shape as _shared/apple.ts: a .p8 pasted into an env var, either way. */
function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  const buf = new ArrayBuffer(raw.length);
  const out = new Uint8Array(buf);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return buf;
}

let cachedToken: { jwt: string; mintedAt: number; keyId: string } | null = null;

/** ES256 provider token, cached for 50 minutes (see the header). */
async function providerToken(): Promise<string> {
  const keyId = env("APNS_KEY_ID")!;
  const teamId = env("APNS_TEAM_ID")!;
  const now = Date.now();
  // The key id is part of the cache identity: a rotated key must not keep
  // signing with the retired one until the TTL happens to lapse.
  if (cachedToken && cachedToken.keyId === keyId && now - cachedToken.mintedAt < TOKEN_TTL_MS) {
    return cachedToken.jwt;
  }

  const iat = Math.floor(now / 1000);
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const payload = b64url(enc.encode(JSON.stringify({ iss: teamId, iat })));
  const signingInput = `${header}.${payload}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(env("APNS_KEY_P8")!),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(signingInput)),
  );
  const jwt = `${signingInput}.${b64url(sig)}`;
  cachedToken = { jwt, mintedAt: now, keyId };
  return jwt;
}

/** Drop the cached token — used when Apple says it is expired or invalid. */
export function resetProviderToken(): void {
  cachedToken = null;
}

/** The reasons that mean "this device token is gone", not "try again later". */
const DEAD_REASONS = new Set(["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"]);

export function isDead(status: number, reason: string | null): boolean {
  // 410 is Unregistered by definition; 400 BadDeviceToken is the same fact
  // arriving with a different status because the token never parsed.
  if (status === 410) return true;
  return status === 400 && reason !== null && DEAD_REASONS.has(reason);
}

function hostFor(environment: string): string {
  return environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
}

/**
 * Send one notification. NEVER throws: a transport failure is reported as
 * `{ ok: false, reason }` so one unreachable host cannot take the drain down.
 *
 * `fetchImpl` is injectable so the tests can exercise the 410 path without a
 * network (the edge regression runs --deny-net).
 */
export async function send(
  message: ApnsMessage,
  fetchImpl: typeof fetch = fetch,
): Promise<ApnsResult> {
  if (!configured()) {
    return { ok: false, id: null, status: null, reason: "not_configured", dead: false };
  }

  let token: string;
  try {
    token = await providerToken();
  } catch (e) {
    // A malformed APNS_KEY_P8 is a configuration error, not a per-row failure.
    // The message, not the key, is what gets logged.
    return {
      ok: false,
      id: null,
      status: null,
      reason: `provider token could not be signed: ${e instanceof Error ? e.message : String(e)}`,
      dead: false,
    };
  }

  const aps = {
    aps: {
      alert: { title: message.title, body: message.body },
      sound: "default",
      "interruption-level": "active",
    },
    category: message.category,
    deep_link: message.deepLink,
    data: message.data,
  };

  const headers: Record<string, string> = {
    authorization: `bearer ${token}`,
    "apns-topic": TOPIC,
    "apns-push-type": "alert",
    "apns-priority": "10",
    // An alert that could not be delivered within an hour is not news any more —
    // the same judgement notification_sweep() makes with its 72-hour expiry.
    "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
    "content-type": "application/json",
  };
  if (message.collapseId) headers["apns-collapse-id"] = message.collapseId.slice(0, 64);

  let res: Response;
  try {
    res = await fetchImpl(
      `https://${hostFor(message.environment)}/3/device/${message.deviceToken}`,
      { method: "POST", headers, body: JSON.stringify(aps) },
    );
  } catch (e) {
    return {
      ok: false,
      id: null,
      status: null,
      reason: `apns unreachable: ${e instanceof Error ? e.message : String(e)}`,
      dead: false,
    };
  }

  const id = res.headers.get("apns-id");
  if (res.status === 200) {
    return { ok: true, id, status: 200, reason: null, dead: false };
  }

  let reason: string | null = null;
  try {
    const text = await res.text();
    if (text) reason = (JSON.parse(text) as { reason?: string }).reason ?? text.slice(0, 200);
  } catch {
    reason = null;
  }

  // A token Apple says is expired or invalid: mint a fresh one for the next row
  // rather than failing the whole batch on a clock or a key rotation.
  if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") resetProviderToken();

  return {
    ok: false,
    id,
    status: res.status,
    reason: reason ?? `apns ${res.status}`,
    dead: isDead(res.status, reason),
  };
}
