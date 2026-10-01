# Listing-first pages and HD fly-through — 1 October 2026

This release addresses the owner's report that opening a property link forces
visitors into the fly-through, details navigation jumps past a long video, and
returning to the top repeatedly buffers a compressed file.

## Deployed result

Normal branded `/f/:slug` and unbranded `/u/:slug` pages open with the property
address, price and overview. Photos/rooms, floor plan and contact have ordinary
navigation; Top returns immediately. **Watch fly-through** opens a separate
native playback dialog with play/pause, seeking, fullscreen and room shortcuts.
**Back to listing** stops playback, destroys HLS if used, removes the media
source, empties the decoder and restores scroll position and focus. Escape also
returns. Rapid close/reopen cannot let an earlier queued dialog event shut the
new session. No video bytes or video-view beacon are requested before opening.
Photos, property details, staging/original disclosures and lead capture keep the
existing public data contract. MLS output still strips agent/contact/form data
and runs the fail-closed sentinel check. `?embed=1` explicitly keeps the existing
scroll-driven embed; the iPhone bundled preview remains a scroll player.

The normal player prefers the published R2 master, without a browser resolution
cap or re-encode. HLS remains a lazy fallback with bounded buffers. The visible
quality label reports actual decoded dimensions. A failed load offers Retry and
Back to listing; it does not trap visitors behind the video.

## Why a page change is insufficient for old video quality

A range-only inspection of an existing public tour found a **720 × 1280**,
132.233-second, 60 fps master, **159,039,685 bytes** (approximately 9.62 Mbps).
Its MP4 metadata was at the end, offset 158,997,299, so loading needs an extra
end-of-file request. The inspection read **42,426 bytes**, not the entire customer
video. That tour has no HLS fallback. This establishes the stored-file limitation;
it is not a subjective review of footage or a camera test.

New native and optional-server renders now retain a maximum **1920-pixel long
edge** with aspect preserved and **no upscaling**, target **24 Mbps**, H.264
all-intra, nominal 60 fps, Rec.709 SDR, and metadata before media bytes. Existing
retiming, stabilization selection and silent standard-tour audio are preserved.
At the target bitrate a minute is approximately **180 MB**; actual encoding rate,
phone render time, storage and upload time depend on footage/device/network.
This improves full-HD master detail; it does not claim 4K delivery.

The phone's Fly-through detail screen adds **Re-render fly-through** when the
original recording exists locally, opening the existing review/settings flow.
Missing source gets an explicit download/add-again explanation. Confirmation and
entitlement responses recheck account/session/workspace/listing identity before
mutation. A failed new render keeps the earlier completed tour.

Publishing the new render creates a **new sharing link** under the current
publication contract. Previously shared links keep the earlier video. No old
customer video is automatically re-rendered, overwritten or relabeled HD.
The optional worker's committed defaults changed too, with explicit BT.709 VUI
metadata; environment overrides and fleet deployment are separate from this
release. No backend function or migration is needed for the normal native path.

## Verification and release boundary

The actual AVFoundation RenderEngine and FFmpeg worker encoded generated test
media at 1920 × 1080, 3840 × 2160, 1080 × 1920 and 640 × 480. All eight outputs
passed aspect/no-upscale, all-keyframes, SDR tags, silent audio, unchanged speed
and MP4 metadata order. Native output of the static 30 fps fixture retains the
same **45 frame timestamps** on the nominal 60 fps timeline as the prior policy;
FFmpeg's fps filter produces 60 frames. These are not claims about unique camera
frames. A decoded fine-detail synthetic pattern measured **46.41 dB luma PSNR**
versus **21.24 dB** for the earlier 720p render enlarged to HD. Reverting the HD
ceiling fails the actual-output gate. Explicit worker color tags preserve decoded
luma bytes exactly. These synthetic metrics do not certify real-house footage.

Thirty-three executable checks use the exact submission/entitlement guard source,
including suspended replies and owner/workspace changes. Removing the confirmation
fence fails its queued-owner-change negative control. The 27 existing Phase 1
Node suites passed. The tour-host static suite passed **2,766 assertions**,
including 693 unbranded assertions, with legacy embed and new normal-page spatial
teardown contracts checked separately. The normal-page browser passed **138 assertions** with real synthetic SOG
rendering and **134 assertions** on the CI-default spatial-module failure path.
The legacy spatial browser also passed on official Chrome. These exercise encoded
H.264/AAC, byte ranges, mobile/desktop layout, native controls, delivered frames,
failure/retry, focus/scroll restoration and slow-transfer cancellation. Deliberate
eager loading, retained media and queued-close regressions must be rejected.

Internal **TestFlight 1.0.3 (37)** is available to the existing **Rendprop team**.
Apple readback at **20:50:00 UTC** confirmed `VALID`, `INTERNAL_ONLY`,
`IN_BETA_TESTING` and membership in that existing group. The English testing
instructions were updated and read back at **20:54:55 UTC**. The signed archive
binds **197 native inputs**, **133 tracked Swift inputs** and one generated Swift
input to source `512fb8b710625615259d6ece9323220312288e29`. Its executable and
both surviving dSYMs have the same arm64 UUID; archive/DerivedData dSYM bytes
match. Xcode moved the separate DerivedData app product during archiving, so
there is no claim of an independently surviving executable byte comparison.
One internal-only upload succeeded; no duplicate upload, App Store review,
public-version attachment, subscription-price or tester/group change occurred.

All **12 CI jobs passed** on the archived native source:
[run 36921783108](https://github.com/AaronPilk/RendProp-Ai/actions/runs/36921783108).
The positive HDR tone-map regression passed there. Local FFmpeg lacks zscale;
its local prerequisite failure remains recorded rather than counted as a pass.

Public tour-host is live at **100% traffic**, Worker version
`8268c7a9-aad9-43a7-89ac-f1769e75896b`, deployed from web source
`a87834cd44c39e37178cfc8fe91684aa623ccde3`. This follow-up changes only the
existing contact-verification widget's size from flexible to compact; its
300-pixel minimum previously overflowed the actual 320-pixel page. The deployed
150 × 140 widget fits the available panel. No challenge configuration, secret
or validation endpoint changed; see [Cloudflare's widget sizes](https://developers.cloudflare.com/turnstile/get-started/client-side-rendering/widget-configurations/).
All **12 CI jobs also passed** on this exact web source:
[run 36924574346](https://github.com/AaronPilk/RendProp-Ai/actions/runs/36924574346).

Final live verification at **20:53:48 UTC** passed **153 assertions** on an
actual branded and unbranded listing. Both matched the local inline renderer,
decoded the existing R2 master only after explicit opening, and emptied the
decoder/source while restoring focus and scroll on close. There were no layout
failures or application exceptions. Home, pricing, terms, privacy and health
retained their normalized bodies and stable security headers; raw marketing
HTML varies through Cloudflare's injected challenge script. The verification
read 10,584,458 bounded media bytes and saved no complete customer video.
Every attempted browser write was blocked, including infrastructure challenges
and post-play view beacons, so this check does not establish lead delivery,
analytics receipt or challenge-token validation. Bounded ranges alter transfer
behavior; this is not a full-bandwidth benchmark. Actual HLS streaming and
physical iPhone/Safari acceptance remain separate checks.

The [delivery receipt](../releases/TESTFLIGHT-37-20261001.json) records the final
source, CI, archive, upload, Apple availability and production readback, with
hashes of the preserved private evidence. Earlier preflight/deployment receipts
retain their original pending fields; later evidence completes those gates.
Source remains on isolated `fix/listing-first-tour-20261001`, with stacked draft
[PR #14](https://github.com/AaronPilk/RendProp-Ai/pull/14) against
`fix/room-tour-photo-delivery-20261001`. Shared main was not advanced or
force-pushed. Documentation commits are separate from both runtime sources.
No backend function, migration, server-worker fleet deployment, paid provider/GPU
run or spatial activation is part of this release.

## Owner acceptance on a real phone

1. Open an existing branded link and its unbranded counterpart. Navigate Photos,
   Details and Top without opening video; the page should remain responsive.
2. Open Watch fly-through, pause, seek a room and close. Return to the same listing
   position. Repeat on mobile Safari, including a slower cellular connection.
3. Install **TestFlight 1.0.3 (37)**. Open a listing with its original
   recording on the phone, choose Re-render fly-through, review settings and render.
4. Publish, copy the **new** link and compare actual detail on phone and desktop.
   The old link intentionally keeps its earlier render. Smaller originals remain
   their original resolution; phone thermal/render time need real-device testing.
5. Check AI-altered gallery disclosures and ordinary lead capture using the
   intended test listing. Read-only deployment checks do not create customer
   leads or analytics.
