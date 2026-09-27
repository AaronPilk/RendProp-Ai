import {assert,HttpError,json} from "../_shared/http.ts";
import type {StudioContext} from "./context.ts";
import {assertFinishingPayload} from "./finishing-payload.ts";
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export function projectPayload(value:unknown,listingId:string|null):Record<string,unknown>{
 const p=value as Record<string,unknown>;
 assert(p&&p.schema===1&&typeof p.name==="string"&&p.name.trim().length>0&&p.name.trim().length<=80&&!/[\u0000-\u001f]/.test(p.name)&&typeof p.archived==="boolean"&&p.listingId===listingId,400,"Choose a project name and matching property.");
 assert(p.draft&&typeof p.draft==="object"&&!Array.isArray(p.draft)&&new TextEncoder().encode(JSON.stringify(p.draft)).byteLength<=65536,400,"This edit is too large to save.");
 assertFinishingPayload(p.draft);
 assert(Array.isArray(p.sources)&&p.sources.length<=24,400,"Invalid project sources.");
 const hashes=new Set<string>();const sources=p.sources.map((s:Record<string,unknown>)=>{assert(s&&typeof s.sha256==="string"&&/^[a-f0-9]{64}$/.test(s.sha256)&&!hashes.has(s.sha256)&&typeof s.assetId==="string"&&UUID.test(s.assetId)&&typeof s.listingId==="string"&&UUID.test(s.listingId),400,"Invalid project source.");hashes.add(s.sha256);return {sha256:s.sha256,assetId:s.assetId,listingId:s.listingId};});
 assert(p.conversation===undefined||p.conversation&&typeof p.conversation==="object"&&!Array.isArray(p.conversation)&&new TextEncoder().encode(JSON.stringify(p.conversation)).byteLength<=65536,400,"Project conversation is too large.");
 return {schema:1,name:p.name.trim(),archived:p.archived,listingId,draft:p.draft,sources,...(p.conversation?{conversation:p.conversation}:{})};
}
export async function handleProjectIndex(req:Request,context:StudioContext):Promise<Response>{
 assert(req.method==="GET",405,"Use project Save to make changes.");
 const result=await context.db.from("studio_documents").select("key,listing_id,revision,updated_at,payload->name,payload->archived").eq("user_id",context.userId).eq("org_id",context.orgId).eq("kind","project").order("updated_at",{ascending:false}).limit(100).abortSignal(req.signal);
 if(result.error)throw new HttpError(503,"Your video projects could not be loaded.");
 return json({projects:(result.data??[]).map(p=>({key:p.key,name:p.name,archived:p.archived,listingId:p.listing_id,revision:p.revision,updatedAt:p.updated_at}))},200,{"Cache-Control":"private, no-store"});
}
