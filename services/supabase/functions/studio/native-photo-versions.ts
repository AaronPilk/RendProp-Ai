import {
  assert,
  HttpError,
  json,
  pathSegments,
  readJsonLimited,
} from "../_shared/http.ts";
import {
  type PrivateMediaScope,
  privateMediaUrl,
} from "../_shared/private-media.ts";
import type { StudioContext } from "./context.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HASH = /^[a-f0-9]{64}$/;
const VERSION_ID = /^[A-Za-z0-9-]{1,128}$/;
const PHOTO_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
  "image/heif",
]);
const MAX_PHOTO_BYTES = 50 * 1024 * 1024;

type RecordValue = Record<string, unknown>;
function object(value: unknown): value is RecordValue {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function keys(value: RecordValue, allowed: string[]): boolean {
  return Object.keys(value).every((key) => allowed.includes(key));
}
function idOrNull(value: unknown): boolean {
  return value === null || typeof value === "string" && VERSION_ID.test(value);
}
function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (object(value)) {
    return `{${
      Object.keys(value).sort().map((key) =>
        `${JSON.stringify(key)}:${stableJSON(value[key])}`
      ).join(",")
    }}`;
  }
  return JSON.stringify(value);
}
function asset(value: unknown): value is RecordValue {
  return object(value) &&
    keys(value, ["asset_id", "sha256", "bytes", "content_type"]) &&
    Object.keys(value).length === 4 && typeof value.asset_id === "string" &&
    UUID.test(value.asset_id) &&
    typeof value.sha256 === "string" && HASH.test(value.sha256) &&
    Number.isSafeInteger(value.bytes) && Number(value.bytes) >= 1 &&
    Number(value.bytes) <= MAX_PHOTO_BYTES &&
    typeof value.content_type === "string" &&
    PHOTO_TYPES.has(value.content_type);
}

/** Only immutable, verified native capture families are admitted in v1. This
 * schema is deliberately separate from gallery selection and AI provenance. */
export function nativePhotoVersionManifest(value: unknown): RecordValue {
  const fields = [
    "schema",
    "listing_id",
    "version_id",
    "family_id",
    "image_file",
    "original_file",
    "image",
    "original",
    "parent_id",
    "source_id",
    "staging_base_id",
    "staging_reference_id",
    "edit",
    "style",
    "effects",
    "disclosure",
    "provenance_id",
    "provenance_recorded",
    "created_at",
  ];
  assert(
    object(value) && keys(value, fields) &&
      Object.keys(value).length === fields.length,
    400,
    "Choose one complete saved photo version.",
  );
  assert(
    value.schema === 1 && typeof value.listing_id === "string" &&
      UUID.test(value.listing_id) &&
      typeof value.version_id === "string" &&
      VERSION_ID.test(value.version_id) &&
      typeof value.family_id === "string" && VERSION_ID.test(value.family_id) &&
      typeof value.image_file === "string" &&
      /^(?:enh|edit|orig)-[A-Za-z0-9-]{1,128}\.(?:jpg|png|webp)$/.test(
        value.image_file,
      ) &&
      typeof value.original_file === "string" &&
      /^orig-[A-Za-z0-9-]{1,128}\.jpg$/.test(value.original_file) &&
      asset(value.image) && asset(value.original),
    400,
    "Saved photo identity or upload receipt is invalid.",
  );
  assert(
    idOrNull(value.parent_id) && idOrNull(value.source_id) &&
      idOrNull(value.staging_base_id) &&
      idOrNull(value.staging_reference_id) && typeof value.edit === "string" &&
      [
        "capture",
        "capture-original",
        "declutter",
        "stage",
        "sky",
        "twilight",
        "lawn",
        "custom",
      ].includes(value.edit) &&
      (value.style === null ||
        typeof value.style === "string" && value.style.length <= 100) &&
      Array.isArray(value.effects) && value.effects.length <= 12 &&
      value.effects.every((item) =>
        typeof item === "string" && /^[a-z-]{1,32}$/.test(item)
      ) &&
      new Set(value.effects).size === value.effects.length &&
      (value.disclosure === null ||
        typeof value.disclosure === "string" &&
          value.disclosure.length <= 2000) &&
      (value.provenance_id === null ||
        typeof value.provenance_id === "string" &&
          UUID.test(value.provenance_id)) &&
      typeof value.provenance_recorded === "boolean" &&
      (!value.provenance_recorded || value.provenance_id !== null) &&
      typeof value.created_at === "string" &&
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/
        .test(value.created_at) &&
      Number.isFinite(Date.parse(value.created_at)),
    400,
    "Saved photo lineage is invalid.",
  );
  const image = value.image as RecordValue,
    original = value.original as RecordValue;
  if (value.edit === "capture") {
    assert(
      value.family_id === value.version_id && value.parent_id === null &&
        value.source_id === null &&
        image.content_type === "image/jpeg" &&
        value.staging_base_id === null && value.staging_reference_id === null &&
        value.image_file === `enh-${value.version_id}.jpg` &&
        value.original_file === `orig-${value.version_id}.jpg` &&
        (value.effects as unknown[]).length === 0 &&
        value.provenance_id === null && value.provenance_recorded === false,
      400,
      "A capture must bind its original and enhanced file as one root.",
    );
  } else if (value.edit === "capture-original") {
    assert(
      value.version_id === `${value.family_id}-original` &&
        value.image_file === value.original_file &&
        value.parent_id === null && value.source_id === null &&
        value.staging_base_id === null &&
        value.staging_reference_id === null &&
        image.asset_id === original.asset_id &&
        image.sha256 === original.sha256 && image.bytes === original.bytes &&
        image.content_type === original.content_type &&
        (value.effects as unknown[]).length === 0 &&
        value.provenance_id === null && value.provenance_recorded === false,
      400,
      "An original source must use its root's retained bytes.",
    );
  } else {
    assert(
      value.family_id !== value.version_id && value.parent_id !== null &&
        value.source_id !== null &&
        ["image/jpeg", "image/png", "image/webp"].includes(
          image.content_type as string,
        ) &&
        value.image_file ===
          `edit-${value.version_id}.${
            image.content_type === "image/png"
              ? "png"
              : image.content_type === "image/webp"
              ? "webp"
              : "jpg"
          }` &&
        (value.effects as string[]).includes(value.edit as string) &&
        (value.edit === "stage" || value.staging_reference_id === null),
      400,
      "An edited version must name its saved parent, source, and output.",
    );
  }
  // Normalize UUID casing for JSONB exact-replay equality across Swift and JS.
  return {
    ...value,
    listing_id: (value.listing_id as string).toLowerCase(),
    image: { ...image, asset_id: (image.asset_id as string).toLowerCase() },
    original: {
      ...original,
      asset_id: (original.asset_id as string).toLowerCase(),
    },
    provenance_id: value.provenance_id === null
      ? null
      : (value.provenance_id as string).toLowerCase(),
  };
}

function rpcError(error: { message?: unknown } | null | undefined): never {
  const match = /^RP(400|401|403|404|409): ([^\r\n]{1,240})$/.exec(
    String(error?.message),
  );
  throw new HttpError(
    match ? Number(match[1]) : 503,
    match
      ? match[2]
      : "Saved photo history could not be confirmed. Retry when connected.",
  );
}

export async function handleNativePhotoVersions(
  req: Request,
  context: StudioContext,
  sign: (scope: PrivateMediaScope, seconds: number) => Promise<string> =
    privateMediaUrl,
): Promise<Response | null> {
  const seg = pathSegments(req, "studio");
  if (seg[0] !== "native-photo-versions" || seg.length < 1 || seg.length > 2) {
    return null;
  }
  assert(
    req.method === "GET" || req.method === "POST",
    405,
    "Use GET or POST for saved photo versions.",
  );
  const query = new URL(req.url).searchParams;
  const selectedLibrary = req.headers.get("x-org-id") ?? query.get("org_id");
  assert(
    typeof selectedLibrary === "string" && UUID.test(selectedLibrary),
    400,
    "Choose a valid photo library.",
  );
  if (seg.length === 2) {
    assert(
      req.method === "GET" && UUID.test(seg[1]),
      400,
      "Choose one saved photo asset.",
    );
    const listing = query.get("listing_id")?.toLowerCase(),
      asset = seg[1].toLowerCase();
    assert(
      typeof listing === "string" && UUID.test(listing) &&
        !query.has("version_id") && !query.has("offset"),
      400,
      "Choose the saved asset's listing.",
    );
    await context.authorizeListing(listing);
    const args = {
      p_actor: context.userId,
      p_org: context.orgId,
      p_library: selectedLibrary.toLowerCase(),
      p_listing: listing,
      p_asset: asset,
    };
    const read = async () => {
      const { data, error } = await context.admin.rpc(
        "native_photo_backup_download",
        args,
      );
      if (error) rpcError(error);
      assert(
        object(data) && data.ok === true && data.listing_id === listing &&
          data.asset_id === asset &&
          data.bucket === "uploads" && typeof data.storage_key === "string" &&
          data.storage_key.startsWith(`uploads/${context.orgId}/${listing}/`) &&
          typeof data.sha256 === "string" && HASH.test(data.sha256) &&
          Number.isSafeInteger(data.bytes) && Number(data.bytes) >= 1 &&
          Number(data.bytes) <= MAX_PHOTO_BYTES &&
          typeof data.content_type === "string" &&
          PHOTO_TYPES.has(data.content_type),
        503,
        "Saved photo download could not be confirmed.",
      );
      return data;
    };
    const before = await read();
    const url = await sign({
      actor: context.userId,
      org: context.orgId,
      listing,
      bucket: "uploads",
      key: before.storage_key as string,
    }, 300);
    const after = await read();
    assert(
      stableJSON(before) === stableJSON(after),
      409,
      "Saved photo access changed. Retry the download.",
    );
    const { storage_key: _key, bucket: _bucket, ...publicReceipt } = after;
    return json(
      {
        ...publicReceipt,
        url,
        expires_at: new Date(Date.now() + 300_000).toISOString(),
      },
      200,
      { "Cache-Control": "private, no-store" },
    );
  }
  if (req.method === "POST") {
    const manifest = nativePhotoVersionManifest(
      await readJsonLimited(req, 8192),
    );
    const listing = manifest.listing_id as string;
    assert(
      !query.has("listing_id") ||
        query.get("listing_id")?.toLowerCase() === listing,
      400,
      "Listing selectors disagree.",
    );
    await context.authorizeListing(listing);
    const { data, error } = await context.admin.rpc(
      "native_photo_backup_commit",
      {
        p_actor: context.userId,
        p_org: context.orgId,
        p_library: selectedLibrary.toLowerCase(),
        p_listing: listing,
        p_manifest: manifest,
      },
    );
    if (error) rpcError(error);
    assert(
      object(data) && data.ok === true && data.listing_id === listing &&
        data.version_id === manifest.version_id &&
        data.family_id === manifest.family_id &&
        data.manifest !== undefined &&
        stableJSON(data.manifest) === stableJSON(manifest) &&
        typeof data.replayed === "boolean" && data.available === true &&
        typeof data.committed_at === "string",
      503,
      "Saved photo confirmation was incomplete.",
    );
    return json(data, 200, { "Cache-Control": "private, no-store" });
  }
  const listing = query.get("listing_id")?.toLowerCase();
  assert(
    typeof listing === "string" && UUID.test(listing),
    400,
    "Choose a valid listing.",
  );
  const version = query.get("version_id");
  assert(
    version === null || VERSION_ID.test(version),
    400,
    "Choose a valid saved version.",
  );
  const offsetRaw = query.get("offset") ?? "0";
  assert(
    /^(0|[1-9]\d{0,4})$/.test(offsetRaw) && Number(offsetRaw) <= 10000 &&
      Number(offsetRaw) % 50 === 0 &&
      (version === null || Number(offsetRaw) === 0),
    400,
    "Choose a valid saved photo page.",
  );
  await context.authorizeListing(listing);
  const { data, error } = await context.admin.rpc("native_photo_backup_read", {
    p_actor: context.userId,
    p_org: context.orgId,
    p_library: selectedLibrary.toLowerCase(),
    p_listing: listing,
    p_version: version,
    p_offset: Number(offsetRaw),
  });
  if (error) rpcError(error);
  assert(
    object(data) && data.ok === true && data.listing_id === listing &&
      Array.isArray(data.versions) && data.versions.length <= 50 &&
      data.versions.every((row: unknown) =>
        object(row) && row.listing_id === listing &&
        typeof row.version_id === "string" && VERSION_ID.test(row.version_id) &&
        typeof row.available === "boolean"
      ) &&
      (data.next_offset === null || Number.isInteger(data.next_offset) &&
          data.next_offset === Number(offsetRaw) + 50),
    503,
    "Saved photo history could not be read.",
  );
  return json(data, 200, { "Cache-Control": "private, no-store" });
}
