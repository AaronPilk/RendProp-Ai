import assert from "node:assert/strict";
import test from "node:test";
import type { Session, AuthChangeEvent } from "@supabase/auth-js";
import { createStudioServices, type StudioAuth } from "../src/data/services";
import { uploadListingAsset } from "../src/features/listings/uploads";
import { prepareGalleryCopy } from "../src/features/listings/gallery-copy";

const ACTOR="10000000-0000-4000-8000-000000000001",OTHER_ACTOR="10000000-0000-4000-8000-000000000002";
const LIBRARY="20000000-0000-4000-8000-000000000001",OTHER_LIBRARY="20000000-0000-4000-8000-000000000002",ORG="20000000-0000-4000-8000-000000000003";
const LISTING="30000000-0000-4000-8000-000000000001",SOURCE="40000000-0000-4000-8000-000000000001",DEST="40000000-0000-4000-8000-000000000002";
const PHOTO=new Uint8Array([255,216,255,0,1,2]),SHA=Buffer.from(await crypto.subtle.digest("SHA-256",PHOTO)).toString("hex");
const key=`renders/${ORG}/${LISTING}/original-${SOURCE}.jpg`,destinationKey=`renders/${ORG}/${LISTING}/gallery-${DEST}.jpg`;
const putURL=`https://uploads.rendprop.com/v2/${DEST}?expires=1999999999&signature=${"a".repeat(64)}`;
function deferred<T>(){let resolve!:(value:T)=>void,reject!:(reason:unknown)=>void;const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});return{promise,resolve,reject};}
const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers:{"Content-Type":"application/json"}});
const tick=()=>new Promise<void>(resolve=>setImmediate(resolve));
function session(user=ACTOR,token="closed-fixture-token"):Session{return{access_token:token,refresh_token:"closed-fixture-refresh",expires_in:3600,token_type:"bearer",user:{id:user,aud:"authenticated",created_at:"2026-10-16T00:00:00Z",app_metadata:{},user_metadata:{}}};}
function fixture(){
 let current=session(),callback:(event:AuthChangeEvent,next:Session|null)=>void=()=>{},selected=LIBRARY;
 const auth:StudioAuth={getSession:async()=>({data:{session:current},error:null}),refreshSession:async()=>({data:{session:current},error:null}),signInWithOAuth:async()=>({error:null}),signOut:async()=>({error:null}),onAuthStateChange:cb=>{callback=cb;return{data:{subscription:{unsubscribe(){}}}};}};
 const directory=(target=selected,removed=false)=>({actor_id:current.user.id,own_org_id:LIBRARY,billing_org_id:LIBRARY,active_org_id:target,can_switch_agent_libraries:true,workspaces:[{id:LIBRARY,name:"Own library",role:"owner",access_mode:"own",library_owner_user_id:current.user.id,billing_org_id:LIBRARY,can_read:true,can_write:true,can_manage_subscription:true},...removed?[]:[{id:OTHER_LIBRARY,name:"Other library",role:"team_owner",access_mode:"team_owner",library_owner_user_id:OTHER_ACTOR,billing_org_id:LIBRARY,can_read:true,can_write:true,can_manage_subscription:false}]]});
 const me=(target=selected)=>({user:{id:current.user.id,email:null,name:null,avatar_url:null},org:{id:target,name:"Library",space_type:"real_estate",handle:null},billing:{org_id:LIBRARY,content_org_id:target,serving_org_id:LIBRARY,role:"owner",can_manage_subscription:true},plan:"free",plan_raw:"free",trial_ends_at:null,plan_expires_at:null,usage:{listings:1,leads:0,leads_new:0,renders:0}});
 const row=(library=selected)=>({id:LISTING,org_id:ORG,library_org_id:library,space_type:"real_estate",address:"Synthetic only",tagline:null,details:{},status:"draft",created_at:"2026-10-16T00:00:00Z",deleted_at:null,main_photo_key:null,beds:null,baths:null,sqft:null,price_cents:null});
 const page=(rows=[row()])=>({actor_id:current.user.id,listings:rows,total:rows.length,next_offset:null});
 const seen:Array<{path:string;query:URLSearchParams;method:string;body:any;headers:Headers;wire:RequestInit}>=[];
 let directoryGate:ReturnType<typeof deferred<Response>>|undefined,mappingGate:ReturnType<typeof deferred<Response>>|undefined,mediaGate:ReturnType<typeof deferred<Response>>|undefined;
 let directoryStarted=deferred<void>(),mappingStarted=deferred<void>(),mediaStarted=deferred<void>(),uploaded=false,complete=false,operation:string|undefined;
 const media=(org=ORG,listing=LISTING)=>({org_id:org,listing_id:listing,photos:[],videos:[],next_offset:null,unavailable_count:0});
 function copy(){const exp=Math.floor(Date.now()/1000)+590,payload={v:1,actor:ACTOR,org:ORG,listing:LISTING,bucket:"renders",key,exp};return{schema:1,actor_id:ACTOR,org_id:ORG,library_org_id:LIBRARY,listing_id:LISTING,operation_id:operation,source:{asset_id:SOURCE,key,bytes:PHOTO.length,sha256:SHA,mime:"image/jpeg",kind:"original",provenance:null},destination_asset_id:uploaded?DEST:null,complete,photo:complete?{id:DEST,listing_id:LISTING}:null,download:complete?null:{url:`https://rendprop.com/private-media/${Buffer.from(JSON.stringify(payload)).toString("base64url")}.${"f".repeat(64)}`,expires_at:new Date(exp*1000).toISOString()}};}
 const services=createStudioServices({supabaseUrl:"https://closed-refresh.supabase.co",publishableKey:"sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY",redirectTo:"http://localhost:5173/"},{auth,fetch:async(input,options={})=>{
  const url=new URL(String(input)),body=typeof options.body==="string"?JSON.parse(options.body):null,headers=new Headers(options.headers),method=options.method??"GET";seen.push({path:url.pathname,query:url.searchParams,method,body,headers,wire:options});
  if(url.pathname==="/functions/v1/me/workspaces"){directoryStarted.resolve();return directoryGate?.promise??json(directory());}
  if(url.pathname==="/functions/v1/me"){selected=headers.get("X-Org-Id")!;return json(me());}
  if(url.pathname==="/functions/v1/listings"){mappingStarted.resolve();return mappingGate?.promise??json(page());}
  if(url.pathname==="/functions/v1/studio/media"){mediaStarted.resolve();return mediaGate?.promise??json(media(url.searchParams.get("org_id")!,url.searchParams.get("listing_id")!));}
  if(url.pathname==="/functions/v1/studio/photo-copy"){operation??=body.operation_id;assert.equal(body.operation_id,operation);if(body.action==="bind")uploaded=true;if(body.action==="finish")complete=true;return json(copy());}
  if(url.pathname==="/functions/v1/uploads"||url.pathname.endsWith("/renew"))return json({asset_id:DEST,storage_key:destinationKey,mode:"single",uploaded,put_url:putURL});
  if(url.pathname.endsWith("/complete")){uploaded=true;return json({id:DEST,storage_key:destinationKey,listing_id:LISTING,uploaded:true});}
  if(url.origin==="https://uploads.rendprop.com"){assert.equal(headers.get("Authorization"),null);assert.equal(options.credentials,"omit");assert.deepEqual(new Uint8Array(await (options.body as Blob).arrayBuffer()),PHOTO);return new Response(null,{headers:{ETag:"same-bytes"}});}
  if(url.pathname==="/functions/v1/studio/probe")return json({ok:true});
  throw Error(`Unexpected closed transport ${url.pathname}`);
 }});
 const storageMap=new Map<string,string>(),storage={getItem:(k:string)=>storageMap.get(k)??null,setItem:(k:string,v:string)=>void storageMap.set(k,v),removeItem:(k:string)=>void storageMap.delete(k)}as Storage;
 return{services,seen,storage,storageMap,directory,me,page,row,copy,media,
  scope:{actor:ACTOR,org:ORG,library:LIBRARY,listing:LISTING},
  async open(){await services.loadWorkspace(undefined,LIBRARY);await services.listListings(LIBRARY);},
  gates(){directoryStarted=deferred();mappingStarted=deferred();directoryGate=deferred();mappingGate=deferred();return{directory:directoryGate,mapping:mappingGate,directoryStarted:directoryStarted.promise,mappingStarted:mappingStarted.promise};},
  clearGates(){directoryGate=undefined;mappingGate=undefined;},
  holdMedia(){mediaStarted=deferred();mediaGate=deferred();return{response:mediaGate,started:mediaStarted.promise};},
  emit(user:string,token?:string){current=session(user,token);callback(user===ACTOR&&token?"TOKEN_REFRESHED":"SIGNED_IN",current);},
  actions(){return seen.filter(r=>r.method!=="GET");},
 };
}
async function sourceTransport<T>(body:()=>Promise<T>){const saved=globalThis.fetch;globalThis.fetch=async()=>new Response(PHOTO,{headers:{"Content-Type":"image/jpeg","Content-Length":String(PHOTO.length)}});try{return await body();}finally{globalThis.fetch=saved;}}
const options={orgId:ORG,expectedLibraryOrgId:LIBRARY,method:"POST"as const,body:{action:"finish",operation_id:"50000000-0000-4000-8000-000000000001"}};

test("actual source-copy upload waits for directory AND adopted physical mapping, then finishes the same journal operation once",async()=>{
 const f=fixture();try{await f.open();const gates=f.gates();let appRead:Promise<unknown>|undefined;
 const result=sourceTransport(()=>prepareGalleryCopy(f.services,f.scope,SOURCE,"Room",new AbortController().signal,{storage:f.storage,progress:message=>{if(message==="Verifying the saved version…")appRead=f.services.loadWorkspace(undefined,LIBRARY).then(w=>f.services.listListings(w.org.id));}})).then(value=>({value,error:null}),error=>({value:null,error}));
 await gates.directoryStarted;await tick();const before=f.actions().length;
 assert.equal(f.seen.filter(r=>r.body?.action==="finish").length,0);assert.equal(f.storageMap.size,1);
 const saved=JSON.parse([...f.storageMap.values()][0]);assert.equal(saved.upload.assetId,DEST);
 gates.directory.resolve(json(f.directory()));await gates.mappingStarted;await tick();
 assert.equal(f.actions().length,before,"Directory membership alone cannot send finish");
 assert.equal(f.seen.filter(r=>r.path==="/functions/v1/listings").length,2,"App and action join exactly one fresh mapping read");
 gates.mapping.resolve(json(f.page()));const outcome=await result;assert.equal(outcome.error,null,"The same copy must finish after the fresh mapping resolves");assert(outcome.value?.complete);await appRead;
 const finishes=f.seen.filter(r=>r.body?.action==="finish");assert.equal(finishes.length,1);assert.equal(finishes[0].body.operation_id,saved.operationId);assert.equal(finishes[0].headers.get("X-Org-Id"),ORG);
 assert(f.seen.filter(r=>r.method!=="GET").every(r=>!JSON.stringify(r.body).includes("expectedLibraryOrgId")&&!r.headers.has("expectedLibraryOrgId")));
 assert.equal(f.storageMap.size,0);assert.equal(f.seen.filter(r=>r.wire.method==="PUT").length,1);
 }finally{f.services.dispose();}
});

test("API and gateway PUT share current mapping; aborting one waiter cannot cancel another",async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),refresh=f.services.loadWorkspace(undefined,LIBRARY);await gates.directoryStarted;
 const cancelled=new AbortController(),stopped=assert.rejects(f.services.api("/functions/v1/studio/probe",{...options,signal:cancelled.signal}),e=>e instanceof Error&&e.name==="AbortError");
 const api=f.services.api("/functions/v1/studio/probe",options),put=f.services.upload(putURL,new Blob([PHOTO]),{orgId:ORG,expectedLibraryOrgId:LIBRARY});
 await tick();assert.equal(f.actions().length,0);gates.directory.resolve(json(f.directory()));await refresh;await gates.mappingStarted;cancelled.abort();await stopped;await tick();assert.equal(f.actions().length,0);
 gates.mapping.resolve(json(f.page()));assert.deepEqual(await api,{ok:true});await put;
 assert.equal(f.actions().length,2);assert.equal(f.seen.filter(r=>r.path==="/functions/v1/listings").length,2);
 }finally{f.services.dispose();}
});

for(const fault of["directory-failure","mapping-failure","malformed-actor","mapping-removed","library-switched","actor-returned","superseded","caller-abort","read-abort"]as const)test(`fresh ${fault} refuses API and upload before either transport`,async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),readController=new AbortController(),refresh=f.services.loadWorkspace(readController.signal,LIBRARY);const refreshHandled=refresh.catch(()=>{});await gates.directoryStarted;
 const caller=new AbortController();let a:unknown,b:unknown;
 const api=f.services.api("/functions/v1/studio/probe",{...options,signal:caller.signal}).catch(error=>{a=error;});
 const put=f.services.upload(putURL,new Blob([PHOTO]),{orgId:ORG,expectedLibraryOrgId:LIBRARY,signal:caller.signal}).catch(error=>{b=error;});
 await tick();assert.equal(f.actions().length,0);
 if(fault==="directory-failure")gates.directory.resolve(json({},503));
 else if(fault==="actor-returned"){f.emit(OTHER_ACTOR);f.emit(ACTOR);gates.directory.resolve(json(f.directory()));}
 else if(fault==="superseded"||fault==="library-switched"){
  f.clearGates();await f.services.loadWorkspace(undefined,fault==="library-switched"?OTHER_LIBRARY:LIBRARY);gates.directory.resolve(json(f.directory()));
 }else if(fault==="read-abort"){readController.abort();gates.directory.resolve(json(f.directory()));}
 else{
  gates.directory.resolve(json(f.directory()));await refresh;await gates.mappingStarted;
  if(fault==="caller-abort")caller.abort();
  gates.mapping.resolve(fault==="mapping-failure"?json({},403):json(fault==="malformed-actor"?{...f.page(),actor_id:OTHER_ACTOR}:f.page(fault==="mapping-removed"?[]:undefined)));
 }
 await Promise.all([api,put,refreshHandled]);assert(a instanceof Error);assert(b instanceof Error);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("fresh directory removing the selected library never falls back to another membership",async()=>{
 const f=fixture();try{await f.open();await f.services.loadWorkspace(undefined,OTHER_LIBRARY);const gates=f.gates(),refresh=f.services.loadWorkspace(undefined,OTHER_LIBRARY);const refused=assert.rejects(refresh);await gates.directoryStarted;
 const request=assert.rejects(f.services.api("/functions/v1/studio/probe",{...options,expectedLibraryOrgId:OTHER_LIBRARY}));
 gates.directory.resolve(json(f.directory(LIBRARY,true)));await Promise.all([request,refused]);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("same actor token refresh during mapping keeps the one operation and uses only the fresh token",async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),refresh=f.services.loadWorkspace(undefined,LIBRARY);await gates.directoryStarted;const action=f.services.api("/functions/v1/studio/probe",options);
 gates.directory.resolve(json(f.directory()));await refresh;await gates.mappingStarted;f.emit(ACTOR,"new-closed-token");gates.mapping.resolve(json(f.page()));await action;
 assert.equal(f.actions().length,1);assert.equal(f.actions()[0].headers.get("Authorization"),"Bearer new-closed-token");assert.deepEqual(f.actions()[0].body,options.body);
 }finally{f.services.dispose();}
});

test("no workspace was read is a genuine membership denial, with zero directory or mutation transport",async()=>{
 const f=fixture();try{await f.services.ready();await assert.rejects(f.services.api("/functions/v1/studio/probe",options));assert.equal(f.seen.length,0);}finally{f.services.dispose();}
});

test("leaving the logical library rejects stale copy intent even if both libraries remain memberships",async()=>{
 const f=fixture();try{await f.open();await f.services.loadWorkspace(undefined,OTHER_LIBRARY);await assert.rejects(f.services.api("/functions/v1/studio/probe",options));await assert.rejects(f.services.upload(putURL,new Blob([PHOTO]),{orgId:ORG,expectedLibraryOrgId:LIBRARY}));assert.equal(f.actions().length,0);}finally{f.services.dispose();}
});


test("a completed upload cannot finish the old-library copy after a same-actor library switch",async()=>{
 const f=fixture();try{await f.open();
 await sourceTransport(()=>assert.rejects(prepareGalleryCopy(f.services,f.scope,SOURCE,"Room",new AbortController().signal,{storage:f.storage,upload:async(services,options)=>{
  const result=await uploadListingAsset(services,options);
  await f.services.loadWorkspace(undefined,OTHER_LIBRARY);await f.services.listListings(OTHER_LIBRARY);return result;
 }})));
 assert.equal(f.seen.filter(r=>r.body?.action==="finish").length,0);assert.equal(f.storageMap.size,1);
 const journal=JSON.parse([...f.storageMap.values()][0]);assert.equal(journal.upload.assetId,DEST);assert.equal(journal.scope.library,LIBRARY);
 }finally{f.services.dispose();}
});

test("a synchronous account switch from upload progress cannot dispatch PUT using an earlier authority check",async()=>{
 const f=fixture();try{await f.open();await assert.rejects(f.services.upload(putURL,new Blob([PHOTO]),{orgId:ORG,expectedLibraryOrgId:LIBRARY,onProgress:loaded=>{if(loaded===0){f.emit(OTHER_ACTOR);f.emit(ACTOR);}}}));assert.equal(f.actions().length,0);}finally{f.services.dispose();}
});

test("typed media joins the fresh directory and exact adopted-listing mapping before its first GET",async()=>{
 const f=fixture();let gates:ReturnType<typeof f.gates>|undefined;try{
  await f.open();gates=f.gates();const refresh=f.services.loadWorkspace(undefined,LIBRARY);void refresh.catch(()=>{});await gates.directoryStarted;
  let outcome:unknown;const pending=f.services.listMedia(ORG,LISTING,undefined,50).then(value=>{outcome=value;return value;},error=>{outcome=error;throw error;});void pending.catch(()=>{});
  await tick();assert.equal(outcome,undefined,"A temporary cleared membership cache must wait, not become a media alert");assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,0);
  gates.directory.resolve(json(f.directory()));await refresh;await gates.mappingStarted;
  const appRead=f.services.listListings(LIBRARY);await tick();assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,0,"Directory membership alone cannot authorize an adopted listing");
  gates.mapping.resolve(json(f.page()));const result=await pending;await appRead;
  assert.equal(result.orgId,ORG);assert.equal(result.listingId,LISTING);assert.equal(f.seen.filter(r=>r.path.endsWith("/listings")).length,2,"The typed read and App share one fresh mapping read");
  const reads=f.seen.filter(r=>r.path.endsWith("/media"));assert.equal(reads.length,1);assert.equal(reads[0].method,"GET");assert.equal(reads[0].headers.get("X-Org-Id"),ORG);assert.equal(reads[0].query.get("org_id"),ORG);assert.equal(reads[0].query.get("listing_id"),LISTING);assert.equal(reads[0].query.get("offset"),"50");assert.equal(reads[0].wire.credentials,"omit");assert.equal(f.actions().length,0);
 }finally{gates?.directory.resolve(json(f.directory()));gates?.mapping.resolve(json(f.page()));f.services.dispose();}
});

test("typed media also fills a fresh completed directory's mapping gap instead of trusting old routing hints",async()=>{
 const f=fixture();let gates:ReturnType<typeof f.gates>|undefined;try{
  await f.open();gates=f.gates();const refresh=f.services.loadWorkspace(undefined,LIBRARY);void refresh.catch(()=>{});await gates.directoryStarted;gates.directory.resolve(json(f.directory()));await refresh;
  let outcome:unknown;const pending=f.services.listMedia(ORG,LISTING).then(value=>{outcome=value;return value;},error=>{outcome=error;throw error;});void pending.catch(()=>{});
  await tick();assert.equal(outcome,undefined,"The completed directory still requires a fresh exact-listing map");await gates.mappingStarted;assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,0);
  gates.mapping.resolve(json(f.page()));assert.equal((await pending).listingId,LISTING);
 }finally{gates?.directory.resolve(json(f.directory()));gates?.mapping.resolve(json(f.page()));f.services.dispose();}
});

test("aborting one typed media waiter leaves another waiter and App's fresh mapping intact",async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),refresh=f.services.loadWorkspace(undefined,LIBRARY);await gates.directoryStarted;
  const cancelled=new AbortController(),stopped=assert.rejects(f.services.listMedia(ORG,LISTING,cancelled.signal),e=>e instanceof Error&&e.name==="AbortError"),pending=f.services.listMedia(ORG,LISTING);
  gates.directory.resolve(json(f.directory()));await refresh;await gates.mappingStarted;const appRead=f.services.listListings(LIBRARY);cancelled.abort();await stopped;await tick();assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,0);
  gates.mapping.resolve(json(f.page()));assert.equal((await pending).listingId,LISTING);await appRead;assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,1);assert.equal(f.seen.filter(r=>r.path.endsWith("/listings")).length,2);
 }finally{f.services.dispose();}
});

for(const fault of["directory-failure","mapping-failure","malformed-actor","mapping-removed","other-listing-same-org","other-org-same-listing","library-switched","actor-returned","superseded","caller-abort","read-abort"]as const)test(`typed media fresh ${fault} refuses before its GET`,async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),readController=new AbortController(),refresh=f.services.loadWorkspace(readController.signal,LIBRARY);const refreshHandled=refresh.catch(()=>{});await gates.directoryStarted;
  const caller=new AbortController();let error:unknown;const pending=f.services.listMedia(ORG,LISTING,caller.signal).catch(reason=>{error=reason;});await tick();assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,0);
  if(fault==="directory-failure")gates.directory.resolve(json({},503));
  else if(fault==="actor-returned"){f.emit(OTHER_ACTOR);f.emit(ACTOR);gates.directory.resolve(json(f.directory()));}
  else if(fault==="superseded"||fault==="library-switched"){
   f.clearGates();await f.services.loadWorkspace(undefined,fault==="library-switched"?OTHER_LIBRARY:LIBRARY);gates.directory.resolve(json(f.directory()));
  }else if(fault==="read-abort"){readController.abort();gates.directory.resolve(json(f.directory()));}
  else{
   gates.directory.resolve(json(f.directory()));await refresh;
   // Failures in the old implementation occur before the mapping read starts.
   // Positive tests above prove the real barrier starts; these assert it stays closed.
   await tick();if(fault==="caller-abort")caller.abort();
   const rows=fault==="mapping-removed"?[]:[fault==="other-listing-same-org"?{...f.row(),id:"30000000-0000-4000-8000-000000000002"}:fault==="other-org-same-listing"?{...f.row(),org_id:OTHER_LIBRARY}:f.row()];
   gates.mapping.resolve(fault==="mapping-failure"?json({},403):json(fault==="malformed-actor"?{...f.page(),actor_id:OTHER_ACTOR}:f.page(rows)));
  }
  await Promise.all([pending,refreshHandled]);assert(error instanceof Error);assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,0);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

for(const replacement of["refresh","library-switch","actor-returned","caller-abort"]as const)test(`typed media rejects its late response after ${replacement}`,async()=>{
 const f=fixture();try{await f.open();const held=f.holdMedia(),caller=new AbortController();const pending=assert.rejects(f.services.listMedia(ORG,LISTING,caller.signal));await held.started;
  if(replacement==="caller-abort")caller.abort();
  else if(replacement==="actor-returned"){f.emit(OTHER_ACTOR);f.emit(ACTOR);}
  else await f.services.loadWorkspace(undefined,replacement==="library-switch"?OTHER_LIBRARY:LIBRARY);
  held.response.resolve(json(f.media()));await pending;assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,1);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("typed media accepts only its exact mapped listing even when the storage org is a direct membership",async()=>{
 const f=fixture();try{await f.services.loadWorkspace(undefined,LIBRARY);await f.services.listListings(LIBRARY);
  await assert.rejects(f.services.listMedia(LIBRARY,LISTING));assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,0,"Membership must not authorize the same ID under a different storage org");
  await assert.rejects(f.services.listMedia(ORG,"30000000-0000-4000-8000-000000000002"));assert.equal(f.seen.filter(r=>r.path.endsWith("/media")).length,0,"Another listing's physical org is not an exact-listing mapping");
 }finally{f.services.dispose();}
});

test("same actor token refresh during typed media mapping uses the fresh token without restarting reads",async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),refresh=f.services.loadWorkspace(undefined,LIBRARY);await gates.directoryStarted;
  const pending=f.services.listMedia(ORG,LISTING);gates.directory.resolve(json(f.directory()));await refresh;await gates.mappingStarted;f.emit(ACTOR,"new-typed-media-token");gates.mapping.resolve(json(f.page()));await pending;
  const reads=f.seen.filter(r=>r.path.endsWith("/media"));assert.equal(reads.length,1);assert.equal(reads[0].headers.get("Authorization"),"Bearer new-typed-media-token");assert.equal(f.seen.filter(r=>r.path.endsWith("/listings")).length,2);
 }finally{f.services.dispose();}
});

test("typed media without a workspace never starts directory, mapping or media transport",async()=>{
 const f=fixture();try{await f.services.ready();await assert.rejects(f.services.listMedia(ORG,LISTING));assert.equal(f.seen.length,0);}finally{f.services.dispose();}
});

test("an abandoned mapping flight cannot cancel or poison a fresh read in the same workspace",async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),refresh=f.services.loadWorkspace(undefined,LIBRARY);await gates.directoryStarted;gates.directory.resolve(json(f.directory()));await refresh;
  const caller=new AbortController(),cancelled=f.services.listMedia(ORG,LISTING,caller.signal),handled=assert.rejects(cancelled,error=>error instanceof Error&&error.name==="AbortError");await gates.mappingStarted;
  const abandoned=f.seen.filter(row=>row.path.endsWith("/listings")).at(-1)!;caller.abort();await handled;assert.equal(abandoned.wire.signal?.aborted,true);
  f.clearGates();let freshError:unknown;const fresh=f.services.listListings(LIBRARY).catch(error=>{freshError=error;return[];});await tick();
  const startedBeforeOldReply=f.seen.filter(row=>row.path.endsWith("/listings")).length;
  // A late response from the cancelled flight contains no listing. It must
  // neither remove the newly mapped listing nor cache its abort as authority.
  gates.mapping.resolve(json(f.page([])));const rows=await fresh;await tick();
  assert.equal(freshError,undefined,"An active read must not inherit another caller's AbortError");assert.equal(startedBeforeOldReply,3);assert.equal(rows[0].id,LISTING);
  await f.services.listMedia(ORG,LISTING);assert.equal(f.seen.filter(row=>row.path.endsWith("/media")).length,1);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("cancelling one mapping waiter keeps another active waiter and its single transport alive",async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),refresh=f.services.loadWorkspace(undefined,LIBRARY);await gates.directoryStarted;gates.directory.resolve(json(f.directory()));await refresh;
  const caller=new AbortController(),cancelled=f.services.listMedia(ORG,LISTING,caller.signal),handled=assert.rejects(cancelled,error=>error instanceof Error&&error.name==="AbortError");await gates.mappingStarted;
  const kept=f.services.listListings(LIBRARY);await tick();const shared=f.seen.filter(row=>row.path.endsWith("/listings")).at(-1)!;
  caller.abort();await handled;assert.equal(shared.wire.signal?.aborted,false);gates.mapping.resolve(json(f.page()));assert.equal((await kept)[0].id,LISTING);
  assert.equal(f.seen.filter(row=>row.path.endsWith("/listings")).length,2);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});

test("a genuine current mapping transport failure stays visible and never retries a mutation",async()=>{
 const f=fixture();try{await f.open();const gates=f.gates(),refresh=f.services.loadWorkspace(undefined,LIBRARY);await gates.directoryStarted;gates.directory.resolve(json(f.directory()));await refresh;
  const first=f.services.listMedia(ORG,LISTING),handled=assert.rejects(first,error=>error instanceof Error&&"code"in error&&error.code==="network");await gates.mappingStarted;
  gates.mapping.reject(new TypeError("Synthetic current transport failure"));await handled;
  const mappings=f.seen.filter(row=>row.path.endsWith("/listings")).length;await assert.rejects(f.services.listMedia(ORG,LISTING),error=>error instanceof Error&&"code"in error&&error.code==="network");
  assert.equal(f.seen.filter(row=>row.path.endsWith("/listings")).length,mappings);assert.equal(f.seen.filter(row=>row.path.endsWith("/media")).length,0);assert.equal(f.actions().length,0);
 }finally{f.services.dispose();}
});
