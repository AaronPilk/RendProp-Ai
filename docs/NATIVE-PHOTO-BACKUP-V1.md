# Private native Photo Studio backup v1

The backup acknowledgement is a completed **private** upload receipt for each
saved image plus an immutable, server-committed version manifest. A photo in the
listing gallery, an AI provenance row, or an upload completion response alone is
not a native history backup. This contract covers newly captured/imported
families whose local `originalVerified` and `sourceHistoryKnown` flags are true.
Legacy/cloud families with an unverified or absent original are excluded and
must remain visibly unbacked up until a separate migration proves their source.

All requests use the signed-in Supabase access token, `X-Org-Id` set to the
**selected logical library UUID**, and the existing Studio function base URL.
The server resolves the physical content org, checks current listing access,
and accepts only private `uploads` bucket assets for that same physical org and
listing. A successful POST never selects a gallery photo or publishes it.

## Upload prerequisites

Upload the exact immutable local file bytes using `/uploads` with `kind=photo`,
`role=capture`, and the real MIME type detected from the bytes. Supported MIME
types are JPEG, PNG, WebP, HEIC, and HEIF; each file is at most 50 MiB. Native
`orig-<family>.jpg` is a local legacy filename and may contain HEIC bytes. Use
`.heic` in the upload ticket when the bytes are HEIC; the manifest still records
the local `orig-<family>.jpg` name. Hash the bytes actually transferred, and
recheck the source file before accepting the upload completion. The manifest
receipt is `{asset_id,sha256,bytes,content_type}` with lowercase SHA-256 hex.
The SQL commit requires the completed reservation, exact metadata, private
storage key, and retained R2 transfer receipt. The new image upload must belong
to the committing actor; a retained original may belong to a prior member of
the same listing.

The upload service checks object length, type, and ETag on R2. Its SHA-256 is
currently supplied by the client; v1 acknowledges durable server receipt and
lineage, **not** a server-side cryptographic readback of every byte.

## POST `/studio/native-photo-versions`

Send one full JSON object, all nullable fields explicitly present:

```json
{
  "schema": 1,
  "listing_id": "40000000-0000-4000-8000-000000000004",
  "version_id": "175000000000000-50000000-0000-4000-8000-000000000005",
  "family_id": "175000000000000-50000000-0000-4000-8000-000000000005",
  "image_file": "enh-175000000000000-50000000-0000-4000-8000-000000000005.jpg",
  "original_file": "orig-175000000000000-50000000-0000-4000-8000-000000000005.jpg",
  "image": {"asset_id":"70000000-0000-4000-8000-000000000007","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","bytes":200,"content_type":"image/jpeg"},
  "original": {"asset_id":"60000000-0000-4000-8000-000000000006","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bytes":100,"content_type":"image/heic"},
  "parent_id": null,
  "source_id": null,
  "staging_base_id": null,
  "staging_reference_id": null,
  "edit": "capture",
  "style": null,
  "effects": [],
  "disclosure": null,
  "provenance_id": null,
  "provenance_recorded": false,
  "created_at": "2026-11-04T20:00:00Z"
}
```

Commit order is the dependency order of the saved local graph:

1. Synthetic retained source: `version_id=<family>-original`, `edit=capture-original`,
   `image=original`, and `image_file=original_file=orig-<family>.jpg`; graph refs
   null, effects empty.
2. Root enhanced capture: `version_id=family_id`, `edit=capture`, enhanced
   `image` receipt, same original receipt, `image_file=enh-<family>.jpg`;
   graph refs null, effects empty.
3. Each AI edit: `version_id=<saved edit id>`, `edit` matching local history,
   `image_file=edit-<id>.(jpg|png|webp)`, its exact output receipt, the same
   family original receipt, and existing `parent_id`/`source_id`. `effects`
   includes the edit. `staging_base_id` if present refers to a version in the
   same family. `staging_reference_id` if present refers to a previously
   committed staged version in the same listing; it may be another family.

`edit` is one of `capture`, `capture-original`, `declutter`, `stage`, `sky`,
`twilight`, `lawn`, or `custom`. `style`, `disclosure`, and `provenance_id` may be
null. Keep the saved `created_at`; do not regenerate it for retries. Review
flags such as staging/custom approval are mutable local state and this manifest
does not certify publication approval.

`(listing_id,version_id)` is the idempotency identity. An exact replay of the
canonical JSON manifest returns HTTP 200 with `replayed:true`; a different
manifest for that identity returns HTTP 409. A successful response has:

```json
{"ok":true,"listing_id":"<uuid>","version_id":"<id>","family_id":"<id>","manifest":{},"replayed":false,"available":true,"committed_at":"<server timestamp>"}
```

`manifest` is the full canonical submitted object, with UUIDs lowercased. A
client may say this version is backed up only after HTTP 200, exact identity
and manifest match, and `available:true`. A timeout or ambiguous response is
not an acknowledgement.

## GET `/studio/native-photo-versions?listing_id=<uuid>&offset=0`

Pages contain up to 50 rows in committed order, with offsets `0,50,...,10000`:

```json
{"ok":true,"listing_id":"<uuid>","versions":[{"listing_id":"<uuid>","version_id":"<id>","family_id":"<id>","manifest":{},"available":true,"committed_at":"<server timestamp>"}],"next_offset":null}
```

`next_offset` is the next integer page when more rows exist. Add
`&version_id=<id>` with offset 0 to probe an exact version after a lost POST
reply; an absent version returns an empty `versions` array. `available` checks
both stored asset receipts on each read. Clients must reconcile by
`(listing_id,version_id)` when pages can change as new versions arrive.

## GET `/studio/native-photo-versions/<asset_id>?listing_id=<uuid>`

Request a fresh private download capability for one `image.asset_id` or
`original.asset_id` returned by a committed manifest. The server verifies the
same signed-in actor, physical org, selected logical library, listing, exact
completed asset receipt, and current media visibility. It rechecks those after
signing. A guessed UUID from another listing or an asset without a committed
manifest returns 404. Success returns:

```json
{"ok":true,"listing_id":"<uuid>","asset_id":"<uuid>","sha256":"<lowercase hex>","bytes":100,"content_type":"image/heic","url":"<expiring private URL>","expires_at":"<server timestamp>"}
```

The URL expires in 300 seconds, uses the existing private-media gateway when
active, and never exposes a raw storage key. Download and verify the exact
byte count and SHA-256 before rebuilding local history. The backend provides
the restore transport; the native client is responsible for safe file writes,
graph reconstruction, and review-state handling after reinstall.

Deploy the migration before the Studio function, then enable the native client.
Until both server components are deployed, no native UI should claim this
server-acknowledged history backup or working restore. This branch has no
production deployment.
