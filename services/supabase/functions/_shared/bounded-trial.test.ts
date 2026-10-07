import { assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { boundedTrialContext, subscriptionServingActivation, trialServingActivationForSync, type TrialUsage } from "./bounded-trial.ts";
import { HttpError } from "./http.ts";
const org = "c2000000-0000-4000-8000-000000000001";
const actor = "c1000000-0000-4000-8000-000000000001";
function current(): TrialUsage { return { org_id:org, status:"active", starts_at:new Date(Date.now()-60000).toISOString(), ends_at:new Date(Date.now()+86400000).toISOString(),
 walkthroughs:{used:0,cap:1,remaining:1},photo_edits:{used:0,cap:5,remaining:5},published_listings:{used:0,cap:1,remaining:1},upload_budget_bytes:1073741824,upload_used_bytes:0 }; }
const client = (data: unknown, error: unknown = null) => ({ rpc(name: string,args: unknown) { assertEquals(name,"subscription_trial_context"); assertEquals(args,{p_actor:actor,p_org:org}); return Promise.resolve({data,error}); } });
Deno.test("serving activation is independently scoped and distinguishes sponsorship from collected funding",async()=>{
 const valid={org_id:org,available:true,funded:false,authority:"private_sponsorship"};
 const rpc=(data:unknown)=>({rpc(name:string,args:unknown){assertEquals(name,"subscription_serving_activation");assertEquals(args,{p_actor:actor,p_org:org});return Promise.resolve({data,error:null});}});
 assertEquals(await subscriptionServingActivation(rpc(valid),actor,org),valid);
 for(const invalid of [{...valid,org_id:"other"},{...valid,authority:"unknown"},{...valid,available:true,authority:"subscription_activation_unavailable"},
  {...valid,authority:"verified_retail"},{...valid,available:false},{...valid,funded:true}])await assertRejects(()=>subscriptionServingActivation(rpc(invalid),actor,org),HttpError);
});
Deno.test("unfunded active Production trial is never returned as usable service; paid chronology and Sandbox remain distinct",()=>{
 const tx={environment:"Production",offerType:1,offerDiscountType:"FREE_TRIAL"};
 assertEquals(trialServingActivationForSync({funded:true},tx,"active"),{funded:true});
 assertEquals(assertThrows(()=>trialServingActivationForSync({funded:false,reason:"bounded_trial_disabled"},tx,"active"),HttpError).status,503);
 assertEquals(trialServingActivationForSync({funded:false,reason:"sandbox"},{...tx,environment:"Sandbox"},"active"),{funded:false,reason:"sandbox"});
 assertEquals(trialServingActivationForSync({funded:false,reason:"expired"},tx,"expired"),{funded:false,reason:"expired"});
 assertEquals(trialServingActivationForSync({funded:false,reason:"unattested_proceeds_and_serving"},{environment:"Production"},"active"),{funded:false,reason:"unattested_proceeds_and_serving"});
 assertThrows(()=>trialServingActivationForSync(null,tx,"active"),HttpError);
});
Deno.test("bounded trial context preserves paid/null and exposes no dormant offer", async()=>{
 assertEquals(await boundedTrialContext(client({trial_usage:null,trial_offer:null}),actor,org),{trial_usage:null,trial_offer:null});
 const usage=current(); assertEquals(await boundedTrialContext(client({trial_usage:usage,trial_offer:null}),actor,org),{trial_usage:usage,trial_offer:null});
});
Deno.test("bounded trial context refuses wrong workspace, inflated counters, old active time and live proposal",async()=>{
 const mutations=[(u:any)=>u.org_id="other",(u:any)=>u.photo_edits.cap=6,(u:any)=>u.photo_edits.remaining=4,
  (u:any)=>u.upload_budget_bytes=1073741825,(u:any)=>u.upload_used_bytes=-1,(u:any)=>u.ends_at=new Date(Date.now()-1000).toISOString(),
  (u:any)=>u.ends_at=new Date(Date.now()+8*86400000).toISOString()];
 for(const mutate of mutations){const usage=current();mutate(usage);await assertRejects(()=>boundedTrialContext(client({trial_usage:usage,trial_offer:null}),actor,org),HttpError);}
 await assertRejects(()=>boundedTrialContext(client({trial_usage:null,trial_offer:{enabled:true,photo_edits:5}}),actor,org),HttpError);
 await assertRejects(()=>boundedTrialContext(client(null,{message:"unavailable"}),actor,org),HttpError);
});
Deno.test("bounded trial context retains expired saved-work usage and exhausted buckets",async()=>{
 const usage=current();usage.status="expired";usage.ends_at=new Date(Date.now()-1000).toISOString();
 assertEquals((await boundedTrialContext(client({trial_usage:usage,trial_offer:null}),actor,org)).trial_usage?.status,"expired");
 const exhausted=current();exhausted.status="exhausted";for(const b of [exhausted.walkthroughs,exhausted.photo_edits,exhausted.published_listings]){b.used=b.cap;b.remaining=0;}
 assertEquals((await boundedTrialContext(client({trial_usage:exhausted,trial_offer:null}),actor,org)).trial_usage?.status,"exhausted");
 exhausted.status="active";await assertRejects(()=>boundedTrialContext(client({trial_usage:exhausted,trial_offer:null}),actor,org),HttpError);
 const fullIngress=current();fullIngress.upload_used_bytes=fullIngress.upload_budget_bytes;
 assertEquals((await boundedTrialContext(client({trial_usage:fullIngress,trial_offer:null}),actor,org)).trial_usage?.status,"active");
});
