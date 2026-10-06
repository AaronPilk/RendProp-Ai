import { createRoot } from "react-dom/client";
import type { Session, AuthChangeEvent } from "@supabase/supabase-js";
import App from "../../src/App";
import { createStudioServices, type StudioAuth } from "../../src/data";
import "../../src/styles.css";

// Separately bundled test entry, never imported by src/main.tsx. No real Auth,
// provider redirect, customer fixture, remote request or secret is used here.
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const ORG = "33333333-3333-4333-8333-333333333333";
const OTHER = "44444444-4444-4444-8444-444444444444";
const sharedProperty = new URLSearchParams(window.location.search).has("sharedProperty");
const factsFixture = new URLSearchParams(window.location.search).has("facts");
let user = A;
let mode = "ok";
let callbacks: (event: AuthChangeEvent, session: Session | null) => void = () => {};
let release: (() => void) | undefined;
const documents = new Map<string, unknown>();
const contacts = new Map<string, Record<string, unknown>>();
let failContactSave = false;
let holdContactSave = false;
let releaseContactSave: (() => void) | undefined;
let failFactsSave = false, holdFactsSave = false, mismatchFactsReceipt = false;
let releaseFactsSave: (() => void) | undefined;
// Every account/workspace has its own property; noProperties covers local-first creation.
const listingRows: Record<string, unknown>[] = [A, B].flatMap((actor, actorIndex) => [ORG, OTHER].map((orgId, orgIndex) => ({
  id: `55555555-5555-4555-8555-5555555555${actorIndex}${orgIndex}`,
  org_id: orgId, agent_id: actor, space_type: "real_estate", address: `Isolated property ${actorIndex + 1}-${orgIndex + 1}`,
  tagline: null, details: {}, status: "draft", created_at: "2026-09-22T00:00:00Z", deleted_at: null,
  main_photo_key: null, beds: null, baths: null, sqft: null, price_cents: null,
})));
if (new URLSearchParams(window.location.search).has("secondProperty")) listingRows.push({
  ...listingRows[0], id:"66666666-6666-4666-8666-666666666666", address:"Second property for navigation checks",
});
if (new URLSearchParams(window.location.search).has("noProperties")) listingRows.length = 0;
if (factsFixture && listingRows.length) Object.assign(listingRows[0], { tagline: "", beds: 0, baths: null, sqft: null, price_cents: 0, sold_at: null, details: { floorplan_asset_id: "fixture-office-plan", imported_nested: { null_value: null, number_value: 20 }, hours: null, capacitySeated: 20, allow_indexing: false } });
const calls: { path: string; org?: string | null; method: string; body?: unknown }[] = [];
const session = (): Session => ({
  access_token: "isolated-fixture-not-a-token",
  refresh_token: "isolated-fixture-not-a-refresh-token",
  token_type: "bearer", expires_in: 3600,
  user: { id: user, email: "fixture@example.invalid", is_anonymous: false,
    aud: "authenticated", app_metadata: {}, user_metadata: {}, created_at: "2026-09-12T00:00:00Z" },
});
const auth: StudioAuth = {
  getSession: async () => ({ data: { session: session() }, error: null }),
  refreshSession: async () => ({ data: { session: session() }, error: null }),
  onAuthStateChange(callback) { callbacks = callback; return { data: { subscription: { unsubscribe() {} } } }; },
  async signInWithOAuth() { throw new Error("No provider operation is permitted in this fixture"); },
  async signOut() { callbacks("SIGNED_OUT", null); return { error: null }; },
};
const publicCards = new Map<string, Record<string,string>>();
const fetcher: typeof fetch = async (input, options) => {
  const url = new URL(String(input));
  const org = new Headers(options?.headers).get("X-Org-Id") ?? ORG;
  const actor = user;
  calls.push({ path: url.pathname, org, method: options?.method ?? "GET", ...(options?.body ? { body: JSON.parse(String(options.body)) } : {}) });
  if (url.pathname === "/functions/v1/studio/projects") return Response.json({projects:[]});
  if (url.pathname === "/functions/v1/studio/project-media" && options?.method !== "POST") return Response.json({media:null});
  if (url.pathname === "/functions/v1/studio/media-analysis" && options?.method !== "POST") return Response.json({available:false});
  if ((url.pathname === "/functions/v1/studio/edit-plan" || url.pathname === "/functions/v1/studio/prompt-enhancement") && options?.method !== "POST") return Response.json({available:false,reason:"disabled",supportedOperations:[]});
  if (url.pathname === "/functions/v1/spatial/capability") return Response.json({enabled:false});
  if (url.pathname === "/functions/v1/studio/creative-results") return Response.json({results:[],next_offset:null});
  if (url.pathname === "/functions/v1/studio/presenter/jobs" && options?.method !== "POST") return Response.json({org_id:org,listing_id:url.searchParams.get("listing_id"),quotes:[],jobs:[],runtime:{available:false,code:"enterprise_contract_required",reason:"AI generation is not connected."}});
  if (url.pathname === "/functions/v1/studio/presenter" && options?.method !== "POST") return Response.json({
    org_id:org, listing_id:url.searchParams.get("listing_id"), profiles:[], drafts:[], reference_candidates:[], source_candidates:[],
    permissions:{can_save_profile:true,can_create_draft:true},
    runtime:{available:false,code:"enterprise_contract_required",reason:"AI generation is not enabled. Save your presenter setup or edit original footage."},
  });
  if (calls.length > 250) throw new Error("Unexpected request loop");
  if (url.pathname === "/functions/v1/listings" && options?.method === "POST") {
    const body = JSON.parse(String(options.body));
    const row = {id:crypto.randomUUID(),org_id:org,agent_id:actor,space_type:"real_estate",address:"",tagline:null,details:{},status:"draft",created_at:new Date().toISOString(),deleted_at:null,main_photo_key:null,beds:null,baths:null,sqft:null,price_cents:null,...body};
    listingRows.push(row);return Response.json(row,{status:201});
  }
  if (url.pathname.startsWith("/functions/v1/listings/") && options?.method === "PATCH") return Response.json({error:"Upgrade before saving ordinary listing facts."},{status:426});
  if (url.pathname.endsWith("/facts") && options?.method === "PUT") {
    const id = url.pathname.split("/").at(-2)!;
    const row = listingRows.find(row => row.id === id && row.org_id === org && (row.agent_id === actor || sharedProperty && row.id === listingRows[0].id));
    if (!row) return Response.json({error:"Foreign fixture property"},{status:403});
    if (failFactsSave) { failFactsSave = false; return Response.json({error:"Synthetic save failed"},{status:503}); }
    if (holdFactsSave) await new Promise<void>(resolve => { releaseFactsSave = resolve; });
    const body = JSON.parse(String(options.body)), fields = ["address","tagline","space_type","beds","baths","sqft","price_cents","status","sold_at"];
    if (JSON.stringify(Object.keys(body).sort()) !== JSON.stringify(["changes","details_changes","details_expected","expected"]) || JSON.stringify(Object.keys(body.expected).sort()) !== JSON.stringify(Object.keys(body.changes).sort()) || !Object.keys(body.changes).length || Object.keys(body.changes).some(key => !fields.includes(key)) || Object.keys(body.details_expected).length || Object.keys(body.details_changes).length) return Response.json({error:"Invalid explicit fixture edit"},{status:400});
    const before = structuredClone(row);
    for (const [key,value] of Object.entries(body.changes)) if ((row[key] ?? null) !== body.expected[key] && (row[key] ?? null) !== value) return Response.json({error:"Facts changed"},{status:409});
    Object.assign(row,body.changes);
    if (mismatchFactsReceipt) { mismatchFactsReceipt = false; return Response.json(before); }
    return Response.json(row);
  }
  if (url.pathname.endsWith("/client-contact")) {
    const id = url.pathname.split("/").at(-2)!;
    if (!listingRows.some(row => row.id === id && row.org_id === org && (row.agent_id === actor || sharedProperty && row.id === listingRows[0].id))) return Response.json({error:"Foreign fixture property"}, {status:403});
    const contactKey = `${sharedProperty ? "shared" : actor}:${org}:${id}`;
    if (options?.method !== "PUT") return Response.json({contact:contacts.get(contactKey) ?? null});
    if (failContactSave) { failContactSave = false; return Response.json({error:"Synthetic contact save failed. Your changes are kept."}, {status:503}); }
    if (holdContactSave) await new Promise<void>(resolve => { releaseContactSave = resolve; });
    const body = JSON.parse(String(options.body)), saved = contacts.get(contactKey);
    if (body.expected_revision !== (saved?.revision ?? 0)) return Response.json({error:"Contact revision changed"}, {status:409});
    const contact = {...body,listing_id:id,revision:Number(body.expected_revision)+1,updated_at:new Date().toISOString()};
    contacts.set(contactKey, contact); return Response.json({contact});
  }
  if (url.pathname === "/functions/v1/studio/listing-state") return Response.json({org_id:org,listing_id:url.searchParams.get("listing_id"),assets:[],photos:[],jobs:[],renders:[],chapters:[],next_offset:null});
  if (url.pathname === "/functions/v1/studio/media") return Response.json({org_id:org,listing_id:url.searchParams.get("listing_id"),photos:[],videos:[],next_offset:null,unavailable_count:0});
  if (url.pathname === "/functions/v1/studio/documents") {
    const body=options?.body ? JSON.parse(String(options.body)) : null;
    const key=body?.key ?? url.searchParams.get("key"); const storageKey=`${actor}:${org}:${key}`;
    if(body) { const existing=documents.get(storageKey) as {revision:number}|undefined;
      if(body.expected_revision!==(existing?.revision??0))return Response.json({error:"Conflict"},{status:409});
      documents.set(storageKey,{...body,revision:(existing?.revision??0)+1,updated_at:new Date().toISOString()});
    }
    return Response.json({document:documents.get(storageKey)??null});
  }
  if (url.pathname === "/rest/v1/memberships") {
    if (mode === "hold") await new Promise<void>((resolve) => {
      const done = () => { options?.signal?.removeEventListener("abort", done); resolve(); };
      release = done;
      options?.signal?.addEventListener("abort", done, { once: true });
    });
    if (mode === "403" || mode === "503") return Response.json({}, { status: Number(mode) });
    return Response.json([ORG, OTHER].map((id) => ({ user_id: actor, org_id: id, role: "owner",
      orgs: { id, name: id === ORG ? "Fixture business" : "Second business", space_type: "real_estate", deleted_at: null } })), { headers: { "Content-Range": "0-1/2" } });
  }
  if (url.pathname === "/functions/v1/me/card") {
    const card = publicCards.get(actor) ?? {};
    if (options?.method === "PATCH") { const b = JSON.parse(String(options.body)); for (const [key, value] of Object.entries(b.changes)) { const e = b.expected[key]; if (Object.hasOwn(card,key) !== e.present || e.present && card[key] !== e.value) return Response.json({error:"Personal card changed"},{status:409}); if(value===null) delete card[key]; else card[key]=String(value); } publicCards.set(actor,card); }
    const {space_type,...public_card}=card; return Response.json({ok:true,user_id:actor,space_type:space_type??null,public_card:publicCards.has(actor)?public_card:null});
  }
  if (url.pathname === "/functions/v1/me/portfolio") return Response.json({ok:true,user_id:actor,org_id:org,id:null,revision:0,listing_ids:[],portfolio_url:null});
  if (url.pathname === "/functions/v1/me") return Response.json({
    user: { id: actor, name: actor === A ? "  " : "Fixture B", email: "fixture@example.invalid", avatar_url: null },
    org: { id: org, name: org === ORG ? "Fixture business" : "Second business", handle: null, space_type: "real_estate" },
    plan: "free", plan_raw: "trial", trial_ends_at: null, plan_expires_at: null,
    usage: { listings: 0, leads: 0, leads_new: 0, renders: 0 },
  });
  if (url.pathname === "/rest/v1/listings") {
    if (url.searchParams.get("org_id") !== `eq.${org}`) throw new Error("Missing selected workspace filter");
    const selectedRows=listingRows.filter(row=>row.org_id===org&&(row.agent_id===actor||sharedProperty&&row.id===listingRows[0].id));
    return Response.json(selectedRows, { headers: { "Content-Range": selectedRows.length ? `0-${selectedRows.length-1}/${selectedRows.length}` : "*/0" } });
  }
  throw new Error(`Unexpected fixture request: ${url.pathname}`);
};
const servicesFactory = () => createStudioServices({
  supabaseUrl: "https://studio-isolated-fixture.supabase.co",
  publishableKey: "sb_publishable_ISOLATED_FIXTURE_NOT_REAL",
  redirectTo: `${window.location.origin}/`,
}, { auth, fetch: fetcher, readTimeoutMs: 5000 });
Object.assign(window, { studioFixture: {
  setMode(next: string) { mode = next; },
  release() { mode = "ok"; release?.(); release = undefined; },
  switchUser(next: "A" | "B") { user = next === "A" ? A : B; callbacks("SIGNED_IN", session()); },
  failContactSave() { failContactSave = true; },
  holdContactSave() { holdContactSave = true; },
  releaseContactSave() { holdContactSave = false; releaseContactSave?.(); releaseContactSave = undefined; },
  phoneFacts(changes: Record<string, unknown>, id = listingRows[0]?.id) { const row = listingRows.find(row => row.id === id); if (!row) throw new Error("Unknown fixture property"); Object.assign(row, changes); },
  failFactsSave() { failFactsSave = true; },
  holdFactsSave() { holdFactsSave = true; },
  releaseFactsSave() { holdFactsSave = false; releaseFactsSave?.(); releaseFactsSave = undefined; },
  mismatchFactsReceipt() { mismatchFactsReceipt = true; },
  listingRows() { return structuredClone(listingRows); },
  legacyFactsWrite() { return services.api(`/functions/v1/listings/${listingRows[0].id}`, { orgId: ORG, method: "PATCH", body: { address: "Rejected legacy broad write" } }).then(() => ({ accepted: true }), error => ({ accepted: false, status: error.status })); },
  calls() { return calls.slice(); },
} });
const services = servicesFactory();
createRoot(document.getElementById("root")!).render(<App servicesFactory={() => services} />);
