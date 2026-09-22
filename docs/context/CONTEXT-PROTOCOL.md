# Rendprop engineering handoff protocol

This protocol records work; it does not authorize a deployment, provider expense,
customer-data transfer or Apple change. Owner instructions and the standing brief
still govern those decisions. Update STATUS after a meaningful result, before a
context/model handoff, and whenever a previous conclusion changes.

## Required record for every unit

- **Requested outcome:** what should work for the customer, not only which files
  should exist. Spatial means navigating the captured room, not exporting images.
- **Source:** full commit, branch, worktree, clean/dirty state, owned files and
  integration status. Keep source changes distinct from untracked test artifacts.
- **Implementation:** behavior changed, reason, compatibility/rollout effects,
  and what was deliberately left unchanged. Include actual code/file anchors.
- **Proof:** exact command, exit status, assertion/test count, skipped count,
  fixture type, tested commit, result/log paths and hashes when available.
  “Compiled,” “screen captured,” “uploaded,” and “works on device” are different
  claims. A diagnostic that intentionally exposes an open defect stays red.
- **Negative control:** identify the real broken behavior the gate detects.
  Missing binary/filter/fixture is unavailable verification, not a passing test.
- **Limits/open work:** no untested live integration, visual quality, performance
  or runtime configuration becomes verified by inference from unit tests.
- **Delivery:** pushed commit/branch, integrated commit, deployed service/build
  only if actually deployed, and exact rollback/recovery boundary if applicable.

## Parallel work and review

One bounded unit per branch. Review a pinned commit in a stable worktree. Do not
switch or reuse that worktree while another agent is testing it; announce the
handoff and create a separate worktree for the next unit. This pass caught two
wrong-tree test attempts when branches changed under reviewers; neither was
counted as verification of the intended source. Never compensate by weakening
the assertion or accepting a smaller test count.

The integrator reads the actual diff and meaningful tests, then reruns relevant
gates on the merged source. A fresh full-app receipt must bind the final app/test
bundle and exact XCTest IDs to a clean source tree. Later changes invalidate the
claim that the earlier result covers those changes, even if they look small.

## Status vocabulary

| State | Meaning |
|---|---|
| Found | Concrete evidence exists; not repaired |
| Implemented | Source changed; verification may remain |
| Tested locally | Named checks executed against named source; not deployed |
| Tested on hosted CI | Exact run/job URL and source SHA read back, commands/counts checked; still not deployed |
| Independently reviewed | Another reviewer inspected the source/proof |
| Integrated and pushed | Included in the named remote branch |
| Deployed | Provider/Apple state explicitly read back and source binding recorded |
| Device-verified | Owner/real-device evidence records the exact build and flow |

Use FIXED/PARTIAL/NOT FIXED only with scope: a repaired local worker function is
not a production rollout, and a valid capture is not completed spatial delivery.
Do not mark the whole application GO merely because some suites pass.

## Hosted CI and corrected findings

Record the overall workflow conclusion separately from each job. An edge
entrypoint typecheck passing does not mean tests compiled or executed. A worker
job may genuinely pass HDR while a separate database invariant remains red.
Record the selected runtime versions: this pass found a timer type error on
Deno2.9.6 that the local2.7.13 suite did not reproduce. A narrow local pass
cannot certify the different hosted type environment.

When a negative control fails, inspect the reason before calling it proof. The
first removed scalar-guard experiment hit an existing duration constraint,
not the intended acceptance assertion. Keep that failed attempt in the report,
correct the claimed defect, and show the later intended failure plus restored
positive result. Never erase an inconvenient earlier result or quietly count
unexecuted/skipped stages as covered.

`VERIFICATION-INDEX.json` is a curated receipt/hash index, not the raw artifact
backup. GitHub artifact retention is finite; expired artifacts mean the bytes
are unavailable even if the durable Markdown still records their historical
result. Update existing reports when a fix supersedes a finding, rather than
leaving an older “still open” section as the apparent current diagnosis.

## File map

- `docs/context/RENDPROP-CONTEXT.md`: front door and historical context.
- `docs/audits/2026-09-10/STATUS.md`: living engineering checkpoint.
- Per-lane audit documents: detailed findings, literal reproduction/repair plans.
- `docs/releases/`: source-bound release receipts; no private signing material.
- `docs/handoff/`: bounded implementation/verification handoffs.
- `docs/web-client/`: architecture/parity/editor work and unbuilt capability gaps.
- `docs/spatial-spike/`: real-room experiment state and deployment prerequisites.

Keep private captures, raw room geometry, customer transcripts, tokens and archive
signing material out of Git and shared logs. Context should contain enough code,
commands and factual diagnostics for another engineer to continue, without
requiring that engineer to reconstruct this conversation or trust prior prose.
