import { useCallback, useEffect, useRef, useState } from "react";
import type { Listing, Workspace } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import type { AgentPlanHandoff } from "../creative/model";
import { approvedDraft, approvedProfile, confirmsAction, decodePresenter, decodePreviews, formOf, FORMATS, newDraft, sameForm, type Action, type Draft, type DraftForm, type PresenterState, type Preview } from "./model";
import "./presenter.css";
import PresenterJobs from "./PresenterJobs";

type Props = { services: StudioServices; workspace: Workspace; listing: Listing; onChanged: () => void; onPendingChange?: (pending: boolean, busy?: boolean) => void; onUseAgentPlan?: (plan: AgentPlanHandoff) => void };
const message = (error: unknown) => error instanceof Error ? error.message : "Presenter could not finish this action. Please retry.";

export default function PresenterPanel({ services, workspace, listing, onChanged, onPendingChange, onUseAgentPlan }: Props) {
  const org = workspace.org.id, user = workspace.user.id, listingId = listing.id;
  const [data, setData] = useState<PresenterState | null>(null), [form, setForm] = useState<DraftForm>(() => newDraft()), [base, setBase] = useState<Draft>();
  const [dirty, setDirty] = useState(false), [profileDirty, setProfileDirty] = useState(false), [profileOpen, setProfileOpen] = useState(false);
  const [name, setName] = useState(workspace.user.name ?? ""), [referenceIds, setReferenceIds] = useState<string[]>([]), [page, setPage] = useState(0);
  const [jobBusy, setJobBusy] = useState(false);
  const [busy, setBusy] = useState(false), [error, setError] = useState(""), [notice, setNotice] = useState(""), [conflict, setConflict] = useState(false);
  const [uncertain, setUncertain] = useState<Action | null>(null), [likenessConsent, setLikenessConsent] = useState(false), [performanceConsent, setPerformanceConsent] = useState(false);
  const [previews, setPreviews] = useState<Preview[]>([]), [profilePreviews, setProfilePreviews] = useState<Preview[]>([]), [sourcePreview, setSourcePreview] = useState<Preview | null>(null);
  const [previewError, setPreviewError] = useState(""), [previewRetry, setPreviewRetry] = useState(0);
  const alive = useRef(true), abort = useRef(new AbortController()), running = useRef(false), initial = useRef(true), version = useRef(services.getSnapshot().identityVersion);
  const own = data?.profiles.find(profile => profile.subject_user_id === user);
  const selectedProfile = data?.profiles.find(profile => profile.id === form.profile_id);
  const source = data?.source_candidates.find(candidate => candidate.asset_id === form.source_asset_id);
  const pending = dirty || profileDirty || busy || jobBusy || !!uncertain;
  const locked = busy || jobBusy || !!uncertain || conflict;
  const canEdit = !!data && (base ? base.permissions.can_save : data.permissions.can_create_draft);
  const scopeCurrent = useCallback(() => {
    const identity = services.getSnapshot();
    return alive.current && !abort.current.signal.aborted && identity.status === "signed-in" && identity.identity?.userId === user && identity.identityVersion === version.current;
  }, [services, user]);
  const api = useCallback((path = "", body?: unknown) => services.api(`/functions/v1/studio/presenter${path}`, {
    orgId: org, signal: abort.current.signal, ...(path === "/jobs" ? { timeoutMs: 180_000 } : {}), method: body === undefined ? "GET" : "POST", ...(body === undefined ? {} : { body: { listing_id: listingId, ...body as object } }),
  }), [services, org, listingId]);
  const read = useCallback(async () => decodePresenter(await api(`?${new URLSearchParams({ listing_id: listingId })}`), org, listingId), [api, org, listingId]);
  useEffect(() => {
    let active = true; alive.current = true; abort.current = new AbortController();
    const unsubscribe = services.subscribe(() => {
      if (scopeCurrent()) return;
      abort.current.abort(); setData(null); setForm(newDraft()); setReferenceIds([]); setPreviews([]); setProfilePreviews([]); setSourcePreview(null);
      setError("Your account changed. Reopen Presenter in the current workspace.");
    });
    void read().then(next => {
      if (!active || !scopeCurrent()) return;
      setData(next);
      const first = next.drafts[0];
      if (first) { setForm(formOf(first)); setBase(first); }
      else setForm(value => ({ ...value, profile_id: next.profiles.find(p => p.subject_user_id === user)?.id ?? next.profiles[0]?.id ?? "" }));
      initial.current = false;
    }).catch(e => { if (active && scopeCurrent()) setError(message(e)); });
    return () => { active = false; alive.current = false; abort.current.abort(); unsubscribe(); };
  }, [read, services, scopeCurrent, user]);
  useEffect(() => { onPendingChange?.(pending, busy || jobBusy); }, [onPendingChange, pending, busy, jobBusy]);
  useEffect(() => () => onPendingChange?.(false, false), [onPendingChange]);
  useEffect(() => {
    if (!pending) return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; };
    window.addEventListener("beforeunload", warn); return () => window.removeEventListener("beforeunload", warn);
  }, [pending]);
  const candidates = data?.reference_candidates.slice(page * 8, page * 8 + 8) ?? [];
  const candidateKey = profileOpen ? candidates.map(c => c.asset_id).join(",") : "";
  const profileKey = selectedProfile ? `${selectedProfile.id}:${selectedProfile.revision}` : "";
  useEffect(() => {
    let active = true; setPreviews([]); setPreviewError("");
    if (candidateKey) {
      const ids = candidateKey.split(",");
      void api("/media", { asset_ids: ids }).then(raw => {
        const found = decodePreviews(raw, org, listingId, { ids });
        if (active && scopeCurrent()) setPreviews(found);
      }).catch(e => { if (active && scopeCurrent()) setPreviewError(message(e)); });
    }
    return () => { active = false; };
  }, [api, org, listingId, candidateKey, previewRetry, scopeCurrent]);
  useEffect(() => {
    let active = true; setProfilePreviews([]); setLikenessConsent(false); setPerformanceConsent(false);
    if (selectedProfile && !selectedProfile.invalid_reason) {
      const profile = selectedProfile;
      void api("/media", { profile_id: profile.id, expected_profile_revision: profile.revision }).then(raw => {
        const found = decodePreviews(raw, org, listingId, { profile });
        if (active && scopeCurrent()) setProfilePreviews(found);
      }).catch(e => { if (active && scopeCurrent()) setPreviewError(message(e)); });
    }
    return () => { active = false; };
    // The key binds the request to the exact profile revision, not object identity.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api, org, listingId, profileKey, previewRetry, scopeCurrent]);
  useEffect(() => {
    let active = true; setSourcePreview(null); setPerformanceConsent(false);
    if (source) {
      const asset = source.asset_id;
      void api("/media", { source_asset_id: asset }).then(raw => {
        const found = decodePreviews(raw, org, listingId, { source: asset });
        if (found[0].duration_s !== source.duration_s) throw new Error("Video details changed. Refresh saved status before continuing.");
        if (active && scopeCurrent()) setSourcePreview(found[0]);
      }).catch(e => { if (active && scopeCurrent()) setPreviewError(message(e)); });
    }
    return () => { active = false; };
  }, [api, org, listingId, source?.asset_id, previewRetry, scopeCurrent]);

  function update(patch: Partial<DraftForm>) { setForm(value => ({ ...value, ...patch })); setDirty(true); setPerformanceConsent(false); setNotice(""); }
  function accept(next: PresenterState, action?: Action) {
    setData(next); setUncertain(null); setConflict(false); setError(""); setLikenessConsent(false); setPerformanceConsent(false);
    if (action?.action.endsWith("profile")) {
      const saved = next.profiles.find(profile => profile.subject_user_id === user);
      setProfileDirty(false); setProfileOpen(false);
      if (saved) setForm(value => ({ ...value, profile_id: value.profile_id || saved.id }));
      const changed = next.drafts.find(draft => draft.id === form.id);
      if (base && changed) {
        if (sameForm(formOf(base), formOf(changed))) setBase(changed);
        else { setConflict(true); setError("This draft also changed on another device. Compare its saved version before continuing."); }
      }
    } else {
      const saved = next.drafts.find(draft => draft.id === (action?.draft_id ?? form.id)) ?? (initial.current ? next.drafts[0] : undefined);
      if (saved) { setForm(formOf(saved)); setBase(saved); }
      else if (!action) { setForm(newDraft(next.profiles.find(p => approvedProfile(p))?.id)); setBase(undefined); }
      setDirty(false);
    }
    initial.current = false; setNotice(action ? "Saved to your shared Presenter workspace." : "Latest saved Presenter state loaded."); onChanged();
  }
  async function mutate(action: Action) {
    if (running.current || locked || !scopeCurrent()) return;
    running.current = true; setBusy(true); setError(""); setNotice("");
    try {
      let next: PresenterState;
      try { next = decodePresenter(await api("", action), org, listingId); }
      catch (failure) {
        if (!scopeCurrent()) return;
        try {
          next = await read();
          if (!scopeCurrent()) return;
          if (!confirmsAction(next, action, user)) { setData(next); setConflict(true); setError(`${message(failure)} Your edits are kept. Review the saved version.`); return; }
        } catch { setUncertain(action); setError("The save could not be confirmed. Your edits are still here. Check saved status before continuing."); return; }
      }
      if (!scopeCurrent()) return;
      if (!confirmsAction(next, action, user)) throw new Error("The saved revision changed unexpectedly. Reload before continuing.");
      accept(next, action);
    } catch (e) { if (scopeCurrent()) { setUncertain(action); setError(message(e)); } }
    finally { running.current = false; if (scopeCurrent()) setBusy(false); }
  }
  async function refresh(replace: boolean) {
    if (running.current || !scopeCurrent()) return;
    if (replace && (dirty || profileDirty) && !window.confirm("Replace your unsaved Presenter changes with the saved version?")) return;
    running.current = true; setBusy(true);
    try {
      const next = await read(); if (!scopeCurrent()) return;
      if (uncertain && confirmsAction(next, uncertain, user)) accept(next, uncertain);
      else if (replace || !data || (!dirty && !profileDirty && !uncertain)) { setProfileDirty(false); setProfileOpen(false); accept(next); }
      else { setData(next); setUncertain(null); setConflict(true); setError("Review the latest saved version below. Your unsaved fields are unchanged."); }
    } catch (e) { if (scopeCurrent()) setError(message(e)); }
    finally { running.current = false; if (scopeCurrent()) setBusy(false); }
  }
  function chooseDraft(id: string) {
    if (locked || ((dirty || profileDirty) && !window.confirm("Leave unsaved Presenter changes and open another draft?"))) return;
    const found = data?.drafts.find(d => d.id === id); setBase(found); setForm(found ? formOf(found) : newDraft(own?.id ?? data?.profiles[0]?.id));
    setDirty(false); setProfileDirty(false); setProfileOpen(false); setPerformanceConsent(false); setNotice("");
  }
  function editProfile() {
    setName(own?.display_name ?? workspace.user.name ?? ""); setReferenceIds(own?.source_listing_id === listingId ? own.reference_asset_ids : []);
    setProfileOpen(true); setPage(0);
  }
  const validDraft = form.title.trim().length > 0 && form.script.trim().length > 0 && !!source && approvedProfile(selectedProfile);
  const profileReady = !!selectedProfile && !previewError && profilePreviews.length === selectedProfile.reference_asset_ids.length;
  const sameSavedProfile = !!base && base.profile_id === selectedProfile?.id && base.profile_revision === selectedProfile?.revision;
  const readyForApproval = !!base && !dirty && !profileDirty && sameSavedProfile && approvedProfile(selectedProfile) && profileReady && !!sourcePreview && base.subject_user_id === user && base.permissions.can_approve;
  const latest = data?.drafts.find(d => d.id === form.id);

  return <section className="presenter" aria-label="AI Presenter">
    <div className="creative-card presenter-intro">
      <span className="creative-eyebrow">AI PRESENTER</span><h2>Your agent. Your performance. A reviewed video.</h2>
      <p>Prepare a performance for the agent to review.</p>
      <p className="creative-notice" role="status">Saving a profile or draft does not start a paid generation.</p>
      <div className="creative-actions"><button disabled={busy} onClick={() => void refresh(false)}>{uncertain ? "Check saved status" : "Refresh saved status"}</button>{busy && <span role="status">Saving or checking…</span>}{notice && <span role="status">{notice}</span>}</div>
    </div>
    {error && <div className="creative-alert" role="alert"><p>{error}</p>{!data && <button disabled={busy} onClick={() => void refresh(true)}>Retry Presenter</button>}</div>}
    {conflict && <div className="creative-card" role="region" aria-label="Presenter version conflict"><h3>Another saved version needs your review</h3>
      {latest && <><p>Saved draft revision {latest.revision}: {latest.title}</p><blockquote>{latest.script}</blockquote></>}
      <p>Your edits are kept. Saving again replaces this draft and clears approval.</p>
      <div className="creative-actions"><button onClick={() => void refresh(true)}>Use saved version</button><button onClick={() => { setBase(latest); setConflict(false); setUncertain(null); setError(""); setNotice("Review your fields, then save your version when ready."); }}>Keep my changes for review</button></div>
    </div>}
    {data && <>
      {data.truncated && <p className="creative-notice">Showing recent profiles, drafts and media. Older items may not appear.</p>}
      <div className="creative-card"><h3>1 · Choose the agent</h3>
        <label>Agent likeness profile<select value={form.profile_id} disabled={locked || !canEdit} onChange={e => update({ profile_id: e.target.value })}><option value="">Choose an agent</option>{data.profiles.map(p => <option key={p.id} value={p.id}>{p.display_name}{p.subject_user_id === user ? " (you)" : ""} · {p.status}</option>)}</select></label>
        {selectedProfile && <><p>{selectedProfile.display_name} · profile revision {selectedProfile.revision} · {selectedProfile.invalid_reason ?? (approvedProfile(selectedProfile) ? "Likeness approved" : "Needs the agent’s approval")}</p><Gallery photos={profilePreviews} label="Agent reference" onError={() => setPreviewError("Reference could not load. Refresh previews before approving.")} /></>}
        {data.permissions.can_save_profile && <button disabled={locked} onClick={editProfile}>{own ? "Update my likeness profile" : "Create my likeness profile"}</button>}
        <small>Your profile works across this workspace’s properties.</small>
        {profileOpen && <fieldset disabled={locked} className="presenter-profile"><legend>{own ? "Update my profile" : "My likeness profile"}</legend>
          <label>Your display name<input maxLength={80} value={name} onChange={e => { setName(e.target.value); setProfileDirty(true); }} /></label>
          <p>Choose 1–8 photos of yourself: JPEG, PNG or WebP, under 12 MB each. Updating references clears approval.</p>
          {own && own.source_listing_id !== listingId && <p>Choose replacement photos here, or keep your profile’s existing references.</p>}
          <div className="presenter-gallery">{previews.map((p, index) => <label key={p.asset_id}><img src={p.url} alt={`Available reference ${page * 8 + index + 1}`} loading="lazy" /><span><input type="checkbox" aria-label={`Use reference photo ${page * 8 + index + 1}`} checked={referenceIds.includes(p.asset_id)} disabled={!referenceIds.includes(p.asset_id) && referenceIds.length >= 8} onChange={e => { setReferenceIds(ids => e.target.checked ? [...ids, p.asset_id] : ids.filter(id => id !== p.asset_id)); setProfileDirty(true); }} /> Photo {page * 8 + index + 1}</span></label>)}</div>
          {!data.reference_candidates.length && <p>Upload original photos of yourself to this property’s media library first, then refresh Presenter.</p>}
          <div className="creative-actions"><button disabled={page === 0} onClick={() => setPage(p => p - 1)}>Previous photos</button><span>{referenceIds.length} of 8 selected</span><button disabled={(page + 1) * 8 >= data.reference_candidates.length} onClick={() => setPage(p => p + 1)}>More photos</button></div>
          <button className="creative-primary" disabled={!name.trim() || referenceIds.length < 1 || !profileDirty} onClick={() => void mutate({ action: "save_profile", expected_revision: own?.revision ?? 0, display_name: name.trim(), reference_asset_ids: referenceIds })}>Save my profile</button>
        </fieldset>}
        {selectedProfile?.subject_user_id === user && selectedProfile.permissions.can_approve && !approvedProfile(selectedProfile) && <div className="presenter-consent"><label><input type="checkbox" checked={likenessConsent} disabled={locked || profileDirty || !profileReady} onChange={e => setLikenessConsent(e.target.checked)} />I am the person shown in these references, and I consent to using my likeness for AI Presenter.</label><button disabled={locked || profileDirty || !profileReady || !likenessConsent} onClick={() => void mutate({ action: "approve_profile", profile_id: selectedProfile.id, expected_revision: selectedProfile.revision, likeness_consent: true })}>Approve my likeness profile</button></div>}
        {own?.permissions.can_revoke && own.status !== "revoked" && <button className="presenter-revoke" disabled={locked} onClick={() => { if (window.confirm("Revoke permission to use your likeness for future Presenter generation?")) void mutate({ action: "revoke_profile", profile_id: own.id, expected_revision: own.revision }); }}>Revoke my likeness permission</button>}
      </div>
      <div className="creative-card"><h3>2 · Prepare the performance</h3>
        <label>Saved Presenter draft<select value={base?.id ?? ""} disabled={locked} onChange={e => chooseDraft(e.target.value)}><option value="">New draft</option>{data.drafts.map(d => <option key={d.id} value={d.id}>{d.title} · revision {d.revision}</option>)}</select></label>
        <fieldset disabled={locked || !canEdit}><legend>Recording guide</legend>
          <label>Video title<input maxLength={120} value={form.title} onChange={e => update({ title: e.target.value })} /></label>
          <div className="presenter-row"><label>Video purpose<select value={form.format} onChange={e => update({ format: e.target.value as DraftForm["format"] })}>{Object.entries(FORMATS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label><label>Presenter resolution<select value={form.resolution} onChange={e => update({ resolution: e.target.value as DraftForm["resolution"] })}><option value="720p">720p</option><option value="480p">480p</option></select></label></div>
          <label>Script or talking points<textarea maxLength={2000} rows={5} value={form.script} onChange={e => update({ script: e.target.value })} /></label>
          <small>Record a 4–30 second performance under 48 MB. Use these words while recording; editing text does not change video audio or clone a voice.</small>
          <label>Source performance video<select aria-label="Source performance video" value={form.source_asset_id} onChange={e => update({ source_asset_id: e.target.value })}><option value="">Choose an uploaded 4–30 second performance</option>{data.source_candidates.map((s, i) => <option key={s.asset_id} value={s.asset_id}>Video {i + 1} · {s.duration_s?.toFixed(1)} seconds</option>)}</select></label>
          {!data.source_candidates.length && <p>Record a 4–30 second performance, upload the original to this property, then refresh Presenter.</p>}
        </fieldset>
        {sourcePreview && <video key={sourcePreview.url} src={sourcePreview.url} controls preload="metadata" aria-label="Source performance preview" onError={() => setPreviewError("Video could not load. Refresh previews.")} />}
        <div className="creative-actions"><button className="creative-primary" disabled={locked || !canEdit || !validDraft || (!dirty && !!base && sameSavedProfile)} onClick={() => void mutate({ action: "save_draft", draft_id: form.id, expected_revision: base?.revision ?? 0, expected_profile_revision: selectedProfile!.revision, profile_id: form.profile_id, title: form.title.trim(), script: form.script.trim(), source_asset_id: form.source_asset_id, format: form.format, resolution: form.resolution })}>Save Presenter draft</button><span role="status">{dirty ? "Unsaved changes" : base ? `Shared draft · revision ${base.revision}` : "Choose an approved profile and source video"}</span></div>
        {!canEdit && <small>You can review this draft. Its author or an authorized editor must save changes.</small>}
      </div>
      {previewError && <div className="creative-alert" role="alert"><p>{previewError}</p><button onClick={() => { setPreviewError(""); setPreviewRetry(value => value + 1); }}>Refresh previews</button></div>}
      <div className="creative-card"><h3>3 · Review and approve</h3>
        {base ? <><p>{base.title} · draft revision {base.revision} · profile revision {base.profile_revision} · {base.resolution}</p><blockquote>{base.script}</blockquote><p>{approvedDraft(base, selectedProfile) && !dirty ? "The agent approved this exact saved draft and profile." : !sameSavedProfile ? "The likeness profile changed. Save this draft again, then approve it." : "The represented agent needs to approve this exact saved draft."}</p></> : <p>Save your draft for the agent to review on another device.</p>}
        {base?.subject_user_id === user && <div className="presenter-consent"><label><input type="checkbox" checked={performanceConsent} disabled={locked || !readyForApproval} onChange={e => setPerformanceConsent(e.target.checked)} />I approve this saved script, likeness and video, and I have permission to use the source performance.</label><button disabled={locked || !readyForApproval || !performanceConsent || approvedDraft(base, selectedProfile)} onClick={() => void mutate({ action: "approve_draft", draft_id: base.id, expected_revision: base.revision, expected_profile_revision: selectedProfile!.revision, source_performance_consent: true })}>Approve this Presenter draft</button></div>}
        <PresenterJobs org={org} user={user} listing={listingId} draft={base} ready={!dirty && !profileDirty && !!base?.permissions.can_request_generation && approvedDraft(base, selectedProfile)} blocked={busy || !!uncertain || conflict || dirty || profileDirty} api={api} current={scopeCurrent} onBusy={setJobBusy} onUse={onUseAgentPlan} />
        {onUseAgentPlan && <div className="presenter-original"><h3>Keep creating with your original video</h3><p>Edit the original video and audio now. Add property photos, captions and cutaways.</p><button disabled={locked || dirty || !base || !sourcePreview || !canEdit} onClick={() => onUseAgentPlan({ listingId, assetId: form.source_asset_id, cutaways: [], script: form.script })}>Edit the original performance video</button></div>}
      </div>
    </>}
  </section>;
}
function Gallery({ photos, label, onError }: { photos: Preview[]; label: string; onError: () => void }) {
  return <div className="presenter-gallery">{photos.map((photo, index) => <img key={photo.asset_id} src={photo.url} alt={`${label} ${index + 1}`} loading="lazy" onError={onError} />)}</div>;
}
