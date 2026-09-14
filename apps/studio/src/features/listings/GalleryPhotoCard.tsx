import { useState } from "react";
import type { StudioPhoto } from "../../data/contracts";
import type { GalleryPhoto } from "./model";

export default function GalleryPhotoCard({ photo, preview, index, count, isCover, busy, canWrite, onSaveCaption, onCover, onMove }: {
  photo: GalleryPhoto; preview?: StudioPhoto; index: number; count: number; isCover: boolean; busy: boolean; canWrite: boolean;
  onSaveCaption: (caption: string, expected: string | null) => Promise<boolean>;
  onCover: () => void; onMove: (direction: -1 | 1) => void;
}) {
  const [edit, setEdit] = useState<{ text: string; expected: string | null } | null>(null);
  const changedElsewhere = edit !== null && edit.expected !== photo.caption;
  const title = photo.caption || `Gallery photo ${index + 1}`;
  return <article className="lw-media-card lw-gallery-photo" aria-label={`Gallery photo ${index + 1}`}>
    {preview ? <img src={preview.url} alt={title} loading="lazy" /> : <div className="lw-preview-unavailable">Preview unavailable. Refresh to try again.</div>}
    <div><span>{index + 1} of {count}{isCover ? " · Cover photo" : " · Tour gallery"}</span><strong>{title}</strong>
      {(photo.is_staged || preview?.isAltered) && <span className="lw-disclosure">AI-altered photo · disclosure retained</span>}
      {preview && <a href={preview.url} target="_blank" rel="noreferrer">Open photo ↗</a>}
      {edit ? <form onSubmit={async event => { event.preventDefault(); if (!changedElsewhere && await onSaveCaption(edit.text, edit.expected)) setEdit(null); }}>
        <label>Photo caption<textarea value={edit.text} maxLength={2000} rows={3} disabled={busy || !canWrite} onChange={event => setEdit({ ...edit, text: event.target.value })} /></label>
        <p className="lw-help">Up to 500 characters. Required AI disclosures are retained when you save.</p>
        {changedElsewhere && <p role="alert" className="lw-error">The caption changed on another device. Your text is still here.<button type="button" disabled={busy} onClick={() => setEdit({ text: photo.caption ?? "", expected: photo.caption })}>Use latest caption</button><button type="button" disabled={busy} onClick={() => setEdit({ ...edit, expected: photo.caption })}>Keep my text and review again</button></p>}
        <div className="lw-photo-actions"><button className="primary" disabled={busy || !canWrite || changedElsewhere}>Save caption</button><button type="button" disabled={busy} onClick={() => setEdit(null)}>Cancel</button></div>
      </form> : <button disabled={busy || !canWrite} onClick={() => setEdit({ text: photo.caption ?? "", expected: photo.caption })}>Edit caption</button>}
      <div className="lw-photo-actions"><button disabled={busy || !canWrite || isCover} onClick={onCover}>{isCover ? "Cover photo" : "Use as cover"}</button><button aria-label={`Move photo ${index + 1} earlier`} disabled={busy || !canWrite || index === 0 || count > 500} onClick={() => onMove(-1)}>← Earlier</button><button aria-label={`Move photo ${index + 1} later`} disabled={busy || !canWrite || index === count - 1 || count > 500} onClick={() => onMove(1)}>Later →</button></div>
    </div>
  </article>;
}
