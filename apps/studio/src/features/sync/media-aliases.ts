import type {StudioServices} from "../../data/services";
export type ReadableMedia = {url:string;originalUrl?:string|null};
/** Resolve IDs omitted by the signer's storage-key dedupe without swapping original pixels for an enhancement. */
export async function resolvePhotoAliases(services:StudioServices,orgId:string,listingId:string,available:Map<string,ReadableMedia>,requested:string[],signal:AbortSignal):Promise<void>{
  if(requested.every(id=>available.has(id)))return;
  const assets=new Map<string,string>(),photos=new Map<string,{original:string|null;display:string|null}>();let offset:number|null=0;
  const key=(value:unknown):string|null=>typeof value==="string"&&["uploads","renders"].some(bucket=>value.startsWith(`${bucket}/${orgId}/${listingId}/`))&&!value.includes("..")?value:null;
  do{
    const raw=await services.api(`/functions/v1/studio/listing-state?listing_id=${listingId}&offset=${offset}`,{orgId,signal}) as {org_id:string;listing_id:string;assets:{id:string;storage_key:string}[];photos:{id:string;original_key:string|null;enhanced_key:string|null}[];next_offset:number|null};
    if(raw.org_id!==orgId||raw.listing_id!==listingId||!Array.isArray(raw.assets)||!Array.isArray(raw.photos))throw new Error("The property source identities could not be verified.");
    raw.assets.forEach(asset=>{const k=key(asset.storage_key);if(k)assets.set(asset.id,k);});
    raw.photos.forEach(photo=>photos.set(photo.id,{original:key(photo.original_key),display:key(photo.enhanced_key||photo.original_key)}));
    if(raw.next_offset!==null&&(raw.next_offset!==offset+100||raw.next_offset>10000))throw new Error("The property media identities could not be loaded completely.");offset=raw.next_offset;
  }while(offset!==null);
  const originals=[...available];
  for(const id of requested){
    if(available.has(id))continue;
    const wanted=assets.get(id)??photos.get(id)?.display;if(!wanted)continue;
    for(const [other,media] of originals){
      const photo=photos.get(other),display=photo?.display??assets.get(other);
      if(display===wanted){available.set(id,{...media});break;}
      if(photo?.original===wanted&&media.originalUrl){available.set(id,{url:media.originalUrl,originalUrl:media.originalUrl});break;}
    }
  }
}
