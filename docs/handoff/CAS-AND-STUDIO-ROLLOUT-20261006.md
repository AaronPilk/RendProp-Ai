# Actual CAS, Studio and photo-permission rollout — 6 October 2026

This is a delivered checkpoint, separate from the dormant subscription-trial
candidate. Native and Studio source is `5eeb783125867a8bebbcc7254dd2b09d58ae439e`;
the additive listings/Studio conflict repair is
`4a209d49f9c4151cf9f4a375aae27e29680a05cb`. No public App Store submission or
release was performed. Public 1.0.3 (42) remains unchanged.

## Delivered and verified

- Internal TestFlight **1.0.4 (45)** was verified available by Apple at
  **2026-10-06 19:23:12 UTC**, from `5eeb783`. Its package, source, dSYMs and
  twelve CI jobs are bound by [the delivery receipt](../releases/TESTFLIGHT-45-20261006.json).
- All twelve jobs of [CI run 37521230754](https://github.com/AaronPilk/RendProp-Ai/actions/runs/37521230754)
  passed on the actual merge checkout containing `4a209d4`. Its source tree equals
  the conflict-repair branch; this was not inferred from a different green build.
- The preceding coordinated backend deployment verified all **25 functions**.
  Its 157 staged source files match frozen `5eeb783`, with each function's
  existing JWT policy preserved. `me` keeps gateway JWT verification; the Apple
  notification webhook keeps signature authentication and gateway JWT disabled.
  Private deployment receipt SHA-256 is
  `a0d2397fb8499de57f0c4c58de71028ddf8d249d9b7effe0cf9ae56d2604094d`.
- Live **listings** and **studio** functions returned runtime source closures
  matching `4a209d4`, with JWT verification retained. Stale facts, captions and
  gallery edits now return terminal HTTP 409 instead of entering PostgREST's
  serialization retry path.
- Canonical `20261006193633_cas_conflicts_terminal.sql` was applied once. The
  actual migration ledger records `20261006205216 / cas_conflicts_terminal`.
  Before/after catalog checks preserved all 77 RPC identities, owners and
  arguments; only the three intended conflict bodies changed.
- **Studio** was deployed once, from the existing frozen `5eeb783` assets, as
  Worker version `1d34a9d3-0495-4bab-a354-219496a2238a`, verified at 100% traffic.
  The service is assets-only: remote module download returns HTTP 204 with an
  empty body. There is no JavaScript worker module to compare.
- The public tour Worker is version `3de4f42e-4b18-4722-8e18-15f3fb1ecad2` at
  100% traffic. Its actual downloaded module matches the retained `5eeb783`
  bundle. Protected-reader flags and the managed-public-domain cutover remain
  separate; this module match does not prove cache-rule acceptance.
- The actual served-assets check passed **35 GETs**: 28 bundles plus the entry,
  robots and mark files matched; the configured `/auth/callback` rewrite returned
  the canonical 307 to `/?same-query`; following that exact root URL returned
  the entry bytes. Unknown paths and missing hashed modules returned 404. There
  is no blanket SPA fallback. Sign-in itself was not performed by this check.
- Canonical `20261005215832_photo_authority_acl_contract.sql` was applied once
  after function deployment and the owned API continuation. The actual ledger
  records `20261006210936 / photo_authority_acl_contract`. Authenticated photo
  SELECT remains allowed, while direct INSERT/UPDATE/DELETE and legacy gallery
  execute privileges are denied. The service-authoritative edit path remains.
  The final catalog check preserved 74 non-conflict definitions and 73 complete
  original contracts, with one deliberate legacy-gallery ACL contraction.
- Original cleanup crons remain active; the three new retention jobs remain
  inactive. No retail, trial or App Review funds or schedules were seeded.

## API evidence and retained failures

The original synthetic run remains **failed**: 14 requests, seven application
mutation attempts and an uncertain stale-edit outcome. It was reconciled through
fresh read-only database observations; its uncertain writes were not replayed.
Two fresh sessions were obtained for that same retained account through a
separate four-request authentication renewal. No second account was created.

The subsequent owned continuation passed **39 requests, 20 mutation attempts
and 24 checks**. It verified terminal stale-write conflicts, independent-field
preservation, three tiny finalized uploads, photo attachment/caption/order/cover,
cross-listing rejection, short signed exact-byte media reads and account JSON
export. It touched only the retained synthetic account and two unpublished
drafts. It made no provider call, grant, email, publication, deletion or customer
edit. The fixtures remain retained for traceable follow-up.

After the photo ACL contraction, four additional requests to the same retained
fixture returned 200/200/403/200: a service gallery read, service caption edit,
direct client PATCH denied with PostgreSQL `42501`, and a second-session service
read. The checker itself remained failed because its stable comparison omitted
the refreshed `original_url`. A separate **zero-network** reconciliation checked
all ten current/original capabilities against the exact owned finalized keys,
host-only signatures, 600-second maximum and recorded response expiry, then
confirmed unchanged photo/video metadata and order with only the intended
caption changed. Independent review passed. No request was replayed and the
failed checker journal remains failed. This is one successful synthetic service
edit and one denied client mutation attempt, with no customer or provider work.

A fresh Apple read at **21:26:24 UTC** found no new beta report, changed comment
or changed historical crash text; [the feedback handoff](LAUNCH-BETA-20261006.md)
retains its exact private evidence. Physical acceptance is still separate.

Earlier Studio verifiers also remain failed. They incorrectly expected a remote
JavaScript module, blanket `/workspace` SPA fallback, or callback HTTP 200 instead
of the committed canonical 307. The corrected readbacks record the actual
committed routing contract; they do not rewrite those failed attempts as passes.
The robots response contains a managed prefix, so crawl blocking is not claimed.

Private raw responses, attempt journals and source bindings are retained under
`/Users/pilksclaes/LocalRendpropAudits/launch-20261006`. The scoped checkpoint
receipt is `current-rollout-checkpoint.receipt.json`, SHA-256
`ae0bdbd44c18410a64d205b79507ce07f9bc34c2aaba3269f0d64cc2bdf3d75a`.
The subsequent `current-rollout-final.receipt.json` binds the post-contraction
response reconciliation, its independent review and fresh beta readback, SHA-256
`a362e242717110a5d5f8c08867abf463dbedb39e59f47d651744a85202c7071d`.
Do not copy credentials or signed media capabilities into Git.

## Protected-media baseline, before any cutover

Two read-only phases completed against the current public deployment: an
inventory of eleven published scopes and 21 objects used **64 GET/HEADs**, then
the selected video/poster baseline used **46 GET/HEADs** and received 32,562,480
bytes. The latter compared complete legacy and protected response bytes,
range/conditional responses and retained existing-object negative cases. Both
phases made zero live mutations. Their receipts are SHA-256
`6e24156f39e64578db65fcefe7bcceb7be1d96afd96fa0d76db184d8450ebed5` and
`31bc4220322e2d167f4204ef613be604bd40c6b63d571230f4fcc1f7c008c566`.

These are baseline proofs. No public-reader flag, managed R2 domain, cache rule
or published listing was changed. They do not establish denial of the old public
domain after cutover, withdrawal/deletion/retention transitions or Stream
acceptance. Those gates remain open.

## Still separate launch gates

- [The limited subscription trial](../studio/subscription-trial.md) is candidate
  source, disabled and absent from build 45. The source-file duration guard has
  passed local handler and PostgreSQL controls; it is not deployed. The atomic
  pre-StoreKit hold and native hook are implemented and locally reviewed. The
  current backend suite passes 1,648 tests; disposable PostgreSQL covers 43
  purchase, 61 usage, 63 funding and 31 duration assertions fresh and replayed,
  including real concurrent admission and executed guard-removal controls.
  Native hold tests pass 70 assertions and 23 compiled rejection controls; the
  full Release Simulator target compiles. These are candidate-source proofs,
  separate from funding approval, signed release and real billing acceptance.
  No proposed $5 account or $25 launch subsidy is approved.
- The paid-plan marketed photo bundles exceed the serving budgets supporting
  the owner's 75%-after-Apple margin target. A passing budget guard is not proof
  that a marketed allowance is financially deliverable.
  A separate native follow-up blocks new live paid checkout and plan changes
  pending exact-product funding admission; current plan or private testing
  authority cannot authorize a new charge. Its final StoreKit call requires a
  freshly validated held seven-day trial. Restore and Manage remain available.
  This follow-up needs its own tests, CI, signed build and delivery receipt;
  it is absent from the available build 45 and changes no App Store products.
- Protected media cutover is incomplete. The existing deployment credential
  cannot read Cloudflare cache rules; account sign-in/readback is still required.
  Public reader functions, flags and managed-public access must not be switched
  solely because Studio assets passed.
- Physical camera, spatial capture, measurement accuracy, StoreKit purchasing,
  cross-account team behavior and generated-output quality require real-device
  or controlled provider acceptance. Build availability does not prove these.

Do not bulk-push migrations: recorded live timestamps differ from canonical
source filenames. Keep source commits, ledger aliases and exact runtime receipts
together, and preserve the older dated checkpoints as history.
