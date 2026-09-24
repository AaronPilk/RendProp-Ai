import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { assertMediaVisible, mediaVisibility, withVisibleMedia, type MediaAccessClient } from "./media-source-access.ts";
import { HttpError } from "./http.ts";
const listing = "10000000-0000-4000-8000-000000000001";
const asset = "20000000-0000-4000-8000-000000000002";
function fixture(allowed = true) {
  const calls: Record<string, unknown>[] = [];
  const db: MediaAccessClient = { rpc(name, args) {
    assertEquals(name, "studio_presenter_media_visibility"); calls.push(args);
    return Promise.resolve({ error: null, data: Object.fromEntries(["assets", "renders", "keys"].map(kind => [kind,
      Object.fromEntries((args[`p_${kind}`] as string[]).map(value => [value, allowed]))])) });
  } };
  return { db, calls };
}
Deno.test("media visibility batches a full page and retains exact boolean entries", async () => {
  const f = fixture(); const keys = Array.from({ length: 401 }, (_, i) => `renders/org/${listing}/${i}.mp4`);
  const actual = await mediaVisibility(f.db, listing, { assets: [asset, asset], keys });
  assertEquals(f.calls.length, 3);
  assertEquals(f.calls.map(c => (c.p_assets as unknown[]).length + (c.p_renders as unknown[]).length + (c.p_keys as unknown[]).length), [200, 200, 2]);
  assertEquals(Object.keys(actual.keys).length, 401); assertEquals(actual.assets[asset], true);
});
Deno.test("prototype-like keys cannot silently disappear from permission checking", async () => {
  const f = fixture(false);
  await assertRejects(() => assertMediaVisible(f.db, listing, { keys: ["__proto__", "constructor"] }), HttpError, "no longer available");
  assertEquals(f.calls[0].p_keys, ["__proto__", "constructor"]);
});
Deno.test("permission RPC failures and incomplete or nonboolean results fail closed", async () => {
  for (const reply of [{ data: null, error: null }, { data: {}, error: null }, { data: { assets: { [asset]: "true" } }, error: null }, { data: { assets: { [asset]: true } }, error: { message: "db down" } }]) {
    const db: MediaAccessClient = { rpc: () => Promise.resolve(reply) };
    await assertRejects(() => assertMediaVisible(db, listing, { assets: [asset] }), HttpError);
  }
});
Deno.test("invalid identities and overbound pages never reach the database", async () => {
  const f = fixture();
  await assertRejects(() => mediaVisibility(f.db, "bad", { assets: [asset] }), HttpError);
  await assertRejects(() => mediaVisibility(f.db, listing, { assets: ["bad"] }), HttpError);
  await assertRejects(() => mediaVisibility(f.db, listing, { keys: Array.from({ length: 501 }, (_, i) => String(i)) }), HttpError);
  assertEquals(f.calls.length, 0);
});
Deno.test("a denied source is never signed; revocation while signing discards the capability", async () => {
  let signed = 0;
  await assertRejects(() => withVisibleMedia(fixture(false).db, listing, { assets: [asset] }, () => { signed++; return Promise.resolve("private-url"); }), HttpError);
  assertEquals(signed, 0);
  let checks = 0;
  const db: MediaAccessClient = { rpc: () => Promise.resolve({ error: null, data: { assets: { [asset]: ++checks === 1 } } }) };
  await assertRejects(() => withVisibleMedia(db, listing, { assets: [asset] }, () => { signed++; return Promise.resolve("private-url"); }), HttpError);
  assertEquals(checks, 2); assertEquals(signed, 1);
});
