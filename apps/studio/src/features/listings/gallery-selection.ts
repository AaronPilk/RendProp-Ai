import type { StudioServices } from "../../data/services";
import { StudioError } from "../../data/config";
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
export type GallerySelectionAction={action:"use"|"use_cover";photo_id:string;reviewed:boolean}|{action:"remove";photo_id:string;operation_id:string}|{action:"reorder_selected";expected_order:string[];photo_ids:string[]};
type SelectionConfirmation=Readonly<{scope:Readonly<GalleryScope>;identityVersion:number;action:GallerySelectionAction["action"];photoId:string|null;reviewed:boolean;gallery:readonly string[]|null;cover:string|null|undefined;order:readonly string[];families:string;asset:string|null}>;
export class UnconfirmedGallerySelection extends Error{
 constructor(readonly confirmation:SelectionConfirmation){super("Your photo choice may have been saved. Refresh this property to confirm it. It has not been sent again.");this.name="UnconfirmedGallerySelection";}
}
function confirmationFor(scope:GalleryScope,version:number,before:GallerySelection,body:GallerySelectionAction,coverKey?:string):SelectionConfirmation{
 let gallery=before.gallery_asset_ids===null?null:[...before.gallery_asset_ids],cover:string|null|undefined=before.main_photo_key,asset:string|null=null;
 if(body.action==="reorder_selected"){
  if(gallery!==null){const selected=gallery,mapped=[...new Set(body.photo_ids.map(id=>before.photos.find(p=>p.photo_id===id)?.asset_id).filter((id):id is string=>!!id&&selected.includes(id)))];let at=0;gallery=selected.map(id=>mapped.includes(id)?mapped[at++]:id);}
 }else{
  asset=before.photos.find(p=>p.photo_id===body.photo_id)?.asset_id??null;gallery=[...(gallery??before.effective_asset_ids)];
  if(body.action==="remove"){gallery=gallery.filter(id=>id!==asset);if(coverKey===undefined&&cover!==null)cover=undefined;else if(coverKey===cover)cover=null;}
  else if(asset&&!gallery.includes(asset))gallery.push(asset);
  if(body.action==="use_cover")cover=coverKey;
 }
 return Object.freeze({scope:Object.freeze({...scope}),identityVersion:version,action:body.action,photoId:body.action==="reorder_selected"?null:body.photo_id,reviewed:"reviewed"in body&&body.reviewed,gallery:gallery===null?null:Object.freeze(gallery),cover,order:Object.freeze([...(body.action==="reorder_selected"?body.photo_ids:before.photo_order)]),families:familyKeys(before),asset});
}
function familyKeys(selection:GallerySelection){return JSON.stringify(selection.photos.map(p=>[p.photo_id,p.asset_id]).sort((a,b)=>String(a[0]).localeCompare(String(b[0]))));}
export function confirmsGallerySelection(error:UnconfirmedGallerySelection,current:GallerySelection,services:StudioServices,scope:GalleryScope):boolean{
 const intent=error.confirmation,actor=services.getSnapshot();
 return actor.status==="signed-in"&&actor.identityVersion===intent.identityVersion&&actor.identity?.userId===intent.scope.actor&&
  (Object.keys(scope)as(keyof GalleryScope)[]).every(key=>scope[key]===intent.scope[key])&&current.actor_id===scope.actor&&current.org_id===scope.org&&current.library_org_id===scope.library&&current.listing_id===scope.listing&&
  intent.cover!==undefined&&JSON.stringify(current.gallery_asset_ids)===JSON.stringify(intent.gallery)&&current.main_photo_key===intent.cover&&JSON.stringify(current.photo_order)===JSON.stringify(intent.order)&&familyKeys(current)===intent.families&&
  (intent.action==="reorder_selected"||intent.asset!==null&&current.photos.some(p=>p.photo_id===intent.photoId&&p.asset_id===intent.asset&&(intent.action==="remove"?!p.selected:p.selected&&p.can_use&&(!p.review_required||intent.reviewed))));
}
export async function readGallerySelection(services:StudioServices,scope:GalleryScope,signal?:AbortSignal):Promise<GallerySelection>{
 return decodeGallerySelection(await services.api(`/functions/v1/studio/photos?${new URLSearchParams({listing_id:scope.listing,selection:"1"})}`,{orgId:scope.org,expectedLibraryOrgId:scope.library,expectedListingId:scope.listing,signal}),scope);
}
export async function changeListingSelection(services:StudioServices,scope:GalleryScope,current:GallerySelection,body:GallerySelectionAction,signal?:AbortSignal,coverKey?:string):Promise<GallerySelection>{
 const actor=services.getSnapshot();const assertCurrent=()=>{const now=services.getSnapshot();if(signal?.aborted)throw new DOMException("Selection check cancelled","AbortError");if(actor.identityVersion!==now.identityVersion||now.status!=="signed-in"||now.identity?.userId!==scope.actor)throw new Error("Your account changed. Reopen this property before choosing photos.");};
 assertCurrent();const fresh=await readGallerySelection(services,scope,signal);assertCurrent();
 if(!sameSelection(current,fresh))throw new Error("The listing photo selection changed on another device. Refresh before choosing again.");
 const removed=body.action==="remove"?fresh.photos.find(p=>p.photo_id===body.photo_id):null;
 if(body.action==="remove"&&(!UUID.test(body.operation_id)||!removed?.asset_id||!removed.selected||familyKeys(current)!==familyKeys(fresh)))throw new Error("The saved photo version changed. Refresh before removing it from the listing.");
 const uncertainty=new UnconfirmedGallerySelection(confirmationFor(scope,actor.identityVersion,fresh,body,coverKey));
 let result:unknown;
 try{result=await services.api("/functions/v1/studio/photos",{orgId:scope.org,expectedLibraryOrgId:scope.library,expectedListingId:scope.listing,signal,method:"PATCH",...(body.action==="remove"?{idempotencyKey:`gallery-remove:${body.operation_id}`}:{ }),body:{listing_id:scope.listing,...body,...(body.action==="remove"?{expected_asset_id:removed!.asset_id}:{}),expected_selection:selectionExpected(fresh)}});assertCurrent();}
 catch(reason){
  assertCurrent();
  if(!(reason instanceof StudioError)||!( ["network","timeout","identity-changed"].includes(reason.code)||body.action==="remove"&&(reason.status??0)>=500))throw reason;
  // An accepted PATCH can lose its reply or cross a directory refresh. Read
  // once through fresh authority; never replay the mutation or infer success
  // merely because this photo happens to be selected in another snapshot.
  try{const checked=await readGallerySelection(services,scope,signal);assertCurrent();if(confirmsGallerySelection(uncertainty,checked,services,scope))return checked;}
  catch{assertCurrent();}
  throw uncertainty;
 }
 const raw=result as Record<string,unknown>;if(raw?.ok!==true||raw.action!==body.action||raw.photo_id!==(body.action==="reorder_selected"?null:body.photo_id))throw new Error("The saved listing selection could not be confirmed. Refresh before trying again.");
 const checked=decodeGallerySelection(result,scope);
 if(body.action==="remove"){
  const receipt=raw.gallery_remove as Record<string,unknown>|undefined;
  if(!receipt||receipt.operation_id!==body.operation_id||receipt.actor_id!==scope.actor||typeof receipt.replayed!=="boolean"||JSON.stringify(receipt.requested_asset_ids)!==JSON.stringify([removed!.asset_id])||JSON.stringify(receipt.removed_asset_ids)!==JSON.stringify([removed!.asset_id])||!confirmsGallerySelection(uncertainty,checked,services,scope))throw uncertainty;
 }
 return checked;
}
