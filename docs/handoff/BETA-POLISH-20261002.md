# Listing and photo-work feedback — 2 October 2026

Runtime `3615a23a4c055045be053cf788e776263de75851` is deployed from isolated
`fix/beta-polish-20261002`, based on delivered build 40 documentation `eef4918`.
Internal **TestFlight 1.0.3 (41)** was verified available to the existing Rendprop
team on **2 October 2026 at 17:23:58 UTC**. Apple reports VALID, INTERNAL_ONLY and
IN_BETA_TESTING after one upload. English testing notes are readback-verified.
The [delivery receipt](../releases/TESTFLIGHT-41-20261002.json) binds source,
archive, CI, upload and production readbacks. Main and Claude's checkout were not
rewritten; [draft PR 18](https://github.com/AaronPilk/RendProp-Ai/pull/18) is stacked
on the delivered crash-hardening branch. The later delivery commit changes docs only.

The gallery migration is recorded live as `20261002171338` (source filename
`20261002160344`); all eight schema/grant checks and three function bodies match.
Functions listings 38, tours 45 and ai-photo 49 are ACTIVE with JWT verification
on. Submitted files are 12/14/24; extracted files are 12/13/24, all source-matching.
Tours extraction omits contract.ts, reached only through an erased Row type edge;
its unused runtime exports are not a missing runtime dependency. Worker
`0d5db590-c2c8-4482-9f3f-77bcf893fcd6` is deployed at 100%. Four existing branded/MLS
HTML GETs match the reviewed engine/CSS without fetching media. These live checks
are separate from the 195 local actual-browser assertions and phone acceptance.

The owner confirmed repeated cold opens on40 worked. Available Apple screenshot
feedback was exhaustively paginated:25 submissions, including13 for40, two for37,
one for28, six for27 and three for24. Every comment was read and all 25 screenshots
were visually reviewed. The screenshots and
customer identifiers remain in private local audit storage outside Git. The
owner's five new screenshots are also part of this review.

## Changes

- The public page uses the selected main photo, then eligible ordered gallery,
  before a video-poster fallback. Property information remains outside the video.
  The compact navigation aligns controls at mobile widths. Opening the video
  defaults to **Explore**, a scroll-controlled paused fly-through inside its own
  overlay; **Play video** enables ordinary playback. Source loading starts only
  after opening, and closing unloads playback and restores the listing position.
- Native client-contact editing uses labeled branded cards, public preview,
  separate private lead routing and a Save control above the keyboard. The client
  card and recipient do not share public/private fields.
- Apartment/unit input is available alongside an address and survives current
  location, creation and subsequent edits. It is persisted in the existing street
  address with `#unit`, preserving coordinates and metadata without a schema change.
- **Edit listing details** is prominent on the listing screen. Existing property
  facts open expanded and save bedrooms, bathrooms, size and price while retaining
  other metadata, including year built.
- Room tagging scrolls safely, shrinks the player while typing and keeps custom
  name/Add/Done above the keyboard. Confirmed manual tags survive reopening.
- App-owned photo work continues after leaving Photos. A global top banner shows
  completed-attempt percentage and counts, with Review and specific failure reasons.
  No invented provider percentage is displayed. Local completion notifications
  require OS permission and enabled account/render preferences. Account/workspace
  changes or deleting the listing stop the captured job.
- Photo results remain visible after edits. History retains originals and earlier
  versions. **Use this version on listing** selects an older or newer result and
  updates a published gallery. New staging outputs require deliberate selection;
  non-staging edits keep the established automatic selection behavior.
- Server cover/gallery validation accepts only ready, visible same-workspace,
  same-listing gallery photos. Main selection is server-resolved from an asset ID.
  Explicit galleries are ordered and limit40. Cloud-imported local additions use
  an atomic additive RPC so concurrent additions preserve one another. Corrupt
  history or missing selected files block publication with an error and preserve
  the existing published gallery.
- Known public photo disclosures now instruct comparison with the original;
  they no longer certify unchanged architecture based on a generation prompt.
  Native saved-version captions and exports also present corrected review wording
  while preserving their immutable historical sentences. Historical audit rows
  and source images are retained. Existing provenance is
  attached to the actual gallery asset selected for publication.
- Motion smoothing reports measured correction, steady footage or unavailable
  analysis. A safety crop alone no longer claims successful stabilization. Capture
  modes, motion profile parameters and render speed are unchanged.

## Feedback disposition

Indices below are stable positions in the private25-row retrieval, not tester IDs.

| Indices / build | Issue | Disposition |
| --- | --- | --- |
|0 /40 | Cannot edit published property facts; wants nearby attractions | Facts editing fixed and tested. Verified nearby-location enrichment is separate work; no attractions fabricated. |
|1 /40 | Center/level photos and show more room | Existing guided0.5×/1× capture remains. Automatic perspective/composition correction is not added in this release; unseen room content must not be invented. Physical capture acceptance is still required. |
|2–3 /40 | Publish declutter instead of staging; return to an earlier edit | Explicit saved-version selection, retained sources and published-gallery selection implemented and tested. |
|4–9 /40 | Furniture intersects wall/door, fridge moved, invented window, inconsistent room furniture and artifacts | Confirmed output-quality failures. Staging requires review and deliberate selection; factual geometry/multiview consistency is not claimed fixed. |
|10 /40 | Cannot see edited photos after staging | Results remain visible and completion refreshes the library; queue/lifecycle checks cover refresh. |
|11 /40 | One edit failed with unclear reason | Batch failures now retain photo number and error; Review surfaces the reason. This does not retroactively identify an unrecorded historical provider failure. |
|12 /40 | Declutter works well | Provider/model/prompt routing left unchanged. Originals retained. |
|13–14 /37 | Room standing position/target is frustrating | Separate spatial/room capture work remains with Claude and owner phone tests. No capture policy or global reconstruction flag changed. |
|15 /28;16 /27 | Fly-through dominates listing and quality reduced | Listing-first page retained, compact navigation and Explore/Play added. Existing HD1920-master policy retained; old compressed media requires original-source re-render and a new link. |
|17–18 /27 | Enhancement too slow / needs progress | Existing render progress remains. Photo batches now show honest completed-attempt progress and support app navigation. Provider time is not shortened or converted to a fabricated countdown. |
|19 /27 | Phone contact opens mail | Current public/native card uses distinct telephone/email actions; public regression checks preserve them. Controlled phone acceptance remains. |
|20 /27 | Address autocomplete | Existing autocomplete preserved; unit/current-location changes are tested. Real geocoder/GPS acceptance remains. |
|21 /27 | Capture/import should start with a project/address | Existing project-first route preserved and source reviewed. |
|22–23 /24 | Code fails / entering it in Settings is confusing | Current account/auth flow was changed since24 and previous readiness work remains. Old feedback alone cannot prove a current authentication defect or fix; fresh Apple/email sign-in is a phone acceptance check. |
|24 /24 | Screenshot without comment | Reviewed visually; no independent new defect inferred solely from an old screenshot. |

## Validation and limits

The public player passed195 actual Chrome assertions with generated H264/AAC media
and five deliberately broken controls. Worker typechecking and all publication,
MLS, routing, lead and media tests pass. Independent backend/player review is GO.
Backend gallery handling passed42 Deno tests,47 SQL assertions on fresh and replayed
migrations, concurrent different-photo/repeated-photo appends and deletion regression.

Native checks exercise actual source:304 photo-history/export assertions,22 Combine
queue assertions,65 lifecycle/notification boundary assertions,71 unit/metadata form
assertions and60 existing client-contact assertions. All 12 CI jobs passed on the
archived source; the pull-request merge tree matches it. Five beta UI cases passed
across preserved runs, with final queue navigation and cold toolbox checks on
native inputs byte-identical to the archive. Earlier editor/detail runs are
qualified separately; this is not one all-green twelve-case UI run. The actual
banner/Back overlap caught during UI testing was fixed and its regression passed.
The signed arm64 archive, 214 inputs, 140 compile inputs, dSYM and fixture exclusion
passed independent review. Earlier compiler/harness failures remain recorded.

Actual AVFoundation synthetic renders classify feature-rich stationary footage as
`steady`, translated jitter as `applied`, and featureless footage as `unavailable`.
A private former crop-only success mutant fails the stationary assertion. Existing
HD, orientation, color, all-intra, silent-tour and retiming checks still pass. These
fixtures do not validate real walking parallax, physical capture or drone quality.

The queue is in memory. Navigating around Rendprop is supported; force-quitting
interrupts unfinished work and iOS grants only finite background time. Saved edits
survive. Remaining photos require deliberate selection rather than automatic paid
retry. Local history is not a shared cloud version-history system. Cloud append
preserves older remote variants because cross-device version-family identity is not
inferred; complete local selection retains the existing last-writer behavior.

Video object removal is possible, but photo declutter is not a full-video declutter
feature. The existing reflection-removal path is bounded to short Bria clips and
needs its own provider/real-footage acceptance. Bria's current
[video editing documentation](https://docs.bria.ai/video-editing/editing) specifies
a five-second eraser limit. No paid eraser, AI generation or spatial experiment ran.

Deployed targets are the new gallery-selection migration, `listings`, `tours`,
`ai-photo`, public tour-host Worker and internal TestFlight 41. JWT verification stays
enabled on all three functions. No public App Store release, pricing change, tester
changes, spatial activation or budget increase is part of this release.
