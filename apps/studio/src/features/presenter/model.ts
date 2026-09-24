import { mediaURL, uuid } from "../../data/contracts";

export const FORMATS = { listing_intro: "Listing introduction", property_tour: "Property tour", market_update: "Market update" } as const;
export type Format = keyof typeof FORMATS;
export type DraftForm = { id: string; profile_id: string; title: string; script: string; source_asset_id: string; format: Format; resolution: "480p" | "720p" };
export type Profile = {
  id: string; subject_user_id: string; source_listing_id: string; display_name: string; reference_asset_ids: string[];
  status: "pending" | "approved" | "revoked"; revision: number; approved_revision: number | null; invalid_reason?: string | null;
  permissions: { can_save: boolean; can_approve: boolean; can_revoke: boolean };
};
export type Draft = DraftForm & {
  listing_id: string; author_user_id: string; subject_user_id: string; profile_revision: number; revision: number;
  status: "draft" | "approved"; approved_revision: number | null; approved_profile_revision: number | null;
  permissions: { can_save: boolean; can_approve: boolean; can_request_generation: boolean; can_generate: boolean };
};
export type Candidate = { asset_id: string; listing_id: string; duration_s?: number };
export type PresenterState = {
  truncated: boolean; profiles: Profile[]; drafts: Draft[]; reference_candidates: Candidate[]; source_candidates: Candidate[];
  permissions: { can_save_profile: boolean; can_create_draft: boolean };
  runtime: { available: boolean; code: string; reason: string };
};
export type Preview = { asset_id: string; url: string; expires_at: string; duration_s?: number };
export type Action = Record<string, unknown> & { action: string; expected_revision: number };
export function invalid(): never { throw new Error("Presenter details could not be verified. Reload this property before continuing."); }
export function row(value: unknown): Record<string, unknown> { if (!value || typeof value !== "object" || Array.isArray(value)) return invalid(); return value as Record<string, unknown>; }
export function str(value: unknown, limit: number): string { if (typeof value !== "string" || !value.trim() || value.length > limit) return invalid(); return value; }
export function rev(value: unknown): number { if (!Number.isSafeInteger(value) || Number(value) < 1 || Number(value) >= 2147483647) return invalid(); return Number(value); }
function optionalRev(value: unknown): number | null { return value === null ? null : rev(value); }
export function list(value: unknown, max = 100): unknown[] { if (!Array.isArray(value) || value.length > max) return invalid(); return value; }
export function permissions<T extends string>(value: unknown, keys: T[]): Record<T, boolean> {
  const source = row(value); return Object.fromEntries(keys.map(key => { if (typeof source[key] !== "boolean") invalid(); return [key, source[key]]; })) as Record<T, boolean>;
}
function unique(values: string[]): string[] { if (new Set(values).size !== values.length) invalid(); return values; }
export function scope(raw: Record<string, unknown>, org: string, listing: string) { if (raw.org_id !== org || raw.listing_id !== listing) throw new Error("The account or property changed. Reopen Presenter to continue."); }
export function newDraft(profile_id = ""): DraftForm { return { id: crypto.randomUUID(), profile_id, title: "", script: "", source_asset_id: "", format: "listing_intro", resolution: "720p" }; }
export function formOf(draft: Draft): DraftForm { const { id, profile_id, title, script, source_asset_id, format, resolution } = draft; return { id, profile_id, title, script, source_asset_id, format, resolution }; }
export function sameForm(a: DraftForm, b: DraftForm) { return Object.keys(a).every(key => a[key as keyof DraftForm] === b[key as keyof DraftForm]); }
export function approvedProfile(profile: Profile | undefined): boolean { return !!profile && profile.status === "approved" && profile.approved_revision === profile.revision && !profile.invalid_reason; }
export function approvedDraft(draft: Draft | undefined, profile: Profile | undefined): boolean {
  return !!draft && approvedProfile(profile) && draft.profile_id === profile!.id && draft.profile_revision === profile!.revision && draft.status === "approved" && draft.approved_revision === draft.revision && draft.approved_profile_revision === profile!.revision;
}
export function decodePresenter(raw: unknown, org: string, listing: string): PresenterState {
  const data = row(raw); scope(data, org, listing);
  const profiles = list(data.profiles, 200).map(value => {
    const p = row(value), ids = unique(list(p.reference_asset_ids, 8).map(id => uuid(id)));
    if (!ids.length || !["pending", "approved", "revoked"].includes(String(p.status))) return invalid();
    return { id: uuid(p.id), subject_user_id: uuid(p.subject_user_id), source_listing_id: uuid(p.source_listing_id), display_name: str(p.display_name, 80), reference_asset_ids: ids,
      status: p.status as Profile["status"], revision: rev(p.revision), approved_revision: optionalRev(p.approved_revision), invalid_reason: p.invalid_reason == null ? null : str(p.invalid_reason, 500),
      permissions: permissions(p.permissions, ["can_save", "can_approve", "can_revoke"]) };
  });
  const drafts = list(data.drafts).map(value => {
    const d = row(value); if (d.listing_id !== listing || !Object.hasOwn(FORMATS, String(d.format)) || !["480p", "720p"].includes(String(d.resolution)) || !["draft", "approved"].includes(String(d.status))) return invalid();
    return { id: uuid(d.id), listing_id: listing, profile_id: uuid(d.profile_id), author_user_id: uuid(d.author_user_id), subject_user_id: uuid(d.subject_user_id), profile_revision: rev(d.profile_revision),
      title: str(d.title, 120), script: str(d.script, 2000), source_asset_id: uuid(d.source_asset_id), format: d.format as Format, resolution: d.resolution as DraftForm["resolution"],
      revision: rev(d.revision), status: d.status as Draft["status"], approved_revision: optionalRev(d.approved_revision), approved_profile_revision: optionalRev(d.approved_profile_revision),
      permissions: permissions(d.permissions, ["can_save", "can_approve", "can_request_generation", "can_generate"]) };
  });
  unique(profiles.map(p => p.id)); unique(drafts.map(d => d.id));
  const candidates = (key: string, video: boolean): Candidate[] => list(data[key], 200).map(value => {
    const c = row(value); if (c.listing_id !== listing) invalid();
    if (video && (typeof c.duration_s !== "number" || !Number.isFinite(c.duration_s) || c.duration_s < 4 || c.duration_s > 30)) invalid();
    return { asset_id: uuid(c.asset_id), listing_id: listing, ...(video ? { duration_s: Number(c.duration_s) } : {}) };
  });
  const runtime = row(data.runtime); if (typeof runtime.available !== "boolean") invalid();
  return { truncated: data.truncated ? Object.values(permissions(data.truncated, ["profiles", "drafts", "reference_candidates", "source_candidates"])).some(Boolean) : false, profiles, drafts, reference_candidates: candidates("reference_candidates", false), source_candidates: candidates("source_candidates", true),
    permissions: permissions(data.permissions, ["can_save_profile", "can_create_draft"]), runtime: { available: runtime.available, code: str(runtime.code, 100), reason: str(runtime.reason, 500) } };
}
export function decodePreviews(raw: unknown, org: string, listing: string, request: { ids?: string[]; profile?: Profile; source?: string }): Preview[] {
  const data = row(raw); scope(data, org, listing);
  if (request.profile && (data.profile_id !== request.profile.id || data.profile_revision !== request.profile.revision)) invalid();
  const values = request.source ? [data.source] : list(data.references, 8);
  const expected = request.profile?.reference_asset_ids ?? request.ids ?? [request.source!];
  const found = values.map(value => { const p = row(value), asset_id = uuid(p.asset_id), expires_at = str(p.expires_at, 80);
    if (!expected.includes(asset_id)) invalid();
    if (request.source && (typeof p.duration_s !== "number" || !Number.isFinite(p.duration_s) || p.duration_s < 4 || p.duration_s > 30)) invalid();
    return { asset_id, expires_at, url: mediaURL(p.url, org, request.profile?.source_listing_id ?? listing, expires_at, Date.now()), ...(request.source ? { duration_s: Number(p.duration_s) } : {}) };
  });
  unique(found.map(p => p.asset_id)); if (found.length !== expected.length) invalid(); return found;
}
/** A lost response is acknowledged only by the exact next revision and content. */
export function confirmsAction(state: PresenterState, action: Action, user: string): boolean {
  if (action.action.endsWith("profile")) {
    const p = state.profiles.find(p => action.profile_id ? p.id === action.profile_id : p.subject_user_id === user);
    if (!p || p.subject_user_id !== user || p.revision !== action.expected_revision + 1) return false;
    if (action.action === "save_profile") return p.status === "pending" && p.display_name === action.display_name && JSON.stringify(p.reference_asset_ids) === JSON.stringify(action.reference_asset_ids);
    return action.action === "approve_profile" ? approvedProfile(p) : p.status === "revoked";
  }
  const d = state.drafts.find(d => d.id === action.draft_id);
  if (!d || d.revision !== action.expected_revision + 1 || d.profile_revision !== action.expected_profile_revision) return false;
  if (action.action === "approve_draft") return d.status === "approved" && d.approved_revision === d.revision && d.approved_profile_revision === action.expected_profile_revision;
  return d.status === "draft" && ["profile_id", "title", "script", "source_asset_id", "format", "resolution"].every(key => d[key as keyof Draft] === action[key]);
}
