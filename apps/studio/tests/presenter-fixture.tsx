import { useState } from "react";
import { createRoot } from "react-dom/client";
import CreativeWorkspace from "../src/features/creative/CreativeWorkspace";
import type { StudioServices } from "../src/data/services";
import type { Listing, Workspace } from "../src/data/contracts";
import type { Draft, Profile } from "../src/features/presenter/model";
import "../src/styles.css";
const org="11111111-1111-4111-8111-111111111111",listing="22222222-2222-4222-8222-222222222222",second="22222222-2222-4222-8222-222222222223",user="33333333-3333-4333-8333-333333333333",editor="33333333-3333-4333-8333-333333333334",viewer="33333333-3333-4333-8333-333333333335",video="55555555-5555-4555-8555-555555555555";
const ids=Array.from({length:9},(_,i)=>`44444444-4444-4444-8444-${String(i+1).padStart(12,"0")}`);
let actor=user,epoch=1,lose="",failBefore="",readFailure=false,hold="",release:(()=>void)|undefined;
const subscribers=new Set<(snapshot: unknown)=>void>(),calls:any[]=[],handoffs:any[]=[],pending:any[]=[];
const saved=JSON.parse(localStorage.getItem("presenter-fixture-server")??'{"profiles":[],"drafts":[]}');
let profiles:Profile[]=saved.profiles,drafts:Draft[]=saved.drafts,jobs:any[]=saved.jobs??[],quotes:any[]=saved.quotes??[],generationAvailable=!!saved.generationAvailable,dispatches=saved.dispatches??0,closedSubmissions:any[]=saved.closedSubmissions??[];
function persist(){localStorage.setItem("presenter-fixture-server",JSON.stringify({profiles,drafts,jobs,quotes,generationAvailable,dispatches,closedSubmissions}));}
function state(selected=listing){return {org_id:org,listing_id:selected,profiles:profiles.filter(p=>p.subject_user_id===actor||p.status==="approved").map(p=>({...p,permissions:{can_save:p.subject_user_id===actor,can_approve:p.subject_user_id===actor&&p.status!=="approved",can_revoke:p.subject_user_id===actor&&p.status!=="revoked"}})),drafts:drafts.filter(d=>d.listing_id===selected).map(d=>({...d,permissions:{can_save:actor!==viewer,can_approve:d.subject_user_id===actor&&actor!==viewer,can_request_generation:actor!==viewer&&d.status==="approved",can_generate:false}})),reference_candidates:ids.map(asset_id=>({asset_id,listing_id:selected})),source_candidates:[{asset_id:video,listing_id:selected,duration_s:6}],permissions:{can_save_profile:actor!==viewer,can_create_draft:actor!==viewer},runtime:{available:generationAvailable,code:generationAvailable?"ready":"enterprise_contract_required",reason:generationAvailable?"Generation is available for approved drafts.":"AI generation is not connected. You can prepare drafts and edit original footage."}};}
const stamp="2099-01-01T00:00:00Z";
function preview(asset_id:string,property=listing,kind="jpg"){const now=new Date(Math.floor(Date.now()/1000)*1000),query=new URLSearchParams({"X-Amz-Algorithm":"AWS4-HMAC-SHA256","X-Amz-Credential":"fixture/auto/s3/aws4_request","X-Amz-Date":now.toISOString().replace(/[-:]/g,"").replace(".000",""),"X-Amz-Expires":"300","X-Amz-SignedHeaders":"host","X-Amz-Signature":"f".repeat(64)});return {asset_id,url:`https://${"a".repeat(32)}.r2.cloudflarestorage.com/bucket/uploads/${org}/${property}/${asset_id}.${kind}?${query}`,expires_at:new Date(now.getTime()+300000).toISOString()};}
function jobsState(selected=listing){return{org_id:org,listing_id:selected,runtime:state(selected).runtime,quotes:quotes.filter(q=>drafts.find(d=>d.id===q.draft_id)?.listing_id===selected),jobs:jobs.filter(j=>drafts.find(d=>d.id===j.draft_id)?.listing_id===selected).map(j=>{const d=drafts.find(d=>d.id===j.draft_id)!,p=profiles.find(p=>p.id===d.profile_id),valid=d.revision===j.draft_revision&&p?.revision===j.profile_revision,subject=d.subject_user_id===actor;const o=j.output?{...j.output}:null;if(o&&subject&&valid){const media=preview(j.id,selected,"mp4");o.preview_url=media.url.replace(`/uploads/${org}/${selected}/${j.id}.mp4`,`/presenter-private/${org}/${j.id}/output.mp4`);o.preview_expires_at=media.expires_at;}return{...j,status:valid?j.status:"invalidated",output:valid?o:null,imported_asset_id:valid?j.imported_asset_id:null,permissions:{can_cancel:["queued","processing","uncertain"].includes(j.status),can_review:subject&&valid&&j.status==="review",can_import:valid&&["accepted","importing","imported"].includes(j.status)}};})};}
const services={getSnapshot:()=>({status:"signed-in",identityVersion:epoch,identity:{userId:actor,isAnonymous:false}}),subscribe:(fn:(snapshot: unknown)=>void)=>{subscribers.add(fn);return()=>subscribers.delete(fn);},listMedia:async(_org:string,id:string)=>({orgId:org,listingId:id,photos:[],videos:[],nextOffset:null,unavailableCount:0}),api:async(path:string,options:any)=>{
 const body=options.body,query=new URL(path,"https://fixture.invalid"),selected=body?.listing_id??query.searchParams.get("listing_id")??listing;
 calls.push({path,body:structuredClone(body),actor,org:options.orgId});if(calls.length>200)throw new Error("Unexpected request loop");if(options.orgId!==org)throw new Error("Wrong org");
 if(path.includes("studio/documents?"))return{document:null};if(path.includes("studio/creative-results?"))return{results:[],next_offset:null};if(path.includes("studio/listing-state?"))return{org_id:org,listing_id:selected,assets:[],photos:[],jobs:[],renders:[],chapters:[],next_offset:null};
 if(path.includes("studio/presenter/jobs?")){if(readFailure){readFailure=false;throw new Error("Offline job receipt check");}return structuredClone(jobsState(selected));}
 if(path.endsWith("studio/presenter/jobs")){
  const action=body.action;let closedSubmission:any=null;if(failBefore===action){failBefore="";readFailure=true;throw new Error("Request did not reach the server");}
  if(action==="quote"){const d=drafts.find(d=>d.id===body.draft_id)!;if(!generationAvailable||d.status!=="approved"||d.revision!==body.expected_revision||d.profile_revision!==body.expected_profile_revision)throw new Error("Approval changed");quotes.unshift({id:crypto.randomUUID(),draft_id:d.id,draft_revision:d.revision,profile_revision:d.profile_revision,quote_cents:47,max_cost_cents:100,estimate_usd:"0.470000",expires_at:new Date(Date.now()+300000).toISOString(),consumed:false});}
  else if(action==="close_submission"){const existing=jobs.find(j=>j.quote_id===body.quote_id);if(!existing){closedSubmission={quote_id:body.quote_id,idempotency_key:body.idempotency_key};closedSubmissions.push(closedSubmission);quotes=quotes.filter(q=>q.id!==body.quote_id);}}
  else if(action==="generate"){if(closedSubmissions.some(s=>s.quote_id===body.quote_id||s.idempotency_key===body.idempotency_key))throw new Error("This request is closed");const q=quotes.find(q=>q.id===body.quote_id);if(!q||Date.parse(q.expires_at)<=Date.now())throw new Error("Get a fresh presenter quote");if(!body.cost_consent||body.max_cost_cents!==q.max_cost_cents)throw new Error("Cost consent missing");if(!q.consumed){q.consumed=true;dispatches++;jobs.unshift({id:crypto.randomUUID(),quote_id:q.id,draft_id:q.draft_id,draft_revision:q.draft_revision,profile_revision:q.profile_revision,revision:1,status:"queued",quote_cents:q.quote_cents,max_cost_cents:q.max_cost_cents,held_cents:q.max_cost_cents,estimate_usd:q.estimate_usd,charged_cents:null,actual_usd:null,output:null,imported_asset_id:null});}}
  else{const j=jobs.find(j=>j.id===body.job_id)!;if(j.revision!==body.expected_revision)throw new Error("Job changed");const dto=jobsState(selected).jobs.find(x=>x.id===j.id)!;
   if(action==="check"){if(j.status==="queued"||j.status==="processing"){j.status="review";j.output={sha256:"c".repeat(64),bytes:12345,duration_s:6};j.held_cents=0;j.charged_cents=41;j.actual_usd="0.410000";}}
   else if(action==="cancel"){if(!dto.permissions.can_cancel)throw new Error("Cannot cancel");j.status="cancelled";j.held_cents=0;j.charged_cents=0;j.actual_usd="0.000000";}
   else if(action==="accept"||action==="reject"){if(!dto.permissions.can_review)throw new Error("Subject review required");if(action==="accept"&&(!body.output_consent||body.output_sha256!==j.output.sha256))throw new Error("Exact output approval required");j.status=action==="accept"?"accepted":"rejected";}
   else if(action==="import"){if(!dto.permissions.can_import)throw new Error("Output not accepted");j.status="imported";j.imported_asset_id="55555555-5555-4555-8555-555555555556";}
   else throw new Error("Unknown job action");j.revision++;
  }
  persist();if(lose===action){lose="";readFailure=true;throw new Error("Job saved but response lost");}return structuredClone({...jobsState(selected),...(closedSubmission?{closed_submission:closedSubmission}:{})});
 }
 if(path.includes("studio/presenter?")){if(readFailure){readFailure=false;throw new Error("Offline receipt check");}return structuredClone(state(selected));}
 if(path.endsWith("studio/presenter/media")){
  if(body.source_asset_id)return{org_id:org,listing_id:selected,source:{...preview(body.source_asset_id,selected,"mp4"),duration_s:6}};
  const p=body.profile_id?profiles.find(p=>p.id===body.profile_id):undefined;if(p&&p.revision!==body.expected_profile_revision)throw new Error("Profile changed");
  return{org_id:org,listing_id:selected,profile_id:p?.id??null,profile_revision:p?.revision??null,references:(p?.reference_asset_ids??body.asset_ids).map((id:string)=>preview(id,p?.source_listing_id??selected))};
 }
 if(path.endsWith("studio/presenter")){
  const action=body.action;
  if(action==="generate")throw new Error("No fixture provider exists");
  if(hold===action){hold="";await new Promise<void>(done=>{release=done;});release=undefined;}
  if(action==="save_profile"){
   const previous=profiles.find(p=>p.subject_user_id===actor);if((previous?.revision??0)!==body.expected_revision)throw new Error("Profile changed on another device");
   const p={id:previous?.id??crypto.randomUUID(),subject_user_id:actor,source_listing_id:selected,display_name:body.display_name,reference_asset_ids:body.reference_asset_ids,status:"pending",revision:(previous?.revision??0)+1,approved_revision:null,permissions:{}} as Profile;
   profiles=profiles.filter(p=>p.subject_user_id!==actor).concat(p);
   for(const d of drafts)if(d.profile_id===p.id){d.revision++;d.status="draft";d.approved_revision=null;d.approved_profile_revision=null;}
  }else if(action.endsWith("profile")){
   const p=profiles.find(p=>p.id===body.profile_id)!;if(p.subject_user_id!==actor||p.revision!==body.expected_revision)throw new Error("Profile permission or revision changed");
   if(action==="approve_profile"&&!body.likeness_consent)throw new Error("Likeness consent missing");p.revision++;p.status=action==="approve_profile"?"approved":"revoked";p.approved_revision=p.status==="approved"?p.revision:null;
   for(const d of drafts)if(d.profile_id===p.id){d.revision++;d.status="draft";d.approved_revision=null;d.approved_profile_revision=null;}
  }else{
   const old=drafts.find(d=>d.id===body.draft_id),p=profiles.find(p=>p.id===(body.profile_id??old?.profile_id))!;
   if((old?.revision??0)!==body.expected_revision||p.revision!==body.expected_profile_revision||p.status!=="approved")throw new Error("Draft or profile changed on another device");
   if(action==="save_draft"){
    const d={id:body.draft_id,listing_id:selected,author_user_id:old?.author_user_id??actor,subject_user_id:p.subject_user_id,profile_id:p.id,profile_revision:p.revision,title:body.title,script:body.script,source_asset_id:body.source_asset_id,format:body.format,resolution:body.resolution,revision:(old?.revision??0)+1,status:"draft",approved_revision:null,approved_profile_revision:null,permissions:{}} as Draft;
    drafts=drafts.filter(x=>x.id!==d.id).concat(d);
   }else{if(old!.subject_user_id!==actor||!body.source_performance_consent)throw new Error("Subject approval missing");old!.revision++;old!.status="approved";old!.approved_revision=old!.revision;old!.approved_profile_revision=p.revision;}
  }
  persist();if(lose===action){lose="";readFailure=true;throw new Error("Saved, but response lost");}return structuredClone(state(selected));
 }
 throw new Error(`Unexpected fixture call ${path}`);
}} as unknown as StudioServices;
function Fixture(){const[active,setActive]=useState(actor);const listings:Listing[]=[listing,second].map((id,i)=>({id,orgId:org,spaceType:"real_estate",address:i?"Second property":"18 Oak Street",tagline:null,details:{},status:"draft",createdAt:stamp,mainPhotoKey:null,beds:null,baths:null,sqft:null,priceCents:null}));const workspace:Workspace={user:{id:active,email:null,name:active===user?"Morgan Agent":"Agency Editor",avatarUrl:null},org:{id:org,name:"Fixture team",handle:null,spaceType:"real_estate"},plan:"starter",planRaw:null,planDegraded:false,trialEndsAt:null,planExpiresAt:null,memberships:[{orgId:org,role:"admin",orgName:"Fixture team",spaceType:"real_estate"}],usage:{listings:2,leads:0,leadsNew:0,renders:0}};
 Object.assign(window,{presenterFixture:{snapshot:()=>structuredClone({profiles,drafts,jobs,quotes,dispatches,calls,handoffs,pending}),expireQuotes:()=>{for(const q of quotes)if(!q.consumed)q.expires_at=new Date(Date.now()-1000).toISOString();persist();},failBefore:(action:string)=>{failBefore=action;},enableGeneration:()=>{generationAvailable=true;persist();},lose:(action:string)=>{lose=action;},hold:(action:string)=>{hold=action;},release:()=>release?.(),held:()=>!!release,editRemote:()=>{const d=drafts[0];d.revision++;d.script="A newer script from the office";d.status="draft";d.approved_revision=null;d.approved_profile_revision=null;persist();},actor:(which:string)=>{actor=which==="editor"?editor:which==="viewer"?viewer:user;epoch++;subscribers.forEach(fn=>fn(services.getSnapshot()));setActive(actor);}}});
 return <main style={{padding:24}}><CreativeWorkspace key={active} services={services} workspace={workspace} listings={listings} entryRequest={{id:active,listingId:listing,tool:"presenter"}} onChanged={()=>{}} onPresenterPendingChange={(value,busy)=>pending.push({value,busy})} onUseAgentPlan={plan=>handoffs.push(plan)}/></main>;
}
createRoot(document.getElementById("root")!).render(<Fixture/>);
