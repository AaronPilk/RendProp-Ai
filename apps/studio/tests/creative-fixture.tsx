import {useState} from "react";
import {createRoot} from "react-dom/client";
import CreativeWorkspace from "../src/features/creative/CreativeWorkspace";
import type {StudioServices} from "../src/data/services";
import type {Workspace,Listing,StudioPhoto} from "../src/data/contracts";
import {EMPTY_DRAFT,type ShotPlanHandoff,type AgentPlanHandoff,type CreativeEntryRequest,type CreativeTool} from "../src/features/creative/model";
import "../src/styles.css";
const user="11111111-1111-4111-8111-111111111111",org="22222222-2222-4222-8222-222222222222",listing="33333333-3333-4333-8333-333333333333",other="33333333-3333-4333-8333-333333333334",source="44444444-4444-4444-8444-444444444444",render="55555555-5555-4555-8555-555555555555",job="66666666-6666-4666-8666-666666666666",provenance="77777777-7777-4777-8777-777777777777";
const calls:{path:string;method:string;body:any}[]=[],docs=new Map<string,any>(),tickets=new Map<string,any>(),results:any[]=[];
const shotHandoffs:ShotPlanHandoff[]=[],agentHandoffs:AgentPlanHandoff[]=[],editorHandoffs:string[]=[];
const png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=";
const url=(name:string)=>`https://012345678901234567890123456789ab.r2.cloudflarestorage.com/rendprop-renders/renders/${org}/${listing}/${name}?X-Amz-Signature=fixture`;
let counter=0;
const workspace:Workspace={user:{id:user,email:"agent@example.invalid",name:"Agent",avatarUrl:null},org:{id:org,name:"Fixture office",handle:"office",spaceType:"real_estate"},memberships:[{orgId:org,orgName:"Fixture office",role:"owner",spaceType:"real_estate"}],plan:"team",planRaw:"team",planDegraded:false,planExpiresAt:null,trialEndsAt:null,usage:{listings:2,leads:0,leadsNew:0,renders:1}};
const listings:Listing[]=[listing,other].map((id,i)=>({id,orgId:org,spaceType:"real_estate",address:i?"22 Pine Street":"10 Oak Street",tagline:"Bright rooms and a patio",details:{access_code:"private-must-not-send"},status:"ready",createdAt:"2026-09-14T12:00:00Z",mainPhotoKey:null,beds:3,baths:2,sqft:2000,priceCents:null}));
const photos:StudioPhoto[]=[{id:source,listingId:listing,url:url("source.png"),originalUrl:url("source.png"),isAltered:false,expiresAt:"2099-01-01T00:00:00Z",caption:"Kitchen",isStaged:false,sort:0}];
const services={subscribe:()=>()=>{},getSnapshot:()=>({status:"signed-in",identityVersion:1,identity:{userId:user,isAnonymous:false,email:"agent@example.invalid"}}),upload:async()=>({etag:'"fixture-receipt"'}),listMedia:async(_org:string,selected:string)=>({orgId:org,listingId:selected,photos:selected===listing?[...photos]:[],videos:[],nextOffset:null,unavailableCount:0}),api:async(path:string,options:any)=>{
 if(options.orgId!==org)throw new Error("Wrong organization");const body=options.body,method=options.method??"GET";calls.push({path,body,method});if(calls.length>160)throw new Error("Request loop");
 if(path==="/functions/v1/me"&&method==="GET")return {user:{id:user},org:{id:org,name:"Fixture office",handle:"office",space_type:"real_estate",brand_kit:{}},usage:{by_feature:{renders:1,photo_edits:0,reels:0,aerials:0,drone:0},caps:{renders:50,photo_edits:50,reels:50,aerials:50,drone:50},windows:{renders:null,photo_edits:null,reels:null,aerials:null,drone:null}},notifications:{lead_received:true,render_ready:true,upload_stuck:false,free_week_ending:true,allowance_low:true,first_tour_nudge:false,muted_until:null},entitlement:{degraded:false},portfolio_url:null,plan_source:"apple"};
 if(path.includes("studio/documents?")&&method==="GET"){const key=new URL(path,"https://fixture.invalid").searchParams.get("key")!;return {document:structuredClone(docs.get(key)??null)};}
 if(path.endsWith("studio/documents")&&method==="POST"){const previous=docs.get(body.key);if((previous?.revision??0)!==body.expected_revision)throw new Error("The draft changed on another device. Reload the cloud version.");const document={key:body.key,kind:body.kind,listing_id:body.listing_id,revision:(previous?.revision??0)+1,payload:body.payload,updated_at:new Date().toISOString()};docs.set(body.key,structuredClone(document));return {document};}
 if(path.includes("studio/listing-state?")){const selected=new URL(path,"https://fixture.invalid").searchParams.get("listing_id");return {org_id:org,listing_id:selected,assets:selected===listing?[{id:source,listing_id:listing,kind:"video",bucket:"renders",storage_key:`renders/${org}/${listing}/source.mp4`,uploaded:true,duration_s:30,bytes:1000,created_at:"2026-09-14T12:00:00Z"}]:[],jobs:selected===listing?[{id:job,listing_id:listing,capture_asset_id:source,status:"done",progress:1,current_step:"complete",tier:"smooth",error:null,created_at:"2026-09-14T12:00:00Z"}]:[],renders:selected===listing?[{id:render,listing_id:listing,job_id:job,slug:"fixture-tour",published_at:"2026-09-14T12:00:00Z",duration_s:30,staged:false,created_at:"2026-09-14T12:00:00Z"}]:[],photos:[],chapters:[],next_offset:null};}
 if(path.includes("studio/creative-results?"))return {results:structuredClone(results),next_offset:null};
 if(path.endsWith("ai-copy/script"))return {script:"Discover this bright three-bedroom property with a spacious kitchen and welcoming patio."};
 if(path.endsWith("ai-copy/shotlist"))return {script:"Welcome inside. The bright kitchen opens onto a patio.",shots:body.photos.map((p:any,i:number)=>({photo_id:p.id,order:i+1,room:p.room,motion:"push_in",seconds:5,on_screen_text:"Bright kitchen",voice_line:"The kitchen opens onto the patio."}))};
 if(path.endsWith("ai-copy/agent-reel"))return {cutaways:[{photo_id:source,start:4,end:6,on_screen_text:"Kitchen and patio",motion:"push_in"}]};
 if(path.endsWith("ai-copy/edit-prompt"))return {prompt:"Remove the movable boxes while preserving the room and permanent features."};
 if(path.endsWith("ai-photo")){if(body.edit==="suggest")return {suggestions:[{edit:"declutter",reason:"Clear the movable boxes to show the room."}]};return {image_b64:png,mime:"image/png",disclosure:"This photo was digitally altered with AI.",provenance:{id:provenance,recorded:true}};}
 if(path==="/functions/v1/uploads"&&method==="POST"){const id=`88888888-8888-4888-8888-${String(++counter).padStart(12,"0")}`;const ticket={asset_id:id,storage_key:`renders/${org}/${body.listing_id}/${body.role}-${id}.png`,uploaded:false,mode:"single",put_url:`https://uploads.rendprop.com/v2/${id}?signature=fixture`};tickets.set(id,ticket);return ticket;}
 if(/\/uploads\/[^/]+\/complete$/.test(path)){const id=path.split("/").at(-2)!;const ticket=tickets.get(id);return {...ticket,id,listing_id:listing,uploaded:true};}
 if(path.includes("me/compliance/")&&method==="PATCH")return {ok:true};
 if(path.endsWith("studio/photos")){photos.push({id:body.asset_id,listingId:listing,url:url("edited.png"),originalUrl:url("source.png"),expiresAt:"2099-01-01T00:00:00Z",caption:body.caption,isStaged:true,isAltered:true,sort:1});return {ok:true,photo:{id:body.asset_id,listing_id:listing}};}
 if(path.endsWith("ai-voice/voices"))return {voices:[{voice_id:"voice_fixture",name:"Sam",labels:"warm · conversational"}]};
 if(path.endsWith("studio/voice")){const result={id:"99999999-9999-4999-8999-999999999999",kind:"voice",state:"completed",url:url("voice.mp3"),voice_name:"Sam",words:[{text:"Bright",start:0,end:.5}],disclosure:"AI generated narration.",duration_s:10};results.unshift(result);return {result};}
 if(path.endsWith("studio/video")){const result={id:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",kind:"video",state:"processing",video_kind:body.kind,label:body.label,disclosure:"This clip was generated with AI.",request_id:"fixture-video-request",provenance_id:provenance,source_asset_id:body.asset_id};results.unshift(result);return {result};}
 if(path.endsWith("studio/video-status")){const result=results.find(r=>r.id===body.result_id);Object.assign(result,{state:"completed",url:url("generated.mp4"),source_url:url("source.png"),asset_id:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",qc_required:true,qc_publishable:false,qc_message:"Review property accuracy before publishing."});return {result:structuredClone(result)};}
 if(path.endsWith("studio/sign-media"))return {result:structuredClone(results.find(r=>r.id===body.result_id))};
 if(path.endsWith("ai-video/drift")){const result=results.find(r=>r.request_id===body.request_id);Object.assign(result,{qc_publishable:true,qc_message:"Property accuracy review passed."});return {drift:{status:"pass",publishable:true,message:"Property accuracy review passed."}};}
 if(path.endsWith("ai-chapters"))return {chapters:[{label:"Entry",start_s:0},{label:"Kitchen",start_s:5}],summary:"Two rooms identified."};
 if(path.endsWith(`/renders/${render}/chapters`))return {ok:true};
 if(path.endsWith("coach"))return {reply:"Start by choosing your best property photos, then use Scripts & shot plans to build a reel.",suggested_replies:["How do I add a voiceover?"]};
 throw new Error(`Unexpected fixture API ${method} ${path}`);
}} as unknown as StudioServices;
function Controls(){return <div style={{padding:16,background:"#14161d"}}><button onClick={()=>{const key=`creative:${listing}`,previous=docs.get(key);docs.set(key,{key,kind:"creative",listing_id:listing,revision:(previous?.revision??0)+1,payload:{...EMPTY_DRAFT,script:"Newer phone script"},updated_at:new Date().toISOString()});}}>Simulate phone edit</button><button onClick={()=>{const node=document.querySelector("#fixture-calls")!;node.textContent=JSON.stringify({calls,docs:[...docs.values()],results,shotHandoffs,agentHandoffs,editorHandoffs});}}>Show fixture receipts</button><pre id="fixture-calls" style={{display:"none"}}/></div>}
function Fixture(){
 const [entryRequest,setEntryRequest]=useState<CreativeEntryRequest>();
 Object.assign(window,{creativeFixture:{
  entry:(tool:CreativeTool,options:{id?:string;listingId?:string;preset?:CreativeEntryRequest["preset"]}={})=>setEntryRequest({id:options.id??crypto.randomUUID(),listingId:options.listingId??listing,tool,preset:options.preset}),
  calls:()=>structuredClone(calls),
 }});
 return <><Controls/><main style={{padding:32}}><CreativeWorkspace services={services} workspace={workspace} listings={listings} entryRequest={entryRequest} onChanged={()=>{}} onOpenEditor={id=>editorHandoffs.push(id)} onUseShotPlan={plan=>shotHandoffs.push(plan)} onUseAgentPlan={plan=>agentHandoffs.push(plan)}/></main></>;
}
createRoot(document.getElementById("root")!).render(<Fixture/>);
