# Rendprop Studio — phone and office release

The subsequent [app branding and creation workflow release](brand-parity-2026-09-14/README.md) is now live, with native feature cards, appearance modes and a phone-media reel picker. Its separate receipts document the remaining native/desktop boundaries.

This release extends the September 14 connected Studio into a working property,
creative, and business workspace. Its native companion is Rendprop 1.0.3 build 27.
The iPhone and browser use the same Supabase account, memberships, listings,
uploaded assets, published tours, lead records, brand, and entitlement.

The older `PARITY.md` and `packages/client-contracts/capabilities.json` remain a
historical inventory. They contain several future capabilities that are absent
from the native product too. They must not be read as a claim that every behavior
below has been exercised on real hardware or against a paid provider.

## Everyday workflow

1. Sign in with the same Apple account and choose the same workspace.
2. Create or edit property details on either device. Build 27 creates an identified
   user's cloud draft immediately; retries return the same listing.
3. Upload phone footage/photos using the existing app transfer workflow. Studio
   provides the same resumable upload transport, including larger multipart files.
4. Open the property in Studio to finish media, scripts, room chapters and tours.
   The phone refreshes its cloud listings and can import shared photos, video,
   scripts and narration when returning to the app.
5. Handle leads, brand and team work from the office. The shared backend remains
   authoritative for roles, quotas, plan access, and publication.

## Implemented surfaces

| Native capability | Studio experience and shared data |
| --- | --- |
| Property creation, facts, edit, sold/active, delete | Properties workspace; address lookup with reviewed facts; replay-safe create; existing listing routes |
| Upload, retry, cancel | Completed-asset receipts, full-file identity checks and durable upload journals; same single-use upload gateway; multipart to 2 GiB |
| Photos and originals | Shared gallery with captions, reorder and one property cover; original/altered distinction, original attachment, enhancement presets and immutable provenance |
| Scripts, shot plans, agent cutaways | Creative workspace; editable script, selected-photo shot list and phrase-timed cutaway plan with SRT/VTT timing import; account document save |
| Continue a phone Reel setup | Explicit restore of saved phone photos and settings; completed upload receipts preserve genuine photo IDs, and selected native narration retains its shared result |
| Edit and export a video | Trims, order, aspect and framing; 0.25–4× playback, photo motion, styled captions, cut/dissolve/whip transitions and saved narration mixed into MP4; agent photo cutaways preserve the recording's speech |
| AI voice and captions | Existing voice catalog/generation, preserved result history, fresh signed playback, captions export; native import reuses the result |
| Drone, aerial and motion clips | Existing provider routes behind a trusted result wrapper, recoverable status, completed asset ingestion and quality review |
| Property tours and chapters | Explicit render-and-publish action for the existing worker; free edited-MP4 publication; branded/MLS links; QR/download; room chapter editing |
| Spatial room jobs | Existing capability-driven review, privacy, retry/resume/cancel and publication controls; native capture remains required |
| Floor plans | Shared image attachment, view and download. Native RoomPlan capture and local USDZ/PDF files retain their device workflow; a shared image export is supported |
| Content planning | Account-backed plans, time zones/DST-safe reminders, import/export, conflict handling; social publishing is manual |
| Leads and team operations | Search/filter/status/export; role-aware roster, invitations, joining and removal; team activity |
| Brand, subscription, preferences | Shared agent card and notification preferences; existing entitlement; Apple subscription management stays in the iPhone app |
| Disclosure and account privacy | Provenance details/CSV and normal account-deletion workflow with cleanup status |
| Local draft recovery | Browser backup plus versioned cloud documents, uploaded original-source references, account/workspace isolation, offline save recovery and conflict warning |

The disabled gear catalog remains disabled. Internal provider administration and
brokerage governance that does not exist in the current native product are not
presented as customer features. Browser editing has explicit source, duration and
memory limits; original uploaded media is retained independently of an edit.

## Verification boundaries

Browser workflow suites exercise actual UI and exports with isolated service
fixtures. They deliberately send no invitations, customer messages or paid AI
requests. Backend tests cover scoped media, save revisions, upload/result recovery
and trusted publication inputs. A transient local PostgreSQL database exercises
the actual new SQL and role grants.

Production verification uses a disposable synthetic account for two independent
sessions, listing replay, document revisions, real image and MP4 uploads with signed
byte read-back, edited-output disclosure and the normal account cleanup route. No customer record is mutated
by that proof. The owner’s successful Apple sign-in has also been observed in the
live browser. A physical iPhone/desktop acceptance pass and live paid-provider
outputs are separate from fixture coverage.

Deployment and final test receipts are saved alongside this release report.
Build 27 must be installed before its new phone pull/create/import behavior can
be exercised. Raw local captures still need the normal upload action before
another device can access their bytes.

Successful new native narration is added to the shared voice history. Existing
older local narration is not retroactively reconstructed. History failure keeps
the already generated audio available on the phone; it does not initiate another
paid request or pretend the result was saved to the account.

The existing account-deletion retry endpoint is now scheduled every five minutes
with the project's existing Vault credential. The first production invocation
returned HTTP 200 and processed the three synthetic cleanup receipts. Storage
objects remain queued until their original upload write windows have drained;
the tests do not claim those bytes vanished immediately. Voice history keys are
included in the leased cleanup inventory before database cascades remove them,
while shared-workspace media is retained.

The auth fallback now points to production Studio, consistent with
[Supabase's redirect configuration](https://supabase.com/docs/guides/auth/redirect-urls),
so an expired OAuth session no longer returns to localhost. Both native and web
Apple audiences and existing redirect permissions were preserved.

Build 27 is processed and available to internal TestFlight testers as version
1.0.3. Its native media journals retain completed photo identities, and **Save
setup** shares the selected photos, editor settings and shared narration. That
setup is imported explicitly in Studio; local capture bytes still use Upload.

The final deployed integration passed 12 groups, including real gallery caption,
cover and ordering changes from two sessions, sold-to-active changes and a
provider-free voice reservation replay. The [evidence index](release-parity-2026-09-14/README.md)
links the final deployment manifests, test results and recorded limits.
