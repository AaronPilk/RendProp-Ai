import { useEffect, useRef, useState } from "react";
import type { Workspace } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { assertKitIdentity, buildKit, KIT_MAX_SELECTED, loadKit } from "./delivery-kit";
import type { KitProgress, KitSnapshot } from "./delivery-kit";
import "./listing-kit.css";

export default function ListingKit(props: { services: StudioServices; workspace: Workspace; listingId: string }) {
  return <KitSession key={`${props.workspace.user.id}:${props.workspace.org.id}:${props.listingId}`} {...props} />;
}
function KitSession({ services, workspace, listingId }: { services: StudioServices; workspace: Workspace; listingId: string }) {
  const [open, setOpen] = useState(false), [snapshot, setSnapshot] = useState<KitSnapshot | null>(null);
  const [selected, setSelected] = useState<string[]>([]), [reviewed, setReviewed] = useState(false);
  const [busy, setBusy] = useState<"" | "loading" | "download">(""), [error, setError] = useState(""), [notice, setNotice] = useState("");
  const [progress, setProgress] = useState<KitProgress | null>(null);
  const action = useRef<AbortController | null>(null), mounted = useRef(true);
  useEffect(() => {
    mounted.current = true; const version = services.getSnapshot().identityVersion;
    const unsubscribe = services.subscribe?.(() => {
      if (services.getSnapshot().identityVersion === version) return;
      action.current?.abort(); setSnapshot(null); setSelected([]); setReviewed(false); setBusy(""); setNotice(""); setError("Your account changed. Reopen this property before downloading.");
    }) ?? (() => {});
    return () => { mounted.current = false; action.current?.abort(); unsubscribe(); };
  }, [services]);
  const cancel = () => { action.current?.abort(); setBusy(""); setProgress(null); setNotice("Download cancelled. Your saved property and selections are unchanged."); };
  async function prepare() {
    if (busy) return; action.current?.abort(); const current = new AbortController(); action.current = current;
    setOpen(true); setBusy("loading"); setError(""); setNotice(""); setSnapshot(null); setReviewed(false);
    try {
      const result = await loadKit(services, workspace, listingId, current.signal);
      if (!mounted.current || current.signal.aborted) return;
      setSnapshot(result); setSelected(result.items.filter(item => item.kind === "photo").slice(0, KIT_MAX_SELECTED).map(item => item.id));
    } catch (reason) { if (mounted.current && !current.signal.aborted) setError(reason instanceof Error ? reason.message : "Saved materials could not be loaded. Try again."); }
    finally { if (mounted.current && !current.signal.aborted) setBusy(""); }
  }
  async function download() {
    if (!snapshot || busy || !reviewed) return;
    action.current?.abort(); const current = new AbortController(); action.current = current;
    setBusy("download"); setError(""); setNotice(""); setProgress(null);
    try {
      const kit = await buildKit(snapshot, selected, { services, workspace, signal: current.signal, progress: value => { if (mounted.current && !current.signal.aborted) setProgress(value); } });
      if (!mounted.current || current.signal.aborted) return;
      assertKitIdentity(services, workspace, snapshot.identityVersion, current.signal);
      const url = URL.createObjectURL(kit.blob), anchor = document.createElement("a"); anchor.href = url; anchor.download = kit.filename;
      document.body.append(anchor); anchor.click(); anchor.remove(); setTimeout(() => URL.revokeObjectURL(url), 30_000);
      setNotice(`Kit sent to your browser’s downloads with ${kit.mediaCount} selected media item${kit.mediaCount === 1 ? "" : "s"}. Unzip it and open START-HERE.html.`);
    } catch (reason) { if (mounted.current && !current.signal.aborted) setError(reason instanceof Error ? reason.message : "The kit could not finish. No incomplete kit was downloaded."); }
    finally { if (mounted.current && !current.signal.aborted) { setBusy(""); setProgress(null); } }
  }
  function choose(id: string, checked: boolean) { setSelected(current => checked ? [...current, id] : current.filter(value => value !== id)); setReviewed(false); setNotice(""); }
  return <section className="lw-card listing-kit" aria-labelledby="listing-kit-heading">
    <div className="listing-kit-heading"><div><p className="eyebrow">Ready for your next step</p><h2 id="listing-kit-heading">Download listing kit</h2><p>Bring selected photos, saved copy and available tour links together in one ZIP.</p></div><button disabled={!!busy} onClick={() => open ? setOpen(false) : void prepare()}>{open ? "Hide kit options" : "Choose kit materials"}</button></div>
    {error && <p role="alert" className="lw-error">{error}</p>}{notice && <p role="status" className="lw-notice">{notice}</p>}
    {open && <div className="listing-kit-options">
      {busy === "loading" && <p role="status">Checking saved property materials…</p>}
      {snapshot && <>
        <p className="lw-help">Includes saved property details{snapshot.script.trim() ? " and script" : ""}. Unsaved field edits stay where you left them. {snapshot.published ? "Your latest published tour links and QR codes are included." : "No tour has been published, so this kit will have no tour links or QR codes."}</p>
        <div className="listing-kit-tools"><strong>{selected.length} of {snapshot.items.length} media items selected</strong><button disabled={!!busy} onClick={() => { setSelected([]); setReviewed(false); setNotice(""); }}>Clear selection</button><button disabled={!!busy} onClick={() => { setSelected(snapshot.items.filter(item => item.kind === "photo").slice(0, KIT_MAX_SELECTED).map(item => item.id)); setReviewed(false); setNotice(""); }}>Select gallery photos</button></div>
        <p className="lw-help">Choose up to 40 items. Altered photos include their paired original automatically. Videos stay unselected until you choose them. Maximum 256 MB per kit and 128 MB per file.</p>
        {snapshot.items.length ? <div className="listing-kit-grid">{snapshot.items.map(item => <article className="listing-kit-item" key={item.id}>
          {item.kind === "photo" ? <img src={item.url} alt={item.label} loading="lazy" referrerPolicy="no-referrer" /> : <video src={item.url} controls preload="none" playsInline />}
          <label><input type="checkbox" checked={selected.includes(item.id)} disabled={!!busy || selected.length >= KIT_MAX_SELECTED && !selected.includes(item.id)} onChange={event => choose(item.id, event.target.checked)} />Include {item.label}</label>
          {item.caption && <p>{item.caption}</p>}<small>{item.disclosure}</small>{item.originalLabel && <p className="listing-kit-pair">{item.originalLabel} included</p>}
        </article>)}</div> : <p>No downloadable gallery photos or completed reviewed videos are available. You can still download the saved property details.</p>}
        {snapshot.excluded.length > 0 && <details className="listing-kit-exclusions"><summary>{snapshot.excluded.length} item(s) unavailable for this kit</summary><ul>{snapshot.excluded.map((reason, index) => <li key={index}>{reason}</li>)}</ul></details>}
        <label className="lw-check"><input type="checkbox" checked={reviewed} disabled={!!busy} onChange={event => setReviewed(event.target.checked)} />I reviewed the selected materials and saved property details. I’ll keep disclosures and paired originals with altered media when sharing.</label>
        <p className="lw-help">This download does not publish new work or certify MLS compliance.</p>
        <div className="lw-actions"><button className="primary" disabled={!!busy || !reviewed} onClick={() => void download()}>{busy === "download" ? "Preparing download…" : "Download ZIP"}</button><button disabled={!!busy} onClick={() => void prepare()}>Refresh saved materials</button></div>
      </>}
      {!snapshot && !busy && <button onClick={() => void prepare()}>Try loading materials again</button>}
      {busy && <div className="listing-kit-progress" role="status">{progress && <><p>{progress.label} · {progress.done}/{progress.total} files · {(progress.bytes / 1024 / 1024).toFixed(1)} MB</p><progress aria-label="Listing kit download progress" max={Math.max(1, progress.total)} value={progress.done} /></>}<button onClick={cancel}>Cancel {busy === "loading" ? "loading" : "download"}</button></div>}
    </div>}
  </section>;
}
