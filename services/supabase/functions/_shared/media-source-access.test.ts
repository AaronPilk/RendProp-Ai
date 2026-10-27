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
Deno.test("request-local intermediate proof avoids duplicate HEADs, while the final fence always rechecks", async () => {
  const org="30000000-0000-4000-8000-000000000003",publication="40000000-0000-4000-8000-000000000004";
  const source="50000000-0000-4000-8000-000000000005",output="60000000-0000-4000-8000-000000000006";
  const keyPrefix=`renders/${org}/${listing}/`;
  const original=`${keyPrefix}original-${source}.jpg`, altered=`${keyPrefix}gallery-${output}.jpg`;
  const privatePrefix=`ai-router/${org}/photo-evidence/${source}/${output}/`;
  const objects=[original,altered,privatePrefix+"input.jpg",privatePrefix+"candidate.jpg"]
    .map(key=>({key,bucket:"renders" as const,bytes:100,mime:"image/jpeg",etag:"exact-etag"}));
  let etag="exact-etag",available=true,heads=0,admissions=0;
  const db:MediaAccessClient={rpc(_name,args){const group=(kind:"assets"|"renders"|"keys")=>
    Object.fromEntries((args[`p_${kind}`] as string[]).map(value=>[value,true]));
    return Promise.resolve({error:null,data:{assets:group("assets"),renders:group("renders"),keys:group("keys"),
      photo_publications:[{publication_id:publication,org_id:org,listing_id:listing,assets:[output,source],keys:[original,altered],objects:objects.map(o=>({...o,etag}))}]}});
  }};
  const headIO={head:async(o:{key:string;bytes:number;mime:string;etag:string})=>{heads++;return{exists:available,bytes:o.bytes,contentType:o.mime,etag:o.etag};},admit:async()=>{admissions++;}};
  const refs={assets:[output],keys:[altered]};
  const proofs=new Map<string,string>();
  await assertMediaVisible(db,listing,refs,{intermediateProofs:proofs,headIO});
  assertEquals(heads,4);assertEquals(admissions,4);assertEquals(proofs.size,1);
  await assertMediaVisible(db,listing,refs,{intermediateProofs:proofs,headIO});
  assertEquals(heads,4);assertEquals(admissions,4);
  etag="changed-receipt";
  await assertMediaVisible(db,listing,refs,{intermediateProofs:proofs,headIO});
  assertEquals(heads,8);assertEquals(admissions,8);
  available=false;
  await assertRejects(()=>assertMediaVisible(db,listing,refs,{headIO}),HttpError,"no longer available");
  assertEquals(heads,12);assertEquals(admissions,12);
});
