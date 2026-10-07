import {assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {heldTrialPurchase,prepareTrialPurchase,reservedTrialWorkspace} from "./trial-purchase.ts";
import {fundVerifiedAppleTransaction} from "./apple-funding.ts";
import {inputHash} from "./funded-serving.ts";
import {HttpError} from "./http.ts";
const actor="e1000000-0000-4000-8000-000000000002",org="e2000000-0000-4000-8000-000000000001",product="com.rendprop.app.starter.monthly";
const receipt=()=>({reservation_id:"e3000000-0000-4000-8000-000000000001",actor_id:actor,app_account_token:actor,org_id:org,product_id:product,held_at:new Date().toISOString(),trial_offer:{enabled:true,walkthroughs:1,photo_edits:5,published_listings:1,max_days:7,max_video_seconds:90,upload_budget_bytes:1073741824}});
const body=()=>({actor_id:actor,app_account_token:actor,org_id:org,product_id:product});
const tx=()=>({environment:"Production",appAccountToken:actor,productId:product,originalTransactionId:"synthetic-original",transactionId:"synthetic-tx",priceMilliunits:0,currency:"USD",storefront:"USA",offerType:1,offerDiscountType:"FREE_TRIAL",purchaseDate:new Date().toISOString(),expiresDate:new Date(Date.now()+7*86400000).toISOString(),signedDate:new Date().toISOString()}) as any;
Deno.test("trial prepare requires explicit authenticated buyer/token/org and echoes exact held seven-day terms",async()=>{
 let calls=0;const data=receipt();const admin={rpc:(name:string,args:unknown)=>{calls++;assertEquals(name,"prepare_subscription_trial_purchase");assertEquals(args,{p_actor:actor,p_org:org,p_product:product});return Promise.resolve({data,error:null});}};
 assertEquals(await prepareTrialPurchase(admin,actor,org,body()),data);
 for(const patch of [{actor_id:"foreign"},{app_account_token:"foreign"},{actor_id:undefined},{app_account_token:undefined},{org_id:"foreign"},{product_id:"unknown"}])await assertRejects(()=>prepareTrialPurchase(admin,actor,org,{...body(),...patch}),HttpError);
 assertEquals(calls,1);
});
Deno.test("trial held DTO refuses foreign actor/token/org/SKU and inflated or short terms",async()=>{
 const data=receipt();for(const mutate of [(r:any)=>r.actor_id=org,(r:any)=>r.app_account_token=org,(r:any)=>delete r.app_account_token,(r:any)=>r.org_id=actor,(r:any)=>r.product_id="unknown",(r:any)=>r.trial_offer.max_days=3,(r:any)=>r.trial_offer.photo_edits=6,(r:any)=>r.trial_offer.max_video_seconds=91,(r:any)=>r.trial_offer.upload_budget_bytes=1073741825,(r:any)=>r.held_at="invalid"]){const r=structuredClone(data);mutate(r);await assertRejects(()=>heldTrialPurchase({rpc:()=>Promise.resolve({data:r,error:null})},actor,org),HttpError);}
 assertEquals(await heldTrialPurchase({rpc:()=>Promise.resolve({data:null,error:null})},actor,org),null);
});
Deno.test("trial prepare propagates bounded admission errors and refuses unknown or malformed upstream",async()=>{
 for(const status of [402,403,409]){const e=await assertRejects(()=>prepareTrialPurchase({rpc:()=>Promise.resolve({error:{message:`RP${status}: Synthetic refusal`}})},actor,org,body()),HttpError);assertEquals(e.status,status);}
 for(const data of [null,{},receipt().trial_offer])await assertRejects(()=>prepareTrialPurchase({rpc:()=>Promise.resolve({data,error:null})},actor,org,body()),HttpError);
});
Deno.test("signed trial notification lookup recovers exact held actor/SKU only, before any provisioning",async()=>{
 let calls=0;const admin={rpc:(name:string,args:unknown)=>{calls++;assertEquals(name,"subscription_trial_reserved_workspace");assertEquals(args,{p_actor:actor,p_product:product});return Promise.resolve({data:org,error:null});}};
 assertEquals(await reservedTrialWorkspace(admin,tx()),org);
 for(const patch of [{currency:"EUR"},{storefront:"CAN"},{environment:"Sandbox"},{priceMilliunits:49000},{offerType:2},{offerDiscountType:"PAY_AS_YOU_GO"},{appAccountToken:null},{appAccountToken:"invalid"},{productId:"unknown"}])assertEquals(await reservedTrialWorkspace(admin,{...tx(),...patch}),null);
 assertEquals(calls,1);
 assertEquals(await reservedTrialWorkspace({rpc:()=>Promise.resolve({data:null,error:null})},tx()),null);
 await assertRejects(()=>reservedTrialWorkspace({rpc:()=>Promise.resolve({data:[org,actor],error:null})},tx()),HttpError);
});
Deno.test("verified free-trial funding dispatch binds signed buyer; paid and Sandbox retain their authority paths",async()=>{
 const calls:{name:string;args:any}[]=[];const rpc=async(name:string,args:any)=>{calls.push({name,args});return {data:{funded:true},error:null};};
 await fundVerifiedAppleTransaction(rpc,org,tx());assertEquals(calls[0].name,"fund_reserved_subscription_trial");assertEquals(calls[0].args.p_actor,actor);
 const paid={...tx(),priceMilliunits:49000,offerType:undefined,offerDiscountType:undefined};
 const paidProof={p_org:org,p_original:paid.originalTransactionId,p_transaction:paid.transactionId,p_product:product,p_price_milliunits:49000,p_currency:"USD",p_storefront:"USA",p_offer_type:null,p_offer_discount_type:null,p_purchased_at:paid.purchaseDate,p_expires_at:paid.expiresDate,p_signed_at:paid.signedDate,p_actor:actor};
 await fundVerifiedAppleTransaction(rpc,org,paid);assertEquals(calls[1],{name:"fund_verified_retail_apple_transaction",args:{...paidProof,p_evidence_sha256:await inputHash(paidProof)}});
 await fundVerifiedAppleTransaction(rpc,org,{...tx(),appAccountToken:undefined});assertEquals(calls[2].name,"fund_reserved_subscription_trial");assertEquals(calls[2].args.p_actor,null);
 await fundVerifiedAppleTransaction(rpc,org,{...paid,appAccountToken:null});assertEquals(calls[3].name,"fund_verified_apple_transaction");assertEquals("p_actor"in calls[3].args,false);
 assertEquals(await fundVerifiedAppleTransaction(rpc,org,{...tx(),environment:"Sandbox"}),{funded:false,reason:"sandbox"});assertEquals(calls.length,4);
 await assertRejects(()=>fundVerifiedAppleTransaction(async()=>({data:null,error:{message:"fixture"}}),org,tx()),HttpError);
});
