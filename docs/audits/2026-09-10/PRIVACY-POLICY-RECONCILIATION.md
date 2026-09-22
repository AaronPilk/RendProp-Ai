# Privacy Policy / Terms: factual reconciliation proposal

Audit date: 2026-09-10. **Proposal only; not approved legal text and not published.**

## Scope and source bases

This is a read-only comparison of the public-page **source** with implemented data paths, followed by proposed wording in this document only. No public URL, provider account, customer media, deletion endpoint, Apple service, or production configuration was accessed. There is no claim that the source equals the currently published response or that any conditional provider path ran for a customer.

- Worktree branch: `audit/privacy-policy-reconciliation-20260910`.
- Source base: `b9c6b4084ac1090a023866a79457bc690675eeb4`, the separately committed AI-consent-v2 correction. This audit does not amend it.
- Root comparison: `audit/full-regression-20260910` at `f0192fd96803792d67b1100377a83ae5086f824f` when inspected.
- Both revisions contain the same `services/edge/tour-host/src/legal.ts` blob: `48ebb652ffd5cbb399ff4c1c52ecc671b672471b`. Its shared effective-date string is still September 5, 2026 (`legal.ts:12`). That is a source value, not evidence of a publication date.
- The compared API, Coach, networking, and relevant studio source paths also had no differences between those two revisions. References use that source base, not floating live files. Short `legal.ts` references mean `services/edge/tour-host/src/legal.ts`; short `ai-*`, `coach/` and `_shared/` references are under `services/supabase/functions/`; `functions/` is under `services/supabase/`; short `Networking/`, `Screens/` and `PrivacyInfo.xcprivacy` references are under `apps/ios/Rendprop/`.
- The host imports the actual page functions at `services/edge/tour-host/src/index.ts:33` and serves their generated HTML at `:452`; these are not unused policy drafts. This still does not verify a deployment.
- Detailed AI payload evidence is also recorded in [AI-CONSENT-DISCLOSURE.md](AI-CONSENT-DISCLOSURE.md). The Cloudflare and Supabase skills informed source inspection; no platform operations were performed.

Classification: **code-backed mismatch** means a stated inventory or universal claim conflicts with a reachable implementation. **Manual gate** means the code cannot establish a contractual, operational, retention, or runtime-setting promise. Neither classification is a legal compliance opinion.

## 1. Provider and input inventory — code-backed mismatches

The Privacy Policy describes photos/frames but omits text inputs, whole-video analysis, OpenAI and ElevenLabs (`legal.ts:245–248,295–297`). Its Anthropic row lists only frames despite a chat path. It also omits a conditional Apple speech-recognition path. These are supported paths, not a claim that every request goes to every named provider.

| Source evidence | Consequence for the policy |
| --- | --- |
| `services/supabase/functions/ai-chapters/index.ts:518–562` signs the source-video URL, uploads the video, and supplies its file URI to Gemini. | “Frames” is not a sufficient inventory for video analysis; the provider can receive the selected video file. |
| `apps/ios/Rendprop/Coach/CoachModel.swift:144–147`; `services/supabase/functions/coach/index.ts:182–194,283–304`; `coach/prompt.ts:221–232` forward chat/history and context to Anthropic/OpenAI. `ai-copy/index.ts:360–389,799–832,893–917` also supports text/planning routes. | Include user text, chat history, project context, and writing/planning assistance; do not suggest that every input is media or fully anonymized. |
| `apps/ios/Rendprop/Screens/FlythroughDetailView.swift:4385–4392`; `Networking/LiveAPIClient.swift:1018–1040`; `services/supabase/functions/ai-video/index.ts:1596–1638,2101–2179,2225–2244` send source images and sampled generated-clip frames to Anthropic/OpenAI quality checks. | OpenAI is an image recipient as well as a text provider. Anthropic's image entry is valid and must not be replaced with a “text only” claim. |
| `services/supabase/migrations/0018_ai_routes.sql:298–317`; `functions/ai-photo/index.ts:631–671`; `functions/_shared/providers/openai.ts:313–329` include an OpenAI photo-edit route and multipart image/mask submission. | Add OpenAI photo editing, conditionally according to the selected route. Seed configuration is not proof of today's active database settings. |
| `apps/ios/Rendprop/Screens/FlythroughDetailView.swift:8359–8362,8467–8476,8514–8529`; `Networking/LiveAPIClient.swift:1080–1092`; `services/supabase/functions/ai-voice/index.ts:618–633,649–670` submit a script and selected voice to ElevenLabs. The script can contain the filled listing address. | Add ElevenLabs; disclose scripts and possible user-entered personal details. Text validation is not general PII removal. |
| `services/supabase/functions/_shared/providers/fal.ts:79–170,254–263`; `ai-video/index.ts:604–607,656–675` send media and prompts to fal.ai, including named video/upscaling model families. | Add prompts to the fal.ai data column. Distinguish the serving service from the model family: Seedance is not a Gemini feature. A model identifier does not establish all subprocessors or contractual relationships. |
| `apps/ios/Rendprop/Voice/SpeechTranscriber.swift:142–153,169–175`; actual caller `Screens/FlythroughDetailView.swift:8222`; existing `PrivacyInfo.xcprivacy:61–83`. | Caption transcription permits Apple server recognition when on-device recognition is unavailable or an on-device attempt fails. Actual transport was not measured; the privacy manifest already describes this conditional audio path. |

### Exact minimal proposed edits

For Privacy §1 “Your content,” retain the opening inventory and replace the AI-processing sentences (`legal.ts:246–248`) with:

> Depending on the feature you request, Rendprop sends selected photos or video, sampled frames, edit instructions, chat history and project context, scripts or transcript excerpts to the AI providers below. Media and text can contain personal information, including an address you include in a voiceover script. Review your inputs before requesting cloud processing.

Update only the affected provider-table cells; preserve the existing infrastructure rows except the additions specified below:

| Provider cell | Proposed “What it does” | Proposed “What it receives” |
| --- | --- | --- |
| Google Gemini | Photo editing, video analysis, and writing assistance | Selected photos or video, sampled frames, and text inputs for those features |
| fal.ai | AI image and video editing, generation, and upscaling, using the selected model | Photos, video, and prompts for those features, including exterior photos used for aerial intros |
| Anthropic | Chat and writing assistance, planning, and quality checks on AI output | User text, chat history and project context; source photos and frames from generated clips for quality checks |
| OpenAI — new row | Chat and writing assistance, planning, quality checks on AI output, and photo editing | User text, chat history and project context; source photos and generated-clip frames for quality checks; photos and edit inputs for photo editing |
| ElevenLabs — new row | Voiceover generation | Your voiceover script, including any address or personal details in it, and your selected voice |

Append to the existing Apple “What it does” cell: **“Speech recognition for captions.”** Append to “What it receives”:

> Recorded voiceover audio may be processed by Apple when on-device recognition is unavailable or a recognition attempt falls back to the server.

Append to the existing Supabase data cell (`legal.ts:291`):

> Inputs sent through Rendprop's API, including media and text supplied for AI processing.

This describes API transit, not a claim that every request body is permanently stored in the database. Do not add a universal “all processing is on-device,” “photos never reach OpenAI/Anthropic,” or “we strip all personal information” qualification.

## 2. Lead/CRM wording — code-backed mismatches

Privacy §1 says the “same details,” including message/preferred date, go to CRM (`legal.ts:253–257`). The implemented CRM payload contains name, email, phone, tags, and an optional **listing address in its source label**, not the complete lead `extra` data. CRM sync is conditional on configured credentials/location (`services/supabase/functions/leads/index.ts:47–81,273–301`). Configuration and successful delivery were not checked.

Privacy §3 then says no provider except CRM receives lead details (`legal.ts:299–302`), contradicting its own Supabase/API/database row (`:291`) and the actual lead insert (`services/supabase/functions/leads/index.ts:273–287`). The CRM also receives tour/workspace/listing metadata, not “only lead-form submissions.”

Replace the CRM-transfer sentence in Privacy §1 with:

> When CRM sync is configured, we send GoHighLevel / LeadConnector the submitter's name, email and phone, plus tour, workspace and listing tags and the listing address used in the contact's source label. The message or preferred date remains part of the lead details stored for your Leads inbox.

Replace only the GoHighLevel data cell (`legal.ts:294`) with:

> The name, phone and email submitted through a tour's lead form; tour, workspace and listing tags; and the listing address used in the contact's source label.

Replace the operational inventory paragraph at `legal.ts:299–302` with this proposed factual wording, **subject to the promise-review gate in §5 below**:

> Rendprop sends inputs for the feature you request. Some AI features use more than one provider, including for fallback or quality checks. Lead submissions are handled by our backend and may also be synced to the CRM as described above. Rendprop does not send these inputs for advertising.

The final sentence retains the existing statement about **Rendprop's purpose**; it does not establish what every provider contract permits. This audit neither verifies nor reverses that business-policy commitment. Do not silently remove or weaken a contractual assurance without owner/legal approval.

## 3. Guest sessions — code-backed omissions

Terms §2 presents Apple sign-in as universal (`legal.ts:123`); Privacy §1 and its summary account only for Apple (`:242–244,371`). The app can establish an anonymous session through the authentication signup endpoint without Apple sign-in (`apps/ios/Rendprop/Auth/AuthStore.swift:668–722`). “Guest” is not a claim of no identifier, no network request, or no stored account data.

Replace only the first Terms §2 sentence with:

> You can use Rendprop without signing in with Apple. The app creates a guest session for its online features; signing in with Apple is optional.

Replace Privacy §1's “Account details” item with:

> Account and session details — Rendprop creates a guest session for online features. If you choose Sign in with Apple, Apple provides the name and email or private-relay address you choose to share. Apple-linked sign-in and account deletion can exchange tokens with Apple.

In the Privacy summary (`legal.ts:371`), replace **“your account details (via Apple)”** with **“your account and session details, including details from Apple if you choose to sign in.”** Leave the unrelated age, account-responsibility, and business-authority terms for legal review, not this factual correction.

## 4. Deletion scope versus completion promises

**Code-backed mismatch:** the Terms summary's “everything in it” and §7's unqualified shared-link statement (`legal.ts:191–196,228–229`) omit retained shared-workspace content. Deletion classifies solo/shared organizations, collects cleanup targets for solo organizations, and transfers ownership/removes membership for shared organizations (`services/supabase/functions/me/index.ts:1283–1305,1402–1445`). It does not unpublish all links belonging to every organization the departing user shared.

**Manual gate:** immediate completion, retries “until it completes,” and “normally within hours” are not established by this source review. `services/supabase/functions/me/index.ts:1484–1512` distinguishes auth deletion failure, success, and pending external cleanup; `:1516–1518` says to wire the sweeper to a schedule. That comment is neither proof that scheduling is absent nor proof it is currently healthy. No deletion was attempted.

Proposed replacement for the operational part of Terms §7, retaining the separate suspension clause:

> You can request account deletion in Settings → Delete account. Deletion covers your account and the content of workspaces only you belong to. Content in workspaces shared with other members can remain for those members. The app reports request failures and whether further cleanup is pending. Associated storage, video-delivery and CRM cleanup may finish separately.

Replace the Terms summary's final deletion clause (`legal.ts:228–229`) with:

> you can request account deletion in the app; shared-workspace content and pending cleanup are explained in section 7.

Privacy §5 already limits organization deletion to solo organizations (`legal.ts:343–344`); preserve that useful qualification. Append after that sentence:

> Content in shared workspaces can remain for other members. Account deletion and completion of associated cleanup are separate statuses; the app indicates when cleanup is pending.

Replace the Privacy summary's **“deleting your account removes your data”** (`legal.ts:377–378`) with **“account deletion and its shared-workspace and cleanup limits are explained in section 5.”** These are scope corrections, not approval of a new retention period or permission to retain content indefinitely.

Related app-copy debt remains outside this document-only unit: `apps/ios/Rendprop/Screens/SettingsView.swift:464–466` still promises all tour links are down and automatic background completion. Its actual request handling distinguishes failure and pending cleanup (`:735–776,792–824`). Reconcile that copy when the owner approves the deletion wording; do not treat this proposed website change as fixing the app.

## 5. Owner/legal/runtime decisions — do not invent replacements

| Existing claim | What source establishes / does not establish | Evidence needed before approving public wording |
| --- | --- | --- |
| Providers process data “solely” for Rendprop's function (`legal.ts:287–288`); AI inputs are used “only” to produce a result (`:299–300`). | We can trace submitted payloads, not vendors' downstream use, subprocessors, retention, training, or contractual purpose limits. | Owner-approved current provider contracts/DPAs, product-tier settings and subprocessor inventory. Do not substitute “zero retention” or “no training” from memory. |
| Rendprop never uses content for marketing/training without written consent (Terms `:145–146,226`; Privacy `:283–284`). | This is a business-policy/legal commitment. No contradicting training/marketing implementation was demonstrated by this bounded audit; absence of such a path is not an independent audit of all use. Router `trains_by_default` filtering is metadata, not provider-contract proof (`services/supabase/functions/_shared/router.ts:345–361`). | Owner confirmation of Rendprop's actual policy and provider obligations/settings. Clarify which entity is promising what; do not automatically broaden “Rendprop” into “every provider.” |
| Automatically retried deletion, normally within hours; records disappear with deletion (`legal.ts:191–196,342–346`). | Cleanup queues and a sweeper exist, with partial failures/pending status. This review did not verify current scheduling, retry health, external deletion or completion time. | Current scheduler configuration and monitored completion evidence from an owner-authorized operational check; no destructive test against customer records. |
| Analytics deleted after 180 days (`legal.ts:336,345`). | `services/supabase/migrations/0022_app_events_purge_schedule.sql:20–27,43–68` schedules a 180-day purge only if the extension/setup succeeds; it explicitly preserves a manual gate otherwise. A migration is not current job-execution evidence. | Confirm installed scheduling and recent successful job history before certifying the promise. Do not run a purge for this audit. |
| Backups/logs age out on a “short, fixed schedule”; logs are “short-lived” (`legal.ts:270–271,345–346`). | No comprehensive backup, log, or downstream-provider retention inventory was established. The fal.ai lifecycle preference (`_shared/providers/fal.ts:35–37,254–263`) concerns output-object expiry and does not establish all input/log/back-up retention. | Written inventory of systems, actual retention settings, backup expiry and exceptions, reviewed by owner/legal. Do not invent a number or infer one universal period from the fal header. |
| Content ownership and license ends on deletion (Terms `:141–146`). | These are legal permissions, not a technical guarantee that every copy disappears synchronously. | Legal review if qualifying license scope/end is required; this audit proposes no new license rights. |
| Policy-change notice and effective date (`legal.ts:12,212–215,359–361`). | Source has a shared date and a notice promise. Consent v2 changes app disclosure; it does not publish a policy or prove that users received a policy-change notice. | Owner/legal approval of wording, effective date and notice mechanism, followed by a separately authorized publishing/verification step. |

Routes can change through database configuration and flags (`services/supabase/functions/_shared/router.ts:258–308`) and may invoke a fallback chain (`_shared/providers/chain.ts:57–65,79–92`). This inventory covers implemented paths and seed evidence, not a frozen runtime provider allowlist. Disabled Kie/Higgsfield seeds (`services/supabase/migrations/0018_ai_routes.sql:327–330,342–365`) are **not** evidence of current receipt or authorization to enable them. Any future activation needs disclosure/contract review first.

## Verification and handoff

Completed here: full legal-source reading; comparison of the pinned legal blob and supporting source paths; inspection of actual request construction, guest-session code, deletion branches and scheduler migration; and documentation-only checks. No production HTML/Terms, app code, consent acceptance flow, provider configuration, date, or deployment was changed. No claim of a full privacy, security or accessibility audit; payment terms, statutory rights and jurisdiction-specific duties were not evaluated.

The offline Node reference check passed with 51 explicit references across 24 source files, zero missing/out-of-range references, matching pinned legal blobs, and valid scope/base/whitespace checks (exit 0). It initially caught two undeclared shortened paths; those references were expanded before the passing run. This is a reference-integrity check, not execution of the described data paths or validation of the proposed legal meaning.

Before a separately authorized publication: approve §1–4 factual edits and §5 decisions; reconcile app/deletion copy and platform privacy declarations; add offline tests against actual `termsPage()` / `privacyPage()` output for the approved statements and omissions; check both pages' rendered layout, internal links and contrast; then verify the published responses and effective-date/notice handling. These future checks have **not** passed in this unit. Publishing is not authorized by this proposal.
