# Kie processor permission: backend contract and proposed client/legal changes (NOT APPLIED)

- Date: 2026-10-16. Lane S4 (documents only), written for Codex's iOS / Studio / legal lane. Owner contact: Aaron@pilk.ai.
- Worktree `claude-kie-video-migration`, branch `claude/kie-video-migration-20261016`, base `462e4c8`, uncommitted.
- Status: **proposals only.** Nothing here is applied to iOS, Studio, the website, the legal pages, App Store metadata or
  any database. No vendor, Apple or legal contact was made and no terms were accepted. Nothing here is a legal
  conclusion. Every user-facing or legal wording below is **proposed — owner/legal decision**.
- Policy sources: the external review packet
  `/Volumes/Rendprop Files/Builds/Active/build87-kie-current-handoff-review-1715/FINAL-CURRENT-BLOCKERS-AND-NEXT-CLAUDE-ASSIGNMENT.md`
  (cited as `packet:<line>`) and `OFFICIAL-POLICY-VERIFICATION.json` in the same folder (`policy.json:<line>`), both
  retrieved 2026-10-16. This lane did not re-read any vendor or Apple page.
- Paths are repo-relative. `†` = uncommitted candidate file. The backend files (`property-video-jobs/index.ts`,
  `ai-video/index.ts`, `property-video-worker/engine.ts`) were being edited by a parallel lane while this was written;
  their line numbers are as read at the end of this lane and each cite names an anchor.

## 0. Summary

1. Shipped clients still create and resume property videos with `property-video-jobs-v1`, shown after a disclosure that
   does not name Kie: iOS `apps/ios/Rendprop/Networking/PropertyVideoJobsAPI.swift:119`; Studio
   `apps/studio/src/features/sync/property-video.ts:81`, `:116`.
2. The backend side of the permission now exists **in source only** (never applied, deployed or executed):
   - SQL, migration `services/supabase/migrations/20261016110000_property_video_kie_scope_consent_drain.sql` †: a new Kie
     job needs `property-video-jobs-v2` for the current published disclosure revision; the permission is stored on the
     job and cannot change; v1 can never admit Kie. The disclosure config is not seeded, so Kie admission fails closed
     until one is published (`:13-20`, `:132-153`).
   - Edge, `services/supabase/functions/property-video-jobs/index.ts` †: parses v1/v2 and the disclosure header
     (`:17-19`), serves `GET /processor-consent` (`:35-36`), refuses with `processor_consent_required` /
     `processor_disclosure_unpublished` (`:24-31`, `:45`), admits through `property_video_job_admit_v2` (`:46`), and
     allows the new headers in CORS (`:2`). Documented in `property-video-jobs/README.md:8-43` †; handler test
     `property-video-jobs/processor-consent.test.ts` † (not run by this lane).
3. What is still missing: a published disclosure revision, the iOS and Studio changes (sections 3-4), the website and
   legal text (section 5), and the operator step that creates an owner test grant (section 1.3).
4. Unchanged on purpose. The pinned Kie row keeps the conservative `trains_by_default` tier (identity
   `services/supabase/functions/_shared/property-video-kie-identity.json:45` †; route seed
   `services/supabase/migrations/20261016100000_property_video_kie_kling3_4k_profile.sql:21` †). The operator
   acknowledgement `kie-terms-2025-08-01-section-3-owner-accepted` (identity `:46`; written by
   `docs/handoff/KIE-ACTIVATION.sql:9-11`, `:78` †) and the `processor_disclosure` identifier (`KIE-ACTIVATION.sql:12-14`,
   format check only at `:86-91` †) are operator records. They are not any user's permission, and the SQL does not
   accept them as permission (`20261016110000…sql:19-20`, `:142-153`).

## 1. Backend contract (as implemented in source)

### 1.1 SQL (migration 20261016110000 †)

| Piece | Behaviour | Lines |
|---|---|---|
| Published disclosure | `app_config.property_video_processor_consent` must be exactly `{token:"property-video-jobs-v2", disclosure_revision:<1-200 visible ASCII>, processors:[…,"kie",…], profiles:[…,"kie-kling3-4k-steady-v1",…]}` with no other keys; anything else reads as "not published". The migration never seeds it. | `:132-140`; `:15-16` |
| What a job stores | No consent or exactly v1 → `processor_consent` NULL; a Kie job then refuses RP403. v2 → needs a published disclosure and exactly `{token, disclosure_revision}` equal to it, else RP403; stores `{token, disclosure_revision, processors, recorded_at}`. | `:142-153` |
| Admission entry | `property_video_job_admit_v2(actor, manifest, quote, profile, consent, test_grant)`; consent and grant travel as transaction-local settings into the unchanged admission/freeze path. | `:189-201` |
| Freeze (job INSERT) | Records the permission, sets `consent_revision` to its token, sets `kie_test_grant_id` only for Kie; any later change raises RP409. | `:253-260` |
| Table rules | Revision v1 or v2; v1 ⇔ NULL `processor_consent`, v2 ⇔ an object; a Kie job must be v2; a grant only on a Kie job. | `:104-125` |
| Selector first | `property_video_quality_profile_for` asks the global selector first (an unknown or hold value refuses every admission, grants included); a named grant can only narrow to Kie. | `:177-185`; `:34-37` |
| Allowance floor | After a rollback or hold, the paid-quality floor stays for a billing org with its own not-cancelled, pre-deadline Kie job of the exact identity; FAL accounting unchanged. | `:6-12`, `:246-252` |

`property_video_job_resume` is not patched: SQL does not re-check processor permission on resume.

### 1.2 Edge (`property-video-jobs/index.ts` †)

Headers on `POST /property-video-jobs` (create) and `POST /property-video-jobs/:job_id/resume`:
- `x-rendprop-ai-consent: property-video-jobs-v1`: creates legacy/FAL work only; resumes only a job saved under v1
  (`index.ts:47-49`; README `:15-16`).
- `x-rendprop-ai-consent: property-video-jobs-v2` plus `x-rendprop-ai-consent-disclosure: <revision>` (1-200 visible
  ASCII, `:19`): the person allowed the processors of the current published disclosure. Required for a Kie create,
  accepted (and stored) for any other create. On resume only the v2 token is checked; no revision, any job
  (`:47-49`; README `:17-22`).
- Optional `x-rendprop-quality-test-grant: <uuid>` on create (malformed → 400, `:20-21`): owner-only test; the quote then
  uses the grant-narrowed profile (`:43-44`). Ordinary clients never send it.
- Anything else → 403 `consent_required` (`:40`, `:47`).

`GET /property-video-jobs/processor-consent` (signed-in user, `:33`, `:35-36`): 200
`{token, disclosure_revision, processors, profiles}` with `no-store`, or 404 `processor_disclosure_unpublished`.

What a create gets (`processorConsentRefusal`, `:24-31`; called at `:45`, after the existing-operation lookup at `:41`):

| Request | Profile chosen is legacy/FAL | Profile chosen is Kie (activated selector or grant) |
|---|---|---|
| v1 | admitted as today, v1 stored | 403 `processor_disclosure_unpublished` if nothing is published, otherwise 403 `processor_consent_required` |
| v2 + current revision | admitted, **v2 record stored on the FAL/legacy job** | admitted, v2 stored |
| v2 + another revision | 403 `processor_consent_required` (or `…_unpublished` if nothing is published) | same |
| v2, nothing published | 403 `processor_disclosure_unpublished` | same |

- The `processor_consent_required` body carries `processor_consent:{token, disclosure_revision, processors}` for the
  current disclosure (`:30`), so a client can show it and retry.
- Replays: a create whose operation already has a job returns that job before the processor check (`:41` before `:45`),
  so a revision change after admission does not strand it. The header must still parse (`:40`).
- Race: if the published revision changes between the edge check (`:45`) and admission (`:46`), the SQL RP403 comes
  back through `throwRpc` as a plain 403 with no code (`_shared/http.ts:289-302`). Clients should treat a create 403
  without a code like `processor_consent_required`: refetch `GET /processor-consent` and ask again.
- Stop paths need no consent: cancel (`:52`) and cancel-all (`:37`). Keep it that way so turning permission off always
  stops work.

### 1.3 Owner-only quality-test grant

- `property_video_kie_test_grants` † pins one actor, logical library, physical listing, the reviewed Kie identity, 1-10
  exact ordered sources (asset, version, provenance, prepared-bytes SHA-256), 1-4 operation ids, 1-20 creates, a cents
  ceiling ≤ creates × 167.5, an approval reference and an expiry ≤ 72 h after creation (`20261016110000…sql:41-62`).
  Scope is immutable, usage only grows, revocation is one-way (`:74-101`).
- Admission under a grant re-checks the scope and the current bytes of every source (`:156-176`) while the global
  selector stays legacy/FAL (`:177-185`).
- Before every prospective paid Kie dispatch, ai-video calls the worker's `kieDispatchAuthority`
  (`services/supabase/functions/ai-video/index.ts:1568-1575` †), which calls `property_video_kie_dispatch_authority`
  (`property-video-worker/engine.ts:15-19` †). That re-checks the saved recipe and permission and, for a grant job, the
  scope, consuming one create atomically and idempotently per attempt; expiry, revocation or a spent budget refuse new
  creates (`20261016110000…sql:203-241`). Polling never calls it (`:30-31`).
- Not present: any grant row (`:32-33`) and the operator script `docs/handoff/KIE-OWNER-TEST-GRANT.sql` named at `:32`.
- **A grant is not user permission.** A grant-scoped Kie create still needs the owner's own v2 permission for a
  published revision (edge `index.ts:45`; SQL `:253-260` → `:142-153`). The owner test therefore also needs a revision in
  `app_config.property_video_processor_consent` and a client that shows it to the owner and sends v2, the revision and
  the grant id.
- For the grant lane: grant-scoped admission needs the pinned row ON (`20261016100000…sql:63-70` †). Invariant #144
  accepts the ON row only when activated or draining (`services/supabase/tests/invariants.sql:1379-1385` †), so with the
  selector unchanged and no Kie job admitted yet it reads red. Confirm the intended handling.

## 2. Kie facts a disclosure can rely on

Can state:

| Fact | Source |
|---|---|
| For a property video Kie receives the selected listing photo, which Kie fetches from Rendprop's storage through a presigned link valid 7,200 s, plus a fixed camera-motion prompt; 5 s, silent, 4K mode | `services/supabase/functions/ai-video/property-video-quality.ts:139-141`, `:144-148` †; identity `:7-10`, `:20-35` † |
| Kie Terms §3 (effective date printed 2025-08-01): the customer keeps ownership; the license granted is limited to operating and improving Kie's services | `policy.json:7-10`; `packet:25` |
| Kie API guide §6: generated media kept 14 days and text/metadata logs 2 months, then deleted automatically; the homepage FAQ states similar periods | `policy.json:19-21`, `:24-26`; `packet:26` |
| Kie's Privacy Policy is about account email | `policy.json:13-16`; `packet:27` |
| Rendprop copies the finished clip into its own storage on the first poll after Kie reports success | `ai-video/index.ts:2297-2300` †; `_shared/providers/common.ts:479-506` † |

Cannot state (unresolved; no one was contacted):
- Whether Kie, or the model operator it calls, trains on API inputs or outputs. The §3 license to improve services does
  not prove training occurs, and the reviewed text has no express API no-training guarantee (`policy.json:9-10`;
  `packet:25`).
- How long Kie, upstream model copies, caches or backups keep the fetched photos. The two-hour link limits access; it is
  not deletion (`policy.json:21`; `packet:26`).
- A specific license to redistribute or commercially use generated output. Marketing of commercial workflows is not
  that license, and the absence of a detailed grant does not prove commercial use is forbidden (`policy.json:10`,
  `:26`; `packet:27`).
- Which upstream model providers are involved (`policy.json:16`).

## 3. iOS (proposed; Codex's lane)

### 3.1 Current source

| Fact | file:line |
|---|---|
| Consent is asked at the door of each AI surface, stored per device, revocable in Settings | `apps/ios/Rendprop/RendpropApp.swift:4823-4830` |
| Key `ai.thirdPartyProcessing.consent.v3`; its comment: bump when the processors or what is sent change | `RendpropApp.swift:4835-4839` |
| One Bool; no disclosure revision is stored | `:4844`, `:4851`, `:4883-4888` |
| Five processor cards; no Kie | `:4860-4871` |
| Intro says media goes "through Rendprop's servers to the providers below" | `:4974` |
| Third bullet: "These services process what is sent to return your result." | `:5001-5002` |
| Revoke clears the grant and bumps `revocationRevision`; Settings button; account erase also revokes | `:4906-4910`; `Screens/SettingsView.swift:404-411`, `:1444-1448` |
| Revocation sends `cancel-all` with `ai_consent_revoked`, which needs no consent header | `Networking/PropertyVideoJobCancellation.swift:68-77`; `PropertyVideoJobsAPI.swift:60-85` |
| Every other property-video request requires `isGranted` and sends v1, GET and cancel included | `PropertyVideoJobsAPI.swift:11-14`, `:96-101`, `:119` |
| An uncertain create is replayed with the same operation | `Render/PropertyVideoJobRunner.swift:166-167` |
| Reel Studio's consent door | `Screens/FlythroughDetailView.swift:10573-10577` |
| Settings footer lists the processor names | `SettingsView.swift:108-112` |
| Copy test pins the five cards and the v3 key, rejects "retained for" and "no.training guarantee", lists 13 UI-test launch overrides on v3; Bria precedent v2→v3 with a negative control | `tests/phase1/consent-disclosure.test.mjs:18-29`, `:40`, `:47-73`, `:114-134` |

### 3.2 Proposal

1. **Kie card** (proposed — owner/legal decision):
   `Processor(name: "Kie", detail: "Receives the listing photos you select for a property video and the camera-motion instructions, to make the video clips. Kie's terms let it use submitted content to operate and improve its services.")`
   - Retention and deletion periods stay out of the card, as for every other card: the reviewed copy deliberately adds
     no provider retention or no-training assurance (`docs/audits/2026-09-10/AI-CONSENT-DISCLOSURE.md:124-127`), and the
     copy test rejects "retained for" (`consent-disclosure.test.mjs:40`). They belong in the Privacy Policy (section 5).
   - Kie fetches the photo from Rendprop's storage with a presigned link (`property-video-quality.ts:144-148` †).
     Owner/legal to confirm the intro's "through Rendprop's servers" (`RendpropApp.swift:4974`) still reads accurately.
   - Proposed third bullet: "These services process what is sent to return your result. Some providers' terms also let
     them use submitted content to operate and improve their services; the cards above say which. Rendprop does not sell
     your media and does not use it for advertising." (Passes the `:40` regex.)
2. **New storage key.** Option A (recommended; matches the rule at `RendpropApp.swift:4835-4838` and the Bria
   precedent): add the card and bump to `ai.thirdPartyProcessing.consent.v4`, plus one stored string, e.g.
   `ai.thirdPartyProcessing.propertyVideoDisclosure.v1`, holding the `disclosure_revision` the person accepted on a
   screen that showed that revision's text. `revoke()` clears both, so Settings "Turn off" and account erase clear it.
   Side effects to accept or design around: everyone is asked again for every AI tool; and because `isCurrent` requires
   `isGranted` (`PropertyVideoJobsAPI.swift:11-14`), saved property-video jobs on the device cannot be polled, cancelled
   from the job screen or resumed until the person agrees again (cancel-all still works, `:60-85`).
   Option B: keep v3 and add a Kie-only permission shown only at the property-video door. No global re-ask, but the
   general sheet and Settings footer would not list Kie, contrary to the key rule. Either way, **a v3 grant alone must
   never produce a v2 header.**
3. **Sending v2:**
   - Before a create, call `GET /property-video-jobs/processor-consent`.
   - 404 (nothing published): send v1 (legacy/FAL only). If the create then answers `processor_disclosure_unpublished`
     or `processor_consent_required` (the profile is Kie), say native-4K video is not available on this version and do
     not retry with v2.
   - 200 with a revision this build ships card text for, and the stored accepted revision equals it: send v2 and the
     revision.
   - 200, revision known but not yet accepted (or another accepted): show the Kie disclosure with explicit "Agree and
     continue" / "Not now"; send v2 only after Agree; store the revision.
   - 200 with a revision this build does not know: do not send v2; ask the person to update the app. (Server-provided
     card text is the alternative; it would put text App Review never saw on the consent screen.)
   - `processor_consent_required` after a v2 send, or a create 403 with no code (section 1.2 race): refetch, ask again,
     retry the same operation only after Agree. The 403 body already carries the current disclosure (`index.ts:30`).
   - Resume of a v2 job: the edge needs only the v2 token (`index.ts:47-49`). Send it only while the stored v4 grant
     stands; never send v2 to resume when the person has not accepted any v2 revision.
   - Only create and resume carry the consent headers that matter; GET and cancel can keep today's header.
   - Store the headers with the saved request so a replay sends the same ones (`PropertyVideoJobRunner.swift:166-167`).
4. **Revocation unchanged.** Turn off → `revoke()` → `consentWasRevoked()` → cancel-all
   (`PropertyVideoJobCancellation.swift:68-77`). Clips Kie has already accepted cannot be recalled; the server stops
   sending new clips.
5. **Tests to change with it:** the card list and key pins, a negative control that a persisted v3 YES cannot grant v4
   (same shape as `consent-disclosure.test.mjs:114-134`), the 13 launch overrides (`:52-73`), and new tests: no v2 header
   without a stored revision equal to the server's; a revision change asks again; revoke clears the revision; a replay
   keeps the original headers.
6. **Owner-only test:** proposed to stay out of the shipped app; the grant header belongs in an owner-only Studio control
   (section 4). Codex decision.

## 4. Studio (proposed; Codex's lane)

### 4.1 Current source

| Fact | file:line |
|---|---|
| Consent checkbox state lives in the page session only (not stored) | `apps/studio/src/features/sync/MakeVideo.tsx:36` |
| Text: "I allow AI processing of these selected property photos. I'll review the result for property accuracy." | `MakeVideo.tsx:205` |
| Create refused without it; Resume button requires it | `MakeVideo.tsx:121`, `:209` |
| Create and resume send v1 | `apps/studio/src/features/sync/property-video.ts:116`, `:81` |
| `aiConsent` accepts only `property-video-jobs-v1` / `property-video-plan-v1`; sent as `X-Rendprop-AI-Consent`; allowed only on POST to create, resume and plan | `apps/studio/src/data/services.ts:127`, `:425`, `:660-663` |
| Studio links the website privacy policy | `apps/studio/src/App.tsx:870-874` |
| The edge already allows the two new headers in CORS | `property-video-jobs/index.ts:2` † |

### 4.2 Proposal

1. On opening Make Video and before a create, call `GET /functions/v1/property-video-jobs/processor-consent`.
2. If it returns a revision, show a Kie panel with the section 2 facts and a second, unchecked checkbox (proposed —
   owner/legal decision): "I allow Kie to process these selected property photos to make the video clips, as described
   in disclosure `<revision>`. Kie's terms let it use submitted content to operate and improve its services." Send v2 and
   the revision only when that box is checked in this page session and the revision still equals the server's. Otherwise
   send v1 as today.
3. Types and guards: allow `property-video-jobs-v2` on the same two paths and method only; add an `aiConsentDisclosure`
   option validated like the edge and SQL (`^[!-~]{1,200}$`; `index.ts:19`, `20261016110000…sql:136`) and sent as
   `X-Rendprop-AI-Consent-Disclosure`; refuse v2 on create without it.
4. Save the consent headers (and a grant id, if any) with the operation's journal (`property-video.ts:114-117`) so a replay
   sends the same ones.
5. Errors: `processor_consent_required` (or a create 403 without a code) → refetch, untick, show the current revision.
   `processor_disclosure_unpublished` → say native-4K video is not available yet. Never switch the same operation from v2
   to v1 automatically: that would create a job under a different permission and possibly a different processor.
6. Owner-only test (if Studio is that client): an admin-only control that sends `x-rendprop-quality-test-grant`, never
   shown in ordinary UI; the owner still ticks the Kie box for the current revision (section 1.3).

## 5. Website and legal text (proposed — owner/legal decision)

### 5.1 Current statements

| Statement | file:line |
|---|---|
| Terms §4: "never uses it to train AI models without your written consent" | `services/edge/tour-host/src/legal.ts:181-182` |
| Terms summary: "we never use it for marketing or AI training without your written consent" | `legal.ts:271-273` |
| Privacy §2: "never used to train AI models without your written consent" | `legal.ts:346-347` |
| Website FAQ (HTML and JSON-LD) and support page: same promise, "written permission" | `services/edge/tour-host/public/index.html:113`, `:572-574`; `public/support.html:196-197` |
| Privacy §3 processor table: fal.ai row, no Kie row | `legal.ts:349-367` (fal.ai `:363`) |
| Provider-copies paragraph names Google and Bria | `legal.ts:372-377` |
| Privacy §5: provider copies follow their retention settings | `legal.ts:438-439` |
| Notice before a material change: Terms §10, Privacy §8 | `legal.ts:259-261`, `:458-459` |
| Effective date | `legal.ts:12` |
| CI pins: provider rows, effective date, "without your written consent" in both pages, 14 rows / 39 cells | `services/edge/tour-host/scripts/check-legal.mjs:25-36`, `:50`, `:54`, `:81-82` |

### 5.2 Processor entry and retention (Privacy §3)

- Table row: **Kie (kie.ai)** · "Property video clips generated from listing photos you select" · "The selected listing
  photos, fetched through a temporary link, and camera-motion instructions".
- Provider-copies paragraph, add: "Kie's API documentation states that generated media is deleted after 14 days and
  request logs after two months. Kie's published terms do not state how long it keeps the photos it fetches."
- Training, add (neutral): "Kie's terms license submitted content to Kie to operate and improve its services. They do
  not expressly say whether content sent through its API is used to train models."
- CI: add `provider("Kie (kie.ai)", [...])`; rows 14 → 15 and cells 39 → 42 (`check-legal.mjs:81-82`); new effective
  date (`legal.ts:12`, `check-legal.mjs:50`).

### 5.3 The training promise

Compatibility of the current promise with Kie Terms §3 is **unresolved**, not a settled conflict: §3 licenses submitted
content to Kie for operating and improving its services; that does not prove training occurs, and the reviewed text has
no express API no-training guarantee (`packet:25`). Options (owner/legal decision; this lane recommends none):

- A. Keep the promise and settle the question in writing with Kie before broad activation (not requested by this lane).
- B. Treat the explicit in-app Kie permission (sections 3-4) as the "written consent" the promise already allows. Legal
  decides whether that is adequate.
- C. Narrow the promise to Rendprop's own use and disclose provider terms. Proposed Privacy §2 text: "Rendprop never uses
  your content for its own marketing and never uses it to train Rendprop's own AI models without your written consent.
  Some AI providers' terms license submitted content to them to operate and improve their services; section 3 names
  them." Mirror in Terms §4, the Terms summary, the website FAQ (HTML and JSON-LD) and the support page;
  `check-legal.mjs:54` must change on purpose.

### 5.4 Notice before the change takes effect

Terms §10 and Privacy §8 promise to flag a material change "in the app or by email before it takes effect"
(`legal.ts:259-261`, `:458-459`). Proposed order: publish the updated pages; send the notice ahead of the effective
date; record date and channel in a new `docs/legal/RENDPROP-LEGAL-NOTICE-<date>.md` (precedent:
`docs/legal/RENDPROP-LEGAL-NOTICE-20261010.md:1-7`); only then publish the revision in
`app_config.property_video_processor_consent`. Whether a given notice period is sufficient is a legal question.

### 5.5 One identifier

`disclosure_revision` should identify the exact published text the person saw (for example the Privacy Policy version
and effective date). Proposed: `KIE-ACTIVATION.sql`'s `processor_disclosure` must equal it; today the script checks only
the identifier's format (`KIE-ACTIVATION.sql:86-91` †).

## 6. Admin and operator copy (proposed)

- `apps/ios/Rendprop/Screens/SettingsView.swift:5539-5546` (admin routing explainer for every `trains_by_default` row)
  says "This provider trains on what we send unless we opt out. Do not send a customer's home here." (`:5543`). The tier
  stays. Proposed explainer: "Treated as trains-by-default: this provider's terms do not rule out using what we send to
  improve its service. Customer media only through a profile that records the customer's own processor permission." An
  owner or operator acknowledgement is not that permission. Needs an iOS build.
- `services/supabase/functions/admin/index.ts:407-417` names Kie "KIE.ai (one-key multi-model fallback)" with
  `optional: true` and "set KIE_API_KEY only to route restage through KIE". Proposed: while the selector names Kie or Kie
  jobs drain, show `KIE_API_KEY` as required (without it accepted clips cannot be polled) and name the property-video
  role.
- `services/supabase/set-secrets.sh:79-85` and `docs/GPT-AGENT-BRIEF.md:54-57` still say Kie rows stay disabled pending
  written no-training terms. Update them only together with the owner's recorded decision on section 5.3.

## 7. App Store 5.1.2(i) and the three stages

- The rule requires clear disclosure of personal-data sharing with third-party AI and explicit permission before
  sharing. Apple does not prescribe a v4 key or a v2 token; those are engineering choices. Operator acceptance of a v1
  token cannot show the affected user's permission. Historical FAL-job consent and recovery stay as they are
  (`policy.json:28-33`; `packet:28`). This is a release-gate observation, not a legal conclusion.
- **Stage 1, offline code and proofs:** none of sections 3-6 is needed; no App Store release and no public legal
  deployment (`packet:40`).
- **Stage 2, one bounded owner-only QA test:** the owner's own explicit, scoped processor permission given through a
  client (v2 for a recorded disclosure revision), Codex's exact approved grant (created by an operator step that does not
  exist yet, section 1.3), and the owner lifting the paid-test pause (`packet:34`, `:40`). The acknowledgement in the
  selector is not that permission.
- **Stage 3, broad customer activation:** updated Privacy/Terms published with the Kie row and the reconciled promise
  (5.2-5.3); notice before it takes effect (5.4); a reviewed iOS build with the Kie card and revision logic live; Studio
  deployed; the edge and migration deployed; the revision published in `app_config.property_video_processor_consent`;
  review notes and privacy-label answers reconciled (`docs/appstore/review-notes.md:25`;
  `docs/appstore/privacy-labels.md:11-12`, `:32`); then `KIE-ACTIVATION.sql`.
- While the selector names Kie, v1-only clients (every shipped iOS build and current Studio) cannot create property
  videos: they get `processor_consent_required` or `processor_disclosure_unpublished`. Open question 6.

## 8. Open questions

1. Resume of a v2 Kie job: the edge accepts the bare v2 token for any job, with no revision check
   (`property-video-jobs/index.ts:47-49`; README `:22`), and the stored record cannot change
   (`20261016110000…sql:253-255`). Confirm that is intended.
2. v2 on a legacy/FAL job is accepted and stored (README `:20-21`; table in 1.2). Confirm, or ignore/refuse it.
3. Should `processor_disclosure` (activation) equal `disclosure_revision` (section 5.5)?
4. Card text compiled into the reviewed app (proposed) or served by the backend?
5. Permission per device (iOS today, `RendpropApp.swift:4829-4830`) or per account?
6. While the selector names Kie, are v1-only clients refused (current code), or should broad activation wait for client
   adoption? Only the selector or a grant decides the profile (`20261016110000…sql:177-185`).
7. Owner-test grant versus invariant #144 (section 1.3).
8. Vendor questions still open: training on API content, retention of fetched inputs and upstream copies, output
   license. No one was contacted.
