import assert from "node:assert/strict";
import test from "node:test";
import type { Session, AuthChangeEvent } from "@supabase/auth-js";
import { createStudioServices, type StudioAuth } from "../src/data/services";
import { buildKit, loadKit } from "../src/features/listings/delivery-kit";
import { scopedListingWorkspace } from "../src/data/contracts";

const ACTOR = "10000000-0000-4000-8000-000000000001", OTHER_ACTOR = "10000000-0000-4000-8000-000000000002";
const LIBRARY = "20000000-0000-4000-8000-000000000001", OTHER_LIBRARY = "20000000-0000-4000-8000-000000000002";
const STORAGE = "20000000-0000-4000-8000-000000000003", WRONG_LISTING = "30000000-0000-4000-8000-000000000002";
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
function fixture(physicalOrg = LIBRARY, withPhoto = false) {
  let current = session(), selected = LIBRARY, kitStatus = 200, mediaOrg = physicalOrg, mediaListing = LISTING, reportedLibrary: string | undefined, reportedPhysical = physicalOrg, listingRemoved = false, mappingStatus = 200;
  let callback: (event: AuthChangeEvent, value: Session | null) => void = () => {};
  const auth: StudioAuth = {
    getSession: async () => ({ data: { session: current }, error: null }), refreshSession: async () => ({ data: { session: current }, error: null }),
    signInWithOAuth: async () => ({ error: null }), signOut: async () => ({ error: null }),
    onAuthStateChange: next => { callback = next; return { data: { subscription: { unsubscribe() {} } } }; },
  };
  const photoId="40000000-0000-4000-8000-000000000001",key=`renders/${physicalOrg}/${LISTING}/source-${photoId}.png`,exp=Math.floor(Date.now()/1000)+590;
  const photoURL=`https://rendprop.com/private-media/${Buffer.from(JSON.stringify({v:1,actor:ACTOR,org:physicalOrg,listing:LISTING,bucket:"renders",key,exp})).toString("base64url")}.${"f".repeat(64)}`;
  const mediaPhoto={id:photoId,listing_id:LISTING,url:photoURL,expires_at:new Date(exp*1000).toISOString(),caption:null,is_staged:false,sort:0};
  const galleryPhoto={id:photoId,listing_id:LISTING,original_key:key,enhanced_key:null,caption:null,is_staged:false,is_main:false,sort:0,created_at:"2026-10-16T00:00:00Z"};
  const directory = () => ({ actor_id: current.user.id, own_org_id: LIBRARY, billing_org_id: LIBRARY, active_org_id: selected, can_switch_agent_libraries: true, workspaces: [
    { id: LIBRARY, name: "Own library", role: "owner", access_mode: "own", library_owner_user_id: current.user.id, billing_org_id: LIBRARY, can_read: true, can_write: true, can_manage_subscription: true },
    { id: OTHER_LIBRARY, name: "Other library", role: "team_owner", access_mode: "team_owner", library_owner_user_id: OTHER_ACTOR, billing_org_id: LIBRARY, can_read: true, can_write: true, can_manage_subscription: false },
  ] });
  const me = () => ({ user: { id: current.user.id, email: null, name: null, avatar_url: null }, org: { id: selected, name: "Library", space_type: "real_estate", handle: null }, billing: { org_id: LIBRARY, content_org_id: selected, serving_org_id: LIBRARY, role: "owner", can_manage_subscription: true }, plan: "free", plan_raw: "free", trial_ends_at: null, plan_expires_at: null, usage: { listings: 1, leads: 0, leads_new: 0, renders: 0 } });
  const page = () => ({ actor_id: current.user.id, listings: listingRemoved ? [] : [{ id: LISTING, org_id: reportedPhysical, library_org_id: reportedLibrary ?? selected, space_type: "real_estate", address: "Synthetic only", tagline: null, details: {}, status: "draft", created_at: "2026-10-16T00:00:00Z", deleted_at: null, main_photo_key: null, beds: null, baths: null, sqft: null, price_cents: null }], total: listingRemoved ? 0 : 1, next_offset: null });
  const media = () => ({ org_id: mediaOrg, listing_id: mediaListing, photos: withPhoto?[mediaPhoto]:[], videos: [], next_offset: null, unavailable_count: 0 });
  const seen: Array<{ path: string; method: string; wire: RequestInit }> = [];
  let directoryGate: ReturnType<typeof deferred<Response>> | undefined, mappingGate: ReturnType<typeof deferred<Response>> | undefined, mediaGate: ReturnType<typeof deferred<Response>> | undefined;
  let directoryStarted = deferred<void>(), mappingStarted = deferred<void>(), mediaStarted = deferred<void>();
  const services = createStudioServices({ supabaseUrl: "https://closed-kit-refresh.supabase.co", publishableKey: "sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY", redirectTo: "http://localhost:5173/" }, { auth, fetch: async (input, options = {}) => {
    const url = new URL(String(input)), method = options.method ?? "GET";
    seen.push({ path: url.pathname, method, wire: options });
    assert.equal(method, "GET", "Opening kit materials cannot send a mutation");
    if (url.pathname === "/functions/v1/me/workspaces") { directoryStarted.resolve(); return directoryGate?.promise ?? json(directory()); }
    if (url.pathname === "/functions/v1/me") { selected = new Headers(options.headers).get("X-Org-Id")!; return json(me()); }
    if (url.pathname === "/functions/v1/listings") { mappingStarted.resolve(); return mappingGate?.promise ?? json(page(),mappingStatus); }
    if (url.pathname === "/functions/v1/studio/media") { mediaStarted.resolve(); return mediaGate?.promise ?? json(media()); }
    if (url.pathname === "/functions/v1/studio/listing-state") return json({ org_id: physicalOrg, listing_id: LISTING, assets: [], photos: withPhoto?[galleryPhoto]:[], jobs: [], renders: [], chapters: [], next_offset: null }, kitStatus);
    if (url.pathname === "/functions/v1/studio/creative-results") return json({ results: [], next_offset: null });
    if (url.pathname === "/functions/v1/studio/documents") return json({ document: null });
    throw new Error(`Unexpected closed kit transport ${url.pathname}`);
  } });
  return { services, seen, directory, page, media,
    gates() { directoryStarted = deferred(); mappingStarted = deferred(); directoryGate = deferred(); mappingGate = deferred(); return { directory: directoryGate, mapping: mappingGate, directoryStarted: directoryStarted.promise, mappingStarted: mappingStarted.promise }; },
    holdMedia() { mediaStarted = deferred(); mediaGate = deferred(); return { response: mediaGate, started: mediaStarted.promise }; },
    failKit() { kitStatus = 503; },
    alterMedia(org: string, listing = LISTING) { mediaOrg = org; mediaListing = listing; },
    alterListingLibrary(library: string) { reportedLibrary = library; },
    alterListingPhysical(org: string) { reportedPhysical = org; },
    removeListing() { listingRemoved = true; },
    failMapping() { mappingStatus = 503; },
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


const materialReads = (f: ReturnType<typeof fixture>) => f.seen.filter(row => row.path.startsWith("/functions/v1/studio/"));
async function adopted(f: ReturnType<typeof fixture>) {
 const account=await f.services.loadWorkspace(undefined,LIBRARY),listing=(await f.services.listListings(LIBRARY))[0];
 return scopedListingWorkspace(account,listing);
}
test("an adopted kit uses logical membership and exact physical storage without an artificial membership",async()=>{
 const f=fixture(STORAGE);try{const w=await adopted(f);assert.equal(w.org.id,STORAGE);assert.equal(w.libraryOrgId,LIBRARY);assert(!w.memberships.some(row=>row.orgId===STORAGE));
  const result=await loadKit(f.services,w,LISTING,new AbortController().signal);assert.equal(result.listing.orgId,STORAGE);assert.equal(result.listing.libraryOrgId,LIBRARY);assert.equal(result.listing.id,LISTING);
  assert.equal(materialReads(f).length,4);assert(materialReads(f).every(row=>new Headers(row.wire.headers).get("X-Org-Id")===STORAGE));assert(f.seen.filter(row=>row.path==="/functions/v1/listings").every(row=>new Headers(row.wire.headers).get("X-Org-Id")===LIBRARY));assert.equal(f.actions().length,0);
  const kit=await buildKit(result,[],{services:f.services,workspace:w,signal:new AbortController().signal,progress:()=>{},fetcher:async()=>{throw new Error("No media selected");}});assert.equal(kit.mediaCount,0);assert(kit.blob.size>0);
 }finally{f.services.dispose();}
});

test("physical-org membership cannot stand in for the missing selected logical membership",async()=>{
 const f=fixture(STORAGE);try{const w=await adopted(f),bad={...w,memberships:[{...w.memberships[0],orgId:STORAGE}]},before=f.seen.length;
  await assert.rejects(loadKit(f.services,bad,LISTING,new AbortController().signal));assert.equal(f.seen.length,before);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

for(const bad of["physical-org","listing-id","logical-library"]as const)test(`kit refuses wrong ${bad} before material fan-out`,async()=>{
 const f=fixture(STORAGE);try{const w=await adopted(f);if(bad==="logical-library")f.alterListingLibrary(OTHER_LIBRARY);
  await assert.rejects(loadKit(f.services,bad==="physical-org"?{...w,org:{...w.org,id:OTHER_LIBRARY}}:w,bad==="listing-id"?WRONG_LISTING:LISTING,new AbortController().signal));
  assert.equal(materialReads(f).length,0);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("another selected library cannot start old-library material GETs even with the same physical org and listing ID",async()=>{
 const f=fixture(STORAGE);try{const w=await adopted(f);await f.services.loadWorkspace(undefined,OTHER_LIBRARY);await f.services.listListings(OTHER_LIBRARY);
  await assert.rejects(loadKit(f.services,w,LISTING,new AbortController().signal));assert.equal(materialReads(f).length,0);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

for(const bad of["physical-org","listing-id"]as const)test(`adopted kit rejects a media response from the wrong ${bad}`,async()=>{
 const f=fixture(STORAGE);try{const w=await adopted(f);f.alterMedia(bad==="physical-org"?OTHER_LIBRARY:STORAGE,bad==="listing-id"?WRONG_LISTING:LISTING);
  await assert.rejects(loadKit(f.services,w,LISTING,new AbortController().signal));assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("download refuses an otherwise logical-library kit snapshot from another physical org",async()=>{
 const f=fixture(STORAGE);try{const w=await adopted(f),snapshot=await loadKit(f.services,w,LISTING,new AbortController().signal);let fetched=false;
  await assert.rejects(buildKit({...snapshot,listing:{...snapshot.listing,orgId:OTHER_LIBRARY}},[],{services:f.services,workspace:w,signal:new AbortController().signal,progress:()=>{},fetcher:async()=>{fetched=true;throw new Error("Must not fetch");}}));assert.equal(fetched,false);
 }finally{f.services.dispose();}
});


test("logical library retirement between real listing admission and kit material reads cannot dispatch old-scope materials",async()=>{
 const f=fixture(STORAGE);try{const w=await adopted(f),read=f.services.listListings;let retire=true;
  f.services.listListings=async(...args:Parameters<typeof read>)=>{const rows=await read(...args);if(retire){retire=false;await f.services.loadWorkspace(undefined,OTHER_LIBRARY);await read(OTHER_LIBRARY);}return rows;};
  await assert.rejects(loadKit(f.services,w,LISTING,new AbortController().signal));
  assert.equal(materialReads(f).length,0,"A fresh different logical library must not authorize material transport for the old kit, even when it maps the same physical property");assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});


test("a logical library switch while the actual private photo download is pending cannot return an old-library kit",async()=>{
 const f=fixture(LIBRARY,true);try{const w=await f.services.loadWorkspace(undefined,LIBRARY);await f.services.listListings(LIBRARY);const snapshot=await loadKit(f.services,w,LISTING,new AbortController().signal);assert.equal(snapshot.items.length,1);let downloads=0;
  const png=Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="),char=>char.charCodeAt(0));
  const output=buildKit(snapshot,[snapshot.items[0].id],{services:f.services,workspace:w,signal:new AbortController().signal,progress:()=>{},fetcher:async()=>{downloads++;await f.services.loadWorkspace(undefined,OTHER_LIBRARY);await f.services.listListings(OTHER_LIBRARY);return new Response(png,{headers:{"Content-Type":"image/png","Content-Length":String(png.length)}});}});
  await assert.rejects(output,"Current logical library changed during the awaited private fetch; cached old workspace memberships must not authorize its ZIP");assert.equal(downloads,1);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});


const png=Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="),char=>char.charCodeAt(0));
async function ownPhoto(f:ReturnType<typeof fixture>){const w=await f.services.loadWorkspace(undefined,LIBRARY);await f.services.listListings(LIBRARY);return{w,snapshot:await loadKit(f.services,w,LISTING,new AbortController().signal)};}
function optionsFor(f:ReturnType<typeof fixture>,w:Awaited<ReturnType<typeof ownPhoto>>["w"],signal=new AbortController().signal){return{services:f.services,workspace:w,signal,progress:()=>{}};}

test("a stable photo kit uses cached read authority with no additional HTTP and no duplicate download",async()=>{
 const f=fixture(LIBRARY,true);try{const{w,snapshot}=await ownPhoto(f),before=f.seen.length;let fetched=0;
  const kit=await buildKit(snapshot,[snapshot.items[0].id],{...optionsFor(f,w),fetcher:async(_url,wire)=>{fetched++;assert.equal(wire?.credentials,"omit");assert.equal(wire?.referrerPolicy,"no-referrer");assert.equal(wire?.redirect,"error");return new Response(png,{headers:{"Content-Type":"image/png"}});}});
  assert.equal(kit.mediaCount,1);assert.equal(fetched,1);assert.equal(f.seen.length,before);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("same-library completed refresh and its caller retirement during a private download remain usable",async()=>{
 const f=fixture(LIBRARY,true);try{const{w,snapshot}=await ownPhoto(f),before=f.seen.length;let fetched=0;
  const kit=await buildKit(snapshot,[snapshot.items[0].id],{...optionsFor(f,w),fetcher:async()=>{fetched++;const caller=new AbortController();await f.services.loadWorkspace(caller.signal,LIBRARY);await f.services.listListings(LIBRARY,caller.signal);caller.abort();return new Response(png,{headers:{"Content-Type":"image/png"}});}});
  assert.equal(kit.mediaCount,1);assert.equal(fetched,1);assert.equal(f.seen.length-before,3,"Only the explicit directory/me/listing refresh sends HTTP");assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

for(const change of["library","physical-org","listing-removed","actor-returned","caller-abort","mapping-failure"]as const)test(`private response after ${change} is cancelled before it is consumed`,async()=>{
 const f=fixture(LIBRARY,true);try{const{w,snapshot}=await ownPhoto(f),caller=new AbortController();let fetched=0,cancelled=0,pulled=0;
  const output=buildKit(snapshot,[snapshot.items[0].id],{...optionsFor(f,w,caller.signal),fetcher:async()=>{fetched++;
   if(change==="actor-returned"){f.emit(OTHER_ACTOR);f.emit(ACTOR);}else if(change==="caller-abort")caller.abort();else{
    if(change==="physical-org")f.alterListingPhysical(OTHER_LIBRARY);if(change==="listing-removed")f.removeListing();if(change==="mapping-failure")f.failMapping();
    await f.services.loadWorkspace(undefined,change==="library"?OTHER_LIBRARY:LIBRARY);await f.services.listListings(change==="library"?OTHER_LIBRARY:LIBRARY).catch(()=>{});
   }
   return new Response(new ReadableStream<Uint8Array>({pull(c){pulled++;c.enqueue(png);},cancel(){cancelled++;}},{highWaterMark:0}),{headers:{"Content-Type":"image/png"}});
  }});
  let error:unknown;try{await output;}catch(reason){error=reason;}assert(error instanceof Error);if(change==="mapping-failure")assert.notEqual(error.name,"AbortError");
  assert.equal(fetched,1);assert.equal(cancelled,1);assert.equal(pulled,0,"Scope refusal must cancel the unread private response");assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("a library switch during a reader chunk cancels before a second pull or ZIP",async()=>{
 const f=fixture(LIBRARY,true);try{const{w,snapshot}=await ownPhoto(f);let pulls=0,cancelled=0,fetched=0;
  const output=buildKit(snapshot,[snapshot.items[0].id],{...optionsFor(f,w),fetcher:async()=>{fetched++;return new Response(new ReadableStream<Uint8Array>({async pull(c){pulls++;if(pulls===1){await f.services.loadWorkspace(undefined,OTHER_LIBRARY);await f.services.listListings(OTHER_LIBRARY);c.enqueue(png);}else c.close();},cancel(){cancelled++;}},{highWaterMark:0}),{headers:{"Content-Type":"image/png"}});}});
  await assert.rejects(output);assert.equal(fetched,1);assert.equal(pulls,1);assert.equal(cancelled,1);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("a logical switch during ZIP packing cannot return a completed download or regenerate it",async()=>{
 const f=fixture();try{const{w,snapshot}=await ownPhoto(f);let packing=0,refresh:Promise<unknown>|undefined,fetched=0;
  const output=buildKit(snapshot,[],{...optionsFor(f,w),progress:value=>{if(value.label==="Packing your listing kit…"){packing++;refresh=f.services.loadWorkspace(undefined,OTHER_LIBRARY).then(()=>f.services.listListings(OTHER_LIBRARY));}},fetcher:async()=>{fetched++;throw new Error("No selected media");}});
  await assert.rejects(output);await refresh;assert.equal(packing,1);assert.equal(fetched,0);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("a scope guard from an older generation never passes after a new read even in the same library",async()=>{
 const f=fixture();try{await ownPhoto(f);const old=await f.services.listingReadScope(LIBRARY,LISTING,LIBRARY);old();await f.services.loadWorkspace(undefined,LIBRARY);await f.services.listListings(LIBRARY);assert.throws(old);
  const before=f.seen.length,current=await f.services.listingReadScope(LIBRARY,LISTING,LIBRARY);current();assert.equal(f.seen.length,before);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("typed media optional library binding refuses another library while four-argument callers retain their wire contract",async()=>{
 const f=fixture(STORAGE);try{await adopted(f);const ordinary=await f.services.listMedia(STORAGE,LISTING,undefined,0);assert.equal(ordinary.orgId,STORAGE);const before=f.seen.length;
  await assert.rejects(f.services.listMedia(STORAGE,LISTING,undefined,0,OTHER_LIBRARY));await assert.rejects(f.services.listMedia(STORAGE,LISTING,undefined,0,"bad-library"));assert.equal(f.seen.length,before);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});


test("a same-library refresh still pending during a photo download joins its one fresh map",{timeout:3000},async()=>{
 const f=fixture(LIBRARY,true);let gates:ReturnType<typeof f.gates>|undefined,refresh:Promise<unknown>|undefined;try{
  const{w,snapshot}=await ownPhoto(f);gates=f.gates();const started=deferred<void>();let finished=false;
  const output=buildKit(snapshot,[snapshot.items[0].id],{...optionsFor(f,w),fetcher:async()=>{refresh=f.services.loadWorkspace(undefined,LIBRARY);void refresh.catch(()=>{});await gates!.directoryStarted;started.resolve();return new Response(png,{headers:{"Content-Type":"image/png"}});}});void output.then(()=>{finished=true;},()=>{finished=true;});
  await started.promise;await tick();assert.equal(finished,false);gates.directory.resolve(json(f.directory()));await refresh;await gates.mappingStarted;const app=f.services.listListings(LIBRARY);gates.mapping.resolve(json(f.page()));await app;
  assert.equal((await output).mediaCount,1);assert.equal(f.actions().length,0);
 }finally{gates?.directory.resolve(json(f.directory()));gates?.mapping.resolve(json(f.page()));f.services.dispose();}
});
