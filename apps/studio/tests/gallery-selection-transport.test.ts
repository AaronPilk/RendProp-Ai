import assert from "node:assert/strict";
import test from "node:test";
import type { Session, AuthChangeEvent } from "@supabase/auth-js";
import { readFileSync } from "node:fs";
import ts from "typescript-parser";
import { createStudioServices, type StudioAuth } from "../src/data/services";
import { changeListingSelection, confirmsGallerySelection, UnconfirmedGallerySelection, readGallerySelection } from "../src/features/listings/gallery-selection";
import { decodeListingState, EMPTY_STATE } from "../src/features/listings/model";

const ACTOR="10000000-0000-4000-8000-000000000001",OTHER_ACTOR="10000000-0000-4000-8000-000000000002";
const LIBRARY="20000000-0000-4000-8000-000000000001",ORG="20000000-0000-4000-8000-000000000002",OTHER_LIBRARY="20000000-0000-4000-8000-000000000003";
const LISTING="30000000-0000-4000-8000-000000000001",PHOTO="40000000-0000-4000-8000-000000000001",ASSET="50000000-0000-4000-8000-000000000001";
const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers:{"Content-Type":"application/json"}});
type Mode="lost-reply"|"refresh-reply"|"403"|"409"|"qc"|"failed-read"|"library-switch"|"actor-returned"|"caller-abort"|"listing-removed";
function fixture(mode:Mode){
 let user=ACTOR,version=0,callback:(event:AuthChangeEvent,next:Session|null)=>void=()=>{},selected=LIBRARY;
 const session=():Session=>({access_token:"OFFLINE-CLOSED-TOKEN",refresh_token:"OFFLINE-CLOSED-REFRESH",expires_in:3600,token_type:"bearer",user:{id:user,aud:"authenticated",created_at:"2026-10-16T00:00:00Z",app_metadata:{},user_metadata:{}}});
 const auth:StudioAuth={getSession:async()=>({data:{session:session()},error:null}),refreshSession:async()=>({data:{session:session()},error:null}),signInWithOAuth:async()=>({error:null}),signOut:async()=>({error:null}),onAuthStateChange:cb=>{callback=cb;return{data:{subscription:{unsubscribe(){}}}};}};
 const scope={actor:ACTOR,org:ORG,library:LIBRARY,listing:LISTING},caller=new AbortController();
 let ids:string[]=[],reads=0,patches=0,mappingReads=0,failNextRead=false,mappedListing=LISTING;
 const snapshot=()=>({schema:1 as const,actor_id:user,org_id:ORG,library_org_id:LIBRARY,listing_id:LISTING,gallery_asset_ids:[...ids],main_photo_key:null,effective_asset_ids:[...ids],photo_order:[PHOTO],photos:[{photo_id:PHOTO,asset_id:ASSET,selected:ids.includes(ASSET),can_use:true,review_required:false}]});
 const calls:Array<{path:string;method:string;body:any;headers:Headers}>=[];
 const services=createStudioServices({supabaseUrl:"https://closed-selection.supabase.co",publishableKey:"sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY",redirectTo:"http://localhost:5173/"},{auth,fetch:async(input,options={})=>{
  const url=new URL(String(input)),method=options.method??"GET",body=typeof options.body==="string"?JSON.parse(options.body):null,headers=new Headers(options.headers);calls.push({path:url.pathname,method,body,headers});
  if(url.pathname.endsWith("/me/workspaces"))return json({actor_id:user,own_org_id:LIBRARY,billing_org_id:LIBRARY,active_org_id:selected,can_switch_agent_libraries:true,workspaces:[{id:LIBRARY,name:"Own",role:"owner",access_mode:"own",library_owner_user_id:user,billing_org_id:LIBRARY,can_read:true,can_write:true,can_manage_subscription:true},{id:OTHER_LIBRARY,name:"Other",role:"team_owner",access_mode:"team_owner",library_owner_user_id:OTHER_ACTOR,billing_org_id:LIBRARY,can_read:true,can_write:true,can_manage_subscription:false}]});
  if(url.pathname==="/functions/v1/me"){selected=headers.get("X-Org-Id")!;return json({user:{id:user,email:null,name:null,avatar_url:null},org:{id:selected,name:"Library",space_type:"real_estate",handle:null},billing:{org_id:LIBRARY,content_org_id:selected,serving_org_id:LIBRARY,role:"owner",can_manage_subscription:true},plan:"free",plan_raw:"free",trial_ends_at:null,plan_expires_at:null,usage:{listings:1,leads:0,leads_new:0,renders:0}});}
  if(url.pathname==="/functions/v1/listings"){mappingReads++;return json({actor_id:user,listings:[{id:mappedListing,org_id:ORG,library_org_id:selected,space_type:"real_estate",address:"Closed fixture",tagline:null,details:{},status:"draft",created_at:"2026-10-16T00:00:00Z",deleted_at:null,main_photo_key:null,beds:null,baths:null,sqft:null,price_cents:null}],total:1,next_offset:null});}
  if(url.pathname==="/functions/v1/studio/photos"&&method==="GET"){reads++;if(failNextRead){failNextRead=false;throw new TypeError("Closed lost read");}return json(snapshot());}
  if(url.pathname==="/functions/v1/studio/listing-state")return json({org_id:ORG,listing_id:LISTING,assets:[],jobs:[],renders:[],photos:[],chapters:[],next_offset:null});
  if(url.pathname==="/functions/v1/studio/media")return json({org_id:ORG,listing_id:LISTING,photos:[],videos:[],next_offset:null,unavailable_count:0});
  if(url.pathname==="/functions/v1/studio/photos"&&method==="PATCH"){
   patches++;assert.deepEqual(body,{listing_id:LISTING,action:"use",photo_id:PHOTO,reviewed:false,expected_selection:{gallery_asset_ids:[],main_photo_key:null}});
   if(mode==="403"||mode==="409")return json({},Number(mode));if(mode==="qc")return json({code:"photo_quality_hold",error:"Accuracy review is required."},400);
   ids=[ASSET];
   if(mode==="refresh-reply"){await services.loadWorkspace(undefined,LIBRARY);return json({...snapshot(),ok:true,action:"use",photo_id:PHOTO});}
   if(mode==="listing-removed"){mappedListing="30000000-0000-4000-8000-000000000002";await services.loadWorkspace(undefined,LIBRARY);}
   if(mode==="library-switch")await services.loadWorkspace(undefined,OTHER_LIBRARY);
   if(mode==="actor-returned"){user=OTHER_ACTOR;callback("SIGNED_IN",session());user=ACTOR;callback("SIGNED_IN",session());}
   if(mode==="caller-abort")caller.abort();if(mode==="failed-read")failNextRead=true;
   throw new TypeError("Closed lost PATCH reply");
  }
  throw new Error("Unexpected closed selection transport");
 }});
 return{services,scope,caller,calls,snapshot,counts:()=>({reads,patches,mappingReads}),setIds:(next:string[])=>{ids=[...next];},async switchLibrary(){await services.loadWorkspace(undefined,OTHER_LIBRARY);await services.listListings(OTHER_LIBRARY);},async returnActor(){user=OTHER_ACTOR;callback("SIGNED_IN",session());user=ACTOR;callback("SIGNED_IN",session());await services.loadWorkspace(undefined,LIBRARY);await services.listListings(LIBRARY);},async open(){await services.loadWorkspace(undefined,LIBRARY);await services.listListings(LIBRARY);version=services.getSnapshot().identityVersion;},version:()=>version};
}
for(const mode of["lost-reply","refresh-reply"]as const)test(`actual selection ${mode} confirms committed effect by GET without a second PATCH`,async()=>{
 const f=fixture(mode);try{await f.open();const result=await changeListingSelection(f.services,f.scope,f.snapshot(),{action:"use",photo_id:PHOTO,reviewed:false},f.caller.signal);
  assert.deepEqual(result.gallery_asset_ids,[ASSET]);assert.equal(result.photos[0].selected,true);assert.equal(result.main_photo_key,null);assert.equal(f.counts().patches,1);assert.equal(f.counts().reads,2);assert.equal(f.counts().mappingReads,mode==="refresh-reply"?2:1);assert(f.calls.filter(c=>c.path.endsWith("/photos")).every(c=>c.headers.get("X-Org-Id")===ORG));
 }finally{f.services.dispose();}
});

for(const mode of["403","409","qc"]as const)test(`actual definite ${mode} selection refusal is preserved without reconciliation GET`,async()=>{
 const f=fixture(mode);try{await f.open();await assert.rejects(changeListingSelection(f.services,f.scope,f.snapshot(),{action:"use",photo_id:PHOTO,reviewed:false}),error=>error instanceof Error&&!(error instanceof UnconfirmedGallerySelection));assert.equal(f.counts().patches,1);assert.equal(f.counts().reads,1);assert.deepEqual(f.snapshot().gallery_asset_ids,[]);}finally{f.services.dispose();}
});
for(const mode of["failed-read","library-switch","actor-returned","caller-abort","listing-removed"]as const)test(`actual ${mode} cannot turn an ambiguous PATCH into confirmed success`,async()=>{
 const f=fixture(mode);try{await f.open();await assert.rejects(changeListingSelection(f.services,f.scope,f.snapshot(),{action:"use",photo_id:PHOTO,reviewed:false},f.caller.signal));assert.equal(f.counts().patches,1);assert.deepEqual(f.snapshot().gallery_asset_ids,[ASSET]);assert.equal(f.counts().reads,mode==="failed-read"?2:1);}finally{f.services.dispose();}
});

const source=readFileSync(new URL("../src/features/listings/ListingWorkflow.tsx",import.meta.url),"utf8"),ast=ts.createSourceFile("ListingWorkflow.tsx",source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const component=ast.statements.find(n=>ts.isFunctionDeclaration(n)&&n.name?.text==="PropertyWorkspace");assert(component&&ts.isFunctionDeclaration(component)&&component.body);
function actualStatement(name:string){const node=component.body!.statements.find(n=>ts.isVariableStatement(n)&&n.declarationList.declarations.some(d=>ts.isIdentifier(d.name)&&d.name.text===name));assert(node,`Missing actual ${name}`);return node.getText(ast);}
function componentHarness(f:ReturnType<typeof fixture>){
 const ui={actionError:"",readError:"",notice:"",busy:"",selection:f.snapshot()as ReturnType<typeof f.snapshot>|null};
 const context={services:f.services,workspace:{user:{id:ACTOR},org:{id:ORG},libraryOrgId:LIBRARY},listing:{id:LISTING},galleryScope:f.scope,selection:f.snapshot(),useCallback:(fn:unknown)=>fn,load:{current:null},action:{current:null},alive:{current:true},uncertainSelection:{current:null as UnconfirmedGallerySelection|null},actionErrorOwner:{current:null as unknown},canWrite:true,EMPTY_STATE,decodeListingState,changeListingSelection,confirmsGallerySelection,UnconfirmedGallerySelection,readGallerySelection,
  message:(error:unknown)=>error instanceof Error?error.message:"Failed",setState:()=>{},setMedia:()=>{},setLoading:()=>{},setLoadFailed:()=>{},setSelection:(value:any)=>{ui.selection=value;},setReadError:(value:string)=>{ui.readError=value;},setActionError:(value:string|((previous:string)=>string))=>{ui.actionError=typeof value==="function"?value(ui.actionError):value;},setNotice:(value:string)=>{ui.notice=value;},setBusy:(value:string)=>{ui.busy=value;},setUploadingName:()=>{},onChanged:()=>{}};
 const program=ts.transpileModule(`${actualStatement("refresh")}\n${actualStatement("run")}\n${actualStatement("selectPhoto")}\nreturn{refresh,run,selectPhoto};`,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
 const actual=new Function(...Object.keys(context),program)(...Object.values(context))as{refresh:()=>Promise<void>;run:(name:string,work:(signal:AbortSignal)=>Promise<void>)=>Promise<void>;selectPhoto:(body:{action:"use";photo_id:string;reviewed:boolean},success:string)=>Promise<void>};
 return{ui,context,...actual};
}
for(const mode of["lost-reply","refresh-reply"]as const)test(`actual component ${mode} installs verified selection and success with only one PATCH`,async()=>{
 const f=fixture(mode);try{await f.open();const h=componentHarness(f);await h.selectPhoto({action:"use",photo_id:PHOTO,reviewed:false},"Photo selected.");assert.equal(h.ui.actionError,"");assert.equal(h.ui.readError,"");assert.equal(h.ui.notice,"Photo selected.");assert.deepEqual(h.ui.selection?.gallery_asset_ids,[ASSET]);assert.equal(f.counts().patches,1);}finally{f.services.dispose();}
});
test("actual component later explicit refresh clears only its matching uncertainty after failed reconciliation GET",async()=>{
 const f=fixture("failed-read");try{await f.open();const h=componentHarness(f);await h.selectPhoto({action:"use",photo_id:PHOTO,reviewed:false},"Photo selected.");assert.match(h.ui.actionError,/may have been saved/);assert(h.context.uncertainSelection.current instanceof UnconfirmedGallerySelection);assert.equal(h.ui.notice,"");assert.equal(f.counts().patches,1);
  await h.refresh();assert.equal(h.ui.actionError,"");assert.equal(h.ui.readError,"");assert.equal(h.ui.notice,"Your listing photo selection is verified.");assert.equal(h.context.uncertainSelection.current,null);assert.deepEqual(h.ui.selection?.gallery_asset_ids,[ASSET]);assert.equal(f.counts().patches,1);
 }finally{f.services.dispose();}
});
for(const mode of["403","409","qc"]as const)test(`actual component healthy refresh never erases its definite ${mode} refusal`,async()=>{
 const f=fixture(mode);try{await f.open();const h=componentHarness(f);await h.selectPhoto({action:"use",photo_id:PHOTO,reviewed:false},"Photo selected.");const failure=h.ui.actionError;assert(failure);assert.equal(h.context.uncertainSelection.current,null);await h.refresh();assert.equal(h.ui.actionError,failure);assert.equal(h.ui.notice,"");assert.equal(f.counts().patches,1);}finally{f.services.dispose();}
});
for(const fault of["different-selection","actor-returned","library-switched","different-error"]as const)test(`actual component ${fault} cannot clear a previous selection uncertainty`,async()=>{
 const f=fixture("failed-read");try{await f.open();const h=componentHarness(f);await h.selectPhoto({action:"use",photo_id:PHOTO,reviewed:false},"Photo selected.");const warning=h.ui.actionError;
  if(fault==="different-selection")f.setIds([ASSET,"50000000-0000-4000-8000-000000000002"]);else if(fault==="actor-returned")await f.returnActor();else if(fault==="library-switched")await f.switchLibrary();else{h.ui.actionError="Different definite refusal";h.context.actionErrorOwner.current=new Error(h.ui.actionError);}
  await h.refresh();assert.equal(h.ui.actionError,fault==="different-error"?"Different definite refusal":warning);assert.equal(h.ui.notice,"");assert.equal(f.counts().patches,1);
 }finally{f.services.dispose();}
});
