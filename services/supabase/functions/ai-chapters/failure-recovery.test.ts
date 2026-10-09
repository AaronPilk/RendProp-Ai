// Execute the production request handler and quota guards. Auth, storage,
// provider transport and Postgres are synthetic; no live generation is made.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";

const encode = (text: string) => "data:application/typescript;base64," + btoa(String.fromCharCode(...new TextEncoder().encode(text)));
const functionBody = (source: string, name: string) => {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf("\n}\n", start);
  assert(start >= 0 && end > start);
  return source.slice(start, end + 3);
};
type Failure = "none" | "monthly" | "route" | "sign" | "upload" | "generate";
async function fixture(failure: Failure, removeAbort = false) {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const start = source.indexOf("Deno.serve(async (req) => {"), end = source.indexOf("\n});", start);
  assert(start > 0 && end > start);
  let handler = source.slice(start, end + 4).replace("Deno.serve(async (req) => {", "export const handler = async (req:Request) => {").replace(/\}\);$/, "};");
  if (removeAbort) handler = handler.replace("await abortFundingOperationBeforeDispatch(funding);\n      throw e;", "throw e;");
  const module = `
    import {HttpError,assert,json,respondError,readJson} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    import {fundingContext,fundedAttempt,completeFundingOperation,abortFundingOperationBeforeDispatch,FundingAdmissionError,videoInputTokenBound} from ${JSON.stringify(new URL("../_shared/funded-serving.ts", import.meta.url).href)};
    import {requiredIdempotencyKey} from ${JSON.stringify(new URL("../_shared/idempotency.ts", import.meta.url).href)};
    type ChaptersBody=any;type Charge=any;type RateChargeReceipt=any;type ChosenRoute=any;type RouteStep=any;
    const failure=${JSON.stringify(failure)};
    export const state={charges:[] as string[],refunds:[] as string[],uploads:0,generations:0,deletions:0,attempts:0,abortCalls:0,closed:false,liability:false,saved:false,ledger:null as any};
    const BURST_MAX_PER_WINDOW=10,BURST_WINDOW_SECONDS=300,MONTH_SECONDS=2592000,DEFAULT_MAX_CHAPTERS=12,HARD_MAX_CHAPTERS=24,SOURCE_URL_TTL_SECONDS=900,MAX_VIDEO_BYTES=300000000,GEMINI_DEADLINE_MS=110000,SAMPLE_FPS=1;
    const LEGACY_ROUTE={provider:'gemini',model:'synthetic-model',unit:'call',unitCents:1,routeId:null};
    const handleOptions=()=>new Response(null,{status:204}),pathSegments=()=>[],requireGemini=()=>{},getUser=async()=>({id:'synthetic-user'}),userClient=()=>({}),preferredOrg=()=>null,orgForUser=async()=> 'synthetic-org';
    const requiredUuid=(value:any)=>value, cleanLanguage=()=> 'en';
    const resolveVideoAsset=async()=>({id:'synthetic-asset',orgId:'synthetic-org',bucket:'uploads',storageKey:'synthetic.mp4',spaceType:'real_estate',durationS:90,contentType:'video/mp4'});
    const rpc=async(name:string,_args:any)=>{
      if(name==='serving_operation_begin')return {data:{begun:true},error:null};
      if(name==='serving_cost_reserve'){state.attempts++;state.liability=true;return {data:{reserved:true},error:null};}
      if(name==='serving_cost_finish')return {data:{finished:true},error:null};
      if(name==='serving_operation_no_dispatch'){state.abortCalls++;if(state.attempts===0)state.closed=true;return {data:{closed:state.closed},error:null};}
      if(name==='serving_operation_complete'){state.saved=true;return {data:{saved:true},error:null};}
      throw new Error('Unmodeled RPC '+name);
    };
    const adminClient=()=>({rpc,from:()=>{const q:any={select:()=>q,eq:()=>q,maybeSingle:async()=>({data:{role:'owner'},error:null})};return q;}});
    const assertPaidAiIdentity=async()=>{}, entitlementForCharge=async()=>({renders_per_month:10,plan:'starter'}), quotaError=()=>new HttpError(402,'quota');
    const chargeRateReceipt=async(key:string,_max:number,windowSeconds:number)=>{
      if(failure==='monthly'&&key.startsWith('chaptersmo:'))throw new HttpError(503,'Meter unavailable','upstream');
      state.charges.push(key);return {accepted:true,receipt:{key,windowSeconds,windowStart:'2026-10-07T00:00:00Z'}};
    };
    const refundRateReceipt=async(receipt:any)=>{state.refunds.push(receipt.key);return true;};
    const spaceTypeOf=()=> 'real_estate',allowedLabels=()=>['Kitchen'];
    const chooseChain=async()=>{if(failure==='route')throw new HttpError(503,'Route unavailable','upstream');return {router:null,chain:[LEGACY_ROUTE]};};
    const presignGet=async()=>{if(failure==='sign')throw new HttpError(500,'Signer unavailable','internal');return 'https://media.fixture.invalid/clip.mp4';};
    const chaptersPrompt=()=> 'synthetic prompt',systemInstruction=()=> 'synthetic system';
    const uploadVideoFromUrl=async()=>{state.uploads++;if(failure==='upload')throw new HttpError(502,'Upload unavailable','upstream');return {name:'files/synthetic',uri:'https://files.fixture.invalid/synthetic',mimeType:'video/mp4'};};
    const waitForActive=async()=>{},deleteFile=async()=>{state.deletions++;};
    const textAttemptQuote=()=>({cents:1,version:'synthetic-tariff'});
    const generateChapters=async()=>{state.generations++;if(failure==='generate')throw new HttpError(502,'Generation unavailable','upstream');return {text:'{}',promptTokens:1,outputTokens:1,finishReason:'STOP'};};
    const reportOutcome=async()=>{},postprocessChapters=()=>({chapters:[],warnings:[] as string[]}),ledgerUnits=()=>90,recordAppAiCost=async(args:any,receipt:any)=>{state.ledger=receipt;return {total_cents:1};},recordProvenance=async()=>({id:'synthetic',recorded:true,disclosure:'Synthetic'});
    async ${functionBody(source, "guardChapters")}
    async ${functionBody(source, "refundCharge")}
    ${functionBody(source, "errorClassOf")}
    ${handler}
  `;
  return await import(encode(module));
}
const request = () => new Request("https://fixture.invalid/ai-chapters", {
  method:"POST",headers:{"content-type":"application/json","idempotency-key":crypto.randomUUID()},
  body:JSON.stringify({listing_id:"synthetic-listing",asset_id:"synthetic-asset"}),
});
for (const failure of ["route", "sign", "upload"] as const) {
  Deno.test(`actual chapter ${failure} failure returns exact quota and closes only unused operation`, async()=>{
    const f=await fixture(failure),response=await f.handler(request());
    assert(response.status>=500);
    assertEquals(f.state.refunds,["chaptersmo:synthetic-org","aichapters:synthetic-org"]);
    assertEquals(f.state.generations,0);assertEquals(f.state.attempts,0);
    assertEquals(f.state.abortCalls,1);assertEquals(f.state.closed,true);assertEquals(f.state.liability,false);
  });
}
Deno.test("actual chapter monthly meter outage returns its already charged burst receipt",async()=>{
  const f=await fixture("monthly"),response=await f.handler(request());
  assertEquals(response.status,503);assertEquals(f.state.charges,["aichapters:synthetic-org"]);
  assertEquals(f.state.refunds,["aichapters:synthetic-org"]);assertEquals(f.state.closed,true);
  assertEquals(f.state.uploads,0);assertEquals(f.state.generations,0);
});
Deno.test("actual failed chapter generation refunds feature quota while retaining provider liability",async()=>{
  const f=await fixture("generate"),response=await f.handler(request());
  assertEquals(response.status,502);assertEquals(f.state.refunds.length,2);
  assertEquals(f.state.generations,1);assertEquals(f.state.attempts,1);
  assertEquals(f.state.liability,true);assertEquals(f.state.closed,false);assertEquals(f.state.deletions,1);
});
Deno.test("actual chapter success saves result and deletes uploaded provider file without refund",async()=>{
  const f=await fixture("none"),response=await f.handler(request());
  assertEquals(response.status,200);assertEquals(f.state.refunds,[]);assertEquals(f.state.abortCalls,0);
  assertEquals(f.state.generations,1);assertEquals(f.state.saved,true);assertEquals(f.state.deletions,1);
  assertEquals(f.state.ledger.meta.stage,"chapters:0");
  assertEquals(typeof f.state.ledger.meta.request_key,"string");
});
Deno.test("compiled removed predispatch closure fails the same chapter recovery boundary",async()=>{
  const f=await fixture("sign",true),response=await f.handler(request());assert(response.status>=500);
  await assertRejects(()=>Promise.resolve().then(()=>assertEquals(f.state.closed,true)));
});
