import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { renewEraseOutput } from "./erase-output.ts";
import { createEraseHandler } from "./erase.ts";
import { HttpError } from "../_shared/http.ts";
const org="10000000-0000-4000-8000-000000000001",user="20000000-0000-4000-8000-000000000002",id="30000000-0000-4000-8000-000000000003";
const key=`video-reflections/${org}/${id}.mp4`,job={id,org_id:org,user_id:user,state:"completed",output_key:key,output_url:"urn:rendprop:r2:renders:"+key};
Deno.test("completed reflection status renews exact private output on every cached read without provider dispatch",async()=>{
 let minted=0;const handler=createEraseHandler({rpc:async()=>({data:job,error:null}),resolveAsset:()=>{throw Error("no input read");},fetch:()=>{throw Error("no paid transport");},falKey:()=>"",persist:()=>{throw Error("no persistence");},completedURL:j=>renewEraseOutput(j,{sign:async(k,seconds)=>{assertEquals(k,key);assertEquals(seconds,600);return `https://private.invalid/fresh-${++minted}`;},read:async args=>{assertEquals(args,{p_org:org,p_user:user,p_job:id});return{data:job,error:null};}})});
 for(let n=1;n<=2;n++){const response=await handler(new Request("https://project.invalid/functions/v1/ai-video/status?erase_job="+id),{orgId:org,userId:user},"status",id);assertEquals((await response.json()).video_url,`https://private.invalid/fresh-${n}`);}
});
Deno.test("completed reflection renewal refuses changed identity, object and revocation before exposing its capability",async()=>{
 for(const current of [{...job,state:"cancelled"},{...job,output_key:key+".other"},{...job,user_id:org},null])await assertRejects(()=>renewEraseOutput(job,{sign:async()=>"secret-capability",read:async()=>({data:current,error:null})}),HttpError,"no longer available");
 let signed=false;await assertRejects(()=>renewEraseOutput({...job,output_key:`video-reflections/${org}/unowned.mp4`},{sign:async()=>{signed=true;return "secret";},read:async()=>({data:job,error:null})}),HttpError,"could not be verified");assertEquals(signed,false);
});
