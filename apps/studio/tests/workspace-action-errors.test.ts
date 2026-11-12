import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript-parser";
import { activitySignature, decodeListingState, EMPTY_STATE } from "../src/features/listings/model";
import { earliestExpiry, LINK_RENEW_MS, rememberMedia, retainFreshLinks } from "../src/data/media-cache";
import { confirmsGallerySelection, UnconfirmedGallerySelection } from "../src/features/listings/gallery-selection";

// Execute the actual component's refresh/action closures. No copied error-state
// implementation, DOM shim, production credentials, or network is involved.
const source=readFileSync(new URL("../src/features/listings/ListingWorkflow.tsx",import.meta.url),"utf8");
const ast=ts.createSourceFile("ListingWorkflow.tsx",source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const component=ast.statements.find(n=>ts.isFunctionDeclaration(n)&&n.name?.text==="PropertyWorkspace");
assert(component&&ts.isFunctionDeclaration(component)&&component.body);
function statement(name:string){const node=component.body!.statements.find(n=>ts.isVariableStatement(n)&&n.declarationList.declarations.some(d=>ts.isIdentifier(d.name)&&d.name.text===name));assert(node,`Missing actual ${name} closure`);return node.getText(ast);}
const refreshSource=statement("refresh"),runSource=statement("run");
function harness(){
 const org="20000000-0000-4000-8000-000000000001",listing="30000000-0000-4000-8000-000000000001";
 const ui={actionError:"",readError:"",notice:"",busy:"",uploadingName:"",loading:false,loadFailed:false,states:0};
 let failRead=false;
 const context={
  useCallback:(fn:unknown)=>fn,
  workspace:{org:{id:org},libraryOrgId:org,user:{id:"10000000-0000-4000-8000-000000000001"}},listing:{id:listing},galleryScope:{},
  shownMedia:{current:null as unknown},stateSignature:{current:null as string|null},mediaCacheScope:()=>null,activitySignature,earliestExpiry,LINK_RENEW_MS,retainFreshLinks,rememberMedia,
  load:{current:null},action:{current:null},alive:{current:true},uncertainSelection:{current:null},actionErrorOwner:{current:null},confirmsGallerySelection,UnconfirmedGallerySelection,canWrite:true,EMPTY_STATE,decodeListingState,
  services:{api:async()=>{if(failRead)throw Error("Workspace read failed");return{org_id:org,listing_id:listing,assets:[],jobs:[],renders:[],photos:[],chapters:[],next_offset:null};},listMedia:async()=>({photos:[],videos:[],nextOffset:null,unavailableCount:0})},
  readGallerySelection:async()=>null,message:(reason:unknown)=>reason instanceof Error?reason.message:"Failed",
  setState:()=>{ui.states++;},setMedia:()=>{},setSelection:()=>{},setLoading:(v:boolean)=>{ui.loading=v;},setLoadFailed:(v:boolean)=>{ui.loadFailed=v;},
  setActionError:(v:string|((previous:string)=>string))=>{ui.actionError=typeof v==="function"?v(ui.actionError):v;},setReadError:(v:string)=>{ui.readError=v;},setNotice:(v:string)=>{ui.notice=v;},setBusy:(v:string)=>{ui.busy=v;},setUploadingName:(v:string)=>{ui.uploadingName=v;},
 };
 const program=ts.transpileModule(`${refreshSource}\n${runSource}\nreturn {refresh,run};`,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
 const actual=new Function(...Object.keys(context),program)(...Object.values(context))as{refresh:()=>Promise<void>;run:(name:string,fn:(signal:AbortSignal)=>Promise<void>)=>Promise<void>};
 return{ui,context,...actual,failRead:(v:boolean)=>{failRead=v;}};
}
test("actual action failure clears Verifying and survives successful automatic property refresh",async()=>{
 const h=harness();await h.run("gallery",async()=>{h.ui.notice="Verifying the saved version…";throw Error("Exact copy finish did not return");});
 assert.equal(h.ui.actionError,"Exact copy finish did not return");assert.equal(h.ui.notice,"");assert.equal(h.ui.busy,"");assert.equal(h.context.action.current,null);
 await h.refresh();assert.equal(h.ui.states,1);assert.equal(h.ui.actionError,"Exact copy finish did not return");assert.equal(h.ui.readError,"");
});
test("read failure and later recovery have their own error and never erase an action refusal",async()=>{
 const h=harness();await h.run("gallery",async()=>{throw Error("No longer authorized to finish this copy");});h.failRead(true);await h.refresh();
 assert.equal(h.ui.readError,"Workspace read failed");assert.equal(h.ui.loadFailed,true);assert.equal(h.ui.actionError,"No longer authorized to finish this copy");
 h.failRead(false);await h.refresh();assert.equal(h.ui.readError,"");assert.equal(h.ui.loadFailed,false);assert.equal(h.ui.actionError,"No longer authorized to finish this copy");
});
test("the next explicit action clears only its old action error; aborted or unmounted work cannot install a late error",async()=>{
 const h=harness();h.ui.readError="Separate read failure";h.ui.actionError="Old action failure";
 await h.run("gallery",async()=>{assert.equal(h.ui.actionError,"");assert.equal(h.ui.readError,"Separate read failure");});
 await h.run("gallery",async signal=>{(h.context.action.current as unknown as AbortController).abort();assert(signal.aborted);throw Error("Late cancelled failure");});assert.equal(h.ui.actionError,"");
 h.context.alive.current=false;await h.run("gallery",async()=>{throw Error("Late unmounted failure");});assert.equal(h.ui.actionError,"");
});

test("automatic refresh signs media again only when saved activity changed or the links on screen are aging",async()=>{
 const h=harness(),org=h.context.workspace.org.id,listing=h.context.listing.id,services=h.context.services as Record<string,unknown>;
 const refresh=h.refresh as (showLoading?:boolean,automatic?:boolean)=>Promise<void>;
 let reads=0,assets:unknown[]=[];
 const photo=()=>({id:"40000000-0000-4000-8000-000000000001",listingId:listing,url:`https://media.example.invalid/a.jpg?signature=${reads}`,expiresAt:new Date(Date.now()+600_000).toISOString(),caption:null,isStaged:false,sort:0});
 services.api=async()=>({org_id:org,listing_id:listing,assets,jobs:[],renders:[],photos:[],chapters:[],next_offset:null});
 services.listMedia=async()=>{reads++;return{orgId:org,listingId:listing,photos:[photo()],videos:[],nextOffset:null,unavailableCount:0};};
 await refresh(true);assert.equal(reads,1);
 await refresh(false,true);assert.equal(reads,1,"nothing changed: the timer read must not sign the gallery again");
 await refresh();assert.equal(reads,2,"an action or the Refresh button always reads media");
 const shown=h.context.shownMedia.current as {photos:{url:string}[]};
 assert.equal(shown.photos[0].url,"https://media.example.invalid/a.jpg?signature=1","a still-good link stays on screen so the photo is not downloaded twice");
 assets=[{id:"40000000-0000-4000-8000-000000000002",listing_id:listing,storage_key:`uploads/${org}/${listing}/b.jpg`,kind:"photo",bucket:"uploads",uploaded:true,duration_s:null,created_at:"2026-11-12T00:00:00Z"}];
 await refresh(false,true);assert.equal(reads,3,"a photo saved from the phone is picked up by the next timer read");
 await refresh(false,true);assert.equal(reads,3);
 h.context.shownMedia.current={...shown,photos:[{...shown.photos[0],expiresAt:new Date(Date.now()+120_000).toISOString()}]};
 await refresh(false,true);assert.equal(reads,4,"links close to expiry are renewed before they break");
 assert.equal((h.context.shownMedia.current as {photos:{url:string}[]}).photos[0].url,"https://media.example.invalid/a.jpg?signature=4");
 assert.equal(h.ui.readError,"");assert.equal(h.ui.loadFailed,false);
});
