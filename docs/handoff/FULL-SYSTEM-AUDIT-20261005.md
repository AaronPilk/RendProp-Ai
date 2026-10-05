# Full-system audit follow-up — 5 October 2026

## Release status

This is **source remediation and regression evidence, not a production deployment
or a signed TestFlight upload**. The work is isolated on
`fix/full-system-audit-20261005`, based on `f64c842`. Claude's shared checkout was
not edited. This branch includes the earlier debugging, beta-feedback and private
testing branches; their delivery receipts remain the authority for what is live.

The installed internal release is still **1.0.4 (44)** and the last verified public
release is **1.0.3 (42)**. Neither contains all changes in this follow-up.
The existing explicit owner/family testing grants are preserved. Joining the
owner's testing team does not grant access to the owner's or another tester's
listings. Retail plan prices, quotas and membership roles are unchanged.

**NO-GO for a broad team launch or an App Store submission from this source.**
The critical outstanding gates are private media delivery/revocation, the App
Review Sandbox account workflow, complete serving-cost allocation, and reviewed
legal publication. Passing local checks does not close those operational gates.

## Confirmed changes

- Photo mutations move behind service-only, actor/org/listing-bound RPCs. The
  server derives known edit disclosures from authoritative provenance and retains
  compare-and-set caption/cover/gallery behavior. Member reads remain available.
  Native build 44 uses the existing capture-asset gallery path, not direct photo
  table writes. Brokerage price/quote helpers lose unintended public execution.
- Verified Sandbox receipts cannot change live retail Apple plans. Only an
  existing explicit internal-testing authority admits Sandbox testing; otherwise
  the response is `sandbox_testing_required`. The native client retains the
  pending transaction for recovery. TestFlight and App Review both use Sandbox,
  so a separate reviewed App Review account/allowance workflow remains required.
- Video admission binds the charged monthly and burst windows to an owned job.
  Refunds address those immutable windows. Old-month reservations cannot consume
  a fresh month's budget, and unknown provider outcomes retain their money hold.
  A timeout is not evidence of a free attempt or permission to submit again.
- New video status links are signed for the submitting actor and the admitted
  listing. Unsigned legacy status requires an owned provider-job record. AI photo
  and video storage record exact cleanup intent **before** the object PUT; listing
  scope comes from admission, never status-client input.
- Automatic global CRM export is removed. Cleanup inventory retains legacy
  email and phone identifiers only while cleanup is outstanding. Lead deletion
  is selected-workspace scoped and cancels queued buyer payloads. Completed
  cleanup scrubs buyer identifiers and prunes acknowledged output journals.
- Ordinary notification email uses the confirmed Auth email. Client forwarding
  requires the current listing recipient to confirm a revision-bound, expiring,
  one-use token. Opening the GET link never confirms it; explicit POST does.
  Studio and native client editors expose the verification action/status.
- Promotional email is disabled, including queued messages, until opt-in and
  unsubscribe are implemented. Transactional notices preserve preferences.
  Email uses `RendProp LLC`, `855 Central Avenue, Saint Petersburg, FL 33701`
  and Reply-To `aaron@pilk.ai`.
- Upload admission derives a technical monthly ingress ceiling from existing
  feature allowances and requires named identity or verified Production-paid
  guest authority. Replays and explicit internal grants are preserved. Cleanup
  scheduling is source-only; it must receive a read-only live inventory before
  any live sweep. These ceilings do **not** establish profitability or a funded
  retention policy.
- Native changes preserve active forms during load, queue modal deep links,
  elect the visible local paywall host, allow ordinary photo browsing without
  AI consent, retain empty Reel setup while adding photos, scope cellular retry
  approval, restore archived state and show offline player recovery.
- Studio catches lazy-module/render failures with explicit reload recovery.
  The React root uses a fixed safe caught-error message; private error content
  does not leak through React's independent console logging.
  Missing assets return 404 rather than SPA HTML. The known auth callback retains
  its query on the canonical root. CSP permits the exact existing public R2 host;
  this compatibility fix is not private delivery or URL revocation.
- Hosted portfolios are noindex and exclude private-link-only and client-mode
  listings. Discovery and media approval are rechecked after asynchronous work.
  Native string-valued `allow_indexing: "true"` is preserved. Hosted portfolios
  still need their own deliberate, per-member listing selection; the native
  selected HTML export is already separate.
- Public page partner promotions default off. Financing requires the owner's
  explicit lender details; the invented fixed-rate mortgage estimate is removed.
  Canonical HTTPS/apex routing now includes static files, and shared response
  headers also cover spatial routes. Malformed join encoding fails as 404.
  SQL-generated new slugs use cryptographic UUID entropy; old links are retained.
- Unexpected shared RPC failures, public beacon failures and portfolio database
  failures return generic unavailable responses. Beacon JSON is bounded to
  16 KiB. This is not a claim that every legacy error site has been sanitized.

## Review of every numbered Claude finding

“Source fixed” means implementation exists on this branch and has regression
evidence. It never means delivered. “Partial” or “open” remains a launch limit.

| # | Subject | Disposition |
| --- | --- | --- |
| 1 | Global CRM, consent, phone cleanup and lead delete | Source fixed; promotional email disabled rather than claiming unsubscribe exists. |
| 2 | Media deletion and permanent public URLs | Partial: durable listing/account output inventory and completion cleanup. Existing direct public R2/Stream URLs still require a delivery cutover and revocation proof. |
| 3 | Indefinite video holds | Window isolation/refund authority source fixed. Unknown paid outcomes intentionally stay held pending reconciliation. |
| 4 | Sandbox creates real plans | Source fenced. App Review test-account authority is an explicit remaining release gate. |
| 5 | Source/live migration drift | Read-only alias guard and captured ledger metadata added. No history repair or bulk migration push; SQL equivalence and staged rollout remain required. |
| 6 | Guest ingress and missing sweep | Technical admission/sweep source added. Retention allocation and live inventory/dry-run remain open. |
| 7 | Direct photo mutation strips disclosure | Actor-bound expand/contract RPCs and client ACL restriction source fixed. Deployment order matters. |
| 8 | Published legal pages lag subscriptions | Exact source-generated revised draft prepared; publication still needs review and matching deployed behavior. |
| 9 | Default promotions and invented mortgage estimate | Source fixed: explicit promotion/lender intent, no fabricated payment estimate. |
| 10 | Fair-housing semantic/language/split-field bypasses | Open. Existing lexical/prompt guards are not a semantic or multilingual compliance guarantee. |
| 11 | RoomPlan entry/scan state | Native entry is capability/experimental-state gated and existing rescan confirmation retained. Real furnished-room quality remains phone acceptance. |
| 12 | Image/reel provenance and export metadata | Earlier version/export safeguards preserved; not every re-upload/export route has a complete durable disclosure guarantee. Partial. |
| 13 | Hosted portfolio auto-collects workspace | Private/client listings excluded, noindex restored. Hosted per-member deliberate selection remains open. |
| 14 | Legal entity/providers/duties/acceptance | Entity, address, processor and user-duty draft updated. Notice review and versioned acceptance evidence remain open. |
| 15 | Email address/Reply-To/opt-out | Source postal footer and Reply-To fixed; promotional email disabled. Opt-in/unsubscribe remains unbuilt. |
| 16 | Editable email used as delivery authority | Confirmed Auth and revision-bound client verification source fixed. Real inbox acceptance remains separate. |
| 17 | Demo/onboarding friction | Earlier interactive guide retained; native onboarding/guide path improved. No fabricated tap-count claim. |
| 18 | Cellular publication retry | Explicit approval stays bound to the queued workspace. Source fixed. |
| 19 | Tab identity resets forms | Readiness uses established identity without resetting the whole TabView. Source fixed. |
| 20 | Gallery unnecessarily requires AI consent | Ordinary gallery opens; AI action still requires consent. Actual mocked UIKit case passes. |
| 21 | Join before root load | Join waits for root readiness. Source fixed. |
| 22 | Modal Upgrade does not present | Local visible host chosen; actual quota→paywall→dismiss→same Reel UIKit case passes. |
| 23 | Nil scope/cached houses/duplicate Home | Earlier identity fences retained and establishment/reset behavior tested. No customer listings deleted. |
| 24 | Empty Reel cannot add media | Actual modal Add photos return retains the same setup; no automatic generation. |
| 25 | Modal/deferred links dropped | Bounded deduplicated queue waits for presentation readiness. Source fixed. |
| 26 | Offline player black screen | Native loading/failure/reload UI added. Real network/device acceptance remains separate. |
| 27 | Archive/zero-value restoration | Archive DTO/merge restoration fixed. Existing raw-zero facts CAS was already correct; preserved. |
| 28 | Studio CSP/chunk failure/Apple web secret | CSP, real 404 and recovery source fixed. Apple web secret expiry/rotation monitoring remains open. |
| 29 | Raw backend errors | Shared/public affected paths sanitized. Legacy sites remain; no blanket closure claim. |
| 30 | Leads/counts/habits/notification permission | Earlier diagnostic denominators retained; no new broad permission/count redesign in this pass. |
| 31 | Studio non-real-estate fields/copy | Open product work. Existing backend industry scope is not complete form parity. |
| 32 | Native real-estate-specific labels | Earlier terminology work retained; remaining industry-specific screens remain open. |
| 33 | Public real-estate labels | Promotion/finance now housing-only. Complete industry page parity remains open. |
| 34 | Notices/MLS/no-marketing messaging | Public lead copy no longer implies marketing consent. Complete MLS/industry notice review remains open. |
| 35 | Contrast/theme | Existing appearance fixes preserved. This pass does not certify all native contrast or accessibility states. |
| 36 | Marketing logo/Open Graph | No new asset redesign or deployed scraper acceptance in this pass. Open. |
| 37 | Experimental prompt library/research links | Preserved as experimental; recipes are not validated provider-output capabilities. Product presentation remains open. |
| 38 | Names/terminology | No wholesale renaming in this risk-focused patch. Open product cleanup. |
| 39 | Disabled button styling | No blanket styling closure. Open. |
| 40 | Git authorship/history naming | Existing history untouched; no rewriting another contributor's commits. |

Additional Tier-5 items: malformed joins, protocol-relative asset URLs, lead
existence-oracle payloads, public spatial headers, cryptographic SQL slugs and
immutable quota refunds receive source corrections. Session/draft retention,
broader CSP/CDN controls, distributed endpoint limits, Turnstile hostname/action,
full GPS/coordinate minimization, data export/security contact, and complete cost
allocation are still open. The claim that a short cache TTL alone lets ordinary
video double-charge omitted its existing permanent SQL idempotency tombstone;
that authority is preserved, with recovery made actor-bound.

## Local evidence and limits

Private receipts live under the local full-system audit evidence directory; raw
tester reports, keys, customer rows and images are not committed.

- Photo authority: 29 fresh and 29 replay SQL assertions, 5 separately compiled
  semantic faults; actual Studio RPC adapter tests.
- Billing/Sandbox/slugs/brokerage: the follow-up proof passes 81 fresh and
  81 replay SQL assertions, the original 5 compiled faults and 17 compiled ACL
  controls, both real quota-window race orders, guarded-definition no-overwrite
  and security metadata equality. It reproduces the previous three-helper ACL
  omission and proves real service contract/entitlement/quote callers still work.
- Native UI: three actual mocked Release UIKit cases, 0 failed/0 skipped.
  They use the real gallery, Reel and paywall presentation but no camera,
  picker, StoreKit purchase, real API or provider call.
- Native pure/source-bound gates cover UX, workspace allowances, profile,
  adoption, subscription handling, lead privacy, photo reconciliation and Reel
  recovery, including separately compiled semantic controls.
- Backend: 1,521 tests passed, 0 failed, 1 ignored. The ignored local-SQL
  presenter-controller case passed separately against disposable Postgres
  (119 database checks plus the actual controller lifecycle). It remains ignored
  in the unit-suite count. All 25 edge-function entrypoints typecheck.
- Recipient verification: 58 fresh/replay SQL assertions and 7 compiled faults.
  Cleanup: 61 fresh/replay assertions and 9 faults. Upload admission: 19
  fresh/replay assertions and 4 faults. Photographer delivery: 61 assertions
  on each schema and 4 real overlap checks. The combined privacy adapters
  pass 111 tests; the actual Studio editor passes 10 browser flow checks.
- Studio: 442 unit tests and production build/size gate. Nine actual production
  React recovery behaviors in a closed-network browser fixture, including
  a signed-URL error sentinel. Both draft-loss and unsafe-root compiled controls
  fail at their intended assertions; storage is seeded only once.
  Real pinned Wrangler local routing verifies missing-file 404, callback query
  preservation and served security headers. The build gate reports
  `connectedConfigVerified: false`; no production connection claim follows.
- Tour host: actual renderer/routes/upstream/lead/legal/client/spatial/bundle
  checks pass. The dry-run bundle is not a deploy and spatial fixtures are not
  trained-room output.
- Migration guard: exact live metadata capture, 84 recorded versions, and
  deterministic name/version collision tests. The known private-testing source
  migration is recognized under its actual live version and refused for reapply.
  A matching name or recorded digest does not establish SQL/schema equivalence.

Both unsigned physical Release variants (ordinary App Store and internal lab)
compile from the final frozen native source. Neither Mach-O binary contains the
simulator quota fixture. These are builds, not signed archives or uploads.
Full database verification passed on clean source commit `77afb02`: all 103
migrations apply, 84 replay at their supported historical points, and both
270-invariant runs have 269 passes plus the same single documented Astra
ceiling exception. There are no unexpected failures or stale exceptions.
Actual publication and corrupted-Team negative controls fail as required;
all owned clusters stop. The assertion and provider ceiling remain unchanged.

Final combined regression and physical-build receipts are recorded separately
under the private evidence directory. Earlier failures (disk exhaustion, an obsolete
allowance fixture and an invalid nested-toolbar test selector) are retained;
they are not counted as successful runs.

The previous private-testing PR's CI failures were also investigated. Team
readiness now requires all 21 distinct handler tests, with no ignored, filtered
or missing result, rather than the stale 12-test summary. Its 34 fresh/replay SQL
assertions, two real races and eight compiled inventory controls pass. The
measurement harness keeps its runtime deadline and exact semantic rejections,
but allows the compiler enough time for the hosted runner; baseline 140 assertions
and the first affected `drop-wire` control pass. Compiler/runtime timeouts retain
partial diagnostics and a failed receipt. Privacy proof receipts mark success
only after final source checks; four actual-runner groups detect file drift and
reordered-success mutations. No runtime or quota was weakened for these repairs.

The first PR 30 run exposed three more proof/inventory defects: draft-sync
extraction omitted the real context predicate, the API inventory omitted two
new methods, and workspace selection expected 28 handlers instead of 31.
The repaired draft-sync gate passes 245 assertions and three compiled semantic
controls; the related photos-first lifecycle gate passes 264 assertions,
reproduces the historical discarded-edit defect and rejects three compiled
regressions. All 146 native runtime inputs remain frozen. Workspace selection
passes all 31 handlers, 28 fresh/replay SQL checks, both races and both existing
controls. Its actual inventory parser also refuses 12 defective result variants
and detects two compiled guard removals. The complete 72-method/73-declaration
API inventory passes 17 checks and its three named controls. None of these
inventory repairs establishes browser parity, camera quality or a live rollout.
The separate manual upload gate also had an obsolete 100-case total. It now
passes all 114 actual transport/publication cases, the Worker adapter typecheck
and the compiled final-byte stream control. Its inventory proof separately
rejects 12 defective outputs and detects two compiled guard removals.

## Media-delivery compatibility and finite review authority

The remaining media gate cannot be closed by turning off one public domain.
Build 44 validates private library downloads as R2 S3 SigV4 URLs, with at most a
600-second lifetime, and downloads without API headers or redirects. Preserve
that contract. Its AI completion downloads also need header-free signed URLs.
Studio's generated-result import adapter currently rejects R2 S3 result URLs;
change it with the output-serving contract. Public pages need a byte boundary
that resolves the exact published media identity and checks current approval
on GET, HEAD, Range and conditional reads. An ancestry check or key prefix alone
is not authority. Stream requires its own protected playback/segment strategy.
Inventory every legacy reference and prove old URL denial before disabling all
public R2 ingress; existing downloaded copies cannot be revoked.

App Review access likewise needs separate finite actor/workspace authority.
Sandbox renewal, Restore, reinstall, calendar rollover, quota refunds and plan
changes must never replenish its lifetime budget. Existing owner and sponsored
family grants are unlimited and cannot supply that boundary. A small expiring
monthly entitlement alone is insufficient: every allowed provider attempt,
including retries/helpers/queued work, needs pre-dispatch admission. Unpriced
review actions must refuse dispatch. Provisioning a real review account, window,
feature allowlist and funded budget remains an operational input; no such grant
was created in this audit.

## Follow-up review: complete brokerage ACL inventory

Claude's review of `27f5412` correctly found that the pending brokerage ACL
migration covered only three internal functions. The complete inventory also
includes `brokerage_cogs_ceiling_cents(brokerage_contracts)` and
`brokerage_contract(uuid)`. The latter's invoker mode and deny-all table policy
already prevent direct client rows; that does not justify leaving its execute
permission open. Existing service-only `brokerage_overview(uuid)` and the
contract writer also need their ACLs preserved by the proof.

The reviewed rationale misstated `effective_plan(uuid)` as SECURITY DEFINER.
Current source keeps it SECURITY INVOKER and reads the contract table directly;
`org_entitlement(uuid)` calls the contract/COGS helpers. This repair must preserve
those function bodies, owners and security modes and prove service entitlement
reads still work. The earlier full database receipt is historical evidence until
the revised ACL migration receives a new complete regression receipt.

## Pricing gate: current allowances are not yet funded

The [Topaz and margin policy](TOPAZ-AND-MARGIN-20261004.md),
[pricing audit](../PRICING-AUDIT-20261003.md) and
[allowance proposal](../PLAN-ALLOWANCES-20261004.md) remain applicable. The current
retail source was rechecked; no prices or quantities changed in this audit.
The owner confirmed Small Business enrollment, but the effective commission date
is not verified. The conservative 30% case remains relevant until that is known.

At an effective 15% fee, the following are the maximum **total monthly serving
costs** allowed by the owner's target, rounded down to cents. The provider ceiling
already exceeds that entire envelope, before storage, delivery and other costs.
Annual proceeds are allocated across twelve service months.

| Sold product | Customer price | Current provider ceiling/month | Maximum all serving costs/month at 15% |
| --- | --- | --- | --- |
| Starter monthly | $49/month | $12 | $10.41 |
| Starter annual | $490/year | $12 | $8.67 |
| Pro monthly | $99/month | $24 | $21.03 |
| Pro annual | $990/year | $24 | $17.53 |
| Team monthly | $249/month | $60 | $52.91 |

The formula is `0.25 × recognized net receipts`; actual proceeds adjustments,
refunds, offers and currency conversion can reduce funding. Feature counts are
pooled and do not promise that every combination fits the current provider cap.
Fixing reservation/refund authority does not fix collected-revenue funding.
The 75% floor is still unenforced: it needs a shared pre-dispatch money gate,
proceeds-based period accounting, measured recurring allocations and invoice
reconciliation. The existing weighted-credit proposal is unapproved. These are
source-model scenarios, not actual margin results or authorization to reduce
existing customer commitments. Internal testing remains separately owner-funded.

The follow-up review's proposed `$10 / $21 / $53` provider limits are insufficient
to enforce this target: they do not reserve the other serving costs, omit the
lower annual envelopes, and `$53` exceeds Team's entire `$52.91` envelope. There
is no evidence here that typical usage remains below the cap. No ceiling was
changed or declared profitable on that basis.

## Deployment and remaining decisions

1. Reconcile prior-stack dependencies and live schema definitions before any
   mutation. Do not run bulk `supabase db push`: earlier migrations have live
   timestamp aliases and some historical rows lack statement digests. The
   read-only `tools/deploy/check-migration-ledger.mjs` never approves SQL writes.
2. Apply the photo RPC **expand**, deploy the exact Studio adapter bundle, then
   apply the photo ACL **contract**. Deploy the corresponding immutable video
   quota RPC/handler and notification/cleanup contracts together; older-client
   compatibility must be checked against the actual live schema.
3. Deploy the client-recipient confirmation route and its asset before sending
   verification email. Confirm GET is inert, POST single-use, no buyer data is
   included, and the old forwarding path cannot bypass verification.
4. Inventory legacy AI/presenter objects, queued notifications and pending
   uploads read-only. Review the dry run before any live cleanup. Shared team
   content is not treated as solely owned account data.
5. Complete authenticated/private media delivery, legacy reader/provider
   compatibility, Range support and revocation checks before disabling the R2
   public domain. Do not break current tours by disabling it prematurely.
6. Resolve App Review Sandbox authority with a bounded reviewed test account;
   do not manufacture a retail Team subscription or reset money limits from a
   receipt. No new review grant is active in this patch.
7. Allocate all serving costs against the owner's 75% margin target **after
   Apple's fee**, including retained storage, requests, voice/chapters, failed
   attempts and discounts. Feature-derived ingress caps are not a profit model.
8. Review the [exact generated legal draft](../legal/RENDPROP-LEGAL-NOTICE-DRAFT-20261005.md).
   The existing source publication guard requires review of effective date,
   notice, provider terms and retention evidence before publishing revised policy
   text. The owner's supplied business facts do not establish provider contracts.
9. After those gates pass, use a new signed archive and coordinated backend/web
   rollout. Physical camera quality, generated media quality, measuring accuracy,
   purchase/restore and phone-to-Studio acceptance remain real-device tests.

Spatial runtime values, training/capture plumbing and provider training gates
are unchanged. No GPU experiment, paid generation, customer email, customer
deletion, App Store action or new live cleanup was performed in this audit.
