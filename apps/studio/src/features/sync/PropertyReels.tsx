import { useCallback, useEffect, useRef, useState } from "react";
import CloudEditor, {type CloudEditorProps} from "./CloudEditor";
import { scopeKey } from "../../workspace";

type Delivery = Pick<CloudEditorProps, "entryRequest" | "importRequest" | "importPlan" | "importAgentPlan">;
/** One mounted encoder at a time; each property has its own durable document. */
export default function PropertyReels(props: CloudEditorProps) {
  return <PropertyReelSession {...props} key={scopeKey(props.workspace.user.id, props.workspace.org.id)} />;
}
function PropertyReelSession(props: CloudEditorProps) {
  const allowed = (id?: string) => props.listings.some(listing => listing.id === id && listing.orgId === props.workspace.org.id);
  const first = allowed(props.listingId) ? props.listingId! : props.listings[0]?.id ?? "";
  const [selection, setSelection] = useState({id: first, delivery: {} as Delivery});
  const [message, setMessage] = useState("");
  const [pending, setPending] = useState<{id: string; delivery: Delivery} | null>(null);
  const guard = useRef<(() => Promise<void>) | null>(null), operation = useRef(0), mounted = useRef(true);
  const selected = useRef(selection.id); selected.current = selection.id;
  const received = useRef(new Set<string>());
  const register = useCallback((prepare: (() => Promise<void>) | null) => {guard.current = prepare;}, []);
  useEffect(() => () => {mounted.current = false; operation.current++; guard.current = null;}, []);
  async function open(id: string, delivery: Delivery = {}) {
    if (!allowed(id)) {setMessage("That property is no longer in this workspace. Choose an available property."); return;}
    const attempt = ++operation.current;
    if (id !== selected.current && guard.current) {
      try {await guard.current();}
      catch (error) {
        if (mounted.current && attempt === operation.current) {setPending({id, delivery}); setMessage(error instanceof Error ? error.message : "Finish saving this reel before opening another property.");}
        return;
      }
    }
    if (!mounted.current || attempt !== operation.current) return;
    const scopedDelivery = Object.fromEntries(Object.entries(delivery).filter(([, request]) => !request?.listingId || request.listingId === id)) as Delivery;
    selected.current = id; setSelection({id, delivery: scopedDelivery}); setPending(null); setMessage("");
  }
  useEffect(() => {
    const delivery: Delivery = {};
    let target: string | undefined;
    for (const name of ["entryRequest", "importRequest", "importPlan", "importAgentPlan"] as const) {
      const request = props[name]; if (!request || received.current.has(request.id)) continue;
      received.current.add(request.id); Object.assign(delivery, {[name]: request}); target = request.listingId ?? target;
    }
    if (Object.keys(delivery).length) void open(target ?? selected.current ?? first, delivery);
    else if (!selected.current && first) void open(first);
  }, [props.entryRequest, props.importRequest, props.importPlan, props.importAgentPlan, first]);
  return <div>
    <section className="panel sync-toolbar" aria-label="Property reels">
      <label>Property reel<select aria-label="Property reel" value={selection.id} onChange={event => void open(event.target.value)}><option value="" disabled>Choose a property</option>{props.listings.map(listing => <option key={listing.id} value={listing.id}>{listing.address || "Untitled property"}</option>)}</select></label>
      <p>Each property keeps its own reel. Your saved photos, timing and captions will be here when you return.</p>
      {message && <p role="status">{message}</p>}
      {pending && <div><button onClick={() => void open(pending.id, pending.delivery)}>Try opening {props.listings.find(listing => listing.id === pending.id)?.address || "that property"} again</button><button onClick={() => {setPending(null);setMessage("");}}>Stay with this reel</button></div>}
    </section>
    {allowed(selection.id) ? <CloudEditor {...props} {...selection.delivery} entryRequest={selection.delivery.entryRequest} importRequest={selection.delivery.importRequest} importPlan={selection.delivery.importPlan} importAgentPlan={selection.delivery.importAgentPlan} key={selection.id} listingId={selection.id} onPrepareSwitch={register} /> : <p>Choose or create a property to start its reel.</p>}
  </div>;
}
