import { bucketForKey } from "../studio/handler.ts";
import { mediaVisibility, type MediaAccessClient } from "./media-source-access.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from "./r2.ts";
import { presignGet } from "./providers/common.ts";
/** Private audit exports are download capabilities, not claims that advertising
 * originals are publicly reachable. Exact provenance rows are already actor/org
 * authorized by the caller; key scope and current revocation are checked here. */
export async function privateProvenanceLinks(db:MediaAccessClient,org:string,rows:readonly Record<string,unknown>[],sign:(bucket:string,key:string,seconds:number,listing:string,physicalOrg:string)=>Promise<string>=presignGet){
  const groups=new Map<string,{org:string;listing:string;keys:Set<string>}>();
  const rowOrg=(row:Record<string,unknown>)=>typeof row.org_id==="string"&&/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(row.org_id)?row.org_id:org;
  const groupKey=(row:Record<string,unknown>)=>`${rowOrg(row)}:${String(row.listing_id)}`;
  for(const row of rows){if(typeof row.listing_id!=="string")continue;const physicalOrg=rowOrg(row),identity=groupKey(row);for(const value of [row.original_key,row.altered_key])if(typeof value==="string"&&bucketForKey(value,{orgId:physicalOrg,listingId:row.listing_id})){let group=groups.get(identity);if(!group){group={org:physicalOrg,listing:row.listing_id,keys:new Set()};groups.set(identity,group);}group.keys.add(value);}}
  const available=new Map<string,Map<string,string>>();
  for(const [identity,group]of groups){
    const {org:physicalOrg,listing}=group;
    const keys=[...group.keys],links=new Map<string,string>();available.set(identity,links);
    for(let index=0;index<keys.length;index+=200){
      const batch=keys.slice(index,index+200),visible=await mediaVisibility(db,listing,{keys:batch});
      for(const key of batch){if(visible.keys[key]!==true)continue;const bucket=bucketForKey(key,{orgId:physicalOrg,listingId:listing})!;links.set(key,await sign(bucket==="uploads"?R2_BUCKET_UPLOADS:R2_BUCKET_RENDERS,key,600,listing,physicalOrg));}
      // Discard capabilities withdrawn during local signing before any response.
      const current=await mediaVisibility(db,listing,{keys:batch});
      for(const key of batch)if(current.keys[key]!==true)links.delete(key);
    }
  }
  // A later group's signer can yield while an earlier listing is withdrawn.
  // Recheck every issued capability immediately before constructing the export.
  for(const [identity,links]of available){const listing=groups.get(identity)!.listing;const keys=[...links.keys()];for(let index=0;index<keys.length;index+=200){const batch=keys.slice(index,index+200),current=await mediaVisibility(db,listing,{keys:batch});for(const key of batch)if(current.keys[key]!==true)links.delete(key);}}
  return rows.map(row=>{const links=available.get(groupKey(row));return{original_url:typeof row.original_key==="string"?links?.get(row.original_key)??null:null,altered_url:typeof row.altered_key==="string"?links?.get(row.altered_key)??null:null,original_available:false,original_download_available:typeof row.original_key==="string"&&links?.has(row.original_key)===true};});
}
