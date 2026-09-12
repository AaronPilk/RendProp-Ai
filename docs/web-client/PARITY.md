# Parity inventory — before components

Source baseline: `2ca9c7a`. This is an inventory, **not verified parity**.
Machine-readable truth: `packages/client-contracts/capabilities.json`. Its verifier
compares every `APIClient` protocol method against the actual Swift file, detects missing,
extra and duplicate mappings, and checks paths for capabilities outside that protocol.
There are 53 distinct method names / 54 declarations (two `completeUpload` overloads),
mapped into 15 API groups, plus 24 capabilities outside the protocol.
UI discovery remains a manual review obligation: a method inventory cannot prove every
interactive behavior, accessibility path, business rule or hidden direct call is covered.

| Capability group | Desktop equivalent | Blocking evidence |
| --- | --- | --- |
| Listings/create/edit/delete | Bulk workspace, multi-select, individual failure receipts | Direct Data API ownership/RLS; local-only deletion fixtures |
| Upload tickets/parts/batches/complete/abort/renew/restart | Planned resumable uploader with same-asset renewal and explicit linked restart | Real browser CORS, durable restart intent, account/file recovery, server completion ambiguity and spent-byte accounting; no automatic fresh attempt |
| Spatial jobs/inputs/start/status/review/publish/retry/cancel/resume | Planned browser workspace over the ten shared spatial API operations | Web workspace parity is unimplemented; private viewer availability alone does not prove capture-to-publish or recovery parity |
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
| Spatial capture | Native measured capture; planned browser import/handoff | Browser handoff remains unimplemented; physical-phone capture and real-room reconstruction quality acceptance are separate from API inventory |
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

First command must pass with exactly 16 tests and zero skips. The last three must each
exit 1 for their intended failed assertion. The positive suite also removes
`restartUpload` and each of the ten spatial mappings individually, requiring the exact
missing-method error. Equality, duplicate mapping, source path, contrast and no-op
validator rejection checks remain intact.

This repairs the inventory drift reported by hosted CI run `34662282586`: ten spatial
methods were already missing at `2612c7c`; `renewUpload` added an eleventh omission by
`71f9eb7`; `restartUpload` added the twelfth at this baseline. Registering these as
planned work does not implement them on the web. These checks validate the inventory
and tokens only; they do not run a browser, establish feature parity, or fix tenancy.
