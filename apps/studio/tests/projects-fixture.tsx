import {createRoot} from "react-dom/client";
import {useMemo,useState} from "react";
import Projects from "../src/features/projects/Projects";
import {StudioError} from "../src/data/config";
import type {StudioServices,Workspace} from "../src/data";
import "../src/styles.css";
const ORG="22222222-2222-4222-8222-222222222222",A="11111111-1111-4111-8111-111111111111",B="33333333-3333-4333-8333-333333333333";
function Fixture(){
 const [actor,setActor]=useState(new URLSearchParams(location.search).get("actor")==="B"?B:A);
 const scope=`fixture:${actor}:${ORG}`;
 const services=useMemo(()=>({api:async(path:string,options:any)=>{
  const response=await fetch(`/fixture${path.slice("/functions/v1/studio".length)}`,{method:options.method??"GET",signal:options.signal,headers:{"X-Fixture-Actor":actor,"X-Fixture-Org":options.orgId,"Content-Type":options.binary?"application/octet-stream":"application/json"},body:options.binary??(options.body===undefined?undefined:JSON.stringify(options.body))});
  if(!response.ok)throw new StudioError("fixture",(await response.json()).error??"Fixture failure",response.status);return response.json();
 }}) as StudioServices,[actor]);
 const workspace={user:{id:actor},org:{id:ORG},memberships:[{orgId:ORG,role:new URLSearchParams(location.search).get("role")==="marketing"?"marketing":"owner"}]} as Workspace;
 let draft;try{draft=JSON.parse(localStorage.getItem(`${scope}:scratch`)??"null")??undefined;}catch{}
 return <main style={{padding:20}}><button onClick={()=>setActor(actor===A?B:A)}>Switch fixture account</button><p>Fixture account {actor===A?"A":"B"}</p>
  <Projects key={scope} services={services} workspace={workspace} storageScope={scope} initialDraft={draft} initialMode="conversation" onDraftChange={value=>localStorage.setItem(`${scope}:scratch`,JSON.stringify(value))}/>
 </main>;
}
createRoot(document.getElementById("root")!).render(<Fixture/>);
