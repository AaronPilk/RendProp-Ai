import { HttpError } from "./http.ts";
import { headObject, R2_BUCKET_RENDERS } from "./r2.ts";
import { admitMediaRead } from "./media-delivery-admission.ts";
import { PHOTO_OUTPUT_MAX_BYTES } from "./photo-output-policy.ts";

type Row=Record<string,any>;
type ObjectReceipt={key:string;bucket:"renders";bytes:number;mime:string;etag:string};
export type PublicationVisibility={publication_id:string;org_id:string;listing_id:string;assets:string[];keys:string[];objects:ObjectReceipt[]};
type Client={rpc(name:string,args:Record<string,unknown>):PromiseLike<{data:unknown;error:unknown}>};
export type PublicationHeadIO={
  head(object:ObjectReceipt,signal:AbortSignal):Promise<{exists:boolean;bytes:number|null;contentType:string|null;etag:string|null}>;
  admit(db:Client,org:string):Promise<void>;
};
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const object=(v:unknown):v is Row=>!!v&&typeof v==="object"&&!Array.isArray(v);
const fail=()=>new HttpError(503,"The saved photo publication access could not be verified.");
const exact=(v:Row,keys:string[])=>Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
export function publicationVisibilityRows(raw:unknown,listing:string):PublicationVisibility[]{
  // Older ordinary responses have no marked publications. New marked rows are
  // always returned by the guarded SQL visibility expansion.
  if(raw===undefined)return[];
  if(!Array.isArray(raw)||raw.length>100)throw fail();
  const ids=new Set<string>(),objects=new Map<string,string>();
  return raw.map((v)=>{
    if(!object(v)||!exact(v,["publication_id","org_id","listing_id","assets","keys","objects"])||!UUID.test(v.publication_id)||ids.has(v.publication_id)||!UUID.test(v.org_id)||v.listing_id!==listing||!Array.isArray(v.assets)||v.assets.length!==2||v.assets.some((x:unknown)=>typeof x!=="string"||!UUID.test(x))||new Set(v.assets).size!==2||!Array.isArray(v.keys)||v.keys.length!==2||new Set(v.keys).size!==2||!Array.isArray(v.objects)||v.objects.length!==4)throw fail();
    ids.add(v.publication_id);
    const canonical=`renders/${v.org_id}/${listing}/`;
    if(v.keys.some((key:unknown)=>typeof key!=="string"||!key.startsWith(canonical)||key.slice(canonical.length).includes("/")||!new RegExp(`^(?:original-${UUID.source.slice(1,-1)}|gallery-${UUID.source.slice(1,-1)}(?:-complete-${UUID.source.slice(1,-1)})?)\\.(?:jpg|png|webp)$`).test(key.slice(canonical.length))))throw fail();
    const seen=new Set<string>();let privateInput=0,privateOutput=0;const sourceScopes=new Set<string>();
    const checked=v.objects.map((o:unknown):ObjectReceipt=>{
      if(!object(o)||!exact(o,["key","bucket","bytes","mime","etag"])||typeof o.key!=="string"||o.key.length>1024||/[\\%?#\u0000-\u001f]/.test(o.key)||seen.has(o.key)||o.bucket!=="renders"||!Number.isSafeInteger(o.bytes)||o.bytes<1||o.bytes>PHOTO_OUTPUT_MAX_BYTES||!["image/jpeg","image/png","image/webp"].includes(o.mime)||typeof o.etag!=="string"||o.etag.length<1||o.etag.length>256||/[\u0000-\u001f\u007f]/.test(o.etag))throw fail();
      seen.add(o.key);
      if(!v.keys.includes(o.key)){
        const match=new RegExp(`^ai-router/${v.org_id}/photo-evidence/(${UUID.source.slice(1,-1)})/(${UUID.source.slice(1,-1)})/(input|candidate)\\.(?:jpg|png|webp)$`).exec(o.key);
        if(!match)throw fail();sourceScopes.add(match[1]+"/"+match[2]);if(match[3]==="input")privateInput++;else privateOutput++;
      }
      const normalized={key:o.key,bucket:"renders" as const,bytes:o.bytes,mime:o.mime,etag:o.etag};
      const fingerprint=JSON.stringify(normalized),prior=objects.get(o.key);
      if(prior&&prior!==fingerprint)throw fail();objects.set(o.key,fingerprint);
      return normalized;
    });
    if(privateInput!==1||privateOutput!==1||sourceScopes.size!==1||!v.keys.every((key:string)=>seen.has(key)))throw fail();
    return{publication_id:v.publication_id,org_id:v.org_id,listing_id:listing,assets:[...v.assets].sort(),keys:[...v.keys].sort(),objects:checked.sort((a,b)=>a.key.localeCompare(b.key))};
  }).sort((a,b)=>a.publication_id.localeCompare(b.publication_id));
}
const defaults:PublicationHeadIO={
  head:(o,signal)=>headObject(R2_BUCKET_RENDERS,o.key,signal),
  admit:(db,org)=>admitMediaRead(db,org,0,false),
};
/** SQL metadata is not physical-object proof. One bounded, non-retrying HEAD
 * per exact descriptor also fences private source disappearance after copying. */
export async function publicationHeadDenials(db:Client,rows:PublicationVisibility[],io:PublicationHeadIO=defaults):Promise<Set<string>>{
  const signal=AbortSignal.timeout(30_000),work=new Map<string,{org:string;object:ObjectReceipt;owners:PublicationVisibility[]}>();
  for(const row of rows)for(const object of row.objects){const old=work.get(object.key);if(old)old.owners.push(row);else work.set(object.key,{org:row.org_id,object,owners:[row]});}
  const jobs=[...work.values()],denied=new Set<string>();let next=0;
  await Promise.all(Array.from({length:Math.min(4,jobs.length)},async()=>{
    for(;;){const index=next++;if(index>=jobs.length)return;const job=jobs[index];let valid=false;
      try{signal.throwIfAborted();await io.admit(db,job.org);const h=await io.head(job.object,AbortSignal.any([signal,AbortSignal.timeout(10_000)]));valid=h.exists&&h.bytes===job.object.bytes&&(h.contentType??"").split(";")[0].trim().toLowerCase()===job.object.mime&&h.etag===job.object.etag;}
      catch{valid=false;}
      if(!valid)for(const owner of job.owners)denied.add(owner.publication_id);
    }
  }));
  return denied;
}
