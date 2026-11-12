import { assert, HttpError, json } from "../_shared/http.ts";
import { listingLibraryScope } from "../_shared/library-access.ts";
import { removePublishedPhotos } from "../listings/gallery-remove.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
type Row=Record<string,unknown>;
type Context={userId:string;orgId:string;admin?:any;authorizeListing(id:string):Promise<void>};
function ids(value:unknown,max:number):value is string[]{return Array.isArray(value)&&value.length<=max&&value.every(x=>typeof x==="string"&&UUID.test(x))&&new Set(value).size===value.length;}
export function checkedGallerySelection(value:unknown,scope:{actor:string;org:string;library:string;listing:string}):Row{
 assert(!!value&&typeof value==="object"&&!Array.isArray(value),503,"The listing photo selection could not be checked.");
 const s=value as Row;
 assert(s.schema===1&&s.actor_id===scope.actor&&s.org_id===scope.org&&s.library_org_id===scope.library&&s.listing_id===scope.listing&&
  (s.gallery_asset_ids===null||ids(s.gallery_asset_ids,100))&&ids(s.effective_asset_ids,100)&&
  (s.main_photo_key===null||typeof s.main_photo_key==="string"&&s.main_photo_key.length<=1024)&&ids(s.photo_order,10_000)&&Array.isArray(s.photos)&&s.photos.length===s.photo_order.length,
  503,"The listing photo selection returned inconsistent data.");
 const selected=s.gallery_asset_ids??s.effective_asset_ids;
 if(s.gallery_asset_ids!==null)assert((s.effective_asset_ids as string[]).every(id=>(selected as string[]).includes(id)),503,"The listing photo selection returned inconsistent data.");
 for(let i=0;i<(s.photos as unknown[]).length;i++){
  const p=(s.photos as Row[])[i];assert(!!p&&typeof p==="object"&&!Array.isArray(p)&&p.photo_id===(s.photo_order as string[])[i]&&
   (p.asset_id===null||typeof p.asset_id==="string"&&UUID.test(p.asset_id))&&typeof p.selected==="boolean"&&typeof p.can_use==="boolean"&&typeof p.review_required==="boolean"&&
   p.selected===(typeof p.asset_id==="string"&&(selected as string[]).includes(p.asset_id)),503,"The listing photo selection returned inconsistent data.");
 }
 return s;
}
function rpcError(error:{message?:unknown}|null){if(!error)return;const match=/^RP(400|403|404|409): (.{1,240})$/.exec(String(error.message));throw new HttpError(match?Number(match[1]):503,match?match[2]:"The listing photo selection could not be saved. Refresh before trying again.");}
export async function gallerySelectionRequest(context:Context,listing:string,body?:Row,idempotencyKey:string|null=null):Promise<Response>{
 assert(context.admin,503,"The listing photo selection is temporarily unavailable.");
 const scope=await listingLibraryScope(context.admin,context.userId,listing,!!body);
 assert(scope.org_id===context.orgId,404,"Property not found in this workspace.");
 let name="studio_gallery_selection_snapshot",args:Row={p_actor:context.userId,p_org:context.orgId,p_listing:listing};
 if(body){
  const action=body.action;assert(action==="use"||action==="use_cover"||action==="remove"||action==="reorder_selected",400,"Choose a listing photo action.");
  const expected=body.expected_selection as Row|undefined;
  assert(!!expected&&typeof expected==="object"&&!Array.isArray(expected)&&Object.keys(expected).length===2&&Object.hasOwn(expected,"gallery_asset_ids")&&Object.hasOwn(expected,"main_photo_key")&&
   (expected.gallery_asset_ids===null||ids(expected.gallery_asset_ids,100))&&(expected.main_photo_key===null||typeof expected.main_photo_key==="string"&&expected.main_photo_key.length<=1024),400,"Refresh the saved listing photo selection.");
  if(action==="reorder_selected")assert(ids(body.expected_order,500)&&body.expected_order.length>0&&ids(body.photo_ids,500)&&body.photo_ids.length===body.expected_order.length,400,"Choose each gallery photo once, up to 500 photos.");
  else assert(typeof body.photo_id==="string"&&UUID.test(body.photo_id)&&(body.reviewed===undefined||typeof body.reviewed==="boolean"),400,"Choose and review a gallery photo.");
  if(action==="remove"){
   const fields=["listing_id","action","photo_id","operation_id","expected_asset_id","expected_selection"];
   assert(Object.keys(body).length===fields.length&&fields.every(key=>Object.hasOwn(body,key))&&body.listing_id===listing&&typeof body.operation_id==="string"&&UUID.test(body.operation_id)&&typeof body.expected_asset_id==="string"&&UUID.test(body.expected_asset_id),400,"Keep the exact saved photo removal and its selection snapshot.");
   const before=await context.admin.rpc("studio_gallery_selection_snapshot",args);rpcError(before.error);
   const current=checkedGallerySelection(before.data,{actor:context.userId,org:context.orgId,library:scope.library_org_id,listing});
   const choice=(current.photos as Row[]).find(photo=>photo.photo_id===body.photo_id);
   assert(choice?.asset_id===body.expected_asset_id,409,"The saved photo version changed. Refresh before removing it from the listing.","gallery_selection_changed");
   // Shared authority owns ordered CAS, cover clearing and immutable replay.
   // Do not require publish eligibility/review to withdraw an already selected edit.
   const removed=await removePublishedPhotos(context.admin,{orgId:context.orgId,listingId:listing},context.userId,{
    gallery_remove_asset_ids:[choice.asset_id],gallery_remove_operation_id:body.operation_id,
    expected_gallery_asset_ids:expected.gallery_asset_ids,expected_main_photo_key:expected.main_photo_key,
   },idempotencyKey);
   const after=await context.admin.rpc("studio_gallery_selection_snapshot",args);rpcError(after.error);
   const value=checkedGallerySelection(after.data,{actor:context.userId,org:context.orgId,library:scope.library_org_id,listing});
   await context.authorizeListing(listing);
   return json({...value,ok:true,action:"remove",photo_id:body.photo_id,gallery_remove:removed.gallery_remove},200,{"cache-control":"private, no-store"});
  }
  name="studio_gallery_selection_change";args={...args,p_action:action,p_photo:action==="reorder_selected"?null:body.photo_id,p_expected:expected,p_expected_order:action==="reorder_selected"?body.expected_order:null,p_order:action==="reorder_selected"?body.photo_ids:null,p_reviewed:body.reviewed===true};
 }
 const {data,error}=await context.admin.rpc(name,args);rpcError(error);
 const value=checkedGallerySelection(data,{actor:context.userId,org:context.orgId,library:scope.library_org_id,listing});
 if(body)assert(value.ok===true&&value.action===body.action&&value.photo_id===(body.action==="reorder_selected"?null:body.photo_id),503,"The saved listing photo selection could not be confirmed.");
 await context.authorizeListing(listing);
 return json(value,200,{"cache-control":"private, no-store"});
}
