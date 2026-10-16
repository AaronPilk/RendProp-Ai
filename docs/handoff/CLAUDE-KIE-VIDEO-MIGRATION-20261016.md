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
