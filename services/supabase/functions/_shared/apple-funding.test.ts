import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {fundVerifiedAppleTransaction} from "./apple-funding.ts";
import {HttpError} from "./http.ts";
import type {AppleTransaction} from "./applejws.ts";
const actor="af100001-0000-4000-8000-000000000001",org="af200001-0000-4000-8000-000000000001";
const tx:AppleTransaction={transactionId:"synthetic-tx",originalTransactionId:"synthetic-chain",productId:"com.rendprop.app.pro.monthly",bundleId:"com.rendprop.app",environment:"Production",purchaseDate:"2026-10-01T00:00:00Z",expiresDate:"2026-11-01T00:00:00Z",signedDate:"2026-10-01T00:01:00Z",revocationDate:null,revocationReason:null,type:"Auto-Renewable Subscription",inAppOwnershipType:"PURCHASED",appAccountToken:actor,webOrderLineItemId:null,subscriptionGroupIdentifier:null,priceMilliunits:49000,currency:"USD",storefront:"USA"};
for(const [name,patch,rpcName,hasBuyer]of[
 ["exact paid buyer",{},"fund_verified_retail_apple_transaction",true],
 ["missing legacy token",{appAccountToken:null},"fund_verified_apple_transaction",false],
 ["legacy missing price",{priceMilliunits:null},"fund_verified_apple_transaction",false],
 ["held trial",{priceMilliunits:0,offerType:1,offerDiscountType:"FREE_TRIAL"},"fund_reserved_subscription_trial",true],
 ["zero unrecognized offer",{priceMilliunits:0},"fund_verified_apple_transaction",false],
 ["refund preserves signed buyer",{revocationDate:"2026-10-02T00:00:00Z"},"fund_verified_retail_apple_transaction",true],
 ["refund missing token",{revocationDate:"2026-10-02T00:00:00Z",appAccountToken:null},"fund_verified_apple_transaction",false]
]as const)Deno.test(`verified funding route ${name}`,async()=>{
 const calls:Array<{name:string,args:Record<string,unknown>}>=[];
 const result=await fundVerifiedAppleTransaction((name,args)=>{calls.push({name,args});return Promise.resolve({data:{funded:true},error:null});},org,{...tx,...patch});
 assertEquals(result,{funded:true});assertEquals(calls.length,1);assertEquals(calls[0].name,rpcName);assertEquals("p_actor"in calls[0].args,hasBuyer);if(hasBuyer)assertEquals(calls[0].args.p_actor,actor);
 assertEquals(calls[0].args.p_org,org);assertEquals(calls[0].args.p_original,tx.originalTransactionId);assertEquals(calls[0].args.p_transaction,tx.transactionId);assert(/^[a-f0-9]{64}$/.test(calls[0].args.p_evidence_sha256 as string));
});
Deno.test("Sandbox never calls a Production funding RPC",async()=>{let calls=0;assertEquals(await fundVerifiedAppleTransaction(()=>{calls++;throw Error("dispatch");},org,{...tx,environment:"Sandbox"}),{funded:false,reason:"sandbox"});assertEquals(calls,0);});
Deno.test("funding RPC outage retains explicit restore recovery",async()=>{const e=await assertRejects(()=>fundVerifiedAppleTransaction(()=>Promise.resolve({data:null,error:{message:"synthetic outage"}}),org,tx),HttpError);assertEquals(e.status,503);assert(e.message.includes("recorded")&&e.message.includes("Restore"));});
