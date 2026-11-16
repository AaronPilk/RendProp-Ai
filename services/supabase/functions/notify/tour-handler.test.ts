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
type Options = { current?: Array<boolean | "outage" | "malformed">; apnsDead?: boolean; enrolled?: boolean;
  twoDevices?: boolean; secondDisabled?: boolean; deviceLookupError?: boolean; emptyDevices?: boolean;
  apnsUnconfigured?: boolean; fallbackError?: boolean; fallbackRpcError?: boolean; fallbackStale?: boolean;
  fallbackStore?: Map<string, unknown> };
async function invoke(rows: OutboxRow[], options: Options = {}) {
  const vars = { ...env, APNS_KEY_P8: pem, APNS_KEY_ID: "TESTKEYID1", APNS_TEAM_ID: "TEAMID1234",
    RESEND_API_KEY: "fixture-only", NOTIFY_FROM_EMAIL: "Rendprop <notify@fixture.invalid>" };
  const previous = new Map(Object.keys(vars).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(vars)) Deno.env.set(key, value);
  if (options.apnsUnconfigured) for (const key of ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID"]) Deno.env.delete(key);
  const oldFetch = globalThis.fetch;
  const calls: Array<{ url: URL; body: Record<string, unknown> }> = [];
  const marked: Array<Record<string, unknown>> = [], fallback: unknown[] = [];
  let accessReads = 0, fallbackChecks = 0;
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
      if (url.searchParams.get("select") === "user_id,device_token,environment") {
        if (options.deviceLookupError) return Response.json({ message: "device database unavailable" }, { status: 503 });
        return Response.json(options.emptyDevices ? [] : [
          { user_id: USER, device_token: "synthetic-device", environment: "production" },
          ...(options.twoDevices ? [{ user_id: USER, device_token: "synthetic-device-2", environment: "production" }] : []),
        ]);
      }
      assertEquals(url.searchParams.get("user_id"), "eq." + USER);
      assertEquals(url.searchParams.get("environment"), "eq.production");
      assertEquals(url.searchParams.get("disabled_at"), "is.null");
      const token = url.searchParams.get("device_token")?.replace(/^eq\./, "");
      assert(token === "synthetic-device" || token === "synthetic-device-2");
      return Response.json(options.enrolled === false || options.secondDisabled && token === "synthetic-device-2" ? null : { device_token: token });
    }
    if (url.pathname === "/rest/v1/rpc/notification_mark") { marked.push(body); return Response.json({ ok: true }); }
    if (url.pathname === "/rest/v1/rpc/notification_disable_device") return Response.json({ ok: true });
    if (url.pathname === "/rest/v1/rpc/notification_email_fallback_enqueue") {
      const claimed = rows.find((r) => r.id === body.p_push)!;
      assertEquals(body.p_attempt, claimed.attempts);
      assertEquals(body.p_expected, { outbox_id: claimed.id, org_id: claimed.org_id,
        recipient_user_id: claimed.user_id, category: claimed.category, channel: claimed.channel,
        dedupe_key: claimed.dedupe_key, payload: claimed.payload, to_email: claimed.to_email ?? null });
      assert(typeof body.p_reason === "string");
      if (options.fallbackRpcError) return Response.json({ message: "RPC response unavailable" }, { status: 503 });
      if (options.fallbackStale) return Response.json("stale");
      const current = options.current?.[accessReads + fallbackChecks] ?? true;
      fallbackChecks++;
      if (current === false) {
        marked.push({ p_id: claimed.id, p_state: "skipped", p_error: "Notification or account access changed before email fallback." });
        return Response.json("denied");
      }
      if (options.fallbackError) {
        marked.push({ p_id: claimed.id, p_state: "failed", p_error: "Email fallback could not be queued (P0001)." });
        return Response.json("retry");
      }
      const derived = { org_id: claimed.org_id, user_id: claimed.user_id, category: claimed.category,
        channel: "email", dedupe_key: claimed.dedupe_key + ":email-fallback", payload: claimed.payload };
      const duplicate = options.fallbackStore?.has(derived.dedupe_key) ?? false;
      if (!duplicate) { options.fallbackStore?.set(derived.dedupe_key, derived); fallback.push(derived); }
      marked.push({ p_id: claimed.id, p_state: "skipped", p_error: body.p_reason });
      return Response.json(duplicate ? "duplicate" : "queued");
    }
    throw new Error("Unmodeled fixture request: " + url.pathname);
  };
  try {
    const response = await handler(new Request("https://edge.invalid/notify", { method: "POST", headers: { apikey: SERVICE } }));
    assertEquals(response.status, 200);
    return { result: await response.json(), calls, marked, fallback, accessReads, fallbackChecks };
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
  assertEquals(out.accessReads, 2); assertEquals(out.fallbackChecks, 1); assertEquals(providerCalls(out).length, 1);
  assertEquals(out.result.skipped, 1); assertEquals(out.fallback, []);
  assertStringIncludes(String(out.marked[0].p_error), "before email fallback");
});

Deno.test("access revoked between two device attempts suppresses the second attempt and fallback", async () => {
  const out = await invoke([row()], { twoDevices: true, apnsDead: true, current: [true, true, false] });
  assertEquals(out.accessReads, 3); assertEquals(providerCalls(out).length, 1);
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

Deno.test("batch device outage retries push without fallback while unrelated email still sends", async () => {
  const out = await invoke([row(), { ...row("email"), id: id(10) }], { deviceLookupError: true });
  assertEquals(out.result.failed, 1); assertEquals(out.result.sent, 1); assertEquals(out.result.skipped, 0);
  assertEquals(out.marked.map((m) => m.p_state), ["failed", "sent"]);
  assertStringIncludes(String(out.marked[0].p_error), "devices could not be read");
  assertEquals(providerCalls(out).map((c) => c.url.hostname), ["api.resend.com"]);
  assertEquals(out.fallback, []);
});

Deno.test("successful empty device lookup still queues the genuine no-device fallback", async () => {
  const out = await invoke([row()], { emptyDevices: true });
  assertEquals(out.result.skipped, 1); assertEquals(out.result.failed, 0);
  assertEquals(providerCalls(out), []); assertEquals(out.fallback.length, 1);
  assertEquals((out.fallback[0] as OutboxRow).dedupe_key, row().dedupe_key + ":email-fallback");
});

Deno.test("unconfigured APNs skips without querying devices or creating fallback", async () => {
  const out = await invoke([row()], { apnsUnconfigured: true, deviceLookupError: true });
  assertEquals(out.result.skipped, 1); assertEquals(out.result.failed, 0);
  assert(!out.calls.some((c) => c.url.pathname === "/rest/v1/notification_devices"));
  assertEquals(providerCalls(out), []); assertEquals(out.fallback, []);
  assertStringIncludes(String(out.marked[0].p_error), "push is not configured");
});

Deno.test("fallback write failure keeps push retryable and later retries dedupe the same email twin", async () => {
  const store = new Map<string, unknown>();
  const failed = await invoke([row()], { apnsDead: true, fallbackError: true, fallbackStore: store });
  assertEquals(failed.result.failed, 1); assertEquals(failed.result.skipped, 0);
  assertEquals(failed.marked[0].p_state, "failed");
  assertStringIncludes(String(failed.marked[0].p_error), "fallback could not be queued");
  assert(!failed.calls.some((c) => c.url.pathname === "/rest/v1/rpc/notification_mark"));
  assertEquals(store.size, 0);
  const retry = await invoke([row()], { emptyDevices: true, fallbackStore: store });
  const replay = await invoke([row()], { emptyDevices: true, fallbackStore: store });
  assertEquals(retry.result.skipped, 1); assertEquals(replay.result.skipped, 1);
  assertEquals(store.size, 1);
  assertEquals([...store.keys()], [row().dedupe_key + ":email-fallback"]);
  assertEquals((store.values().next().value as OutboxRow).payload, row().payload);
});

Deno.test("dead first device plus disabled second enrollment is not all-tokens-rejected fallback", async () => {
  const out = await invoke([row()], { apnsDead: true, twoDevices: true, secondDisabled: true });
  assertEquals(out.result.skipped, 1); assertEquals(providerCalls(out).length, 1);
  assertEquals(out.accessReads, 3); assertEquals(out.fallback, []);
  assertEquals(out.marked[0].p_error, "the current account or device enrollment changed");
});

Deno.test("genuinely rejected currently enrolled devices still create exactly one fallback", async () => {
  const out = await invoke([row()], { apnsDead: true, twoDevices: true });
  assertEquals(providerCalls(out).length, 2); assertEquals(out.fallback.length, 1);
  assertEquals(out.result.skipped, 1); assertEquals(out.result.failed, 0);
});

Deno.test("stale or uncertain fallback RPC never marks a newer claim by ID", async () => {
  for (const options of [{ fallbackStale: true }, { fallbackRpcError: true }]) {
    const claimed = row(), original = structuredClone(claimed);
    const out = await invoke([claimed], { emptyDevices: true, ...options });
    assertEquals(out.result[options.fallbackStale ? "skipped" : "failed"], 1);
    assertEquals(out.marked, []); assertEquals(out.fallback, []); assertEquals(claimed, original);
    assert(!out.calls.some((c) => c.url.pathname === "/rest/v1/rpc/notification_mark"));
  }
});
