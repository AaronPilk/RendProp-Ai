// The production wiring (index.ts) through the real Supabase client, the real
// limiter and the shared preferredOrg(), against a closed transport that
// answers only the exact Auth/RPC paths. Its own file (its own isolate): the
// shared client reads its environment when first imported, so nothing here
// imports it statically before the fixture environment is set.
import {assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";

const id=(n:number)=>`f8500000-0000-4000-8000-${String(n).padStart(12,"0")}`;
const actor=id(1),org=id(2),prov=id(3),feedbackId=id(4);
const body={output:{provenance_id:prov,output_sha256:"b".repeat(64)},client_key:"studio:k-0001",revision:1,verdict:"needs_work",reasons:["blocked_doorway_or_opening"],note:"Door covered",platform:"studio"};
const post=(headers:Record<string,string>)=>new Request("https://db.fixture.invalid/functions/v1/photo-feedback",
 {method:"POST",headers:{authorization:"Bearer fixture","content-type":"application/json",...headers},body:JSON.stringify(body)});

Deno.test("production wiring authenticates, reads X-Org-Id with preferredOrg, rate-limits and calls only the feedback RPC with the service key",async()=>{
 const serviceKey="sb_secret_"+"f".repeat(24);
 const env={SUPABASE_URL:"https://feedback-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture",SUPABASE_SECRET_KEYS:JSON.stringify({default:serviceKey}),RENDPROP_SECRET_KEY_NAME:"default"};
 const previous=Object.fromEntries(Object.keys(env).map(k=>[k,Deno.env.get(k)]));for(const [k,v] of Object.entries(env))Deno.env.set(k,v);
 const seen:string[]=[];let rpcBody:Record<string,unknown>|null=null;
 const priorFetch=globalThis.fetch;
 globalThis.fetch=(async(raw:Request|URL|string,init?:RequestInit)=>{
  const req=new Request(raw,init),url=new URL(req.url);seen.push(req.method+" "+url.pathname);
  if(url.hostname!=="feedback-db.fixture.invalid")throw new Error("Unexpected network host "+url.hostname);
  if(url.pathname==="/auth/v1/user")return Response.json({id:actor,is_anonymous:false,aud:"authenticated"});
  assertEquals(req.headers.get("apikey"),serviceKey);
  if(url.pathname==="/rest/v1/rpc/bump_rate")return Response.json(true);
  if(url.pathname==="/rest/v1/rpc/photo_feedback_submit"){
   rpcBody=await req.json();
   return Response.json({state:"recorded",feedback_id:feedbackId,provenance_id:rpcBody!.p_provenance,revision:rpcBody!.p_revision,revision_count:1,verdict:rpcBody!.p_verdict,
    reasons:rpcBody!.p_reasons,note:rpcBody!.p_note,updated_at:"2026-10-17T20:00:00Z",attribution:{basis:"evidence"}});
  }
  throw new Error("Unexpected path "+url.pathname);
 }) as typeof fetch;
 try{
  const {handler}=await import("./index.ts");
  const response=await handler(post({"x-org-id":org.toUpperCase()}));
  assertEquals(response.status,200,await response.clone().text());assertEquals((await response.json()).state,"recorded");
  assertEquals(rpcBody,{p_actor:actor,p_selected:org,p_provenance:prov,p_output_sha256:"b".repeat(64),p_client_key:"studio:k-0001",p_revision:1,p_verdict:"needs_work",p_reasons:["blocked_doorway_or_opening"],p_note:"Door covered",p_platform:"studio"});
  assertEquals(seen,["GET /auth/v1/user","POST /rest/v1/rpc/bump_rate","POST /rest/v1/rpc/photo_feedback_submit"]);
  // No other header selects a library: refused after Auth, before the limiter or any RPC.
  seen.length=0;
  const other=await handler(post({"x-rendprop-org":org}));
  assertEquals([other.status,(await other.json()).code],[400,"invalid_request"]);
  assertEquals(seen,["GET /auth/v1/user"]);
 }finally{
  globalThis.fetch=priorFetch;for(const [k,v] of Object.entries(previous))if(v===undefined)Deno.env.delete(k);else Deno.env.set(k,v);
 }
});
