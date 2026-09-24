import {useCallback,useEffect,useRef,useState} from "react";
import type {StudioServices,Workspace} from "../../data";
import {StudioError} from "../../data/config";
import {timelineDuration} from "../../editor/model";
import {reelPayload} from "../sync/property-reels";
import {commentPosition,decodeReviewBundle,REVIEW_LABELS,timeLabel,type ReviewAction,type ReviewBundle} from "./review";
import "./production.css";
export type ReviewPanelProps={services:StudioServices;workspace:Workspace;listingId:string;authorId?:string;ready?:boolean;savedRevision?:number;prepare?:()=>Promise<void>;onBundle?:(bundle:ReviewBundle)=>void;onSeek?:(time:number)=>void;onChanged?:()=>void};
export default function ReviewPanel({services,workspace,listingId,authorId=workspace.user.id,ready=true,savedRevision=0,prepare,onBundle,onSeek,onChanged}:ReviewPanelProps){
  const [bundle,setBundle]=useState<ReviewBundle>(),[loading,setLoading]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState(""),[notice,setNotice]=useState(""),[message,setMessage]=useState(""),[position,setPosition]=useState("");
  const controller=useRef(new AbortController()),operation=useRef(0),mutating=useRef(false),refreshAfter=useRef(false),callbacks=useRef({onBundle,onChanged});callbacks.current={onBundle,onChanged};
  const path=`/functions/v1/studio/production-review?key=${encodeURIComponent(`edit:${listingId}`)}&document_user_id=${authorId}`;
  const load=useCallback(async()=>{
    if(mutating.current){refreshAfter.current=true;return;}
    const request=++operation.current,signal=controller.current.signal;setLoading(true);setError("");
    try{const raw=await services.api(path,{orgId:workspace.org.id,signal}),next=decodeReviewBundle(raw,workspace.org.id,listingId,authorId);if(signal.aborted||request!==operation.current)return;setBundle(next);callbacks.current.onBundle?.(next);}
    catch(reason){if(signal.aborted||request!==operation.current)return;if(reason instanceof StudioError&&reason.status===404){setBundle(undefined);setNotice("Save a reel with this property before sending it for review.");}else setError(reason instanceof Error?reason.message:"Review could not be opened.");}
    finally{if(!signal.aborted&&request===operation.current)setLoading(false);}
  },[services,path,workspace.org.id,listingId,authorId]);
  useEffect(()=>{const abort=new AbortController();controller.current=abort;setBundle(undefined);setMessage("");setPosition("");setNotice("");return()=>{abort.abort();operation.current++;};},[path,workspace.org.id]);
  useEffect(()=>{if(ready)void load();},[load,ready,savedRevision]);
  async function act(action:ReviewAction){
    if(!bundle||mutating.current)return;mutating.current=true;setBusy(true);setError("");setNotice("");
    const snapshot=bundle,signal=controller.current.signal;
    ++operation.current;
    try {
      const text=message.trim();
      if((action==="comment"||action==="request_changes")&&!text)throw new Error("Describe the change or feedback before sending.");
      const duration=snapshot.document?timelineDuration(reelPayload(snapshot.document.payload,listingId).draft.clips):undefined;
      const at=commentPosition(position,duration);
      await prepare?.();
      if(signal.aborted)return;
      const raw=await services.api("/functions/v1/studio/production-review",{method:"POST",orgId:workspace.org.id,signal,body:{key:`edit:${listingId}`,document_user_id:authorId,expected_document_revision:snapshot.source_revision,expected_review_revision:snapshot.review.revision,action,...(text?{message:text}:{}),...(at===null?{}:{position_ms:at})}});
      if(signal.aborted)return;
      const next=decodeReviewBundle(raw,workspace.org.id,listingId,authorId);setBundle(next);setMessage("");setPosition("");setNotice(action==="approve"?"This saved version is approved. Editing it again will require a new review.":action==="submit"?"This saved version is ready for your workspace to review.":"Review updated.");callbacks.current.onBundle?.(next);callbacks.current.onChanged?.();
    } catch(reason){if(!signal.aborted){setError(reason instanceof Error?reason.message:"The review action did not finish. Refresh its status before trying again.");if(reason instanceof StudioError&&reason.status===409){setNotice("The saved version changed. Review the refreshed contents before trying again.");void load();}}}
    finally{mutating.current=false;if(!signal.aborted){setBusy(false);if(refreshAfter.current){refreshAfter.current=false;void load();}}}
  }
  const permissions=bundle?.permissions,disabled=!ready||loading||busy;
  return <section className="production-panel" aria-label="Video review">
    <header className="production-heading"><div><h2>Review & approval</h2><p>Send a saved reel and its capture brief to your workspace. New edits clear approval.</p></div>{bundle&&<span className="production-state">{REVIEW_LABELS[bundle.review.status]} · version {bundle.source_revision}</span>}</header>
    {loading&&<p role="status">Opening the saved review…</p>}{error&&<p role="alert">{error}</p>}{notice&&<p role="status">{notice}</p>}
    {!ready&&<p className="muted">Finish syncing this edit and its source files before reviewing it.</p>}
    <div className="production-actions"><button disabled={busy||loading||!ready} onClick={()=>void load()}>Refresh review</button>{permissions?.can_submit&&<button className="primary" disabled={disabled} onClick={()=>void act("submit")}>Send saved version for review</button>}{permissions?.can_approve&&<button disabled={disabled} onClick={()=>void act("approve")}>Approve this version</button>}{permissions?.can_withdraw&&<button disabled={disabled} onClick={()=>void act("withdraw")}>Return to draft</button>}</div>
    {permissions?.can_comment&&<><label>Feedback<textarea maxLength={2000} value={message} disabled={disabled} onChange={event=>setMessage(event.target.value)} placeholder="Describe a specific change, or leave a note for the editor."/></label><div className="production-settings"><label>Video time (optional)<input aria-label="Comment video time" placeholder="0:12" value={position} disabled={disabled} onChange={event=>setPosition(event.target.value)}/></label><button disabled={disabled||!message.trim()} onClick={()=>void act("comment")}>Add comment</button>{permissions.can_request_changes&&<button disabled={disabled||!message.trim()} onClick={()=>void act("request_changes")}>Request changes</button>}</div></>}
    {bundle&&<ol className="production-review-events" aria-label="Review history">{[...bundle.review.events].reverse().map(event=><li key={event.id}><strong>{({submit:"Sent for review",comment:"Comment",request_changes:"Changes requested",approve:"Approved",withdraw:"Returned to draft",edit:"Edit updated",invalidate:"Approval cleared"} as Record<string,string>)[event.action]??"Review updated"}</strong><small> · Version {event.document_revision} · {event.author_id===workspace.user.id?"You":"Workspace member"} · {new Date(event.created_at).toLocaleString()}</small>{event.position_ms!==null&&(onSeek&&event.document_revision===bundle.source_revision?<button onClick={()=>onSeek(event.position_ms!/1000)}>Go to {timeLabel(event.position_ms)}</button>:<span> · {timeLabel(event.position_ms)}</span>)}{event.message&&<p>{event.message}</p>}{event.document_revision!==bundle.source_revision&&<small>Feedback on an earlier version</small>}</li>)}</ol>}
  </section>;
}
