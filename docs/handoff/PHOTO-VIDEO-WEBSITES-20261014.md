# Photo videos, property designs and automatic scene planning

Local integration on `feature/photo-video-sites-20261014`. No production migration,
function deployment, Apple change, SKU activation or purchase was performed by
this backend lane. App Store74 is outside this change.

## Wire and authority

- Photo publication uses `presentation_kind: photo_video`, schema1 listing/16:9
  composition, `branding_policy: unbranded`, up to100 source receipts,
  registered output asset and distinct uploaded first-clip poster.
- `publication_id` UUID and `Idempotency-Key: photo-video:<same lowercase UUID>`
  identify one durable selection operation. Success echoes operation, output,
  listing, physical `org_id` and selected `library_org_id`. Immutable output,
  poster and manifest survive explicit A→B→A reselection; new selections use
  fresh operations. A superseded lost-reply retry returns409 with only the
  specific `publication_superseded` code; it does not change the newer choice.
- Actual retained MP4 metadata must be16:9, at least1920×1080, at most8K/600s.
  The existing trial duration gate still runs. Container/SPS geometry checks
  are metadata evidence, not independent decoded-video sharpness certification.
- AI sources bind accepted paid request/provenance to exact owned prepared JPEG
  bytes, a full byte SHA256 and the existing32-character QC lineage hash. AI
  publication requires the exact passing QC ledger and completed QC journal.
  Original-photo movement needs its own owned source and any known source edit
  provenance, but no successful generation receipt. Client `source_bound` is
  not server authority.
- Known source photo provenance is checked for the same listing/org, current QC
  and source-key privacy. Native selected-version metadata is retained; a
  resized JPEG's equivalence to its edited master is not independently proven
  by server pixel comparison. Neither prompts nor these tests certify geometry.
- App-added unbranded composition policy is persisted and checked by `/u`.
  Tests verify the native compositor policy separately; the server does not
  perform OCR or independent certification of every uploaded pixel.
- Public projection is additive `listing_video` with exact video/first-clip
  poster URLs, dimensions/duration/disclosure/branding policy and typed
  `website_theme`. Raw `details.reel_url` and customer theme flags are not
  authority. Selected output/source/poster privacy is checked freshly, including
  before byte delivery. Photo-only anchors do not authorize stale anchor media.
- Existing recorded walkthroughs, chapters and slugs remain separate. Recorded
  publishing delegates to existing RPCs through `publish_recorded_render` and
  never changes selected photo composition. Known photo-master outputs cannot
  be relabeled captured footage through that older route.

## Property design purchase

SKU `com.rendprop.app.website.premium.property` is one consumable credit per
property, unlocking either Signature Estate or Coastal Luxe; switching themes
needs no second credit. The owner's intended price is$20; native uses the
actual localized StoreKit product price. Basic stays included and plan/grace
hosting rules still apply.

`GET /property-sites/:listing`, `PATCH` with `website_theme/expected_org_id`,
and `POST /upgrade` with a signed Apple transaction use the existing pinned
Apple verifier and fresh private-library authority. Transactions must be
Consumable/PURCHASED/quantity1, correct bundle/SKU and appAccountToken. A durable
assignment never moves to another property/account. Another paid credit arriving
for an already-upgraded property is retained unassigned. Notification refunds
work without a phone sidecar; stale restore/ONE_TIME_CHARGE cannot undo them,
and only a newer signed refund reversal reactivates the original credit.
Outer notification chronology is independent of freshly re-signed transactions.
`receipt_grants_upgrade` distinguishes the exact transaction's grant from a
property that remains unlocked by a separate newer valid credit.

**Both Production and Sandbox purchase flags default false.** No SKU activation
is part of this lane. Sandbox credits are test-only and cannot upgrade the live
Production site. Previews do not need a purchase and never persist theme, accept
buyer forms, emit beacons or claim indexing eligibility.

## Automatic selected-photo plan

New `POST /property-video-plan`:

```json
{"listing_id":"UUID","expected_org_id":"UUID","photos":[{"photo_id":"opaque local ID","asset_id":"owned private JPEG UUID"}]}
```

Requires saved Idempotency-Key and
`x-rendprop-ai-consent: property-video-plan-v1`, sent only while native AI consent
is granted/current. It plans1–20 selected photos per batch, never account-wide.
Native batches all100, then caches/freezes the final order and per-photo motion
before generation. Optional native recipe `automaticOrder` survives Studio sync.

The actual gpt-5.6-terra Responses request contains only owned signed low-detail
photo URLs and opaque numbered indexes; no supplied URL, local filename,
address, user identity or client room claim reaches it. Strict closed schema
returns every index once. Server echoes exact local IDs/assets in input order,
closed room/motion enums, confidence0–1 and fixed5s. Unknown/confidence≤.6 uses
existing restrained `push_in`; no unsupported static preset or hidden retry.
Fresh account/listing/upload/HEAD/privacy fences run before supplier and after
reply. Completed durable replay makes no second supplier call. Invalid/partial
plans fail truthfully, allowing native's disclosed selected-order fallback.

Official model rates are$2/M input and$12/M output. A complete conservative hold
uses2048input tokens per low-detail image plus prompt/schema bytes, and a2000
output-token cap. Successful provider-reported usage is recorded as a standard
rate **estimate**, not invoice reconciliation. If a completed response lacks
usage, the bounded attempt estimate is used; HTTP401 does not invent a bill.
Provider status/latency is reported through existing health accounting.

Official sources read2026-10-14:
- https://developers.openai.com/api/docs/models/gpt-5.6-terra
- https://developers.openai.com/api/docs/guides/images-vision
- https://developers.openai.com/api/docs/guides/structured-outputs

## Verification and deployment handoff

Migration created by Supabase CLI:
`20261014162938_property_video_websites.sql`. Every new table has RLS and no direct
anon/authenticated write grant; service/authenticated RPC authority is explicit.
Migration replay is idempotent and requires no anchor/bootstrap exception.

`services/supabase/tests/property_video_websites_pg.py` owns a disposable socket-
only PostgreSQL cluster and applies the real schema.54 assertions include first
photo-only publication, preserved recorded secondary, passing AI/QC lineage,
refunded/unassigned credits and guarded disclosure. Five concurrent scenarios
include one transaction/two properties, two transactions/one property with the
second credit retained, selection/retry/reselection, and lock-removal negative
controls. The controls pause at the actual empty-slot observation.

Closed Deno tests cover actual handlers, bounded AVC metadata/retained bytes,
first-clip posters, exact operation acknowledgment/superseded code, private
source substitution, notification verification/routes, original-photo fallback,
public-byte freshness and unchanged subscription fingerprints. Automatic planner
also has five compiled actual-route fault controls. Studio's optional Boolean
has11 focused recipe tests and full typecheck. These do not replace real phone
visual/model acceptance.

Evidence is under the private workspace
`_bridge/photo-video-websites-backend/`; final source binding is `receipt.json`.
The PG receipt is `pg-final-authority/receipt.json`; earlier failed fixture/
control attempts remain as diagnostic evidence and are not acceptance receipts.

Root deploys only after reviewing the integrated source/gates: migration, changed
`ai-video`, `renders`, `tours`, `apple-subscriptions`, and new `property-sites` /
`property-video-plan`. Nothing in this document activates the premium product or
promotes unmeasured video-provider quality. Root's ordinary-account1080p quality
benchmarks and real staged-photo→video→publish phone acceptance remain required.
