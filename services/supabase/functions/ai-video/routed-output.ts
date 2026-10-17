import { assert, HttpError } from "../_shared/http.ts";
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
  /** The provider's completed result itself can never become this output: a
   * format with no video extension (an image), or a result over the persist
   * limit. Same 503 as before; details.result_unretainable lets a caller that
   * knows the provider's work is finished (a Kie routed status) decide it is
   * terminal instead of a retry. The journal, CAS and signing are untouched. */
  const unretainable=(message:string)=>new HttpError(503,message,"upstream",{failure_phase:"persistence",result_unretainable:true});
  async function complete(state:DoneState):Promise<{key:string;url:string}>{
    const saved=await existing();if(saved)return saved;
    const extension=extensions[state.mime.split(";")[0].trim().toLowerCase()];
    if(!extension)throw unretainable("The video service returned an unsupported saved format");
    const key=`${stem}.${extension}`;
    let stored:{key:string;bytes:number};
    try{stored=await deps.persist(state,key,async intent=>{assert(intent.key===key,503,"The saved video identity changed","upstream");await deps.register(key,intent.bytes);});}
    catch(error){if((error as {result_unretainable?:unknown}|null)?.result_unretainable===true)throw unretainable("The video service result is over the saved video size limit");throw error;}
    assert(stored.key===key,503,"The saved video identity changed","upstream");
    const result=await existing();assert(result&&result.key===key,503,"The saved video output could not be verified","upstream");return result;
  }
  return{existing,complete};
}
