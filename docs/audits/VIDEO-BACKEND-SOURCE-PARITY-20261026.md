# Video backend source parity — October 26, 2026

This is a **source-only** recovery on `codex/video-backend-parity-20261026`. It does not deploy functions, apply SQL, run paid generations, or establish device acceptance. Keep this branch separate from Claude's luxury-site work.

## Live function bundles

| Function | Live version | Recovered source |
| --- | ---: | --- |
| `property-video-jobs` | 34 | Deployed entrypoint and job modules, including aerial opening, explicit Photo Motion, source custody, and accepted photo selection. |
| `property-video-plan` | 11 | Deployed planner entrypoint and source-custody guard. |
| `listings` | 62 | Deployed fresh-read listing creation and accepted-photo publication selection. |
| `property-video-worker` | 32 | Deployed entrypoint, engine, aerial worker, accepted-result retention, and Photo Motion/KIE prompt support. |

The bundles were read from the RendProp Supabase project `ymgqpbnjpztwjsyvceld` with `get_edge_function`. The worker bundle has 84 source files; 75 now match this branch's text hashes. The other nine are intentionally retained from newer source: jobs v34's `aerial-rpc.ts`, `aerial-public.ts`, `input.ts`, `runtime.ts`, `_shared/providers/kie.ts`, and `_shared/r2.ts`; plan v11's `_shared/providers/openai.ts`; the later restrictive `_shared/entitlements.ts`; and the later KIE-capable `property-video-worker/provider-diagnostic.ts`. These variants type-check together and preserve the newer trial and diagnostic controls. The jobs source also came from the existing local CLI staging bundle, with copied files checked against the live bundle.

The worker restoration includes the already-paid KIE retention path. It does not authorize a new generation, substitute media, or accept a result for publication by itself. Existing source-extraction test fixtures were updated to compile the new Photo Motion and registered-prompt dependencies instead of testing an obsolete snippet.

## Applied SQL recovered

For the 24 applied migrations dated October 21–24, 2026, all local files now match the live `supabase_migrations.schema_migrations.statements[1]` MD5 exactly. This branch adds the 23 files absent from GitHub; `20261023202520_photo_publication_internal_scope_validation_20261023.sql` was already present and already matched. This includes the explicit Photo Motion, 12% timeline, durable aerial opening, 1080p aerial route, prompt registry, and recovery-controller SQL. The migration files were recovered read-only and were **not** applied.

Earlier migration history is still divergent. Among the October 14–20 applied rows, 26 live migration versions have different local timestamps; 23 have the same SQL bytes under another filename. Three are not byte-identical: `photo_input_legacy_9mb`, `freeze_property_attempt_liability`, and `conservative_pipeline_cost_binding`. The last differs only by a trailing newline; the liability guard has a substantive earlier-source difference. Do not claim that a fresh database or `supabase db push` will replay the entire live history from this branch until that older version map and the concurrent October 26 trial/address migrations are reconciled. This recovery was deliberately limited to the missing October 21–24 video/aerial files rather than adding duplicate historical migrations that might execute twice.

## Verification

- `deno check` passed for the jobs, planner, worker, listings, and `ai-video` entrypoints.
- Worker suite: 90 passed, 6 intentionally ignored.
- Job suite: 75 passed.
- `ai-video` suite: 614 passed.
- 109 focused video jobs, planner, listings, publication, and consent fixture tests passed.
- 48 trial funding, purchase, and video attestation tests passed.
- 5 new Photo Motion input tests passed, covering the 2/3/3-second timeline, frozen directions, exact master identity, and refusal of an AI override or unaccepted aerial opening.
- All 24 October 21–24 migration MD5 values match the live statements; staged changes passed `git diff --check`.

No paid generation, live mutation, TestFlight build, or deployment was performed for this parity work.
