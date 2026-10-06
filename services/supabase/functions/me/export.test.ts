import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { accountDataExport, EXPORT_LIMITS, sanitizeExport } from "./export.ts";
import { HttpError } from "../_shared/http.ts";
const actor = "ea100601-0000-4000-8000-000000000001", other = "ea100601-0000-4000-8000-000000000009", org = "ea100601-0000-4000-8000-000000000002", listing = "ea100601-0000-4000-8000-000000000003";
type Row = Record<string, unknown>;
function fixture() {
  const tables: Record<string, Row[]> = {
    profiles: [{ id: actor, email: "synthetic@example.invalid", name: "Synthetic Owner", apple_refresh_token: "DO_NOT_EXPORT" }],
    memberships: [{ id: "member", user_id: actor, org_id: org, role: "owner" }, { id: "foreign-member", user_id: other, org_id: org, role: "agent" }],
    orgs: [{ id: org, name: "Synthetic Workspace", plan: "free", deleted_at: null, brand_kit: { email: "other-member@example.invalid" } }],
    listings: [{ id: listing, org_id: org, agent_id: actor, deleted_at: null, details: { outline: [1, 2], floorplan_url: "https://renders.rendprop.com/unsafe.jpg" } }, { id: "other-listing", org_id: org, agent_id: other, deleted_at: null, address: "DO_NOT_EXPORT" }],
    studio_documents: [{ user_id: actor, org_id: org, key: "project:one", listing_id: listing, payload: { script: "Authored words", token: "DO_NOT_EXPORT", nested: { storage_key: "DO_NOT_EXPORT" }, media: "https://abc.r2.cloudflarestorage.com/uploads/private?X-Amz-Signature=secret" } }, { user_id: other, org_id: org, key: "other-private", payload: { script: "DO_NOT_EXPORT" } }],
    leads: [{ id: "lead", org_id: org, listing_id: listing, name: "Synthetic Inquiry", extra: { party_size: 3, token: "DO_NOT_EXPORT" } }],
    notification_devices: [{ id: "device", user_id: actor, environment: "production", device_token: "DO_NOT_EXPORT" }],
    apple_subscriptions: [{ original_transaction_id: "synthetic-own", user_id: actor, org_id: org, status: "active", signed_payload: "DO_NOT_EXPORT" }, { original_transaction_id: "synthetic-other", user_id: other, org_id: org, status: "active" }],
    serving_operation_results: [{org_id:org,actor_id:actor,request_key:"synthetic-key",result:{copy:"Authored generated copy",media:"urn:rendprop:r2:renders:private/key",poster:"https://rendprop.com/media/slug/r2/private%2Fkey"}},{org_id:org,actor_id:other,request_key:"other-key",result:{copy:"DO_NOT_EXPORT"}}],
  };
  const calls: { table: string; filters: [string, string[]][]; fields: string; start: number; end: number }[] = [];
  let namedCalls = 0; const unavailable = new Set<string>();
  const state = { named: true, hook: (_table: string, _number: number) => {}, inject: (_table: string, rows: Row[]) => rows };
  const admin = {
    rpc: async (name: string, args: Record<string, unknown>) => { if (name === "effective_plan") { assert(typeof args.p_org === "string" && tables.orgs.some((o) => o.id === args.p_org)); return { data: "free", error: null }; } assertEquals(name, "studio_review_named_account"); assertEquals(args, { p_user: actor }); namedCalls++; return { data: state.named, error: null }; },
    from: (table: string) => {
      let fields = ""; const filters: [string, string[]][] = [], order: string[] = [];
      const q = { select: (f: string, opts: unknown) => { assertEquals(opts, { count: "exact" }); fields = f; return q; }, eq: (column: string, value: string) => { filters.push([column, [value]]); return q; }, in: (column: string, values: string[]) => { assert(values.length <= 100); filters.push([column, values]); return q; }, order: (key: string) => { order.push(key); return q; }, range: async (start: number, end: number) => {
        calls.push({ table, filters, fields, start, end }); state.hook(table, calls.filter((c) => c.table === table).length);
        if (unavailable.has(table)) return { data: null, count: null, error: { code: "42P01", message: "PRIVATE_SCHEMA_DETAIL" } };
        const all = (tables[table] ?? []).filter((row) => filters.every(([column, values]) => values.includes(String(row[column])))).sort((a, b) => order.map((key) => String(a[key]).localeCompare(String(b[key]))).find((n) => n !== 0) ?? 0);
        return { data: state.inject(table, all.slice(start, end + 1)), count: all.length, error: null };
      } }; return q;
    },
  };
  return { tables, calls, state, admin, unavailable, get namedCalls() { return namedCalls; } };
}
Deno.test("account export includes own data across current membership and names exclusions without secrets", async () => {
  const f = fixture(); const response = await accountDataExport(f.admin, actor); const body = await response.text(), value = JSON.parse(body);
  assertEquals(response.headers.get("cache-control"), "private, no-store"); assert(response.headers.get("content-disposition")?.includes('filename="rendprop-account-data.json"'));
  assertEquals(value.manifest.actor_id, actor); assertEquals(value.manifest.truncated, false); assertEquals(value.data.listings.length, 1); assertEquals(value.data.studio_documents.length, 1); assertEquals(value.data.apple_subscriptions.length, 1);
  assertEquals(value.data.workspaces[0].effective_plan, "free"); assertEquals(value.data.workspaces[0].plan_raw, "free"); assert(!("plan" in value.data.workspaces[0]));
  assertEquals(value.data.studio_documents[0].payload.script, "Authored words"); assertEquals(value.data.leads[0].extra.party_size, 3); assert(body.includes("private media link omitted"));
  assert(!body.includes("DO_NOT_EXPORT")); assert(!body.includes("other-member@example.invalid")); assert(!body.includes("X-Amz-Signature")); assert(!body.includes("device_token"));
  assertEquals(value.data.serving_operation_results.length,1);assertEquals(value.data.serving_operation_results[0].result.copy,"Authored generated copy");assert(!body.includes("urn:rendprop:r2:"));assert(!body.includes("/media/slug/r2/"));
  assert(value.manifest.omissions.some((x: Row) => x.collection === "binary_media")); assert(value.manifest.omissions.some((x: Row) => x.collection === "workspace_cost_and_usage_ledger")); assertEquals(f.namedCalls, 3);
  for (const call of f.calls.filter((c) => c.table === "studio_documents")) assert(call.filters.some(([column, values]) => column === "user_id" && values[0] === actor));
});
Deno.test("account export enumerates multiple active workspaces without the selected org header", async () => {
  const f = fixture(); const second = "ea100601-0000-4000-8000-000000000004";
  f.tables.memberships.push({ id: "member-two", user_id: actor, org_id: second, role: "agent" }); f.tables.orgs.push({ id: second, deleted_at: null });
  f.tables.listings.push({ id: "listing-two", org_id: second, agent_id: actor, deleted_at: null });
  const value = await (await accountDataExport(f.admin, actor)).json(); assertEquals(value.data.workspaces.length, 2); assertEquals(value.data.listings.length, 2);
});
Deno.test("account export completes exact ordered pages and partitions long IN filters", async () => {
  const f = fixture(); f.tables.listings = Array.from({ length: 205 }, (_, n) => ({ id: `listing-${String(n).padStart(4, "0")}`, org_id: org, agent_id: actor, deleted_at: null }));
  f.tables.studio_documents = []; f.tables.leads = f.tables.listings.map((l, n) => ({ id: `lead-${String(n).padStart(4, "0")}`, org_id: org, listing_id: l.id }));
  const value = await (await accountDataExport(f.admin, actor, { ...EXPORT_LIMITS, page: 37 })).json(); assertEquals(value.data.listings.length, 205); assertEquals(value.data.leads.length, 205);
  assert(f.calls.some((c) => c.table === "listings" && c.start === 185)); assert(f.calls.every((c) => c.filters.every(([, values]) => values.length <= 100)));
});
Deno.test("account export refuses foreign actor, workspace, listing and asset receipts independently of DB filters", async () => {
  for (const [table, malicious] of [["profiles", { id: other }], ["memberships", { id: "injected", user_id: other, org_id: org }], ["studio_documents", { user_id: other, org_id: org, key: "injected" }], ["studio_documents", { user_id: actor, org_id: other, key: "injected" }], ["leads", { id: "injected", listing_id: "other-listing", org_id: org }], ["leads", { id: "injected", listing_id: listing, org_id: other }]] as const) {
    const f = fixture(); f.state.inject = (name, rows) => name === table ? [malicious] : rows;
    await assertRejects(() => accountDataExport(f.admin, actor), HttpError);
  }
});
Deno.test("account export detects deletion, membership removal, org deletion and assignment withdrawal during assembly", async () => {
  for (const change of ["deletion", "membership", "org", "assignment", "referenced-listing"]) {
    const f = fixture(); f.state.hook = (table) => { if (table === "deletion_requests") {
      if (change === "deletion") f.state.named = false;
      if (change === "membership") f.tables.memberships = [];
      if (change === "org") f.tables.orgs[0].deleted_at = "2026-10-06T00:00:00Z";
      if (change === "assignment") f.tables.listings[0].agent_id = other;
      if (change === "referenced-listing") f.tables.listings[0].deleted_at = "2026-10-06T00:00:00Z";
    } };
    await assertRejects(() => accountDataExport(f.admin, actor), HttpError);
  }
});
Deno.test("account export rejects stale portfolio assignment and unavailable authored listing", async () => {
  for (const mode of ["portfolio", "document"]) { const f = fixture(); if (mode === "portfolio") f.tables.member_portfolios = [{ id: "portfolio", user_id: actor, org_id: org, listing_ids: ["other-listing"] }]; else f.tables.studio_documents[0].listing_id = "missing"; await assertRejects(() => accountDataExport(f.admin, actor), HttpError); }
});
Deno.test("account export supports author-owned collaborator work without exporting collaborator inventory", async () => {
  const f = fixture(); f.tables.studio_documents[0].listing_id = "other-listing";
  const value = await (await accountDataExport(f.admin, actor)).json(); assertEquals(value.data.studio_documents.length, 1); assertEquals(value.data.listings.map((l: Row) => l.id), [listing]);
});
Deno.test("account export names a missing optional schema but refuses core schema outage", async () => {
  const f = fixture(); f.unavailable.add("studio_presenter_jobs"); const value = await (await accountDataExport(f.admin, actor)).json(); assert(!("studio_presenter_jobs" in value.data)); assert(value.manifest.omissions.some((x: Row) => x.collection === "studio_presenter_jobs")); assert(!JSON.stringify(value).includes("PRIVATE_SCHEMA_DETAIL"));
  f.unavailable.add("profiles"); await assertRejects(() => accountDataExport(f.admin, actor), HttpError, "temporarily unavailable");
});
Deno.test("account export reports explicit byte, row, query and per-collection overflow without truncation", async () => {
  for (const limits of [{ bytes: 100 }, { rows: 1 }, { collectionRows: 0 }, { queries: 1 }]) { const f = fixture(); try { await accountDataExport(f.admin, actor, { ...EXPORT_LIMITS, ...limits }); throw Error("accepted overflow"); } catch (e) { assert(e instanceof HttpError); assertEquals(e.status, 413); } }
});
Deno.test("account export detects shifting pagination counts and duplicate ordered keys", async () => {
  for (const mode of ["count", "duplicate"]) { const f = fixture(); f.tables.studio_documents = [{ user_id: actor, org_id: org, key: "one" }, { user_id: actor, org_id: org, key: "two" }]; f.state.hook = (table, n) => { if (table === "studio_documents" && n === 2 && mode === "count") f.tables.studio_documents.pop(); }; f.state.inject = (table, rows) => table === "studio_documents" && mode === "duplicate" ? rows.map((r) => ({ ...r, key: "one" })) : rows; await assertRejects(() => accountDataExport(f.admin, actor, { ...EXPORT_LIMITS, page: 1 }), HttpError); }
});
Deno.test("saved content redaction preserves authored text and external URLs with bounded nesting", () => {
  assertEquals(sanitizeExport({ words: "Call the client https://example.invalid/info", bearer_token: "secret", source: "https://x.invalid/media?token=secret", nested: { reference_snapshot: { private: "secret" } } }), { words: "Call the client https://example.invalid/info", source: "[private media link omitted]", nested: {} });
});

async function actualRoute() {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url)), start = source.indexOf("Deno.serve(async (req) => {"), end = source.indexOf("\n});", start) + 5;
  const body = source.slice(start, end).trimEnd().replace("Deno.serve(async (req) => {", "export const handler=async(req:Request)=>{").replace(/\n\}\);$/, "\n};");
  const code = `import{HttpError,assert,json,pathSegments,respondError}from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};import{handleOptions}from ${JSON.stringify(new URL("../_shared/cors.ts", import.meta.url).href)};export const state:any={actor:${JSON.stringify(actor)},calls:[]};const getUser=async()=>{if(!state.actor)throw new HttpError(401,"Sign in required");return{id:state.actor}};const adminClient=()=>({});const accountDataExport=async(admin:any,id:string)=>{state.calls.push(id);return new Response(JSON.stringify({actor:id}))};${body}`;
  return import("data:application/typescript;base64," + btoa(String.fromCharCode(...new TextEncoder().encode(code))));
}
Deno.test("actual authenticated /me export dispatch is GET-only, workspace-independent and ignores injected identity", async () => {
  const f = await actualRoute(); const r = await f.handler(new Request(`https://fixture.invalid/me/export?user_id=${other}&org_id=${other}`, { headers: { "X-Org-Id": other } })); assertEquals(r.status, 200); assertEquals(await r.json(), { actor }); assertEquals(f.state.calls, [actor]);
  f.state.calls = []; assertEquals((await f.handler(new Request("https://fixture.invalid/me/export", { method: "POST" }))).status, 405); assertEquals(f.state.calls, []);
  f.state.actor = null; assertEquals((await f.handler(new Request("https://fixture.invalid/me/export"))).status, 401);
});
