import type { StudioServices } from "../../data/services";
import { isPrivateMediaURL, privateMediaCapability } from "../../data/private-media";
import { mediaURL } from "../../data/contracts";
import type { GalleryScope } from "./gallery-selection";
import { fingerprintFile, uploadListingAsset, type UploadJournal } from "./uploads";

const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SHA=/^[a-f0-9]{64}$/;const MAX=10*1024**2;
type ObjectRef={asset_id:string;key:string;bytes:number;sha256:string;mime:string;kind:"original"|"altered";provenance:null|{id:string;original_asset_id:string;disclosure:string}};
export type GalleryCopy={schema:1;actor_id:string;org_id:string;library_org_id:string;listing_id:string;operation_id:string;source:ObjectRef;destination_asset_id:string|null;complete:boolean;photo:null|{id:string;listing_id:string};download:null|{url:string;expires_at:string}};
type Journal={schema:1;scope:GalleryScope;sourceId:string;operationId:string;sourceSHA?:string;upload?:UploadJournal};
const problem=()=>new Error("This saved photo could not be verified. Refresh and resume the same photo.");
export function decodeGalleryCopy(value:unknown,scope:GalleryScope,sourceId:string):GalleryCopy{
 if(!value||typeof value!=="object"||Array.isArray(value))throw problem();const r=value as GalleryCopy;
 if(r.schema!==1||r.actor_id!==scope.actor||r.org_id!==scope.org||r.library_org_id!==scope.library||r.listing_id!==scope.listing||!UUID.test(r.operation_id)||r.source?.asset_id!==sourceId||
  !Number.isSafeInteger(r.source.bytes)||r.source.bytes<1||r.source.bytes>MAX||!SHA.test(r.source.sha256)||!["image/jpeg","image/png","image/webp"].includes(r.source.mime)||
  typeof r.source.key!=="string"||!r.source.key.startsWith(`renders/${scope.org}/${scope.listing}/`)||r.source.key.includes("..")||/[?#%\\\u0000-\u001f]/.test(r.source.key)||
  !["original","altered"].includes(r.source.kind)||typeof r.complete!=="boolean"||!(r.destination_asset_id===null||typeof r.destination_asset_id==="string"&&UUID.test(r.destination_asset_id)))throw problem();
 if(r.source.kind==="original"?r.source.provenance!==null:!r.source.provenance||!UUID.test(r.source.provenance.id)||!UUID.test(r.source.provenance.original_asset_id)||!r.source.provenance.disclosure?.trim())throw problem();
 if(r.complete){if(r.download!==null||r.photo?.id!==r.destination_asset_id||r.photo?.listing_id!==scope.listing)throw problem();}
 else{
  if(!r.download||!Number.isFinite(Date.parse(r.download.expires_at))||Date.parse(r.download.expires_at)<=Date.now())throw problem();
  // The existing server supports both its signed gateway and scoped SigV4
  // downloads. Validate either transport without changing delivery settings.
  mediaURL(r.download.url,scope.org,scope.listing,r.download.expires_at,Date.now(),scope.actor);
  if(isPrivateMediaURL(r.download.url)){
   privateMediaCapability(r.download.url,{actor:scope.actor,org:scope.org,listing:scope.listing,bucket:"renders",key:r.source.key});
  }else{
   const path=new URL(r.download.url).pathname.slice(1).split("/").map(decodeURIComponent);
   if(path.slice(1).join("/")!==r.source.key)throw problem();
  }
 }
 return r;
}
function key(scope:GalleryScope,sourceId:string){return`rendprop:gallery-copy:1:${scope.actor}:${scope.library}:${scope.org}:${scope.listing}:${sourceId}`;}
async function readExactPhoto(copy:GalleryCopy,signal:AbortSignal,assertCurrent:()=>void):Promise<File>{
 const source=copy.source;assertCurrent();
 const response=await fetch(copy.download!.url,{credentials:"omit",redirect:"error",signal:AbortSignal.any([signal,AbortSignal.timeout(90_000)])});assertCurrent();
 if(!response.ok||!response.body)throw new Error("The saved photo could not download. Resume the same photo; its original is unchanged.");
 const declared=response.headers.get("content-length"),mime=(response.headers.get("content-type")??"").split(";")[0].trim().toLowerCase();
 if(declared!==null&&(!/^\d+$/.test(declared)||Number(declared)!==source.bytes)||mime!==source.mime){void response.body.cancel();throw problem();}
 const reader=response.body.getReader(),chunks:Uint8Array[]=[];let size=0;
 try{for(;;){const next=await reader.read();assertCurrent();if(next.done)break;size+=next.value.length;if(size>source.bytes||size>MAX)throw problem();chunks.push(next.value);}}
 finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
 if(size!==source.bytes)throw problem();const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 const sha=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),n=>n.toString(16).padStart(2,"0")).join("");assertCurrent();if(sha!==source.sha256)throw new Error("The saved photo changed. No replacement or compressed copy was used.");
 const extension=source.mime==="image/jpeg"?"jpg":source.mime==="image/png"?"png":"webp";
 return new File([bytes],`saved-${source.asset_id}.${extension}`,{type:source.mime});
}
/** A prepare operation saves private history only. Listing selection is a separate explicit action. */
export async function prepareGalleryCopy(services:StudioServices,scope:GalleryScope,sourceId:string,caption:string,signal:AbortSignal,
 options:{storage?:Storage;upload?:typeof uploadListingAsset;progress?:(message:string)=>void}={}):Promise<GalleryCopy>{
 const actor=services.getSnapshot(),storage=options.storage??localStorage,storageKey=key(scope,sourceId);
 const assertCurrent=()=>{signal.throwIfAborted();const now=services.getSnapshot();if(actor.identityVersion!==now.identityVersion||now.status!=="signed-in"||now.identity?.userId!==scope.actor)throw new Error("Your account changed. Reopen this property before preparing photos.");};
 assertCurrent();if(!UUID.test(sourceId))throw problem();
 let journal:Journal;const raw=storage.getItem(storageKey);
 if(raw){try{const v=JSON.parse(raw);if(raw.length>20_000||v.schema!==1||v.sourceId!==sourceId||JSON.stringify(v.scope)!==JSON.stringify(scope)||!UUID.test(v.operationId)||v.sourceSHA!==undefined&&!SHA.test(v.sourceSHA))throw problem();journal=v;}catch{throw problem();}}
 else journal={schema:1,scope:{...scope},sourceId,operationId:crypto.randomUUID()};
 const persist=()=>{assertCurrent();storage.setItem(storageKey,JSON.stringify(journal));};persist();
 // Bind every internal upload/copy step to the logical library that mounted this action.
 // This is a local fence: API headers, bodies, upload keys and durable journals stay unchanged.
 const scopedServices:StudioServices={...services,
  api:(path,request)=>services.api(path,{...request,expectedLibraryOrgId:scope.library}),
  upload:(url,body,request)=>services.upload(url,body,{...request,expectedLibraryOrgId:scope.library}),
 };
 const api=async(body:Record<string,unknown>)=>{const result=decodeGalleryCopy(await scopedServices.api("/functions/v1/studio/photo-copy",{orgId:scope.org,method:"POST",body:{listing_id:scope.listing,operation_id:journal.operationId,...body},signal,timeoutMs:120_000}),scope,sourceId);assertCurrent();return result;};
 options.progress?.("Checking this saved photo…");
 let copy=await api({action:"prepare",source_asset_id:sourceId,caption:caption.slice(0,500)});
 if(journal.sourceSHA!==undefined&&journal.sourceSHA!==copy.source.sha256)throw problem();
 if(journal.upload&&journal.operationId!==copy.operation_id)throw problem();
 journal={...journal,operationId:copy.operation_id,sourceSHA:copy.source.sha256};persist();
 if(copy.complete){storage.removeItem(storageKey);return copy;}
 options.progress?.("Preparing your saved photo…");const file=await readExactPhoto(copy,signal,assertCurrent);
 if(!journal.upload){journal.upload={version:1,userId:scope.actor,orgId:scope.org,listingId:scope.listing,filename:file.name,bytes:file.size,contentType:file.type,role:"gallery",fingerprint:await fingerprintFile(file,signal),operationId:copy.operation_id,assetId:copy.destination_asset_id??undefined,parts:[],updatedAt:new Date().toISOString()};persist();}
 if(copy.destination_asset_id&&journal.upload.assetId&&journal.upload.assetId!==copy.destination_asset_id)throw problem();
 if(copy.destination_asset_id&&!journal.upload.assetId){journal.upload={...journal.upload,assetId:copy.destination_asset_id};persist();}
 await(options.upload??uploadListingAsset)(scopedServices,{orgId:scope.org,listingId:scope.listing,file,role:"gallery",signal,resume:journal.upload,
  onJournal:value=>{journal={...journal,upload:value};persist();},
  onReserved:async assetId=>{const bound=await api({action:"bind",destination_asset_id:assetId});if(bound.operation_id!==copy.operation_id||bound.destination_asset_id!==assetId)throw problem();copy=bound;},
 });assertCurrent();
 options.progress?.("Verifying the saved version…");
 copy=await api({action:"finish"});if(!copy.complete||copy.operation_id!==journal.operationId)throw problem();
 storage.removeItem(storageKey);return copy;
}
