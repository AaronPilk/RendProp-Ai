import {assert} from '../_shared/http.ts';
import {adminClient,contentOrgForUser} from '../_shared/supabase.ts';
import {privateMediaUrl} from '../_shared/private-media.ts';
import {ownedHead,rpc} from './runtime.ts';

const UUID=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const SHA=/^[a-f0-9]{64}$/;

type Selection={composition_id:string;asset_id:string;storage_key:string;duration_s:number;branding_policy:string};
type Composition={id:string;actor_id:string;org_id:string;listing_id:string;asset_id:string;selected:boolean};
type Source={actor_id:string;org_id:string;listing_id:string;asset_id:string;bucket:'uploads'|'renders';storage_key:string;content_type:string;bytes:number;sha256:string;etag:string};

interface Dependencies {
 scope:(actor:string,library:string,listing:string)=>Promise<string>;
 presentation:(listing:string)=>Promise<Selection|null>;
 composition:(id:string)=>Promise<Composition|null>;
 owned:(actor:string,listing:string,asset:string)=>Promise<Source>;
 head:(source:Source)=>Promise<unknown>;
 sign:(scope:{actor:string;org:string;listing:string;bucket:'uploads'|'renders';key:string})=>Promise<string>;
}

const live:Dependencies={
 scope:(actor,library,listing)=>contentOrgForUser(actor,library,listing,false),
 presentation:async listing=>{
  const result=await rpc('property_public_presentation',{p_listing:listing});
  return result.listing_video??null;
 },
 composition:async id=>{
  const {data,error}=await adminClient().from('property_video_compositions')
   .select('id,actor_id,org_id,listing_id,asset_id,selected').eq('id',id).maybeSingle();
  assert(!error,503,'The selected video could not be checked.');
  return data;
 },
 owned:(actor,listing,asset)=>rpc('property_owned_upload',{p_actor:actor,p_listing:listing,p_asset:asset,p_kind:'video'}),
 head:ownedHead,
 sign:privateMediaUrl,
};

/** The private file must be the currently selected, public-ready composition,
 * not the newest job or a different phone's stale local selection. The existing
 * private-media gateway rechecks actor access and asset visibility on byte read
 * when enabled; direct R2 presigns retain their existing short expiry. */
export async function selectedVideoDownload(actor:string,listing:string,library:string,deps:Dependencies=live){
 const org=await deps.scope(actor,library,listing);
 const selected=await deps.presentation(listing);
 assert(selected&&UUID.test(selected.composition_id)&&UUID.test(selected.asset_id)&&
  typeof selected.storage_key==='string'&&selected.storage_key.startsWith(`renders/${org}/${listing}/`)&&
  selected.storage_key.endsWith('.mp4')&&selected.branding_policy==='unbranded'&&
  Number.isFinite(selected.duration_s)&&selected.duration_s>0&&selected.duration_s<=600,
  404,'A ready listing video is not selected.');
 const composition=await deps.composition(selected.composition_id);
 assert(composition?.selected===true&&composition.id===selected.composition_id&&
  composition.actor_id&&UUID.test(composition.actor_id)&&composition.org_id===org&&
  composition.listing_id===listing&&composition.asset_id===selected.asset_id,
  409,'The selected listing video changed.');
 const source=await deps.owned(composition.actor_id,listing,selected.asset_id);
 assert(source.actor_id===composition.actor_id&&source.org_id===org&&source.listing_id===listing&&source.asset_id===selected.asset_id&&
  source.bucket==='renders'&&source.storage_key===selected.storage_key&&
  source.content_type==='video/mp4'&&Number.isSafeInteger(source.bytes)&&source.bytes>0&&
  source.bytes<=1_610_612_736&&SHA.test(source.sha256)&&typeof source.etag==='string'&&source.etag.length>0,
  409,'The selected listing video receipt changed.');
 await deps.head(source);
 const download_url=await deps.sign({actor,org,listing,bucket:'renders',key:source.storage_key});
 const current=await deps.presentation(listing);
 assert(current?.composition_id===selected.composition_id&&current.asset_id===selected.asset_id&&
  current.storage_key===selected.storage_key,409,'The selected listing video changed.');
 assert(await deps.scope(actor,library,listing)===org,409,'The selected property library changed.');
 return {listing_id:listing,org_id:org,selected_library_org_id:library,
  composition_id:selected.composition_id,asset_id:selected.asset_id,duration_s:selected.duration_s,
  bytes:source.bytes,sha256:source.sha256,download_url};
}
