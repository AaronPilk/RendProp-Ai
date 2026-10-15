// Actual public handler/auth/library/calibration/storage/wait/response helpers.
// Only HTTP Auth/PostgREST/R2/CPU dependencies are synthetic; no provider runs.
import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
const id=(n:number)=>`f8500000-0000-4000-8000-${String(n).padStart(12,"0")}`;
const serviceKey="sb_secret_"+"r".repeat(24);
const actor=id(1),org=id(2),listing=id(3),asset=id(4),evidence=id(5),check=id(6),other=id(7);
const fixtureEnv={SUPABASE_URL:"https://review-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture",SUPABASE_SECRET_KEYS:JSON.stringify({default:serviceKey}),RENDPROP_SECRET_KEY_NAME:"default",CLOUDFLARE_ACCOUNT_ID:"a".repeat(32),R2_ACCESS_KEY_ID:"inert-fixture",R2_SECRET_ACCESS_KEY:"inert-fixture",PHOTO_QUALITY_RENDER_URL:"https://review-cpu.fixture.invalid",PHOTO_QUALITY_RENDER_TRIGGER_KEY:"inert-cpu-trigger"};
function installFixtureEnv(){
 const previous=Object.fromEntries(Object.keys(fixtureEnv).map(key=>[key,Deno.env.get(key)]));
 for(const[key,value]of Object.entries(fixtureEnv))Deno.env.set(key,value);
 return()=>{for(const[key,value]of Object.entries(previous))if(value===undefined)Deno.env.delete(key);else Deno.env.set(key,value);};
}
const restoreImportEnv=installFixtureEnv();let production:typeof import("./index.ts");
try{production=await import("./index.ts");}finally{restoreImportEnv();}
let handler=production!.handler;
const {REVIEW_CONSENT,REVIEW_REQUEST_BYTES}=production;
const {inputHash}=await import("../_shared/funded-serving.ts"),{photoResultKeys}=await import("../ai-photo/photo-result.ts");
const jpeg=(w=1024,h=768)=>new Uint8Array([255,216,255,192,0,11,8,h>>8,h&255,w>>8,w&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
const source=jpeg(),candidate=jpeg(3584,4780),encoded=btoa(String.fromCharCode(...source));
const old={listing_id:listing,original_asset_id:asset,image_b64:encoded,mime:"image/jpeg",edit:"declutter"},key="historical-owned-paid-photo",body={generation_request_key:key,generation_request_body:old};
const pointer={kind:"photo_output",bucket:"renders",key:(await photoResultKeys({actorId:actor,orgId:org,requestKey:key,listingId:listing}))["image/jpeg"],mime:"image/jpeg",metadata:{edit:"declutter",provenance:{id:id(8),recorded:true}}};
const requestSHA=await inputHash(old),oldPointer=JSON.stringify(pointer);
const verdict={policy:"photo-fixed-features-v1",verdict:"pass",action:"accept",confidence:.99,preservation:{geometry:100,openings:100,fixtures:100,surfaces:100,viewpoint:100},artifacts:100,edit_quality:100,findings:[],reason:"Synthetic transport fixture; no real quality assertion."};
async function fixture(){
 const restoreEnv=installFixtureEnv();
 const objects=new Map<string,{bytes:Uint8Array<ArrayBuffer>;mime:string;sha:string;etag:string}>([[pointer.key,{bytes:candidate,mime:"image/jpeg",sha:"b".repeat(64),etag:'"historic-etag"'}]]);
 const state={auth:true,guest:false,deleting:false,withdrawn:false,owned:true,paid:true,rawHash:requestSHA,row:null as any,calibrationCalls:0,puts:0,gets:0,starts:0,calls:[] as string[],rpcs:[] as string[],lastBegin:null as any};
 const scope=()=>({actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,billing_org_id:org,team_org_id:null,library_owner_user_id:actor,listing_owner_user_id:actor,role:"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true});
 const envelope=()=>({...structuredClone(state.row),can_continue:!!state.row?.evidence.output_etag&&state.row?.check.judge_started_at===null,created:undefined});
 const oldFetch=fetch;
 globalThis.fetch=async(raw,init)=>{
  const req=new Request(raw,init),url=new URL(req.url);state.calls.push(req.method+" "+url.hostname+url.pathname);
  const json=(value:unknown,status=200)=>Response.json(value,{status});
  if(url.hostname==="review-cpu.fixture.invalid"){
   state.starts++;assertEquals(req.method,"POST");assertEquals(await req.json(),{check_id:check});return json({accepted:false},503);
  }
  if(url.hostname==="review-db.fixture.invalid"){
   if(url.pathname==="/auth/v1/user")return state.auth?json({id:actor,is_anonymous:state.guest}):json({message:"Invalid token"},401);
   assertEquals(req.headers.get("apikey"),serviceKey);
   if(url.pathname.endsWith("/deletion_requests"))return json(state.deleting?{id:other}:null);
   if(url.pathname.endsWith("/serving_operations")){assertEquals(url.searchParams.get("actor_id"),"eq."+actor);return json({state:"completed",input_sha256:state.rawHash,operation:"/ai-photo"});}
   if(url.pathname.endsWith("/serving_operation_results"))return json({result:pointer});
   if(url.pathname.endsWith("/private_ai_outputs")){assertEquals(url.searchParams.get("user_id"),"eq."+actor);return json(state.owned?{org_id:org,user_id:actor,listing_id:listing,bucket:"renders",storage_key:pointer.key,bytes:candidate.length}:null);}
   if(url.pathname.endsWith("/cost_ledger"))return json(state.paid?[{provider:"gemini",model:"gemini-3.1-flash-image",total_cents:16.7584,meta:{stage:"photo.declutter:0"}}]:[]);
   if(url.pathname.endsWith("/serving_cost_reservations"))return json({id:id(9)});
   if(url.pathname.includes("/rpc/")){
    const name=url.pathname.split("/").at(-1)!,b=await req.json();state.rpcs.push(name);
    if(name==="listing_library_scope")return state.withdrawn?json({message:"RP404: Property withdrawn",code:"P0001"},400):json(scope());
    if(name==="photo_quality_status"){
     assertEquals(b,{p_actor:actor,p_check:check});
     return state.deleting?json({message:"RP404: Account unavailable",code:"P0001"},400):json(envelope());
    }
    if(name==="photo_quality_calibration_begin"){
     state.calibrationCalls++;state.lastBegin=b;assertEquals(b.p_actor,actor);assertEquals(b.p_org,org);assertEquals(b.p_request_sha256,requestSHA);assertEquals(b.p_output.source_key,pointer.key);
     if(state.row)return json({...envelope(),created:false});
     const root=`ai-router/${org}/photo-evidence/${actor}/${evidence}/`;
     state.row={evidence:{id:evidence,purpose:"calibration",actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,request_key:key,request_sha256:requestSHA,policy:"photo-fixed-features-v1",edit:"declutter",style:null,input:{...b.p_input,bucket:"renders",key:root+"input.jpg"},output:null,input_etag:null,output_etag:null,state:"pending",provenance_id:null},check:{id:check,evidence_id:evidence,policy:"photo-fixed-features-v1",state:"pending",lease_token:null,lease_until:null,judge_started_at:null},can_continue:false};return json({...envelope(),created:true});
    }
    if(name==="photo_quality_set_context"){assertEquals(b.p_request_sha256,requestSHA);state.row.evidence.judge_context=b.p_context;return json(envelope());}
    if(name==="photo_quality_evidence_reserve"){
     assertEquals(b.p_actor,actor);const {generation_stage,provider,model,...facts}=b.p_output;
     Object.assign(state.row.evidence,{output:{...facts,bucket:"renders",key:`ai-router/${org}/photo-evidence/${actor}/${evidence}/candidate.jpg`},generation_stage,generation_provider:provider,generation_model:model});return json(state.row.evidence);
    }
    if(name==="photo_quality_evidence_receipt"){
     const e=state.row.evidence;e[b.p_kind+"_etag"]=b.p_etag;e.state=b.p_kind==="input"?"input_ready":"evidence_ready";return json(envelope());
    }
    throw Error("Forbidden generation/funding/other RPC "+name);
   }
  }
  if(url.hostname==="a".repeat(32)+".r2.cloudflarestorage.com"){
   const key=decodeURIComponent(url.pathname.split("/").slice(2).join("/")),object=objects.get(key);
   if(req.method==="PUT"){
    state.puts++;assertEquals(req.headers.get("if-none-match"),"*");assert(!key.includes("completed-photo"));
    objects.set(key,{bytes:new Uint8Array(await req.arrayBuffer()),mime:req.headers.get("content-type")!,sha:req.headers.get("x-amz-meta-sha256")!,etag:'"retained-etag"'});return new Response(null,{status:200});
   }
   assert(object,"Only exact owned private objects are readable");
   const headers={"content-type":object.mime,"content-length":String(object.bytes.length),etag:object.etag,"x-amz-meta-sha256":object.sha};
   if(req.method==="HEAD")return new Response(null,{headers});
   assertEquals(req.method,"GET");state.gets++;return new Response(object.bytes,{headers});
  }
  throw Error("No supplier/generation/other transport allowed "+url.hostname+url.pathname);
 };
 const request=(path="",method="POST",value:unknown=body,headers:Record<string,string>={})=>new Request("https://public.fixture.invalid/functions/v1/photo-quality-review"+path,{method,headers:{authorization:"Bearer actual-auth-fixture","x-org-id":org,"content-type":"application/json","x-rendprop-ai-consent":REVIEW_CONSENT,...headers},...(method==="GET"||method==="OPTIONS"?{}:{body:JSON.stringify(value)})});
 const run=async(req=request())=>{const res=await handler(req);return{status:res.status,headers:res.headers,body:await res.json()};};
 return{state,objects,run,request,close:()=>{globalThis.fetch=oldFetch;restoreEnv();}};
}
Deno.test("normal actor's exact owned paid pair is copied once into private calibration; no generation or credit charge",async()=>{
 const f=await fixture();try{
  const first=await f.run();assertEquals(first.status,409);assertEquals(first.body.code,"photo_quality_pending");assertEquals(first.body.check_id,check);assertEquals(first.body.image_b64,undefined);assertEquals(f.state.puts,2);assertEquals(f.state.starts,1);
  assertEquals(f.state.lastBegin.p_input.bytes,source.length);assertEquals(f.state.lastBegin.p_output.bytes,candidate.length);
  assertEquals([...f.objects.values()].at(-2)?.bytes,source);assertEquals([...f.objects.values()].at(-1)?.bytes,candidate);
  const second=await f.run();assertEquals(second.status,409);assertEquals(f.state.puts,2,"Replay never copies new evidence or creates a new check");assertEquals(f.state.calibrationCalls,2);
  assertEquals(JSON.stringify(pointer),oldPointer,"Old result pointer/provenance stays byte-identical");assert(!f.state.rpcs.some(n=>n.startsWith("serving_")||n.includes("register")||n==="photo_quality_begin"));
  assertEquals(first.headers.get("cache-control"),"no-store");assertEquals(first.headers.get("access-control-allow-methods"),"GET, POST, OPTIONS");
 }finally{f.close();}
});
Deno.test("fresh Auth, named account, current library, exact paid lineage and undeleted account fence POST before copying",async()=>{
 for(const fault of["auth","guest","deleting","foreign-library","withdrawn","owned","paid","rawHash"]){const f=await fixture();try{
  if(fault==="auth")f.state.auth=false;else if(fault==="guest")f.state.guest=true;else if(fault==="deleting")f.state.deleting=true;else if(fault==="withdrawn")f.state.withdrawn=true;else if(fault==="owned")f.state.owned=false;else if(fault==="paid")f.state.paid=false;else if(fault==="rawHash")f.state.rawHash="f".repeat(64);
  const r=await f.run(f.request("","POST",body,fault==="foreign-library"?{"x-org-id":other}:{}));assert(r.status>=400,fault);assertEquals(f.state.puts,0,fault);assertEquals(f.state.gets,0,fault);assertEquals(f.state.starts,0,fault);assertEquals(f.state.calibrationCalls,0,fault);
 }finally{f.close();}}
});
Deno.test("current consent attestation and selected-library header are required before any pair read or continuation",async()=>{
 for(const headers of[{"x-rendprop-ai-consent":""},{"x-rendprop-ai-consent":"property-video-jobs-v1"},{"x-org-id":""}] as Record<string,string>[]){const f=await fixture();try{const r=await f.run(f.request("","POST",body,headers));assert(r.status===400||r.status===403);assertEquals(f.state.gets,0);assertEquals(f.state.puts,0);assertEquals(f.state.starts,0);assertEquals(f.state.calibrationCalls,0);}finally{f.close();}}
});
Deno.test("GET exact calibration status is read-only after consent revocation and never returns media or prospective results",async()=>{
 const f=await fixture();try{
  await f.run();f.state.row.check.state="accept";f.state.row.check.result=verdict;f.state.row.evidence.state="accept";
  const before={puts:f.state.puts,gets:f.state.gets,starts:f.state.starts,begin:f.state.calibrationCalls};f.state.rpcs=[];
  const r=await f.run(f.request("/status?check_id="+check,"GET",null,{"x-rendprop-ai-consent":""}));assertEquals(r.status,200);assertEquals(r.body.publishable,false);assertEquals(r.body.purpose,"calibration");assertEquals(r.body.result,verdict);assertEquals(r.body.image_b64,undefined);assertEquals(r.body.asset_key,undefined);
  assertEquals({puts:f.state.puts,gets:f.state.gets,starts:f.state.starts,begin:f.state.calibrationCalls},before);assert(f.state.rpcs.every(n=>["photo_quality_status","listing_library_scope"].includes(n)));
  f.state.row.evidence.purpose="prospective";assertEquals((await f.run(f.request("/status?check_id="+check,"GET"))).status,404);f.state.row.evidence.purpose="calibration";
  assertEquals((await f.run(f.request("/status?check_id="+check,"GET",null,{"x-org-id":other}))).status,404);
  f.state.deleting=true;assertEquals((await f.run(f.request("/status?check_id="+check,"GET"))).status,404);
 }finally{f.close();}
});
Deno.test("strict routes, JSON/header/wire bounds and closed outer DTO reject arbitrary authority before evidence",async()=>{
 const f=await fixture();try{
  for(const extra of[{actor_id:other},{model:"override"},{url:"https://evil.invalid"},{policy:"prospective"}])assertEquals((await f.run(f.request("","POST",{...body,...extra}))).status,400);
  assertEquals((await f.run(f.request("/judge"))).status,405);assertEquals((await f.run(f.request("","DELETE"))).status,405);assertEquals((await f.run(f.request("","POST",body,{"content-type":"text/plain"}))).status,400);
  assertEquals((await f.run(f.request("","POST",body,{"content-length":String(REVIEW_REQUEST_BYTES+1)}))).status,413);
  const malformed=new Request("https://public.fixture.invalid/photo-quality-review",{method:"POST",headers:{authorization:"Bearer actor","x-org-id":org,"content-type":"application/json","x-rendprop-ai-consent":REVIEW_CONSENT},body:"not-json"});assertEquals((await f.run(malformed)).status,400);
  for(const path of["/status?check_id=invalid","/status?check_id="+check+"&check_id="+check,"/status?check_id="+check+"&actor="+other])assertEquals((await f.run(f.request(path,"GET"))).status,400);
  assertEquals(f.state.puts,0);assertEquals(f.state.gets,0);assertEquals(f.state.starts,0);assertEquals(f.state.calibrationCalls,0);
  const calls=f.state.calls.length,preflight=await handler(f.request("","OPTIONS"));assertEquals(preflight.status,200);assertEquals(f.state.calls.length,calls);assert(preflight.headers.get("access-control-allow-headers")?.includes("x-rendprop-ai-consent"));
 }finally{f.close();}
});

Deno.test("compiled consent and calibration-only bypasses fail independent public boundary oracles",async()=>{
 const path=new URL("./index.ts",import.meta.url),source=await Deno.readTextFile(path);
 for(const [anchor,replacement,oracle]of [
  ['assert(req.headers.get("x-rendprop-ai-consent")===REVIEW_CONSENT,','assert(true,',async(f:Awaited<ReturnType<typeof fixture>>)=>assertEquals((await f.run(f.request("","POST",body,{"x-rendprop-ai-consent":""}))).status,403)],
  ['assert(row.evidence.purpose==="calibration",','assert(true,',async(f:Awaited<ReturnType<typeof fixture>>)=>{await f.run();f.state.row.evidence.purpose="prospective";assertEquals((await f.run(f.request("/status?check_id="+check,"GET"))).status,404);}],
 ]as const){
  assertEquals(source.split(anchor).length-1,1);
  const text=source.replace(anchor,replacement).replace(/from "(\.\.?\/[^"\n]+)"/g,(_all,specifier)=>`from ${JSON.stringify(new URL(specifier,path).href)}`);
  const mutant=await import("data:application/typescript;base64,"+btoa(unescape(encodeURIComponent(text))));handler=mutant.handler;
  const f=await fixture();try{await assertRejects(()=>oracle(f),Error);}finally{f.close();handler=production.handler;}
 }
});

Deno.test("review fixture restores every process environment override including modern key selector",async()=>{
 const previous=Object.fromEntries(Object.keys(fixtureEnv).map(key=>[key,Deno.env.get(key)]));
 const f=await fixture();try{assert(Deno.env.get("RENDPROP_SECRET_KEY_NAME")==="default");}finally{f.close();}
 for(const[key,value]of Object.entries(previous))assert(Deno.env.get(key)===value,"fixture must restore "+key);
});
