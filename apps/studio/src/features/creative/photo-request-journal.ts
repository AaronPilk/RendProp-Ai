/** Durable private paid-operation identity. No credential, URL target or account
 * token is retained. A pending row can only be replayed, never replaced. */
import type {PhotoSource} from "./photo-lineage";
import {PHOTO_OUTPUT_WIRE_BYTES} from "../../data/photo-output";
import type {Edit} from "./model";
export type PhotoRequestScope={actor:string;library:string;listing:string};
export type PhotoRequestContext={channel:"single"|"batch";source:PhotoSource;edit:Edit;style:string;prompt:string;originalAssetId:string;photoId?:string;batchId?:string};
export type SavedPhotoRequest={schema:1;slot:string;scope:string;identity:PhotoRequestScope;sourceId:string;versionId:string;requestKey:string;requestJSON:string;requestSHA:string;context:PhotoRequestContext;state:"pending"|"ready";resultJSON?:string;resultSHA?:string;createdAt:number};
const DB="rendprop-photo-requests-v1",STORE="requests",UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i,SHA=/^[a-f0-9]{64}$/;
const unavailable=()=>new Error("The photo request could not be confirmed. Your original is unchanged. Allow browser storage and reopen this property before trying again.");
function request<T>(r:IDBRequest<T>):Promise<T>{return new Promise((resolve,reject)=>{r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(unavailable());});}
function complete(tx:IDBTransaction):Promise<void>{return new Promise((resolve,reject)=>{tx.oncomplete=()=>resolve();tx.onabort=tx.onerror=()=>reject(unavailable());});}
async function database():Promise<IDBDatabase>{
 if(typeof indexedDB==="undefined")throw unavailable();
 const open=indexedDB.open(DB,1);open.onupgradeneeded=()=>open.result.createObjectStore(STORE,{keyPath:"slot"}).createIndex("scope","scope");
 return await request(open);
}
export function photoRequestScope(value:PhotoRequestScope):string{
 if(![value.actor,value.library,value.listing].every(v=>UUID.test(v)))throw unavailable();return[value.actor,value.library,value.listing].map(v=>v.toLowerCase()).join(":");
}
const hash=async(bytes:BufferSource)=>Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),b=>b.toString(16).padStart(2,"0")).join("");
export const photoRequestHash=(value:string)=>hash(new TextEncoder().encode(value));
export async function validateSavedPhotoRequest(row:SavedPhotoRequest,identity:PhotoRequestScope):Promise<SavedPhotoRequest>{
 const scope=photoRequestScope(identity);
 if(row?.schema!==1||row.scope!==scope||photoRequestScope(row.identity)!==scope||!SHA.test(row.sourceId)||!SHA.test(row.versionId)||row.slot!==scope+":"+row.sourceId||!/^studio-photo:[a-f0-9-]{36}$/i.test(row.requestKey)||typeof row.requestJSON!=="string"||row.requestJSON.length>1_600_000||await photoRequestHash(row.requestJSON)!==row.requestSHA||!["pending","ready"].includes(row.state))throw unavailable();
 const body=JSON.parse(row.requestJSON),original=row.context?.source?.original?.file;
 const prepared=body.edit==="stage"&&row.context?.source?.stageBase?row.context.source.stageBase:row.context?.source;
 if(prepared?.base64!==body.image_b64||prepared?.mime!==body.mime||body.edit==="stage"&&body.style!==row.context.style||body.edit==="custom"&&body.prompt!==row.context.prompt)throw unavailable();
 if(body.listing_id?.toLowerCase()!==identity.listing.toLowerCase()||body.original_asset_id!==row.context.originalAssetId||body.edit!==row.context.edit||typeof body.image_b64!=="string"||await photoRequestHash(body.image_b64)!==row.versionId||!(original instanceof Blob)||await hash(await original.arrayBuffer())!==row.sourceId||row.state==="ready"&&(typeof row.resultJSON!=="string"||row.resultJSON.length>PHOTO_OUTPUT_WIRE_BYTES||!SHA.test(row.resultSHA??"")||await photoRequestHash(row.resultJSON)!==row.resultSHA))throw unavailable();
 return row;
}
export async function beginPhotoRequest(identity:PhotoRequestScope,body:Record<string,unknown>,context:PhotoRequestContext,signal?:AbortSignal):Promise<SavedPhotoRequest>{
 signal?.throwIfAborted();const scope=photoRequestScope(identity),original=context.source.original?.file;
 if(!(original instanceof Blob)||!context.source.originalVerified||typeof body.image_b64!=="string"||body.listing_id!==identity.listing||body.original_asset_id!==context.originalAssetId)throw unavailable();
 const sourceId=await hash(await original.arrayBuffer()),versionId=await photoRequestHash(body.image_b64),requestJSON=JSON.stringify(body);
 if(requestJSON.length>1_600_000)throw unavailable();
 const row:SavedPhotoRequest={schema:1,slot:scope+":"+sourceId,scope,identity:{...identity},sourceId,versionId,requestKey:"studio-photo:"+crypto.randomUUID(),requestJSON,requestSHA:await photoRequestHash(requestJSON),context,state:"pending",createdAt:Date.now()};
 signal?.throwIfAborted();const db=await database();let saved:SavedPhotoRequest;
 try{const tx=db.transaction(STORE,"readwrite"),done=complete(tx);void done.catch(()=>{});const store=tx.objectStore(STORE),existing=await request(store.get(row.slot))as SavedPhotoRequest|undefined;
  signal?.throwIfAborted();saved=existing??row;if(!existing)store.put(row);await done;
 }finally{db.close();}
 signal?.throwIfAborted();return await validateSavedPhotoRequest(saved,identity);
}
export async function savedPhotoRequests(identity:PhotoRequestScope):Promise<SavedPhotoRequest[]>{
 const db=await database();let rows:SavedPhotoRequest[];try{rows=await request(db.transaction(STORE,"readonly").objectStore(STORE).index("scope").getAll(photoRequestScope(identity)));}finally{db.close();}
 const checked:SavedPhotoRequest[]=[];for(const row of rows.sort((a,b)=>a.createdAt-b.createdAt))checked.push(await validateSavedPhotoRequest(row,identity));return checked;
}
export async function readyPhotoRequest(row:SavedPhotoRequest,result:unknown):Promise<SavedPhotoRequest>{
 const resultJSON=JSON.stringify(result);if(!resultJSON||resultJSON.length>PHOTO_OUTPUT_WIRE_BYTES)throw unavailable();const resultSHA=await photoRequestHash(resultJSON);const db=await database();let saved:SavedPhotoRequest;
 try{const tx=db.transaction(STORE,"readwrite"),done=complete(tx);void done.catch(()=>{});const store=tx.objectStore(STORE),current=await request(store.get(row.slot))as SavedPhotoRequest|undefined;
  if(!current||current.requestKey!==row.requestKey||current.requestSHA!==row.requestSHA){tx.abort();await done.catch(()=>{});throw unavailable();}
  saved=current.state==="ready"?current:{...current,state:"ready",resultJSON,resultSHA};store.put(saved);await done;
 }finally{db.close();}return saved;
}
/** Only a confirmed terminal refusal/no-dispatch, a saved gallery result, or an
 * explicit new edit after a ready preview may release this operation slot. */
export async function finishPhotoRequest(row:SavedPhotoRequest,definitive=false):Promise<void>{
 const db=await database();try{const tx=db.transaction(STORE,"readwrite"),done=complete(tx);void done.catch(()=>{});const store=tx.objectStore(STORE),current=await request(store.get(row.slot))as SavedPhotoRequest|undefined;
  if(current?.requestKey===row.requestKey){if(current.state!=="ready"&&!definitive){tx.abort();await done.catch(()=>{});throw unavailable();}store.delete(row.slot);}await done;
 }finally{db.close();}
}

export async function matchingPhotoRequest(identity:PhotoRequestScope,source:PhotoSource):Promise<SavedPhotoRequest|null>{
 const original=source.original?.file;if(!(original instanceof Blob))throw unavailable();const sourceId=await hash(await original.arrayBuffer());
 return(await savedPhotoRequests(identity)).find(row=>row.sourceId===sourceId)??null;
}
