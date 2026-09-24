import {useEffect,useRef,useState} from "react";
import type {Listing,ListingMedia,StudioServices,Workspace} from "../../data";
import {canonicalDocument,DocumentSync,type SyncState} from "../../data/documents";
import {scopeKey} from "../../workspace";
import SyncStatus from "../sync/SyncStatus";
import {changeProductionFormat,decodeProductionPlan,FORMATS,newProductionPlan,planProgress,type ProductionPlan,type ProductionRecipe,type ProductionShot} from "./model";
import "./production.css";

export default function CapturePlan({services,workspace,listing,onPlan,onPrepareSwitch}:{services:StudioServices;workspace:Workspace;listing:Listing;onPlan?:(plan:ProductionPlan)=>void;onPrepareSwitch?:(prepare:(()=>Promise<void>)|null)=>void}) {
  const [plan,setPlan]=useState<ProductionPlan>(),[state,setState]=useState<SyncState>("loading"),[error,setError]=useState(""),[attempt,setAttempt]=useState(0),[expanded,setExpanded]=useState(false);
  const [backup,setBackup]=useState<ProductionPlan>(),[media,setMedia]=useState<ListingMedia>(),[mediaBusy,setMediaBusy]=useState(false),[mediaError,setMediaError]=useState("");
  const sync=useRef<DocumentSync|null>(null),current=useRef<ProductionPlan|undefined>(undefined),abort=useRef(new AbortController()),onPlanRef=useRef(onPlan);onPlanRef.current=onPlan;
  const canEdit=["owner","admin","agent"].includes(workspace.memberships.find(member=>member.orgId===workspace.org.id)?.role??"");
  const localKey=`${scopeKey(workspace.user.id,workspace.org.id)}:production:${listing.id}`;
  useEffect(()=>{
    const controller=new AbortController();abort.current=controller;
    const writer=new DocumentSync(services,workspace.org.id,`production:${listing.id}`,setState);sync.current=writer;
    setPlan(undefined);setBackup(undefined);setError("");setMedia(undefined);current.current=undefined;
    onPrepareSwitch?.(async()=>{
      if(controller.signal.aborted)throw new Error("This capture plan has closed.");
      await writer.flush();
      if(writer.hasUnsavedWork)throw new Error("Finish syncing your capture plan before switching properties. Retry saving or resolve the newer cloud version first.");
    });
    const unload=(event:BeforeUnloadEvent)=>{if(writer.hasUnsavedWork){event.preventDefault();event.returnValue="";}};
    const focus=()=>{if(document.visibilityState==="visible")void writer.checkRemote();};
    window.addEventListener("beforeunload",unload);window.addEventListener("focus",focus);
    void writer.open().then(doc=>{
      if(controller.signal.aborted)return;
      const saved=doc?decodeProductionPlan(doc.payload,listing.id):newProductionPlan(listing.id);
      let recovered:ProductionPlan|undefined;
      try {const raw=localStorage.getItem(localKey);if(raw)recovered=decodeProductionPlan(JSON.parse(raw),listing.id);}
      catch {setError("The browser copy could not be read. Your cloud plan is unchanged.");}
      if(recovered&&canonicalDocument(recovered)!==canonicalDocument(saved))setBackup(recovered);
      current.current=saved;setPlan(saved);onPlanRef.current?.(saved);
    }).catch(reason=>{if(!controller.signal.aborted)setError(reason instanceof Error?reason.message:"Your capture plan could not be opened.");});
    return()=>{onPrepareSwitch?.(null);controller.abort();writer.dispose();window.removeEventListener("beforeunload",unload);window.removeEventListener("focus",focus);};
  },[services,workspace.org.id,listing.id,localKey,attempt,onPrepareSwitch]);
  function update(next:ProductionPlan){
    if(!canEdit)return;
    let valid:ProductionPlan;
    try {valid=decodeProductionPlan(next,listing.id);}
    catch(reason){setError(reason instanceof Error?reason.message:"The capture plan could not be saved.");return;}
    current.current=valid;setPlan(valid);onPlanRef.current?.(valid);setError("");
    try {localStorage.setItem(localKey,JSON.stringify(valid));}
    catch {setError("The browser backup is unavailable. Keep this page open until cloud saving finishes.");}
    sync.current?.queue(valid);
  }
  function editShot(id:string,patch:Partial<ProductionShot>){if(current.current)update({...current.current,shots:current.current.shots.map(shot=>shot.id===id?{...shot,...patch}:shot)});}
  async function loadMedia(){
    if(mediaBusy)return;const signal=abort.current.signal;setMediaBusy(true);setMediaError("");
    try {const page=await services.listMedia(workspace.org.id,listing.id,signal,media?.nextOffset??0);if(signal.aborted)return;setMedia(old=>old?{...page,photos:[...old.photos,...page.photos],videos:[...old.videos,...page.videos]}:page);}
    catch(reason){if(!signal.aborted)setMediaError(reason instanceof Error?reason.message:"Media could not be loaded.");}
    finally{if(!signal.aborted)setMediaBusy(false);}
  }
  const progress=plan?planProgress(plan):null,locked=!plan||state==="conflict"||!canEdit;
  return <section className="production-panel" aria-label="Capture plan">
    <header className="production-heading"><div><h2>Start with a clear plan</h2><p>Choose the video you want. This checklist follows the same property between your phone and Studio.</p></div><SyncStatus state={state} retry={()=>{if(plan)void sync.current?.retry();else setAttempt(value=>value+1);}} reload={()=>setAttempt(value=>value+1)}/></header>
    {error&&<p role="alert">{error}</p>}{!canEdit&&<p className="muted">Your workspace role can read this plan. An agent or administrator can change it.</p>}
    {backup&&<div className="notice"><p>A different browser copy is preserved. Review it before replacing the cloud plan.</p><p>{FORMATS.find(item=>item.id===backup.recipe)?.title} · {planProgress(backup).covered} recorded shots marked</p><button disabled={locked} onClick={()=>{update(backup);setBackup(undefined);}}>Use browser plan</button><button onClick={()=>{try{if(plan)localStorage.setItem(localKey,JSON.stringify(plan));setBackup(undefined);}catch{setError("Browser storage is unavailable. The previous copy is still preserved.");}}}>Keep cloud plan</button></div>}
    {plan&&<>
      <div className="production-formats">{FORMATS.map(format=><button className="production-format" key={format.id} aria-pressed={plan.recipe===format.id} disabled={locked} onClick={()=>{try{update(changeProductionFormat(plan,format.id as ProductionRecipe));}catch(reason){setError((reason as Error).message);}}}><strong>{format.title}</strong><span>{format.description}</span></button>)}</div>
      <div className="production-settings"><label>How will you tell the story?<select value={plan.presentation} disabled={locked} onChange={event=>update({...plan,presentation:event.target.value as ProductionPlan["presentation"]})}><option value="music">Property visuals · no speaking</option><option value="voiceover">Record a voiceover</option><option value="on-camera">Speak on camera</option></select></label><label>Target length<select disabled={locked} value={plan.targetSeconds} onChange={event=>update({...plan,targetSeconds:Number(event.target.value) as ProductionPlan["targetSeconds"]})}><option value={30}>30 seconds</option><option value={45}>45 seconds</option><option value={60}>60 seconds</option></select></label></div>
      <div><strong>{progress!.covered} of {progress!.required} required shots marked captured</strong><progress aria-label="Capture checklist progress" value={progress!.covered} max={Math.max(1,progress!.required)}/><p className="muted">Your checklist records what you have captured. It does not certify focus, sound or completed uploads. {progress!.linked} shots have uploaded media linked.</p></div>
      <div className="production-actions"><button aria-expanded={expanded} onClick={()=>setExpanded(value=>!value)}>{expanded?"Hide shot checklist":"Open shot checklist"}</button><button disabled={mediaBusy||media?.nextOffset===null} onClick={()=>void loadMedia()}>{mediaBusy?"Loading property media…":media?"Load more property media":"Link uploaded photos & videos"}</button>{media&&<span className="muted">{media.photos.length} photos · {media.videos.length} videos loaded</span>}</div>
      {mediaError&&<p role="alert">{mediaError}</p>}
      {expanded&&<div className="production-shots">{plan.shots.map(shot=><article className="production-shot" key={shot.id}><header><h3>{shot.title}</h3><span className="production-tag">{shot.required?"Suggested essential":"Optional"}</span></header><p>{shot.guidance}</p><label>Shot status<select aria-label={`${shot.title} status`} disabled={locked} value={shot.status} onChange={event=>editShot(shot.id,{status:event.target.value as ProductionShot["status"]})}><option value="needed">Still needed</option><option value="captured">I captured this</option><option value="not-needed">Not needed for this video</option></select></label><label>Notes<textarea aria-label={`${shot.title} notes`} value={shot.notes} maxLength={500} disabled={locked} onChange={event=>editShot(shot.id,{notes:event.target.value})}/></label>{media&&<details><summary>Link uploaded media ({shot.sourcePhotoIds.length+shot.sourceVideoIds.length})</summary>{[...media.photos.map((item,index)=>({id:item.id,label:item.caption||`Photo ${index+1}`,kind:"photo" as const})),...media.videos.map((item,index)=>({id:item.id,label:`Video ${index+1}${item.durationSeconds?` · ${Math.round(item.durationSeconds)}s`:""}`,kind:"video" as const}))].map(item=>{const field=item.kind==="photo"?"sourcePhotoIds":"sourceVideoIds",selected=shot[field].includes(item.id);return <label key={`${item.kind}:${item.id}`}><input type="checkbox" disabled={locked||(!selected&&shot[field].length>=12)} checked={selected} onChange={()=>editShot(shot.id,{[field]:selected?shot[field].filter(id=>id!==item.id):[...shot[field],item.id]})}/>{item.label}</label>;})}</details>}</article>)}</div>}
      <label>Brief for the edit<textarea maxLength={2000} disabled={locked} value={plan.notes} placeholder="What should viewers remember? Include verified facts and any editing preferences." onChange={event=>update({...plan,notes:event.target.value})}/></label>
    </>}
  </section>;
}
