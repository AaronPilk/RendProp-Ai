import {assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {reservedTrialWorkspace} from "../_shared/trial-purchase.ts";
import {HttpError} from "../_shared/http.ts";
// Execute the actual entrypoint's binding block after the independently tested
// Apple JWS verifier. The test closes only database transport, no provider/Auth.
const source=await Deno.readTextFile(new URL('./index.ts',import.meta.url));
const start=source.indexOf('  const originalTransactionId = facts.transaction?.originalTransactionId ?? null;');
const end=source.indexOf('  // A product id we do not map',start);
if(start<0||end<start)throw new Error('Actual signed-notification binding block missing');
const generated=`export default async function(facts:any,admin:any,reservedTrialWorkspace:any,HttpError:any){${source.slice(start,end)} return {orgId,environmentMismatch};}`;
const {default:resolve}=await import('data:application/typescript,'+encodeURIComponent(generated));
const actor='e1000000-0000-4000-8000-000000000002',org='e2000000-0000-4000-8000-000000000001',product='com.rendprop.app.starter.monthly';
const tx=()=>({environment:'Production',currency:'USD',storefront:'USA',priceMilliunits:0,offerType:1,offerDiscountType:'FREE_TRIAL',appAccountToken:actor,productId:product,originalTransactionId:'synthetic-held-original'});
Deno.test('actual signed notification binding recovers held exact buyer/SKU before chronology; unsupported facts stay unbound',async()=>{
 let lookups=0;const rpcCalls:any[]=[];const query={select:()=>query,eq:()=>query,maybeSingle:async()=>({data:null,error:null})};
 const admin={from:()=>{lookups++;return query;},rpc:async(name:string,args:any)=>{rpcCalls.push({name,args});return {data:args.p_actor===actor&&args.p_product===product?org:null,error:null};}};
 const run=(t:any)=>resolve({environment:t.environment,transaction:t},admin,reservedTrialWorkspace,HttpError);
 assertEquals(await run(tx()),{orgId:org,environmentMismatch:false});assertEquals(rpcCalls[0],{name:'subscription_trial_reserved_workspace',args:{p_actor:actor,p_product:product}});
 for(const patch of [{appAccountToken:org},{productId:'com.rendprop.app.pro.monthly'}])assertEquals(await run({...tx(),...patch}),{orgId:null,environmentMismatch:false});
 const count=rpcCalls.length;
 for(const patch of [{environment:'Sandbox'},{priceMilliunits:49000},{appAccountToken:null},{offerType:2},{offerDiscountType:'PAY_AS_YOU_GO'}])assertEquals(await run({...tx(),...patch}),{orgId:null,environmentMismatch:false});
 assertEquals(rpcCalls.length,count);assertEquals(lookups,8);assertEquals(rpcCalls.some(c=>c.name.includes('fund')),false);
});
Deno.test('actual notification binding preserves existing exact chain and refuses ambiguous held lookup',async()=>{
 const query={select:()=>query,eq:()=>query,maybeSingle:async()=>({data:{org_id:org,environment:'Production'},error:null})};
 const admin={from:()=>query,rpc:()=>{throw new Error('Known chain must not recover different hold');}};
 assertEquals(await resolve({environment:'Production',transaction:tx()},admin,reservedTrialWorkspace,HttpError),{orgId:org,environmentMismatch:false});
 query.maybeSingle=async()=>({data:null as any,error:null});
 await assertRejects(()=>resolve({environment:'Production',transaction:tx()},{from:()=>query,rpc:async()=>({data:[org,actor],error:null})},reservedTrialWorkspace,HttpError),HttpError);
});
