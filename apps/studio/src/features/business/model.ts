import type { Role, Workspace } from "../../data/contracts";
import { uuid } from "../../data/contracts";
import { decodeServingActivation, decodeTrialUsage, type ServingActivation, type TrialUsage } from "../../data/trial";
import { decodePhotoPackage, type PhotoPackage } from "../../data/photo-package";

export const leadStatuses = ["new", "contacted", "won", "lost"] as const;
export type LeadStatus = typeof leadStatuses[number];
export const notificationLabels = {
  lead_received: "New leads", render_ready: "Tours ready to share", upload_stuck: "Uploads that need attention",
  free_week_ending: "Trial reminders", allowance_low: "Low monthly allowance", first_tour_nudge: "Getting started tips",
} as const;
export type NotificationKey = keyof typeof notificationLabels;
export type Notifications = Record<NotificationKey, boolean> & { muted_until: string | null };
export type ClientDelivery = { state: "queued" | "sending" | "email_sent" | "failed" | "skipped"; recipient_email: string | null; client_name: string | null; current_recipient_email?: string | null; current_client_name?: string | null; last_attempt_at: string | null; sent_at: string | null; can_resend: boolean; reason: string | null };
export type Lead = { id: string; listingId: string | null; name: string; email: string; phone: string; message: string; address: string; source: string; status: LeadStatus; synced: boolean; createdAt: string; clientDelivery?: ClientDelivery | null };
export type TeamMember = { id: string; name: string; email: string; role: Role; isYou: boolean };
export type TeamInvite = { id: string; email: string; role: Role; expiresAt: string };
export type Team = { canManage: boolean; used: number; allowed: number; members: TeamMember[]; invites: TeamInvite[] };
export type InviteResult = { email: string; outcome: string; code: string | null; expiresAt: string | null };
export const brandFields = ["name", "title", "brokerage", "phone", "email", "website", "avatar_url", "headshot_url", "instagram", "linkedin", "tiktok", "accent"] as const;
export type Brand = Record<typeof brandFields[number], string> & { org_name: string; handle: string; space_type: string };
export type Account = { brand: Brand; notifications: Notifications; portfolioUrl: string | null; planSource: string; plan: string | null; planExpiresAt: string | null; trialEndsAt: string | null; degraded: boolean; trialUsage?: TrialUsage | null; servingActivation?: ServingActivation | null; servingPhotoPackage?: PhotoPackage | null; meters: { key: string; title: string; used: number; cap: number; resetsAt: string | null }[] };
export function serviceActivationPending(account: Account, now = Date.now()): boolean {
  if (account.servingActivation?.available !== false) return false;
  if (account.trialUsage) return account.trialUsage.status === "active";
  return account.planSource === "apple" && (account.plan === "starter" || account.plan === "pro" || account.plan === "team")
    && account.planExpiresAt !== null && Date.parse(account.planExpiresAt) > now;
}
export type ComplianceRow = { id: string; listingId: string | null; address: string; label: string; kind: string; edit: string; disclosure: string; originalUrl: string | null; alteredUrl: string | null; originalAvailable: boolean; agent: string; createdAt: string; model: string; prompt: string };
export type Compliance = { rows: ComplianceRow[]; truncated: boolean };
export type Overview = { from: string; to: string; seats: { used: number; allowed: number; pending: number }; totals: { listings: number; tours: number; ai: number; inactive: number }; members: { id: string; name: string; role: string; listings: number; tours: number; ai: number; lastActive: string | null }[] };

export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Rendprop returned an unreadable response. Refresh this page.");
  return value as Record<string, unknown>;
}
function text(value: unknown, fallback = ""): string {
  if (value === null || value === undefined) return fallback;
  if (typeof value !== "string" || value.length > 20_000) throw new Error("Rendprop returned an unreadable text field.");
  return value;
}
function count(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new Error("Rendprop returned an unreadable count.");
  return value;
}
function rows(value: unknown, max = 5000): unknown[] {
  if (!Array.isArray(value) || value.length > max) throw new Error("Rendprop returned an unreadable list.");
  return value;
}
function boolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("Rendprop returned an unreadable setting.");
  return value;
}
function date(value: unknown): string {
  const v = text(value);
  if (!v || !Number.isFinite(Date.parse(v))) throw new Error("Rendprop returned an unreadable date.");
  return v;
}
function role(value: unknown): Role {
  if (!["owner", "admin", "agent", "marketing"].includes(text(value))) throw new Error("Rendprop returned an unknown team role.");
  return value as Role;
}
function nullableId(value: unknown): string | null { return value === null || value === undefined ? null : uuid(value); }
function unique<T extends { id: string }>(values: T[]): T[] {
  if (new Set(values.map((v) => v.id)).size !== values.length) throw new Error("Rendprop returned duplicate records. Refresh this page.");
  return values;
}
export function safeHTTPS(value: unknown): string | null {
  if (typeof value !== "string" || !value || value.length > 16_384) return null;
  try {
    const u = new URL(value);
    return u.protocol === "https:" && !u.username && !u.password ? u.href : null;
  } catch { return null; }
}
export function decodeLead(value: unknown): Lead {
  const r = record(value);
  const status = text(r.status);
  if (!(leadStatuses as readonly string[]).includes(status)) throw new Error("Rendprop returned an unknown lead status.");
  return { id: uuid(r.id), listingId: nullableId(r.listing_id), name: text(r.name, "New inquiry"), email: text(r.email), phone: text(r.phone), message: text(r.message), address: text(r.listing_address, "General inquiry"), source: text(r.source, "tour"), status: status as LeadStatus, synced: boolean(r.synced_crm), createdAt: date(r.created_at), clientDelivery: r.client_delivery == null ? null : decodeClientDelivery(r.client_delivery) };
}
export function decodeClientDelivery(value: unknown): ClientDelivery {
  const r = record(value), state = text(r.state), recipient_email = r.recipient_email === null ? null : text(r.recipient_email);
  if (!["queued", "sending", "email_sent", "failed", "skipped"].includes(state) || (recipient_email === null ? state !== "skipped" || r.last_attempt_at != null || r.sent_at != null : recipient_email.length > 200 || !/^[^\s@?&#]+@[^\s@?&#]+\.[^\s@?&#]+$/.test(recipient_email))) throw new Error("The client email delivery could not be verified. Refresh your leads.");
  const current_recipient_email = r.current_recipient_email == null ? null : text(r.current_recipient_email);
  if (current_recipient_email && (current_recipient_email.length > 200 || !/^[^\s@?&#]+@[^\s@?&#]+\.[^\s@?&#]+$/.test(current_recipient_email))) throw new Error("The current client recipient could not be verified.");
  return { state: state as ClientDelivery["state"], recipient_email, client_name: r.client_name === null ? null : text(r.client_name), ...(r.current_recipient_email === undefined ? {} : {current_recipient_email}), ...(r.current_client_name === undefined ? {} : {current_client_name: r.current_client_name === null ? null : text(r.current_client_name)}), last_attempt_at: r.last_attempt_at == null ? null : date(r.last_attempt_at), sent_at: r.sent_at == null ? null : date(r.sent_at), can_resend: boolean(r.can_resend), reason: r.reason == null ? null : text(r.reason) };
}
export function decodeLeads(value: unknown): Lead[] { return unique(rows(record(value).leads, 500).map(decodeLead)); }
export function filterLeads(leads: Lead[], query: string): Lead[] {
  const q = query.trim().toLocaleLowerCase();
  return q ? leads.filter((l) => [l.name, l.email, l.phone, l.address, l.message, l.clientDelivery?.client_name ?? "", l.clientDelivery?.recipient_email ?? "", l.clientDelivery?.current_client_name ?? "", l.clientDelivery?.current_recipient_email ?? ""].some((v) => v.toLocaleLowerCase().includes(q))) : leads;
}
export function decodeTeam(value: unknown, orgId: string): Team {
  const r = record(value), seats = record(r.seats);
  if (uuid(r.org_id) !== orgId) throw new Error("This team belongs to a different workspace. Reload Studio.");
  const canManage = boolean(r.can_manage);
  return { canManage, used: count(seats.used), allowed: count(seats.allowed), members: unique(rows(r.members).map((v) => {
    const m = record(v); return { id: uuid(m.user_id), name: text(m.name), email: text(m.email), role: role(m.role), isYou: boolean(m.is_you) };
  })), invites: canManage ? unique(rows(r.invites).map((v) => {
    const i = record(v); return { id: uuid(i.id), email: text(i.email), role: role(i.role), expiresAt: date(i.expires_at) };
  })) : [] };
}
export function workspaceRole(workspace: Workspace): Role | null { return workspace.memberships.find((m) => m.orgId === workspace.org.id)?.role ?? null; }
export function manager(role: Role | null): boolean { return role === "owner" || role === "admin"; }
export function canRemoveMember(actor: Role | null, member: TeamMember): boolean {
  return manager(actor) && !member.isYou && member.role !== "owner" && (member.role !== "admin" || actor === "owner");
}
export function canEditLeads(role: Role | null): boolean { return role === "owner" || role === "admin" || role === "agent"; }
export function decodeNotifications(value: unknown): Notifications {
  const r = record(value), result = {} as Notifications;
  for (const key of Object.keys(notificationLabels) as NotificationKey[]) result[key] = boolean(r[key]);
  result.muted_until = r.muted_until === null ? null : date(r.muted_until);
  return result;
}
export function decodeAccount(value: unknown, workspace: Workspace): Account {
  const r = record(value), org = record(r.org), user = record(r.user);
  if (uuid(org.id) !== workspace.org.id || uuid(user.id) !== workspace.user.id) throw new Error("The account changed. Reload Studio.");
  const kit = record(org.brand_kit ?? {}), brand = {} as Brand;
  for (const field of brandFields) brand[field] = text(kit[field]);
  Object.assign(brand, { org_name: text(org.name), handle: text(org.handle), space_type: text(org.space_type) });
  const usage = record(r.usage), used = record(usage.by_feature), caps = record(usage.caps), windows = record(usage.windows);
  const servingActivation = decodeServingActivation(r.serving_activation, workspace.org.id);
  const entitlement = record(r.entitlement), degraded = (entitlement.degraded === undefined ? false : boolean(entitlement.degraded)) || servingActivation?.available === false;
  const titles: Record<string, string> = { renders: "Cloud renders", photo_edits: "Photo edits", reels: "AI reels", aerials: "Aerial videos", drone: "Drone enhancements" };
  const meters = Object.entries(titles).map(([key, title]) => {
    const cap = count(caps[key]);
    return { key, title, used: count(used[key]), cap: servingActivation?.available === false ? 0 : cap, resetsAt: windows[key] === null ? null : date(record(windows[key]).resets_at) };
  });
  return { brand, notifications: decodeNotifications(r.notifications), portfolioUrl: safeHTTPS(r.portfolio_url), planSource: text(r.plan_source), plan: r.plan == null ? null : text(r.plan), planExpiresAt: r.plan_expires_at == null ? null : date(r.plan_expires_at), trialEndsAt: r.trial_ends_at == null ? null : date(r.trial_ends_at), degraded, trialUsage: decodeTrialUsage(r.trial_usage, workspace.org.id), servingActivation, servingPhotoPackage: decodePhotoPackage(r.serving_photo_package, workspace.org.id), meters };
}
export function brandPayload(brand: Brand): Record<string, string | null> {
  if (!brand.org_name.trim() || brand.org_name.length > 120 || brand.org_name.includes("@")) throw new Error("Enter a business name up to 120 characters.");
  if (brand.name.includes("@")) throw new Error("Use your name in the display name field and your email in the email field.");
  if (brand.handle && !/^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$/.test(brand.handle.trim().toLowerCase())) throw new Error("Portfolio address needs 3–32 letters, numbers or hyphens, starting and ending with a letter or number.");
  if (!["real_estate", "venue", "restaurant", "retail", "fitness", "other"].includes(brand.space_type)) throw new Error("Choose a business type.");
  if (brand.accent && !/^#([a-f\d]{3}|[a-f\d]{4}|[a-f\d]{6}|[a-f\d]{8})$/i.test(brand.accent)) throw new Error("Enter a brand color such as #7c3aed.");
  const payload: Record<string, string | null> = { org_name: brand.org_name.trim(), handle: brand.handle.trim().toLowerCase() || null, space_type: brand.space_type };
  for (const field of brandFields) {
    if (brand[field].length > 300) throw new Error(`${field.replaceAll("_", " ")} must be 300 characters or fewer.`);
    payload[field] = brand[field].trim() || null;
  }
  for (const key of ["website", "avatar_url", "headshot_url", "instagram", "linkedin", "tiktok"] as const) {
    let value = payload[key];
    if (value && !/^[a-z][a-z0-9+.-]*:/i.test(value) && !/\s/.test(value)) {
      const bases = { instagram: "https://instagram.com/", linkedin: "https://linkedin.com/in/", tiktok: "https://tiktok.com/@" };
      const social = key === "instagram" || key === "linkedin" || key === "tiktok";
      const isHost = !value.startsWith("@") && (/^(www\.)/i.test(value) || value.includes("/") || /\.(com|net|org|io|co|app|me|tv|us|uk|ca|au|de|fr|es|it|nl|biz|info|realtor|homes|realestate|bar|restaurant|fit)$/i.test(value));
      if (social && !isHost && /^@?[a-z0-9_.-]+$/i.test(value)) value = bases[key] + value.replace(/^@/, "");
      else if (key === "website" || social) value = "https://" + value;
      payload[key] = value;
    }
    if (payload[key] && !safeHTTPS(payload[key])) throw new Error(`Use a complete https:// address for ${key.replaceAll("_", " ")}.`);
  }
  return payload;
}
export function inviteEmails(value: string): string[] {
  const emails = value.split(/[\s,;]+/).map((v) => v.trim()).filter(Boolean);
  if (emails.length > 200) throw new Error("Invite up to 200 people at a time.");
  if (emails.some((e) => e.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e))) throw new Error("Check the email addresses. Separate each one with a comma or a new line.");
  return [...new Set(emails.map((e) => e.toLowerCase()))];
}
export function decodeInviteResults(value: unknown, bulk: boolean): InviteResult[] {
  const r = record(value);
  return (bulk ? rows(r.results, 200) : [r]).map((raw) => {
    const i = record(raw), code = i.code === undefined || i.code === null ? null : text(i.code);
    if (code && !/^[A-Z0-9-]{12,20}$/.test(code)) throw new Error("The invite was created but its code could not be read. Reload the team before creating another invite.");
    return { email: text(i.email), outcome: bulk ? text(i.outcome) : "issued", code, expiresAt: i.expires_at ? date(i.expires_at) : null };
  });
}
export function decodeCompliance(value: unknown, orgId: string): Compliance {
  const r = record(value);
  if (uuid(r.org_id) !== orgId) throw new Error("This report belongs to a different workspace. Reload Studio.");
  const result = unique(rows(r.rows).map((raw) => {
    const p = record(raw);
    return { id: uuid(p.id), listingId: nullableId(p.listing_id), address: text(p.listing_address), label: text(p.label), kind: text(p.kind), edit: text(p.edit), disclosure: text(p.disclosure), originalUrl: safeHTTPS(p.original_url), alteredUrl: safeHTTPS(p.altered_url), originalAvailable: boolean(p.original_available), agent: text(p.agent, text(p.agent_name)), createdAt: date(p.created_at), model: text(p.model_id), prompt: text(p.prompt_summary) };
  }));
  if (count(r.count) !== result.length) throw new Error("This report is incomplete. Refresh it before exporting.");
  return { rows: result, truncated: boolean(r.truncated) };
}
export function decodeOverview(value: unknown, orgId: string): Overview {
  const r = record(value), seats = record(r.seats), totals = record(r.totals);
  if (uuid(r.org_id) !== orgId) throw new Error("This overview belongs to a different workspace. Reload Studio.");
  return { from: date(r.from), to: date(r.to), seats: { used: count(seats.used), allowed: count(seats.allowed), pending: count(seats.pending) }, totals: { listings: count(totals.listings), tours: count(totals.tours_published), ai: count(totals.ai_assets_published), inactive: count(totals.members_published_nothing) }, members: unique(rows(r.members).map((raw) => {
    const m = record(raw); return { id: uuid(m.user_id), name: text(m.name, text(m.email, "Team member")), role: role(m.role), listings: count(m.listings), tours: count(m.tours_published), ai: count(m.ai_assets_published), lastActive: m.last_activity_at ? date(m.last_activity_at) : null };
  })) };
}
export function csv(rows: (string | number | boolean | null)[][]): string {
  return "\ufeff" + rows.map((row) => row.map((value) => {
    let text = String(value ?? "");
    if (/^[\s\u0000-\u001f]*[=+@-]/.test(text)) text = `'${text}`;
    return `"${text.replaceAll('"', '""')}"`;
  }).join(",")).join("\r\n") + "\r\n";
}
export function contactLink(kind: "email" | "phone", value: string): string | null {
  if (kind === "email") return /^[^\s@?&#]+@[^\s@?&#]+\.[^\s@?&#]+$/.test(value) ? `mailto:${encodeURIComponent(value)}` : null;
  const phone = value.replace(/[\s().-]/g, "");
  return /^\+?\d{5,18}$/.test(phone) ? `tel:${phone}` : null;
}
