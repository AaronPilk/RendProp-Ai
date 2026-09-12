import { StudioError } from "./config";

export type Role = "owner" | "admin" | "agent" | "marketing";
export type Membership = {
  orgId: string;
  role: Role;
  orgName: string;
  spaceType: string;
};
export type Workspace = {
  user: {
    id: string;
    email: string | null;
    name: string | null;
    avatarUrl: string | null;
  };
  org: { id: string; name: string; handle: string | null; spaceType: string };
  plan: string;
  planRaw: string | null;
  trialEndsAt: string | null;
  planExpiresAt: string | null;
  memberships: Membership[];
  usage: { listings: number; leads: number; leadsNew: number; renders: number };
};
export type Listing = {
  id: string;
  orgId: string;
  spaceType: string;
  address: string | null;
  tagline: string | null;
  details: Record<string, unknown>;
  status: string;
  createdAt: string;
  mainPhotoKey: string | null;
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
  };
  org: { id: string; name: string; handle: string | null; space_type: string };
  plan: string;
  plan_raw: string | null;
  trial_ends_at: string | null;
  plan_expires_at?: string | null;
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
  if (typeof value !== "string" || !value.trim()) return invalid(field);
  return value;
}
function nullableString(
  value: unknown,
  field: string,
  optional = false,
): string | null {
  if (value === null || (optional && value === undefined)) return null;
  if (typeof value !== "string") return invalid(field);
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
  return {
    user: {
      id: userId,
      email: nullableString(user.email, "user email", true),
      name: nullableString(user.name, "user name", true),
      avatarUrl: nullableString(user.avatar_url, "user avatar_url", true),
    },
    org: {
      id: orgId,
      name: str(org.name, "organization name"),
      handle: nullableString(org.handle, "organization handle"),
      spaceType: str(org.space_type, "organization space_type"),
    },
    plan: str(row.plan, "plan"),
    planRaw: nullableString(row.plan_raw, "plan_raw"),
    trialEndsAt: nullableDate(row.trial_ends_at, "trial_ends_at"),
    planExpiresAt: nullableDate(row.plan_expires_at, "plan_expires_at", true),
    memberships,
    usage: {
      listings: integer(usage.listings, "listing usage"),
      leads: integer(usage.leads, "leads usage"),
      leadsNew: integer(usage.leads_new, "leads_new usage"),
      renders: integer(usage.renders, "renders usage"),
    },
  };
}

export function decodeListings(
  value: unknown,
  orgId: string,
  memberships: Membership[],
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
    if (!allowed.has(rowOrg)) {
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
      orgId: rowOrg,
      spaceType: str(row.space_type, "listing space_type"),
      address: nullableString(row.address, "listing address"),
      tagline: nullableString(row.tagline, "listing tagline"),
      details: record(row.details, "listing details"),
      status,
      createdAt: date(row.created_at, "listing created_at"),
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
  return rows.filter((row) => row.orgId === orgId);
}

function mediaURL(
  value: unknown,
  orgId: string,
  listingId: string,
  expiresAt: string,
  now: number,
): string {
  const s = str(value, "media URL");
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
    segments[2] !== orgId || segments[3] !== listingId ||
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
      url: mediaURL(item.url, orgId, listingId, expiresAt, now),
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
  return { orgId, listingId, photos, videos, nextOffset, unavailableCount };
}
