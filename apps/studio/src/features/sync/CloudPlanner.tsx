import { useEffect, useRef, useState } from "react";
import Planner from "../../Planner";
import { downloadBlob, planBackupFile, scopeKey, validatePlans, type PlanItem } from "../../workspace";
import { canonicalDocument, DocumentSync, type SyncState } from "../../data/documents";
import type { StudioServices, Workspace } from "../../data";
import { acknowledgePlannerPlans, keepPlannerRecovery, openPlannerRecovery, removePlannerRecovery, samePlans, writePendingPlans, type PlannerRecovery } from "./planner-recovery";
import SyncStatus from "./SyncStatus";
import "./planner-recovery.css";

export default function CloudPlanner({ services, workspace, onNotice }: { services: StudioServices; workspace: Workspace; onNotice: (message: string) => void }) {
  const [items, setItems] = useState<PlanItem[]>([]), [ready, setReady] = useState(false), [state, setState] = useState<SyncState>("loading");
  const [copies, setCopies] = useState<PlannerRecovery[]>([]), [review, setReview] = useState<{ copy: PlannerRecovery; snapshot: string } | null>(null);
  const sync = useRef<DocumentSync | null>(null), currentItems = useRef<PlanItem[]>([]), pending = useRef<PlanItem[] | null>(null);
  const editorId = useRef(crypto.randomUUID()), notice = useRef(onNotice); notice.current = onNotice;
  const localKey = `${scopeKey(workspace.user.id, workspace.org.id)}:plans`;

  function acknowledge(plans: PlanItem[]) {
    try {
      acknowledgePlannerPlans(localStorage, localKey, plans);
      setCopies(previous => previous.filter(copy => !samePlans(copy.items, plans)));
    } catch { notice.current("Your account plan saved. This browser's recovery copy could not be cleared and is still preserved."); }
  }

  useEffect(() => {
    let active = true, initialized = false;
    setReady(false); setState("loading"); setCopies([]); setReview(null); pending.current = null;
    const session = new DocumentSync(services, workspace.org.id, "planner", next => {
      if (!active) return;
      setState(next);
      // open() reports saved before reconciliation. That does not acknowledge an
      // earlier interrupted browser save.
      if (initialized && next === "saved" && pending.current) {
        const confirmed = pending.current; pending.current = null; acknowledge(confirmed);
      }
    });
    sync.current = session;
    const unload = (event: BeforeUnloadEvent) => { if (session.hasUnsavedWork) { event.preventDefault(); event.returnValue = ""; } };
    const focus = () => { if (document.visibilityState === "visible") void session.checkRemote(); };
    window.addEventListener("beforeunload", unload); window.addEventListener("focus", focus); document.addEventListener("visibilitychange", focus);
    void session.open().then(doc => {
      if (!active) return;
      const cloud = doc ? validatePlans(doc.payload.items) : null;
      let plans = cloud ?? [], migrate = false;
      try {
        const recovery = openPlannerRecovery(localStorage, localKey, cloud);
        plans = recovery.items; migrate = recovery.migrate;
        setCopies(recovery.copies);
        if (recovery.unreadable) notice.current("An earlier browser backup could not be read. Its original copy is preserved.");
      } catch { notice.current("Browser backup storage is unavailable. Your saved account plan is still available."); }
      currentItems.current = plans; setItems(plans); setReady(true); initialized = true;
      if (migrate) {
        // The initial GET established revision zero. Queue legacy data with CAS
        // so a second device can actually open it. Recovery already journaled it.
        pending.current = plans; session.queue({ items: plans }); void session.flush();
      }
    }).catch(error => { if (active) { setState("offline"); notice.current(error instanceof Error ? error.message : "Saved plans could not be opened."); } });
    return () => {
      active = false; session.dispose(); if (sync.current === session) sync.current = null;
      window.removeEventListener("beforeunload", unload); window.removeEventListener("focus", focus); document.removeEventListener("visibilitychange", focus);
    };
  }, [services, workspace.user.id, workspace.org.id, localKey]);

  function save(next: PlanItem[]) {
    const plans = validatePlans(next), session = sync.current;
    if (!session || !ready) throw new Error("Wait for your account plan to open before saving.");
    try { writePendingPlans(localStorage, localKey, editorId.current, plans); }
    catch { throw new Error("This browser could not preserve a recovery copy. Free some browser storage and save again; your open changes have been kept."); }
    currentItems.current = plans; pending.current = plans; setItems(plans); session.queue({ items: plans });
    if (session.state === "saved" && !session.hasUnsavedWork) { pending.current = null; acknowledge(plans); }
    else void session.flush();
  }

  function useRecovery() {
    if (!review) return;
    try {
      if (state !== "saved") throw new Error("Finish syncing or reload the latest account plan before choosing a recovery copy.");
      if (canonicalDocument(currentItems.current) !== review.snapshot) throw new Error("The account plan changed while you were reviewing. Review this copy again before replacing it.");
      if (currentItems.current.length && !samePlans(currentItems.current, review.copy.items)) {
        const previous = keepPlannerRecovery(localStorage, localKey, currentItems.current);
        setCopies(value => value.some(copy => samePlans(copy.items, previous.items)) ? value : [...value, previous]);
      }
      save(review.copy.items); setReview(null);
      notice.current("The reviewed browser copy is queued to your account. The previous account plan is kept as a recovery copy.");
    } catch (error) { notice.current(error instanceof Error ? error.message : "The recovery copy could not be applied."); }
  }

  function discard(copy: PlannerRecovery) {
    if (!window.confirm("Discard this browser recovery copy? Your current account plan will stay as it is.")) return;
    try {
      removePlannerRecovery(localStorage, copy);
      setCopies(value => value.filter(candidate => candidate !== copy));
      if (review?.copy === copy) setReview(null);
      notice.current("Browser recovery copy discarded. Your account plan is unchanged.");
    } catch { notice.current("The recovery copy could not be removed. It is still preserved."); }
  }

  function download(copy: PlannerRecovery) {
    try { const file = planBackupFile(copy.items); downloadBlob(new Blob([file.text], { type: "application/json;charset=utf-8" }), file.filename); }
    catch (error) { notice.current(error instanceof Error ? error.message : "The recovery backup could not be downloaded."); }
  }

  return <>
    <div className="panel sync-toolbar"><SyncStatus state={state} retry={() => { if (ready) void sync.current?.retry(); else window.location.reload(); }} reload={() => window.location.reload()} /></div>
    {ready && copies.length > 0 && <section className="panel planner-recovery" aria-label="Plan recovery">
      <h2>Browser recovery copies</h2>
      <p>These copies differ from your saved account plan. Review a copy before replacing the account plan, or download it for safekeeping.</p>
      {copies.map(copy => <div className="planner-recovery-copy" key={copy.keys[0]}>
        <p><strong>{copy.pending ? "Interrupted browser save" : "Earlier plan copy"}</strong> · {copy.items.length} {copy.items.length === 1 ? "plan" : "plans"}{copy.items[0] ? ` · ${copy.items[0].title}` : " · Empty queue"}</p>
        <div className="planner-recovery-actions"><button onClick={() => setReview({ copy, snapshot: canonicalDocument(currentItems.current) })}>Review copy</button><button onClick={() => download(copy)}>Download copy</button><button disabled={state === "saving"} onClick={() => discard(copy)}>Discard copy</button></div>
      </div>)}
      {review && <div className="planner-recovery-review" aria-label="Recovery review">
        <h3>Review browser plans</h3><p>Compare these {review.copy.items.length} plans with the {items.length} account plans below. Replacing changes the whole queue. The current account plan will be kept as another recovery copy.</p>
        {review.copy.items.length ? <ul>{review.copy.items.map(item => <li key={item.id}><strong>{item.title}</strong><p>{item.channel} · {item.date}</p><p>{item.caption}</p></li>)}</ul> : <p>This copy clears the planned content queue.</p>}
        <div className="planner-recovery-actions"><button disabled={state !== "saved"} onClick={useRecovery}>Replace account plan with this copy</button><button onClick={() => setReview(null)}>Cancel review</button></div>
      </div>}
    </section>}
    {ready ? <Planner items={items} onSave={save} onNotice={onNotice} connected /> : <p role="status">Opening your saved content plan…</p>}
  </>;
}
