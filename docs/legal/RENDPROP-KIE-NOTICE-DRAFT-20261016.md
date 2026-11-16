# October 16 Kie processing notice — local integration draft

**Not published or activated.** This records the reviewable source package, not an agreement with a provider, a customer notice already delivered, an App Store update, or permission to run paid generation. Website 77 remains the previously verified live website until a separate deployment and readback. Kie remains off and paid generation remains paused.

The new optional photo-to-video processor needs its own explicit permission. Earlier Rendprop AI permission is not reused. Native and Studio use the same compiled title and body in `packages/client-contracts/property-video-processor-disclosure.json`; an exact published server contract and an affirmative choice must match before a new Kie request. Read, cancel and recovery of historical work must remain available without a new grant. Settings withdrawal stops future dispatch and cannot recall a provider's accepted work.

## Exact client copy

Revision: `rendprop-property-video-kie-20261016-r1`. Token: `property-video-jobs-v2`. Processor: `kie`. Profile: `kie-kling3-4k-steady-v1`.

**Allow Kie to make your video clips?**

Rendprop may send the property photos you select and camera-motion instructions to Kie (kie.ai). Kie’s terms allow submitted content to be used to operate and improve its services, and do not expressly rule out AI model training. Choose Allow only if you agree to that processing. Your saved originals stay unchanged.

Actions: **Allow and continue** / **Not now**. Privacy: https://rendprop.com/privacy. Provider terms: https://kie.ai/terms-of-use.

UTF-8 SHA-256 of title, two newlines and body: `11d500972be541f0c34f1ccd96f1a2d79d15c9827a4a010e934ca6b534f9ef9c`. The package's `draft_not_published` state is descriptive source metadata; it is not server activation authority.

## Source reconciliation

Checked October 16 against [Kie's terms](https://kie.ai/terms-of-use), effective August 1, 2025, and [Kie's API introduction](https://docs.kie.ai/1973359m0). The terms allow use for operating and improving the service; they do not expressly exclude model training. This does not establish that training occurs. The API documentation gives generated media for 14 days and request logs two months; fetched-input-photo retention is not specified. Temporary Rendprop link expiry does not prove provider deletion. No unsupported no-training or immediate-deletion assurance is added.

Terms section 4, Privacy section 3 and the Home/Support ownership answer now distinguish Rendprop's own no-marketing/no-training commitment from optional provider processing. Existing shared-workspace, deletion-cleanup and retention qualifications remain. Terms and Privacy carry the proposed October 16 date. The existing October 10 notice remains historical.

Actual `legal.ts` SHA-256: `a27721f605c6ca62391c033d23d5a6d55aa597830a94890bdc6ff85570218e9c`. Actual rendered Terms HTML: `d71041637d19c67dbba6624e2d8b92f5f9dc5ce69fbff87e7e57f71936488a9e`. Actual rendered Privacy HTML: `7c5dc9d1bbfea1b769046781b7541198d7a293557d5ccd3a351df4265151450f`. Rendered HTML and phone screenshots are retained in `/Volumes/Rendprop Files/Builds/Active/build88-kie-disclosure-proof/rendered`.

## Verified scope and remaining rollout

The actual emitted-page check passes 110 assertions. Against the previous source it fails 17 meaningful checks; removing the Kie row fails 7, and changing client copy without updating its digest fails 1. The website test suite, TypeScript check and 113 SEO checks pass locally. Twelve actual Chromium renders at 320/390/1440 px in light/dark have no horizontal overflow, retain provider table semantics and make no external requests. The 390 px Kie card was visually inspected.

Evidence: `/Volumes/Rendprop Files/Builds/Active/build88-kie-disclosure-proof/LEGAL-CAUSAL-RECEIPT.json` and `RENDERED-LEGAL-RECEIPT.json`. These do not prove customer consent, live publication, provider account settings, accepted paid output or legal compliance.

Before activation: integrate and test both clients and the private server candidate; verify the exact rendered public notice after deployment; reconcile App Privacy purposes against provider use; publish only the matching server disclosure revision. Preserve historical FAL recovery. The next normal internal build must include the tested client source; no App Store submission or release is authorized by this notice.
