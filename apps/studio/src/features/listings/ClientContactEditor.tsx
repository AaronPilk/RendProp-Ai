import { useCallback, useEffect, useRef, useState } from "react";
import type { StudioServices } from "../../data/services";
import { uploadListingAsset } from "./uploads";
import { clientContactPayload, clientForm, decodeClientContact, type ClientContact, type ClientForm } from "./client-contact";

type Props = { services: StudioServices; orgId: string; listingId: string; canWrite: boolean; onBlocked: (blocked: boolean) => void; onChanged: () => void };
const failure = (error: unknown) => error instanceof Error ? error.message : "The listing contact could not be saved. Please try again.";
export default function ClientContactEditor({ services, orgId, listingId, canWrite, onBlocked, onChanged }: Props) {
  const [saved, setSaved] = useState<ClientContact | null>(null), [form, setForm] = useState<ClientForm>(clientForm(null));
  const [loaded, setLoaded] = useState(false), [loading, setLoading] = useState(true), [busy, setBusy] = useState(false), [error, setError] = useState("");
  const [conflict, setConflict] = useState(false), [notice, setNotice] = useState("");
  const current = useRef(form), baseline = useRef(form), active = useRef<AbortController | null>(null), input = useRef<HTMLInputElement>(null);
  current.current = form;
  const dirty = JSON.stringify(form) !== JSON.stringify(baseline.current);
  const path = `/functions/v1/listings/${listingId}/client-contact`;
  useEffect(() => { onBlocked(!loaded || loading || busy || dirty || conflict || !!error); }, [loaded, loading, busy, dirty, conflict, error, onBlocked]);
  const load = useCallback(async (discard = false) => {
    if (active.current) return;
    const controller = new AbortController(); active.current = controller; setLoading(true); setError("");
    try {
      const contact = decodeClientContact(await services.api(path, { orgId, signal: controller.signal }), listingId);
      if (controller.signal.aborted) return;
      const hasEdits = JSON.stringify(current.current) !== JSON.stringify(baseline.current);
      if (hasEdits && !discard) {
        if (contact?.revision !== saved?.revision) setConflict(true);
      } else { const value = clientForm(contact); baseline.current = value; current.current = value; setForm(value); setSaved(contact); setConflict(false); setNotice(""); }
      setLoaded(true);
    } catch (error) { if (!controller.signal.aborted) setError(failure(error)); }
    finally { if (active.current === controller) active.current = null; if (!controller.signal.aborted) setLoading(false); }
  }, [services, path, orgId, listingId, saved?.revision]);
  useEffect(() => { void load(); return () => { active.current?.abort(); active.current = null; }; }, [services, path, orgId, listingId]);
  useEffect(() => { const refresh = () => { if (document.visibilityState === "visible") void load(); }; window.addEventListener("focus", refresh); return () => window.removeEventListener("focus", refresh); }, [load]);
  useEffect(() => { if (!dirty) return; const protect = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; }; window.addEventListener("beforeunload", protect); return () => window.removeEventListener("beforeunload", protect); }, [dirty]);
  const update = (next: Partial<ClientForm>) => { onBlocked(true); setForm(value => ({ ...value, ...next })); setNotice(""); };
  const save = async () => {
    if (active.current || !canWrite || !loaded || conflict) return;
    const controller = new AbortController(); active.current = controller; setBusy(true); setError(""); setNotice("");
    try {
      const body = clientContactPayload(form, saved?.revision ?? 0);
      const contact = decodeClientContact(await services.api(path, { method: "PUT", orgId, body, signal: controller.signal }), listingId);
      if (controller.signal.aborted) return;
      if (!contact || contact.revision <= (saved?.revision ?? 0) || contact.enabled !== body.enabled || contact.recipient_email !== body.recipient_email || contact.hide_rendprop_branding !== body.hide_rendprop_branding || (contact.photo_asset_id ?? null) !== body.photo_asset_id || Object.entries(body.public_card).some(([key, value]) => contact.public_card[key as keyof typeof contact.public_card] !== value)) throw new Error("The saved contact could not be confirmed. Refresh and review it before publishing.");
      const value = clientForm(contact); baseline.current = value; current.current = value; setSaved(contact); setForm(value); setConflict(false); setNotice(contact.enabled ? `Client contact saved. New inquiries will be emailed to ${contact.recipient_email} and kept in your lead inbox.` : "This listing uses your account’s contact card."); onChanged();
    } catch (error) { if (!controller.signal.aborted) { setError(failure(error)); if (/changed|conflict|revision/i.test(failure(error))) setConflict(true); } }
    finally { if (active.current === controller) active.current = null; if (!controller.signal.aborted) setBusy(false); }
  };
  const uploadPhoto = async (file: File) => {
    if (active.current || !canWrite) return;
    const controller = new AbortController(); active.current = controller; setBusy(true); setError(""); setNotice("");
    try {
      const asset = await uploadListingAsset(services, { orgId, listingId, file, role: "contact_photo", signal: controller.signal });
      if (!controller.signal.aborted) { update({ photo_asset_id: asset.assetId, avatar_url: null }); setNotice("Photo uploaded. Save the client contact to put it on the listing."); }
    } catch (error) { if (!controller.signal.aborted) setError(failure(error)); }
    finally { if (active.current === controller) active.current = null; if (!controller.signal.aborted) setBusy(false); }
  };
  const fields: { key: keyof ClientForm["public_card"]; label: string; type?: string }[] = [
    { key: "name", label: "Client name or business name" }, { key: "brokerage", label: "Brokerage or business" }, { key: "title", label: "Professional title" },
    { key: "phone", label: "Client public phone", type: "tel" }, { key: "email", label: "Client public email", type: "email" },
    { key: "website", label: "Client website", type: "url" }, { key: "instagram", label: "Client Instagram link", type: "url" }, { key: "linkedin", label: "Client LinkedIn link", type: "url" },
  ];
  const recipient = form.separate_recipient ? form.recipient_email : form.public_card.email;
  return <section className="lw-card" aria-label="Listing contact"><h3>Who should buyers contact?</h3><p>Choose whose name and contact details appear at the bottom of this property’s marketing page.</p>
    {loading && <p role="status">Loading listing contact…</p>}{error && <p className="lw-error" role="alert">{error}</p>}
    {conflict && <p className="lw-notice" role="alert">This contact changed on another device. Your edits are kept. Reload the saved contact before trying again.</p>}
    {(error || conflict) && <button type="button" disabled={busy || loading} onClick={() => { if (!dirty || window.confirm("Discard your unsaved contact changes and load the saved contact?")) void load(true); }}>Reload saved contact</button>}
    <fieldset disabled={!canWrite || !loaded || loading || busy || conflict} className="lw-contact-fields"><legend className="business-sr-only">Listing contact choice</legend>
      <label><input type="radio" name={`contact-${listingId}`} checked={!form.enabled} onChange={() => update({ enabled: false })} /> My account</label>
      <label><input type="radio" name={`contact-${listingId}`} checked={form.enabled} onChange={() => update({ enabled: true })} /> My client</label>
      {form.enabled && <><p className="lw-help">Your client does not need a Rendprop account. Your account keeps ownership of this property and its leads.</p>
        <div className="lw-form-grid">{fields.filter(field => ["name", "brokerage", "phone", "email"].includes(field.key)).map(field => <label key={field.key}>{field.label}<input type={field.type ?? "text"} maxLength={field.key === "name" ? 120 : 300} value={form.public_card[field.key]} onChange={event => update({ public_card: { ...form.public_card, [field.key]: event.target.value } })} /></label>)}</div>
        <details><summary>More contact details (optional)</summary><div className="lw-form-grid">{fields.filter(field => !["name", "brokerage", "phone", "email"].includes(field.key)).map(field => <label key={field.key}>{field.label}<input type={field.type ?? "text"} maxLength={300} value={form.public_card[field.key]} onChange={event => update({ public_card: { ...form.public_card, [field.key]: event.target.value } })} placeholder={field.type === "url" ? "https://" : undefined} /></label>)}</div></details>
        <input ref={input} type="file" accept="image/jpeg,image/png,image/webp,.jpg,.jpeg,.png,.webp" hidden onChange={event => { const file = event.target.files?.[0]; event.target.value = ""; if (file) void uploadPhoto(file); }} />
        <div className="lw-actions"><button type="button" onClick={() => input.current?.click()}>{form.photo_asset_id ? "Replace client photo" : "Upload client photo"}</button>{form.photo_asset_id && <button type="button" onClick={() => update({ photo_asset_id: null, avatar_url: null })}>Remove client photo</button>}</div>
        <label><input type="checkbox" checked={form.separate_recipient} onChange={event => update({ separate_recipient: event.target.checked, recipient_email: form.recipient_email || form.public_card.email })} /> Send leads to a different email</label>
        {form.separate_recipient && <label>Private lead delivery email<input aria-label="Private lead delivery email" type="email" maxLength={200} value={form.recipient_email} onChange={event => update({ recipient_email: event.target.value })} /><small>This delivery address is not shown on the public listing.</small></label>}
        <label><input type="checkbox" checked={form.hide_rendprop_branding} onChange={event => update({ hide_rendprop_branding: event.target.checked })} /> Hide Rendprop logos and app promotions</label>
        <p className="lw-help">The page still uses a rendprop.com address and identifies the service in its privacy disclosure. The MLS link keeps all contact details and forms hidden.</p>
        <aside className="lw-contact-preview" aria-label="Client contact preview">{form.avatar_url && <img src={form.avatar_url} alt={form.public_card.name || "Client photo"} referrerPolicy="no-referrer" />}<strong>{form.public_card.name || "Your client’s name"}</strong><span>{[form.public_card.title, form.public_card.brokerage].filter(Boolean).join(" · ")}</span><span>{form.public_card.phone}</span><span>{form.public_card.email}</span>{form.photo_asset_id && !form.avatar_url && <small>New photo will appear after you save.</small>}<p>New inquiries → <strong>{recipient || "Add a lead delivery email"}</strong></p></aside>
      </>}
    </fieldset>
    {notice && <p role="status" className="lw-notice">{notice}</p>}
    <div className="lw-actions"><button type="button" className="primary" disabled={!canWrite || !loaded || !dirty || loading || busy || conflict} onClick={() => void save()}>{busy ? "Saving…" : "Save listing contact"}</button>{dirty && <p className="lw-help">Save this contact before publishing.</p>}</div>
  </section>;
}
