# Rendprop Studio — app branding and creation workflow

> **Historical evidence: 14 September 2026.** This report preserves the behavior,
> versions, test counts and open checks observed at that release. For the current
> Create-first navigation, property edit/chat sync, prompt library and deployment
> state, read [the 24 September production record](../../handoff/CODEX-STUDIO-LIVE-20260924.md). Guided prompt
> enhancement is live; optional LLM enhancement and Presenter generation remain
> disabled. Older screenshots, TestFlight references and local-only boundaries
> below are not a current release checklist.

The live Studio now uses the native app's purple hero, light/dark palette,
rounded cards, feature names and project-first navigation. This is a frontend
release on top of the tested September 14 account/media backend. It does not
change native build 27, Apple identity configuration, Supabase schema/functions,
or the marketing site.

## Shipped experience

- Home follows the app: My homes, Make something, Leads and creation help. Native
  creation cards route to the selected property. Zero homes opens creation; one
  home opens directly; multiple homes offer a keyboard-accessible picker.
- Make a tour, Add photos, AI Photo Studio, Make a reel, Make a floor plan, Make an
  aerial shot and Agent card are prominent. 3D walkthrough appears only when the
  existing service capability is enabled. Additional cards expose narration,
  scripts/shot plans, photo animation, room chapters and Ask Rendprop.
- AI Photo Studio follows the native mode-first flow, with the native edit names,
  four visible staging styles and up to six sequential photo previews. Every
  generation is explicit and uses the existing allowance. Completed results can
  be reviewed and saved independently; ambiguous failures do not regenerate.
- Make a reel has Photos → Voice → Make it guidance and a property media picker.
  It imports actual uploaded photos/videos in selection order, preserves source
  IDs and uses bounded downloads. Existing files are reused in the same property.
  Opening a different property's picker does not move or reset an existing edit.
- Property, creative, editor, planner and business workspaces stay mounted within
  the verified account scope when navigating. Forms, file bindings and previews
  survive a trip Home. Account/workspace transitions still fence prior work.
- System/Light/Dark appearance works across every workspace, follows OS changes,
  and stores only a browser preference. Mobile navigation uses short labels.

## Deployed version

- URL: https://studio.rendprop.com
- Worker: `rendprop-studio`
- Version: `0969a2bc-a822-46d3-94b9-7509ff2d749b`
- [Exact served build proof](deployed-bytes.json): 23 files and the SPA fallback
  matched this verified build. The pre-existing managed robots prefix is recorded
  separately; the receipt does not claim robots crawl blocking.
- Combined compressed built assets: 263,966 bytes, under the unchanged 300,000
  byte gate. The actual Rendprop mark remains byte-identical.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Full unit suite, TypeScript, production build, distribution checks | 276 tests passed | [Build and tests](build-and-tests.json) |
| Real App home cards, exact tool/property routes, dirty forms, appearance, actual media import and property preservation | 13 browser groups | [Home and reel](home-and-reel-receipt.json) |
| Auth, workspace/account boundaries, refresh failures and retained file bindings | 8 browser groups | [Connected account](connected-account-receipt.json) |
| Creative, business and card entries | 21 browser groups | [Creative evidence](creative/README.md) |
| Existing full editor regression and new media picker | 18 browser groups | [Reel evidence](reel/README.md) |
| Appearance behavior, measured semantic contrast pairs, responsive module layouts | 7 scenarios, 16 pairs, 20 layouts | [Theme evidence](theme/README.md) |

That is 60 functional browser groups in addition to the appearance/layout checks.
All new browser flow fixtures use synthetic records and intercept media locally.
They do not send invitations, run paid AI jobs, or mutate customer records. Source
and capture evidence for real cross-session API/media synchronization remains in
[the previous release](../release-parity-2026-09-14/README.md).

The current Apple session and existing property were observed after this release
loaded on the live custom domain. Production card navigation was checked read-only.
Owner names, addresses, media and screenshots are not included in this report.

[Synthetic home, light](screenshots/home-light-1440.png) ·
[Synthetic home, dark](screenshots/home-dark-1440.png) ·
[Mobile home](screenshots/home-light-390.png) ·
[Reel workspace](screenshots/reel-dark-1440.png)

## Honest boundaries

This is not a claim that every native behavior is now identical or that paid
providers and physical-device flows were exercised in this pass.

- Phone captures still require Upload. To continue a phone reel's setup, choose
  Save setup in the app and Load phone reel setup in Studio. To return a finished
  desktop video to the phone, export it, then choose Save video to listing.
- Studio currently keeps one active desktop edit per user/workspace. Its property
  is visible; importing from another property requires review before reassignment.
  This is not a separate desktop edit archive for every property.
- Batch previews are session work until saved. They survive tool navigation but
  must be saved before changing property, account or reloading the page.
- Native camera/RoomPlan capture remains on the phone. Existing sharing and review
  contracts are used on desktop; private local capture files do not sync by magic.
- The native local headshot JPEG has no shared file contract. Shared contact text
  is supported; a phone portrait does not automatically become a desktop/hosted
  photo. See the [headshot audit](creative/headshot-contract-gap.md).
- Native build 27 must be installed for its new cloud create/pull/setup behavior.
  A physical iPhone-to-office acceptance run and real paid-provider outputs remain
  outside these fixture proofs. Older local narration is not reconstructed.
