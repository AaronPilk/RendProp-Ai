import { HttpError } from "../_shared/http.ts";
import { bucketForKey } from "../studio/handler.ts";
import { mediaVisibility } from "../_shared/media-source-access.ts";
import { publicR2Url, publishedR2Url } from "../_shared/r2.ts";
import { assertHostingAvailable } from "../_shared/hosting-retention.ts";

/** URLs in legacy JSON are references, never authority. Resolve to an exact
 * registered object using the configured storage origin before DB admission. */
export function legacyObjectKey(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const base = Deno.env.get("R2_PUBLIC_BASE_URL")?.trim().replace(/\/+$/, "");
  if (!base) return null;
  try {
    const u = new URL(value), origin = new URL(base);
    if (u.origin !== origin.origin || u.username || u.password || u.hash || u.search || !u.pathname.startsWith(origin.pathname.replace(/\/+$/, "") + "/")) return null;
    const key = u.pathname.slice(origin.pathname.replace(/\/+$/, "").length + 1).split("/").map(decodeURIComponent).join("/");
    return key && key.length <= 1024 && !key.split("/").some(v => !v || v === "." || v === ".." || /[\\%?#\u0000-\u001f]/.test(v)) && publicR2Url(key) === value ? key : null;
  } catch { return null; }
}
// deno-lint-ignore no-explicit-any
export async function admittedFloorplan(admin: any, scope: {orgId:string;listingId:string}, value: unknown, slug: string, refs: {assets:string[];keys:string[]}): Promise<string|null> {
  const key = legacyObjectKey(value);
  const bucket = bucketForKey(key, scope);
  if (!key || !bucket) return null;
  const {data,error} = await admin.from("capture_assets").select("id,listing_id,kind,bucket,storage_key,uploaded").eq("listing_id",scope.listingId).eq("storage_key",key).maybeSingle();
  if (error) throw new HttpError(503,"The floor plan could not be verified.");
  if (!data || data.listing_id !== scope.listingId || data.storage_key !== key || data.bucket !== bucket || data.kind !== "photo" || data.uploaded !== true) return null;
  const visible = await mediaVisibility(admin,scope.listingId,{assets:[data.id],keys:[key]});
  if (visible.assets[data.id] !== true || visible.keys[key] !== true) return null;
  refs.assets.push(data.id); refs.keys.push(key);
  return publishedR2Url(slug,key);
}
// deno-lint-ignore no-explicit-any
export async function admittedBusinessLogo(admin:any,org:string,value:unknown,slug:string):Promise<{url:string;key:string}|null>{
  if(typeof value!=="string")return null;
  const {data,error}=await admin.from("org_brand_assets").select("object_key,public_url,state,org_id").eq("org_id",org).eq("public_url",value).eq("state","published").maybeSingle();
  if(error)throw new HttpError(503,"The business logo could not be verified.");
  if(!data||data.org_id!==org||data.public_url!==value||data.state!=="published"||typeof data.object_key!=="string"||!new RegExp(`^renders/${org}/brand/[a-f0-9-]{36}\\.(jpg|png)$`).test(data.object_key))return null;
  const url=publishedR2Url(slug,data.object_key);return url?{url,key:data.object_key}:null;
}
export function deliveryEnvelope(slug:string,scope:{orgId:string;listingId:string},keys:readonly string[],stream:unknown,logoKey?:string){
  const objects:Record<string,"uploads"|"renders">=Object.create(null);
  for(const key of new Set(keys)){
    const bucket=bucketForKey(key,scope);
    if(!bucket)throw new HttpError(503,"Published media identity could not be verified.");
    objects[key]=bucket;
  }
  if(logoKey)objects[logoKey]="renders";
  return {schema:1,slug,objects,stream_uid:typeof stream==="string"&&/^[a-f0-9]{32}$/.test(stream)?stream:null};
}
/** A business logo is deliberately public independently of tour publication,
 * but removing/replacing it or deleting its workspace revokes new byte reads. */
// deno-lint-ignore no-explicit-any
export async function businessLogoDelivery(admin:any,org:string,key:unknown){
  if(typeof key!=="string"||!new RegExp(`^renders/${org}/brand/[a-f0-9-]{36}\\.(jpg|png)$`).test(key))throw new HttpError(404,"Logo not found.");
  const current=async()=>{const {data,error}=await admin.from("orgs").select("id,deleted_at,brand_kit").eq("id",org).is("deleted_at",null).maybeSingle();if(error)throw new HttpError(503,"The logo could not be verified.");return data;};
  const owner=await current();if(!owner||owner.deleted_at||typeof owner.brand_kit?.business_logo_url!=="string")throw new HttpError(404,"Logo not found.");
  const {data,error}=await admin.from("org_brand_assets").select("org_id,object_key,public_url,state").eq("org_id",org).eq("object_key",key).eq("state","published").maybeSingle();
  if(error)throw new HttpError(503,"The logo could not be verified.");
  if(!data||data.org_id!==org||data.object_key!==key||data.state!=="published"||data.public_url!==owner.brand_kit.business_logo_url)throw new HttpError(404,"Logo not found.");
  const latest=await current();if(!latest||latest.deleted_at||latest.brand_kit?.business_logo_url!==data.public_url)throw new HttpError(404,"Logo not found.");
  await assertHostingAvailable(admin, org);
  return {schema:1,slug:org,objects:{[key]:"renders"},stream_uid:null};
}
/** Legacy JSON can contain duplicate media references outside the explicit
 * gallery/floorplan fields. Rewrite only already admitted exact identities;
 * never turn arbitrary JSON, key ancestry or a host suffix into byte authority. */
export function publishedListingDetails(value:Record<string,unknown>,slug:string,keys:readonly string[]):Record<string,unknown>{
 const allowed=new Set(keys);
 const visit=(input:unknown,depth:number):unknown=>{
  if(depth>16)return null;
  if(typeof input==="string"){
   const key=legacyObjectKey(input);if(key)return allowed.has(key)?publishedR2Url(slug,key):null;
   return input;
  }
  if(Array.isArray(input))return input.map(v=>visit(v,depth+1));
  if(input&&typeof input==="object")return Object.fromEntries(Object.entries(input).map(([k,v])=>[k,visit(v,depth+1)]));
  return input;
 };
 return visit(value,0) as Record<string,unknown>;
}
