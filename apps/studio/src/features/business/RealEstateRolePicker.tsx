import { useEffect, useId, useRef, useState } from "react";
import type { StudioServices } from "../../data/services";
import type { RealEstateRole, Workspace } from "../../data/contracts";
import { businessApi } from "./api";
import "./business.css";

export default function RealEstateRolePicker({ workspace, services, onSaved, onboarding = false }: { workspace: Workspace; services: StudioServices; onSaved: () => void; onboarding?: boolean }) {
  const [role, setRole] = useState<RealEstateRole | "">(workspace.user.realEstateRole ?? ""), [saved, setSaved] = useState(workspace.user.realEstateRole ?? "");
  const [busy, setBusy] = useState(false), [error, setError] = useState(""), [notice, setNotice] = useState("");
  const active = useRef<AbortController | null>(null);
  const group = useId();
  useEffect(() => () => active.current?.abort(), []);
  useEffect(() => { setSaved(workspace.user.realEstateRole ?? ""); setRole(workspace.user.realEstateRole ?? ""); }, [workspace.user.realEstateRole]);
  if (workspace.org.spaceType !== "real_estate") return null;
  return <section className="business-card business-work-role" aria-label="Real estate work preference"><h3>{onboarding ? "What do you do in real estate?" : "Your real estate work"}</h3><p>{onboarding ? "We’ll tailor your workspace to the work you do. You can change this in Business → Account & plan." : "This changes your workspace guidance. Your team permissions and subscription stay the same."}</p>
    <fieldset className="business-stack" disabled={busy}><label className="business-check"><input type="radio" name={group} checked={role === "agent"} onChange={() => setRole("agent")} /> Agent</label><label className="business-check"><input type="radio" name={group} checked={role === "photographer_videographer"} onChange={() => setRole("photographer_videographer")} /> Photographer / videographer</label></fieldset>
    {role === "photographer_videographer" && <p>Publish for your clients using their contact card. Client leads stay in your inbox and can be emailed to them.</p>}
    {error && <p role="alert" className="business-notice error">{error}</p>}{notice && <p role="status" className="business-notice success">{notice}</p>}
    <button className="primary" disabled={busy || !role || role === saved} onClick={() => void (async () => {
      if (!role || active.current) return; const controller = new AbortController(); active.current = controller; setBusy(true); setError(""); setNotice("");
      try { await businessApi(services, workspace).saveWorkRole(role, controller.signal); if (!controller.signal.aborted) { setSaved(role); setNotice("Work preference saved across your phone and Studio."); onSaved(); } }
      catch (error) { if (!controller.signal.aborted) setError(error instanceof Error ? error.message : "Your work preference could not be saved."); }
      finally { if (active.current === controller) active.current = null; if (!controller.signal.aborted) setBusy(false); }
    })()}>{busy ? "Saving…" : onboarding ? "Continue" : "Save work preference"}</button>
  </section>;
}
