import { assertEquals } from "jsr:@std/assert@1";
import { createPresenterDrain, handlePresenterDrain } from "./handler.ts";
const request = (body: unknown = {}, method = "POST") => new Request("https://fixture.rendprop.com/presenter-drain", { method, ...(method === "POST" ? { body: JSON.stringify(body), headers: { "content-type": "application/json" } } : {}) });
Deno.test("presenter drain rejects untrusted callers before inventory or job operations", async () => {
  assertEquals((await handlePresenterDrain(request())).status, 403);
  let calls = 0;
  const handle = createPresenterDrain({ authorized: () => false, inventory: () => { calls++; return Promise.resolve({ jobs: [] }); }, progress: () => { calls++; return Promise.resolve(); } });
  assertEquals((await handle(request())).status, 403); assertEquals(calls, 0);
});
Deno.test("presenter drain is POST-only and bounds operations before database access", async () => {
  let calls = 0;
  const handle = createPresenterDrain({ authorized: () => true, inventory: () => { calls++; return Promise.resolve({ jobs: [] }); }, progress: () => Promise.resolve() });
  assertEquals((await handle(request({}, "GET"))).status, 405);
  for (const body of [{ limit: 4 }, { limit: 0 }, { limit: 1.5 }, { job_id: crypto.randomUUID() }]) assertEquals((await handle(request(body))).status, 400);
  assertEquals(calls, 0);
});
Deno.test("presenter drain isolates job failures and reveals no private provider values", async () => {
  const checked: string[] = [];
  const handle = createPresenterDrain({ authorized: () => true, inventory: (limit) => { assertEquals(limit, 3); return Promise.resolve({ jobs: [{ id: "a" }, { id: "b" }, { id: "c" }] }); }, progress: (job) => { checked.push(job); return job === "b" ? Promise.reject(new Error("private signed URL must not be returned")) : Promise.resolve(); } });
  const response = await handle(request());
  assertEquals(response.status, 200); assertEquals(await response.json(), { checked: 3, completed: 2, retry_pending: 1 }); assertEquals(checked, ["a", "b", "c"]);
});
Deno.test("presenter drain never overlaps memory-heavy media retention jobs", async () => {
  let active = 0, peak = 0;
  const handle = createPresenterDrain({ authorized: () => true, inventory: () => Promise.resolve({ jobs: [{ id: "a" }, { id: "b" }, { id: "c" }] }), progress: async () => {
    active++; peak = Math.max(peak, active); await Promise.resolve(); active--;
  } });
  assertEquals((await handle(request())).status, 200); assertEquals(peak, 1); assertEquals(active, 0);
});
