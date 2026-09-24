import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import CloudEditor, {type CloudEditorProps} from "./CloudEditor";
import { scopeKey } from "../../workspace";
import ReviewQueue from "../production/ReviewQueue";
import {StudioError} from "../../data/config";
import {decodeDocument} from "../../data/documents";
import {reelPayload} from "./property-reels";
import {canCopyVersion,decodeCopyResult,decodeVersionSnapshot,versionPath,type VersionChoice,type VersionSnapshot} from "../production/versions";
import ProductionBrief from "../production/ProductionBrief";

type Delivery = Pick<CloudEditorProps, "entryRequest" | "importRequest" | "importPlan" | "importAgentPlan">;
type Props = CloudEditorProps & {
  renderLocalCreation?: (active: boolean, onSwitchBlockChange: (reason: string | null) => void) => ReactNode;
  localCreationHasWork?: boolean;
  onSelectListing?: (id: string) => boolean;
};
/** Only the visible editor is active. Local file bindings survive opening a property. */
export default function PropertyReels(props: Props) {
  return <PropertyReelSession {...props} key={scopeKey(props.workspace.user.id, props.workspace.org.id)} />;
}
function PropertyReelSession(props: Props) {
  const allowed = (id?: string) => props.listings.some(listing => listing.id === id && listing.orgId === props.workspace.org.id);
  const first = allowed(props.listingId) ? props.listingId! : "";
  const [selection, setSelection] = useState({id: first, cloudId: first, epoch:0, delivery: {} as Delivery});
  const [localOpened, setLocalOpened] = useState(!first);
  const localBlock = useRef<string | null>(null);
  const observeLocalBlock = useCallback((reason: string | null) => { localBlock.current = reason; }, []);
  const explicitSelection = useRef(first);
  type CopyState={choice:VersionChoice;phase:"preparing"|"confirm"|"copying"|"uncertain";snapshot?:VersionSnapshot;targetRevision?:number;error?:string};
  const [copy,setCopy]=useState<CopyState|null>(null),copyRef=useRef<CopyState|null>(null),copyFlight=useRef(false),copyAbort=useRef(new AbortController());
  const showCopy=(next:CopyState|null)=>{copyRef.current=next;setCopy(next);};
  const [message, setMessage] = useState("");
  const [pending, setPending] = useState<{id: string; delivery: Delivery} | null>(null);
  const guard = useRef<(() => Promise<void>) | null>(null), operation = useRef(0), mounted = useRef(true);
  const selected = useRef(selection.id); selected.current = selection.id;
  const received = useRef(new Set<string>());
  const register = useCallback((prepare: (() => Promise<void>) | null) => {guard.current = prepare;}, []);
  useEffect(() => () => {mounted.current = false; operation.current++; guard.current = null;copyAbort.current.abort();}, []);
  async function prepareCurrentEdit() {
    if (selected.current) await guard.current?.();
    else {
      if (localBlock.current) throw new Error(localBlock.current);
      if (props.localCreationHasWork && !window.confirm("Open a separate property edit? Your local video stays on this device and its files will not be uploaded or added to the property. Choose Local video to return to it.")) throw new Error("Your local video is still open. Choose a property when you are ready to open its separate edit.");
    }
  }
  async function open(id: string, delivery: Delivery = {}) {
    if(copyRef.current){setMessage("Finish or cancel the version handoff before switching properties.");return;}
    if (id ? !allowed(id) : !props.renderLocalCreation) {setMessage("That property is no longer in this workspace. Choose an available property."); return;}
    const attempt = ++operation.current;
    if (id !== selected.current) {
      try {await prepareCurrentEdit();}
      catch (error) {
        if (mounted.current && attempt === operation.current) {setPending({id, delivery}); setMessage(error instanceof Error ? error.message : "Finish saving this reel before opening another property.");}
        return;
      }
    }
    if (!mounted.current || attempt !== operation.current) return;
    if (id !== selected.current && props.onSelectListing && !props.onSelectListing(id)) return;
    const scopedDelivery = Object.fromEntries(Object.entries(delivery).filter(([, request]) => !request?.listingId || request.listingId === id)) as Delivery;
    if (!id) setLocalOpened(true);
    selected.current = id; setSelection(previous=>({id,cloudId:id || previous.cloudId,epoch:previous.epoch,delivery: scopedDelivery})); setPending(null); setMessage("");
  }
  async function targetRevision(choice:VersionChoice){
    const document=decodeDocument(await props.services.api(`/functions/v1/studio/documents?key=${encodeURIComponent(`edit:${choice.listingId}`)}`,{orgId:props.workspace.org.id,signal:copyAbort.current.signal}),`edit:${choice.listingId}`);
    if(document){if(document.kind!=="edit"||document.listing_id!==choice.listingId)throw new Error("The saved target belongs to another property.");reelPayload(document.payload,choice.listingId);}
    return document?.revision??0;
  }
  async function beginCopy(choice:VersionChoice){
    if(copyRef.current||copyFlight.current||!allowed(choice.listingId)||!canCopyVersion(props.workspace))return;
    copyFlight.current=true;showCopy({choice,phase:"preparing"});setMessage("");
    try{
      if(!canCopyVersion(props.workspace))throw new Error("Your current workspace role can view saved versions but cannot replace an edit.");
      await prepareCurrentEdit();
      if(!mounted.current)return;
      const snapshot=decodeVersionSnapshot(await props.services.api(versionPath("version",choice),{orgId:props.workspace.org.id,signal:copyAbort.current.signal}),props.workspace.org.id,choice);
      const revision=await targetRevision(choice);
      if(mounted.current)showCopy({choice,phase:"confirm",snapshot,targetRevision:revision});
    }catch(error){if(mounted.current){setMessage(error instanceof Error?error.message:"Finish saving your current edit before opening a saved version.");showCopy(null);}}
    finally{copyFlight.current=false;}
  }
  async function confirmCopy(){
    const pending=copyRef.current;if(!pending||pending.phase!=="confirm"||pending.targetRevision===undefined||copyFlight.current)return;
    copyFlight.current=true;showCopy({...pending,phase:"copying"});let dispatched=false;
    try{
      if(!canCopyVersion(props.workspace))throw new Error("Your current workspace role can view saved versions but cannot replace an edit.");
      if (selected.current) await guard.current?.();
      else if (localBlock.current) throw new Error(localBlock.current);
      if(!mounted.current)return;
      dispatched=true;
      const raw=await props.services.api("/functions/v1/studio/production-review/copy",{method:"POST",orgId:props.workspace.org.id,signal:copyAbort.current.signal,body:{key:`edit:${pending.choice.listingId}`,document_user_id:pending.choice.authorId,document_revision:pending.choice.revision,expected_target_revision:pending.targetRevision}});
      decodeCopyResult(raw,props.workspace.org.id,props.workspace.user.id,pending.choice,pending.targetRevision);
      if(!mounted.current)return;
      selected.current=pending.choice.listingId;setSelection(previous=>({id:pending.choice.listingId,cloudId:pending.choice.listingId,epoch:previous.epoch+1,delivery:{}}));showCopy(null);setPending(null);setMessage("Saved version copied into your private edit. The source version and your previous saved version remain available.");props.onChanged();
    }catch(error){if(!mounted.current)return;const message=error instanceof Error?error.message:"The version handoff could not be confirmed.";
      if(!dispatched||error instanceof StudioError&&error.status!==undefined&&[400,401,403,404,409,422].includes(error.status)){showCopy(null);setMessage(`${message} Your open edit is unchanged. Open the version again to review the latest target.`);}
      else showCopy({...pending,phase:"uncertain",error:`${message} The copy may have completed. Editing remains paused until you reopen the server's latest saved edit.`});
    }finally{copyFlight.current=false;}
  }
  async function recoverCopy(){
    const pending=copyRef.current;if(!pending||pending.phase!=="uncertain"||copyFlight.current)return;copyFlight.current=true;
    try{await targetRevision(pending.choice);if(!mounted.current)return;selected.current=pending.choice.listingId;setSelection(previous=>({id:pending.choice.listingId,cloudId:pending.choice.listingId,epoch:previous.epoch+1,delivery:{}}));showCopy(null);setMessage("Opened the latest server edit. Review its contents before continuing; the previous copy request was not repeated.");}
    catch(error){if(mounted.current)showCopy({...pending,error:error instanceof Error?error.message:"The latest server edit is unavailable. Editing remains paused."});}
    finally{copyFlight.current=false;}
  }
  useEffect(() => {
    if(copy)return;
    const delivery: Delivery = {};
    let target: string | undefined;
    for (const name of ["entryRequest", "importRequest", "importPlan", "importAgentPlan"] as const) {
      const request = props[name]; if (!request || received.current.has(request.id)) continue;
      received.current.add(request.id); Object.assign(delivery, {[name]: request}); target = request.listingId ?? target;
    }
    if (Object.keys(delivery).length) void open(target ?? selected.current, delivery);
    else if (first !== explicitSelection.current) { explicitSelection.current = first; if (first && first !== selected.current) void open(first); }
  }, [props.entryRequest, props.importRequest, props.importPlan, props.importAgentPlan, first,copy]);
  return <div>
    <section className="creation-location" aria-label="Property reels">
      <label>Working on<select aria-label="Property reel" disabled={!!copy} value={selection.id} onChange={event => void open(event.target.value)}><option value="" disabled={!props.renderLocalCreation}>{props.renderLocalCreation ? "Local video" : "Choose a property"}</option>{props.listings.map(listing => <option key={listing.id} value={listing.id}>{listing.address || "Untitled property"}</option>)}</select></label>
      <p>{selection.id ? "This property's edit syncs with your account." : "Local video · draft saved in this browser. Files stay on this device."}</p>
      {message && <p role="status">{message}</p>}
      {pending && <div><button onClick={() => void open(pending.id, pending.delivery)}>Try opening {pending.id ? props.listings.find(listing => listing.id === pending.id)?.address || "that property" : "Local video"} again</button><button onClick={() => {setPending(null);setMessage("");}}>Stay with this reel</button></div>}
    </section>
    {copy&&<section className="production-panel" aria-label="Confirm version handoff"><h2>{copy.choice.authorId===props.workspace.user.id?"Restore a saved version":"Make an editable agency copy"}</h2><p>Property: {props.listings.find(item=>item.id===copy.choice.listingId)?.address||"Selected property"} · source version {copy.choice.revision}</p>{copy.phase==="preparing"&&<p role="status">Checking saved work and the source version…</p>}{copy.phase==="copying"&&<p role="status">Copying this version. Editing and property switching are paused…</p>}{copy.phase==="confirm"&&<><p>{copy.snapshot&&reelPayload(copy.snapshot.document.payload,copy.choice.listingId).draft.title||"Untitled reel"}</p><p>{copy.targetRevision?`This replaces your current private edit at saved revision ${copy.targetRevision}. That saved version is retained in history.`:"This creates your private editable reel for this property."} The source author's version stays unchanged. Media and saved narration are reused without generation.</p><button className="primary" onClick={()=>void confirmCopy()}>Confirm copy to my edit</button><button onClick={()=>showCopy(null)}>Cancel handoff</button></>}{copy.phase==="uncertain"&&<><p role="alert">{copy.error}</p><button onClick={()=>void recoverCopy()}>Open latest saved edit</button></>}</section>}
    {copy?.snapshot?.brief&&<ProductionBrief plan={copy.snapshot.brief}/>}
    <fieldset disabled={!!copy} inert={!!copy} style={{border:0,padding:0,margin:0,minWidth:0}} aria-label="Property editing workspace">
    {localOpened && props.renderLocalCreation && <section hidden={!!selection.id} aria-label="Local video workspace">{props.renderLocalCreation(props.active !== false && !selection.id && !copy, observeLocalBlock)}</section>}
    {allowed(selection.cloudId) && <section hidden={selection.id !== selection.cloudId} aria-label="Saved property video workspace"><CloudEditor {...props} {...selection.delivery} active={props.active !== false && selection.id === selection.cloudId && !copy} entryRequest={selection.delivery.entryRequest} importRequest={selection.delivery.importRequest} importPlan={selection.delivery.importPlan} importAgentPlan={selection.delivery.importAgentPlan} readOnly={!!copy||props.readOnly} key={`${selection.cloudId}:${selection.epoch}`} listingId={selection.cloudId} onPrepareSwitch={register} onCopyVersion={choice=>void beginCopy(choice)} /></section>}
    {!selection.id && !props.renderLocalCreation && <p>Choose a property to open its saved reel.</p>}
    </fieldset>
    {!!props.listings.length && <details className="creation-review-tools"><summary>Team review &amp; saved versions</summary><ReviewQueue services={props.services} workspace={props.workspace} listings={props.listings} onCopy={choice=>void beginCopy(choice)}/></details>}
  </div>;
}
