# Higgsfield Genjutsu motion transfer: verified API contract

Verified against official public documentation on 2026-09-24. This change adds
request construction, an account quote helper, and dedicated retained-request
submit/status/cancel operations, with offline tests. It does
not activate a route, authorize provider processing, prove output quality, or
make any live authenticated call. The enterprise no-training agreement remains
pending; this adapter does not establish that agreement.

## Exact model and media contract

The official endpoint is intentionally spelled
`POST https://api.higgsfield.ai/higgsfiled/genjutsu/motion-transfer/v1.0`.
Do not correct `higgsfiled` to `higgsfield`.

| API field | Verified constraint |
| --- | --- |
| `video_url` | Required source performance video URI, 1–2083 characters |
| `image_urls` | Required ordered list of 1–8 image reference URIs, each 1–2083 characters |
| `prompt` | String, optional upstream with empty default, at most 10,000 characters |
| `resolution` | Exactly `720p` (default) or `480p` |

The JSON schema has `additionalProperties: false`. There is no `duration`,
`aspect_ratio`, `enhance_prompt`, voice identifier, Soul ID or other generation
parameter. Rendprop sends the reviewed prompt unchanged and never sends a prompt
enhancement flag to this endpoint. Sending `enhance_prompt: false`, as older
Higgsfield models require, would violate this model's schema.

Upstream requires a source video of at least four seconds and trims videos over
30 seconds. Rendprop instead requires a verified duration from **4 through 30
seconds**, including fractional measured durations, so a request cannot silently
lose its ending. No duration is sent in the API body; output follows the source.
The performance video must be a separate asset from the approved character
images. Resolution is limited to the documented tiers; this adapter does not
promise native 1080p/4K output, identity fidelity, property fidelity or lip sync.

Sources: [Motion transfer schema](https://docs.higgsfield.ai/docs/models/genjutsu/motion-transfer.md),
[Genjutsu workflows](https://docs.higgsfield.ai/docs/models/genjutsu.md).

## Trusted server integration

Call `createHfMotionTransferInput()` with this server-only shape:

```ts
{
  performanceVideoUrl: string,
  performanceDurationSeconds: number,
  approvedCharacterImageUrls: readonly string[],
  reviewedPrompt: string,
  resolution?: "720p" | "480p"
}
```

The caller must first resolve owned asset records, completed upload receipts,
measured video duration, approved character references, active identity consent,
the reviewed prompt, property/org authorization and provider activation. Do not
construct this input directly from client URL fields or trust client-supplied
duration or approval booleans. URLs must point to server-approved storage objects
with enough remaining access time for the provider to read them.

The factory adds a process-local WeakMap brand and snapshots references and
prompt. A generic `GenerateInput`, forged `extra` fields, JSON round-trip or
shallow clone cannot activate the motion-transfer endpoint. This catches
accidental use; **the brand is not an authorization boundary**. Reconstruct it
after fresh server checks when resuming a durable job in another process.

Provider validation additionally rejects non-HTTPS URLs, credentials, fragments,
custom ports, IP literals, local-only hostnames, whitespace/backslashes, invalid
lengths, unsupported fields and invalid duration/resolution/reference counts.
It does not perform DNS resolution or prove storage ownership; the calling
server must enforce its storage host and object-key allowlist. Signed URLs are
preserved exactly and never included in validation errors.

The upload table's `duration_s` is client-claimed completion metadata, not a
trusted media probe. The execution controller downloads each authorized original,
checks its actual SHA-256 and size against the approved binding, and runs the
existing strict `ai-video/mp4duration.ts` movie/track/sample timing probe over
those same bytes. It repeats verification before dispatch and rechecks approval
immediately before estimate and dispatch. Source clips are currently limited to
48 MiB and reference photos to 12 MiB each; JPEG, PNG and WebP are supported,
while HEIC must first be exported to one of those formats. Source duration is
4–30 seconds; generated outputs permit 1–31 seconds for encoder boundaries.
Unsupported media fails before a quote. These are bounded Edge memory limits,
not upstream pricing tiers. Signed source/reference URLs are renewed after all
byte probes; queue-time availability still needs controlled live validation.

The recording guide is not sent as the provider's visual edit instruction. The
SQL quote and job store an immutable `execution_spec` containing the versioned
instruction to replace only the approved presenter identity while preserving
performance and property details. The controller sends that exact instruction.
This instruction is not proof that a model obeys it: identity, property fidelity,
motion and audio still require human review of a real generated video.

No shared `GenerateInput` fields or generic provider interfaces were widened.
Use task `video.agent_presenter` and the exact model constant. Do not put a
fabricated `unit_cents` price into a live route to enable this adapter.

## Quotes and real cost

The official billing documentation prescribes a preflight
`POST /estimate/{model_slug}` using the same parameters as generation and the
authenticated account. The model-specific expansion for this integration is
`/estimate/higgsfiled/genjutsu/motion-transfer/v1.0`. This path is derived from
the documented generic estimate convention; its response for this account has
not been exercised live.

`estimateHfMotionTransfer(input)` sends that request once and returns
`{ credits, usd, ceilingCents }`. The first two are exact validated decimal
strings returned by the provider. `ceilingCents` rounds USD upward using integer
arithmetic, including fractions of a cent. Negative, scientific-notation,
non-string, non-finite, malformed and unbounded amounts fail closed. The parser's
$10,000 maximum is only a defensive numeric ceiling; it is **not a spending
allowance**. The server must enforce the approved per-job and account budget,
bind any quote to the exact reviewed media and prompt, and handle quote expiry
or changes before submission.

**There is no verified Genjutsu credit/USD price yet.** The documentation's
`1.500` credits / `$0.094` example is illustrative and uses a SOUL endpoint;
it is not a Genjutsu price. Obtain this account's authenticated estimate and
confirm enterprise pricing before activating or publishing a price. Do not
convert credits with an assumed exchange rate. Reconcile actual provider usage
after a controlled accepted job; an estimate is not a final invoice.

Source: [Billing and retention](https://docs.higgsfield.ai/docs/concepts/billing-and-retention.md).

## Request lifecycle and cancellation

Authentication is `Authorization: Key <key_id>:<key_secret>`, server-side only.
A successful submit returns `request_id`, `status_url`, and `cancel_url`.
Persist the accepted request identifier immediately. The dedicated execution
helpers require a UUID and exact matching `https://api.higgsfield.ai/requests/`
status/cancel paths, prohibit redirects, bound responses to 64 KiB, and check
the returned status identity. Valid accepted references are retained even if
the initial response has already advanced beyond `queued`.
It preserves the separate terminal moderation state; refusal is not a reason
to submit the same request to another provider.

The upstream statuses are `queued`, `in_progress`, `completed`, `failed`,
`nsfw`, and `canceled`. The final four are terminal. Successful outputs remain
available for at least seven days, so copy approved results to Rendprop storage
before reporting durable success. Upstream says failed/NSFW requests and
successfully canceled queued requests are refunded; verify actual billing when
reconciling jobs.

Rendprop stores the completed clip in its private uploads bucket under
`presenter-private/<org>/<job>/output.mp4`. Only the represented person can
preview it until they approve those exact bytes. Import into the property
library uses native upload quota/reservation receipts only after acceptance,
adds explicit generated-media provenance, and remains fenced by current consent.
Revocation/deletion queues private and imported-object cleanup. A known provider
completion releases its concurrency slot even if output retention needs retry;
it does not release the financial hold. Real charge reconciliation remains
manual because the public status response does not establish an actual-cost API.

`PRESENTER_EXECUTION_ENABLED` is off by default; SQL runtime also requires a
confirmed data-use agreement, a verified price version, an explicitly approved
per-job maximum and workspace budget. The exact account estimate is displayed
separately from the larger authorized maximum hold. `PRESENTER_OUTPUT_HOSTS`
must list verified exact output CDN hosts; documentation examples do not justify
a guessed host. The service-only `presenter-drain` is implemented for durable
recovery, cancellation and cleanup, but no scheduler or live route is enabled
by these changes. See [execution protocol](../studio/presenter-execution-rpc.md).

Submissions do **not** currently accept an idempotency key. The adapter sends one
POST and does not retry it. A submission timeout is ambiguous: the job may have
been accepted. A durable caller must reconcile that attempt rather than run the
generic timeout failover loop or silently submit another job. Quotes do not
create a generation.

The official queued cancellation endpoint is `POST /requests/{request_id}/cancel`;
prefer the validated `cancel_url` returned by submission. Success is **202 with
an empty body**, so a cancellation implementation must not require JSON. A 400
means processing has started and cancellation is unavailable. The documented
request ID is a UUID. Cancellation must remain bound to the server's stored job
and authenticated account.

This change does not add cancellation to the generic `JobRef` interface, which
does not retain `cancel_url`. The dedicated Presenter lifecycle stores and
validates that returned URL separately, binds cancellation to the stored request,
and records the result without claiming an in-progress job was stopped or
refunded. This does not change cancellation for older generic provider jobs.

Sources: [Authentication](https://docs.higgsfield.ai/docs/authentication.md),
[Request lifecycle](https://docs.higgsfield.ai/docs/concepts/requests.md),
[Polling](https://docs.higgsfield.ai/docs/concepts/polling.md),
[Errors and retries](https://docs.higgsfield.ai/docs/concepts/errors.md),
[Cancel a queued request](https://docs.higgsfield.ai/docs/api-reference/requests/cancel-a-queued-request.md).

## Offline validation

Run from `services/supabase/functions`:

```sh
deno test --cached-only --allow-env --allow-read \
  _shared/providers/higgsfield_motion_transfer_test.ts \
  _shared/providers/providers_test.ts
```

The focused suite verifies the exact endpoint/body, trust-brand failures,
immutable approval snapshots, media/prompt bounds, invalid URL schemes and local
hosts, exact quote arithmetic, one-POST timeout behavior, and completed/moderated
responses. The existing provider suite covers unchanged Seedance/DoP behavior.
Network permission is absent, and provider HTTP calls are mocked. These checks
prove contract handling; they do not prove live Genjutsu availability, price,
performance, enterprise privacy terms or video quality.
