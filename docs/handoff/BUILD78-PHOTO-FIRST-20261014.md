# Build 78: photo-first property video and website integration

Internal TestFlight candidate on `feature/photo-video-sites-20261014`, based on
build77 delivery `d37fd66`. Normal project remains1.0.4(74); the explicit internal
spatial project is1.0.4(78). App Store74 remains outside these delivery steps.
This document is a source/integration handoff, not a claim of phone acceptance.

## Consumer flow

Start a property and its address/details, capture/import photos, polish or stage
and review saved versions, make a video, review it, then publish. Reviewed staged
versions can go directly into video without re-upload. Originals stay separate.
The selected older staged version wins over a newer editing preview.

Make a video asks Listing16:9 or Social media9:16, then Photos → Create → Review.
All100 selected photos are handled in bounded batches. Automatic visual planning
chooses closed per-photo motion hints and globally orders confident scenes;
uncertain scenes retain their slots. Voice, captions, transitions and global
motion overrides are under Advanced. New videos start with voice, branding and
picture labels off. A failed planner retains all photos in the selected order.
Exact prepared source bytes, order, motion and receipts survive recovery.

The selected finished landscape video leads the website with an explicit Play
control and first-clip poster; the captured drone-style walkthrough is secondary.
Captured footage guidance is slow/steady movement with a gimbal recommendation.
Aerial remains Coming soon. No automatic MLS/Zillow syndication is implemented.

## Website and purchase

Classic is included; Signature Estate and Coastal Luxe are distinct mobile
property sites with glass navigation/cards and restrained pointer effects.
Home/Gallery/Location/Contact use the same property data, with reduced-motion and
privacy-preserving previews. A preview query never grants a paid theme.

One consumable credit upgrades one property to either luxury design. The owner
confirmed$20/property; native displays StoreKit's localized price. The Apple draft
is `com.rendprop.app.website.premium.property`, ID6822852888. Draft metadata/USD
price preparation does not activate sales or change the app submission. Both
server purchase flags stay disabled until real Sandbox acceptance. Hosting still
follows plan/grace rules; a design credit adds no perpetual hosting.

Exact signed receipt assignment precedes Apple finish. Account/library changes,
reinstall, lost response, orphan recovery, concurrent credits, refunds and stale
notifications are covered by production-source-bound closed tests and SQL races.
These are not real payment-sheet acceptance.

## Validation and remaining acceptance

Native normal/lab iPhoneOS SDK builds passed on the current Swift source. Focused
compiled controls cover staged-version substitution, full photo-plan cardinality,
scene uncertainty, exact source cache, recovery and publication identities.
Backend proof includes54 SQL assertions/five races,251 focused Deno tests and five
planner controls. Website full predeploy,62 actual browser checks/five controls,
219 existing browser checks and24 real-image fixture layouts passed. The image
fixtures are not evidence of AI architectural fidelity.

Required before a new public candidate:

- Install78 and accept the actual simplified workflow on the mirrored iPhone.
- Real staged-photo → automatic video → review → publish, both output formats,
  longer sequences, ordinary-account route, exact sources and ledger settlement.
- Compare raw provider output and final encode for geometry, furniture, sharpness,
  motion, duration and crop. Portrait-source filling landscape loses large regions;
  resolution metadata alone is not proof of retained scene detail.
- Real buyer link, website video/gallery/location/contact and Leads; account privacy,
  source exports and Sandbox consumable recovery. Do not send external test messages.
- True full-video background finish/notification: current UIKit execution expiry
  pauses safe saved work. A separate durable server-batch implementation is in
  progress; phone suspension cannot yet be certified as full-job completion.
- Refresh onboarding with actual photo-first phone screens, Willow, no blank scenes,
  maximum60 seconds. Existing introduction is unchanged in this internal build.

Kie is not yet the ordinary route; the expired private test override did not
promote it. Ordinary photo edits are direct Gemini2K, not a4K promise. FAL's old401
is not evidence that all current calls fail. Promote exact measured model/format
routes after output acceptance and matching provider consent/disclosure.

Do not submit the internal spatial-lab archive publicly. Only after acceptance,
create a normal App Store archive and a tested replacement submission with
AFTER_APPROVAL automatic distribution. CMA remains a separately planned accurate
paid-report product pending data rights; spatial reconstruction and measurements
remain experimental, outside the photo/video launch acceptance.
