import { useState } from "react";
import { createRoot } from "react-dom/client";
import CreativeWorkspace from "../src/features/creative/CreativeWorkspace";
import { StudioError } from "../src/data/config";
import type { StudioServices } from "../src/data/services";
import type { Workspace } from "../src/data/contracts";
import type { CloudDocument } from "../src/data/documents";
import "../src/styles.css";
const user="33333333-3333-4333-8333-333333333333",other="33333333-3333-4333-8333-333333333334",org="11111111-1111-4111-8111-111111111111",otherOrg="11111111-1111-4111-8111-111111111112";
let actor=user,activeOrg=org,epoch=1,lose=false,hold=false,release:(()=>void)|undefined;
const subscribers=new Set<(snapshot:unknown)=>void>(),calls:any[]=[],pending:any[]=[];
const documents:Record<string,CloudDocument>=JSON.parse(localStorage.getItem("prompts-fixture-server")??"{}");
const key=()=>`${activeOrg}:${actor}`,persist=()=>localStorage.setItem("prompts-fixture-server",JSON.stringify(documents));
const services={getSnapshot:()=>({status:"signed-in",identityVersion:epoch,identity:{userId:actor,isAnonymous:false}}),subscribe:(fn:(snapshot:unknown)=>void)=>{subscribers.add(fn);return()=>subscribers.delete(fn);},api:async(path:string,options:any)=>{
  const body=structuredClone(options.body),scope=key();calls.push({path,body,actor,org:options.orgId});
  if(calls.length>200)throw new Error("Unexpected request loop");if(options.orgId!==activeOrg)throw new Error("Wrong workspace");
  if(path==="/functions/v1/studio/documents?key=prompts")return{document:structuredClone(documents[scope]??null)};
  if(path!=="/functions/v1/studio/documents"||body.key!=="prompts"||body.kind!=="prompts"||body.listing_id!==undefined)throw new Error("Unexpected API or property scoped write");
  if(hold){hold=false;await new Promise<void>(done=>release=done);release=undefined;}
  if((documents[scope]?.revision??0)!==body.expected_revision)throw new StudioError("revision_conflict","Another device saved",409);
  const document={key:"prompts",kind:"prompts",listing_id:null,revision:body.expected_revision+1,payload:body.payload,updated_at:new Date().toISOString()};documents[scope]=document;persist();
  if(lose){lose=false;throw new Error("Committed, response lost");}return{document:structuredClone(document)};
}} as unknown as StudioServices;
function Fixture(){const[identity,setIdentity]=useState(`${actor}:${activeOrg}`),[visible,setVisible]=useState(true);const workspace:Workspace={user:{id:actor,email:null,name:"Morgan",avatarUrl:null},org:{id:activeOrg,name:"Fixture workspace",handle:null,spaceType:"real_estate"},plan:"starter",planRaw:null,planDegraded:false,trialEndsAt:null,planExpiresAt:null,memberships:[{orgId:activeOrg,role:"admin",orgName:"Fixture workspace",spaceType:"real_estate"}],usage:{listings:0,leads:0,leadsNew:0,renders:0}};
  Object.assign(window,{promptsFixture:{snapshot:()=>structuredClone({documents,calls,pending,actor,org:activeOrg}),lose:()=>lose=true,hold:()=>hold=true,held:()=>!!release,release:()=>release?.(),visible:(value:boolean)=>setVisible(value),remote:(title:string)=>{const doc=documents[key()];if(!doc)throw new Error("No saved document");doc.revision++;(doc.payload as any).entries[0].title=title;(doc.payload as any).entries[0].prompt=`Remote text: ${title}`;persist();},actor:(which:string)=>{actor=which==="other"?other:user;epoch++;subscribers.forEach(fn=>fn(services.getSnapshot()));setIdentity(`${actor}:${activeOrg}`);},workspace:(which:string)=>{activeOrg=which==="other"?otherOrg:org;epoch++;subscribers.forEach(fn=>fn(services.getSnapshot()));setIdentity(`${actor}:${activeOrg}`);}}});
  return <main style={{padding:24}}><div hidden={!visible}><CreativeWorkspace key={identity} services={services} workspace={workspace} listings={[]} onChanged={()=>{}} onPresenterPendingChange={(value,busy)=>pending.push({value,busy})}/></div></main>;
}
createRoot(document.getElementById("root")!).render(<Fixture/>);
