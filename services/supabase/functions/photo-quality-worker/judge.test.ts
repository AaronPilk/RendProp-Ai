import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
const id=(n:number)=>`f8400000-0000-4000-8000-${String(n).padStart(12,"0")}`,org=id(1),actor=id(2),evidence=id(3),check=id(4),listing=id(5),secret="sb_secret_"+"x".repeat(24);
for(const[k,v]of Object.entries({SUPABASE_URL:"https://judge-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"legacy-fixture",SUPABASE_SECRET_KEYS:JSON.stringify({default:secret})}))Deno.env.set(k,v);
const {handler}=await import("./index.ts"),{invokeSavedPhotoJudge}=await import("./judge-client.ts");
const {judgeSavedPhoto}=await import("./judge.ts");
async function invoke(options:{auth?:boolean;extra?:Record<string,unknown>;missingContext?:boolean;withdrawn?:boolean}={}){
 const prior=globalThis.fetch,calls:string[]=[],rpcs:string[]=[];
 const row={evidence:{id:evidence,actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,request_key:"retained-judge-fixture",request_sha256:"a".repeat(64),policy:"photo-fixed-features-v1",edit:"custom",style:null,input:{},output:{image_b64:"NEVER_RETURN_PRIVATE_IMAGE"},input_etag:"source",output_etag:"output",state:options.missingContext?"evidence_ready":"accept",judge_context:null},check:{id:check,evidence_id:evidence,policy:"photo-fixed-features-v1",state:options.missingContext?"derivative_ready":"accept",judge_started_at:null},can_continue:!!options.missingContext};
 globalThis.fetch=async(input,init)=>{const req=new Request(input,init),url=new URL(req.url);calls.push(req.method+" "+url.pathname);assertEquals(url.hostname,"judge-db.fixture.invalid","No provider/CPU/media transport is allowed in this boundary fixture");assertEquals(req.headers.get("apikey"),secret);
  if(url.pathname.endsWith("/photo_quality_checks"))return Response.json({evidence_id:evidence});
  if(url.pathname.endsWith("/photo_edit_evidence"))return Response.json({actor_id:actor,library_org_id:org});
  const name=url.pathname.split("/").at(-1)!,b=await req.json();rpcs.push(name);
  if(name==="photo_quality_status"){assertEquals(b,{p_actor:actor,p_check:check});return Response.json(row);}
  if(name==="listing_library_scope")return options.withdrawn?Response.json({message:"RP404: Property withdrawn",code:"P0001"},{status:400}):Response.json({actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,billing_org_id:org,team_org_id:null,library_owner_user_id:actor,listing_owner_user_id:actor,role:"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true});
  if(name==="photo_quality_failure"){assertEquals(b.p_phase,"quality_context_missing");row.evidence.state="hold";row.check.state="hold";return Response.json(row);}
  throw Error("Unexpected paid/other RPC "+name);
 };
 try{const response=await handler(new Request("https://private.fixture.invalid/photo-quality-worker/judge",{method:"POST",headers:{"content-type":"application/json",...(options.auth===false?{}:{apikey:secret})},body:JSON.stringify({check_id:check,...options.extra})}));return{status:response.status,body:await response.json(),calls,rpcs};}finally{globalThis.fetch=prior;}
}
Deno.test("private judge requires exact service auth and only check_id before any scope read",async()=>{
 const no=await invoke({auth:false});assertEquals(no.status,403);assertEquals(no.calls,[]);
 for(const extra of [{actor_id:actor},{model:"override"},{url:"https://evil.invalid"},{instruction:"new scope"}]){const r=await invoke({extra});assertEquals(r.status,400);assertEquals(r.calls,[]);}
});
Deno.test("private judge derives current actor/library from evidence and replies only IDs/state",async()=>{
 const r=await invoke();assertEquals(r.status,200);assertEquals(r.body,{check_id:check,evidence_id:evidence,state:"accept"});assert(!JSON.stringify(r.body).includes("NEVER_RETURN"));assertEquals(r.rpcs.filter(x=>x==="listing_library_scope").length,2);assert(!r.rpcs.some(x=>x.includes("cost")));
 const withdrawn=await invoke({withdrawn:true});assertEquals(withdrawn.status,404);assert(!withdrawn.rpcs.some(x=>x.includes("cost")));
});
Deno.test("missing retained custom context holds in judge isolate before any paid admission",async()=>{
 const r=await invoke({missingContext:true});assertEquals(r.status,200);assertEquals(r.body.state,"hold");assert(r.rpcs.includes("photo_quality_failure"));assert(!r.rpcs.some(x=>x.includes("cost")));
});
Deno.test("main invokes isolated judge once with selected modern service key and no caller context/media",async()=>{
 for(const lost of [false,true]){const before=globalThis.fetch;let calls=0;globalThis.fetch=async(input,init)=>{calls++;const req=new Request(input,init);assertEquals(req.url,"https://judge-db.fixture.invalid/functions/v1/photo-quality-worker/judge");assertEquals(req.headers.get("apikey"),secret);assertEquals(req.headers.get("authorization"),null);assertEquals(req.redirect,"error");assertEquals(await req.json(),{check_id:check});if(lost)throw Error("Lost reply");return Response.json({check_id:check,evidence_id:evidence,state:"accept"});};try{await invokeSavedPhotoJudge(check);assertEquals(calls,1);}finally{globalThis.fetch=before;}}
});
Deno.test("isolated judge forwards a bounded120second deadline without the old45second cap",async()=>{
 const row={evidence:{id:evidence,actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,request_key:"timeout-fixture",request_sha256:"a".repeat(64),policy:"photo-fixed-features-v1",edit:"stage",state:"evidence_ready"},check:{id:check,evidence_id:evidence,policy:"photo-fixed-features-v1",state:"derivative_ready",judge_started_at:null},can_continue:true}as any;
 const admin={from:(name:string)=>{const q:any={select:()=>q,eq:()=>q,maybeSingle:async()=>({data:name==="photo_quality_checks"?{evidence_id:evidence}:{actor_id:actor,library_org_id:org},error:null})};return q;},rpc:async(name:string)=>({data:name==="photo_quality_status"?row:{actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,billing_org_id:org,team_org_id:null,library_owner_user_id:actor,listing_owner_user_id:actor,role:"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true},error:null})};
 let calls=0;const before=Date.now();
 await judgeSavedPhoto(admin,check,new Request("https://private.fixture.invalid/judge"),async(_admin,received,args)=>{calls++;assertEquals(received.check.id,check);assert(args.deadline!>=before+119000&&args.deadline!<=Date.now()+120000);return received;});
 assertEquals(calls,1);
});
Deno.test("isolated judge client preserves the remaining budget up to120seconds and issues only one request",async()=>{
 const previousFetch=globalThis.fetch,previousTimeout=AbortSignal.timeout;
 try{for(const budget of[undefined,60000,300000]){
  const timers:number[]=[];let calls=0;
  AbortSignal.timeout=(milliseconds:number)=>{timers.push(milliseconds);return previousTimeout(milliseconds);};
  globalThis.fetch=async()=>{calls++;return Response.json({check_id:check,evidence_id:evidence,state:"hold"});};
  await invokeSavedPhotoJudge(check,undefined,budget);assertEquals(calls,1);assertEquals(timers,[Math.min(budget??120000,120000)]);
 }}finally{globalThis.fetch=previousFetch;AbortSignal.timeout=previousTimeout;}
});
