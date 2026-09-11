# Viewer bundle and interrupted uploads — follow-up

September 11, 2026. Base commit `71f9eb77d866554d9902610f519ef0092cc019d4`.
Integration branch `fix/spatial-upload-release-recovery-20260911`.
**Work in progress. Not deployed, not a new TestFlight build, not a whole-app GO.**

## Independently established

At `2026-09-11T23:38:11.419Z`, root fetched the public asset
`https://rendprop.com/spatial-viewer.js` with TLS verification, redirects forbidden,
20-second request timeout and a 1MiB streaming limit. No credential, customer
record or room media was involved.

- HTTP200, JavaScript Content-Type, exactly26,442bytes.
- SHA256 `cfc2a3ed5da478101618382ca23bd7ec12cc2ff635011ddb09e9999822ea66a5`.
- A fresh Node `vm.SourceTextModule` evaluated the browser module successfully.
- Invoking `decodeSpatialManifest` under a1-second VM execution limit threw
  exactly `ReferenceError: __name is not defined`; the reproduction asserted
  the error name/message and exited0. This is an accepted reproduction of a
  failing live asset, **not a viewer acceptance pass**.
- An independent agent fetched the same byte count/hash at23:37:56UTC and
  reproduced the same error with a valid synthetic manifest fixture.

The bug crosses a build boundary: `spatialModule()` serializes decoder functions
with `.toString()`. Wrangler can inject helper references into those functions
without shipping the helper inside the browser string. Merely importing source,
parsing the returned JavaScript or getting HTTP200 does not execute those helpers.

## Correction to prior proof

The previous private real-room preview imported `spatialPage`, `spatialModule`,
the manifest decoder and SOG guard directly through Deno. It proved that the
source could render the actual room locally, with the listed fixture substitutions.
It did **not** execute the emitted Wrangler artifact. The earlier phrase
"Real production viewer" overstated that proof and is corrected in the older
report and STATUS. The native training renders were also blurry, independently
of this browser bug; fixing serialization cannot restore missing room detail.

## Current implementation ownership

1. `fix/spatial-built-viewer-20260911`: viewer build configuration and a gate
   that actually runs the emitted Worker, requests its browser asset, then
   executes the decoders/runtime. The old/broken configuration must fail.
2. Backend upload recovery: preserve the physical-transfer budget, completion
   winner, exact ticket ownership and one idempotent replacement for an explicit
   Restart. Do not reset counters or blindly redispatch an uncertain write.
3. iOS upload recovery: preserve local media and recovery intent, distinguish
   Retry from Restart, expose errors for photos/video/spatial, and stop new
   scheduling on Pause without cancelling writes already dispatched.

These are implementation goals until replaced with commands/results below.
Source fixes must be integrated and tested together; a new client must not be
distributed before the corresponding recovery route/migration is deployed.

## Unchanged limits and delivery gates

- No production data deletion, bulk ticket cancellation, feature enablement,
  new GPU allocation, Cloudflare/Supabase deployment or Apple action in this pass.
- The paired0039 deletion handler/migration and0041 provider journal remain
  separate deployment obligations. A tip handler dependency is not evidence
  that the older live handler is currently down. No production `DELETE /me`
  will be used as a test.
- The last known production spatial runtime is disabled with zero budgets.
  The deployed Modal controller is deliberately disabled; no new live readback
  of either is implied by this document.
- Training still has7000-iteration and1800-second ceilings in schema and code.
  A25000-step run requires deliberate reviewed changes, not just a larger CLI
  argument. More iterations are not established as sufficient for quality.
- The pending App Review submission and existing internal TestFlight builds are
  untouched. Source fixes do not update the owner's installed app.

## Results

Pending implementation and independent integration tests. Retain failures and
exact command receipts here; do not substitute another agent's claimed counts.
