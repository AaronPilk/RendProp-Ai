// Actual public lead capture; no real Auth, CRM, email or storage services.
import {assert,assertEquals}from "https://deno.land/std@0.224.0/assert/mod.ts";
const ORG="de660103-0000-4000-8000-000000000001",LISTING="de660103-0000-4000-8000-000000000002",RENDER="de660103-0000-4000-8000-000000000003",LEAD="de660103-0000-4000-8000-000000000004";
const fixtureEnv={SUPABASE_URL:"https://lead-privacy-fixture.invalid",SUPABASE_ANON_KEY:"fixture-public",SUPABASE_SERVICE_ROLE_KEY:"fixture-service"};
const previous=new Map(Object.keys(fixtureEnv).map(key=>[key,Deno.env.get(key)]));for(const[key,value]of Object.entries(fixtureEnv))Deno.env.set(key,value);
let handler!:(req:Request)=>Promise<Response>;const serve=Object.getOwnPropertyDescriptor(Deno,"serve")!;
Object.defineProperty(Deno,"serve",{configurable:serve.configurable,enumerable:serve.enumerable,writable:true,value:(fn:typeof handler)=>{handler=fn;return{};}});
try{await import("./index.ts?capture-privacy-proof");}finally{Object.defineProperty(Deno,"serve",serve);for(const[key,value]of previous)if(value===undefined)Deno.env.delete(key);else Deno.env.set(key,value);}
async function invoke(options:{duplicate?:boolean,deleted?:boolean,slug?:string,honey?:boolean,turnstileClosed?:boolean,rateLimited?:boolean}={}){
 const old=globalThis.fetch,keys=["TURNSTILE_SECRET_KEY","TURNSTILE_OPTIONAL","GHL_API_KEY","GHL_LOCATION_ID"],saved=new Map(keys.map(key=>[key,Deno.env.get(key)]));
 Deno.env.delete("TURNSTILE_SECRET_KEY");if(options.turnstileClosed)Deno.env.delete("TURNSTILE_OPTIONAL");else Deno.env.set("TURNSTILE_OPTIONAL","1");Deno.env.set("GHL_API_KEY","fixture-only");Deno.env.set("GHL_LOCATION_ID","fixture-location");
 const calls:Array<{url:string,method:string,body:Record<string,unknown>|undefined}>=[];
 globalThis.fetch=async(input,init)=>{const req=new Request(input,init),url=new URL(req.url),body=req.method==="POST"?await req.json():undefined;calls.push({url:req.url,method:req.method,body});
  if(url.hostname!=="lead-privacy-fixture.invalid")throw new Error("Public capture leaked a buyer to an external service");
  if(url.pathname==="/rest/v1/rpc/bump_rate")return Response.json(!options.rateLimited);
  if(url.pathname==="/rest/v1/renders")return Response.json({id:RENDER,listing_id:LISTING});
  if(url.pathname==="/rest/v1/listings")return Response.json({id:LISTING,org_id:ORG,deleted_at:options.deleted?"2026-10-05T00:00:00Z":null});
  if(url.pathname==="/rest/v1/leads"&&req.method==="GET")return Response.json(options.duplicate?{id:LEAD}:null);
  if(url.pathname==="/rest/v1/leads"&&req.method==="POST")return Response.json({id:LEAD},{status:201});
  throw new Error("Unmodeled capture request: "+url.pathname);
 };
 try{const response=await handler(new Request("https://edge.invalid/leads",{method:"POST",headers:{"content-type":"application/json","cf-connecting-ip":"192.0.2.10"},body:JSON.stringify({slug:options.slug??"published-fixture",name:"Synthetic buyer",email:"buyer@fixture.invalid",phone:"7275550101",...(options.honey?{_hp:"bot"}:{})})}));return{status:response.status,body:await response.json(),calls};}
 finally{globalThis.fetch=old;for(const[key,value]of saved)if(value===undefined)Deno.env.delete(key);else Deno.env.set(key,value);}
}
Deno.test("actual lead capture stores buyer in exact workspace without global CRM upsert or identity response",async()=>{
 const out=await invoke();assertEquals(out.status,201);assertEquals(out.body,{ok:true,accepted:true});const insert=out.calls.find(c=>new URL(c.url).pathname==="/rest/v1/leads"&&c.method==="POST")!.body!;
 assertEquals(insert.org_id,ORG);assertEquals(insert.listing_id,LISTING);assertEquals(insert.render_id,RENDER);assertEquals(insert.synced_crm,false);assertEquals(insert.email,"buyer@fixture.invalid");assert(out.calls.every(c=>new URL(c.url).hostname==="lead-privacy-fixture.invalid"));
});
Deno.test("actual duplicate and honeypot replies contain no lead identity or deduplication oracle",async()=>{
 for(const opts of [{duplicate:true},{honey:true}]){const out=await invoke(opts);assertEquals(out.status,200);assertEquals(out.body,opts.honey?{ok:true}:{ok:true,accepted:true});assert(!out.calls.some(c=>new URL(c.url).pathname==="/rest/v1/leads"&&c.method==="POST"));}
});
Deno.test("build 57: actual capture rate limit answers 429 before any tour lookup, and Turnstile fails closed with 403 before any lookup or insert",async()=>{
 const limited=await invoke({rateLimited:true});assertEquals(limited.status,429);assertEquals(limited.body.code,"rate_limited");
 assertEquals(limited.calls.map(c=>new URL(c.url).pathname),["/rest/v1/rpc/bump_rate"]);
 const closed=await invoke({turnstileClosed:true});assertEquals(closed.status,403);assert(String(closed.body.error).includes("Bot check failed"));
 assert(!closed.calls.some(c=>["/rest/v1/renders","/rest/v1/listings","/rest/v1/leads"].includes(new URL(c.url).pathname)));
 // The honeypot still answers its plain shape ahead of the Turnstile gate so bots learn nothing from a closed gate either.
 const honey=await invoke({turnstileClosed:true,honey:true});assertEquals(honey.status,200);assertEquals(honey.body,{ok:true});
});
Deno.test("sample and deleted listings never create unmanageable buyer records",async()=>{
 for(const opts of [{slug:"estate-demo"},{slug:"demo"},{deleted:true}]){const out=await invoke(opts);assert([400,404].includes(out.status));assert(!out.calls.some(c=>new URL(c.url).pathname==="/rest/v1/leads"&&c.method==="POST"));}
});
