import {assert,HttpError,json,pathSegments,readJsonLimited} from "../_shared/http.ts";
import {R2_BUCKET_UPLOADS,writeStudioChunk,inspectStudioChunk} from "../_shared/r2.ts";
import {presignGet} from "../_shared/providers/common.ts";
import type {StudioContext} from "./context.ts";
export const PROJECT_CHUNK_BYTES=8*1024*1024;
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const HASH=/^[a-f0-9]{64}$/;
const TYPES=["image/jpeg","image/png","image/webp","video/mp4","video/quicktime","video/webm","audio/mpeg","audio/mp4","audio/wav","audio/x-wav","audio/wave","audio/ogg","audio/webm"];
export type ProjectMediaRow={id:string;actor_id:string;org_id:string;sha256:string;bytes:number;mime:string;filename:string;modified:number;parts:number;write_deadline:string;receipts:Record<string,{sha256:string;bytes:number;state:string}>};
export function projectMediaInput(input:Record<string,unknown>){
 assert(typeof input.id==="string"&&UUID.test(input.id)&&typeof input.sha256==="string"&&HASH.test(input.sha256),400,"Choose a valid original file.");
 assert(Number.isSafeInteger(input.bytes)&&Number(input.bytes)>0&&Number(input.bytes)<=128*1024*1024,413,"Project originals support up to 128 MiB per file.");
 assert(typeof input.mime==="string"&&TYPES.includes(input.mime)&&typeof input.filename==="string"&&input.filename.length>0&&input.filename.length<=255&&!/[\u0000-\u001f]/.test(input.filename),400,"Choose a supported photo, video or music file.");
 assert(Number.isSafeInteger(input.modified)&&Number(input.modified)>=0,400,"Invalid original file date.");
 return {id:input.id,sha256:input.sha256,bytes:input.bytes,mime:input.mime,filename:input.filename,modified:input.modified};
}
export function projectMediaComplete(row:ProjectMediaRow):boolean{return row.parts>0&&row.parts===Math.ceil(row.bytes/PROJECT_CHUNK_BYTES)&&Array.from({length:row.parts},(_,i)=>row.receipts[String(i)]).every((p,i)=>p?.state==="complete"&&HASH.test(p.sha256)&&p.bytes===Math.min(PROJECT_CHUNK_BYTES,row.bytes-i*PROJECT_CHUNK_BYTES));}
export function projectChunkKey(row:ProjectMediaRow,part:number):string{return `studio-project/${row.org_id}/${row.actor_id}/${row.id}/${part}`;}
/** The caller must authorize this row; this helper never accepts client keys. */
export async function projectMediaManifest(row:ProjectMediaRow,sign=presignGet){
 const complete=projectMediaComplete(row);
 return {id:row.id,sha256:row.sha256,bytes:row.bytes,mime:row.mime,filename:row.filename,modified:row.modified,complete,parts:await Promise.all(Array.from({length:row.parts},async(_,index)=>{const p=row.receipts[String(index)];return {index,bytes:Math.min(PROJECT_CHUNK_BYTES,row.bytes-index*PROJECT_CHUNK_BYTES),sha256:p?.sha256??null,complete:p?.state==="complete",...(complete?{url:await sign(R2_BUCKET_UPLOADS,projectChunkKey(row,index),120)}:{})};}))};
}
async function write(context:StudioContext,id:string,action:string,data:Record<string,unknown>,signal:AbortSignal){
 const result=await context.admin.rpc("studio_project_media_write",{p_actor:context.userId,p_org:context.orgId,p_id:id,p_action:action,p_data:data}).abortSignal(signal);
 if(result.error){const m=/^RP(400|403|404|409): ([^\r\n]{1,240})$/.exec(result.error.message??"");throw new HttpError(m?Number(m[1]):503,m?m[2]:"Project storage could not be confirmed.");}
 assert(result.data,503,"Project storage returned no confirmation.");return result.data;
}
async function binary(req:Request):Promise<Uint8Array<ArrayBuffer>>{
 assert(req.headers.get("content-type")?.split(";")[0]==="application/octet-stream",415,"Use a binary media part.");
 assert(Number(req.headers.get("content-length")??0)<=PROJECT_CHUNK_BYTES,413,"Upload part is too large.");
 const reader=req.body?.getReader();assert(reader,400,"Choose an upload part.");const parts:Uint8Array[]=[];let size=0;
 const signal=AbortSignal.any([req.signal,AbortSignal.timeout(30_000)]),cancel=()=>{void reader.cancel().catch(()=>{});};signal.addEventListener("abort",cancel,{once:true});
 try{for(;;){signal.throwIfAborted();const p=await reader.read();signal.throwIfAborted();if(p.done)break;size+=p.value.byteLength;assert(size<=PROJECT_CHUNK_BYTES,413,"Upload part is too large.");parts.push(p.value);}}finally{signal.removeEventListener("abort",cancel);void reader.cancel().catch(()=>{});reader.releaseLock();}
 assert(size>0,400,"The upload part is empty.");const result=new Uint8Array(size);let offset=0;for(const p of parts){result.set(p,offset);offset+=p.length;}return result;
}
/** An uncertain successful write can be recovered after the dispatch cap. */
export async function settleProjectPart(context:StudioContext,id:string,part:number,bytes:Uint8Array<ArrayBuffer>,hash:string,signal:AbortSignal,storage={inspect:inspectStudioChunk,write:writeStudioChunk}){
 const input={part,bytes:bytes.byteLength,sha256:hash};
 const checked=await write(context,id,"inspect",input,signal);
 const previous=checked.media.receipts[String(part)];
 let verified=previous?.state==="complete";
 if(previous&&!verified){const found=await storage.inspect(projectChunkKey(checked.media,part));signal.throwIfAborted();if(found){assert(found.bytes===bytes.byteLength&&found.sha256===hash,409,"Stored media does not match this upload part.");verified=true;}}
 if(!verified){
  const claimed=await write(context,id,"claim",input,signal);
  if(claimed.dispatch){signal.throwIfAborted();assert(Date.parse(claimed.media.write_deadline)>Date.now(),409,"This media upload expired.");await storage.write(projectChunkKey(claimed.media,part),bytes,hash);}
 }
 return (await write(context,id,"finish",input,signal)).media as ProjectMediaRow;
}
export async function handleProjectMedia(req:Request,context:StudioContext,manifest=projectMediaManifest):Promise<Response>{
 const seg=pathSegments(req,"studio"),url=new URL(req.url);const headers={"Cache-Control":"private, no-store"};
 const response=async(row:ProjectMediaRow|null)=>{
  if(!row)return json({media:null},200,headers);
  const media=await manifest(row);req.signal.throwIfAborted();
  // Signing can be asynchronous. Recheck current membership/deletion and the
  // exact private row before returning any download capability.
  const current=await write(context,row.id,"read",{},req.signal) as ProjectMediaRow;
  assert(current.id===row.id&&current.actor_id===row.actor_id&&current.org_id===row.org_id&&current.sha256===row.sha256&&current.bytes===row.bytes,409,"The saved original changed. Reload the project.");
  return json({media},200,headers);
 };
 if(seg.length===1&&req.method==="GET"){
  const id=url.searchParams.get("id"),hash=url.searchParams.get("sha256");assert((id&&UUID.test(id)&&!hash)||(!id&&hash&&HASH.test(hash)),400,"Choose one saved original.");
  let query=context.admin.from("studio_project_media").select("*").eq("actor_id",context.userId).eq("org_id",context.orgId);
  query=id?query.eq("id",id):query.eq("sha256",hash!);const result=await query.abortSignal(req.signal).maybeSingle();assert(!result.error,503,"Project originals could not be loaded.");
  return await response(result.data as ProjectMediaRow|null);
 }
 if(seg.length===1&&req.method==="POST"){
  const input=projectMediaInput(await readJsonLimited(req,4096));const row=await write(context,input.id,"reserve",input,req.signal);return await response(row);
 }
 assert(seg.length===3&&req.method==="PUT"&&UUID.test(seg[1])&&/^(?:[0-9]|1[0-5])$/.test(seg[2]),405,"Choose an upload part.");
 const bytes=await binary(req),hash=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),b=>b.toString(16).padStart(2,"0")).join("");
 const settled=await settleProjectPart(context,seg[1],Number(seg[2]),bytes,hash,req.signal);return await response(settled);
}
