# Offline reel style-policy foundation

This is **planning and experiment bookkeeping**, not a renderer or live feature.
It never calls providers, changes routes, rewrites motion prompts, or publishes.
All three original generic styles are draft-only. No accounts or dependencies
are required beyond an existing Deno installation (verified with 2.7.13).

## Run the complete gate

From the repository root:

```sh
deno run --no-config --no-lock --cached-only --deny-net --deny-env --allow-read --allow-write=/tmp --allow-run tools/style-policy/verify.ts
```

The verifier's only subprocess is its own Deno executable with a cleared
environment. Child tests deny network, environment and subprocess access. The
verifier writes small synthetic fixtures, copied-source mutants and logs to a
new `/tmp/rendprop-style-policy-verify-*` directory; it never deletes them. It
first requires a deliberately invalid CLI registration to exit 1, then requires
exactly 101 tests with zero failures/ignored tests, positive CLI flows, and
seven deliberately defective implementations to fail their real tests. Any
unexpected outcome makes the verifier exit 1. The printed evidence directory
contains `summary.json` and each command's exit/output log.

Unit tests only (no runtime filesystem permissions required):

```sh
deno test --no-config --no-lock --cached-only --deny-net --deny-env --deny-run tools/style-policy/policy_test.ts tools/style-policy/compile_test.ts tools/style-policy/experiment_test.ts
```

## Interfaces

- `policy.ts`: `CATALOG`, `catalogRefs()`, `validateCatalog(raw)`,
  `resolveStyle(ref)`. References require exact ID, version and canonical
  SHA-256. `null` means legacy, never an implicit style. Objects are deeply
  frozen; catalog snapshots pin the three version-1 payload digests.
- `compile.ts`: `compileStyle(ref, edl)` validates and copies a strict offline
  envelope, retaining all EDL JSON values and its canonical hash. Whitespace and
  object-key order in the source file are not byte-preservation claims. Timings,
  photos, motions, captions and original audio declarations are not altered.
  Transition/caption intent is separate; **none of it is rendered or applied**.
- `experiment.ts`: `preregister`, `validateSeal`, `bindAssets`, `validateBound`,
  `blindAssignments`, `expectedAssets` (private operator mapping),
  `scoreExperiment`.
- `cli.ts`: `catalog`; `compile STYLE_REF.json EDL.json`; `register INPUT.json`;
  `asset-plan REGISTRATION.json`; `bind REGISTRATION.json ASSETS.json`;
  `assign BOUND.json`; `score BOUND.json SCORES.json`. Inputs are regular JSON
  files, at most 1 MiB each. Unknown commands, keys, malformed/nonfinite values,
  duplicate IDs and incomplete data fail exit 1. The CLI only writes its result
  to stdout; it has no generation command.

For example, supply read access only to the selected local fixture directory:

```sh
deno run --no-config --no-lock --cached-only --deny-net --deny-env --deny-run --allow-read=/tmp/your-owned-fixtures tools/style-policy/cli.ts register /tmp/your-owned-fixtures/input.json
```

Use the verifier's generated files as clearly marked **synthetic examples** of
registration, score, style-reference and EDL schemas; do not submit their scores
as a quality study. `test_helpers.ts` is fixture-only, not a production adapter.

## Safety and capability boundary

Every compiled result states `stage=offline-plan`, `room_safety=unverified`,
`publication_ready=false`, `live_api_applied=false`, `rendered=false`, and an
empty `applied_effects`. Timing, motion, music, grade, transition and caption
treatment are explicitly unapplied. A bathroom orbit may be preserved as input
without being approved; vocabulary validation is **not** a room-veto validator.
The private upstream room allowlist is not copied or approximated. Live adoption
requires a separately reviewed authoritative accessor and safety integration.

The agent envelope requires supplied photo identities and phrase boundaries,
plus the original-audio hash declaration. It validates the existing lead/tail,
window, gap, coverage, caption and count limits using upstream constants. It
does not prove the boundaries came from genuine speech or that audio bytes match
the declared hash. Unknown/extra API fields require an explicit adapter; this is
not a drop-in live response decoder. Negative zero is refused instead of
normalized.

No fair-housing clearance, privacy review, room geometry guarantee, tenant
authorization or renderer capability is established by these offline tools.

## Blind pilot protocol

Registration fixes 24 distinct same-listing pairs, 4 per each of 6 strata, 3
distinct declared raters, configuration/input digests, a candidate style pin and
seed. The immutable protocol fixes six equally weighted 1–5 criteria, five
binary critical-defect categories, 72 judgments and 48 declared outputs. All
data must arrive: no optional/missing/duplicate scores, early stopping, post-hoc
rubric or threshold changes. Ties are not candidate wins. Advancement's
diagnostic threshold is 18 majority-preferred pairs, no new critical defects and
no lower median property-fidelity score.

Commit the registration file/hash to a separately retained record **before**
generating/selecting outputs. Once permitted outputs exist, `bind` validates and
freezes their 48 declarations with `asset_manifest_sha256`; retain that bound
file before `assign` or scoring. Reviewer packets and score submissions carry
this same hash. A replacement declaration, even a freshly rebound one, cannot
reuse the old score packet unchanged. A local hash detects mismatch against a
retained record; it is not a trusted timestamp and cannot stop someone replacing
every record and score hash together. Output/rights/rater identities remain
declarations, not independently authenticated by this harness.

Give raters only `assign` output and opaque media. Never give them registration,
the bound operator manifest, `asset-plan` output, filenames or metadata
revealing variants. For actual reviews use a privately generated high-entropy
64-hex seed; the all-zero seed is synthetic-fixture-only. Assignment puts the
candidate on side A exactly 12 times per rater; display order uses a separate
domain-separated shuffle, so first-half position does not encode candidate side.
Opaque asset IDs also include the private seed. Blinding hides labels, not
visible stylistic differences. `asset-plan` stays private and binds both
variants to the same listing input. Identical pair output hashes are rejected as
no treatment contrast.

`score` verifies metadata bindings but **does not read media bytes**. Even
perfect synthetic scores return `quality_win_claimed=false`; actual
existing-media reviews also remain exploratory, with no publication or
population claim. Paid generation, human-rater independence, real output
quality, delivery format, licensed music/color effects and representative
performance are unproved.
