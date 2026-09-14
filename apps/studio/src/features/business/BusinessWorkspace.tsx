import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from "react";
import type { StudioServices } from "../../data/services";
import type { Listing, Workspace } from "../../data/contracts";
import { businessApi, type BusinessApi } from "./api";
import {
  canEditLeads, canRemoveMember, contactLink, csv, filterLeads, inviteEmails, leadStatuses, manager,
  notificationLabels, safeHTTPS, workspaceRole,
  type Account, type Brand, type ComplianceRow, type InviteResult, type Lead, type LeadStatus, type Notifications,
} from "./model";
import "./business.css";

export type BusinessWorkspaceProps = {
  services: StudioServices; workspace: Workspace; listings: Listing[]; listingId?: string;
  onChanged: () => void; onSelectListing?: (id: string) => void;
  sectionRequest?: BusinessSectionRequest;
};
export type BusinessSection = "leads" | "brand" | "team" | "activity" | "disclosures" | "account";
export type BusinessSectionRequest = { id: string; section: BusinessSection };
const sections: { id: BusinessSection; label: string }[] = [
  { id: "leads", label: "Leads" }, { id: "brand", label: "Agent card" }, { id: "team", label: "Team" },
  { id: "activity", label: "Team activity" }, { id: "disclosures", label: "AI disclosures" }, { id: "account", label: "Account & plan" },
];
const displayDate = (value: string | null) => value ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(new Date(value)) : "—";
const failure = (error: unknown) => error instanceof Error ? error.message : "That could not be completed. Please try again.";

function useResource<T>(read: (signal: AbortSignal) => Promise<T>, refreshOnFocus = true, keepLoadedForm = false) {
  const [data, setData] = useState<T | null>(null), [error, setError] = useState<string | null>(null), [loading, setLoading] = useState(true);
  const [version, setVersion] = useState(0);
  const reload = useCallback(() => setVersion((n) => n + 1), []);
  useEffect(() => {
    const controller = new AbortController();
    setLoading(true); setError(null);
    if (!keepLoadedForm) setData(null);
    void read(controller.signal).then((value) => {
      if (!controller.signal.aborted) setData(value);
    }).catch((error: unknown) => { if (!controller.signal.aborted) setError(failure(error)); })
      .finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [read, version, keepLoadedForm]);
  useEffect(() => {
    if (!refreshOnFocus) return;
    const refresh = () => { if (document.visibilityState === "visible") reload(); };
    window.addEventListener("focus", refresh);
    const timer = window.setInterval(refresh, 60_000);
    return () => { window.removeEventListener("focus", refresh); window.clearInterval(timer); };
  }, [refreshOnFocus, reload]);
  return { data, error, loading, reload };
}
function useAction() {
  const [busy, setBusy] = useState(false), [error, setError] = useState<string | null>(null), [message, setMessage] = useState<string | null>(null);
  const active = useRef<AbortController | null>(null), mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; active.current?.abort(); }; }, []);
  const run = async (task: (signal: AbortSignal) => Promise<string | void>) => {
    if (active.current) return;
    const controller = new AbortController(); active.current = controller;
    setBusy(true); setError(null); setMessage(null);
    try {
      const result = await task(controller.signal);
      if (mounted.current && !controller.signal.aborted) setMessage(result || "Saved. Your iPhone uses the same workspace.");
    } catch (error) { if (mounted.current && !controller.signal.aborted) setError(failure(error)); }
    finally { if (active.current === controller) active.current = null; if (mounted.current) setBusy(false); }
  };
  return { busy, error, message, run };
}
function Feedback({ error, message }: { error?: string | null; message?: string | null }) {
  return <>{error && <p className="business-notice error" role="alert">{error}</p>}{message && <p className="business-notice success" role="status">{message}</p>}</>;
}
function ResourceState({ loading, error, reload }: { loading: boolean; error: string | null; reload: () => void }) {
  return <>{loading && <p className="business-loading" role="status">Loading your workspace…</p>}{error && <div className="business-notice error" role="alert"><p>{error}</p><button onClick={reload}>Try again</button></div>}</>;
}
function Card({ title, children, className = "" }: { title: string; children: ReactNode; className?: string }) {
  return <section className={`business-card ${className}`}><h3>{title}</h3>{children}</section>;
}
function ListingFilter({ listings, value, onChange, label = "Listing" }: { listings: Listing[]; value: string; onChange: (value: string) => void; label?: string }) {
  return <label>{label}<select value={value} onChange={(e) => onChange(e.target.value)}><option value="">All listings</option>{listings.map((listing) => <option key={listing.id} value={listing.id}>{listing.address || listing.tagline || "Untitled listing"}</option>)}</select></label>;
}
function downloadCSV(name: string, cells: (string | number | boolean | null)[][]) {
  const url = URL.createObjectURL(new Blob([csv(cells)], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a"); link.href = url; link.download = name; link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export default function BusinessWorkspace(props: BusinessWorkspaceProps) {
  return <BusinessWorkspaceContent key={`${props.workspace.user.id}:${props.workspace.org.id}`} {...props} />;
}
function BusinessWorkspaceContent(props: BusinessWorkspaceProps) {
  const { workspace, services } = props;
  const [section, setSection] = useState<BusinessSection>("leads");
  const [visited, setVisited] = useState<ReadonlySet<BusinessSection>>(() => new Set(["leads"]));
  const consumedRequests = useRef(new Set<string>());
  const openSection = useCallback((next: BusinessSection) => {
    setVisited((current) => current.has(next) ? current : new Set([...current, next]));
    setSection(next);
  }, []);
  const api = useMemo(() => businessApi(services, workspace), [services, workspace]);
  const isManager = manager(workspaceRole(workspace));
  useEffect(() => {
    const request = props.sectionRequest;
    if (!request || consumedRequests.current.has(request.id)) return;
    consumedRequests.current.add(request.id);
    openSection(request.section === "activity" && !isManager ? "account" : request.section);
  }, [props.sectionRequest, isManager, openSection]);
  useEffect(() => {
    if (section === "activity" && !isManager) openSection("account");
  }, [section, isManager, openSection]);
  return <div className="business-workspace">
    <header className="business-intro"><div><span className="business-eyebrow">Your business</span><h2>{sections.find((item) => item.id === section)?.label}</h2><p>Your agent card, leads and team stay together on your phone and in Studio.</p></div><span className="business-chip">{workspace.org.name}</span></header>
    <nav className="business-nav" aria-label="Business tools">{sections.filter((s) => s.id !== "activity" || isManager).map((item) => <button key={item.id} aria-current={section === item.id ? "page" : undefined} onClick={() => openSection(item.id)}>{item.label}</button>)}</nav>
    {sections.map((item) => visited.has(item.id) && <div key={item.id} hidden={section !== item.id}><div className="business-content">
      {item.id === "leads" && <LeadsPanel {...props} api={api} />}
      {item.id === "brand" && <BrandPanel {...props} api={api} />}
      {item.id === "team" && <TeamPanel {...props} api={api} />}
      {item.id === "activity" && isManager && <ActivityPanel api={api} />}
      {item.id === "disclosures" && <DisclosurePanel {...props} api={api} />}
      {item.id === "account" && <AccountPanel {...props} api={api} />}
    </div></div>)}
  </div>;
}
type PanelProps = BusinessWorkspaceProps & { api: BusinessApi };

function LeadsPanel({ api, workspace, listings, listingId, onChanged, onSelectListing }: PanelProps) {
  const [listing, setListing] = useState(listingId ?? ""), [status, setStatus] = useState<LeadStatus | "">(""), [since, setSince] = useState(""), [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string | null>(null), [overrides, setOverrides] = useState<Record<string, Lead>>({});
  useEffect(() => { setListing(listingId ?? ""); setSelected(null); }, [listingId]);
  const read = useCallback((signal: AbortSignal) => api.leads({ listingId: listing || undefined, status: status || undefined, since: since || undefined }, signal), [api, listing, status, since]);
  const resource = useResource(read), action = useAction();
  // A fresh server read always wins over an earlier save on this screen.
  useEffect(() => setOverrides({}), [resource.data]);
  const all = (resource.data ?? []).map((l) => overrides[l.id] ?? l).filter((l) => !status || l.status === status);
  const visible = filterLeads(all, query), current = visible.find((l) => l.id === selected);
  const editable = canEditLeads(workspaceRole(workspace));
  const update = (lead: Lead, next: LeadStatus) => void action.run(async (signal) => {
    const saved = await api.setLeadStatus(lead.id, next, signal);
    setOverrides((current) => ({ ...current, [saved.id]: saved })); onChanged();
    return `${saved.name || "Lead"} marked ${saved.status}.`;
  });
  return <>
    <div className="business-heading"><div><h3>Lead inbox</h3><p>Follow up after a showing, then pick up the conversation here.</p></div><div className="business-actions"><button disabled={resource.loading || action.busy} onClick={resource.reload}>Refresh</button><button disabled={!visible.length} onClick={() => downloadCSV("rendprop-leads.csv", [["Name", "Email", "Phone", "Listing", "Status", "Message", "Source", "Received", "CRM synced"], ...visible.map((l) => [l.name, l.email, l.phone, l.address, l.status, l.message, l.source, l.createdAt, l.synced])])}>Export current results</button></div></div>
    <div className="business-filters"><label className="business-grow">Search loaded leads<input type="search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Name, email, property or message" /></label><ListingFilter listings={listings} value={listing} onChange={(v) => { setListing(v); setSelected(null); }} /><label>Status<select value={status} onChange={(e) => { setStatus(e.target.value as LeadStatus | ""); setSelected(null); }}><option value="">All statuses</option>{leadStatuses.map((s) => <option key={s}>{s}</option>)}</select></label><label>Received since<input type="date" value={since} onChange={(e) => { setSince(e.target.value); setSelected(null); }} /></label></div>
    <ResourceState {...resource} /><Feedback {...action} />
    {resource.data && <>
      {resource.data.length === 500 && <p className="business-notice">Showing the newest 500 matching leads. Narrow the listing, status or date filters to find a specific inquiry.</p>}
      <p className="business-subtle">{visible.length} {visible.length === 1 ? "lead" : "leads"} · Updates refresh when you return to this page.</p>
      {!visible.length ? <div className="business-empty"><h3>{resource.data.length ? "No leads match these filters" : "Your next conversation starts here"}</h3><p>{resource.data.length ? "Try another search or clear the filters." : "Inquiries from your published tours will appear here and on your iPhone."}</p></div> : <div className={current ? "business-lead-layout" : ""}><div className="business-table-scroll"><table><caption className="business-sr-only">Leads in the selected workspace</caption><thead><tr><th scope="col">Contact</th><th scope="col">Listing</th><th scope="col">Received</th><th scope="col">Status</th></tr></thead><tbody>{visible.map((lead) => <tr key={lead.id} className={selected === lead.id ? "selected" : ""}><td><button className="business-text-button" onClick={() => setSelected(lead.id)}>{lead.name || lead.email || "New inquiry"}</button><small>{lead.email || lead.phone || "Contact details not supplied"}</small></td><td>{lead.address || "General inquiry"}</td><td>{displayDate(lead.createdAt)}</td><td>{editable ? <select aria-label={`Status for ${lead.name || lead.email || "lead"}`} value={lead.status} disabled={action.busy} onChange={(e) => update(lead, e.target.value as LeadStatus)}>{leadStatuses.map((s) => <option key={s}>{s}</option>)}</select> : <span className={`business-status ${lead.status}`}>{lead.status}</span>}</td></tr>)}</tbody></table></div>
        {current && <Card title={current.name || "New inquiry"}><button className="business-close" aria-label="Close lead details" onClick={() => setSelected(null)}>Close</button><p>{current.address}</p><blockquote>{current.message || "No message was included."}</blockquote><div className="business-contact-links">{contactLink("email", current.email) && <a href={contactLink("email", current.email)!}>Email {current.email}</a>}{contactLink("phone", current.phone) && <a href={contactLink("phone", current.phone)!}>Call {current.phone}</a>}</div><p className="business-subtle">Received {displayDate(current.createdAt)} · {current.source}{current.synced && " · Saved to connected CRM"}</p>{current.listingId && onSelectListing && <button onClick={() => onSelectListing(current.listingId!)}>Open listing</button>}</Card>}
      </div>}
    </>}
  </>;
}

function BrandPanel(props: PanelProps) {
  const read = useCallback((signal: AbortSignal) => props.api.account(signal), [props.api]);
  const resource = useResource(read, false, true);
  return <><div className="business-heading"><div><h3>Your agent card</h3><p>Keep your contact details together on your phone, branded tours and public profile.</p></div></div><ResourceState {...resource} />{resource.data && <BrandForm {...props} account={resource.data} />}</>;
}
function BrandForm({ api, workspace, onChanged, account }: PanelProps & { account: Account }) {
  const [brand, setBrand] = useState<Brand>(account.brand), [saved, setSaved] = useState(account.brand), action = useAction();
  const editable = manager(workspaceRole(workspace)), dirty = JSON.stringify(brand) !== JSON.stringify(saved);
  const lastRemoteBrand = useRef(account.brand);
  useEffect(() => {
    if (lastRemoteBrand.current === account.brand) return;
    lastRemoteBrand.current = account.brand;
    if (!dirty) { setBrand(account.brand); setSaved(account.brand); }
  }, [account.brand, dirty]);
  const update = (key: keyof Brand, value: string) => setBrand((b) => ({ ...b, [key]: value }));
  useEffect(() => {
    if (!dirty) return;
    const before = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; };
    window.addEventListener("beforeunload", before); return () => window.removeEventListener("beforeunload", before);
  }, [dirty]);
  const fields: { id: keyof Brand; label: string; type?: string; help?: string }[] = [
    { id: "name", label: "Display name" }, { id: "title", label: "Professional title" }, { id: "brokerage", label: "Brokerage" },
    { id: "phone", label: "Public phone", type: "tel" }, { id: "email", label: "Public email", type: "email" }, { id: "website", label: "Website", type: "text" },
    { id: "headshot_url", label: "Headshot address", type: "url", help: "Public https:// image URL. This appears on branded share pages." }, { id: "avatar_url", label: "Avatar address", type: "url" },
    { id: "instagram", label: "Instagram link or handle", type: "text" }, { id: "linkedin", label: "LinkedIn link or handle", type: "text" }, { id: "tiktok", label: "TikTok link or handle", type: "text" },
  ];
  return <form onSubmit={(e) => { e.preventDefault(); void action.run(async (signal) => { const snapshot = { ...brand }; await api.saveBrand(snapshot, signal); setSaved(snapshot); onChanged(); return "Brand saved to your workspace and public tours."; }); }}>
    {!editable && <p className="business-notice">Your workspace owner or an admin can update this shared card.</p>}
    <div className="business-columns"><Card title="Agent & business details"><fieldset disabled={!editable || action.busy} className="business-form-grid"><label>Business name<input value={brand.org_name} maxLength={120} required onChange={(e) => update("org_name", e.target.value)} /></label><label>Business type<select value={brand.space_type} onChange={(e) => update("space_type", e.target.value)}>{["real_estate", "venue", "restaurant", "retail", "fitness", "other"].map((type) => <option value={type} key={type}>{type.replaceAll("_", " ")}</option>)}</select></label>{fields.map((field) => <label key={field.id}>{field.label}<input type={field.type ?? "text"} value={brand[field.id]} maxLength={300} onChange={(e) => update(field.id, e.target.value)} />{field.help && <small>{field.help}</small>}</label>)}</fieldset></Card>
      <div className="business-stack"><Card title="Portfolio & color"><fieldset disabled={!editable || action.busy}><label>Portfolio address<input value={brand.handle} maxLength={32} placeholder="your-name" onChange={(e) => update("handle", e.target.value)} /><small>rendprop.com/a/{brand.handle || "your-name"}</small></label><label>Brand color<input value={brand.accent} placeholder="#7c3aed" maxLength={9} onChange={(e) => update("accent", e.target.value)} /></label></fieldset>{account.portfolioUrl && <a href={account.portfolioUrl} target="_blank" rel="noopener noreferrer">View current portfolio ↗</a>}</Card>
      <Card title="Card preview" className="business-preview"><div className="business-brand-rule" style={{ backgroundColor: /^#[a-f\d]{3,8}$/i.test(brand.accent) ? brand.accent : "#7c3aed" }} /><strong>{brand.name || "Your name"}</strong><p>{[brand.title, brand.brokerage].filter(Boolean).join(" · ") || "Your professional title and brokerage"}</p><p>{brand.phone}<br />{brand.email}</p><small>Contact details appear on branded tours. The MLS version stays unbranded.</small></Card></div></div>
    <Feedback {...action} /><div className="business-save-bar"><span>{dirty ? "Unsaved changes" : "Your saved workspace brand"}</span><button type="button" disabled={!dirty || action.busy} onClick={() => setBrand(saved)}>Reset</button><button className="primary" disabled={!editable || !dirty || action.busy} type="submit">{action.busy ? "Saving…" : "Save brand"}</button></div>
  </form>;
}

function TeamPanel({ api, workspace, onChanged }: PanelProps) {
  const read = useCallback((signal: AbortSignal) => api.team(signal), [api]), resource = useResource(read, false), action = useAction();
  const [emails, setEmails] = useState(""), [role, setRole] = useState("agent"), [code, setCode] = useState("");
  const [issued, setIssued] = useState<InviteResult[]>([]), [confirmed, setConfirmed] = useState(false);
  const [removal, setRemoval] = useState<{ kind: "member" | "invite"; id: string; name: string } | null>(null);
  const actor = workspaceRole(workspace), canManage = manager(actor) && resource.data?.canManage;
  let recipientCount = 0; try { recipientCount = inviteEmails(emails).length; } catch { /* Form validation explains malformed input on submit. */ }
  return <>
    <div className="business-heading"><div><h3>Your team</h3><p>Share one workspace so every agent sees the same listings.</p></div><button disabled={resource.loading || action.busy} onClick={resource.reload}>Refresh team</button></div>
    <ResourceState {...resource} /><Feedback {...action} />
    {resource.data && <>
      <div className="business-metrics"><div><strong>{resource.data.used} / {resource.data.allowed}</strong><span>Seats in use</span></div><div><strong>{resource.data.members.length}</strong><span>Team members</span></div><div><strong>{resource.data.invites.length}</strong><span>{canManage ? "Pending invites" : "Visible invitations"}</span></div></div>
      {resource.data.used >= resource.data.allowed && <p className="business-notice">All seats are reserved. Pending invitations hold a seat. Revoke an unused invitation or manage your plan in Rendprop on your iPhone.</p>}
      <Card title="Members"><div className="business-table-scroll"><table><caption className="business-sr-only">Current team members</caption><thead><tr><th scope="col">Person</th><th scope="col">Role</th>{canManage && <th scope="col">Access</th>}</tr></thead><tbody>{resource.data.members.map((member) => <tr key={member.id}><td>{member.name || member.email || "Team member"}{member.isYou && <span className="business-chip">You</span>}<small>{member.name ? member.email : ""}</small></td><td className="business-capitalize">{member.role}</td>{canManage && <td>{canRemoveMember(actor, member) && <button disabled={action.busy} onClick={() => setRemoval({ kind: "member", id: member.id, name: member.name || member.email || "this member" })}>Remove</button>}</td>}</tr>)}</tbody></table></div></Card>
      {canManage && <div className="business-columns"><Card title="Invite your team"><form onSubmit={(e) => { e.preventDefault(); if (recipientCount && !confirmed) return; void action.run(async (signal) => { const result = await api.invite(emails, role, signal); setIssued(result); setEmails(""); setConfirmed(false); resource.reload(); onChanged(); return "Invitations created. Keep the links below until you have shared them."; }); }}><label>Email addresses<textarea rows={3} value={emails} onChange={(e) => { setEmails(e.target.value); setConfirmed(false); }} placeholder="agent@example.com, teammate@example.com" /><small>One or more email addresses, or leave blank to create a link you can share yourself.</small></label><label>Role<select value={role} onChange={(e) => setRole(e.target.value)}><option value="agent">Agent — listings and leads</option><option value="marketing">Marketing — view workspace content</option><option value="admin">Admin — manage shared brand and team</option></select></label>{emails.trim() && <label className="business-check"><input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} />Send an invitation email to {recipientCount || "these"} {recipientCount === 1 ? "person" : "people"}.</label>}<button className="primary" disabled={action.busy || resource.data.used >= resource.data.allowed || (!!emails.trim() && !confirmed)}>{action.busy ? "Creating…" : emails.trim() ? "Create & send invitations" : "Create invite link"}</button></form></Card>
      <Card title="Pending invitations">{resource.data.invites.length ? <ul className="business-list">{resource.data.invites.map((invite) => <li key={invite.id}><div><strong>{invite.email || "Shared invite link"}</strong><small>{invite.role} · Expires {displayDate(invite.expiresAt)}</small></div><button disabled={action.busy} onClick={() => setRemoval({ kind: "invite", id: invite.id, name: invite.email || "this invite link" })}>Revoke</button></li>)}</ul> : <p>No invitations are waiting.</p>}</Card></div>}
    </>}
    {issued.length > 0 && <Card title="New invitations"><p>Each link can be accepted once. The code is only shown when the invitation is created.</p><ul className="business-list">{issued.map((invite, index) => <li key={`${invite.email}:${index}`}><div><strong>{invite.email || "Shareable invite"}</strong><small>{invite.outcome.replaceAll("_", " ")}{invite.expiresAt && ` · Expires ${displayDate(invite.expiresAt)}`}</small>{invite.code && <><code>{invite.code}</code><input aria-label={`Invitation link for ${invite.email || "new team member"}`} readOnly value={`https://rendprop.com/join/${encodeURIComponent(invite.code)}`} onFocus={(e) => e.target.select()} /></>}</div>{invite.code && <button onClick={() => void action.run(async () => { await navigator.clipboard.writeText(`https://rendprop.com/join/${encodeURIComponent(invite.code!)}`); return "Invitation link copied."; })}>Copy link</button>}</li>)}</ul></Card>}
    {removal && <section className="business-confirm" aria-label="Confirm access change"><h3>{removal.kind === "member" ? "Remove team access?" : "Revoke this invitation?"}</h3><p>{removal.name} will {removal.kind === "member" ? "lose access to this workspace. Existing listings remain in the workspace." : "no longer be able to join with this invitation. Its reserved seat will become available."}</p><div className="business-actions"><button disabled={action.busy} onClick={() => setRemoval(null)}>Keep access</button><button className="business-danger" disabled={action.busy} onClick={() => void action.run(async (signal) => { if (removal.kind === "member") await api.removeMember(removal.id, signal); else await api.revokeInvite(removal.id, signal); setRemoval(null); resource.reload(); onChanged(); return "Team access updated."; })}>{removal.kind === "member" ? "Remove member" : "Revoke invitation"}</button></div></section>}
    <Card title="Join another workspace"><form className="business-inline-form" onSubmit={(e) => { e.preventDefault(); void action.run(async (signal) => { await api.join(code, signal); setCode(""); onChanged(); resource.reload(); return "Workspace joined. Select it from the workspace switcher to see the team's listings."; }); }}><label>Invitation code<input value={code} onChange={(e) => setCode(e.target.value)} placeholder="XXXX-XXXX-XXXX" autoComplete="off" maxLength={20} /></label><button disabled={action.busy || !code.trim()}>Join workspace</button></form><p className="business-subtle">Sign in with Apple on either device, then use the code your team sent you.</p></Card>
  </>;
}

function ActivityPanel({ api }: { api: BusinessApi }) {
  const [window, setWindow] = useState<"7d" | "30d" | "90d">("30d");
  const read = useCallback((signal: AbortSignal) => api.overview(window, signal), [api, window]), resource = useResource(read);
  return <><div className="business-heading"><div><h3>Team activity</h3><p>See what your agents have published and where someone may need a hand.</p></div><label>Period<select value={window} onChange={(e) => setWindow(e.target.value as typeof window)}><option value="7d">Last 7 days</option><option value="30d">Last 30 days</option><option value="90d">Last 90 days</option></select></label></div><ResourceState {...resource} />{resource.data && <>
    <p className="business-subtle">{displayDate(resource.data.from)} – {displayDate(resource.data.to)}</p><div className="business-metrics"><div><strong>{resource.data.totals.listings}</strong><span>Current listings</span></div><div><strong>{resource.data.totals.tours}</strong><span>Tours published in period</span></div><div><strong>{resource.data.totals.ai}</strong><span>AI assets published in period</span></div><div><strong>{resource.data.totals.inactive}</strong><span>Members without a tour in period</span></div></div>
    <div className="business-table-scroll"><table><caption className="business-sr-only">Publishing activity by agent</caption><thead><tr><th scope="col">Agent</th><th scope="col">Listings</th><th scope="col">Tours published</th><th scope="col">AI assets</th><th scope="col">Last activity</th></tr></thead><tbody>{resource.data.members.map((m) => <tr key={m.id}><td>{m.name}<small className="business-capitalize">{m.role}</small></td><td>{m.listings}</td><td>{m.tours}</td><td>{m.ai}</td><td>{displayDate(m.lastActive)}</td></tr>)}</tbody></table></div><p className="business-subtle">Tour counts reflect published versions, so publishing a listing twice counts as two tours. AI totals include assets with a published result.</p>
  </>}</>;
}

function DisclosurePanel({ api, workspace, listings, listingId, onSelectListing }: PanelProps) {
  const [listing, setListing] = useState(listingId ?? ""), [scope, setScope] = useState<"user" | "org">("user"), [from, setFrom] = useState(""), [to, setTo] = useState("");
  const read = useCallback((signal: AbortSignal) => {
    if (from && to && from > to) return Promise.reject(new Error("Choose an end date on or after the start date."));
    return api.compliance({ listingId: listing || undefined, scope, from: from || undefined, to: to || undefined }, signal);
  }, [api, listing, scope, from, to]);
  const resource = useResource(read, false), action = useAction();
  const [editing, setEditing] = useState<ComplianceRow | null>(null), [label, setLabel] = useState("");
  return <><div className="business-heading"><div><h3>AI disclosure records</h3><p>Review each alteration, its disclosure and the original image available to viewers.</p></div><div className="business-actions"><button disabled={resource.loading || action.busy} onClick={resource.reload}>Refresh</button><button disabled={!resource.data?.rows.length} onClick={() => downloadCSV("rendprop-ai-disclosures.csv", [["Created", "Listing", "Agent", "Label", "Kind", "Edit", "Model", "Disclosure", "Original available", "Original URL", "Altered URL", "Prompt summary"], ...resource.data!.rows.map((r) => [r.createdAt, r.address, r.agent, r.label, r.kind, r.edit, r.model, r.disclosure, r.originalAvailable, r.originalUrl, r.alteredUrl, r.prompt])])}>Export records</button></div></div>
    <div className="business-filters"><ListingFilter listings={listings} value={listing} onChange={setListing} />{manager(workspaceRole(workspace)) && <label>Scope<select value={scope} onChange={(e) => setScope(e.target.value as typeof scope)}><option value="user">Workspace records</option><option value="org">Team records with agent attribution</option></select></label>}<label>From (UTC)<input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label><label>Through (UTC)<input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label></div>
    <ResourceState {...resource} /><Feedback {...action} />
    {resource.data && <>{resource.data.truncated && <p className="business-notice">This report reached its record limit. Narrow the dates or listing before exporting a complete report.</p>}{!resource.data.rows.length ? <div className="business-empty"><h3>No AI alterations in this view</h3><p>Disclosures appear after you generate media with Rendprop's AI tools.</p></div> : <div className="business-disclosure-grid">{resource.data.rows.map((r) => <Card key={r.id} title={r.label || r.edit || r.kind}><span className={`business-status ${r.originalAvailable ? "won" : "new"}`}>{r.originalAvailable ? "Original available" : "Original not attached"}</span><p>{r.address || "Not assigned to a listing"}</p><blockquote>{r.disclosure}</blockquote><small>{displayDate(r.createdAt)}{r.agent && ` · ${r.agent}`}</small><div className="business-actions">{r.originalUrl && <a href={r.originalUrl} target="_blank" rel="noopener noreferrer">View original ↗</a>}{r.alteredUrl && <a href={r.alteredUrl} target="_blank" rel="noopener noreferrer">View result ↗</a>}</div><div className="business-actions">{canEditLeads(workspaceRole(workspace)) && <button onClick={() => { setEditing(r); setLabel(r.label || ""); }}>Edit label</button>}{r.listingId && onSelectListing && <button onClick={() => onSelectListing(r.listingId!)}>Open listing</button>}</div></Card>)}</div>}</>}
    {editing && <Card title="Edit asset label"><form onSubmit={(e) => { e.preventDefault(); void action.run(async (signal) => { await api.labelProvenance(editing.id, label, signal); setEditing(null); resource.reload(); return "Asset label updated."; }); }}><label>Label<input autoFocus value={label} maxLength={80} required onChange={(e) => setLabel(e.target.value)} /></label><div className="business-actions"><button type="button" onClick={() => setEditing(null)} disabled={action.busy}>Cancel</button><button className="primary" disabled={action.busy || !label.trim()}>Save label</button></div></form></Card>}
  </>;
}

function AccountPanel(props: PanelProps) {
  const read = useCallback((signal: AbortSignal) => props.api.account(signal), [props.api]), resource = useResource(read, false, true);
  return <><div className="business-heading"><div><h3>Account & plan</h3><p>Your Apple sign-in, subscription and allowances are shared with Rendprop on your iPhone.</p></div><button disabled={resource.loading} onClick={resource.reload}>Refresh allowance</button></div><ResourceState {...resource} />{resource.data && <AccountDetails {...props} account={resource.data} />}</>;
}
function AccountDetails({ account, workspace, services, api, onChanged }: PanelProps & { account: Account }) {
  const [preferences, setPreferences] = useState<Notifications>(account.notifications), [saved, setSaved] = useState(account.notifications), action = useAction();
  const [deleting, setDeleting] = useState(false), [confirmation, setConfirmation] = useState(""), [acknowledged, setAcknowledged] = useState(false);
  const [deletion, setDeletion] = useState<{ accountDeleted: boolean; complete: boolean; needsSupport: boolean; requestId: string } | null>(null);
  const dirty = JSON.stringify(preferences) !== JSON.stringify(saved);
  const lastRemotePreferences = useRef(account.notifications);
  useEffect(() => {
    if (lastRemotePreferences.current === account.notifications) return;
    lastRemotePreferences.current = account.notifications;
    if (!dirty) { setPreferences(account.notifications); setSaved(account.notifications); }
  }, [account.notifications, dirty]);
  useEffect(() => {
    if (!dirty) return;
    const before = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; };
    window.addEventListener("beforeunload", before);
    return () => window.removeEventListener("beforeunload", before);
  }, [dirty]);
  return <>
    <div className="business-columns"><Card title="Signed in with Apple"><strong>{workspace.user.name || account.brand.name || "Your Rendprop account"}</strong><p>{workspace.user.email || "Apple did not share an email address"}</p><p className="business-subtle">Use this same Apple account on your iPhone. Apple may display a private relay email when Hide My Email is enabled.</p><a href="https://apps.apple.com/us/app/id6808982413" target="_blank" rel="noopener noreferrer">Open Rendprop for iPhone ↗</a></Card><Card title="Shared subscription"><div className="business-plan-name">{account.degraded || workspace.planDegraded ? "Temporarily unavailable" : workspace.plan}</div><p>{workspace.planExpiresAt ? `Current access through ${displayDate(workspace.planExpiresAt)}.` : workspace.trialEndsAt ? `Trial ends ${displayDate(workspace.trialEndsAt)}.` : "Your current workspace allowance is shown below."}</p><p className="business-subtle">Purchases and restores are managed in the iPhone app. A restored purchase updates this workspace automatically.</p><a href="https://apps.apple.com/account/subscriptions" target="_blank" rel="noopener noreferrer">Manage Apple subscriptions ↗</a></Card></div>
    <Card title="Current allowance">{account.degraded ? <p className="business-notice">The plan could not be verified. Refresh before starting new paid work.</p> : <div className="business-meter-grid">{account.meters.map((meter) => <div key={meter.key} className="business-meter"><div><strong>{meter.title}</strong><span>{meter.used} / {meter.cap}</span></div><progress value={Math.min(meter.used, meter.cap)} max={Math.max(1, meter.cap)} aria-label={`${meter.title}: ${meter.used} used of ${meter.cap}`} /><small>{meter.cap === 0 ? "Not included in your current plan" : meter.resetsAt ? `Resets ${displayDate(meter.resetsAt)}` : "Window starts with your first use"}</small></div>)}</div>}<p className="business-subtle">These are the same meters used by the iPhone app. Publishing a video rendered on your device does not use a cloud render allowance.</p></Card>
    <Card title="Notifications on your account"><form onSubmit={(e) => { e.preventDefault(); void action.run(async (signal) => { const result = await api.saveNotifications(preferences, signal); setSaved(result); setPreferences(result); onChanged(); return "Notification preferences saved for your account."; }); }}><fieldset disabled={action.busy}><div className="business-toggle-grid">{Object.entries(notificationLabels).map(([key, label]) => <label className="business-check" key={key}><input type="checkbox" checked={preferences[key as keyof typeof notificationLabels]} onChange={(e) => setPreferences((p) => ({ ...p, [key]: e.target.checked }))} />{label}</label>)}</div><div className="business-mute"><p>{preferences.muted_until && Date.parse(preferences.muted_until) > Date.now() ? `Notifications paused until ${new Date(preferences.muted_until).toLocaleString()}.` : "Notifications are not paused."}</p><div className="business-actions"><button type="button" onClick={() => setPreferences((p) => ({ ...p, muted_until: new Date(Date.now() + 3_600_000).toISOString() }))}>Pause for 1 hour</button><button type="button" onClick={() => setPreferences((p) => ({ ...p, muted_until: new Date(Date.now() + 86_400_000).toISOString() }))}>Pause for 1 day</button><button type="button" onClick={() => setPreferences((p) => ({ ...p, muted_until: null }))}>Resume now</button></div></div></fieldset><p className="business-subtle">These preferences control Rendprop's account notifications. iPhone push permission is managed in iOS Settings.</p><button className="primary" disabled={!dirty || action.busy}>{action.busy ? "Saving…" : "Save notification preferences"}</button></form></Card>
    <Feedback {...action} />
    <Card title="Help & privacy"><div className="business-actions"><a href="https://rendprop.com/support" target="_blank" rel="noopener noreferrer">Rendprop support ↗</a><a href="https://rendprop.com/privacy" target="_blank" rel="noopener noreferrer">Privacy policy ↗</a><a href="https://rendprop.com/terms" target="_blank" rel="noopener noreferrer">Terms of service ↗</a></div><p>Before switching devices, finish uploading your files. Your completed uploads, listings, published tours, brand and team are available from the same workspace.</p></Card>
    <details className="business-danger-zone" onToggle={(e) => { if (!e.currentTarget.open) setDeleting(false); }}><summary>Delete Rendprop account</summary><p>This deletes your Rendprop identity on your iPhone and in Studio. Workspaces you own alone and their tours are removed; you leave shared workspaces. Existing Apple subscriptions must be cancelled separately.</p>{!deleting && !deletion && <button className="business-danger" disabled={action.busy} onClick={() => setDeleting(true)}>Review account deletion</button>}
      {deleting && !deletion && <form onSubmit={(e: FormEvent) => { e.preventDefault(); if (!acknowledged) return; void action.run(async (signal) => { const result = await api.deleteAccount(confirmation, signal); setDeletion(result); setDeleting(false); return result.complete ? "Your account has been deleted." : "Account deletion has started. Any remaining cleanup will continue on the server."; }); }}><label className="business-check"><input type="checkbox" checked={acknowledged} onChange={(e) => setAcknowledged(e.target.checked)} />I understand this affects my iPhone account and cannot be undone.</label><label>Type DELETE MY ACCOUNT<input autoComplete="off" value={confirmation} onChange={(e) => setConfirmation(e.target.value)} /></label><div className="business-actions"><button type="button" disabled={action.busy} onClick={() => setDeleting(false)}>Keep my account</button><button className="business-danger" disabled={action.busy || !acknowledged || confirmation !== "DELETE MY ACCOUNT"}>{action.busy ? "Deleting account…" : "Permanently delete my account"}</button></div></form>}
      {deletion && <div className="business-notice" role="status"><p>{deletion.complete ? "Account deleted." : "Deletion is being processed. Please do not submit it again."}{deletion.needsSupport && " Some cleanup needs support review."}</p><p>Request reference: <code>{deletion.requestId}</code></p>{deletion.accountDeleted && <button onClick={() => void services.signOut()}>Finish and sign out</button>}</div>}
    </details>
  </>;
}
