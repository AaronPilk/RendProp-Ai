import {useCallback,useEffect,useRef,useState} from "react";
import type {Listing,StudioServices,Workspace} from "../../data";
import {EDIT_LIMITS,draftMedia,type AudioSourceRef,type EditDraft} from "../../editor/model";
import VideoEditor from "../../editor/VideoEditor";
import {downloadNarration} from "../sync/narration";
import {decodeSavedMedia,downloadSavedMedia} from "../projects/cloud-media";
import {downloadSource} from "../sync/CloudEditor";
import {resolvePhotoAliases,type ReadableMedia} from "../sync/media-aliases";
import {reelPayload} from "../sync/property-reels";
import ReviewPanel from "./ReviewPanel";
import VersionHistory,{CopyVersion} from "./VersionHistory";
import {canCopyVersion,type VersionChoice} from "./versions";
import ProductionBrief from "./ProductionBrief";
import {decodePermissions,decodeReview,REVIEW_LABELS,type ProductionReview,type ReviewBundle,type ReviewPermissions} from "./review";

type QueueEntry={review:ProductionReview;permissions:ReviewPermissions;source_revision:number};
export default function ReviewQueue({services,workspace,listings,onCopy}:{services:StudioServices;workspace:Workspace;listings:Listing[];onCopy?:(choice:VersionChoice)=>void}){
  const [open,setOpen]=useState(false),[rows,setRows]=useState<QueueEntry[]>([]),[offset,setOffset]=useState<number|null>(0),[busy,setBusy]=useState(false),[error,setError]=useState(""),[selected,setSelected]=useState<ProductionReview>();
  const controller=useRef(new AbortController()),flight=useRef(false);
  useEffect(()=>{const abort=new AbortController();controller.current=abort;return()=>abort.abort();},[services,workspace.org.id,workspace.user.id]);
  async function load(next=0){
    if(flight.current)return;flight.current=true;const signal=controller.current.signal;setBusy(true);setError("");
    try {
      const raw=await services.api(`/functions/v1/studio/production-review-queue?offset=${next}`,{orgId:workspace.org.id,signal}) as {reviews:unknown[];next_offset:number|null};
      if(!Array.isArray(raw.reviews)||raw.reviews.length>50||(raw.next_offset!==null&&raw.next_offset!==next+50))throw new Error("The review queue could not be read.");
      const entries=raw.reviews.map(item=>{
        const row=item as QueueEntry,review=decodeReview(row.review,workspace.org.id),permissions=decodePermissions(row.permissions);
        if(!listings.some(listing=>listing.id===review.listing_id)||!Number.isSafeInteger(row.source_revision)||row.source_revision<1)throw new Error("A review is outside the available properties. Refresh your workspace.");
        return {review,permissions,source_revision:row.source_revision};
      });
      if(signal.aborted)return;
      setRows(previous=>next===0?entries:[...previous,...entries]);setOffset(raw.next_offset);
    }catch(reason){if(!signal.aborted)setError(reason instanceof Error?reason.message:"The review queue is unavailable.");}
    finally{flight.current=false;if(!signal.aborted)setBusy(false);}
  }
  return <section className="production-panel" aria-label="Workspace review queue"><header className="production-heading"><div><h2>Team review queue</h2><p>Review submitted reels from this workspace. Private drafts stay with their authors until submitted.</p></div><button aria-expanded={open} onClick={()=>{setOpen(value=>!value);if(!open)void load();}}>{open?"Close review queue":"Open review queue"}</button></header>
    {open&&<><div className="production-actions"><button disabled={busy} onClick={()=>void load()}>Refresh queue</button></div>{error&&<p role="alert">{error}</p>}{busy&&<p role="status">Loading reviews…</p>}{!busy&&!error&&!rows.length&&<p>No submitted reels yet. Open a property, save its reel and send that version for review.</p>}
      <div className="production-queue">{rows.map(({review,source_revision})=><article className="production-queue-item" key={`${review.document_user_id}:${review.key}`}><div><h3>{listings.find(listing=>listing.id===review.listing_id)?.address||"Property reel"}</h3><p>{review.document_user_id===workspace.user.id?"Your reel":"Workspace reel"} · version {source_revision} · {new Date(review.updated_at).toLocaleString()}</p></div><span className="production-state">{REVIEW_LABELS[review.status]}</span><button onClick={()=>setSelected(review)}>Open review</button></article>)}</div>
      {offset!==null&&offset>0&&<button disabled={busy} onClick={()=>void load(offset)}>Load more reviews</button>}
      {selected&&<div className="production-review-dialog" aria-label="Selected team review"><div className="production-actions"><h3>{listings.find(listing=>listing.id===selected.listing_id)?.address||"Property reel"}</h3><button onClick={()=>setSelected(undefined)}>Close selected review</button></div><SharedReview key={`${selected.document_user_id}:${selected.key}`} services={services} workspace={workspace} review={selected} onChanged={()=>void load()} onCopy={onCopy}/></div>}
    </>}
  </section>;
}
function SharedReview({services,workspace,review,onChanged,onCopy}:{services:StudioServices;workspace:Workspace;review:ProductionReview;onChanged:()=>void;onCopy?:(choice:VersionChoice)=>void}){
  const [bundle,setBundle]=useState<ReviewBundle>(),[preview,setPreview]=useState<{draft:EditDraft;files:File[];revision:number}>(),[busy,setBusy]=useState(false),[error,setError]=useState(""),[seek,setSeek]=useState<{id:string;time:number}>();
  const abort=useRef(new AbortController()),snapshot=useRef<ReviewBundle|undefined>(undefined);snapshot.current=bundle;
  useEffect(()=>()=>abort.current.abort(),[]);
  useEffect(()=>{setPreview(undefined);},[bundle?.source_revision,!!bundle?.document,bundle?.review.status==="draft"]);
  async function restore(){
    if(!bundle?.document||bundle.review.status==="draft"||busy)return;const source=bundle;setBusy(true);setError("");
    try {
      const payload=reelPayload(source.document!.payload,review.listing_id),allMedia=draftMedia(payload.draft),required=new Map(payload.sources.map(ref=>[ref.assetId,ref])),available=new Map<string,ReadableMedia>();
      const expected=new Set(allMedia.map(clip=>clip.source.sha256));
      if(payload.sources.length===0||[...expected].some(hash=>!payload.sources.some(ref=>ref.sha256===hash)))throw new Error("The author still needs to upload the original files used by this edit.");
      let offset:number|null=0;
      do {
        const page=await services.listMedia(workspace.org.id,review.listing_id,abort.current.signal,offset);
        for(const media of [...page.photos,...page.videos])available.set(media.id,media);
        offset=page.nextOffset;
        if(offset!==null&&offset>10000)throw new Error("This property has too much media to restore at once.");
      } while(offset!==null&&[...required.keys()].some(id=>!available.has(id)));
      await resolvePhotoAliases(services,workspace.org.id,review.listing_id,available,[...required.keys()],abort.current.signal);
      const files:File[]=[];let bytes=0;
      for(const hash of expected){
        const ref=payload.sources.find(ref=>ref.sha256===hash)!,clip=allMedia.find(clip=>clip.source.sha256===hash)!,media=available.get(ref.assetId);
        if(!media)throw new Error("An original file is unavailable. Ask the author to restore it before reviewing.");
        bytes+=clip.source.size;if(bytes>EDIT_LIMITS.totalBytes)throw new Error("This review exceeds the browser's media limit.");
        files.push(await downloadSource(media.url,clip.source,AbortSignal.any([abort.current.signal,AbortSignal.timeout(120000)])));
      }
      if(abort.current.signal.aborted||snapshot.current?.source_revision!==source.source_revision||!snapshot.current.document||snapshot.current.review.status==="draft")return;
      setPreview({draft:payload.draft,files,revision:source.source_revision});
    }catch(reason){if(!abort.current.signal.aborted)setError(reason instanceof Error?reason.message:"The review preview could not be restored.");}
    finally{if(!abort.current.signal.aborted)setBusy(false);}
  }
  const resolveNarration=useCallback(async(id:string,signal:AbortSignal)=>{
    if(!preview)throw new Error("Open the saved version before restoring narration.");
    const raw=await services.api("/functions/v1/studio/production-review/narration",{method:"POST",orgId:workspace.org.id,signal,body:{key:review.key,document_user_id:review.document_user_id,result_id:id,expected_document_revision:preview.revision}}) as {result:unknown};
    return downloadNarration(raw.result,id,signal);
  },[services,workspace.org.id,review.key,review.document_user_id,preview?.revision]);
  const resolveMusic=useCallback(async(source:AudioSourceRef,signal:AbortSignal)=>{
    if(!preview)throw new Error("Open the saved version before restoring music.");
    const raw=await services.api("/functions/v1/studio/production-review/music",{method:"POST",orgId:workspace.org.id,signal,body:{listing_id:review.listing_id,sha256:source.sha256,key:review.key,document_user_id:review.document_user_id,expected_document_revision:preview.revision}});
    const media=decodeSavedMedia(raw,source.sha256);if(!media||media.bytes!==source.size)throw new Error("The review's music source could not be verified.");
    return downloadSavedMedia(media,signal);
  },[services,workspace.org.id,review.key,review.listing_id,review.document_user_id,preview?.revision]);
  return <><div className="production-actions"><button disabled={busy||!bundle?.document||bundle.review.status==="draft"} onClick={()=>void restore()}>{busy?"Restoring original media…":"Preview this saved version"}</button></div>{error&&<p role="alert">{error}</p>}{bundle&&!bundle.document&&<p>The author has changed this draft. Its new contents stay private until they submit it again.</p>}{preview&&<VideoEditor key={preview.revision} readOnly initialMode="simple" initialDraft={preview.draft} resolveNarration={resolveNarration} resolveMusic={resolveMusic} relinkRequest={{id:`review-${preview.revision}`,files:preview.files}} seekRequest={seek}/>}
    {onCopy&&<VersionHistory services={services} workspace={workspace} listingId={review.listing_id} authorId={review.document_user_id} onCopy={onCopy}/>}
    {bundle?.brief&&<ProductionBrief plan={bundle.brief}/>}
    {bundle?.document&&bundle.review.status!=="draft"&&onCopy&&canCopyVersion(workspace)&&<CopyVersion own={review.document_user_id===workspace.user.id} choice={{listingId:review.listing_id,authorId:review.document_user_id,revision:bundle.source_revision}} onCopy={onCopy}/>}
    <ReviewPanel services={services} workspace={workspace} listingId={review.listing_id} authorId={review.document_user_id} onBundle={setBundle} onChanged={onChanged} onSeek={time=>setSeek({id:crypto.randomUUID(),time})}/>
  </>;
}
