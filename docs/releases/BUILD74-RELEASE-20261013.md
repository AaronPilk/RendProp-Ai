# Rendprop 1.0.4 (74) — submitted for review

Build **74** was submitted once on **2026-10-14 03:45 UTC**. Apple readback: review submission **WAITING_FOR_REVIEW**, attached version **1.0.4 (74)**, release type **AFTER_APPROVAL**. Distribution is automatic after Apple approves; public release is not yet claimed. All seven requested writes and metadata readback succeeded. Existing review contact/account fields and the six other screenshots were preserved. John Apple was not modified.

## Video and phone acceptance

The branded introduction is **55.366667 seconds**, 1080 × 1920 H264/AAC, with Willow narration at the requested20% faster pace. Real phone screens show the sequence: Apple/plan/trial overview, address/details, photos and steady walkthrough, AI edits and review/selection, buyer contact, publishing/gallery/link, organized export, reels/voice/background completion and Leads/Ask AI. It retains the approved visual style. Aerial, Measurements and 3D remain Coming soon.

On the actual mirrored iPhone, TestFlight **74** was installed. Get started opened the New Home address/unit form; media entry required an address. Settings replay opened the55-second guide, which progressed through its final scene. All three optional questions displayed correct feedback; Done returned to signed-in Settings. Eleven captures bind this scoped acceptance. Ordinary retail purchases and subjective audio listening are not claimed by the owner's test.

## Artifact binding

Signed/uploaded source: `c60e4c20f39cfdef3ab0609677100d931886bffd`. One normal App Store-eligible archive/export/upload. IPA SHA256: `09f690dd7d31fe12b65385fbb16e7d65aad8e685879f0e3e715990b1909228f8`. Bundled video SHA256: `8ccd867b223e36b4f42348fac8fe3e75b288850dbc463fcfbab0422ed5d6dfb1`. Full decode,17 encoded-frame review, duration boundary tests and exact archive/export media bytes passed.

TestFlight/Apple build ID: `0d6dfeeb-9ecb-49bf-a1bc-33e8d9115901`. Review submission: `cdd8edb2-1b4b-4a46-a06e-08376f9b9d1a`. The app source, resource and project trees (179entries) match the later test-only commit `053f152145a4df12b3818533f26d986b97e3737b`; no second archive was invented.

## CI evidence and explicit release decision

The archive-commit [run38501706161](https://github.com/AaronPilk/RendProp-Ai/actions/runs/38501706161) remains failed13/2. Its synthetic AVAssetWriter input timed out before production decoding; underlying writer status/error was not logged and remains unresolved. A test-only change pins the originally generated known-good MP4 with SHA/provenance, preserving16 actual decoder assertions and both compiled controls. The new hosted decoder gate passed.

The new [run38504902086](https://github.com/AaronPilk/RendProp-Ai/actions/runs/38504902086) is **not claimed green or complete at submission**. Current UIKit exports and native steps52–67 passed, including decoder, source motion, clean reel framing, whole listing ZIP, account/context and form checks. The remaining68–76 repeat checks are still running in the snapshot. All actual Swift and unchanged native test runners/fixtures match the fully passed [a6 checkpoint](https://github.com/AaronPilk/RendProp-Ai/actions/runs/38495763306),15/15 jobs. Root explicitly reuses that complete result only for source-identical unchanged checks; the new movie/version assets have separate current proofs.

The current Studio gate failed because the test expected a successor-preparation deadline message but the unchanged timing guard won first: two measured drift readings122.229/122.929ms exceeded66.667ms, refused any file, released both decoded resources and stopped all tracks. Fixed narrated/original MP4 positive exports passed first. The audio suite was not reached in this run; the entire Studio tree (including fixtures/runners/package pins) matches the prior green checkpoint. No safety threshold was relaxed, no loop-until-green retry or Studio redeployment was performed. This failure and its clock readings are preserved as an explicit classified release exception.

The companion JSON binds the physical, archive, decode, source-equivalence, prior CI, classified refusal, root release decision and one actual Apple submission journals. Source-identical prior proofs and current scoped passes are distinguished from incomplete fresh repeats.
