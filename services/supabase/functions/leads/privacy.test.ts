import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { requestClientVerification, verifyClientRecipient, CLIENT_VERIFICATION_ERROR } from "./recipient-verification.ts";
import { deleteLead } from "./deletion.ts";
import { HttpError } from "../_shared/http.ts";
const user="de110103-0000-4000-8000-000000000001",org="de110103-0000-4000-8000-000000000002",listing="de110103-0000-4000-8000-000000000003",lead="de110103-0000-4000-8000-000000000004";
Deno.test("recipient request uses saved actor/org/listing and a fresh nonce without reflecting it",async()=>{
 const calls:Array<{name:string,args:Record<string,unknown>}>=[];
 const admin={rpc(name:string,args:Record<string,unknown>){calls.push({name,args});return Promise.resolve({data:{ok:true,state:"queued",token:args.p_nonce,email:"private@fixture.invalid"},error:null});}};
 for(let i=0;i<2;i++)assertEquals(await requestClientVerification(admin,user,org,{listing_id:listing}),{ok:true,state:"queued"});
 assertEquals(calls.map(c=>c.name),["client_recipient_verification_request","client_recipient_verification_request"]);
 for(const c of calls){assertEquals(c.args.p_user,user);assertEquals(c.args.p_org,org);assertEquals(c.args.p_listing,listing);assert(/^[0-9a-f]{64}$/.test(String(c.args.p_nonce)));}
 assert(calls[0].args.p_nonce!==calls[1].args.p_nonce);
});
Deno.test("recipient endpoint forbids typed destination overrides and malformed inputs before SQL",async()=>{
 let calls=0;const admin={rpc(){calls++;throw new Error("Unexpected RPC");}};
 for(const input of [null,[],{}, {listing_id:"bad"},{listing_id:listing,email:"other@fixture.invalid"},{listing_id:listing,org_id:org}])await assertRejects(()=>requestClientVerification(admin,user,org,input),HttpError);
 assertEquals(calls,0);
});
Deno.test("recipient API never treats outage or malformed verification receipts as success",async()=>{
 for(const response of [{data:null,error:{message:"db private text"}},{data:{ok:true,state:"sent"},error:null},{data:{ok:false,state:"queued"},error:null}]){
  const error=await assertRejects(()=>requestClientVerification({rpc:()=>Promise.resolve(response)},user,org,{listing_id:listing}),HttpError);assertEquals(error.status,503);assert(!error.message.includes("private text"));
 }
});
Deno.test("public nonce confirmation accepts only explicit exact-shape tokens and generic invalid receipts",async()=>{
 let calls=0;const admin={rpc(name:string,args:Record<string,string>){calls++;assertEquals(name,"client_recipient_verification_consume");assertEquals(args,{p_nonce:"a".repeat(64)});return Promise.resolve({data:true,error:null});}};
 assertEquals(await verifyClientRecipient(admin,{token:"a".repeat(64)}),{ok:true});
 for(const input of [{token:"A".repeat(64)},{token:"a".repeat(64),email:"private@fixture.invalid"},{token:""},{}]){const e=await assertRejects(()=>verifyClientRecipient(admin,input),HttpError);assertEquals(e.status,400);assertEquals(e.message,CLIENT_VERIFICATION_ERROR);}
 assertEquals(calls,1);
 for(const data of [false,null,{ok:true}]){const e=await assertRejects(()=>verifyClientRecipient({rpc:()=>Promise.resolve({data,error:null})},{token:"a".repeat(64)}),HttpError);assertEquals(e.status,400);assertEquals(e.message,CLIENT_VERIFICATION_ERROR);}
 const e=await assertRejects(()=>verifyClientRecipient({rpc:()=>Promise.resolve({data:false,error:{message:"token details"}})},{token:"a".repeat(64)}),HttpError);assertEquals(e.status,503);assert(!e.message.includes("details"));
});
Deno.test("inquiry DELETE binds selected workspace and requires exact acknowledged receipt",async()=>{
 const receipt={ok:true,lead_id:lead,deleted:true,cleanup_pending:true};
 const calls:unknown[]=[];const admin={rpc(name:string,args:unknown){calls.push({name,args});return Promise.resolve({data:receipt,error:null});}};
 assertEquals(await deleteLead(admin,user,org,lead),receipt);assertEquals(calls,[{name:"delete_workspace_lead",args:{p_user:user,p_org:org,p_lead:lead}}]);
 for(const data of [null,{...receipt,lead_id:listing},{...receipt,deleted:false},{...receipt,cleanup_pending:"false"}]){const e=await assertRejects(()=>deleteLead({rpc:()=>Promise.resolve({data,error:null})},user,org,lead),HttpError);assertEquals(e.status,503);}
 const e=await assertRejects(()=>deleteLead({rpc:()=>Promise.resolve({data:null,error:{message:"private buyer details"}})},user,org,lead),HttpError);assertEquals(e.status,503);assert(!e.message.includes("details"));
});
