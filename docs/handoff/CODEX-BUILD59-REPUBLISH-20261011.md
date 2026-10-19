# Build 59 — republish retry

Claude's fix `6169527` was fast-forwarded into
`fix/build58-reel-integration-20261011`. The archive source is `d40c7f7`; use
`docs/releases/BUILD59-REPUBLISH-RETRY-20261011.json` for current results.

An old best-effort warning must not permanently veto Republish. The fix clears
it after the existing in-flight guard, before syncing the facts and gallery.
Fresh sync failures, unsent changes, conflicts, account/library changes and
a different returned slug still refuse success. No ordinary publish behavior
was changed.

The new simulator-only fixture seeds `lastError = "stale"`, supplies a clean
cloud listing with no local walkthrough, and exposes the actual model warning
and share URL. Its UI test taps the real Republish action and requires the
completion receipt, nil warning and unchanged URL. It does not fake the result
or use live credentials. The existing same-link/Recently deleted UI case is
run alongside it. Source gates include missing-clear, late-clear and
dropped-refusal negative controls. Shipping-boundary controls verify these
fixture switches remain absent from the physical app.

The first new-fixture run stopped before the action because the compiled app
lacked its new actor allowlist case; that case was aligned and the app rebuilt.
The first failed result is retained, not counted as a pass.

The repaired Mac worktree answers Git normally, with a clean starting index.
There are no prunable Mac paths. Two old sandbox `/sessions/...` worktree
entries are still marked prunable on this Mac; no prune/remove was performed.

The build-58 hosted native job completed successfully; 11 of 12 jobs passed.
Its audio export failure remains retained. The isolated retry was superseded
by the build-59 workflow; it is not counted as a completed retry. No audio
detector, RMS, pitch or duration oracle was changed. A later passing test is
not described as a code fix or allowed to erase the earlier result.

No backend, website, Studio, credential, pricing or funding change is needed
for this native correction. App Store 1.0.4 (57) remains on its manual review
hold; internal TestFlight 59 is the delivery target.

## Phone acceptance

On build 59, edit 855 Central Ave and Republish: verify the original URL updates.
Then disconnect, attempt Republish, reconnect and retry: the retry must run
rather than being blocked by the earlier warning. A genuine unsynced-change
error must still block success and explain the problem. Also check ZIP
downloads/disclosures/originals and restore a disposable deleted listing with
its original URL. Review a portrait Fly-through from a landscape photo for
cropping, motion and any changes to the property.

This record does not certify real-phone acceptance or generative quality.
Do not press manual Release on build 57 or attach 59 to its submission.

## Validation and delivery record

The five source tests pass, including the missing-clear, late-clear and
dropped-refusal controls. Both Release simulator UI cases pass (the stale
warning case and existing same-link/Recently deleted case). The signed
1.0.4 (59) archive verifies, its executable and dSYM UUIDs match, the IPA was
exported, and Xcode reports Upload succeeded. Apple availability is recorded
in the JSON receipt after processing, never inferred from upload alone.

CI on the exact archive commit `d40c7f7` is run `38172803786`; the new source
gate has passed. The earlier `3f102fe` run passed audio-resume and original
audio with the correctly rejected negative control, but failed later in
`cloud-editor-browser.mjs`: a planned four-second agent export had a 4.862
second video track and a 3.989 second audio track. This is a distinct failure,
not the previous narrated-cadence refusal. It is not called environment-only
or fixed without evidence. Its artifact is preserved in
`~/Rendprop AI/_bridge/build59-hosted-tour-retest/`. No oracle was weakened.
The unchanged full cloud-editor suite passed locally, 16 checks, with the same
agent export lasting 4.019833 seconds. That comparison is preserved in
`~/Rendprop AI/_bridge/build59-cloud-editor-local/`; it does not erase the hosted
failure. There are no additional ad-hoc retries until green.

This native fix is cleared for internal TestFlight acceptance testing when
Apple reports the build VALID and in the internal beta group. Public/manual
release remains uncleared pending phone acceptance and the export discrepancy.

Apple has now completed processing: build ID
`58c681f5-8464-4689-a690-49b08bc0de26`, VALID / IN_BETA_TESTING. The existing
internal Rendprop team group includes it (relationship readback), and testing
notes were written and read back. Non-exempt encryption is false. The original
App Store build 57 association remains unchanged, WAITING_FOR_REVIEW / MANUAL.

The exact-source CI run remains in progress at this handoff snapshot; eleven
jobs are green and none has failed yet. Its new republish gate passed. The
receipt has the per-job snapshot and the prior hosted export failure; it must
not be read as an all-green final run.

The exact-source tour-host job has now passed, including the full unchanged
audio/export checks. The earlier duration failure remains in the receipt;
this is a passing verification run, not an exporter code fix. Only the hosted
native audit remains in progress. Physical-phone acceptance is still pending.
