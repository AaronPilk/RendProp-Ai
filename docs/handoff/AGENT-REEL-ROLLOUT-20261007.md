# Agent reel budget headroom — 7 October 2026

Delivered: the exact `fe0a59c` source passed all twelve hosted CI jobs in
[run 37565928915, attempt 1](https://github.com/AaronPilk/RendProp-Ai/actions/runs/37565928915).
One selected deployment moved `ai-copy` from v20 to **v21 ACTIVE**, with JWT
verification enabled. Returned runtime source, other function metadata and
provider-route rows passed the before/after checks. Internal TestFlight 46
remains the native build to test. Public paid launch remains gated below.

The agent-reel request previously asked Astra for 700 visible tokens while its
combined reasoning/output cap was also 700. The fixed caller contract asks for 500, and
the complete provider JSON must fit within 500 UTF-8 bytes. Request-local photo
aliases and compact window tuples keep all twelve cutaways representable;
optional captions share a 240-byte budget. The server restores original photo
UUIDs and the existing client response, with timing and motion preserved.

The parser requires every planned window exactly once and refuses oversized,
incomplete or malformed replies. It does not salvage a prefix of a broken JSON
reply. The existing provider limit of 700 and reservation for the configured
actual cap are unchanged. Handler tests also cover an Anthropic route configured
at 900 despite the caller's smaller visible-answer request. No route, tariff,
plan price, SKU or funded allowance changed.

Source is isolated on `fix/agent-reel-headroom-20261006`, commit
`fe0a59c1581370623430edf5c707056effd521b4`. Its deployment closure is the same
22 source files / 21 runtime files frozen at `5b866f5`; later commits repaired
verification consumers and included the earlier release documentation. All
native executable inputs remain those of available internal TestFlight 46.

## Verification

- The actual twelve-job hosted run succeeded on `fe0a59c` and tree
  `5e74783f17aeb9fdb992ebe8d09cecaad01d923c`. All twelve checkout logs bind
  merge `efac343a9119cd6ceb8dd0e519d72749420e306f`, whose tree matches.
  Hosted fresh/replay SQL passed 270 each; Deno passed 1,662 with zero failures
  and one existing ignore, plus 61 style/seat cases.
- Hosted browser playback passed two runs of 203 assertions. Three deliberate
  chapter/Explore faults were rejected. Actual synthetic HD encoding and MP4/AAC
  export checks passed, including two HD guard-removal controls. These software
  fixtures do not establish physical-camera or paid-provider quality.
- 45 focused handler/parser tests and type checks passed. The full retained
  backend suite passed 1,662 tests, with one existing ignored case.
- Eight actual guard-removal controls detected the relevant defects. The main
  disposable database applied 110 migrations and replayed 91, with all 270
  invariants passing in both phases. No known-red allowance remains.
- The unchanged style-policy suite passed 101 positives and seven mutants after
  its fixture switched to the new private wire format. Expanded client EDL was
  byte-identical to the prior fixture. No assertion or test count was reduced.
- Four active audit consumers were repaired after actual hosted CI rejected
  all-270 success under their obsolete expected-failure gates. Each current
  whole local harness passed; each executed a private SQL copy restoring only
  the former headroom failure and rejected its 270-row/exit-3 result. Normal and
  optimized Python checks each passed four positives and twenty negatives.
  The current CI caller scan found no additional stale positive expectation;
  historical tools and handoffs were preserved.

The four-harness proof binds 156 unique current inputs and 666 retained producer
files. One earlier brand polling-command snapshot reused a filename; its
overwritten version is explicitly unavailable. All acceptance-critical positive,
negative, race and source logs remain verified. Earlier failed/cancelled hosted
runs remain historical evidence, rather than being relabeled successful.

## Hosted browser failure retained

Run `37558351257`, attempt 1, tested the exact `793ef9a` tree through merge
checkout `2559158683f8b064cbdb3c50bdb7cd4f9aca47e7`. Eleven jobs succeeded;
the native audit job failed at the published-listing browser step. Its actual
four-second condition required the media clock to advance, rather than merely
reporting `paused=false`. The failure artifact recorded `currentTime=0`,
`paused=false`, decoded readiness 4, an eight-second synthetic source, and no
page error. Its pause anchor and ended state were not recorded; the root cause
cannot be reconstructed from that artifact. Later skipped steps are not passed.

Independent original-source local runs passed all 203 assertions. A separate
natural-end-of-file control exposed a fixture flaw: native playback correctly
restarts at zero, while comparing against an earlier end-of-file anchor makes
advancement beyond that anchor impossible. That control does not explain the
hosted clock-at-zero failure. A bounded interior playback anchor and retained
failure diagnostics are implemented in the fixture; the original clock timeout, pause/seek
requirements, and production-defect controls remain required. No unsuccessful
result has been discarded or renamed successful.

## Fixture and development dependency repair

The exact fixture patch passed three local positives with all 203 original
checks each: ordinary playback, a genuine completed clip before setup, and the
existing delayed chapter observation. A real playback-rate-zero control kept
`paused=false` and its clock at one second across 241 polls and failed the
unchanged four-second condition. All eight existing production-defect controls
also failed their intended boundaries. The original hosted cause remains
unknown; local Chrome 154 / Node 25 evidence is distinct from hosted Chrome 152 /
Node 22. The one-second pause anchor and bounded passive event/poll diagnostics
are test code. Production player source, focus dispatch, seek coverage and
original timeouts are unchanged. CI now retains `playback-clock.json` alongside
its existing artifacts.

The two development toolchains now pin Wrangler 4.148.0. A version-scoped
Miniflare override selects Sharp 0.35.5 because Miniflare still pins 0.35.4;
this is an explicit patch override of the vendor pin. Studio resolves the
already-allowed source-map-js 1.2.2 patch. Direct runtime dependencies and npm
scripts are unchanged. Both exact lockfiles installed unchanged with scripts
ignored, and both full audits reported zero vulnerabilities. Worker typechecks,
checks, dry-bundle controls and assets passed; Studio passed 461 tests and its
typecheck/build/dist checks. Actual native Sharp synthetic image round-trips and
a loopback Miniflare smoke test passed. The newer Worker types satisfy Wrangler's
updated peer requirement.

The audit findings were in development tooling; the retained deployed Worker
bundle did not include those dependencies. Initial partial-copy Studio fixture
failures, two probes using an obsolete Miniflare API, and the Wrangler-only
candidate that remained vulnerable are retained. They are not relabeled passes.
The final local acceptance binds 652 committed source inputs plus the four
intentional package overlays. The separate hosted gate subsequently passed all twelve jobs on this exact source.
Remove the scoped Sharp override only after the selected upstream Miniflare pin
resolves the patched version and the lock audit and toolchain checks pass.

## Actual server delivery

| Check | Actual result |
|---|---|
| Selected deployment | One attempt, `ai-copy` v20 → v21 ACTIVE, JWT enabled |
| Returned source | All 21 mandatory runtime files match the frozen 22-source-file closure |
| Other functions | All 24 complete metadata records unchanged across this operation |
| Agent-reel routes | All four ordered rows, provider caps and prices unchanged |
| Unauthenticated request | GET returned 401; no authenticated generation attempted |
| Trial state | OFF; zero sponsor pools, serving schedules, bounded grants or purchase reservations |
| Financial writes | No trial funds, route updates, prices, SKUs or application DDL writes |

The closure also brings this function's shared R2 HEAD helper to the optional
abort-aware signature already present in the frozen `7f5879e` source. The current
provider caller supplies no signal, preserving its existing dispatch behavior.
This source synchronization is separate from the open public-media/cache cutover.

Retained private receipt hashes:

- Actual twelve-job CI: `0e8209b3527bf2e935f475fcebd031053c64c9d6d33b6a61cb216bd4ce58acb5`.
- Actual single-function rollout: `3ab68510af599ca2d24296a69f9f190aa5d4e0b4c50c00003a9abf3461f47e60`.
- Independent actual rollout acceptance: `493960b2e919f1a66ba339972045cdf803224b4ffbb19fc889ef1b1ff6528f5c`.
- Latest beta readback: `201de68f8ad5978199b19966b41bbe0c71bfd8c12dd3c0498a40be74e10c5349`.
- Read-only current trial dormancy: `5a086a715cd8fb27e76d9e6bd280731aa8fe09a0d648c1751ac87bb30c5eb71a`.
- Unauthenticated 401: `0590a52fc50ba7b35021b40e822e532f7f5c95309008b4dbb6332291710175af`.

## Separate launch gates

There is no paid provider quality canary in this work. Budget/parser tests and
returned deployment bytes do not establish real generation quality. No GPU job,
new iOS archive/upload, public App Store/App Review submission, purchase offer,
trial funding or serving schedule is created by this fix.

[Internal build 46](TESTFLIGHT-46-AND-DORMANT-TRIAL-ROLLOUT-20261006.md) and Studio
remain the delivered client checkpoint. [The phone checklist](PHONE-ACCEPTANCE-TESTFLIGHT46-20261006.md)
is still unchecked: real camera/room capture, downloads, private Team identity,
cross-device edits and StoreKit behavior need the owner's device. All 52 beta
reports remain reconciled, with no new or changed reports in the latest five
successful Apple GETs at 7 October 2026, 03:49:23 UTC.

Trial configuration remains OFF and new build-46 ordinary paid checkout remains
closed pending complete funding admission. The 100/200/400 paid photo promises
remain financially uncertified. See the [pricing decision sheet](PRICING-DECISIONS-20261007.md). The owner-approved target is 75% after Apple's
fee, excluding acquisition advertising; AI-provider costs, storage, delivery, compute, email,
support, retention and uncertainty must fit within the remaining 25%.
Protected public-media/cache cutover remains a separate open gate.

The build-46 release record and its historical 269/270 SQL result are preserved
as the earlier source checkpoint; this later strict-270 result does not rewrite
that record.
