import {isPrivateMediaURL,privateMediaCapability} from "./private-media";
import { StudioError } from "./config";
import { decodePhotoPackage, type PhotoPackage } from "./photo-package";
import { decodeServingActivation, decodeTrialOffer, decodeTrialUsage, type ServingActivation, type TrialOffer, type TrialUsage } from "./trial";

export type Role = "owner" | "admin" | "agent" | "marketing" | "team_owner";
export type RealEstateRole = "agent" | "photographer_videographer";
export function decodeRealEstateRole(value: unknown): RealEstateRole | null {
  if (value === undefined || value === null) return null;
  if (value !== "agent" && value !== "photographer_videographer") throw new Error("Your real estate work preference could not be read. Refresh your account.");
  return value;
}
export type Membership = {
  orgId: string;
  role: Role;
  orgName: string;
  spaceType: string;
  accessMode?: "own" | "team_owner";
  libraryOwnerUserId?: string;
  billingOrgId?: string;
  canRead?: boolean;
  canWrite?: boolean;
  canManageSubscription?: boolean;
};
export type WorkspaceDirectory = {
  actorId: string; ownOrgId: string; billingOrgId: string; activeOrgId: string;
  canSwitchAgentLibraries: boolean; workspaces: Membership[];
};
export type Workspace = {
  user: {
    id: string;
    email: string | null;
    name: string | null;
    avatarUrl: string | null;
    realEstateRole?: RealEstateRole | null;
  };
  org: { id: string; name: string; handle: string | null; spaceType: string };
  plan: string;
  planRaw: string | null;
  /** The server could not verify the effective entitlement; do not display its fallback as a downgrade. */
  planDegraded: boolean;
  trialEndsAt: string | null;
  trialUsage?: TrialUsage | null;
  trialOffer?: TrialOffer | null;
  servingActivation?: ServingActivation | null;
  servingPhotoPackage?: PhotoPackage | null;
  planExpiresAt: string | null;
  memberships: Membership[];
  ownOrgId?: string;
  billingOrgId?: string;
  canSwitchAgentLibraries?: boolean;
  servingOrgId?: string;
  /** Selected logical library, retained only for listing-specific real-org requests. */
  libraryOrgId?: string;
  usage: { listings: number; leads: number; leadsNew: number; renders: number };
};
export type Listing = {
  id: string;
  agentId?: string;
  orgId: string;
  libraryOrgId?: string;
  spaceType: string;
  address: string | null;
  tagline: string | null;
  details: Record<string, unknown>;
  status: string;
  createdAt: string;
  mainPhotoKey: string | null;
  soldAt?: string | null;
  beds: number | null;
  baths: number | null;
  sqft: number | null;
  priceCents: number | null;
};
export type StudioPhoto = {
  id: string;
  listingId: string;
  url: string;
  expiresAt: string;
  caption: string | null;
  isStaged: boolean;
  isAltered?: boolean;
  originalUrl?: string | null;
  sort: number;
};
export type StudioVideo = {
  id: string;
  listingId: string;
  url: string;
  expiresAt: string;
  kind: "video";
  createdAt: string;
  durationSeconds: number | null;
};
export type ListingMedia = {
  orgId: string;
  listingId: string;
  photos: readonly StudioPhoto[];
  videos: readonly StudioVideo[];
  nextOffset: number | null;
  unavailableCount: number;
};

// Literal wire DTOs mirror existing routes. Normalization happens only after validation.
export type MembershipDTO = {
  user_id: string;
  org_id: string;
  role: Role;
  orgs: { id: string; name: string; space_type: string; deleted_at: null };
};
export type MeDTO = {
  user: {
    id: string;
    email?: string | null;
    name?: string | null;
    avatar_url?: string | null;
    real_estate_role?: RealEstateRole | null;
  };
  org: { id: string; name: string; handle: string | null; space_type: string };
  plan: string;
  plan_raw: string | null;
  trial_ends_at: string | null;
  trial_usage?: unknown;
  trial_offer?: unknown;
  serving_activation?: unknown;
  serving_photo_package?: unknown;
  plan_expires_at?: string | null;
  entitlement?: { degraded?: boolean };
  usage: {
    listings: number;
    leads: number;
    leads_new: number;
    renders: number;
  };
};
export type ListingDTO = {
  id: string;
  org_id: string;
  space_type: string;
  address: string | null;
  tagline: string | null;
  details: Record<string, unknown>;
  status: string;
  created_at: string;
  main_photo_key: string | null;
  beds: number | null;
  baths: number | null;
  sqft: number | null;
  price_cents: number | null;
  deleted_at: null;
};
export type StudioPhotoDTO = {
  id: string;
  listing_id: string;
  url: string;
  expires_at: string;
  caption: string | null;
  is_staged: boolean;
  sort: number;
};
export type StudioVideoDTO = {
  id: string;
  listing_id: string;
  url: string;
  expires_at: string;
  kind: "video";
  created_at: string;
  duration_s: number | null;
};
export type ListingMediaDTO = {
  org_id: string;
  listing_id: string;
  photos: readonly StudioPhotoDTO[];
  videos: readonly StudioVideoDTO[];
  next_offset: number | null;
  unavailable_count: number;
};

function invalid(field: string): never {
  throw new StudioError(
    "invalid-response",
    `The server returned an invalid ${field}. Please retry.`,
  );
}
function record(value: unknown, field: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return invalid(field);
  }
  return value as Record<string, unknown>;
}
function list(value: unknown, field: string): unknown[] {
  if (!Array.isArray(value)) return invalid(field);
  return value;
}
function str(value: unknown, field: string): string {
  if (typeof value !== "string" || !value.trim() || value.length > 16_384) return invalid(field);
  return value;
}
function nullableString(
  value: unknown,
  field: string,
  optional = false,
): string | null {
  if (value === null || (optional && value === undefined)) return null;
  if (typeof value !== "string" || value.length > 16_384) return invalid(field);
  return value;
}
export function uuid(value: unknown, field = "identifier"): string {
  const v = str(value, field);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)
  ) {
    return invalid(field);
  }
  return v.toLowerCase();
}
function num(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    return invalid(field);
  }
  return value;
}
function nullableNumber(value: unknown, field: string): number | null {
  return value === null ? null : num(value, field);
}
function integer(value: unknown, field: string): number {
  const n = num(value, field);
  if (!Number.isSafeInteger(n)) return invalid(field);
  return n;
}
function date(value: unknown, field: string): string {
  const s = str(value, field);
  if (!Number.isFinite(Date.parse(s))) return invalid(field);
  return s;
}
function nullableDate(
  value: unknown,
  field: string,
  optional = false,
): string | null {
  return value === null || (optional && value === undefined)
    ? null
    : date(value, field);
}
function equal(actual: string, expected: string, field: string): void {
  if (actual !== expected) {
    throw new StudioError(
      "identity-mismatch",
      `The server returned data outside the current ${field}. Reload the workspace.`,
    );
  }
}
function unique(values: { id: string }[], field: string): void {
  if (new Set(values.map((value) => value.id)).size !== values.length) {
    invalid(field);
  }
}

export function decodeMemberships(
  value: unknown,
  userId: string,
): Membership[] {
  const rows = list(value, "workspace memberships").map((raw) => {
    const row = record(raw, "membership");
    equal(uuid(row.user_id, "membership user_id"), userId, "account");
    const orgId = uuid(row.org_id, "membership org_id");
    const role = str(row.role, "membership role");
    if (!["owner", "admin", "agent", "marketing"].includes(role)) {
      invalid("membership role");
    }
    const org = record(row.orgs, "membership orgs");
    equal(uuid(org.id, "organization id"), orgId, "workspace");
    if (org.deleted_at !== null) invalid("organization deleted_at");
    return {
      orgId,
      role: role as Role,
      orgName: str(org.name, "organization name"),
      spaceType: str(org.space_type, "organization space_type"),
    };
  });
  unique(
    rows.map((row) => ({ id: row.orgId })),
    "duplicate membership",
  );
  return rows;
}

export function decodeWorkspace(
  value: unknown,
  userId: string,
  memberships: Membership[],
  requestedOrg?: string,
  directory?: WorkspaceDirectory,
): Workspace {
  const row = record(value, "workspace");
  const user = record(row.user, "workspace user");
  equal(uuid(user.id, "user id"), userId, "account");
  const org = record(row.org, "workspace org");
  const orgId = uuid(org.id, "organization id");
  if (!memberships.some((m) => m.orgId === orgId)) {
    throw new StudioError(
      "identity-mismatch",
      "This workspace is not in your current memberships. Reload the workspace.",
    );
  }
  if (requestedOrg) equal(orgId, requestedOrg, "workspace");
  const usage = record(row.usage, "workspace usage");
  const entitlement = row.entitlement === undefined ? undefined : record(row.entitlement, "entitlement");
  if (entitlement?.degraded !== undefined && typeof entitlement.degraded !== "boolean")
    invalid("entitlement degraded state");
  const billingOrg = directory?.billingOrgId ?? orgId;
  const servingOrg = directory?.workspaces.find(m => m.orgId === orgId)?.billingOrgId ?? orgId;
  if (directory) {
    equal(directory.actorId, userId, "account");
    const billing = record(row.billing, "billing");
    equal(uuid(billing.content_org_id, "billing content org"), orgId, "listing library");
    equal(uuid(billing.org_id, "billing org"), billingOrg, "billing account");
    equal(uuid(billing.serving_org_id, "serving org"), servingOrg, "serving account");
    if (typeof billing.can_manage_subscription !== "boolean") invalid("billing authority");
  }
  const servingActivation = decodeServingActivation(row.serving_activation, servingOrg);
  return {
    user: {
      id: userId,
      email: nullableString(user.email, "user email", true),
      name: nullableString(user.name, "user name", true),
      avatarUrl: nullableString(user.avatar_url, "user avatar_url", true),
      realEstateRole: decodeRealEstateRole(user.real_estate_role),
    },
    org: {
      id: orgId,
      name: str(org.name, "organization name"),
      handle: nullableString(org.handle, "organization handle"),
      spaceType: str(org.space_type, "organization space_type"),
    },
    plan: str(row.plan, "plan"),
    planRaw: nullableString(row.plan_raw, "plan_raw"),
    planDegraded: entitlement?.degraded === true || servingActivation?.available === false,
    trialEndsAt: nullableDate(row.trial_ends_at, "trial_ends_at"),
    trialUsage: decodeTrialUsage(row.trial_usage, servingOrg),
    trialOffer: decodeTrialOffer(row.trial_offer),
    servingActivation,
    servingPhotoPackage: decodePhotoPackage(row.serving_photo_package, servingOrg),
    planExpiresAt: nullableDate(row.plan_expires_at, "plan_expires_at", true),
    memberships,
    ...(directory ? { ownOrgId: directory.ownOrgId, billingOrgId: billingOrg, servingOrgId: servingOrg, canSwitchAgentLibraries: directory.canSwitchAgentLibraries } : {}),
    usage: {
      listings: integer(usage.listings, "listing usage"),
      leads: integer(usage.leads, "leads usage"),
      leadsNew: integer(usage.leads_new, "leads_new usage"),
      renders: integer(usage.renders, "renders usage"),
    },
  };
}

function boundedDetails(value: unknown): Record<string, unknown> {
  const details = record(value, "listing details");
  try {
    if (new TextEncoder().encode(JSON.stringify(details)).byteLength > 65_536)
      return invalid("listing details size");
  } catch {
    return invalid("listing details size");
  }
  return details;
}

export function decodeListings(
  value: unknown,
  orgId: string,
  memberships: Membership[],
  authoritativeLibrary = false,
): Listing[] {
  const allowed = new Set(memberships.map((m) => m.orgId));
  if (!allowed.has(orgId)) {
    throw new StudioError(
      "membership-required",
      "Reload your workspace before opening these listings.",
    );
  }
  const rows = list(value, "listings").map((raw) => {
    const row = record(raw, "listing");
    const rowOrg = uuid(row.org_id, "listing org_id");
    // Existing GET /listings returns all caller-visible orgs, ignoring X-Org-Id.
    // Validate the whole response before selecting; an unknown tenant fails closed.
    const libraryOrg = authoritativeLibrary ? uuid(row.library_org_id, "listing library_org_id") : rowOrg;
    if (!allowed.has(libraryOrg) || (authoritativeLibrary && libraryOrg !== orgId)) {
      throw new StudioError(
        "identity-mismatch",
        "The server returned a listing outside your current memberships. Reload the workspace.",
      );
    }
    if (row.deleted_at !== null) invalid("listing deleted_at");
    const status = str(row.status, "listing status");
    if (
      ![
        "draft",
        "capturing",
        "uploading",
        "processing",
        "ready",
        "expired",
        "archived",
      ].includes(status)
    ) {
      invalid("listing status");
    }
    const priceCents = nullableNumber(row.price_cents, "listing price_cents");
    if (priceCents !== null && !Number.isSafeInteger(priceCents)) {
      invalid("listing price_cents");
    }
    return {
      id: uuid(row.id, "listing id"),
      ...(row.agent_id == null ? {} : { agentId: uuid(row.agent_id, "listing agent_id") }),
      orgId: rowOrg,
      ...(authoritativeLibrary ? { libraryOrgId: libraryOrg } : {}),
      spaceType: str(row.space_type, "listing space_type"),
      address: nullableString(row.address, "listing address"),
      tagline: nullableString(row.tagline, "listing tagline"),
      details: boundedDetails(row.details),
      status,
      createdAt: date(row.created_at, "listing created_at"),
      soldAt: row.sold_at == null ? null : date(row.sold_at, "listing sold_at"),
      mainPhotoKey: nullableString(
        row.main_photo_key,
        "listing main_photo_key",
      ),
      beds: nullableNumber(row.beds, "listing beds"),
      baths: nullableNumber(row.baths, "listing baths"),
      sqft: nullableNumber(row.sqft, "listing sqft"),
      priceCents,
    };
  });
  unique(rows, "duplicate listing");
  return rows.filter((row) => (row.libraryOrgId ?? row.orgId) === orgId);
}

/** No plan, ordinary owner role, or saved browser preference grants delegation. */
export function decodeWorkspaceDirectory(value: unknown, actor: string): WorkspaceDirectory {
  const row = record(value, "listing directory");
  equal(uuid(row.actor_id, "directory actor"), actor, "account");
  const ownOrgId = uuid(row.own_org_id, "own library"), billingOrgId = uuid(row.billing_org_id, "billing account");
  const activeOrgId = uuid(row.active_org_id, "active library");
  if (typeof row.can_switch_agent_libraries !== "boolean") invalid("library switching authority");
  const canSwitchAgentLibraries = row.can_switch_agent_libraries;
  const workspaces = list(row.workspaces, "listing libraries").map(raw => {
    const entry = record(raw, "listing library"), orgId = uuid(entry.id, "library id");
    const owner = uuid(entry.library_owner_user_id, "library owner"), role = str(entry.role, "library role");
    const mode = entry.access_mode;
    if (entry.can_read !== true || typeof entry.can_write !== "boolean" || typeof entry.can_manage_subscription !== "boolean") invalid("library access");
    if (mode === "own") { if (role !== "owner" || owner !== actor) invalid("own library access"); }
    else if (mode !== "team_owner" || !canSwitchAgentLibraries || role !== "team_owner" || owner === actor || entry.can_manage_subscription !== false) invalid("delegated library access");
    return { orgId, orgName: entry.name == null ? "My listings" : str(entry.name, "library name"), role: role as Role,
      spaceType: typeof entry.space_type === "string" ? str(entry.space_type, "library business") : "",
      accessMode: mode as "own" | "team_owner", libraryOwnerUserId: owner,
      billingOrgId: uuid(entry.billing_org_id, "library billing account"), canRead: true,
      canWrite: entry.can_write, canManageSubscription: entry.can_manage_subscription };
  });
  unique(workspaces.map(m => ({id:m.orgId})), "duplicate library");
  if (!workspaces.length || workspaces.length > 10_000 || !workspaces.some(m => m.orgId === ownOrgId && m.accessMode === "own") ||
      !workspaces.some(m => m.orgId === activeOrgId && (canSwitchAgentLibraries || m.orgId === ownOrgId))) invalid("active library");
  return { actorId: actor, ownOrgId, billingOrgId, activeOrgId, canSwitchAgentLibraries, workspaces };
}

export function belongsToLibrary(listing: Listing, workspace: Workspace): boolean {
  return (listing.libraryOrgId ?? listing.orgId) === (workspace.libraryOrgId ?? workspace.org.id);
}
export function canEditListing(workspace: Workspace, listing: Listing): boolean {
  if (!belongsToLibrary(listing, workspace)) return false;
  const member = workspace.memberships.find(m => m.orgId === (workspace.libraryOrgId ?? workspace.org.id));
  return member?.canWrite ?? ["owner", "admin", "agent"].includes(member?.role ?? "");
}
/** A listing feature sends real-org headers without changing the selected library. */
export function scopedListingWorkspace(workspace: Workspace, listing: Listing): Workspace {
  if (!belongsToLibrary(listing, workspace)) invalid("selected listing library");
  return { ...workspace, libraryOrgId: workspace.libraryOrgId ?? workspace.org.id, org: { ...workspace.org, id: listing.orgId } };
}

export function mediaURL(
  value: unknown,
  orgId: string,
  listingId: string,
  expiresAt: string,
  now: number,
  actor?: string,
): string {
  const s = str(value, "media URL");
  if(isPrivateMediaURL(s)){const c=privateMediaCapability(s,{actor:actor??"",org:orgId,listing:listingId},now);if(!Number.isFinite(Date.parse(expiresAt))||Date.parse(expiresAt)>c.exp*1000+1000)invalid("media expiry mismatch");return s;}
  let url: URL;
  try {
    url = new URL(s);
  } catch {
    return invalid("media URL");
  }
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.hash ||
    url.port ||
    !/^[a-f0-9]{32}\.r2\.cloudflarestorage\.com$/.test(url.hostname) ||
    [...url.searchParams.keys()].some((key) =>
      ["access_token", "refresh_token", "token", "apikey"].includes(
        key.toLowerCase(),
      )
    )
  ) {
    invalid("media URL");
  }
  let segments: string[];
  try {
    segments = url.pathname.slice(1).split("/").map(decodeURIComponent);
  } catch {
    return invalid("media URL path");
  }
  // Match the existing path-style signer: /<bucket>/<uploads|renders>/<org>/<listing>/<file>.
  // This validates the literal route contract, not the cryptographic signature.
  if (
    segments.length < 5 || !["uploads", "renders"].includes(segments[1]!) ||
    !(segments[2] === orgId && segments[3] === listingId || segments[1] === "renders" && segments[2] === listingId) ||
    segments.some((segment) =>
      !segment || segment === "." || segment === ".." ||
      /[\\/%?#\u0000-\u001f]/.test(segment)
    )
  ) {
    invalid("media URL scope");
  }
  const params = url.searchParams;
  const names = [...params.keys()];
  if (
    new Set(names.map((name) => name.toLowerCase())).size !== names.length ||
    params.get("X-Amz-Algorithm") !== "AWS4-HMAC-SHA256" ||
    !/^[a-f0-9]{64}$/i.test(params.get("X-Amz-Signature") ?? "") ||
    params.get("X-Amz-SignedHeaders") !== "host" ||
    !params.get("X-Amz-Credential")
  ) invalid("media signature");
  const stamp = params.get("X-Amz-Date") ?? "";
  const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(stamp);
  const seconds = params.get("X-Amz-Expires") ?? "";
  if (!match || !/^[1-9]\d{0,2}$/.test(seconds) || Number(seconds) > 600) {
    invalid("media signature lifetime");
  }
  const issuedAt = Date.parse(
    `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}Z`,
  );
  if (
    !Number.isFinite(issuedAt) ||
    new Date(issuedAt).toISOString().replace(/[-:]/g, "").replace(
        ".000",
        "",
      ) !== stamp
  ) {
    invalid("media signature date");
  }
  const signedExpiry = issuedAt + Number(seconds) * 1000;
  if (signedExpiry <= now) {
    throw new StudioError(
      "media-expired",
      "The private media link has expired. Refresh the library.",
    );
  }
  // SigV4 timestamps have second precision, while the route's timestamp has milliseconds.
  if (Date.parse(expiresAt) > signedExpiry + 1000) {
    invalid("media expiry mismatch");
  }
  return s;
}
export function mediaOffset(value: unknown): number {
  const offset = integer(value, "media page offset");
  if (offset % 50 !== 0 || offset > 10000) invalid("media page offset");
  return offset;
}
export function decodeMedia(
  value: unknown,
  orgId: string,
  listingId: string,
  offset = 0,
  actor?: string,
): ListingMedia {
  const row = record(value, "listing media");
  const now = Date.now();
  mediaOffset(offset);
  equal(uuid(row.org_id, "media org_id"), orgId, "workspace");
  equal(uuid(row.listing_id, "media listing_id"), listingId, "listing");
  function common(raw: unknown) {
    const item = record(raw, "media item");
    equal(uuid(item.listing_id, "media listing_id"), listingId, "listing");
    const expiresAt = date(item.expires_at, "media expires_at");
    if (Date.parse(expiresAt) <= now) {
      throw new StudioError(
        "media-expired",
        "The private media link has expired. Refresh the library.",
      );
    }
    return {
      item,
      id: uuid(item.id, "media id"),
      listingId,
      url: mediaURL(item.url, orgId, listingId, expiresAt, now, actor),
      expiresAt,
    };
  }
  const photoRows = list(row.photos, "photos"),
    videoRows = list(row.videos, "videos");
  if (photoRows.length > 100 || videoRows.length > 100) {
    invalid("media page size");
  }
  const nextOffset = row.next_offset === null
    ? null
    : mediaOffset(row.next_offset);
  if (nextOffset !== null && nextOffset !== offset + 50) {
    invalid("media next_offset");
  }
  const unavailableCount = integer(
    row.unavailable_count,
    "media unavailable_count",
  );
  const photos = photoRows.map((raw) => {
    const { item, ...base } = common(raw);
    if (typeof item.is_staged !== "boolean") invalid("photo is_staged");
    return {
      ...base,
      caption: nullableString(item.caption, "photo caption"),
      isStaged: item.is_staged,
      ...(item.is_altered === undefined ? {} : { isAltered: item.is_altered === true }),
      ...(item.original_url === undefined ? {} : { originalUrl: item.original_url === null ? null : mediaURL(item.original_url, orgId, listingId, base.expiresAt, now, actor) }),
      sort: integer(item.sort, "photo sort"),
    };
  });
  const videos = videoRows.map((raw) => {
    const { item, ...base } = common(raw);
    if (item.kind !== "video") invalid("video kind");
    return {
      ...base,
      kind: "video" as const,
      createdAt: date(item.created_at, "video created_at"),
      durationSeconds: nullableNumber(item.duration_s, "video duration_s"),
    };
  });
  unique(photos, "duplicate photo");
  unique(videos, "duplicate video");
  const propertyPhotos = photos.filter(photo => {
    try { return !decodeURIComponent(new URL(photo.url).pathname).split("/").at(-1)?.startsWith("contact-"); } catch { return false; }
  });
  return { orgId, listingId, photos: propertyPhotos, videos, nextOffset, unavailableCount };
}
