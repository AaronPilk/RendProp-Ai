# Conversational Studio production release — 24 September 2026

Deployed after the owner's explicit “push it live” instruction.

Application source: `d6e30361a82947e96233913a8689b4de8da2175f`.
GitHub main fast-forwarded from `d14cc1b` to this exact tested commit without force.
PRs #6 and #7 are merged. Shared Claude checkouts were not changed.
This record supersedes the **not deployed** status in the earlier Presenter and
conversational Studio handoffs; their activation boundaries still apply.

## Live layers

Studio: https://studio.rendprop.com/

- Cloudflare Worker `rendprop-studio` version
  `bd135a4d-570a-4c05-bb92-72e3fcf6d6f7` at 100%.
- Deployment `07f151e7-499e-48d7-94c4-4b35b4f4539e`,
  `2026-09-24T20:27:06.487554Z`.
- Supabase project `ymgqpbnjpztwjsyvceld`.

| Function | Active version | verify_jwt | Bundled files matched |
| --- | ---: | --- | ---: |
| studio | 10 | true | 38 |
| renders | 38 | true | 6 |
| tours | 41 | true | 10 |
| portfolio | 35 | false | 8 |
| presenter-drain | 1 | true | 13 |

All **75 API-listed source files** match the release checkout by SHA-256.
Existing JWT settings were preserved; the new drain also checks service-role
authorization internally and remains **unscheduled**. No drain request was run.
The unchanged ai-photo/ai-video paths were not redeployed merely because their
shared Higgsfield file now also contains the unused Presenter adapter.

## Database

The already-applied production-review SQL was verified against the repository
(only its final newline differed), including nine function bodies, grants, RLS
and trigger. Its ledger version was changed from `20260924165200` to
`20260924153826`, guarded by the exact recorded SQL MD5. The SQL was not reapplied.

Applied these four exact source files in order with the migration API:

1. `20260924174114_studio_presenter_workspace.sql`
2. `20260924180853_studio_presenter_execution.sql`
3. `20260924184052_studio_prompt_library.sql`
4. `20260924184319_studio_presenter_media_revocation.sql`

The API's generated ledger versions were normalized to these source versions,
guarded by full statement-array equality and absent destination versions. Older
historical filename/ledger differences were not broadly repaired. Do not use an
unreviewed `db push --include-all` to reconcile those differences.

Readback verified 31 final function bodies, nine patched existing functions with
unchanged grants, seven new service-only tables with RLS and no client privileges,
three restrictive policies and 13 enabled triggers. Runtime, quotes, jobs and
closed submissions are empty; no Presenter schedule or new text routes exist.

Security advisor before: 1 ERROR / 42 WARN / 30 INFO; after: 1 / 47 / 37.
The additions are exactly seven intentional deny-all table notices and five
authenticated, membership-scoped access-predicate warnings. Existing findings,
including the `ai_routes_expiring` security-definer view, remain unchanged.
This release does not claim the entire project's advisor is clean.

## Build and verification

The local test build initially lacked production Supabase configuration. It was
rebuilt using only the two public Vite values from the earlier agency release's
`.env.production.local`. Both values matched the previously live bundle. The
expected project URL and exact publishable key were verified in the new bundle;
key fingerprint prefix `20fbe3da1853`. No server credential entered the frontend.
Connected build JavaScript gzip total: **293,933 / 300,000 bytes**.

- Exact application commit CI: **12/12 jobs passed**, run `36051791633`.
- Release build typecheck, build, asset checks and Wrangler dry-run passed.
- Live custom-domain verifier: **27/27 files**, hashes/security headers and SPA
  fallback passed at `2026-09-24T20:27:33.703Z`. The known managed robots prefix
  remains; crawl blocking is not claimed, while noindex remains enabled.
- Unauthenticated probes to edit-plan, prompt-enhancement, documents, presenter,
  renders, tours and presenter-drain all returned 401.
- Actual signed-in browser restored the existing workspace and property list.
  Create, Chat/Simple/Pro views and Improve prompt were visible. Live guided
  enhancement changed “Make it square” to “Set the ratio to 1:1” for review;
  acceptance filled the composer without submitting or changing the draft.
  The temporary prompt was cleared. No property draft was overwritten.

No new camera, real-phone sync, fresh Apple OAuth exchange or live model-quality
test was performed. No customer media was uploaded or paid provider called.

## Still disabled and release cautions

Guided chat edits and guided prompt enhancement are live. Optional LLM routes
`copy.edit_plan` / `copy.prompt_enhancement` and their activation secrets remain
absent. Higgsfield Presenter generation remains disabled per the owner, with no
runtime row, enterprise confirmation or budget. Existing unrelated AI features
and spatial settings were not changed. No iOS/App Store Connect action occurred.

The older `apps/studio/scripts/deploy-backend.mjs` does not select all functions
required by this combined release and forces a uniform JWT setting. This release
used isolated targeted staging with the five explicit settings above. Do not
reuse that older helper unchanged for Presenter/privacy releases. Likewise,
`check-dist` alone does not prove a connected production build: verify the public
connection settings before every website deployment.

Local detailed receipts:

- `/tmp/rendprop-creation-deployed-assets-20260924.json`
- `/tmp/rendprop-edge-release-readback-20260924.json`
- `/tmp/rendprop-release-db-check-Jh1lI3/receipt.json`
- `/tmp/rendprop-creation-auth-probes-20260924.json`
- `/tmp/rendprop-creation-worker-deployment-20260924.json`

These are deployment evidence, not proof of real-person generation quality.
