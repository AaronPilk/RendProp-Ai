import {assert,assertEquals,assertThrows,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {assertExpectedSubscriptionWorkspace,assertVerifiedPurchaseOwner} from "./billing.ts";
import type {SupabaseClient} from "npm:@supabase/supabase-js@2.116.0";
import {HttpError} from "../_shared/http.ts";
const USER="d0100103-0000-4000-8000-000000000001", ORG="d0100103-0000-4000-8000-000000000002", OTHER="d0100103-0000-4000-8000-000000000003";
type Handler=(req:Request)=>Promise<Response>;
let handler:Handler;
type Options={role?:string;plan?:string;rawPlan?:string;source?:string|null;anonymous?:boolean;degraded?:boolean;membershipError?:boolean;selector?:string;subscriptionError?:boolean;testingContext?:unknown;testingError?:boolean;projection?:boolean;master?:boolean;trialUsage?:unknown;trialError?:boolean;servingUnavailable?:boolean;heldPurchase?:unknown;prepareBody?:unknown;photoPackage?:unknown;photoPackageError?:boolean;servingMode?:string;servingEnvelope?:unknown};
async function invoke(o:Options={}) {
 const values={SUPABASE_URL:"https://billing-fixture.invalid",SUPABASE_SERVICE_ROLE_KEY:"fixture-service",SUPABASE_ANON_KEY:"fixture-anon"};
 const previous=new Map(Object.keys(values).map(key=>[key,Deno.env.get(key)]));for(const [key,value]of Object.entries(values))Deno.env.set(key,value);
 const oldFetch=globalThis.fetch,serve=Object.getOwnPropertyDescriptor(Deno,"serve")!;
 const unexpected:string[]=[],queries:URL[]=[];
 const json=(v:unknown,status=200)=>new Response(JSON.stringify(v),{status,headers:{"content-type":"application/json"}});
 try {
  globalThis.fetch=async(input,init)=>{
   const req=new Request(input,init),url=new URL(req.url);queries.push(url);
   if(url.hostname!=="billing-fixture.invalid"){unexpected.push(req.url);throw new Error("Unmodeled network refused");}
   const table=url.pathname.split("/").pop();
   const row=(v:unknown)=>json(req.headers.get("accept")?.includes("vnd.pgrst.object")?v:[v]);
   if(url.pathname==="/auth/v1/user")return json({id:USER,aud:"authenticated",is_anonymous:o.anonymous??false});
   if(table==="active_org_for_user")return json(ORG);
   if(table==="workspace_directory")return json({active_org_id:o.selector??ORG,workspaces:[{id:o.selector??ORG,name:"Fixture Workspace",role:o.role??"owner"}]});
   if(table==="org_entitlement")return json(o.degraded?null:{plan:o.plan??"free",renders_per_month:o.projection?2147483647:1,photo_edits_per_month:o.projection?2147483647:0,reels_per_month:o.projection?2147483647:0,aerials_per_month:o.projection?2147483647:0,topaz_per_month:o.projection?2147483647:0,seats:1,cogs_ceiling_cents:o.projection?2147483647:250,price_cents:0});
   if(table==="org_has_internal_testing_grant")return json(o.master??false);
   if(table==="hosting_retention_state") {
    assertEquals(await req.json(),{p_org:o.selector??ORG});
    return json({org_id:o.selector??ORG,policy:"preserved",protected:Boolean(o.master||o.testingContext),retention_ends_at:null,hosting_available:true});
   }
   if(table==="private_internal_testing_context") {
    assertEquals(await req.json(),{p_user:USER,p_private_org:o.selector??ORG});
    return o.testingError?json({message:"fixture failed"},503):json(o.testingContext??null);
   }
   if(table==="notification_preferences_for")return json({});
   if(table==="subscription_trial_held_offer")return json(o.heldPurchase??null);
   if(table==="prepare_subscription_trial_purchase"){assertEquals(await req.json(),{p_actor:USER,p_org:o.selector??ORG,p_product:"com.rendprop.app.starter.monthly"});return json(o.heldPurchase??null);}
   if(table==="subscription_trial_context") {
    assertEquals(await req.json(),{p_actor:USER,p_org:o.selector??ORG});
    return o.trialError?json({message:"fixture unavailable"},503):json({trial_usage:o.trialUsage??null,trial_offer:null});
   }
   if(table==="subscription_serving_activation") {
    assertEquals(await req.json(),{p_actor:USER,p_org:o.selector??ORG});
    return json({org_id:o.selector??ORG,available:!o.servingUnavailable,funded:!o.servingUnavailable,authority:o.servingUnavailable?"subscription_activation_unavailable":"verified_retail"});
   }
   if(table==="serving_mode") return json(o.servingMode??"ceiling");
   if(table==="serving_envelope_state") {
    assertEquals(await req.json(),{p_org:o.selector??ORG});
    return json(o.servingEnvelope??{kind:"free",plan:"free",ceiling_cents:300,spent_cents:12.5,held_cents:0,available_cents:287.5,period_start:null,period_end:null,window:"lifetime",pool:null});
   }
   if(table==="serving_photo_package_context") {
    assertEquals(req.method,"POST");
    assertEquals(await req.json(),{p_actor:USER,p_org:o.selector??ORG});
    return o.photoPackageError?json({message:"fixture unavailable"},503):json(o.photoPackage??null);
   }
   if(table==="memberships") {
    if(url.searchParams.get("select")==="org_id")return row({org_id:OTHER});
    return o.membershipError?json({message:"fixture denied"},400):row({role:o.role??"owner"});
   }
   if(table==="orgs")return row({id:o.selector??ORG,name:"Fixture Workspace",plan:o.rawPlan??o.plan??"free",plan_source:o.source??null});
   if(table==="apple_subscriptions")return o.subscriptionError?json({message:"fixture unavailable"},400):json([{original_transaction_id:"fixture-original-transaction"}]);
   if(table==="profiles")return row({id:USER,name:"Fixture Person"});
   if(req.method==="HEAD")return new Response(null,{headers:{"content-range":"*/0"}});
   if(["cost_ledger","rate_limits"].includes(table??""))return json([]);
   unexpected.push(url.pathname);throw new Error("Unmodeled request");
  };
  Object.defineProperty(Deno,"serve",{configurable:true,writable:true,value:(fn:Handler)=>{handler=fn;return {};}});
  (await import("../_shared/funded-serving.ts")).resetServingModeCache();
  await import("./index.ts");assert(handler);
  const response=await handler(new Request(o.prepareBody?"https://edge.invalid/me/trial/prepare":"https://edge.invalid/me",{...(o.prepareBody?{method:"POST",body:JSON.stringify(o.prepareBody)}:{}),headers:{authorization:"Bearer fixture-token",...(o.selector?{"x-org-id":o.selector}:{})}}));
  const body=await response.json();assertEquals(unexpected,[]);return {response,body,queries};
 }finally{globalThis.fetch=oldFetch;Object.defineProperty(Deno,"serve",serve);for(const[key,value]of previous)value===undefined?Deno.env.delete(key):Deno.env.set(key,value);}
}
Deno.test("/me reports the serving mode the paywall keys on (ceiling → ordinary StoreKit purchase)",async()=>{
 const ceiling=await invoke({});assertEquals(ceiling.response.status,200);assertEquals(ceiling.body.serving_mode,"ceiling");
 assertEquals(ceiling.body.serving_envelope,{kind:"free",ceiling_cents:300,spent_cents:12.5,held_cents:0,available_cents:287.5,period_start:null,period_end:null,window:"lifetime",pool:null});
 const trial=await invoke({servingEnvelope:{kind:"trial",plan:"trial",ceiling_cents:500,spent_cents:"60.5",held_cents:4,available_cents:435.5,period_start:"2026-10-08T00:00:00+00:00",period_end:"2026-10-15T00:00:00+00:00",window:"trial_window",pool:{cap_cents:29000,starts_at:"2026-10-08T00:00:00+00:00",ends_at:"2026-11-08T00:00:00+00:00",spent_cents:460}}});
 assertEquals(trial.body.serving_envelope,{kind:"trial",ceiling_cents:500,spent_cents:60.5,held_cents:4,available_cents:435.5,period_start:"2026-10-08T00:00:00+00:00",period_end:"2026-10-15T00:00:00+00:00",window:"trial_window",pool:{cap_cents:29000,spent_cents:460,ends_at:"2026-11-08T00:00:00+00:00"}});
 const funded=await invoke({servingMode:"funded"});assertEquals(funded.body.serving_mode,"funded");assertEquals(funded.body.serving_envelope,null);
});
Deno.test("billing context belongs to the same selected workspace as entitlement",async()=>{
 const r=await invoke({selector:OTHER});assertEquals(r.response.status,200);assertEquals(r.body.org.id,OTHER);assertEquals(r.body.billing,{org_id:OTHER,org_name:"Fixture Workspace",role:"owner",can_manage_subscription:true,original_transaction_ids:[],source:null});
 assert(r.queries.filter(u=>u.pathname.endsWith("memberships")).every(u=>u.searchParams.get("org_id")==="eq."+OTHER));
});
Deno.test("guest owner may explicitly subscribe; membership does not require a named identity",async()=>{const r=await invoke({anonymous:true});assertEquals(r.response.status,200);assertEquals(r.body.billing.can_manage_subscription,true);});
Deno.test("actual me returns only the selected workspace's verified photo allowance",async()=>{
 const p={org_id:OTHER,policy:"one-gemini-1k-4096-plus-one-kontext-20261007",tariff_version:"published-standard-20261006",starts_at:new Date(Date.now()-1000).toISOString(),ends_at:new Date(Date.now()+86400000).toISOString(),photo_admissions:{cap:20,used:3,remaining:17},photo_hold_cents:35.1296,protected_photo_cents:703,other_ai:{cap_cents:240,used_cents:1,remaining_cents:239}};
 const r=await invoke({selector:OTHER,photoPackage:{...p,funding_id:"not-public",actor_id:"not-public"}});assertEquals(r.response.status,200);assertEquals(r.body.serving_photo_package,p);
 const legacy=await invoke();assertEquals(legacy.response.status,200);assertEquals(legacy.body.serving_photo_package,null);
 for(const photoPackage of [{...p,org_id:ORG},{...p,photo_admissions:{...p.photo_admissions,remaining:18}},{...p,protected_photo_cents:702}]){const bad=await invoke({selector:OTHER,photoPackage});assertEquals(bad.response.status,503);assert(!bad.body.serving_photo_package);}
 const unavailable=await invoke({photoPackageError:true});assertEquals(unavailable.response.status,503);
});
Deno.test("actual me returns scoped bounded trial usage without advertising a dormant offer",async()=>{
 const usage={org_id:OTHER,status:"active",starts_at:new Date(Date.now()-1000).toISOString(),ends_at:new Date(Date.now()+86400000).toISOString(),walkthroughs:{used:0,cap:1,remaining:1},photo_edits:{used:1,cap:5,remaining:4},published_listings:{used:0,cap:1,remaining:1},upload_budget_bytes:1073741824,upload_used_bytes:20};
 const r=await invoke({selector:OTHER,plan:"starter",source:"apple",trialUsage:usage});assertEquals(r.response.status,200);assertEquals(r.body.trial_usage,usage);assertEquals(r.body.trial_offer,null);
 const paid=await invoke({plan:"starter",source:"apple"});assertEquals(paid.body.trial_usage,null);assertEquals(paid.body.usage.caps.photo_edits,0);
 const wrong=await invoke({selector:OTHER,trialUsage:{...usage,org_id:ORG}});assertEquals(wrong.response.status,503);assert(!wrong.body.trial_usage);
 const unavailable=await invoke({trialError:true});assertEquals(unavailable.response.status,503);
 const unfunded=await invoke({plan:"starter",source:"apple",servingUnavailable:true});
 assertEquals(unfunded.response.status,200);assertEquals(unfunded.body.plan,"starter");assertEquals(unfunded.body.plan_raw,"starter");assertEquals(unfunded.body.entitlement.degraded,true);
 assertEquals(unfunded.body.usage.caps,{renders:0,photo_edits:0,reels:0,aerials:0,drone:0});assertEquals(unfunded.body.serving_activation.available,false);assertEquals(unfunded.body.billing.can_manage_subscription,true);
});
for(const role of ["agent","marketing"])Deno.test(`billing refuses shared-workspace subscription for ${role}`,async()=>{const r=await invoke({role});assertEquals(r.response.status,200);assertEquals(r.body.billing.can_manage_subscription,false);});
Deno.test("admin may manage ordinary subscription",async()=>{const r=await invoke({role:"admin",plan:"pro",source:"apple"});assertEquals(r.body.billing.can_manage_subscription,true);});
Deno.test("contract, manual and degraded entitlement contexts do not invite a new Apple purchase",async()=>{for(const option of [{plan:"brokerage",source:"apple"},{plan:"pro",source:"manual"},{degraded:true}]){const r=await invoke(option);assertEquals(r.response.status,200);assertEquals(r.body.billing.can_manage_subscription,false);}});
Deno.test("billing permissions fail closed on membership lookup failure",async()=>{const r=await invoke({membershipError:true});assertEquals(r.response.status,503);assert(!("billing"in r.body));});
Deno.test("workspace-bound receipt refuses active-org changes before entitlement binding",()=>{
 assertExpectedSubscriptionWorkspace(ORG,ORG);assertExpectedSubscriptionWorkspace(ORG.toUpperCase(),ORG);assertExpectedSubscriptionWorkspace(undefined,ORG);
 const moved=assertThrows(()=>assertExpectedSubscriptionWorkspace(ORG,OTHER),HttpError);assertEquals(moved.status,409);
 for(const invalid of [null,"",42,"not-an-org"]){const error=assertThrows(()=>assertExpectedSubscriptionWorkspace(invalid,ORG),HttpError);assertEquals(error.status,400);}
});

function adoptedReceiptFixture(patch:Record<string,unknown>={}) {
 const operation="d0100103-0000-4000-8000-000000000004";
 const row={operation_id:operation,source_user_id:OTHER,destination_user_id:USER,org_id:ORG};
 const receipt={...row,ok:true,adopted:true};
 const filters:Record<string,unknown>={};let calls=0;
 const query={select:()=>query,eq:(key:string,value:unknown)=>{filters[key]=value;return query;},maybeSingle:async()=>({data:row,error:null,...patch.rowResult as object})};
 const admin={from:(name:string)=>{assertEquals(name,"anonymous_adoption_receipts");calls++;return query;},rpc:async(name:string,args:Record<string,unknown>)=>{assertEquals(name,"adoption_receipt");assertEquals(args,{p_user:USER,p_anon_user:OTHER,p_operation:operation});calls++;return {data:receipt,error:null,...patch.receiptResult as object};}};
 return {admin:admin as unknown as SupabaseClient,row,receipt,filters,calls:()=>calls};
}
Deno.test("own and legacy token checks require no alias lookup",async()=>{
 const f=adoptedReceiptFixture();await assertVerifiedPurchaseOwner(USER.toUpperCase(),USER,ORG,f.admin);await assertVerifiedPurchaseOwner(null,USER,ORG,f.admin);assertEquals(f.calls(),0);
});
Deno.test("guest subscription survives sign-in only with the exact live adoption receipt",async()=>{
 const f=adoptedReceiptFixture();await assertVerifiedPurchaseOwner(OTHER.toUpperCase(),USER,ORG,f.admin);assertEquals(f.calls(),2);assertEquals(f.filters,{source_user_id:OTHER,destination_user_id:USER,org_id:ORG});
});
Deno.test("team membership without adoption proof cannot claim another account purchase",async()=>{
 const f=adoptedReceiptFixture({rowResult:{data:null}});const error=await assertRejects(()=>assertVerifiedPurchaseOwner(OTHER,USER,ORG,f.admin),HttpError);assertEquals(error.status,403);assertEquals(f.calls(),1);
});
Deno.test("purchase alias cannot cross destination, org, source or operation bindings",async()=>{
 for(const key of ["source_user_id","destination_user_id","org_id","operation_id"]){const f=adoptedReceiptFixture();(f.receipt as Record<string,unknown>)[key]="d0100103-0000-4000-8000-000000000099";const error=await assertRejects(()=>assertVerifiedPurchaseOwner(OTHER,USER,ORG,f.admin),HttpError);assertEquals(error.status,403);}
});
Deno.test("removed membership or deletion makes historical purchase alias unusable",async()=>{
 const f=adoptedReceiptFixture({receiptResult:{data:null,error:{message:"RP409: transferred workspace is no longer available to this account"}}});const error=await assertRejects(()=>assertVerifiedPurchaseOwner(OTHER,USER,ORG,f.admin),HttpError);assertEquals(error.status,403);
});
Deno.test("purchase alias lookup failures are recoverable and never grant access",async()=>{
 for(const patch of [{rowResult:{data:null,error:{message:"offline"}}},{receiptResult:{data:null,error:{message:"offline"}}}]){const f=adoptedReceiptFixture(patch);const error=await assertRejects(()=>assertVerifiedPurchaseOwner(OTHER,USER,ORG,f.admin),HttpError);assertEquals(error.status,503);}
});

Deno.test("billing discloses current workspace Apple bindings only to authorized purchasers",async()=>{
 const owner=await invoke({plan:"pro",source:"apple"});assertEquals(owner.body.billing.original_transaction_ids,["fixture-original-transaction"]);
 assert(owner.queries.filter(u=>u.pathname.endsWith("apple_subscriptions")).every(u=>u.searchParams.get("org_id")==="eq."+ORG));
 const member=await invoke({plan:"pro",source:"apple",role:"agent"});assertEquals(member.body.billing.original_transaction_ids,[]);assert(!member.queries.some(u=>u.pathname.endsWith("apple_subscriptions")));
 const failed=await invoke({plan:"pro",source:"apple",subscriptionError:true});assertEquals(failed.response.status,503);assert(!failed.body.billing);
});

const SPONSOR="d0100103-0000-4000-8000-000000000009";
const privateContext={active:true,sponsor_org_id:SPONSOR,sponsor_org_name:"Fixture testing team",private_org_id:ORG,beneficiary_user_id:USER,plan:"team",source:"manual",unmetered_business_allowances:true};
Deno.test("sponsored trial keeps its resource identity and raw source without a purchase prompt",async()=>{
 const r=await invoke({plan:"team",rawPlan:"trial",source:"trial",projection:true,testingContext:privateContext});
 assertEquals(r.response.status,200);assertEquals(r.body.org.id,ORG);assertEquals(r.body.org.name,"Fixture Workspace");
 assertEquals(r.body.plan_raw,"trial");assertEquals(r.body.plan_source_raw,"trial");assertEquals(r.body.plan_source,"manual");
 assertEquals(r.body.billing.can_manage_subscription,false);assertEquals(r.body.billing.org_id,ORG);assertEquals(r.body.billing.source,"manual");
 assertEquals(r.body.testing_access,{active:true,team_name:"Fixture testing team"});
 assert(!r.queries.some(u=>u.pathname.endsWith("apple_subscriptions")));
 assert(r.queries.every(u=>u.pathname.startsWith("/auth/")||!u.searchParams.get("org_id")||u.searchParams.get("org_id")==="eq."+ORG));
});
Deno.test("master manual Team keeps its own subscription context with a current grant",async()=>{
 const r=await invoke({plan:"team",source:"manual",projection:true,master:true});
 assertEquals(r.response.status,200);assertEquals(r.body.plan_source,"manual");assertEquals(r.body.billing.can_manage_subscription,false);assert(!r.body.testing_access);
});
Deno.test("revoked or racing sponsorship never publishes a stale unlimited billing receipt",async()=>{
 for(const o of [
  {plan:"team",rawPlan:"trial",source:"trial",projection:true},
  {plan:"team",source:"manual",projection:true},
  {plan:"team",rawPlan:"trial",source:"trial",testingContext:privateContext},
  {plan:"team",projection:true,testingError:true},
  {plan:"team",projection:true,testingContext:{...privateContext,beneficiary_user_id:SPONSOR}},
  {plan:"team",projection:true,testingContext:{...privateContext,private_org_id:SPONSOR}}
 ]) {const r=await invoke(o);assertEquals(r.response.status,503);assert(!r.body.billing);}
});

Deno.test("actual me prepare and fresh GET share exact buyer-token held DTO; foreign wire fails before reservation",async()=>{
 const held={reservation_id:"e3000000-0000-4000-8000-000000000001",actor_id:USER,app_account_token:USER,org_id:ORG,product_id:"com.rendprop.app.starter.monthly",held_at:new Date().toISOString(),trial_offer:{enabled:true,walkthroughs:1,photo_edits:5,published_listings:1,max_days:7,max_video_seconds:90,upload_budget_bytes:1073741824}};
 const request={actor_id:USER,app_account_token:USER,org_id:ORG,product_id:held.product_id};
 const r=await invoke({heldPurchase:held,prepareBody:request});assertEquals(r.response.status,200);assertEquals(r.body,held);
 const fresh=await invoke({heldPurchase:held});assertEquals(fresh.body.trial_reservation,held);assertEquals(fresh.body.trial_offer,held.trial_offer);
 const wrong=await invoke({heldPurchase:held,prepareBody:{...request,app_account_token:OTHER}});assertEquals(wrong.response.status,403);assert(!wrong.queries.some(u=>u.pathname.endsWith("prepare_subscription_trial_purchase")));
 const corrupt=await invoke({heldPurchase:{...held,app_account_token:OTHER}});assertEquals(corrupt.response.status,503);
 const converted=await invoke();assertEquals(converted.body.trial_reservation,null);assertEquals(converted.body.trial_offer,null);
});
