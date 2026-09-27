# Rendprop Supabase Edge Functions

Deno/TypeScript APIs shared by the iOS app, Studio and public tour host. Schema
comes from [migrations](../migrations/), including the legacy numbered migrations
and later timestamped releases; it does not stop at the original 0011 baseline.
See [backend architecture](../../../docs/BACKEND-ARCHITECTURE.md),
[upload/publication contract](../../../docs/UPLOAD-AND-PUBLISH-CONTRACT.md), and
[CI](../../../.github/workflows/ci.yml) for contracts and executable checks.

The latest Studio deployment is recorded in
[CODEX-STUDIO-LIVE-20260924](../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md).
It deployed the conversational Studio stack and four Presenter/prompt-library
migrations. Guided chat and prompt enhancement are live; optional LLM enhancement
and Higgsfield Presenter generation remain disabled. That record, not old setup
instructions or a function's presence in this directory, establishes deployment
versions and activation state.

Current source additionally implements named Studio projects, immutable private
media chunks, property-music handoffs and source-verified speech analysis. It seeds
bounded text routes while retaining separate endpoint enablement gates. These
changes await a new deployment receipt. See [projects and finishing](../../../docs/studio/projects-and-finishing.md)
and [activation/acceptance](../../../docs/studio/editing-intelligence-activation.md).

## Function map

Supabase routes requests to `/functions/v1/<name>` and retains subpaths.
`_shared/http.ts` provides `pathSegments` to normalize them. This inventory
describes handler responsibilities; gateway settings are a separate deployment
contract and must be preserved per function.

| Function | Access and responsibility |
| --- | --- |
| `listings` | Authenticated workspace listing CRUD, soft deletion and unpublication. |
| `uploads` | Authorized single/multipart/batch upload tickets, completion and abort; media goes directly to storage. |
| `renders` | Authorized native publication, worker jobs/status, publish and chapter updates; source visibility checks. |
| `me` | Current user/workspace/entitlements, brand and notification settings, device tokens, Apple exchange, account deletion and service-only cleanup. |
| `adopt` | Authenticated anonymous-to-connected workspace recovery with verified source/target authority. |
| `team` | Workspace members, seat limits, single/bulk invitations, atomic acceptance and management. |
| `property` | Authenticated property-data lookup/import. |
| `studio` | Authenticated media, revisioned property/named-project documents, private source chunks, music handoffs, source speech analysis, production review, prompt library and gated Presenter/text services. [Details](studio/README.md). |
| `ai-photo` | Authenticated photo transformations and prompting helpers using configured routing. |
| `ai-video` | Authenticated drone, declutter/reflection, aerial, reel and output-quality workflows; bound async status recovery. |
| `ai-copy` | Authenticated scripts, shot plans and agent cutaway assistance. |
| `ai-voice` | Authenticated voice catalog and narration with timing/alignment. |
| `ai-chapters` | Authenticated room/chapter assistance. |
| `coach` | Authenticated Ask Rendprop guidance. [Details](coach/README.md). |
| `ai-enhance` | Validates and queues worker enhancement requests; acceptance is not proof the worker produced output. |
| `spatial` | Capture/job lifecycle, gated provider execution and permission-checked scene/artifact access. [Details](spatial/README.md). |
| `tours` | Published, non-sensitive tour payload by slug, including current source permission checks. |
| `portfolio` | Published portfolio by handle; filters unavailable/revoked sources. |
| `leads` | Public protected lead submission; authenticated scoped inbox/status actions. [Details](leads/README.md). |
| `beacon` | Public tour engagement/metering events. |
| `events` | Authenticated product-event ingestion. |
| `admin` | Authenticated administrative operations with server-side admin authorization. |
| `apple-subscriptions` | StoreKit transaction verification and App Store server notifications, with route-specific authentication. [Details](apple-subscriptions/README.md). |
| `notify` | Service-only lifecycle outbox delivery and recovery; missing provider configuration can produce skipped delivery. |
| `presenter-drain` | Service-only Presenter recovery/cleanup; deployed but **unscheduled** in the latest release. |

`_shared/` contains authorization, HTTP/CORS, storage, entitlements, routing,
providers, ledger, notification and source-visibility helpers. It is bundled into
functions, not deployed as its own endpoint. Deploy affected imports from the same
source revision; source-file readback is stronger evidence than an upload log.

## Authorization and data boundaries

Owner/workspace routes validate the token and current membership, deletion state
and role. Per-request user clients enforce RLS; service clients operate only after
explicit authorization or through restricted transactional RPCs. Client-provided
organization, listing and object identifiers never grant access. `X-Org-Id` selects
a workspace only when membership permits it.

Public reads use a deliberately limited published subset, not arbitrary table
access. Application-level public access does not imply `verify_jwt=false`: the
tour host can supply a public legacy JWT to a gateway-verified read handler.
Newly issued media access also respects tracked Presenter revocation; previously
issued capabilities/downloads cannot be recalled immediately.

Provider, service-role, Apple and storage credentials stay server-side. Uploads
use direct storage tickets for property media; private project originals use
bounded authenticated immutable chunk writes. Document/text APIs do not imply
permission to send customer media to a generation provider. Speech analysis is a
separate explicit action over an authorized saved original. Estimated ledger entries are not provider
invoices. Metering, reservations and limits differ by route; do not assume one
universal hard spend cap covers every AI path. Consult the relevant handler and
[AI cost model](../../../docs/AI-COST-MODEL.md).

The shared error shape is `{ "error": string, "code": string, ...details }`.
Typical codes include `validation`, `unauthorized`, `forbidden`, `not_found`,
`conflict`, `plan_required`, `quota_exceeded`, `rate_limited`, `upstream` and
`internal`. RPC `RPnnn:` errors are mapped in `_shared/http.ts`; unknown server
errors should not expose credentials or internal records.

## Develop and verify

Use the Deno version pinned in [CI](../../../.github/workflows/ci.yml) (2.9.6 at the
recorded release). From this directory, typecheck a handler and run an isolated
fixture suite:

```bash
deno check --no-config --no-lock --node-modules-dir=auto studio/index.ts
deno test --no-config --no-lock --node-modules-dir=auto --deny-net --deny-run --deny-write --allow-read --allow-env studio/
```

Initial dependency resolution needs registry access. Network-denied tests use
fixtures rather than real identity, storage or paid providers. The complete CI
suite also typechecks every deployed entrypoint and exercises real disposable
PostgreSQL with the [schema tests](../tests/). Run fixture SQL only on an owned
throwaway database: some tests deliberately create/delete synthetic identities.

For Supabase local serving, stage the repository's nonstandard `services/supabase`
layout into a scratch standard `supabase/functions` directory with matching config
and local-only environment. Discover current CLI options with `supabase --help`
and `supabase functions serve --help`; do not copy production credentials into
fixtures or commit scratch staging. [Function configuration](https://supabase.com/docs/guides/functions/function-configuration)
documents per-function JWT settings.

## Production release

1. Confirm the source revision, project, live migration history and current
   per-function JWT settings. Apply only reviewed pending schema changes before
   dependent handlers; preserve intentional client-deny RLS/grants.
2. Stage the affected functions and shared imports from that exact revision.
   For a Presenter/privacy release, include every changed media read handler,
   not only `studio`.
3. Deploy with explicit existing gateway settings. Read back bundled source
   hashes, inspect schema/grants/advisors, and probe authentication boundaries
   before publishing dependent Studio assets.
4. Keep capability activation and paid-provider trials separate from deploying
   their disabled handlers. Record versions and verification limits in a handoff.

The updated [Studio backend helper](../../../apps/studio/scripts/deploy-backend.mjs)
implements selected-function staging, explicit deployment and source readback.
From `apps/studio`, `node scripts/deploy-backend.mjs --functions studio` is an
offline dry run. Adding `--run` uses the existing CLI login/environment, verifies
the live selection against [function-jwt-policy.json](../function-jwt-policy.json),
deploys only those functions and compares downloaded sources with the staged
hashes. Import closure, policy and receipts are preserved in a temporary directory.
The helper fails on live JWT drift and does not apply migrations, activate
providers, deploy new unlisted functions or infer every affected entrypoint.

The 24 September release preserved these settings:

| Function | Version | `verify_jwt` |
| --- | ---: | --- |
| `studio` | 10 | true |
| `renders` | 38 | true |
| `tours` | 41 | true |
| `portfolio` | 35 | false |
| `presenter-drain` | 1 | true, plus internal service-role authorization |

The production-review migration ledger was reconciled to `20260924153826` without
reapplying its SQL. The four subsequent Presenter/prompt-library source versions
were applied and matched. Older historical ledger differences remain; an
unreviewed `db push --include-all` is not a safe reconciliation procedure.

**Legacy helper limitations:** [deploy-functions.sh](../deploy-functions.sh)
lists 17 functions, omits newer handlers, and would set `tours` JWT verification
false. It remains unsuitable as a whole-product release command. Use the updated
explicit-selection helper above and choose all affected read handlers. Earlier sections of
[DEPLOYMENT.md](../DEPLOYMENT.md) document older rollout/setup work; use the latest
release record for current production facts.

## Configuration and scheduled work

Supabase supplies its own URL and API credentials to hosted functions. Additional
server-only configuration includes R2/Stream access, public tour/media origins,
provider credentials, job-token signing, Apple exchange/revocation, optional CRM,
and notification delivery. Use the relevant handler/feature documentation as the
exact variable contract; a listed adapter does not prove the account is enabled
or correctly priced. Never place these secrets in Studio `VITE_*` variables.

Lead capture verifies Turnstile and uses a durable limiter. Missing
`TURNSTILE_SECRET_KEY` fails closed unless the explicit development/operational
opt-out is configured; the public site key alone does not establish protection.
Notifications and team invitation enqueueing are implemented. Delivery depends
on provider configuration, preferences and an authenticated outbox schedule;
queued/skipped status is not evidence of delivery.

Account-deletion/storage sweepers and `notify` need their existing authenticated
operations schedule. Inspect current schedules before creating duplicates.
`presenter-drain` is the exception documented above: it remains unscheduled and
Presenter runtime remains disabled. In the recorded production baseline the
Studio text routes were also disabled; current source seeds eligible routes but
still requires separate environment gates. Speech analysis shares existing
Whisper routing with its own limits. See [editing intelligence activation](../../../docs/studio/editing-intelligence-activation.md)
for exact configuration, estimated accounting and live acceptance requirements.
