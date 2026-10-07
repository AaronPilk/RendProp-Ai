import { useEffect, useRef, useState } from "react";
import { buildPhotoDownload, renderPhoto, type PhotoDestination, type PhotoRatio } from "./photo-export";
import type { PhotoDelivery } from "./photo-lineage";

export default function PhotoExportPanel({ photos: incomingPhotos, assertScope, disabled = false }: {
  photos: readonly PhotoDelivery[]; assertScope: () => void; disabled?: boolean;
}) {
  const stablePhotos = useRef(incomingPhotos);
  if (stablePhotos.current.length !== incomingPhotos.length || stablePhotos.current.some((photo, index) => photo !== incomingPhotos[index])) stablePhotos.current = incomingPhotos;
  const photos = stablePhotos.current;
  const [open, setOpen] = useState(false), [destination, setDestination] = useState<PhotoDestination>("mls"),
    [ratio, setRatio] = useState<PhotoRatio>("original"), [confirmed, setConfirmed] = useState<number[]>([]),
    [previews, setPreviews] = useState<string[]>([]), [busy, setBusy] = useState(false), [error, setError] = useState<string | null>(null);
  const scope = useRef(assertScope); scope.current = assertScope;
  const exportRun = useRef<AbortController | null>(null);
  useEffect(() => { setConfirmed([]); setBusy(false); return () => { exportRun.current?.abort(); }; }, [photos]);
  useEffect(() => {
    if (!open) return;
    const controller = new AbortController(), urls: string[] = [];
    setPreviews([]); setError(null);
    void (async () => {
      try {
        scope.current();
        for (const photo of photos) {
          const value = await renderPhoto(photo, { destination, ratio }, controller.signal);
          controller.signal.throwIfAborted(); scope.current();
          urls.push(URL.createObjectURL(value.blob));
        }
        setPreviews([...urls]);
      } catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Preview could not be prepared."); }
    })();
    return () => { controller.abort(); urls.forEach(url => URL.revokeObjectURL(url)); };
  }, [open, photos, destination, ratio]);
  async function download() {
    if (busy || disabled) return;
    const controller = new AbortController(); exportRun.current = controller;
    setBusy(true); setError(null);
    try {
      const selected = photos.map((photo, index) => ({ ...photo, originalVerified: !!photo.original && (photo.originalVerified || confirmed.includes(index)) }));
      const result = await buildPhotoDownload(selected, { destination, ratio }, controller.signal, () => scope.current());
      controller.signal.throwIfAborted(); scope.current();
      const url = URL.createObjectURL(result.blob), link = document.createElement("a");
      link.href = url; link.download = result.filename; link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Download could not be prepared."); }
    finally { if (!controller.signal.aborted) setBusy(false); }
  }
  if (!open) return <button disabled={disabled || !photos.length} onClick={() => setOpen(true)}>Download {photos.length === 1 ? "photo" : "photos"}</button>;
  return <section className="photo-delivery" aria-label="Download photos">
    <h3>Where will you use these photos?</h3>
    <fieldset disabled={busy || disabled}><legend>Destination</legend><div className="creative-actions">
      {([["mls", "MLS"], ["web", "Zillow / web"], ["social", "Social"]] as const).map(([value, label]) => <button key={value} className={destination === value ? "creative-primary" : undefined} aria-pressed={destination === value} onClick={() => setDestination(value)}>{label}</button>)}
    </div><label>Photo shape<select value={ratio} onChange={event => setRatio(event.target.value as PhotoRatio)}>
      <option value="original">Original frame · full size</option>
      {(["4:3", "16:9", "3:2", "1:1", "4:5", "9:16"] as const).map(value => <option key={value} value={value}>{value} · center crop</option>)}
    </select></label></fieldset>
    <p>{destination === "mls" ? "Clean, unbranded JPEGs with separate captions. Include each verified original beside its edit and follow your MLS's disclosure fields." : "JPEGs include a visible alteration label. Keep the supplied caption and original comparison with your post."}</p>
    {ratio !== "original" && <p>Check this crop before downloading. Only the exported edit is cropped; the original stays untouched.</p>}
    <div className="creative-comparison">{photos.map((photo, index) => <figure key={index}>
      {previews[index] ? <img src={previews[index]} alt={`Download preview ${index + 1}`} /> : error ? <p>Preview unavailable.</p> : <p role="status">Preparing preview {index + 1}…</p>}
      <figcaption>Photo {index + 1}</figcaption>
      {!photo.originalVerified && photo.originalPreview && <details><summary>Review the paired source</summary>
        <img src={photo.originalPreview} alt={`Paired source for photo ${index + 1}`} />
        <p>Earlier edit history is unverified. Downloading still saves your edited JPEG and its disclosure.</p>
        <label><input type="checkbox" disabled={busy} checked={confirmed.includes(index)} onChange={event => setConfirmed(ids => event.target.checked ? [...ids, index] : ids.filter(id => id !== index))} />I checked this is the actual unedited original. Include it separately.</label>
      </details>}
      {!photo.original && <p>The paired original is unavailable. This download includes your edited JPEG and an unverified-history caption.</p>}
    </figure>)}</div>
    <p>Your download includes edited photos, available verified originals and disclosure captions. Add the captions when you publish. If your advertising rules require a public link to the original, add it before posting.</p>
    {error && <p role="alert">{error}</p>}
    <button className="creative-primary" disabled={busy || disabled || previews.length !== photos.length} onClick={() => void download()}>{busy ? "Preparing download…" : "Download photo package"}</button>
  </section>;
}
