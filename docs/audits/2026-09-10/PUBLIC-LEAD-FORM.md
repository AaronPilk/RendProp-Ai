# WH-10 — public enquiry confirmation and bounded waiting

Status: repaired and tested locally, not deployed. This closes the **browser
lead-form portion** retained by `PUBLIC-HOST-UPSTREAM.md`; it does not change
the leads API, CRM, schema, Turnstile policy, or Apple builds.

Base: `48401beb3ef0bfb997bff054ee19e8454653de29`.
Branch: `fix/public-lead-form-confirmation-20260910`.
Owned files: `src/player.ts`, `scripts/check-lead-form.mjs`, and `package.json`
under `services/edge/tour-host/`, plus this report. No HTML/CSS/layout changes,
new dependency, provider call, customer lead, migration, or deployment.

## Original bug, reproduced through the emitted handler

At base `player.ts:1613`, the submit handler had no deadline/abort signal.
`res.json()` failures became `{}` at `:1615`, and only HTTP status was checked
at `:1616`. Every 2xx reached the success branch at `:1626`: form hidden,
“Request sent” displayed, and an optional booking link opened, even for HTML,
empty 204, `{ok:false}`, or `{ok:true}` with no persisted lead identity.
Disabling the button at `:1612` also did not guard a second submit event.

Offline reproductions now live in `scripts/check-lead-form.mjs`:

- `:137`: return malformed success envelopes from the actual emitted form's
  fetch; the old handler hides the form and opens a booking link.
- `:153`: return HTML 200 or empty 204; old behavior incorrectly confirms.
- `:171`: hold either fetch headers or `res.json()` unresolved; the old form
  remains disabled indefinitely. Resolve late after the deadline; a timed-out
  attempt must not later confirm.
- `:185`: invoke the real registered submit callback twice before settlement;
  the old code issues two POSTs.
- `:194`: let attempt A time out, explicitly retry as B, then resolve A while B
  remains pending. A must not hide B's form, reset B's token, or cancel B's timer.

## Actual contract and repair

The API creates a lead at `services/supabase/functions/leads/index.ts:273` and
returns **201 `{ok:true,id}`** at `:301`. Its 10-minute dedup path returns
**200 `{ok:true,id,deduplicated:true}`** at `:270`. IDs are UUIDs
(`services/supabase/migrations/0001_init.sql:161`), and the route's own UUID
pattern is `leads/index.ts:43`.

The intentional honeypot path returns **200 `{ok:true}` without inserting**
at `leads/index.ts:198`. The browser preserves that behavior only when its
submitted `_hp` is truthy, including whitespace (the API checks raw truthiness).
It does not weaken normal submission confirmation to the honeypot envelope.

Current `services/edge/tour-host/src/player.ts`:

- `:1595`: one in-flight guard; duplicate submits are ignored before validation,
  payload collection, or network. The guard remains set after confirmed success.
- `:1596`: UUID-shaped lead ID required for ordinary success, with `ok === true`
  and a non-array JSON object checked at `:1623`.
- `:1598`: `sendLead` uses one **15,000 ms** deadline covering headers and JSON.
  It races that deadline against the entire operation and aborts the fetch at
  expiry. A stalled/abort-ignoring response cannot hold the form disabled or
  confirm after the race has already failed. Both outcomes clear the timer.
- `:1597`: timeout/unconfirmed copy says “We couldn't confirm your request.
  Your details are still here. Please wait a moment before trying again.”
  It deliberately does not say that the server failed to save the lead.
- `:1656`: only confirmed success hides the form and opens the existing optional
  booking handoff. `:1666` restores the original button label and enables manual
  retry on failure, retains all input, and preserves the existing Turnstile
  reset. Existing 403 validation and 429 wait-a-minute messages are unchanged.

Neither the old nor new success path calls `form.reset()`. Failure does not
clear any contact/message/honeypot input; only Turnstile is reset because a
consumed token cannot be sent again. Success/CTA markup, brand styles, request
credential settings, field validation, token forwarding, and unbranded
lead-script removal are unchanged.

## Executed proof

Node **25.9.0**, npm **11.12.1**, existing local dependencies. All commands ran
from this branch's `services/edge/tour-host/`; no live fetch is reachable in the
new fixture. Every fixture executes the form script extracted from the actual
`renderTourPage()` result, with its actual emitted config and form fields.
The complete engine is syntax-parsed; a bounded DOM stub executes the form
slice, not camera/video playback or a copied submit implementation.

| Command / source | Result |
|---|---|
| `node scripts/check-lead-form.mjs` against original base handler, initial 30 cases | **Exit 1**, 108 failures / 399 executed assertions / 30 cases / 0 skipped |
| Same gate after adding non-UUID fixture, against intermediate nonempty-ID check | **Exit 1**, 5 failures / 418 assertions / 31 cases / 0 skipped; `{ok:true,id:'not-a-lead-id'}` wrongly confirmed |
| `node scripts/check-lead-form.mjs` after UUID repair | **Exit 0**, 418 assertions / 31 cases / 0 skipped / 0 real network requests |
| `npm run typecheck` | **Exit 0**, `tsc --noEmit` |
| `npm test` | **Exit 0**: unbranded 557 assertions / 15 renders + 12 gate self-tests; routes 584 assertions; upstream 707 assertions / 75 cases / 0 skipped; lead form 418 assertions / 31 cases / 0 skipped |
| `npm run check:assets` | **Exit 0**, both local demo media files present and under 25 MiB |
| `git diff --check` | **Exit 0** |

The full `npm test` total is **2,266 assertions + 12 gate self-tests**, not
2,278 distinct end-to-end user flows. The initial negative run contains30
rather than31 cases. It also executes fewer postcondition assertions because
the pre-fix handler throws synchronously in its deliberate synchronous-fetch-
failure case; that exception is a recorded test failure, not a skip. The
subsequent UUID negative and positive runs both execute31 cases and418 assertions.

Evidence directory: `/tmp/rendprop-lead-form.1taicF/` (temporary; not durable).
Logs: `negative-before.log`, `negative-id-shape.log`, `lead-form-after.log`,
`typecheck.log`, `host-tests.log`, `assets.log`.

Final code SHA-256:

```text
75c1ed8fe8ed98aaa1ec1393f293ec92166f592ca3832d172178194173958dc4  src/player.ts
439cdd1fa618b52a6a5657a063f5bfe33181e86e7e48c05c1d67d73e3b0ce341  scripts/check-lead-form.mjs
9dcdfe40f0d78433ff98446ae4475ff2f02bea0cb056fbf425365a19bf09b3b0  package.json
b3048718ae64c50a47d0af7576148922e0fff1072529bd8f19d0ddea9064e750  host-tests.log
```

## Deliberate limits / next operator gate

Abort cannot retract server-side acceptance. The API still awaits optional CRM
work **after insertion** (`leads/index.ts:288`), so a browser timeout may mean the
lead is already saved. No automatic retry was introduced. Its 10-minute dedup
read (`:265`) is not an atomic idempotency guarantee, does not cover the demo
path (`:237` / `:244`), and does not establish exactly-once delivery across tabs,
devices, or retry windows. This unit does not claim otherwise.

This is an offline handler regression proof, not a live browser/CRM/Turnstile
integration or production deployment receipt. Browser timers can be throttled
while a tab is suspended; the 15-second application deadline is enforced when
the event loop runs, not a guarantee that a suspended page redraws on time.
No camera simulator testing, App Store Connect, provider spend, or deployment
was performed. Review and integrate this commit, then run the host gates on the
integrated tree before any separately authorized deployment.

## Root integration proof

Integrated and pushed as **`a9b13b1f1b66fee1f52fdd566e7de82f8b272b3b`**. Root read
the complete diff and actual-handler fixture, then independently executed
`npm run typecheck && npm test && npm run check:assets` from the integrated
host directory. Exit0, with the same2,266 assertions/12 self-tests and31 form
cases/0 skips; both demo assets pass. Current hashes match the three source
hashes above. A full hosted CI run was dispatched on this exact source; its
result is recorded separately in `HOSTED-CI-20260910.md`. Run34546654166 host
job103100643656 now also passes all2,266 assertions/12 self-tests including
418/31 form assertions/cases, clean install/typecheck, dry-run bundle and zero
production npm advisories. Full workflow remains red for the separate database
and scanner gates. No deployment occurred.
