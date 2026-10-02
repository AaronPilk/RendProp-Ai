# Rendprop Supabase Edge Functions

Deno/TypeScript APIs shared by the iOS app, Studio and public tour host. Schema
comes from [migrations](../migrations/), including the legacy numbered migrations
and later timestamped releases; it does not stop at the original 0011 baseline.
See [backend architecture](../../../docs/BACKEND-ARCHITECTURE.md),
[upload/publication contract](../../../docs/UPLOAD-AND-PUBLISH-CONTRACT.md), and
[CI](../../../.github/workflows/ci.yml) for contracts and executable checks.

## Preparing direct Bria internal beta

The [build-43 handoff](../../../docs/handoff/BRIA-PHOTO-VERSIONS-BETA-20261002.md)
is **PREPARING**: its migration and `ai-video` changes are not deployed and the
TestFlight binary is not uploaded. Direct Bria requires the internal client's
consent-v3 acknowledgement, `BRIA_BETA_ENABLED=true`, a server-configured
`BRIA_BETA_USER_IDS` list containing the authenticated user, confirmed rates and
exact output hosts. A saved API token does not switch providers. Other users and
normal App Store clients retain fal; eligible unconfigured beta requests fail
before paid dispatch.

The confirmed catalog rates are **2¢/second masking + 4.5¢/second erasing**, used
for pinned stage reservations/accounting, not invoice reconciliation. Rendprop's
AI clip allowance, workspace ceiling and existing **240¢ batch fence** remain.
Each paid stage has durable admission and an immutable receipt; no automatic paid
retry or fallback exists. The narrow starting host
`d1ei2xrl63k822.cloudfront.net` has historical Bria-owned video-output evidence,
without a guarantee for current mask/erase outputs. Unknown hosts fail closed and
can strand paid output while references and cost accounting remain. Environment
changes cannot repair a job's pinned allowlist through normal polling.

See the [adapter tests](ai-video/bria_test.ts), [handler tests](ai-video/erase_test.ts),
[migration](../migrations/20261002225458_video_erase_direct_bria.sql),
[SQL contracts](../tests/video_erase_direct_bria.sql) and
[disposable PostgreSQL runner](../tests/video_erase_direct_bria_pg.py).
Apply schema before the dependent handler and verify deployed source/grants before
enablement. Tester IDs, credentials and customer evidence stay outside Git.

## Delivered release checkpoints

The [2 October beta feedback release](../../../docs/handoff/BETA-POLISH-20261002.md)
deployed **listings v38, tours v45 and ai-photo v49**, all ACTIVE with JWT
verification enabled. Gallery selection validates ordered ready/visible listing
photos; a service-only atomic append preserves concurrent cloud additions. The
gallery migration is recorded live as `20261002171338`, from source filename
`20261002160344`; do not apply it twice. All eight catalog/permission checks and
three exact database function bodies match. Deployed extraction returns 12/13/24
files, all byte-matching the source; tours submitted 14, with only `spatial/contract.ts`
omitted because its sole incoming edge is an erased Row type import. That module's
unused runtime exports are unreachable through that edge. All 12 CI jobs passed
on runtime `3615a23`; three unauthenticated GET probes return 401. No paid generation
or synthetic customer write was used. See the
[delivery receipt](../../../docs/releases/TESTFLIGHT-41-20261002.json).

The [build 40 crash audit](../../../docs/handoff/IOS-CRASH-HARDENING-20261002.md)
deployed **events v26 ACTIVE**, with JWT verification enabled. A narrow,
whitelisted diagnostic `app_version` exemption preserves `marketing.version (build)`
for future crash attribution; arbitrary strings still pass through scrubbing.
All six downloaded source files match runtime `4580f76`; downloaded-source tests
pass 30/30 and the entrypoint type-check passes. No migration or production
test-event ingestion was required. Already redacted historical builds cannot
be recovered, and accepted telemetry summaries are not a complete crash census.

[Photographer client delivery](../../../docs/studio/photographer-client-delivery.md)
adds a nullable, explicit real estate work preference, service-only per-listing
client contacts, verified contact-photo uploads and transactional client inquiry
emails. Recipients and delivery history remain private; public tours expose only
the client card and display flags. The migration is applied under live ledger
`20261001233128` (source filename stamp `20261001222809`; do not apply it twice).
At that delivery, selected versions were **me43, listings37, uploads45, leads36, notify11,
studio15, tours44 and ai-video45**; all downloaded runtime source files match
the release. The adopt handler is unchanged; its existing RPC preserves role
preference. All 19 migration function contracts and six triggers pass live
metadata readback. See the
[release handoff](../../../docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md)
for exact evidence and real inbox acceptance still required.

The [1 October core release](../../../docs/handoff/CORE-READINESS-20261001.md)
deployed **team v16, me v42, coach v19 and listings v36**, all ACTIVE with JWT
verification on. The three trial/invitation/workspace migrations are applied;
45/45 runtime source copies and migration payload hashes match the reviewed
source. Existing grants are preserved. The report maps source filenames to
live migration timestamps; do not apply these migrations twice.

The [27 September release checkpoint](../../../docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md)
records Studio API **v12 ACTIVE**, JWT verification enabled, and all **44 runtime
source files** matching the release source. The four new project/media/music/text
route migrations are applied. The new website also passed 30-file byte
verification. Model-backed editing, enhancement and speech are activated with
bounded estimated limits and passed a signed-in synthetic production smoke.
Higgsfield Presenter generation remains disabled. Final CI passed 12/12 jobs, and
PR #8 merged to main as `10e2b22`.

Deployed backend additions include named Studio projects, immutable private media
chunks, property-music handoffs and source-verified speech analysis. Bounded text
route seeds retain separate endpoint enablement gates. The
[24 September record](../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md) documents
the earlier conversational Studio/Presenter release and its other function versions. See [projects and finishing](../../../docs/studio/projects-and-finishing.md)
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

## Subscription and team readiness (deployed 1 October)

New workspaces start on `free`, with no trial expiry or trial source. An eligible
7-day App Store introductory trial begins after the customer confirms a
subscription in Apple's purchase sheet; the selected plan's allowances and
Apple's expiry then apply. Existing trial, manual and Apple grants retain their
current values. This change is prospective and requires migration
`20261001143615_subscription_confirmed_trial_start.sql`.

`GET /me` includes `billing` for the same resolved workspace as its entitlement:
`org_id`, `org_name`, `role`, `can_manage_subscription` and `source`. Native clients
show that workspace before a purchase and send `expected_org_id` to
`POST /me/entitlement`; a changed workspace fails with 409 instead of binding the
receipt elsewhere. A verified Apple transaction whose account token belongs to
an adopted guest is accepted only with the exact, still-authorized adoption
receipt. Membership in someone else's team is not purchase-ownership proof.

Team invitation responses distinguish creating a valid code from queuing its
email. `email_queued` and legacy `emailed` mean the outbox accepted the message,
not inbox delivery; bulk `emails_queued` counts successful acknowledgements.
Migration `20261001142823_team_invite_delivery_confirmation.sql` fixes the queue
function's profile-name column reference. It does not resend existing codes.
Standard Team includes two seats; separately provisioned brokerage contracts use
their contracted seat count. A disposable 100-seat contract is covered by the
regression below; this does not prove a live email provider or phone workflow.

Explicit workspace selection is available through `GET /me/workspaces`
(`active_org_id`, `workspaces: [{id,name,role}]`) and `POST /me/workspace`
(`{org_id}` → `{ok,org_id,org_name,role}`). `GET /me` also includes `workspaces`.
Migration `20261001145730_workspace_selection.sql` verifies live membership and
account/deletion state in service-only functions; selection changes only the
session default, never existing listing ownership or roles.

Clients capture `X-Org-Id` before starting workspace work and preserve it through
refresh/retry. Explicit IDs fail closed if membership disappears. A legacy
`GET /listings` without that header deliberately remains a complete snapshot of
all authorized memberships; native cloud reconciliation depends on this. A
request with the header is filtered to the verified workspace, and explicit
listing edits cannot target another workspace. Draft creation must retain its
original workspace and idempotency key, even when another device switches the
active default. Native selection and stale-response handling require the
corresponding app build.

For authorized purchasers, `billing.original_transaction_ids` lists the selected
Apple-paid workspace's active/grace subscription bindings. Before an upgrade,
compare StoreKit's verified original ID with these bindings. An empty list does
not establish that an existing device subscription is unbound; restore/resolve
its workspace first. Agents and marketing members receive no subscription IDs.

Run from the repository root:

```bash
python3 tools/audit/run_workspace_selection.py
python3 tools/audit/run_team_readiness.py
python3 tools/audit/run_subscription_trial_regression.py
```

These create socket-only disposable PostgreSQL, test the old failure before the
fix and its replay, and run network-denied handler tests. They never send real
invites, call Apple or make purchases. The subscription suite preserves the
known owner-retained Astra ceiling invariant failure separately from its passing
policy checks. Deployment status and live timestamp mappings are recorded in
the [release receipt](../../../docs/handoff/CORE-READINESS-20261001.md).

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

The [deploy-functions.sh](../deploy-functions.sh) wrapper now delegates to that
same explicit-selection helper. It no longer deploys an implicit list or forces
uniform JWT settings. Choose every affected read handler deliberately. Earlier sections of
[DEPLOYMENT.md](../DEPLOYMENT.md) document older rollout/setup work; use the latest
[release record](../../../docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md)
for current production facts.

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
