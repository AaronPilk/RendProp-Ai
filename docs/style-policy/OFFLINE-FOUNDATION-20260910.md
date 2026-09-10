# Offline style-policy implementation

Base: `f14081d49d5fb40b1dde59562176692ddb2664c6`. Isolated branch:
`feat/reel-style-policy-20260910`.

Owned additions are confined to `tools/style-policy/` and this note. No existing
motion/agent-reel source, routing, renderer, provider configuration, migration,
app source or publication flow is modified. The sparse checkout uses only the
small local dependency closure; no package install or service call is needed.

## What is implemented

Three original generic draft styles (`clear-tour`, `editorial-calm`,
`concise-highlights`) have frozen canonical version-1 payloads and SHA-256 pins.
The resolver is deterministic and requires exact reference identity. Omitted
style stays legacy. The immutable compiler accepts strict offline agent/photo
EDL envelopes and returns separate presentation intent; **all effects remain
unapplied**, and it cannot label an EDL room-safe or publication-ready.

It imports only local pure constants/helpers from `ai-video/motion.ts`,
`ai-copy/agentreel.ts` and `ai-copy/shotlist.ts`. The latter's local dependency
closure contains prompt/guard text but no route entrypoint or service client.
Supabase skill review informed this strict separation; no database operation was
relevant or performed. The complete frozen motion-text hash is tested.

The A/B harness is executable local bookkeeping: preregistration, commitment
validation, opaque balanced assignment, private asset binding and complete
scoring. Its fixed 24 pairs × 3 raters require 72 judgments, six predeclared
criteria, exact metadata identity and no duplicate/missing scores. Synthetic
perfect scores are explicitly protocol exercise evidence, never a quality win.

## Verification gates

`tools/style-policy/verify.ts` checks the deliberately invalid CLI first (must
exit 1), 101 typed Deno tests (zero skips), real
register/bind/assign/score/compile CLI flows, and seven modified-source
implementations. Those mutants bypass a style hash, alter the EDL, claim room
safety, claim a quality win, allow zero scores, leak candidate side through
display order, or accept substituted output declarations. Each must execute
tests and exit 1 with actual failed assertions; a syntax, type-loading or
missing-permission failure does not count as mutation detection. The normal
compiler is additionally exercised over all 408 combinations of 17 room hints ×
8 motion enums × 3 styles, always preserving the EDL and withholding safety
claims. An agent fixture is produced through the actual upstream planner/parser
rather than a substitute implementation.

Exact commands and invocation permissions are in `tools/style-policy/README.md`.
The verifier prints a unique retained `/tmp` evidence directory and writes
`summary.json`, full bounded test logs, synthetic JSON fixtures and mutant logs.
It exits nonzero on any unexpected count or result. No cleanup/delete behavior
is included. Final task handoff records the implementation commit and final run.

Independent review caught two pre-commit harness gaps: balanced side allocation
initially doubled as display order, and score results did not commit to declared
output hashes. The implementation now uses independent seeded display ordering
and a separate `bind` stage before assignments. Bound output manifest hashes are
required in packets, score submissions and reports. Tests reproduce both prior
failure modes, and actual copied-source mutations prove those tests fail if the
protections are removed. Neither fix claims actual media-byte verification or a
trusted preregistration timestamp.

## Deliberate limits and integration gates

This code is not imported by any live API. It does not resolve the existing
room-veto divergence: explicit reel motion accepts vocabulary without a room
intersection, and the shot-list closer can choose bathroom `pull_back` despite
the private motion table's veto. Copying a unsafe legacy choice does not approve
it; compiled output says `room_safety=unverified`. An authoritative room
accessor, shared enforcement and renderer parity require separate review.

There is no music/beat/grade/timing execution or agent-EDL rendering here. The
compiler does not verify actual audio, images, transcript truth, compliance,
privacy, tenant authorization or provider rights. The harness checks declared
media hashes and configuration bindings, not physical media bytes or rater
independence. Its local commitment needs an externally retained preregistration
record; it is not a trusted timestamp. Even a met diagnostic threshold does not
authorize publication, paid generation, route wiring or a quality claim.

Live work must preserve server-side fair-housing enforcement, existing routing
and cost accounting, and add only explicitly reviewed style snapshot metadata.
Do not present these three draft policies as effects currently available in the
app. Spatial phases B–E remain untouched.
