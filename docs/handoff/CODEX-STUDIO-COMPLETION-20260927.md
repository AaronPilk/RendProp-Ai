# Studio completion release — 27 September 2026

**Website, database, Studio API and bounded editing AI are live.** Exact-byte
website verification and a signed-in synthetic production smoke passed, including
cloud source upload, AI prompt enhancement, AI editing, reviewed speech captions
and a downloaded MP4. Full-page reload restored the saved QA project and its
conversation, and final CI passed all 12 jobs. This does not establish phone
capture, a fresh Apple sign-in, second-browser production restoration or real-room
reconstruction acceptance. Cross-browser restoration is verified in isolated
browser fixtures, not a second live production browser.

Website verified: `2026-09-27T14:14:56.867Z`. Editing AI activated approximately
`2026-09-27T14:15:00Z`; signed-in synthetic production checks followed.
Branch: `feat/studio-completion-20260924`.
Implementation commit: `fd9f007662e003eef5cb66bfad19eb3bbdf74ffc`.
Database regression fix: `41471a6d390d6adf0e356926a6a05c8ea9827b1f`.
Completed implementation CI: `685ca87`, run `36324844881`, **12/12 jobs passed**.
Deployed website source: `a1ac2096cbdd476c611ef7ae3699a9d8db7a5391`.
Follow-up test-only fix: `e5632ff`; CI run `36325429637` **passed all 12 jobs**.
The fix updates a negative-control fixture and does not change deployed runtime.
Earlier run `36325134604` is superseded for final acceptance.
[PR #8](https://github.com/AaronPilk/RendProp-Ai/pull/8) merged normally at
`2026-09-27T14:28:35Z` as `10e2b2238b827111432ae64ae9cb644f2b2932c9`.
The isolated local branch fast-forwarded to that merge commit; its runtime has no
difference from tested source `e5632ff222dca2ba12c4f28536b710b239289d27`.
No shared branch was force-pushed.

## What this release adds

- Named private projects, account-scoped original-media storage and verified
  restoration in another browser; conflict copies, recoverable local snapshots
  and upload recovery protect unsaved work.
- Music mixing, fades, speech/original-audio ducking, reviewed beat-cut proposals,
  speech captions and transcript-grounded passage selection. Timeline changes
  remain reviewable and undoable.
- Explicit local preparation of large source videos into bounded 720p editing
  copies. The original remains on the user's device.
- Optional model-backed editing and prompt enhancement, plus authorized speech
  analysis of property media or saved private project media.
- Private property music bound to exact review revisions, with copied-version
  permissions and withdrawal checks.
- Capture-quality and spatial-adapter fixes, plus complete native project file
  registration. These source changes do not establish acceptable 3D output.

Product behavior and current limits are documented in
[Projects and finishing](../studio/projects-and-finishing.md) and
[Editing intelligence activation](../studio/editing-intelligence-activation.md).
Cloud project media is limited to 128 MiB per file and 512 MiB per organization.
Archiving a project does not free its media storage; individual orphan-media
cleanup is not implemented. Account/workspace deletion has durable cleanup.

## Live layers at the checkpoint

| Layer | State | Evidence |
| --- | --- | --- |
| Database | Four new migrations applied; ledger normalized to the source versions | Exact full SQL guarded normalization; live schema and grants verified |
| `studio` edge function | **v12 ACTIVE**, `verify_jwt=true` | Fresh API download: all 44 runtime files match the branch byte-for-byte |
| Studio web | **Deployed and byte-verified** | 30/30 files, response policy and SPA fallback pass for `a1ac2096` |
| Model-backed editing and speech | **Activated and smoke-tested** | Flags `true / 8 / true / 3`; real enhancement, compound edit and Whisper transcription succeeded |
| iOS | Source and unsigned builds ready; **not delivered** | Two generic-device Release builds succeeded; no App Store Connect action |
| 3D reconstruction | **Not accepted; activation remains off** | No winning quality run and no new GPU experiment in this release |
| Presenter generation | **Disabled** | No enterprise no-training agreement; no Higgsfield key present |

The 44 verified function files exclude two staged modules erased as type-only
imports: `_shared/providers/types.ts` and `studio/context.ts`. They are recorded
as not present in the runtime, not claimed as downloaded matches. The function
ID is `48930645-bb3e-481a-a615-501f300e4dee` in project
`ymgqpbnjpztwjsyvceld`. No other function was redeployed during this readback.

Unauthenticated GET probes to `/studio/projects`, `/studio/project-media`,
`/studio/media-analysis` and `/studio/production-review-queue` each returned 401.
This confirms the anonymous boundary; it does not prove signed-in upload,
restoration or paid model behavior.

### Database source versions

1. `20260924232058_studio_named_projects.sql`
2. `20260924232510_studio_project_media.sql`
3. `20260924232803_studio_property_music.sql`
4. `20260924235553_studio_editing_intelligence_routes.sql`

The migration API originally assigned generated ledger timestamps. Recovery
normalized only these four rows, guarded by exact full recorded SQL and absent
destination versions. SQL was not reapplied. Do not use a broad
`db push --include-all` to repair unrelated historical ledger differences.

Fresh security-advisor responses contain **0 ERROR / 26 WARN / 1 INFO grouped
notices**, compared with **1 / 26 / 1** before this release. The
`ai_routes_expiring` view now uses invoker security, removing the prior ERROR.
These are grouped response counts; they must not be compared numerically with
older handoffs that counted expanded per-object findings. Existing warnings remain.

### Website deployment

Source `a1ac2096cbdd476c611ef7ae3699a9d8db7a5391` is live through Cloudflare
Worker version `4efe8d13-b897-4289-8cf1-f0fa14b386c5`, deployment
`f8b85623-1471-44cf-85b1-649d6e2077b6` at `2026-09-27T14:14:42.033598Z`.
The custom-domain verifier
passed at `2026-09-27T14:14:56.867Z`: **30/30 files**, exact bytes, required response
headers and SPA fallback. It returned no warnings. The connected release build
measured **135,649 B initial / 216,383 B Create / 318,219 B total gzip**, within
the respective 160,000 / 260,000 / 350,000-byte budgets.

The final UI copy changes also passed 21 targeted browser checks. The preceding
`685ca87` implementation passed all 12 jobs. After a test-only negative-control
fixture correction in `e5632ff`, final CI run `36325429637` **passed all 12 jobs**. The
website runtime remains `a1ac2096`; signed-in production checks are recorded below.

### Historical predeployment readback — superseded by the deployment above

The live page returned 200 and retained `no-store, no-transform`, `noindex`,
`nosniff`, `no-referrer` and the expected restrictive CSP. Its entry asset was
`/assets/index-Dlrqovad.js`; the current local build expected
`/assets/index-B4QgqbSl.js`. Exact application-byte verification therefore failed
at the index and did not approve this new website release.

- Live index SHA-256:
  `38175ba44ebc51e3ee742eb9a58c42aa5c7606eb34429c8097c8e6b2c220f805`
- Local index SHA-256 at checkpoint:
  `b21ca9b8d80ce6634d93f3ca1e0e8c3be4cb867eb1a198fa1d394ed28d929f81`

### Model activation and signed-in production smoke

After website deployment, these values were set successfully at approximately
14:15 UTC on 27 September:

```text
STUDIO_EDIT_PLANNER_ENABLED=true
STUDIO_EDIT_PLANNER_MAX_ESTIMATED_CENTS=8
STUDIO_MEDIA_ANALYSIS_ENABLED=true
STUDIO_MEDIA_ANALYSIS_MAX_ESTIMATED_CENTS=3
```

The earlier read-only receipt correctly records their preactivation absence.
Existing Anthropic/OpenAI provider credentials were used without printing their
values. Presenter and spatial activation were not changed.

The existing signed-in Chrome session restored the owner's workspace. A clearly
named synthetic QA project, `QA — synthetic Studio check — 2026-09-27`, used key
`project:4bd21cda-4c53-4c73-96d1-2ba11118a5b2`. Two synthetic originals of 79,358 and
4,589 bytes completed upload, each with one attempt; database readback confirmed
the expected source hashes. No camera or customer footage was used. This QA
project is intentionally retained for review and was not archived.

Observed production behavior:

- AI prompt enhancement returned an AI proposal preserving the exact quoted
  title. Review preceded acceptance, and acceptance only filled the composer.
- A compound AI edit made the video square, reordered clips and set the title.
  Undo/Redo restored the expected orders.
- Whisper analyzed a 15-second saved synthetic source and returned all 12
  expected words with timestamps spanning 0–5.8 seconds. Applying captions was
  disabled until the transcript was reviewed, then succeeded.
- An unsupported overhead-generation request returned a clear capability
  limitation and did not fabricate or apply an edit.
- A full-page reload and explicit selection of the QA project restored the source
  files, saved draft and conversation, including the unsupported response. The
  status read “Saved source files restored” and “Project and originals saved.”
  The two-clip sequence remained green first for 3 seconds, speech second for
  6 seconds, 9 seconds total, in 1:1 format. This was the existing browser.
- A real MP4 download contained H.264 video and AAC audio, 960×960 pixels,
  9.009533 seconds and 209,960 bytes. A decoded frame showed the expected title
  and caption. The initial green segment was silent (RMS 0); the later blue
  segment contained speech (RMS 0.127976).

Export SHA-256:
`33f74c66b84350a1ea06ad9e1dc21bfbaac159904a376b79079c47953895d992`.
The final ledger records **four successful, single-attempt calls**: three Sonnet
text calls at 8 cents each and one Whisper call at 0.15 cents. The total is
**24.15 cents ($0.2415), estimated**. Every row has `price_estimated=true`; this is
not a provider invoice or a claim of measured token billing.

These tests establish this synthetic saved-project path in the existing browser
session. They do not certify every property-source/agency path, a second browser,
a fresh Apple OAuth exchange, private camera footage or general AI output quality.

## Verification evidence available before final acceptance

The private-media regression runner passed against a fresh local PostgreSQL
database with all 74 migrations: 51 project/media SQL assertions, two music SQL
fixtures, two real concurrent-connection races and 31 typechecked Deno tests.
The quota race admitted exactly one competing upload at the 512 MiB boundary;
the project revision race preserved one winner and rejected the other with 409.
Storage transport was mocked; these are not production upload/deletion tests.

The independent speech extension review passed 21 existing and three additional
Deno cases, plus four frontend request-helper cases. Its receipt records a later
change to the Projects component; those earlier review results are not a final
UI acceptance receipt.

The broad database regression on `fd9f007` exposed an outdated invariant that
allowed route parameters only on the older three Astra writing seats. The
`41471a6` follow-up corrected the assertion for the two new bounded Studio routes.
Its fresh rerun passed all 74 migrations and the replay phase. Each 266-invariant
run had **265 passes plus the one explicitly owner-retained expected failure,
assertion 155**. That recorded Astra ceiling failure remains visible; it is not
reported as a passing invariant.

Spatial validation includes 160 passing Python tests, 161 main Swift assertions,
3,076 pose assertions, seven adversarial cases, eight JPEG cases and the existing
negative controls. Both `Rendprop` and `RendpropSpatialTestFlight` generic-device
Release builds passed with code signing disabled. These are compile and synthetic
checks, not simulator-camera or physical-phone acceptance.

Additional completed implementation checks:

- **414 Studio unit tests passed**, with TypeScript checking and the connected
  build/distribution checks.
- **189 Studio Deno tests passed; one PostgreSQL-dependent case ignored** by that
  offline suite. Database behavior is covered separately by the disposable
  PostgreSQL runs.
- **14 browser suites / 103 checks passed**, plus the deliberately broken-refresh
  negative control. The latest four-suite macOS rerun passed **47 checks**.
- GitHub CI run `36324844881` passed **12/12 jobs** for `685ca87`; final run
  `36325429637` also passed **12/12 jobs** for test-only follow-up `e5632ff`.

Synthetic browser/export runs exercise real encoded media. The separate live
signed-in checks above establish the tested production path; neither suite
certifies physical-camera quality or every agency workflow.

## Boundaries that remain after the website release

- App Store Connect and real-phone camera testing remain with the owner.
- Presenter generation remains disabled until the separate agreement and budget
  requirements are satisfied.
- Spatial reconstruction has no accepted winning profile. The $25 lifetime
  ceiling is unchanged: reconciled spend is $19.98118436, leaving approximately
  $5.0188. No new GPU rental or activation is part of this checkpoint.
- The signed-in synthetic model/export smoke above passed. No fresh Apple OAuth
  exchange, second-browser production restoration, real-phone flow or real-room
  reconstruction is claimed as tested by this release.

## Evidence locations

All local receipts are outside Git, under:
`/Users/pilksclaes/LocalRendpropAudits/studio-completion-20260924/`.

- `recovery-20260927/receipt.json`: fresh function inventory, source hashes,
  runtime readback and secret-name presence.
- `recovery-20260927/web-current.json`: current live page/assets, response policy
  and four unauthenticated API probes.
- `recovery-20260927/web-deployed.json`: final website 30-file byte/header
  verification and SPA fallback, passed at 14:14:56.867 UTC.
- `recovery-20260927/live-synthetic/export-receipt.json`: downloaded MP4 hash,
  duration, codecs, dimensions and measured silent/spoken audio segments.
- `recovery-20260927/live-synthetic/live-smoke-receipt.json`: live UI assertions,
  retained QA project, database source receipts and four estimated ledger entries.
- `recovery-20260927/final-ci.json`: final run `36325429637`, 12 successful jobs.
- `private-media/reusable-runner-final/receipt.json`: database/media isolation,
  recovery and concurrent-connection tests.
- `private-media/analysis-independent/receipt.json`: independent speech extension
  review, including its recorded source-change limitation.
- `private-media/general-database-fd9f007/summary.json`: pre-fix broad database
  regression result; explicitly not an acceptance pass.
- `spatial/source-receipt.json`, `spatial/product-build-receipt.json` and
  `spatial/testflight-build-receipt.json`: source hashes, offline checks and
  unsigned native build evidence.

## Final deployment and acceptance

Completed: website deployment and exact-byte readback; bounded model activation;
signed-in synthetic upload, enhancement, editing, reviewed transcription, export,
unsupported-request and reload checks; final four-call estimated cost accounting;
final 12/12 CI; and normal merge of PR #8 to main as
`10e2b2238b827111432ae64ae9cb644f2b2932c9`. The physical-phone, second-browser
production and disabled-generation boundaries above remain separate. Documentation
updates may follow in a separate commit without changing the deployed application.
