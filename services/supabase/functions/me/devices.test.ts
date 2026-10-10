import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { deviceBinding } from "./devices.ts";
import { HttpError } from "../_shared/http.ts";
const USER="b1dd1010-0000-4000-8000-000000000001",SESSION="b1dd1010-0000-4000-8000-000000000002",DEVICE="b1dd1010-0000-4000-8000-000000000003",TOKEN="ab".repeat(32);
function bearer(claims:Record<string,unknown>={sub:USER,session_id:SESSION}){return "Bearer "+btoa(JSON.stringify({alg:"fixture"}))+"."+btoa(JSON.stringify(claims)).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_")+".signature";}
function request(method="POST",body:Record<string,unknown>={device_token:TOKEN,environment:"sandbox"},auth=bearer(),path="devices"){return new Request("https://edge.invalid/me/"+path,{method,headers:{authorization:auth,"content-type":"application/json"},body:JSON.stringify(body)});}
function fixture(options:{error?:string;badReceipt?:boolean}={}){const calls:Array<{name:string,args:Record<string,unknown>}>=[];return{calls,admin:{rpc:async(name:string,args:Record<string,unknown>)=>{calls.push({name,args});return{data:options.badReceipt?null:name==="notification_unregister_device"?{unregistered:true}:{id:DEVICE,environment:args.p_environment,bundle_id:args.p_bundle_id,last_seen_at:"2026-10-09T00:00:00Z",device_token:TOKEN,session_id:SESSION},error:options.error?{message:options.error}:null};}}};}
Deno.test("device routes derive user and session only from already-verified bearer and never echo credentials",async()=>{
 for(const method of["POST","DELETE"]){const f=fixture();const response=await deviceBinding(request(method),f.admin,USER);assertEquals(response.status,200);const out=await response.json();assertEquals(f.calls.length,1);assertEquals(f.calls[0].name,method==="DELETE"?"notification_unregister_device":"notification_register_device_session");assertEquals(f.calls[0].args.p_user,USER);assertEquals(f.calls[0].args.p_session,SESSION);assertEquals(f.calls[0].args.p_token,TOKEN);assertEquals(f.calls[0].args.p_environment,"sandbox");assert(!JSON.stringify(out).includes(TOKEN));assert(!JSON.stringify(out).includes(SESSION));if(method==="DELETE")assertEquals(out,{ok:true,unregistered:true});}
});
Deno.test("body identity, malformed/unbound session and device input fail before any device mutation",async()=>{
 const cases=[request("POST",{device_token:TOKEN,user_id:USER}),request("DELETE",{device_token:TOKEN,session_id:SESSION}),request("POST",undefined,bearer({sub:DEVICE,session_id:SESSION})),request("POST",undefined,bearer({sub:USER})),request("DELETE",undefined,bearer({sub:USER,session_id:"bad"})),request("POST",undefined,"Bearer not-a-jwt"),request("POST",{device_token:"bad"}),request("DELETE",{device_token:TOKEN,environment:"other"})];
 for(const req of cases){const f=fixture();await assertRejects(()=>deviceBinding(req,f.admin,USER),HttpError);assertEquals(f.calls,[]);}
});
Deno.test("unconfirmed registration/removal is not acknowledged and database errors do not disclose token",async()=>{
 for(const method of["POST","DELETE"]){const f=fixture({badReceipt:true});await assertRejects(()=>deviceBinding(request(method),f.admin,USER),HttpError);const failed=fixture({error:"synthetic database context "+TOKEN});const error=await assertRejects(()=>deviceBinding(request(method),failed.admin,USER),HttpError);assertEquals(error.status,503);assert(!error.message.includes(TOKEN));}
});

// Execute the actual me Deno.serve route, including getUser's Auth request.
const env={SUPABASE_URL:"https://device-fixture.invalid",SUPABASE_ANON_KEY:"fixture-public",SUPABASE_SERVICE_ROLE_KEY:"fixture-service"};
const saved=new Map(Object.keys(env).map(k=>[k,Deno.env.get(k)]));for(const[k,v]of Object.entries(env))Deno.env.set(k,v);
let handler!:(req:Request)=>Promise<Response>;const serve=Object.getOwnPropertyDescriptor(Deno,"serve")!;
Object.defineProperty(Deno,"serve",{...serve,value:(fn:typeof handler)=>{handler=fn;return{};}});
try{await import("./index.ts?actual-device-route");}finally{Object.defineProperty(Deno,"serve",serve);for(const[k,v]of saved)if(v===undefined)Deno.env.delete(k);else Deno.env.set(k,v);}
Deno.test("actual me authenticates before session mutation and DELETE devices never deletes account",async()=>{
 const fetchOld=globalThis.fetch;let deny=false;const calls:Array<{path:string,method:string,body:any}>=[];
 globalThis.fetch=async(input,init)=>{const req=new Request(input,init),url=new URL(req.url);assertEquals(url.hostname,"device-fixture.invalid");const body=req.method==="POST"?await req.json():null;calls.push({path:url.pathname,method:req.method,body});if(url.pathname==="/auth/v1/user")return deny?Response.json({message:"invalid token"},{status:401}):Response.json({id:USER,aud:"authenticated",email:"fixture@example.invalid",role:"authenticated"});if(url.pathname==="/rest/v1/rpc/notification_unregister_device")return Response.json({unregistered:true});if(url.pathname==="/rest/v1/rpc/notification_register_device_session")return Response.json({id:DEVICE,environment:body.p_environment,bundle_id:null,last_seen_at:null});throw Error("Forbidden/unmodeled route "+url.pathname);};
 try{for(const method of["POST","DELETE"]){calls.length=0;const response=await handler(request(method));assertEquals(response.status,200);assertEquals(calls.map(c=>c.path),["/auth/v1/user","/rest/v1/rpc/notification_"+(method==="POST"?"register_device_session":"unregister_device")]);assertEquals(calls[1].body.p_user,USER);assertEquals(calls[1].body.p_session,SESSION);}
 deny=true;calls.length=0;assertEquals((await handler(request("DELETE"))).status,401);assertEquals(calls.length,1);
 deny=false;calls.length=0;assertEquals((await handler(request("DELETE",undefined,bearer(),"devices/extra"))).status,404);assertEquals(calls.length,1);
 }finally{globalThis.fetch=fetchOld;}
});
