import type { StudioServices } from "../../data/services";
export type GalleryScope={actor:string;org:string;library:string;listing:string};
export type GalleryChoice={photo_id:string;asset_id:string|null;selected:boolean;can_use:boolean;review_required:boolean};
export type GallerySelection={schema:1;actor_id:string;org_id:string;library_org_id:string;listing_id:string;gallery_asset_ids:string[]|null;main_photo_key:string|null;effective_asset_ids:string[];photo_order:string[];photos:GalleryChoice[]};
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function ids(value:unknown,max:number):value is string[]{return Array.isArray(value)&&value.length<=max&&value.every(x=>typeof x==="string"&&UUID.test(x))&&new Set(value).size===value.length;}
export function decodeGallerySelection(value:unknown,scope:GalleryScope):GallerySelection{
 const error=()=>new Error("The listing photo selection could not be verified. Refresh this property before choosing photos.");
 if(!value||typeof value!=="object"||Array.isArray(value))throw error();const s=value as Record<string,unknown>;
 if(s.schema!==1||s.actor_id!==scope.actor||s.org_id!==scope.org||s.library_org_id!==scope.library||s.listing_id!==scope.listing||
  !(s.gallery_asset_ids===null||ids(s.gallery_asset_ids,100))||!ids(s.effective_asset_ids,100)||
  !(s.main_photo_key===null||typeof s.main_photo_key==="string"&&s.main_photo_key.length<=1024)||!ids(s.photo_order,10_000)||!Array.isArray(s.photos)||s.photos.length!==s.photo_order.length)throw error();
 const selected=s.gallery_asset_ids??s.effective_asset_ids;
 if(!(s.effective_asset_ids as string[]).every(id=>s.gallery_asset_ids===null||(selected as string[]).includes(id)))throw error();
 for(let i=0;i<s.photos.length;i++){const p=s.photos[i]as GalleryChoice;if(!p||typeof p!=="object"||Array.isArray(p)||p.photo_id!==s.photo_order[i]||!(p.asset_id===null||typeof p.asset_id==="string"&&UUID.test(p.asset_id))||typeof p.can_use!=="boolean"||typeof p.selected!=="boolean"||typeof p.review_required!=="boolean"||p.selected!==(p.asset_id!==null&&(selected as string[]).includes(p.asset_id)))throw error();}
 return s as unknown as GallerySelection;
}
export function selectionExpected(s:GallerySelection){return{gallery_asset_ids:s.gallery_asset_ids,main_photo_key:s.main_photo_key};}
export function sameSelection(a:GallerySelection,b:GallerySelection){return JSON.stringify(selectionExpected(a))===JSON.stringify(selectionExpected(b))&&JSON.stringify(a.photo_order)===JSON.stringify(b.photo_order);}
export async function readGallerySelection(services:StudioServices,scope:GalleryScope,signal?:AbortSignal):Promise<GallerySelection>{
 return decodeGallerySelection(await services.api(`/functions/v1/studio/photos?${new URLSearchParams({listing_id:scope.listing,selection:"1"})}`,{orgId:scope.org,signal}),scope);
}
export async function changeListingSelection(services:StudioServices,scope:GalleryScope,current:GallerySelection,body:{action:"use"|"use_cover";photo_id:string;reviewed:boolean}|{action:"reorder_selected";expected_order:string[];photo_ids:string[]},signal?:AbortSignal):Promise<GallerySelection>{
 const actor=services.getSnapshot();const assertCurrent=()=>{const now=services.getSnapshot();if(signal?.aborted)throw new DOMException("Selection check cancelled","AbortError");if(actor.identityVersion!==now.identityVersion||now.status!=="signed-in"||now.identity?.userId!==scope.actor)throw new Error("Your account changed. Reopen this property before choosing photos.");};
 assertCurrent();const fresh=await readGallerySelection(services,scope,signal);assertCurrent();
 if(!sameSelection(current,fresh))throw new Error("The listing photo selection changed on another device. Refresh before choosing again.");
 const result=await services.api("/functions/v1/studio/photos",{orgId:scope.org,signal,method:"PATCH",body:{listing_id:scope.listing,...body,expected_selection:selectionExpected(fresh)}});assertCurrent();
 const raw=result as Record<string,unknown>;if(raw?.ok!==true||raw.action!==body.action||raw.photo_id!==(body.action==="reorder_selected"?null:body.photo_id))throw new Error("The saved listing selection could not be confirmed. Refresh before trying again.");
 return decodeGallerySelection(result,scope);
}
