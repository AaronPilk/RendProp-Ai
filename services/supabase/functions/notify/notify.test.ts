// notify.test.ts — the two behaviours the drain's promise rests on.
//
//   deno test --allow-env --allow-read notify/notify.test.ts
//
// 1. THE PROVIDER-ABSENT PATH. This function ships INERT: 0047 and the drain go
//    live with no APNs key and no e-mail key, and the owner turns messaging on
//    by adding secrets. That is only true if an absent secret produces a
//    `skipped` row with a reason and lets the OTHER channel through — not a
//    throw, not a 500, not a retry loop that burns five attempts per row.
//
// 2. THE APNs 410 PATH. Apple answers 410 Unregistered (and 400 BadDeviceToken)
//    for a device the app has been deleted from. Those tokens must be DISABLED,
//    not retried: a queue that keeps pushing at dead phones never empties, and
//    every retry is five more attempts of latency ahead of the lead that
//    matters.
//
// Both run offline. The APNs key is generated here with WebCrypto and PEM-wrapped
// the way a real .p8 arrives, and every provider call goes through an injected
// `fetch` — the edge regression runs --deny-net, so a test that reached the
// network would fail rather than pass quietly.

import { assert, assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import * as apns from "./apns.ts";
import * as email from "./email.ts";
import { deliverEmail, deliverPush, type DeviceRow, type OutboxRow } from "./deliver.ts";
import { absoluteLink, emailText, render } from "./copy.ts";

const BASE = "https://rendprop.com";

const APNS_VARS = ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID"] as const;
const EMAIL_VARS = ["RESEND_API_KEY", "NOTIFY_FROM_EMAIL"] as const;

function clearSecrets() {
  for (const name of [...APNS_VARS, ...EMAIL_VARS]) Deno.env.delete(name);
  apns.resetProviderToken();
}

/** A real ES256 private key in the PEM shape Apple's .p8 download arrives in. */
async function makeP8(): Promise<string> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let raw = "";
  for (const b of pkcs8) raw += String.fromCharCode(b);
  const b64 = btoa(raw).replace(/(.{64})/g, "$1\n");
  return `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;
}

async function withApnsSecrets(): Promise<void> {
  Deno.env.set("APNS_KEY_P8", await makeP8());
  Deno.env.set("APNS_KEY_ID", "TESTKEYID1");
  Deno.env.set("APNS_TEAM_ID", "TEAMID1234");
  apns.resetProviderToken();
}

function row(overrides: Partial<OutboxRow> = {}): OutboxRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    org_id: "22222222-2222-2222-2222-222222222222",
    user_id: "33333333-3333-3333-3333-333333333333",
    category: "lead_received",
    channel: "push",
    dedupe_key: "lead_received:abc:def",
    payload: {
      deep_link: "/f/abc123xyz9",
      data: {
        lead_id: "44444444-4444-4444-4444-444444444444",
        lead_name: "Nina Patel",
        has_phone: true,
        has_email: false,
        listing_address: "412 Marina Blvd",
      },
    },
    attempts: 1,
    ...overrides,
  };
}

const device: DeviceRow = {
  user_id: "33333333-3333-3333-3333-333333333333",
  device_token: "aabbccdd00112233445566778899aabb",
  environment: "production",
};

/** A fetch that must never be called. */
const forbiddenFetch: typeof fetch = () => {
  throw new Error("the provider was called even though no secret is set");
};

/** An APNs response with the given status and (optional) reason body. */
function apnsResponse(status: number, reason?: string): Response {
  return new Response(reason ? JSON.stringify({ reason }) : "", {
    status,
    headers: { "apns-id": "APNS-MSG-1" },
  });
}

// ── 1. Provider absent ───────────────────────────────────────────────────────

Deno.test("push with no APNs secrets is skipped, names every missing variable, and never calls a provider", async () => {
  clearSecrets();
  assertEquals(apns.configured(), false);

  const outcome = await deliverPush(row(), [device], BASE, forbiddenFetch);

  assertEquals(outcome.state, "skipped");
  assertEquals(outcome.providerId, null);
  assertEquals(outcome.deadTokens, []);
  assertStringIncludes(outcome.reason ?? "", "push is not configured");
  for (const name of APNS_VARS) assertStringIncludes(outcome.reason ?? "", name);
});

Deno.test("a PARTIALLY configured APNs still ships inert and names only what is missing", async () => {
  clearSecrets();
  Deno.env.set("APNS_KEY_ID", "TESTKEYID1");

  const outcome = await deliverPush(row(), [device], BASE, forbiddenFetch);

  assertEquals(outcome.state, "skipped");
  assertStringIncludes(outcome.reason ?? "", "APNS_KEY_P8");
  assertStringIncludes(outcome.reason ?? "", "APNS_TEAM_ID");
  assert(!(outcome.reason ?? "").includes("APNS_KEY_ID"), "a secret that IS set must not be reported missing");
  clearSecrets();
});

Deno.test("email with no provider secrets is skipped, names them, and never calls a provider", async () => {
  clearSecrets();
  assertEquals(email.configured(), false);

  const outcome = await deliverEmail(row({ channel: "email" }), "agent@example.com", BASE, forbiddenFetch);

  assertEquals(outcome.state, "skipped");
  assertEquals(outcome.providerId, null);
  assertStringIncludes(outcome.reason ?? "", "email is not configured");
  for (const name of EMAIL_VARS) assertStringIncludes(outcome.reason ?? "", name);
});

Deno.test("a missing secret is SKIPPED, never FAILED — a skipped row is not retried", async () => {
  clearSecrets();
  const push = await deliverPush(row(), [device], BASE, forbiddenFetch);
  const mail = await deliverEmail(row({ channel: "email" }), "a@b.co", BASE, forbiddenFetch);
  // `failed` would send the row back to `queued` with a backoff (0047's
  // notification_mark) and burn five attempts against a secret nobody has set.
  assertEquals([push.state, mail.state], ["skipped", "skipped"]);
});

Deno.test("one channel's missing secret does not block the other", async () => {
  clearSecrets();
  Deno.env.set("RESEND_API_KEY", "re_test_key");
  Deno.env.set("NOTIFY_FROM_EMAIL", "Rendprop <hello@rendprop.test>");

  let sentBody: Record<string, unknown> = {};
  const fakeResend: typeof fetch = (_url, init) => {
    sentBody = JSON.parse(String((init as RequestInit).body));
    return Promise.resolve(new Response(JSON.stringify({ id: "resend-1" }), { status: 200 }));
  };

  // APNs is still unset…
  const push = await deliverPush(row(), [device], BASE, forbiddenFetch);
  assertEquals(push.state, "skipped");
  // …and the e-mail row in the same batch goes out anyway.
  const mail = await deliverEmail(row({ channel: "email" }), "agent@example.com", BASE, fakeResend);
  assertEquals(mail.state, "sent");
  assertEquals(mail.providerId, "resend-1");
  assertEquals(sentBody.subject, "Nina Patel asked about 412 Marina Blvd");
  assertStringIncludes(String(sentBody.text), "https://rendprop.com/f/abc123xyz9");

  clearSecrets();
});

Deno.test("sendEmail with no provider configured resolves rather than throwing", async () => {
  clearSecrets();
  const result = await email.sendEmail({ to: "a@b.co", subject: "s", text: "t" }, forbiddenFetch);
  assertEquals(result.ok, false);
  assertEquals(result.dead, false);
  assertStringIncludes(result.reason ?? "", "RESEND_API_KEY");
});

Deno.test("apns.send with no secrets resolves rather than throwing", async () => {
  clearSecrets();
  const result = await apns.send({
    deviceToken: device.device_token,
    environment: "production",
    title: "t",
    body: "b",
    deepLink: null,
    category: "render_ready",
    data: {},
  }, forbiddenFetch);
  assertEquals(result.ok, false);
  assertEquals(result.reason, "not_configured");
  assertEquals(result.dead, false);
});

// ── 2. APNs 410 / BadDeviceToken ─────────────────────────────────────────────

Deno.test("isDead classifies exactly the tokens that are gone for good", () => {
  assertEquals(apns.isDead(410, "Unregistered"), true);
  assertEquals(apns.isDead(410, null), true, "410 is Unregistered by definition");
  assertEquals(apns.isDead(400, "BadDeviceToken"), true);
  assertEquals(apns.isDead(400, "DeviceTokenNotForTopic"), true);
  // Transients: these MUST stay retryable or a provider blip loses the message.
  assertEquals(apns.isDead(429, "TooManyRequests"), false);
  assertEquals(apns.isDead(500, "InternalServerError"), false);
  assertEquals(apns.isDead(503, "ServiceUnavailable"), false);
  assertEquals(apns.isDead(400, "PayloadTooLarge"), false);
  assertEquals(apns.isDead(403, "ExpiredProviderToken"), false);
});

Deno.test("a 410 Unregistered marks the token dead and does not report success", async () => {
  clearSecrets();
  await withApnsSecrets();

  let calledHost = "";
  const fake410: typeof fetch = (url) => {
    calledHost = new URL(String(url)).host;
    return Promise.resolve(apnsResponse(410, "Unregistered"));
  };

  const result = await apns.send({
    deviceToken: device.device_token,
    environment: "production",
    title: "t",
    body: "b",
    deepLink: null,
    category: "lead_received",
    data: {},
  }, fake410);

  assertEquals(result.ok, false);
  assertEquals(result.status, 410);
  assertEquals(result.reason, "Unregistered");
  assertEquals(result.dead, true);
  assertEquals(calledHost, "api.push.apple.com");
  clearSecrets();
});

Deno.test("a 410 on the only device SKIPS the row and hands the token back to be disabled", async () => {
  clearSecrets();
  await withApnsSecrets();
  const fake410: typeof fetch = () => Promise.resolve(apnsResponse(410, "Unregistered"));

  const outcome = await deliverPush(row(), [device], BASE, fake410);

  // Skipped, NOT failed: five retries against a phone the app was deleted from
  // is exactly the crash-loop this drain must not have.
  assertEquals(outcome.state, "skipped");
  assertEquals(outcome.deadTokens, [device.device_token]);
  assertStringIncludes(outcome.reason ?? "", "rejected by APNs");
  clearSecrets();
});

Deno.test("a dead iPad does not lose the message when the iPhone takes it", async () => {
  clearSecrets();
  await withApnsSecrets();
  const ipad: DeviceRow = { ...device, device_token: "deadbeef00000000" };
  const fake: typeof fetch = (url) =>
    Promise.resolve(
      String(url).endsWith(ipad.device_token)
        ? apnsResponse(410, "Unregistered")
        : apnsResponse(200),
    );

  const outcome = await deliverPush(row(), [ipad, device], BASE, fake);

  assertEquals(outcome.state, "sent");
  assertEquals(outcome.providerId, "APNS-MSG-1");
  // Still retired, even though the row succeeded on the other device.
  assertEquals(outcome.deadTokens, [ipad.device_token]);
  clearSecrets();
});

Deno.test("a 503 is a FAILED (retryable), never a disabled device", async () => {
  clearSecrets();
  await withApnsSecrets();
  const fake: typeof fetch = () => Promise.resolve(apnsResponse(503, "ServiceUnavailable"));

  const outcome = await deliverPush(row(), [device], BASE, fake);

  assertEquals(outcome.state, "failed");
  assertEquals(outcome.deadTokens, []);
  assertStringIncludes(outcome.reason ?? "", "ServiceUnavailable");
  clearSecrets();
});

Deno.test("a sandbox device is sent to the sandbox host", async () => {
  clearSecrets();
  await withApnsSecrets();
  let host = "";
  const fake: typeof fetch = (url) => {
    host = new URL(String(url)).host;
    return Promise.resolve(apnsResponse(200));
  };

  await deliverPush(row(), [{ ...device, environment: "sandbox" }], BASE, fake);

  // Sending a development token to the production host is a silent 400, which
  // is the worst kind of bug: nothing arrives and nothing complains.
  assertEquals(host, "api.sandbox.push.apple.com");
  clearSecrets();
});

Deno.test("an unreachable APNs is reported, not thrown", async () => {
  clearSecrets();
  await withApnsSecrets();
  const fake: typeof fetch = () => Promise.reject(new Error("connection reset"));

  const outcome = await deliverPush(row(), [device], BASE, fake);

  assertEquals(outcome.state, "failed");
  assertStringIncludes(outcome.reason ?? "", "apns unreachable");
  clearSecrets();
});

Deno.test("the push payload carries the alert, the category and the deep link", async () => {
  clearSecrets();
  await withApnsSecrets();
  let body: Record<string, unknown> = {};
  let headers: Record<string, string> = {};
  const fake: typeof fetch = (_url, init) => {
    const req = init as RequestInit;
    body = JSON.parse(String(req.body));
    headers = req.headers as Record<string, string>;
    return Promise.resolve(apnsResponse(200));
  };

  await deliverPush(row(), [device], BASE, fake);

  const aps = body.aps as { alert: { title: string; body: string } };
  assertEquals(aps.alert.title, "Nina Patel asked about 412 Marina Blvd");
  assertEquals(body.category, "lead_received");
  assertEquals(body.deep_link, "https://rendprop.com/f/abc123xyz9");
  assertEquals(headers["apns-topic"], "com.rendprop.app");
  assertEquals(headers["apns-push-type"], "alert");
  clearSecrets();
});

// ── 3. The copy, and the link ────────────────────────────────────────────────

Deno.test("the lead message carries the lead's name AND the listing", () => {
  const m = render("lead_received", row().payload);
  assertEquals(m.title, "Nina Patel asked about 412 Marina Blvd");
  assertEquals(m.body, "They left a phone number. The details are on your Leads screen.");
});

Deno.test("the lead message degrades when the buyer left no name and the listing has no address", () => {
  const m = render("lead_received", { data: { has_email: true } });
  assertEquals(m.title, "Someone asked about your tour");
  assertEquals(m.body, "They left an email address. The details are on your Leads screen.");
});

Deno.test("all six categories render, and none of them shouts", () => {
  const categories = [
    "lead_received",
    "render_ready",
    "upload_stuck",
    "free_week_ending",
    "allowance_low",
    "first_tour_nudge",
  ];
  for (const c of categories) {
    const m = render(c, { data: { hours_left: 9, feature: "renders", used: 7, cap: 8, left: 1 } });
    assert(m.title.length > 0 && m.body.length > 0, `${c} rendered nothing`);
    assert(!m.title.includes("!") && !m.body.includes("!"), `${c} uses an exclamation mark`);
    assert(
      !/don'?t miss|act now|hurry|last chance/i.test(`${m.title} ${m.body}`),
      `${c} uses urgency copy`,
    );
    assert(!/\$\d/.test(`${m.title} ${m.body}`), `${c} quotes a price`);
  }
});

Deno.test("free_week_ending says when, coarsely", () => {
  assertEquals(render("free_week_ending", { data: { hours_left: 1 } }).title, "Your free week ends within the hour");
  assertEquals(render("free_week_ending", { data: { hours_left: 9 } }).title, "Your free week ends in 9 hours");
  assertEquals(render("free_week_ending", { data: { hours_left: 40 } }).title, "Your free week ends tomorrow");
  assertEquals(render("free_week_ending", {}).title, "Your free week ends soon");
});

Deno.test("allowance_low names the meter in the customer's words", () => {
  assertEquals(
    render("allowance_low", { data: { feature: "photo_edits", used: 48, cap: 60, left: 12 } }).title,
    "48 of 60 photo edits used this cycle",
  );
  assertEquals(
    render("allowance_low", { data: { feature: "renders", used: 8, cap: 8, left: 0 } }).body,
    "The allowance resets at the start of your next cycle. Tours you have already published are not affected.",
  );
});

Deno.test("an operator-composed title and body win over the template", () => {
  const m = render("render_ready", { title: "Scheduled maintenance", body: "Back in ten minutes." });
  assertEquals(m.title, "Scheduled maintenance");
  assertEquals(m.body, "Back in ten minutes.");
});

Deno.test("absoluteLink prefixes a stored path and refuses anything that is not one", () => {
  assertEquals(absoluteLink({ deep_link: "/f/abc" }, BASE), "https://rendprop.com/f/abc");
  assertEquals(absoluteLink({ deep_link: "https://elsewhere.test/x" }, BASE), "https://elsewhere.test/x");
  // A bad link in a notification is worse than no link.
  assertEquals(absoluteLink({ deep_link: "javascript:alert(1)" }, BASE), null);
  assertEquals(absoluteLink({ deep_link: "f/abc" }, BASE), null);
  assertEquals(absoluteLink({}, BASE), null);
});

Deno.test("the email body carries the link and how to turn these off", () => {
  const text = emailText({ title: "t", body: "b" }, "https://rendprop.com/f/abc");
  assertStringIncludes(text, "https://rendprop.com/f/abc");
  assertStringIncludes(text, "Settings");
});
