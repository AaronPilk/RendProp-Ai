import { useEffect, useRef, useState } from "react";
import type { StudioServices } from "../../data/services";
import { coordinatorPhotoParts, loadCoordinatorPhotos, type CoordinatorPart } from "./coordinator-photo-export";

export default function CoordinatorPhotoExportPanel({ services, orgId, listingId, title, scopeSignal, assertScope, disabled = false }: {
  services: StudioServices; orgId: string; listingId: string; title: string; scopeSignal: AbortSignal; assertScope: () => void; disabled?: boolean;
}) {
  const [part,setPart] = useState<CoordinatorPart | null>(null), [busy,setBusy] = useState(false), [status,setStatus] = useState(""),
    [error,setError] = useState<string | null>(null), [downloaded,setDownloaded] = useState<number | null>(null);
  const scope = useRef(assertScope); scope.current = assertScope;
  const run = useRef<{ controller: AbortController; parts: AsyncGenerator<CoordinatorPart> | null } | null>(null);
  const urls = useRef(new Set<string>());
  useEffect(() => () => {
    run.current?.controller.abort(); void run.current?.parts?.return(undefined).catch(() => {});
    for (const url of urls.current) URL.revokeObjectURL(url); urls.current.clear();
  }, [orgId,listingId,scopeSignal]);
  const check = () => { scopeSignal.throwIfAborted(); scope.current(); };
  async function next(start = false) {
    if (busy || disabled) return;
    setBusy(true); setError(null); setPart(null); setDownloaded(null);
    let active = run.current;
    try {
      check();
      if (start || !active) {
        active?.controller.abort(); void active?.parts?.return(undefined).catch(() => {});
        active = { controller:new AbortController(),parts:null }; run.current=active;
        const signal = AbortSignal.any([active.controller.signal,scopeSignal]);
        setStatus("Loading all uploaded photo versions…");
        const photos = await loadCoordinatorPhotos(services,orgId,listingId,signal,check); check(); signal.throwIfAborted();
        setStatus(`Preparing ${photos.length} uploaded photos and their delivery copies…`);
        active.parts = coordinatorPhotoParts(photos,signal,check,{title,progress:(done,total) => {
          if (run.current === active) setStatus(`Preparing photo ${Math.min(done+1,total)} of ${total} and its delivery copies…`);
        }});
      } else setStatus("Preparing the next full-quality part…");
      const value = await active.parts!.next(); check(); active.controller.signal.throwIfAborted();
      if (run.current !== active) return;
      if (value.done) { setStatus("All photo-package parts are complete."); run.current=null; }
      else { setPart(value.value); setStatus(""); }
    } catch (reason) {
      if (active && run.current === active && !active.controller.signal.aborted && !scopeSignal.aborted) {
        setError(reason instanceof Error ? reason.message : "The coordinator package could not be prepared.");
        active.controller.abort(); void active.parts?.return(undefined).catch(() => {}); run.current=null;
      }
    } finally { if (!active || run.current === active || run.current === null) setBusy(false); }
  }
  function download() {
    if (!part || busy || disabled) return;
    try {
      check(); const url = URL.createObjectURL(part.blob); urls.current.add(url);
      const link = document.createElement("a"); link.href=url; link.download=part.filename; link.click(); setDownloaded(part.part);
      setTimeout(() => { URL.revokeObjectURL(url); urls.current.delete(url); },1000);
    } catch (reason) { run.current?.controller.abort(); void run.current?.parts?.return(undefined).catch(() => {}); run.current=null; setError(reason instanceof Error ? reason.message : "Reopen this property before downloading."); setPart(null); }
  }
  function cancel() { run.current?.controller.abort(); void run.current?.parts?.return(undefined).catch(() => {}); run.current=null; setBusy(false);setPart(null);setStatus(""); }
  return <section className="creative-card creative-wide" aria-label="Coordinator photo package">
    <h2>Send photos to your listing coordinator</h2>
    <p>All uploaded saved versions, organized into Originals, Decluttered and Staged, with MLS, Zillow and Instagram copies. Full saved masters stay untouched.</p>
    <p>Delivery copies use 4:3, 4:5 and 9:16 center-crop presets at the available resolution. Review crops and add the included disclosures before advertising; platform requirements differ.</p>
    <p>Large libraries use numbered ZIP parts to keep full quality. Download every part and extract them into the same folder. Phone-only files must be uploaded first.</p>
    {busy && <p role="status">{status}</p>}
    {part && <div aria-live="polite">
      <p>Part {part.part}: {part.files} files · photos {part.from}–{part.through} of {part.total}. {part.more ? "More parts follow." : "Final part."}</p>
      {part.notes.length > 0 && <p role="note">This browser could not create delivery copies for some HEIC/HEIF masters. Their exact files are included, with missing delivery copies identified in the manifest.</p>}
      <button className="creative-primary" disabled={busy || disabled} onClick={download}>Download coordinator ZIP · part {part.part}</button>
      {part.more && <button disabled={busy || disabled || downloaded !== part.part} onClick={() => void next()}>Prepare next part</button>}
      {!part.more && downloaded === part.part && <p role="status">Every part has been offered for download. Check your Downloads folder and keep all numbered parts together.</p>}
    </div>}
    {!busy && !part && <button disabled={disabled} onClick={() => void next(true)}>Prepare coordinator ZIP</button>}
    {(busy || part) && <button onClick={cancel}>Close package</button>}
    {error && <p role="alert">{error}</p>}
  </section>;
}
