# Kie property-video profile — activation preconditions, remaining FAL inventory, canary facts

Lane F3, 2026-10-16. Worktree `claude-kie-video-migration`, base `462e4c8` plus the uncommitted candidate
(`kie-kling3-4k-steady-v1`, see `KIE-MIGRATION-WORKING-SPEC.md`). Read-only audit: no provider, network, DB or
git-write actions; secret **names** only.

Conventions
- Paths are repo-relative. `†` = file modified or added by the candidate and still being edited by parallel lanes.
  Its line numbers were re-read at 15:29–15:42 UTC and most cites carry an anchor (function name or literal) so they
  can be re-found if lines drift. Unmarked files are unchanged from `462e4c8` (checked with a read-only
  `git diff --name-status 462e4c8` plus `ls-files --others`).
- Reconciled 2026-10-16 by lane S4 (documents only, no shell, so no git): every `†` cite re-read; stale claims fixed
  (log at the end). Since F3, `_shared/providers/common.ts` became a modified file (G2; listed in the build87 review
  receipt `/Volumes/Rendprop Files/Builds/Active/build87-kie-current-handoff-review-1715/OBSERVED-CURRENT-SOURCE-V2.json:10`)
  and migration `20261016110000_property_video_kie_scope_consent_drain.sql` † was added; both are now marked `†`.
- Quotes are ≤ 15 words. Every "Proposed" text is **proposed — owner/legal decision**. This lane edits no legal text.
  Proposed client and legal wording now lives in one place: `docs/handoff/KIE-CONSENT-CLIENT-PROPOSALS.md`.

---

## 0. Verdict

The migration seeds the pinned Kie row OFF and does not touch the selector
(`services/supabase/migrations/20261016100000_property_video_kie_kling3_4k_profile.sql:6-8`, `:20-22` †); only
`docs/handoff/KIE-ACTIVATION.sql` enables it (`:39-43`, `:130` †). Any older note that the row ships enabled is stale.

### Activation blockers (resolve before `KIE-ACTIVATION.sql` runs)

| # | Blocker | Evidence | Clears when |
|---|---|---|---|
| B1 | Published processor list names fal.ai and not Kie | `services/edge/tour-host/src/legal.ts:349-367` (fal.ai row `:363`) | Kie row published (A1); that published version is what `-v processor_disclosure=` records (`docs/handoff/KIE-ACTIVATION.sql:12-14` †) |
| B2 | Terms, Privacy and the website promise content is never used to train AI models without written consent. Kie Terms §3 licenses submitted content to Kie for operating and improving its services; that does not prove training occurs, and the reviewed text has no express API no-training guarantee. Compatibility with the promise is unresolved (review packet `FINAL-CURRENT-BLOCKERS-AND-NEXT-CLAUDE-ASSIGNMENT.md:25`) | `legal.ts:181-182`, `:272-273`, `:346-347`; `services/edge/tour-host/public/index.html:113`, `:572-574`; `public/support.html:196-197` | Owner/legal picks one option in A2 |
| B3 | In-app third-party AI consent (App Review 5.1.2(i)) names fal.ai, not Kie, and the device grant (key `v3`) stores no disclosure revision. The new SQL never admits Kie on v1 (`20261016110000…sql:144-145` †), so a v3 grant must never be turned into a v2 header | `apps/ios/Rendprop/RendpropApp.swift:4835-4839`, `:4860-4871` | Kie card, new key and stored revision in a shipped iOS build (A3; `KIE-CONSENT-CLIENT-PROPOSALS.md` §3) |
| B4 | The edge still accepts only `property-video-jobs-v1` for create and resume, which iOS and Studio send after a disclosure that does not name Kie. Migration `20261016110000` † (source only, unexecuted) widens the jobs CHECK to v1/v2, requires v2 for the current published revision on every Kie job and stores it immutably; no edge wiring or client change exists yet | `services/supabase/functions/property-video-jobs/index.ts:18`, `:21`; `apps/ios/Rendprop/Networking/PropertyVideoJobsAPI.swift:119`; `apps/studio/src/data/services.ts:127`; `services/supabase/migrations/20261014183851_background_property_videos.sql:7`, `:82`; `20261016110000…sql:113-125`, `:142-153` † | Edge contract deployed and clients send v2 only after showing the Kie disclosure (A3; proposals doc §1-4). An operator's acceptance of v1 cannot show the user's permission (review packet `:28`) |
| B5 | Terms §10 and Privacy §8 promise notice **before** a material change takes effect | `legal.ts:259-261`, `:458-459` | Notice flagged in app/email ahead of the activation date (A7) |
| B6 | Operator rules/copy still forbid customer homes on Kie | `apps/ios/Rendprop/Screens/SettingsView.swift:5543`; `docs/GPT-AGENT-BRIEF.md:54-57`; `services/supabase/set-secrets.sh:79-85` | Updated in the activation release (A4) |

### Gates on the first approved Kie clip (a later owner-only test or the first job after activation; see S1)

Content-Type must be exactly `video/mp4`, file ≤ 64 MiB, H.264 8-bit 4:2:0, exactly 24/1 CFR, 120/121 frames, SDR
BT.709 — otherwise the clip fails terminally (Part C3). Since G2 this includes a retained Kie clip stored with another
type or larger than 64 MiB (`property-video-worker/engine.ts:57-67` †). Transport errors, a missing or changed retained
object, and results the persistence step refuses (over 100 MiB, image extension) still re-poll until the 24 h deadline
(`engine.ts:48-50` †; `ai-video/index.ts:2299-2304` †).

---

## Part A — Activation preconditions

### A1. Subprocessor / vendor disclosures

| Surface | file:line | What it says | FAL | Kie | Change before activation |
|---|---|---|---|---|---|
| Website Privacy §3 table | `services/edge/tour-host/src/legal.ts:349-367`; fal.ai row `:363` | "Rendprop uses the infrastructure and AI providers below." | ✓ | ✗ | Add Kie row; bump `EFFECTIVE_DATE` (`:12`) |
| Website Terms §4 | `legal.ts:177-180` | "passing it to the processing providers listed in our Privacy Policy" | by reference | ✗ | True once the Kie row is published |
| Legal CI check | `services/edge/tour-host/scripts/check-legal.mjs:25-36`, `:50`, `:81-82` | pins one row per provider; 14 rows / 39 cells | ✓ | ✗ | Add `provider("Kie …")`; 15 rows / 42 cells; new date |
| Rendered notice record | `docs/legal/RENDPROP-LEGAL-NOTICE-20261010.md:3`, `:7`, `:278` | provider terms checked: Gemini, fal, Bria, Anthropic | ✓ | ✗ | New dated notice rendered from the updated `legal.ts`, citing Kie's terms |
| iOS consent sheet | `apps/ios/Rendprop/RendpropApp.swift:4860-4871` | `Processor(name: "fal.ai", …)` — no Kie card | ✓ | ✗ | Add Kie card; new `storageKey` (`:4839`) plus the accepted disclosure revision (proposals §3) |
| iOS Settings › Your data | `apps/ios/Rendprop/Screens/SettingsView.swift:110` | prints `AIConsent.processors` names | ✓ | ✗ | Follows the consent list |
| Consent copy test | `tests/phase1/consent-disclosure.test.mjs:18-24`, `:47-50` | pins the exact five cards and the `v3` key | ✓ | ✗ | Update cards + key deliberately |
| Studio property-video consent | `apps/studio/src/features/sync/MakeVideo.tsx:205` | "I allow AI processing of these selected property photos." | ✗ | ✗ | Name Kie (proposed below); Studio links `/privacy` at `apps/studio/src/App.tsx:870-874` |
| App Store review notes | `docs/appstore/review-notes.md:25`; `docs/appstore/metadata/en-US/review_notes.txt:13` | "Consent names providers and media/text uses" | n/a | n/a | True only after the Kie card ships |
| Admin provider inventory (admin-only) | `services/supabase/functions/admin/index.ts:302-375` (fal), `:407-427` (kie) | Kie: "KIE.ai (one-key multi-model fallback)", `optional: true` | ✓ | ✓ (as restage fallback) | See A4 |

Lists naming FAL but not Kie: website Privacy table, its CI check and notice record, iOS consent sheet + Settings,
the consent test. Studio and the website FAQ name no vendor and defer to `/privacy`.

Proposed wording (owner/legal decision) is kept in one place so it cannot drift:
`docs/handoff/KIE-CONSENT-CLIENT-PROPOSALS.md` §3.2 (iOS card and bullet), §4.2 (Studio checkbox), §5.2-5.3 (Privacy
§3 row, retention sentence, neutral training sentence, options for the promise). Kie facts it relies on, and the ones
that stay unresolved, are in its §2.

### A2. Promises whose compatibility with Kie Terms §3 and Kie retention is unresolved

Kie facts as recorded in the repo: §3 licenses content "for the purpose of operating and improving our services"
(`services/supabase/functions/_shared/property-video-kie.ts:10-11` †; `docs/handoff/KIE-ACTIVATION.sql:9-10` †);
files kept 14 days (`property-video-kie.ts:9` †; `_shared/providers/kie.ts:52` † "Kie deletes generated media after
14 DAYS"; `docs/AI-ROUTER-CONTRACT.md:89`). FAL by contrast: our adapter *requests* 24 h output expiry because "fal
keeps result objects indefinitely by default." (`_shared/providers/fal.ts:12-16`, `:37-39`, `:408`) — a request,
not a guarantee (`docs/audits/2026-09-10/AI-CONSENT-DISCLOSURE.md:137-141`). Nothing equivalent exists for Kie.

Official-source observations retrieved 2026-10-16 (external review packet
`/Volumes/Rendprop Files/Builds/Active/build87-kie-current-handoff-review-1715/FINAL-CURRENT-BLOCKERS-AND-NEXT-CLAUDE-ASSIGNMENT.md:25-28`
and `OFFICIAL-POLICY-VERIFICATION.json:6-33` there; not re-read by this lane, not legal conclusions):
- Kie Terms §3 (effective date printed 2025-08-01) licenses submitted content for operating and improving Kie's
  services. That does not prove training occurs, and the reviewed text has no express API no-training guarantee.
- Kie API guide §6: generated media 14 days and text/metadata logs 2 months, then automatic deletion. Nothing reviewed
  establishes how long fetched input images, upstream model copies or backups are kept, or a specific generated-output
  redistribution license. A two-hour source URL is access expiry, not vendor deletion.
- Kie's Privacy Policy is account-email focused and does not resolve these questions.

| Statement | file:line | Quote | Compatibility question |
|---|---|---|---|
| Terms §4 | `legal.ts:181-182` | "never uses it to train AI models without your written consent" | Kie Terms §3 licenses content for improving its services; whether API content is used for training is not stated either way — unresolved |
| Terms summary | `legal.ts:271-273` | "we never use it for marketing or AI training without your written consent" | same |
| Privacy §2 | `legal.ts:346-347` | "never used to train AI models without your written consent" | passive voice — can be read as covering vendors; unresolved as above |
| Website FAQ (HTML + JSON-LD) | `services/edge/tour-host/public/index.html:113`, `:572-574` | "never used for our marketing or to train AI models without your written permission" | same |
| Website support page | `services/edge/tour-host/public/support.html:196-197` | "never to train AI models, without your written permission" | same |
| iOS consent bullet | `RendpropApp.swift:5001-5002` | "These services process what is sent to return your result." | does not mention that a processor's terms license content for improving its services |
| Privacy §3 retention note | `legal.ts:372-377` | "Provider copies can remain after a result is saved in Rendprop." | names Google and Bria only; a Kie entry would add 14-day media and 2-month logs (API guide §6) and state that input retention is not published |
| Privacy §5 | `legal.ts:438-439` | "provider copies follow their applicable retention settings" | consistent with the above |
| Consent test guard | `tests/phase1/consent-disclosure.test.mjs:40` | rejects `retained for` and `no.training guarantee` in consent copy | Kie copy must avoid those phrases or the guard changes on purpose |
| Internal policy | `docs/GPT-AGENT-BRIEF.md:57`; `HANDOFF-DB.md:147-149`; `services/supabase/migrations/0018_ai_routes.sql:255-258` | "Kie and Higgsfield are disabled pending written no-training terms." | Activation reverses this; record the decision |

Options for B2 (owner/legal decision — pick one before broad activation; this lane recommends none):
1. Settle the question in writing with Kie (for example a DPA or addendum on API content and training) → the promises
   stand. Not requested by this lane; no one was contacted.
2. Treat the explicit in-app Kie permission (iOS card, Studio checkbox, v2 server token, A3) as the "written consent"
   the promise already allows — legal decides whether that is adequate.
3. Narrow the promise to Rendprop's own use and disclose provider terms (proposed text in
   `KIE-CONSENT-CLIENT-PROPOSALS.md` §5.3). Mirror in Terms §4/summary and the three website lines;
   `services/edge/tour-host/scripts/check-legal.mjs:54` pins the current wording and must change on purpose.

### A3. Consent-version mechanics (why B3/B4 are blockers)

| Fact | file:line |
|---|---|
| iOS key comment: "Bumped if the set of processors or what we send them ever changes" | `RendpropApp.swift:4835-4836`; key `ai.thirdPartyProcessing.consent.v3` at `:4839` |
| Precedent: Bria disclosure forced v2→v3, with a negative test that an old grant cannot authorize it | `tests/phase1/consent-disclosure.test.mjs:114-134` |
| Server requires exactly `property-video-jobs-v1` to create and to resume | `property-video-jobs/index.ts:18`, `:21`; `property-video-jobs/README.md:13` |
| Jobs table pins the revision; enqueue writes the literal | `20261014183851_background_property_videos.sql:7` (CHECK), `:82`; widened to v1/v2 with "Kie ⇒ v2" by `20261016110000…sql:113-125` † (source only) |
| Clients send v1 | iOS `PropertyVideoJobsAPI.swift:119`; Studio `services.ts:127`, `:425`, `:660-662`, `apps/studio/src/features/sync/property-video.ts:81`, `:116` |
| Server-side processor-consent precedent | `services/supabase/functions/ai-video/erase.ts:18` (`bria-video-v1`), checked `:63-64` |
| Audit rule | `AI-CONSENT-DISCLOSURE.md:91-92` "Adding a different recipient requires owner review and updated consent" |

Status (2026-10-16, as read): the SQL half exists in source only. Migration `20261016110000` † widens the CHECK, adds
an immutable `processor_consent` record, requires `property-video-jobs-v2` for the current published disclosure
revision on every Kie job and never accepts v1 for Kie (`:104-153`, `:253-260`); the disclosure config is not seeded,
so Kie admission fails closed (`:13-20`). Still missing: the edge headers, GET route and 403 codes (`index.ts:18`, `:21`
unchanged), a published disclosure, and the iOS/Studio changes. Contract and proposals:
`KIE-CONSENT-CLIENT-PROPOSALS.md`. v1 stays valid for legacy/FAL jobs and their resume; while the selector names Kie,
v1-only clients cannot create property videos (owner/Codex decision, proposals §8 question 8).

### A4. Admin/operator copy that warns against or restricts Kie

| Copy | file:line | Quote | Change before activation |
|---|---|---|---|
| iOS admin routing explainer, shown for every `trains_by_default` row — including the pinned Kie row once ON | `SettingsView.swift:5539-5546` (text `:5543`) | "This provider trains on what we send unless we opt out. Do not send a customer's home here." | Keep the tier. Proposed explainer in `KIE-CONSENT-CLIENT-PROPOSALS.md` §6: customer media only through a profile that records the customer's own processor permission; an owner acknowledgement is not that permission (needs an iOS build) |
| Owner-QA module (Kie only for the owner's own listing) | `services/supabase/functions/ai-video/owner-reel-qa.ts:1-3`, `:13`, `:51`, `:89` | "Temporary owner-only model comparison. This is not a public route switch" | Keep; add a header note that the Kie *property profile* is separate (pinned row + selector acknowledgement) |
| Secrets script | `set-secrets.sh:36`, `:79-85` | KIE key "should stay blank until the terms are signed" | KIE_API_KEY required while the selector names Kie |
| Admin provider inventory | `admin/index.ts:256`, `:407-427`, `:719` | "set KIE_API_KEY only to route restage through KIE" | `optional: true` would show a missing key as "optional, off" during a Kie outage; add the `kling-3.0/video` 4K SKU (33.5¢/s) |
| Agent rules | `docs/GPT-AGENT-BRIEF.md:54-57` | "Never enable a disabled `ai_routes` row." | Add the `KIE-ACTIVATION.sql` exception |
| DB / admin / router contracts | `HANDOFF-DB.md:145-149`; `docs/ADMIN-CONSOLE-CONTRACT.md:430-432`; `docs/AI-ROUTER-CONTRACT.md:105`, `:108` | Kie rows "disabled until commercial-rights confirmed" | Record the owner exception (the invariant already does: `services/supabase/tests/invariants.sql:1327-1365` †) |
| Seed comments (historical — do not edit) | `0018_ai_routes.sql:85-90`, `:255-258`, `:327-330` | "every Kie row — commercial/redistribution rights unconfirmed" | Document in the handoff only |
| Admin step switch | `admin/index.ts:2129-2159`; only `note='legacy'` rows are protected (`:2146-2153`) | any admin can flip `enabled` on the pinned Kie row | Guard the pinned row (or document it as emergency-off only); "only KIE-ACTIVATION.sql enables it" is procedural today |
| Provider-down alert | `services/supabase/functions/notify/copy.ts:100-101` | names FAL, OpenAI, Google | Kie reads as "The connected AI service"; add Kie |
| Admin mock data | `apps/ios/Rendprop/Networking/MockAPIClient.swift:404`, `:516` | "KIE.ai (fallback route)" | cosmetic |

### A5. App Store (owner decision)

- Review notes `docs/appstore/review-notes.md:25` and `metadata/en-US/review_notes.txt:13` stay true only if the
  Kie card ships first.
- Privacy label: Photos or Videos declared for "App Functionality" only (`docs/appstore/privacy-labels.md:32`);
  the file says to reconcile "with the shipped privacy manifest and actual feature/provider collection"
  (`:11-12`). Whether a processor that may use photos to improve its own service changes the declared purposes is an
  owner/legal call.
- The consent gate's own rationale (`RendpropApp.swift:4811-4821`) is why a new card needs a reviewed build.

### A6. Router privacy rule — and why the candidate reads the pinned row by id

| Fact | file:line |
|---|---|
| Tier semantics: customer-media "callers never touch `trains_by_default`"; unknown terms assume the worst | `0018_ai_routes.sql:85-90`; default `retained_30d` `:113`; CHECK `:125-128` |
| Context flag | `_shared/router.ts:128` (`carries_customer_media`) |
| Enforcement in `orderSteps`: hard drop + `no_retention` dominant sort | `router.ts:353-358`, `:373`, `:382`, `:388-392` |
| Unknown tier read as `trains_by_default` | `router.ts:488-495` |
| Scope: only paths through `orderSteps` — router ON (`router.ts:278-301`) and photo legacy (`:326-328`). Non-photo router-OFF returns the `legacy` row forced enabled, unfiltered (`:330`) | `router.ts:274-334` |
| Property/reel callers set customer media | `ai-video/index.ts:1109` † (`propertyVideoRecipeQuote`), `:1590-1603` † (`candidateSteps`); `ai-video/property-video-quality.ts:84` † |
| Consequence: `resolveRoute` can never return the Kie row for customer media, so the candidate reads row `7f2c9a3e…` by primary key and checks every identity field | `property-video-quality.ts:44-48` † (`readPinnedRoute`), `:52-64` † (`kiePropertyRouteStep`), `:74-81` † |
| The bypass is an explicit, recorded operator decision | selector ack `migrations/20261016100000_property_video_kie_kling3_4k_profile.sql:53-56` †; admission re-check `:63-70` †; invariant exception `tests/invariants.sql:1327-1415` †; activation record + `processor_disclosure` `KIE-ACTIVATION.sql:4-14`, `:44-50`, `:140-147` † |
| An operator record is not user permission; the user's permission is the separate v2 record on each Kie job | `20261016110000…sql:13-20`, `:142-153` † |
| Precedent: owner-QA Kie step also bypassed the router, with a per-listing recorded consent and `trains_by_default` | `owner-reel-qa.ts:1-3`, `:13`, `:51`, `:89` |

Do not "fix" this by relabelling the tier; the audit rule is explicit: "Do not enable disabled vendors to match a
broader disclosure." (`AI-CONSENT-DISCLOSURE.md:143-144`).

### A7. Process before the activation date

1. Legal decision on A2; publish Privacy/Terms with the Kie row (tour-host deploy + readback, precedent
   `docs/handoff/PUBLIC-LEGAL-ROLLOUT-20261007.md:3-7`); new `docs/legal/RENDPROP-LEGAL-NOTICE-<date>.md`.
2. Notice to users before it takes effect (B5).
3. iOS build with the Kie card, new key and stored revision approved and live; Studio copy deployed; the v2 edge
   contract deployed on top of migration `20261016110000` †; the published revision recorded in
   `app_config.property_video_processor_consent` (A3; `KIE-CONSENT-CLIENT-PROPOSALS.md` §7).
4. Admin/ops copy (A4); KIE_API_KEY set; Kie shown non-optional.
5. Run `KIE-ACTIVATION.sql` with `-v processor_disclosure=<published version>`. Note the script checks only the
   identifier's format (`KIE-ACTIVATION.sql:12-14`, `:86-91` †), not the disclosure content, consent version or token.

---

## Part B — Remaining FAL dependencies (for the release lead)

### B(i) Historical FAL property video — must stay recoverable under its original identity

| Item | file:line | Why it must stay |
|---|---|---|
| Saved profiles `legacy`, `fal-kling3-4k-v1`, `fal-kling3-4k-steady-v2` remain valid and immutable | `20261016100000…sql:92-98` † (CHECK); freeze `20261015073835_property_video_immutable_quality_profile.sql:22-37`; parser `property-video-quality.ts:29-33` † | resumes/polls dispatch under the frozen profile |
| FAL quality route `b04b57c1…` (`video.property_reel_clip`, fal Kling 3 4K, 42¢/s) | `20261015073835…sql:5-7`; resolver demands exactly one row `property-video-quality.ts:83-87` † | resumes of FAL-quality jobs; needs `ai_router` ON — "New FAL task has no legacy seat and requires routerON." (`docs/handoff/OWNER-CONTEXT-20261014.md:514-515`) |
| Legacy FAL Seedance | `0018_ai_routes.sql:508-510`; constant `MODEL_I2V` `ai-video/index.ts:737` † | `legacy` jobs |
| Signed status → adapter poll → persist | `ai-video/index.ts:1994-2042` † (`GET /ai-video/status`), `:2228-2289` † (`completed`, `output.complete`); `fal.ts:1-5`, `FAL_HOSTS` `:35` | in-flight and accepted FAL receipts |
| Legacy unsigned `queue.fal.run` receipts (older clients) | `ai-video/index.ts:2036-2038` † (`requireFalUrl`, `assertLegacyVideoReceipt`), `:2729-2755` † (both definitions); `fal.ts:55-74` (`falLegacyReceipt*`) | old builds' saved jobs |
| FAL-only worker recovery branches (Kie excluded by `!kie`) | `property-video-worker/engine.ts:38-43` † | 404/404 missing result, 403 result read |
| SQL recovery functions | see B(iii) rows 7-10 | — |
| Lost-202 journal for direct FAL reels | `ai-video/operation-recovery.ts:14-35`; caller `ai-video/index.ts:1720` † | recovery of direct reel clips |
| Operator receipt diagnostic (FAL-only) | `property-video-worker/provider-diagnostic.ts:1-27` (asserts `provider==='fal'` `:14`); route `property-video-worker/index.ts:19` † | support tooling |
| FAL video-erase jobs | `ai-video/erase.ts:15`, `:118-131`, `:150-160`; `20261002225458_video_erase_direct_bria.sql:3`, `:7` | historical erase receipts/outputs |
| Studio results referencing `fal.media` | `services/supabase/functions/studio/creative.ts:171-176` | historical imports |

FAL tail after activation is bounded by saved deadlines: `legacy` default 4 h (`20261014183851…sql:7`), FAL quality
24 h (`20261015073835…sql:33`; steady-v2 via `20261016002000_property_video_steady_v2.sql:7`); no deadline-extension
statement found in migrations. Keep `FAL_KEY` and `JOB_TOKEN_SIGNING_SECRET` (`set-secrets.sh:27-28`) until every
FAL-profile job is terminal and past deadline, and until B(ii) features are migrated.

### B(ii) Working FAL features that need their own verified migration

| Feature | file:line | FAL model(s) | Ordinary users today? |
|---|---|---|---|
| Photo editing | `0018_ai_routes.sql:271-317` (Kontext pos 3; Flux Fill declutter pos 1 `:292`); capability fix `20261010000032_private_library_adoption_and_serving_safety.sql:645-647`; `ai-photo/masked-photo-pricing.ts:5-18`; funded serving `_shared/funded-serving.ts:154-163`; package `_shared/serving-package.ts:9-17` | `flux-pro/kontext`, `flux-pro/v1/fill` | Yes when `ai_router` ON; router OFF uses enabled Gemini legacy rows only (`0056_active_photo_fallback.sql:8-20`) |
| Aerial intro | `ai-video/index.ts:1274` † route, gate `:372-378` †; `0018_ai_routes.sql:339-357`, `:511-516`; `apps/ios/Rendprop/Support/LaunchFeatureAvailability.swift:7` | Seedance v1 pro fast, Veo 3.1 fast | No — sponsored beta; app shows Coming soon |
| AI enhance / drone (Topaz) | `ai-video/index.ts:1160-1229` † (asserts FAL Topaz `:1229`); `ai-video/dronecost.ts:28-34`; iOS `RendpropApp.swift:2449-2450`, `Screens/RenderStatusView.swift:490` | `topaz/upscale/video` | Team add-on; trial overrides grant 1 (`0044_plan_rework_and_industry_trial.sql:118-122`) |
| Video reflection/object removal | `ai-video/erase.ts:15`, `:48-69` ("App Store clients retain fal."; direct Bria = allowlisted beta) | `bria/video/erase/prompt` on fal | Yes — Review & Submit (`Screens/ReviewSubmitView.swift:107-110`) |
| Direct reel clip (non-worker `POST /ai-video/reel-clip`) | `ai-video/index.ts:1453` † (non-worker = `legacy`), `:1591-1603` †; iOS animate photo `Screens/FlythroughDetailView.swift:5984`; Reel Studio per-clip path when a sample or extra clip is present (`:13179` gate → `:13592-13600`); Studio creative "reel" `studio/creative.ts:781-786`, `:822-828` | Seedance v1 pro fast (+ resolveChain constant) | Yes |
| Owner QA comparisons | `owner-reel-qa.ts:14-15`, `:66-77` (FAL Kling 4K), `:78-91` (Kie) | Kling 3 4K | Admin only, ≤ 24 h grant |
| Studio import allowlist | `studio/creative.ts:171-176` | `fal.media`, `*.fal.media`, `v3.fal.media` | Studio users |
| Admin probes / inventory | `admin/probe.ts:315-351` (fal), `:462-468` (kie); `admin/index.ts:302-375`; iOS `Screens/AdminProbeAPI.swift:328-331`, `:418` | key check only | Admins |
| Python enhancement pipeline (optional worker) | `services/pipeline/providers/fal_client.py:48-52`, `:73-90` (uploads inputs to fal's public CDN), `:69`; `services/pipeline/router.py:148`, `:166-172`, `:187-200`, `:242-249`; `services/worker/enhance_bridge.py:110-113` | Flux Fill, Kontext, Seedance hero, Topaz | Unproven — "does not establish that a production worker fleet is currently running" (`services/worker/README.md:18-19`) |
| Audit tooling (live, paid) | `tools/audit/call-20260919/reflection/bria-smoke.ts:8-9`, `:52`, `:91` | bria erase on fal | Not product |
| Dormant rows | `0034_agent_reel_and_video_ladder.sql:91-125` (disabled, "NO CALLER") | Seedance 2.x | No |
| Price tables | `ai-video/cost-reservation.ts:98-116`; `_shared/ledger.ts:125-136` | — | — |

### B(iii) SQL hard-codes

| # | Object | file:line | Hard-code | Kie impact |
|---|---|---|---|---|
| 1 | `ai_routes` FAL seeds + `legacy` rows | `0018_ai_routes.sql:271-372`, `:508-520` | provider `fal`; flag-OFF answers for `video.*` | keep; per-feature migration |
| 2 | FAL quality route | `20261015073835…sql:5-7` | `video.property_reel_clip`, 42¢/s | keep for FAL resumes |
| 3 | Default selector | `20261015073835…sql:4` | `{"enabled":false,"profile":"fal-kling3-4k-v1"}` | absent/disabled → `legacy` FAL (B(v)) |
| 4 | `property_video_quality_profile()` | `20261015073835…sql:15-21`; steady-v2 `20261016002000…sql:6`; Kie `20261016100000…sql:53-56` † | FAL literals; RP503 otherwise | patched; grant-aware wrapper `property_video_quality_profile_for` `20261016110000…sql:177-185` † |
| 5 | admit / freeze | `20261015073835…sql:22-37`, `:50`, `:53` (210¢ floor) | FAL literals | patched (`20261016100000…sql:57-71` †); permission and grant scope added (`20261016110000…sql:253-261` †) |
| 6 | `paid_quality_processing_budget` | `20261015080552_paid_quality_monthly_processing_allowance.sql:17`; `20261016002000…sql:9`; Kie `20261016100000…sql:72` † | FAL profile literals | patched; Kie drain floor per billing org `20261016110000…sql:246-252` † (source only) |
| 7 | `property_video_delivery_receipt`, `property_video_job_result_read_failure` | `20261015160252_property_video_retained_result_delivery_recovery.sql:9-16`, `:46-52` | `provider='fal'`; issue `fal` 403 | no Kie delivery recovery exists |
| 8 | `property_video_submit_refusal` | `20261015165932_property_video_unaccepted_submit_recovery.sql:5-16` | FAL Kling 4K, 403, 5×42=210 | FAL-only |
| 9 | `property_video_missing_result_receipt`, `property_video_job_result_missing` | `20261015172920_property_video_missing_paid_result_replacement.sql:7-39` | FAL 404/404 | FAL-only |
| 10 | `app_video_submission_receipt_authority/save/read` | `20261015200518_app_video_submission_receipts.sql:30-60` | `provider='fal'`; `poll_url` must be `https://queue.fal.run/…` | the only SQL status-URL host allowlist; direct FAL reels only |
| 11 | `app_video_cost_reservations.provider` | `20261003020955_app_video_cost_reservations.sql:12`, `:92`; `20261009192550_team_private_listing_libraries.sql:1110` | `('fal','kie','higgsfield')` | Kie allowed |
| 12 | `video_erase_*` | `20261002225458…sql:3`, `:7`, `:89-94`; `20261009192550…sql:925`, `:1036`, `:1263`, `:3402-3426`; `20261008235218_launch_round2.sql:148`, `:173`; `20261009022239_admit_pre_and_grants.sql:32`; `20261009005727_launch_settlement_identity.sql:22`; `20261010001329_retain_deleted_video_settlement_liability.sql:38` | default `'fal'`; FAL bria ledger rows; stage `reflection.fal` | FAL erase |
| 13 | `serving_photo_partition_guard()` | `20261007145527_serving_photo_partitions.sql:72`, `:92`; restated `20261010000032…sql:342` | stage `:1` must be fal `flux-pro/kontext`, 4¢ | photo fallback tied to FAL |
| 14 | Flux Fill capability correction | `20261010000032…sql:645-647` | `provider='fal'` | photo declutter |
| 15 | Reflection ledger | `0055_video_reflection_jobs.sql:192-195` | `'fal','bria/video/erase/prompt'` 14¢ | historical |
| 16 | Consent revision | `20261014183851…sql:7`, `:82` | `property-video-jobs-v1` only | widened to v1/v2, Kie ⇒ v2, by `20261016110000…sql:113-125` † (source only); v1 stays for legacy/FAL |
| 17 | Job receipt | `20261014183851…sql:169-176` | provider-neutral; no host check | OK for Kie |

### B(iv) Secret / config names

| Name | Read at | Purpose |
|---|---|---|
| `FAL_KEY` | `ai-video/index.ts:733` †, `:1076` †; `_shared/providers/fal.ts:84`; `admin/probe.ts:336-342`; `set-secrets.sh:27`; `services/supabase/DEPLOYMENT.md:85`, `:242`; `services/pipeline/config.py:180`; `services/worker/.env.example:37`; `services/pipeline/SECRETS-ROTATION.md:38`; `tools/audit/…/bria-smoke.ts:8` | all FAL calls |
| `FAL_DECLUTTER_MODEL`, `FAL_RESTAGE_FALLBACK_MODEL`, `FAL_HERO_MODEL` | `services/pipeline/config.py:186-188`; `services/pipeline/.env.example:14-16`; `services/worker/.env.example:38-40` | pipeline models |
| `FAL_POLL_INTERVAL_S`, `FAL_TIMEOUT_S` | `services/pipeline/config.py:196-197`; `services/pipeline/.env.example:56-57` | pipeline polling |
| `VIDEO_ERASE_PROVIDER` (default `fal`) | `ai-video/erase.ts:56` | erase provider |
| `BRIA_BETA_ENABLED`, `BRIA_BETA_USER_IDS`, `BRIA_MASK_CENTS_PER_SECOND`, `BRIA_ERASE_CENTS_PER_SECOND`, `BRIA_PRICE_VERSION`, `BRIA_OUTPUT_HOSTS`, `BRIA_API_TOKEN` | `ai-video/erase.ts:60-79`; `ai-video/index.ts:1080` †, `:1087` †; `services/supabase/functions/README.md:78-79` | direct Bria beta |
| `KIE_API_KEY` | `_shared/providers/kie.ts:83`, `:92` †; `set-secrets.sh:36`, `:79-85`; `admin/index.ts:413-414`; `admin/probe.ts:462-468`; `services/pipeline/config.py:182`; `services/pipeline/SECRETS-ROTATION.md:40`; `DEPLOYMENT.md:242` | Kie |
| `KIE_I2V_MODEL`, `KIE_IMAGE_EDIT_MODEL` (legacy example, excluded from the bundle) | `apps/ios/Rendprop/Resources/Secrets.example.plist:17-21`; exclusion `apps/ios/project.yml:32-39` | none at runtime |
| `JOB_TOKEN_SIGNING_SECRET` | `set-secrets.sh:28` | signs FAL and Kie status tokens |
| `app_config` keys | `property_video_quality` (`20261015073835…sql:4`); `ai_router` (`0018_ai_routes.sql:63`); `owner_reel_provider_qa` (`owner-reel-qa.ts:10`); `property_video_jobs` (`property-video-worker/index.ts:20` †); `property_video_quality_kie_activation` (`KIE-ACTIVATION.sql:44-50`, `:146` †); `property_video_processor_consent` (`20261016110000…sql:134` †, never seeded) | selectors / switches / published disclosure |

### B(v) Fallback risks — can a NEW property-video request still reach paid FAL?

Selector `app_config.property_video_quality` (read once, globally: `20261015073835…sql:15-21`):

| Selector value | `property_video_quality_profile()` | New saved job dispatches to | Paid FAL? |
|---|---|---|---|
| absent | `legacy` (`20261015073835…sql:18`) | FAL Seedance: router OFF → `legacy` row `0018_ai_routes.sql:508-510` (forced enabled `router.ts:330`); router ON → `:324-326`; empty chain → constant via `legacyVideoStep` `ai-video/index.ts:782` †, `:1602` † | **Yes** |
| `{"enabled":false, …}` — **any** profile, Kie included | `legacy` (`:18`) | same | **Yes** |
| enabled + `fal-kling3-4k-v1` / `fal-kling3-4k-steady-v2` | that profile | FAL Kling 3 4K via `resolveRoute('video.property_reel_clip')` (`property-video-quality.ts:83-87` †); router OFF → 503 "No lower-quality generation was sent." (`:85` †) | **Yes** (router ON) |
| enabled + Kie profile + exact acknowledgement | Kie (`20261016100000…sql:56` †) | pinned Kie row only; single-step chain `ai-video/index.ts:1639` † (`runChain(task, [selected]`); no FAL step (`property-video-quality.ts:74-81` †) | No |
| legacy/FAL selector + a named owner-only test grant (inactive: no grant row, no operator script, no edge wiring) | Kie for that admission only (`20261016110000…sql:177-185` †) | pinned Kie row; scope re-checked at admission and meant to be re-checked before each paid dispatch (`:156-176`, `:203-241` †) | No |
| Kie profile with a missing or different acknowledgement; non-boolean `enabled`; unknown profile, including a hold value | RP503 (`20261015073835…sql:20`) | no admission, grant-scoped ones included (`20261016110000…sql:34-37` †) | No |
| Kie selector, pinned row OFF/changed/retired | Kie | admission RP409 (`20261016100000…sql:63-70` †); dispatch refuses before POST (`property-video-quality.ts:79-80` †; `ai-video/index.ts:1643-1650` †) | No |

Rollback restores the selector saved in the durable activation record `app_config.property_video_quality_kie_activation`
(`KIE-ROLLBACK.sql:4-8`, `:152-160` †) and never a default (`:8`, `:164-166`); `-v previous` is used only when no current
record exists (`:161-163`). By construction that value is absent, `enabled:false` or a FAL profile
(`KIE-ACTIVATION.sql:34-38`, `:106-110` †) — i.e. new jobs go back to paid FAL. EMERGENCY also restores it
(`KIE-ROLLBACK.sql:42-50` †). Still open (K10; review packet `:16`): activation does not take the operator's exact
expected baseline (selector and route state, `KIE-ACTIVATION.sql:101-111` †), and rollback checks only that the current
selector names Kie (`KIE-ROLLBACK.sql:152` †), with no exact expected-current compare-and-set. Neither script offers
"stop Kie without returning to FAL"; migration `20261016110000` † names a hold script
`docs/handoff/KIE-HOLD-NEW-ADMISSIONS.sql` (`:34-37`) that is not in the worktree as read. Repo-visible ways to stop
without FAL: keep the Kie selector and switch only the pinned row OFF (admin step switch, `admin/index.ts:2129-2159`)
so new admissions refuse RP409; or the global worker gate `app_config.property_video_jobs.enabled`
(`property-video-worker/index.ts:20` †), which halts all property-video work including Kie drain.

Paths to paid FAL that ignore the selector:
1. Direct `POST /ai-video/reel-clip` without worker scope is always `legacy` (`ai-video/index.ts:1453` †) → FAL
   Seedance. Callers: iOS animate photo (`FlythroughDetailView.swift:5984`), Reel Studio per-clip path whenever the
   job path is skipped — sample listing or an extra clip such as a saved aerial intro (`:13179`, `:1056`) — and Studio
   creative "reel" (`studio/creative.ts:781-786`, `:822-828`).
2. Resumes/recoveries of jobs frozen on `legacy`/FAL profiles until their deadlines: resume variants
   (`20261015160252…sql:69`, `20261015165932…sql:56`, `20261015172920…sql:64`), one submit-refusal retry, one
   missing-result replacement, one drift-QC paid retry (`engine.ts:93` †).
3. Owner-QA grant, `legacy` profile only (`ai-video/index.ts:1108` †, `:1591` †; `owner-reel-qa.ts:66-77`).
4. Aerial, AI enhance, video erase, photo editing (router ON), Python pipeline — B(ii).
5. `resolveChain` ordering: `resolveRoute` first; empty → photo refuses (`_shared/providers/chain.ts:79-82`), every
   other task gets the FAL constant (`:83-84`). The Kie profile never calls `resolveChain` (`ai-video/index.ts:1109`
   †, `:1593` †).
6. Router-ON `video.reel_clip` chain: FAL Seedance (`0018_ai_routes.sql:324`), FAL Hailuo (`:331`, dropped by the
   1080p need and by `reel-framing.ts:14-26`); Kie Seedance (`:327-330`) is disabled and privacy-filtered
   (`router.ts:382`) even if an admin enables it.

### Voice

No FAL. `services/supabase/functions/ai-voice/index.ts:2`, `:22` (ElevenLabs `api.elevenlabs.io`); `tts.*` legacy
rows are ElevenLabs (`0018_ai_routes.sql:521-524`); Studio narration calls `ai-voice/tts`
(`studio/creative.ts:751-757`); a case-insensitive grep for `fal`/`FAL_`/`queue.fal` in `ai-voice/` finds nothing.

### Tests and docs (no runtime effect)

97 test files reference FAL (`path:first-hit`): FAL-specific suites `_shared/providers/fal_legacy_receipt_test.ts:2`,
`fal_missing_result_test.ts:2`, `fal_owner_motion_test.ts:2`, `fal_submission_audit_test.ts:9`,
`ai-video/fal-status-handler_test.ts:49`, `ai-video/erase_test.ts:26`, `ai-video/owner-reel-qa.test.ts:4`,
`property-video-worker/provider-diagnostic.test.ts:4`; router/provider `_shared/router.test.ts:61`,
`_shared/providers/providers_test.ts:10`; SQL `services/supabase/tests/property_video_steady_v2.sql:10`,
`property_video_quality_profile.sql:9`, `app_video_submission_receipts.sql:24`, `launch_blockers.sql:72`,
`app_video_cost_pg.py:100`; candidate Kie suites that also pin FAL/legacy behaviour (e.g. quotes pinned to base
`462e4c8`) `property-video-kie-quote.test.ts:3` †, `property_video_kie_profile.sql:61` †,
`property_video_kie_profile_pg.py:5` †; legal/consent
`tests/phase1/consent-disclosure.test.mjs:20`. Docs: 35 files under `docs/handoff`, plus `docs/AI-ROUTER-CONTRACT.md`,
`docs/AI-COST-MODEL.md`, `docs/PRICING-DATA.md` and others.

---

## Part C — Retention and delivery facts for the first approved Kie canary

### C1. Where the Kie result enters our storage, and when

1. Worker poll calls `GET /ai-video/status` (`engine.ts:36` †).
2. Kie `success` → first `resultUrls` entry must be https (`kie.ts:552` †, `isHttpsUrl` `:239` †); MIME guessed from
   the URL extension (`mimeFor` `:230-236` †: `.mp4`/`.m4v` or none → `video/mp4`, `.mov` → `video/quicktime`, image
   extensions → image types); `meta.expires_in_days: 14` (`:494` †).
3. Copy: `output.complete(state)` (`ai-video/index.ts:2289` †) → key `ai-router/{org}/completed-video/{digest}.{mp4|mov|webm}`
   (`ai-video/routed-output.ts:18-19`, `:38`; an image MIME is refused there, `:38-39`) → `persistResult` GET, redirects
   followed (`_shared/providers/common.ts:187` †, `:479` †), ≤ 100 MiB (`:35`, `:484-495` †), 120 s (`:28` †).
   Content-Type: for a Kie MP4, a missing, `application/octet-stream`, `binary/octet-stream` or case-variant
   `video/mp4` header is stored as `video/mp4`; any other upstream type is stored as sent (`common.ts:496-504` †, G2).
   Immutable PUT (`ai-video/index.ts:2260` †), journaled by `register_private_ai_output` (`:2256` †). A refused copy
   answers 503 (`:2288-2293` †) and the worker re-polls (`engine.ts:44-46` †).
4. Worker re-verifies our copy: R2 HEAD (`engine.ts:52` †) must show the same bytes, an ETag and Content-Type exactly
   `video/mp4` (`:59`). For Kie, an unchanged object (same bytes, an ETag) stored with another type or larger than
   64 MiB is terminal `source_video_unverifiable` after the paid-receipt check and before any byte is read
   (`:53-58`, `:61-63` †, G2); a missing or changed object keeps re-polling. Then MP4 probe of the presigned R2 object
   (`:64-65` †); `kieProperty4KFacts` (`:70` †; `property-video-kie.ts:134-141` †); canvas and 5 ± 0.1 s (`engine.ts:71` †);
   full read ≤ 64 MiB (`:72` †, bound `:23`; `property-video-jobs/runtime.ts:18`).
5. Compose writes `renders/{org}/{listing}/background/{job}/{lease}/master.mp4` (`engine.ts:107` †).

Timing: the copy happens on the first poll after Kie success, inside the job's 24 h deadline
(`20261016100000…sql:59` †); Kie keeps its file 14 days and text/metadata logs 2 months (Kie API guide §6, per the review
packet `:26`). Our copy has no TTL defined in the repo (no R2 lifecycle rule for `ai-router/` found) — it is removed by
listing/account privacy cleanup (`20261005220002_privacy_cleanup_inventory.sql:106`, `:159`, `:175`). Kie fetches the
source photo from a presigned GET valid 7200 s (`property-video-quality.ts:141` †, `:148` †); that is access expiry,
not deletion, and Kie's retention of fetched inputs is not published in the sources reviewed (review packet `:26`). No
Kie delete call exists in `kie.ts`; FAL gets a 24 h lifecycle request (`fal.ts:408`). After the 24 h deadline there is
no Kie delivery recovery (B(iii) row 7 is FAL-only), so a copy that never landed is unrecoverable through the product
even while Kie still holds the file.

### C2. Host allowlists vs the Kie result host

Kie result hosts seen in repo: `tempfile.aiquickdraw.com` (`_shared/providers/kie_property_profile_test.ts:166` †, `const RESULT`),
`cdn.kie.ai` (`_shared/providers/providers_test.ts:170-211`).

| Code | file:line | Allowed | Kie result host |
|---|---|---|---|
| Kie API submit/poll | `kie.ts:81-82` †; `requireHost` `common.ts:162-176` † | `api.kie.ai` | n/a |
| Kie result acceptance | `kie.ts:239-246` †, `:552` † | any https | accepted |
| Persist download | `common.ts:479` †, `fetchBounded` `:179-195` † (`fetch` at `:187`) | no allowlist; redirects followed | accepted (record any redirect chain) |
| Worker probe / read | `ai-video/mp4video.ts:761` (`redirect: "error"`); `runtime.ts:18` | our presigned R2 only | n/a |
| Studio import | `studio/creative.ts:171-176` | own R2/gateway, `fal.media`, `*.fal.media`, `v3.fal.media`, `storage.googleapis.com`, `tempfile.aiquickdraw.com` | `tempfile.aiquickdraw.com` yes; `cdn.kie.ai` no. Routed completions normally hand Studio our R2 URL (`ai-video/index.ts:2228-2231` †, signed at `:2261` †) |
| Erase output | `ai-video/erase.ts:156-160` | `fal.media`, `*.fal.media` | n/a |
| Legacy FAL status | `ai-video/index.ts:2740-2755` † | `queue.fal.run`, `*.fal.run` | n/a |
| Renderer downloads | `services/edge/property-video-render/container/renderer.py:119` (`hosts`) | configured hosts (our R2) | n/a |

### C3. Facts to record on the canary clip

| Fact | Required | Enforced at | If not met |
|---|---|---|---|
| Task state, credits | `success`; 335 credits = 67/s × 5 s → 167.5¢ | identity `_shared/property-video-kie-identity.json:12-15` †; poll meta `kie.ts` `done()` † | cost mismatch |
| Result URL, final host, redirects | https | `kie.ts:552` †; `common.ts:187` † | non-https → failed |
| Download Content-Type | `video/mp4` (a missing or generic header on a Kie MP4 is stored as `video/mp4`) | `common.ts:496-504` † (G2), then `engine.ts:58-59` † | any other stored type on an unchanged object: terminal `source_video_unverifiable` for Kie (`engine.ts:53-58`, `:63` †, G2); FAL/legacy keep the 503 re-poll loop |
| URL extension | `.mp4`/`.m4v` or none | `kie.ts:230-236` †; `routed-output.ts:19`, `:38-39` | `.mov` → stored as `video/quicktime`, then terminal at the type check; image extension → 503 at persistence, re-polled until the 24 h deadline (`ai-video/index.ts:2288-2293` †; `engine.ts:44-46` †) |
| Bytes | ≤ 64 MiB (67,108,864) | `engine.ts:23`, `:58`, `:72` †; also ≤ 100 MiB `common.ts:35` †, `routed-output.ts:26`; ≤ 128 MiB `compose.py:99` | 64-100 MiB on an unchanged object: terminal `source_video_unverifiable` for Kie before any byte is read (`engine.ts:58`, `:63` †, G2); > 100 MiB never persists (`common.ts:484-495` †), so the status call answers 503 and the worker re-polls until the deadline |
| Container | non-fragmented MP4; top level only `ftyp/free/skip/wide/moov/mdat`; `moov` ≤ 2 MiB; local data ref | `mp4video.ts:833-839`, `:18`, `:651-661` | 400 → `source_video_unverifiable` (`engine.ts:84` †) |
| Codec | H.264 `avc1`; profile 66/77/100, level ≤ 6.2; 8-bit 4:2:0 progressive; entry boxes only `avcC/pasp/colr/btrt/fiel/chrm` | `mp4video.ts:219-224`, `:250`, `:342`, `:350` | HEVC/AV1/10-bit → `source_video_unverifiable` |
| Frame rate | exactly 24/1 CFR (not 24000/1001), uniform `stts` | `property-video-kie.ts:139` †; `mp4video.ts:488-493`; `compose.py:52` | unverifiable / compose refusal |
| Frames | 120 or 121 | identity `:38-41` †; `compose.py:110` | unverifiable |
| Duration | 5 ± 0.1 s; renderer 4.97–5.08 s | `property-video-kie.ts:141` †; `engine.ts:71` †; `renderer.py:126-128`; `compose.py:103` | unverifiable / `source_quality_below_1080` |
| Dimensions | actual short side ≥2160 and ≥8,000,000px (owner/Codex decision implemented privately; see `KIE-MIGRATION-WORKING-SPEC.md` "Native-pixel policy"); separately covers1920×1080 or1080×1920 without upscale; ≤8192/side; ≤33,177,600px | identity `:42-43` †; `engine.ts:70-71` †; `compose.py:99-102`; `renderer.py:126` | refusal |
| Rotation | none | `compose.py:107-108` | compose refusal |
| Colour / HDR | SDR; transfer not PQ/HLG; record `colr` primaries/transfer/matrix/range — BT.709 expected | `compose.py:105-106`; output tagged bt709 without conversion `compose.py:118-121` | HDR refused; non-709 primaries shift colour silently |
| Audio | none expected (`sound:false`) — record if present | identity `:8` †; probe skips `soun` `mp4video.ts:663` | informational |
| Echo | `meta.substituted` absent; note `echo_unverified` | `kie.ts` `done()` † | informational |
| Our copy | `ai-router/{org}/completed-video/…mp4`; `private_ai_outputs.bytes` = R2 bytes; ETag present | `routed-output.ts:18-26`; `engine.ts:49-60` † | missing or changed object: 503, re-polled until the deadline |
| Timing | submit → success; persist ≤ 120 s; all inside 24 h, far inside 14 days | `common.ts:28` †; `20261016100000…sql:59` † | re-polled until the deadline |

No Kie operator diagnostic exists (`provider-diagnostic.ts:14` asserts FAL), so the canary readback is SQL/R2 only.

---

## Surprises and gaps (beyond the brief)

- S1. **Activation is global.** One selector key decides every new admission (`20261015073835…sql:15-21`); there is
  no per-org Kie switch, so after activation "the first approved canary" is whatever the next customer job is. A quiet
  window or the worker gate (`property-video-worker/index.ts:20` †) does not create scope (review packet `:17`).
  Migration `20261016110000` † now adds a server-enforced owner-only test grant (one actor, library, listing, exact
  sources, operation ids, create and cents ceilings, ≤ 72 h; `:21-33`, `:41-101`, `:156-185`, `:203-241`) that can
  admit Kie while the global selector stays unchanged. It is inactive: no grant row, the operator script
  `KIE-OWNER-TEST-GRANT.sql` named at `:32` is not in the worktree, and no function calls the dispatch authority yet.
- S2. **Direct reel clips bypass the selector** and stay on paid FAL Seedance (B(v) 1).
- S3. **Retention stalls (updated for G2).** Before G2, a stored type other than `video/mp4` and a clip over 64 MiB
  both looped on `poll_release` until the deadline. G2 makes both terminal `source_video_unverifiable` for Kie when the
  retained object is unchanged (`engine.ts:53-63` †), and stores a generic Kie MP4 type as `video/mp4`
  (`common.ts:496-504` †); FAL and legacy keep the loop. Still re-polled until the deadline for Kie: a result over
  100 MiB or with an image extension (refused at persistence, `ai-video/index.ts:2288-2293` †), transport errors, and a
  missing or changed retained object (`engine.ts:44-46`, `:59` †). Source-present, not executed (review packet `:7`,
  `:14`). The Kie runs recorded in the repo were phone-polled (`docs/handoff/CODEX-BUILD64-LIVE-QA-20261012.md:13`,
  `CODEX-BUILD65-LIVE-QA-20261012.md:17`); no Kie clip has passed this server gate.
- S4. **`{"enabled":false,"profile":"kie-…"}` is not "off"** — it is `legacy` FAL.
- S5. **Admin step switch** can flip the pinned Kie row outside the scripts (`admin/index.ts:2129-2159`).
- S6. **Privacy filter is router-ON only** for video tasks (`router.ts:330`).
- S7. **Native-pixel floor (current private implementation).** CanonicalJSON, TS mirror, SQL identity and
  reviewed Activation/Verify/OwnerGrant copies require actual short side≥2160 plus≥8,000,000pixels. The
  generic1080p delivery wire, native24fps/120–121frames/5±0.1seconds, source-auto aspect, crop honesty and
  no-upscale rules are unchanged. Actual helper/poller tests reject1080-high8MP panoramas and the old
  2032/1952-short-side synthetic geometries while accepting genuine landscape/portraitUHD. This is not
  an exact3840×2160 canvas rule:2160×3704 still passes geometry. The previous1080+8MP candidate and
  receipts remain preserved historical evidence. The2492×3324@24 input is FAL-derived geometry, now
  truthfully labeled; no accepted real Kie4K MP4 or motion/fidelity parity is established. Root's21:31:36Z
  read-only precheck found no deployed/admitted Kie identity, so this floor changes only the prospective
  private candidate. It never rewrites historical FAL or accepted job identities.
- S8. **Legal record does not match source**: `legal.ts` at base hashes to `a46dcd06…`; the latest notice records
  `f5d302d9…` (`docs/legal/RENDPROP-LEGAL-NOTICE-20261010.md:3`). A fresh notice is needed for Kie anyway.
- S9. **Admin health would mask a Kie outage** (`admin/index.ts:412` `optional: true`).
- S10. The Python pipeline uploads customer inputs to fal's public CDN storage (`fal_client.py:48-52`, `:73-90`); no
  retention for those objects is recorded anywhere in the repo.

---

## Reconciliation log (lane S4, 2026-10-16)

- Retention stalls: wrong stored type and > 64 MiB are now terminal for Kie after G2 (Part 0 gates, C1, C3, S3);
  remaining Kie re-poll cases listed.
- Native pixels (supersedes the earlier reconciliation): the owner/Codex2160 decision is implemented in this
  private candidate: spec = canonicalJSON = TS = SQL = reviewed operator copies =2160+8MP. Original1080
  snapshots/receipts remain historical; actual under2160 refusal and UHD positives are retained offline.
- Pinned row: stated as seeded OFF (Part 0).
- Rollback: restores from the durable activation record, never a default; remaining K10 gaps named (B(v)).
- "Real Kie" canary: 2492×3324 identified as FAL Kling 3 4K output; no Kie 4K MP4 in the repo (S7).
- Kie Terms §3: categorical "direct conflict" wording replaced by the review packet's neutral wording (B2, A2).
- Consent: B3, B4, A3, B(iii) row 16 and A7 now reflect migration `20261016110000` † (source only) and point to
  `KIE-CONSENT-CLIENT-PROPOSALS.md`; "owner accepts v1 in writing" removed (operator acceptance is not user
  permission); the A4 proposed admin text no longer treats an owner decision as customer permission.
- Line cites re-read for every `†` file and for `common.ts` (now `†`). Not re-verified by S4: the `legal.ts` base hash in
  S8 (no shell) and cites in files unchanged since F3.
