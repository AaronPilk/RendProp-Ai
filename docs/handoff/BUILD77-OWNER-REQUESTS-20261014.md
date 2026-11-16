# Build 77 owner requests and working context — 14 October 2026

This is the persistent checklist for the current release. Every new owner message must update this checklist before the release is declared complete. Implementation, automated evidence, deployment and physical-phone acceptance are separate states; never describe preparation as delivery.

## Current delivery

- Branch: `testflight/listing77-20261014`; baseline delivered TestFlight 76 source `7a8c08a84030dbf26d38c53eabd2c554837e08d1`.
- Target: internal-only TestFlight 1.0.4 (77), pushed to GitHub, with the fixes below tested through the owner's mirrored iPhone.
- App Store 1.0.4 (74) is a separate signed candidate. Preserve its submission and automatic release setting. Do not replace, cancel, change metadata or submit an internal lab build.
- Use all three available parallel agent slots for disjoint source work. Root owns deployment, integration, signed archive and physical-phone control.

## Required fixes in this update

| Owner request | Implementation scope | Completion evidence required |
| --- | --- | --- |
| Ordinary photo uploads must allow more than 15, including repeated large batches | Unlimited-selection ordinary picker; serial file-backed import; durable selected order; preserve originals and high-quality browser delivery; report partial failures | Actual import/persistence tests above 15, negative controls, signed build, phone picker check |
| Manage details at the very top of a listing; toolbox above Your tour | Reorder existing listing sections without losing actions or detail fields | Section preservation/order check and phone view |
| Desktop Studio must not be the first thing shown | Move it to the bottom of listing detail | Source and phone check |
| Compliance must not dominate the listing screen; real estate details lower | Compact collapsed compliance near bottom, expandable existing records; keep existing disclosures and provenance | Preservation check and phone expansion check |
| Leads need a bottom tab grouped by house | Home, Listings, Leads, Profile, Settings; filters and account-change fences | Grouping/privacy tests and phone tab/filter check |
| Make a reel must say Make a video and ask its destination first | Social media = 9:16; Listing = 16:9; preserve purpose through API, durable jobs, recovery, composition and export | Both aspect paths, recovery tests and phone chooser |
| Video creation must support more than eight photos | Up to 100 selected photos per video; no silent truncation; preserve order; bounded serial preparation and durable batch decoding | More-than-eight actual recipe/recovery and encoder checks; explicit limit copy |
| Buyer listing links must open the public website, including when Rendprop is installed | Exclude public paths from Apple association; native safe browser fallback; browser-only `/property/` sharing alias for older cached associations | Route/AASA/native tests, production readback, phone browser check |
| Keep the current Home glass design and listing toolbox styles | Narrow changes only for specifically authorized feedback | Diff review and phone comparison |
| Floor plans/measurements and 3D tours must have clear, consistent testable entry points | Retain build 76's two-tool model and lab access in build 77 | Signed lab flag and phone entry points |

## Previously established requirements to preserve

- Accounts are personal. Only the Team owner can switch member libraries; ordinary members must not see each other's listings. Non-Team users do not need workspace terminology.
- Owner-sponsored testers inherit the owner's testing access without imposing a public free-tier restriction. Keep usage measurement and account/privacy boundaries.
- Ordinary import is distinct from paid AI generation limits. Do not change production credentials, provider activation, funding grants or repository visibility during this update.
- Photo variants retain Original, Decluttered and Staged histories. Export remains organized and high quality. Do not delete predecessor originals.
- Video renders recover in the background, notify on completion, preserve the requested frame, and export at least 1080p. Do not add black bars or blurred filler to hide framing problems.
- Aerial intro remains coming soon pending actual quality acceptance. No new aerial provider activation in this release.
- Onboarding, Apple sign-in/purchases, Ask AI, published website, media quality and privacy fixes from the preceding candidate remain baseline requirements. Regressions must be recorded, fixed and retested; no blanket claim that every possible behavior has been tested.
- Leave the unknown John Apple account alone. Never message testers or share private property examples without specific authorization.

## Future work explicitly requested, not quietly lost

- 3D tours are the primary experimental feature: photographic room previews, spatial capture datasets and eventual true navigable reconstruction are different outputs. Do not claim Matterport-quality reconstruction from a dataset or synthetic test. Discuss Blender/Unreal and separately priced reconstruction after real capture acceptance.
- Measurements and precise floor plans are later priority. Their accuracy and usability need the owner's brother and real measuring workflows; do not claim professional measurement accuracy without evidence.
- CMA: exceptionally detailed, accurate, cited and agent-reviewed. The owner accepts approximately $5 research cost if warranted and is considering a one-time $25–$30 price. The earlier 75% margin is a planning target, not a reason to underbuild the report. No invented comparable sales or adjustments. Data rights, actual MLS/provider availability and accuracy must be proven before a paid feature is activated. No CMA purchase or provider contract has been created.
- Keep the anonymized partner deck accurate about implemented versus experimental capabilities and verified release state.

## Closure rule

Populate release receipts with exact source/build/deployment IDs and results. Update this document with any remaining physical acceptance limits. A request is complete only when its intended result is available and its relevant checks pass; do not substitute a plan or another agent's unverified assertion for completion.
