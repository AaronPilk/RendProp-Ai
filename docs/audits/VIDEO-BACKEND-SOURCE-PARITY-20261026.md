# Video backend source parity — October 26, 2026

This is a **source-only** recovery in `codex/video-backend-parity-20261026`. It does not deploy functions, run paid video generations, apply SQL, or establish phone acceptance.

## Compared with live Supabase

| Function | Live version | Source result |
| --- | ---: | --- |
| `property-video-jobs` | 34 | Its deployed entrypoint, internal modules, and KIE adapter changes were restored. The aerial and explicit Photo Motion routes are present. |
| `property-video-plan` | 11 | Its deployed source-custody guard and entrypoint were restored. |
| `listings` | 62 | Its deployed fresh-read listing create and accepted-photo publication selection guard were restored. |

The deployed bundles were read from the RendProp Supabase project `ymgqpbnjpztwjsyvceld` with `get_edge_function`. The jobs source came from the existing local CLI staging bundle at `/Users/pilksclaes/Rendprop AI/.tmp/jobs33-normal-cli-stage/supabase/functions`; each copied source file was checked against the live bundle before use. The plan and listings changes came directly from their live bundles. Of 100 distinct files represented in those three bundles, this branch matches all except the following intentionally newer shared sources:

- `_shared/entitlements.ts`: retain the later, restrictive trial policy; the v34 jobs bundle contains the older, broader fallback.
- `_shared/r2.ts`: retain the newer jobs/listings variant; the v11 plan bundle contains an older variant.
- `_shared/providers/openai.ts`: retain the newer plan variant; the v34 jobs bundle contains an older variant.

The source changes are not a deployment package. Live `property-video-worker` is version 32 and differs from this repository, including its entrypoint, engine, aerial worker and retention code. Several live-applied SQL migrations for Photo Motion, aerial openings, prompt profiles, and recovery are absent from this branch's migration source, including `20261021222704`, `20261022223052`, `20261023200943`, and `20261024000646`. Reconcile the worker and those migrations before attempting to reproduce production or redeploy this backend from GitHub.

## Verification

- `deno check` passed for all three entrypoints.
- 109 focused video jobs, planner, listings, publication, and consent fixture tests passed.
- 48 trial funding, purchase, and video attestation tests passed.
- 5 new Photo Motion input tests passed, covering the 2/3/3-second timeline, frozen directions, exact master identity, and refusal of an AI override or unaccepted aerial opening.
- `git diff --check` passed.

No paid generation, live mutation, TestFlight build, or deployment was performed for this parity work.
