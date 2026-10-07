import { assert, HttpError } from "../_shared/http.ts";
import { R2_BUCKET_RENDERS, headObject } from "../_shared/r2.ts";
import { MAX_INLINE_IMAGE_BYTES, persistResult, presignGet, bytesToB64 } from "../_shared/providers/common.ts";
import type { DoneState } from "../_shared/providers/types.ts";
import { admitMediaRead } from "../_shared/media-delivery-admission.ts";
import { assertHostingAvailable } from "../_shared/hosting-retention.ts";

type Row = Record<string, unknown>;
export interface PhotoResultIdentity { actorId:string; orgId:string; requestKey:string; listingId:string|null }
export interface PhotoResultPointer { kind:"photo_output"; bucket:"renders"; key:string; mime:string; metadata:Record<string,unknown> }
export interface PhotoResultDependencies {
  head(key:string):Promise<{exists:boolean;bytes:number|null}>;
  sign(key:string):Promise<string>;
  read(url:string):Promise<Response>;
  persist(state:DoneState,key:string,beforeWrite:(intent:{key:string;bytes:number})=>Promise<void>):Promise<{key:string;bytes:number}>;
}
const mimeExtensions:Record<string,string>={"image/jpeg":"jpg","image/png":"png","image/webp":"webp"};
const actual:PhotoResultDependencies={head:key=>headObject(R2_BUCKET_RENDERS,key),sign:key=>presignGet(R2_BUCKET_RENDERS,key,600),read:url=>fetch(url,{method:"GET",credentials:"omit",redirect:"error",signal:AbortSignal.timeout(30_000)}),persist:(state,key,before)=>persistResult("saved-photo",state,key,before,true)};
export async function photoResultKeys(identity:PhotoResultIdentity):Promise<Record<string,string>> {
 const digest=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(JSON.stringify({v:1,...identity})))),byte=>byte.toString(16).padStart(2,"0")).join("");
 return Object.fromEntries(Object.entries(mimeExtensions).map(([mime,extension])=>[mime,`ai-router/${identity.orgId}/completed-photo/${digest}.${extension}`]));
}
async function authority(admin:any,identity:PhotoResultIdentity,key:string,bytes:number) {
 const membership=await admin.from("memberships").select("user_id,org_id,role").eq("user_id",identity.actorId).eq("org_id",identity.orgId).maybeSingle();
 assert(!membership.error&&membership.data?.user_id===identity.actorId&&membership.data?.org_id===identity.orgId&&["owner","admin","agent"].includes(membership.data.role),403,"The saved photo is unavailable for this account.");
 const {data,error}=await admin.rpc("register_private_ai_output",{p_user:identity.actorId,p_org:identity.orgId,p_listing:identity.listingId,p_bucket:"renders",p_key:key,p_bytes:bytes});
 assert(!error&&data?.ok===true&&data.key===key,403,"The saved photo is unavailable for this account.");
}
async function receipt(admin:any,identity:PhotoResultIdentity,keys:Record<string,string>,pointer?:PhotoResultPointer):Promise<{key:string;mime:string;bytes:number}|null> {
 if(pointer)assert(pointer.kind==="photo_output"&&pointer.bucket==="renders"&&keys[pointer.mime]===pointer.key,403,"The saved photo identity could not be verified.");
 let query=admin.from("private_ai_outputs").select("org_id,user_id,listing_id,bucket,storage_key,bytes").eq("org_id",identity.orgId).eq("user_id",identity.actorId).eq("bucket","renders").in("storage_key",Object.values(keys));
 query=identity.listingId===null?query.is("listing_id",null):query.eq("listing_id",identity.listingId);
 const {data,error}=await query.limit(2);
 assert(!error&&Array.isArray(data)&&data.length<=1,503,"The saved photo receipt could not be verified.");
 if(!data.length)return null;
 const row=data[0] as Row,mime=Object.keys(keys).find(mime=>keys[mime]===row.storage_key),bytes=Number(row.bytes);
 assert(mime&&row.org_id===identity.orgId&&row.user_id===identity.actorId&&row.listing_id===identity.listingId&&row.bucket==="renders"&&Number.isSafeInteger(bytes)&&bytes>0&&bytes<=MAX_INLINE_IMAGE_BYTES&&(!pointer||pointer.key===row.storage_key),403,"The saved photo identity could not be verified.");
 return {key:String(row.storage_key),mime,bytes};
}
export async function boundedPhotoResultBytes(response:Response,expected:number):Promise<Uint8Array<ArrayBuffer>> {
 assert(response.status===200&&response.body,503,"The saved photo could not be downloaded.");
 const declared=response.headers.get("content-length");
 assert(declared===null||Number(declared)===expected,503,"The saved photo size changed.");
 const reader=response.body.getReader(),bytes=new Uint8Array(expected);let length=0,empty=0;
 let expired=false,timer:ReturnType<typeof setTimeout>|undefined;
 const timeout=new Promise<never>((_,reject)=>{timer=setTimeout(()=>{expired=true;void reader.cancel().catch(()=>{});reject(new HttpError(503,"The saved photo download timed out."));},30_000);});
 const read=async()=>{while(true){const {value,done}=await reader.read();assert(!expired,503,"The saved photo download timed out.");if(done)break;
  assert(value instanceof Uint8Array&&value.byteLength<=expected-length,503,"The saved photo size changed.");
  if(!value.byteLength){assert(++empty<=64,503,"The saved photo download made no progress.");continue;}empty=0;
  bytes.set(value,length);length+=value.byteLength;
 }};
 try{await Promise.race([read(),timeout]);}
 catch(error){void reader.cancel().catch(()=>{});throw error;}
 finally{clearTimeout(timer);}
 assert(length===expected,503,"The saved photo size changed.");
 return bytes;
}
/** Replay reads one exact actor-owned journal object. No provider transport,
 * saved capability, prefix authorization, redirect or extra GET headers. */
export async function restorePhotoResult(admin:any,identity:PhotoResultIdentity,pointer?:PhotoResultPointer,deps=actual):Promise<{key:string;mime:string;image_b64:string}|null> {
 const keys=await photoResultKeys(identity),saved=await receipt(admin,identity,keys,pointer);if(!saved)return null;
 await authority(admin,identity,saved.key,saved.bytes);
 await assertHostingAvailable(admin,identity.orgId);
 await admitMediaRead(admin,identity.orgId,saved.bytes,false);
 const head=await deps.head(saved.key);assert(head.exists&&head.bytes===saved.bytes,503,"The saved photo could not be verified.");
 const url=await deps.sign(saved.key);
 await authority(admin,identity,saved.key,saved.bytes);
 const response=await deps.read(url),type=response.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
 if(type&&type!==saved.mime){void response.body?.cancel().catch(()=>{});throw new HttpError(503,"The saved photo format changed.");}
 const bytes=await boundedPhotoResultBytes(response,saved.bytes);
 await authority(admin,identity,saved.key,saved.bytes);
 return{key:saved.key,mime:saved.mime,image_b64:bytesToB64(bytes)};
}
/** Every generated photo, including router-off, gets one immutable owned copy.
 * Journal before PUT; failures after generation never authorize paid fallback. */
export async function persistOwnedPhotoResult(admin:any,identity:PhotoResultIdentity,state:DoneState,deps=actual):Promise<{key:string;mime:string}> {
 const mime=state.mime.split(";")[0].trim().toLowerCase(),keys=await photoResultKeys(identity),key=keys[mime];
 assert(key,503,"The generated photo format cannot be saved.");
 const stored=await deps.persist(state,key,async intent=>{assert(intent.key===key&&Number.isSafeInteger(intent.bytes)&&intent.bytes>0&&intent.bytes<=MAX_INLINE_IMAGE_BYTES,503,"The generated photo receipt could not be verified.");await authority(admin,identity,key,intent.bytes);});
 assert(stored.key===key,503,"The generated photo identity changed.");
 const saved=await receipt(admin,identity,keys);assert(saved&&saved.key===key&&saved.bytes===stored.bytes,503,"The generated photo receipt could not be verified.");
 const head=await deps.head(key);assert(head.exists&&head.bytes===saved.bytes,503,"The generated photo could not be verified.");
 await authority(admin,identity,key,saved.bytes);return{key,mime};
}
