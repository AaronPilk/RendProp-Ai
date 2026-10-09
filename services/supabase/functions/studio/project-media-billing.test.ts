import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { settleProjectPart } from "./project-media.ts";
import type { StudioContext } from "./context.ts";
const actor="ab300109-0000-4000-8000-000000000001",org="ab300109-0000-4000-8000-000000000002",id="ab300109-0000-4000-8000-000000000003",hash="c".repeat(64);
function fixture(exhausted=false) {
  const calls:{name:string;args:Record<string,unknown>}[]=[],writes:string[]=[];
  const media={id,actor_id:actor,org_id:org,sha256:hash,bytes:2,mime:"audio/mpeg",filename:"licensed.mp3",modified:0,parts:1,write_deadline:new Date(Date.now()+60000).toISOString(),receipts:{}};
  const admin={rpc:(name:string,args:Record<string,unknown>)=>({abortSignal:async()=>{
    calls.push({name,args});
    if(name==="studio_project_media_write")return {data:args.p_action==="finish"?{media:{...media,receipts:{"0":{bytes:2,sha256:hash,state:"complete"}}}}:{media,dispatch:args.p_action==="claim"},error:null};
    assertEquals(name,"library_media_storage_reserve");
    assertEquals(args,{p_actor:actor,p_org:org,p_bucket:"uploads",p_key:`studio-project/${org}/${actor}/${id}/0`,p_bytes:2});
    return exhausted?{data:null,error:{message:"RP402: Current actor storage funding exhausted"}}:{data:{reserved:true},error:null};
  }})};
  return {context:{admin,userId:actor,orgId:org} as unknown as StudioContext,calls,writes,storage:{inspect:async()=>null,write:async(key:string)=>{writes.push(key);}}};
}
Deno.test("project upload reserves actor-aware liability while preserving the physical source key",async()=>{
  const f=fixture(),row=await settleProjectPart(f.context,id,0,new Uint8Array([1,2]),hash,new AbortController().signal,f.storage);
  assertEquals(row.org_id,org);assertEquals(f.writes,[`studio-project/${org}/${actor}/${id}/0`]);
  assertEquals(f.calls.map(c=>c.name),["studio_project_media_write","studio_project_media_write","library_media_storage_reserve","studio_project_media_write"]);
});
Deno.test("exhausted actor storage cannot dispatch an unfunded project chunk",async()=>{
  const f=fixture(true);await assertRejects(()=>settleProjectPart(f.context,id,0,new Uint8Array([1,2]),hash,new AbortController().signal,f.storage),HttpError);
  assertEquals(f.writes,[]);assertEquals(f.calls.filter(c=>c.args.p_action==="finish"),[]);
});
