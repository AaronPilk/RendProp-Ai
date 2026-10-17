import { assert } from "../_shared/http.ts";
import type { DoneState } from "../_shared/providers/types.ts";
type Row = Record<string, unknown>;
export interface RoutedOutputIdentity { orgId:string; userId:string; listingId:string|null; provider:string; model:string; requestId:string; submittedAt:string; kind:string }
interface Dependencies {
  find(keys:string[]):Promise<Row[]>;
  register(key:string,bytes:number):Promise<void>;
  head(key:string):Promise<{exists:boolean;bytes:number|null}>;
  persist(state:DoneState,key:string,beforeWrite:(intent:{key:string;bytes:number})=>Promise<void>):Promise<{key:string;bytes:number}>;
  sign(key:string):Promise<string>;
}
/** A signed provider receipt has exactly one deterministic private result.
 * A prefix never proves ownership: reuse requires the exact scoped SQL journal,
 * current actor/listing authority and the observed object size. Writes use CAS.
 * A lost PUT response is recovered from that journal without redownloading. */
export async function createRoutedOutput(identity:RoutedOutputIdentity,deps:Dependencies) {
  const digest=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(JSON.stringify({v:1,...identity})))),n=>n.toString(16).padStart(2,"0")).join("");
  const stem=`ai-router/${identity.orgId}/completed-video/${digest}`;
  const extensions:Record<string,string>={"video/mp4":"mp4","video/quicktime":"mov","video/webm":"webm"};
  const keys=Object.values(extensions).map(ext=>`${stem}.${ext}`);
  async function existing():Promise<{key:string;url:string}|null>{
    const rows=await deps.find(keys);
    assert(Array.isArray(rows)&&rows.length<=1,503,"The saved video output could not be verified","upstream");
    if(!rows.length)return null;
    const row=rows[0],key=String(row.storage_key),bytes=Number(row.bytes);
    assert(keys.includes(key)&&row.org_id===identity.orgId&&row.user_id===identity.userId&&row.listing_id===identity.listingId&&row.bucket==="renders"&&Number.isSafeInteger(bytes)&&bytes>0&&bytes<=104857600,503,"The saved video output could not be verified","upstream");
    await deps.register(key,bytes);
    const head=await deps.head(key);
    if(!head.exists)return null;
    assert(head.bytes===bytes,503,"The saved video output could not be verified","upstream");
    const url=await deps.sign(key);
    assert(typeof url==="string"&&url.length>0,503,"The saved video link could not be verified","upstream");
    await deps.register(key,bytes);
    return{key,url};
  }
  async function complete(state:DoneState):Promise<{key:string;url:string}>{
    const saved=await existing();if(saved)return saved;
    const extension=extensions[state.mime.split(";")[0].trim().toLowerCase()];
    assert(extension,503,"The video service returned an unsupported saved format","upstream");
    const key=`${stem}.${extension}`;
    const stored=await deps.persist(state,key,async intent=>{assert(intent.key===key,503,"The saved video identity changed","upstream");await deps.register(key,intent.bytes);});
    assert(stored.key===key,503,"The saved video identity changed","upstream");
    const result=await existing();assert(result&&result.key===key,503,"The saved video output could not be verified","upstream");return result;
  }
  return{existing,complete};
}
