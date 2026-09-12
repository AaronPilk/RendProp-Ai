# Spatial viewer: actual emitted-bundle failure and fix

Base: `71f9eb77d866554d9902610f519ef0092cc019d4`.
Branch: `fix/spatial-built-viewer-20260911`.
Scope: local source/configuration/tests plus one unauthenticated read of the
public JavaScript asset. No deployment, GPU, room upload, production mutation,
or Apple change was performed by this work unit.

**Integration update:** this document preserves the original unit's historical
commands/counts. The root follow-up strengthened the gate: supplied file or live
browser bytes must now SHA-match a fresh build of the reviewed source **before
execution**. Unknown bytes are rejected as deployment drift; Node VM timeouts
are not a security boundary. Current self-test is36 assertions, current matching
file mode33; the broken-config test still rejects the exact `__name` failure.
The full integrated predeploy and a real-room responsive-browser check passed,
but reconstruction remains visibly blurry. The latest live bytes still match
the old broken asset and fail identity verification. See the authoritative
root [work log](../../releases/VIEWER-UPLOAD-RECOVERY-20260911.md) for current
receipts, source bindings and outstanding deployment/phone gates.

## Confirmed P0, not a hypothetical compiler concern

At `2026-09-11T23:37:56.107Z`, a bounded GET of
`https://rendprop.com/spatial-viewer.js` returned HTTP200 and26,442bytes.
SHA256:
`cfc2a3ed5da478101618382ca23bd7ec12cc2ff635011ddb09e9999822ea66a5`.

The downloaded ES module evaluated, but invoking its actual
`decodeSpatialManifest` with a valid synthetic scene in a fresh Node VM raised
`ReferenceError: __name is not defined`. No `__name` helper was supplied by the
test. Ten helper calls existed in the downloaded module.

The unmodified configuration's **actual Wrangler4.129.0 dry-run output** was
then loaded as a Worker ES module. Calling its default export's
`fetch(new Request('https://rendprop.com/spatial-viewer.js'), {}, ctx)` produced
the **identical26,442-byte browser asset and identical SHA256**, and the same
valid-input exception. This ties the source build to the observed failure;
compilation success and HTTP200 alone were insufficient.

Root cause:

- `services/edge/tour-host/src/spatial.ts:81` serializes the shared validators
  with `Function.toString()` into a separate browser module.
- `src/spatial-manifest.ts:22` and `src/spatial-sog.ts:4` contain local helper
  functions. Wrangler's default name preservation transforms those helpers into
  `__name(...)` calls whose implementation remains in the enclosing Worker.
- `scripts/build-src.mjs:27` used TypeScript transpilation instead of Wrangler.
  `scripts/check-spatial.mjs:63` checked syntax, not invocation of the built
  browser decoder. Those passing source tests did not exercise this transform.

## Minimal source fix

`services/edge/tour-host/wrangler.toml:6` now explicitly sets
`keep_names = false`, with a comment explaining the serialization boundary.
The current official [Wrangler configuration reference](https://developers.cloudflare.com/workers/wrangler/configuration/#inheritable-keys)
and installed configuration schema confirm this option controls esbuild name
preservation and otherwise defaults to true. This changes no authority checks,
manifest limits, engine version, SRI hash, or room data.

The fixed emitted Worker SHA256 is
`b0e1a36a73bd294822a33a3eb973457a7c0ccc51ce51a9b4e6a31a3a620e6ca3`.
Its actual `/spatial-viewer.js` response is26,118bytes, SHA256
`c31b3d1c86fc65fd418a78343071b6f3c701627399c55c994d89420d20436517`.
Valid manifest and SOG-envelope calls now execute successfully.

## Regression gate and reproduction

Run from `services/edge/tour-host`:

```sh
npm run check:spatial:built
node --experimental-vm-modules scripts/check-spatial-built.mjs --negative-control
node --experimental-vm-modules scripts/check-spatial-built.mjs --asset-url https://rendprop.com/spatial-viewer.js
node --experimental-vm-modules scripts/check-spatial-built.mjs --asset-file /absolute/path/to/spatial-viewer.js
```

The first command must pass. The deliberate negative-control command must exit1:
it builds a separate configuration with `keep_names=true`, without editing the
working configuration. The public-asset mode is deliberately a normal assertion
gate, **not an expected-failure wrapper**: it exited1 on the still-broken live
asset during this run. After a separately authorized deployment, it should pass.
The file mode executes exactly the supplied browser bytes; fixed file passed26
assertions, retained live file failed on `__name`.

The default/self-test path runs `wrangler deploy --dry-run` directly, loads the
emitted `bundle/index.js`, calls the real route, then evaluates its response in
a separate VM. The extra export statement only exposes existing lexical
validators; no helper implementation, source validator, DOM mock, or transpiled
substitute is injected. It checks valid synthetic/private manifests, field
stripping,15 invalid manifest cases, a valid stored-ZIP SOG envelope and5 invalid
SOG cases. The envelope is intentionally not a renderable room or WebP proof.

Self-test reports34 assertions including Worker route checks and verifies that
the broken-config child exits1 **for the exact missing-helper exception**, not
an unrelated build or environment failure. Module evaluation and decoder calls
have bounded execution; asynchronous module/route promises also have deadlines.
Asset downloads are exact-URL, unauthenticated, redirect-refusing,15-second and
512KB bounded. Files, browser/Worker hashes, configuration/lock hashes and exit
evidence remain in each printed temporary evidence directory.

`npm test` now invokes this gate, so the existing `predeploy` and
`.github/workflows/ci.yml:110` automatically include it. No recursive invocation
of `npm test` or deployment exists inside the gate.

## Commands actually completed

- Original-config built gate: exit1, exact live browser hash and `__name` error.
- Fixed `npm run check:spatial:built`: exit0,34 assertions; broken config child
  exit1 with exact live browser hash/error.
- Fixed browser `--asset-file`: exit0,26 assertions.
- Saved live browser `--asset-file`: exit1, exact missing-helper error.
- Public `--asset-url`: HTTP200, exit1, same live SHA as above.
- `npm run predeploy`: exit0, including TypeScript check; unbranded557 assertions
  plus12 self-tests; routes584; upstream707; lead418; legal57; spatial103;
  built gate34; static asset preflight2 files. This command does not deploy.

The first standalone-file gate exposed a harness counter that mistakenly
included build-stage assertions. It was corrected to count the26 browser checks
independently; both fixed and broken file modes were rerun. An initial Wrangler
package-subpath lookup failed before building; the gate now invokes the installed
CLI path directly. Neither harness failure was reported as a product pass.

Local runtime: Node25.9.0, installed pinned Wrangler4.129.0. Existing dependencies
were reused through a temporary link; **no fresh npm-ci reproduction or hosted
CI run is claimed**. CI currently specifies Node22 and the gate uses its supported
experimental VM-module flag. No private room/media was copied into the repository.

Example fixed bundle/evidence retained from the successful local run:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-7MSKrs/`.
Earlier failed live proof:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-kZFFrP/`.

## Limits and remaining release action

This closes the reproduced serialization defect **in source and actual built
bytes**, not on the live site. Root is separately checking a real room through
the fixed emitted Worker bundle. No Node VM result is a WebGL/iPhone performance
or reconstruction-quality result. The blurry trained room remains a separate
quality issue. Production authorization, revocation, rendering, mobile navigation,
and the post-deployment public asset require their own evidence.
