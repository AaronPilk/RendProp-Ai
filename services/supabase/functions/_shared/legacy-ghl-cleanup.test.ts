import { assert,assertEquals,assertRejects }from "https://deno.land/std@0.224.0/assert/mod.ts";
import {cleanupLegacyGhlTarget}from "./legacy-ghl-cleanup.ts";
const org="de220103-0000-4000-8000-000000000001",other="de220103-0000-4000-8000-000000000002";
async function fixture(work:()=>Promise<void>){const old=[Deno.env.get("GHL_API_KEY"),Deno.env.get("GHL_LOCATION_ID")];Deno.env.set("GHL_API_KEY","fixture");Deno.env.set("GHL_LOCATION_ID","fixture-location");try{await work();}finally{for(const[i,key]of["GHL_API_KEY","GHL_LOCATION_ID"].entries()){if(old[i]===undefined)Deno.env.delete(key);else Deno.env.set(key,old[i]!);}}}
Deno.test("legacy phone-only cleanup matches normalized identity and exact tenant before DELETE",()=>fixture(async()=>{
 const calls:Request[]=[];const contact={id:"fixture-contact",phone:"7275550101",tags:[`rendprop_org:${org}`]};
 const result=await cleanupLegacyGhlTarget({org_id:org,phone:"+1 (727) 555-0101"},(input,init)=>{const req=new Request(input,init);calls.push(req);assert(req.signal);assertEquals(req.redirect,"error");return Promise.resolve(req.method==="DELETE"?new Response(null,{status:204}):Response.json(new URL(req.url).pathname.endsWith("/contacts/")?{contacts:[contact]}:{contact}));});
 assertEquals(result,{removed:1,untagged:0,leftover:0});assertEquals(calls.map(c=>c.method),["GET","GET","DELETE"]);
}));
Deno.test("merged legacy agency identity is untagged without deleting another agency contact",()=>fixture(async()=>{
 const calls:Request[]=[];const contact={id:"fixture-multi",email:"buyer@fixture.invalid",tags:[`rendprop_org:${org}`,`rendprop_org:${other}`]};
 const result=await cleanupLegacyGhlTarget({org_id:org,email:"buyer@fixture.invalid"},(input,init)=>{const req=new Request(input,init);calls.push(req);return Promise.resolve(req.method==="DELETE"?new Response(null,{status:204}):Response.json(new URL(req.url).pathname.endsWith("/contacts/")?{contacts:[contact]}:{contact}));});
 assertEquals(result,{removed:0,untagged:1,leftover:0});assert(calls[2].url.endsWith("/tags"));assertEquals(await calls[2].json(),{tags:[`rendprop_org:${org}`]});
}));
Deno.test("changed full contact identity and missing tenant tag retain legacy cleanup",()=>fixture(async()=>{
 for(const full of [{id:"fixture",email:"changed@fixture.invalid",tags:[`rendprop_org:${org}`]},{id:"fixture",email:"buyer@fixture.invalid",tags:[`rendprop_org:${other}`]}]){
  let deletes=0;const result=await cleanupLegacyGhlTarget({org_id:org,email:"buyer@fixture.invalid"},(input,init)=>{const req=new Request(input,init);if(req.method==="DELETE")deletes++;return Promise.resolve(Response.json(new URL(req.url).pathname.endsWith("/contacts/")?{contacts:[{id:"fixture",email:"buyer@fixture.invalid"}]}:{contact:full}));});assertEquals(deletes,0);assertEquals(result.leftover,1);
 }
}));
Deno.test("CRM pagination, unavailable inventory and oversized body cannot report cleanup success",()=>fixture(async()=>{
 for(const reply of [Response.json({contacts:[],meta:{nextPageUrl:"https://fixture.invalid/next"}}),Response.json({contacts:[],meta:{total:21}}),Response.json({contacts:"broken"}),new Response("x".repeat(131073)),new Response(null,{status:503})])await assertRejects(()=>cleanupLegacyGhlTarget({org_id:org,email:"buyer@fixture.invalid"},()=>Promise.resolve(reply)));
}));
