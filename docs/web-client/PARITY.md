# Parity inventory — before components

Source baseline: `f14081d`. This is an inventory, **not verified parity**.
Machine-readable truth: `packages/client-contracts/capabilities.json`. Its verifier
compares every `APIClient` protocol method against the actual Swift file, detects missing,
extra and duplicate mappings, and checks paths for capabilities outside that protocol.
There are 41 distinct method names / 42 declarations (two `completeUpload` overloads).
UI discovery remains a manual review obligation: a method inventory cannot prove every
interactive behavior, accessibility path, business rule or hidden direct call is covered.

| Capability group | Desktop equivalent | Blocking evidence |
| --- | --- | --- |
| Listings/create/edit/delete | Bulk workspace, multi-select, individual failure receipts | Direct Data API ownership/RLS; local-only deletion fixtures |
| Upload tickets/parts/batches/complete/abort | Resumable bounded 2 GiB+ uploader | Real browser CORS, identity/file recovery, server completion ambiguity |
| Render/status/publish/chapters | Timeline and versioned canonical export | Renderer fencing, shared content hash, caps; do not claim iOS byte parity today |
| Photo edit/suggest/improve | Bulk photo studio, before/after and provenance | Server-only staging/provenance fields; approved provider and per-file cost |
| Provenance/CSV/original media | Disclosure/evidence panel | Server-verified originals and immutable artifact binding |
| Script/shotlist/agent reel | Shared server EDL with editable client timeline | Native agentreel method and phrase-timed offline-only integration missing; existing SpeechTranscriber permits server fallback |
| Drone/aerial/reel/drift | Existing approved AI jobs, placement in editor | No disabled routes, no unapproved media sharing; live spend/cap fixtures |
| Voices/TTS/chapters/coach | Same route-backed tools | Exact decoding, fairness, transient failure and replay fixtures |
| Usage/brand/leads/lookup | Team dashboard, card, lead inbox, property form | Current org selected independently of user identity; server authority |
| Admin read/write | Separate operations tooling | Admin ≠ brokerage owner. Provider activation restricted, not a product convenience |
| Anonymous onboarding/session | No registration wall, recoverable anonymous workspace | Actual refresh race/adoption failure tests; same identity semantics as iOS |
| Team seats/invites | Brokerage/office roster and join flows | Concurrent last seat, stale JWT, membership removal and personal-org preservation |
| Plans/purchases | Same server entitlement; native purchase handoff | No invented browser Stripe ledger; no ASC change |
| Camera/photo library | Upload instead, browser capture only where verified | Permissions, supported formats and true unsupported-state UX |
| LiDAR/RoomPlan | Capture-only, upload instead | Do not impersonate measured geometry from a browser photo |
| Spatial Phase A | Native capture only | Owner must see real reconstructed room on phone before Phase B–E product work |
| Floor plan | Import/view/edit existing exports | Units/provenance/measurement labels, keyboard editor and export tests |
| Local drafts/recovery | Persistent browser drafts and transfer records | File re-permission, eviction, logout/account switch, tab racing |
| Review/approval/governance | Versioned coordinator review and locked brand hierarchy | E11 schema/RPCs absent; approval bound to current hashes and revocation |
| Two links/QR/download/player | Existing tour-host output | Actual branded/unbranded URLs serve same approved media; revocation/cache tests |
| Settings/deletion/analytics | Same privacy/cleanup state and governed events | No destructive production tests; all four analytics contract locations |
| Provider probes/funnel | Restricted operations-only reports | Separate AdminProbeAPI/AdminFunnelAPI outside APIClient; no paid probes in tests |
| Gear catalog | Curated capture guidance and validated disclosed affiliate links | GearStore's separate transport, cache and URL validation need parity fixtures |

## Per-row completion receipt required

Each row must eventually link the source commit, exact executed command, nonzero-failing
harness, fixture identity (no credentials), positive and adversarial result counts,
unskipped tests, browser/device/version and any live route receipt. `planned`,
`native-handoff`, `upload-instead` and `deferred-owner-gate` are not passes.
Capture-only alternatives need an actual usable handoff and supported import, not text.

The complete browser walk is create → upload/edit → review → publish → both links.
Run as an anonymous owner, identified solo owner, ordinary team member, marketing,
removed member and cross-tenant outsider. Verify low-privilege direct Data API denial
separately from route denial. Do not test destructive cases against production.

## Offline foundation gate

```sh
python3 tools/web-client/verify_foundation.py
python3 tools/web-client/verify_foundation.py --inject-fault missing-upload
python3 tools/web-client/verify_foundation.py --inject-fault low-contrast
python3 tools/web-client/verify_foundation.py --inject-fault no-op-validator
```

First command must pass, last three must exit nonzero. These validate the inventory and
tokens only; they do not run a browser, establish feature parity, or fix tenancy.
