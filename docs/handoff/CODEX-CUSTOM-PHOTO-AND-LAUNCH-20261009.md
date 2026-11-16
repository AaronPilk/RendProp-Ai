# Custom photo requests and owner alerts — 9 October 2026

**Final delivery update:** These changes are included in TestFlight 1.0.4 (54),
VALID and available to internal testers. The matching Team/backend/Studio/site
updates are live. The historical delivery instructions below are superseded by
`CODEX-TO-CLAUDE-FINAL-AUDIT-20261009.md`: **do not submit to Apple until Claude's
final GO and completed successful exact-source CI**. Build53 remains attached
to the unsubmitted draft until that separate preparation step.

Aaron requested these changes before final App Review submission. Build 53 is
already available in TestFlight but does not include this follow-up. Its signed
archive and upload records remain preserved. The new iOS source needs a new
App Store eligible build before the draft is submitted; release stays MANUAL.

## Photo editing

Ask for anything now prepares a request automatically, before a paid image
attempt. The free deterministic policy recognizes specific lighting, movable
clutter, sky, furniture, existing lawn and photographer-reflection edits.
Ambiguous wording asks a plain clarification instead of guessing. Requests to
repaint fixed features, remodel, remove permanent features or hide damage are
refused. These refusals happen before the funding operation, quota charge or
provider dispatch. The server independently validates old and new clients.

The accepted request is quoted as data within precise scope instructions.
Existing paint colors, garage-door and trim finishes, materials, layout and
actual condition are expressly locked across provider attempts and fallbacks.
This is an instruction to a generative model, not a guarantee of image fidelity.
Users must compare new custom outputs with their retained original before
using them on a listing, as a cover or in a download. Native review acknowledgments
are saved for the exact version; new descendants need a new review. Original,
decluttered and staged history is retained.

Native and Studio show clarification choices and preserve the original request.
The optional paid writing helper remains optional, handles the full 600-character
request, and cannot silently return a wider or different scope. An unusable
model-authored suggestion is an upstream failure, not permission to repaint.
No new mandatory paid LLM call or pricing change is introduced.

## Owner notifications

Provider, workspace spending-limit and cost-tracking alerts are owner/admin
operational notices. They now say **Admin**, name the affected feature, explain
the consequence in plain language and give the observation time. Existing
recipient authorization, privacy and deduplication stay enforced.

The recent missing-ledger warning came from our deleted ordinary QA account.
Before deletion its successful photo hold was correctly linked to its cost
record. Account deletion intentionally removed that record and cleared the
foreign-key reference while retaining the provider liability. The new
`20261009155553_ops_alert_live_workspace` migration excludes deleted workspaces
from that operational finding. Active workspaces with a genuinely missing cost
record still alert; no hold is refunded, rejected or rewritten to hide it.

## Provider and Apple state

Aaron saved a replacement FAL key. One real Seedance image-to-video request then
authenticated, completed, persisted and downloaded. Root inspected sampled
frames of the actual 5-second kitchen result. Its matched video ledger is a
catalog estimate, not a supplier invoice. This owner-sponsored test proves
provider access and output delivery, not ordinary customer purchase admission.
The result remains unpublished with drift checking pending.

All three annual subscriptions are unavailable; monthly pricing is unchanged.
Seven reviewed professional marketing graphics and three genuine monthly
paywall review images are uploaded and COMPLETE. Public 1.0.3 stays unchanged
until Apple approval and the separate manual release. John Apple is untouched.

## Verification and remaining delivery

Actual server handler tests cover free clarification/refusal, full requests,
fallback finish locks and guard-removal negative controls. Native runtime tests
cover exact-version review, publication/cover/export guards, retained originals
and independent staging review. A real rendered CustomEditSheet test covers
vague request → clarification → specific instruction, text-change invalidation
and garage repaint refusal, without a camera or paid generation. Studio batch
tests exercise refusal before upload and review before gallery attachment.
The SQL regression exercises actual account deletion and retains the liability.

Deploy only the new migration, ai-photo, ai-copy, notify and Studio after the
integrated tests pass. Do not redeploy unchanged handoff functions. Archive,
upload and verify the next signed iOS build from the exact integrated commit,
then replace build 53 in the unsubmitted 1.0.4 draft. Add the existing three
monthly subscription items and submit for review with MANUAL release.

Physical iPhone purchase cancellation, eligible trial, restore, camera capture
and workspace acceptance remain explicitly owner-deferred, not passed. Spatial
capture remains experimental. Do not claim every model or every input has been
quality-certified because this controlled FAL request succeeded.
