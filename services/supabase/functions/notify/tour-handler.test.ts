// The actual dispatcher and providers run with synthetic Auth/PostgREST/APNs.
import { assert, assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { OutboxRow } from "./deliver.ts";
import * as apns from "./apns.ts";

const id = (n: number) => `e0160000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const USER = id(1), ORG = id(2), LISTING = id(3), RENDER = id(4), OUTBOX = id(5), JOB = id(6);
const SERVICE = "sb_secret_" + "tour_fixture_only_".repeat(2);
const env = { SUPABASE_URL: "https://tour-notify-fixture.invalid", SUPABASE_ANON_KEY: "fixture-public",
  SUPABASE_SERVICE_ROLE_KEY: "fixture-service", SUPABASE_SECRET_KEYS: JSON.stringify({ default: SERVICE }),
  RENDPROP_SECRET_KEY_NAME: "default", RENDPROP_LEGACY_SERVICE_AUTH: "disabled" };
const saved = new Map(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
let handler!: (req: Request) => Promise<Response>;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: serve.configurable, enumerable: serve.enumerable, writable: true,
  value: (fn: typeof handler) => { handler = fn; return {}; } });
try { await import("./index.ts?tour-handler-proof"); }
finally {
  Object.defineProperty(Deno, "serve", serve);
  for (const [key, value] of saved) if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
}
if (!handler) throw new Error("Actual notify handler not captured");

const key = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const p8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", key.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...p8))}\n-----END PRIVATE KEY-----`;
const row = (channel: "email" | "push" = "push"): OutboxRow => ({
  id: OUTBOX, org_id: ORG, user_id: USER, category: "render_ready", channel, attempts: 1,
  dedupe_key: `render_ready:${RENDER}:${USER}`,
  payload: { deep_link: "/f/exact-tour", data: { render_id: RENDER, listing_id: LISTING, slug: "exact-tour", listing_address: "Private fixture address", source: "worker" } },
});
type Options = { current?: Array<boolean | "outage" | "malformed">; apnsDead?: boolean; enrolled?: boolean; twoDevices?: boolean; secondDisabled?: boolean };
async function invoke(rows: OutboxRow[], options: Options = {}) {
  const vars = { ...env, APNS_KEY_P8: pem, APNS_KEY_ID: "TESTKEYID1", APNS_TEAM_ID: "TEAMID1234",
    RESEND_API_KEY: "fixture-only", NOTIFY_FROM_EMAIL: "Rendprop <notify@fixture.invalid>" };
  const previous = new Map(Object.keys(vars).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(vars)) Deno.env.set(key, value);
  const oldFetch = globalThis.fetch;
  const calls: Array<{ url: URL; body: Record<string, unknown> }> = [];
  const marked: Array<Record<string, unknown>> = [], fallback: unknown[] = [];
  let accessReads = 0;
  apns.resetProviderToken();
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init), url = new URL(request.url);
    const body = request.method === "POST" || request.method === "PATCH" ? await request.json() : {};
    calls.push({ url, body });
    if (url.hostname === "api.push.apple.com") {
      return options.apnsDead ? Response.json({ reason: "Unregistered" }, { status: 410 }) : new Response(null, { status: 200, headers: { "apns-id": "fixture-message" } });
    }
    if (url.hostname === "api.resend.com") { assertEquals(request.redirect, "error"); return Response.json({ id: "fixture-email" }); }
    if (url.hostname !== "tour-notify-fixture.invalid") throw new Error("Unmodeled external dispatch");
    if (url.pathname === "/rest/v1/rpc/notification_claim_batch") return Response.json(rows);
    if (url.pathname === "/rest/v1/rpc/notification_verified_recipients") return Response.json([{ id: USER, email: "verified@fixture.invalid" }]);
    if (url.pathname === "/rest/v1/rpc/tour_notification_current") {
      const claimed = rows.find((r) => r.id === body.p_outbox)!;
      const data = claimed.payload.data as Record<string, unknown>;
      assertEquals(body, { p_outbox: claimed.id, p_expected: { outbox_id: claimed.id, org_id: claimed.org_id,
        recipient_user_id: claimed.user_id, render_id: data.render_id, listing_id: data.listing_id,
        slug: data.slug, deep_link: claimed.payload.deep_link } });
      const answer = options.current?.[accessReads] ?? true;
      accessReads++;
      return answer === "outage" ? Response.json({ message: "database unavailable" }, { status: 503 }) : Response.json(answer === "malformed" ? null : answer);
    }
    if (url.pathname === "/rest/v1/rpc/property_video_notification_current") { assertEquals(body, { p_job: JOB, p_actor: USER }); return Response.json(true); }
    if (url.pathname === "/rest/v1/notification_devices") {
      if (request.method === "PATCH") return Response.json({});
      if (url.searchParams.get("select") === "user_id,device_token,environment") return Response.json([
        { user_id: USER, device_token: "synthetic-device", environment: "production" },
        ...(options.twoDevices ? [{ user_id: USER, device_token: "synthetic-device-2", environment: "production" }] : []),
      ]);
      assertEquals(url.searchParams.get("user_id"), "eq." + USER);
      assertEquals(url.searchParams.get("environment"), "eq.production");
      assertEquals(url.searchParams.get("disabled_at"), "is.null");
      const token = url.searchParams.get("device_token")?.replace(/^eq\./, "");
      assert(token === "synthetic-device" || token === "synthetic-device-2");
      return Response.json(options.enrolled === false || options.secondDisabled && token === "synthetic-device-2" ? null : { device_token: token });
    }
    if (url.pathname === "/rest/v1/rpc/notification_mark") { marked.push(body); return Response.json({ ok: true }); }
    if (url.pathname === "/rest/v1/rpc/notification_disable_device") return Response.json({ ok: true });
    if (url.pathname === "/rest/v1/notification_outbox" && request.method === "POST") { fallback.push(body); return Response.json({}); }
    throw new Error("Unmodeled fixture request: " + url.pathname);
  };
  try {
    const response = await handler(new Request("https://edge.invalid/notify", { method: "POST", headers: { apikey: SERVICE } }));
    assertEquals(response.status, 200);
    return { result: await response.json(), calls, marked, fallback, accessReads };
  } finally {
    globalThis.fetch = oldFetch; apns.resetProviderToken();
    for (const [name, value] of previous) if (value === undefined) Deno.env.delete(name); else Deno.env.set(name, value);
  }
}
const providerCalls = (out: Awaited<ReturnType<typeof invoke>>) => out.calls.filter((c) => ["api.push.apple.com", "api.resend.com"].includes(c.url.hostname));

Deno.test("actual drain sends exact authorized tour route and generic APNs copy to its own recipient", async () => {
  const out = await invoke([row()]);
  assertEquals(out.result.sent, 1); assertEquals(out.accessReads, 2);
  const payload = providerCalls(out)[0].body;
  assertEquals(payload.category, "render_ready"); assertEquals(payload.recipient_user_id, USER);
  assertEquals(payload.deep_link, "https://rendprop.com/f/exact-tour");
  assertEquals(payload.data, { render_id: RENDER, listing_id: LISTING, slug: "exact-tour" });
  assert(!JSON.stringify(payload).includes("Private fixture address"));
  assertEquals(out.marked[0].p_state, "sent"); assertEquals(out.fallback, []);
});

Deno.test("actual tour email uses verified identity and the same current render scope", async () => {
  const out = await invoke([row("email")]);
  assertEquals(out.result.sent, 1); assertEquals(out.accessReads, 1);
  const email = providerCalls(out)[0].body;
  assertEquals(email.to, ["verified@fixture.invalid"]);
  assertStringIncludes(String(email.text), "https://rendprop.com/f/exact-tour");
});

Deno.test("inaccessible queued tours skip both channels without provider dispatch or fallback", async () => {
  for (const channel of ["push", "email"] as const) {
    const out = await invoke([row(channel)], { current: [false] });
    assertEquals(out.result.skipped, 1); assertEquals(out.marked[0].p_state, "skipped");
    assertEquals(providerCalls(out), []); assertEquals(out.fallback, []);
  }
});

Deno.test("malformed and cross-type completion notices never reach tour or private-job authority", async () => {
  for (const payload of [
    {}, { ...row().payload, deep_link: "/f/wrong-tour" },
    { ...row().payload, data: { ...(row().payload.data as object), property_video_job_id: JOB, reel_job_id: JOB } },
    { data: { listing_id: LISTING, property_video_job_id: JOB } },
  ]) {
    const out = await invoke([{ ...row(), payload }]);
    assertEquals(out.result.skipped, 1); assertEquals(out.accessReads, 0);
    assert(!out.calls.some((c) => c.url.pathname.endsWith("property_video_notification_current")));
    assertEquals(providerCalls(out), []); assertEquals(out.fallback, []);
  }
});

Deno.test("tour authority failure retries without presenting success or manufacturing fallback", async () => {
  for (const answer of ["outage", "malformed"] as const) {
    const out = await invoke([row()], { current: [answer] });
    assertEquals(out.result.failed, 1); assertEquals(out.marked[0].p_state, "failed");
    assertEquals(providerCalls(out), []); assertEquals(out.fallback, []);
  }
});

Deno.test("tour revocation or enrollment loss before a device attempt prevents APNs and email", async () => {
  for (const options of [{ current: [true, false] }, { enrolled: false }]) {
    const out = await invoke([row()], options);
    assertEquals(out.result.skipped, 1); assertEquals(providerCalls(out), []); assertEquals(out.fallback, []);
  }
});

Deno.test("access lost after APNs rejection never creates a fallback email", async () => {
  const out = await invoke([row()], { apnsDead: true, current: [true, true, false] });
  assertEquals(out.accessReads, 3); assertEquals(providerCalls(out).length, 1);
  assertEquals(out.result.skipped, 1); assertEquals(out.fallback, []);
  assertStringIncludes(String(out.marked[0].p_error), "before email fallback");
});

Deno.test("access revoked between two device attempts suppresses the second attempt and fallback", async () => {
  const out = await invoke([row()], { twoDevices: true, apnsDead: true, current: [true, true, false, false] });
  assertEquals(out.accessReads, 4); assertEquals(providerCalls(out).length, 1);
  assertEquals(out.result.skipped, 1); assertEquals(out.fallback, []);
  const enrollment = out.calls.filter((c) => c.url.pathname === "/rest/v1/notification_devices" && c.url.searchParams.get("select") === "device_token");
  assertEquals(enrollment.length, 1);
});

Deno.test("an authorized fallback is deduped then independently denied if access changes before its drain", async () => {
  const out = await invoke([row()], { apnsDead: true });
  assertEquals(out.fallback.length, 1);
  const fallback = out.fallback[0] as OutboxRow;
  assertEquals(fallback.dedupe_key, row().dedupe_key + ":email-fallback");
  assertEquals(fallback.user_id, USER); assertEquals(fallback.payload, row().payload);
  const later = await invoke([{ ...fallback, id: id(9), attempts: 1 }], { current: [false] });
  assertEquals(later.result.skipped, 1); assertEquals(providerCalls(later), []);
});

Deno.test("valid private-video notices retain their original actor-scoped job checks and route", async () => {
  const out = await invoke([{ ...row(), payload: { data: { property_video_job_id: JOB, reel_job_id: JOB, listing_id: LISTING } } }]);
  assertEquals(out.result.sent, 1); assertEquals(out.accessReads, 0);
  assertEquals(out.calls.filter((c) => c.url.pathname.endsWith("property_video_notification_current")).length, 2);
  assertEquals(providerCalls(out)[0].body.data, { property_video_job_id: JOB, reel_job_id: JOB, listing_id: LISTING });
});
