import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
for(const[k,v]of Object.entries({SUPABASE_URL:"https://v2-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture",GEMINI_API_KEY:"inert-fixture"}))Deno.env.set(k,v);
let served=0;const serve=Deno.serve;Deno.serve=(()=>{served++;throw Error("Import must not bind an HTTP listener");})as typeof Deno.serve;
let mod:typeof import("./index.ts");try{mod=await import("./index.ts");}finally{Deno.serve=serve;}
const {handleAIPhotoV2,canonicalPhotoRequest}=mod!;
Deno.test("importing versioned wrapper/strict canonical callback opens no listener",()=>assertEquals(served,0));
Deno.test("fixed root/status rewrite preserves origin/query/auth/headers/method and one unread byte stream",async()=>{
 const bytes=new Uint8Array(1_000_000).fill(123);let pulls=0;
 const stream=new ReadableStream<Uint8Array>({pull(controller){pulls++;controller.enqueue(bytes);controller.close();}},{highWaterMark:0});
 const req=new Request("https://ordinary.example/functions/v1/ai-photo-v2?keep=a%2Fb&target=https%3A%2F%2Fevil.invalid",{method:"POST",headers:{authorization:"Bearer ordinary-user","x-org-id":"owned-library","idempotency-key":"stable-operation","content-type":"application/json","x-rendprop-photo-quality-protocol":"retained-operation-v1"},body:stream,signal:new AbortController().signal});
 const original=req.url;let ran=0;
 const response=await handleAIPhotoV2(req,async forwarded=>{
  ran++;assertEquals(new URL(forwarded.url).origin,new URL(original).origin);assertEquals(new URL(forwarded.url).pathname,"/functions/v1/ai-photo");assertEquals(new URL(forwarded.url).search,new URL(original).search);assertEquals(forwarded.method,"POST");assertEquals([...forwarded.headers],[...req.headers]);assertEquals(pulls,0);assertEquals(req.bodyUsed,false);
  assertEquals(new Uint8Array(await forwarded.arrayBuffer()),bytes);return Response.json({forwarded:true});
 });
 assertEquals(response.status,200);assertEquals(ran,1);assertEquals(pulls,1);assertEquals(req.bodyUsed,true);assertEquals(response.headers.get("cache-control"),"no-store");assert(response.headers.get("access-control-allow-headers")?.includes("x-rendprop-photo-quality-protocol"));
 for(const prefix of["","/functions/v1"]){const r=canonicalPhotoRequest(new Request("https://ordinary.example"+prefix+"/ai-photo-v2/status?check_id=saved",{headers:{authorization:"Bearer actor"}}));assertEquals(r.url,"https://ordinary.example"+prefix+"/ai-photo/status?check_id=saved");assertEquals(r.method,"GET");assertEquals(r.headers.get("authorization"),"Bearer actor");}
});
Deno.test("only exact versioned root/status and corresponding methods can reach shared handler",async()=>{
 let calls=0;const run=async()=>{calls++;return Response.json({});};
 for(const path of["/ai-photo-v2/","/ai-photo-v2/check-existing","/ai-photo-v2/status/extra","/ai-photo","/other/ai-photo-v2","/functions/v1/ai-photo-v2/judge"]){const res=await handleAIPhotoV2(new Request("https://ordinary.example"+path,{method:"POST"}),run);assertEquals(res.status,404);}
 for(const [path,method]of[["/ai-photo-v2","GET"],["/ai-photo-v2/status","POST"],["/ai-photo-v2","DELETE"]])assertEquals((await handleAIPhotoV2(new Request("https://ordinary.example"+path,{method}),run)).status,405);
 assertEquals(calls,0);
 const preflight=await handleAIPhotoV2(new Request("https://ordinary.example/ai-photo-v2",{method:"OPTIONS"}));assertEquals(preflight.status,200);assertEquals(calls,0);
});
Deno.test("actual versioned entry still authenticates ordinary JWT before any request body or provider",async()=>{
 const previous=fetch,calls:string[]=[];let pulls=0;
 globalThis.fetch=async(raw,init)=>{const req=new Request(raw,init);calls.push(req.url);assertEquals(req.url,"https://v2-db.fixture.invalid/auth/v1/user");assertEquals(req.headers.get("authorization"),"Bearer expired-caller");return Response.json({message:"expired"},{status:401});};
 try{
  const body=new ReadableStream<Uint8Array>({pull(c){pulls++;c.enqueue(new Uint8Array([1]));c.close();}},{highWaterMark:0});
  const r=await handleAIPhotoV2(new Request("https://ordinary.example/ai-photo-v2",{method:"POST",headers:{authorization:"Bearer expired-caller"},body}));assertEquals(r.status,401);assertEquals(calls.length,1);assertEquals(pulls,0);
 }finally{globalThis.fetch=previous;}
});
Deno.test("forwarded request cancellation remains attached without reconstructing its body",()=>{
 const control=new AbortController(),req=new Request("https://ordinary.example/ai-photo-v2",{method:"POST",body:"exact",signal:control.signal}),forward=canonicalPhotoRequest(req);assertEquals(forward.signal.aborted,false);control.abort();assertEquals(forward.signal.aborted,true);
});

Deno.test("request-key status GET keeps exact opaque key nullable listing and selected-library headers through alias",()=>{
 for(const prefix of["","/functions/v1"])for(const listing of[null,"EA100606-0000-4000-8000-000000000003"]){
  const query=new URLSearchParams({request_key:"EA100606-0000-4000-8000-0000000000A1"});if(listing)query.set("listing_id",listing);
  const request=new Request("https://ordinary.example"+prefix+"/ai-photo-v2/status?"+query,{headers:{authorization:"Bearer owner","x-org-id":"owned-library"}});
  const forwarded=canonicalPhotoRequest(request),url=new URL(forwarded.url);
  assertEquals(url.pathname,prefix+"/ai-photo/status");assertEquals(url.search,new URL(request.url).search);assertEquals(forwarded.method,"GET");assertEquals([...forwarded.headers],[...request.headers]);assertEquals(forwarded.body,null);
 }
});
Deno.test("actual request-key status GET authenticates before any saved lookup delivery or provider",async()=>{
 const previous=fetch,calls:string[]=[];
 globalThis.fetch=async(raw,init)=>{const req=new Request(raw,init);calls.push(req.url);assertEquals(req.url,"https://v2-db.fixture.invalid/auth/v1/user");assertEquals(req.headers.get("authorization"),"Bearer expired-status-caller");return Response.json({message:"expired"},{status:401});};
 try{const response=await handleAIPhotoV2(new Request("https://ordinary.example/ai-photo-v2/status?request_key=EA100606-0000-4000-8000-0000000000A1",{headers:{authorization:"Bearer expired-status-caller","x-org-id":"owned-library"}}));assertEquals(response.status,401);assertEquals(calls.length,1);}finally{globalThis.fetch=previous;}
});
