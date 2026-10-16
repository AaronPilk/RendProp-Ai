import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript-parser";
import { decodeListingState, EMPTY_STATE } from "../src/features/listings/model";

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
  load:{current:null},action:{current:null},alive:{current:true},canWrite:true,EMPTY_STATE,decodeListingState,
  services:{api:async()=>{if(failRead)throw Error("Workspace read failed");return{org_id:org,listing_id:listing,assets:[],jobs:[],renders:[],photos:[],chapters:[],next_offset:null};},listMedia:async()=>({photos:[],videos:[],nextOffset:null,unavailableCount:0})},
  readGallerySelection:async()=>null,message:(reason:unknown)=>reason instanceof Error?reason.message:"Failed",
  setState:()=>{ui.states++;},setMedia:()=>{},setSelection:()=>{},setLoading:(v:boolean)=>{ui.loading=v;},setLoadFailed:(v:boolean)=>{ui.loadFailed=v;},
  setActionError:(v:string)=>{ui.actionError=v;},setReadError:(v:string)=>{ui.readError=v;},setNotice:(v:string)=>{ui.notice=v;},setBusy:(v:string)=>{ui.busy=v;},setUploadingName:(v:string)=>{ui.uploadingName=v;},
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
