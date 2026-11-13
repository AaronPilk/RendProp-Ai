# Native and Studio authority and recovery

The native iPhone app and Studio remain separate clients of the shared backend. The selected screen, a cached object, a local download or a preview does not grant server authority. This map documents the existing implementation; it does not introduce a PWA migration.

| Data | Authority | Client and recovery boundary |
|---|---|---|
| Account, workspace and listing | Authenticated actor, current server membership and exact logical-library to physical-organization mapping | Both clients retain the opening identity around asynchronous work. An account switch cannot inherit another actor's pending operation. |
| Saved listing facts | Server listing and sparse expected-value comparisons in `save_listing_facts` | Both clients submit changed fields and their captured expected values. A conflicting same-field write refuses with409; disjoint edits preserve unrelated fields. Native persists intent and acknowledges only submitted values. Studio keeps dirty fields in memory and prompts for review; it does not promise durable offline drafts after relaunch. |
| Photo bytes and provenance | Server assets, upload reservation/completion and verified provenance | Native local version history remains local until an exact scoped cloud mapping exists. A matching digest alone does not establish the whole version family or public selection. Originals and saved edits survive selection changes. |
| Public photo selection, order and cover | Raw server gallery IDs, cover key, sort positions and locked compare-and-set operations | `NULL` and an explicit empty selection differ. Native saves its exact-family intent before one mutation; uncertain replies reconcile through current state and the immutable receipt. Studio sends one action and uses a fresh read to confirm the exact desired effect without replaying the mutation. A fresh read does not prove which request caused the effect. Reordering never adds unselected photos. |
| Paid video operation and status | Server operation ID, immutable source manifest, consent, route, attempts and worker lease | Both clients persist scoped identity before submission. An uncertain submission is read by operation ID. An empty result without a matching durable closure remains unknown. Abandonment serializes with admission; accepted jobs recover through status/cancel. Unknown processor permission blocks further paid work while allowing status and cancellation. No blind paid replay or universal exactly-once claim. |
| Public website/video | Explicit server publication identity, selected verified presentation and entitlement | Private completed videos and design previews do not publish themselves. Retry keeps the same publication identity; a newer definitive publication supersedes an older intent. |
| Website upgrade | Server entitlement derived from verified Apple transaction, account, property and environment | Native records the original property and acknowledges with the server before finishing the transaction. A preview cannot mint entitlement; one purchase cannot unlock a second property. Genuine Sandbox purchase/recovery remains a separate acceptance gate. |
| Costs and usage | Server reservation, allowance, ledger and attempt receipts | Credits, holds, estimates and actual booked usage remain separate. Clients cannot invent provider acceptance or allowance. Supplier invoices and historical/shared-account reconciliation remain separate evidence. |

Read retries are deliberately narrower than paid mutation retries. Studio may refresh authentication and retry a GET once; it does not automatically replay a mutation after auth recovery. Native foreground video polling uses six-second status reads and pauses after a transport error with a visible recovery action. Neither policy authorizes a fresh supplier purchase.

## Evidence and its limits

The source map covers nine domains,65 bindings and the existing SQL, Edge, extracted Swift, transport and component regressions. Its retained receipt is `/Volumes/Rendprop Files/Builds/Active/build88-shared-contract-and-recovery-map/SHARED-CONTRACT-AND-RECOVERY-MAP.json` (SHA-256 `5f97085410865dfce3b6de0efa4175cc02765978eafb366b50660b36b7a88971`). It was a read-only inventory, not a new test run.

Relevant checks passed in CI run38990359799 at `c4fee13302f28110a044132b0eb5ef7211161f6f`: actual database concurrency in both winner orders, same-operation receipts, admission/abandon races, stale facts/gallery conflicts, account fences and closed paid-recovery controls. The mapped server/native authority files remain byte-identical to that revision. New Studio visual, fixture and audio changes require their own current-source checks. The run finished15/16 jobs passing; its tour-host audio-startup failure prevents a whole-green claim.

Implementation and documentation for checklist O13–O15 are supported within these scopes. Remaining acceptance is explicit: delivered phone/Studio round trips and delayed-reply/reopen behavior, physical account isolation, actual interruption/cancellation, genuine per-property purchase, supplier quality and complete historical costs. Synthetic tests and a source map do not close those gates.

## Main implementation and test entry points

- Facts: `services/supabase/functions/listings/index.ts`, `20261005024702_listing_facts_intent_cas.sql`, `tools/audit/run_listing_facts_cas.py`.
- Photo choice: `PhotoCloudSelectionCoordinator.swift`, `apps/studio/src/features/listings/gallery-selection.ts`, `20261016163911_native_photo_family_selection.sql`, `20261016171912_native_photo_family_abandon_cover.sql`, `native_photo_family_selection_pg.py`, `studio_gallery_order_pg.py`.
- Video recovery: `PropertyVideoJobRunner.swift`, `PropertyVideoJobsAPI.swift`, `apps/studio/src/features/sync/property-video.ts`, `property_video_abandon_pg.py`, `property_video_submit_recovery_pg.py`.
- Publication and purchase: `ListingWebsiteVideo.swift`, `WebsiteUpgradeStore.swift`, `services/supabase/functions/renders/index.ts`, `property-website-purchase.ts`, `property_video_websites.sql`.
- Costs: `provider-attempt-receipt.ts`, `20261016192846_provider_attempt_receipts.sql`, `tools/audit/run_backend_billing_authority.py` and O09's separate reconciliation.
