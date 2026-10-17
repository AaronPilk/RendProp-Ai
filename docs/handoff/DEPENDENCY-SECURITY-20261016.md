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

## Remaining acceptance

This is local implementation/verification, not a hosted enforcement claim.
Run the workflow at the final integrated source; verify PR dependency-graph access
and required-check configuration before claiming a merge is blocked. Hosted npm
uses Node22 and must independently pass; local Node25 evidence is not substituted.

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
