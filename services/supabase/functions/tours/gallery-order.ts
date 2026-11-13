import { HttpError } from "../_shared/http.ts";
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
type DB={rpc(name:string,args:Record<string,unknown>):PromiseLike<{data:unknown;error:unknown}>};
/** Same bounded candidate membership as the old NULL gallery; only mapped
 * selected slots follow saved Studio order. No client ordering or media URLs. */
export async function legacyGalleryOrder(db:DB,org:string,listing:string):Promise<{ids:string[];snapshot:string}>{
 const {data,error}=await db.rpc("listing_gallery_projection",{p_listing:listing});
 const p=data as Record<string,unknown>|null;
 if(error||!p||Array.isArray(p)||p.org_id!==org||p.listing_id!==listing||p.gallery_asset_ids!==null||
  !(p.main_photo_key===null||typeof p.main_photo_key==="string"&&p.main_photo_key.length<=1024)||!Array.isArray(p.effective_asset_ids)||p.effective_asset_ids.length>100||
  !p.effective_asset_ids.every(id=>typeof id==="string"&&UUID.test(id))||new Set(p.effective_asset_ids).size!==p.effective_asset_ids.length)
  throw new HttpError(503,"The published photo order could not be verified. Please refresh.");
 return {ids:p.effective_asset_ids as string[],snapshot:JSON.stringify({org_id:org,listing_id:listing,gallery_asset_ids:null,main_photo_key:p.main_photo_key,effective_asset_ids:p.effective_asset_ids})};
}
