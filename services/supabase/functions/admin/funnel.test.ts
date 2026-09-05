// funnel.test.ts — GET /admin/funnel's window validation and response shaping.
//
//   deno test --allow-env --allow-net services/supabase/functions/admin/funnel.test.ts
//
// `--allow-net` is only needed because supabase-js constructs a client; the
// stubbed `fetch` means no request ever leaves the process. The stub is what
// makes the interesting assertion possible: it captures the actual RPC body, so
// the test proves `?window=90d` really becomes `p_window: "90 days"` rather than
// trusting a lookup table by eye.
//
// What this file defends:
//   • an unknown window is a 400, never a silent fall-back to 30d;
//   • the Postgres numerics the RPC returns as STRINGS come out as JSON numbers
//     (Codable on the phone decodes `Double`, not `String`);
//   • a null percentage stays null and is never coerced to 0 — "nobody got
//     here" and "nobody converted" must not render as the same thing;
//   • steps and by_day are always arrays, and every step always has a label.

import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

// supabase.ts reads its env at module load, so the env must exist BEFORE
// funnel.ts is evaluated — hence the dynamic import below.
Deno.env.set("SUPABASE_URL", "https://funnel-test.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key");
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");

const { handleFunnel } = await import("./funnel.ts");

const realFetch = globalThis.fetch;

/** The shape admin_funnel() actually returns (numerics as strings). */
const RPC_PAYLOAD = {
  generated_at: "2026-09-05T12:00:00Z",
  from: "2026-08-06T12:00:00Z",
  to: "2026-09-05T12:00:00Z",
  window_seconds: 2592000,
  steps: [
    { name: "app_open", count: 100, pct_of_first: "100.0", pct_of_previous: null },
    { name: "signup", count: 40, pct_of_first: "40.0", pct_of_previous: "40.0" },
    { name: "home_created", count: 0, pct_of_first: "0.0", pct_of_previous: "0.0" },
    { name: "capture_finished", count: 0, pct_of_first: "0.0", pct_of_previous: null },
    { name: "render_finished", count: 0, pct_of_first: "0.0", pct_of_previous: null },
    { name: "tour_published", count: 0, pct_of_first: "0.0", pct_of_previous: null },
    { name: "paywall_viewed", count: 0, pct_of_first: "0.0", pct_of_previous: null },
    { name: "purchase_completed", count: 0, pct_of_first: "0.0", pct_of_previous: null },
  ],
  crashes: 3,
  errors: 7,
  active_devices: 101,
  sessions: 260,
  events: 4211,
  by_day: [{ day: "2026-09-04", opens: 9, signups: 5, purchases: 0, crashes: 1 }],
};

interface Captured { url: string; body: unknown }

/** Answer every RPC with `payload`, recording what was asked for. */
function stubFetch(payload: unknown, captured: Captured[]) {
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    let body: unknown = null;
    try { body = init?.body ? JSON.parse(String(init.body)) : null; } catch { /* not JSON */ }
    captured.push({ url, body });
    return Promise.resolve(
      new Response(JSON.stringify(payload), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as typeof fetch;
}

function request(query = ""): Request {
  return new Request(`https://funnel-test.invalid/functions/v1/admin/funnel${query}`);
}

Deno.test("funnel: the window maps to a real Postgres interval", async () => {
  const captured: Captured[] = [];
  stubFetch(RPC_PAYLOAD, captured);
  try {
    for (const [q, expected] of [["?window=7d", "7 days"], ["?window=30d", "30 days"], ["?window=90d", "90 days"]]) {
      captured.length = 0;
      const res = await handleFunnel(request(q));
      assertEquals(res.status, 200);
      assertStringIncludes(captured[0].url, "/rpc/admin_funnel");
      assertEquals((captured[0].body as Record<string, unknown>).p_window, expected);
    }
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("funnel: no window means 30 days", async () => {
  const captured: Captured[] = [];
  stubFetch(RPC_PAYLOAD, captured);
  try {
    const res = await handleFunnel(request());
    const body = await res.json();
    assertEquals(body.window, "30d");
    assertEquals((captured[0].body as Record<string, unknown>).p_window, "30 days");
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("funnel: an unknown window is a 400, never a silent default", async () => {
  const captured: Captured[] = [];
  stubFetch(RPC_PAYLOAD, captured);
  try {
    let status = 0;
    let message = "";
    try {
      await handleFunnel(request("?window=all"));
    } catch (e) {
      status = (e as { status: number }).status;
      message = (e as Error).message;
    }
    assertEquals(status, 400);
    assertStringIncludes(message, "7d");
    assertEquals(captured.length, 0, "a bad window must not reach the database");
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("funnel: numerics become numbers and nulls stay null", async () => {
  stubFetch(RPC_PAYLOAD, []);
  try {
    const body = await (await handleFunnel(request("?window=7d"))).json();
    assertEquals(body.steps.length, 8);
    assertEquals(body.steps[0].pct_of_first, 100);          // "100.0" → 100
    assertEquals(body.steps[0].pct_of_previous, null);      // first step has no previous
    assertEquals(body.steps[1].pct_of_previous, 40);
    // 0% and "no data" must not collapse into each other.
    assertEquals(body.steps[2].pct_of_previous, 0);
    assertEquals(body.steps[3].pct_of_previous, null);
    assertEquals(body.crashes, 3);
    assertEquals(body.errors, 7);
    assertEquals(body.active_devices, 101);
    assertEquals(body.sessions, 260);
    assertEquals(body.by_day, [{ day: "2026-09-04", opens: 9, signups: 5, purchases: 0, crashes: 1 }]);
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("funnel: every step carries plain-words label", async () => {
  stubFetch(RPC_PAYLOAD, []);
  try {
    const body = await (await handleFunnel(request())).json();
    assertEquals(body.steps.map((s: { label: string }) => s.label), [
      "Opened the app", "Signed up", "Added a home", "Finished a walkthrough",
      "Tour rendered", "Tour published", "Saw plans", "Subscribed",
    ]);
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("funnel: an empty database still answers a full-shaped report", async () => {
  // Every key present, arrays never omitted — the phone's Codable decodes this.
  stubFetch({ steps: [], by_day: [] }, []);
  try {
    const body = await (await handleFunnel(request())).json();
    assertEquals(body.steps, []);
    assertEquals(body.by_day, []);
    assertEquals(body.crashes, 0);
    assertEquals(body.active_devices, 0);
    assertEquals(typeof body.generated_at, "string");
    assertStringIncludes(body.note, "distinct devices");
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("funnel: a step the labels don't know still reads as words", async () => {
  stubFetch({ steps: [{ name: "new_step_here", count: 5 }], by_day: [] }, []);
  try {
    const body = await (await handleFunnel(request())).json();
    assertEquals(body.steps[0].label, "New Step Here");
  } finally {
    globalThis.fetch = realFetch;
  }
});
