// logic.test.ts — beacon's replay-resistance decision (audit: "public beacon
// metrics are replayable").
//
//   deno test services/supabase/functions/beacon/logic.test.ts
//
// Pure module, no network/DB/Deno.serve — see logic.ts's header.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { shouldCountView } from "./logic.ts";

Deno.test("shouldCountView: view_start:false never counts, and never even checks the dedupe gate", async () => {
  let called = false;
  const result = await shouldCountView(false, () => {
    called = true;
    return Promise.resolve(true);
  });
  assertEquals(result, false);
  assertEquals(called, false, "a plain watch/scroll beacon must not spend a rate-limit check");
});

Deno.test("shouldCountView: view_start:undefined behaves the same as false", async () => {
  let called = false;
  const result = await shouldCountView(undefined, () => {
    called = true;
    return Promise.resolve(true);
  });
  assertEquals(result, false);
  assertEquals(called, false);
});

Deno.test("shouldCountView: view_start:true counts only when the dedupe gate allows it", async () => {
  assertEquals(await shouldCountView(true, () => Promise.resolve(true)), true);
  assertEquals(await shouldCountView(true, () => Promise.resolve(false)), false);
});

Deno.test("shouldCountView: a REPLAYED view_start (same ip+slug inside the window) is not counted twice", async () => {
  // Simulates durableRateLimit(key, 1, window): true the first time it's
  // called for a key, false on every call after that until the window rolls.
  let calls = 0;
  const reserve = () => Promise.resolve(++calls === 1);

  assertEquals(await shouldCountView(true, reserve), true); // first beacon of the session -> counted
  assertEquals(await shouldCountView(true, reserve), false); // an attacker (or a bug) replaying the same claim -> not counted again
  assertEquals(await shouldCountView(true, reserve), false); // still not, a third time
});

Deno.test("shouldCountView: independent reserve() calls (different ip/slug keys) are independent", async () => {
  // Not this function's job to key the gate — index.ts does that by closing
  // over clientIp(req) + render.id — but the contract must hold: two
  // different `reserve` callbacks never interfere with each other.
  const gateA = { count: 0 };
  const gateB = { count: 0 };
  const reserveA = () => Promise.resolve(++gateA.count === 1);
  const reserveB = () => Promise.resolve(++gateB.count === 1);

  assertEquals(await shouldCountView(true, reserveA), true);
  assertEquals(await shouldCountView(true, reserveB), true); // a different (ip, slug) still gets its own first view
  assertEquals(await shouldCountView(true, reserveA), false);
});
