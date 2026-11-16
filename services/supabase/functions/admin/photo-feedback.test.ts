// GET /admin/photo-feedback: window handling, verbatim honesty wording, null
// rates, fail-closed shape checks, and the ACTUAL admin dispatcher wiring
// (requireAdmin + GET-only + per-admin rate limit before the route).
// Closed: the RPC is injected, fetch refuses any network.
import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
for(const [k,v] of Object.entries({SUPABASE_URL:"https://admin-feedback.fixture.invalid",SUPABASE_SERVICE_ROLE_KEY:"test-service-role-key",SUPABASE_ANON_KEY:"test-anon-key"}))Deno.env.set(k,v);
const {handlePhotoFeedback,PHOTO_FEEDBACK_REPORT_KEYS}=await import("./photo-feedback.ts");
const {HttpError}=await import("../_shared/http.ts");

const NOW=new Date("2026-10-17T20:00:00.000Z");
function report(extra:Record<string,unknown>={}){
 return {from:"x",to:"y",basis:"Ledger amounts are internal modeled estimates, not supplier invoices. Breakdowns are observational: differences between edits, providers, models or recipe revisions are not evidence that one setting is better.",
  data_range:{first_generated_at:null,last_generated_at:null,first_feedback_at:null,last_feedback_at:null},
  generated:{outputs:0,accepted:0,refused:0,held:0,pending:0,retained_candidates:0,excluded_calibration_checks:0},
  explicit:{reviewable_outputs:0,reviewed_outputs:0,feedback_rows:0,useful:0,needs_work:0,useful_rate:null,coverage:null,unreviewed_outputs:0,reviewers:0},
  historical:{feedback_rows:0,outputs:0,useful:0,needs_work:0,basis:"…"},signals:{accuracy_ack:0,manual_selection:0,automatic_selection:0,export:0,publication:0,note:"…"},
  reasons:[],fidelity_vs_taste:{},by_edit:[],by_provider_model:[],by_recipe_revision:[],
  cost:{attributable_attempts:0,recorded_cents:0,attempts_per_useful:null,recorded_cents_per_useful:null,basis:"Internal modeled estimates, never invoices."},
  regression_cases:{active:0,withdrawn:0,by_defect:[],by_recipe_revision:[]},sample_note:"Every cell carries its own n.",...extra};
}
async function closed<T>(work:()=>Promise<T>):Promise<T>{
 const previous=globalThis.fetch;globalThis.fetch=(()=>{throw new Error("Unexpected network call");}) as typeof fetch;
 try{return await work();}finally{globalThis.fetch=previous;}
}
const get=(query="")=>new Request("https://fixture.invalid/functions/v1/admin/photo-feedback"+query);

Deno.test("each window asks the SQL report for exactly that range and echoes it",async()=>{
 for(const [query,window,days] of [["","30d",30],["?window=7d","7d",7],["?window=30d","30d",30],["?window=90d","90d",90]] as const){
  const calls:{name:string;args:Record<string,unknown>}[]=[];
  const response=await closed(()=>handlePhotoFeedback(get(query),async(name,args)=>{calls.push({name,args});return{data:report(),error:null};},()=>NOW));
  assertEquals(response.status,200);assertEquals(response.headers.get("cache-control"),"no-store");
  assertEquals(calls,[{name:"photo_feedback_report",args:{p_from:new Date(NOW.getTime()-days*86_400_000).toISOString(),p_to:NOW.toISOString()}}]);
  const body=await response.json();assertEquals(body.generated_at,NOW.toISOString());assertEquals(body.window,window);
  for(const key of PHOTO_FEEDBACK_REPORT_KEYS)assert(key in body,key);
 }
});
Deno.test("honesty wording and null rates reach the console verbatim",async()=>{
 const response=await closed(()=>handlePhotoFeedback(get("?window=7d"),async()=>({data:report(),error:null}),()=>NOW));
 const body=await response.json();
 assert(body.basis.includes("not supplier invoices"));assert(body.basis.includes("not evidence that one setting is better"));
 assertEquals(body.explicit.useful_rate,null,"no reviews is null, never 0");assertEquals(body.explicit.coverage,null);assertEquals(body.cost.recorded_cents_per_useful,null);
});
Deno.test("unknown windows and extra parameters are refused before the RPC",async()=>{
 for(const query of ["?window=1d","?window=","?window=7d&window=30d","?window=7d&org=x","?window=hasOwnProperty","?window=__proto__"]){
  let called=false;
  const error=await assertRejects(()=>closed(()=>handlePhotoFeedback(get(query),async()=>{called=true;return{data:report(),error:null};},()=>NOW)),HttpError);
  assertEquals(error.status,400,query);assertEquals(called,false);
 }
});
Deno.test("a failed or malformed report fails closed as 503 upstream",async()=>{
 const replies:(()=>Promise<{data:unknown;error:{message?:string}|null}>)[]=[
  async()=>({data:null,error:{message:"permission denied for function photo_feedback_report"}}),
  async()=>{throw new Error("socket closed");},
  async()=>({data:null,error:null}),async()=>({data:[],error:null}),
  async()=>({data:report({by_edit:{}}),error:null}),async()=>({data:(({cost:_c,...rest})=>rest)(report()),error:null}),async()=>({data:report({basis:null}),error:null}),
 ];
 for(const reply of replies){
  const error=await assertRejects(()=>closed(()=>handlePhotoFeedback(get(),reply,()=>NOW)),HttpError);
  assertEquals(error.status,503);assertEquals(error.code,"upstream");assert(!error.message.includes("permission denied"));
 }
});

// The actual dispatcher from admin/index.ts with every collaborator stubbed.
async function dispatcher(removeGate=false){
 let source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 const start=source.indexOf("Deno.serve(async (req) => {"),end=source.indexOf("\n});\n",start);
 assert(start>0&&end>start,"Extract the actual admin dispatcher");
 let body=source.slice(start+"Deno.serve(".length,end+2);
 if(removeGate){const anchor="    const admin = await requireAdmin(req);";assertEquals(body.split(anchor).length-1,1);body=body.replace(anchor,"    const admin = {userId:\"ungated\"};");}
 const names=["handleSpend","handleProbe","handleProviders","handleUsage","handleSubscriptions","handleHealth","handleFunnel","handleCohorts","handleChurn","handleRoutingWrite","handleRouting"];
 const url=(p:string)=>JSON.stringify(new URL(p,import.meta.url).href);
 const module=await import("data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(`// @ts-nocheck
  import {HttpError,json,pathSegments,respondError} from ${url("../_shared/http.ts")};
  import {handleOptions} from ${url("../_shared/cors.ts")};
  export const state={user:"admin",allow:true,calls:[],limits:[]};
  const ADMIN_MAX_PER_WINDOW=60,ADMIN_WINDOW_SECONDS=60;
  async function requireAdmin(){if(state.user===null)throw new HttpError(401,"Missing Authorization bearer token");if(state.user!=="admin")throw new HttpError(403,"Admin access is required for this console.","forbidden");return{userId:"admin-1"};}
  async function durableRateLimit(key,max,window){state.limits.push([key,max,window]);return state.allow;}
  ${names.map(n=>`const ${n}=async()=>{state.calls.push(${JSON.stringify(n)});return json({other:true});};`).join("\n")}
  const handlePhotoFeedback=async(req)=>{state.calls.push("handlePhotoFeedback:"+new URL(req.url).search);return json({report:true});};
  export const serve=${body};
 `))));
 return module as {state:{user:string|null;allow:boolean;calls:string[];limits:unknown[]};serve:(req:Request)=>Promise<Response>};
}
Deno.test("the actual admin dispatcher gates /admin/photo-feedback like every other admin route",async()=>{
 const m=await dispatcher();
 m.state.user=null;assertEquals((await m.serve(get("?window=7d"))).status,401);
 m.state.user="tenant";assertEquals((await m.serve(get("?window=7d"))).status,403);
 m.state.user="admin";assertEquals((await m.serve(new Request("https://fixture.invalid/functions/v1/admin/photo-feedback",{method:"POST",body:"{}"}))).status,405);
 m.state.allow=false;assertEquals((await m.serve(get("?window=7d"))).status,429);
 assertEquals(m.state.calls,[],"No refused request reached the report");
 m.state.allow=true;const ok=await m.serve(get("?window=7d"));assertEquals(ok.status,200);assertEquals(await ok.json(),{report:true});
 assertEquals(m.state.calls,["handlePhotoFeedback:?window=7d"]);
 assertEquals(m.state.limits.at(-1),["admin:admin-1",60,60]);
});
Deno.test("compiled removal of the admin gate fails the unchanged unauthenticated oracle",async()=>{
 const m=await dispatcher(true);m.state.user=null;
 const response=await m.serve(get("?window=7d"));
 assertEquals(response.status,200,"Without requireAdmin an anonymous caller reaches the report");
 assertEquals(m.state.calls,["handlePhotoFeedback:?window=7d"]);
});
