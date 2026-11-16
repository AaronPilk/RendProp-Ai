import {lazy,Suspense,useEffect,useState,type ReactNode} from "react";
import type {CloudEditorProps} from "./CloudEditor";
const MakeVideo=lazy(()=>import("./MakeVideo"));
const AdvancedPropertyReels=lazy(()=>import("./AdvancedPropertyReels"));
type Props=CloudEditorProps&{renderLocalCreation?:(active:boolean,onSwitchBlockChange:(reason:string|null)=>void)=>ReactNode;localCreationHasWork?:boolean;onSelectListing?:(id:string)=>boolean;};

/** Simple creation leads; opening the advanced editor retains its local work. */
export default function PropertyReels(props:Props){
 const [advanced,setAdvanced]=useState(!!(props.importRequest||props.importPlan||props.importAgentPlan));
 const [advancedOpened,setAdvancedOpened]=useState(advanced);
 useEffect(()=>{if(props.importRequest||props.importPlan||props.importAgentPlan){setAdvancedOpened(true);setAdvanced(true);}},[props.importRequest?.id,props.importPlan?.id,props.importAgentPlan?.id]);
 return <div><div className="video-photo-actions"><button aria-pressed={!advanced} onClick={()=>setAdvanced(false)}>Make a video</button><button aria-pressed={advanced} onClick={()=>{setAdvancedOpened(true);setAdvanced(true);}}>Advanced desktop editor</button></div>
  <section hidden={advanced} aria-label="Simple property video"><Suspense fallback={<p role="status">Opening your photo-to-video workspace…</p>}><MakeVideo services={props.services} workspace={props.workspace} listings={props.listings} listingId={props.listingId} active={props.active!==false&&!advanced} readOnly={props.readOnly} onChanged={props.onChanged} onSelectListing={props.onSelectListing}/></Suspense></section>
  {advancedOpened&&<section hidden={!advanced} aria-label="Advanced property video"><Suspense fallback={<p role="status">Opening your saved desktop editor…</p>}><AdvancedPropertyReels {...props} active={props.active!==false&&advanced}/></Suspense></section>}
 </div>;
}
