// Actual notify dispatcher; all Auth, PostgREST and provider traffic is synthetic.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
const USER="de550103-0000-4000-8000-000000000001",ORG="de550103-0000-4000-8000-000000000002",VERIFY="de550103-0000-4000-8000-000000000003";
const SERVICE="sb_secret_"+"notify_fixture_only_".repeat(2);
const env={SUPABASE_URL:"https://notify-privacy-fixture.invalid",SUPABASE_ANON_KEY:"fixture-public",SUPABASE_SERVICE_ROLE_KEY:"fixture-service",SUPABASE_SECRET_KEYS:JSON.stringify({default:SERVICE}),RENDPROP_SECRET_KEY_NAME:"default",RENDPROP_LEGACY_SERVICE_AUTH:"disabled"};
const previous=new Map(Object.keys(env).map(key=>[key,Deno.env.get(key)]));
for(const[key,value]of Object.entries(env))Deno.env.set(key,value);
let handler!:(req:Request)=>Promise<Response>;
const serve=Object.getOwnPropertyDescriptor(Deno,"serve")!;
Object.defineProperty(Deno,"serve",{configurable:serve.configurable,enumerable:serve.enumerable,writable:true,value:(fn:typeof handler)=>{handler=fn;return{};}});
try{await import("./index.ts?privacy-handler-proof");}finally{Object.defineProperty(Deno,"serve",serve);for(const[key,value]of previous)if(value===undefined)Deno.env.delete(key);else Deno.env.set(key,value);}
if(!handler)throw new Error("Actual notify handler not captured");
const row=(category="lead_received")=>({id:"fixture-outbox-"+category,org_id:ORG,user_id:USER as string|null,to_email:"editable-profile@fixture.invalid",category,channel:"email",dedupe_key:"fixture-"+category,payload:{data:{lead_name:"Synthetic buyer",listing_address:"Synthetic property"}},attempts:1});
async function invoke(rows:Array<ReturnType<typeof row> & {client_verification_id?:string}>,options:{lookupError?:boolean,verificationError?:boolean,authenticated?:boolean,serviceHeaders?:Record<string,string>}={}){
 const oldFetch=globalThis.fetch,keys=["SUPABASE_SERVICE_ROLE_KEY","RESEND_API_KEY","NOTIFY_FROM_EMAIL","APNS_KEY_P8","APNS_KEY_ID","APNS_TEAM_ID"];
 const saved=new Map(keys.map(key=>[key,Deno.env.get(key)]));
 Deno.env.set("SUPABASE_SERVICE_ROLE_KEY","fixture-service");Deno.env.set("RESEND_API_KEY","fixture-only");Deno.env.set("NOTIFY_FROM_EMAIL","Rendprop <notify@fixture.invalid>");for(const key of keys.slice(3))Deno.env.delete(key);
 const calls:Array<{url:string,method:string,body:Record<string,unknown>}> = [],marked:Array<Record<string,unknown>>=[];
 globalThis.fetch=async(input,init)=>{
  const req=new Request(input,init),url=new URL(req.url),body=req.method==="POST"?await req.json():{};calls.push({url:req.url,method:req.method,body});
  if(url.hostname==="api.resend.com"){assertEquals(req.redirect,"error");assert(req.signal);return Response.json({id:"fixture-provider"});}
  if(url.hostname!=="notify-privacy-fixture.invalid")throw new Error("Unmodeled external network dispatch");
  if(url.pathname==="/rest/v1/rpc/notification_claim_batch")return Response.json(rows);
  if(url.pathname==="/rest/v1/rpc/notification_verified_recipients")return options.lookupError?Response.json({message:"private SQL unavailable"},{status:503}):Response.json([{id:USER,email:"confirmed-auth@fixture.invalid"}]);
  if(url.pathname==="/rest/v1/rpc/client_recipient_verification_prepare")return options.verificationError?Response.json({to:"other@fixture.invalid"}):Response.json({to:"client@fixture.invalid",from:"Rendprop <notify@fixture.invalid>",subject:"Confirm your listing inquiry email",text:"Confirm only if expected. https://rendprop.com/verify-client-email#token="+"a".repeat(64),idempotency_key:"client-verification/"+VERIFY});
  if(url.pathname==="/rest/v1/rpc/notification_mark"){marked.push(body);return Response.json({ok:true});}
  throw new Error("Unmodeled database request: "+url.pathname);
 };
 // Modern service authentication is the exact configured apikey, never a JWT role claim.
 try{const response=await handler(new Request("https://edge.invalid/notify",{method:"POST",headers:options.serviceHeaders??(options.authenticated===false?{authorization:"Bearer fixture-user"}:{apikey:SERVICE})}));return {status:response.status,body:await response.json(),calls,marked};}
 finally{globalThis.fetch=oldFetch;for(const[key,value]of saved)if(value===undefined)Deno.env.delete(key);else Deno.env.set(key,value);}
}
Deno.test("actual drain ignores editable destination and sends private email to verified Auth",async()=>{
 const out=await invoke([row()]);assertEquals(out.status,200);assertEquals(out.body.sent,1);
 const mail=out.calls.find(c=>new URL(c.url).hostname==="api.resend.com")!.body;
 assertEquals(mail.to,["confirmed-auth@fixture.invalid"]);assertEquals(mail.reply_to,"aaron@pilk.ai");assert(String(mail.text).endsWith("RendProp LLC\n855 Central Avenue\nSaint Petersburg, FL 33701\nQuestions or email preferences: aaron@pilk.ai"));
 assert(!out.calls.some(c=>new URL(c.url).pathname==="/rest/v1/profiles"));
});
Deno.test("actual drain retries private recipient outage without delivering to typed contact",async()=>{
 const out=await invoke([row()],{lookupError:true});assertEquals(out.body.failed,1);assertEquals(out.body.sent,0);assert(!out.calls.some(c=>new URL(c.url).hostname==="api.resend.com"));assertEquals(out.marked[0].p_state,"failed");
});
Deno.test("actual drain disables promotional email even when already claimed and preferences default on",async()=>{
 const out=await invoke([row("first_tour_nudge"),row("free_week_ending")]);assertEquals(out.body.skipped,2);assertEquals(out.body.sent,0);assert(!out.calls.some(c=>new URL(c.url).hostname==="api.resend.com"));assert(out.marked.every(c=>c.p_state==="skipped"));
});
Deno.test("recipient verification has its own frozen destination and no buyer snapshot",async()=>{
 const verification={...row("client_recipient_verification"),user_id:null,to_email:"client@fixture.invalid",client_verification_id:VERIFY};
 const out=await invoke([row(),verification],{lookupError:true});assertEquals(out.body.sent,1);assertEquals(out.body.failed,1);
 const mail=out.calls.filter(c=>new URL(c.url).hostname==="api.resend.com");assertEquals(mail.length,1);assertEquals(mail[0].body.to,["client@fixture.invalid"]);assert(!String(mail[0].body.text).includes("Synthetic buyer"));assert(!String(mail[0].body.text).includes("Synthetic property"));
});
Deno.test("malformed recipient authority cannot dispatch and non-service callers cannot claim",async()=>{
 const verification={...row("client_recipient_verification"),user_id:null,to_email:"client@fixture.invalid",client_verification_id:VERIFY};
 const out=await invoke([verification],{verificationError:true});assertEquals(out.body.failed,1);assert(!out.calls.some(c=>new URL(c.url).hostname==="api.resend.com"));
 const denied=await invoke([row()],{authenticated:false});assertEquals(denied.status,403);assertEquals(denied.calls,[]);
});
Deno.test("actual drain refuses forged service claims, wrong apikey and bearer-only modern key before dispatch",async()=>{
 const forged="eyJhbGciOiJIUzI1NiJ9."+btoa(JSON.stringify({role:"service_role"}))+".synthetic-unsigned";
 const refused:Record<string,string>[]=[{authorization:"Bearer "+forged},{apikey:SERVICE+"x",authorization:"Bearer "+forged},{authorization:"Bearer "+SERVICE}];
 for(const headers of refused){
  const out=await invoke([row()],{serviceHeaders:headers});assertEquals(out.status,403);assertEquals(out.calls,[]);assertEquals(out.marked,[]);
 }
});
