import {propertyMusicRow,hasMusicCopy} from "../studio/property-music.ts";
import {projectMediaComplete,type ProjectMediaRow} from "../studio/project-media.ts";
import type {StudioContext} from "../studio/context.ts";
import { assert, HttpError } from "./http.ts";
import { presignGet } from "./providers/common.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from "./r2.ts";
import { assertHostingAvailable } from "./hosting-retention.ts";
import { admitMediaRead } from "./media-delivery-admission.ts";
import { bucketForKey } from "../studio/handler.ts";
import { assertMediaVisible } from "./media-source-access.ts";

export interface PrivateMediaScope { actor:string;org:string;listing:string|null;bucket:"uploads"|"renders";key:string;review?:{owner:string;result:string;revision:number} }
interface Capability extends PrivateMediaScope { v:1;exp:number }
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const origin="https://rendprop.com";
function valid(c:Capability,now:number):boolean {
 return c.v===1&&typeof c.actor==="string"&&UUID.test(c.actor)&&typeof c.org==="string"&&UUID.test(c.org)&&(c.listing===null||typeof c.listing==="string"&&UUID.test(c.listing))&&["uploads","renders"].includes(c.bucket)&&
  typeof c.key==="string"&&c.key.length>0&&new TextEncoder().encode(c.key).length<=1024&&!c.key.split("/").some(v=>!v||v==="."||v===".."||/[\\%?#\u0000-\u001f]/.test(v))&&
  Number.isSafeInteger(c.exp)&&c.exp>now&&c.exp<=now+600&&
  (Object.keys(c).sort().join(",")==="actor,bucket,exp,key,listing,org,v"||
   Object.keys(c).sort().join(",")==="actor,bucket,exp,key,listing,org,review,v"&&c.listing!==null&&
   c.review!==null&&typeof c.review==="object"&&!Array.isArray(c.review)&&Object.keys(c.review).sort().join(",")==="owner,result,revision"&&
   typeof c.review.owner==="string"&&UUID.test(c.review.owner)&&typeof c.review.result==="string"&&UUID.test(c.review.result)&&Number.isSafeInteger(c.review.revision)&&c.review.revision>0&&c.review.revision<2147483647);
}
/** Parsing here is an origin/identity check, not signature authorization. A
 * fetch of this URL still passes the gateway's HMAC and current-row checks. */
export function privateMediaIdentity(raw:string):Capability|null {
 try{const url=new URL(raw);if(url.origin!==origin||url.username||url.password||url.port||url.search||url.hash)return null;
 const match=/^\/private-media\/([A-Za-z0-9_-]+)\.([a-f0-9]{64})$/.exec(url.pathname);if(!match||url.pathname.length>4096)return null;
 const c=JSON.parse(decodeURIComponent(escape(atob(match[1].replaceAll("-","+").replaceAll("_","/")))));
 return c&&typeof c==="object"&&!Array.isArray(c)&&valid(c,Math.floor(Date.now()/1000))?c:null;}catch{return null;}
}
async function mac(body:string):Promise<string>{
 const secret=Deno.env.get("MEDIA_GATEWAY_SECRET")||"";assert(/^[a-f0-9]{64}$/.test(secret),503,"Media service activation pending.");
 const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
 return Array.from(new Uint8Array(await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(body))),b=>b.toString(16).padStart(2,"0")).join("");
}
/** Caller has already authorized this exact row. A capability carries identity,
 * not final byte authority: the gateway checks current records on every read. */
export async function privateMediaUrl(scope:PrivateMediaScope,seconds=600):Promise<string>{
 assert(Number.isSafeInteger(seconds)&&seconds>0&&seconds<=600,503,"Media expiry could not be verified.");
 const flag=Deno.env.get("PRIVATE_MEDIA_DELIVERY");assert(flag===undefined||flag===""||flag==="off"||flag==="gateway-v1",503,"Media service configuration unavailable.");
 if(flag!=="gateway-v1")return await presignGet(scope.bucket==="uploads"?R2_BUCKET_UPLOADS:R2_BUCKET_RENDERS,scope.key,Math.min(seconds,600));
 const now=Math.floor(Date.now()/1000),c:Capability={v:1,...scope,exp:now+Math.min(seconds,600)};
 assert(valid(c,now),503,"Media identity could not be verified.");
 const body=btoa(unescape(encodeURIComponent(JSON.stringify(c)))).replaceAll("+","-").replaceAll("/","_").replace(/=+$/,"");
 assert(body.length+65<=4096,503,"Media identity exceeded its bound.");
 return `${origin}/private-media/${body}.${await mac(body)}`;
}
export async function verifyPrivateCapability(token:unknown):Promise<Capability>{
 assert(typeof token==="string"&&token.length<=4096,404,"Media unavailable.");
 const match=/^([A-Za-z0-9_-]+)\.([a-f0-9]{64})$/.exec(token);assert(match,404,"Media unavailable.");
 const expected=await mac(match[1]);let difference=0;for(let i=0;i<64;i++)difference|=expected.charCodeAt(i)^match[2].charCodeAt(i);
 assert(difference===0,404,"Media unavailable.");
 let value:unknown;try{value=JSON.parse(decodeURIComponent(escape(atob(match[1].replaceAll("-","+").replaceAll("_","/")))));}catch{throw new HttpError(404,"Media unavailable.");}
 assert(value!==null&&typeof value==="object"&&!Array.isArray(value)&&valid(value as Capability,Math.floor(Date.now()/1000)),404,"Media unavailable.");
 return value as Capability;
}
// deno-lint-ignore no-explicit-any
export async function privateMediaAuthority(admin:any,token:unknown,bytes:number){
 const c=await verifyPrivateCapability(token);
 // Spend before all ownership/catalogue reads. Failed/ambiguous reads also
 // consume the request; replay cannot create unmetered database work.
 await admitMediaRead(admin,c.org,bytes,true);
 const current=async()=>{
  const membership=await admin.from("memberships").select("user_id,org_id,role").eq("user_id",c.actor).eq("org_id",c.org).maybeSingle();
  assert(!membership.error&&membership.data?.user_id===c.actor&&membership.data?.org_id===c.org&&["owner","admin","agent"].includes(membership.data.role),404,"Media unavailable.");
  const actor=await admin.from("profiles").select("id").eq("id",c.actor).maybeSingle();
  const deletion=await admin.from("deletion_requests").select("id").eq("user_id",c.actor).in("status",["pending","processing"]).limit(1);
  assert(!actor.error&&actor.data?.id===c.actor&&!deletion.error&&Array.isArray(deletion.data)&&deletion.data.length===0,404,"Media unavailable.");
  await assertHostingAvailable(admin,c.org);
 };
 await current();
 if(c.listing!==null){
  const property=await admin.from("listings").select("id,org_id,deleted_at").eq("id",c.listing).eq("org_id",c.org).is("deleted_at",null).maybeSingle();
  assert(!property.error&&property.data?.id===c.listing&&property.data?.org_id===c.org&&!property.data.deleted_at,404,"Media unavailable.");
 }
 // Prefix alone never admits a key. Bind to an uploaded asset, immutable render,
 // explicit photo alias, creative receipt or the exact actor-owned output row.
 const outputs=await admin.from("private_ai_outputs").select("id,bucket,storage_key,listing_id").eq("user_id",c.actor).eq("org_id",c.org).eq("bucket",c.bucket).eq("storage_key",c.key).maybeSingle();
 assert(!outputs.error,503,"Media identity could not be verified.");
 let registered=outputs.data?.storage_key===c.key&&outputs.data?.bucket===c.bucket&&outputs.data?.listing_id===c.listing;
 if(c.bucket==="uploads"&&c.key.startsWith(`studio-project/${c.org}/`)){
  const tail=c.key.slice(`studio-project/${c.org}/`.length).split("/");
  assert(tail.length===3&&UUID.test(tail[0])&&UUID.test(tail[1])&&/^(?:[0-9]|1[0-5])$/.test(tail[2]),404,"Media unavailable.");
  const project=await admin.from("studio_project_media").select("*").eq("id",tail[1]).eq("actor_id",tail[0]).eq("org_id",c.org).maybeSingle();
  const p=project.data as ProjectMediaRow|null;
  registered=!project.error&&p!==null&&p.actor_id===tail[0]&&p.org_id===c.org&&Number.isSafeInteger(p.bytes)&&p.bytes>0&&p.bytes<=128*1024*1024&&projectMediaComplete(p)&&Number(tail[2])<p.parts;
  assert(registered&&p,404,"Media unavailable.");
  if(c.listing===null){assert(!c.review&&p.actor_id===c.actor,404,"Media unavailable.");}
  else{
   const context={admin,orgId:c.org,userId:c.actor} as StudioContext;
   const bound=await propertyMusicRow(context,c.listing,p.sha256);assert(bound.id===p.id&&bound.actor_id===p.actor_id,404,"Media unavailable.");
   if(c.review){
    assert(c.review.result===p.id,404,"Media unavailable.");
    const review=await admin.rpc("studio_production_review",{p_actor:c.actor,p_org_id:c.org,p_document_user_id:c.review.owner,p_key:`edit:${c.listing}`,p_action:"get"});
    assert(!review.error&&review.data?.document&&review.data.review?.status!=="draft"&&review.data.review?.submitted_at&&review.data.document.revision===c.review.revision&&review.data.source_revision===c.review.revision&&
     review.data.document.payload?.draft?.music?.source?.sha256===p.sha256&&review.data.document.payload?.draft?.music?.source?.size===p.bytes&&review.data.document.payload?.draft?.music?.licensed===true,404,"Media unavailable.");
    if(p.actor_id!==c.review.owner)assert(await hasMusicCopy(context,c.review.owner,c.listing,p.sha256),404,"Media unavailable.");
   }else if(p.actor_id!==c.actor){
    const document=await admin.from("studio_documents").select("payload").eq("user_id",c.actor).eq("org_id",c.org).eq("key",`edit:${c.listing}`).maybeSingle();
    assert(!document.error&&document.data?.payload?.draft?.music?.source?.sha256===p.sha256&&document.data.payload.draft.music.licensed===true&&await hasMusicCopy(context,c.actor,c.listing,p.sha256),404,"Media unavailable.");
   }
  }
 }else if(c.review){
  const review=await admin.rpc("studio_production_review",{p_actor:c.actor,p_org_id:c.org,p_document_user_id:c.review.owner,p_key:`edit:${c.listing}`,p_action:"get"});
  assert(!review.error&&review.data?.document&&review.data.review?.status!=="draft"&&review.data.review?.submitted_at&&
   review.data.document.revision===c.review.revision&&review.data.source_revision===c.review.revision&&
   review.data.document.payload?.draft?.narration?.resultId===c.review.result,404,"Media unavailable.");
  const voice=await admin.from("studio_creative_results").select("id,user_id,org_id,listing_id,kind,bucket,storage_key,metadata")
   .eq("id",c.review.result).eq("user_id",c.review.owner).eq("org_id",c.org).eq("listing_id",c.listing).eq("kind","voice").maybeSingle();
  assert(!voice.error&&voice.data?.metadata?.state==="completed"&&voice.data.bucket===c.bucket&&voice.data.storage_key===c.key&&c.bucket==="uploads"&&c.key.startsWith(`ai-voice/${c.org}/`),404,"Media unavailable.");
  registered=true;
 }else if(!registered&&c.bucket==="uploads"&&new RegExp(`^ai-voice/${c.org}/${UUID.source.slice(1,-1)}\\.mp3$`).test(c.key)){
  const voice=await admin.from("voice_storage_reservations").select("id,actor_id,org_id,listing_id,storage_key").eq("actor_id",c.actor).eq("org_id",c.org).eq("storage_key",c.key).maybeSingle();
  registered=!voice.error&&voice.data?.storage_key===c.key&&voice.data?.listing_id===c.listing;
 }
 if(!registered&&c.bucket==="uploads"&&c.key.startsWith(`presenter-private/${c.org}/`)&&c.listing!==null){
  const tail=c.key.slice(`presenter-private/${c.org}/`.length).split("/");assert(tail.length===2&&UUID.test(tail[0])&&tail[1]==="output.mp4",404,"Media unavailable.");
  const preview=await admin.rpc("studio_presenter_execution",{p_actor:c.actor,p_org_id:c.org,p_listing_id:c.listing,p_action:"preview",p_payload:{job_id:tail[0]}});
  registered=!preview.error&&preview.data?.output_key===c.key;
 }
 if(!registered&&c.bucket==="renders"&&c.key.startsWith(`video-reflections/${c.org}/`)){
  const id=c.key.slice(`video-reflections/${c.org}/`.length).replace(/\.mp4$/,"");
  assert(UUID.test(id)&&c.key===`video-reflections/${c.org}/${id}.mp4`,404,"Media unavailable.");
  const job=await admin.rpc("video_erase_get",{p_org:c.org,p_user:c.actor,p_job:id});
  registered=!job.error&&job.data?.id===id&&job.data.org_id===c.org&&job.data.user_id===c.actor&&job.data.state==="completed"&&job.data.output_key===c.key&&c.listing===null;
 }
 if(c.listing!==null&&!registered){
  // Worker renders have the established renders/<listing>/<render> form.
  // A recorded exact render below proves their org; a prefix never does.
  assert(bucketForKey(c.key,{orgId:c.org,listingId:c.listing})===c.bucket||c.bucket==="renders"&&c.key.startsWith(`renders/${c.listing}/`),404,"Media unavailable.");
  const asset=await admin.from("capture_assets").select("id,listing_id,bucket,storage_key,uploaded").eq("listing_id",c.listing).eq("bucket",c.bucket).eq("storage_key",c.key).eq("uploaded",true).maybeSingle();
  assert(!asset.error,503,"Media identity could not be verified.");
  registered=asset.data?.listing_id===c.listing&&asset.data?.bucket===c.bucket&&asset.data?.storage_key===c.key&&asset.data?.uploaded===true;
  if(!registered){
   const lookups=await Promise.all([["photos","original_key"],["photos","enhanced_key"],["renders","video_key"],["renders","poster_key"],["media_provenance","original_key"],["media_provenance","altered_key"]].map(async([table,column])=>{let query=admin.from(table).select(column).eq("listing_id",c.listing).eq(column,c.key);if(table==="media_provenance")query=query.eq("org_id",c.org);const result=await query.limit(2);assert(!result.error&&Array.isArray(result.data),503,"Media identity could not be verified.");return result.data.some((row:Record<string,unknown>)=>row[column]===c.key);}));
   registered=lookups.some(Boolean);
  }
 }
 assert(registered,404,"Media unavailable.");
 if(c.listing!==null)await assertMediaVisible(admin,c.listing,{keys:[c.key]});
 await current();
 return{schema:1,slug:"private",objects:{[c.key]:c.bucket},stream_uid:null};
}
