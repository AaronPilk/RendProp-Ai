import {assert,assertEquals,assertThrows,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {assertExpectedSubscriptionWorkspace,assertVerifiedPurchaseOwner} from "./billing.ts";
import type {SupabaseClient} from "npm:@supabase/supabase-js@2";
import {HttpError} from "../_shared/http.ts";
const USER="d0100103-0000-4000-8000-000000000001", ORG="d0100103-0000-4000-8000-000000000002", OTHER="d0100103-0000-4000-8000-000000000003";
type Handler=(req:Request)=>Promise<Response>;
let handler:Handler;
type Options={role?:string;plan?:string;source?:string|null;anonymous?:boolean;degraded?:boolean;membershipError?:boolean;selector?:string;subscriptionError?:boolean};
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
   if(table==="org_entitlement")return json(o.degraded?null:{plan:o.plan??"free",renders_per_month:1,photo_edits_per_month:0,reels_per_month:0,aerials_per_month:0,topaz_per_month:0,seats:1,cogs_ceiling_cents:250,price_cents:0});
   if(table==="notification_preferences_for")return json({});
   if(table==="memberships") {
    if(url.searchParams.get("select")==="org_id")return row({org_id:OTHER});
    return o.membershipError?json({message:"fixture denied"},400):row({role:o.role??"owner"});
   }
   if(table==="orgs")return row({id:o.selector??ORG,name:"Fixture Workspace",plan:o.plan??"free",plan_source:o.source??null});
   if(table==="apple_subscriptions")return o.subscriptionError?json({message:"fixture unavailable"},400):json([{original_transaction_id:"fixture-original-transaction"}]);
   if(table==="profiles")return row({id:USER,name:"Fixture Person"});
   if(req.method==="HEAD")return new Response(null,{headers:{"content-range":"*/0"}});
   if(["cost_ledger","rate_limits"].includes(table??""))return json([]);
   unexpected.push(url.pathname);throw new Error("Unmodeled request");
  };
  Object.defineProperty(Deno,"serve",{configurable:true,writable:true,value:(fn:Handler)=>{handler=fn;return {};}});
  await import("./index.ts");assert(handler);
  const response=await handler(new Request("https://edge.invalid/me",{headers:{authorization:"Bearer fixture-token",...(o.selector?{"x-org-id":o.selector}:{})}}));
  const body=await response.json();assertEquals(unexpected,[]);return {response,body,queries};
 }finally{globalThis.fetch=oldFetch;Object.defineProperty(Deno,"serve",serve);for(const[key,value]of previous)value===undefined?Deno.env.delete(key):Deno.env.set(key,value);}
}
Deno.test("billing context belongs to the same selected workspace as entitlement",async()=>{
 const r=await invoke({selector:OTHER});assertEquals(r.response.status,200);assertEquals(r.body.org.id,OTHER);assertEquals(r.body.billing,{org_id:OTHER,org_name:"Fixture Workspace",role:"owner",can_manage_subscription:true,original_transaction_ids:[],source:null});
 assert(r.queries.filter(u=>u.pathname.endsWith("memberships")).every(u=>u.searchParams.get("org_id")==="eq."+OTHER));
});
Deno.test("guest owner may explicitly subscribe; membership does not require a named identity",async()=>{const r=await invoke({anonymous:true});assertEquals(r.response.status,200);assertEquals(r.body.billing.can_manage_subscription,true);});
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
