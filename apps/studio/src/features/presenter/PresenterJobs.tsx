import { useCallback, useEffect, useRef, useState } from "react";
import type { AgentPlanHandoff } from "../creative/model";
import type { Draft } from "./model";
import { activeJob, decodeJobs, dollars, JOB_STATES, nextAutoCheck, readSubmission, resolvesSubmission, submissionKey, type JobsState, type PresenterJob, type Submission } from "./jobs";

type Props = { org: string; user: string; listing: string; draft?: Draft; ready: boolean; blocked: boolean; api: (path?: string, body?: unknown) => Promise<unknown>; current: () => boolean; onBusy: (busy: boolean) => void; onUse?: (plan: AgentPlanHandoff) => void };
const message = (e: unknown) => e instanceof Error ? e.message : "Presenter job could not be checked.";
export default function PresenterJobs({ org, user, listing, draft, ready, blocked, api, current, onBusy, onUse }: Props) {
  const key = submissionKey(org, user, listing);
  const [stored] = useState(() => { try { return { marker: readSubmission(localStorage.getItem(key)), error: "" }; } catch { return { marker: null, error: "Pending submission storage could not be read. Generation is locked until storage is available." }; } });
  const [state, setState] = useState<JobsState | null>(null), [busy, setBusy] = useState(false), [error, setError] = useState(stored.error), [consent, setConsent] = useState(""), [reviewed, setReviewed] = useState("");
  const [marker, setMarker] = useState<Submission | null>(stored.marker), [previewErrors, setPreviewErrors] = useState<string[]>([]), [loadedOutput, setLoadedOutput] = useState<Record<string, string>>({}), [previewVersion, setPreviewVersion] = useState(0);
  const poll = useRef(() => {}), attempts = useRef<Record<string, number>>({});
  const running = useRef(false), alive = useRef(true), pending = useRef(marker), serial = useRef(0);
  const accept = useCallback((next: JobsState) => {
    setState(next); setReviewed(""); setPreviewVersion(v => v + 1);
    if (pending.current && resolvesSubmission(next, pending.current)) {
      try { localStorage.removeItem(key); pending.current = null; setMarker(null); } catch { setError("The job is saved, but browser storage could not be updated. Refresh its status before another generation."); }
    }
  }, [key]);
  const read = useCallback(async () => decodeJobs(await api(`/jobs?${new URLSearchParams({ listing_id: listing })}`), org, listing), [api, org, listing]);
  useEffect(() => {
    alive.current = true; const version = ++serial.current;
    void read().then(next => { if (alive.current && current() && version === serial.current) accept(next); }).catch(e => { if (alive.current && current() && version === serial.current) setError(message(e)); });
    return () => { alive.current = false; serial.current++; };
  }, [read, current, accept, draft?.revision, draft?.profile_revision]);
  useEffect(() => { onBusy(busy); return () => onBusy(false); }, [busy, onBusy]);
  const jobs = state?.jobs.filter(j => j.draft_id === draft?.id) ?? [];
  const quote = state?.quotes.find(q => q.draft_id === draft?.id && q.draft_revision === draft.revision && q.profile_revision === draft.profile_revision && !q.consumed && Date.parse(q.expires_at) > Date.now());
  const quoteKey = quote ? `${quote.id}:${quote.max_cost_cents}:${quote.estimate_usd}:${quote.draft_revision}:${quote.profile_revision}` : "";
  useEffect(() => { setConsent(""); setReviewed(""); if (!quote) return; const timer = window.setTimeout(() => { setConsent(""); setState(s => s ? { ...s } : s); }, Math.max(0, Date.parse(quote.expires_at) - Date.now()) + 5); return () => clearTimeout(timer); }, [quoteKey, draft?.revision, draft?.profile_revision]);
  const available = !!state?.runtime.available, locked = busy || blocked;
  const canQuote = available && ready && !locked && !marker && !stored.error && !jobs.some(activeJob);
  async function run(action?: string, body?: Record<string, unknown>) {
    if (running.current || !current() || (action && blocked)) return;
    running.current = true; serial.current++; setBusy(true); setError(""); setReviewed("");
    try {
      const next = action ? decodeJobs(await api("/jobs", { action, ...body }), org, listing) : await read();
      if (alive.current && current()) accept(next);
    } catch (e) {
      if (!alive.current || !current()) return;
      try { const next = await read(); if (alive.current && current()) { accept(next); setError(message(e)); } }
      catch { if (alive.current && current()) setError("Status could not be confirmed. Check job status before continuing."); }
    } finally { running.current = false; if (alive.current && current()) setBusy(false); }
  }
  poll.current = () => {
    const job = nextAutoCheck(jobs, attempts.current, alive.current && current() && ready && !locked && !running.current && !error && !marker && navigator.onLine && document.visibilityState === "visible");
    if (!job) return;
    attempts.current[job.id] = (attempts.current[job.id] ?? 0) + 1;
    void run("check", { job_id: job.id, expected_revision: job.revision });
  };
  useEffect(() => { const timer = window.setInterval(() => poll.current(), 10_000); return () => clearInterval(timer); }, []);
  function generate() {
    if (!canQuote || consent !== quoteKey || !quote || Date.parse(quote.expires_at) <= Date.now()) return;
    const submission = { quote_id: quote.id, idempotency_key: crypto.randomUUID(), max_cost_cents: quote.max_cost_cents };
    try { localStorage.setItem(key, JSON.stringify(submission)); pending.current = submission; setMarker(submission); }
    catch { setError("Generation was not sent because its recovery receipt could not be saved in this browser."); return; }
    setConsent(""); void run("generate", { ...submission, cost_consent: true, max_cost_cents: quote.max_cost_cents });
  }
  const jobAction = (action: string, job: PresenterJob, extra?: Record<string, unknown>) => void run(action, { job_id: job.id, expected_revision: job.revision, ...extra });
  return <section className="presenter-original" aria-label="Presenter generation jobs">
    <h3>4 · Generate and review</h3>
    <p role="status">{state?.runtime.reason ?? "Checking generation availability…"}</p>
    {error && <p className="creative-alert" role="alert">{error}</p>}
    {marker && <div className="creative-alert"><p role="status">A submission is awaiting confirmation. Check status or recover this same request; a new request will not be created. Authorized maximum: {dollars((marker.max_cost_cents / 100).toFixed(2))}.</p><button disabled={locked} onClick={() => void run("generate", { ...marker, cost_consent: true })}>Recover submission</button>{error && <><p>If this request never reached generation, close it before requesting a fresh quote. An existing job will be recovered instead.</p><button disabled={locked} onClick={() => void run("close_submission", { quote_id: marker.quote_id, idempotency_key: marker.idempotency_key })}>Close unsubmitted request</button></>}</div>}
    <small>Status updates while this tab is visible and online. Check manually if updates pause.</small>
    <div className="creative-actions"><button disabled={busy} onClick={() => void run()}>Check job status</button>{busy && <span role="status">Checking or saving job…</span>}</div>
    {!available ? <button disabled>Generate AI Presenter · unavailable</button> : <>
      <button disabled={!canQuote} onClick={() => void run("quote", { draft_id: draft!.id, expected_revision: draft!.revision, expected_profile_revision: draft!.profile_revision })}>Get generation quote</button>
      {!ready && <small>Save changes and approve the exact draft and likeness before requesting a quote.</small>}
      {quote && <div className="presenter-consent"><p>Estimated cost: <strong>{dollars(quote.estimate_usd)}</strong>. Quote expires {new Date(quote.expires_at).toLocaleTimeString()}.</p>
        <label><input type="checkbox" checked={consent === quoteKey} disabled={!canQuote} onChange={e => setConsent(e.target.checked ? quoteKey : "")} />I authorize up to {dollars((quote.max_cost_cents / 100).toFixed(2))} for this generation.</label>
        <button className="creative-primary" disabled={!canQuote || consent !== quoteKey} onClick={generate}>Generate this approved draft</button>
      </div>}
    </>}
    {!jobs.length && <small>No generation jobs for this draft.</small>}
    {jobs.map(job => { const valid = job.draft_revision === draft?.revision && job.profile_revision === draft.profile_revision; const previewKey = `${previewVersion}:${job.revision}:${job.output?.preview_url}`, previewReady = loadedOutput[job.id] === previewKey && !previewErrors.includes(job.id); return <article className="presenter-original" key={job.id} aria-label={`Presenter job ${job.id}`}>
      <h4>{JOB_STATES[job.status]}</h4><p>Draft revision {job.draft_revision ?? "withdrawn"} · likeness revision {job.profile_revision ?? "withdrawn"}</p>
      <small>Estimate {dollars(job.estimate_usd)} · Authorized maximum {dollars((job.max_cost_cents / 100).toFixed(2))} · Held {dollars((job.held_cents / 100).toFixed(2))}{job.actual_usd !== null ? ` · Recorded cost ${dollars(job.actual_usd)}` : " · Final cost not reported"}</small>
      {job.status === "uncertain" && <p>The provider receipt is uncertain. Checking status will not submit another generation.</p>}
      {job.status === "invalidated" && <p>The source, likeness or draft approval changed. This output cannot be reviewed or imported.</p>}
      {job.status === "failed" && <p>This job did not finish. Review its recorded cost before requesting another quote.</p>}
      <div className="creative-actions">{activeJob(job) && draft?.permissions.can_save && <button disabled={locked} onClick={() => jobAction("check", job)}>Check progress</button>}{job.permissions.can_cancel && <button disabled={locked} onClick={() => { if (window.confirm("Request cancellation? Work already started may still be charged.")) jobAction("cancel", job); }}>Cancel generation</button>}</div>
      {valid && job.output?.preview_url && (draft?.subject_user_id === user || ["accepted", "importing", "imported"].includes(job.status)) && <video key={previewKey} src={job.output.preview_url} controls preload="metadata" aria-label="Private Presenter output" onLoadedMetadata={event => { if (current() && Number.isFinite(event.currentTarget.duration) && event.currentTarget.duration > 0) { setLoadedOutput(v => ({ ...v, [job.id]: previewKey })); setPreviewErrors(v => v.filter(id => id !== job.id)); } }} onError={() => setPreviewErrors(v => v.includes(job.id) ? v : [...v, job.id])} />}
      {previewErrors.includes(job.id) && <p role="alert">Preview could not load. Check job status for a fresh preview before approving.</p>}
      {valid && job.permissions.can_review && draft?.subject_user_id === user && <div className="presenter-consent"><p>Review appearance, spoken words, audio, and property/background accuracy before accepting.</p><label><input type="checkbox" checked={reviewed === job.id} disabled={locked || !previewReady} onChange={e => setReviewed(e.target.checked ? job.id : "")} />I reviewed this exact generated video and approve using my likeness in it.</label><div className="creative-actions"><button disabled={locked || reviewed !== job.id || !previewReady} onClick={() => jobAction("accept", job, { output_sha256: job.output!.sha256, output_consent: true })}>Accept generated video</button><button disabled={locked} onClick={() => { if (window.confirm("Reject this generated video? It will not be added to property media.")) jobAction("reject", job); }}>Reject generated video</button></div></div>}
      {valid && job.permissions.can_import && job.status !== "imported" && <button disabled={locked} onClick={() => jobAction("import", job)}>{job.status === "importing" ? "Resume accepted video import" : "Add accepted video to property"}</button>}
      {valid && job.imported_asset_id && job.permissions.can_import && onUse && <button disabled={locked} onClick={() => onUse({ listingId: listing, assetId: job.imported_asset_id!, cutaways: [], script: draft?.script ?? "" })}>Open generated video in editor</button>}
    </article>; })}
  </section>;
}
