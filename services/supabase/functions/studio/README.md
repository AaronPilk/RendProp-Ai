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

## Route map

| Route | Purpose |
| --- | --- |
| `GET /media` | Listing-scoped, paginated photos, completed capture assets and renders; short-lived signed reads. |
| `GET/POST /documents` | User/workspace documents, including property edit + conversation, content plans, capture plans and prompt collections; revision checks and recovery. |
| `GET /listing-state` | Listing production state and related media information. |
| `POST/PATCH /photos`, `POST /floorplan` | Attach verified uploaded media and edit gallery order/captions/disclosure through scoped actions. |
| `/voice`, `/video`, `/video-status`, `/creative-results`, `/sign-media`, `/edit-output` | Existing creative generation/recovery, output visibility and explicit saved-edit handoffs. |
| `GET/POST /production-review`, `GET /production-review-queue`, `/production-review/narration` | Versioned production review, approval and narration reads. |
| `GET/POST /presenter`, `POST /presenter/media`, `/presenter/jobs` | Subject profiles, approval/revocation, source preview and gated durable jobs. |
| `GET/POST /edit-plan`, `GET/POST /prompt-enhancement` | Optional text-service capabilities and proposals; no server-side render, upload or publication. |

Read [index.ts](index.ts) and the route handlers for exact methods and payloads.
[Agency workflow](../../../../docs/studio/agency-production-workflow.md),
[conversational creation](../../../../docs/studio/conversational-creation.md),
[Presenter execution](../../../../docs/studio/presenter-execution-rpc.md), and
[prompt library](../../../../docs/studio/prompt-library.md) describe their contracts.

## Media and privacy

`GET /media?org_id=<uuid>&listing_id=<uuid>&offset=0` checks user-token RLS and
current membership. If `X-Org-Id` is supplied it must agree with `org_id`. Pages
examine up to 50 photos, 50 completed capture assets and 50 stored renders;
`next_offset` advances by 50 or is null. An oversized collection fails visibly at
the paging boundary instead of claiming completeness.

Signed reads expire after 600 seconds and are restricted to canonical authorized
objects. Unavailable/unlinked outputs are counted, not issued unrestricted object
capabilities. Presenter permission checks also follow tracked derived media before
new URLs are issued. Previously issued links and downloaded files cannot be
instantly recalled. Private bucket credentials stay on the server; browser GET,
HEAD and Range require the exact Studio-origin R2 CORS policy.

The media-read route itself creates no upload or generation job; its rate-limit
counter is its only mutation. Other Studio routes deliberately support writes and
use role checks, service-only RPCs and scoped ownership checks as appropriate.

## Optional text services and Presenter gates

`copy.edit_plan` and `copy.prompt_enhancement` require eligible configured pricing
and the documented `STUDIO_EDIT_PLANNER_*` configuration. Neither is automatically
inserted/enabled. Requests omit file bytes, source filenames, fingerprints and
URLs; user-supplied text is still sent if the service is enabled. Each attempt has
one bounded provider call, retry suppression, rate limits and estimated accounting.
This is **not a hard dollar reservation or verified invoice**.

Enhancement proposes wording only; the browser reviews original/proposal and
acceptance fills the composer without sending. Edit plans propose finite validated
operations. Neither endpoint activates Presenter generation.

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
JWT settings and deploy all dependent privacy read handlers (`studio`, `renders`,
`tours`, `portfolio`) together. The legacy all-functions and Studio backend helpers
are incomplete for this release; use the targeted release procedure and source
readback described in the [production record](../../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md).
