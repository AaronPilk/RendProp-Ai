import { useEffect, useRef, useState } from "react";
import { FEEDBACK_REASONS, REASON_LABELS } from "./photo-feedback-reasons";
import { same, type Content, type PhotoFeedbackQueue, type Verdict } from "./photo-feedback-queue";

/** Optional rating of one exact output version. It sits below the review actions
 * and never gates the acknowledgment, save, download or publication. It reuses
 * the shared segmented control, reason grid and checkbox row styles. */
export default function PhotoFeedbackControl({ queue, provenanceId, file }: { queue: PhotoFeedbackQueue; provenanceId: string; file: Blob }) {
  const [, redraw] = useState(0);
  useEffect(() => queue.subscribe(() => redraw(value => value + 1)), [queue]);
  const saved = queue.entry(provenanceId), body = saved?.body;
  const [verdict, setVerdict] = useState<Verdict | undefined>(body?.verdict), [reasons, setReasons] = useState<string[]>(body?.reasons ?? []),
    [note, setNote] = useState(body?.note ?? ""), [failed, setFailed] = useState(false);
  // The hash pins the answer to the bytes on screen; the server refuses a mismatch.
  const digest = useRef<Promise<string>>(null);
  const draft: Content = { verdict: "needs_work", reasons, note: reasons.includes("other") && note.trim() || undefined };
  async function send(next: Content) {
    setVerdict(next.verdict); setFailed(false);
    try {
      digest.current ??= file.arrayBuffer().then(bytes => crypto.subtle.digest("SHA-256", bytes)).then(hash => [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join(""));
      queue.submit({ ...next, provenance_id: provenanceId, output_sha256: await digest.current });
    } catch { setFailed(true); }
  }
  const editing = verdict === "needs_work" && !(body && same(draft, body));
  const status = failed || saved?.state === "dropped" ? "Couldn't save this feedback." : !body || editing || verdict !== body.verdict ? ""
    : saved!.state === "sent" ? "Saved" : queue.waiting() || !navigator.onLine ? "Will send when online" : "Saving…";
  return <div role="group" aria-label="Rate this edit">
    <h3>Was this edit useful?</h3>
    <small>Optional. Your answer never changes this photo or starts a new edit.</small>
    <div className="video-photo-actions">
      <button type="button" aria-pressed={verdict === "useful"} onClick={() => void send({ verdict: "useful", reasons: [] })}>Useful</button>
      <button type="button" aria-pressed={verdict === "needs_work"} onClick={() => setVerdict("needs_work")}>Needs work</button>
    </div>
    {verdict === "needs_work" && <>
      <p>What needs work?</p>
      <div className="creative-preset-grid" role="group" aria-label="What needs work?">
        {FEEDBACK_REASONS.map((reason, index) => <label key={reason} className="creative-review-confirmation"><input type="checkbox" checked={reasons.includes(reason)} onChange={event => {
          const checked = event.target.checked;
          setReasons(list => FEEDBACK_REASONS.filter(item => item === reason ? checked : list.includes(item)));
        }} />{REASON_LABELS[index]}</label>)}
      </div>
      {reasons.includes("other") && <label>Tell us more (optional)<textarea maxLength={500} value={note} onChange={event => setNote(event.target.value)} /></label>}
      <button type="button" disabled={!reasons.length || !editing} onClick={() => void send(draft)}>Send feedback</button>
    </>}
    <small role="status">{status}</small>
  </div>;
}
