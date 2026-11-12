import {
  assertEquals,
  assertRejects,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
import {
  handleNativePhotoVersions,
  nativePhotoVersionManifest,
} from "./native-photo-versions.ts";

const actor = "10000000-0000-4000-8000-000000000001";
const org = "20000000-0000-4000-8000-000000000002";
const library = "30000000-0000-4000-8000-000000000003";
const listing = "40000000-0000-4000-8000-000000000004";
const family = "175000000000000-50000000-0000-4000-8000-000000000005";
const originalAsset = "60000000-0000-4000-8000-000000000006";
const enhancedAsset = "70000000-0000-4000-8000-000000000007";
const receipt = (asset_id: string) => ({
  asset_id,
  sha256: "a".repeat(64),
  bytes: 137,
  content_type: "image/jpeg",
});
const base = () => ({
  schema: 1,
  listing_id: listing,
  version_id: family,
  family_id: family,
  image_file: `enh-${family}.jpg`,
  original_file: `orig-${family}.jpg`,
  image: receipt(enhancedAsset),
  original: receipt(originalAsset),
  parent_id: null,
  source_id: null,
  staging_base_id: null,
  staging_reference_id: null,
  edit: "capture",
  style: null,
  effects: [],
  disclosure: null,
  provenance_id: null,
  provenance_recorded: false,
  created_at: "2026-11-04T19:00:00.123Z",
});
const route = `https://edge.invalid/functions/v1/studio/native-photo-versions`;
function fixture(response: unknown, error: string | null = null) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const checked: string[] = [];
  const context = {
    userId: actor,
    orgId: org,
    authorizeListing(id: string) {
      checked.push(id);
      return Promise.resolve();
    },
    admin: {
      rpc(name: string, args: Record<string, unknown>) {
        calls.push({ name, args });
        return Promise.resolve({
          data: response,
          error: error ? { message: error } : null,
        });
      },
    },
  } as unknown as StudioContext;
  return { context, calls, checked };
}
function post(body: unknown, selected = library) {
  return new Request(route, {
    method: "POST",
    headers: { "x-org-id": selected },
    body: JSON.stringify(body),
  });
}
function get(query: string, selected = library) {
  return new Request(`${route}?${query}`, {
    headers: { "x-org-id": selected },
  });
}

Deno.test("capture commit binds logical library, physical org and immutable exact manifest", async () => {
  const manifest = base();
  const response = {
    ok: true,
    listing_id: listing,
    version_id: family,
    family_id: family,
    manifest: Object.fromEntries(Object.entries(manifest).reverse()),
    replayed: false,
    available: true,
    committed_at: "2026-11-04T19:01:00Z",
  };
  const f = fixture(response);
  const reply = await handleNativePhotoVersions(post(manifest), f.context);
  assertEquals(reply?.status, 200);
  assertEquals(reply?.headers.get("cache-control"), "private, no-store");
  assertEquals(f.checked, [listing]);
  assertEquals(f.calls, [{
    name: "native_photo_backup_commit",
    args: {
      p_actor: actor,
      p_org: org,
      p_library: library,
      p_listing: listing,
      p_manifest: manifest,
    },
  }]);
});

Deno.test("lineage parser rejects substitutions, guessed assets and omitted nullable fields", () => {
  const valid = base();
  const patches = [
    { ...valid, original: { ...valid.original, sha256: "A".repeat(64) } },
    { ...valid, image: { ...valid.image, storage_key: "uploads/injected" } },
    { ...valid, listing_id: "not-a-uuid" },
    { ...valid, parent_id: "foreign" },
    { ...valid, effects: ["stage"] },
    { ...valid, original_file: "orig-other.jpg" },
    { ...valid, provenance_recorded: true },
    { ...valid, created_at: "yesterday" },
  ];
  for (const patch of patches) {
    assertThrows(() => nativePhotoVersionManifest(patch), HttpError);
  }
  const omitted = { ...valid } as Record<string, unknown>;
  delete omitted.staging_reference_id;
  assertThrows(() => nativePhotoVersionManifest(omitted), HttpError);
  const source = {
    ...valid,
    edit: "capture-original",
    version_id: `${family}-original`,
    image_file: `orig-${family}.jpg`,
    image: valid.original,
  };
  assertEquals(nativePhotoVersionManifest(source), source);
  assertThrows(
    () => nativePhotoVersionManifest({ ...source, image: valid.image }),
    HttpError,
  );
});

Deno.test("GET page and exact lost-reply probe forward only bounded listing scope", async () => {
  const row = {
    listing_id: listing,
    version_id: family,
    family_id: family,
    manifest: base(),
    available: true,
    committed_at: "2026-11-04T19:01:00Z",
  };
  const f = fixture({
    ok: true,
    listing_id: listing,
    versions: [row],
    next_offset: null,
  });
  assertEquals(
    (await handleNativePhotoVersions(
      get(`listing_id=${listing}&version_id=${family}`),
      f.context,
    ))?.status,
    200,
  );
  assertEquals(f.calls[0], {
    name: "native_photo_backup_read",
    args: {
      p_actor: actor,
      p_org: org,
      p_library: library,
      p_listing: listing,
      p_version: family,
      p_offset: 0,
    },
  });
  const bad = fixture(null);
  for (
    const q of [
      `listing_id=${listing}&offset=1`,
      `listing_id=${listing}&offset=10050`,
      `listing_id=${listing}&version_id=${family}&offset=50`,
      `listing_id=not-uuid`,
    ]
  ) {
    await assertRejects(
      () => handleNativePhotoVersions(get(q), bad.context),
      HttpError,
    );
  }
  assertEquals(bad.calls.length, 0);
});

Deno.test("unconfirmed response, conflict and unknown SQL errors never claim backup", async () => {
  const manifest = base();
  for (
    const response of [null, {
      ok: true,
      listing_id: listing,
      version_id: family,
      family_id: family,
      manifest,
      replayed: false,
      available: false,
      committed_at: "now",
    }]
  ) {
    const f = fixture(response);
    const error = await assertRejects(
      () => handleNativePhotoVersions(post(manifest), f.context),
      HttpError,
    );
    assertEquals(error.status, 503);
  }
  for (
    const [message, status] of [["RP409: The saved version changed", 409], [
      "private postgres detail",
      503,
    ]] as const
  ) {
    const f = fixture(null, message);
    const error = await assertRejects(
      () => handleNativePhotoVersions(post(manifest), f.context),
      HttpError,
    );
    assertEquals(error.status, status);
  }
});

Deno.test("restore URL is minted only for committed scoped asset and is rechecked after signing", async () => {
  const key = `uploads/${org}/${listing}/${originalAsset}.heic`;
  const f = fixture({
    ok: true,
    listing_id: listing,
    asset_id: originalAsset,
    sha256: "a".repeat(64),
    bytes: 137,
    content_type: "image/heic",
    bucket: "uploads",
    storage_key: key,
  });
  const scopes: unknown[] = [];
  const response = await handleNativePhotoVersions(
    new Request(`${route}/${originalAsset}?listing_id=${listing}`, {
      headers: { "x-org-id": library },
    }),
    f.context,
    (scope, seconds) => {
      scopes.push({ scope, seconds });
      return Promise.resolve("https://private.invalid/expiring");
    },
  );
  assertEquals(response?.status, 200);
  const body = await response?.json();
  assertEquals(body.asset_id, originalAsset);
  assertEquals(body.url, "https://private.invalid/expiring");
  assertEquals(body.storage_key, undefined);
  assertEquals(scopes, [{
    scope: { actor, org, listing, bucket: "uploads", key },
    seconds: 300,
  }]);
  assertEquals(
    f.calls.filter((c) => c.name === "native_photo_backup_download").length,
    2,
  );
});

Deno.test("restore refuses foreign scope and missing manifest before URL signing", async () => {
  let signs = 0;
  const request = new Request(
    `${route}/${originalAsset}?listing_id=${listing}`,
    { headers: { "x-org-id": library } },
  );
  for (
    const message of [
      "RP404: Saved photo asset is unavailable",
      "RP404: This property is no longer in the selected library",
    ]
  ) {
    const f = fixture(null, message);
    const error = await assertRejects(
      () =>
        handleNativePhotoVersions(request.clone(), f.context, () => {
          signs++;
          return Promise.resolve("unexpected");
        }),
      HttpError,
    );
    assertEquals(error.status, 404);
    assertEquals(f.calls.length, 1);
  }
  const foreign = fixture({
    ok: true,
    listing_id: listing,
    asset_id: originalAsset,
    sha256: "a".repeat(64),
    bytes: 137,
    content_type: "image/heic",
    bucket: "uploads",
    storage_key: `uploads/${org}/${actor}/${originalAsset}.heic`,
  });
  await assertRejects(
    () =>
      handleNativePhotoVersions(request.clone(), foreign.context, () => {
        signs++;
        return Promise.resolve("unexpected");
      }),
    HttpError,
  );
  assertEquals(signs, 0);
});
