import {assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {admitMediaRead,deliveryBytes,requireMediaGateway} from "./media-delivery-admission.ts";
const receipt=(bytes:number)=>({admitted:true,legacy_unbudgeted:false,basis:"product_media_serving",financial_budget_bypassed:true,request_counted:true,bytes_counted:bytes,infrastructure_cost:"unpriced"});
Deno.test("ordinary exact media usage uses unchanged service RPC/current actor-library contract",async()=>{
 const calls:unknown[]=[];const admin={rpc:async(name:string,args:Record<string,unknown>)=>{calls.push({name,args});return{data:receipt(Number(args.p_bytes)),error:null};}};
 await admitMediaRead(admin,"org",0);await admitMediaRead(admin,"org",1234,true,"actor");
 assertEquals(calls,[{name:"media_delivery_admit",args:{p_org:"org",p_bytes:0,p_required:true}},{name:"library_media_delivery_admit",args:{p_actor:"actor",p_org:"org",p_bytes:1234,p_required:true}}]);
});
Deno.test("unpriced metering receipt cannot pretend paid funding or omit exact usage",async()=>{
 for(const changed of [{bytes_counted:1233},{request_counted:false},{infrastructure_cost:"paid"},{financial_budget_bypassed:false}])await assertRejects(()=>admitMediaRead({rpc:async()=>({data:{...receipt(1234),...changed},error:null})},"org",1234));
 await assertRejects(()=>admitMediaRead({rpc:async()=>({data:null,error:{message:"RP403: Current listing access required"}})},"org",0));
});
Deno.test("gateway shared-secret authentication and byte parsing are unchanged",async()=>{
 const before=Deno.env.get("MEDIA_GATEWAY_SECRET");try{Deno.env.set("MEDIA_GATEWAY_SECRET","a".repeat(64));await requireMediaGateway(new Request("https://closed.invalid",{headers:{"X-Rendprop-Media-Gateway":"a".repeat(64)}}));await assertRejects(()=>requireMediaGateway(new Request("https://closed.invalid")));await assertRejects(()=>requireMediaGateway(new Request("https://closed.invalid",{headers:{"X-Rendprop-Media-Gateway":"b".repeat(64)}})));assertEquals(deliveryBytes(new Request("https://closed.invalid?bytes=268435456")),268435456);}finally{before===undefined?Deno.env.delete("MEDIA_GATEWAY_SECRET"):Deno.env.set("MEDIA_GATEWAY_SECRET",before);}
});
