import {useEffect,useMemo,useState} from "react";
import type {StudioServices,Workspace} from "../../data";
import type {VideoEditorProps} from "../../editor/VideoEditor";
import {buildEditPlanRequest} from "./edit-plan-request";

/** Text assistance is available to signed-in local creations too. A property is
 * optional; selecting one only adds authorization and property-copy context. */
export function useEditingAssistant(services:StudioServices|null,workspace:Workspace|null,active:boolean,listingId?:string){
  const scope=workspace?`${workspace.user.id}:${workspace.org.id}`:"";
  const activation=useMemo(()=>({}),[services,scope,active]);
  const [capability,setCapability]=useState<{activation:object|null;edit:boolean;enhance:boolean}>({activation:null,edit:false,enhance:false});
  useEffect(()=>{
    if(!services||!workspace||!active)return;
    const abort=new AbortController();
    const read=async(path:string)=>{
      try{return (await services.api(`/functions/v1/studio/${path}`,{orgId:workspace.org.id,signal:abort.signal}) as {available?:unknown})?.available===true;}
      catch{return false;}
    };
    void Promise.all([read("edit-plan"),read("prompt-enhancement")]).then(([edit,enhance])=>{if(!abort.signal.aborted)setCapability({activation,edit,enhance});});
    return ()=>abort.abort();
  },[services,workspace?.user.id,workspace?.org.id,active,activation]);
  const current=active&&scope!==""&&capability.activation===activation;
  const editAssistAvailable=current&&capability.edit,promptEnhanceAvailable=current&&capability.enhance;
  const request=(path:"edit-plan"|"prompt-enhancement",available:boolean):NonNullable<VideoEditorProps["requestEditPlan"]>=>async(message,draft,history,signal)=>{
    if(!available||!services||!workspace||!active)throw new Error("This text assistant is not enabled in your workspace.");
    return services.api(`/functions/v1/studio/${path}`,{method:"POST",orgId:workspace.org.id,idempotencyKey:crypto.randomUUID(),signal,timeoutMs:45000,body:buildEditPlanRequest(draft,message,history,listingId)});
  };
  return {editAssistAvailable,promptEnhanceAvailable,requestEditPlan:request("edit-plan",editAssistAvailable),requestPromptEnhancement:request("prompt-enhancement",promptEnhanceAvailable)};
}
