# Rendprop engineering backlog and implementation contracts

## Scope and operating rules

This is the implementation companion to `MARKET-STRATEGY.md`, based on source snapshot `afa6923e443de9a3fc83c36fd8978b6e9eb85c4e`. It distinguishes actual code from proposed additions. It is not a claim that the whole app has been re-audited or that historical P0s have all been reverified against production.

Keep App Store Connect, submission, metadata, pricing and TestFlight unchanged while the current submission is pending. Do not enable routes, spend on a new provider, use customer media, deploy a backend or run production deletion as part of these tasks. Fetch and inspect upstream before integration; work on a branch per unit, preserve other agents’ work, and never force-push a shared branch.

Read `docs/GPT-AGENT-BRIEF.md` completely. Its real-room Phase A gate remains in force: no Phase B–E product implementation until the owner sees an actual permitted room reconstructed and running on the phone with recorded results. The agent-reel gate is independent: finish API and strictly offline transcription, then prove a real 60-second route round-trip before writing capture UI. A mock, transcript fixture or simulator cannot stand in for that proof.

Every test runner must assert and exit nonzero on failure, and include a demonstrated negative control. Grep for new symbols before compiling. Record source commit, command, exit code, executed tests/assertions and evidence path. A skipped test or compile-only pass is not an end-to-end pass.

## 1. Ground truth in the current tree

| Area | Source evidence | Consequence |
| --- | --- | --- |
| Spatial lab | `apps/ios/Rendprop/Capture/SpatialCaptureLabView.swift:1`, `:13` | Compile-flagged local Phase A capture; explicitly no upload/model generation |
| Capability detection | `tools/spatial-spike/capture-ios/Sources/SpatialCaptureViewController.swift:72`, `:116` | AR world-tracking support is queried; a preferred ≤1920-wide/30fps format is selected where available |
| Saved capture contract | `tools/spatial-spike/capture-ios/Sources/CaptureModel.swift:80` | Existing manifest and coordinate conventions must remain compatible with the adapter |
| Agent-reel API protocol gap | `apps/ios/Rendprop/Networking/APIClient.swift:925`, `:939` | Script/shotlist methods exist; tree search found no `aiCopyAgentReel` implementation |
| Exact decoding helper | `apps/ios/Rendprop/Networking/LiveAPIClient.swift:245`, `:260` | Explicit snake_case CodingKeys must use `decodeExact`, not `.convertFromSnakeCase` |
| General speech behavior | `apps/ios/Rendprop/Voice/SpeechTranscriber.swift:139`, `:151`, `:174` | Existing transcription may use server recognition or retry there; it is not a strict offline implementation |
| Existing composition seam | `apps/ios/Rendprop/Render/ReelComposer.swift:248` | Extend the existing engine rather than replacing its export/audio/transition behavior |
| Actual server request/response | `services/supabase/functions/ai-copy/index.ts:426`, `:714`, `:863` | Wire contract already defines transcript, clip length and cutaways |
| Actual cutaway fields | `services/supabase/functions/ai-copy/agentreel.ts:394` | Window identity, start/end, photo ID, room, motion and overlay text |
| Existing public chapter | `services/edge/tour-host/src/types.ts:27` | Only label, time and sort; no current spatial anchor |
| Existing plan/video UI | `services/edge/tour-host/src/player.ts:428` | Extend its room/seek behavior after the gate, with old-tour regression fixtures |
| Unbranded sanitization | `services/edge/tour-host/src/player.ts:219` | New spatial fields need explicit safe projection, not unrestricted passthrough |
| Provenance foundation | `apps/ios/Rendprop/Networking/APIClient.swift:147`, `:858`, `:866` | Original/altered records and compliance CSV already exist; extend rather than duplicate them |
| Team transaction foundation | `services/supabase/migrations/0033_team_transactions.sql:89`, `:170`, `:230`, `:287` | Invitations/adoption and service-role-only RPC grants exist; do not infer enterprise readiness or live verification |
| CI exists | `.github/workflows/ci.yml:18`, `:57`, `:101`, `:180`, `:236` | Edge, Deno, database, Python and iOS static jobs exist; “no CI” is stale |
| iOS CI limitation | `.github/workflows/ci.yml:236` | The iOS job uses Ubuntu/static gates, not an Xcode build or simulator run |

Line numbers refer to the source snapshot above, not future branches. Search whole symbols before editing because some views remain in large combined files: `ReelStudioView` currently lives in `Screens/FlythroughDetailView.swift`, not a standalone file of the same name.

## 2. Near-term branch units

### E01 — Harden saved-capture export boundaries

Status: implemented on isolated branch `fix/spatial-capture-hardening-20260910`; see its `tools/spatial-spike/capture-ios/HARDENING-VERIFICATION.md` and this directory’s `VERIFICATION-AND-HANDOFF.md` for exact final commit/tests. It is **not** included in the already uploaded build 17.

The reproduced failures were unexpected image/sidecar/directory symlinks, an undeclared link included in whole-folder export, and oversized but syntactically valid manifest/sidecar JSON. Commit `9b154c8` uses bounded regular-file reads and exact expected contents. Follow-up `0f36496` adds a 64 MiB JPEG cap, 8192-axis/16,777,216-pixel limits, metadata preflight before decode and matching capture-start/encoding guards. The complete code and verification are on the hardening branch, not in the earlier TestFlight artifact.

Threat model: local saved-capture integrity, not a remote upload vulnerability. Do not claim static path checks create an atomic snapshot against a concurrent local writer. A future server importer must independently validate archives, reject traversal/symlinks/decompression bombs and enforce compressed/decompressed totals; the local iOS validator cannot be its security boundary.

### E02 — Add the agent-reel contract to all clients

Proposed branch unit: typed request/result models, API protocol requirement, live route and deterministic mock, plus fixture tests. No capture UI and no paid generative-video path.

Read the actual request contract at `ai-copy/index.ts:426` and response at `:863`. Reuse the existing fact/photo cleaning conventions from `aiCopyShotlist` (`LiveAPIClient.swift:752`), including city/state rather than an added structured street-address field. That packing is **not** a guarantee that the text provider receives no address: free text can contain one, and `agentreel.ts:370` includes transcript excerpts in the prompt. Define a review/minimization policy for outgoing speech and facts; test spoken-address/private-detail fixtures before promising a stronger guarantee. The offline claim covers transcription, not the subsequent text-provider EDL call. Use the existing authorized transport and error mapping; do not build a second session or refresh implementation. Confirm the current transport’s retry semantics before sending a potentially billed request twice.

The following is a **proposed model excerpt**, not a patch already integrated or compiled. It spells the observed wire fields exactly; integrate it with the project’s existing error/types and tests:

```swift
struct AgentReelPhrase: Codable, Sendable, Equatable {
    let t: Double
    let text: String
}

struct AgentReelResult: Decodable, Sendable {
    let subject: String
    let clipSeconds: Double
    let cutaways: [Cutaway]
    let coveredSeconds: Double
    let faceSeconds: Double
    let model: String

    enum CodingKeys: String, CodingKey {
        case subject, cutaways, model
        case clipSeconds = "clip_seconds"
        case coveredSeconds = "covered_seconds"
        case faceSeconds = "face_seconds"
    }

    struct Cutaway: Decodable, Sendable {
        let windowID: String
        let start: Double
        let end: Double
        let photoID: String
        let room: String
        let motion: String
        let onScreenText: String

        enum CodingKeys: String, CodingKey {
            case start, end, room, motion
            case windowID = "window_id"
            case photoID = "photo_id"
            case onScreenText = "on_screen_text"
        }
    }
}
```

Add `func aiCopyAgentReel(_ request: AgentReelRequest) async throws -> AgentReelResult` to `APIClient`, `LiveAPIClient` and `MockAPIClient`. Define a separate outgoing request model; do not confuse the server-internal `AgentReelRequest` with the HTTP body. The body carries `listing_id`, `space_type`, `tone`, `subject`, `clip_seconds`, `transcript`, `photos`, `facts`. The live result must call `decodeExact(data)`.

Decoding is not validation. Before composition, reject nonfinite times, duplicate window IDs, reversed/overlapping windows, unknown nonempty photo IDs, out-of-clip ranges, mismatched duration and unknown unsupported motions. Empty `photo_id` deliberately means stay on the agent. Compare duration/coverage with an explicit rounding tolerance consistent with the server’s tenths-of-a-second output; do not reject a valid response because binary floating-point arithmetic differs by an epsilon.

Tests must include exact snake_case success, missing required fields, a demonstration that the wrong decoder fails, malicious photo identity, unknown motion, overlap, negative time, duration mismatch, empty photo fallback and deterministic mock behavior. An unexpected new motion should be rejected or explicitly supported, not converted to a paid generation request. Preserve any intentional treatment of unknown extra JSON keys; “exact” here refers to key mapping, not an unimplemented rejection of all extra fields.

### E03 — Add strict offline transcription and phrase construction

Proposed branch unit: add an explicit recognition policy or a dedicated offline entry point. Preserve the existing general voiceover behavior unless intentionally migrated; it currently has a documented server fallback.

The required policy is conceptually:

```swift
enum TranscriptionPolicy {
    case offlineRequired
    case onDevicePreferred
}
// For .offlineRequired:
// 1. Require supportsOnDeviceRecognition; otherwise return an actionable error.
// 2. Set requiresOnDeviceRecognition = true for every request.
// 3. On failure, cancellation or timeout: never retry with onDevice = false.
// 4. Never upload the clip or audio to obtain the transcript.
```

This is a control-flow contract, not a fabricated drop-in Speech API wrapper. Use the existing continuation/cancellation discipline in `SpeechTranscriber.swift:187` and preserve exactly-once completion. Confirm current Apple Speech documentation and the supported locale/device behavior during implementation. A model download prerequisite must be disclosed; offline-required cannot silently become “works online.”

Construct phrases from actual recognized segment timestamps, using punctuation/pause boundaries and a documented maximum phrase length. Preserve monotonic timing; do not sort broken output into a confident fictional transcript. Keep timings in the original clip’s timebase, including any extraction offset. Refuse or request an explicit user-approved trim when the route’s limits are exceeded; never silently discard the tail of a recording.

The current server accepts 6–180 seconds and up to 200 phrases (`agentreel.ts:105`, `:116`). It rounds output boundaries to tenths. The B-roll share constant is currently 0.55 (`:100`); do not change it because a prose comment says the face occupies a majority. Any product-policy tuning is a separate reviewed change.

Required tests: available/unavailable on-device recognizer, no authorization, empty audio, timeout, cancellation, simultaneous final/error callbacks, multilingual or unsupported locale handling, phrase limits and strictly increasing in-range times. Inject a fake recognizer/transport policy to prove a fallback request is never constructed. Real offline behavior still requires the permitted phone test with connectivity disabled and a suitable installed language model.

### E04 — Real round-trip acceptance before UI

Owner supplies a permitted approximately 60-second talking-head clip and permitted listing photos. Record its measured duration/hash locally without logging private speech. Produce an offline transcript, call only the already-authorized route, record the returned EDL and validate every reference/time. Keep private assets and transcripts outside Git.

Before the live call, confirm authorization for any billed text invocation and use the current allowed route; do not enable a row or add a provider. The existing offline test suite does not prove the currently deployed route or secrets. A failure must report the actual response/status without exposing tokens or private content. A recorded fixture can then back future regression tests after appropriate redaction/permission.

Acceptance: actual clip → actual offline transcript → actual EDL response, with source identity and timing checks. This is not satisfied by a mock transcript or merely running the server’s pure planner tests. Stop before capture UI if this is not proved.

### E05 — Extend composition, then add capture UI

Extend `ReelComposer.compose()` at `ReelComposer.swift:248` using a typed, optional composition mode. Keep old callers’ default behavior unchanged. The talking-head video/audio is the full timeline; cutaways cover defined intervals. Do not concatenate cutaways as if they were the whole video or retime the agent’s voice to fit them.

Keep the original audio at 1× and its correct offset. Preserve the source track transform and tested portrait/landscape geometry. A failed or absent cutaway leaves the original agent video visible. Use only locally available, permitted images/recorded assets; the current EDL is not authorization to call `/ai-video/reel_clip`. Add captions as overlays with bounded text and safe area handling.

Test no cutaways, one cutaway, all-empty photo IDs, adjacent/nearby windows, failed image load, rotation, silence, cancellation, export error and all existing composer modes. Use synthetic colored frames/time markers and audio pulses to assert timeline behavior, then inspect the permitted real clip. Do not call a visually plausible MP4 an audio-sync pass without checking the timeline.

Only then implement agent capture in the actual `ReelStudioView` location. Keep permission denial/recovery, retained drafts, honest offline limitations and accessible controls. The mock must support the screenshot walk without network or provider charges.

### E06 — Add real iOS CI without changing distribution

Existing CI is substantial, but `.github/workflows/ci.yml:236` only runs iOS static checks. Add a separate bounded macOS job that selects a known Xcode/runtime, runs `xcodegen generate`, builds for testing and executes named tests. Inspect available runner versions rather than inventing a pinned image. No signing credentials, archive, upload or App Store action belongs in this lane.

The job must fail if the named simulator, scheme or tests are absent. Parse results for executed counts and skipped/failing tests. Preserve bounded diagnostic artifacts and actual UI screenshots where required. Add portable capture/training/viewer tests to CI after confirming platform dependencies; do not treat a Python skip due to missing image/video support as a green quality gate.

Maintain the existing source/privacy checks, but recognize their limits: a grep cannot prove Release-binary pricing absence, and a parseable privacy manifest cannot establish that all data flows match its declarations. Those remain scoped release checks with their own evidence.

## 3. Spatial product units after the physical gate

### E07 — Canonical room identity and optional spatial binding

Proposed contracts below are **design examples**, not deployed schemas. The exact database migration must be designed against the then-current tables and tested on a disposable database. Do not copy a guessed migration number or assume existing tenancy constraints cover a new table.

```typescript
type Vec3 = readonly [number, number, number];
type Quaternion = readonly [number, number, number, number];

interface SpatialAnchorV1 {
  schema_version: 1;
  room_id: string;
  scene_version_id: string;
  coordinate_frame: "room-local-rh-y-up-metres-v1";
  position: Vec3;
  orientation_xyzw: Quaternion;
}

// Additive: an old tour needs no spatial data to remain a valid tour.
interface ChapterWithSpatial {
  label: string;
  t_ms: number;
  sort: number;
  spatial_anchor?: SpatialAnchorV1;
}
```

Specify conversion from ARKit coordinates to this frame once, and test known landmarks and quaternion conventions. TypeScript tuples do not validate JSON: enforce cardinality, finite numbers, normalized quaternion tolerance, coordinate version, and room/scene/listing ownership server-side. A user-provided URL or bucket key must not select an arbitrary model.

A chapter’s label is editable presentation, not identity. Introduce durable room IDs and an explicit chapter/room association. Scene versions need approved/published/revoked states with immutable asset hashes. Parent-child references should include tenant/listing consistency enforced by constraints or transactional checks; indexes must support ownership reads and deletion enumeration.

Acceptance sequence: publish video V1; attach approved scene S1; fetch both branded/unbranded manifests; verify same video ID and content hash; confirm optional 3D entry works; revoke S1; verify future requests are denied within the documented access/link/cache bound; confirm V1 still plays. Include old clients, old manifests, renamed rooms, reordered chapters, missing scenes and attempted cross-tenant bindings. Explicitly document that revocation cannot recall bytes already downloaded, decoded, cached outside the controlled policy or copied by recipients. Do not put private originals in a public bucket and rely on revocation to recover privacy.

### E08 — Private reconstruction and spend state machine

State concept: `queued → leased → reconstructing → validating → private_ready → review_required → published`, with explicit failure/cancel/revocation states. A database-ready row is not proof that a GPU wrote the artifact; a file’s presence is not proof it is approved. Do not share one boolean between these meanings.

Store source fingerprint, pipeline version, authorized cost reservation, attempt identity, lease/fencing token, artifact checksums, observed resource usage and explicit failure reason. Workers claim atomically and settle only with their current lease. Retry delivery is at least once; finalization must be idempotent. Never report success before the verified artifact and durable metadata agree.

Test two claimers, expired lease, late completion from the old lease holder, provider timeout after accepting a job, duplicate callback, failed ledger write, cancellation and attempts to publish caller-selected object keys. Costs from failed attempts remain attributable. A limit checker executed after provider spend is not a spend reservation.

No raw household media, captions or credentials in general-purpose logs. Correlation IDs, bounded counts, stage durations and sanitized error classes are enough for ordinary diagnostics. Provider-specific deletion and retention remain part of job/account cleanup, not an assumption about a storage lifecycle rule.

### E09 — Privacy review with derivative-safe exclusion

Use the existing media-provenance foundation instead of creating a second audit log. Bind review to exact source/output hashes and a revision. Any edit invalidates the previous approval. Private, original and approved-public storage must have distinct access policies.

For spatial media, prepublication redaction must survive alternate camera angles, thumbnails, model exports, screenshots and every relevant level of detail. A screen overlay or blurred preview is insufficient. If this cannot be proved for the chosen renderer/format, require room exclusion or recapture. Keep a clear distinction between hiding private information and concealing material property facts.

Required tests use synthetic faces/documents/labels and include a sensitive item partly occluded from the initial view. Attack old public versions, direct asset URLs, alternate `/u/` rendering and stale caches. A missing approval must fail closed. A review screen alone is not a privacy control.

### E10 — Progressive viewer and capability tiers

One shared web viewer is appropriate, but “runs on all capable iPhones” needs an explicit capability matrix. Separate capture capability, reconstruction input quality and playback capability. Do not hardcode “Pro” as the only qualification: AR world tracking, depth support, OS support and measured resources are different axes.

Start with the owner’s iPhone 15 Pro, then test an available supported non-LiDAR device and a constrained/older supported device. Do not label a model family supported until tested. Unsupported capture should retain ordinary photos/video; unsupported spatial playback should offer a plan/poster/video fallback.

Use per-room lazy loading and release resources on navigation. Measure first meaningful frame, decode memory, frame-time distribution, thermal behavior, context loss and recovery. The existing synthetic benchmark tests the measurement harness, not the actual WebGL performance. Multi-room memory must not grow linearly without an eviction budget.

## 4. Team, brokerage and platform units

### E11 — Review and organizational governance

Extend existing team transactions only after fresh membership/adoption tests against a disposable DB. Define a role matrix for capture, editing, approval, publication, member administration and billing. “Marketing” must not inherit write access because an upload role string says `render`. Test direct Data API access as well as handlers.

Introduce revision-bound approvals, delegated single-listing access and explicit transfer/departure behavior. A team member’s departure must invalidate active sessions/delegated tokens as designed while retaining organization-owned listing assets. SSO is not sufficient unless deprovisioning and membership revocation work.

Branch-level policies require a documented precedence rule: organization default, branch override where permitted, listing exception with explicit approval. Avoid unbounded inheritance trees until a qualified customer needs them. Never make a UI-hidden button the authorization mechanism.

### E12 — Platform media-job API and delivery contract

Begin with one qualified embedded use case. Proposed external contract:

```text
POST /v1/media-jobs
  tenant-scoped credential + Idempotency-Key
  input: existing authorized asset IDs, operation, policy version
  202: stable job ID, state, status URL
  replay, same fingerprint: same job
  replay, different fingerprint: 409

GET /v1/media-jobs/{id}
  tenant-scoped status, bounded failure class, approved output references

webhook: media_job.ready | media_job.failed | media_job.revoked
  event ID + timestamp + signature + schema version
```

This is a proposed interface, not an available route. Define authentication, quotas, pagination, expiry, retry horizon, compatibility, cancellation and data-retention semantics before implementation. No API key should select an arbitrary tenant. Hash stored credentials; support rotation/revocation and bounded scopes. Webhook destinations need SSRF controls, an ownership/authorization process, signature verification guidance, replay protection and a dead-letter/redelivery design. Never place tokens or private media in callback URLs.

Tests include cross-tenant reads, revoked keys, duplicate keys with different payloads, out-of-order events, invalid signatures, endpoint redirects/private-network targets and revoked assets referenced by an old event. Build a synthetic contract sandbox before onboarding a customer.

### E13 — Authorized connectors and operating evidence

Prioritize export into an existing workflow. RESO standardization does not grant MLS access or redistribution rights. Canva Autofill/Brand Templates require appropriate Enterprise access. Aryeo API existence does not imply a commercial license. Resolve customer demand, access, field mapping and rights before spending on an integration.

Each connector needs versioned mapping, allowed fields, media rights, idempotent external IDs, status reconciliation, retry policy and a customer-visible delivery outcome. A successful HTTP response is not proof that a destination published or accepted the intended media.

Enterprise evidence should cover tenant isolation, access reviews, incident handling, subprocessors, retention, failed cleanup, restore tests, support and actual service metrics. Runtime secrets, rotation, R2 lifecycle rules including staging, scheduled sweeps, provider settings and current store labels are **manual gates**, not repo-verifiable facts. This turn performed no production validation of those settings.

## 5. Definition of done for every branch

1. Source symbols exist in the intended target; generated project/resource membership is checked where relevant.
2. Negative case fails on the old implementation or the test’s deliberate fault, then passes only for the intended fix.
3. Positive fixtures include normal existing behavior, not only rejection paths.
4. Exact command exits nonzero on failure and prints executed counts; skipped required work fails its acceptance gate.
5. No customer media, transcripts, credentials or unintended generated resources enter Git or the app bundle.
6. Independent review checks authorization, concurrency, resource bounds and honest claims proportional to the change.
7. Evidence names what was not tested: physical AR, real audio, GPU, live route, dashboard setting or destination publication.
8. Integration uses an isolated branch, fetches current upstream, resolves changes without overwriting another agent’s work, and reruns relevant checks.
9. No deployment, provider activation, spending expansion or Apple action is inferred from a local green test.

Use `VERIFICATION-AND-HANDOFF.md` for the work actually completed in this pass. Everything labeled proposed above remains backlog until its code and acceptance evidence exist.
