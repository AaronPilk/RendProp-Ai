import {useEffect,useRef,useState} from "react";
import type {StudioServices,Workspace} from "../../data";
import {draftMedia,formatTime,timelineDuration} from "../../editor/model";
import {reelPayload} from "../sync/property-reels";
import {canCopyVersion,decodeVersionPage,decodeVersionSnapshot,versionPath,type SavedVersion,type VersionChoice,type VersionSnapshot} from "./versions";
import ProductionBrief from "./ProductionBrief";

export function CopyVersion({choice,own,onCopy,disabled=false}:{choice:VersionChoice;own:boolean;onCopy:(choice:VersionChoice)=>void;disabled?:boolean}){
  return <button disabled={disabled} onClick={()=>onCopy(choice)}>{own?"Restore this saved version":"Copy into my editable reel"}</button>;
}
export default function VersionHistory({services,workspace,listingId,authorId=workspace.user.id,onCopy}:{services:StudioServices;workspace:Workspace;listingId:string;authorId?:string;onCopy:(choice:VersionChoice)=>void}){
  const [open,setOpen]=useState(false),[rows,setRows]=useState<SavedVersion[]>([]),[offset,setOffset]=useState<number|null>(0),[snapshot,setSnapshot]=useState<VersionSnapshot>(),[busy,setBusy]=useState(false),[error,setError]=useState("");
  const controller=useRef(new AbortController()),request=useRef(0),flight=useRef(false);
  useEffect(()=>{const abort=new AbortController();controller.current=abort;setRows([]);setOffset(0);setSnapshot(undefined);setOpen(false);setBusy(false);flight.current=false;return()=>{abort.abort();request.current++;};},[services,workspace.org.id,workspace.user.id,listingId,authorId]);
  async function load(next=0){
    if(flight.current)return;flight.current=true;const signal=controller.current.signal,operation=++request.current;setBusy(true);setError("");
    try{const page=decodeVersionPage(await services.api(versionPath("versions",{listingId,authorId},next),{orgId:workspace.org.id,signal}),workspace.org.id,{listingId,authorId},next);if(signal.aborted||operation!==request.current)return;setRows(old=>next===0?page.versions:[...old,...page.versions.filter(row=>!old.some(item=>item.document_revision===row.document_revision))]);setOffset(page.nextOffset);}
    catch(reason){if(!signal.aborted&&operation===request.current)setError(reason instanceof Error?reason.message:"Version history is unavailable.");}
    finally{if(operation===request.current){flight.current=false;if(!signal.aborted)setBusy(false);}}
  }
  async function select(version:SavedVersion){
    if(flight.current)return;flight.current=true;const signal=controller.current.signal,operation=++request.current;setBusy(true);setError("");setSnapshot(undefined);
    try{const choice={listingId,authorId,revision:version.document_revision};const next=decodeVersionSnapshot(await services.api(versionPath("version",choice),{orgId:workspace.org.id,signal}),workspace.org.id,choice);if(!signal.aborted&&operation===request.current)setSnapshot(next);}
    catch(reason){if(!signal.aborted&&operation===request.current)setError(reason instanceof Error?reason.message:"This saved version is unavailable.");}
    finally{if(operation===request.current){flight.current=false;if(!signal.aborted)setBusy(false);}}
  }
  const draft=snapshot?reelPayload(snapshot.document.payload,listingId).draft:undefined;
  return <section className="production-panel" aria-label="Saved version history"><header className="production-heading"><div><h2>Saved versions</h2><p>Submitted versions and the saved edit preserved before a replacement stay available here.</p></div><button aria-expanded={open} disabled={busy} onClick={()=>{setOpen(value=>!value);if(!open)void load();}}>{open?"Close saved versions":"Open saved versions"}</button></header>
    {open&&<><button disabled={busy} onClick={()=>void load()}>Refresh saved versions</button>{busy&&<p role="status">Opening saved versions…</p>}{error&&<p role="alert">{error}</p>}{!rows.length&&!busy&&!error&&<p>No archived versions yet. Sending an edit for review saves its version here.</p>}
      <ol className="production-review-events">{rows.map(version=><li key={version.id}><strong>Version {version.document_revision}</strong> · {version.reason==="submitted"?"Submitted for review":"Preserved before replacement"} · {new Date(version.created_at).toLocaleString()} <button disabled={busy} onClick={()=>void select(version)}>View version {version.document_revision}</button></li>)}</ol>
      {offset!==null&&offset>0&&<button disabled={busy} onClick={()=>void load(offset)}>Load older versions</button>}
      {snapshot&&draft&&<div className="notice" aria-label="Selected saved version"><h3>{draft.title||"Untitled reel"} · version {snapshot.version.document_revision}</h3><p>{formatTime(timelineDuration(draft.clips))} · {draft.clips.length} sequence items · {draft.overlays?.length??0} cutaways · {draft.narration?"Saved narration":draft.audio==="original"?"Original audio":"Muted audio"}</p><p>Original source references and editing settings are preserved. Restoring creates your new private edit; it does not change this saved version.</p><ol>{draftMedia(draft).map(item=><li key={item.id}>{item.source.name}{item.caption?` — ${item.caption}`:""}</li>)}</ol>{canCopyVersion(workspace)?<CopyVersion choice={{listingId,authorId,revision:snapshot.version.document_revision}} own={authorId===workspace.user.id} onCopy={onCopy} disabled={busy}/>:<p>Your workspace role can view saved versions.</p>}</div>}
      {snapshot?.brief&&<ProductionBrief plan={snapshot.brief}/>}
    </>}
  </section>;
}
