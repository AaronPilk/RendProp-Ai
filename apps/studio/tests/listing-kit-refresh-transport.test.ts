import assert from "node:assert/strict";
import test from "node:test";
import type { Session, AuthChangeEvent } from "@supabase/auth-js";
import { createStudioServices, type StudioAuth } from "../src/data/services";
import { loadKit } from "../src/features/listings/delivery-kit";

const ACTOR = "10000000-0000-4000-8000-000000000001", OTHER_ACTOR = "10000000-0000-4000-8000-000000000002";
const LIBRARY = "20000000-0000-4000-8000-000000000001", OTHER_LIBRARY = "20000000-0000-4000-8000-000000000002";
const LISTING = "30000000-0000-4000-8000-000000000001";
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
function session(user = ACTOR): Session {
  return { access_token: "closed-kit-fixture-token", refresh_token: "closed-kit-fixture-refresh", expires_in: 3600, token_type: "bearer", user: { id: user, aud: "authenticated", created_at: "2026-10-16T00:00:00Z", app_metadata: {}, user_metadata: {} } };
}
/** The real service, request gates and kit decoder run over a closed GET-only transport. */
function fixture() {
  let current = session(), selected = LIBRARY, kitStatus = 200;
  let callback: (event: AuthChangeEvent, value: Session | null) => void = () => {};
  const auth: StudioAuth = {
    getSession: async () => ({ data: { session: current }, error: null }), refreshSession: async () => ({ data: { session: current }, error: null }),
    signInWithOAuth: async () => ({ error: null }), signOut: async () => ({ error: null }),
    onAuthStateChange: next => { callback = next; return { data: { subscription: { unsubscribe() {} } } }; },
  };
  const directory = () => ({ actor_id: current.user.id, own_org_id: LIBRARY, billing_org_id: LIBRARY, active_org_id: selected, can_switch_agent_libraries: true, workspaces: [
    { id: LIBRARY, name: "Own library", role: "owner", access_mode: "own", library_owner_user_id: current.user.id, billing_org_id: LIBRARY, can_read: true, can_write: true, can_manage_subscription: true },
    { id: OTHER_LIBRARY, name: "Other library", role: "team_owner", access_mode: "team_owner", library_owner_user_id: OTHER_ACTOR, billing_org_id: LIBRARY, can_read: true, can_write: true, can_manage_subscription: false },
  ] });
  const me = () => ({ user: { id: current.user.id, email: null, name: null, avatar_url: null }, org: { id: selected, name: "Library", space_type: "real_estate", handle: null }, billing: { org_id: LIBRARY, content_org_id: selected, serving_org_id: LIBRARY, role: "owner", can_manage_subscription: true }, plan: "free", plan_raw: "free", trial_ends_at: null, plan_expires_at: null, usage: { listings: 1, leads: 0, leads_new: 0, renders: 0 } });
  const page = () => ({ actor_id: current.user.id, listings: [{ id: LISTING, org_id: LIBRARY, library_org_id: selected, space_type: "real_estate", address: "Synthetic only", tagline: null, details: {}, status: "draft", created_at: "2026-10-16T00:00:00Z", deleted_at: null, main_photo_key: null, beds: null, baths: null, sqft: null, price_cents: null }], total: 1, next_offset: null });
  const media = () => ({ org_id: LIBRARY, listing_id: LISTING, photos: [], videos: [], next_offset: null, unavailable_count: 0 });
  const seen: Array<{ path: string; method: string; wire: RequestInit }> = [];
  let directoryGate: ReturnType<typeof deferred<Response>> | undefined, mappingGate: ReturnType<typeof deferred<Response>> | undefined, mediaGate: ReturnType<typeof deferred<Response>> | undefined;
  let directoryStarted = deferred<void>(), mappingStarted = deferred<void>(), mediaStarted = deferred<void>();
  const services = createStudioServices({ supabaseUrl: "https://closed-kit-refresh.supabase.co", publishableKey: "sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY", redirectTo: "http://localhost:5173/" }, { auth, fetch: async (input, options = {}) => {
    const url = new URL(String(input)), method = options.method ?? "GET";
    seen.push({ path: url.pathname, method, wire: options });
    assert.equal(method, "GET", "Opening kit materials cannot send a mutation");
    if (url.pathname === "/functions/v1/me/workspaces") { directoryStarted.resolve(); return directoryGate?.promise ?? json(directory()); }
    if (url.pathname === "/functions/v1/me") { selected = new Headers(options.headers).get("X-Org-Id")!; return json(me()); }
    if (url.pathname === "/functions/v1/listings") { mappingStarted.resolve(); return mappingGate?.promise ?? json(page()); }
    if (url.pathname === "/functions/v1/studio/media") { mediaStarted.resolve(); return mediaGate?.promise ?? json(media()); }
    if (url.pathname === "/functions/v1/studio/listing-state") return json({ org_id: LIBRARY, listing_id: LISTING, assets: [], photos: [], jobs: [], renders: [], chapters: [], next_offset: null }, kitStatus);
    if (url.pathname === "/functions/v1/studio/creative-results") return json({ results: [], next_offset: null });
    if (url.pathname === "/functions/v1/studio/documents") return json({ document: null });
    throw new Error(`Unexpected closed kit transport ${url.pathname}`);
  } });
  return { services, seen, directory, page, media,
    gates() { directoryStarted = deferred(); mappingStarted = deferred(); directoryGate = deferred(); mappingGate = deferred(); return { directory: directoryGate, mapping: mappingGate, directoryStarted: directoryStarted.promise, mappingStarted: mappingStarted.promise }; },
    holdMedia() { mediaStarted = deferred(); mediaGate = deferred(); return { response: mediaGate, started: mediaStarted.promise }; },
    failKit() { kitStatus = 503; },
    emit(user: string) { current = session(user); callback("SIGNED_IN", current); },
    actions() { return seen.filter(row => row.method !== "GET"); },
  };
}

test("actual kit remains readable after a completed same-workspace directory caller is retired",async()=>{
 const f=fixture();try{
  const old=new AbortController(),workspace=await f.services.loadWorkspace(old.signal,LIBRARY);
  await f.services.listListings(LIBRARY,old.signal);
  const caller=new AbortController();old.abort();
  const pending=loadKit(f.services,workspace,LISTING,caller.signal);
  let error:unknown,result:Awaited<ReturnType<typeof loadKit>>|undefined;
  try{result=await pending;}catch(reason){error=reason;}
  assert.equal(caller.signal.aborted,false,"Kit caller did not cancel");
  assert.equal(f.services.getSnapshot().identity.userId,ACTOR);
  assert.equal(f.actions().length,0);
  assert.equal(error,undefined,"A completed directory caller's later retirement must not abort an active same-workspace Kit caller");
  assert.equal(result?.listing.id,LISTING);assert.equal(result?.items.length,0);
 }finally{f.services.dispose();}
});


test("actual kit ordinary read is valid and read-only before any retirement",async()=>{
 const f=fixture();try{const w=await f.services.loadWorkspace(undefined,LIBRARY);await f.services.listListings(LIBRARY);const result=await loadKit(f.services,w,LISTING,new AbortController().signal);assert.equal(result.listing.id,LISTING);assert.equal(result.items.length,0);assert.equal(f.actions().length,0);}finally{f.services.dispose();}
});

test("pending directory cancellation still refuses kit before any material transport",async()=>{
 const f=fixture();let gates:ReturnType<typeof f.gates>|undefined;try{
  const w=await f.services.loadWorkspace(undefined,LIBRARY);await f.services.listListings(LIBRARY);gates=f.gates();
  const old=new AbortController(),refresh=f.services.loadWorkspace(old.signal,LIBRARY),refreshHandled=refresh.catch(()=>{});await gates.directoryStarted;
  const kit=loadKit(f.services,w,LISTING,new AbortController().signal),rejected=assert.rejects(kit,error=>error instanceof Error&&error.name==="AbortError");
  old.abort();gates.directory.resolve(json(f.directory()));await Promise.all([rejected,refreshHandled]);
  assert.equal(f.seen.filter(row=>row.path.startsWith("/functions/v1/studio/")).length,0);assert.equal(f.actions().length,0);
 }finally{gates?.directory.resolve(json(f.directory()));gates?.mapping.resolve(json(f.page()));f.services.dispose();}
});

test("a kit mapping waiter survives completed-directory App waiter retirement",async()=>{
 const f=fixture();let gates:ReturnType<typeof f.gates>|undefined;try{
  const old=new AbortController(),w=await f.services.loadWorkspace(old.signal,LIBRARY);gates=f.gates();
  const app=f.services.listListings(LIBRARY,old.signal),appCancelled=assert.rejects(app,error=>error instanceof Error&&error.name==="AbortError");await gates.mappingStarted;
  const kit=loadKit(f.services,w,LISTING,new AbortController().signal);await tick();old.abort();await appCancelled;
  gates.mapping.resolve(json(f.page()));const result=await kit;assert.equal(result.listing.id,LISTING);assert.equal(f.actions().length,0);
 }finally{gates?.directory.resolve(json(f.directory()));gates?.mapping.resolve(json(f.page()));f.services.dispose();}
});

for(const change of["generation","library","actor-returned","caller-abort"]as const)test(`actual kit late response refuses after ${change}`,async()=>{
 const f=fixture();try{
  const w=await f.services.loadWorkspace(undefined,LIBRARY);await f.services.listListings(LIBRARY);const gate=f.holdMedia(),caller=new AbortController();
  const kit=loadKit(f.services,w,LISTING,caller.signal),rejected=assert.rejects(kit);await gate.started;
  if(change==="caller-abort")caller.abort();
  else if(change==="actor-returned"){f.emit(OTHER_ACTOR);f.emit(ACTOR);}
  else{await f.services.loadWorkspace(undefined,change==="library"?OTHER_LIBRARY:LIBRARY);await f.services.listListings(change==="library"?OTHER_LIBRARY:LIBRARY);}
  gate.response.resolve(json(f.media()));await rejected;assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("genuine current kit transport failure remains visible without retry",async()=>{
 const f=fixture();try{const w=await f.services.loadWorkspace(undefined,LIBRARY);await f.services.listListings(LIBRARY);f.failKit();
  await assert.rejects(loadKit(f.services,w,LISTING,new AbortController().signal),error=>error instanceof Error&&error.name!=="AbortError");
  assert.equal(f.seen.filter(row=>row.path==="/functions/v1/studio/listing-state").length,1);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});
