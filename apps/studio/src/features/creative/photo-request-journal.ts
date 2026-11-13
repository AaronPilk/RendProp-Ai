/** Durable private paid-operation identity. No credential, URL target or account
 * token is retained. A pending row can only be replayed, never replaced. */
import type {StudioServices} from "../../data/services";
import {sha256Bytes as hash,uploadListingAsset,validateUpload,type UploadJournal} from "../listings/uploads";
import type {PhotoSource} from "./photo-lineage";
import {PHOTO_OUTPUT_WIRE_BYTES,photoOutputSize} from "../../data/photo-output";
import type {Edit} from "./model";
export type PhotoRequestScope={actor:string;library:string;listing:string};
export type PhotoRequestContext={channel:"single"|"batch";source:PhotoSource;edit:Edit;style:string;prompt:string;originalAssetId:string;photoId?:string;batchId?:string};
export type SavedPhotoRequest={schema:1;slot:string;scope:string;identity:PhotoRequestScope;sourceId:string;versionId:string;requestKey:string;requestJSON:string;requestSHA:string;context:PhotoRequestContext;state:"pending"|"ready";resultJSON?:string;resultSHA?:string;createdAt:number;outputUpload?:UploadJournal};
const DB="rendprop-photo-requests-v1",STORE="requests",UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i,SHA=/^[a-f0-9]{64}$/;
export function photoUploadOperation(key:string):string{const value=key.startsWith("studio-photo:")?key.slice(13):"";if(!UUID.test(value))throw unavailable();return value.toLowerCase();}
function checkUpload(row:SavedPhotoRequest,j:UploadJournal){
 if(j.version!==1||j.userId!==row.identity.actor||!UUID.test(j.orgId)||j.listingId!==row.identity.listing||j.role!=="gallery"||j.operationId!==photoUploadOperation(row.requestKey)||!UUID.test(j.assetId??""))throw unavailable();
}
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
export const photoRequestHash=(value:string)=>hash(new TextEncoder().encode(value));
export async function validateSavedPhotoRequest(row:SavedPhotoRequest,identity:PhotoRequestScope):Promise<SavedPhotoRequest>{
 const scope=photoRequestScope(identity);
 if(row?.schema!==1||row.scope!==scope||photoRequestScope(row.identity)!==scope||!SHA.test(row.sourceId)||!SHA.test(row.versionId)||row.slot!==scope+":"+row.sourceId||!/^studio-photo:[a-f0-9-]{36}$/i.test(row.requestKey)||typeof row.requestJSON!=="string"||row.requestJSON.length>1_600_000||await photoRequestHash(row.requestJSON)!==row.requestSHA||!["pending","ready"].includes(row.state))throw unavailable();
 const body=JSON.parse(row.requestJSON),original=row.context?.source?.original?.file;
 const prepared=body.edit==="stage"&&row.context?.source?.stageBase?row.context.source.stageBase:row.context?.source;
 if(prepared?.base64!==body.image_b64||prepared?.mime!==body.mime||body.edit==="stage"&&body.style!==row.context.style||body.edit==="custom"&&body.prompt!==row.context.prompt)throw unavailable();
 if(body.listing_id?.toLowerCase()!==identity.listing.toLowerCase()||body.original_asset_id!==row.context.originalAssetId||body.edit!==row.context.edit||typeof body.image_b64!=="string"||await photoRequestHash(body.image_b64)!==row.versionId||!(original instanceof Blob)||await hash(await original.arrayBuffer())!==row.sourceId||row.state==="ready"&&(typeof row.resultJSON!=="string"||row.resultJSON.length>PHOTO_OUTPUT_WIRE_BYTES||!SHA.test(row.resultSHA??"")||await photoRequestHash(row.resultJSON)!==row.resultSHA))throw unavailable();
 if(row.outputUpload){if(row.state!=="ready")throw unavailable();checkUpload(row,row.outputUpload);}
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
/** One transaction owns every update to an existing paid-operation slot. */
async function changePhotoRequest<T>(row:SavedPhotoRequest,apply:(current:SavedPhotoRequest|undefined,store:IDBObjectStore)=>T):Promise<T>{
 const db=await database();try{const tx=db.transaction(STORE,"readwrite"),done=complete(tx);void done.catch(()=>{});const store=tx.objectStore(STORE),current=await request(store.get(row.slot))as SavedPhotoRequest|undefined;let result:T;
  try{result=apply(current,store);}catch(error){tx.abort();await done.catch(()=>{});throw error;}await done;return result;
 }finally{db.close();}
}
export async function readyPhotoRequest(row:SavedPhotoRequest,result:unknown):Promise<SavedPhotoRequest>{
 const resultJSON=JSON.stringify(result);if(!resultJSON||resultJSON.length>PHOTO_OUTPUT_WIRE_BYTES)throw unavailable();const resultSHA=await photoRequestHash(resultJSON);
 return changePhotoRequest(row,(current,store)=>{
  if(!current||current.requestKey!==row.requestKey||current.requestSHA!==row.requestSHA)throw unavailable();
  const saved=current.state==="ready"?current:{...current,state:"ready"as const,resultJSON,resultSHA};store.put(saved);return saved;
 });
}
/** Only a confirmed terminal refusal/no-dispatch, a saved gallery result, or an
 * explicit new edit after a ready preview may release this operation slot. */
export async function finishPhotoRequest(row:SavedPhotoRequest,definitive=false):Promise<void>{
 await changePhotoRequest(row,(current,store)=>{if(current?.requestKey===row.requestKey){if(current.state!=="ready"&&!definitive)throw unavailable();store.delete(row.slot);}});
}

export async function matchingPhotoRequest(identity:PhotoRequestScope,source:PhotoSource):Promise<SavedPhotoRequest|null>{
 const original=source.original?.file;if(!(original instanceof Blob))throw unavailable();const sourceId=await hash(await original.arrayBuffer());
 return(await savedPhotoRequests(identity)).find(row=>row.sourceId===sourceId)??null;
}

/** Commit the exact reservation before PUT; retries renew it even after completion or reload. */
async function bindPhotoUpload(row:SavedPhotoRequest,journal:UploadJournal):Promise<void>{
 checkUpload(row,journal);await changePhotoRequest(row,(current,store)=>{
  if(!current||current.state!=="ready"||current.requestKey!==row.requestKey||current.requestSHA!==row.requestSHA||current.resultSHA!==row.resultSHA||current.outputUpload&&(current.outputUpload.assetId!==journal.assetId||current.outputUpload.fingerprint!==journal.fingerprint||current.outputUpload.operationId!==journal.operationId))throw unavailable();
  store.put({...current,outputUpload:current.outputUpload??journal});
 });
}
export async function uploadSavedPhotoResult(services:StudioServices,identity:PhotoRequestScope,orgId:string,key:string,file:File,signal:AbortSignal,assertScope:()=>void){
 const check=()=>{signal.throwIfAborted();assertScope();};check();if(services.getSnapshot().identity?.userId!==identity.actor)throw unavailable();const operationId=photoUploadOperation(key),row=(await savedPhotoRequests(identity)).find(r=>r.requestKey===key);check();
 if(!row||row.state!=="ready")throw unavailable();validateUpload(file,"gallery");const result=JSON.parse(row.resultJSON!);
 if(result.mime!==file.type||photoOutputSize(result.image_b64)!==file.size)throw unavailable();const expected=atob(result.image_b64),bytes=new Uint8Array(await file.arrayBuffer());
 if(bytes.some((v,i)=>v!==expected.charCodeAt(i)))throw unavailable();check();let journal:UploadJournal|undefined;
 return uploadListingAsset(services,{orgId,listingId:identity.listing,file,role:"gallery",signal,operationId,resume:row.outputUpload,onJournal:j=>{journal=j;},onReserved:async()=>{await bindPhotoUpload(row,journal!);check();}});
}
