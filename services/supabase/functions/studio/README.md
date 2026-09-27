# Studio media and creation APIs

The authenticated API behind [Rendprop Studio](../../../../apps/studio/README.md).
All routes use `/functions/v1/studio`. Deploy with JWT verification enabled;
handlers also check Supabase Auth, account deletion, current membership, selected
workspace and listing access. Workspace selectors are requests, never authority.
Non-media actions require a non-anonymous connected account.

The [24 September release](../../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
deployed **studio v10**, including the production workflow, Presenter preparation,
prompt library and optional text endpoints. Guided chat/enhancement run in the
browser and are live. Optional LLM text routes and Higgsfield generation remain
**disabled**. This API is no longer only the original read-only media bridge.

Current source extends that baseline with private named projects and media chunks,
music handoffs, verified source speech, and text-route seeds. These additions
await their own deployment and activation receipt; the route inventory below
describes source capability, not a claim that every route is already live.

## Route map

| Route | Purpose |
| --- | --- |
| `GET /media` | Listing-scoped, paginated photos, completed capture assets and renders; short-lived signed reads. |
| `GET/POST /documents` | User/workspace documents, including named projects, property edit + conversation, content plans, capture plans and prompt collections; revision checks and recovery. |
| `GET /projects` | Private named-project summaries for the current account/workspace; saves use `/documents`. |
| `GET/POST /project-media`, `PUT /project-media/:id/:part` | Private source lookup/reservation and bounded immutable chunk upload; exact actor/org authorization and integrity receipts. |
| `GET/POST /property-music`, `POST /production-review/music` | Explicit attachment and restoration of selected music, including exact submitted-review access. |
| `GET/POST /media-analysis` | Gated word-timed speech and source-backed passage suggestions for a saved property or private project video. |
| `GET /listing-state` | Listing production state and related media information. |
| `POST/PATCH /photos`, `POST /floorplan` | Attach verified uploaded media and edit gallery order/captions/disclosure through scoped actions. |
| `/voice`, `/video`, `/video-status`, `/creative-results`, `/sign-media`, `/edit-output` | Existing creative generation/recovery, output visibility and explicit saved-edit handoffs. |
| `GET/POST /production-review`, `GET /production-review-queue`, `/production-review/narration` | Versioned production review, approval and narration reads. |
| `GET/POST /presenter`, `POST /presenter/media`, `/presenter/jobs` | Subject profiles, approval/revocation, source preview and gated durable jobs. |
| `GET/POST /edit-plan`, `GET/POST /prompt-enhancement` | Optional text-service capabilities and proposals; no server-side render, upload or publication. |

Read [index.ts](index.ts) and the route handlers for exact methods and payloads.
[Agency workflow](../../../../docs/studio/agency-production-workflow.md),
[conversational creation](../../../../docs/studio/conversational-creation.md),
[projects and finishing](../../../../docs/studio/projects-and-finishing.md),
[Presenter execution](../../../../docs/studio/presenter-execution-rpc.md), and
[prompt library](../../../../docs/studio/prompt-library.md) describe their contracts.

## Media and privacy

`GET /media?org_id=<uuid>&listing_id=<uuid>&offset=0` checks user-token RLS and
current membership. If `X-Org-Id` is supplied it must agree with `org_id`. Pages
examine up to 50 photos, 50 completed capture assets and 50 stored renders;
`next_offset` advances by 50 or is null. An oversized collection fails visibly at
the paging boundary instead of claiming completeness.

Listing-media signed reads expire after 600 seconds and are restricted to canonical authorized
objects. Unavailable/unlinked outputs are counted, not issued unrestricted object
capabilities. Presenter permission checks also follow tracked derived media before
new URLs are issued. Previously issued links and downloaded files cannot be
instantly recalled. Private bucket credentials stay on the server; browser GET,
HEAD and Range require the exact Studio-origin R2 CORS policy.

The media-read route itself creates no upload or generation job; its rate-limit
counter is its only mutation. Other Studio routes deliberately support writes and
use role checks, service-only RPCs and scoped ownership checks as appropriate.

Private project originals use 8 MiB immutable parts, at most 128 MiB per source
and 512 MiB reserved per workspace. Lookup and fresh signing recheck the exact
account/workspace, membership and deletion state. Part URLs expire after 120
seconds; clients verify part hashes and the assembled SHA-256. Expired upload
authority does not prevent reading a completed owned original. Account deletion
inventories every possible chunk before removing metadata. Archive is not storage
cleanup, and individual-file deletion is not supplied by this release.

Property music is private until explicitly attached and selected for review.
New copy access requires a currently shared exact document revision. A completed
copy retains its narrow immutable-version grant after author withdrawal; future
copies are denied, and current access still requires membership and available
source/account records. These grants never make the uploader's other files public.

## Optional text services and Presenter gates

`copy.edit_plan` and `copy.prompt_enhancement` require eligible configured pricing
and the documented `STUDIO_EDIT_PLANNER_*` configuration. A new migration seeds
eligible rows only for absent tasks, preserving existing operator choices. It does
not set environment gates or change the router master flag. Requests omit file
bytes, source filenames, fingerprints and
URLs; user-supplied text is still sent if the service is enabled. Each attempt has
one bounded provider call, retry suppression, rate limits and estimated accounting.
This is **not a hard dollar reservation or verified invoice**.

Enhancement proposes wording only; the browser reviews original/proposal and
acceptance fills the composer without sending. Edit plans propose finite validated
operations. Neither endpoint activates Presenter generation.

Speech analysis has its own enablement and allowance. It accepts either a
listing-bound asset/render identity or an owned `project_media` identity, never a
client URL. Private project parts and the full source SHA are verified before
provider dispatch. Source access is checked again before returning results. Words
and suggestions are bounded to actual source times and require review; no visual
quality or factual certification is implied. See [editing intelligence activation](../../../../docs/studio/editing-intelligence-activation.md)
for the strict limits, price estimates and one-attempt behavior.

Presenter execution additionally requires explicit enterprise-processing terms,
pricing, budget, credentials and runtime activation. The production runtime table
has no enabled row; `presenter-drain` is deployed separately but unscheduled.
See [AI Presenter](../../../../docs/studio/ai-presenter.md) before activation.

## Verify and release

From the repository root, with the CI Deno version and cached dependencies:

```bash
deno check --no-config --no-lock --node-modules-dir=auto services/supabase/functions/studio/index.ts
deno test --no-config --no-lock --node-modules-dir=auto --deny-net --deny-run --deny-write --allow-read --allow-env services/supabase/functions/studio/
```

Fixtures test route contracts, scope and rejection paths. Dedicated disposable
PostgreSQL suites under [tests](../../tests/) verify real grants, transactions and
RPCs; mock handlers alone do not establish production RLS. See
[CI](../../../../.github/workflows/ci.yml) for the complete matrix.

Apply required schema before handlers, then Studio assets. The four Presenter/
prompt-library migrations and the prior production-review ledger mismatch were
resolved in the latest release record. Do not reapply that SQL or use an unreviewed
`db push --include-all` to repair older migration history. Preserve per-function
JWT settings and include every affected privacy read handler (`studio`, `renders`,
`tours`, `portfolio`) when changing shared source-visibility behavior. The updated
[deployment helper](../../../../apps/studio/scripts/deploy-backend.mjs) requires
explicit `--functions` selection and is offline unless `--run` is supplied. It
checks fresh live JWT policy, stages the parsed import closure, deploys the
selection and verifies downloaded source hashes. It does not apply schema or
activate providers. Record new versions and results separately from the existing
[production baseline](../../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md).
