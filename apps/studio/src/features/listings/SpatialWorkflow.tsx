import { useCallback, useEffect, useRef, useState } from "react";
import type { Listing, Workspace } from "../../data/contracts";
import { uuid } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { safeHTTPS } from "./model";
export type SpatialJob = { id: string; listing_id: string; room_label: string; status: string; progress: number; failure_code: string | null; viewer_url: string | null; share_url: string | null; artifact_revision: string | null; privacy_state: string; attempt_number: number; can_retry: boolean; can_cancel: boolean; can_resume: boolean };
export function decodeSpatialJob(raw: unknown, listingId: string): SpatialJob {
  if (!raw || typeof raw !== "object") throw new Error("The 3D room could not be read.");
  const row = raw as SpatialJob;
  uuid(row.id);
  if (row.listing_id !== listingId || !["uploading", "queued", "processing", "review", "ready", "failed"].includes(row.status) || !Number.isFinite(row.progress) || row.progress < 0 || row.progress > 1 || typeof row.room_label !== "string" || !row.room_label.trim() || !Number.isInteger(row.attempt_number) || row.attempt_number < 1 || row.attempt_number > 3) throw new Error("The 3D room returned incomplete progress.");
  if (["review", "ready"].includes(row.status)) uuid(row.artifact_revision);
  if (row.viewer_url && !safeHTTPS(row.viewer_url) || row.share_url && !safeHTTPS(row.share_url)) throw new Error("The 3D viewer address could not be verified.");
  if (row.share_url && (row.status !== "ready" || row.privacy_state !== "approved")) throw new Error("This 3D room has not been approved for sharing.");
  if (row.can_retry && (row.status !== "failed" || row.attempt_number >= 3) || row.can_cancel && !["uploading", "queued"].includes(row.status) || row.can_resume && (row.status !== "failed" || row.failure_code !== "user_cancelled")) throw new Error("The 3D room returned invalid recovery actions.");
  return row;
}
export async function spatialRetryKey(job: Pick<SpatialJob, "id" | "attempt_number">): Promise<string> {
  // Match the iPhone's per-attempt operation id: moving between devices cannot buy another retry.
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`rendprop-spatial-retry-v1:${job.id.toLowerCase()}:${job.attempt_number}`))).slice(0, 16);
  hash[6] = (hash[6] & 0x0f) | 0x50; hash[8] = (hash[8] & 0x3f) | 0x80;
  const hex = [...hash].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
const titles: Record<string, string> = { uploading: "Uploading from your phone", queued: "Waiting to generate", processing: "Building your 3D room", review: "Ready for private review", ready: "Ready to share", failed: "Needs attention" };
export default function SpatialWorkflow({ services, workspace, listing, canWrite }: { services: StudioServices; workspace: Workspace; listing: Listing; canWrite: boolean }) {
  const [jobs, setJobs] = useState<SpatialJob[]>([]), [error, setError] = useState(""), [busy, setBusy] = useState("");
  const [notice, setNotice] = useState(""), [reviewed, setReviewed] = useState<Record<string, boolean>>({}), [opened, setOpened] = useState<Record<string, boolean>>({});
  const [loading, setLoading] = useState(true), [capability, setCapability] = useState<boolean | null>(null);
  const pending = useRef<AbortController | null>(null), active = useRef<AbortController | null>(null), alive = useRef(true);
  const refresh = useCallback(async () => {
    pending.current?.abort(); const controller = new AbortController(); pending.current = controller;
    try {
      const response = await services.api(`/functions/v1/spatial?listing_id=${listing.id}`, { orgId: workspace.org.id, signal: controller.signal }) as { jobs?: unknown[] };
      if (!Array.isArray(response.jobs) || response.jobs.length > 100) throw new Error("3D rooms could not be loaded.");
      const values = response.jobs.map((job) => decodeSpatialJob(job, listing.id));
      if (!controller.signal.aborted) { setJobs(values); setError(""); }
    } catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "3D rooms could not be loaded."); }
    finally { if (!controller.signal.aborted) setLoading(false); }
  }, [services, workspace.org.id, listing.id]);
  useEffect(() => {
    alive.current = true; void refresh();
    const controller = new AbortController();
    void services.api("/functions/v1/spatial/capability", { orgId: workspace.org.id, signal: controller.signal }).then((raw) => { if (!controller.signal.aborted) setCapability((raw as { enabled?: boolean }).enabled === true); }, () => {});
    const timer = setInterval(() => { if (document.visibilityState === "visible") void refresh(); }, 30_000);
    return () => { alive.current = false; clearInterval(timer); controller.abort(); pending.current?.abort(); active.current?.abort(); };
  }, [refresh, services, workspace.org.id]);
  const action = async (job: SpatialJob, kind: "retry" | "resume" | "cancel" | "review" | "publish", approve = false) => {
    if (active.current) return;
    const controller = new AbortController(); active.current = controller; setBusy(job.id); setError(""); setNotice("");
    try {
      const body = kind === "review" ? { artifact_revision: job.artifact_revision, approved: approve, exclude_room: !approve, redactions: [] } : kind === "publish" ? { artifact_revision: job.artifact_revision } : {};
      const raw = await services.api(`/functions/v1/spatial/${job.id}/${kind}`, { method: "POST", orgId: workspace.org.id, body, signal: controller.signal, idempotencyKey: kind === "retry" ? await spatialRetryKey(job) : undefined });
      const result = decodeSpatialJob(raw, listing.id);
      if (!controller.signal.aborted) { setJobs((all) => all.map((j) => j.id === result.id ? result : j)); setNotice(kind === "publish" ? "3D room published." : kind === "review" ? approve ? "Privacy review saved. You can now publish this room." : "Room excluded from sharing." : "Room status updated."); }
    } catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "The room action did not finish."); }
    finally { if (active.current === controller) active.current = null; if (alive.current) setBusy(""); }
  };
  return <section className="lw-card"><div className="lw-title"><div><h3>3D rooms from your phone</h3><p>Check processing, privately review each room, and choose when to share.</p></div><button onClick={() => void refresh()} disabled={loading}>Refresh rooms</button></div>{capability === false && <p className="lw-notice">New 3D generation is currently unavailable for this workspace. Existing rooms remain here.</p>}{error && <p role="alert" className="lw-error">{error}</p>}{notice && <p role="status" className="lw-notice">{notice}</p>}{loading ? <p role="status">Loading 3D rooms…</p> : jobs.length === 0 ? <p className="lw-muted">Capture a 3D room in the iPhone app. Its upload and processing progress will appear here.</p> : jobs.map((job) => {
    const revision = `${job.id}:${job.artifact_revision}`;
    const canReview = job.status === "review" || job.status === "ready";
    return <article className="lw-spatial-room" key={job.id}><div><h4>{job.room_label}</h4><span>{titles[job.status]}</span></div>{["uploading", "queued", "processing"].includes(job.status) && <progress max={1} value={job.progress} />}{job.failure_code && <p>{job.failure_code.replaceAll("_", " ")}</p>}<div className="lw-actions">{job.viewer_url && <a href={job.viewer_url} target="_blank" rel="noreferrer" onClick={() => setOpened((all) => ({ ...all, [revision]: true }))}>Open private 3D review ↗</a>}{job.share_url && <a href={job.share_url} target="_blank" rel="noreferrer">Open shared 3D room ↗</a>}{job.can_retry && <button disabled={!canWrite || !!busy} onClick={() => void action(job, "retry")}>Retry generation · uses allowance</button>}{job.can_resume && <button disabled={!canWrite || !!busy} onClick={() => void action(job, "resume")}>Resume room</button>}{job.can_cancel && <button disabled={!canWrite || !!busy} onClick={() => void action(job, "cancel")}>Cancel this room</button>}</div>{canReview && canWrite && <div className="lw-spatial-review"><p>Before publishing, check for people, personal documents, and private belongings in the 3D viewer.</p><label className="lw-check"><input type="checkbox" disabled={!opened[revision]} checked={!!reviewed[revision]} onChange={(e) => setReviewed((all) => ({ ...all, [revision]: e.target.checked }))} />I opened this version and reviewed the entire room for privacy.</label><div className="lw-actions"><button disabled={!!busy || !reviewed[revision]} onClick={() => void action(job, "review", true)}>Approve this room</button><button disabled={!!busy} onClick={() => void action(job, "review", false)}>Exclude room from sharing</button>{job.privacy_state === "approved" && !job.share_url && <button className="primary" disabled={!!busy || !reviewed[revision]} onClick={() => void action(job, "publish")}>Publish 3D room</button>}</div><p className="lw-help">If sensitive details are visible, exclude the room and capture it again after removing them.</p></div>}</article>;
  })}</section>;
}
