import { assert, HttpError, json, readJsonLimited } from "../_shared/http.ts";
import { listingLibraryScope } from "../_shared/library-access.ts";
import { privateMediaUrl } from "../_shared/private-media.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { R2_BUCKET_RENDERS } from "../_shared/r2.ts";

const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SHA=/^[a-f0-9]{64}$/;const MAX=10*1024**2;
type Row=Record<string,any>;
type Context={userId:string;orgId:string;admin?:any;authorizeListing(id:string):Promise<void>};
export type CopyObject=Row&{asset_id:string;key:string;bytes:number;mime:string;sha256?:string;uploaded?:boolean};
type Dependencies={read(object:CopyObject,signal:AbortSignal):Promise<{bytes:number;sha256:string;mime:string}>;sign(scope:{actor:string;org:string;listing:string;bucket:"renders";key:string}):Promise<string>};
const fail=()=>new HttpError(503,"The prepared photo could not be verified. Refresh and resume this same photo.");
function object(v:unknown):v is Row{return !!v&&typeof v==="object"&&!Array.isArray(v);}
function media(v:unknown,org:string,listing:string,gallery:boolean):v is CopyObject{
 if(!object(v)||!UUID.test(v.asset_id)||!Number.isSafeInteger(v.bytes)||v.bytes<1||v.bytes>MAX||!["image/jpeg","image/png","image/webp"].includes(v.mime))return false;
 return typeof v.key==="string"&&v.key.startsWith(`renders/${org}/${listing}/${gallery?"gallery-":""}`)&&v.key.length<=1023&&!v.key.includes("..")&&!/[?#%\\\u0000-\u001f]/.test(v.key);
}
export function checkedGalleryCopy(v:unknown,scope:{actor:string;org:string;library:string;listing:string}):Row{
 if(!object(v)||v.schema!==1||v.actor_id!==scope.actor||v.org_id!==scope.org||v.library_org_id!==scope.library||v.listing_id!==scope.listing||!UUID.test(v.operation_id)||
  !media(v.source,scope.org,scope.listing,false)||typeof v.source.sha256!=="string"||!SHA.test(v.source.sha256)||!["original","altered"].includes(v.source.kind)||typeof v.complete!=="boolean"||
  !(v.destination_asset_id===null||typeof v.destination_asset_id==="string"&&UUID.test(v.destination_asset_id))||
  !(v.destination===null?v.destination_asset_id===null:media(v.destination,scope.org,scope.listing,true)&&v.destination.asset_id===v.destination_asset_id&&v.destination.bytes===v.source.bytes&&v.destination.mime===v.source.mime&&typeof v.destination.uploaded==="boolean"))throw fail();
 if(v.source.kind==="original"?v.source.provenance!==null:!object(v.source.provenance)||!UUID.test(v.source.provenance.id)||!UUID.test(v.source.provenance.original_asset_id)||typeof v.source.provenance.disclosure!=="string"||!v.source.provenance.disclosure.trim())throw fail();
 if(v.complete&&(!object(v.photo)||v.photo.id!==v.destination_asset_id||v.photo.listing_id!==scope.listing||v.destination?.uploaded!==true))throw fail();
 return v;
}
function rpcError(error:any){if(!error)return;const match=/^RP(400|403|404|409): (.{1,240})$/.exec(String(error.message));throw new HttpError(match?Number(match[1]):503,match?match[2]:"This photo could not be prepared. Resume the same photo to check its status.");}
/** Bounded server-side byte verification. No browser digest is accepted as proof. */
export async function readGalleryCopyObject(o:CopyObject,signal:AbortSignal):Promise<{bytes:number;sha256:string;mime:string}>{
 const response=await fetch(await presignGet(R2_BUCKET_RENDERS,o.key,60),{signal:AbortSignal.any([signal,AbortSignal.timeout(60_000)]),redirect:"error"});
 return await verifyGalleryCopyResponse(response,o,signal);
}
export async function verifyGalleryCopyResponse(response:Response,o:CopyObject,signal:AbortSignal):Promise<{bytes:number;sha256:string;mime:string}>{
 assert(response.ok&&response.body,409,"This saved photo is unavailable. Its original is unchanged.");
 const length=response.headers.get("content-length"),mime=(response.headers.get("content-type")??"").split(";")[0].trim().toLowerCase();
 assert(length!==null&&/^\d+$/.test(length)&&Number(length)===o.bytes&&mime===o.mime,409,"Stored photo metadata changed. Refresh before preparing it.");
 const reader=response.body.getReader(),chunks:Uint8Array[]=[];let total=0;
 try{for(;;){const next=await reader.read();signal.throwIfAborted();if(next.done)break;total+=next.value.length;assert(total<=o.bytes&&total<=MAX,409,"The saved photo exceeds its verified size.");chunks.push(next.value);}}
 finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
 assert(total===o.bytes,409,"The saved photo download was incomplete. Resume the same photo.");
 const bytes=new Uint8Array(total);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 const actual=bytes[0]===255&&bytes[1]===216&&bytes[2]===255?"image/jpeg":[137,80,78,71,13,10,26,10].every((n,i)=>bytes[i]===n)?"image/png":new TextDecoder().decode(bytes.slice(0,4))==="RIFF"&&new TextDecoder().decode(bytes.slice(8,12))==="WEBP"?"image/webp":null;
 assert(actual===o.mime,409,"The saved photo format could not be verified.");
 const sha256=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),n=>n.toString(16).padStart(2,"0")).join("");
 return{bytes:total,sha256,mime};
}
export async function galleryCopyRequest(req:Request,context:Context,deps:Dependencies={read:readGalleryCopyObject,sign:scope=>privateMediaUrl(scope,600)}):Promise<Response>{
 assert(req.method==="POST",405,"Use Prepare for listing to save this photo for review.");
 const body=await readJsonLimited<Row>(req,8192);assert(object(body)&&["prepare","bind","finish"].includes(body.action)&&typeof body.listing_id==="string"&&UUID.test(body.listing_id)&&typeof body.operation_id==="string"&&UUID.test(body.operation_id),400,"Choose the saved photo to prepare.");
 const allowed=body.action==="prepare"?["action","listing_id","operation_id","source_asset_id","caption"]:body.action==="bind"?["action","listing_id","operation_id","destination_asset_id"]:["action","listing_id","operation_id"];
 assert(Object.keys(body).every(k=>allowed.includes(k)),400,"The prepared photo request contains unexpected data.");
 await context.authorizeListing(body.listing_id);assert(context.admin,503,"Photo preparation is temporarily unavailable.");
 const scope=await listingLibraryScope(context.admin,context.userId,body.listing_id,true);assert(scope.org_id===context.orgId,404,"Property not found in this workspace.");
 const identity={actor:context.userId,org:context.orgId,library:scope.library_org_id,listing:body.listing_id};
 const common={p_actor:context.userId,p_org:context.orgId,p_listing:body.listing_id,p_operation:body.operation_id};
 const rpc=async(name:string,args:Row)=>{const {data,error}=await context.admin.rpc(name,args);rpcError(error);return checkedGalleryCopy(data,identity);};
 let result:Row;
 if(body.action==="prepare"){
  assert(typeof body.source_asset_id==="string"&&UUID.test(body.source_asset_id)&&(body.caption===undefined||typeof body.caption==="string"&&body.caption.length<=500),400,"Choose a saved photo and short caption.");
  result=await rpc("studio_gallery_copy_prepare",{...common,p_source:body.source_asset_id,p_caption:body.caption??""});
  assert(result.source.asset_id===body.source_asset_id,503,"The saved photo source could not be confirmed.");
 }else if(body.action==="bind"){
  assert(typeof body.destination_asset_id==="string"&&UUID.test(body.destination_asset_id),400,"Resume this photo's saved upload.");
  result=await rpc("studio_gallery_copy_bind",{...common,p_destination:body.destination_asset_id});
  assert(result.operation_id===body.operation_id&&result.destination_asset_id===body.destination_asset_id,503,"The saved photo upload could not be confirmed.");
 }else{
  result=await rpc("studio_gallery_copy_status",common);
  assert(result.operation_id===body.operation_id,503,"The prepared photo request changed.");
  if(!result.complete){
   assert(result.destination?.uploaded===true,409,"Finish this photo's saved upload before preparing it.");
   const readSignal=AbortSignal.any([req.signal,AbortSignal.timeout(90_000)]);
   const source=await deps.read(result.source,readSignal),copy=await deps.read(result.destination,readSignal);
   assert(source.sha256===result.source.sha256&&copy.sha256===source.sha256&&source.bytes===result.source.bytes&&copy.bytes===source.bytes&&source.mime===result.source.mime&&copy.mime===source.mime,409,"The prepared copy is not the exact saved photo. No substitute was used.");
   await context.authorizeListing(body.listing_id);
   result=await rpc("studio_gallery_copy_finish",{...common,p_verified_sha256:source.sha256,p_verified_bytes:source.bytes});
   assert(result.complete===true,503,"The prepared photo is still pending. Resume the same photo.");
  }
 }
 await context.authorizeListing(body.listing_id);
 const download=result.complete?null:{url:await deps.sign({actor:context.userId,org:context.orgId,listing:body.listing_id,bucket:"renders",key:result.source.key}),expires_at:new Date(Date.now()+600_000).toISOString()};
 await context.authorizeListing(body.listing_id);
 return json({...result,download},200,{"cache-control":"private, no-store"});
}
