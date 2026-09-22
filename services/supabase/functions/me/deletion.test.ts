// Actual /me handler with synthetic Auth/PostgREST; no provider or socket.
// The fake's ownership change is paired with a real PostgreSQL overlap gate.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const USER = "00000000-0000-4000-8000-000000000001";
const DEST = "00000000-0000-4000-8000-000000000002";
const ORG = "00000000-0000-4000-8000-000000000003";
const LISTING = "00000000-0000-4000-8000-000000000004";
const REQUEST = "00000000-0000-4000-8000-000000000005";
const LEASE = "00000000-0000-4000-8000-000000000006";
const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), {
  status, headers: { "content-type": "application/json" },
});
Deno.env.set("SUPABASE_URL", "https://deletion-fixture.invalid");
Deno.env.set("SUPABASE_ANON_KEY", "synthetic-public-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "synthetic-service-key");
Deno.env.set("CLOUDFLARE_ACCOUNT_ID", "deletion-storage-fixture");
Deno.env.set("R2_ACCESS_KEY_ID", "synthetic-only-access");
Deno.env.set("R2_SECRET_ACCESS_KEY", "synthetic-only-secret");
let handler!: (req: Request) => Promise<Response>;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
// An explicit DATA descriptor, not `{...serve, value}`. `Deno.serve` is an
// ACCESSOR property (get/set) in the pinned runtime, and spreading it carries
// those keys along, so adding `value` makes the descriptor invalid and the whole
// module fails to load with "Cannot both specify accessors and a value or
// writable attribute" — before a single test runs. Same shape adopt/adopt.test.ts
// already uses; the `finally` below still restores the original accessor.
Object.defineProperty(Deno, "serve", {
  configurable: serve.configurable,
  enumerable: serve.enumerable,
  writable: true,
  value: (fn: typeof handler) => { handler = fn; return {}; },
});
try { await import("./index.ts"); } finally { Object.defineProperty(Deno, "serve", serve); }
if (!handler) throw new Error("Actual /me handler was not captured");

type Options = { prepareError?: boolean; receiptPatch?: Record<string, unknown>; finishError?: boolean; finishPatch?: Record<string, unknown>; authError?: boolean; sweep?: boolean; legacy?: boolean;
  payloadPatch?: Record<string, unknown>; providerReady?: boolean; providerError?: boolean; storageError?: boolean;
  // Non-RPnnn PostgREST failures (deadlock, lock timeout, missing overload): the exact text the DB would send.
  prepareDbError?: string; finishDbError?: string; claimEscalated?: boolean };
async function invoke(opts: Options = {}) {
  const prior = globalThis.fetch;
  let owner = USER, winnerDeleted = false, authDeleted = false;
  const calls: { path: string; method: string; body: unknown }[] = [];
  const payload = { r2: [], stream_uids: [], ghl_targets: [], apple_refresh_token: null,
    analytics_user_id: USER, profile_id: USER, auth_user_id: USER, provider_leases: [],
    multipart_uploads: [], unresolved_uploads: [], unresolved_render_jobs: [], storage_not_before: null, ...opts.payloadPatch };
  const receipt = () => ({ ok: true, snapshot_version: 2, request_id: REQUEST, source_user_id: USER,
    lease_token: LEASE, payload, scope: { source_user_id: USER, solo_orgs: [], shared_orgs: [], db_purged: true },
    manual_review_required: false, ...opts.receiptPatch });
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    if(url.hostname==="deletion-storage-fixture.r2.cloudflarestorage.com") {
      calls.push({path:url.pathname+url.search,method:req.method,body:undefined});
      if(req.method!=="DELETE") throw new Error("Only fixture cleanup is allowed");
      return new Response(null,{status:opts.storageError?400:204});
    }
    if (url.hostname !== "deletion-fixture.invalid") throw new Error("Unmodelled external request");
    const body = ["POST", "PATCH"].includes(req.method) ? await req.json() : undefined;
    calls.push({ path: url.pathname, method: req.method, body });
    if (url.pathname === "/auth/v1/user") return json({ id: USER, email: "source@fixture.invalid", is_anonymous: true });
    if (url.pathname === `/auth/v1/admin/users/${USER}`) {
      if (opts.authError) return json({ message: "synthetic outage" }, 503);
      authDeleted = true; return json({ user: { id: USER } });
    }
    if (url.pathname === "/rest/v1/rpc/prepare_account_deletion") {
      // Adoption commits before the deletion transaction obtains its lock.
      // The real SQL gate proves that this yields no owned-org target.
      owner = DEST;
      if (opts.prepareDbError) return json({ code: "40P01", message: opts.prepareDbError }, 500);
      return opts.prepareError ? json({ message: "RP409: synthetic snapshot failure" }, 400) : json(receipt());
    }
    if (url.pathname === "/rest/v1/rpc/claim_account_deletion") {
      if (opts.claimEscalated) return json({ ok: false, manual_review_required: true, request_id: REQUEST,
        escalation_reason: "no cleanup progress in 12 consecutive sweeps; retained for manual reconciliation: provider_leases=1" });
      return json(opts.legacy ? { ok: false, manual_review_required: true, request_id: REQUEST } : receipt());
    }
    if (url.pathname === "/rest/v1/rpc/finish_account_deletion") {
      const remaining=(body as {p_remaining:Record<string,unknown>}).p_remaining;
      const complete=Object.values(remaining).every(x=>x===null || (Array.isArray(x)&&x.length===0));
      if (opts.finishDbError) return json({ code: "55P03", message: opts.finishDbError }, 500);
      return opts.finishError ? json({ message: "RP409: synthetic stale lease" }, 400)
        : json({ ok: true, request_id: REQUEST, source_user_id: USER,
          cleanup_complete: authDeleted&&complete, manual_review_required: false, ...opts.finishPatch });
    }
    if(url.pathname==="/rest/v1/rpc/account_deletion_provider_ready") return opts.providerError
      ? json({message:"synthetic provider journal outage"},400):json(opts.providerReady===true);
    // Keep the old handler executable: it reads the old ownership first,
    // then loses the race immediately before inserting its unfenced tombstone.
    const table = url.pathname.split("/").at(-1);
    if (table === "deletion_requests" && req.method === "POST") { owner = DEST; return json({ id: REQUEST }); }
    if (table === "deletion_requests" && req.method === "GET") return json(opts.sweep ? [{ id: REQUEST }] : []);
    if (table === "memberships" && req.method === "HEAD") return new Response(null, { headers: { "content-range": "0-0/1" } });
    if (table === "memberships" && req.method === "GET") return json([{ id: ORG, org_id: ORG, user_id: USER, role: "owner" }]);
    if (table === "profiles" && req.method === "GET") return json({ id: USER, email: "source@fixture.invalid", apple_refresh_token: null });
    if (table === "listings" && req.method === "GET") return json([{ id: LISTING }]);
    if (req.method === "GET") return json([]);
    if (req.method === "DELETE" && ["orgs", "listings"].includes(table ?? "") && owner === DEST) winnerDeleted = true;
    return json(null);
  };
  try {
    const response = await handler(new Request(`https://edge.invalid/me${opts.sweep ? "/sweep-deletions" : ""}`, {
      method: opts.sweep ? "POST" : "DELETE",
      headers: { authorization: `Bearer ${opts.sweep ? "synthetic-service-key" : "synthetic-user-session"}` },
    }));
    return { status: response.status, body: await response.json(), calls, owner, winnerDeleted, authDeleted };
  } finally { globalThis.fetch = prior; }
}

Deno.test("adoption winner is never destroyed by the earlier DELETE ownership snapshot", async () => {
  const out = await invoke();
  assertEquals(out.owner, DEST);
  assertEquals(out.winnerDeleted, false, "adopted workspace was destroyed from stale ownership");
  assertEquals(out.status, 200);
  assertEquals(out.body.cleanup_complete, true);
  assertEquals(out.calls.filter(c => c.path.endsWith("/prepare_account_deletion")).length, 1);
});

Deno.test("snapshot failure prevents every destructive operation", async () => {
  const out = await invoke({ prepareError: true });
  assertEquals(out.status, 409);
  assertEquals(out.calls.some(c => c.method === "DELETE" || c.method === "PATCH"), false);
});
for (const patch of [{ ok: false }, { source_user_id: DEST }, { request_id: "bad" },
  { lease_token: "bad" }, { snapshot_version: 0 }, { scope: { db_purged: false, solo_orgs: [], shared_orgs: [] } },
  { scope: { source_user_id: DEST, db_purged: true, solo_orgs: [], shared_orgs: [] } },
  { payload: { r2: [] } }]) {
  Deno.test(`malformed deletion receipt ${Object.keys(patch)[0]} cannot authorize cleanup`, async () => {
    const out = await invoke({ receiptPatch: patch });
    assertEquals(out.status, 502);
    assertEquals(out.calls.some(c => c.method === "DELETE" || c.method === "PATCH"), false);
  });
}
Deno.test("failed Auth deletion remains pending and returns500", async () => {
  const out = await invoke({ authError: true });
  assertEquals(out.status, 500); assertEquals(out.body.ok, false);
  const finish = out.calls.find(c => c.path.endsWith("/finish_account_deletion"));
  assertEquals((finish?.body as { p_remaining: { auth_user_id: string } }).p_remaining.auth_user_id, USER);
});
Deno.test("unconfirmed final CAS cannot report deletion success", async () => {
  const out = await invoke({ finishError: true });
  assertEquals(out.status, 409);
  assertEquals(out.body.ok, undefined);
});
Deno.test("legacy sweep quarantines unbound payload without deletion", async () => {
  const out = await invoke({ sweep: true, legacy: true });
  assertEquals(out.status, 200); assertEquals(out.body.manual_review, 1);
  assertEquals(out.calls.some(c => c.method === "DELETE" || c.method === "PATCH"), false);
});
Deno.test("false completed envelope cannot conceal a retained Auth target", async () => {
  const out = await invoke({ authError: true, finishPatch: { cleanup_complete: true } });
  assertEquals(out.status, 502); assertEquals(out.body.ok, undefined);
});

const GPU = {job_id:LISTING,lease_token:LEASE};
const OBJECT = {bucket:"rendprop-uploads",key:"spatial/fixture/model.sog"};
const MULTIPART = {...OBJECT,upload_id:"synthetic-multipart"};
function remaining(out:Awaited<ReturnType<typeof invoke>>) {
  return (out.calls.find(c=>c.path.endsWith("/finish_account_deletion"))!.body as
    {p_remaining:Record<string,unknown>}).p_remaining;
}
Deno.test("spatial provider files stay queued after sign-in deletion",async()=>{
  const out=await invoke({payloadPatch:{provider_leases:[GPU]}});
  assertEquals(out.status,200);assertEquals(out.body.ok,true);assertEquals(out.body.cleanup_complete,false);
  assertEquals(out.body.pending.gpu_attempts,1);assertEquals(remaining(out).provider_leases,[GPU]);
});
Deno.test("confirmed provider cleanup is consumed by actual handler",async()=>{
  const out=await invoke({payloadPatch:{provider_leases:[GPU]},providerReady:true});
  assertEquals(out.body.cleanup_complete,true);assertEquals(remaining(out).provider_leases,[]);
  assertEquals(out.calls.filter(c=>c.path.endsWith("/account_deletion_provider_ready")).length,1);
});
Deno.test("provider readiness outage retains exact lease",async()=>{
  const out=await invoke({payloadPatch:{provider_leases:[GPU]},providerError:true});
  assertEquals(out.body.cleanup_complete,false);assertEquals(remaining(out).provider_leases,[GPU]);
});
Deno.test("false completed envelope cannot conceal retained spatial files",async()=>{
  const out=await invoke({payloadPatch:{provider_leases:[GPU]},finishPatch:{cleanup_complete:true}});
  assertEquals(out.status,502);assertEquals(out.body.ok,undefined);
});
Deno.test("future write deadline prevents object and multipart cleanup",async()=>{
  const deadline=new Date(Date.now()+3600000).toISOString();
  const out=await invoke({payloadPatch:{r2:[OBJECT],multipart_uploads:[MULTIPART],storage_not_before:deadline}});
  assertEquals(out.body.cleanup_complete,false);assertEquals(remaining(out).storage_not_before,deadline);
  assertEquals(remaining(out).r2,[OBJECT]);assertEquals(remaining(out).multipart_uploads,[MULTIPART]);
  assertEquals(out.calls.filter(c=>c.path.startsWith("/rendprop-uploads/")).length,0);
});
Deno.test("drained writes execute real R2 helper paths against fixture and clear both targets",async()=>{
  const out=await invoke({payloadPatch:{r2:[OBJECT],multipart_uploads:[MULTIPART],storage_not_before:"2000-01-01T00:00:00Z"}});
  assertEquals(out.body.cleanup_complete,true);
  assertEquals(out.calls.filter(c=>c.path.startsWith("/rendprop-uploads/")&&c.method==="DELETE").length,2);
  assertEquals(remaining(out).r2,[]);assertEquals(remaining(out).multipart_uploads,[]);
});
Deno.test("object and multipart failures remain queued for another sweep",async()=>{
  const out=await invoke({payloadPatch:{r2:[OBJECT],multipart_uploads:[MULTIPART]},storageError:true});
  assertEquals(out.body.cleanup_complete,false);assertEquals(remaining(out).r2,[OBJECT]);
  assertEquals(remaining(out).multipart_uploads,[MULTIPART]);
});
Deno.test("missing spatial cleanup category rejects receipt before any cleanup",async()=>{
  const out=await invoke({payloadPatch:{provider_leases:undefined}});
  assertEquals(out.status,502);assertEquals(out.calls.some(c=>c.method==="DELETE"||c.method==="PATCH"),false);
});
Deno.test("unknown multipart allocation is retained not treated as absent",async()=>{
  const target={operation_id:LEASE,...OBJECT};
  const out=await invoke({payloadPatch:{unresolved_uploads:[target]}});
  assertEquals(out.body.cleanup_complete,false);assertEquals(remaining(out).unresolved_uploads,[target]);
});
Deno.test("sweeper consumes confirmed spatial lease without an Auth session",async()=>{
  const out=await invoke({sweep:true,payloadPatch:{provider_leases:[GPU]},providerReady:true});
  assertEquals(out.status,200);assertEquals(out.body.processed,1);assertEquals(remaining(out).provider_leases,[]);
});
Deno.test("malformed provider identity rejects entire cleanup receipt",async()=>{
  const out=await invoke({payloadPatch:{provider_leases:[{...GPU,lease_token:"wrong"}]}});
  assertEquals(out.status,502);assertEquals(out.calls.some(c=>c.method==="DELETE"||c.method==="PATCH"),false);
});
Deno.test("provider per-pass cap retains every unvisited lease",async()=>{
  const targets=Array.from({length:17},(_,i)=>({...GPU,lease_token:"00000000-0000-4000-8000-"+String(100+i).padStart(12,"0")}));
  const out=await invoke({payloadPatch:{provider_leases:targets},providerReady:true});
  assertEquals(out.body.cleanup_complete,false);
  assertEquals(out.calls.filter(c=>c.path.endsWith("/account_deletion_provider_ready")).length,16);
  assertEquals(remaining(out).provider_leases,[targets[16]]);
});
Deno.test("legacy active render worker cannot disappear from cleanup",async()=>{
  const out=await invoke({payloadPatch:{unresolved_render_jobs:[LISTING]}});
  assertEquals(out.body.cleanup_complete,false);assertEquals(remaining(out).unresolved_render_jobs,[LISTING]);
});

// A database that cannot answer is not a client mistake. Deadlocks, lock
// timeouts and a missing overload used to reach throwRpc and come back as
// 400 "validation" carrying the raw Postgres text.
for (const [label, message] of [
  ["deadlock", "deadlock detected"],
  ["lock timeout", "canceling statement due to lock timeout"],
  ["missing overload", "function public.prepare_account_deletion(uuid, text, text) does not exist"],
] as const) {
  Deno.test(`snapshot ${label} is a 503 retry that never echoes database text`, async () => {
    const out = await invoke({ prepareDbError: message });
    assertEquals(out.status, 503); assertEquals(out.body.code, "upstream");
    assertEquals(JSON.stringify(out.body).includes("prepare_account_deletion"), false);
    assertEquals(JSON.stringify(out.body).includes(message), false);
    assertEquals(out.calls.some(c => c.method === "DELETE" || c.method === "PATCH"), false);
  });
}
Deno.test("RPnnn refusals from the snapshot keep their own status", async () => {
  const out = await invoke({ prepareError: true });
  assertEquals(out.status, 409); assertEquals(out.body.code, "conflict");
});
Deno.test("final CAS database outage is a 503 and never a reported deletion", async () => {
  const out = await invoke({ finishDbError: "deadlock detected" });
  assertEquals(out.status, 503); assertEquals(out.body.code, "upstream"); assertEquals(out.body.ok, undefined);
  assertEquals(JSON.stringify(out.body).includes("deadlock"), false);
});
Deno.test("sweep database outage on the final CAS is a 503, not a 400", async () => {
  const out = await invoke({ sweep: true, finishDbError: "canceling statement due to lock timeout" });
  assertEquals(out.status, 503); assertEquals(out.body.code, "upstream");
});

// Retained work the DB has parked for a person is reported, not hidden.
const ESCALATION = "provider lease without a cleanup journal 24 hours after the request; no worker can confirm file removal for job "+LISTING+" lease "+LEASE;
Deno.test("escalated request reports manual review and the recorded reason", async () => {
  const out = await invoke({ payloadPatch: { provider_leases: [GPU] }, finishPatch: { manual_review_required: true, escalation_reason: ESCALATION } });
  assertEquals(out.status, 200); assertEquals(out.body.ok, true); assertEquals(out.body.cleanup_complete, false);
  assertEquals(out.body.manual_review_required, true);
  assertEquals((out.body.warnings as string[]).includes(`escalated for manual review: ${ESCALATION}`), true);
  assertEquals(remaining(out).provider_leases, [GPU]);
});
Deno.test("false completed envelope cannot hide an escalation", async () => {
  const out = await invoke({ finishPatch: { cleanup_complete: true, manual_review_required: true, escalation_reason: ESCALATION } });
  assertEquals(out.status, 502); assertEquals(out.body.ok, undefined);
});
Deno.test("malformed escalation reason rejects the completion receipt", async () => {
  const out = await invoke({ finishPatch: { escalation_reason: 42 } });
  assertEquals(out.status, 502);
});
Deno.test("sweep counts a request the DB parked during this pass", async () => {
  const out = await invoke({ sweep: true, payloadPatch: { provider_leases: [GPU] }, finishPatch: { manual_review_required: true, escalation_reason: ESCALATION } });
  assertEquals(out.status, 200); assertEquals(out.body.processed, 1); assertEquals(out.body.escalated, 1);
  assertEquals(remaining(out).provider_leases, [GPU]);
});
Deno.test("sweep leaves an already escalated request alone", async () => {
  const out = await invoke({ sweep: true, claimEscalated: true });
  assertEquals(out.status, 200); assertEquals(out.body.manual_review, 1); assertEquals(out.body.processed, 0); assertEquals(out.body.escalated, 0);
  assertEquals(out.calls.some(c => c.method === "DELETE" || c.method === "PATCH" || c.path.endsWith("/finish_account_deletion")), false);
});
Deno.test("sweep without escalations reports zero", async () => {
  const out = await invoke({ sweep: true });
  assertEquals(out.body.escalated, 0); assertEquals(out.body.processed, 1);
});
