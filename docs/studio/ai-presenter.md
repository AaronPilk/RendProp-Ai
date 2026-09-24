# AI Presenter

AI Presenter lets an agency prepare a short performance using an agent's approved
likeness, request a priced generation, and import the result only after the
represented person reviews it. The implementation is complete for offline
validation. **Production activation and real-person output quality are not yet
verified.** New runtime settings default to disabled, with no spending allowance.

## Using the workflow

1. Open **AI Presenter** on Studio Home or in Creative Studio. Choose the property
   with the original uploaded media.
2. The represented agent creates their own profile with one to eight clear JPEG,
   PNG or WebP reference photos and approves likeness use. This is an account
   attestation, not biometric identity verification. An administrator cannot
   consent for somebody else. Profiles can be reused across properties within
   the same workspace; original reference files remain bound to their property.
3. An editor selects that profile and a 4–30 second source performance, then saves
   the title, recording guide, purpose and resolution. The represented person
   reviews and approves the exact saved revision and source-performance rights.
4. Once generation is activated, request a quote. Studio shows the provider's
   estimate separately from the maximum authorized amount. Confirm that maximum
   to submit. The workspace reserves the full maximum against its approved budget.
5. The job persists across browser reloads. A lost response recovers the existing
   request; it does not silently buy another generation. If no submission was
   accepted, an authoritative server closure allows a fresh quote safely.
6. The generated video stays private to the represented agent for review. They
   check appearance, spoken content/audio, and property/background accuracy, then
   accept those exact bytes or reject them. Input approval does not approve an
   unseen result.
7. Import accepted footage into the property library, then use the existing reel
   editor, cutaways, captions, production review and export workflows. The native
   upload quota and transport are reused. AI disclosure follows the accepted clip
   into edits.

**Edit the original performance video** remains available without generation.
That handoff uses the original uploaded video and its recorded audio. It does not
create a digital person. Applying it explicitly replaces the current sequence.

The script is a recording guide. Editing its text does not change the source
speech. The selected motion-transfer API has no voice identity parameter. This
feature does not supply voice cloning or promise generated audio fidelity. The
first live trial must check audio, lip timing and likeness as well as pixels.

## Media and approval boundaries

The backend downloads and hashes the immutable originals before estimates and
again before dispatch. It measures the actual MP4 timeline instead of trusting
client-uploaded duration. Source video is capped at 48 MiB; each reference photo
at 12 MiB. HEIC references need conversion before this workflow. Inputs are not
silently trimmed. Documented output tiers are 480p and 720p; native 1080p/4K is not
promised.

A fixed versioned instruction asks the model to replace only the performer and
preserve property details. The quote and job bind that instruction along with
source bytes, reference bytes, profile/draft revisions, price version and runtime
revision. This instruction is not proof that the model preserves geometry or
signage; the human output review remains necessary.

Changing inputs, revoking consent, removing required members, or deleting the
source identity/property invalidates access and queues owned object cleanup.
Short private preview URLs are checked before and after signing. A previously
issued link can remain usable until expiry; downloaded or externally published
copies cannot be recalled. Provider-side retention/deletion depends on the actual
contract, not Rendprop's local cleanup.

Shared writes use revision checks. Unsaved navigation, account/workspace changes,
late responses and pending cost submissions are explicitly fenced. Direct browser
access to the new tables and privileged RPCs is denied.

## Cost and durable execution

See [the RPC contract](presenter-execution-rpc.md) for exact fields and transitions.
A quote is valid for at most five minutes. Creation reserves the full configured
per-job maximum atomically; holds plus confirmed charges consume the workspace's
lifetime Presenter allocation. There is no invented per-second rate or automatic
monthly budget reset.

The provider has no submission idempotency key. A committed dispatch claim
permits one POST for that job's entire lifetime. A timeout or crash after that
claim is uncertain and cannot automatically resubmit or fail over. A known
request is polled/canceled using its validated stored references. Unknown billing
keeps its hold even if the output is rejected, consent is revoked or an account
is deleted. Confirmed final billing is recorded separately; an overrun disables
further generation. An estimate is never labeled as the final charge.

The service-only `presenter-drain` endpoint performs bounded durable recovery and
cleanup. It is not scheduled by this branch. Activation must include an
authenticated scheduler and monitoring for stuck jobs, held billing and cleanup
failures. Generation activation flags do not disable already-required cleanup.

The generated result is downloaded only from explicitly configured verified CDN
hosts, checked as bounded MP4 bytes, and stored privately. Subject acceptance
binds its digest. Import goes through the existing upload reservation/gateway,
then records provenance and an immutable Presenter identity marker. Existing
publication and recursive edit checks enforce the approval predicate.

## Activation and deployment

This branch does not enable paid processing. Before a permitted live trial:

- Establish Higgsfield enterprise terms covering these client/likeness inputs,
  including no training and actual retention/deletion. Quotes transmit media URLs
  too and require the same data-use gate.
- Confirm account entitlement and pricing for the exact Genjutsu endpoint. Agree
  on a Presenter-specific per-job maximum and total budget with the owner. The
  spatial experiment budget does not authorize this work.
- Verify the provider output CDN host for this account and set its exact hostname
  in `PRESENTER_OUTPUT_HOSTS`. Do not guess or use a wildcard.
- Configure server secrets and `PRESENTER_EXECUTION_ENABLED=true`, then insert the
  service-managed workspace runtime with `enabled`,
  `enterprise_no_training_confirmed`, `contract_reference`, `price_version`,
  `max_job_cents` and `total_budget_cents`. Leave these disabled/zero until the
  preceding evidence exists. Never place API keys in the browser.
- Deploy and schedule the service-authenticated `presenter-drain` endpoint. Track
  unknown submissions and final billing using actual provider evidence. Test
  failed/canceled jobs and storage cleanup before allowing routine use.
- Run a small authorized real-person example. Check identity, gestures, temporal
  consistency, speech/audio, property preservation and actual billing. Approval
  to ship depends on that result, not the offline fixture screenshots.

Apply all four new migrations before deploying the Studio, renders and tours
edge functions, the recovery function and web assets. A pre-existing migration-history mismatch must be
reconciled first: the production-review migration is `20260924153826` in the
repository but `20260924165200` in the live ledger. Do not blindly reapply it.

Implementation and receipts are described in
[the handoff](../handoff/CODEX-AI-PRESENTER-20260924.md). The verified provider schema
and official sources are in [the provider note](../providers/higgsfield-genjutsu-motion-transfer-20260924.md).
