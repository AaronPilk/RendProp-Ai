import { useEffect, useRef, useState } from "react";
import type { StudioServices } from "../../data/services";
import type { Workspace } from "../../data/contracts";
import { decodePersonalCard, PERSONAL_FIELDS, personalCardBody, personalCardConfirmed, personalCardValues, type PersonalCard, type PersonalKey } from "./personal-card";

type Draft = { saved: PersonalCard; values: Record<PersonalKey, string>; spaceType: string };
const drafts = new WeakMap<StudioServices, Map<string, Draft>>();
const labels: Record<PersonalKey, string> = { name: "Display name", title: "Professional title", brokerage: "Brokerage or business", phone: "Public phone", email: "Public email", website: "Website", instagram: "Instagram link", linkedin: "LinkedIn link", tiktok: "TikTok link" };
export default function PersonalCardEditor({ services, workspace }: { services: StudioServices; workspace: Workspace }) {
  const actor = workspace.user.id, draft = drafts.get(services)?.get(actor);
  const [saved, setSaved] = useState<PersonalCard | null>(draft?.saved ?? null), [values, setValues] = useState<Record<PersonalKey, string> | null>(draft?.values ?? null);
  const [spaceType, setSpaceType] = useState(draft?.spaceType ?? workspace.org.spaceType), [busy, setBusy] = useState(false), [error, setError] = useState(""), [notice, setNotice] = useState("");
  const action = useRef<AbortController | null>(null), running = useRef(false);
  const dirty = !!(saved && values && Object.keys(personalCardBody(saved, values, spaceType).changes).length);
  useEffect(() => {
    if (!saved || !values) return;
    let owned = drafts.get(services); if (!owned) { owned = new Map(); drafts.set(services, owned); }
    if (dirty) owned.set(actor, { saved, values, spaceType }); else owned.delete(actor);
  }, [services, actor, saved, values, spaceType, dirty]);
  useEffect(() => { if (!dirty) return; const protect = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; }; window.addEventListener("beforeunload", protect); return () => window.removeEventListener("beforeunload", protect); }, [dirty]);
  async function load(signal: AbortSignal) {
    const next = decodePersonalCard(await services.api("/functions/v1/me/card", { orgId: workspace.org.id, signal }), actor);
    if (signal.aborted) return;
    setSaved(next); setValues(personalCardValues(next)); setSpaceType(next.spaceType ?? workspace.org.spaceType); setError("");
  }
  useEffect(() => {
    const controller = new AbortController(); action.current = controller;
    if (!draft) { setBusy(true); void load(controller.signal).catch(reason => { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Your card could not be loaded."); }).finally(() => { if (!controller.signal.aborted) setBusy(false); }); }
    return () => { controller.abort(); action.current?.abort(); };
  }, [services, actor]);
  async function save(event: React.FormEvent) {
    event.preventDefault(); if (running.current || busy || !saved || !values || !dirty) return;
    running.current = true; const controller = new AbortController(); action.current = controller; setBusy(true); setError(""); setNotice("");
    try {
      const body = personalCardBody(saved, values, spaceType);
      const next = decodePersonalCard(await services.api("/functions/v1/me/card", { method: "PATCH", orgId: workspace.org.id, body, signal: controller.signal }), actor);
      if (controller.signal.aborted) return;
      if (!personalCardConfirmed(next, body.changes)) throw new Error("Your saved card could not be confirmed. Your draft is kept; reload and review it.");
      setSaved(next); setValues(personalCardValues(next)); setNotice("Personal card saved to your account.");
    } catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Your draft is kept. Please retry."); }
    finally { running.current = false; if (!controller.signal.aborted) setBusy(false); }
  }
  async function reload() {
    if (busy || running.current || dirty && !window.confirm("Reload your saved personal card and discard this draft?")) return;
    const controller = new AbortController(); action.current = controller; setBusy(true);
    try { await load(controller.signal); } catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Your draft is kept."); } finally { if (!controller.signal.aborted) setBusy(false); }
  }
  return <form className="business-card" onSubmit={event => void save(event)} aria-label="Personal contact card"><h3>Your personal contact card</h3><p>Your saved name and public contact details follow your account when you switch teams. Review each field, then Save. Your sign-in email is private unless you enter it here.</p>{error && <p className="business-notice error" role="alert">{error}</p>}{notice && <p className="business-notice success" role="status">{notice}</p>}{values ? <fieldset className="business-form-grid" disabled={busy}>{PERSONAL_FIELDS.map(key => <label key={key}>{labels[key]}<input value={values[key]} type={key === "email" ? "email" : key === "phone" ? "tel" : key.endsWith("site") || ["instagram", "linkedin", "tiktok"].includes(key) ? "url" : "text"} maxLength={key === "website" ? 2048 : 500} onChange={event => { setValues(current => ({ ...current!, [key]: event.target.value })); setNotice(""); }} /></label>)}<label>Card business type<select value={spaceType} onChange={event => setSpaceType(event.target.value)}>{["real_estate", "venue", "restaurant", "retail", "fitness", "other"].map(type => <option key={type} value={type}>{type.replaceAll("_", " ")}</option>)}</select></label></fieldset> : <p role="status">{busy ? "Loading your personal card…" : "Reload to open your saved card."}</p>}<div className="business-save-bar"><span>{dirty ? "Unsaved personal card changes" : "Account-owned card"}</span><button type="button" onClick={() => void reload()} disabled={busy}>Reload personal card</button><button className="primary" type="submit" disabled={busy || !dirty}>{busy ? "Saving…" : "Save personal card"}</button></div></form>;
}
