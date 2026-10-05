# Complete beta-feedback follow-up — 5 October 2026

## Inventory and scope

The initial GET-only own-app Apple read completed at **14:43:44 UTC / 10:43:44 EDT**:
49 screenshot submissions, 50 images and 48 nonempty written comments. A second
complete read at **15:55:35 UTC / 11:55:35 EDT** found three additional submissions:
**52 screenshot submissions, 53 images, 51 nonempty written comments, and one
unchanged build-37 crash submission**. Both reads exhausted pagination and matched
their reported totals. A third complete GET-only read at **16:41:09 UTC /
12:41:09 EDT** returned the same records, with no added, removed or changed reports. Every comment and all 53 images were reviewed, including
the twelve submissions added since the October 4 review.
The crash log was read separately. These are submitted feedback reports, not
a census of all device crashes.

Work is isolated on `fix/beta-feedback-20261005`, based on `748ac2a` from the
full-debugging branch. Claude's shared checkout is untouched. Customer images,
tester identities, contact values, signed image URLs and raw Apple responses
remain private under `/Users/pilksclaes/LocalRendpropAudits/beta-feedback-20261005`.
The 50-image manifest SHA-256 is
`215ea5575512b0132acb71c0f4fe76ad1405b00e8145788bf65ae4ff78975997`.

**Source changes are not a signed TestFlight release or a backend deployment.**
Physical camera/AR acceptance, paid provider output and actual StoreKit purchases
are separate from offline and simulator checks. In particular, architecture
hallucinations are not certified fixed by a stronger prompt or a review checkbox.

## Every submission

Indices 0–48 below refer to the stable newest-first initial October 5 inventory.
“Prior source” means the implementation already exists in the inherited branches;
it does not mean every change has reached the user's installed build.

| Index | Build | Request or observation | Concrete disposition |
| --- | --- | --- | --- |
| 0 | 44 | Add spatial capture to toolbox, Coming soon | Add an informational 3D walkthrough card. Preserve the separate local TestFlight Lab; do not enable the global pipeline. |
| 1 | 44 | Floor plan Coming soon | Separate usable Measurements/outline/worksheet/upload from the experimental 3D scan card. Disable new scans in the ordinary flow; saved plans remain accessible. |
| 2 | 44 | Send a business card without portfolio | Add a separate contact-only vCard share action. |
| 3 | 44 | Top buttons misaligned | Correct the published page's mobile navigation with aligned rows, short fly-through label, real touch targets and large-text wrapping. The screenshot is not the native Home toolbar. |
| 4 | 44 | Choose which listings accompany the card | Add deliberate published-listing selection and scoped portfolio export. |
| 5 | 44 | Replace sample tours with an app walkthrough | Hide samples from customer collections/Home and add a clickable, offline feature guide in Home, the empty collection and Settings. |
| 6 | 44 | Retry publication opens Compare | Current source already calls gallery sync directly. Preserve that path, strengthen identity/selection guards, and keep cover review separately named. Verify the actual reported control before claiming a live-build reproduction. |
| 7 | 44 | Remove Plan your video | Remove its top-level listing-detail entry. Preserve agency production-plan data and Studio workflow. |
| 8 | 43 | Download JPEG for MLS | Add an explicitly named JPEG/Files export on the reported listing file grid; retain original/source and version choices. |
| 9 | 43 | Show selected photo | Prior source: distinct published selection, cover and device-save states, correct row/action identity, Compare-close refresh. |
| 10 | 43 | Find desktop Studio | Prior source: named Studio entry in Settings and listing detail, same-account/workspace instructions and local-upload distinction. |
| 11 | 43 | Renewal disabled | This is aggregate owner churn reporting. Explain that renewal-off can coexist with access until expiry; preserve counts and Apple's subscription state. |
| 12 | 43 | Listings tab name/icon | Prior source: Listings/My Listings with distinct list icon, preserving photographer and industry labels. |
| 13 | 43 | Many empty workspaces | Aggregate cohort exclusion count, not duplicate picker entries. Prior source corrects the denominator and numeric-suffix decoders; do not delete workspaces. |
| 14 | 43 | Five crashes/thirteen errors | Historical build-37 diagnostics and routine MetricKit launch records. Prior source stops routine metrics being classified as errors; retain real diagnostics and historical data. |
| 15 | 43 | Apple key should be active | Prior source distinguishes an incomplete server exchange/revocation bundle from native Supabase id-token sign-in. Do not infer missing-key identity or disablement from this health result. |
| 16 | 43 | Optional providers off | Owner's Higgsfield enterprise/privacy condition still disables generation. Optional configuration is not a shipping entitlement; do not enable providers blindly. |
| 17 | 43 | FAL appears inactive | Prior source separates configured state, recent ledger activity and actual credential/output verification. No-activity is not an invalid-key result. |
| 18 | 43 | ElevenLabs key diagnostic | Prior source reports missing diagnostic permission as unverified, preserving actual auth failures. Do not widen key scope or claim voice output from this check. |
| 19 | 43 | Cleaner paywall | Compact plan selection with one selected benefit panel. Preserve actual StoreKit prices, trial eligibility/disclosures, unavailable states and all pricing allowances. |
| 20 | 43 | Account-aware Coach and Needs attention | Add bounded authorized account/workspace/selected-listing context, safe recovery reasons and deterministic actions; preserve existing safety/rate/token caps. |
| 21 | 43 | Business logo and phone formatting | Add distinct hosted business logo with immutable scoped uploads and cleanup/deletion accounting. Format domestic display without destroying international numbers or headshots. |
| 22 | 42 | Gallery sync warning | Prior source: explicit warning/retry and gallery reconciliation. A visible warning is not proof of successful cloud publication. |
| 23 | 42 | Reel generation failures | Retain completed clips, stop after failure, expose the failed clip, and recover accepted provider requests without generating/charging again after a transient polling/download failure. Upstream output remains a separate test. |
| 24 | 40 | Edit facts and nearby attractions | Prior facts CAS preserves unrelated concurrent edits. Add explicit Apple Maps lookup, reviewed selection and a bounded nearby-place note using the same exact field/presence CAS. No invented travel times. |
| 25 | 40 | Center/level/wide interior photos | Prior supported-lens/level capture improvements. Non-generative enhancement and actual framing must be evaluated on real source photos; unseen room area cannot be recovered faithfully by inventing content. |
| 26 | 40 | Choose decluttered versus staged | Prior persistent Original/Decluttered/Staged libraries and explicit gallery/download choice. Preserve those libraries. |
| 27 | 40 | Retain declutter after staging | Prior durable base/history keeps predecessor files; do not reapply the older deletion approach. |
| 28 | 40 | Table intersects wall | Strengthen fixed-architecture/placement instructions and explicit review. Actual output-quality acceptance remains open. |
| 29 | 40 | Refrigerator moved | Lock fixed appliances and architectural positions in instructions/review. Actual output-quality acceptance remains open. |
| 30 | 40 | Staging differs between views | Add shared furnishing instructions and explicit cross-view review. The new optional reference-image adapter is Coming soon: all reference requests refuse before quota/provider dispatch because input-image costs are not yet included in the ledger. Do not enable it before reviewed pricing and held-out consistency evaluation. |
| 31 | 40 | Furniture blocks doorway | Require review of door/access clearance and placement; do not claim automatic geometric validation or certified output. |
| 32 | 40 | Invented window | Preserve windows/walls/openings in instructions and review. Real output evaluation is still required. |
| 33 | 40 | Editing artifacts | Retain original comparison/version history and review. No prompt guarantees absence of artifacts. |
| 34 | 40 | Edited photos disappeared | Prior durable version history and viewed-version exports, plus explicit JPEG/Files route in this follow-up. |
| 35 | 40 | One edit failed | Retain successful outputs and explicit per-photo failure/retry. Add safe failure classification; do not promise every provider succeeds. |
| 36 | 40 | Declutter works well | Positive feedback preserved. It is not certification of all rooms/photos. |
| 37 | 37 | Position tolerances make room scan unusable | Prior handheld guidance improvements; real-phone acceptance remains. The ordinary 3D cards are Coming soon, with experiments separate in TestFlight Lab. |
| 38 | 37 | Purple target/position confusion | Same physical capture acceptance boundary. Do not certify camera behavior from a simulator. |
| 39 | 28 | Fly-through dominates page | Prior listing-first main-photo page, opt-in viewer and normal section scroll, verified with actual renderer/media. |
| 40 | 27 | Public layout/video quality | Actual Explore/Watch switching, unload on close, source/HD behavior and aligned navigation. Walking footage cannot be called an actual drone shot. |
| 41 | 27 | Enhancement slow/skip | Prior background photo queue, retained results and safe skip/status. Provider speed/ETA is not guaranteed. |
| 42 | 27 | Useful percentage progress | Prior completed-photo percentage/global status; do not fabricate a per-provider percentage. |
| 43 | 27 | Phone action opens email | Prior separate typed phone/email actions; actual device handling remains acceptance. |
| 44 | 27 | Address suggestions | Prior autocomplete/current-location/unit-number flow; actual Maps/geocoder acceptance remains distinct. |
| 45 | 27 | Name project before capture | Prior project-first gate; no loose capture or AI job before choosing a listing. |
| 46 | 24 | Invitation fails | Prior real invite/adoption/concurrency fixes. Use actual valid invitations, not the photographed synthetic placeholder code. |
| 47 | 24 | Discover joining a team | Prior Workspace/Settings Team/Join navigation; include this path in the app guide. |
| 48 | 24 | Empty comment, invitation error image | Read the image; do not infer an additional written request. Same invite acceptance boundary as 46. |

### Three reports received during the review

These entries retain separate N-indices so the original evidence mapping remains
stable. All three new screenshots and comments were read in full.

| Index | Build | Request or observation | Concrete disposition |
| --- | --- | --- | --- |
| N0 | 44 | 25 tour renders but only two drone glides is confusing | Label cloud renders and video quality upgrades distinctly. Explain that on-phone tour publishing does not use the cloud-render allowance and that AI resolution/detail upgrades do not turn walking footage into an actual drone shot. Keep existing prices and quotas; a full 75%-of-net margin floor remains unfinished. |
| N1 | 44 | Team invite replaces personal Profile; duplicate Owner workspaces | Reproduce the personal-card replacement in actual compiled Profile code, then separate account-owned public cards from workspace branding. Explicitly reviewed personal card storage must not copy an inviter's contact information or the private login email. The screenshot after leaving the team shows duplicate names, so show a distinguishing workspace ID without deleting or merging workspaces. |
| N2 | 44 | Profile editing needs Save | Add a visible explicit Save action, retained drafts and presence/value conflict protection for the account-owned card. Saving must not silently update the selected workspace's agency branding. |

Profile contact edits require the explicit **Save** action. A local draft survives
a rejected online save; closing the editor does not publish a new contact card.
The public-card Save is independent of the selected workspace business-logo action.

Default shared-workspace inquiries continue to notify workspace owners/admins.
The existing explicit photographer-client delivery overrides remain separate;
editing a public card does not change private login or notification addresses.

## Verification and rollout

The complete closed backend suite passes **1,442 tests**, with zero failures
and one existing ignored database-backed presenter test. All 233 TypeScript
source files match their start/end hashes. The presenter and privacy paths have
separate SQL/controller coverage; an ignored test is not a live-integration proof.
The actual published-page browser gate passes **203 checks**, including mobile
navigation at 200% text, nearby-text escaping, real 720p H.264/AAC playback,
Explore/Watch switching and unload/retry. Source/executable Phase 1 passes
**33 tests**, the actual listing form passes **29 assertions**, and subscription
policy passes **312 assertions**. These are different scopes, not a single
end-to-end customer journey.

Photo export executes the actual UIKit JPEG renderer against synthetic images:
**48 assertions plus seven compiled fault controls**. Paid reel recovery executes
actual submission/retrieval/manifest/consent bodies: **89 assertions**, **14 Lab
dispatch assertions**, and **13 compiled fault controls**. It refuses duplicate
POSTs after ambiguous submission, retains successful downloaded clips before
acknowledging a job, and refuses inaccessible or corrupt authoritative history.
This includes two independently reproduced data-loss bugs: an unreadable new
request marker previously fell back to an old receipt, and an unreadable clip
manifest previously fell back to an empty old record and deleted paid clips.
All failed intermediate attempts remain private and labeled failed.

Independent database checks pass **44 logo assertions** and **34 personal-card
assertions**, two mutation controls and two real transaction races per feature.
The facts runner passes **52 facts and six nearby assertions** on fresh and replay
runs, with actual same-field/disjoint-field races. The full invariant set remains
**269/270**, with the one explicitly recognized Astra answer-ceiling failure;
this work does not claim that missing budget fence is repaired.

Actual native Profile policy passes **117 assertions and 14 compiled fault
controls**. The independently compiled erase/migrate proof passes **seven**
checks, and the full matrix of nine successful personal-card/logo Save, Clear and
Reload transitions passes **19**. This catches both legacy cache resurrection
after device erase and an older cloud read replacing a newly acknowledged or
explicitly reloaded logo. Source-bound receipts retain the original failing
reproducers. Personal cards remain account-owned through team switches; the
explicit Save bar must remain reachable above the keyboard.

All **five full-app Release simulator UI cases passed**, with zero failures or
skips and unchanged full source hashes: card-only OS share, deliberate portfolio
selection, separate logo/international phone, stale client Save, large-text guide,
and keyboard-open personal-card Save followed by a team switch (sharing flows
share one case). Both the **regular and TestFlight Lab unsigned physical iOS
Release builds passed**, with unchanged source hashes. These are compile/UI
proofs; there was no signing, archive upload or camera acceptance. The draft
PR records all twelve CI jobs against the final exact commit. Receipts distinguish
canceled/intermediate builds from verified final bytes.
Actual StoreKit product/purchase UI remains unverified: the local StoreKitTest
daemon refused configuration, and no real-purchase fallback ran.

The nearby note adds only `nearbyAttractions` (maximum 500 characters) to the
service-only facts RPC. It does not replace amenities, private measurements or
the floor-plan attachment. The three new additive migrations must be applied in this order before their
corresponding function handlers:

1. `20261005150445_scoped_business_logo.sql` — workspace-owned immutable logos,
   role/lineage checks, reservation/replay and cleanup accounting.
2. `20261005150951_nearby_places_reviewed_facts.sql` — bounded reviewed nearby note
   in the existing service-only facts CAS.
3. `20261005160701_personal_public_card.sql` — account-owned explicitly reviewed
   public card and authorized listing-agent identity lookup.

Deploy the updated `me` and `tours` handlers after the schemas, and coordinate
`coach`, `ai-photo`, `ai-video` and the public Worker with their native callers.
The native logo-clear endpoint is **POST `/me/brand/logo/clear`**. The old handler
rejects that route without deleting an account; its historical generic DELETE
handling makes a subpath DELETE unsafe before the new handler reaches production.
No real account-deletion probe was performed.

Public-card edits never copy a private login email or an inviter's card.
Arbitrary/external portrait URLs cannot be accepted as personal-card identity:
the previous native profile stored portraits locally, without a hosted upload.
Local card exports retain the chosen portrait, but a new shared-workspace portrait
upload is not implemented by this change. The legacy sole-owner portrait fallback
requires verified own photo lineage and the configured public R2 origin.

Explicit photographer-client contacts still take precedence on the listing.
Public-agent identities are rechecked against current membership/deletion state;
editing the personal card does not redirect default workspace inquiry emails. The inherited Apple chronology/facts
EXPAND/CONTRACT rollout requirements in [the full debugging report](FULL-DEBUGGING-20261004.md)
remain; do not bulk-push migrations or deploy contract cutovers out of order.

Real-phone acceptance must cover supported 0.5× capture/leveling, camera/AR lab
guidance, actual Files/Photos delivery, real same-account sync and invitations.
Paid AI evaluation must compare architecture, fixed appliances, access clearance,
artifacts and cross-view furniture identity against held-out original room photos.
These cannot be honestly marked closed by a source-only or synthetic run.
