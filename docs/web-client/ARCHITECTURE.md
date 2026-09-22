# Rendprop web client: architecture decision record 001

Date: 2026-09-10. Source baseline: `f14081d49d5fb40b1dde59562176692ddb2664c6`.
Status: accepted implementation direction, **not a deployed web application**.
These decisions precede components. Source and behavioral evidence override older
audit conclusions and product aspirations. See `PARITY.md` for the inventory and gates.

## 1. One backend and one identity model

Reuse Supabase Auth, existing edge routes, organization membership, entitlements,
fair-housing checks, provenance, job identities and cost ledger. Do not introduce a
second auth service, queue, planner, or billing ledger. `apps/web/player/` is an archived
prototype, not an existing production owner client or an authentication implementation.

Swift cannot execute in the browser. "Reuse transport" means a browser adapter for
the same wire protocol and state transitions, tested against shared fixtures, not a
second identity model. Preserve `AuthStore.isSignedIn != isIdentified`, lazy anonymous
bootstrap, single-flight refresh, and `LiveAPIClient.execute`'s one 401 retry with the
**same serialized body and idempotency key**. Do not log tokens, transcripts, asset
URLs, or response bodies. Do not require registration to create/edit locally or use
features; identity is only required for genuine cross-device/team operations.

Browser credential persistence is security-sensitive implementation work, not solved
by copying Swift Keychain code. Use the official Supabase browser session mechanism
with explicit storage and cross-tab refresh tests; no bearer token in URLs, server
HTML, analytics, or service-worker caches. A dedicated owner origin with strict CSP,
no third-party scripts, and no user HTML reduces XSS exposure. HttpOnly BFF sessions
are a later alternative only if they retain this identity model and receive a written
threat review; they are not silently introduced as a second session system here.

All org/role/seat/ownership checks remain database-enforced. `X-Org-Id` is a selector,
never authority. Capture each operation's workspace at start; switching workspace must
not retarget an outstanding upload, approval, or export. Refuse stale revisions with
409 and show recovery. Membership removal must invalidate authorization at mutation
time, not wait for a JWT to expire. Do not query server-owned tables directly for writes.

Current blockers include client-writable photo provenance fields, incomplete direct
listing write restrictions, non-durable anonymous-workspace adoption, and no E11
approval schema. A service-role catalog query is not a low-privilege HTTP test. These
are prerequisites for shipping owner UI, not issues to conceal with disabled buttons.

## 2. Render per operation, not per platform

| Operation | Execution | Bounded behavior / truth |
| --- | --- | --- |
| Timeline scrubbing, crop/framing, caption layout, drag/reorder | Browser proxy preview | Zero new render job or AI call per scrub. Decode a bounded neighborhood; pause background tabs. |
| Thumbnail/waveform extraction | Browser worker where supported | Sampled windows; abort signal, decoded-memory ceiling, no whole 2 GiB ArrayBuffer. |
| Local proxy creation | Browser capability probe | Optional. Unsupported codec/memory pressure falls back to a server proxy job, never a frozen tab. |
| AI copy, photo edit, motion generation, voice | Existing edge routes/router | Same input/output fair-housing gate, entitlements, idempotency semantics, ledger and approved providers. |
| Durable final video / multi-item export | Existing server job architecture, extended once | Immutable edit revision; per-job resource/deadline/spend cap; fenced claim and publication. No new queue. |
| Buyer playback / the two links | Existing tour-host / Stream | Same approved render ID and immutable content, not a per-client regeneration. |
| iOS local export for preview/offline use | Existing AVFoundation engines | Label local draft/export. It is not evidence of canonical server render parity. |

WebCodecs support is feature-detected with an actual codec configuration, not a browser
name. A local preview is not literally cost-free: it consumes customer battery, memory
and time. Server preview fallback must be explicit and metered once per source/revision,
not on every mouse move. Existing worker code requires a publication-fencing audit
before enabling new final-export traffic; a lease alone does not fence a stale writer.

### The byte-identical question — current answer: NO

Today iOS `publishApp` uploads an AVFoundation-encoded asset. The Python/ffmpeg path is
different. The code does **not** prove that independent encoders produce identical
bytes. Even equivalent scenes can differ in codec implementation, metadata and timing.
Do not promise byte equality from an EDL alone or rewrite native rendering prematurely.

Required design: both clients persist the same versioned edit intent, resolve it through
one canonical renderer profile, and publish/reference **one immutable output artifact**.
Artifact identity is `{edit_revision, renderer_version, input_hashes, content_sha256}`.
Both clients must retrieve that artifact; download hashes must match. If the renderer
changes, it creates a new version requiring new review. Branded/unbranded pages can
differ in chrome while referencing the same content. Server storage checksums and
an export approval are separate from multipart ETags (which are not a whole-file SHA).

This canonical path is NOT implemented by this decision record. Product parity remains
blocked until it is exercised on iOS and web. Preserving the current iOS export is a
compatibility measure, not a claim that two encoders have become equivalent.

## 3. A 2 GiB walkthrough on hotel Wi-Fi

Use existing `/uploads` multipart tickets, part-urls, complete and abort, not Supabase
Storage, a proxy through an edge function, or a second uploader protocol. Server video
ceiling is currently 12 GiB, multipart threshold 64 MiB, photo ceiling 50 MiB, batch
ceiling 200 files, and daily org budget 200 GiB (`uploads/index.ts:176–200`). Preserve
server authorization, exact unique part coverage, object verification and server-byte
accounting. Browser batching does not change per-file charging or permit marketing writes.

Durable browser transfer record, scoped to session identity AND org AND listing:

```ts
type TransferIdentityV1 = {
  schema: 1; operationId: string; authSubject: string; orgId: string; listingId: string;
  source: { name: string; size: number; lastModified: number; sha256?: string };
  // Exact normalized request bytes/key survive a lost ticket response.
  ticketRequest: { bodyJSON: string; idempotencyKey: string };
};
type TransferV1 = TransferIdentityV1 & (
  { phase: 'ticket-pending' | 'ticket-outcome-unknown' } |
  {
    phase: 'ticketed' | 'uploading' | 'paused' | 'completing' |
           'verified' | 'failed' | 'aborted';
    assetId: string; partSize: number; partsTotal: number;
    acknowledged: Record<number, { etag: string; bytes: number }>;
  }
);
// Signed URLs are refreshed from the server, never durable credentials.
```

Implementation requirements:

1. Persist operation ID before ticket creation; replay same request/key after ambiguous
   responses. Reject unsafe/fractional byte counts. Use server-authoritative part size.
2. Read `File.slice` chunks, at most two in flight initially, bounded retry and jitter;
   persist each acknowledged ETag. Never load the entire video into JS memory/base64.
3. On reload request file permission again, or require file reselection. Name/size/mtime
   alone are **not** proof it is the same file. Verify content hashes before mixing old
   acknowledged parts with a reselected source. Incremental hashing must also be bounded.
4. A second tab cannot complete a transfer concurrently: acquire a local transfer lease,
   but treat server idempotency/status as authoritative. Persist before every state change.
5. On URL expiry obtain fresh URLs for the SAME asset/parts. Do not create another ticket.
   Reconcile missing/ambiguous acknowledgements with a server status/list-parts contract;
   local ETags alone cannot recover a lost browser database. This status path is a gap,
   not something the current UI can assume exists.
6. Completion with a lost response is an unknown outcome. Reconcile/replay same identity;
   never report success before verified server state, and never immediately abort an
   object that may already be published. Cancellation, pause and deletion are distinct.
7. Browser R2 CORS must permit approved owner origins, required PUT headers, and expose
   ETag. Test preflight and actual response in a real browser. This runtime setting is
   an unverified manual gate; native URLSession working proves nothing about it.

Ideal transfer time for 2 GiB is ~57.3 min at 5 Mbps, ~4.77 h at 1 Mbps, before retries.
Neither "15 minutes covers upload" nor keeping a tab alive is a durability strategy.
Test at least: airplane mode, URL expiry, tab close, token refresh, disk/storage eviction,
source mismatch, lost completion response, concurrent tabs, role revocation and cap hit.

## 4. Review, provenance and governance before publish

E11 requires immutable edit revisions and approval bound to actual asset hashes,
org, listing, policy version and reviewer identity. Any input/edit/policy mutation
invalidates approval. Publication verifies the current approved revision in the same
transaction that selects the artifact. Revoking review/share authorization is effective
server-side, including cached buyer responses. Do not implement approvals as browser flags.

Brokerage → office → agent precedence must be documented and server-resolved. A locked
field cannot be overridden at a lower level; an explicit unset differs from inheritance.
Brand/template version is part of export identity. Public reviewer tokens are scoped,
expiring, hashed at rest, revocable, and not full tenant JWTs. No such schema or route is
claimed shipped by the current branch. Local fixtures must prove it before screens depend on it.

Buyer pages prioritize plans/photos, with tours/video as distinct navigation. The market
research's 33/26/20/4 preference figures are not our conversion measurement. Agent-facing
reel conversion and buyer engagement must be measured separately. No analytics events
are added until all four LAUNCH-CONTRACT locations are updated together.

## 5. Component and style boundaries

Design tokens live in `packages/client-contracts/design-tokens.json`; use the supplied
vector mark in `docs/brand/`, not a recreation. Original violet stays the main accent;
light violet is used for text/focus on dark surfaces. Do not use muted placeholder text
as a label. No font binaries are copied before redistribution rights are confirmed.
The token verifier checks numerical contrast, not full WCAG compliance. Keyboard flows,
zoom, reduced motion, screen readers and browser rendering still require real UI tests.

Styles are versioned policies over the closed motion vocabulary and existing EDL, not
new generation prompts. `REEL_MOTION_TEXT` stays frozen. No style may bypass room vetoes,
fair-housing or change coverage timing without an explicitly versioned planner capability.
Until the authoritative room allowlist is shared and tested, keep legacy motion and
report unapplied ranking rather than pretending the style's move preference was applied.
No creator references were supplied: initial styles are generic original policies, not
creator imitation, licensed music, or copied templates. See the style lane's assessment.

## 6. Delivery gates

1. Internal-only build 18: source-bound fresh integrated UI evidence, visual inspection,
   guarded archive/upload and read-only Apple postflight; never modify pending build 16.
2. Contract/token coverage and independent tenancy/vendor/style reports (this foundation).
3. Local low-privilege JWT / direct Data API fixtures, adoption/revocation/approval races,
   and real browser session/upload tests. Admin catalog checks alone cannot satisfy this.
4. Browser editor and canonical render integration; real create → edit → review → publish
   → branded and unbranded links, on supported browsers and an actual phone.
5. Owner physical capture and reconstructed-room experiment stays separate. No spatial
   Phase B–E product work, paid provider experiment or disabled-route activation here.

No web deployment, provider adoption, production schema mutation or approval claim is
authorized by a green offline contract test. The report must distinguish implemented
contracts, tests actually executed, blocked work and user/runtime gates.
