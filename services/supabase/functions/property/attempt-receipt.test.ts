// Exact property handler and actual RentCast/ledger/receipt/library helpers.
// Auth, DB and provider transport are closed synthetic boundaries, not invoices.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const actor = "a9100000-0000-4000-8000-000000000001", org = "a9100000-0000-4000-8000-000000000002", attemptId = "a9100000-0000-4000-8000-000000000003";
const address = "PRIVATE-ADDRESS-SENTINEL", operation = "PRIVATE-OPERATION-KEY-SENTINEL";
const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const begin = source.indexOf("Deno.serve("); assert(begin >= 0 && source.trimEnd().endsWith("});"));
const handler = source.slice(begin + "Deno.serve(".length).trimEnd().slice(0, -2);
const actual = (path: string) => JSON.stringify(new URL(path, import.meta.url).href);
const mod = await import("data:application/typescript," + encodeURIComponent(`
  import {HttpError,assert,json,respondError} from ${actual("../_shared/http.ts")};
  import {requireLibraryWrite,libraryBillingOrg} from ${actual("../_shared/library-access.ts")};
  import {recordAppAiCost} from ${actual("../_shared/ledger.ts")};
  import {addressKey,hasSubstance,PropertyLookupFailure,type PropertyLookupResponse,type PropertyProvider} from ${actual("../_shared/property/provider.ts")};
  import {rentcast} from ${actual("../_shared/property/rentcast.ts")};
  import {beginPropertyAttempt,finishPropertyAttempt,recordPropertyAttemptCost} from ${actual("../_shared/provider-attempt-receipt.ts")};
  const PROVIDERS:PropertyProvider[]=[rentcast],CACHE_DAYS=30,RATE_MAX=40,RATE_WINDOW_S=3600;
  export function make(state:any){
    const handleOptions=()=>new Response(null,{status:204}),preferredOrg=()=>${JSON.stringify(org)};
    const getUser=async(req:Request)=>{if(state.authFailure||!req.headers.has("authorization"))throw new HttpError(401,"Invalid or expired token");return{id:${JSON.stringify(actor)},is_anonymous:state.anonymous};};
    const orgForUser=async()=>${JSON.stringify(org)};
    const assertPaidAiIdentity=async(user:any)=>{if(user.is_anonymous)throw new HttpError(403,"Sign in before property lookup");};
    const durableRateLimit=async()=>state.rate;
    const adminClient=()=>state.admin;
    return ${handler};
  }
`));

async function fixture() {
  const state: any = { rate: true, anonymous: false, authFailure: false, writable: true, providerStatus: 200, transportUnknown: false, invalid: false, unreadableBody: false, beginFailure: false, finishFailure: false, referenceOverloadMissing: false, supplierHeaders: {}, ledgerFailure: false, cache: null, supplierCalls: 0, ledgers: [], ledgerAttempts: [], rpcs: [], events: [], receipts: new Map(), admin: null };
  state.admin = {
    async rpc(name: string, args: any) {
      state.rpcs.push({ name, args }); state.events.push(name);
      if (name === "library_access") return { data: { actor_id: actor, org_id: org, library_owner_user_id: actor, role: "owner", access_mode: "own", can_read: true, can_write: state.writable, can_manage_subscription: true, billing_org_id: org, team_org_id: null }, error: null };
      if (name === "library_actor_billing_org") return { data: org, error: null };
      if (name === "provider_attempt_begin") {
        if (state.beginFailure) return { data: null, error: { message: "closed-db-failure" } };
        let row = state.receipts.get(args.p_operation_sha256), dispatch = false;
        if (row && row.input_sha256 !== args.p_input_sha256) return { data: null, error: { message: "RP409: Provider operation inputs are immutable" } };
        if (!row) { row = { attempt_id: attemptId, actor_id: args.p_actor, org_id: args.p_org, operation_sha256: args.p_operation_sha256, input_sha256: args.p_input_sha256, outcome: "intent" }; state.receipts.set(args.p_operation_sha256, row); dispatch = true; }
        return { data: { ...row, dispatch }, error: null };
      }
      if (name === "provider_attempt_finish") {
        if (state.finishFailure) return { data: null, error: { message: "lost-terminal-write" } };
        // A schema before 20261017190000 has only the eight-argument RPC: PostgREST answers PGRST202 for nine named keys.
        if (state.referenceOverloadMissing && "p_provider_request_ref" in args) return { data: null, error: { code: "PGRST202", message: "Could not find the function public.provider_attempt_finish(p_actor, p_attempt, p_estimated_cents, p_http_status, p_ledger_status, p_org, p_outcome, p_provider_request_id, p_provider_request_ref) in the schema cache" } };
        const row = [...state.receipts.values()].find((r: any) => r.attempt_id === args.p_attempt);
        Object.assign(row, { outcome: args.p_outcome, status: args.p_http_status, estimatedCents: args.p_estimated_cents, ledgerStatus: args.p_ledger_status, requestId: args.p_provider_request_id, requestRef: "p_provider_request_ref" in args ? args.p_provider_request_ref : "absent" });
        return { data: { saved: true, attempt_id: args.p_attempt }, error: null };
      }
      throw new Error("Unexpected closed RPC " + name);
    },
    from(table: string) {
      if (table === "cost_ledger") return { async insert(row: unknown) { state.ledgerAttempts.push(row); if (state.ledgerFailure) return { error: { code: "closed-fixture", message: "ledger unavailable" } }; state.ledgers.push(row); return { error: null }; } };
      assertEquals(table, "property_lookups");
      const q: any = { select: () => q, eq: () => q, gt: () => q, maybeSingle: async () => ({ data: state.cache, error: null }), upsert: async (row: any) => { state.cache = row; return { error: null }; } }; return q;
    },
  };
  const previousFetch = globalThis.fetch, previousKey = Deno.env.get("RENTCAST_API_KEY"); Deno.env.set("RENTCAST_API_KEY", "inert-property-fixture");
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init); assertEquals(new URL(req.url).origin, "https://api.rentcast.io"); assertEquals(req.method, "GET"); state.supplierCalls++; state.events.push("supplier");
    if (state.transportUnknown) throw new DOMException("PRIVATE-TRANSPORT-SENTINEL", "AbortError");
    if (state.unreadableBody) return new Response(new ReadableStream({ start(controller) { controller.error(new DOMException("PRIVATE-BODY-SENTINEL", "AbortError")); } }), { status: 200, headers: { "x-request-id": attemptId } });
    if (state.providerStatus === 404) return new Response(null, { status: 404, headers: state.supplierHeaders });
    return Response.json(state.invalid ? { error: address } : state.providerStatus !== 200 ? { message: address } : [{ bedrooms: 3, squareFootage: 1500 }], { status: state.providerStatus, headers: state.supplierHeaders });
  };
  return { state, run: (requestKey = operation) => mod.make(state)(new Request("https://closed-property.invalid/property?address=" + address, { headers: { authorization: "Bearer inert-fixture", "idempotency-key": requestKey } })), close: () => { globalThis.fetch = previousFetch; previousKey === undefined ? Deno.env.delete("RENTCAST_API_KEY") : Deno.env.set("RENTCAST_API_KEY", previousKey); } };
}
async function check(run: (f: Awaited<ReturnType<typeof fixture>>) => Promise<void>) { const f = await fixture(); try { await run(f); } finally { f.close(); } }

Deno.test("actual property route persists intent before dispatch and books only its unchanged hit/miss catalog estimate", () => check(async f => {
  const res = await f.run(); assertEquals(res.status, 200); assertEquals((await res.json()).facts.beds, 3);
  assertEquals(f.state.supplierCalls, 1); assert(f.state.events.indexOf("provider_attempt_begin") >= 0 && f.state.events.indexOf("provider_attempt_begin") < f.state.events.indexOf("supplier")); assertEquals(f.state.receipts.size, 1); assertEquals(f.state.ledgers.length, 1);
  const row: any = [...f.state.receipts.values()][0]; assertEquals(row.outcome, "hit"); assertEquals(row.estimatedCents, 7); assertEquals(row.ledgerStatus, "recorded");
  assertEquals(f.state.ledgers[0].total_cents, 7); assertEquals(f.state.ledgers[0].meta.provider_attempt_id, attemptId);
  assert(!JSON.stringify(f.state.rpcs).includes(address)); assert(!JSON.stringify(f.state.rpcs).includes(operation));
  assertEquals((await f.run()).status, 200); assertEquals(f.state.supplierCalls, 1, "A real cache hit makes no supplier call");
}));
Deno.test("journal failure, existing auth/library/rate refusal and malformed operation key prevent supplier dispatch", () => check(async f => {
  for (const option of ["beginFailure", "authFailure", "anonymous"]) {
    f.state[option] = true; const res = await f.run(); assert(res.status >= 400); assertEquals(f.state.supplierCalls, 0); f.state[option] = false;
  }
  assertEquals((await f.run("bad")).status, 400); assertEquals(f.state.supplierCalls, 0);
  for (const option of ["writable", "rate"]) { f.state[option] = false; assert((await f.run()).status >= 400); assertEquals(f.state.supplierCalls, 0); f.state[option] = true; }
}));
Deno.test("actual property auth/rate/server/malformed and transport outcomes never masquerade as no_record or booked bills", async () => {
  for (const option of [{ providerStatus: 401 }, { providerStatus: 429 }, { providerStatus: 500 }, { invalid: true }, { transportUnknown: true }]) await check(async f => {
    Object.assign(f.state, option); const res = await f.run(); assertEquals(res.status, 502); const body = await res.json(); assertEquals(body.facts, undefined);
    assertEquals(f.state.supplierCalls, 1); assertEquals(f.state.ledgers.length, 0); assertEquals(f.state.cache, null);
    const row: any = [...f.state.receipts.values()][0]; assert(row); assertEquals(row.estimatedCents, null); assertEquals(row.ledgerStatus, "not_booked");
    assertEquals((await f.run()).status, 409); assertEquals(f.state.supplierCalls, 1, "An unresolved or failed operation is never re-dispatched");
  });
});
Deno.test("genuine404 is a recorded no_record, while lost outcome/ledger writes preserve known facts and unknown accounting debt", async () => {
  await check(async f => { f.state.providerStatus = 404; const res = await f.run(); assertEquals(res.status, 200); assertEquals((await res.json()).facts, null); assertEquals([...f.state.receipts.values()][0].outcome, "no_record"); assertEquals(f.state.ledgers[0].total_cents, 7); });
  await check(async f => { f.state.finishFailure = true; assertEquals((await f.run()).status, 200); assertEquals([...f.state.receipts.values()][0].outcome, "intent"); assertEquals(f.state.supplierCalls, 1); });
  await check(async f => { f.state.ledgerFailure = true; assertEquals((await f.run()).status, 200); const row: any = [...f.state.receipts.values()][0]; assertEquals(row.outcome, "hit"); assertEquals(row.ledgerStatus, "unconfirmed"); assertEquals(row.estimatedCents, 7); assertEquals((await f.run()).status, 200); assertEquals(f.state.supplierCalls, 1); assertEquals(f.state.ledgerAttempts.length, 1); });
});
Deno.test("successful headers with an unreadable body retain known HTTP evidence but no invented miss or cost", () => check(async f => {
  f.state.unreadableBody = true;
  const res = await f.run(); assertEquals(res.status, 502);
  assertEquals((await res.json()).facts, undefined); assertEquals(f.state.supplierCalls, 1);
  const row: any = [...f.state.receipts.values()][0];
  assertEquals(row.outcome, "invalid_response"); assertEquals(row.status, 200);
  assertEquals(row.estimatedCents, null); assertEquals(row.ledgerStatus, "not_booked");
  const terminal = f.state.rpcs.find((r: any) => r.name === "provider_attempt_finish");
  assertEquals(terminal.args.p_provider_request_id, attemptId); assertEquals(terminal.args.p_provider_request_ref, null);
  assertEquals(f.state.ledgers.length, 0); assertEquals(f.state.cache, null);
  assert(!JSON.stringify(f.state.rpcs).includes("PRIVATE-BODY-SENTINEL"));
  assertEquals((await f.run()).status, 409); assertEquals(f.state.supplierCalls, 1);
}));
Deno.test("RentCast's Google Frontend trace id reaches the receipt as the supplier reference; absent or unbounded headers stay null", async () => {
  const trace = "2c3738f2d4c4b4984f9f9b36a137d515";
  for (const [headers, requestId, requestRef, status] of [
    [{ "x-cloud-trace-context": trace.toUpperCase() + "/1234567890;o=1" }, null, trace, 200],
    [{ "x-cloud-trace-context": trace }, null, trace, 404],
    [{ "x-request-id": attemptId, "x-cloud-trace-context": trace }, attemptId, null, 200],
    [{ "x-cloud-trace-context": "https://private.invalid/PRIVATE-URL-SENTINEL" }, null, null, 200],
    [{}, null, null, 200],
  ] as const) await check(async f => {
    f.state.supplierHeaders = headers; f.state.providerStatus = status;
    assertEquals((await f.run()).status, 200);
    const terminal = f.state.rpcs.filter((r: any) => r.name === "provider_attempt_finish");
    assertEquals(terminal.length, 1, "One terminal write per outcome");
    assertEquals(terminal[0].args.p_provider_request_id, requestId); assertEquals(terminal[0].args.p_provider_request_ref, requestRef);
    const row: any = [...f.state.receipts.values()][0]; assertEquals(row.outcome, status === 404 ? "no_record" : "hit"); assertEquals(row.requestRef, requestRef);
    assert(!JSON.stringify(f.state.rpcs).includes("PRIVATE-URL-SENTINEL"));
  });
});
Deno.test("a schema without the reference overload still records the same outcome through the legacy RPC; other finish errors are never retried", async () => {
  await check(async f => {
    f.state.referenceOverloadMissing = true; f.state.supplierHeaders = { "x-cloud-trace-context": "2c3738f2d4c4b4984f9f9b36a137d515" };
    assertEquals((await f.run()).status, 200);
    const terminal = f.state.rpcs.filter((r: any) => r.name === "provider_attempt_finish");
    assertEquals(terminal.length, 2); assert("p_provider_request_ref" in terminal[0].args); assert(!("p_provider_request_ref" in terminal[1].args));
    assertEquals(terminal[1].args.p_outcome, "hit"); assertEquals(terminal[1].args.p_estimated_cents, 7); assertEquals(terminal[1].args.p_ledger_status, "recorded");
    const row: any = [...f.state.receipts.values()][0]; assertEquals(row.outcome, "hit"); assertEquals(row.requestRef, "absent");
    assertEquals(f.state.supplierCalls, 1);
  });
  await check(async f => {
    f.state.finishFailure = true; assertEquals((await f.run()).status, 200);
    assertEquals(f.state.rpcs.filter((r: any) => r.name === "provider_attempt_finish").length, 1, "A lost terminal write is not retried");
    assertEquals([...f.state.receipts.values()][0].outcome, "intent");
  });
});
