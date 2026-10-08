# AI model quality and recovery review — 8 October 2026 UTC

Quality is a requirement before changing suppliers, routing or included allowances. A cheaper model is useful only if it produces usable property media. Model names, route positions, successful HTTP responses, review checkboxes and passing code tests do not establish visual fidelity.

This review starts from `37b0c2dbeeddacefbdc294c747ae76a74e699304`, the source of internal TestFlight 1.0.4 (49). Follow-up recovery changes are isolated on `fix/ai-output-reliability-20261008`. Build 49 remains unchanged. No model, price, included 100/200/400 photo allowance, funding pool or global feature flag was changed by this work.

## What the application actually calls

A SELECT-only production snapshot at 01:01:45 UTC confirmed routing is enabled. Free/trial/Starter have cheapest route ordering; Pro/Team have curated ordering. Those settings are not the whole execution policy: `boundedPhotoChain` filters ordinary finite photo serving to the main `gemini-3.1-flash-image` and at most one eligible Kontext fallback. Lite/GPT cannot be selected merely because they are cheaper. Private internal QA can use the eligible operator chain. Unmasked Declutter currently has no enabled task-matched Kontext fallback.

The current Google request uses the source image, assembled property-preservation prompt, IMAGE output, one candidate, 1K resolution and a 4,096-token output ceiling. Same-room image references remain refused before dispatch; their cost and quality are not qualified. Capability labels such as `fidelity` and the curated `best` policy are metadata, not measured quality scores.

The last 30 days' success ledger includes 53 main Gemini photo results and three Lite results. This establishes recorded use, not reviewed fidelity or supplier invoice cost. The provider-health snapshot includes older FAL failures that predate the replacement FAL key saved on 7 October. They cannot establish that the new key or present service is failing. Latency EWMAs are not measured p95 timings.

## Actual quality evidence and its limits

The [existing photo evaluation](AI-PHOTO-QUALITY-EVALUATION-20261005.md) records beta problems including invented windows, moved appliances, blocked doorways, artifacts and inconsistent furnishings. Stronger prompts and staging review are safeguards; those cases remain unverified until their outputs are tested.

Eight retained September generations on one public demonstration room were reviewed against the unchanged original. They include an older Declutter result that retained a person and staging results with invented ceiling fixtures. These used older prompts and are regression examples, not the current build's failure rate. Repeated generations of one view do not establish consistency across views of a room.

The current photo handler accepts usable returned image bytes without a semantic source/output comparison. Native image decoding detects unreadable bytes but cannot detect moved appliances or invented openings. A generated image can therefore succeed technically and still be unsuitable for publishing.

The isolated follow-up also clarifies contradictory prompt instructions. Canned Declutter explicitly removes every person and reflection while preserving the prohibition on adding people or selecting them by personal traits; other edit guards are unchanged. Staging limits decorative lighting to movable floor/table lamps, prohibits changing ceiling/wall fixtures, and explicitly permits replacing movable furniture. These are unqualified prompt clarifications, not evidence that visual defects have been solved. The first paid screen remains frozen to production's original Build 49 prompts.

Video drift checks compare the source with three sampled frames and can hold an unchecked result. They do not inspect every frame or prove motion quality. The retained Bria smoke attempt produced no edited video because the supplier request was refused; direct Bria video output still needs a real, consented test. This photo review cannot close Bria, smooth-flight or physical capture acceptance.

## Recovery defects addressed separately

The review found clients that lost accepted-work context and could create a new request on retry. The follow-up patch retains the exact photo request key, body and source history before dispatch, scoped to account, workspace and property. Recovery explicitly reuses that request. Ambiguous outcomes retain their records; forgetting one requires confirmation and does not cancel or refund provider work.

Native photo recovery also preallocates the saved version ID, so interruption after a successful local save does not submit the same edit again. Aerial recovery retains accepted receipts after a local deadline or failed download. Unsupported generic claims that an error means “nothing was charged” are removed. These changes address request reliability; they do not qualify generated-media quality.

## Controlled output evaluation

The prepared first screen uses only Rendprop's existing public demonstration original: SHA-256 `411d36de24ec4e62b1197007e62eccfd6e3191a23aa0da0d19bd790aeb6b4dac`. It fixes the current prompts and Google settings for up to two Declutter and two Stage attempts, with no paid fallback, helper, automatic retry, new supplier or public publication. Each output must be reviewed before the next attempt. An ambiguous dispatch or critical fidelity defect stops the screen; failed and unusable outputs remain in the record.

Four unchanged primary attempts have a conservative maximum provider-token liability of $1.245184, rounded to $1.25. This uses the current model's maximum input-token limit and prices every permitted output token at the highest output rate. It is not a prediction of the invoice, and applicable tax/FX charges are separate. The earlier $290 launch-preparation ceiling is not approval to spend on this evaluation. Execution requires a specific expense and image-rights approval; preparation reads no provider credentials and sends no requests.

A four-attempt, one-room screen can identify obvious regressions, but cannot certify the model. Full qualification still requires the existing held-out corpus: ten rooms, three overlapping views, three staging repetitions, plus ten Declutter cases. Retain every output and failure, use independent reviewers, and treat any critical change to openings, walls, fixed appliances, visible defects or access as a failure. Record actual supplier usage and reconcile charges; application ledger estimates are insufficient.

The FAL Nano Banana 2 candidate advertises the same model family but has different thinking controls and an experimental generation limiter that may affect quality. It is not a qualified substitute. No paid comparison or lower serving reservation is justified until its maximum billable generation count and configuration are established. See [Google pricing](https://ai.google.dev/gemini-api/docs/pricing#gemini-3.1-flash-image), [FAL model pricing](https://fal.ai/models/fal-ai/nano-banana-2/edit) and [FAL request schema](https://fal.ai/models/fal-ai/nano-banana-2/edit/api).

## Verification status

Offline provider payload, fallback, actual photo-result handler, video drift, video-output journal and Bria adapter suites passed: **187 tests, zero failures**, with network permission disabled. This checks code behavior against controlled responses; it does not establish that live providers return good media.

The native recovery suite passed **127 checks and eight compiled negative controls**; existing lifecycle, queue, delivery and reel-failure suites passed another 582 checks. A full unsigned iOS Release build for the physical-device SDK succeeded. That establishes compilation, not camera or phone lifecycle acceptance.

Studio's full verification passed **473 unit tests**. Its final source also passed eight browser recovery checks, the seven existing photo-delivery browser checks, two compiled negative controls, typechecking, production build and bundle limits. The final built assets total 343,487 gzip bytes against the 350,000-byte limit. Browser fixtures use synthetic accounts and closed API boundaries, not real provider calls. A subsequent warning-copy correction and received-response storage-failure case were checked in the focused browser suite and final build; the earlier full verification is retained separately.

The prompt guard suite passed 17 tests, and the actual photo handler typechecked with remote imports denied. The clarified prompts have not been tested with new generated outputs. Production's baseline prompts remain separately frozen for the first screen.

The first hosted CI run passed 11 of 12 workflow jobs. Its offline audit job stopped because the older consent-batch fixture lacked the durable recovery service's storage/history interfaces; no consent runtime oracle executed in that failed case. The fixture now compiles actual photo history, capture storage and request contracts against disposable files. The complete Phase 1 Node glob passed 34 of 34 tests locally, including 69 photo consent assertions and three compiled controls that reject consent bypass, revoke/regrant revival and saving a late response under a changed account/workspace. App behavior was unchanged by this harness repair. Hosted successor CI remains to finish; the failed first run is retained.

Remaining native limitations are explicit: aerial submission whose response is lost before an accepted receipt is saved is not covered; existing aerial UserDefaults readback has no power-loss durability proof; older unbound aerial receipts are preserved for support and cannot be automatically adopted by another account. No general guarantee of duplicate-free work follows from these bounded fixes.

No new paid output was generated for this review. The four-case screen is prepared and independently reviewed, with expense approval and verified billing coverage still pending. Neither these source fixes nor model fidelity are deployed or accepted. Camera, Photos/Files exports and physical-device lifecycle acceptance remain phone tests.
