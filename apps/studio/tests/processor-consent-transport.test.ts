import assert from "node:assert/strict";
import test from "node:test";
import type {Session,AuthChangeEvent} from "@supabase/auth-js";
import {StudioError} from "../src/data/config";
import {createStudioServices,type StudioAuth} from "../src/data/services";
import {CONSENT_V1,CONSENT_V2,PROCESSOR_DISCLOSURE,fetchProcessorAvailability} from "../src/features/sync/processor-consent";
const ACTOR="10000000-0000-4000-8000-000000000001",ORG="20000000-0000-4000-8000-000000000001",LISTING="30000000-0000-4000-8000-000000000001",JOB="40000000-0000-4000-8000-000000000001";
const endpoint="/functions/v1/property-video-jobs/processor-consent",create="/functions/v1/property-video-jobs",resume=`${create}/${JOB}/resume`;
const json=(v:unknown,status=200)=>new Response(JSON.stringify(v),{status,headers:{"Content-Type":"application/json"}});
function fixture(){
 let refreshes=0;let callback:(event:AuthChangeEvent,s:Session|null)=>void=()=>{};
 const session:Session={access_token:"closed-processor-fixture-not-real",refresh_token:"closed-fixture-refresh",expires_in:3600,expires_at:Math.floor(Date.now()/1000)+3600,token_type:"bearer",user:{id:ACTOR,aud:"authenticated",created_at:"2026-10-16T00:00:00Z",app_metadata:{},user_metadata:{}}};
 const auth:StudioAuth={getSession:async()=>({data:{session},error:null}),refreshSession:async()=>{refreshes++;return{data:{session},error:null};},signInWithOAuth:async()=>({error:null}),signOut:async()=>({error:null}),onAuthStateChange:cb=>{callback=cb;return{data:{subscription:{unsubscribe(){}}}};}};
 const seen:Array<{path:string;method:string;headers:Headers;body:unknown}>=[];let respond:(path:string)=>Response|Promise<Response>=()=>json({ok:true});
 const services=createStudioServices({supabaseUrl:"https://closed-processor.supabase.co",publishableKey:"sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY",redirectTo:"http://localhost:5173/"},{auth,fetch:async(input,options={})=>{
  const u=new URL(String(input)),headers=new Headers(options.headers),method=options.method??"GET";
  if(u.pathname==="/functions/v1/me/workspaces")return json({actor_id:ACTOR,own_org_id:ORG,billing_org_id:ORG,active_org_id:ORG,can_switch_agent_libraries:false,workspaces:[{id:ORG,name:"Own library",role:"owner",access_mode:"own",library_owner_user_id:ACTOR,billing_org_id:ORG,can_read:true,can_write:true,can_manage_subscription:true}]});
  if(u.pathname==="/functions/v1/me")return json({user:{id:ACTOR,email:null,name:null,avatar_url:null},org:{id:ORG,name:"Library",space_type:"real_estate",handle:null},billing:{org_id:ORG,content_org_id:ORG,serving_org_id:ORG,role:"owner",can_manage_subscription:true},plan:"free",plan_raw:"free",trial_ends_at:null,plan_expires_at:null,usage:{listings:1,leads:0,leads_new:0,renders:0}});
  if(u.pathname==="/functions/v1/listings")return json({actor_id:ACTOR,listings:[{id:LISTING,org_id:ORG,library_org_id:ORG,space_type:"real_estate",address:"Synthetic only",tagline:null,details:{},status:"draft",created_at:"2026-10-16T00:00:00Z",deleted_at:null,main_photo_key:null,beds:null,baths:null,sqft:null,price_cents:null}],total:1,next_offset:null});
  seen.push({path:u.pathname,method,headers,body:typeof options.body==="string"?JSON.parse(options.body):null});return respond(u.pathname);
 }});
 return{services,seen,setReply:(fn:typeof respond)=>{respond=fn;},refreshes:()=>refreshes,async open(){await services.loadWorkspace(undefined,ORG);await services.listListings(ORG);},scope:()=>({actor:ACTOR,org:ORG,library:ORG,listing:LISTING,identityVersion:services.getSnapshot().identityVersion}),scopeOptions:{orgId:ORG,expectedLibraryOrgId:ORG,expectedListingId:LISTING},emitOther(){callback("SIGNED_IN",{...session,user:{...session.user,id:JOB}});}};
}

test("actual transport sends scopedv2 disclosure only on create/resume and keeps planner/headerless reads unchanged",async()=>{
 const f=fixture();try{await f.open();for(const path of [create,resume])await f.services.api(path,{...f.scopeOptions,method:"POST",body:{},aiConsent:CONSENT_V2,aiConsentDisclosure:PROCESSOR_DISCLOSURE.disclosure_revision});
 await f.services.api("/functions/v1/property-video-plan",{...f.scopeOptions,method:"POST",body:{},aiConsent:"property-video-plan-v1"});await f.services.api(endpoint,f.scopeOptions);
 for(const row of f.seen.slice(0,2)){assert.equal(row.headers.get("X-Rendprop-AI-Consent"),CONSENT_V2);assert.equal(row.headers.get("X-Rendprop-AI-Consent-Disclosure"),PROCESSOR_DISCLOSURE.disclosure_revision);assert.equal(row.headers.get("X-Org-Id"),ORG);}
 assert.equal(f.seen[2].headers.get("X-Rendprop-AI-Consent"),"property-video-plan-v1");assert.equal(f.seen[2].headers.get("X-Rendprop-AI-Consent-Disclosure"),null);assert.equal(f.seen[3].headers.get("X-Rendprop-AI-Consent"),null);
 }finally{f.services.dispose();}
});
test("v2 cannot leak onto unrelated routes/reads or use missing malformed or v1-disclosure headers",async()=>{
 const f=fixture();try{await f.open();const bad=[{path:"/functions/v1/studio/voice",method:"POST"as const,aiConsent:CONSENT_V2,aiConsentDisclosure:PROCESSOR_DISCLOSURE.disclosure_revision},{path:endpoint,method:"GET"as const,aiConsent:CONSENT_V2,aiConsentDisclosure:PROCESSOR_DISCLOSURE.disclosure_revision},{path:create,method:"POST"as const,aiConsent:CONSENT_V2},{path:resume,method:"POST"as const,aiConsent:CONSENT_V2,aiConsentDisclosure:"bad revision"},{path:create,method:"POST"as const,aiConsent:CONSENT_V1,aiConsentDisclosure:PROCESSOR_DISCLOSURE.disclosure_revision}];
 for(const {path,...options}of bad)await assert.rejects(()=>f.services.api(path,{...f.scopeOptions,...options}),e=>e instanceof StudioError&&e.code==="request-consent");assert.equal(f.seen.length,0);
 }finally{f.services.dispose();}
});
test("only precise processor404/body-code becomes unpublishedlegacy; ordinary missing route does not",async()=>{
 const f=fixture();try{await f.open();f.setReply(()=>json({code:"processor_disclosure_unpublished"},404));assert.deepEqual(await fetchProcessorAvailability(f.services,f.scope()),{kind:"legacy"});
 for(const response of [()=>json({code:"request-failed"},404),()=>new Response("unreadable",{status:404}),()=>json({code:"processor_disclosure_unpublished"},503)]){f.setReply(response);await assert.rejects(()=>fetchProcessorAvailability(f.services,f.scope()));}
 assert(f.seen.every(x=>x.method==="GET"));
 }finally{f.services.dispose();}
});
test("typed processor403 is retained on exact video actions without reinterpreting arbitrary access403 or auto retry",async()=>{
 const f=fixture();try{await f.open();for(const path of [create,resume]){f.setReply(()=>json({code:"processor_consent_required",error:"https://MUST-NOT-ECHO.invalid/secret"},403));await assert.rejects(()=>f.services.api(path,{...f.scopeOptions,method:"POST",body:{},aiConsent:CONSENT_V1}),e=>e instanceof StudioError&&e.code==="processor_consent_required"&&e.status===403&&!e.message.includes("MUST-NOT-ECHO"));}
 for(const [path,response]of [[create,()=>json({code:"access_denied"},403)],[create,()=>new Response("unreadable",{status:403})],["/functions/v1/studio/voice",()=>json({code:"processor_consent_required"},403)]]as const){f.setReply(response);await assert.rejects(()=>f.services.api(path,{...f.scopeOptions,method:"POST",body:{}}),e=>e instanceof StudioError&&e.code==="request-failed"&&e.status===403);}
 assert.equal(f.seen.length,5);assert.equal(f.refreshes(),0);
 }finally{f.services.dispose();}
});
test("401 or ambiguous lostPOST never refreshes and replays a paid video mutation",async()=>{
 const f=fixture();try{await f.open();f.setReply(()=>json({code:"expired"},401));await assert.rejects(()=>f.services.api(create,{...f.scopeOptions,method:"POST",body:{},aiConsent:CONSENT_V2,aiConsentDisclosure:PROCESSOR_DISCLOSURE.disclosure_revision}));assert.equal(f.seen.length,1);assert.equal(f.refreshes(),0);
 f.setReply(()=>{throw TypeError("lost accepted reply");});await assert.rejects(()=>f.services.api(create,{...f.scopeOptions,method:"POST",body:{},aiConsent:CONSENT_V2,aiConsentDisclosure:PROCESSOR_DISCLOSURE.disclosure_revision}));assert.equal(f.seen.length,2);assert.equal(f.refreshes(),0);
 }finally{f.services.dispose();}
});
test("late account change cannot return a processor contract to the previous property session",async()=>{
 const f=fixture();try{await f.open();const scope=f.scope();f.setReply(()=>{f.emitOther();return json({token:CONSENT_V2,disclosure_revision:PROCESSOR_DISCLOSURE.disclosure_revision,processors:[...PROCESSOR_DISCLOSURE.processors],profiles:[...PROCESSOR_DISCLOSURE.profiles]});});await assert.rejects(()=>fetchProcessorAvailability(f.services,scope));assert.equal(f.seen.length,1);
 }finally{f.services.dispose();}
});
