# Photographer client delivery — 1 October 2026

## Delivery status

The client workflow is deployed to the backend, public listing host and
[Studio](https://studio.rendprop.com/). Internal **TestFlight 1.0.3 (39)** is
available to the existing Rendprop team. Apple availability was read back at
**23:41:47 UTC**: `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING`, included in that
internal group. Exact English testing notes were read back at **23:42:56 UTC**.
No public App Store release, pricing, tester or group change was made.

Runtime source is `971deb085f25f8f8b4ed34e0097e1c62e59a83f0` on isolated branch
`feat/photographer-client-delivery-20261001`. All 12 jobs passed in
[CI run 36940470745](https://github.com/AaronPilk/RendProp-Ai/actions/runs/36940470745).
Its virtual merge tree exactly matches the runtime source tree.
[PR #16](https://github.com/AaronPilk/RendProp-Ai/pull/16) is a stacked draft
against `fix/room-tour-usability-20261001`; shared branches were not force-pushed.
The final documentation commit is separate from the archived/deployed source.
[The delivery receipt](../releases/TESTFLIGHT-39-20261001.json) binds source,
CI, production readbacks, signed archive, one upload and Apple availability.

## Product behavior

Real-estate onboarding asks **Agent** or **Photographer / videographer**.
Existing accounts can change **Settings → Real estate workflow** on iPhone,
or **Business → Account & plan** in Studio. This preference changes guidance,
not workspace permissions, plan access or published client routing.

Each listing has an independent **Listing contact**. Choose **My client**,
enter the realtor/business name, brokerage, public contact details and a
separate headshot, review the private inquiry recipient, and save before
publishing. The client needs no Rendprop account. **My account** explicitly
uses the photographer's own account card instead. Neither choice overwrites
another listing's client or the photographer's profile.

On iPhone, the contact editor is reachable during listing setup and from the
listing detail tools. In Studio, open **My homes → Create & publish / Details →
Listing contact**. Both publish entries verify the current contact server state
and save dirty edits before publishing. Unchanged/default **My account** is
verified by GET and may have no contact row. Unsaved, failed or conflicting
revisions must be resolved first.
Native drafts remain scoped to identity/workspace and survive interruption.
A successfully uploaded headshot is reused after an ambiguous contact-save
reply, including after reopening; selecting another photo or removing it
clears that pending asset association.

Client marketing pages show the selected client's public card and inquiry
form. **Hide Rendprop logos and app promotions** removes promotional service
branding, app banners and service partner advertisements. The rendprop.com
address, truthful privacy disclosure, property alteration labels and original
image links remain. Client pages never advertise the photographer's portfolio.
MLS `/u/` links still omit all contact cards and inquiry forms.

New inquiries remain in the photographer's inbox and queue an email to the
saved client recipient. Emails include the inquiry details and listing link;
no client login is required. **Settings → Leads** on iPhone and **Business →
Leads** in Studio show delivery history, current-recipient confirmation and
**Send to client / Resend to client**. Assigning a client does not email older
inquiries automatically; those become manually sendable.

**Email sent** means provider acceptance, not inbox placement. Each intention
freezes its message and recipient; historical attempts retain their old
recipient after contact changes. Pending sends cancel when routing changes,
is disabled or deleted, or listing/workspace/account deletion revokes access.
If an already dispatched message is subsequently accepted, history records
that original recipient truthfully; it cannot be recalled or requeued.
One deliberate request per inquiry per minute and 20 per person/workspace in
ten minutes bound manual forwarding. Lost replies retry the same UUID request
without duplicating mail. Provider retries preserve the frozen payload/key and
stop at 23 hours, before the provider's 24-hour idempotency window.

See the [workflow and API guide](../studio/photographer-client-delivery.md).

## Production readback

Only `20261001222809_photographer_client_delivery.sql` was newly applied.
Its reviewed source hash is
`8cba2047d6a46bdb57ff343dd1987eee2c95b42e9c986aa0ec9d610b1422b14c`.
The deployment tool allocated live ledger **20261001233128**, named
`photographer_client_delivery`. Source and live timestamps differ; **do not
apply this migration again under the source filename**.

Live metadata verification at **23:43:01 UTC** confirmed exact reviewed bodies,
language, security/search-path settings and client-denying grants for all
**19 functions**, all **six triggers**, nullable/NULL-default role preference,
notification category contract and both new RLS-enabled tables with zero
client policies. Neither table permits direct client reads/writes; service
SELECT is allowed, with writes through verified privileged transactions.
The before/after security advisor comparison found no new ERROR/WARN findings;
26 pre-existing WARN entries covering 47 distinct finding identities remain.
The two new tables appear in the existing deny-all RLS INFO group, whose table
count increases from 40 to 42. This is not an all-clear security claim.

| Function | Live version | Gateway JWT | Runtime files matched |
| --- | ---: | --- | ---: |
| me | 43 | on | 17 |
| listings | 37 | on | 10 |
| uploads | 45 | on | 10 |
| leads | 36 | off | 9 |
| notify | 11 | on | 9 |
| studio | 15 | on | 44 |
| tours | 44 | on | 11 |
| ai-video | 45 | on | 29 |

All eight selected function deployments were downloaded and source-hash
verified, from a 93-file unique staged closure. Type-only files omitted from
runtime bundles are explicitly accounted for. `leads` retains its public
submission route; private lead routes verify JWT identity and selected
workspace in the handler. Sixteen live missing/invalid-auth probes returned
401. The adopt edge handler was unchanged; its existing transaction RPC now
preserves explicit role preference during anonymous-account adoption.

Studio Worker **1cc57a97-e685-4c7c-aae1-641901a0087d** passed live byte readback
at **23:41:49 UTC**: all **31 served application files** match the connected
build, including **28 JS/CSS bundles** and three public root files. SPA fallback
and response security headers pass. Total gzip is **330,202 / 350,000 B**;
initial load **136,146 / 160,000 B**, Create **217,443 / 260,000 B**.
Authenticated login and crawler blocking are outside this receipt's checks.

Public Worker **4ad3ab1c-0709-442b-bbf9-6426a5fb0bb2** was read back as the
100% active deployment. The live marketing/MLS demos match the release's
renderer engine and CSS, retain opt-in video, and preserve MLS contact stripping.
Five marketing/legal/health routes return 200. This verifies served renderer
behavior and deployment metadata, not a full remote Worker source hash or a
new live client listing.

## Executed software verification

- **441 Studio unit tests**, typecheck, connected build/budgets and nine
  actual-component photographer browser checks; existing property, business,
  branding, finishing and media-kit browser suites also pass.
- **60 native client/role/sync checks**, **16 existing adoption checks** and one
  navigation-only onboarding/contact/settings UI test. No camera was started.
  Normal unsigned iPhone compilation and the signed lab archive pass.
- **123 targeted backend tests** and eight Deno entrypoint checks; **61 actual
  PostgreSQL assertions** on fresh schema plus 61 on replay. Overlapping database
  transactions exercise revision conflicts, distinct resend races and same-request
  idempotency. Recipient selection, quotas, deletion and late provider acceptance
  are tested against actual migration functions.
- Public Worker suites and **150 actual-browser assertions** pass with real
  encoded synthetic video, opt-in transfer and playback checks. Client renderer
  fixtures check separate identities, strict flags, disclosures and MLS stripping.
- The signed archive binds **203 tracked source inputs**, **136 compiled tracked
  Swift inputs** and one generated input. Signature, entitlements, arm64 UUID and
  surviving DerivedData/archive dSYM bytes were independently verified. Fifteen
  offline release-helper negative controls pass. The separate DerivedData app
  product is absent after archiving; no separate executable byte-match claim.

The first CI run, **36939229209 / 17f42b7**, failed because the new API inventory
and adoption harness compiler/scaffold inputs were not registered. Explicit
registrations and omission/fault controls fixed these in `a8e37a6`.
The next run, **36939746735 / a8e37a6**, failed a fixed-delay keyboard media-clock
assertion. A bounded wait for actual playback advancement preserves the original
stall failure and passed in the final 12-job run. The precise CI scheduling cause
was not proven. Earlier failed runs and signed source archives remain retained;
none of those archives was uploaded. Only the final source was uploaded, once.

## Owner acceptance still needed

Use two owner-controlled test listings with distinct client cards and headshots.
Verify phone → Studio and Studio → phone saved revisions, reopen after an
interrupted save, and ensure a conflicting/unsaved card cannot publish. Inspect
each marketing link and its MLS twin for correct identity and privacy.

With an address you control, submit one permitted inquiry and check the actual
intended inbox, photographer inbox and displayed status, then confirm one
deliberate resend. Check spam placement separately. Verification sent no real
inquiry email and did not mutate customer listings; mock provider transport
does not prove deliverability or real cross-device acceptance.

Build39 retains the previous room-tour and camera work. Physical camera quality
and room-tour comfort/seams still need the owner's phone. Room tours remain
local exports; 3D reconstruction and Presenter generation were not activated,
and no paid provider/GPU experiment was performed for this release.
