# Edge bundle source reconciliation — 2026-10-27

This source change starts at clean release commit `6c5ba17131731ea6326d3cee27ee12160f6bce94`. It reconciles the read-only live bundle triage at `/Volumes/Rendprop Files/Builds/Active/release-qa-integration-20261026/live-rollout-20261027/EDGE-BUNDLE-PARITY-TRIAGE-20261027T1043Z.md`. Work was done in the isolated `codex/edge-bundle-parity-20261027` worktree. No production function, database, migration, paid supplier, Apple code, or device state was changed.

## Merged source behavior

| Area | Reconciled behavior | Preserved release behavior |
| --- | --- | --- |
| `uploads` | An actor can complete only their exact owned v2 reservation when the ordinary presenter lookup hides an unapproved stored AI photo master. The route rechecks current listing write authority, reservation state/spec/key, and physical transfer. Renew, abort, and part URL routes do not use this fallback. | Source-only HTTP response changes and R2 publication helpers. |
| `renders` | Ordinary recorded/video source and poster routes refuse allocated aerial working and review objects. Photo motion v1/v2/opening manifests require saved source receipts, registered matching profiles, exact 24 fps, and an exact frame timeline. | The physical `photo_publications` visibility gate and registered FAL/Kie 24 fps master checks. |
| `ai-photo` and `ai-photo-v2` | Read-only saved `request_key` status checks the exact actor, selected library, organization, nullable listing, and case-preserved key without new work. Declutter assessment is tied to the supplied source SHA-256 and returns uncertain on malformed or low-confidence analysis; it never starts an image edit. The v2 alias forwards the same handler. | Zero-creative degraded trial fallback, newer R2 helpers, and the Kie aerial adapter. |
| `ai-video` | No entrypoint replacement was needed. Its current source code retains exact settled Kie receipts, terminal unretainable-result handling, registered prompt identity, and publication visibility. | Existing direct and legacy routes remain in source. |

The merge selected only Edge changes from local commits `f04e82d0`, `04d98d29`, and `28de5a65`; it did not cherry-pick their native app or CI changes. The live-only `renders/internal-media.ts`, `_shared/property-media-purpose.ts`, and `ai-photo/declutter-assessment.ts` modules are now source-controlled. There were no Git patch conflicts. The semantic conflict in `_shared/property-video.ts` was resolved by admitting both Photo motion and registered FAL/Kie profiles without weakening either profile's 24 fps and receipt checks.

## Bundle and import-closure review

Read-only `get_edge_function` comparisons after the source merge found the `uploads/index.ts`, `ai-photo/index.ts`, `ai-photo/photo-qc-store.ts`, `ai-photo/declutter-assessment.ts`, and `ai-photo-v2/index.ts` files byte-for-byte equal to their live counterparts. Of their complete live file sets, the remaining differences are newer source-only `http.ts`/`r2.ts` for uploads and `entitlements.ts`/`r2.ts`/`providers/kie.ts` for both photo aliases. The render helpers preserve the live purpose logic; `property-video.ts` and `renders/index.ts` intentionally differ because they combine that logic with HEAD publication and registered-master checks.

The changed imports close through `renders`, `ai-video`, `property-video-worker`, and `property-video-jobs`; `ai-photo-v2` closes through `ai-photo/index.ts`, and `photo-quality-worker`/`photo-quality-review` continue to import the additive photo QC store. `listings` closes through the preserved publication visibility module. Each deployed Edge function freezes its own imported files, so a later coordinated release must update every affected bundle rather than assuming one standalone deployment changes its siblings.

The observed live rollback references and JWT settings remain: `uploads` v61 / `77bbd0484e7ab9198591f60ec8aed3d8f29d5531f5180012c3ce118ceeee39ba` (`verify_jwt=false`), `renders` v61 / `eb54c15734e555d8d3031cb46e734b50dcbb4ba9b64de3fe774681dac26e64c8` (`true`), `ai-photo` v90 / `89e0a87f974c1effe007d2bc83d8dcf2fb7d542248a69f650bd8b595ec98b1e9` (`true`), `ai-photo-v2` v14 / `5f695a4c74b079f982d6bb36dfd44260fa11285290854386c1e39f1efe58712d` (`true`), and standalone `ai-video` v92 / `6c0fe35c2a66f939f5c2e939acd8fbbf34ea79f5dd66b4304a131c659e3cf7eb` (`true`).

## Offline verification

- `deno check --no-config --no-lock --node-modules-dir=auto` passed for `uploads`, `renders`, `ai-photo`, `ai-photo-v2`, `ai-video`, `property-video-worker`, `property-video-jobs`, `listings`, `photo-quality-worker`, and `photo-quality-review` entrypoints.
- Focused photo/upload contract tests passed: 108/108 for v2 alias, saved status, declutter, photo result handler, and owned hidden upload completion.
- The complete `tools/audit/uploads_*_test.ts` fixture set passed: 90/90.
- Render purpose, Photo motion, publication route, and registered Kie tests passed: 28/28.
- Publication visibility, property video, Kie attestation/guards, and paid unretainable Kie result tests passed: 48/48.
- The separate recorded-tour republish route fixture passed: 4/4.
- The trial-video attestation suite passed: 36/36 after its compiled mutation harness was updated to resolve the new local render helper and remove both independent authority checks in its negative control.
- Full recursive Edge function suite passed: **2,995 passed, 0 failed, 2 ignored** (`deno test --allow-all --node-modules-dir=auto --reporter=dot .` from `services/supabase/functions`).

These are offline fixture and typecheck results. They do not establish authenticated live responses, paid generation results, rollout, or device behavior. The local Deno runtime was 2.7.13; the repository's recorded CI version is 2.9.6.

## Remaining release gaps

Production still runs the old frozen bundles. A coordinated release and readback must cover at least `uploads`, `renders`, `ai-photo`, `ai-photo-v2`, and standalone `ai-video`, then inspect the imported `ai-video` copies in `property-video-worker` and `property-video-jobs`. Live `renders` and standalone `ai-video` still lack HEAD's physical photo-publication gate; live standalone `ai-video` still lacks HEAD's exact paid Kie handling. Live photo/video entitlements still advertise the older degraded trial fallback even though the charge path fails closed and live SQL enforces the introductory policy. Authenticated negative paths and actual device presentation remain unverified.

Migration history is a separate issue: live trial SQL is recorded as `20261026194816` while this checkout names the byte-identical migration `20261026165813`. Do not run a routine migration push until that version mapping is deliberately reconciled. This Edge source change needs no migration.

## Staged sibling audit and repair — 2026-10-27

A read-only comparison of the ten-function dry-run staged at `2026-10-27T11:03:19Z` found two live-only behaviors missing from its `property-video-worker` bundle. Live worker v32 accepts a missing `property_video_aerial_worker_read` row as an ordinary-video tick probe, whereas the staged source returned 503. Live worker v32 also validates the saved v1 or v2 Kie prompt identity at dispatch; the staged source used a v1-only pin. The SQL prompt-revision migration is live, the selector is v2, and a saved v2 job exists. Both omissions are repaired in source. The standalone `ai-video` bundle shares the Kie adapter, so it receives the same registry guard. No production function or database was changed.

The same read-only audit found no additional live-only behavior removed from `property-video-jobs` v34, `listings` v62, `photo-quality-worker` v12, or `photo-quality-review` v7. Listings' entrypoint is byte-identical to live and its only staged difference adds an unused optional visibility proof. The photo-quality entrypoints are byte-identical to live; their differing shared modules contain newer source guards and photo features. Staged files matched the dry-run receipt hashes for these sibling closures.

The repair tests exercise both sides of the boundary: an ordinary tick's null/empty/all-null aerial probe returns no aerial row, while required aerial RPC rows still reject absence with 503 and present rows keep identity validation; an exact v2 gentle push-in prompt makes one closed Kie request, while missing, mismatched, unknown, or changed revision/prompt combinations refuse before key read or HTTP. The existing v1 prompt matrix and Kie money-path controls still pass. Focused offline suites passed **48/48** (`--cached-only --deny-net`), the three affected entrypoints passed `deno check`, and the full recursive Edge suite passed **2,999 passed, 0 failed, 2 ignored** (`deno test --allow-all --node-modules-dir=auto --reporter=dot .`). `git diff --check` passed. These remain local code results; the dry-run receipt must be regenerated from the repaired commit before any video bundle rollout.
