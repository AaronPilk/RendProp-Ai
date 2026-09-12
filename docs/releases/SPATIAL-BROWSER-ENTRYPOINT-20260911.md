# Spatial browser entrypoint: deployment baseline and evidence

**Do not deploy the `3097317` checkout to fix the spatial viewer.** Its
`keep_names = false` setting addresses the reported compiler behavior, but that
checkout contains no spatial viewer implementation or spatial routes. Deploying
its Worker would replace the spatial-capable host with one that returns a
branded 404 for `/spatial-viewer.js`, `/s/:id`, `/s/:id/manifest` and
`/s/:id/model`. This conclusion was independently verified in Git source, not
inferred from the commit message. No deployment was performed by this work unit.

Checkpoint: September 11 Eastern / September 12 UTC, 2026. New isolated branch
`fix/spatial-browser-entrypoint-20260911`, initial source
`259bfad4fe953e4f68c4f50b7ec346d79d15789d`, at
`/Users/pilksclaes/Rendprop AI/spatial-browser-entrypoint-20260911`.
The refactor is committed and pushed as
`c391bb95b3a36b1ca99a306cd19465950abd1656`, parent `259bfad`, changing only
16 files under `services/edge/tour-host`. The fresh local predeploy and synthetic
browser gates **pass** with receipts below. The hosted tour-host job also **passes
on Node22.23.2**; the complete repository workflow is **6 passing / 4 failing
jobs**, with causes recorded below. **Production still serves the old browser asset; this work has
not deployed it.** Previous branch counts remain historical, not new test results.

The compact durable evidence companion is
`docs/releases/evidence/SPATIAL-BROWSER-ENTRYPOINT-20260911.json`; raw temporary
receipts below retain the fuller run details while available.

## 1. Git topology: an old main is not the deployment baseline

Read-only commands completed:

```sh
git show -s --format='%H %P %D%n%s' 3097317
git rev-list --left-right --count main...3200ce8
git rev-list --left-right --count main...3097317
git rev-list --left-right --count 3097317...d9eadc7
git merge-base 3097317 d9eadc7
git diff --name-status 8263e25 259bfad -- services/edge/tour-host
git diff --name-only d9eadc7 259bfad -- services/edge/tour-host
```

- `3097317b69b08657ba83d2a54c1eb8a8c7b47a72` is on `feat/agent-reel`, parent
  `3200ce83ebfc38bd50cc1c70d488329407572509`. It adds four configuration lines.
- `main...3200ce8` is `0 39`; `main...3097317` is `0 40`. These mean the
  feature commits are **39/40 ahead of the local main ref**, not behind it.
  Neither result means the checkout includes the newer spatial implementation.
- `3097317...d9eadc7` is `1 167`; their common ancestor is `3200ce8`.
  Do not turn that repository-wide count into a claim that 167 changes were
  deployed, or must be deployed to repair this one Worker.
- The **entire `services/edge/tour-host` subtree is identical** at `2612c7c`,
  `8263e25` and `71f9eb7` (both comparisons returned no changed paths).
- From `8263e25` to `d9eadc7`, only three host paths differ:
  `package.json`, `wrangler.toml` and the added
  `scripts/check-spatial-built.mjs`. No host application source, static asset or
  package-lock change is concealed in that comparison.
- Minimal checkpoint `259bfad` is directly based on `8263e25` and has exactly
  that same three-file host change. Its host subtree is byte-identical to
  `d9eadc7`; the read-only comparison returned no changed paths.

This is why an explicitly chosen spatial-capable baseline is safer than deploying
whichever checkout happens to be named `RendProp-Ai` or `feat/agent-reel`.

## 2. What the obsolete checkout would remove

Line references in the first column are **at commit `3097317`**, not current
working-tree line numbers. Comparison references are at the minimal checkpoint
`259bfad` and its identical `d9eadc7` host tree, before the refactor below.

| Obsolete source | Concrete behavior lost or reintroduced | Spatial-capable comparison |
| --- | --- | --- |
| `src/index.ts:418–471`; no `src/spatial*.ts` or matching public asset in Git | No spatial asset, shell, manifest or model route; requests reach the branded 404 fallback at line 471. `keep_names` cannot repair code absent from the bundle. | `src/index.ts:409–419`, `src/spatial.ts:14–96` |
| `src/player.ts:433`, `2558`; old `Chapter` shape | Room-to-3D buttons and the enter/back media lifecycle are absent. | `src/types.ts:32`, `src/player.ts:429–442`, `1561–1596`, `2644` |
| `src/index.ts:286–289`, `321–324`, `367–393` | Customer tour and portfolio HTML again uses the edge cache; a warmed page can outlive publication revocation. | `src/index.ts:292–299`, `332`, `370–381` bypass customer caches and use no-store. |
| `src/index.ts:236–249`, `343–345`, `374–385` | Unbounded upstream JSON reads return; portfolio network/upstream failures can be reported as a missing portfolio. | `src/upstream.ts:7–8`, `21–103`; `src/index.ts:373–384` |
| `src/player.ts:1595–1631` | Malformed or empty successful HTTP responses can hide the lead form and display success; no request/body deadline or in-flight submit guard. | `src/player.ts:1644–1688` requires a confirmed response, bounds waiting and fences overlapping submits. |
| `src/legal.ts:289–300`, `341–345` | Reverts provider/processing disclosures, including OpenAI, ElevenLabs, Apple speech fallback and deletion-cleanup/shared-workspace distinctions. | `src/legal.ts:316–327`, `366–374` |
| `package.json:12–17` | Normal predeploy tests contain no spatial or emitted-browser gate, so green old tests do not establish the missing feature exists. | `package.json:12–19` invokes the built-byte regression gate. |

These are concrete source rollback risks. Except for the independently observed
spatial browser bytes below, this document does not claim every line in the
comparison tree has been matched to the entire live Worker bundle.

## 3. What is actually known about production

The earlier durable live-upload handoff recorded tour-host active version
`0e6b2f90-5911-4e77-934f-8575c9d982e2`, deployed at
`2026-09-11T20:46:15Z`. The root agent's fresh read-only inventory at approximately
`2026-09-12T02:16:42Z` again found that version at **100%**, deployment ID prefix
`059d77b1`. This inventory is a readback, not a new deploy or a source receipt.

The downloaded gate receipt was independently inspected:

- Observed at `2026-09-12T02:16:42.812Z`.
- `/spatial-viewer.js`: HTTP200, **26,442 bytes**.
- Browser SHA256:
  `cfc2a3ed5da478101618382ca23bd7ec12cc2ff635011ddb09e9999822ea66a5`.
- Gate result: **exit1**, `AssertionError`, with the exact reason:
  `Unverified browser asset differs from this source build; supplied JavaScript was not executed`.
- Receipt:
  `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-A5DeNO/receipt.json`.

The browser hash is unchanged from the earlier observed missing-`__name` defect.
This latest gate did **not** evaluate the mismatched live script: source-hash
verification rejected it first. The actual `ReferenceError: __name is not defined`
execution proof belongs to the earlier receipt, not this fresh mismatch result.

After completing local verification, root repeated the read-only public-asset check at
`2026-09-12T02:49:30.801Z`. Receipt
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-ssEWAb/receipt.json`
again records exit1 for the same exact source-mismatch reason and the unchanged
`cfc2a3ed…` browser hash. Cloudflare readback at `02:49:34.386Z` still showed
version `0e6b2f90-5911-4e77-934f-8575c9d982e2` at 100%, deployment prefix
`059d77b1`. The passing local candidate is not a production update.

Independent local evidence review also SHA-verified the retained original-config
Worker and browser files in `rendprop-spatial-built-55EFRV`, and compared all
**11 host sources embedded in its source map** with the exact Git blobs at
`71f9eb7`: every source matched. That browser output has the same hash as the
observed live asset. This ties the reproduced browser defect to the known source
family; it **does not establish a hash match for the whole production Worker**.

## 4. Deployment-safe choices, not a blind command

### Choice A: minimal known hotfix

Checkpoint `259bfad` preserves the spatial-capable host and adds only the
`keep_names=false` correction and its regression gate. Its host bytes match the
previously reviewed `d9eadc7` host. If the owner chooses an immediate narrow fix,
use that exact immutable checkpoint in a clean isolated checkout, run its own
predeploy gate, review the generated bundle and its receipt, and deploy **only
tour-host** after the currently active version is read back. Then verify the
live browser asset against the exact local build and test the relevant routes.

The historical fixed browser was **26,118 bytes**, SHA256
`c31b3d1c86fc65fd418a78343071b6f3c701627399c55c994d89420d20436517`.
That is a comparison for Choice A, not a prescribed hash for a future refactor.
No new execution against checkpoint `259bfad` is claimed merely because its host
subtree equals an earlier tested tree.

### Choice B: durable browser-entrypoint refactor

The active work unit has replaced the stringified-function build boundary with
an actual browser entrypoint in `c391bb9`. Its local gates and hosted Node22
tour-host job pass. A push does not finish deployment or post-deploy verification;
the complete repository workflow still has four failing jobs detailed below.
The refactor retains the same route,
authorization/revision, SOG admission, privacy, no-store and navigation contracts.
It must not rely on a helper injected by a test or on ambient Worker-scope code.

Before choosing this candidate, require:

1. An immutable, clean source checkpoint and an explicit diff from `259bfad`.
2. Tests of the real emitted Worker response and the actual browser entrypoint,
   including deliberately broken build/stale-output controls that fail for the
   intended reason. Source-only import tests do not cover this boundary.
3. Existing host suites and real-browser responsive checks with the emitted
   bytes, a **synthetic SOG and test-pattern video**. These prove specific
   rendering/lifecycle behavior, not the owner's reconstructed-room quality or
   physical-phone navigation; that separate owner acceptance remains open.
4. A reviewed deployment receipt and fresh post-deploy live-byte comparison;
   retain previous version identity for rollback planning. Do not infer a live
   update from a push, a dry-run, HTTP200, or an unrelated TestFlight upload.

Do not copy deploy commands from the obsolete checkout. Do not deploy all
Supabase functions or apply unrelated migrations as part of either host option.
Neither option authorizes changing Apple/App Review, spatial runtime budgets,
provider routing, controller scheduling, or customer data.

### Phone delivery: this viewer asset is remote, not bundled into iOS

Read-only source comparison found no differences between `2612c7c` and `259bfad`
for the four iOS files below. This identifies the existing product path, not the
provenance of whichever binary happens to be installed on a phone:

- `apps/ios/Rendprop/Networking/LiveAPIClient.swift:306–309` fetches the current
  job from `/spatial/:id` and decodes its exact response keys.
- `apps/ios/Rendprop/Screens/SpatialTourView.swift:252–256` takes the fresh
  `viewerURL`; `:397–403` does the same for private review. The sheets at `:128`
  and `:379` pass that URL as `PlayerWebView(remoteURL:)`.
- `apps/ios/Rendprop/Screens/PlayerWebView.swift:51–54` loads that remote URL in
  `WKWebView` and returns **before** the bundled local-player fallback.
- `apps/ios/Rendprop/Networking/SpatialModels.swift:70` maps `viewer_url` to
  `viewerURL`; `:83–85` requires HTTPS.
- The hosted shell in `services/edge/tour-host/src/spatial.ts:90–96` imports
  `/spatial-viewer.js`; `:80–85` serves the generated browser module.

Therefore, for an installed client already carrying this spatial product path,
this specific browser-asset correction does **not** require another TestFlight
binary. After a verified Worker release, close and reopen the room so the app
fetches a fresh viewer URL and a new page. An already-open module is not hot-swapped.
That conclusion does not ship or test separate native capture, upload, recovery,
Home-card or UI changes; those still need their appropriate app build and phone
acceptance. No Worker release or installed-binary provenance check occurred in
this read-only source check.

## 5. Current refactor verification ledger

| Evidence | State |
| --- | --- |
| Topology, three-file minimal diff, source-tree identity | Independently verified read-only as detailed above. |
| Fresh live browser hash and source-mismatch gate | Verified receipt; live defect remains, no deployment performed. |
| Browser-entrypoint implementation | Committed and pushed `c391bb9`; 16 host-only files. Independent build-graph review and local gates completed below. |
| Initial typecheck and source contract | Root reports `npm run typecheck && npm run check:spatial`: exit0, 103 assertions, zero skips. This is not the emitted-Worker/browser matrix. |
| Existing non-built host suites and demo-asset preflight | Root executed the complete command below: exit0; individual counts retained, not merged into a new canonical gate total. |
| Independent browser compiler matrix | Four minify/name-retention combinations built in memory; exact import/export graph asserted. No DOM/WebGL execution in this check. |
| Separate browser-module runtime checks | Root's 33-check data-URL proof and builder agent's reproducible 51-check VM proof passed. These are separate evidence, not added to emitted-Worker gate totals. |
| New emitted-Worker/runtime/negative controls | Rerun passed: 279 assertions, nine positive suites, six exact freshness failures, actual symlinked CLI write, detached-import failure and unmatched-byte rejection. Historical 34/36 counts are not these results. |
| New responsive real-browser behavior check | Rerun passed: 69 UI plus 7 artifact assertions; one exact synthetic beacon handled locally. Uses a synthetic SOG and test-pattern video, not the owner's room. |
| Browser premature-ready negative control | Expected exit1 at the exact no-ready-before-transfer assertion; one UI/four artifact assertions reached. Not counted as a passing normal browser run. |
| Fresh clean dependency install and full predeploy | `npm ci --no-audit --no-fund` exit0; `npm run predeploy` exit0, source unchanged. |
| Hosted CI/Node22 | Run 34668769211 completed against c391bb9: tour-host passed on Node22.23.2, including 279 built-gate assertions and the same canonical browser hash. Full workflow: 6 pass / 4 fail. Local runs used Node25.9.0. |
| Owner's real-room quality and physical-phone acceptance | Remains open; not being performed by this host-only work unit. Prior local room rendering did not meet quality acceptance. |
| Production deployment/post-deploy proof | Not performed by this work unit. |
| New iPhone/TestFlight acceptance | Not performed by this work unit. |

### Existing host regressions, freshly executed by root

From `services/edge/tour-host`, this entire command completed with exit0:

```sh
node scripts/check-unbranded.mjs &&
node scripts/check-routes.mjs &&
node scripts/check-upstream.mjs &&
node scripts/check-lead-form.mjs &&
node scripts/check-legal.mjs &&
npm run check:assets
```

| Suite | Observed checks |
| --- | --- |
| Unbranded | 557 assertions plus 12 self-tests |
| Routes | 584 assertions |
| Upstream | 707 assertions across 75 cases |
| Lead form | 418 assertions across 31 cases; zero network calls |
| Legal | 57 assertions |
| Demo-asset preflight | 2 files |

The earlier `npm run typecheck && npm run check:spatial` also exited0 with
103 spatial assertions and zero skips. The final full predeploy reran these
existing suites and the emitted-Worker gate successfully. Their individual
counts remain separate from the browser/Worker matrix and responsive UI checks.

### Final fresh local receipts and reproducible commands

The team ran a fresh `npm ci --no-audit --no-fund` with exit0, then `npm run predeploy`
with exit0. `/tmp/rendprop-host-predeploy.OznHPJ/receipt.json` records
`source_unchanged: true`, Node25.9.0, start `2026-09-12T02:47:40.526Z`, finish
`02:47:53.422Z`; its log is `/tmp/rendprop-host-predeploy.OznHPJ/predeploy.log`.

The nested `/tmp/rendprop-spatial-built-gFGXbP/receipt.json` is passed with
**279 assertions**. This executes the canonical browser contract, all four
Worker minify/name combinations, and all four browser minify/name combinations:
nine suites of 25 contract checks plus one count-control each. The remaining
assertions check build boundaries and exact negative-control results; do not add
the earlier 33/51 exploratory counts to 279.

The gate proves an actual CLI write through a filesystem alias, and separately
rejects six cases with exit1 and the expected cause: missing generated JSON,
missing generated TypeScript, stale generated bytes, stale imported helper,
stale builder, and stale lockfile. The deliberately detached actual decoder now
builds successfully and fails at exactly
`ReferenceError: isBoundedSpatialNumber is not defined`. Unmatched supplied
JavaScript is rejected by source hash before execution. None of these gates
silently regenerates stale release artifacts or substitutes source-only tests
for the emitted response.

The actual emitted preview Worker SHA256 is
`55e6004280152c2c92cd8d01b7b26df4ac8f4f80575c62b2cd51f2857739e0ce`.
The served browser bytes remain **26,665**, SHA256
`6a093950201c2893c36a9d957bf1133f4ba5e9713226f53bbecbb3e7c643b211`.
Preview receipt:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-preview-aehPLc/receipt.json`.

Fresh Chromium receipt
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-browser-5JMCif/receipt.json`
is passed: **69 UI assertions plus 7 artifact assertions**, including unchanged
served-module hashes and one narrowly validated synthetic beacon. It exercises
real WebGL drawing, responsive navigation, error states, native-ready ordering,
and actual test-pattern MP4 restoration through the emitted Worker. The engine
is the pinned SRI-identical local fixture; CDN availability is not proven.

The deliberately premature native-ready run correctly exits1 at
`no native ready message before model transfer`, after one UI and four artifact
assertions, in
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-browser-2gyvk7/receipt.json`.
This is a verified negative control, not a waived normal-run failure.

From `services/edge/tour-host`, reproduce the local gates:

```sh
npm ci --no-audit --no-fund
npm run predeploy
```

Use the existing explicitly synthetic fixtures described in
`docs/audits/2026-09-10/SPATIAL-WEB-PRODUCT-SOURCE.md:54–64` for the separate
browser proof. The preview command stays running on loopback; run the browser
check in a second terminal. These paths are temporary and must still exist:

```sh
node --experimental-vm-modules scripts/preview-spatial.mjs \
  /tmp/rendprop-spatial-viewer.dCoSW8/SYNTHETIC-NOT-A-ROOM.sog \
  '/Users/pilksclaes/Rendprop AI/spatial-phase-a/tools/spatial-spike/viewer/node_modules/playcanvas/build/playcanvas.min.js' \
  /tmp/rendprop-spatial-browser.C67PoS/SYNTHETIC-NOT-A-TOUR.mp4
```

```sh
node scripts/check-spatial-browser.mjs \
  /Users/pilksclaes/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs
```

Run the same check with `--negative-control` for the deliberate premature-ready
mutation. It must exit1 for the exact assertion above; a different failure is
not evidence that the intended protection works.

The workflow's automatic push trigger is main-only, so root manually dispatched
the existing CI workflow for this branch. Its completed result follows. Local
Node25 passes are not being substituted for the hosted Node22 evidence.

### Hosted CI: Worker green, complete repository not green

Command: `gh workflow run ci.yml --ref fix/spatial-browser-entrypoint-20260911`.
[Run 34668769211](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34668769211)
completed against code commit `c391bb95b3a36b1ca99a306cd19465950abd1656`.
Later documentation-only commits are not a claim of another CI run.

**Passed:** tour-host, Supabase edge functions, iOS static gates, offline audit
and consent gates, reel-style contracts, Python render worker. The iOS static
job is not an Xcode build or physical-phone test. Tour-host job `103485972321`
used Linux/Node **v22.23.2** and passed clean installation, typecheck, tests,
Wrangler dry-run and production-dependency audit. Its built-byte receipt has
**279 assertions, nine positive suites, six freshness controls** and browser
SHA256 `6a093950201c2893c36a9d957bf1133f4ba5e9713226f53bbecbb3e7c643b211`,
identical to the local candidate.

**Four failures remain; no gate was weakened to hide them:**

| Job | Verified cause and next action |
| --- | --- |
| Web inventory `103485972199` | `apps/ios/Rendprop/Networking/APIClient.swift:726–735` adds ten spatial methods not mapped by `packages/client-contracts/capabilities.json:5–20`. `tools/web-client/verify_foundation.py:74–76` rejects that mismatch. Its `:143–144` also expects 41 methods / 42 declarations rather than the actual parser's 51 / 52. Add truthful capability mappings and update the counts; retain negative controls and do not claim unimplemented web parity. |
| Migration invariants `103485972229` | Invariant 155 at `services/supabase/tests/invariants.sql:1424–1433` requires output ceiling strictly above visible output. `0034_agent_reel_and_video_ladder.sql:69–71` seeds 700; `services/supabase/functions/ai-copy/index.ts:220,832` requests 700 visible tokens. The equality is the known failure. Resolve the separately authorized token-headroom decision; do not change `>` to `>=` to green the test. No live provider setting was inferred or changed. |
| Disposable PostgreSQL `103485972257` | The same invariant fails in both initial and replay runs; this is not a second SQL defect. Artifact `10290375337` records 41 migrations applied, 33 eligible replays, 198 invariants per run, publication fixtures and deliberate negative controls executed, `accepted=false`, `clusterStopped=true`. `tools/audit/run_database_regression.py:206–208,226` correctly exits nonzero. |
| Secret scan `103485972288` | Six historical fingerprints were reported in commits `bcba804…` and `4e4776d…`, not in this patch's 16 host files. Selected metadata only was inspected; raw matches were not printed. Resolve each through exact-file/private provenance review, not blanket allowlisting. This run is still red; an older branch's disposition is not a fresh verification here. |

The exact missing inventory methods are `attachSpatialInputs`, `cancelSpatialJob`,
`createSpatialJob`, `publishSpatialJob`, `resumeSpatialJob`, `retrySpatialJob`,
`reviewSpatialJob`, `spatialJob`, `spatialJobs`, and `startSpatialJob`.
Local `python3 tools/web-client/verify_foundation.py` also exited1 for that same
list. Invoking its actual parser returned 51 methods / 52 declarations.

The scanner locations, without any matched values, are:

- `bcba804…`: `services/supabase/functions/admin/probe.test.ts:275` (`jwt`) and
  `:178` (`private-key`); `docs/handoff/launch-P2.md:517` (`curl-auth-header`);
  `services/supabase/functions/apple-subscriptions/notify.test.ts:293` and
  `services/supabase/functions/_shared/applejws.test.ts:924` (`generic-api-key`).
- `4e4776d…`: `apps/ios/Rendprop/Config.swift:33` (`jwt`).

All eight source/workflow files implicated in the first three failures have
identical Git blobs through **8263e25 → 259bfad → c391bb9**; the scoped diff for
Supabase, APIClient, web inventory, database runner and CI workflow returned no
paths. This establishes that the viewer patch did not introduce those failures,
not that they may be ignored for overall release readiness. The secret scan is
history-sensitive and has a separate scope. No failed checks were rerun with
relaxed assertions, provider ceilings, or scanner configuration.

### Development failures retained before any final passing claim

These failures are part of the work log, not erased by a later rerun:

1. **Responsive-browser run failed.** Receipt
   `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-browser-EPplyn/receipt.json`
   records `status: failed`, 69 UI assertions and 6 artifact assertions, with
   `No unexpected network origins: https://spatial-preview.invalid`. The real
   player attempted its normal analytics beacon for the synthetic tour; the
   fixture had not admitted that exact request. Root added an explicitly bounded
   interception for only `POST /functions/v1/beacon/synthetic-tour` at that fake
   origin, validating request fields/body bounds and absence of `Authorization`.
   The fixture fulfils that request locally and never forwards it to a real
   service. Other unexpected requests remain failures. This is not permission to
   disable the network assertion or suppress real player errors. **Repaired;
   the final5JMCif rerun above passed.**

2. **Predeploy run failed despite passing positive contracts.**
   `/tmp/rendprop-host-predeploy.ijuh93/receipt.json` records `npm run predeploy`,
   Node25.9.0, exit1 and `source_unchanged: true`, running from
   `2026-09-12T02:41:16.418Z` to `02:41:24.035Z`. Its emitted-bundle receipt at
   `/tmp/rendprop-spatial-built-OvurTt/receipt.json` reached all nine positive
   decoder/SOG suites (25 contract checks plus one count-control each) but failed
   the detached-helper negative control. The final error was
   `Detached actual decoder must fail specifically at its imported helper`;
   the caught error instead said the Wrangler dry-run failed. A build failure
   must not be reported as the intended browser `ReferenceError`.

   Root traced this to a real builder bug: its CLI-entry comparison used
   `resolve(process.argv[1]) === fileURLToPath(import.meta.url)`. On macOS,
   invoking the fixture via `/tmp` while the module URL resolves to `/private/tmp`
   could skip the entire CLI body. `--write` then exited0 without writing the
   changed generated artifact. The enclosing gate correctly rejected the later
   wrong failure. The builder owner fixed the guard using canonical paths,
   regenerated bound metadata, and added a control proving the requested write
   actually happens. Browser runtime bytes remained identical. **Repaired;
   the final OznHPJ predeploy/gFGXbP gate above passed.** The first run remains
   recorded as failed rather than rewritten as a success.

### Implementation: the browser is now a real compilation target

- `src/browser/spatial-viewer.js:4–6` imports the actual manifest/SOG validators
  and explicitly exports them; `:23` exports the existing `mountSpatial` runtime.
- `src/spatial-manifest.ts:1` imports `isBoundedSpatialNumber`, used at `:35`.
  The real shared helper is in `src/spatial-values.ts:3`; this deliberately
  exercises a transitive dependency instead of relying on self-contained functions.
- `scripts/build-spatial-browser.mjs:40` bundles that entry and complete import
  graph for the browser. `:114` encodes the emitted ESM as an inert TypeScript
  string, with generated metadata; `:120` checks generated bytes for freshness.
- `src/spatial-runtime.ts:3` adapts that generated string to the existing Worker
  name. `src/spatial.ts:83` serves it directly. The production path no longer
  serializes naked validator functions with `Function.toString()`.

Root independently asserted the entire moved runtime body matches the old
`String.raw` body at `259bfad`, apart from the import/export wrapper. Only the
compilation/embedding boundary changes; a matching body is not itself runtime
acceptance. New tests must execute the bundle with its actual dependencies.

### Browser builder peer review and exact input graph

An independent agent read `scripts/build-spatial-browser.mjs`, the browser
entrypoint, Worker wrapper, generated metadata and package/config changes.
A separate read-only Node invocation imported `checkSpatialBrowser` and
`buildSpatialBrowser`, asserted the committed canonical output, and built all
four browser combinations of minification and name preservation **in memory**.
It exited0; no files, DOM, room data, live route or Worker deployment were changed.

Canonical browser output is **26,665 bytes**, SHA256
`6a093950201c2893c36a9d957bf1133f4ba5e9713226f53bbecbb3e7c643b211`.
Every variant had exactly one ESM output, no unresolved imports, and exactly
the exports `decodeSpatialManifest`, `inspectSpatialSog` and `mountSpatial`.
Its actual compiler inputs were exactly:

- `src/browser/spatial-viewer.js`
- `src/spatial-manifest.ts`
- `src/spatial-sog.ts`
- `src/spatial-values.ts`

The builder pins esbuild0.28.1 directly and in the lockfile, records hashes of
the actual bytes read by its compiler hook, detects changes during compilation,
bounds the input graph, and refuses imports outside ordinary package `src`
files. Generated content is checked, not silently refreshed, by the mandatory
Wrangler custom-build hook. The Worker serves the separately compiled ESM as
inert text. An interrupted two-file generation is rejected by the next check.
The initial in-memory builder review did not expose the later filesystem-alias
CLI bug; the development failure and actual-write regression above document its
discovery and repair. Runtime/negative-control acceptance comes from the final
emitted-bundle gate, not this earlier review alone.

Root separately executed all four browser options via data-URL imports with
exact-export/import-graph and invalid-fixture assertions: **33 counted checks,
exit0**. Its first exploratory run had an incorrect expected count of37 and
correctly failed after executing33; the count was corrected without relaxing a
behavior assertion. This is not an additional canonical gate total.

The builder agent's separate reproducible VM proof reports **51 assertions**,
status passed, Node **v25.9.0**, observed `2026-09-12T02:30:59.700Z`. Its script
and receipt were independently read for this handoff. It executes all four
browser variants, valid and invalid decoder inputs, the real imported helper,
the declared exports, the no-external-import graph and pinned engine URL/SRI.
It also verifies working-directory independence and unchanged generated files.

```sh
node --experimental-vm-modules \
  /tmp/rendprop-browser-builder-proof.AbfaAe/proof.mjs \
  '/Users/pilksclaes/Rendprop AI/spatial-browser-entrypoint-20260911/services/edge/tour-host'
```

Receipt: `/tmp/rendprop-browser-builder-proof.AbfaAe/receipt.json`.
These are browser-module VM checks, not emitted-Worker or WebGL proofs. Local
Node22 is not installed; no local Node22 run is claimed. The completed canonical
emitted-Worker and synthetic responsive-browser results are recorded separately
above. The subsequent hosted tour-host job passed on Node22.23.2 with the final
279-assertion gate; the complete workflow remains red for the causes above.

### Tooling dependency audit: do not multiply one advisory into four

The final clean dependency installation added **41 packages** and exited0; the
earlier audit/install output included a 42-package count. The earlier audit
reported **three high-severity package findings in one dependency chain**:
`sharp <0.35.4` → `miniflare` → `wrangler`, underlying advisory
`GHSA-rgj7-g3m4-5g8c`. The available recommended Wrangler update was4.131.1.
This work did not run an automatic dependency upgrade.

Root's separate `npm audit --omit=dev --json` exited0 with no advisories.

The independent browser compiler graph above contains no node_modules, sharp
or miniflare input. A further read-only check SHA-verified the actual source maps
for all six emitted Workers in the final gate (canonical, four option variants,
and the detached-helper control): each has exactly11 ordinary local source
inputs, with no node_modules, sharp or miniflare. This is bundle evidence for
the local candidate; it is not a whole-production-Worker identity proof. These
advisories affect the installed local tooling chain in this candidate, not its
emitted Worker/browser runtime graph. The development tooling still warrants
a separately tested dependency update.

## 6. Prior handoffs and still-open gates

This deliberately narrow branch starts at `8263e25`; later broad integration
handoffs are not silently copied into it. Preserve them via their immutable
`d9eadc7` versions:

- [Viewer/upload recovery work log](https://github.com/AaronPilk/RendProp-Ai/blob/d9eadc79c6d30e4cc5f1f1694ee6f133b734fd82/docs/releases/VIEWER-UPLOAD-RECOVERY-20260911.md)
- [Original emitted-viewer diagnosis](https://github.com/AaronPilk/RendProp-Ai/blob/d9eadc79c6d30e4cc5f1f1694ee6f133b734fd82/docs/audits/2026-09-10/SPATIAL-BUILT-VIEWER-FIX-20260911.md)
- [Controlled live-upload proof](https://github.com/AaronPilk/RendProp-Ai/blob/d9eadc79c6d30e4cc5f1f1694ee6f133b734fd82/docs/releases/LIVE-UPLOAD-PROOF-20260911.md)
- [Real-room evening reconstruction result](https://github.com/AaronPilk/RendProp-Ai/blob/d9eadc79c6d30e4cc5f1f1694ee6f133b734fd82/docs/releases/SPATIAL-INTEGRATION-EVENING-20260911.md)

The room reconstruction remains visibly blurry: serialization/build correctness
cannot restore missing detail. The prior full-integration CI token-headroom
finding (`copy.agent_reel ceiling=700 visible=700`, 197/198 invariants passing)
remains separate; this work neither raises provider caps nor weakens that test.
Privacy review/region-redaction acceptance, reconstruction quality, supported-phone
performance, complete recovery and the paired deletion/provider/upload deployment
gates are not closed by a host fix. The pending App Review submission is untouched.
This document is **not a whole-app GO**.
