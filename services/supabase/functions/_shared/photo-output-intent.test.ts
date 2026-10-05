import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "./http.ts";
import { persistPhotoOutput } from "./photo-output-intent.ts";

const intent = { userId: "fixture-owner", orgId: "fixture-org", listingId: "fixture-listing", key: "ai-router/fixture-org/task/fixture.jpg", bytes: 1234 };
Deno.test("actual photo writer records scoped cleanup intent before any PUT", async () => {
  const order: string[] = [];
  const db = { rpc(name: string, args: Record<string, unknown>) {
    order.push("journal"); assertEquals(name, "register_private_ai_output");
    assertEquals(args, { p_user: intent.userId, p_org: intent.orgId, p_listing: intent.listingId, p_bucket: "renders", p_key: intent.key, p_bytes: 1234 });
    return Promise.resolve({ data: { ok: true, key: intent.key }, error: null });
  } };
  const result = await persistPhotoOutput(db, intent, async () => { order.push("PUT"); return { key: intent.key, bytes: 1234 }; });
  assertEquals(order, ["journal", "PUT"]); assertEquals(result.key, intent.key);
});
Deno.test("unavailable, false and mismatched output journals prevent all storage writes", async () => {
  for (const data of [null, { ok: false, key: intent.key }, { ok: true, key: "foreign-key" }]) {
    let puts = 0;
    await assertRejects(() => persistPhotoOutput({ rpc: () => Promise.resolve({ data, error: null }) }, intent, async () => { puts++; return { key: intent.key, bytes: 1234 }; }), HttpError);
    assertEquals(puts, 0);
  }
  let puts = 0;
  const error = await assertRejects(() => persistPhotoOutput({ rpc: () => Promise.resolve({ data: null, error: { message: "private database row" } }) }, intent, async () => { puts++; return { key: intent.key, bytes: 1234 }; }), HttpError);
  assertEquals(error.message, "Edited photo could not be stored."); assertEquals(puts, 0);
});
Deno.test("a lost photo PUT response leaves the already-committed cleanup journal", async () => {
  const committed: unknown[] = [];
  await assertRejects(() => persistPhotoOutput({ rpc: (_name, args) => { committed.push(args); return Promise.resolve({ data: { ok: true, key: intent.key }, error: null }); } }, intent, async () => { throw new Error("response lost after PUT"); }));
  assertEquals(committed.length, 1);
});
Deno.test("canonical storage results cannot substitute a different key or byte size", async () => {
  const db = { rpc: () => Promise.resolve({ data: { ok: true, key: intent.key }, error: null }) };
  for (const result of [{ key: "foreign-key", bytes: 1234 }, { key: intent.key, bytes: 9999 }]) await assertRejects(() => persistPhotoOutput(db, intent, () => Promise.resolve(result)), HttpError);
});
