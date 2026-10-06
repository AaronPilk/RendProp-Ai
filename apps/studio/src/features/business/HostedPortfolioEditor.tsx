import { useEffect, useRef, useState } from "react";
import type { Listing, Workspace } from "../../data/contracts";
import { uuid } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { record, safeHTTPS } from "./model";
export type PortfolioSelection = { userId: string; orgId: string; revision: number; ids: string[]; url: string | null };
export function decodePortfolioSelection(raw: unknown, actor: string, org: string): PortfolioSelection {
  const r = record(raw);
  if (r.ok !== true || r.user_id !== actor || r.org_id !== org || !Number.isSafeInteger(r.revision) || Number(r.revision) < 0 || !Array.isArray(r.listing_ids) || r.listing_ids.length > 100) throw new Error("Your portfolio could not be confirmed. Reload before saving.");
  const ids = r.listing_ids.map(id => uuid(id)), url = r.portfolio_url === null ? null : safeHTTPS(r.portfolio_url);
  if (new Set(ids).size !== ids.length || r.portfolio_url !== null && !url) throw new Error("Your portfolio could not be confirmed. Reload before saving.");
  return { userId: actor, orgId: org, revision: Number(r.revision), ids, url };
}
const drafts = new WeakMap<StudioServices, Map<string, { saved: PortfolioSelection; ids: string[] }>>();
export default function HostedPortfolioEditor({ services, workspace, listings }: { services: StudioServices; workspace: Workspace; listings: Listing[] }) {
  const actor = workspace.user.id, org = workspace.org.id, key = `${actor}:${org}`, draft = drafts.get(services)?.get(key);
  const [saved, setSaved] = useState<PortfolioSelection | null>(draft?.saved ?? null), [ids, setIds] = useState<string[]>(draft?.ids ?? []), [busy, setBusy] = useState(false), [error, setError] = useState(""), [notice, setNotice] = useState("");
  const action = useRef<AbortController | null>(null), running = useRef(false);
  const dirty = !!saved && JSON.stringify(ids) !== JSON.stringify(saved.ids), canWrite = workspace.memberships.some(m => m.orgId === org && ["owner", "admin", "agent"].includes(m.role));
  const owned = listings.filter(listing => listing.agentId === actor);
  useEffect(() => { let all = drafts.get(services); if (!all) { all = new Map(); drafts.set(services, all); } if (saved && dirty) all.set(key, { saved, ids }); else all.delete(key); }, [services, key, saved, ids, dirty]);
  useEffect(() => { if (!dirty) return; const protect = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; }; window.addEventListener("beforeunload", protect); return () => window.removeEventListener("beforeunload", protect); }, [dirty]);
  async function load(signal: AbortSignal) { const next = decodePortfolioSelection(await services.api("/functions/v1/me/portfolio", { orgId: org, signal }), actor, org); if (!signal.aborted) { setSaved(next); setIds(next.ids); setError(""); } }
  useEffect(() => { const controller = new AbortController(); action.current = controller; if (!draft) { setBusy(true); void load(controller.signal).catch(reason => { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Your portfolio could not be loaded."); }).finally(() => { if (!controller.signal.aborted) setBusy(false); }); } return () => { controller.abort(); action.current?.abort(); }; }, [services, actor, org]);
  async function save() {
    if (!saved || busy || running.current || !canWrite) return;
    running.current = true; const controller = new AbortController(); action.current = controller; setBusy(true); setError(""); setNotice("");
    try { const next = decodePortfolioSelection(await services.api("/functions/v1/me/portfolio", { method: "PUT", orgId: org, body: { expected_revision: saved.revision, listing_ids: ids }, signal: controller.signal }), actor, org); if (controller.signal.aborted) return; if (JSON.stringify(next.ids) !== JSON.stringify(ids)) throw new Error("Your portfolio selection could not be confirmed. Your draft is kept."); setSaved(next); setNotice("Your selected listings are saved to your hosted portfolio."); }
    catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Your draft is kept. Please retry."); }
    finally { running.current = false; if (!controller.signal.aborted) setBusy(false); }
  }
  async function reload() { if (busy || dirty && !window.confirm("Reload your saved portfolio selection and discard this draft?")) return; const controller = new AbortController(); action.current = controller; setBusy(true); try { await load(controller.signal); } catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Your draft is kept."); } finally { if (!controller.signal.aborted) setBusy(false); } }
  return <section className="business-card" aria-label="Hosted portfolio selection"><h3>Choose your hosted portfolio listings</h3><p>Start with an empty portfolio, then choose your own published listings. Private links, client deliveries, sold and archived listings stay out. A listing also needs its public discovery permission. The server checks each selection when you Save.</p>{error && <p role="alert" className="business-notice error">{error}</p>}{notice && <p role="status" className="business-notice success">{notice}</p>}<fieldset disabled={busy || !saved || !canWrite}>{owned.map(listing => { const publicListing = !listing.soldAt && listing.status !== "archived" && [true, "true"].includes(listing.details.allow_indexing as boolean | string); return <label key={listing.id}><input type="checkbox" checked={ids.includes(listing.id)} disabled={!publicListing && !ids.includes(listing.id)} onChange={event => setIds(current => event.target.checked ? [...current, listing.id] : current.filter(id => id !== listing.id))} />{listing.address || listing.tagline || "Untitled listing"}{!publicListing && <small>Public discovery is off, or this listing is sold/archived.</small>}</label>; })}{ids.filter(id => !owned.some(listing => listing.id === id)).map(id => <label key={id}><input type="checkbox" checked onChange={() => setIds(current => current.filter(value => value !== id))} />Previously selected listing is no longer available — remove it from this selection.</label>)}</fieldset>{!owned.length && <p>No listings owned by your account are available in this workspace.</p>}<div className="business-actions"><button type="button" disabled={busy} onClick={() => void reload()}>Reload portfolio selection</button><button type="button" className="primary" disabled={busy || !saved || !canWrite || !dirty && saved.revision > 0} onClick={() => void save()}>{busy ? "Saving…" : "Save hosted portfolio selection"}</button>{saved?.url && <a href={saved.url} target="_blank" rel="noopener noreferrer">View your hosted portfolio ↗</a>}</div></section>;
}
