# Dependency security — O12 implementation checkpoint

Updated October 16, 2026, 23:14 EDT. Existing native/Studio architecture is preserved.

## Change and scope

`.github/workflows/dependency-security.yml` adds a separate read-only security
workflow. A tracked-package inventory discovers every npm manifest, requires its
tracked regular-file lockfile and matching direct dependency specifications, and
feeds the complete directory list to the audit matrix. New projects cannot be
silently omitted by forgetting a static workflow entry. Audits include development
tools and block high/critical known advisories without installing packages,
running lifecycle scripts or applying automatic fixes. Registry fetches and jobs
are bounded. Package inputs must remain unchanged.

The PR-only GitHub dependency review checks new runtime, development and unknown
dependency scopes. The official v5.0.0 action commit was read back from GitHub as
`a1d282b36b6f3519aa1f3fc636f609c47dddb294`; the workflow uses that immutable commit,
not a moving tag. All workflow actions are commit-pinned, permissions are
`contents: read`, checkout credentials are not persisted and no PR comment write
permission is granted. No production credentials or provider calls are needed.

`.github/dependabot.yml` requests weekly update PRs for four npm projects, three
Python requirements directories and GitHub Actions. It does not enable automatic
merging. The pipeline requirements file currently contains comments only and its
Python code intentionally uses the standard library.

## Executed checks

- All four current npm lockfile projects were audited through the public registry
  with development dependencies included: Studio, tour-host, property-video-render
  and the spatial prototype viewer. Each reported zero known advisories. The
  audit used copied manifests/locks, npm11.12.1/Node25.9.0 and no install/fix;
  original source hashes remained exact.
- A separate synthetic lockfile placed known-vulnerable lodash4.17.20 only in
  development dependencies. The former production-only audit returned success
  with zero findings; the new include-development command returned exit1 with
  one high-severity finding. No vulnerable package was downloaded, installed or
  executed. This proves the relevant scope difference with a real advisory.
- Five inventory tests pass: a new project is included automatically, an untracked
  lockfile is refused, changed development dependency specifications are refused,
  symlinked package inputs are refused and paths outside the repository are refused.
- Actual tracked inventory returns exactly the four audited project directories.
  Both YAML files parse through the system Ruby YAML parser. `git diff --check`
  passes. Actionlint is unavailable locally; hosted validation remains required.

Private audit evidence is retained under
`/Volumes/Rendprop Files/Builds/Active/build88-dependency-security-audit/`:
`npm-lock-audit-20261016/RECEIPT.json` and
`dev-only-control-20261016/RECEIPT.json` bind reports and source hashes.

The direct Python review queried ten exact PyPI name/version pairs from five
tracked requirements files, including the verification-to-adapter include. All
releases existed. The stale experimental training pin `Pillow==12.1.1` returned
36 OSV IDs /35 overlapping PyPI records, reducing to18 connected CVE alias groups.
The fix is the one-line pin to12.3.0, already used by the CPU requirements and
the existing training CI. The queried12.3.0 release and the other nine original
direct pairs returned no advisory. There was no package install or new training
run. This experimental pin finding is not a claim that customer exploitation
occurred or that every Python dependency was checked.

Official release metadata retains advisory aliases and fixed versions:
[Pillow12.1.1](https://pypi.org/pypi/pillow/12.1.1/json),
[Pillow12.3.0](https://pypi.org/pypi/pillow/12.3.0/json).
Raw public responses, source bindings, deduplication and the prior CI comparison
are retained in `python-direct-20261016/REVIEW-READY.json` (`bbf3eaa9…`). PyPI's
vulnerability records use OSV, so these are overlapping sources. Unresolved
transitives, the Git-pinned pycolmap dependency, CI-only Modal and native/OS/FFmpeg
remain unqueried or unknown. The new normal training CI must confirm integration.

## Stable required check

`Dependency security required` now combines inventory, every npm matrix audit
and the PR-only dependency review into one stable context for merge protection.
Its `always()` job refuses failed, cancelled, missing or unexpectedly skipped
prerequisites. Push/scheduled/manual runs require the PR review to be explicitly
skipped; PRs require it to succeed. Four focused local tests cover these admission
rules. The new aggregate still requires a real hosted run before enforcement is
claimed. A separate scoped repository change enabled dependency alerts/graph and reviewed
Dependabot security-update PRs. Both read back enabled; auto-merge and secret
scanning/push-protection settings stayed unchanged. Receipt12e26b2a. Branch
protection has not changed yet.

## Remaining acceptance

The following was the earlier source checkpoint. The October 17 section below
supersedes its repository-settings and hosted-enforcement status.

Hosted push workflow38998994789 at5121609 passes the inventory and all four
include-development npm audits. PR-only dependency review correctly skips on a
push; its dependency-graph access is still unproved. Read-only GitHub metadata
confirms secret scanning/push protection enabled, main unprotected and no
rulesets. Dependency alerts/graph and security-update PRs were subsequently enabled and
read back; all other security settings and auto-merge stayed unchanged. Branch
protection and actual PR graph enforcement therefore remain open; a successful push scan is not merge blocking.

Python update PRs alone do not constitute a vulnerability audit; the direct-pin
review above does not resolve transitive/Git/native coverage. Deno imports
outside npm lockfiles, container/OS packages, reproducible rebuild pinning,
publisher/provenance/license review and repository-level enforcement remain open
parts of O12. Moderate findings remain visible but do not trigger this high/critical
gate. A known-advisory scan or a valid signature cannot prove arbitrary code safe.
O12 is therefore still OPEN overall.

Official references:

- [GitHub dependency review](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependency-review)
- [npm audit semantics and scopes](https://docs.npmjs.com/cli/v11/commands/npm-audit/)


## October 17 hosted enforcement and default-branch findings

PR39 dependency security39003478845 atb1 completed all7 jobs, including actual
PR dependency review and the stable aggregate (receipt e2abaa09). Main now requires
all16 full-CI contexts plus `Dependency security required`, with GitHub Actions
app15368, strict freshness and administrator enforcement (acf1a03a). Auto-merge
remains off. The full CI has an independent audio failure; no merge was performed.

Dependency alerts/graph and automatic security-update PRs are enabled/read back
(12e26b2a). Enabling them exposed62 findings on older main:46pip/16npm. Candidate
recursive direct requirements and all matching npm lock versions lie outside every
reported vulnerable range (c92c3e7b, independent09b3a7f3). These alerts remain OPEN
on main until reviewed integration; none were dismissed or assigned zero risk.

## October 17 additional backend dependency scope

One bounded public OSV batch found no matching records for `aws4fetch1.0.20`
and `jpeg-js0.4.4`. Nine other mirrored Deno npm identities exactly match the
already-audited Studio lockfile. This adds those exact observations, not complete
Deno coverage: tests have floating JSR imports, preparation uses `--no-lock`, and
a cache inventory does not establish the active resolver graph. The CPU image's
selected runtime version probe and SLSA descriptor are not a complete installed
Python/OS inventory. No package was installed or automatically upgraded.

Evidence: `/Volumes/Rendprop Files/Builds/Active/build88-o12-deno-installed-image-feasibility/FEASIBILITY.md`
(`b1391069`) and the exact query result (`1b4f12ae`). The reviewed metadata-only capture subsequently ran once against exactb402:
3 Python distributions and295 installed Debian records; source/image checks
remain exact and the initially-Stopped VM is restored. Receiptff9cee97,
inventory16029c7c. No package was installed, pulled or imported by the collector.
Installed-scope advisory classification/query is still pending. O12 stays open
for the broader scopes named above.
This is reported-range reconciliation, not a complete transitive Python/Deno/OS,
publisher, license or arbitrary-code audit. Retain those open scopes.

## October 17, 02:15 EDT: installed scope and resolved import graph

The current PR security run `39007771186` on `bdb1bbf` passes all seven jobs, including actual PR review. Full CI `39007771233` has a separate media export failure.

Installed metadata from renderer image `b4022fc9` yields 210 Debian source/version identities plus pip 26.2.1. One 211-query OSV batch and 65 detail lookups retain 387 unique advisory records. There was no pip match. Record-level CVSS v3 scores are 19 critical, 101 high, 152 medium and 23 low; 68 CVSS v4 records and 24 missing vectors remain unscored. These are advisory scores, not measured application severity or exploitability. No fixed-version event applies to the exact queried Debian 12 source entries; three record-wide events belong to other packages. The 23 end-of-life labels concern mbedtls 2.28.3-1/libmbedcrypto7; actual renderer linkage and use remain unproved. Evidence: review `16df664d`, independent peer `e6d9ffa8`.

The Worker already disables general Internet access and grants exact URL, method and expiry capabilities to downloads. Missing FFmpeg protocol restrictions do not establish arbitrary network SSRF. A narrow patch now rejects unsupported Pillow formats before decoder dispatch and restricts local FFmpeg inputs to file/pipe. Root independently verified that reversing only these 23 argument additions recovers all eight original module ASTs. Actual old-image tests reproduce three intended failures out of eight: TIFF reaches two image decoders and a direct helper attempts its owned loopback fixture. HLS already refuses and is not a new fix.

The corrected offline build now passes all eight boundary checks and thirteen unchanged actual-media regressions on exact derived image `a2796b06`. The regressions exercise real24fps transitions, captions, music, narration,1080p output, exact selected-photo fallback, endpoint trimming and SDR conversion; three SDR reference comparisons have zero RGB MAE, and two compiled conversion omissions fail their intended pixel assertions. Full actual result `5a176828` and final packet `3846b1e7` preserve139 proof files,206 inputs, exact resource limits and Stopped/zero-container cleanup. The earlier legacy-builder manifest error and logical-endpoint refusal remain retained. Root verified the packet and integrated only the eight tested modules plus the new boundary test (`21d9bfb1`). This is source integration, not deployment, package upgrade, blanket advisory clearance or proof over customer media. Full current CI and a separate exact-image rollout remain required.

The network-denied Deno 2.7.13 command ran once using retained cache/manual dependencies without source evaluation: 565 module identities, 32 runtime roots, 227 test roots, 2,313 resolved edges and no missing resolved target. Root independently traversed the raw graph: 242 runtime code modules, 247 including types; 545 test code modules, 552 including types. Four npm entry/type terminals remain opaque, and 151 computed test imports are outside the graph. Floating JSR versions are cached observations rather than reproducible lock pins. The ten-package, 583-file npm inventory is not a traversed CommonJS graph. Packet `6403b59e` and the independent root review bind these limits. No package installation, lock rewrite, source execution or security clearance follows from graph capture.

O12 remains open for exposure, native and transitive dependencies, provenance and reproducibility. No advisory was dismissed, and no provider or live-media request was made.

## October 17, 04:15 EDT: bounded npm source expansion

A separate static supplement expands the four npm terminals over the retained ten packages:583 files/8,144,306 bytes were bound before and after. Trusted TypeScript5.9.3 parses literal imports/requires only; third-party packages are never evaluated. The four root traversals produce a131-file candidate union and25 conditional ambiguities. This is a union of possible files, not evidence of which Deno export condition or CommonJS branch runs. Root independently verified ten evidence hashes and all583 package files (`84c9c57e`, final `d09e18a8`).

Actual condition selection, runtime resolution, globals/ambient types, optional Worker and OpenTelemetry peers remain outside that proof; the151 computed first-party test imports are unchanged. The earlier565-module graph is an as-time snapshot and does not claim coverage of subsequently added first-party tests. Package metadata also does not replace file notices: jpeg-js declares BSD-3-Clause at the package root, while the reachable decoder retains Apache-2.0 and the encoder retains an Adobe BSD-style notice. No license compatibility, notice compliance, provenance or security clearance is inferred. No network, resolver, installation or shared-cache write occurred in this supplement.
