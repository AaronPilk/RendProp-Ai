# Claude assignment — Kie video migration, October 16, 2026

Codex is the integration and release lead. The owner has chosen Kie as the primary provider for new photo-to-video work. Implement a reviewable migration candidate while Codex continues the checklist, phone/UI acceptance and integration.

Use a NEW isolated branch `claude/kie-video-migration-20261016` and worktree `Worktrees/Active/claude-kie-video-migration`, based exactly on `462e4c85745243c515e49538d821fc762561049c`. Do not modify Codex's shared checkout or reuse the old motion branch.

Read `docs/handoff/OWNER-REQUEST-CHECKLIST-20261014.md` in Codex's current worktree and the existing Kie adapter/router/property-video contracts before editing. Your earlier motion handoff has already been integrated and hardened; do not remerge its commits or apply its old V3 patch.

## Your lane

1. Make Kie primary for NEW property-photo video requests through a new, immutable, versioned quality profile. Audit the existing Kie adapter, router/catalog, quote/admission, queued generation, polling/recovery, CPU composition, result delivery and publication chain. Keep the current high-quality/native-pixel requirements; support the existing Listing16:9 and Social9:16 destinations.
2. Freeze provider/model/tier/price/prompt/composition identity at admission. Use current official Kie documentation and record the priced basis, including fractional cents and retries. Keep historical FAL jobs/receipts/polls/results recoverable under their original identities. New-profile work must not silently fall back to a paid FAL request.
3. Preserve owned source/version bytes, upload/manual sequence, property/account scope, disclosure/fidelity checks, result retention in our storage, explicit publication and cancellation. A lost/ambiguous submit reply must not create duplicate paid tasks. Test cold-start recovery and substitutions using server-owned expectations and actual output facts rather than trusting echoed metadata.
4. Preserve native frame cadence using an explicit composition contract; the existing inactive `steady-v2-cfr24` work is available to inspect. Keep frozen legacy behavior unchanged. Temporal diagnostics remain provisional/inactive; do not claim they solve walking bob or apply the old stabilization patch.
5. Add meaningful offline adapter, handler and disposable-Postgres tests. Prove exact Kie selection/quote, replay and concurrency, definite refusal versus ambiguous acceptance, retry accounting, canceled/account-switched results, malformed/substituted output rejection, retained FAL recovery and no automatic publication. Include defect controls that fail when the relevant guard is removed.
6. Return an inventory of other remaining FAL uses. Photo editing/voice and other working features need their own verified migration; do not reroute them merely because a video route changed.

## Boundaries and handoff

Paid generation tests remain PAUSED. Do not run the old comparison matrix, generate/download clips, refresh credentials, call live provider services, change live configuration, apply database migrations, deploy, publish, upload to Apple or change retail prices. Keep heavy artifacts on the external drive and use existing offline dependencies.

Choose model/tier explicitly with evidence. Kie Kling4K is only about20% cheaper than FAL4K; cheaper Seedance/Pro candidates have NOT established equivalent motion, geometry, fidelity or delivery quality. Kie is the chosen provider, not proof that the model's walking-like motion is fixed.

Commit only your isolated candidate. Return commit hashes, exact changed files, test results/limitations, migration and rollout order, secret NAMES only, proposed read-only verification and rollback. Identify any genuine blocker precisely. Codex will review, integrate, deploy and run the separately approved small quality test. The checklist remains open, onboarding stays LAST, and no App Store submission is authorized.

## Codex review follow-up — October 16, late morning

This addendum is for the existing isolated candidate, not a second branch or permission to spend/deploy. Codex inspected only the mutable working specification and activation/rollback drafts; runtime filenames and uncommitted tests are not frozen proof. Finish and commit your own candidate, then return exact hashes. Do not integrate Codex's subsequent Studio cancellation/native toolbox commits into your lane.

Before handoff, address these concrete points:

1. **Frozen identity and historical recovery.** Seed the new route disabled and make the spec agree. Pin Kie profile/model/tier/wire parameters, motion/composition, source and aspect consistently. Demonstrate old accepted FAL work and new accepted Kie work still poll/recover under their original identity after selector changes or disabling admission. Never replay a paid POST or silently select FAL for new Kie work.
2. **Fractional cost.** The draft167.5-cent five-second attempt must remain exact through quote, hold, ledger, retry and settlement. Test odd counts, concurrent same-operation claims, lost settlement replies and recovery. Generation-only pricing must stay separate from QC, preparation, rendering, storage and delivery.
3. **Uncertain submission.** Persist an accepted task ID before later processing. Timeout, malformed/missing task ID,5xx and contradictory vendor replies must retain uncertainty/hold without another createTask. Test actual adapter/handler envelopes, including HTTP200 with a failing bodycode; only positively definite preacceptance refusal releases.
4. **Actual output authority.** Verify retained same-task owned bytes/hash, decoded pixels, duration and native24fps packet grid; echoed resolution/model fields are insufficient. Reject cross-task/source output, VFR or substituted output. Native4K profile admission is not proof of final native1080p delivery or smoothness.
5. **Quality remains a separate release gate.** Current worker quality checks three-frame architectural drift; optional temporal diagnostics are not requested/persisted as a durable per-shot gate. Do not claim a provider/cadence change fixes walking/bob. If your new profile promises temporal rejection, bind server-owned policy/version, retained clip hash, exact source/attempt/lease, measured facts and finite verdict; missing/failed/stale measurements HOLD. Finish/publication must independently enforce the new profile's complete receipts while leaving historical jobs unchanged. A frozen paid AI shot must not inherit the honest Original static fallback exemption. If this is outside your candidate, state it explicitly as NOT IMPLEMENTED rather than imply acceptance.
6. **Supported workload.** State tested source count, CPU/queue/lease and capability-expiry limits. A24-hour job deadline does not extend the existing20-minute CPU request watchdog or30-minute capabilities. Do not assert100-shot stabilized throughput without a measured supported path; preserve safe interruption/recovery with no new providerPOST.
7. **Activation and rollback need exact baseline checks.** Activation must compare the exact expected prior selector/route state and retain that prior state durably. Current draft only refusing “already Kie” is insufficient against another intervening configuration. Rollback must refuse missing recorded prior; remove the default-to-FAL branch. Require exact expected current Kie state before restoring, and preserve polling of already accepted tasks. Lost replies reconcile by GET only.
8. **Customer-media routing flag.** A literal operator acknowledgment in SQL is not evidence of a content-use decision. Preserve the existing conservative routing policy unless actual supported provider terms/configuration and owner direction settle it. Kie's public [privacy policy](https://kie.ai/privacy-policy) and [terms](https://kie.ai/terms-of-use) do not by themselves establish an API no-training guarantee. Do not infer either a guarantee or definite training from silence, and do not accept terms/contact support on the owner's behalf.

Return source/migration/operator-script hashes, each relevant executed test and deliberate-defect result, remaining FAL inventory, exact secrets NAMES, rollout order and limits. Existing [official Kie documentation](https://docs.kie.ai/) distinguishes a successful task creation from completed output and documents checking response-body codes; pin the exact model page/wire evidence too. Paid canaries remain paused pending a separately bounded plan after this review.

The detailed read-only gate receipt is on the connected drive at `/Volumes/Rendprop Files/Builds/Active/build86-kie-activation-independent-review/READONLY-ACTIVATION-GATES.json`, SHA256 `6e45be352827cf33c36799e48f92a21e1a977a3e67fbc0f8491c336dfdff54f3`. It records draft observations, not a completed runtime audit.

## Latest follow-up — October16,13:20EDT

Continue with `CLAUDE-KIE-CLOSEOUT-20261016.md`. It reconciles the owner-supplied activation audit against the newer mutable G draft and specifies the remaining closeout. The original scope and no-spend/no-live-action boundaries remain.

## Current private2160 harmonization — October16,2026

The owner/Codex native-source decision is now implemented in the separate offline harmonization copy:
short side≥2160 AND≥8,000,000pixels, with native24fps CFR,120/121frames and5±0.1seconds unchanged.
CanonicalJSON, TS mirror, SQL and reviewed operator identities agree. Source-auto aspect, faithful crop,
no upscale, generic1080p delivery and frozen historicalFAL recovery remain unchanged. This is not an exact
3840×2160 canvas rule;2160×3704 satisfies geometry alone.

Actual offline tests reject1080-high8MP panoramas and the earlier2032/1952-short-side synthetic inputs,
and accept genuine3840×2160/2160×3840 geometry. The golden is regenerated from actual181-migration
PostgreSQL output; the prior1080 candidate/snapshots/receipts remain preserved historical evidence.
Root's21:31:36Z read-only precheck found no deployed/admitted Kie identity. No accepted identity is rewritten.
No real Kie4K output has been accepted by this server path, and the floor does not prove smooth motion,
fidelity, final delivery or provider parity. Paid generation remains paused and production remains unactivated.

Exact private source and retained proof receipts are under
`/Volumes/Rendprop Files/Builds/Active/build87-kie-2160-harmonization/implementation`.
The earlier assignment and follow-ups above remain historical instructions; this section updates only their
native-pixel interpretation and does not authorize paid generation, deployment, legal publication or release.
