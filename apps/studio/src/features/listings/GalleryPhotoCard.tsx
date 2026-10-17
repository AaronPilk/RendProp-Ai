import { useState } from "react";
import type { StudioPhoto } from "../../data/contracts";
import type { GalleryPhoto } from "./model";
import {orientationLabel,type PhotoOrientation} from "../sync/video-framing";

export default function GalleryPhotoCard({ photo, preview, index, count, isCover, busy, canWrite, selectionReady, selected, usable, reviewRequired, orientation='unknown', onGeometry, onPrepare, onUse, onSaveCaption, onCover, onMove }: {
  photo: GalleryPhoto; preview?: StudioPhoto; index: number; count: number; isCover: boolean; busy: boolean; canWrite: boolean;
  selectionReady:boolean;selected:boolean;usable:boolean;reviewRequired:boolean;onUse:(reviewed:boolean)=>void;
  onSaveCaption: (caption: string, expected: string | null) => Promise<boolean>;
  onCover: (reviewed:boolean) => void; onMove: (direction: -1 | 1) => void;
  onPrepare?:()=>void;
  orientation?:PhotoOrientation; onGeometry?:(width:number,height:number)=>void;
}) {
  const [edit, setEdit] = useState<{ text: string; expected: string | null } | null>(null);
  const [reviewed,setReviewed]=useState(false);
  const canUse=selectionReady&&usable&&(!reviewRequired||reviewed&&!!preview?.originalUrl);
  const changedElsewhere = edit !== null && edit.expected !== photo.caption;
  const title = photo.caption || `Gallery photo ${index + 1}`;
  return <article className="lw-media-card lw-gallery-photo" aria-label={`Gallery photo ${index + 1}`}>
    {preview ? <img src={preview.url} alt={title} loading="lazy" style={{objectFit:"contain"}} onLoad={event=>{const image=event.currentTarget;if(image.currentSrc===preview.url)onGeometry?.(image.naturalWidth,image.naturalHeight);}} /> : <div className="lw-preview-unavailable">Preview unavailable. Refresh to try again.</div>}
    <div><span>{index + 1} of {count}{isCover ? " · Cover photo" : selected ? " · Selected for listing" : " · Saved version"}</span><strong>{title}</strong>
      <span className="lw-orientation" data-orientation={orientation}>{orientationLabel(orientation)}</span>
      {(photo.is_staged || preview?.isAltered) && <span className="lw-disclosure">AI-altered photo{preview?.originalUrl ? " · original available" : ""}</span>}
      {preview && <a href={preview.url} target="_blank" rel="noreferrer">Open photo ↗</a>}
      {onPrepare?<><p className="lw-help">Keep this saved source unchanged and prepare a separate version to review for the listing.</p><button disabled={busy||!canWrite} onClick={onPrepare}>Prepare for listing</button></>:reviewRequired&&<>{preview?.originalUrl?<a href={preview.originalUrl} target="_blank" rel="noreferrer">Open retained original ↗</a>:<p className="lw-help">Refresh to load this edited photo’s retained original before selecting it.</p>}<label className="lw-gallery-review"><input type="checkbox" checked={reviewed} disabled={busy||!canWrite||!preview?.originalUrl} onChange={event=>setReviewed(event.target.checked)}/>I compared this edited version with its original and checked fixed features, layout and property condition.</label></>}
      {!selectionReady&&<p className="lw-help">Refresh to check which photos are selected for the listing.</p>}
      {selectionReady&&!usable&&!onPrepare&&<p className="lw-help">This version needs its available original, disclosure and accuracy review before it can be selected.</p>}
      {edit ? <form onSubmit={async event => { event.preventDefault(); if (!changedElsewhere && await onSaveCaption(edit.text, edit.expected)) setEdit(null); }}>
        <label>Photo caption<textarea value={edit.text} maxLength={2000} rows={3} disabled={busy || !canWrite} onChange={event => setEdit({ ...edit, text: event.target.value })} /></label>
        <p className="lw-help">Up to 500 characters. Required AI disclosures are retained when you save.</p>
        {changedElsewhere && <p role="alert" className="lw-error">The caption changed on another device. Your text is still here.<button type="button" disabled={busy} onClick={() => setEdit({ text: photo.caption ?? "", expected: photo.caption })}>Use latest caption</button><button type="button" disabled={busy} onClick={() => setEdit({ ...edit, expected: photo.caption })}>Keep my text and review again</button></p>}
        <div className="lw-photo-actions"><button className="primary" disabled={busy || !canWrite || changedElsewhere}>Save caption</button><button type="button" disabled={busy} onClick={() => setEdit(null)}>Cancel</button></div>
      </form> : <button disabled={busy || !canWrite} onClick={() => setEdit({ text: photo.caption ?? "", expected: photo.caption })}>Edit caption</button>}
      <div className="lw-photo-actions"><button disabled={busy||!canWrite||selected||!canUse} onClick={()=>onUse(reviewed)}>{selected?"Selected for listing":"Use on listing"}</button><button disabled={busy || !canWrite || isCover||!canUse} onClick={()=>onCover(reviewed)}>{isCover ? "Cover photo" : "Use as cover"}</button><button aria-label={`Move photo ${index + 1} earlier`} disabled={busy || !canWrite ||!selectionReady|| index === 0 || count > 500} onClick={() => onMove(-1)}>← Earlier</button><button aria-label={`Move photo ${index + 1} later`} disabled={busy || !canWrite ||!selectionReady|| index === count - 1 || count > 500} onClick={() => onMove(1)}>Later →</button></div>
    </div>
  </article>;
}
