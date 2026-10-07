# Reviewed launch fixes — 2026-10-07

Candidate branch: `fix/max-audit-20261007`, based on `5ab826a`.
This is a source review and test record. Deployment, CI and TestFlight delivery
must be recorded separately; this file does not claim they have happened.

## Changes

- Upload admission preserves sign-in, plan, size and monthly quota errors.
  The iOS queue stops retrying those terminal admissions; short burst limits
  remain retryable.
- Native presentation and search defaults are scoped to the signed-in account
  and selected workspace. A stale listing screen closes on either transition.
  Admitted background work keeps its existing ownership and recovery rules.
- Older FAL status receipts recover through their stored actor, workspace,
  provider, model and request identity. Only the exact model endpoint or its
  documented application root is accepted. No new generation is submitted.
- Photo, voice and chapter routes refund the exact admitted rate window on the
  covered failures. Money reservations remain separate from usage counters.
- A missing serving allowance reports service unavailability; an exhausted
  funded allowance reports quota exhaustion. Provider balance errors no longer
  imply invalid customer media.
- Server failures log a small sanitized classification without error messages,
  prompts, URLs, credentials or customer identifiers.
- The sample listing explains that it is a demonstration and collects no inquiry.
  Public product text follows current account and trial restrictions.
- The deletion migration blocks unsafe custody transitions before recording a
  destructive intent, protects new references during deletion, retains exact
  reflection cleanup identities and requires the existing soft-delete path.
  Shared/former workspace cleanup can still require explicit support assistance.
- Supabase imports use exact version 2.116.0; the dormant Python worker pins
  updated requests/urllib3, and spatial source plus CI use Pillow 12.3.0.
  These dependency changes do not activate spatial services or GPU jobs.
- CI defaults to read-only repository access and includes the new native privacy
  and deletion integrity checks. Local CLI scratch metadata is no longer tracked.

## Local evidence

Private receipts and retained failure controls are under
`/Users/pilksclaes/LocalRendpropAudits/max-audit-20261007` and the earlier launch
evidence directory. Do not copy credential or customer evidence into Git.

- Backend Deno: 1,745 passed, zero failed, one pre-existing ignored test.
- Native presentation: 32 checks and nine compiled negative controls.
- Upload recovery: 160 assertions and nine compiled negative controls.
- FAL recovery: 55 focused tests, 14 old/new controls, 32 existing receipt
  regressions and nine filter contracts; actual handler typecheck passed.
- Rate receipt routes: 92 focused/neighbour tests, four compiled controls;
  old photo fixtures also pass with exact receipt-window assertions.
- Disposable deletion database: 29 SQL assertions, all 270 invariants on fresh
  application and replay, concurrent reference refusal and an actual invite
  joining while deletion waits on the workspace lock. Removing the post-lock
  custody check fails its unchanged oracle; six actual loopback PostgREST
  checks also pass.
- Public-page typecheck and full local test suite passed, including 430 emitted
  form assertions across 31 cases with no network calls.
- Four worker recovery tests passed under the new resolved Python dependency set.
- Final native sources compiled successfully with the iPhone SDK in Release.
  This was unsigned and used no camera or physical device.

These checks establish the scoped changes. They do not prove that every feature,
customer workflow, provider output or physical capture path works.

## Remaining release gates

Paid checkout and AI availability still need certified serving reserves and
authoritative Apple net receipts. The approved trial experience is seven days
or exhaustion of one walkthrough, five admitted photo requests, one publication
and one GiB lifetime upload; no trial cash pool has been approved or activated.
Usage exhaustion never advances Apple's billing date.

Credential replacement, protected media cutover, restore/DR proof, shared-work
deletion support and permanent purchase-fulfilment error handling remain separate
work. Existing media protections and cost fences must stay enabled. Real-phone,
client-email and provider-quality acceptance remain outstanding. Spatial stays
experimental. Public App Review submission is outside this batch.
