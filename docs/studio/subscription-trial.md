# Limited subscription trial — 6 October 2026

The owner approved a trial lasting seven days or until its included usage is
consumed; funding and activation remain unapproved. The implementation is in
available internal build 46, the dormant backend deployment and verified Studio
files. See [the delivered checkpoint](../handoff/TESTFLIGHT-46-AND-DORMANT-TRIAL-ROLLOUT-20261006.md).
Configuration is OFF, no sponsorship/pools/schedules are seeded, and new trial
offers are unavailable. The actions below describe dormant policy, not a funded
signup promise:

| Included action | Lifetime trial allowance |
| --- | --- |
| Hosted walkthrough using captured or imported footage | 1 |
| AI photo edit credits | 5 |
| Distinct published listing | 1 |
| Upload reservations | 1 GiB total |

The three action counters are independent. Using the walkthrough does not consume
the photo edits or prevent the first listing from being published. These are
lifetime trial counters, not monthly paid-plan allowances. An AI photo edit credit
is an admission allowance; it is not a promise that every provider attempt will
succeed. Provider costs and ambiguous outcomes remain subject to the financial
fence.

The trial requires an eligible Apple subscription confirmation and server
verification. Signing in, choosing a plan in the UI, restoring a purchase or
changing workspaces cannot create another allowance. Apple's verified expiry
sets the time limit. Exhausting an action stops new work for that action; it does
not advance Apple's billing date. The customer can manage or cancel the Apple
subscription separately.

Saved originals, edited versions, history and downloads remain available under
their access and retention rules. Published links follow the approved hosting
terms, including the prospective 90-day grace period after expiry. Existing
testers keep their prior policy. Owner and explicitly sponsored private testing
are separate from a public trial.

Studio and iPhone decode the same additive `/me` trial counters, bound to the
returned account and workspace. Missing trial data preserves compatibility with
older APIs. A disabled trial-offer configuration does not advertise the proposed
quantities. Malformed or mismatched counters do not grant extra usage.

The additive workspace-bound `serving_activation` receipt separates Apple's
recorded subscription from service availability. Studio accepts only the seven
declared authority/available/funded combinations. A missing legacy receipt stays
compatible; a malformed, contradictory or foreign-workspace receipt hides
allowances until a fresh read succeeds. An active recorded Apple paid plan without
service availability shows **Service activation pending**, zero paid caps,
subscription management and restoration links. A recorded active trial with
unavailable service shows pending while retaining its used/cap counters; it does
not offer new creation. Expired/free history and exhausted or expired trial
counters take precedence over that pending label. Saved-work access remains subject to its access and retention
terms. A fresh verified paid renewal restores the normal paid meters.

## Activation gates

Keep the offer disabled until the server implementation, concurrency controls,
actual cross-device flow and verified StoreKit trial have passed. Paid AI and
hosting during a free trial are acquisition costs paid by Rendprop. The owner has
not approved a per-account dollar subsidy or a shared launch funding pool; the
previous $5 and $25 proposals are not authorization. Do not seed funding or
enable this offer based on this document.

Actual provider acceptance, total serving cost, reservation of funding before
promising an Apple trial, and the resulting paid-plan allowance remain launch
gates. The five-credit proposal is not a certified 75% paid margin. No expensive
AI video generation, aerial introduction, upscale or spatial reconstruction is
included in this trial package.

Apple introductory-offer eligibility is not proof that Rendprop has funded the
trial. An eligible purchase must pass a fresh server admission before calling
StoreKit; a missing or disabled `trial_offer` cannot authorize the purchase.
The additive purchase-reservation implementation now commits exact buyer/workspace/SKU funding before StoreKit. An explicit native availability check can POST preparation while GET trial_offer is null; only the returned exact held receipt authorizes the eligible trial purchase. Its sponsor configuration remains disabled/unfunded, and actual Apple acceptance is unproved.
Subscription synchronization must also report a refused financial activation,
while preserving Apple's signed subscription history.

Native build 46 blocks every new live purchase without a freshly validated
held seven-day trial reservation at the actual StoreKit purchase call. This
includes introductory-offer ineligibility, products without a free offer and
direct calls that bypass the paywall. Ordinary paid checkout and new paid plan
changes remain unavailable until a separate admission funds the exact new SKU
before charging. A current paid receipt, manual plan or private testing grant
cannot substitute for that admission. Restore, subscription management and
processing existing Apple transactions remain available. Historical build 45
and public build 42 do not include this new-purchase guard; no App Store product
availability was changed by this internal delivery.

The deployed dormant duration check probes the retained private MP4 object and
records an attestation bound to that exact object before trial publication. A client
duration cannot authorize a longer video. Its maximum is 90 seconds; real
retained-object acceptance is required before activation.

## Verification

Studio's `tests/trial.test.ts` covers absent legacy responses, account/workspace
binding, independent counters across month-end, malformed counters, fresh account
reads, disabled offers and saved-work access after exhaustion or expiry. These
tests use synthetic responses and do not certify live billing, provider quality,
camera capture or deployment.

The current Studio candidate passes 461 unit tests and the existing type, build,
bundle and branding checks, with 28 assets and 339,482 compressed bytes against
the 350,000-byte total budget. Its closed-network browser proof covers eleven
flows, including a 390-pixel-wide trial and pending-service view, active trial
activation loss, expired/free history, exhausted counters, failed allowance
refresh and subsequent paid renewal. The actual deployed-routing verifier also
runs against an isolated build with closed transport, including nine rejection
controls; no external GET is performed by these tests. Earlier 456-test and
ten-flow receipts remain retained as prior source evidence. Local tests do not
describe production or TestFlight availability.

Deploy the bounded-trial, purchase-reservation and trusted-duration migrations in
202500 → 212900 → 213000 order before dependent `me`, Apple notification and
render handlers: every account
read calls the new context RPC. Even with trial activation disabled, the migration
installs the admission guards. New hosted publication requires a funded trial or
existing paid, manual, internal-testing or contract authority. Check that change
against the complete release flow before deploying this separate candidate.
