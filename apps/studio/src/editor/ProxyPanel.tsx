import {useEffect, useRef, useState} from "react";
import {createEditingCopy, validateProxyInput, type EditingCopy} from "./proxy";

export type ProxyPanelProps = {active: boolean; blocked: boolean; onImport: (files: File[]) => Promise<void>; onBusyChange: (busy: boolean) => void};
export default function ProxyPanel({active, blocked, onImport, onBusyChange}: ProxyPanelProps) {
  const [source, setSource] = useState<File | null>(null), [result, setResult] = useState<EditingCopy | null>(null), [busy, setBusy] = useState(false);
  const [issue, setIssue] = useState(""), [stage, setStage] = useState(""), [progress, setProgress] = useState(0);
  const [preview, setPreview] = useState("");
  useEffect(() => {if (!result) {setPreview(""); return;} const url = URL.createObjectURL(result.file); setPreview(url); return () => URL.revokeObjectURL(url);}, [result]);
  const abort = useRef<AbortController | null>(null), mounted = useRef(true);
  useEffect(() => {onBusyChange(busy); return () => onBusyChange(false);}, [busy, onBusyChange]);
  useEffect(() => {if (!active) abort.current?.abort();}, [active]);
  useEffect(() => () => {mounted.current = false; abort.current?.abort();}, []);
  async function create() {
    if (!source || blocked || busy || !active) return;
    const controller = new AbortController(); abort.current = controller; setBusy(true); setResult(null); setIssue("");
    try {
      const made = await createEditingCopy(source, controller.signal, (label, value) => {if (mounted.current && !controller.signal.aborted) {setStage(label); setProgress(value);}});
      if (mounted.current && !controller.signal.aborted) setResult(made);
    } catch (error) {if (mounted.current) setIssue(controller.signal.aborted ? "Editing copy canceled. Your original is unchanged." : error instanceof Error ? error.message : "The editing copy could not be made.");}
    finally {if (abort.current === controller) {abort.current = null; if (mounted.current) setBusy(false);}}
  }
  function download(blob: Blob, name: string) {const url = URL.createObjectURL(blob), link = document.createElement("a"); link.href = url; link.download = name; document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);}
  return <section aria-label="Video preparation">
    <p>Make a smaller 720p copy here from an original up to 2 GiB and three minutes. Your original stays on your device; only the copy is added to the editor or uploaded. This takes roughly the video’s length plus a file check.</p>
    <label>Choose original for editing copy<input aria-label="Original for editing copy" type="file" accept="video/mp4,video/quicktime,video/webm,.mov,.mp4,.webm" disabled={blocked || busy || !active} onChange={event => {const file = event.target.files?.[0]; event.target.value = ""; setResult(null); if (!file) return; try {validateProxyInput(file); setSource(file); setIssue("");} catch (error) {setSource(null); setIssue(error instanceof Error ? error.message : "Choose a supported video.");}}} /></label>
    {source && <p>{source.name} · {(source.size / 1024 / 1024).toFixed(1)} MiB</p>}
    {busy ? <><p role="status">{stage}</p><progress aria-label="Editing copy progress" max="1" value={progress} /><button type="button" onClick={() => abort.current?.abort()}>Cancel editing copy</button></> : <button type="button" disabled={!source || blocked || !active} onClick={() => void create()}>Create editing copy</button>}
    {result && <div role="region" aria-label="Completed editing copy">{preview && <video src={preview} controls preload="metadata" aria-label="Preview editing copy" />}<p>Ready: {result.manifest.copy.width} × {result.manifest.copy.height} · {(result.file.size / 1024 / 1024).toFixed(1)} MiB. Check color and sound before sharing. The provenance file records the original and copy fingerprints; it is not a backup of the original.</p><button type="button" onClick={() => download(result.file, result.file.name)}>Download editing copy</button><button type="button" onClick={() => download(new Blob([JSON.stringify(result.manifest, null, 2)], {type: "application/json"}), `${result.file.name}.provenance.json`)}>Download provenance</button><button type="button" disabled={blocked || busy || !active} onClick={() => void onImport([result.file])}>Use editing copy</button></div>}
    {issue && <p role="status">{issue}</p>}
  </section>;
}
