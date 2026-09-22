import type { ListingDestination, ListingFinish } from "./readiness";

const labels = { saved: "Saved", optional: "Optional", review: "Review", waiting: "Next", live: "Live" };
export default function FinishListing({ finish, canWrite, busy, onNavigate, onPhotos }: {
  finish: ListingFinish; canWrite: boolean; busy: boolean;
  onNavigate: (destination: ListingDestination) => void;
  onPhotos?: () => void;
}) {
  return <section className="lw-finish" aria-labelledby="lw-finish-title" aria-busy={finish.checking}>
    <div className="lw-finish-heading"><div><p className="eyebrow">Pick up where you left off</p><h2 id="lw-finish-title">Finish this listing</h2></div>{finish.publishedLinks && <a className="lw-finish-live" href={finish.publishedLinks.branded} target="_blank" rel="noreferrer">Open live property ↗</a>}</div>
    <div className="lw-finish-next"><div><h3>{finish.title}</h3><p>{finish.detail}</p></div>{finish.next && <button className="primary" disabled={busy || (finish.next.requiresWrite && !canWrite)} onClick={() => finish.next && onNavigate(finish.next.destination)}>{finish.next.label}</button>}</div>
    {finish.progress !== null && <div className="lw-finish-progress"><progress aria-label="Tour preparation progress" max={1} value={finish.progress} /><span>{Math.round(finish.progress * 100)}% reported by processing</span></div>}
    {finish.steps.length > 0 && <ol className="lw-finish-checklist">{finish.steps.map(step => <li key={step.id} data-step={step.id} data-status={step.status}><span className={`lw-finish-badge is-${step.status}`}>{labels[step.status]}</span><div><h3>{step.title}</h3><p>{step.detail}</p><button className="text-button" disabled={busy || (step.action.requiresWrite && !canWrite)} onClick={() => onNavigate(step.action.destination)}>{step.action.label} <span aria-hidden="true">→</span></button>{step.id === "create" && onPhotos && <button className="text-button" disabled={busy || !canWrite} onClick={onPhotos}>Open AI Photo Studio <span aria-hidden="true">→</span></button>}</div></li>)}</ol>}
    {!canWrite && <p className="lw-help">You can view and download available media. An owner, admin or agent can edit and publish.</p>}
  </section>;
}
