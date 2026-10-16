import { assert, HttpError, throwRpc } from "../_shared/http.ts";
import { propertyGalleryKey } from "../_shared/property-cover.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Row = Record<string, unknown>;
type Scope = { orgId: string; libraryOrgId: string; listingId: string };
type Authority = {
  rpc(
    name: string,
    args: Row,
  ): PromiseLike<
    { data: unknown; error: { code?: string; message?: string } | null }
  >;
};
function object(value: unknown): value is Row {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
function exact(value: unknown, keys: string[]): value is Row {
  return object(value) && Object.keys(value).length === keys.length &&
    keys.every((k) => Object.hasOwn(value, k));
}
function ids(value: unknown, nullable = false): string[] | null {
  if (nullable && value === null) return null;
  assert(
    Array.isArray(value) && value.length <= 100 &&
      value.every((x) => typeof x === "string" && UUID.test(x)),
    400,
    "Keep the exact bounded photo identities.",
  );
  const result = value.map((x) => (x as string).toLowerCase());
  assert(
    new Set(result).size === result.length,
    400,
    "Choose each photo once.",
  );
  return result;
}
function request(value: unknown): Row {
  assert(
    exact(value, [
      "family_asset_ids",
      "target",
      "expected_selection",
      "follow_family_cover",
      "reviewed",
    ]),
    400,
    "Send only the saved family photo choice.",
  );
  const family = ids(value.family_asset_ids)!;
  assert(
    family.length > 0 && typeof value.follow_family_cover === "boolean" &&
      typeof value.reviewed === "boolean",
    400,
    "Keep the exact family and review intent.",
  );
  assert(
    exact(value.expected_selection, ["gallery_asset_ids", "main_photo_key"]),
    400,
    "Keep the complete raw selection snapshot.",
  );
  const expected = ids(value.expected_selection.gallery_asset_ids, true),
    cover = value.expected_selection.main_photo_key;
  assert(
    cover === null ||
      typeof cover === "string" && cover.length > 0 && cover.length <= 500,
    400,
    "Keep the current cover snapshot.",
  );
  let target: Row | null = null;
  if (value.target !== null) {
    assert(
      exact(value.target, ["asset_id", "sha256", "bytes"]) &&
        typeof value.target.asset_id === "string" &&
        UUID.test(value.target.asset_id) &&
        typeof value.target.sha256 === "string" &&
        /^[a-f0-9]{64}$/.test(value.target.sha256) &&
        Number.isSafeInteger(value.target.bytes) &&
        Number(value.target.bytes) > 0 &&
        Number(value.target.bytes) <= 134217728,
      400,
      "Choose one exact prepared photo.",
    );
    target = {
      asset_id: (value.target.asset_id as string).toLowerCase(),
      sha256: value.target.sha256,
      bytes: value.target.bytes,
    };
    assert(
      family.includes(target.asset_id as string),
      400,
      "The prepared target must belong to the captured family footprint.",
    );
  } else {assert(
      value.follow_family_cover === false && value.reviewed === false,
      400,
      "Removing exposure does not approve an edit or choose a cover.",
    );}
  return {
    family_asset_ids: family,
    target,
    expected_selection: { gallery_asset_ids: expected, main_photo_key: cover },
    follow_family_cover: value.follow_family_cover,
    reviewed: value.reviewed,
  };
}
function checkedSnapshot(value: unknown, scope: Scope, actor: string): Row {
  assert(
    object(value) && value.schema === 1 && value.actor_id === actor &&
      value.org_id === scope.orgId &&
      value.library_org_id === scope.libraryOrgId &&
      value.listing_id === scope.listingId,
    503,
    "The saved selection returned another identity.",
  );
  // Decode trusted output without turning malformed upstream data into a client400.
  try {
    const gallery = ids(value.gallery_asset_ids, true),
      effective = ids(value.effective_asset_ids)!;
    assert(
      value.main_photo_key === null ||
        typeof value.main_photo_key === "string" &&
          value.main_photo_key.length <= 500,
      400,
      "cover",
    );
    assert(
      gallery === null || effective.every((id) => gallery.includes(id)),
      400,
      "membership",
    );
    assert(
      Array.isArray(value.gallery_assets) && value.gallery_assets.length <= 100,
      400,
      "assets",
    );
    const seen = new Set<string>();
    for (const raw of value.gallery_assets) {
      assert(
        exact(raw, ["asset_id", "sha256", "bytes", "storage_key"]) &&
          typeof raw.asset_id === "string" && UUID.test(raw.asset_id) &&
          !seen.has(raw.asset_id) && effective.includes(raw.asset_id) &&
          typeof raw.sha256 === "string" && /^[a-f0-9]{64}$/.test(raw.sha256) &&
          Number.isSafeInteger(raw.bytes) && Number(raw.bytes) > 0 &&
          Number(raw.bytes) <= 134217728 &&
          propertyGalleryKey(raw.storage_key, scope),
        400,
        "asset identity",
      );
      seen.add(raw.asset_id as string);
    }
    assert(Object.hasOwn(value, "operation"), 400, "receipt");
    if (value.operation !== null) {
      assert(
        exact(value.operation, ["operation_id", "request", "result"]) &&
          typeof value.operation.operation_id === "string" &&
          UUID.test(value.operation.operation_id),
        400,
        "receipt identity",
      );
      const accepted = request(value.operation.request);
      assert(
        exact(value.operation.result, ["gallery_asset_ids", "main_photo_key"]),
        400,
        "receipt result",
      );
      const resultIds = ids(value.operation.result.gallery_asset_ids)!;
      const family = accepted.family_asset_ids as string[];
      const target = accepted.target as Row | null;
      const chosen = target?.asset_id as string | undefined;
      assert(
        resultIds.filter((id) => family.includes(id)).length ===
            (chosen ? 1 : 0) &&
          (chosen === undefined || resultIds.includes(chosen)),
        400,
        "receipt family effect",
      );
      const expected = accepted.expected_selection as Row;
      if (expected.gallery_asset_ids !== null) {
        const ordered: string[] = [];
        let inserted = false;
        for (const id of expected.gallery_asset_ids as string[]) {
          if (family.includes(id)) {
            if (chosen && !inserted) {
              ordered.push(chosen);
              inserted = true;
            }
          } else ordered.push(id);
        }
        if (chosen && !inserted) ordered.push(chosen);
        assert(
          JSON.stringify(resultIds) === JSON.stringify(ordered),
          400,
          "receipt ordered effect",
        );
      }
      const cover = value.operation.result.main_photo_key;
      assert(
        cover === null ||
          typeof cover === "string" && cover.length > 0 && cover.length <= 500,
        400,
        "receipt cover",
      );
      if (!accepted.follow_family_cover) {
        assert(
          chosen
            ? cover === expected.main_photo_key
            : cover === null || cover === expected.main_photo_key,
          400,
          "receipt preserved cover",
        );
      }
    }
  } catch {
    throw new HttpError(
      503,
      "The saved photo selection could not be verified. Keep this operation and refresh.",
    );
  }
  return value;
}
async function call(
  admin: Authority,
  name: string,
  args: Row,
): Promise<unknown> {
  const { data, error } = await admin.rpc(name, args);
  if (error) {
    if (error.code === "PT409") {
      throw new HttpError(
        409,
        "The listing photos changed elsewhere. Refresh before choosing again.",
        "gallery_selection_changed",
      );
    }
    if (typeof error.message === "string" && /RP\d{3}:/.test(error.message)) {
      throwRpc(error.message);
    }
    throw new HttpError(
      503,
      "This photo choice could not be confirmed. Keep the same saved operation and refresh.",
    );
  }
  return data;
}
export async function readPhotoSelection(
  admin: Authority,
  scope: Scope,
  actor: string,
  operation: string | null,
): Promise<Row> {
  assert(
    operation === null || UUID.test(operation),
    400,
    "Keep a valid photo operation identity.",
  );
  const value = checkedSnapshot(
    await call(admin, "native_gallery_selection_snapshot", {
      p_actor: actor,
      p_org: scope.orgId,
      p_library: scope.libraryOrgId,
      p_listing: scope.listingId,
      p_operation: operation?.toLowerCase() ?? null,
    }),
    scope,
    actor,
  );
  if (operation !== null && value.operation !== null) {
    assert(
      object(value.operation) &&
        value.operation.operation_id === operation.toLowerCase(),
      503,
      "This receipt belongs to another operation.",
    );
  }
  return value;
}
export async function changePhotoSelection(
  admin: Authority,
  scope: Scope,
  actor: string,
  body: Row,
  key: string | null,
): Promise<Row> {
  assert(
    exact(body, [
      "operation_id",
      "family_asset_ids",
      "target",
      "expected_selection",
      "follow_family_cover",
      "reviewed",
    ]) && typeof body.operation_id === "string" && UUID.test(body.operation_id),
    400,
    "Send the saved photo operation only.",
  );
  const operation = body.operation_id.toLowerCase();
  assert(
    key?.toLowerCase() === `photo-selection:${operation}`,
    409,
    "Keep the same saved photo operation identity.",
  );
  const { operation_id: _, ...raw } = body;
  const intent = request(raw);
  const value = checkedSnapshot(
    await call(admin, "native_gallery_selection_change", {
      p_actor: actor,
      p_org: scope.orgId,
      p_library: scope.libraryOrgId,
      p_listing: scope.listingId,
      p_operation: operation,
      p_request: intent,
    }),
    scope,
    actor,
  );
  assert(
    value.ok === true && typeof value.replayed === "boolean" &&
      object(value.operation) && value.operation.operation_id === operation,
    503,
    "The saved photo operation could not be confirmed.",
  );
  let acknowledged: Row;
  try {
    acknowledged = request(value.operation.request);
  } catch {
    throw new HttpError(503, "The saved photo intent could not be confirmed.");
  }
  assert(
    JSON.stringify(acknowledged) === JSON.stringify(intent) &&
      exact(value.operation.result, ["gallery_asset_ids", "main_photo_key"]),
    503,
    "This reply does not match the saved photo intent.",
  );
  return value;
}
