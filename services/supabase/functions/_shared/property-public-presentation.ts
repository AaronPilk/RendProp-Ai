import { assert,HttpError,throwRpc } from './http.ts';
import { WEBSITE_THEMES } from './property-website-purchase.ts';
import type { MediaSourceRefs } from './media-source-access.ts';
type Reader={rpc:(name:string,args:Record<string,unknown>)=>PromiseLike<{data:unknown;error:{message:string;code?:string}|null}>};
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
/** The only public projection of these private tables. No purchase identifiers,
 * account identity, raw source images or client-supplied video URL leaves it. */
export async function propertyPublicPresentation(db:Reader,listing:{id:string;org_id:string},slug:string,
 refs:MediaSourceRefs&{keys:string[];assets:string[]},url:(slug:string,key:string|null)=>string|null){
 const {data,error}=await db.rpc('property_public_presentation',{p_listing:listing.id});
 if(error){if(error.code==='PGRST202')return {listing_video:null,website_theme:'basic'};throwRpc(error.message);}
 // A pre-migration optional projection is closed: no video or premium unlock.
 if(data===null)return {listing_video:null,website_theme:'basic'};
 const row=data as Record<string,unknown>;
 assert(row&&typeof row==='object'&&!Array.isArray(row)&&typeof row.website_theme==='string'&&(WEBSITE_THEMES as readonly string[]).includes(row.website_theme),503,'Property presentation could not be verified.');
 if(row.listing_video===null)return {listing_video:null,website_theme:row.website_theme};
 const v=row.listing_video as Record<string,unknown>;
 assert(v&&typeof v==='object'&&!Array.isArray(v)&&typeof v.composition_id==='string'&&UUID.test(v.composition_id)&&typeof v.asset_id==='string'&&UUID.test(v.asset_id)
  &&typeof v.storage_key==='string'&&v.storage_key.startsWith(`renders/${listing.org_id}/${listing.id}/`)&&!v.storage_key.includes('..')&&v.storage_key.endsWith('.mp4')
  &&typeof v.poster_asset_id==='string'&&UUID.test(v.poster_asset_id)&&typeof v.poster_key==='string'&&v.poster_key.startsWith(`renders/${listing.org_id}/${listing.id}/`)&&!v.poster_key.includes('..')&&/\.(jpe?g|png|webp)$/i.test(v.poster_key)
  &&Number.isInteger(v.width)&&Number(v.width)>=1920&&Number(v.width)<=7680&&Number.isInteger(v.height)&&Number(v.height)>=1080&&Number(v.height)<=4320
  &&Number(v.width)*9===Number(v.height)*16&&typeof v.duration_s==='number'&&Number.isFinite(v.duration_s)&&v.duration_s>0&&v.duration_s<=600
  &&v.branding_policy==='unbranded'&&typeof v.disclosure==='string'&&v.disclosure.length>0&&v.disclosure.length<=2000&&Array.isArray(v.source_asset_ids)&&v.source_asset_ids.length>=1&&v.source_asset_ids.length<=100
  &&v.source_asset_ids.every(id=>typeof id==='string'&&UUID.test(id)),503,'The selected property video has an invalid source receipt.');
 refs.keys.push(v.storage_key,v.poster_key as string);refs.assets.push(v.asset_id,v.poster_asset_id as string,...v.source_asset_ids);
 const videoUrl=url(slug,v.storage_key),posterUrl=url(slug,v.poster_key as string);if(!videoUrl||!posterUrl)throw new HttpError(503,'The selected property video has no approved delivery URL.');
 return {listing_video:{url:videoUrl,poster_url:posterUrl,duration_s:v.duration_s,width:Number(v.width),height:Number(v.height),disclosure:v.disclosure,branding_policy:'unbranded' as const},website_theme:row.website_theme};
}
